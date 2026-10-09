package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.repository.LOCAL_FIELDS_RETRY_OFFER_PREFIX
import ai.oriveo.community.core.data.repository.localFieldsRetryOwner
import ai.oriveo.community.core.data.repository.ADDITIONAL_BODY_REJECTED_UPSTREAM_TITLE
import ai.oriveo.community.core.data.repository.localFieldsFailureTitle
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
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.StreamEvent
import ai.oriveo.community.core.provider.relay.buildAnthropicBody
import ai.oriveo.community.core.provider.relay.buildLlamaCppNativeBody
import ai.oriveo.community.core.provider.relay.buildOpenAIChatBody
import ai.oriveo.community.feature.chat.localFieldsResendMarker
import ai.oriveo.community.feature.chat.omitLocalFieldsOnceOwner
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.TextContent
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** Every assertion reads a body built by the production request path, not a hand-made fixture. */
class AdditionalRequestBodySendChainTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val additional = """{"top_k": 40, "chat_template_kwargs": {"enable_thinking": false}}"""

    @After
    fun tearDown() = MetadataTestFixtures.clear()

    @Test
    fun `official service merges the additional body and keeps panel parameters`() = runTest {
        val bodies = mutableListOf<String>()
        anthropic(bodies, "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n")
            .send(ChatRequestOptions(generationParameters = temperature(0.3), additionalRequestBody = additional))
        assertMergedWithPanel(json.parseToJsonElement(bodies.single()).jsonObject, "temperature")
    }

    @Test
    fun `relay chat builder merges the additional body and keeps panel parameters`() {
        val model = profileModel("openai_chat_completions", "temperature" to "temperature")
        val body = buildOpenAIChatBody(
            modelID = model.id, messages = emptyList(), stream = true, reasoningMode = ReasoningMode.Automatic,
            requestOptions = ChatRequestOptions(generationParameters = temperature(0.3), activeModel = model, additionalRequestBody = additional),
            capabilityProjection = projection(model, RelayTransport.OpenAIChatCompletions),
        )
        assertMergedWithPanel(json.parseToJsonElement(body).jsonObject, "temperature")
    }

    @Test
    fun `relay anthropic builder merges the additional body and keeps panel parameters`() {
        val model = profileModel("anthropic_messages", "temperature" to "temperature")
        val body = buildAnthropicBody(
            modelID = model.id, messages = emptyList(), stream = true, reasoningMode = ReasoningMode.Automatic,
            requestOptions = ChatRequestOptions(generationParameters = temperature(0.3), activeModel = model, additionalRequestBody = additional),
            capabilityProjection = projection(model, RelayTransport.AnthropicMessages),
        )
        val parsed = json.parseToJsonElement(body).jsonObject
        assertMergedWithPanel(parsed, "temperature")
        assertNotNull("builder skeleton stays", parsed["max_tokens"])
    }

    @Test
    fun `llama cpp native builder merges the additional body and keeps panel parameters`() {
        val model = profileModel("llamacpp_native", "temperature" to "temperature")
        val body = buildLlamaCppNativeBody(
            messages = emptyList(), stream = true,
            requestOptions = ChatRequestOptions(temperature = 0.3f, activeModel = model, additionalRequestBody = additional),
            capabilityProjection = projection(model, RelayTransport.LlamaCppNative),
        )
        val parsed = json.parseToJsonElement(body).jsonObject
        assertMergedWithPanel(parsed, "temperature")
        assertTrue(parsed.containsKey("prompt"))
    }

    @Test
    fun `local validation failure throws its own error type and sends nothing`() = runTest {
        val bodies = mutableListOf<String>()
        try {
            groq(bodies, "data: [DONE]\n\n").sendMessageStream(
                apiKey = API_KEY, modelID = "llama-3.3-70b-versatile",
                messages = listOf(ProviderTestFixtures.userMessage("hello", ProviderKind.Groq, "llama-3.3-70b-versatile")),
                baseUrl = null, supportsImageGen = false, reasoningMode = ReasoningMode.Automatic, webSearchEnabled = false,
                requestOptions = ChatRequestOptions(temperature = 0.3f, additionalRequestBody = """{"messages": [], "top_k": 1}"""),
            ).collect()
            fail("a protected field must be rejected on device")
        } catch (error: ProviderServiceError.LocalRequestRejected) {
            assertEquals("protected_field", error.reason)
            assertEquals("messages", error.fieldName)
            assertNull("no retry affordance for a local additional body rejection", localFieldsRetryOwner(error, additional, false, false))
        }
        assertTrue("request must not be sent", bodies.isEmpty())
    }

    @Test
    fun `pre content stream error with an additional body offers a retry that drops only the additional body`() = runTest {
        val bodies = mutableListOf<String>()
        val frame = "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\"," +
            "\"message\":\"top_k: Extra inputs are not permitted\"}}\n\n"
        val service = anthropic(bodies, frame, ok = "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n")
        val events = mutableListOf<StreamEvent>()
        val error = runCatching {
            service.send(ChatRequestOptions(generationParameters = temperature(0.3), additionalRequestBody = additional)) { events += it }
        }.exceptionOrNull()
        assertTrue("got $error", error is ProviderServiceError.Upstream)
        assertTrue("events=$events", events.none { it is StreamEvent.Delta })
        val owner = localFieldsRetryOwner(error!!, additional, receivedUpstreamEvent = false, hadToolSideEffects = false)
        assertEquals(AdditionalRequestBody.OWNER, owner)
        val marker = localFieldsResendMarker("$LOCAL_FIELDS_RETRY_OFFER_PREFIX$owner")!!
        assertEquals(AdditionalRequestBody.OWNER, omitLocalFieldsOnceOwner(marker))
        // The same decision switches the error card title
        assertEquals(ADDITIONAL_BODY_REJECTED_UPSTREAM_TITLE, localFieldsFailureTitle((error as ProviderServiceError).title, owner))

        // ChatSendCoordinator treats this marker as "omit the additional request body for this request"; the panel parameters are unaffected.
        service.send(ChatRequestOptions(generationParameters = temperature(0.3), additionalRequestBody = null))
        val retry = json.parseToJsonElement(bodies.last()).jsonObject
        assertNull(retry["top_k"])
        assertNull(retry["chat_template_kwargs"])
        assertNotNull("panel parameter survives the retry: $retry", retry["temperature"])
    }

    @Test
    fun `stream fallbacks that are not error frames never offer the additional body retry`() = runTest {
        // Empty stream: the production path delivers an empty Done and the send orchestration turns it into EmptyResponse
        val emptyEvents = relayGemini("").toList()
        assertTrue("empty stream ends with Done: $emptyEvents", emptyEvents.last() is StreamEvent.Done)
        assertNull(localFieldsRetryOwner(ProviderServiceError.EmptyResponse, additional, false, false))

        // Blocking fallback: the stream has no error frame, yet the production path still throws Upstream(200)
        val blocked = runCatching {
            relayGemini("data: {\"candidates\":[{\"content\":{\"parts\":[]},\"finishReason\":\"SAFETY\"}]}\n\n").toList()
        }.exceptionOrNull()
        assertTrue("got $blocked", blocked is ProviderServiceError.Upstream && blocked.statusCode == 200)
        assertNull(localFieldsRetryOwner(blocked!!, additional, receivedUpstreamEvent = false, hadToolSideEffects = false))
        assertEquals("Provider Request Failed", localFieldsFailureTitle((blocked as ProviderServiceError).title, null))
    }

    private fun relayGemini(stream: String): kotlinx.coroutines.flow.Flow<StreamEvent> {
        val client = HttpClient(MockEngine {
            respond(stream, HttpStatusCode.OK, io.ktor.http.headersOf(io.ktor.http.HttpHeaders.ContentType, "text/event-stream"))
        })
        return ai.oriveo.community.core.provider.relay.RelayTransportCoordinator(
            client = client, json = json, transportRegistry = ai.oriveo.community.core.provider.transport.TransportRegistry(json),
        ).sendMessageStream(
            apiKey = API_KEY, modelID = "gemini-2.5-pro",
            messages = listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.Relay, "gemini-2.5-pro")),
            baseUrl = "https://relay.example.com/v1beta", supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic, webSearchEnabled = false,
            requestOptions = ChatRequestOptions(
                additionalRequestBody = additional,
                relayRequested = RelayRequestedConfig(
                    transport = RelayTransport.GeminiGenerateContent,
                    authMode = ai.oriveo.community.core.model.RelayAuthMode.XGoogApiKey,
                ),
            ),
        )
    }

    private class AnthropicHarness(val service: AnthropicService) {
        suspend fun send(options: ChatRequestOptions, onEvent: (StreamEvent) -> Unit = {}) {
            service.sendMessageStream(
                apiKey = API_KEY,
                modelID = GenerationParameterOutboundContractTest.OFFICIAL_MODEL,
                messages = listOf(ProviderTestFixtures.userMessage("hello", ProviderKind.Anthropic, GenerationParameterOutboundContractTest.OFFICIAL_MODEL)),
                baseUrl = null, supportsImageGen = false, reasoningMode = ReasoningMode.Automatic, webSearchEnabled = false,
                requestOptions = options,
            ).collect { onEvent(it) }
        }
    }

    private fun anthropic(bodies: MutableList<String>, first: String, ok: String = first): AnthropicHarness {
        MetadataTestFixtures.applyRaw(GenerationParameterOutboundContractTest().officialMetadata().toString())
        val client = HttpClient(MockEngine { request ->
            bodies += (request.body as TextContent).text
            respond(if (bodies.size == 1) first else ok, HttpStatusCode.OK)
        })
        return AnthropicHarness(AnthropicService(client, json, ai.oriveo.community.core.provider.transport.TransportRegistry(json)))
    }

    @Test
    fun `classified stream errors and errors after content never offer the additional body retry`() = runTest {
        val bodies = mutableListOf<String>()
        val frames = """data: {"choices":[{"index":0,"delta":{"content":"Partial"}}]}""" + "\n\n" +
            """data: {"error":{"message":"Unrecognized request argument supplied: top_k","type":"invalid_request_error"}}""" + "\n\n"
        val events = mutableListOf<StreamEvent>()
        val error = runCatching {
            groq(bodies, frames).sendMessageStream(
                apiKey = API_KEY, modelID = "llama-3.3-70b-versatile",
                messages = listOf(ProviderTestFixtures.userMessage("hello", ProviderKind.Groq, "llama-3.3-70b-versatile")),
                baseUrl = null, supportsImageGen = false, reasoningMode = ReasoningMode.Automatic, webSearchEnabled = false,
                requestOptions = ChatRequestOptions(temperature = 0.3f, additionalRequestBody = additional),
            ).collect { events += it }
        }.exceptionOrNull()
        assertNotNull(error)
        assertTrue("content before the error is delivered", events.any { it is StreamEvent.Delta && it.text.contains("Partial") })
        assertNull(localFieldsRetryOwner(error!!, additional, receivedUpstreamEvent = true, hadToolSideEffects = false))
        assertNull(localFieldsRetryOwner(ProviderServiceError.RateLimited("x"), additional, false, false))
        assertNull(localFieldsRetryOwner(ProviderServiceError.Upstream(400, "x"), null, false, false))
        assertEquals("reasoning", localFieldsRetryOwner(ProviderServiceError.LocalRequestRejected("reasoning", "unknown_path"), null, false, false))
    }

    @Test
    fun `stream error raw text is redacted and truncated before it reaches technical detail`() = runTest {
        val bodies = mutableListOf<String>()
        val long = "y".repeat(5000)
        val frame = """data: {"error":{"message":"echo Bearer $API_KEY $long","type":"invalid_request_error"}}""" + "\n\n"
        val error = runCatching {
            groq(bodies, frame).sendMessageStream(
                apiKey = API_KEY, modelID = "llama-3.3-70b-versatile",
                messages = listOf(ProviderTestFixtures.userMessage("hello", ProviderKind.Groq, "llama-3.3-70b-versatile")),
                baseUrl = null, supportsImageGen = false, reasoningMode = ReasoningMode.Automatic, webSearchEnabled = false,
                requestOptions = ChatRequestOptions(),
            ).collect()
        }.exceptionOrNull() as ProviderServiceError
        val detail = error.technicalDetail
        assertTrue(detail, detail.contains("Upstream response: {\"error\""))
        assertFalse("credential must be redacted", detail.contains(API_KEY))
        val raw = detail.substringAfter("Upstream response: ")
        assertTrue("raw=${raw.toByteArray().size}", raw.toByteArray().size <= SseParser.STREAM_ERROR_RAW_MAX_BYTES + 3)
    }

    private fun assertMergedWithPanel(body: JsonObject, panelKey: String) {
        assertEquals(40, body["top_k"]!!.jsonPrimitive.content.toInt())
        assertEquals("false", body["chat_template_kwargs"]!!.jsonObject["enable_thinking"]!!.jsonPrimitive.content)
        assertNotNull("panel parameter $panelKey must survive: $body", body[panelKey])
    }

    private fun groq(bodies: MutableList<String>, first: String, ok: String = first): GroqService {
        val client = HttpClient(MockEngine { request ->
            bodies += (request.body as TextContent).text
            respond(if (bodies.size == 1) first else ok, HttpStatusCode.OK)
        })
        return GroqService(client, json)
    }

    private fun temperature(value: Double) = GenerationParameterOverrides(
        mapOf("temperature" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive(value))),
    )

    private fun profileModel(template: String, vararg wire: Pair<String, String>) = AIModel(
        id = "fixture-chat",
        name = "fixture-chat",
        generationProfile = GenerationProfileRef(
            template = template,
            parameters = wire.map { GenerationParameterRef(id = it.first, support = "supported", valueSchema = "number") },
            wire = wire.toMap(),
        ),
    )

    private fun projection(model: AIModel, transport: RelayTransport): CapabilityEvidenceProductionAdapter.Projection {
        val provider = Provider(
            id = "relay-additional-body",
            kind = ProviderKind.Relay,
            baseUrlText = "https://relay.example/v1",
            relayRequested = RelayRequestedConfig(transport = transport),
        )
        val finalUrl = when (transport) {
            RelayTransport.AnthropicMessages -> "https://relay.example/v1/messages"
            RelayTransport.LlamaCppNative -> "https://relay.example/completion"
            else -> "https://relay.example/v1/chat/completions"
        }
        val keys = model.generationProfile!!.parameters.mapNotNull { it.id }.map { "generation_parameter/$it" }.toSet()
        return CapabilityEvidenceProductionAdapter.dispatchCapabilityProjection(
            model = model,
            relayRequested = provider.relayRequested,
            identity = CapabilityEvidenceProductionAdapter.dispatchIdentity(
                CapabilityEvidenceIdentity("test", provider.id, "1", "1", ProviderKind.Relay.rawValue),
                model,
                transport,
                finalUrl,
            ),
            keys = keys,
            explicitKeys = keys,
        )
    }

    private companion object {
        const val API_KEY = "gsk-additional-body-secret-123"
    }
}
