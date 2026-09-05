package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.CapabilityExecutionCollector
import ai.oriveo.community.core.model.CapabilityResponseEvidenceSignal
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Citation
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.StreamEvent
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OpenAICompatibleServiceTest {

    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun `sendMessageStream emits native tool call deltas before tool-only done`() = runTest {
        val payload = """
            data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"search","arguments":"{\"q\":"}}]}}]}

            data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"\"news\"}"}}]},"finish_reason":"tool_calls"}]}

            data: [DONE]
        """.trimIndent()
        val client = HttpClient(MockEngine {
            respond(payload, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "text/event-stream"))
        })
        val service = OpenAICompatibleService(
            client = client,
            json = json,
            defaultBaseUrl = "https://relay.example/v1",
            providerName = "Relay",
            providerKind = ProviderKind.Relay,
        )

        val events = service.sendMessageStream(
            apiKey = "sk-test",
            modelID = "test-model",
            messages = listOf(userMessage("search")),
            baseUrl = null,
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(),
        ).toList()

        val calls = events.filterIsInstance<StreamEvent.ToolCallDeltas>().flatMap { it.deltas }
        val accumulated = mutableMapOf<Int, ai.oriveo.community.core.model.ToolCallDelta>()
        NativeToolCallAccumulator.merge(accumulated, calls)
        val call = NativeToolCallAccumulator.finalize(accumulated, "test").single()
        assertEquals("call_1", call.id)
        assertEquals("search", call.name)
        assertEquals("{\"q\":\"news\"}", call.arguments)
        assertTrue(events.last() is StreamEvent.Done)
    }

    @Test
    fun `sendMessageStream keeps final usage chunk when EOF has no trailing newline`() = runTest {
        val payload = """
            data: {"choices":[{"delta":{"content":"hi"}}]}

            data: {"usage":{"prompt_tokens":7,"completion_tokens":11}}
        """.trimIndent()
        assertFalse(payload.endsWith("\n"))

        val client = HttpClient(
            MockEngine {
                respond(
                    content = payload,
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            }
        )
        val service = OpenAICompatibleService(
            client = client,
            json = json,
            defaultBaseUrl = "https://relay.example/v1",
            providerName = "Relay",
            providerKind = ProviderKind.Relay,
        )

        val events = service.sendMessageStream(
            apiKey = "sk-test",
            modelID = "test-model",
            messages = listOf(userMessage("Hi")),
            baseUrl = null,
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(),
        ).toList()

        assertEquals(2, events.size)
        assertTrue(events[0] is StreamEvent.Delta)
        assertEquals("hi", (events[0] as StreamEvent.Delta).text)

        val done = events[1] as StreamEvent.Done
        assertEquals("hi", done.result.text)
        assertEquals(7, done.result.promptTokens)
        assertEquals(11, done.result.completionTokens)
    }

    /**
     * Regression: DeepSeek, and any provider that follows the OpenAI stream_options.include_usage
     * spec strictly, returns `"usage": null` on mid-stream chunks. That used to make `it.jsonObject`
     * throw on a JsonNull, the whole chunk was then swallowed by the try/catch in SseParser, the
     * delta text was lost with it, and the request ended as an EmptyResponse.
     */
    @Test
    fun `sendMessageStream tolerates null usage in mid-chunks`() = runTest {
        val payload = """
            data: {"choices":[{"delta":{"content":"hello"}}],"usage":null}

            data: {"choices":[{"delta":{"content":" world"}}],"usage":null}

            data: {"choices":[{"delta":{}}],"usage":{"prompt_tokens":3,"completion_tokens":2}}

            data: [DONE]
        """.trimIndent()

        val client = HttpClient(
            MockEngine {
                respond(
                    content = payload,
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            }
        )
        val service = OpenAICompatibleService(
            client = client,
            json = json,
            defaultBaseUrl = "https://relay.example/v1",
            providerName = "Relay",
            providerKind = ProviderKind.Relay,
        )

        val events = service.sendMessageStream(
            apiKey = "sk-test",
            modelID = "test-model",
            messages = listOf(userMessage("Hi")),
            baseUrl = null,
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(),
        ).toList()

        val deltas = events.filterIsInstance<StreamEvent.Delta>().joinToString("") { it.text }
        assertEquals("hello world", deltas)

        val done = events.last() as StreamEvent.Done
        assertEquals("hello world", done.result.text)
        assertEquals(3, done.result.promptTokens)
        assertEquals(2, done.result.completionTokens)
    }

    /**
     * The shape Mistral Magistral actually sends: delta.content is an array of blocks with
     * type=thinking or type=text. The typed StreamChunk only accepts a String content, so unless the
     * base class splits these off first the entire chunk fails to decode and the increment is
     * silently lost. The split lives in the base class and is provider agnostic; a Relay kind is used
     * here to show that a Relay endpoint of the same shape benefits too.
     */
    @Test
    fun `sendMessageStream splits thinking content block arrays into reasoning and text`() = runTest {
        val payload = """
            data: {"choices":[{"delta":{"role":"assistant","content":""}}],"p":"abc"}

            data: {"choices":[{"delta":{"content":[{"type":"thinking","thinking":[{"type":"text","text":"think1"}]}]}}],"p":"de"}

            data: {"choices":[{"delta":{"content":[{"type":"thinking","thinking":[{"type":"text","text":"think2"}]}]}}]}

            data: {"choices":[{"delta":{"content":[{"type":"thinking","thinking":[]}]}}]}

            data: {"choices":[{"delta":{"content":"answer"}}]}

            data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":4,"completion_tokens":6}}

            data: [DONE]
        """.trimIndent()

        val client = HttpClient(
            MockEngine {
                respond(
                    content = payload,
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            }
        )
        val service = OpenAICompatibleService(
            client = client,
            json = json,
            defaultBaseUrl = "https://relay.example/v1",
            providerName = "Relay",
            providerKind = ProviderKind.Relay,
        )

        val events = service.sendMessageStream(
            apiKey = "sk-test",
            modelID = "magistral-medium-latest",
            messages = listOf(userMessage("Hi")),
            baseUrl = null,
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(),
        ).toList()

        // Both the closing frame with its empty thinking array and the non-standard "p" field have to
        // pass through harmlessly.
        val reasoning = events.filterIsInstance<StreamEvent.Reasoning>().joinToString("") { it.text }
        val deltas = events.filterIsInstance<StreamEvent.Delta>().joinToString("") { it.text }
        assertEquals("think1think2", reasoning)
        assertEquals("answer", deltas)

        val done = events.last() as StreamEvent.Done
        assertEquals("answer", done.result.text)
        assertEquals("think1think2", done.result.reasoningText)
        assertEquals(4, done.result.promptTokens)
        assertEquals(6, done.result.completionTokens)
    }

    @Test
    fun `raw stream reasoning confirms only after the service dispatches and emits evidence`() = runTest {
        val payload = """
            data: {"choices":[{"delta":{"content":[{"type":"thinking","thinking":[{"type":"text","text":"proof"}]}]}}]}

            data: [DONE]
        """.trimIndent()
        val collector = CapabilityExecutionCollector()
        // Production compiler registers the authoritative recipe owner. This test deliberately
        // does not manufacture a StreamEvent: OpenAICompatibleService parses the raw SSE frame.
        collector.recordCompiled("reasoning", evidence("reasoning"), revision = "p5-test")
        val service = OpenAICompatibleService(
            client = HttpClient(MockEngine {
                respond(payload, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "text/event-stream"))
            }),
            json = json,
            defaultBaseUrl = "https://relay.example/v1",
            providerName = "Relay",
            providerKind = ProviderKind.Relay,
        )

        val events = service.sendMessageStream(
            apiKey = "sk-test",
            modelID = "m",
            messages = listOf(userMessage("Hi")),
            baseUrl = null,
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(capabilityExecutionCollector = collector),
        ).toList()
        events.forEach(collector::observe)

        assertEquals("observed", collector.successfulTerminalResults().single().state)
        assertTrue(events.any { it is StreamEvent.Reasoning })
    }

    @Test
    fun `successful stream with no matching evidence remains unconfirmed`() = runTest {
        val collector = CapabilityExecutionCollector()
        collector.recordCompiled("web", evidence("citations"), revision = "p5-test")
        val service = OpenAICompatibleService(
            client = HttpClient(MockEngine {
                respond(
                    "data: {\"choices\":[{\"delta\":{\"content\":\"plain\"}}]}\n\ndata: [DONE]\n",
                    HttpStatusCode.OK,
                    headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            }),
            json = json,
            defaultBaseUrl = "https://relay.example/v1",
            providerName = "Relay",
            providerKind = ProviderKind.Relay,
        )
        val events = service.sendMessageStream(
            apiKey = "sk-test", modelID = "m", messages = listOf(userMessage("Hi")), baseUrl = null,
            supportsImageGen = false, reasoningMode = ReasoningMode.Automatic, webSearchEnabled = false,
            requestOptions = ChatRequestOptions(capabilityExecutionCollector = collector),
        ).toList()
        events.forEach(collector::observe)

        assertEquals("unconfirmed", collector.successfulTerminalResults().single().state)
    }

    @Test
    fun `failed or cancelled attempt keeps requested instead of inventing unconfirmed`() = runTest {
        val collector = CapabilityExecutionCollector()
        collector.recordCompiled("web", evidence("citations"), revision = "p5-test")
        collector.confirmDispatched()
        assertEquals("requested", collector.requestedResults().single().state)
    }

    @Test
    fun `multiple upstream loop calls report requested once`() = runTest {
        var requestedWrites = 0
        val collector = CapabilityExecutionCollector { requestedWrites += it.size }
        collector.recordCompiled("web", evidence("citations"), revision = "p5-test")
        collector.confirmDispatched()
        collector.confirmDispatched()
        assertEquals(1, requestedWrites)
        assertEquals(1, collector.requestedResults().size)
    }

    @Test
    fun `empty evidence carriers do not promote observed but valid payloads do`() = runTest {
        val collector = CapabilityExecutionCollector()
        collector.recordCompiled("web", evidence("citations"), revision = "p5-test")
        collector.recordCompiled("reasoning", evidence("reasoning"), revision = "p5-test")
        collector.recordCompiled("generation", evidence("tool_result"), revision = "p5-test")
        collector.confirmDispatched()

        collector.observe(StreamEvent.Citations(emptyList()))
        collector.observe(StreamEvent.Reasoning(""))
        collector.observe(StreamEvent.ToolResult(tool = "", summary = "", step = 1))
        assertEquals(
            listOf("unconfirmed", "unconfirmed", "unconfirmed"),
            collector.successfulTerminalResults().map { it.state },
        )

        collector.observe(StreamEvent.Citations(listOf(Citation(url = "https://example.com"))))
        collector.observe(StreamEvent.Reasoning("proof"))
        collector.observe(StreamEvent.ToolResult(tool = "search", summary = "result", step = 1))
        assertEquals(
            listOf("observed", "observed", "observed"),
            collector.successfulTerminalResults().map { it.state },
        )
    }

    @Test
    fun `parseContentBlockSegments folds non-streaming message content block array`() = runTest {
        // The same block shape on the non-streaming message.content, closed marker included, folded
        // into one reasoning run plus the body text.
        val content = json.parseToJsonElement(
            """
            [
              {"type":"thinking","thinking":[{"type":"text","text":"reasoning one"},{"type":"text","text":"reasoning two"}],"closed":true},
              {"type":"text","text":"body text"}
            ]
            """.trimIndent()
        ).jsonArray

        val segments = parseContentBlockSegments(content)

        assertEquals(
            listOf<ContentBlockSegment>(
                ContentBlockSegment.Reasoning("reasoning one"),
                ContentBlockSegment.Reasoning("reasoning two"),
                ContentBlockSegment.Text("body text"),
            ),
            segments,
        )
    }

    @Test
    fun `parseContentBlockSegments ignores unknown blocks and empty close frame`() = runTest {
        val content = json.parseToJsonElement(
            """[{"type":"thinking","thinking":[]},{"type":"mystery","text":"skip"}]"""
        ).jsonArray

        assertTrue(parseContentBlockSegments(content).isEmpty())
    }

    private fun userMessage(text: String) = ChatMessage(
        id = "msg-1",
        role = ChatRole.User,
        text = text,
        providerKind = ProviderKind.Relay,
        providerName = "Relay",
        modelName = "test-model",
        state = ChatMessageState.Delivered,
    )

    private fun evidence(producerEvent: String) = listOf(
        CapabilityResponseEvidenceSignal(
            producerEvent = producerEvent,
            pointer = "/fixture/$producerEvent",
            nonEmpty = true,
        ),
    )
}
