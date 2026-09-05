/**
 * UsageBreakdown - the common input structure for cost computation.
 *
 * Each Provider Strategy maps upstream response fields into this shape during parseUsage, and
 * `calcCost(breakdown, pricing)` then produces the cost with a single formula.
 *
 * Field semantics:
 *   - promptTokens: plain input tokens, with cached and cacheCreation already subtracted.
 *   - cachedInputTokens: input tokens served from cache, billed at the discounted rate.
 *   - cacheCreation5mTokens: Anthropic 5 minute TTL cache writes (x1.25 rate; always 0 elsewhere).
 *   - cacheCreation1hTokens: Anthropic 1 hour TTL cache writes (x2.0 rate; always 0 elsewhere).
 *   - completionTokens: total output, including reasoning.
 *   - reasoningTokens: the reasoning subset, informational and not part of the formula.
 *   - upstreamCost: an exact cost from upstream (OpenRouter and Grok only); highest priority.
 */
export interface UsageBreakdown {
  promptTokens: number;
  cachedInputTokens: number;
  cacheCreation5mTokens: number;
  cacheCreation1hTokens: number;
  completionTokens: number;
  reasoningTokens: number;
  /** Cost already computed upstream, in USD; when present it is used directly and local estimation is skipped. */
  upstreamCost?: number;
  /** The upstream usage explicitly reported a cache read line item; false or missing means unobservable, which is not the same as 0. */
  cacheReadObserved?: boolean;
  /** The upstream usage explicitly reported a cache write line item; false or missing means unobservable, which is not the same as 0. */
  cacheWriteObserved?: boolean;
}

/** An empty breakdown, for fallbacks and tests. */
export function emptyUsageBreakdown(): UsageBreakdown {
  return {
    promptTokens: 0,
    cachedInputTokens: 0,
    cacheCreation5mTokens: 0,
    cacheCreation1hTokens: 0,
    completionTokens: 0,
    reasoningTokens: 0,
  };
}
