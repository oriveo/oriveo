package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.ProviderSyncResult
import io.ktor.client.HttpClient
import io.ktor.client.request.get
import io.ktor.client.statement.bodyAsText
import io.ktor.http.isSuccess
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.time.Instant

/**
 * DeepSeek Service - the official OpenAI-compatible endpoint.
 *
 * This class only handles key validation and transport; the model list itself is built
 * by `ProviderRepository.buildOfficialEnabled` from the published model catalog.
 *
 * DeepSeek accepts plain-text content only, so attachments are flattened into a string
 * before the chat request goes out.
 */
class DeepSeekService(client: HttpClient, json: Json) : OpenAICompatibleService(
    client = client,
    json = json,
    defaultBaseUrl = "https://api.deepseek.com/v1",
    providerName = "DeepSeek",
    providerKind = ProviderKind.DeepSeek,
), ai.oriveo.community.core.provider.BalanceQueryable {

    companion object {
        // Chat goes to ${origin}/v1/chat/completions, but balance sits on the root
        // path ${origin}/user/balance (no /v1).
        private const val DEFAULT_ORIGIN = "https://api.deepseek.com"
    }

    /**
     * Balance: `GET ${origin}/user/balance` -> `balance_infos`, split per currency with
     * USD preferred.
     *
     * Careful: chat goes to `${origin}/v1/chat/completions` while balance sits on the
     * root path `${origin}/user/balance` with NO /v1 - the origin has to be extracted
     * from the baseURL and joined by hand, `${baseURL}/user/balance` would be wrong.
     */
    override suspend fun fetchBalance(apiKey: String, baseURL: String?): ai.oriveo.community.core.provider.ProviderBalance {
        if (apiKey.isBlank()) throw ProviderServiceError.InvalidAPIKey("API key is empty.")
        val origin = ai.oriveo.community.core.provider.balanceOriginOf(baseURL, DEFAULT_ORIGIN)
        val response = client.get("$origin/user/balance") {
            applyHeaders(apiKey)
        }
        if (!response.status.isSuccess()) throw SseParser.mapHttpError(response)
        val parsed = json.decodeFromString<BalancePayload>(response.bodyAsText())
        val infos = parsed.balance_infos
        // USD first; take the first entry when there is no USD row.
        val info = infos.firstOrNull { it.currency?.uppercase() == "USD" }
            ?: infos.firstOrNull()
            ?: throw ProviderServiceError.Upstream(200, "DeepSeek balance payload empty.")
        return ai.oriveo.community.core.provider.ProviderBalance(
            currency = info.currency ?: "USD",
            total = info.total_balance?.toDoubleOrNull() ?: 0.0,
            granted = info.granted_balance?.toDoubleOrNull(),
            topUp = info.topped_up_balance?.toDoubleOrNull(),
            fetchedAt = Instant.now(),
        )
    }

    @Serializable
    private data class BalancePayload(
        val is_available: Boolean = false,
        val balance_infos: List<BalanceInfo> = emptyList(),
    )

    @Serializable
    private data class BalanceInfo(
        val currency: String? = null,
        val total_balance: String? = null,
        val granted_balance: String? = null,
        val topped_up_balance: String? = null,
    )
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
     * DeepSeek names its cache fields unusually: `prompt_cache_hit_tokens` /
     * `prompt_cache_miss_tokens`. The upstream docs state
     * "prompt_tokens = prompt_cache_hit_tokens + prompt_cache_miss_tokens".
     */
    override fun parseUsage(usage: JsonObject?): ai.oriveo.community.core.provider.UsageBreakdown {
        if (usage == null) return ai.oriveo.community.core.provider.UsageBreakdown()
        val cached = usage["prompt_cache_hit_tokens"]?.jsonPrimitive?.intOrNull ?: 0
        val miss = usage["prompt_cache_miss_tokens"]?.jsonPrimitive?.intOrNull
        // Prefer the miss field; older responses fall back to prompt_tokens.
        val prompt = miss ?: usage["prompt_tokens"]?.jsonPrimitive?.intOrNull ?: 0
        val completion = usage["completion_tokens"]?.jsonPrimitive?.intOrNull ?: 0
        val reasoning = (usage["completion_tokens_details"] as? JsonObject)
            ?.get("reasoning_tokens")?.jsonPrimitive?.intOrNull ?: 0
        return ai.oriveo.community.core.provider.UsageBreakdown(
            promptTokens = prompt,
            cachedInputTokens = cached,
            completionTokens = completion,
            reasoningTokens = reasoning,
            cacheReadObserved = usage["prompt_cache_hit_tokens"]?.jsonPrimitive?.intOrNull != null,
        )
    }

}
