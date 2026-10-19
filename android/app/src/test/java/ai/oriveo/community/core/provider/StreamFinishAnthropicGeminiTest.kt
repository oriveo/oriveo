package ai.oriveo.community.core.provider

import ai.oriveo.community.core.context.StopFamily
import ai.oriveo.community.core.context.StopReason
import ai.oriveo.community.core.context.StopReasonResolver
import ai.oriveo.community.core.context.StreamEnding
import ai.oriveo.community.core.context.StreamFinish
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ProviderChatResult
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.StreamEvent
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.request.get
import io.ktor.client.statement.HttpResponse
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Done events of the Anthropic and Gemini families carry StreamFinish (persistence contract).
 * Raw SSE is fed to the production parser / service, and the assertions are on the finish the parser itself produces.
 */
class StreamFinishAnthropicGeminiTest {

    private val json = Json { ignoreUnknownKeys = true }
    private val transportRegistry = ai.oriveo.community.core.provider.transport.TransportRegistry(json)
    private val openClients = mutableListOf<HttpClient>()

    private fun mockClient(content: String): HttpClient = HttpClient(
        MockEngine {
            respond(
                content = content,
                status = HttpStatusCode.OK,
                headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
            )
        },
    ).also { openClients.add(it) }

    @After
    fun tearDown() {
        openClients.forEach { it.close() }
        openClients.clear()
        MetadataTestFixtures.clear()
        UnsupportedParamCache.resetForTest()
    }

    private suspend fun sseResponse(content: String): HttpResponse = mockClient(content).get("http://localhost/stream")

    private suspend fun anthropicDone(stream: String): StreamEvent.Done =
        SseParser.parseAnthropicStreamMulti(
            response = sseResponse(stream),
            json = json,
            stopFamily = StopFamily.ANTHROPIC,
            onEvent = { _, _ -> emptyList() },
            onDone = { StreamEvent.Done(ProviderChatResult(text = "x")) },
        ).toList().filterIsInstance<StreamEvent.Done>().single()

    private suspend fun geminiDone(stream: String): StreamEvent.Done =
        SseParser.parseGeminiStreamMulti(
            response = sseResponse(stream),
            json = json,
            stopFamily = StopFamily.GEMINI,
            onChunk = { emptyList() },
            onDone = { StreamEvent.Done(ProviderChatResult(text = "x")) },
        ).toList().filterIsInstance<StreamEvent.Done>().single()

    private fun geminiEvents(stream: String) = GeminiService(
        client = mockClient(stream),
        json = json,
        transportRegistry = transportRegistry,
    ).sendMessageStream(
        apiKey = "test-key",
        modelID = "gemini-2.5-flash",
        messages = listOf(
            ChatMessage(
                id = "msg-1",
                role = ChatRole.User,
                text = "Hi",
                providerKind = ProviderKind.Gemini,
                providerName = "Gemini",
                modelName = "gemini-2.5-flash",
                state = ChatMessageState.Delivered,
            ),
        ),
        baseUrl = null,
        supportsImageGen = false,
        reasoningMode = ReasoningMode.Automatic,
        webSearchEnabled = false,
        requestOptions = ChatRequestOptions(),
    )

    private val anthropicDelta =
        "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":3}}}\n\n" +
            "event: content_block_delta\n" +
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hi\"}}\n\n"

    private fun anthropicMessageDelta(stopReason: String) =
        "event: message_delta\n" +
            "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"$stopReason\"},\"usage\":{\"output_tokens\":1}}\n\n"

    private val anthropicStop = "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"

    private val geminiDelta = """data: {"candidates":[{"content":{"parts":[{"text":"hi"}],"role":"model"}}]}"""

    @Test
    fun anthropic_max_tokens() = runTest {
        val done = anthropicDone(anthropicDelta + anthropicMessageDelta("max_tokens") + anthropicStop)
        val finish = done.finish!!
        assertEquals(StreamFinish(StopFamily.ANTHROPIC, StreamEnding.CLEAN, "max_tokens"), finish)
        assertEquals(
            StopReason.LENGTH,
            StopReasonResolver.resolve(finish.family, finish.ended, finish.finishRaw, hadContent = true),
        )
    }

    @Test
    fun anthropic_context_window_exceeded() = runTest {
        val done = anthropicDone(anthropicDelta + anthropicMessageDelta("model_context_window_exceeded") + anthropicStop)
        val finish = done.finish!!
        assertEquals(
            StreamFinish(StopFamily.ANTHROPIC, StreamEnding.CLEAN, "model_context_window_exceeded"),
            finish,
        )
        assertEquals(
            StopReason.CONTEXT_WINDOW_EXCEEDED,
            StopReasonResolver.resolve(finish.family, finish.ended, finish.finishRaw, hadContent = true),
        )
    }

    @Test
    fun anthropic_eof_before_message_stop() = runTest {
        // stop_reason was seen but message_stop never arrived: still EOF, and finishRaw is carried as is
        val done = anthropicDone(anthropicDelta + anthropicMessageDelta("end_turn"))
        assertEquals(StreamFinish(StopFamily.ANTHROPIC, StreamEnding.EOF_WITHOUT_MARKER, "end_turn"), done.finish)
    }

    @Test
    fun gemini_max_tokens() = runTest {
        val done = geminiDone(
            "$geminiDelta\n\n" +
                "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"!\"}],\"role\":\"model\"},\"finishReason\":\"MAX_TOKENS\"}]}\n\n",
        )
        val finish = done.finish!!
        assertEquals(StreamFinish(StopFamily.GEMINI, StreamEnding.CLEAN, "MAX_TOKENS"), finish)
        assertEquals(
            StopReason.LENGTH,
            StopReasonResolver.resolve(finish.family, finish.ended, finish.finishRaw, hadContent = true),
        )
    }

    @Test
    fun gemini_eof_without_finish_reason() = runTest {
        val done = geminiDone("$geminiDelta\n\n")
        assertEquals(StreamFinish(StopFamily.GEMINI, StreamEnding.EOF_WITHOUT_MARKER, null), done.finish)
    }

    @Test
    fun gemini_blocked_carries_finish() = runTest {
        val thrown = runCatching {
            geminiEvents(
                "$geminiDelta\n\n" +
                    "data: {\"candidates\":[{\"content\":{\"parts\":[],\"role\":\"model\"},\"finishReason\":\"SAFETY\"}]}\n\n",
            ).toList()
        }.exceptionOrNull()
        assertTrue("expected Upstream, got $thrown", thrown is ProviderServiceError.Upstream)
        assertEquals(
            StreamFinish(StopFamily.GEMINI, StreamEnding.CLEAN, "SAFETY"),
            (thrown as ProviderServiceError.Upstream).streamFinish,
        )
    }

    private val geminiPromptBlocked = "data: {\"promptFeedback\":{\"blockReason\":\"%s\"}}\n\n"

    private fun relayGeminiEvents(stream: String) = RelayService(
        client = mockClient(stream),
        json = json,
        transportRegistry = transportRegistry,
    ).sendMessageStream(
        apiKey = "goog-key",
        modelID = "gemini-2.5-pro",
        messages = listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.Relay, "gemini-2.5-pro")),
        baseUrl = "https://relay.example.com/v1beta",
        supportsImageGen = false,
        reasoningMode = ReasoningMode.Automatic,
        webSearchEnabled = false,
        requestOptions = ChatRequestOptions(
            relayRequested = RelayRequestedConfig(
                transport = RelayTransport.GeminiGenerateContent,
                authMode = RelayAuthMode.Auto,
            ),
        ),
    )

    @Test
    fun gemini_prompt_block_carries_finish() = runTest {
        // Direct: a blocked prompt still throws, with clean + "blockReason:<value>" on the error
        val direct = runCatching { geminiEvents(geminiPromptBlocked.format("SAFETY")).toList() }.exceptionOrNull()
        assertTrue("expected Upstream, got $direct", direct is ProviderServiceError.Upstream)
        val directFinish = (direct as ProviderServiceError.Upstream).streamFinish
        assertEquals(StreamFinish(StopFamily.GEMINI, StreamEnding.CLEAN, "blockReason:SAFETY"), directFinish)
        assertEquals(
            StopReason.CONTENT_FILTER,
            StopReasonResolver.resolve(directFinish!!.family, directFinish.ended, directFinish.finishRaw, hadContent = false),
        )
    }

    @Test
    fun gemini_prompt_block_carries_finish_relay() = runTest {
        // Relay: any non-empty blockReason (including future new values) is blocked and carries a finish
        val relay = runCatching { relayGeminiEvents(geminiPromptBlocked.format("SOME_FUTURE_REASON")).toList() }.exceptionOrNull()
        assertTrue("expected Upstream, got $relay", relay is ProviderServiceError.Upstream)
        val relayFinish = (relay as ProviderServiceError.Upstream).streamFinish
        assertEquals(StreamFinish(StopFamily.GEMINI, StreamEnding.CLEAN, "blockReason:SOME_FUTURE_REASON"), relayFinish)
        assertEquals(
            StopReason.CONTENT_FILTER,
            StopReasonResolver.resolve(relayFinish!!.family, relayFinish.ended, relayFinish.finishRaw, hadContent = false),
        )
    }
}
