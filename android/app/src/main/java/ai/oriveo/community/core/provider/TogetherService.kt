package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.ProviderSyncResult
import io.ktor.client.HttpClient
import kotlinx.serialization.json.Json

/**
 * Together AI Service - OpenAI-compatible.
 *
 * This class only handles key validation and transport; the model list itself is built
 * by `ProviderRepository.buildOfficialEnabled` from the published model catalog.
 *
 * The base URL is always the one the caller resolved from the endpoint source
 * (`OfficialEndpointSource.effectiveBaseUrlText`), so stored records follow when the server moves the
 * default host to api.together.ai. No host is hard-coded here; when the caller passes an empty value
 * the fallback is the same built-in table, [ProviderKind.defaultBaseUrl].
 */
class TogetherService(client: HttpClient, json: Json) : OpenAICompatibleService(
    client = client,
    json = json,
    defaultBaseUrl = ProviderKind.Together.defaultBaseUrl.orEmpty(),
    providerName = "Together AI",
    providerKind = ProviderKind.Together,
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
