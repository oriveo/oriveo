/**
 * Relay reasoning tiers (RELAY x reasoning; fixture `test-fixtures/relay/reasoning-tier.v1.json`).
 *
 * - Automatic tiers = the Server model-facts `reasoningEfforts` mapped by effortMap (in fast / balanced / deep / max order, deduplicated,
 *   unknown words ignored). Family: the family matched by the official catalog takes priority, otherwise the cached by-model view; empty if neither is available.
 * - Tier rejection: a tier was sent, 400 / 422 before output, and the error body names a reasoning parameter -> that tier is rejected and recorded in the relay negative cache as `reasoningTier:<tier>` (7 days).
 * - Tier landing: swap a rejected tier for the nearest one (down first, then up; with no tier, send no reasoning); in-send resend and later outbound use the same function.
 */
import type { AIModel, Provider } from '@oriveo/shared';
import { relayFirstSendTransport } from '../providers/relay-first-send-transport';
import { relayErrorBodyNamesReasoning } from '@oriveo/core/providers/relay-reasoning-rejection';
import { cachedModelReasoningEffortsByModel, getModelFacts } from '../metadata/metadata-client';
import { providerFormOf } from '../capability/truth/provider-form';
import {
  RELAY_REASONING_TIERS,
  clearRelayNegativeCache,
  recordRelayNegativeCache,
  relayNegativeCachedKinds,
  type RelayNegativeCacheModelKey,
  type RelayReasoningTier,
} from './relay-negative-cache';

export { RELAY_REASONING_TIERS, type RelayReasoningTier };

const EFFORT_TO_TIER: Readonly<Record<string, RelayReasoningTier>> = {
  low: 'fast',
  medium: 'balanced',
  high: 'deep',
  xhigh: 'max',
  max: 'max',
};

const REJECTION_STATUSES: ReadonlySet<number> = new Set([400, 422]);

export function isRelayReasoningTier(value: unknown): value is RelayReasoningTier {
  return typeof value === 'string' && (RELAY_REASONING_TIERS as readonly string[]).includes(value);
}

/** Fixture effortCases: effort vocabulary -> tier, deduplicated in tier order. */
export function relayReasoningTiersFromEfforts(efforts: readonly string[]): RelayReasoningTier[] {
  const mapped = new Set(efforts.flatMap((effort) => (Object.hasOwn(EFFORT_TO_TIER, effort) ? [EFFORT_TO_TIER[effort]!] : [])));
  return RELAY_REASONING_TIERS.filter((tier) => mapped.has(tier));
}

type RelayMatchedModel = AIModel & { relayMatchedProviderKind?: string };

/**
 * The model's `reasoningEfforts` in model-facts: for a family matched by the official catalog (`relayMatchedProviderKind`) look up that family (canonical first);
 * only when there is no match read the cached by-model view. Return empty if neither is available.
 */
export function relayModelFactsReasoningEfforts(model: AIModel): string[] {
  const matched = (model as RelayMatchedModel).relayMatchedProviderKind;
  if (matched) {
    // The canonical id from the match result comes first (trimmed); fall back to the model id when it misses.
    const canonical = model.canonicalModelId?.trim();
    const facts = (canonical ? getModelFacts(matched, canonical) : undefined)
      ?? (canonical !== model.id ? getModelFacts(matched, model.id) : undefined);
    return facts?.reasoningEfforts ?? [];
  }
  return cachedModelReasoningEffortsByModel(model.id) ?? [];
}

/**
 * The automatic set shared by the panel / outbound / model > advanced (control intent vocabulary): when tiers exist `automatic` comes first, followed by each tier; empty without tiers.
 * Including automatic is so that when the user has never picked a tier the default stays automatic = no reasoning field sent, and an existing model that gains tiers keeps its default request body unchanged.
 */
export function relayAutomaticReasoningIntents(provider: Provider, model: AIModel): string[] {
  const tiers = relayAutomaticReasoningTiers(provider, model);
  return tiers.length > 0 ? ['automatic', ...tiers.map((tier) => (tier === 'fast' ? 'low' : tier))] : [];
}

/** Automatic reasoning tiers for the relay shape (excluding local engine connections); empty for other shapes and local engines. */
export function relayAutomaticReasoningTiers(provider: Provider, model: AIModel): RelayReasoningTier[] {
  if (providerFormOf(provider) !== 'relay' || provider.relayRequested?.engineProfile) return [];
  return relayReasoningTiersFromEfforts(relayModelFactsReasoningEfforts(model));
}

/**
 * Fixture classifyCases: the rejected tier; returns null when it is not a tier rejection (404 / 415 are left to protocol fallback; 5xx / 401 / 429 are not evidence).
 * The naming criterion (rejectionTokens) is computed on the original error body: pass `body`, or pass `namesReasoning` already computed where the event is emitted.
 */
export function classifyRelayReasoningTierRejection(input: {
  status: number | undefined;
  sentTier: string | null | undefined;
  outputStarted: boolean;
} & ({ body: string } | { namesReasoning: boolean })): RelayReasoningTier | null {
  if (input.outputStarted || !isRelayReasoningTier(input.sentTier)) return null;
  if (typeof input.status !== 'number' || !REJECTION_STATUSES.has(input.status)) return null;
  const names = 'body' in input ? relayErrorBodyNamesReasoning(input.body) : input.namesReasoning;
  return names ? input.sentTier : null;
}

/**
 * Fixture fallbackCases: use the selected tier if it was not rejected; if rejected, take the nearest available non-rejected tier below it, otherwise the nearest above it,
 * and return null if there is none (this time send no reasoning field). automatic / off and non-tier values are returned as is.
 */
export function relayReasoningTierFallback(
  available: readonly string[],
  rejected: readonly string[],
  selected: string,
): string | null {
  if (!isRelayReasoningTier(selected) || !rejected.includes(selected)) return selected;
  const order: readonly string[] = RELAY_REASONING_TIERS;
  const index = order.indexOf(selected);
  const usable = (tier: string) => available.includes(tier) && !rejected.includes(tier);
  for (let i = index - 1; i >= 0; i -= 1) if (usable(order[i]!)) return order[i]!;
  for (let i = index + 1; i < order.length; i += 1) if (usable(order[i]!)) return order[i]!;
  return null;
}

/** Negative cache key (connection x model x first-send protocol, the same one the send side writes); returns null for non-relay shapes. */
export function relayReasoningTierCacheKey(
  provider: Provider,
  model: AIModel,
  transport?: string,
): RelayNegativeCacheModelKey | null {
  if (providerFormOf(provider) !== 'relay') return null;
  return { connectionId: provider.id, modelId: model.id, transport: transport ?? relayFirstSendTransport(provider, model) };
}

/** Tiers this model has been rejected on under its current protocol (in tier order). */
export function relayRejectedReasoningTiers(key: RelayNegativeCacheModelKey | null, now = Date.now()): RelayReasoningTier[] {
  if (!key) return [];
  const kinds = new Set<string>(relayNegativeCachedKinds(key, now));
  return RELAY_REASONING_TIERS.filter((tier) => kinds.has(`reasoningTier:${tier}`));
}

export function recordRelayReasoningTierRejection(key: RelayNegativeCacheModelKey, tier: RelayReasoningTier, now = Date.now()): void {
  recordRelayNegativeCache({ ...key, kind: `reasoningTier:${tier}` }, now);
}

/** Clear this model's tier records (current protocol) when the user changes the tier override; re-detection clears the whole connection. */
export function clearRelayReasoningTierRejections(key: RelayNegativeCacheModelKey): void {
  clearRelayNegativeCache(key, RELAY_REASONING_TIERS.map((tier) => `reasoningTier:${tier}` as const));
}
