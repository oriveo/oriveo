package ai.oriveo.community.core.voice

import ai.oriveo.community.core.model.ProviderKind
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.MockRequestHandleScope
import io.ktor.client.engine.mock.respond
import io.ktor.client.engine.mock.toByteArray
import io.ktor.client.request.HttpRequestData
import io.ktor.client.request.HttpResponseData
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import java.io.File
import java.nio.ByteBuffer
import java.util.Base64
import kotlin.math.abs
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class CloudSTTEngineTest {

    @get:Rule
    val tmp = TemporaryFolder()

    /** Entries decoded from the real catalog fixture; path / languageField both come from production decoding. */
    private val catalog: VoiceCatalog = VoiceCatalogDecoder.decode(
        Json.parseToJsonElement(workspaceFile("shared/model-contracts/voice_catalog_contract.v2.json").readText())
            .jsonObject["data"],
    )
    private val openAIEntry = catalog.entry(ProviderKind.OpenAI, VoiceDirection.Stt, "gpt-transcribe") as VoiceSttEntry
    private val grokEntry = catalog.provider(ProviderKind.Grok).stt.single { it.transport == VoiceTransport.XaiStt }

    private val requests = mutableListOf<HttpRequestData>()
    private val bodies = mutableListOf<ByteArray>()
    private val sleeps = mutableListOf<Long>()

    private val slotAac: File by lazy {
        File("src/test/resources/voice/sine-silence-16k.aac").copyTo(tmp.root.resolve("slot/rec.aac"))
    }
    private val cacheDir: File by lazy { tmp.root.resolve("cache") }

    private fun engine(
        entry: VoiceSttEntry = openAIEntry,
        baseUrl: String = "https://api.openai.com/v1/",
        responses: List<MockRequestHandleScope.() -> HttpResponseData>,
    ): CloudSTTEngine {
        val mock = MockEngine { request ->
            requests += request
            bodies += request.body.toByteArray()
            responses[requests.size - 1]()
        }
        return CloudSTTEngine(HttpClient(mock), entry, baseUrl, "sk-test", cacheDir, sleeper = { sleeps += it })
    }

    private fun ok(text: String): MockRequestHandleScope.() -> HttpResponseData = {
        respond(
            content = """{"text":"$text"}""",
            status = HttpStatusCode.OK,
            headers = headersOf(HttpHeaders.ContentType, "application/json"),
        )
    }

    private fun status(code: Int, retryAfter: String? = null): MockRequestHandleScope.() -> HttpResponseData = {
        respond(
            content = """{"error":{"message":"x"}}""",
            status = HttpStatusCode.fromValue(code),
            headers = if (retryAfter != null) headersOf(HttpHeaders.RetryAfter, retryAfter) else headersOf(),
        )
    }

    @Test
    fun `openai transcriptions uploads m4a multipart to origin plus entry path`() = runTest {
        val result = engine(responses = listOf(ok("  hello world  ")))
            .transcribe(STTSegment(slotAac), "zh-Hans")

        assertEquals(STTResult.Success("hello world"), result)
        assertUpload(expectedUrl = "https://api.openai.com/v1/audio/transcriptions", model = "gpt-transcribe")
    }

    @Test
    fun `xai stt uploads m4a multipart to origin plus entry path`() = runTest {
        val result = engine(entry = grokEntry, baseUrl = "https://api.x.ai/v1", responses = listOf(ok("hi")))
            .transcribe(STTSegment(slotAac), "zh-Hans")

        assertEquals(STTResult.Success("hi"), result)
        assertUpload(expectedUrl = "https://api.x.ai/v1/stt", model = "grok-voice-transcribe-2.0")
    }

    @Test
    fun `gemini transcribe sends goog key and parses steps`() = runTest {
        val gemini = catalog.entry(ProviderKind.Gemini, VoiceDirection.Stt, "gemini-3.5-transcribe") as VoiceSttEntry
        val steps = """{"steps":[{"type":"model_output","content":[{"type":"text","text":" Hello"},""" +
            """{"type":"text","text":" world. "}]},{"type":"model_output","content":[{"type":"text","text":"Again."}]}]}"""
        val result = engine(entry = gemini, baseUrl = "https://generativelanguage.googleapis.com/v1beta", responses = listOf(json(steps)))
            .transcribe(STTSegment(slotAac), "zh-Hans")

        assertEquals(STTResult.Success("Hello world. Again."), result)
        val request = requests.single()
        assertEquals("https://generativelanguage.googleapis.com/v1beta/interactions", request.url.toString())
        assertEquals("sk-test", request.headers["x-goog-api-key"])
        assertEquals(null, request.headers[HttpHeaders.Authorization])
        assertEquals("application/json", request.body.contentType?.withoutParameters()?.toString())
        val body = Json.parseToJsonElement(String(bodies.single(), Charsets.UTF_8)).jsonObject
        assertEquals(setOf("model", "store", "input"), body.keys)
        assertEquals("gemini-3.5-transcribe", body["model"]!!.jsonPrimitive.content)
        assertEquals("false", body["store"]!!.jsonPrimitive.content)
        val audio = body["input"]!!.jsonArray.single().jsonObject
        assertEquals("audio", audio["type"]!!.jsonPrimitive.content)
        assertEquals("audio/m4a", audio["mime_type"]!!.jsonPrimitive.content)
        val m4a = Base64.getDecoder().decode(audio["data"]!!.jsonPrimitive.content)
        assertEquals("ftyp", String(m4a, 4, 4, Charsets.US_ASCII))
        assertCleanedUp()
    }

    @Test
    fun `gemini transcribe empty text is invalid`() = runTest {
        val gemini = catalog.entry(ProviderKind.Gemini, VoiceDirection.Stt, "gemini-3.5-transcribe") as VoiceSttEntry
        val steps = """{"steps":[{"type":"model_output","content":[{"type":"text","text":"  "}]}]}"""
        val result = engine(entry = gemini, baseUrl = "https://generativelanguage.googleapis.com/v1beta", responses = listOf(json(steps)))
            .transcribe(STTSegment(slotAac), "zh-Hans")

        assertEquals(DictationFailure.InvalidResponse, (result as STTResult.Failed).failure)
        assertEquals(1, requests.size)
        // Production code does not set Accept, so only the `*/*` added by Ktor's default transformation goes on the wire.
        assertEquals(listOf("*/*"), requests.single().headers.getAll(HttpHeaders.Accept))
        assertCleanedUp()
    }

    @Test
    fun `dashscope asr parses output text`() = runTest {
        val dashscope = VoiceSttEntry(
            model = "qwen3-asr-flash",
            transport = VoiceTransport.DashscopeAsr,
            path = "/api/v1/services/aigc/multimodal-generation/generation",
            maxBytes = 10_000_000,
            maxDurationSec = 300,
            languageField = "language_hints",
        )
        val result = engine(
            entry = dashscope,
            baseUrl = "https://dashscope.aliyuncs.com/compatible-mode/v1",
            responses = listOf(json("""{"output":{"text":" \u4f60\u597d\uff0c\u4e16\u754c\u3002 ","finish_reason":"stop"},"request_id":"r"}""")),
        ).transcribe(STTSegment(slotAac), "zh_Hans")

        assertEquals(STTResult.Success("\u4f60\u597d\uff0c\u4e16\u754c\u3002"), result)
        val request = requests.single()
        assertEquals(
            "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation",
            request.url.toString(),
        )
        assertEquals("Bearer sk-test", request.headers[HttpHeaders.Authorization])
        val body = Json.parseToJsonElement(String(bodies.single(), Charsets.UTF_8)).jsonObject
        assertEquals("qwen3-asr-flash", body["model"]!!.jsonPrimitive.content)
        val parameters = body["parameters"]!!.jsonObject
        assertEquals("m4a", parameters["format"]!!.jsonPrimitive.content)
        assertEquals(listOf("zh"), parameters["language_hints"]!!.jsonArray.map { it.jsonPrimitive.content })
        val data = body["input"]!!.jsonObject["messages"]!!.jsonArray.single().jsonObject["content"]!!.jsonArray
            .single().jsonObject["input_audio"]!!.jsonObject["data"]!!.jsonPrimitive.content
        assertTrue(data.startsWith("data:audio/mp4;base64,"))
        val m4a = Base64.getDecoder().decode(data.removePrefix("data:audio/mp4;base64,"))
        assertEquals("ftyp", String(m4a, 4, 4, Charsets.US_ASCII))
        assertCleanedUp()
    }

    private fun json(content: String): MockRequestHandleScope.() -> HttpResponseData = {
        respond(
            content = content,
            status = HttpStatusCode.OK,
            headers = headersOf(HttpHeaders.ContentType, "application/json"),
        )
    }

    @Test
    fun `503 then 200 retries once after default delay`() = runTest {
        val result = engine(responses = listOf(status(503), ok("again"))).transcribe(STTSegment(slotAac), null)

        assertEquals(STTResult.Success("again"), result)
        assertEquals(2, requests.size)
        assertEquals(listOf(1000L), sleeps)
        // The boundary is random per request, so only the file parts of the two requests are compared: the same m4a is resent.
        val files = requests.indices.map { index ->
            val boundary = requireNotNull(requests[index].body.contentType?.parameter("boundary"))
            parseMultipart(bodies[index], boundary).single { it.name == "file" }.content
        }
        assertArrayEquals(files[0], files[1])
        assertCleanedUp()
    }

    @Test
    fun `401 fails once with check connection`() = runTest {
        val result = engine(responses = listOf(status(401))).transcribe(STTSegment(slotAac), null)

        assertEquals(STTResult.Failed(DictationFailure.Http(401), DictationPrimaryAction.CheckConnection), result)
        assertEquals(1, requests.size)
        assertEquals(emptyList<Long>(), sleeps)
        assertCleanedUp()
    }

    @Test
    fun `5xx retried then failed reports autoRetried`() = runTest {
        val result = engine(responses = listOf(status(503), status(502))).transcribe(STTSegment(slotAac), null)

        assertEquals(
            STTResult.Failed(DictationFailure.Http(502), DictationPrimaryAction.Retry, autoRetried = true),
            result,
        )
        assertEquals(2, requests.size)
        assertEquals(listOf(1000L), sleeps)
        assertCleanedUp()
    }

    @Test
    fun `first 401 reports not autoRetried`() = runTest {
        val result = engine(responses = listOf(status(401))).transcribe(STTSegment(slotAac), null)

        assertEquals(false, (result as STTResult.Failed).autoRetried)
        assertEquals(1, requests.size)
    }

    @Test
    fun `400 fails once with retry`() = runTest {
        val result = engine(responses = listOf(status(400))).transcribe(STTSegment(slotAac), null)

        assertEquals(STTResult.Failed(DictationFailure.Http(400), DictationPrimaryAction.Retry), result)
        assertEquals(1, requests.size)
        assertEquals(emptyList<Long>(), sleeps)
    }

    @Test
    fun `retry after above ten seconds is not retried automatically`() = runTest {
        val result = engine(responses = listOf(status(503, retryAfter = "11"))).transcribe(STTSegment(slotAac), null)

        assertEquals(STTResult.Failed(DictationFailure.Http(503, "11"), DictationPrimaryAction.Retry), result)
        assertEquals(1, requests.size)
        assertEquals(emptyList<Long>(), sleeps)
    }

    // ---- Over-limit segmentation ----

    /** The fixture recording lasts 3.036 s (49 frames * 1024 / 16000 - 1600 / 16000); maxDurationSec = 1 means Lmax = 1 s. */
    private val shortEntry = openAIEntry.copy(maxDurationSec = 1)

    /** 61 windows; windows 14..21 silent gives [0.70, 1.10] with midpoint 0.9, windows 30..38 silent gives [1.50, 1.95] with midpoint 1.725. */
    private val envelope: List<Double?> = List(61) { index ->
        if (index in 14..21 || index in 30..38) null else -20.0
    }

    /** [0, 0.9] cuts at silence; within [1.4, 1.9] it takes 1.725; [2.225, 2.725] has no silence so it hard-cuts at 2.725; the remaining 0.311 s becomes the last segment. */
    private val expectedCuts = listOf(0.0 to 0.9, 0.9 to 1.725, 1.725 to 2.725, 2.725 to 3.036)

    @Test
    fun `over max duration uploads segments in order cut at silence and joins texts`() = runTest {
        val result = engine(entry = shortEntry, responses = listOf(ok("one"), ok(" two "), ok("three"), ok("four")))
            .transcribe(STTSegment(slotAac, envelope = envelope), "zh-Hans")

        assertEquals(STTResult.Success("one two three four"), result)
        assertEquals(4, requests.size)
        assertTrue(requests.all { it.url.toString() == "https://api.openai.com/v1/audio/transcriptions" })
        uploadedFiles().forEachIndexed { index, file -> assertSegmentAudio(file, expectedCuts[index]) }
        assertCleanedUp()
    }

    @Test
    fun `segment with blank transcript is dropped from join`() = runTest {
        val result = engine(entry = shortEntry, responses = listOf(ok("one"), ok("  "), ok("three"), ok("four")))
            .transcribe(STTSegment(slotAac, envelope = envelope), null)

        assertEquals(STTResult.Success("one three four"), result)
        assertEquals(4, requests.size)
    }

    @Test
    fun `permanent failure on a segment fails whole dictation and stops later segments`() = runTest {
        val result = engine(entry = shortEntry, responses = listOf(ok("one"), status(400)))
            .transcribe(STTSegment(slotAac, envelope = envelope), null)

        assertEquals(STTResult.Failed(DictationFailure.Http(400), DictationPrimaryAction.Retry), result)
        assertEquals(2, requests.size)
        assertEquals(emptyList<Long>(), sleeps)
        assertCleanedUp()
    }

    @Test
    fun `auto retry is counted per segment`() = runTest {
        val responses = listOf(status(503), ok("one"), status(503), ok("two"), ok("three"), ok("four"))
        val result = engine(entry = shortEntry, responses = responses)
            .transcribe(STTSegment(slotAac, envelope = envelope), null)

        assertEquals(STTResult.Success("one two three four"), result)
        assertEquals(6, requests.size)
        assertEquals(listOf(1000L, 1000L), sleeps)
        val files = uploadedFiles()
        assertArrayEquals(files[0], files[1])
        assertArrayEquals(files[2], files[3])
        assertCleanedUp()
    }

    @Test
    fun `empty envelope hard cuts at max duration`() = runTest {
        val result = engine(entry = shortEntry, responses = listOf(ok("a"), ok("b"), ok("c"), ok("d")))
            .transcribe(STTSegment(slotAac), null)

        assertEquals(STTResult.Success("a b c d"), result)
        val cuts = listOf(0.0 to 1.0, 1.0 to 2.0, 2.0 to 3.0, 3.0 to 3.036)
        uploadedFiles().forEachIndexed { index, file -> assertSegmentAudio(file, cuts[index]) }
    }

    // ---- Invalid endpoint and remux failure ----

    @Test
    fun `unresolvable base url does not throw on construction and fails with check connection`() = runTest {
        for (baseUrl in listOf("", "not a url", "api.openai.com")) {
            val result = engine(baseUrl = baseUrl, responses = emptyList()).transcribe(STTSegment(slotAac), null)

            assertEquals(baseUrl, STTResult.Failed(DictationFailure.InvalidEndpoint, DictationPrimaryAction.CheckConnection), result)
        }
        assertEquals(0, requests.size)
        assertEquals(emptyList<Long>(), sleeps)
    }

    @Test
    fun `export failure fails with retry without request or auto retry`() = runTest {
        val broken = tmp.root.resolve("slot/broken.aac").apply {
            parentFile?.mkdirs()
            writeBytes(ByteArray(64) { 0x11 })
        }
        val result = engine(responses = listOf(ok("never"))).transcribe(STTSegment(broken), null)

        assertEquals(STTResult.Failed(DictationFailure.ExportFailed, DictationPrimaryAction.Retry), result)
        assertEquals(0, requests.size)
        assertEquals(emptyList<Long>(), sleeps)
        assertCleanedUp()
    }

    private fun uploadedFiles(): List<ByteArray> = requests.indices.map { index ->
        val boundary = requireNotNull(requests[index].body.contentType?.parameter("boundary"))
        parseMultipart(bodies[index], boundary).single { it.name == "file" }.content
    }

    /**
     * The segment m4a's samples must be a contiguous run of frames from the fixture, with start and end each within 1 frame of the cut points (recording time + 0.1 s priming = file time).
     */
    private fun assertSegmentAudio(m4a: ByteArray, cut: Pair<Double, Double>) {
        assertEquals("ftyp", String(m4a, 4, 4, Charsets.US_ASCII))
        val sizes = stszEntries(findBox(topLevelBoxes(m4a).getValue("moov"), "stsz"))
        val startSec = cut.first + PRIMING_SEC
        val endSec = cut.second + PRIMING_SEC
        val matched = fixtureFrames.indices.any { first ->
            val last = first + sizes.size
            last <= fixtureFrames.size &&
                abs(first * FRAME_SEC - startSec) < FRAME_SEC &&
                abs(last * FRAME_SEC - endSec) < FRAME_SEC &&
                fixtureFrames.subList(first, last).map { it.payload.size } == sizes
        }
        if (!matched) fail("segment $cut: ${sizes.size} frames do not line up with cut within one frame")
    }

    private val fixtureFrames: List<AdtsFrame> by lazy {
        AdtsFormat.parse(File("src/test/resources/voice/sine-silence-16k.aac").readBytes()).frames
    }

    private fun topLevelBoxes(bytes: ByteArray): Map<String, ByteArray> {
        val boxes = linkedMapOf<String, ByteArray>()
        val buf = ByteBuffer.wrap(bytes)
        var pos = 0
        while (pos + 8 <= bytes.size) {
            var size = buf.getInt(pos).toLong() and 0xFFFFFFFFL
            var header = 8
            if (size == 1L) {
                size = buf.getLong(pos + 8)
                header = 16
            } else if (size == 0L) {
                size = (bytes.size - pos).toLong()
            }
            val type = String(bytes, pos + 4, 4, Charsets.US_ASCII)
            boxes.putIfAbsent(type, bytes.copyOfRange(pos + header, (pos + size).toInt()))
            pos += size.toInt()
        }
        return boxes
    }

    private fun findBox(container: ByteArray, type: String): ByteArray {
        val fourcc = type.toByteArray(Charsets.US_ASCII)
        for (i in 4..container.size - 4) {
            if (container.copyOfRange(i, i + 4).contentEquals(fourcc)) {
                val size = ByteBuffer.wrap(container).getInt(i - 4)
                return container.copyOfRange(i + 4, i - 4 + size)
            }
        }
        throw AssertionError("box $type not found")
    }

    private fun stszEntries(stsz: ByteArray): List<Int> {
        val buf = ByteBuffer.wrap(stsz)
        val sampleSize = buf.getInt(4)
        val count = buf.getInt(8)
        return if (sampleSize != 0) List(count) { sampleSize } else List(count) { buf.getInt(12 + it * 4) }
    }

    private fun assertUpload(expectedUrl: String, model: String) {
        assertEquals(1, requests.size)
        val request = requests.single()
        assertEquals("POST", request.method.value)
        assertEquals(expectedUrl, request.url.toString())
        assertEquals("Bearer sk-test", request.headers[HttpHeaders.Authorization])

        val boundary = requireNotNull(request.body.contentType?.parameter("boundary")) { "no multipart boundary" }
        val parts = parseMultipart(bodies.single(), boundary)
        assertEquals(listOf("model", "language", "file"), parts.map { it.name })
        assertEquals(model, parts[0].text)
        assertEquals("zh", parts[1].text)

        val file = parts[2]
        assertEquals("audio.m4a", file.filename)
        assertEquals("audio/mp4", file.contentType)
        assertEquals("ftyp", String(file.content, 4, 4, Charsets.US_ASCII))
        assertCleanedUp()
    }

    /** The temporary m4a is deleted after use, and the slot's .aac is left as-is. */
    private fun assertCleanedUp() {
        assertEquals(emptyList<String>(), cacheDir.listFiles().orEmpty().map { it.name })
        assertTrue(slotAac.exists())
        assertArrayEquals(File("src/test/resources/voice/sine-silence-16k.aac").readBytes(), slotAac.readBytes())
    }

    private class Part(val headers: Map<String, String>, val content: ByteArray) {
        private val disposition = headers["content-disposition"].orEmpty()
        val name: String? = Regex("(?<![a-z])name=\"?([^\";]+)\"?").find(disposition)?.groupValues?.get(1)
        val filename: String? = Regex("filename=\"?([^\";]+)\"?").find(disposition)?.groupValues?.get(1)
        val contentType: String? = headers["content-type"]
        val text: String get() = String(content, Charsets.UTF_8)
    }

    /** Splits one byte per character as ISO-8859-1, restoring the file part's bytes exactly. */
    private fun parseMultipart(body: ByteArray, boundary: String): List<Part> {
        val raw = String(body, Charsets.ISO_8859_1)
        return raw.split("--$boundary")
            .drop(1)
            .filterNot { it.startsWith("--") }
            .map { chunk ->
                val section = chunk.removePrefix("\r\n").removeSuffix("\r\n")
                val split = section.indexOf("\r\n\r\n")
                val headers = section.substring(0, split).split("\r\n").associate { line ->
                    line.substringBefore(':').trim().lowercase() to line.substringAfter(':').trim()
                }
                Part(headers, section.substring(split + 4).toByteArray(Charsets.ISO_8859_1))
            }
    }

    private fun workspaceFile(relative: String): File {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.exists()) return candidate
            dir = dir.parentFile
        }
        throw IllegalStateException("cannot find $relative")
    }

    private companion object {
        const val FRAME_SEC = 1024.0 / 16000
        const val PRIMING_SEC = 1600.0 / 16000
    }
}
