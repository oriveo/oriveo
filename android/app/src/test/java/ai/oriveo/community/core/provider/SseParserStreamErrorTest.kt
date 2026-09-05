package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.ProviderChatResult
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.StreamEvent
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.request.get
import io.ktor.client.statement.HttpResponse
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.yield
import kotlinx.serialization.json.Json
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Interception of error events that arrive in the middle of a stream.
 *
 * The integration behaviour pinned here: an error handed down mid-protocol (Anthropic's
 * `event: error`, or the OpenAI-compatible `data: {"error":...}`) must throw a
 * ProviderServiceError so the caller shows an error card. Swallowing it silently and then
 * delivering the truncated reply as a Done, as if it had finished normally, is not allowed.
 */
class SseParserStreamErrorTest {

    private val json = Json { ignoreUnknownKeys = true }

    // An HttpClient carries its own SupervisorJob and engine thread pool and stays alive until
    // it is closed. Run serially with forkEvery=1 the process exits with the class and it never
    // shows; turn parallelism on and several classes share a process, so threads and memory grow
    // linearly with the number of cases.
    private val openClients = mutableListOf<HttpClient>()

    private fun mockClient(engine: MockEngine): HttpClient =
        HttpClient(engine).also { openClients.add(it) }

    @After
    fun closeHttpClients() {
        openClients.forEach { it.close() }
        openClients.clear()
    }

    private inline fun <reified T : ProviderServiceError> assertThrowsProviderError(block: () -> Unit): T {
        try {
            block()
        } catch (e: ProviderServiceError) {
            assertTrue("expected ${T::class.simpleName}, got ${e::class.simpleName}", e is T)
            return e as T
        }
        fail("expected ${T::class.simpleName} to be thrown, but nothing was thrown")
        throw AssertionError("unreachable")
    }

    // OpenAI-compatible mid-stream error lines.

    @Test
    fun `openai style mid-stream error throws upstream`() {
        assertThrowsProviderError<ProviderServiceError.Upstream> {
            SseParser.throwIfStreamErrorPayload(
                json,
                """{"error":{"message":"The server had an error processing your request.","type":"server_error"}}""",
            )
        }
    }

    @Test
    fun `rate limit error maps to RateLimited`() {
        assertThrowsProviderError<ProviderServiceError.RateLimited> {
            SseParser.throwIfStreamErrorPayload(
                json,
                """{"error":{"message":"Rate limit reached for requests","type":"rate_limit_error"}}""",
            )
        }
    }

    @Test
    fun `openai stream error redacts credentials prompt and raw payload`() {
        val error = assertThrowsProviderError<ProviderServiceError.RateLimited> {
            SseParser.throwIfStreamErrorPayload(
                json,
                """{"error":{"message":"Rate limit reached for sk-secret while processing prompt-private","type":"rate_limit_error"},"data":"raw-data-private"}""",
            )
        }

        val exposed = "${error.technicalDetail}\n${error.message}"
        assertFalse(exposed.contains("sk-secret"))
        assertFalse(exposed.contains("prompt-private"))
        assertFalse(exposed.contains("raw-data-private"))
    }

    @Test
    fun `quota error maps to QuotaExceeded`() {
        assertThrowsProviderError<ProviderServiceError.QuotaExceeded> {
            SseParser.throwIfStreamErrorPayload(
                json,
                """{"error":{"message":"You exceeded your current quota, please check your plan."}}""",
            )
        }
    }

    @Test
    fun `string error payload throws`() {
        assertThrowsProviderError<ProviderServiceError.Upstream> {
            SseParser.throwIfStreamErrorPayload(json, """{"error":"something went wrong"}""")
        }
    }

    @Test
    fun `error null noise chunk does not throw`() {
        // Some services put "error":null in a mid-chunk when include_usage is on; that must not
        // be mistaken for a failure.
        SseParser.throwIfStreamErrorPayload(json, """{"error":null,"choices":[{"delta":{"content":"hi"}}]}""")
    }

    @Test
    fun `assistant content containing the word error does not throw`() {
        // The word "error" appears inside the delta.content string, not at the top level, so the
        // body text must not be caught by it.
        SseParser.throwIfStreamErrorPayload(
            json,
            """{"choices":[{"delta":{"content":"this is an \"error\" example in code"}}]}""",
        )
    }

    @Test
    fun `payload without error keyword does not throw`() {
        SseParser.throwIfStreamErrorPayload(json, """{"choices":[{"delta":{"content":"hello"}}]}""")
    }

    @Test
    fun `top level code message event is not intercepted when provider detector is disabled`() = runTest {
        val stream = buildString {
            appendLine("event: request.error")
            appendLine(
                """data: {"request_id":"req_1","code":"UPSTREAM_TEMPORARY_UNAVAILABLE","message":"The model stopped after partial output.","primary_action":"retry","retryable":true,"partial":true}""",
            )
            appendLine()
        }

        val events = SseParser.parseOpenAICompatibleMulti(
            response = sseResponse(stream),
            json = json,
            topLevelCodeMessageIsProviderError = false,
            onChunk = { payload ->
                assertTrue(payload.contains("\"type\":\"request.error\""))
                listOf(StreamEvent.Delta("forwarded-event-consumed"))
            },
            onDone = { doneEvent() },
        ).toList()

        assertEquals(StreamEvent.Delta("forwarded-event-consumed"), events.first())
        assertTrue(events.last() is StreamEvent.Done)
    }

    // ── Anthropic event error ────────────────────────────────

    @Test
    fun `anthropic overloaded_error maps to RateLimited`() {
        assertThrowsProviderError<ProviderServiceError.RateLimited> {
            SseParser.throwIfAnthropicErrorEvent(
                json,
                "error",
                """{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}""",
            )
        }
    }

    @Test
    fun `anthropic api_error maps to Upstream`() {
        assertThrowsProviderError<ProviderServiceError.Upstream> {
            SseParser.throwIfAnthropicErrorEvent(
                json,
                "error",
                """{"type":"error","error":{"type":"api_error","message":"Internal server error"}}""",
            )
        }
    }

    @Test
    fun `anthropic stream error redacts credentials prompt and raw payload`() {
        val error = assertThrowsProviderError<ProviderServiceError.InvalidAPIKey> {
            SseParser.throwIfAnthropicErrorEvent(
                json,
                "error",
                """{"type":"error","error":{"type":"authentication_error","message":"Authentication failed for sk-secret and prompt-private"},"data":"raw-data-private"}""",
            )
        }

        val exposed = "${error.technicalDetail}\n${error.message}"
        assertFalse(exposed.contains("sk-secret"))
        assertFalse(exposed.contains("prompt-private"))
        assertFalse(exposed.contains("raw-data-private"))
    }

    @Test
    fun `anthropic error event with unparseable payload still throws`() {
        // An error event is terminal: even when the payload cannot be parsed it still has to
        // throw, rather than letting the stream pretend it completed.
        assertThrowsProviderError<ProviderServiceError.Upstream> {
            SseParser.throwIfAnthropicErrorEvent(json, "error", "not-json-at-all")
        }
    }

    @Test
    fun `anthropic non-error events do not throw`() {
        SseParser.throwIfAnthropicErrorEvent(
            json,
            "content_block_delta",
            """{"delta":{"type":"text_delta","text":"hello"}}""",
        )
        SseParser.throwIfAnthropicErrorEvent(json, "ping", """{"type":"ping"}""")
    }

    // HTTP status classification.

    @Test
    fun `http 402 maps to QuotaExceeded`() = runTest {
        // Payment Required means the user's own account with the provider is out of credit, for
        // example OpenRouter's "Insufficient credits". An account condition has to be classified
        // as QuotaExceeded and must not fall through to the Upstream catch-all.
        val client = mockClient(
            MockEngine {
                respond(
                    content = """{"error":{"message":"Insufficient credits. Add more using https://openrouter.ai/settings/credits","code":402}}""",
                    status = HttpStatusCode.PaymentRequired,
                )
            }
        )
        val error = SseParser.mapHttpError(client.get("http://localhost/chat"))
        assertTrue("expected QuotaExceeded, got ${error::class.simpleName}", error is ProviderServiceError.QuotaExceeded)
    }

    @Test
    fun `production HTTP error parser retains only structured rejected param`() {
        val located = SseParser.mapHttpError(
            400,
            """{"error":{"message":"unsupported optional field","param":"temperature"}}""",
        ) as ProviderServiceError.Upstream
        assertEquals("temperature", located.rejectedParameter)

        val proseOnly = SseParser.mapHttpError(
            400,
            """{"error":{"message":"unsupported parameter temperature"}}""",
        ) as ProviderServiceError.Upstream
        assertEquals(null, proseOnly.rejectedParameter)
    }

    // Gemini in-stream error lines.
    // A Gemini SSE has no [DONE], and a mid-stream `data: {"error":...}` line used to be handed
    // to two parse variants as an ordinary chunk, fail to parse, and be swallowed, leaving a
    // truncated reply masquerading as a normal completion.

    private suspend fun sseResponse(content: String): HttpResponse {
        val client = mockClient(
            MockEngine {
                respond(
                    content = content,
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            }
        )
        return client.get("http://localhost/stream")
    }

    private fun doneEvent() = StreamEvent.Done(ProviderChatResult(text = "done"))

    @Test
    fun `gemini mid-stream error throws upstream`() = runTest {
        val stream = """data: {"error":{"code":500,"message":"Internal error encountered.","status":"INTERNAL"}}""" + "\n"
        assertThrowsProviderError<ProviderServiceError.Upstream> {
            SseParser.parseGeminiStream(
                response = sseResponse(stream),
                json = json,
                onChunk = { null },
                onDone = { doneEvent() },
            ).toList()
        }
    }

    @Test
    fun `gemini mid-stream quota error maps to QuotaExceeded`() = runTest {
        val stream = """data: {"error":{"code":429,"message":"Resource has been exhausted (e.g. check quota).","status":"RESOURCE_EXHAUSTED"}}""" + "\n"
        assertThrowsProviderError<ProviderServiceError.QuotaExceeded> {
            SseParser.parseGeminiStreamMulti(
                response = sseResponse(stream),
                json = json,
                onChunk = { emptyList() },
                onDone = { doneEvent() },
            ).toList()
        }
    }

    @Test
    fun `gemini multi mid-stream error after partial text throws without done`() = runTest {
        val stream = buildString {
            appendLine("""data: {"candidates":[{"content":{"parts":[{"text":"par"}]}}]}""")
            appendLine("""data: {"error":{"code":503,"message":"The service is currently unavailable.","status":"UNAVAILABLE"}}""")
        }
        val events = mutableListOf<StreamEvent>()
        assertThrowsProviderError<ProviderServiceError.ModelUnavailable> {
            SseParser.parseGeminiStreamMulti(
                response = sseResponse(stream),
                json = json,
                onChunk = { listOf(StreamEvent.Delta("par")) },
                onDone = { doneEvent() },
            ).collect { events.add(it) }
        }
        // Partial text emitted before the throw is kept, but a Done saying "finished normally"
        // is never allowed.
        assertTrue(events.any { it is StreamEvent.Delta })
        assertTrue(events.none { it is StreamEvent.Done })
    }

    @Test
    fun `gemini normal chunk containing the word error is not intercepted`() = runTest {
        // The word "error" here only appears inside the parts[].text string, not at the top
        // level, so ordinary body text must not be caught by it.
        val stream = """data: {"candidates":[{"content":{"parts":[{"text":"an \"error\" example"}]}}]}""" + "\n"
        val events = SseParser.parseGeminiStream(
            response = sseResponse(stream),
            json = json,
            onChunk = { StreamEvent.Delta("an \"error\" example") },
            onDone = { doneEvent() },
        ).toList()
        assertEquals(2, events.size)
        assertTrue(events[0] is StreamEvent.Delta)
        assertTrue(events[1] is StreamEvent.Done)
    }

    @Test
    fun `gemini multi normal chunks are not intercepted`() = runTest {
        val stream = buildString {
            appendLine("""data: {"candidates":[{"content":{"parts":[{"text":"hello"}]}}]}""")
            appendLine("""data: {"candidates":[{"content":{"parts":[{"text":" world"}]}}]}""")
        }
        val events = SseParser.parseGeminiStreamMulti(
            response = sseResponse(stream),
            json = json,
            onChunk = { payload ->
                val text = if (payload.contains("hello")) "hello" else " world"
                listOf(StreamEvent.Delta(text))
            },
            onDone = { doneEvent() },
        ).toList()
        assertEquals(3, events.size)
        assertTrue(events.last() is StreamEvent.Done)
    }

    // ══════════════════════════════════════════════════════════════════════
    // Every delta emitted before the error must reach the consumer; pinned separately for
    // each of the seven parsers.
    // ══════════════════════════════════════════════════════════════════════
    // The product requirement is that when an upstream fails inside a 200 stream, the half
    // reply it already produced still shows above the error card. Only the two Gemini paths
    // covered that, indirectly, and even those went red at random because flowOn dropped
    // events; the other five parsers had no assertion at all, which is exactly why the bug
    // survived this long. Hence one case per parser.

    // The key detail is that the consumer has to be *slow*. In production ChatRepository writes
    // a token buffer for every Delta, pushes a StateFlow and occasionally hits the database, so
    // it is never instantaneous, and flowOn drops events precisely in the window where the
    // upstream has already thrown and the consumer has not finished. A test written against an
    // instantaneous consumer can go green by luck even before the fix, which is the same as not
    // writing it. Yielding once before each event widens that window until it reproduces every
    // time.

    /** How long the consumer takes to handle each event, in milliseconds; see [collectSlowly]. */
    private val DOWNSTREAM_LAG_MS = 10L

    /** The three body deltas emitted before the error. They contain neither "error" nor "code",
     *  so throwIfStreamErrorPayload cannot mistake them for a failure. */
    private val partialPayloads = listOf("""{"i":1}""", """{"i":2}""", """{"i":3}""")

    /** A mid-stream error line whose type and message match no more specific pattern, so it
     *  lands on Upstream(200). */
    private val streamErrorPayload = """{"error":{"type":"server_error","message":"upstream exploded"}}"""

    /**
     * Collects slowly, modelling a real consumer that is not instantaneous: ChatRepository
     * writes a token buffer for every Delta, pushes a StateFlow and occasionally hits the
     * database. Returns whatever collect threw, or null if it threw nothing, so the caller can
     * assert on the error type.
     *
     * Why it has to **really sleep** rather than just `yield()`: the producer runs on a real
     * `Dispatchers.IO` thread, while `yield()` only reschedules this coroutine to the back of
     * the test dispatcher's queue on the same thread and returns within microseconds, which
     * barely yields to the producer at all. Measured by temporarily reverting each parser to its
     * pre-fix shape and running three rounds:
     *   - a single `yield()`: 4 of the 7 went red (`parseGeminiStream`,
     *     `parseGeminiStreamMulti` and `parseAnthropicStreamMulti` slipped through on
     *     scheduling luck)
     *   - eight `yield()` calls: 6 went red (`parseAnthropicStreamMulti` stayed green because it
     *     runs early in the class, before the JIT has warmed up, so the producer is the slower
     *     side; run on its own it was red, which shows the green was pure timing accident)
     *   - `Thread.sleep(10)`: **all 7 red in all 3 rounds**
     * A regression test that catches the bug in only half of its runs is barely a test, hence
     * the 10ms.
     *
     * The ordering is deliberate too: sleep first to let the producer get ahead, then `yield()`
     * to create a suspension point where cancellation can be observed, and only then write to
     * the sink. After the fix, ordering is guaranteed by channel FIFO and is independent of
     * timing, so any sleep duration stays green and this does not introduce flakiness of its own.
     */
    private suspend fun <T> collectSlowly(flow: Flow<T>, sink: MutableList<T>): Throwable? =
        try {
            flow.collect { value ->
                @Suppress("BlockingMethodInNonBlockingContext")
                Thread.sleep(DOWNSTREAM_LAG_MS)
                yield()
                sink += value
            }
            null
        } catch (cancellation: CancellationException) {
            // Coroutine cancellation must propagate unchanged; it is not an error under test.
            throw cancellation
        } catch (error: Throwable) {
            error
        }

    /** The shared assertion for every parser: all N deltas arrive, the error comes after them,
     *  and a Done is never delivered. */
    private fun assertPartialsSurvived(thrown: Throwable?, deltaTexts: List<String>) {
        assertTrue(
            "expected Upstream, got ${thrown?.let { it::class.simpleName } ?: "nothing thrown"}",
            thrown is ProviderServiceError.Upstream,
        )
        assertEquals("every delta before the error must reach the consumer", partialPayloads, deltaTexts)
    }

    @Test
    fun `parseOpenAICompatible keeps every delta emitted before the stream error`() = runTest {
        val stream = buildString {
            partialPayloads.forEach { appendLine("data: $it") }
            appendLine("data: $streamErrorPayload")
        }
        val events = mutableListOf<StreamEvent>()
        val thrown = collectSlowly(
            SseParser.parseOpenAICompatible(
                response = sseResponse(stream),
                json = json,
                onChunk = { payload -> StreamEvent.Delta(payload) },
                onDone = { doneEvent() },
            ),
            events,
        )

        assertPartialsSurvived(thrown, events.filterIsInstance<StreamEvent.Delta>().map { it.text })
        assertTrue("a failing stream must never deliver a Done", events.none { it is StreamEvent.Done })
    }

    @Test
    fun `parseOpenAICompatibleMulti keeps every delta emitted before the stream error`() = runTest {
        val stream = buildString {
            partialPayloads.forEach { appendLine("data: $it") }
            appendLine("data: $streamErrorPayload")
        }
        val events = mutableListOf<StreamEvent>()
        val thrown = collectSlowly(
            SseParser.parseOpenAICompatibleMulti(
                response = sseResponse(stream),
                json = json,
                onChunk = { payload -> listOf(StreamEvent.Delta(payload)) },
                onDone = { doneEvent() },
            ),
            events,
        )

        assertPartialsSurvived(thrown, events.filterIsInstance<StreamEvent.Delta>().map { it.text })
        assertTrue("a failing stream must never deliver a Done", events.none { it is StreamEvent.Done })
    }

    @Test
    fun `parseOpenAICompatiblePayloads keeps every payload emitted before the stream error`() = runTest {
        val stream = buildString {
            partialPayloads.forEach { appendLine("data: $it") }
            appendLine("data: $streamErrorPayload")
        }
        val payloads = mutableListOf<String>()
        val thrown = collectSlowly(
            SseParser.parseOpenAICompatiblePayloads(response = sseResponse(stream), json = json),
            payloads,
        )

        assertPartialsSurvived(thrown, payloads)
    }

    @Test
    fun `parseAnthropicStream keeps every delta emitted before the error event`() = runTest {
        val stream = buildString {
            partialPayloads.forEach {
                appendLine("event: content_block_delta")
                appendLine("data: $it")
            }
            appendLine("event: error")
            appendLine("data: $streamErrorPayload")
        }
        val events = mutableListOf<StreamEvent>()
        val thrown = collectSlowly(
            SseParser.parseAnthropicStream(
                response = sseResponse(stream),
                json = json,
                onEvent = { _, data -> StreamEvent.Delta(data) },
                onDone = { doneEvent() },
            ),
            events,
        )

        assertPartialsSurvived(thrown, events.filterIsInstance<StreamEvent.Delta>().map { it.text })
        assertTrue("a failing stream must never deliver a Done", events.none { it is StreamEvent.Done })
    }

    @Test
    fun `parseAnthropicStreamMulti keeps every delta emitted before the error event`() = runTest {
        val stream = buildString {
            partialPayloads.forEach {
                appendLine("event: content_block_delta")
                appendLine("data: $it")
            }
            appendLine("event: error")
            appendLine("data: $streamErrorPayload")
        }
        val events = mutableListOf<StreamEvent>()
        val thrown = collectSlowly(
            SseParser.parseAnthropicStreamMulti(
                response = sseResponse(stream),
                json = json,
                onEvent = { _, data -> listOf(StreamEvent.Delta(data)) },
                onDone = { doneEvent() },
            ),
            events,
        )

        assertPartialsSurvived(thrown, events.filterIsInstance<StreamEvent.Delta>().map { it.text })
        assertTrue("a failing stream must never deliver a Done", events.none { it is StreamEvent.Done })
    }

    @Test
    fun `parseGeminiStream keeps every delta emitted before the stream error`() = runTest {
        val stream = buildString {
            partialPayloads.forEach { appendLine("data: $it") }
            appendLine("data: $streamErrorPayload")
        }
        val events = mutableListOf<StreamEvent>()
        val thrown = collectSlowly(
            SseParser.parseGeminiStream(
                response = sseResponse(stream),
                json = json,
                onChunk = { payload -> StreamEvent.Delta(payload) },
                onDone = { doneEvent() },
            ),
            events,
        )

        assertPartialsSurvived(thrown, events.filterIsInstance<StreamEvent.Delta>().map { it.text })
        assertTrue("a failing stream must never deliver a Done", events.none { it is StreamEvent.Done })
    }

    @Test
    fun `parseGeminiStreamMulti keeps every delta emitted before the stream error`() = runTest {
        val stream = buildString {
            partialPayloads.forEach { appendLine("data: $it") }
            appendLine("data: $streamErrorPayload")
        }
        val events = mutableListOf<StreamEvent>()
        val thrown = collectSlowly(
            SseParser.parseGeminiStreamMulti(
                response = sseResponse(stream),
                json = json,
                onChunk = { payload -> listOf(StreamEvent.Delta(payload)) },
                onDone = { doneEvent() },
            ),
            events,
        )

        assertPartialsSurvived(thrown, events.filterIsInstance<StreamEvent.Delta>().map { it.text })
        assertTrue("a failing stream must never deliver a Done", events.none { it is StreamEvent.Done })
    }
}
