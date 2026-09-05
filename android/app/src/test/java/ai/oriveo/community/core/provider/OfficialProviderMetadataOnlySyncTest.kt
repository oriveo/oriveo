package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.ProviderKind
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpStatusCode
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The metadata-only sync contract for the official providers.
 *
 * ⚠️ **This contract only covers API-key mode.** A Grok subscription instance is an explicit
 * exemption: its source of truth for the model list is the subscription upstream itself
 * (`cli-chat-proxy.grok.com/v1/models`), which when measured had zero overlap with the
 * published catalog, so applying metadata-only there would make every model the user picked
 * nonexistent on that path. The exemption lives in
 * `ProviderRepository.buildSubscriptionEnabled` and is pinned separately by
 * `ProviderRepositoryGrokSubscriptionTest`; the `GrokService.syncProvider` covered by this
 * class must still be metadata-only, because the subscription path never goes through it.
 */
class OfficialProviderMetadataOnlySyncTest {

    private val json = Json { ignoreUnknownKeys = true }
    private val transportRegistry =
        ai.oriveo.community.core.provider.transport.TransportRegistry(json)

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    @Test
    fun `official provider sync only initializes metadata and returns empty models`() = runTest {
        officialServices().forEach { case ->
            MetadataTestFixtures.clear()
            MetadataTestFixtures.applyProviders(
                MetadataTestFixtures.ProviderSpec(
                    providerKind = case.providerKind,
                    defaultModelId = case.modelId,
                    resolveMap = mapOf(case.modelId to case.modelId),
                    models = listOf(MetadataTestFixtures.ModelSpec(case.modelId, displayName = case.modelId)),
                )
            )

            val requestedUrls = mutableListOf<String>()
            val client = HttpClient(
                MockEngine { request ->
                    requestedUrls += request.url.toString()
                    respond("{}", HttpStatusCode.OK)
                }
            )

            val result = case.serviceFactory(client).syncProvider(
                apiKey = "sk-test",
                preferredModelID = " ${case.modelId} ",
                baseUrl = null,
            )

            assertTrue("${case.providerKind} should return metadata-only models", result.models.isEmpty())
            assertEquals("${case.providerKind} should not call upstream during sync", emptyList<String>(), requestedUrls)
        }
    }

    @Test
    fun `openAI custom base url still probes models endpoint`() = runTest {
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.OpenAI,
                defaultModelId = "gpt-4o",
                resolveMap = mapOf("gpt-4o" to "gpt-4o"),
                models = listOf(MetadataTestFixtures.ModelSpec("gpt-4o", displayName = "GPT-4o")),
            )
        )

        val requestedUrls = mutableListOf<String>()
        val client = HttpClient(
            MockEngine { request ->
                requestedUrls += request.url.toString()
                respond("""{"data":[{"id":"gpt-4o","created":0}]}""", HttpStatusCode.OK)
            }
        )

        val result = OpenAIService(client, json, transportRegistry).syncProvider(
            apiKey = "sk-test",
            preferredModelID = "gpt-4o",
            baseUrl = "https://relay.example/v1",
        )

        assertEquals(listOf("https://relay.example/v1/models"), requestedUrls)
        assertEquals(listOf("gpt-4o"), result.models.map { it.id })
    }

    private fun officialServices(): List<OfficialServiceCase> = listOf(
        OfficialServiceCase(ProviderKind.OpenAI, "gpt-4o") { OpenAIService(it, json, transportRegistry) },
        OfficialServiceCase(ProviderKind.Anthropic, "claude-3") { AnthropicService(it, json, transportRegistry) },
        OfficialServiceCase(ProviderKind.Gemini, "gemini-2.5-pro") { GeminiService(it, json, transportRegistry) },
        OfficialServiceCase(ProviderKind.DeepSeek, "deepseek-chat") { DeepSeekService(it, json) },
        OfficialServiceCase(ProviderKind.Grok, "grok-4") { GrokService(it, json, transportRegistry) },
        OfficialServiceCase(ProviderKind.OpenRouter, "openai/gpt-4o") { OpenRouterService(it, json, transportRegistry) },
        OfficialServiceCase(ProviderKind.Groq, "llama-3.3-70b-versatile") { GroqService(it, json) },
        OfficialServiceCase(ProviderKind.Together, "meta-llama/Llama-3.3-70B-Instruct-Turbo") { TogetherService(it, json) },
        OfficialServiceCase(ProviderKind.Fireworks, "accounts/fireworks/models/llama4-maverick-instruct-basic") {
            FireworksService(it, json)
        },
        OfficialServiceCase(ProviderKind.MiniMax, "minimax-text-01") { MiniMaxService(it, json) },
        OfficialServiceCase(ProviderKind.Zhipu, "glm-4.5") { ZhipuService(it, json, transportRegistry) },
        OfficialServiceCase(ProviderKind.Qwen, "qwen-max") { QwenService(it, json, transportRegistry) },
        OfficialServiceCase(ProviderKind.Moonshot, "kimi-k2-0905-preview") { MoonshotService(it, json, transportRegistry) },
        OfficialServiceCase(ProviderKind.Mistral, "magistral-medium-latest") { MistralService(it, json, transportRegistry) },
        OfficialServiceCase(ProviderKind.SiliconFlow, "Qwen/Qwen3-235B-A22B") { SiliconFlowService(it, json) },
    )

    private data class OfficialServiceCase(
        val providerKind: ProviderKind,
        val modelId: String,
        val serviceFactory: (HttpClient) -> ProviderService,
    )
}
