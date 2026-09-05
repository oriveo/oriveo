/**
 * Enrich a Relay's local models against the official catalogs.
 *
 * Every model in a Relay provider's catalogModels is matched across the official providers,
 * and a hit merges in the official displayName / canonical / capabilities / profiles / uiHints.
 * Official capabilities are first intersected with the current transport envelope; locally
 * configured capabilities stay as the user's per-model ceiling. Attachment, web search and
 * image generation entry points are still gated by their own runtime checks.
 *
 * Models with no match keep their local Relay semantics; official capabilities are never invented.
 */
import type { AIModel, ModelCapability } from '@oriveo/shared';
import type {
  RelayRuntimeConfig,
  RelayTransportEnvelope,
  RelayTransportKey,
  ResolvedModelMetadata,
} from '../metadata/metadata-client';
import {
  DEFAULT_RELAY_RUNTIME_CONFIG,
  resolveCatalogModelAcrossProvidersWithProvider,
} from '../metadata/metadata-client';
import { transportProviderPriority } from './relay-runtime-support';
import { resolveModelPricePresentation } from './catalog-model';

export interface RelayEnrichedModel extends AIModel {
  /** Which official match produced this model. Undefined when nothing matched. */
  relayMatchSource?: 'transport_first' | 'cross_provider';
  /** providerKind of the official match. Undefined when nothing matched. */
  relayMatchedProviderKind?: string;
}

function pickEnvelope(
  transport: RelayTransportKey | undefined,
  runtimeConfig: RelayRuntimeConfig,
): RelayTransportEnvelope | null {
  if (!transport) return null;
  return (
    runtimeConfig.transportEnvelopes[transport]
    ?? DEFAULT_RELAY_RUNTIME_CONFIG.transportEnvelopes[transport]
    ?? null
  );
}

function envelopeAllows(
  envelope: RelayTransportEnvelope | null,
  capability: string,
): boolean {
  if (!envelope) return true;
  switch (capability) {
    case 'image':
      return envelope.image;
    case 'video':
      return false;
    case 'file':
      return envelope.nativeFile || envelope.textFileInline;
    case 'web':
      return envelope.webSearch;
    case 'imageGeneration':
      return envelope.imageGeneration;
    case 'reasoning':
      return envelope.reasoning;
    case 'text':
    default:
      return true;
  }
}

function intersectCapabilities(
  capabilities: string[],
  envelope: RelayTransportEnvelope | null,
): string[] {
  if (!envelope) return capabilities;
  return capabilities.filter((cap) => envelopeAllows(envelope, cap));
}

function mergeCapabilities(
  base: string[],
  add: string[],
): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const cap of base) {
    if (!seen.has(cap)) {
      seen.add(cap);
      out.push(cap);
    }
  }
  for (const cap of add) {
    if (!seen.has(cap)) {
      seen.add(cap);
      out.push(cap);
    }
  }
  return out;
}

function normalizeProfile(
  value: string | undefined | null,
): string | undefined {
  return typeof value === 'string' && value.trim() ? value : undefined;
}

/**
 * Recover the real model ID. Manually added models can carry a `relay-manual-` prefix used as a
 * namespace by older clients; the current form is a bare ID plus the `model.isManual` field. The
 * prefix strip stays as a compatibility fallback for legacy synced data and test fixtures.
 */
function resolvedRelayModelId(modelId: string): string {
  const trimmed = modelId.trim();
  return trimmed.startsWith('relay-manual-')
    ? trimmed.slice('relay-manual-'.length)
    : trimmed;
}

/**
 * Merge an official match into a local model, constrained by the transport envelope.
 *
 * Merge rules:
 * - displayName / canonical / uiHints: the official values win.
 * - capabilities: (official capabilities intersected with the transport envelope) unioned with
 *   localModel.capabilities, falling back to at least 'text'. Local manual capabilities are the
 *   user's explicit configuration of a runtime model and must not be swallowed by a catalog hit.
 * - profiles: kept only when both finalCapabilities and the envelope allow them. Once the catalog
 *   matches, the official values are authoritative, so an absent official profile is an
 *   authoritative withdrawal that clears the local one rather than falling back to it. generation
 *   has no matching capability or envelope switch, so it is only withdrawn, never narrowed.
 * - Pricing display follows the official metadata; local Relay models usually carry no pricing.
 */
function applyOfficialMatch(
  localModel: AIModel,
  match: ResolvedModelMetadata & { matchedProviderKind: string; source: 'transport_first' | 'cross_provider' },
  envelope: RelayTransportEnvelope | null,
): RelayEnrichedModel {
  const officialCapabilities: string[] = match.capabilities.length > 0
    ? match.capabilities
    : ['text'];
  const intersectedOfficialCapabilities = intersectCapabilities(officialCapabilities, envelope);
  const finalCapabilities = mergeCapabilities(intersectedOfficialCapabilities, localModel.capabilities ?? []);
  const safeCapabilities: string[] = finalCapabilities.length > 0
    ? finalCapabilities
    : ['text'];

  const reasoning = normalizeProfile(match.profiles.reasoning);
  const webSearch = normalizeProfile(match.profiles.webSearch);
  const imageGen = normalizeProfile(match.profiles.imageGen);

  const pricePresentation = resolveModelPricePresentation(match);

  return {
    ...localModel,
    canonicalModelId: match.canonicalModelId,
    name: match.displayName ?? localModel.name,
    capabilities: safeCapabilities,
    reasoningModeAvailable: safeCapabilities.includes('reasoning') && Boolean(reasoning),
    isRecommended: match.uiHints?.recommended ?? localModel.isRecommended,
    groupKey: match.uiHints?.groupKey ?? localModel.groupKey,
    groupName: match.uiHints?.groupName ?? localModel.groupName,
    sortRank: match.uiHints?.rank ?? localModel.sortRank,
    badgeOrder: match.uiHints?.badgeOrder?.filter(
      (cap) => safeCapabilities.includes(cap) && cap !== 'text',
    ) ?? localModel.badgeOrder,
    priceTier: pricePresentation.priceTier || localModel.priceTier,
    promptPrice: pricePresentation.promptPrice ?? localModel.promptPrice,
    completionPrice: pricePresentation.completionPrice ?? localModel.completionPrice,
    contextLength: match.contextLength ?? localModel.contextLength,
    reasoningProfile: safeCapabilities.includes('reasoning') ? reasoning : undefined,
    webSearchProfile: safeCapabilities.includes('web') ? webSearch : undefined,
    imageGenProfile: safeCapabilities.includes('imageGeneration') ? imageGen : undefined,
    // Authoritative withdrawal, the same rule as the three profiles above: reaching this point means
    // the official catalog matched (a miss returns early in `enrichRelayLocalModel`), so an absent
    // `profiles.generation` means the backend withdrew that model's generation profile. The local value
    // must be cleared rather than kept with `??`, otherwise the expert-parameter UI and the outbound
    // request would keep using a withdrawn profile. generation has no matching capability or envelope
    // switch (`RelayTransportEnvelope` has no such dimension), so no capability narrowing is applied.
    generationProfile: match.profiles.generation,
    relayMatchSource: match.source,
    relayMatchedProviderKind: match.matchedProviderKind,
  };
}

function applyManualOfficialPricing(
  localModel: AIModel,
  match: ResolvedModelMetadata & { matchedProviderKind: string; source: 'transport_first' | 'cross_provider' },
): RelayEnrichedModel {
  const pricePresentation = resolveModelPricePresentation(match);
  return {
    ...localModel,
    canonicalModelId: match.canonicalModelId,
    priceTier: pricePresentation.priceTier || localModel.priceTier,
    promptPrice: pricePresentation.promptPrice ?? localModel.promptPrice,
    completionPrice: pricePresentation.completionPrice ?? localModel.completionPrice,
    relayMatchSource: match.source,
    relayMatchedProviderKind: match.matchedProviderKind,
  };
}

/**
 * Apply official catalog enrichment to a single Relay local model.
 * No match returns the model unchanged; a match merges the official display data, capabilities and
 * profiles, intersected with the transport envelope.
 */
export function enrichRelayLocalModel(
  localModel: AIModel,
  transport: RelayTransportKey | undefined,
  runtimeConfig: RelayRuntimeConfig,
): RelayEnrichedModel {
  // Prefer the `model.isManual` field as the single source of truth.
  // Compatibility fallback: older synced data may still encode the manual flag as a `relay-manual-` prefix.
  // This branch goes through `applyManualOfficialPricing`, which merges only the official pricing and keeps the user's displayName and capabilities.
  const isRelayManualModel = localModel.isManual === true
    || localModel.id.trim().startsWith('relay-manual-');
  const matchResult = resolveCatalogModelAcrossProvidersWithProvider(resolvedRelayModelId(localModel.id), {
    transportPriority: transportProviderPriority(transport, runtimeConfig),
  });
  if (!matchResult) {
    return { ...localModel };
  }
  if (isRelayManualModel) {
    return applyManualOfficialPricing(
      localModel,
      {
        ...matchResult.metadata,
        matchedProviderKind: matchResult.matchedProviderKind,
        source: matchResult.source,
      },
    );
  }
  const envelope = pickEnvelope(transport, runtimeConfig);
  return applyOfficialMatch(
    localModel,
    {
      ...matchResult.metadata,
      matchedProviderKind: matchResult.matchedProviderKind,
      source: matchResult.source,
    },
    envelope,
  );
}

/**
 * Apply official enrichment to a whole Relay catalog. Order is preserved and unmatched models pass through unchanged.
 */
export function enrichRelayCatalog(
  localModels: AIModel[],
  transport: RelayTransportKey | undefined,
  runtimeConfig: RelayRuntimeConfig,
): RelayEnrichedModel[] {
  return localModels.map((model) => enrichRelayLocalModel(model, transport, runtimeConfig));
}
