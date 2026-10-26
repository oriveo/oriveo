import type { AIModel, LastUsedModelRef, Provider } from '@oriveo/shared';
import { sameNormalizedID } from '../../utils/id-utils';
import {
  getProviderCatalogStatus,
  getProviderDefaultModelId,
  getProviderRetiredModels,
  getRelayRuntimeConfig,
  listProviderModelIds,
  resolveCatalogModel,
} from '../metadata/metadata-client';
import {
  resolveModelRetirement,
  type ModelRetirement,
  type RetirementCatalog,
  type RetirementCatalogModel,
} from '../chat/conversation-model-status';
import { buildCatalogModel } from './catalog-model';
import { findModelByIdentifier } from './model-display-lookup';
import { resolveRelayStoredModel } from './relay-model-identity';
import { enrichRelayCatalog } from './relay-official-catalog-match';
import type { RelayRuntimeConfig, RelayTransportKey } from '../metadata/metadata-client';
import { effectiveTransport } from '@oriveo/core/providers/relay-effective';

export interface ProviderSelectionSnapshot {
  provider: Provider;
  enabledModels: AIModel[];
  currentModel: AIModel | null;
  defaultModel: AIModel | null;
  /** Given when the model of an official-provider historical conversation is judged not available: currentModel is empty then. */
  modelRetirement?: ModelRetirement;
  /** last_used_retired when the preferred model of a new chat (last used / user default) was not used. */
  defaultModelHint: 'last_used_retired' | null;
  /** The id of the preferred model that was not used (given together with defaultModelHint); the "once per device" hint is keyed on it. */
  unusedPreferredModelId: string | null;
}

interface SelectionOptions {
  /** The model stored by a historical conversation: when retired / missing, no default model is filled in and it is handed to the verdict as-is. */
  requestedModelId?: string | null;
  /** The preferred model of a new chat (manual selection / last used): when unusable, fall back by the catalog and bring back the hint marker. */
  preferredModelId?: string | null;
  /** A relay's fallback model looks at the last-used model; official providers do not read it. */
  lastUsedModelRef?: LastUsedModelRef | null;
}

export function createProviderSelectionSnapshot(
  provider: Provider | undefined,
  options: SelectionOptions = {},
): ProviderSelectionSnapshot | null {
  if (!provider) return null;

  const enabledModels = provider.kind === 'relay'
    ? enrichRelayModelsByTransport(provider, provider.models, getRelayRuntimeConfig())
    : provider.models;
  if (provider.kind === 'relay') {
    const defaultModel = resolveRelayFallbackModel(provider.id, enabledModels, options.lastUsedModelRef);
    // A relay resolves the stored value with read compatibility: a literal hit, otherwise a unique canonical hit; no date-stripping fold.
    const requestedModel = resolveRelayStoredModel(enabledModels, options.requestedModelId ?? options.preferredModelId);
    return {
      provider,
      enabledModels,
      currentModel: requestedModel ?? defaultModel ?? null,
      defaultModel,
      defaultModelHint: null,
      unusedPreferredModelId: null,
    };
  }

  const requestedModelId = options.requestedModelId?.trim();
  // A conversation with an empty modelID / a new chat without a stated preference: pointing at this connection's last used model is also a tier.
  const lastUsedHere = !requestedModelId && options.lastUsedModelRef
    && sameNormalizedID(options.lastUsedModelRef.providerID, provider.id)
    ? options.lastUsedModelRef.modelID
    : null;
  const preferredModelId = options.preferredModelId?.trim() || lastUsedHere;
  if (!requestedModelId) {
    const { model: defaultModel, hint: defaultModelHint, unusedPreferredModelId } = resolveDefaultEnabledModel(
      provider,
      enabledModels,
      preferredModelId,
    );
    return { provider, enabledModels, currentModel: defaultModel, defaultModel, defaultModelHint, unusedPreferredModelId };
  }
  // Historical conversation: the default model is only computed when it is read (most callers only use currentModel), then remembered.
  let defaultModelMemo: AIModel | null | undefined;
  const lazyDefaultModel = (): AIModel | null => {
    if (defaultModelMemo === undefined) {
      defaultModelMemo = resolveDefaultEnabledModel(provider, enabledModels, preferredModelId).model;
    }
    return defaultModelMemo;
  };

  // A historical conversation gets no preference hint of a new chat and never falls to the default model.
  const requestedModel = findModelByIdentifier(enabledModels, requestedModelId);
  // When the verdict is not available, do not fill in a default model or rewrite the conversation model; leave it to the banner and the send guard.
  const modelRetirement = resolveProviderModelRetirement(provider, requestedModelId, enabledModels);
  if (modelRetirement && modelRetirement.status !== 'available') {
    return {
      provider, enabledModels, currentModel: null, modelRetirement,
      get defaultModel() { return lazyDefaultModel(); },
      defaultModelHint: null, unusedPreferredModelId: null,
    };
  }
  // Available, but neither the enabled models nor the catalog resolve it (catalog not loaded, hand-typed id): build a bare model from the stored id instead of swapping in the default model.
  const currentModel = requestedModel
    ?? resolveHistoricalModel(provider, requestedModelId)
    ?? bareStoredModel(provider, requestedModelId);

  return {
    provider,
    enabledModels,
    currentModel,
    get defaultModel() { return lazyDefaultModel(); },
    defaultModelHint: null,
    unusedPreferredModelId: null,
  };
}

/** A bare model for a stored id: the name is the id, and capabilities / price go through the same construction as catalog models (absent when unresolved). */
function bareStoredModel(provider: Provider, modelId: string): AIModel {
  return buildCatalogModel({ providerKind: provider.kind, runtimeModelId: modelId, fallbackName: modelId });
}

/** Enabled model ids used for the verdict: both the literal id and the canonical count (the catalog default is often the canonical while a dated snapshot is enabled). */
function enabledModelIdentifiers(enabledModels: readonly AIModel[]): string[] {
  const ids = new Set<string>();
  for (const model of enabledModels) {
    ids.add(model.id);
    if (model.canonicalModelId) ids.add(model.canonicalModelId);
  }
  return [...ids];
}

/**
 * The catalog base table shared within one verdict: the catalog id set and the tombstone table (indexed by id).
 * Only a provider whose catalog status is loaded gets a verdict; pending / absent returns null (judged available).
 * It is only reused within a single call or one judge (createRetirementJudge) and never enters a module-level cache, so it cannot go stale after a catalog revision.
 */
interface RetirementCatalogSource {
  retiredModels: NonNullable<RetirementCatalog['retiredModels']>;
  retiredById: Map<string, NonNullable<RetirementCatalog['retiredModels']>[number]>;
  catalogIds: Set<string>;
  defaultModelId: string | undefined;
}

function loadRetirementCatalogSource(provider: Provider): RetirementCatalogSource | null {
  if (getProviderCatalogStatus(provider.kind) !== 'loaded') return null;
  const retiredModels = getProviderRetiredModels(provider.kind);
  const retiredById = new Map<string, (typeof retiredModels)[number]>();
  // Same rule as array find: with several entries for one id, take the first.
  for (const entry of retiredModels) if (!retiredById.has(entry.id)) retiredById.set(entry.id, entry);
  return {
    retiredModels,
    retiredById,
    catalogIds: new Set(listProviderModelIds(provider.kind)),
    defaultModelId: getProviderDefaultModelId(provider.kind),
  };
}

/**
 * Build entries only for the candidate ids and their canonical / successor (the tombstone and lifecycle routedTo); the verdict only looks up by id.
 * onlyWantedTombstones: tombstones carry only the ids in the slice (the verdict only looks tombstones up by those ids, so the result is unchanged), letting per-candidate verdicts scan less of the full table.
 */
function sliceRetirementCatalog(
  provider: Provider,
  source: RetirementCatalogSource,
  candidateIds: readonly string[],
  onlyWantedTombstones = false,
): RetirementCatalog {
  const { retiredModels, retiredById, catalogIds } = source;
  const resolveMap: Record<string, string> = {};
  const wanted = new Set<string>();
  const addId = (id: string) => {
    if (wanted.has(id)) return;
    wanted.add(id);
    const canonical = resolveCatalogModel(id, provider.kind)?.canonicalModelId;
    if (canonical && canonical !== id) {
      resolveMap[id] = canonical;
      wanted.add(canonical);
    }
  };
  // The candidate itself plus its successor: the tombstone routedTo and the catalog lifecycle routedTo (a successor is only given when it is in the catalog).
  for (const id of candidateIds) {
    if (!id) continue;
    addId(id);
    const tombstoneSuccessor = retiredById.get(id)?.routedTo;
    if (tombstoneSuccessor) addId(tombstoneSuccessor);
    const lifecycleSuccessor = resolveCatalogModel(id, provider.kind)?.lifecycle?.routedTo;
    if (lifecycleSuccessor) addId(lifecycleSuccessor);
  }
  const models: RetirementCatalogModel[] = [];
  for (const id of wanted) {
    if (!catalogIds.has(id)) continue;
    const resolved = resolveCatalogModel(id, provider.kind);
    const lifecycle = resolved?.lifecycle;
    models.push({
      id,
      ...(resolved?.displayName ? { displayName: resolved.displayName } : {}),
      ...(lifecycle ? {
        lifecycle: {
          state: lifecycle.state,
          shutdownAt: lifecycle.shutdownAt,
          ...(lifecycle.routedTo !== undefined ? { routedTo: lifecycle.routedTo } : {}),
        },
      } : {}),
    });
  }
  const tombstones = onlyWantedTombstones
    ? [...wanted].flatMap((id) => {
      const entry = retiredById.get(id);
      return entry ? [entry] : [];
    })
    : retiredModels;
  return { models, retiredModels: tombstones, resolveMap, defaultModelId: source.defaultModelId };
}

/**
 * Retirement verdict for the model of a historical conversation; a relay goes through modelRemoval and returns null here.
 * A read-only verdict: it neither writes the conversation nor sends anything out.
 */
export function resolveProviderModelRetirement(
  provider: Provider | undefined,
  conversationModelID: string | null | undefined,
  enabledModels: readonly AIModel[] = provider?.models ?? [],
): ModelRetirement | null {
  if (!provider) return null;
  return createRetirementJudge(provider).retirementOf(conversationModelID, enabledModels);
}

/** Judge retirement / new-chat selectability model by model for one connection: the catalog base table is built once, and the verdicts match calling the single-model entries one by one. */
export interface RetirementJudge {
  /** Same as resolveProviderModelRetirement(provider, modelId, enabledModels). */
  retirementOf(modelId: string | null | undefined, enabledModels: readonly AIModel[]): ModelRetirement | null;
  /** Same as isModelSelectableForNewChat(provider, model). */
  isSelectableForNewChat(model: Pick<AIModel, 'id' | 'canonicalModelId'>): boolean;
}

/**
 * Build a judge for one connection: the catalog base table (catalog id set, tombstone index) is taken once on first use, and each model afterwards only slices its own entries.
 * The base table lives as long as the judge, so callers must rebuild it after a catalog revision (for example memoized by metadata version); now is taken fresh on every verdict.
 */
export function createRetirementJudge(provider: Provider): RetirementJudge {
  if (provider.kind === 'relay') {
    return { retirementOf: () => null, isSelectableForNewChat: () => true };
  }
  let sourceMemo: RetirementCatalogSource | null | undefined;
  const catalogFor = (candidateIds: readonly string[]): RetirementCatalog | null => {
    if (sourceMemo === undefined) sourceMemo = loadRetirementCatalogSource(provider);
    return sourceMemo ? sliceRetirementCatalog(provider, sourceMemo, candidateIds) : null;
  };
  const retirementOf = (
    conversationModelID: string | null | undefined,
    enabledModels: readonly AIModel[],
  ): ModelRetirement | null => {
    const modelId = conversationModelID?.trim();
    if (!modelId) return null;
    const userModels = enabledModelIdentifiers(enabledModels);
    // A stored value that matches an enabled model by canonical / dated snapshot also counts as a user-enabled model.
    if (findModelByIdentifier([...enabledModels], modelId)) userModels.push(modelId);
    return resolveModelRetirement({
      // Build catalog entries only for the conversation model (and its canonical / successor); enabled models are judged through userModels instead of being looked up one by one.
      catalog: catalogFor([modelId]),
      userModels,
      conversation: { modelId },
      now: new Date(),
    });
  };
  const isSelectableForNewChat = (model: Pick<AIModel, 'id' | 'canonicalModelId'>): boolean => {
    const retirement = retirementOf(model.id, [model as AIModel]);
    if (retirement && retirement.status !== 'available') return false;
    const candidates = [model.id, ...(model.canonicalModelId ? [model.canonicalModelId] : [])];
    const catalog = catalogFor(candidates);
    if (!catalog) return true;
    // When the model's own id is not in the catalog, the canonical it falls back to must itself be usable (listed, not tombstoned, not past its shutdown date), not merely listed.
    const now = new Date();
    return candidates.some((id) => listedInCatalog(catalog, id)
      && resolveModelRetirement({ catalog, userModels: [], conversation: { modelId: id }, now }).status === 'available');
  };
  return { retirementOf, isSelectableForNewChat };
}

/**
 * Resolve the transport a Relay model uses for enrichment (through the Relay 2.0 `effectiveTransport`; no model = the connection default).
 * Exported so write-time enrichment (`provider-model-ops.ts:patchProviderModels`) and bootstrap
 * re-enrichment can share it instead of repeating the resolution at several call sites.
 * The llama.cpp native channel has no envelope and returns undefined.
 */
export function resolveRelaySelectionTransport(
  provider: Provider,
  model?: Pick<AIModel, 'relayTransport'> | null,
): RelayTransportKey | undefined {
  const transport = effectiveTransport(provider, model);
  return transport === 'llamacpp_native' ? undefined : transport;
}

/** Enrich each model with its own protocol (Relay 2.0: the protocol is a property of the model, so the envelope intersection is per model too). */
export function enrichRelayModelsByTransport(
  provider: Provider,
  models: AIModel[],
  runtimeConfig: RelayRuntimeConfig,
): AIModel[] {
  return models.flatMap((model) => enrichRelayCatalog([model], resolveRelaySelectionTransport(provider, model), runtimeConfig));
}

/**
 * Fallback model of a relay (including the local engine): if the last-used model points at this connection and is still
 * enabled, use it; otherwise the first enabled model. A relay has no default model, so a legacy `isDefault` is never read.
 */
export function resolveRelayFallbackModel<T extends Pick<AIModel, 'id' | 'canonicalModelId'>>(
  providerID: string,
  enabledModels: readonly T[],
  lastUsedModelRef: LastUsedModelRef | null | undefined,
): T | null {
  if (lastUsedModelRef && sameNormalizedID(lastUsedModelRef.providerID, providerID)) {
    const lastUsed = resolveRelayStoredModel(enabledModels, lastUsedModelRef.modelID);
    if (lastUsed) return lastUsed;
  }
  return enabledModels[0] ?? null;
}

/**
 * Relay verification sample: fallback model -> first catalog model -> null.
 * On null the caller sends no request and takes the existing "missing model" error.
 */
export function resolveRelayVerificationSampleModelID(
  provider: Pick<Provider, 'id' | 'models' | 'catalogModels'>,
  lastUsedModelRef: LastUsedModelRef | null | undefined,
): string | null {
  return resolveRelayFallbackModel(provider.id, provider.models, lastUsedModelRef)?.id
    ?? provider.catalogModels[0]?.id
    ?? null;
}

/**
 * Model for a new chat on an official provider: the preference (manual selection / last used) when usable and enabled;
 * otherwise the catalog defaultModelId, then the first usable enabled model, skipping retired ones; the connection isDefault is not read.
 * When a (non-empty) preference was not used, last_used_retired is returned.
 */
function resolveDefaultEnabledModel(
  provider: Provider,
  enabledModels: AIModel[],
  preferredModelId: string | null | undefined,
): { model: AIModel | null; hint: 'last_used_retired' | null; unusedPreferredModelId: string | null } {
  if (enabledModels.length === 0) return { model: null, hint: null, unusedPreferredModelId: null };

  const enabledIds = enabledModelIdentifiers(enabledModels);
  const enabled = new Set(enabledIds);
  const preferred = preferredModelId?.trim() || null;
  // Take the catalog base table (id set, tombstone index) once at the start of the call; each candidate only slices its own entries; null when the catalog is not loaded.
  const source = loadRetirementCatalogSource(provider);
  const catalogFor = (id: string): RetirementCatalog | null => (
    source ? sliceRetirementCatalog(provider, source, [id], true) : null
  );
  const now = new Date();
  // Judge candidate by candidate and stop at the first hit (a catalog slice is only built for candidates actually judged): the verdict only looks at the entries of that id and its canonical, with the same result as slicing the whole table.
  // Usable = enabled, in the catalog when the catalog is loaded (missing is not a candidate), and not retired; judged usable when the catalog is not loaded.
  const usable = (id: string | null | undefined): id is string => {
    if (!id || !enabled.has(id)) return false;
    const catalog = catalogFor(id);
    if (!catalog) return true;
    if (!listedInCatalog(catalog, id)) return false;
    return resolveModelRetirement({ catalog, userModels: [id], conversation: { modelId: id }, now }).status === 'available';
  };
  // Catalog not loaded: only rank the candidates among the enabled models; the catalog default is still the one the index gives.
  const catalogDefaultId = source
    ? source.defaultModelId
    : getProviderDefaultModelId(provider.kind);
  // The catalog status of an enabled model only looks at its own id: available is usable, retired is always skipped; only missing (not in the catalog) consults the canonical.
  const ownStatus = (id: string) => {
    const catalog = catalogFor(id);
    return catalog
      ? resolveModelRetirement({ catalog, userModels: [], conversation: { modelId: id }, now }).status
      : 'available';
  };
  const modelUsable = (model: AIModel): boolean => {
    const status = ownStatus(model.id);
    if (status === 'retired') return false;
    return status === 'available' || usable(model.canonicalModelId);
  };
  // Catalog default tier: match by alias among the usable enabled models and take the enabled model itself.
  // An enabled model that is missing on its own id but alias-matches the catalog default counts as in the catalog when the catalog default itself is in the catalog and not retired; only used for the default tier.
  const defaultListedAndLive = (id: string): boolean => {
    const catalog = catalogFor(id);
    if (!catalog) return true;
    return listedInCatalog(catalog, id)
      && resolveModelRetirement({ catalog, userModels: [], conversation: { modelId: id }, now }).status === 'available';
  };
  const catalogDefault = catalogDefaultId
    ? findModelByIdentifier(enabledModels, catalogDefaultId, (model) => modelUsable(model)
      || (ownStatus(model.id) === 'missing' && defaultListedAndLive(catalogDefaultId))) ?? null
    : null;
  const pickedId = usable(preferred)
    ? preferred
    : catalogDefault?.id ?? enabledModels.find((model) => modelUsable(model))?.id ?? null;
  const model = catalogDefault && pickedId === catalogDefault.id
    ? catalogDefault
    : pickedId ? findModelByIdentifier(enabledModels, pickedId) ?? null : null;
  // Only counts as last_used_retired when the preference was not used and it is retired / missing in the catalog (whether or not it is still enabled).
  const preferredCatalog = preferred && source ? catalogFor(preferred) : null;
  const preferredGone = preferredCatalog !== null && preferred !== null && resolveModelRetirement({
    catalog: preferredCatalog, userModels: [], conversation: { modelId: preferred }, now,
  }).status !== 'available';
  const pickedHint = preferred !== null && pickedId !== preferred && preferredGone ? 'last_used_retired' as const : null;
  // The hint is only given when a last-used model exists and was not used because of retirement / catalog absence (cross-end-closure newChatDefaultCases);
  // subscription connections without a catalog give no hint; when the catalog is not loaded, retirement / absence cannot be judged, so no hint either.
  const hint = preferred && source && hasRetirementCatalog(provider) ? pickedHint : null;
  return { model, hint, unusedPreferredModelId: hint ? preferred : null };
}

/** Whether the connection has a catalog that can judge retirement: subscription sign-in connections have none. */
function hasRetirementCatalog(provider: Provider): boolean {
  return provider.authMode !== 'subscription';
}

/** The (loaded) catalog lists it: by literal id or by the canonical through resolveMap. */
function listedInCatalog(catalog: RetirementCatalog, id: string): boolean {
  const canonical = catalog.resolveMap?.[id];
  return catalog.models.some((entry) => entry.id === id || (canonical !== undefined && entry.id === canonical));
}

/**
 * Whether an enabled model can be picked by a new chat / skill: a relay always can; an official provider needs it not retired,
 * and, when the catalog is loaded, in the catalog (missing is unusable); judged usable when the catalog is not loaded.
 */
export function isModelSelectableForNewChat(provider: Provider, model: Pick<AIModel, 'id' | 'canonicalModelId'>): boolean {
  return createRetirementJudge(provider).isSelectableForNewChat(model);
}

/**
 * Resolve the successor (successorId) given by a retirement verdict into a selectable model object: only look in the enabled
 * models of the connection (provider.models) by id or canonicalModelId. A successor that is in the catalog but not enabled returns null,
 * and the caller falls back to "choose a model", so a model that is not enabled is not brought into the conversation through catalog
 * resolution (a model that is not enabled must not be added to the model library automatically).
 */
export function resolveRetirementSuccessorModel(
  provider: Provider | undefined,
  successorId: string | null | undefined,
): AIModel | null {
  const trimmed = successorId?.trim();
  if (!provider || !trimmed) return null;
  return findModelByIdentifier(provider.models, trimmed) ?? null;
}

function resolveHistoricalModel(
  provider: Provider,
  requestedModelId: string | null | undefined,
): AIModel | null {
  const trimmed = requestedModelId?.trim();
  if (!trimmed || provider.kind === 'relay') return null;

  const resolved = resolveCatalogModel(trimmed, provider.kind);
  if (!resolved) return null;

  return buildCatalogModel({
    providerKind: provider.kind,
    runtimeModelId: resolved.canonicalModelId,
    fallbackName: resolved.displayName ?? trimmed,
    fallbackContextLength: resolved.contextLength,
  });
}
