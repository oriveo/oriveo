package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.ProviderSyncResult
import io.ktor.client.HttpClient
import kotlinx.serialization.json.Json

/**
 * Zhipu Service - OpenAI-compatible, open.bigmodel.cn
 * Model metadata and the key validation strategy come from the published model catalog.
 * Image generation is dispatched by the route handling in the base class
 * [OpenAICompatibleService] (imageGen profile route=images_api -> /images/generations,
 * with the request body coming from the catalog's requestDefaults).
 *
 * Citations are parsed by the base class through
 * [ai.oriveo.community.core.provider.transport.TransportRegistry]: the openai_chat
 * strategy plus the zhipu_web profile streamShape (citationUrlField="link",
 * citationsArrayPath="choices.0.delta.tool_calls.0.web_search.search_result").
 */
class ZhipuService(
    client: HttpClient,
    json: Json,
    transportRegistry: ai.oriveo.community.core.provider.transport.TransportRegistry,
) : OpenAICompatibleService(
    client = client,
    json = json,
    defaultBaseUrl = "https://open.bigmodel.cn/api/paas/v4",
    providerName = "Zhipu",
    providerKind = ProviderKind.Zhipu,
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
}
