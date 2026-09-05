package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.ProviderSyncResult
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.core.provider.transport.applyProfileMergeParams
import ai.oriveo.community.core.provider.transport.parseJsonObjectOrNull
import io.ktor.client.HttpClient
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import java.util.Base64

/**
 * Grok (xAI) Service - the official OpenAI-compatible endpoint; model metadata comes
 * from the published model catalog.
 *
 * Vision input is supported (image_url data URI). The reasoning parameter is injected
 * only when the catalog's profiles.reasoning declares it. Image generation uses the
 * separate /v1/images/generations endpoint and returns base64 PNG.
 *
 * Transport dispatch:
 *   - text models are routed between openai_chat and openai_responses according to the
 *     catalog's model.transport;
 *   - streaming citations are parsed by the matching transport strategy.
 */
class GrokService(
    client: HttpClient,
    json: Json,
    transportRegistry: TransportRegistry,
) : OpenAICompatibleService(
    client = client,
    json = json,
    defaultBaseUrl = "https://api.x.ai/v1",
    providerName = "Grok",
    providerKind = ProviderKind.Grok,
    transportRegistry = transportRegistry,
) {
    override suspend fun syncProvider(
        apiKey: String,
        preferredModelID: String?,
        baseUrl: String?,
    ): ProviderSyncResult {
        if (apiKey.isBlank()) throw ProviderServiceError.InvalidAPIKey("API key is empty.")

        MetadataClient.ensureInitialized()

        return ProviderSyncResult(models = emptyList())
    }

    /**
     * Grok reports `usage.cost_in_usd_ticks`; dividing it by 1e10 yields the upstream
     * cost in USD directly.
     *
     * Fatal trap: 1 USD = 10,000,000,000 ticks (10^10), NOT 1e8. Dividing by 1e8 would
     * overstate the cost of every Grok assistant message by 100x.
     */
    override fun parseUsage(usage: JsonObject?): ai.oriveo.community.core.provider.UsageBreakdown {
        if (usage == null) return ai.oriveo.community.core.provider.UsageBreakdown()
        val prompt = usage["prompt_tokens"]?.jsonPrimitive?.intOrNull ?: 0
        val completion = usage["completion_tokens"]?.jsonPrimitive?.intOrNull ?: 0
        val cached = (usage["prompt_tokens_details"] as? JsonObject)
            ?.get("cached_tokens")?.jsonPrimitive?.intOrNull ?: 0
        val reasoning = (usage["completion_tokens_details"] as? JsonObject)
            ?.get("reasoning_tokens")?.jsonPrimitive?.intOrNull ?: 0
        val ticks = usage["cost_in_usd_ticks"]?.jsonPrimitive?.longOrNull
        val upstreamCost = ticks?.let { it / GROK_TICKS_PER_USD }
        return ai.oriveo.community.core.provider.UsageBreakdown(
            promptTokens = (prompt - cached).coerceAtLeast(0),
            cachedInputTokens = cached,
            completionTokens = completion,
            reasoningTokens = reasoning,
            upstreamCost = upstreamCost,
            cacheReadObserved = (usage["prompt_tokens_details"] as? JsonObject)
                ?.get("cached_tokens")?.jsonPrimitive?.intOrNull != null,
        )
    }

    // Whether reasoning_effort is injected is decided by the catalog's profiles.reasoning;
    // all this override keeps is the fallback to the 400-driven self-healing cache.
    override fun buildChatRequest(
        modelID: String,
        messages: List<ChatMessage>,
        stream: Boolean,
        reasoningMode: ReasoningMode,
        webSearchEnabled: Boolean,
        supportsImageGen: Boolean,
        requestOptions: ChatRequestOptions,
        resolved: MetadataClient.ResolvedModelMetadata?,
    ): String {
        return super.buildChatRequest(
            modelID = modelID,
            messages = messages,
            stream = stream,
            // Without a complete local identity, a cached self-healing result must
            // not be taken as this call's capability verdict.
            reasoningMode = reasoningMode,
            webSearchEnabled = webSearchEnabled,
            supportsImageGen = supportsImageGen,
            requestOptions = requestOptions,
            resolved = resolved,
        )
    }

    // Image generation (grok-imagine-image / -quality) is dispatched by the base class
    // route handling: imageGen profile grok_images(route=images_api) ->
    // POST /v1/images/generations.

    companion object {
        /**
         * Grok upstream cost unit conversion - xAI states it explicitly:
         * "cost_usd = cost_in_usd_ticks / 10,000,000,000".
         * See https://docs.x.ai/developers/cost-tracking.
         * The unit test asserts `37756000 ticks -> 0.0038 USD +- 1e-6`.
         */
        const val GROK_TICKS_PER_USD: Double = 10_000_000_000.0
    }
}
