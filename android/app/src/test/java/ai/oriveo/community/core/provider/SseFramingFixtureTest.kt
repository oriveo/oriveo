package ai.oriveo.community.core.provider

import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.request.get
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import java.io.ByteArrayInputStream
import java.io.File
import java.io.InputStream
import java.util.Base64
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The shared SSE framing fixture (`shared/test-fixtures/provider-stream/sse-framing.v1.json`) run
 * against the Android chat parser. The fixture is read only: the raw bytes of every case are fed to
 * the production decoder under each chunking the fixture lists, and every assertion is made on what
 * production code handed out.
 */
class SseFramingFixtureTest {

    @Serializable
    private data class Fixture(val schema: String, val cases: List<Case>)

    @Serializable
    private data class Case(
        val id: String,
        val bytes_base64: String,
        val chunkings: List<Chunking>,
        val expect: Expect,
        val openai_chat: OpenAIChat? = null,
    )

    @Serializable
    private data class Chunking(val name: String, val offsets: List<Int> = emptyList(), val every: Int? = null)

    @Serializable
    private data class Expect(val frames: List<Frame>, val comments: Int)

    @Serializable
    private data class Frame(val event: String?, val data: String, val id: String?, val retry: Long?)

    @Serializable
    private data class OpenAIChat(val text: String, val finish_reason: String?, val done: Boolean)

    private val json = Json { ignoreUnknownKeys = true }

    private val fixture: Fixture by lazy {
        val moduleDir = File(System.getProperty("user.dir") ?: ".").absoluteFile
        val repoRoot = moduleDir.parentFile!!.parentFile!!
        val file = File(repoRoot, "shared/test-fixtures/provider-stream/sse-framing.v1.json")
        require(file.exists()) { "fixture not found at: ${file.absolutePath}" }
        json.decodeFromString<Fixture>(file.readText())
    }

    private fun cut(bytes: ByteArray, chunking: Chunking): List<ByteArray> {
        val offsets = chunking.every?.let { step -> (step until bytes.size step step).toList() } ?: chunking.offsets
        val chunks = mutableListOf<ByteArray>()
        var start = 0
        for (offset in offsets) {
            chunks += bytes.copyOfRange(start, offset)
            start = offset
        }
        chunks += bytes.copyOfRange(start, bytes.size)
        return chunks
    }

    /** Hands out one chunk per read, the way the network would deliver the fixture cut. */
    private class ChunkedInputStream(chunks: List<ByteArray>) : InputStream() {
        private val remaining = ArrayDeque(chunks.filter { it.isNotEmpty() })
        private var current: ByteArrayInputStream? = null

        override fun read(): Int {
            val single = ByteArray(1)
            return if (read(single, 0, 1) < 0) -1 else single[0].toInt() and 0xFF
        }

        override fun read(target: ByteArray, offset: Int, length: Int): Int {
            while (current == null || current!!.available() == 0) {
                current = ByteArrayInputStream(remaining.removeFirstOrNull() ?: return -1)
            }
            return current!!.read(target, offset, length)
        }
    }

    @Test
    fun `fixture is the version this test knows and has all 22 cases`() {
        assertEquals("oriveo.fixture.sse-framing/v1", fixture.schema)
        assertEquals(22, fixture.cases.size)
    }

    @Test
    fun `decoder yields the fixture frames and comment count under every chunking`() {
        var checked = 0
        val mismatches = mutableListOf<String>()
        for (case in fixture.cases) {
            for (chunking in case.chunkings) {
                val decoder = SseFrameDecoder()
                val frames = mutableListOf<SseFrame>()
                val sink: (SseItem) -> Unit = { if (it is SseItem.Frame) frames += it.frame }
                for (chunk in cut(Base64.getDecoder().decode(case.bytes_base64), chunking)) {
                    decoder.push(chunk, sink = sink)
                }
                decoder.finish(sink)
                val label = "${case.id} · ${chunking.name}"
                if (case.expect.frames != frames.map { Frame(it.event, it.data, it.id, it.retry) }) mismatches += label
                if (case.expect.comments != decoder.comments) mismatches += "$label comments"
                checked += 1
            }
        }
        assertEquals(fixture.cases.sumOf { it.chunkings.size }, checked)
        assertEquals(emptyList<String>(), mismatches)
    }

    @Test
    fun `line reader hands every non-empty frame to the line loops as event and data lines`() {
        val mismatches = mutableListOf<String>()
        for (case in fixture.cases) {
            for (chunking in case.chunkings) {
                val reader = ChunkedInputStream(cut(Base64.getDecoder().decode(case.bytes_base64), chunking)).sseLineReader()
                val lines = generateSequence { reader.readLine() }
                    .filter { it.startsWith("event: ") || it.startsWith("data: ") }
                    .toList()
                val expected = case.expect.frames.filter { it.data.isNotEmpty() }.flatMap { frame ->
                    // A multi-line event whose joined data is not valid JSON is delivered line by line; none of the multi-line data in the fixture is JSON.
                    val dataLines = if (frame.data.contains('\n')) frame.data.split('\n').filter { it.isNotEmpty() } else listOf(frame.data)
                    listOfNotNull(frame.event?.let { "event: $it" }) + dataLines.map { "data: $it" }
                }
                if (expected != lines) mismatches += "${case.id} · ${chunking.name}"
            }
        }
        assertEquals(emptyList<String>(), mismatches)
    }

    @Test
    fun `production payload stream hands out the fixture payloads and assembles the chat text`() = runBlocking {
        var chatCases = 0
        for (case in fixture.cases) {
            val bytes = Base64.getDecoder().decode(case.bytes_base64)
            val client = HttpClient(
                MockEngine { respond(bytes, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "text/event-stream")) },
            )
            try {
                val payloads = SseParser.parseOpenAICompatiblePayloads(client.get("https://example.invalid/stream"), json).toList()
                // This production path stops at the end sentinel, skips empty payloads and trims each payload (it is JSON, so outer whitespace means nothing).
                val expected = case.expect.frames
                    .flatMap { frame -> if (frame.data.contains('\n')) frame.data.split('\n') else listOf(frame.data) }
                    .map { it.trim() }
                    .takeWhile { it != "[DONE]" }
                    .filter { it.isNotEmpty() }
                assertEquals(case.id, expected, payloads)
                case.openai_chat?.let { chat ->
                    chatCases += 1
                    val text = payloads.joinToString("") { payload ->
                        json.parseToJsonElement(payload).jsonObject["choices"]!!.jsonArray[0].jsonObject["delta"]!!
                            .jsonObject["content"]?.jsonPrimitive?.content.orEmpty()
                    }
                    assertEquals(case.id, chat.text, text)
                }
            } finally {
                client.close()
            }
        }
        assertEquals(7, chatCases)
    }

    @Test
    fun `mcp parser yields the fixture frames whose data is json`() {
        val mismatches = mutableListOf<String>()
        for (case in fixture.cases) {
            val expected = case.expect.frames.mapNotNull { ai.oriveo.community.core.mcp.McpJson.parseOrNull(it.data) }
            val actual = ai.oriveo.community.core.mcp.McpSse.messages(Base64.getDecoder().decode(case.bytes_base64))
            if (expected != actual) mismatches += case.id
        }
        assertEquals(emptyList<String>(), mismatches)
    }

    @Test
    fun `multi-line data that is one JSON document reaches the line loops as one payload`() {
        val body = "data: {\"choices\":[\ndata: {\"delta\":{\"content\":\"A\"}}\ndata: ]}\n\n"
        val reader = ByteArrayInputStream(body.toByteArray()).sseLineReader()
        val payloads = generateSequence { reader.readLine() }.filter { it.startsWith("data: ") }.toList()
        assertEquals(listOf("data: {\"choices\":[\n{\"delta\":{\"content\":\"A\"}}\n]}"), payloads)
    }

    @Test
    fun `json documents separated by a single newline are still delivered one per data line`() {
        val body = "data: {\"a\":1}\ndata: {\"b\":2}\ndata: [DONE]\n"
        val reader = ByteArrayInputStream(body.toByteArray()).sseLineReader()
        val payloads = generateSequence { reader.readLine() }.filter { it.startsWith("data: ") }.toList()
        assertEquals(listOf("data: {\"a\":1}", "data: {\"b\":2}", "data: [DONE]"), payloads)
    }

    @Test
    fun `event and data pairs without blank lines keep the event name of each data line`() {
        val body = "event: content_block_delta\ndata: {\"i\":1}\nevent: content_block_delta\ndata: {\"i\":2}\nevent: error\ndata: {\"i\":3}\n"
        val reader = ByteArrayInputStream(body.toByteArray()).sseLineReader()
        assertEquals(
            listOf(
                "event: content_block_delta", "data: {\"i\":1}",
                "event: content_block_delta", "data: {\"i\":2}",
                "event: error", "data: {\"i\":3}",
            ),
            generateSequence { reader.readLine() }.filter { it.isNotEmpty() }.toList(),
        )
    }

    @Test
    fun `lines that are not sse fields pass through unchanged`() {
        val body = ": keep-alive\n{\"error\":{\"message\":\"boom\"}}\nid: 3\n\nplain\n"
        val reader = ByteArrayInputStream(body.toByteArray()).sseLineReader()
        assertEquals(
            listOf(": keep-alive", "{\"error\":{\"message\":\"boom\"}}", "id: 3", "", "plain"),
            generateSequence { reader.readLine() }.toList(),
        )
    }
}
