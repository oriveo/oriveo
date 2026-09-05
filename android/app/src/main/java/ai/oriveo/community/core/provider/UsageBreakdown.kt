package ai.oriveo.community.core.provider

/**
 * Normalised split of an upstream usage report.
 *
 * Each provider service maps the upstream response fields into this structure in its
 * `parseUsage()`. [CostCalculator.calcCost] then combines it with the catalog prices
 * in [ai.oriveo.community.core.data.remote.MetadataClient.ResolvedModelMetadata] to
 * produce the final cost estimate and its [CostSource].
 *
 * Field semantics, which are the easy thing to get wrong:
 *   - `promptTokens`: the non-cached input only, with cachedInputTokens ALREADY
 *     subtracted. Anthropic's `usage.input_tokens` already means exactly this; the
 *     OpenAI family needs `prompt_tokens - cached_tokens`.
 *   - `cachedInputTokens`: input served from a cache read, billed at the discounted
 *     cachedInput rate.
 *   - `cacheCreation5mTokens` / `cacheCreation1hTokens`: the two cache write TTL tiers
 *     Anthropic splits out in its nested `cache_creation` object, priced at 1.25x and
 *     2.0x. Every other provider leaves these at zero.
 *   - `completionTokens`: total output, INCLUDING reasoning. Gemini is the exception,
 *     where it has to be computed as `candidatesTokenCount + thoughtsTokenCount`; that
 *     was established by measuring real responses.
 *   - `reasoningTokens`: informational only, never part of the cost formula. It exists
 *     so the UI can show how many thinking tokens a request spent.
 *   - `upstreamCost`: the exact USD figure some upstreams (OpenRouter, Grok) return
 *     themselves. When it is non-null CostCalculator adopts it verbatim and skips the
 *     local estimate.
 *   - `cacheReadObserved` / `cacheWriteObserved`: whether the response actually carried
 *     the corresponding cache fields. They separate "upstream explicitly said zero"
 *     from "upstream has no such field" and take no part in the cost formula.
 */
data class UsageBreakdown(
    val promptTokens: Int = 0,
    val cachedInputTokens: Int = 0,
    val cacheCreation5mTokens: Int = 0,
    val cacheCreation1hTokens: Int = 0,
    val completionTokens: Int = 0,
    val reasoningTokens: Int = 0,
    val upstreamCost: Double? = null,
    val cacheReadObserved: Boolean = false,
    val cacheWriteObserved: Boolean = false,
) {
    /**
     * Total input to show the user: normal + cache read + cache write.
     *
     * `promptTokens` is only the newly submitted, non-cached input, so using it alone
     * as the total silently drops the cached portions. Hand-written sums at call sites
     * tended to add `cachedInputTokens` and forget the 5m/1h buckets, which happens to
     * be harmless on the OpenAI family where those are always zero but undercounts
     * Anthropic. Everything goes through this derived property instead.
     */
    val totalInputTokens: Int
        get() = promptTokens + cachedInputTokens + cacheCreation5mTokens + cacheCreation1hTokens

    val reportedCachedInputTokens: Int?
        get() = cachedInputTokens.takeIf { cacheReadObserved || it > 0 }

    val reportedCacheCreation5mTokens: Int?
        get() = cacheCreation5mTokens.takeIf { cacheWriteObserved || it > 0 }

    val reportedCacheCreation1hTokens: Int?
        get() = cacheCreation1hTokens.takeIf { cacheWriteObserved || it > 0 }
}


enum class CostSource {
    UPSTREAM,
    LOCAL_ESTIMATE,
    UNKNOWN,

    /**
     * The user is spending their own subscription allowance, as with a Grok
     * subscription login, so the request is paid for by the billing period rather than
     * per token.
     *
     * This is kept separate from [UNKNOWN] because the two mean different things to the
     * user: [UNKNOWN] says we cannot work the cost out, while this says there is no
     * per-token charge in the first place. Multiplying a subscription message by the
     * API list price would invent money the user never spent, and showing nothing is
     * always better than showing a fabricated number.
     */
    SUBSCRIPTION,
}
