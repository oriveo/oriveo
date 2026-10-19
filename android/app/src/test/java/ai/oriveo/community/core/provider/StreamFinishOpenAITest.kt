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
 * The Done events of the OpenAI chat and Responses families carry StreamFinish (persistence contract).
 * Raw SSE is fed to the production parser / service, and the assertions are on the finish the parser itself produces.
 */
class StreamFinishOpenAITest {

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

    private suspend fun chatDone(stream: String): StreamEvent.Done =
        SseParser.parseOpenAICompatibleMulti(
            response = sseResponse(stream),
            json = json,
            stopFamily = StopFamily.OPENAI_CHAT,
            onChunk = { emptyList() },
            onDone = { StreamEvent.Done(ProviderChatResult(text = "x")) },
        ).toList().filterIsInstance<StreamEvent.Done>().single()

    private fun responsesEvents(stream: String) = OpenAIService(
        client = mockClient(stream),
        json = json,
        transportRegistry = transportRegistry,
    ).sendMessageStream(
        apiKey = "sk-test",
        modelID = "gpt-4o",
        messages = listOf(
            ChatMessage(
                id = "msg-1",
                role = ChatRole.User,
                text = "Hi",
                providerKind = ProviderKind.OpenAI,
                providerName = "OpenAI",
                modelName = "gpt-4o",
                state = ChatMessageState.Delivered,
            ),
        ),
        baseUrl = "https://api.openai.com/v1",
        supportsImageGen = false,
        reasoningMode = ReasoningMode.Automatic,
        webSearchEnabled = false,
        requestOptions = ChatRequestOptions(),
    )

    private val chatDelta = """data: {"choices":[{"delta":{"content":"hi"},"finish_reason":null}]}"""
    private val responsesDelta = "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"hi\"}"

    @Test
    fun openai_chat_done_with_length() = runTest {
        val done = chatDone(
            "$chatDelta\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}\n\ndata: [DONE]\n\n",
        )
        assertEquals(StreamFinish(StopFamily.OPENAI_CHAT, StreamEnding.CLEAN, "length"), done.finish)
    }

    @Test
    fun openai_chat_finish_without_done() = runTest {
        val done = chatDone("$chatDelta\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n")
        assertEquals(StreamFinish(StopFamily.OPENAI_CHAT, StreamEnding.CLEAN, "stop"), done.finish)
    }

    @Test
    fun openai_chat_eof_without_marker() = runTest {
        val done = chatDone("$chatDelta\n\n")
        assertEquals(StreamFinish(StopFamily.OPENAI_CHAT, StreamEnding.EOF_WITHOUT_MARKER, null), done.finish)
    }

    @Test
    fun responses_completed() = runTest {
        val events = responsesEvents(
            "$responsesDelta\n\nevent: response.completed\n" +
                "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"usage\":{\"input_tokens\":3,\"output_tokens\":1}}}\n\n",
        ).toList()
        val done = events.filterIsInstance<StreamEvent.Done>().single()
        assertEquals(StreamFinish(StopFamily.OPENAI_RESPONSES, StreamEnding.CLEAN, "completed"), done.finish)
    }

    @Test
    fun responses_incomplete_max_output_tokens() = runTest {
        val events = responsesEvents(
            "$responsesDelta\n\nevent: response.incomplete\n" +
                "data: {\"type\":\"response.incomplete\",\"response\":{\"status\":\"incomplete\"," +
                "\"incomplete_details\":{\"reason\":\"max_output_tokens\"},\"usage\":{\"input_tokens\":3,\"output_tokens\":1}}}\n\n",
        ).toList()
        val done = events.filterIsInstance<StreamEvent.Done>().single()
        val finish = done.finish!!
        assertEquals(
            StreamFinish(StopFamily.OPENAI_RESPONSES, StreamEnding.CLEAN, "incomplete:max_output_tokens"),
            finish,
        )
        assertEquals(
            StopReason.LENGTH,
            StopReasonResolver.resolve(finish.family, finish.ended, finish.finishRaw, hadContent = true),
        )
    }

    @Test
    fun responses_incomplete_keeps_usage() = runTest {
        val events = responsesEvents(
            "$responsesDelta\n\nevent: response.incomplete\n" +
                "data: {\"type\":\"response.incomplete\",\"response\":{\"status\":\"incomplete\"," +
                "\"incomplete_details\":{\"reason\":\"max_output_tokens\"},\"usage\":{\"input_tokens\":7,\"output_tokens\":5}}}\n\n",
        ).toList()
        val done = events.filterIsInstance<StreamEvent.Done>().single()
        assertEquals(7, done.result.promptTokens)
        assertEquals(5, done.result.completionTokens)
    }

    @Test
    fun responses_incomplete_without_reason() = runTest {
        val events = responsesEvents(
            "$responsesDelta\n\nevent: response.incomplete\n" +
                "data: {\"type\":\"response.incomplete\",\"response\":{\"status\":\"incomplete\"}}\n\n",
        ).toList()
        val finish = events.filterIsInstance<StreamEvent.Done>().single().finish!!
        assertEquals(StreamFinish(StopFamily.OPENAI_RESPONSES, StreamEnding.CLEAN, "incomplete"), finish)
        assertEquals(
            StopReason.INCOMPLETE,
            StopReasonResolver.resolve(finish.family, finish.ended, finish.finishRaw, hadContent = true),
        )
    }

    @Test
    fun responses_failed_carries_finish() = runTest {
        val thrown = runCatching {
            responsesEvents(
                "$responsesDelta\n\nevent: response.failed\n" +
                    "data: {\"type\":\"response.failed\",\"response\":{\"status\":\"failed\",\"error\":{\"message\":\"boom\"}}}\n\n",
            ).toList()
        }.exceptionOrNull()
        assertTrue("expected Upstream, got $thrown", thrown is ProviderServiceError.Upstream)
        assertEquals(
            StreamFinish(StopFamily.OPENAI_RESPONSES, StreamEnding.CLEAN, "failed"),
            (thrown as ProviderServiceError.Upstream).streamFinish,
        )
    }

    @Test
    fun responses_eof_without_marker() = runTest {
        val events = responsesEvents("$responsesDelta\n\n").toList()
        val done = events.filterIsInstance<StreamEvent.Done>().single()
        assertEquals(StreamFinish(StopFamily.OPENAI_RESPONSES, StreamEnding.EOF_WITHOUT_MARKER, null), done.finish)
    }
}
