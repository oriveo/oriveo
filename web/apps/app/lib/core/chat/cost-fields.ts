/**
 * Helpers that derive the cost and citation fields.
 *
 * - `mergeCitationsWithExisting`: merges old and new citations by normalizeUrl on a
 *   continuation or a regenerate.
 * - `applyCitationsToMessage`: writes citations back onto a given message in the store.
 * - `deriveCostFields`: computes cost and cache token fields from a UsageBreakdown for
 *   use on a ChatMessage.
 * - `mergeMessageUsageFields`: accumulates the normalized token usage fields across a
 *   continuation.
 */

import type { StoreApi } from 'zustand';
import type { AIModel, Citation, ProviderAuthMode } from '@oriveo/shared';
import type { AppStore } from '../store/app-store';
import type { StreamUsage } from '../providers/types';
import { normalizeUrl } from '../providers/transport/citation-utils';
import { calcCost, calcCostFromResolved, estimateCost, type CostSource, type PricingInput } from './cost';
import type { UsageBreakdown } from './usage-breakdown';
import { resolveCatalogModel } from '../metadata/metadata-client';

/**
 * Merge old and new citations on a continuation or regenerate.
 * Same strategy as mergeCitation: normalizeUrl is the primary key and arrival order is
 * preserved. Written out separately here rather than reusing mergeCitation, which is
 * built for the incremental ctx.citations case: the old citations go in first and new
 * ones with the same key are skipped, so nothing is duplicated.
 */
export function mergeCitationsWithExisting(
  existing: Citation[] | undefined,
  next: Citation[] | undefined,
): Citation[] | undefined {
  if (!existing || existing.length === 0) return next;
  if (!next || next.length === 0) return existing;
  const merged: Citation[] = [...existing];
  const seen = new Set(existing.map((c) => normalizeUrl(c.url)));
  for (const c of next) {
    const key = normalizeUrl(c.url);
    if (key && seen.has(key)) continue;
    if (key) seen.add(key);
    merged.push(c);
  }
  return merged;
}

export function applyCitationsToMessage(
  store: StoreApi<AppStore>,
  conversationId: string,
  messageId: string,
  citations: Citation[] | undefined,
): void {
  if (!citations || citations.length === 0) return;
  const conversation = store.getState().conversations.find((c) => c.id === conversationId);
  const target = conversation?.messages.find((m) => m.id === messageId);
  if (!conversation || !target) return;
  const merged = mergeCitationsWithExisting(target.citations, citations);
  if (!merged || merged.length === 0) return;
  store.getState().updateConversation(conversationId, {
    messages: conversation.messages.map((m) =>
      m.id === messageId ? { ...m, citations: merged } : m,
    ),
  });
}

/**
 * Map a model's own local prices onto calcCost's PricingInput.
 *
 * The units differ, so do not mix them: `promptPrice` and `completionPrice` are
 * **per token** (already divided by 1e6 during model sync), while the four cache prices
 * are **per M token**, and calcCost converts each on its own terms.
 * Returns null when both primary prices are missing so calcCost can honestly report
 * `unknown`, which is what "the price really is not known" looks like. Do not invent a 0.
 */
function localPricingOf(model: AIModel): PricingInput | null {
  if (typeof model.promptPrice !== 'number' && typeof model.completionPrice !== 'number') {
    return null;
  }
  return {
    promptPerToken: model.promptPrice,
    completionPerToken: model.completionPrice,
    cachedInputPerMToken: model.cacheReadInputPerMToken,
    cacheCreationInputPerMToken: model.cacheCreationInputPerMToken,
    cacheWrite5mPerMToken: model.cacheWrite5mPerMToken,
    cacheWrite1hPerMToken: model.cacheWrite1hPerMToken,
  };
}

/**
 * Compute the cost from a UsageBreakdown and fill in the cache and costSource fields of
 * a ChatMessage.
 *
 * - Prefers {@link calcCost}, which consumes metadata cachedInput and cacheWrite5m/1h.
 * - Falls back to {@link estimateCost} when the breakdown is missing (an older strategy
 *   that does not expose one, or empty usage).
 * - The returned fields spread straight onto a ChatMessage:
 *     `cachedInputTokens` / `cacheCreation5mTokens` / `cacheCreation1hTokens` / `costSource`
 */
export function deriveCostFields(
  usage: StreamUsage | undefined,
  model: AIModel | undefined,
  providerKind: string | undefined,
  authMode?: ProviderAuthMode,
): {
  cost: number;
  costSource: CostSource;
  cachedInputTokens?: number;
  cacheCreation5mTokens?: number;
  cacheCreation1hTokens?: number;
  inputTokens?: number;
  outputTokens?: number;
  cacheCreationInputTokens?: number;
} {
  const messageUsage = deriveMessageUsageFields(usage);
  // Short-circuit subscription mode **before** any price lookup: Grok's usage parser
  // turns `cost_in_usd_ticks` into `breakdown.upstreamCost`, and calcCost prefers the
  // upstream value. Without the short-circuit every message would show an amount
  // converted at API rates that the user never paid, since they pay a monthly fee.
  // Token counts are still shown.
  if (authMode === 'subscription') {
    return { cost: 0, costSource: 'subscription', ...messageUsage };
  }
  if (!usage || !model) {
    return { cost: 0, costSource: 'unknown', ...messageUsage };
  }
  const breakdown: UsageBreakdown | undefined = usage.breakdown;
  if (breakdown && providerKind) {
    const resolved = resolveCatalogModel(model.id, providerKind);
    let result = calcCostFromResolved(breakdown, resolved);
    if (result.source === 'unknown') {
      // The model is not in the catalog: relay models come from the user's own relay,
      // so resolveCatalogModel(providerKind: 'relay') can never find them in the
      // official catalog. calcCost would then return (0, unknown) and zero out the whole
      // cost. Feed it the model's own local prices instead, so calcCost applies the same
      // fallback ratios internally (read x0.5, 5m write x1.25, 1h write x2.0) and both
      // paths agree. Multiplying the cache-inclusive total input directly would roughly
      // double the estimate on every cache hit.
      result = calcCost(breakdown, localPricingOf(model));
    }
    // Only emit a cache field that was actually observed. Writing 0 would claim the provider
    // reported a zero, which is a different fact from it reporting nothing at all.
    const cacheFields: {
      cachedInputTokens?: number;
      cacheCreation5mTokens?: number;
      cacheCreation1hTokens?: number;
    } = {};
    if (breakdown.cacheReadObserved || breakdown.cachedInputTokens > 0) {
      cacheFields.cachedInputTokens = breakdown.cachedInputTokens;
    }
    if (breakdown.cacheWriteObserved || breakdown.cacheCreation5mTokens > 0) {
      cacheFields.cacheCreation5mTokens = breakdown.cacheCreation5mTokens;
    }
    if (breakdown.cacheWriteObserved || breakdown.cacheCreation1hTokens > 0) {
      cacheFields.cacheCreation1hTokens = breakdown.cacheCreation1hTokens;
    }
    return { cost: result.cost, costSource: result.source, ...cacheFields, ...messageUsage };
  }
  // Fallback: the older estimateCost, which has no cache split.
  const fallback = estimateCost(usage, model, providerKind);
  return {
    cost: fallback ?? 0,
    costSource: fallback == null ? 'unknown' : 'localEstimate',
    ...messageUsage,
  };
}

function deriveMessageUsageFields(usage: StreamUsage | undefined): {
  inputTokens?: number;
  outputTokens?: number;
  cachedInputTokens?: number;
  cacheCreationInputTokens?: number;
} {
  if (!usage) return {};
  if (usage.messageUsage) return { ...usage.messageUsage };
  if (usage.breakdown) {
    const breakdown = usage.breakdown;
    const cacheCreationInputTokens =
      breakdown.cacheCreation5mTokens + breakdown.cacheCreation1hTokens;
    return {
      inputTokens:
        breakdown.promptTokens +
        breakdown.cachedInputTokens +
        breakdown.cacheCreation5mTokens +
        breakdown.cacheCreation1hTokens,
      outputTokens: breakdown.completionTokens,
      // The newer parser uses the observed flag to tell a real 0 from a missing field; a positive value still matches older breakdowns.
      ...(breakdown.cacheReadObserved || breakdown.cachedInputTokens > 0
        ? { cachedInputTokens: breakdown.cachedInputTokens }
        : {}),
      ...(breakdown.cacheWriteObserved || cacheCreationInputTokens > 0
        ? { cacheCreationInputTokens }
        : {}),
    };
  }
  return {
    ...(typeof usage.prompt_tokens === 'number' ? { inputTokens: usage.prompt_tokens } : {}),
    ...(typeof usage.completion_tokens === 'number'
      ? { outputTokens: usage.completion_tokens }
      : {}),
  };
}

/**
 * Continuation case: accumulate the cache token fields of prev and this round.
 *
 * - Stays undefined only when both sides are missing; if either side is confirmed
 *   (including a confirmed 0), the accumulated result is kept.
 * - Callers spread it onto a ChatMessage: `{ ...interruptedMsg, ...mergeMessageUsageFields(prev, cur) }`
 */
export function mergeMessageUsageFields(
  prev: {
    inputTokens?: number;
    outputTokens?: number;
    cachedInputTokens?: number;
    cacheCreationInputTokens?: number;
    cacheCreation5mTokens?: number;
    cacheCreation1hTokens?: number;
  },
  cur: {
    inputTokens?: number;
    outputTokens?: number;
    cachedInputTokens?: number;
    cacheCreationInputTokens?: number;
    cacheCreation5mTokens?: number;
    cacheCreation1hTokens?: number;
  },
): {
  inputTokens?: number;
  outputTokens?: number;
  cachedInputTokens?: number;
  cacheCreationInputTokens?: number;
  cacheCreation5mTokens?: number;
  cacheCreation1hTokens?: number;
} {
  const sumOpt = (a?: number, b?: number): number | undefined => {
    if (a == null && b == null) return undefined;
    return (a ?? 0) + (b ?? 0);
  };
  const out: {
    inputTokens?: number;
    outputTokens?: number;
    cachedInputTokens?: number;
    cacheCreationInputTokens?: number;
    cacheCreation5mTokens?: number;
    cacheCreation1hTokens?: number;
  } = {};
  const input = sumOpt(prev.inputTokens, cur.inputTokens);
  if (input != null) out.inputTokens = input;
  const output = sumOpt(prev.outputTokens, cur.outputTokens);
  if (output != null) out.outputTokens = output;
  const cached = sumOpt(prev.cachedInputTokens, cur.cachedInputTokens);
  if (cached != null) out.cachedInputTokens = cached;
  const cacheCreation = sumOpt(prev.cacheCreationInputTokens, cur.cacheCreationInputTokens);
  if (cacheCreation != null) out.cacheCreationInputTokens = cacheCreation;
  const c5m = sumOpt(prev.cacheCreation5mTokens, cur.cacheCreation5mTokens);
  if (c5m != null) out.cacheCreation5mTokens = c5m;
  const c1h = sumOpt(prev.cacheCreation1hTokens, cur.cacheCreation1hTokens);
  if (c1h != null) out.cacheCreation1hTokens = c1h;
  return out;
}
