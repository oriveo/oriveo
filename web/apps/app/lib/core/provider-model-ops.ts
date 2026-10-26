import type { StoreApi } from 'zustand';
import type { AIModel, ModelCapability, Provider } from '@oriveo/shared';
import type { AppStore } from './store/app-store';
import { sameNormalizedID } from '../utils/id-utils';
import { selectResolvedCatalog } from './store/selectors';
import { findModelByIdentifier } from './providers/model-display-lookup';
import { deduplicateRelayModels, findRelayModel, relayModelKey } from './providers/relay-model-identity';
import { enrichRelayCatalog } from './providers/relay-official-catalog-match';
import { resolveRelaySelectionTransport } from './providers/provider-selection-snapshot';
import { cachedModelFamilyByModel, getRelayRuntimeConfig } from './metadata/metadata-client';
import { inferModelFamily } from '@oriveo/shared';
import { bindRelayKey, relayKeyIDs } from '@oriveo/shared/relay/relay-keys';
import { getActiveUIDSync } from '../infra/storage/partition';
import { clearToolCallMemoryForModels } from './chat/capability-recovery-runtime';
import { toolCallMemoryModelId } from './chat/tool-call-verdict';

/**
 * Default capability ceiling for a manually entered model: general chat.
 * `imageGeneration` is excluded because image generation is a dedicated mode for a handful of
 * specific models (gpt-image-*, dall-e-* and so on) and makes a poor default for a manual entry;
 * image models that match the backend catalog have it injected by the enrichment path.
 *
 * The actual entry point is narrowed further by the model capabilities and the transport/runtime route.
 */
export const DEFAULT_MANUAL_MODEL_CAPABILITIES: ModelCapability[] = ['text'];

function uniqueModels(models: AIModel[]): AIModel[] {
  const seen = new Set<string>();
  return models.filter((model) => {
    if (seen.has(model.id)) return false;
    seen.add(model.id);
    return true;
  });
}

/**
 * Runs one catalog enrichment pass over a Relay provider's models and writes the result back.
 * Triggered on every `patchProviderModels` write.
 *
 * Why enrich on write: enriching at write time merges the persisted fields (priceTier, promptPrice,
 * completionPrice, canonicalModelId and so on) back into the model. Enriching lazily on read paths
 * only, such as chat selection and catalog views, left the ModelSwitcher main view reading
 * `provider.models` directly and showing the un-enriched placeholder state, for instance
 * priceTier='?' instead of the real tier for a manually entered model.
 *
 * When metadata has not loaded, `enrichRelayCatalog` runs with the default runtimeConfig and returns
 * unmatched models unchanged, so it is a safe no-op. Once loading finishes, bootstrap runs another
 * enrichment pass and writes it back (`hydrateMetadataAndReconcileProviders`).
 */
export function enrichRelayProviderModels(provider: Provider, models: AIModel[]): AIModel[] {
  if (provider.kind !== 'relay') return models;
  const runtimeConfig = getRelayRuntimeConfig();
  // Enrich each model per its own protocol (protocol is an attribute of the model).
  return models.flatMap((model) => enrichRelayCatalog([model], resolveRelaySelectionTransport(provider, model), runtimeConfig));
}

/**
 * Runs enrichment over a whole Relay provider's `models` and `catalogModels` and writes it back.
 * Used on the provider creation path (`addProvider`): `patchProviderModels` only covers model-level
 * writes, and creating a provider writes to the store through addProvider without going through it.
 *
 * Non-Relay providers are returned unchanged.
 */
export function enrichRelayProvider(provider: Provider): Provider {
  if (provider.kind !== 'relay') return provider;
  return {
    ...provider,
    models: enrichRelayProviderModels(provider, provider.models),
    catalogModels: enrichRelayProviderModels(provider, provider.catalogModels),
  };
}

/** Model family for binding: the cached Server by-model vendor family -> existing heuristics; taken synchronously, no request sent. */
export function relayBindingFamily(modelID: string): string | null {
  return cachedModelFamilyByModel(modelID) ?? inferModelFamily(modelID);
}

/**
 * Pick a key for models newly entering the enabled list by bindCases; a connection with only one key is returned as is and nothing is written.
 * Those that already carry a valid relayKeyID (e.g. undoing a removal) keep their original binding.
 */
export function withRelayKeyBindings(provider: Provider, models: AIModel[]): AIModel[] {
  if (provider.kind !== 'relay') return models;
  const keys = relayKeyIDs(provider);
  if (keys.length < 2) return models;
  const previous = new Set(provider.models.map((model) => relayModelKey(model.id)));
  const enabled: AIModel[] = [...provider.models];
  return models.map((model) => {
    if (previous.has(relayModelKey(model.id))) return model;
    let next = model;
    if (!model.relayKeyID || !keys.includes(model.relayKeyID)) {
      const keyID = bindRelayKey({
        keys,
        catalog: provider.catalogModels,
        enabled,
        targetModelID: model.id,
        family: relayBindingFamily,
      });
      if (keyID) next = { ...model, relayKeyID: keyID };
    }
    enabled.push(next);
    return next;
  });
}

function patchProviderModels(
  store: StoreApi<AppStore>,
  provider: Provider,
  models: AIModel[],
) {
  // Only a model whose manually entered tool_call declaration changed invalidates its rejection memory; enabling / disabling / renaming does not clear it.
  const edited = models.filter((model) => {
    const previous = provider.models.find((item) => item.id === model.id);
    return previous !== undefined && previous.toolCall !== model.toolCall;
  });
  clearToolCallMemoryForModels(
    getActiveUIDSync(),
    provider.id,
    edited.map((model) => toolCallMemoryModelId(provider, model)),
  );
  const enriched = enrichRelayProviderModels(provider, withRelayKeyBindings(provider, models));
  store.getState().updateProvider(provider.id, {
    models: provider.kind === 'relay' ? deduplicateRelayModels(enriched) : uniqueModels(enriched),
    status: { kind: 'connected' },
    updatedAt: new Date().toISOString(),
  });
}

function resolveProvider(store: StoreApi<AppStore>, provider: Provider): Provider {
  return store.getState().providers.find((item) => sameNormalizedID(item.id, provider.id)) ?? provider;
}

export function createManualModel(modelId: string, isDefault = false): AIModel {
  const trimmed = modelId.trim();
  const [groupName, ...rest] = trimmed.split('/');
  const hasGroup = rest.length > 0;

  return {
    id: trimmed,
    name: hasGroup ? rest.join('/') : trimmed,
    capabilities: ['text'],
    reasoningModeAvailable: false,
    isAvailable: true,
    isDefault,
    // Empty-string placeholder. When the model matches the backend catalog, the enrichment path
    // overwrites it with the real tier; when it does not, keeping '' makes the UI showPriceTier
    // check false so no pill is rendered.
    priceTier: '',
    groupKey: hasGroup ? groupName : undefined,
    groupName: hasGroup ? groupName : undefined,
    isManual: true,
  };
}

/** Hand-typed relay models: relay has no default model, so none is ever marked default. */
export function createRelayManualModel(modelId: string): AIModel {
  const model = createManualModel(modelId, false);
  const capabilities = [...DEFAULT_MANUAL_MODEL_CAPABILITIES];
  return {
    ...model,
    capabilities,
    reasoningModeAvailable: capabilities.includes('reasoning'),
    imageGenProfile: capabilities.includes('imageGeneration') ? 'default' : undefined,
  };
}

export function enableProviderModel(
  store: StoreApi<AppStore>,
  provider: Provider,
  model: AIModel,
): AIModel {
  const latestProvider = resolveProvider(store, provider);
  const existing = latestProvider.kind === 'relay'
    ? findRelayModel(latestProvider.models, model.id)
    : latestProvider.models.find((item) => item.id === model.id);
  if (existing) return existing;

  patchProviderModels(store, latestProvider, [...latestProvider.models, model]);
  return model;
}

/**
 * Append several models at once to a relay / local connection (group "add all", CATALOG-19): only append those not yet enabled, write the connection back only once,
 * zero probes (does not go through enableProviderModelWithProbe); key ownership uses the same binding rule as enabling a single model. Returns the number added.
 */
export function enableProviderModels(
  store: StoreApi<AppStore>,
  provider: Provider,
  models: readonly AIModel[],
): number {
  const latestProvider = resolveProvider(store, provider);
  // Relay matches by literal key; official providers keep exact IDs.
  const identity = (id: string) => latestProvider.kind === 'relay' ? relayModelKey(id) : id;
  const existing = new Set(latestProvider.models.map((model) => identity(model.id)));
  const added = models.filter((model) => {
    if (existing.has(identity(model.id))) return false;
    existing.add(identity(model.id));
    return true;
  });
  if (added.length === 0) return 0;
  patchProviderModels(store, latestProvider, [...latestProvider.models, ...added]);
  return added.length;
}

/**
 * Disable a model. A relay / local connection keeps at least one model: when only one is left, refuse, write nothing and return false.
 */
export function disableProviderModel(
  store: StoreApi<AppStore>,
  provider: Provider,
  modelId: string,
): boolean {
  const latestProvider = resolveProvider(store, provider);
  const remaining = latestProvider.kind === 'relay'
    ? latestProvider.models.filter((model) => relayModelKey(model.id) !== relayModelKey(modelId))
    : latestProvider.models.filter((model) => model.id !== modelId);
  if (latestProvider.kind === 'relay' && remaining.length === 0 && latestProvider.models.length > 0) return false;
  patchProviderModels(store, latestProvider, remaining);
  return true;
}

export function replaceProviderModels(
  store: StoreApi<AppStore>,
  provider: Provider,
  models: AIModel[],
) {
  patchProviderModels(store, resolveProvider(store, provider), models);
}

export function addManualProviderModels(
  store: StoreApi<AppStore>,
  provider: Provider,
  modelIds: string[],
): AIModel[] {
  const latestProvider = resolveProvider(store, provider);
  const isRelay = latestProvider.kind === 'relay';
  const identity = (id: string) => isRelay ? relayModelKey(id) : id;
  const existingIds = new Set(latestProvider.models.map((model) => identity(model.id)));
  const trimmedIds = [...new Set(modelIds.map((id) => id.trim()).filter(Boolean))];
  const newModels = trimmedIds
    .filter((id) => {
      if (existingIds.has(identity(id))) return false;
      existingIds.add(identity(id));
      return true;
    })
    .map((id, index) => latestProvider.kind === 'relay'
      ? createRelayManualModel(id)
      : createManualModel(id, latestProvider.models.length === 0 && index === 0));

  if (newModels.length === 0) {
    return [];
  }

  patchProviderModels(store, latestProvider, [...latestProvider.models, ...newModels]);
  return newModels;
}

export function findModelInProvider(
  provider: Provider | undefined,
  modelId: string | null | undefined,
): AIModel | undefined {
  if (!provider || !modelId) return undefined;
  // Relay is purely literal: a dated snapshot and its base are two models, with no canonical / date-stripping fallback.
  if (provider.kind === 'relay') {
    return findRelayModel(provider.models, modelId) ?? findRelayModel(provider.catalogModels, modelId);
  }

  return findModelByIdentifier(provider.models, modelId)
    ?? findModelByIdentifier(provider.catalogModels, modelId);
}

/** Whether a Provider still has catalog models available to add */
export function providerHasCatalogModels(provider: Provider): boolean {
  if (provider.kind === 'relay') return false;
  const resolved = selectResolvedCatalog(provider);
  return resolved.catalog.some((m) => !m.isEnabled);
}
