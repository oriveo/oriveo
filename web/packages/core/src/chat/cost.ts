/**
 * Pure cost estimation.
 *
 * - {@link calcCost}: one formula, summing the five UsageBreakdown buckets. An exact upstream
 *   cost wins; otherwise the price is estimated locally from metadata. Pure, zero IO.
 * - {@link calcCostFromResolved}: convenience wrapper that reads pricing off an object.
 */

import type { UsageBreakdown } from './usage-breakdown';

/**
 * The pricing shape calcCost accepts, compatible with two sources:
 *   1. `ResolvedModelMetadata['pricing']`, where `promptPerToken` is already divided by 1e6 and
 *      comes with a `cachedInputPerMToken` field.
 *   2. Raw `ModelPricing`, with `promptPerMToken` / `completionPerMToken` per million.
 *
 * The fields shared by both shapes (cachedInputPerMToken, cacheCreationInputPerMToken,
 * cacheWrite5m/1h) are all per million and divided by 1_000_000 directly.
 */
export interface PricingInput {
  promptPerToken?: number | null;
  completionPerToken?: number | null;
  promptPerMToken?: number | null;
  completionPerMToken?: number | null;
  cachedInputPerMToken?: number | null;
  cacheCreationInputPerMToken?: number | null;
  cacheWrite5mPerMToken?: number | null;
  cacheWrite1hPerMToken?: number | null;
}

/**
 * `subscription`: a subscription-based path such as a Grok subscription login bills nothing per
 * token for this round. It differs from `unknown` in being a known zero rather than an unknown
 * amount: the catalog unit price must not be multiplied out into money the user never spent (a
 * monthly fee was paid instead), and it must not be reported as a missing measurement either.
 */
export type CostSource = 'upstream' | 'localEstimate' | 'unknown' | 'subscription';

export interface CalcCostResult {
  cost: number;
  source: CostSource;
}

/**
 * The single cost formula.
 *
 * - Upstream first: `breakdown.upstreamCost` is used directly when present (OpenRouter, Grok).
 * - Otherwise the five buckets are summed: promptTokens x input + cachedInputTokens x cachedRead
 *   + cacheCreation5mTokens x write5m + cacheCreation1hTokens x write1h
 *   + completionTokens x output.
 * - Cache write price fallbacks when metadata does not carry them:
 *   cachedRead = cachedInput ?? input x 0.5
 *   write5m = cacheWrite5m ?? cacheCreationInput ?? input x 1.25
 *   write1h = cacheWrite1h ?? input x 2.0
 * - Returns source='unknown' when pricing is missing or the main input/output prices are absent.
 *
 * Every PerMToken price is divided by 1_000_000 to reach a per-token rate.
 */
export function calcCost(
  breakdown: UsageBreakdown,
  pricing: PricingInput | null | undefined,
): CalcCostResult {
  // Highest tier: an exact upstream cost wins.
  if (breakdown.upstreamCost !== undefined) {
    return { cost: breakdown.upstreamCost, source: 'upstream' };
  }

  if (!pricing) {
    return { cost: 0, source: 'unknown' };
  }

  // Normalize to per-token: promptPerToken wins (ResolvedModelMetadata), else promptPerMToken / 1e6.
  const inputPerToken =
    pricing.promptPerToken != null
      ? pricing.promptPerToken
      : pricing.promptPerMToken != null
        ? pricing.promptPerMToken / 1_000_000
        : null;
  const outputPerToken =
    pricing.completionPerToken != null
      ? pricing.completionPerToken
      : pricing.completionPerMToken != null
        ? pricing.completionPerMToken / 1_000_000
        : null;

  if (inputPerToken == null && outputPerToken == null) {
    return { cost: 0, source: 'unknown' };
  }

  const inputRate = inputPerToken ?? 0;
  const outputRate = outputPerToken ?? 0;

  // Cache read price: metadata first, otherwise input x 0.5, which is far closer to the real bill than 0.
  const cachedReadPerToken = pricing.cachedInputPerMToken != null
    ? pricing.cachedInputPerMToken / 1_000_000
    : inputRate * 0.5;

  // Anthropic 5m write price: cacheWrite5m -> cacheCreationInput -> input x 1.25.
  const write5mPerToken =
    pricing.cacheWrite5mPerMToken != null
      ? pricing.cacheWrite5mPerMToken / 1_000_000
      : pricing.cacheCreationInputPerMToken != null
        ? pricing.cacheCreationInputPerMToken / 1_000_000
        : inputRate * 1.25;

  // Anthropic 1h write price: cacheWrite1h -> input x 2.0.
  const write1hPerToken = pricing.cacheWrite1hPerMToken != null
    ? pricing.cacheWrite1hPerMToken / 1_000_000
    : inputRate * 2.0;

  const inputCost =
    breakdown.promptTokens * inputRate
    + breakdown.cachedInputTokens * cachedReadPerToken
    + breakdown.cacheCreation5mTokens * write5mPerToken
    + breakdown.cacheCreation1hTokens * write1hPerToken;
  const outputCost = breakdown.completionTokens * outputRate;

  return { cost: inputCost + outputCost, source: 'localEstimate' };
}

/**
 * Convenience wrapper reading the price off a resolved result that carries pricing. The parameter
 * is narrowed structurally to avoid coupling to the full ResolvedModelMetadata.
 */
export function calcCostFromResolved(
  breakdown: UsageBreakdown,
  resolved: { pricing?: PricingInput | null } | null | undefined,
): CalcCostResult {
  return calcCost(breakdown, resolved?.pricing ?? null);
}
