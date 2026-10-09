package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.GenerationOverrideState
import ai.oriveo.community.core.model.GenerationParameterOverride
import ai.oriveo.community.core.model.GenerationParameterOverrides
import ai.oriveo.community.core.model.GenerationParameterRef
import ai.oriveo.community.core.model.GenerationProfileRef
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.relay.buildAnthropicBody
import ai.oriveo.community.core.provider.transport.TransportRegistry
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.TextContent
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The thinking preview and the outbound path share one source: for the same input, the parameters the preview flags equal the ones really dropped from the request body. */
class GenerationParameterThinkingPreviewTest {
    private val json = Json { ignoreUnknownKeys = true }

    @After
    fun tearDown() = MetadataTestFixtures.clear()

    private val overrides = GenerationParameterOverrides(
        mapOf(
            "temperature" to JsonPrimitive(0.3),
            "max_output_tokens" to JsonPrimitive(10000),
            "top_p" to JsonPrimitive(0.5),
        ).mapValues { GenerationParameterOverride(GenerationOverrideState.Value, it.value) },
    )

    @Test
    fun `official anthropic preview equals what the real send chain drops`() = runTest {
        MetadataTestFixtures.applyRaw(GenerationParameterOutboundContractTest().officialMetadata().toString())
        val options = ChatRequestOptions(generationParameters = overrides)
        var requestBody: String? = null
        val client = HttpClient(MockEngine { request ->
            requestBody = (request.body as? TextContent)?.text
            respond("data: [DONE]\n\n", HttpStatusCode.OK)
        })
        runCatching {
            AnthropicService(client, json, TransportRegistry(json)).sendMessageStream(
                apiKey = "preview-test-key",
                modelID = OFFICIAL,
                messages = listOf(ProviderTestFixtures.userMessage("hello", ProviderKind.Anthropic, OFFICIAL)),
                baseUrl = null,
                supportsImageGen = false,
                reasoningMode = ReasoningMode.Deep,
                webSearchEnabled = false,
                requestOptions = options,
            ).toList()
        }
        val body = json.parseToJsonElement(requireNotNull(requestBody)).jsonObject
        val wire = mapOf("temperature" to "temperature", "max_output_tokens" to "max_tokens")
        val preview = GenerationParameterThinkingPreview.dropped(
            Provider(id = "anthropic-preview", kind = ProviderKind.Anthropic), OFFICIAL, ReasoningMode.Deep, options,
        ).map { it.parameterId }.toSet()
        assertEquals(setOf("max_output_tokens", "temperature"), preview)
        assertEquals(droppedFromBody(body, wire), preview)
    }

    @Test
    fun `relay anthropic preview equals what the real builder drops`() {
        val model = anthropicModel()
        val projection = relayProjection(model, RelayTransport.AnthropicMessages)
        val options = ChatRequestOptions(generationParameters = overrides, activeModel = model)
        val body = json.parseToJsonElement(
            buildAnthropicBody(model.id, emptyList(), true, ReasoningMode.Deep, options, capabilityProjection = projection),
        ).jsonObject
        val preview = GenerationParameterThinkingPreview.dropped(
            relay(RelayTransport.AnthropicMessages), model.id, ReasoningMode.Deep, options,
            relayProfile = model.generationProfile, relayProjection = projection,
        ).map { it.parameterId }.toSet()
        assertEquals(setOf("max_output_tokens", "temperature", "top_p"), preview)
        assertEquals(droppedFromBody(body, model.generationProfile!!.wire), preview)
        // No stored tier (automatic) means no preview, and the builder writes no thinking either.
        assertTrue(
            GenerationParameterThinkingPreview.dropped(
                relay(RelayTransport.AnthropicMessages), model.id, ReasoningMode.Automatic, options,
                relayProfile = model.generationProfile, relayProjection = projection,
            ).isEmpty(),
        )
    }

    @Test
    fun `same model name over chat completions protocol is not previewed`() {
        val model = anthropicModel()
        val options = ChatRequestOptions(generationParameters = overrides, activeModel = model)
        val preview = GenerationParameterThinkingPreview.dropped(
            relay(RelayTransport.OpenAIChatCompletions), model.id, ReasoningMode.Deep, options,
            relayProfile = model.generationProfile, relayProjection = relayProjection(model, RelayTransport.AnthropicMessages),
        )
        assertTrue(preview.isEmpty())
    }

    /** Work backwards from the real request body: a user value that does not appear unchanged on its wire path was dropped. */
    private fun droppedFromBody(body: JsonObject, wire: Map<String, String>): Set<String> =
        overrides.values.filter { (id, override) -> id in wire && body[wire.getValue(id)] != override.value }.keys

    private fun relay(transport: RelayTransport) = Provider(
        id = "relay-preview",
        kind = ProviderKind.Relay,
        baseUrlText = "https://relay.example/v1",
        relayRequested = RelayRequestedConfig(transport = transport),
    )

    private fun anthropicModel() = AIModel(
        id = "claude-sonnet-4-5",
        name = "claude-sonnet-4-5",
        generationProfile = GenerationProfileRef(
            template = "anthropic_messages",
            parameters = listOf(
                GenerationParameterRef(id = "max_output_tokens", support = "supported", valueSchema = "integer"),
                GenerationParameterRef(id = "temperature", support = "supported", valueSchema = "number"),
                GenerationParameterRef(id = "top_p", support = "supported", valueSchema = "number"),
            ),
            wire = mapOf("max_output_tokens" to "max_tokens", "temperature" to "temperature", "top_p" to "top_p"),
        ),
    )

    private fun relayProjection(model: AIModel, transport: RelayTransport): CapabilityEvidenceProductionAdapter.Projection {
        val keys = setOf(
            "reasoning_level/deep",
            "generation_parameter/temperature",
            "generation_parameter/max_output_tokens",
            "generation_parameter/top_p",
        )
        val provider = relay(transport)
        val identity = CapabilityEvidenceProductionAdapter.dispatchIdentity(
            CapabilityEvidenceIdentity("test", provider.id, "1", "1", ProviderKind.Relay.rawValue),
            model,
            transport,
            "https://relay.example/v1/messages",
        )
        return CapabilityEvidenceProductionAdapter.dispatchCapabilityProjection(
            model = model,
            relayRequested = provider.relayRequested,
            identity = identity,
            keys = keys,
            explicitKeys = keys,
        )
    }

    private companion object {
        const val OFFICIAL = GenerationParameterOutboundContractTest.OFFICIAL_MODEL
    }
}
