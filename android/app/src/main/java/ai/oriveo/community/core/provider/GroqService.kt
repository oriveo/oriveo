package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.ProviderSyncResult
import io.ktor.client.HttpClient
import kotlinx.serialization.json.Json

/**
 * Groq Service - OpenAI-compatible, api.groq.com
 *
 * This class only handles key validation and transport; the model list itself is built
 * by `ProviderRepository.buildOfficialEnabled` from the published model catalog.
 */
class GroqService(client: HttpClient, json: Json) : OpenAICompatibleService(
    client = client,
    json = json,
    defaultBaseUrl = "https://api.groq.com/openai/v1",
    providerName = "Groq",
    providerKind = ProviderKind.Groq,
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
