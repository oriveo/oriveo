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

/**
 * SiliconFlow Service - OpenAI-compatible. Chinese and international accounts use
 * separate .cn / .com endpoints.
 * Image generation is dispatched by the route handling in the base class
 * [OpenAICompatibleService] (imageGen profile route=images_api -> /images/generations,
 * with the request body coming from the catalog's requestDefaults).
 */
class SiliconFlowService(client: HttpClient, json: Json) : OpenAICompatibleService(
    client = client,
    json = json,
    defaultBaseUrl = "https://api.siliconflow.cn/v1",
    providerName = "SiliconFlow",
    providerKind = ProviderKind.SiliconFlow,
), BalanceQueryable {
    companion object {
        private const val DEFAULT_ORIGIN = "https://api.siliconflow.cn"
    }

    /**
     * Balance: `GET ${origin}/v1/user/info` -> `data.totalBalance / balance / chargeBalance`.
     */
    override suspend fun fetchBalance(apiKey: String, baseURL: String?): ai.oriveo.community.core.provider.ProviderBalance {
        if (apiKey.isBlank()) throw ProviderServiceError.InvalidAPIKey("API key is empty.")
        val origin = ai.oriveo.community.core.provider.balanceOriginOf(baseURL, DEFAULT_ORIGIN)
        val response = client.get("$origin/v1/user/info") {
            applyHeaders(apiKey)
        }
        if (!response.status.isSuccess()) throw SseParser.mapHttpError(response)
        val envelope = json.decodeFromString<UserInfoEnvelope>(response.bodyAsText())
        val data = envelope.data ?: throw ProviderServiceError.Upstream(200, "SiliconFlow user/info payload missing data.")
        return ai.oriveo.community.core.provider.ProviderBalance(
            currency = if (java.net.URI(origin).host?.lowercase()?.endsWith("siliconflow.com") == true) "USD" else "CNY",
            total = data.totalBalance?.toDoubleOrNull() ?: 0.0,
            granted = data.balance?.toDoubleOrNull(),
            topUp = data.chargeBalance?.toDoubleOrNull(),
            fetchedAt = java.time.Instant.now(),
        )
    }

    @Serializable
    private data class UserInfoEnvelope(val data: UserInfoData? = null)

    @Serializable
    private data class UserInfoData(
        val balance: String? = null,
        val chargeBalance: String? = null,
        val totalBalance: String? = null,
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

    // Vendor resolution, model ordering and the like are driven by model catalog
    // fields rather than maintained locally.
}
