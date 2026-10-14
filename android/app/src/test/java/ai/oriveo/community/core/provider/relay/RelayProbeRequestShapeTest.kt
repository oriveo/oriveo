package ai.oriveo.community.core.provider.relay

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.RelayKeyValue
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.RelayService
import ai.oriveo.community.core.provider.transport.TransportRegistry
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.request.HttpRequestData
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.TextContent
import java.nio.file.Files
import java.nio.file.Paths
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Probe requests have the same shape as chat requests (shared fixture `relay/probe-orchestration.v1.json`, probeRequestRules).
 * Both go through the production [RelayService] to a fake server, and the comparison is on the headers and body actually sent.
 */
class RelayProbeRequestShapeTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val apiKey = "sk-shape"
    private val baseUrl = "https://relay.example.com"
    private val modelID = "shape-model"

    /** A connection with identity / storage / custom headers: probes must carry these fields just like chat. */
    private val connection = RelayRequestedConfig(
        transport = RelayTransport.Auto,
        disableResponseStorage = true,
        serviceTier = "priority",
        headers = listOf(RelayKeyValue("X-Relay-Client", "oriveo")),
        customUserAgent = "shape-agent/1.0",
    )

    private val protocols = listOf(
        RelayTransport.OpenAIChatCompletions,
        RelayTransport.OpenAIResponses,
        RelayTransport.AnthropicMessages,
        RelayTransport.GeminiGenerateContent,
    )

    /**
     * Top-level keys the chat body has and the probe body may lack: limited to conversation content and generation parameters.
     * Identity / storage / cache keys (store, service_tier, prompt_cache_key, model, ...) are not listed here; a probe missing them fails.
     */
    private val contentAndGenerationKeys = setOf(
        // Conversation content and system prompt
        "messages", "input", "contents", "system", "instructions", "systemInstruction",
        // Streaming
        "stream", "stream_options",
        // Tools
        "tools", "tool_choice",
        // Thinking
        "reasoning", "reasoning_effort", "thinking",
        // Sampling parameters and output limit
        "temperature", "top_p", "max_tokens", "max_output_tokens", "generationConfig",
    )

    /** Conversely, top-level keys the probe body has and the chat body may lack: only the output limit and non-streaming. */
    private val probeOnlyKeys = setOf("stream", "max_tokens", "max_output_tokens", "generationConfig")

    private val requests = mutableListOf<HttpRequestData>()
    private val service = RelayService(
        client = HttpClient(
            MockEngine { request ->
                synchronized(requests) { requests += request }
                respond("{}", HttpStatusCode.InternalServerError)
            },
        ),
        json = json,
        transportRegistry = TransportRegistry(json),
    )

    private fun probeRules(): JsonObject {
        var dir = Paths.get("").toAbsolutePath()
        repeat(8) {
            val candidate = dir.resolve("shared/test-fixtures/relay/probe-orchestration.v1.json")
            if (Files.exists(candidate)) {
                return Json.parseToJsonElement(String(Files.readAllBytes(candidate), Charsets.UTF_8))
                    .jsonObject.getValue("probeRequestRules").jsonObject
            }
            dir = dir.parent ?: return@repeat
        }
        throw IllegalStateException("probe-orchestration.v1.json not found")
    }

    /** Run one outbound call (the fake server always answers 500, so the call itself throws) and take the first request it sent. */
    private fun firstRequest(send: suspend () -> Unit): HttpRequestData = runBlocking {
        synchronized(requests) { requests.clear() }
        try {
            send()
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
        }
        synchronized(requests) { requests.first() }
    }

    private fun probeRequest(transport: RelayTransport): HttpRequestData = firstRequest {
        service.verifyGeneration(apiKey, baseUrl, modelID, connection, modelTransport = transport)
    }

    /** A chat send with a single user message (streaming, with a system prompt). */
    private fun chatRequest(transport: RelayTransport): HttpRequestData = firstRequest {
        service.sendMessageStream(
            apiKey = apiKey,
            modelID = modelID,
            messages = listOf(
                ChatMessage(
                    id = "m1",
                    role = ChatRole.User,
                    text = "hello",
                    providerKind = ProviderKind.Relay,
                    providerName = "",
                    modelID = modelID,
                    modelName = modelID,
                    state = ChatMessageState.Delivered,
                ),
            ),
            baseUrl = baseUrl,
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(
                systemPrompt = "You are terse.",
                relayRequested = connection,
                activeModel = AIModel(id = modelID, name = modelID, relayTransport = transport),
            ),
        ).collect()
    }

    private fun HttpRequestData.headerNames(): Set<String> = headers.names().map { it.lowercase() }.toSet()

    private fun HttpRequestData.bodyObject(): JsonObject =
        Json.parseToJsonElement((body as TextContent).text).jsonObject

    @Test
    fun `probe and chat have the same shape`() {
        for (transport in protocols) {
            val probe = probeRequest(transport)
            val chat = chatRequest(transport)
            val label = transport.value

            assertEquals("$label: request header name set", chat.headerNames(), probe.headerNames())
            assertTrue("$label: the connection custom header is really sent", "x-relay-client" in probe.headerNames())
            assertEquals("$label: request path (Gemini differs only by the streaming action)", chat.url.encodedPath.substringBefore(":"), probe.url.encodedPath.substringBefore(":"))

            val probeKeys = probe.bodyObject().keys
            val chatKeys = chat.bodyObject().keys
            assertEquals(
                "$label: keys the chat has and the probe lacks may only be conversation content / generation parameters",
                emptySet<String>(),
                chatKeys - probeKeys - contentAndGenerationKeys,
            )
            assertEquals("$label: extra probe keys may only be the output limit / non-streaming", emptySet<String>(), probeKeys - chatKeys - probeOnlyKeys)
        }

        // Not vacuous: the Responses storage / tier fields exist on both sides, and a probe missing one fails above.
        val responsesProbe = probeRequest(RelayTransport.OpenAIResponses).bodyObject()
        val responsesChat = chatRequest(RelayTransport.OpenAIResponses).bodyObject()
        for (key in listOf("model", "store", "service_tier")) {
            assertEquals("openai_responses: $key", responsesChat.getValue(key), responsesProbe.getValue(key))
        }
        // The probe does not carry the Responses default image_generation tool.
        assertTrue("tools" in responsesChat && "tools" !in responsesProbe)
    }

    @Test
    fun `Responses probe output limit is 16`() {
        val rules = probeRules()
        val responsesCap = rules.getValue("responsesMaxOutputTokens").jsonPrimitive.int
        val otherCap = rules.getValue("otherProtocolsMaxTokens").jsonPrimitive.int
        assertEquals(16, responsesCap)

        fun cap(transport: RelayTransport): Int {
            val body = probeRequest(transport).bodyObject()
            return when (transport) {
                RelayTransport.OpenAIResponses -> body.getValue("max_output_tokens")
                RelayTransport.GeminiGenerateContent -> body.getValue("generationConfig").jsonObject.getValue("maxOutputTokens")
                else -> body.getValue("max_tokens")
            }.jsonPrimitive.int
        }
        assertEquals(responsesCap, cap(RelayTransport.OpenAIResponses))
        for (transport in protocols - RelayTransport.OpenAIResponses) {
            assertEquals(transport.value, otherCap, cap(transport))
        }

        // The construct-only entry and the request actually sent are the same request.
        for (transport in protocols) {
            val sent = probeRequest(transport)
            val built = service.probeWireRequest(apiKey, baseUrl, modelID, connection, transport)
            assertEquals(transport.value, sent.url.toString(), built.url)
            assertEquals(transport.value, sent.bodyObject(), Json.parseToJsonElement(built.body).jsonObject)
        }
    }
}
