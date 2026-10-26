package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.relay.anthropicUsageBreakdown
import ai.oriveo.community.core.provider.relay.geminiUsageBreakdown
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

/**
 * Per-provider usage parsers for regular chat: the service layer's streaming / non-streaming paths and every leg of the tool loop share this one copy,
 * so cache buckets and upstream actual cost (OpenRouter `usage.cost`, Grok `cost_in_usd_ticks`) are kept identically on every leg.
 * Field semantics follow the provider usage cheat sheet in the project docs.
 */
object ChatUsageParsers {

    /** `usage` in OpenAI Chat Completions shape, dispatched to that provider's parser; a null [kind] or any other provider uses the OpenAI template. */
    fun openAIChat(kind: ProviderKind?, usage: JsonObject?): UsageBreakdown = when (kind) {
        ProviderKind.Grok -> grok(usage)
        ProviderKind.Moonshot -> moonshot(usage)
        ProviderKind.DeepSeek -> deepSeek(usage)
        ProviderKind.Qwen -> qwen(usage)
        ProviderKind.OpenRouter -> openRouter(usage)
        else -> openAIChatDefault(usage)
    }

    /**
     * OpenAI template: promptTokens = prompt_tokens - cached_tokens; cachedInputTokens = prompt_tokens_details.cached_tokens;
     * completionTokens = completion_tokens (already includes reasoning); reasoningTokens is informational only.
     */
    fun openAIChatDefault(usage: JsonObject?): UsageBreakdown {
        if (usage == null) return UsageBreakdown()
        val prompt = usage.int("prompt_tokens") ?: 0
        val completion = usage.int("completion_tokens") ?: 0
        val cachedRaw = usage.obj("prompt_tokens_details")?.int("cached_tokens")
        val cached = cachedRaw ?: 0
        return UsageBreakdown(
            promptTokens = (prompt - cached).coerceAtLeast(0),
            cachedInputTokens = cached,
            completionTokens = completion,
            reasoningTokens = usage.obj("completion_tokens_details")?.int("reasoning_tokens") ?: 0,
            cacheReadObserved = cachedRaw != null,
        )
    }

    /**
     * Grok tier S: `usage.cost_in_usd_ticks / 1e10` is the actual upstream cost (USD). 1 USD = 10^10 ticks, not 1e8.
     */
    fun grok(usage: JsonObject?): UsageBreakdown {
        if (usage == null) return UsageBreakdown()
        return openAIChatDefault(usage).copy(
            upstreamCost = usage.long("cost_in_usd_ticks")?.let { it / GrokService.GROK_TICKS_PER_USD },
        )
    }

    /**
     * The usage object in Moonshot (Kimi) stream chunks: top-level `usage` wins; when absent read `choices[0].usage`
     * (Kimi actually puts the last chunk's usage inside the choice, as the recorded streams provider-toolcall/recorded/moonshot*.sse show).
     */
    fun moonshotChunkUsage(root: JsonObject): JsonObject? =
        root["usage"] as? JsonObject
            ?: ((root["choices"] as? JsonArray)?.firstOrNull() as? JsonObject)?.get("usage") as? JsonObject

    /** Moonshot's cached_tokens is at the top level of `usage` (not a prompt_tokens_details subfield); thinking tokens are already counted in completion. */
    fun moonshot(usage: JsonObject?): UsageBreakdown {
        if (usage == null) return UsageBreakdown()
        val prompt = usage.int("prompt_tokens") ?: 0
        val cachedRaw = usage.int("cached_tokens")
        val cached = cachedRaw ?: 0
        return UsageBreakdown(
            promptTokens = (prompt - cached).coerceAtLeast(0),
            cachedInputTokens = cached,
            completionTokens = usage.int("completion_tokens") ?: 0,
            reasoningTokens = 0,
            cacheReadObserved = cachedRaw != null,
        )
    }

    /** DeepSeek: prompt_tokens = prompt_cache_hit_tokens + prompt_cache_miss_tokens; prefer miss, older responses fall back to prompt_tokens. */
    fun deepSeek(usage: JsonObject?): UsageBreakdown {
        if (usage == null) return UsageBreakdown()
        val hit = usage.int("prompt_cache_hit_tokens")
        return UsageBreakdown(
            promptTokens = usage.int("prompt_cache_miss_tokens") ?: usage.int("prompt_tokens") ?: 0,
            cachedInputTokens = hit ?: 0,
            completionTokens = usage.int("completion_tokens") ?: 0,
            reasoningTokens = usage.obj("completion_tokens_details")?.int("reasoning_tokens") ?: 0,
            cacheReadObserved = hit != null,
        )
    }

    /** Qwen (DashScope compatible): cached reads prompt_tokens_details.cached_tokens first, then top-level cached_tokens. */
    fun qwen(usage: JsonObject?): UsageBreakdown {
        if (usage == null) return UsageBreakdown()
        val nested = usage.obj("prompt_tokens_details")?.int("cached_tokens")
        val top = usage.int("cached_tokens")
        val cached = nested ?: top ?: 0
        return UsageBreakdown(
            promptTokens = ((usage.int("prompt_tokens") ?: 0) - cached).coerceAtLeast(0),
            cachedInputTokens = cached,
            completionTokens = usage.int("completion_tokens") ?: 0,
            reasoningTokens = usage.obj("completion_tokens_details")?.int("reasoning_tokens") ?: 0,
            cacheReadObserved = nested != null || top != null,
        )
    }

    /**
     * OpenRouter: `usage.cost` (USD, already includes all cache discounts) is the actual upstream cost; cache_write_tokens go to the 1h tier per OpenRouter's default 1h TTL.
     */
    fun openRouter(usage: JsonObject?): UsageBreakdown {
        if (usage == null) return UsageBreakdown()
        val details = usage.obj("prompt_tokens_details")
        val cachedRaw = details?.int("cached_tokens")
        val writeRaw = details?.int("cache_write_tokens")
        val cached = cachedRaw ?: 0
        val write = writeRaw ?: 0
        return UsageBreakdown(
            promptTokens = ((usage.int("prompt_tokens") ?: 0) - cached - write).coerceAtLeast(0),
            cachedInputTokens = cached,
            cacheCreation1hTokens = write,
            completionTokens = usage.int("completion_tokens") ?: 0,
            upstreamCost = usage["cost"]?.jsonPrimitive?.doubleOrNull,
            cacheReadObserved = cachedRaw != null,
            cacheWriteObserved = writeRaw != null,
        )
    }

    /** `usage` in OpenAI Responses shape (input / output_tokens); Grok additionally reads cost_in_usd_ticks as the actual upstream cost. */
    fun openAIResponses(kind: ProviderKind?, usage: JsonObject?): UsageBreakdown {
        if (usage == null) return UsageBreakdown()
        val input = usage.int("input_tokens") ?: 0
        val cachedRaw = usage.obj("input_tokens_details")?.int("cached_tokens")
        val cached = cachedRaw ?: 0
        val upstreamCost = if (kind == ProviderKind.Grok) {
            usage.long("cost_in_usd_ticks")?.let { it / GrokService.GROK_TICKS_PER_USD }
        } else {
            null
        }
        return UsageBreakdown(
            promptTokens = (input - cached).coerceAtLeast(0),
            cachedInputTokens = cached,
            completionTokens = usage.int("output_tokens") ?: 0,
            reasoningTokens = usage.obj("output_tokens_details")?.int("reasoning_tokens") ?: 0,
            upstreamCost = upstreamCost,
            cacheReadObserved = cachedRaw != null,
        )
    }

    /** `usage` of Anthropic Messages (message_start / message_delta share the shape): when the nested 5m cache-write tier is missing, fall back to the outer cache_creation_input_tokens. */
    fun anthropic(usage: JsonObject?): UsageBreakdown {
        if (usage == null) return UsageBreakdown()
        val creation = usage.obj("cache_creation")
        return anthropicUsageBreakdown(
            inputTokens = usage.int("input_tokens"),
            outputTokens = usage.int("output_tokens"),
            cacheReadInputTokens = usage.int("cache_read_input_tokens"),
            cacheCreation5mInputTokens = creation?.int("ephemeral_5m_input_tokens") ?: usage.int("cache_creation_input_tokens"),
            cacheCreation1hInputTokens = creation?.int("ephemeral_1h_input_tokens"),
        )
    }

    /** Gemini `usageMetadata`: promptTokenCount includes cachedContent, so subtracting it gives uncached input; output = candidates + thoughts. */
    fun gemini(usageMetadata: JsonObject?): UsageBreakdown {
        if (usageMetadata == null) return UsageBreakdown()
        return geminiUsageBreakdown(
            promptTokenCount = usageMetadata.int("promptTokenCount"),
            candidatesTokenCount = usageMetadata.int("candidatesTokenCount"),
            thoughtsTokenCount = usageMetadata.int("thoughtsTokenCount"),
            cachedContentTokenCount = usageMetadata.int("cachedContentTokenCount"),
        )
    }

    private fun JsonObject.int(key: String): Int? = (this[key] as? kotlinx.serialization.json.JsonPrimitive)?.intOrNull
    private fun JsonObject.long(key: String): Long? = (this[key] as? kotlinx.serialization.json.JsonPrimitive)?.longOrNull
    private fun JsonObject.obj(key: String): JsonObject? = this[key] as? JsonObject
}
