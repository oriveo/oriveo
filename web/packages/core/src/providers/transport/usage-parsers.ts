/**
 * UsageBreakdown parsers, shared by the provider strategies.
 *
 * Naming convention: `parseUsageXxx()`, one per provider. There is deliberately no generic
 * mapper: field naming differs too much between vendors, and forcing reuse ends up treating
 * Anthropic `input_tokens` the way OpenAI is treated, which is a fatal accounting error.
 */

import type { UsageBreakdown } from '../../chat/usage-breakdown';

/** OpenRouter / Grok: 1 USD = 10,000,000,000 ticks. */
const GROK_TICKS_PER_USD = 10_000_000_000;

/** Safe number read; anything non-finite becomes 0. */
function num(value: unknown): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : 0;
}

/** Safe optional number read. */
function optNum(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined;
}

/* ── Tier A ───────────────────────────────────────────────────────────── */

/**
 * OpenAI, including the GPT-5 family, shared by Chat Completions and Responses.
 *
 * Key trap: `prompt_tokens_details.cached_tokens` is a subset of `prompt_tokens` and must be
 * subtracted, otherwise the cached part is billed twice.
 */
export function parseUsageOpenAI(usage: Record<string, unknown>): UsageBreakdown {
  const promptDetails = usage.prompt_tokens_details as Record<string, unknown> | undefined;
  const completionDetails = usage.completion_tokens_details as Record<string, unknown> | undefined;

  const promptTotal = num(usage.prompt_tokens ?? usage.input_tokens);
  const cached = num(promptDetails?.cached_tokens);
  const completion = num(usage.completion_tokens ?? usage.output_tokens);
  const reasoning = num(completionDetails?.reasoning_tokens);

  return {
    promptTokens: Math.max(0, promptTotal - cached),
    cachedInputTokens: cached,
    cacheCreation5mTokens: 0,
    cacheCreation1hTokens: 0,
    completionTokens: completion,
    reasoningTokens: reasoning,
    cacheReadObserved: optNum(promptDetails?.cached_tokens) !== undefined,
  };
}

/**
 * Alias Responses-shaped usage onto the Chat Completions shape.
 *
 * The two protocols agree on the *semantics* of usage but not on the *paths*: Responses puts the
 * details in `input_tokens_details` / `output_tokens_details`, Chat Completions in
 * `prompt_tokens_details` / `completion_tokens_details`. Renaming only the top-level token fields
 * and leaving the detail paths alone makes `cached_tokens` and `reasoning_tokens` constantly 0
 * and `cacheReadObserved` constantly false, so the whole cache-read card vanishes even though
 * upstream did report the numbers. Every transport branch has to run the normalization.
 *
 * Aliases are filled in only where the target key is missing (`??`): values upstream really sent
 * are never overwritten and detail objects are never invented. With neither side present the
 * field stays undefined, so the observation flag can honestly stay false.
 */
export function normalizeResponsesUsage(
  usage: Record<string, unknown>,
): Record<string, unknown> {
  return {
    ...usage,
    prompt_tokens: usage.prompt_tokens ?? usage.input_tokens,
    completion_tokens: usage.completion_tokens ?? usage.output_tokens,
    prompt_tokens_details: usage.prompt_tokens_details ?? usage.input_tokens_details,
    completion_tokens_details:
      usage.completion_tokens_details ?? usage.output_tokens_details,
  };
}

/**
 * OpenAI Responses (`/v1/responses`); reuses {@link parseUsageOpenAI} after normalization.
 *
 * Grok also speaks Responses but is the only one carrying `cost_in_usd_ticks`, so it has to go
 * through {@link parseUsageGrok}. Callers should run {@link normalizeResponsesUsage} first and
 * then pick a parser by providerKind, using this one only for the OpenAI family.
 */
export function parseUsageOpenAIResponses(usage: Record<string, unknown>): UsageBreakdown {
  return parseUsageOpenAI(normalizeResponsesUsage(usage));
}

/**
 * Anthropic: `input_tokens` excludes the cached part and counts only what is genuinely new after
 * the last breakpoint. `usage.cache_creation` is a nested object separating the 5m and 1h TTLs;
 * older responses fall back to the outer `cache_creation_input_tokens`, which counts as 5m.
 */
export function parseUsageAnthropic(usage: Record<string, unknown>): UsageBreakdown {
  const cc = usage.cache_creation as Record<string, unknown> | undefined;
  const promptTokens = num(usage.input_tokens);
  const cacheRead = num(usage.cache_read_input_tokens);
  const cacheCreationFallback = num(usage.cache_creation_input_tokens);
  const cache5m = num(cc?.ephemeral_5m_input_tokens);
  const cache1h = num(cc?.ephemeral_1h_input_tokens);
  const output = num(usage.output_tokens);

  return {
    promptTokens,
    cachedInputTokens: cacheRead,
    cacheCreation5mTokens: cc ? cache5m : cacheCreationFallback,
    cacheCreation1hTokens: cc ? cache1h : 0,
    completionTokens: output,
    reasoningTokens: 0, // Anthropic thinking tokens are already counted in output_tokens, with no separate figure
    cacheReadObserved: optNum(usage.cache_read_input_tokens) !== undefined,
    cacheWriteObserved:
      optNum(usage.cache_creation_input_tokens) !== undefined ||
      optNum(cc?.ephemeral_5m_input_tokens) !== undefined ||
      optNum(cc?.ephemeral_1h_input_tokens) !== undefined,
  };
}

/**
 * Gemini: as observed on 2026-05-17, `candidatesTokenCount` does *not* include thoughts, so
 * `completionTokens = candidates + thoughts`. `promptTokenCount` includes
 * `cachedContentTokenCount` and must have it subtracted.
 */
export function parseUsageGemini(usageMetadata: Record<string, unknown>): UsageBreakdown {
  const prompt = num(usageMetadata.promptTokenCount);
  const cached = num(usageMetadata.cachedContentTokenCount);
  const candidates = num(usageMetadata.candidatesTokenCount);
  const thoughts = num(usageMetadata.thoughtsTokenCount);

  return {
    promptTokens: Math.max(0, prompt - cached),
    cachedInputTokens: cached,
    cacheCreation5mTokens: 0,
    cacheCreation1hTokens: 0,
    completionTokens: candidates + thoughts,
    reasoningTokens: thoughts,
    cacheReadObserved: optNum(usageMetadata.cachedContentTokenCount) !== undefined,
  };
}

/**
 * DeepSeek: the documented identity is
 * `prompt_cache_hit_tokens + prompt_cache_miss_tokens === prompt_tokens`. `promptTokens` takes the
 * miss count (falling back to `prompt_tokens`); `reasoning_tokens` is already inside completion.
 */
export function parseUsageDeepSeek(usage: Record<string, unknown>): UsageBreakdown {
  const miss = optNum(usage.prompt_cache_miss_tokens);
  const hit = num(usage.prompt_cache_hit_tokens);
  const completionDetails = usage.completion_tokens_details as Record<string, unknown> | undefined;

  return {
    promptTokens: miss ?? num(usage.prompt_tokens),
    cachedInputTokens: hit,
    cacheCreation5mTokens: 0,
    cacheCreation1hTokens: 0,
    completionTokens: num(usage.completion_tokens),
    reasoningTokens: num(completionDetails?.reasoning_tokens),
    cacheReadObserved: optNum(usage.prompt_cache_hit_tokens) !== undefined,
  };
}

/* ── Tier S ───────────────────────────────────────────────────────────── */

/**
 * OpenRouter: `usage.cost` is returned by default and already includes every cache discount.
 * `cache_write_tokens` passes through writes from Anthropic models and counts as 1h, which is
 * the OpenRouter default.
 */
export function parseUsageOpenRouter(usage: Record<string, unknown>): UsageBreakdown {
  const promptDetails = usage.prompt_tokens_details as Record<string, unknown> | undefined;
  const cached = num(promptDetails?.cached_tokens);
  const cacheWrite = num(promptDetails?.cache_write_tokens);
  const promptTotal = num(usage.prompt_tokens);
  const cost = optNum(usage.cost);

  return {
    // OpenRouter prompt_tokens is the total including cache reads and writes, while
    // UsageBreakdown.promptTokens has to keep its "plain input" meaning; otherwise message stats
    // and the local cost fallback both add the cache in a second time.
    promptTokens: Math.max(0, promptTotal - cached - cacheWrite),
    cachedInputTokens: cached,
    cacheCreation5mTokens: 0,
    cacheCreation1hTokens: cacheWrite,
    completionTokens: num(usage.completion_tokens),
    reasoningTokens: 0,
    upstreamCost: cost,
    cacheReadObserved: optNum(promptDetails?.cached_tokens) !== undefined,
    cacheWriteObserved: optNum(promptDetails?.cache_write_tokens) !== undefined,
  };
}

/**
 * Grok: `cost_in_usd_ticks / 1e10`, not 1e8. Dividing by 1e8 overestimates cost by 100x.
 * `cached_tokens` is a subset of `prompt_tokens` and has to be subtracted.
 */
export function parseUsageGrok(usage: Record<string, unknown>): UsageBreakdown {
  const promptDetails = usage.prompt_tokens_details as Record<string, unknown> | undefined;
  const completionDetails = usage.completion_tokens_details as Record<string, unknown> | undefined;
  const promptTotal = num(usage.prompt_tokens);
  const cached = num(promptDetails?.cached_tokens);
  const ticks = optNum(usage.cost_in_usd_ticks);

  return {
    promptTokens: Math.max(0, promptTotal - cached),
    cachedInputTokens: cached,
    cacheCreation5mTokens: 0,
    cacheCreation1hTokens: 0,
    completionTokens: num(usage.completion_tokens),
    reasoningTokens: num(completionDetails?.reasoning_tokens),
    upstreamCost: ticks !== undefined ? ticks / GROK_TICKS_PER_USD : undefined,
    cacheReadObserved: optNum(promptDetails?.cached_tokens) !== undefined,
  };
}

/* ── Tier B ───────────────────────────────────────────────────────────── */

/**
 * Standard OpenAI-compatible endpoints (Groq / Fireworks / MiniMax / Zhipu / SiliconFlow /
 * Together).
 *
 * Subtle differences from OpenAI:
 *   - SiliconFlow / Together: cached_tokens is not in the published schema, but upstream
 *     GLM/DeepSeek models may pass it through, so the fallback is kept
 *   - MiniMax / Zhipu: observed to return `completion_tokens_details.reasoning_tokens`
 *   - Groq: only the three GPT-OSS models return cached_tokens; elsewhere the field is absent
 *     and counts as 0
 */
export function parseUsageOpenAICompatible(usage: Record<string, unknown>): UsageBreakdown {
  return parseUsageOpenAI(usage);
}

/**
 * Moonshot (Kimi): `cached_tokens` sits at the top level of usage rather than inside
 * `prompt_tokens_details`. Applying the OpenAI template here returns 0 forever.
 */
export function parseUsageMoonshot(usage: Record<string, unknown>): UsageBreakdown {
  const cached = num(usage.cached_tokens);
  const promptTotal = num(usage.prompt_tokens);

  return {
    promptTokens: Math.max(0, promptTotal - cached),
    cachedInputTokens: cached,
    cacheCreation5mTokens: 0,
    cacheCreation1hTokens: 0,
    completionTokens: num(usage.completion_tokens),
    reasoningTokens: 0, // Even kimi-k2-thinking has no separate reasoning_tokens field
    cacheReadObserved: optNum(usage.cached_tokens) !== undefined,
  };
}

/**
 * Qwen DashScope native mode: fields are named `input_tokens` / `output_tokens`, not
 * `prompt_tokens`. The `cached_tokens` path varies by region and model, hence two fallbacks:
 *   Singapore region and some Beijing-region models: `prompt_tokens_details.cached_tokens`
 *   Beijing-region models such as qwen3-vl-plus: `usage.cached_tokens` at the top level
 */
export function parseUsageQwen(usage: Record<string, unknown>): UsageBreakdown {
  const promptDetails = usage.prompt_tokens_details as Record<string, unknown> | undefined;
  const outputDetails = usage.output_tokens_details as Record<string, unknown> | undefined;
  const promptTotal = num(usage.input_tokens ?? usage.prompt_tokens);
  // Two fallbacks: check the nested details first, then the top level
  const cached =
    optNum(promptDetails?.cached_tokens) ?? num(usage.cached_tokens);

  return {
    promptTokens: Math.max(0, promptTotal - cached),
    cachedInputTokens: cached,
    cacheCreation5mTokens: 0,
    cacheCreation1hTokens: 0,
    completionTokens: num(usage.output_tokens ?? usage.completion_tokens),
    reasoningTokens: num(outputDetails?.reasoning_tokens),
    cacheReadObserved:
      optNum(promptDetails?.cached_tokens) !== undefined ||
      optNum(usage.cached_tokens) !== undefined,
  };
}
