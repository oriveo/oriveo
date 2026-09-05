package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.ProviderSyncResult
import io.ktor.client.HttpClient
import kotlinx.serialization.json.Json

/**
 * Mistral AI Service - OpenAI-compatible, api.mistral.ai.
 * Model metadata and the key validation strategy come from the published model catalog.
 *
 * Magistral-family reasoning models return content as an array of blocks
 * (type=thinking/text). The base class [OpenAICompatibleService] parses that shape
 * generically instead of here, so a relay endpoint with the same shape benefits too.
 * Reasoning tiers come from the published mistral_prompt profile
 * (fast -> prompt_mode:"empty", balanced/deep/max -> "reasoning") and are applied
 * through the generic catalog profile injection, so there is no Mistral-specific
 * injection code in this class.
 */
class MistralService(
    client: HttpClient,
    json: Json,
    transportRegistry: ai.oriveo.community.core.provider.transport.TransportRegistry,
) : OpenAICompatibleService(
    client = client,
    json = json,
    defaultBaseUrl = "https://api.mistral.ai/v1",
    providerName = "Mistral",
    providerKind = ProviderKind.Mistral,
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
