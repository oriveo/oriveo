import type { AIModel, ProviderKind } from '@oriveo/shared';
import { formatModelPriceTier } from '../../utils/format-utils';
import { resolveCatalogModel, type ResolvedModelMetadata } from '../metadata/metadata-client';

export const PRICE_TIER_UNKNOWN_LABEL = 'Price unknown';
export const PRICE_TIER_NON_STANDARD_BILLING_LABEL = 'Non-standard billing';

interface BuildCatalogModelOptions {
  providerKind: ProviderKind | string;
  runtimeModelId: string;
  fallbackName: string;
  fallbackContextLength?: number;
  fallbackSummary?: string;
  createdAt?: number;
}

export function buildCatalogModel({
  providerKind,
  runtimeModelId,
  fallbackName,
  fallbackContextLength,
  fallbackSummary,
  createdAt,
}: BuildCatalogModelOptions): AIModel {
  const resolved = resolveCatalogDecorations(runtimeModelId, providerKind);
  const capabilities = resolved.metadata?.capabilities ?? ['text'];
  const pricePresentation = resolveModelPricePresentation(resolved.metadata);
  const contextLength = resolved.metadata?.contextLength ?? fallbackContextLength;

  return {
    id: runtimeModelId,
    canonicalModelId: resolved.metadata?.canonicalModelId,
    name: resolved.metadata?.displayName ?? fallbackName,
    capabilities,
    reasoningModeAvailable: Boolean(resolved.metadata?.profiles.reasoning),
    isAvailable: true,
    isDefault: resolved.metadata?.isDefault ?? false,
    isRecommended: resolved.metadata?.uiHints?.recommended ?? false,
    priceTier: pricePresentation.priceTier,
    summary: fallbackSummary ?? compactContextText(contextLength),
    groupKey: resolved.groupKey,
    groupName: resolved.groupName,
    sortRank: resolved.metadata?.uiHints?.rank,
    badgeOrder: resolved.metadata?.uiHints?.badgeOrder,
    createdAt,
    promptPrice: pricePresentation.promptPrice,
    completionPrice: pricePresentation.completionPrice,
    contextLength,
    maxOutputTokens: resolved.metadata?.maxOutputTokens,
    cacheReadInputPerMToken: normalizePerMillionPrice(resolved.metadata?.pricing?.cacheReadInputPerMToken),
    cacheCreationInputPerMToken: normalizePerMillionPrice(resolved.metadata?.pricing?.cacheCreationInputPerMToken),
    cacheWrite5mPerMToken: normalizePerMillionPrice(resolved.metadata?.pricing?.cacheWrite5mPerMToken),
    cacheWrite1hPerMToken: normalizePerMillionPrice(resolved.metadata?.pricing?.cacheWrite1hPerMToken),
    reasoningProfile: resolved.metadata?.profiles.reasoning,
    webSearchProfile: resolved.metadata?.profiles.webSearch,
    imageGenProfile: resolved.metadata?.profiles.imageGen,
    generationProfile: resolved.metadata?.profiles.generation ?? undefined,
    capabilityControls: resolved.metadata?.capabilityControls,
    capabilityEvidenceCandidates: resolved.metadata?.capabilityEvidenceCandidates,
    capabilityEvidenceOwnedKeys: resolved.metadata?.capabilityEvidenceOwnedKeys,
    capabilityEvidenceViewMalformed: resolved.metadata?.capabilityEvidenceViewMalformed,
    metadataRevision: resolved.metadata?.metadataRevision,
    toolCall: resolved.metadata?.toolCall,
    libraryAgentic: resolved.metadata?.libraryAgentic,
    transport: resolved.metadata?.transport,
    minClientVersion: resolved.metadata?.minClientVersion,
    attachmentExtraction: resolved.metadata?.attachmentExtraction,
  };
}

/**
 * Refresh a stored model against the latest metadata.
 *
 * "The catalog has no such model" and "the catalog has it but the server publishes no profile" are two
 * different situations, so the decision keys off `metadata` itself rather than a single profile field:
 *   - `metadata == null` (catalog miss): manually added models, relay models and models backfilled by
 *     sync all take this branch, and local values must be kept as-is. Overwriting something known with
 *     "not found" is a net loss.
 *   - `metadata != null` (catalog hit): a missing profile is an authoritative withdrawal by the server
 *     and the stored local value must be cleared. Otherwise narrowing the available levels (gpt-5-pro
 *     keeping only high) or withdrawing a profile entirely cannot take effect here, and a `??` or
 *     ternary fallback turns enrich into a ratchet that only ever adds.
 */
export function enrichStoredModel(model: AIModel, providerKind: ProviderKind | string): AIModel {
  const resolved = resolveCatalogDecorations(model.id, providerKind);
  const metadata = resolved.metadata;
  const pricePresentation = resolveModelPricePresentation(metadata);
  const contextLength = metadata?.contextLength ?? model.contextLength;
  const usesCapabilityContractV2 =
    typeof metadata?.capabilityContractVersion === 'number' &&
    metadata.capabilityContractVersion >= 2;

  return {
    ...model,
    canonicalModelId: metadata?.canonicalModelId ?? model.canonicalModelId,
    name: metadata?.displayName ?? model.name,
    capabilities: metadata?.capabilities ?? model.capabilities,
    reasoningModeAvailable: metadata
      ? metadata.profiles.reasoning != null
      : model.reasoningModeAvailable,
    isRecommended: metadata ? Boolean(metadata.uiHints?.recommended) : model.isRecommended,
    priceTier: metadata ? pricePresentation.priceTier : model.priceTier,
    summary: model.summary ?? compactContextText(contextLength),
    groupKey: metadata ? resolved.groupKey : model.groupKey,
    groupName: metadata ? resolved.groupName : model.groupName,
    sortRank: metadata ? metadata.uiHints?.rank : model.sortRank,
    badgeOrder: metadata ? metadata.uiHints?.badgeOrder : model.badgeOrder,
    promptPrice: metadata ? pricePresentation.promptPrice : model.promptPrice,
    completionPrice: metadata ? pricePresentation.completionPrice : model.completionPrice,
    contextLength,
    maxOutputTokens: metadata?.maxOutputTokens ?? model.maxOutputTokens,
    cacheReadInputPerMToken: metadata
      ? normalizePerMillionPrice(metadata.pricing?.cacheReadInputPerMToken)
      : model.cacheReadInputPerMToken,
    cacheCreationInputPerMToken: metadata
      ? normalizePerMillionPrice(metadata.pricing?.cacheCreationInputPerMToken)
      : model.cacheCreationInputPerMToken,
    cacheWrite5mPerMToken: metadata
      ? normalizePerMillionPrice(metadata.pricing?.cacheWrite5mPerMToken)
      : model.cacheWrite5mPerMToken,
    cacheWrite1hPerMToken: metadata
      ? normalizePerMillionPrice(metadata.pricing?.cacheWrite1hPerMToken)
      : model.cacheWrite1hPerMToken,
    // On a catalog hit a missing profile is an authoritative withdrawal, so assign it without a fallback
    reasoningProfile: metadata ? metadata.profiles.reasoning : model.reasoningProfile,
    webSearchProfile: metadata ? metadata.profiles.webSearch : model.webSearchProfile,
    imageGenProfile: metadata ? metadata.profiles.imageGen : model.imageGenProfile,
    // generationProfile follows the same rule as the three above (normalizeProfiles already passes
    // generation through): the server's `profiles.generation` is omitempty, so the field disappears on
    // withdrawal and the stored local value has to be cleared on a catalog hit. Otherwise the expert
    // parameter entry point and outbound injection keep using a profile the backend has removed.
    generationProfile: metadata ? metadata.profiles.generation : model.generationProfile,
    capabilityControls: metadata ? metadata.capabilityControls : model.capabilityControls,
    capabilityEvidenceCandidates: metadata
      ? metadata.capabilityEvidenceCandidates
      : model.capabilityEvidenceCandidates,
    capabilityEvidenceOwnedKeys: metadata
      ? metadata.capabilityEvidenceOwnedKeys
      : model.capabilityEvidenceOwnedKeys,
    capabilityEvidenceViewMalformed: metadata
      ? metadata.capabilityEvidenceViewMalformed
      : model.capabilityEvidenceViewMalformed,
    // Catalog hit but no current ETag must clear a persisted old revision;
    // retaining it could let a stale candidate appear current after refresh.
    metadataRevision: metadata ? metadata.metadataRevision : model.metadataRevision,
    // A v2 catalog hit with null means an authoritative unknown and must overwrite the old value;
    // v1 or a missing version still only updates when a boolean is present, and a catalog miss keeps
    // the local value.
    toolCall: metadata
      ? usesCapabilityContractV2
        ? metadata.toolCall ?? null
        : typeof metadata.toolCall === 'boolean'
          ? metadata.toolCall
          : model.toolCall
      : model.toolCall,
    libraryAgentic: metadata
      ? usesCapabilityContractV2
        ? metadata.libraryAgentic ?? null
        : typeof metadata.libraryAgentic === 'boolean'
          ? metadata.libraryAgentic
          : model.libraryAgentic
      : model.libraryAgentic,
  };
}

export function resolveModelPricePresentation(
  metadata: Pick<ResolvedModelMetadata, 'pricingStatus' | 'pricing' | 'pricingUnit'> | null | undefined,
): {
  priceTier: string;
  promptPrice: number | undefined;
  completionPrice: number | undefined;
} {
  if (!metadata) {
    return { priceTier: '', promptPrice: undefined, completionPrice: undefined };
  }

  const pricingUnit = metadata.pricingUnit ?? 'per_token';
  if (pricingUnit !== 'per_token' && metadata.pricingStatus !== 'unknown') {
    return {
      priceTier: PRICE_TIER_NON_STANDARD_BILLING_LABEL,
      promptPrice: undefined,
      completionPrice: undefined,
    };
  }

  const promptPerToken = normalizeTokenPrice(metadata.pricing?.promptPerToken);
  const completionPerToken = normalizeTokenPrice(metadata.pricing?.completionPerToken);

  switch (metadata.pricingStatus) {
    case 'priced':
      return {
        priceTier: formatModelPriceTier(
          promptPerToken,
          completionPerToken,
        ),
        promptPrice: promptPerToken,
        completionPrice: completionPerToken,
      };
    case 'free':
      return {
        priceTier: 'Free',
        promptPrice: promptPerToken ?? 0,
        completionPrice: completionPerToken ?? 0,
      };
    case 'unknown':
    default:
      return {
        priceTier: PRICE_TIER_UNKNOWN_LABEL,
        promptPrice: undefined,
        completionPrice: undefined,
      };
  }
}

function normalizeTokenPrice(value: number | null | undefined): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined;
}

function normalizePerMillionPrice(value: number | null | undefined): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined;
}

export function buildRecommendedModels(models: AIModel[]): AIModel[] {
  return models
    .filter((model) => model.isAvailable)
    .filter((model) => model.isRecommended)
    .sort(compareCatalogModels)
    .slice(0, 6)
    .map((model) => ({ ...model }));
}

export function compareCatalogModels(left: AIModel, right: AIModel): number {
  const rankDiff = (right.sortRank ?? 0) - (left.sortRank ?? 0);
  if (rankDiff !== 0) return rankDiff;

  const createdDiff = (right.createdAt ?? 0) - (left.createdAt ?? 0);
  if (createdDiff !== 0) return createdDiff;

  return left.name.localeCompare(right.name, undefined, { numeric: true, sensitivity: 'base' });
}

export function compactContextText(ctx?: number): string | undefined {
  if (!ctx || ctx <= 0) return undefined;
  if (ctx >= 1_000_000) return `${Math.floor(ctx / 1_000_000)}M`;
  if (ctx >= 1_000) return `${Math.floor(ctx / 1_000)}K`;
  return `${ctx}`;
}

function resolveCatalogDecorations(
  modelId: string,
  providerKind: ProviderKind | string,
): {
  metadata: ReturnType<typeof resolveCatalogModel>;
  groupKey?: string;
  groupName?: string;
} {
  const metadata = resolveCatalogModel(modelId, providerKind);

  // For an aggregating provider, vendor and group must come from the backend metadata
  // (`vendorKey`/`vendorName` and `uiHints.groupKey`/`groupName`); the client must never infer a vendor
  // from the model id slug (`Qwen/...`, `deepseek-ai/...`).
  return {
    metadata,
    groupKey: metadata?.uiHints?.groupKey,
    groupName: metadata?.uiHints?.groupName,
  };
}

// ── Canonical deduplication ──

const DATE_SUFFIX_RE = /(?:-\d{8}|-\d{4}-\d{2}-\d{2})$/;

/** Canonical key for a model, matching the backend's canonicalModelID(). */
export function canonicalKey(model: AIModel): string {
  return model.canonicalModelId || model.id.replace(DATE_SUFFIX_RE, '');
}

/** Deduplicate by canonical key, keeping the variant without a date suffix. */
export function deduplicateByCanonical(models: AIModel[]): AIModel[] {
  const seen = new Map<string, number>();
  const result: AIModel[] = [];
  for (const model of models) {
    const key = canonicalKey(model);
    const idx = seen.get(key);
    if (idx !== undefined) {
      if (model.id === key) result[idx] = model;
    } else {
      seen.set(key, result.length);
      result.push(model);
    }
  }
  return result;
}
