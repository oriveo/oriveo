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
import { lookupPricing, resolveCatalogModel } from '../metadata/metadata-client';

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
 * discount fields.
 */
export function estimateCost(
  usage: StreamUsage | undefined,
  model: AIModel | undefined,
  providerKind?: ProviderKind | string,
): number | null {
  if (!usage || !model) return 0;

  const promptTokens = usage.prompt_tokens ?? 0;
  const completionTokens = usage.completion_tokens ?? 0;

  // Path 1: the model carries its own pricing, filled in by OpenRouter or during model sync.
  const hasPromptPrice = typeof model.promptPrice === 'number';
  const hasCompletionPrice = typeof model.completionPrice === 'number';
  if (hasPromptPrice || hasCompletionPrice) {
    return promptTokens * (hasPromptPrice ? model.promptPrice! : 0)
         + completionTokens * (hasCompletionPrice ? model.completionPrice! : 0);
  }

  // Path 2: fall back to the backend metadata service.
  if (providerKind) {
    const resolved = resolveCatalogModel(model.id, providerKind);
    if (resolved?.pricingStatus === 'free') {
      return 0;
    }
    if (
      resolved?.pricingStatus === 'priced'
      && resolved.pricingUnit !== 'per_token'
      && resolved.pricing?.costPerUnit != null
    ) {
      return resolved.pricing.costPerUnit;
    }

    const pricing = lookupPricing(model.id, providerKind);
    if (pricing) {
      return promptTokens * pricing.promptPerToken
           + completionTokens * pricing.completionPerToken;
    }
  }

  return null;
}
