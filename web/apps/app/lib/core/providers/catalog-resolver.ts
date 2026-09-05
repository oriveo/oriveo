/**
 * Provider model catalog resolution (pure functions).
 *
 * Merges backend metadata with the local Provider state and produces a single
 * ResolvedProviderCatalog for the UI.
 */

import type {
  AIModel,
  Provider,
  ProviderKind,
} from '@oriveo/shared';
type CapabilityEvidenceCandidateView = NonNullable<AIModel['capabilityEvidenceCandidates']>[number];
import { compareCatalogModels, compactContextText, resolveModelPricePresentation } from './catalog-model';
import type { RelayTransportKey } from '../metadata/metadata-client';
import type { CapabilityControl } from '@oriveo/core/providers/request-preference/capability-runtime';
import { getRelayRuntimeConfig } from '../metadata/metadata-client';
import { enrichRelayCatalog } from './relay-official-catalog-match';
import {
  createCatalogFilterContext,
  shouldHideModelForTransport,
} from './transport/catalog-filter';

/* -- Metadata input types ------------------------------- */

export interface CatalogModelMetadata {
  canonicalModelId?: string;
  aliases?: string[];
  displayName?: string;
  contextLength?: number;
  billingSku?: string;
  pricingUnit?: string;
  sourceSummary?: {
    sourceKind: string;
    sourceName: string;
    fetchedAt: string;
  };
  pricing?: {
    promptPerMToken: number | null;
    completionPerMToken: number | null;
    cachedInputPerMToken?: number | null;
    costPerUnit?: number | null;
    costInputBatches?: number | null;
    costOutputBatches?: number | null;
    costInputPriority?: number | null;
    costOutputPriority?: number | null;
    cacheReadInputPerMToken?: number | null;
    cacheCreationInputPerMToken?: number | null;
  };
  pricingStatus?: "priced" | "free" | "unknown";
  capabilities?: string[];
  /** v2 tri-state: null is an authoritative unknown; only a missing v1 field may fall back to the local value. */
  toolCall?: boolean | null;
  /** v2 tri-state: null is an authoritative unknown; only a missing v1 field may fall back to the local value. */
  libraryAgentic?: boolean | null;
  supportsPdfInput?: boolean;
  supportsServiceTier?: boolean;
  profiles?: {
    reasoning?: string | null;
    webSearch?: string | null;
    imageGen?: string | null;
    generation?: {
      template?: string;
      revision?: string;
      parameters?: Array<{ id?: string; support?: string; source?: string }>;
    };
  };
  capabilityControls?: Record<string, CapabilityControl>;
  uiHints?: {
    groupKey?: string;
    groupName?: string;
    rank?: number;
    recommended?: boolean;
    badgeOrder?: string[];
  };
  /** transport kind + minClientVersion, used for client-side filtering. */
  transport?: string;
  minClientVersion?: string;
  capabilityEvidenceCandidates?: CapabilityEvidenceCandidateView[];
  capabilityEvidenceOwnedKeys?: string[];
  capabilityEvidenceViewMalformed?: boolean;
  metadataRevision?: string;
}

export interface CatalogProviderMetadata {
  defaultModelId?: string;
  models: Record<string, CatalogModelMetadata>;
}

export interface CatalogMetadataInput {
  capabilityContractVersion?: number;
  providers: Record<string, CatalogProviderMetadata>;
}

/* -- Output types --------------------------------------- */

export interface ResolvedModel extends AIModel {
  /** Whether the user has enabled this model */
  isEnabled: boolean;
  /** Manual model, i.e. not present in the metadata catalog */
  isManual: boolean;
}

export interface ResolvedProviderCatalog {
  /** Full catalog of available models */
  catalog: ResolvedModel[];
  /** Models the user enabled, enriched */
  enabledModels: ResolvedModel[];
  /** Recommended but not enabled */
  recommendedModels: ResolvedModel[];
  /** The user default model */
  defaultModel: ResolvedModel | null;
  /** Total number of available models in the catalog */
  availableModelCount: number;
  /** Whether any manual model is present */
  hasManualModels: boolean;
}

/* -- Minimal Provider input interface ------------------- */

interface ProviderInput {
  kind: ProviderKind;
  models: AIModel[];
  catalogModels: AIModel[];
  authMode?: Provider['authMode'];
  relayResolvedTransport?: Provider['relayResolvedTransport'];
}

/* -- Main entry ----------------------------------------- */

/**
 * Resolves the full model catalog for a Provider.
 *
 * Official Providers take metadata as the authority, while Relay and subscription links use the
 * catalog each of them just fetched. Enabled models that are absent from the catalog are isManual.
 */
export function resolveProviderCatalog(
  provider: ProviderInput,
  metadata: CatalogMetadataInput | null,
): ResolvedProviderCatalog {
  // A subscription instance takes its catalog truth from the link it just fetched, and that does not
  // overlap the official metadata at all: the Codex backend serves the gpt-5.x family and the Grok
  // CLI proxy only knows grok-4.6/4.5, while the official catalog is the gpt-4o/o3 and grok-4.3 set.
  // Building the catalog from official metadata would list models that do not exist on this link,
  // and every one the user adds would fail on its first message with a confusing error.
  const usesSubscriptionCatalog = provider.authMode === 'subscription';
  const providerMeta = provider.kind === 'relay' || usesSubscriptionCatalog
    ? null
    : metadata?.providers[provider.kind] ?? null;

  // Relay: official enrichment on top of the local catalogModels (on a hit, merge the official
  //   display and capability data plus the transport intersection)
  // Subscription: the freshly fetched catalog is the whole set and every entry is enabled, so there
  //   is no "available but not enabled" layer
  // Official Provider: metadata is the authority
  const rawCatalog = usesSubscriptionCatalog
    ? provider.models
    : provider.kind === 'relay'
      ? enrichRelayCatalog(
        provider.catalogModels,
        provider.relayResolvedTransport === 'llamacpp_native'
          ? undefined
          : provider.relayResolvedTransport,
        getRelayRuntimeConfig(),
      )
      : buildCatalogFromMetadata(
        providerMeta,
        metadata?.capabilityContractVersion,
      );

  // Reverse map from alias to metadata model ID, used to match older ids the user may have enabled
  const aliasToMetaId = buildAliasMap(providerMeta);

  // Decide whether an enabled model can be matched in the catalog
  const matchedEnabledIds = new Set<string>();
  // metadata model ID -> the model ID the user enabled
  const enabledByMetaId = new Map<string, string>();

  for (const userModel of provider.models) {
    const metaId = findMetadataMatch(userModel.id, rawCatalog, aliasToMetaId);
    if (metaId) {
      matchedEnabledIds.add(userModel.id);
      enabledByMetaId.set(metaId, userModel.id);
    }
  }

  // Build the catalog model list
  const catalog: ResolvedModel[] = [];

  for (const catalogModel of rawCatalog) {
    const matchedUserId = enabledByMetaId.get(catalogModel.id);
    const isEnabled = matchedUserId !== undefined;
    const storedModel = isEnabled
      ? provider.models.find((model) => model.id === matchedUserId)
      : undefined;
    const capabilityVerdicts = mergeCapabilityVerdicts(
      catalogModel,
      storedModel,
      metadata?.capabilityContractVersion,
    );

    catalog.push({
      ...catalogModel,
      ...capabilityVerdicts,
      // If the user enabled an older id, keep their id for compatibility
      id: isEnabled ? matchedUserId : catalogModel.id,
      isEnabled,
      isManual: false,
    });
  }

  // Manual models: enabled by the user but absent from the catalog
  for (const userModel of provider.models) {
    if (!matchedEnabledIds.has(userModel.id)) {
      catalog.push({
        ...userModel,
        isEnabled: true,
        isManual: true,
      });
    }
  }

  const enabledModels = catalog.filter((m) => m.isEnabled);
  const recommendedModels = catalog
    .filter((m) => m.isRecommended && !m.isEnabled)
    .sort(compareCatalogModels)
    .slice(0, 6);
  const hasManualModels = catalog.some((m) => m.isManual);

  const defaultModel = resolveDefaultModel(
    provider,
    enabledModels,
    providerMeta,
  );

  return {
    catalog,
    enabledModels,
    recommendedModels,
    defaultModel,
    availableModelCount: catalog.length,
    hasManualModels,
  };
}

/* -- Default model resolution --------------------------- */

/**
 * Resolves the default model:
 * 1. the isDefault the user set, if it is still in the enabled list
 * 2. the metadata defaultModelId, if it is in the enabled list
 * 3. the first enabled model
 */
export function resolveDefaultModel(
  provider: ProviderInput,
  enabledModels: ResolvedModel[],
  providerMeta: CatalogProviderMetadata | null,
): ResolvedModel | null {
  if (enabledModels.length === 0) return null;

  // 1. The isDefault the user set
  const userDefault = provider.models.find((m) => m.isDefault);
  if (userDefault) {
    const found = enabledModels.find((m) => m.id === userDefault.id);
    if (found) return found;
  }

  // 2. The metadata defaultModelId
  if (providerMeta?.defaultModelId) {
    const found = enabledModels.find(
      (m) => m.id === providerMeta.defaultModelId
        || m.canonicalModelId === providerMeta.defaultModelId,
    );
    if (found) return found;
  }

  // 3. The first enabled model
  return enabledModels[0];
}

/* -- Internal helpers ----------------------------------- */

const VALID_CAPABILITIES = new Set([
  'reasoning', 'text', 'image', 'video', 'file', 'web', 'imageGeneration',
]);

/** Builds the AIModel catalog from metadata */
function buildCatalogFromMetadata(
  providerMeta: CatalogProviderMetadata | null,
  capabilityContractVersion?: number,
): AIModel[] {
  if (!providerMeta) return [];

  const filterCtx = createCatalogFilterContext();
  const models: AIModel[] = [];
  for (const [modelId, meta] of Object.entries(providerMeta.models)) {
    // An unrecognised transport or an unmet minClientVersion hides the model
    if (
      shouldHideModelForTransport(
        { id: modelId, transport: meta.transport, minClientVersion: meta.minClientVersion },
        filterCtx,
      )
    ) {
      continue;
    }
    models.push(metadataToAIModel(
      modelId,
      meta,
      providerMeta,
      capabilityContractVersion,
    ));
  }
  return models;
}

/** Converts a single metadata entry into an AIModel */
function metadataToAIModel(
  modelId: string,
  meta: CatalogModelMetadata,
  providerMeta: CatalogProviderMetadata,
  capabilityContractVersion?: number,
): AIModel {
  const capabilities = (meta.capabilities ?? ['text'])
    .filter((cap): cap is AIModel['capabilities'][number] =>
      VALID_CAPABILITIES.has(cap));

  const promptPerToken = meta.pricing?.promptPerMToken == null
    ? undefined
    : meta.pricing.promptPerMToken / 1_000_000;
  const completionPerToken = meta.pricing?.completionPerMToken == null
    ? undefined
    : meta.pricing.completionPerMToken / 1_000_000;
  const pricePresentation = resolveModelPricePresentation({
    pricingStatus: meta.pricingStatus ?? (
      promptPerToken != null && completionPerToken != null
        ? (promptPerToken > 0 || completionPerToken > 0 ? 'priced' : 'free')
        : 'unknown'
    ),
    pricingUnit: meta.pricingUnit,
    pricing: meta.pricing
      ? {
          promptPerToken: promptPerToken ?? null,
          completionPerToken: completionPerToken ?? null,
          cachedInputPerMToken: meta.pricing?.cachedInputPerMToken,
          costPerUnit: meta.pricing?.costPerUnit,
          costInputBatches: meta.pricing?.costInputBatches,
          costOutputBatches: meta.pricing?.costOutputBatches,
          costInputPriority: meta.pricing?.costInputPriority,
          costOutputPriority: meta.pricing?.costOutputPriority,
          cacheReadInputPerMToken: meta.pricing?.cacheReadInputPerMToken,
          cacheCreationInputPerMToken: meta.pricing?.cacheCreationInputPerMToken,
        }
      : null,
  });

  const reasoning = normalizeNullable(meta.profiles?.reasoning);
  const webSearch = normalizeNullable(meta.profiles?.webSearch);
  const imageGen = normalizeNullable(meta.profiles?.imageGen);
  const generation = meta.profiles?.generation ?? undefined;

  return {
    id: modelId,
    canonicalModelId: meta.canonicalModelId,
    name: meta.displayName ?? modelId,
    capabilities,
    // A v2 catalog hit must keep null explicitly, and a missing key fails safe to null as well, so a
    // later merge cannot fall back to a stale local verdict. v1 keeps its original semantics.
    ...(typeof capabilityContractVersion === 'number' && capabilityContractVersion >= 2
      ? {
          toolCall: typeof meta.toolCall === "boolean" ? meta.toolCall : null,
          libraryAgentic:
            typeof meta.libraryAgentic === "boolean"
              ? meta.libraryAgentic
              : null,
        }
      : {
          ...(typeof meta.toolCall === "boolean" ? { toolCall: meta.toolCall } : {}),
          ...(typeof meta.libraryAgentic === "boolean"
            ? { libraryAgentic: meta.libraryAgentic }
            : {}),
        }),
    reasoningModeAvailable: Boolean(reasoning),
    isAvailable: true,
    isDefault: providerMeta.defaultModelId === modelId,
    isRecommended: meta.uiHints?.recommended ?? false,
    priceTier: pricePresentation.priceTier,
    summary: compactContextText(meta.contextLength),
    groupKey: meta.uiHints?.groupKey,
    groupName: meta.uiHints?.groupName,
    sortRank: meta.uiHints?.rank,
    badgeOrder: meta.uiHints?.badgeOrder?.filter(
      (cap): cap is AIModel['capabilities'][number] =>
        VALID_CAPABILITIES.has(cap) && cap !== 'text',
    ),
    promptPrice: pricePresentation.promptPrice,
    completionPrice: pricePresentation.completionPrice,
    contextLength: meta.contextLength,
    reasoningProfile: reasoning,
    webSearchProfile: webSearch,
    imageGenProfile: imageGen,
    generationProfile: generation,
    capabilityControls: meta.capabilityControls,
    capabilityEvidenceCandidates: meta.capabilityEvidenceCandidates,
    capabilityEvidenceOwnedKeys: meta.capabilityEvidenceOwnedKeys,
    capabilityEvidenceViewMalformed: meta.capabilityEvidenceViewMalformed,
    metadataRevision: meta.metadataRevision,
    transport: meta.transport,
    minClientVersion: meta.minClientVersion,
  };
}

function mergeCapabilityVerdicts(
  catalogModel: AIModel,
  storedModel: AIModel | undefined,
  capabilityContractVersion?: number,
): Pick<AIModel, 'toolCall' | 'libraryAgentic'> {
  if (typeof capabilityContractVersion === 'number' && capabilityContractVersion >= 2) {
    return {
      toolCall:
        typeof catalogModel.toolCall === 'boolean'
          ? catalogModel.toolCall
          : null,
      libraryAgentic:
        typeof catalogModel.libraryAgentic === 'boolean'
          ? catalogModel.libraryAgentic
          : null,
    };
  }

  return {
    toolCall:
      typeof catalogModel.toolCall === 'boolean'
        ? catalogModel.toolCall
        : storedModel?.toolCall,
    libraryAgentic:
      typeof catalogModel.libraryAgentic === 'boolean'
        ? catalogModel.libraryAgentic
        : storedModel?.libraryAgentic,
  };
}

/** Builds the reverse alias to metadata model ID map */
function buildAliasMap(
  providerMeta: CatalogProviderMetadata | null,
): Map<string, string> {
  const map = new Map<string, string>();
  if (!providerMeta) return map;

  for (const [modelId, meta] of Object.entries(providerMeta.models)) {
    // canonicalModelId doubles as an alias
    if (meta.canonicalModelId && meta.canonicalModelId !== modelId) {
      map.set(meta.canonicalModelId, modelId);
    }
    for (const alias of meta.aliases ?? []) {
      map.set(alias, modelId);
    }
  }
  return map;
}

/**
 * Finds the catalog entry matching a model the user enabled.
 * Match order: direct ID, then canonicalModelId, then alias.
 */
function findMetadataMatch(
  userModelId: string,
  catalog: AIModel[],
  aliasToMetaId: Map<string, string>,
): string | null {
  // Direct ID match
  const directMatch = catalog.find((m) => m.id === userModelId);
  if (directMatch) return directMatch.id;

  // canonicalModelId match: the enabled id is the canonicalModelId of some catalog model
  const canonicalMatch = catalog.find(
    (m) => m.canonicalModelId === userModelId,
  );
  if (canonicalMatch) return canonicalMatch.id;

  // alias match: the enabled id is an alias of some catalog model
  const aliasMatch = aliasToMetaId.get(userModelId);
  if (aliasMatch && catalog.some((m) => m.id === aliasMatch)) {
    return aliasMatch;
  }

  return null;
}

function normalizeNullable(value: string | null | undefined): string | undefined {
  return typeof value === 'string' && value.trim() ? value : undefined;
}
