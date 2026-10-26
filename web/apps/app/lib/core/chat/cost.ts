/**
 * Cost estimation.
 *
 * calcCost / calcCostFromResolved / PricingInput are pure functions living in
 * @oriveo/core/chat/cost, imported by both the web and desktop builds; they are re-exported here.
 *
 * estimateCost (deprecated) needs the full metadata (pricingStatus / pricingUnit) plus the model's
 * own prices, so it stays in this package.
 */

import type { AIModel, ProviderKind } from '@oriveo/shared';
import type { StreamUsage } from '../providers/types';
import { resolveCatalogModel, type ResolvedModelMetadata } from '../metadata/metadata-client';

export {
  calcCost,
  calcCostFromResolved,
  type PricingInput,
  type CostSource,
  type CalcCostResult,
} from '@oriveo/core/chat/cost';

/**
 * Legacy cost estimate.
 *
 * @deprecated Use `calcCost`, which reads a UsageBreakdown and covers the cache, upstream and
 * 5m/1h splits. Older callers estimate from prompt plus completion only and ignore the cache
 * discount fields. Returns the amount only, without a currency; use
 * {@link estimateCostWithCurrency} when the currency is needed.
 */
export function estimateCost(
  usage: StreamUsage | undefined,
  model: AIModel | undefined,
  providerKind?: ProviderKind | string,
): number | null {
  const resolved = model && providerKind ? resolveCatalogModel(model.id, providerKind) : null;
  return estimateCostWithCurrency(usage, model, providerKind, resolved, true)?.amount ?? null;
}

/**
 * Legacy prompt-plus-completion estimate together with the currency the price belongs to: a model's
 * own price is in USD (currencyCode omitted); a catalog price carries `resolved.currencyCode` (the
 * caller passes a `resolved` that already picked the regional price for the connection; the currency
 * is returned as is, with no conversion). Returns null when no price is available.
 *
 * When `allowLocalPrice` is false (an official provider on its official endpoint) the model's own
 * price is not read: it does not go through region selection, so recording it as USD would
 * misattribute a cn-region or non-USD price. Only `resolved` is used, and without it the result is null.
 */
export function estimateCostWithCurrency(
  usage: StreamUsage | undefined,
  model: AIModel | undefined,
  providerKind: ProviderKind | string | undefined,
  resolved: ResolvedModelMetadata | null | undefined,
  allowLocalPrice: boolean,
): { amount: number; currencyCode?: string } | null {
  if (!usage || !model) return { amount: 0 };

  const promptTokens = usage.prompt_tokens ?? 0;
  const completionTokens = usage.completion_tokens ?? 0;

  // Path 1: the model carries its own pricing, filled in by OpenRouter or during model sync (USD;
  // used only when the caller allows it).
  const hasPromptPrice = typeof model.promptPrice === 'number';
  const hasCompletionPrice = typeof model.completionPrice === 'number';
  if (allowLocalPrice && (hasPromptPrice || hasCompletionPrice)) {
    return {
      amount: promptTokens * (hasPromptPrice ? model.promptPrice! : 0)
        + completionTokens * (hasCompletionPrice ? model.completionPrice! : 0),
    };
  }

  // Path 2: fall back to the backend metadata; the currency follows the price.
  if (providerKind && resolved) {
    const currencyCode = resolved.currencyCode;
    if (resolved.pricingStatus === 'free') {
      return { amount: 0, currencyCode };
    }
    // Per-unit pricing: the unit count is unknown here, so record unknown instead of estimating one
    // unit; a missing pricingUnit counts as per_token.
    const pricingUnit = resolved.pricingUnit ?? 'per_token';
    if (pricingUnit !== 'per_token') return null;
    const pricing = resolved.pricing;
    if (pricing?.promptPerToken != null && pricing.completionPerToken != null) {
      return {
        amount: promptTokens * pricing.promptPerToken + completionTokens * pricing.completionPerToken,
        currencyCode,
      };
    }
  }

  return null;
}
