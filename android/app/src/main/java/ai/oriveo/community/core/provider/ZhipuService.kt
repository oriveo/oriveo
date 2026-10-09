package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.Citation
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.ProviderSyncResult
import io.ktor.client.HttpClient
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

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
 * The streamShape comes from the legacy profile and may be absent when requests are built from a
 * recipe, so sources are also parsed straight from the raw frame by [zhipuWebSearchCitations]
 * without relying on the delivered field paths.
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

    override fun parseProviderCitations(root: JsonObject): List<Citation> = zhipuWebSearchCitations(root)
}

/**
 * The two places Zhipu puts search sources; entries have the same fields (`{title, link, content, ...}`):
 *  - the top-level `web_search` array of the response (official API reference);
 *  - `choices[0].delta|message.tool_calls[].web_search.search_result` (legacy path).
 * Both are read and de-duplicated by link; entries without a link are not sources.
 */
internal fun zhipuWebSearchCitations(root: JsonObject): List<Citation> {
    val topLevel = (root["web_search"] as? JsonArray).orEmpty()
    val choice = (root["choices"] as? JsonArray)?.firstOrNull() as? JsonObject
    val legacy = listOf("delta", "message").flatMap { key ->
        ((choice?.get(key) as? JsonObject)?.get("tool_calls") as? JsonArray).orEmpty().flatMap { call ->
            (((call as? JsonObject)?.get("web_search") as? JsonObject)?.get("search_result") as? JsonArray).orEmpty()
        }
    }
    return (topLevel + legacy).mapNotNull { element ->
        val item = element as? JsonObject ?: return@mapNotNull null
        fun text(key: String) = (item[key] as? JsonPrimitive)?.takeIf { it.isString }?.content?.takeIf { it.isNotBlank() }
        Citation(url = text("link") ?: return@mapNotNull null, title = text("title"), snippet = text("content"))
    }.distinctBy { it.url }
}
