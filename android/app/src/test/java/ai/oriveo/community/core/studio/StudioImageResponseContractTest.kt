package ai.oriveo.community.core.studio

import ai.oriveo.community.core.studio.StudioImageResponse.Delivery
import ai.oriveo.community.core.studio.StudioImageResponse.Failure
import ai.oriveo.community.core.studio.StudioImageResponse.Image
import ai.oriveo.community.core.studio.StudioImageResponse.Kind
import ai.oriveo.community.core.studio.StudioImageResponse.Outcome
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import java.util.Base64
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Runs the client groups of the shared image_response_samples.v1 fixture: response parsing,
 * usage / declared size, header decoding, materializing and per-image assembly.
 */
class StudioImageResponseContractTest {
    private val dir: Path by lazy {
        generateSequence(Paths.get("").toAbsolutePath().normalize()) { it.parent }
            .take(8)
            .map { it.resolve("\u5171\u4eab/model-contracts/image_response_samples.v1") }
            .firstOrNull { Files.exists(it.resolve("index.json")) }
            ?: error("image_response_samples.v1 not found")
    }

    private fun read(name: String): JsonElement = Json.parseToJsonElement(dir.resolve(name).toFile().readText())

    private val fixture: JsonObject by lazy { read("index.json").jsonObject }

    private fun group(key: String): List<JsonObject> = fixture.getValue(key).jsonArray.map { it.jsonObject }

    private fun JsonObject.str(key: String): String = getValue(key).jsonPrimitive.content
    private fun JsonObject.strOrNull(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull
    private fun JsonObject.strings(key: String): List<String> = getValue(key).jsonArray.map { it.jsonPrimitive.content }

    private fun Image.kindAndMime(): Map<String, String?> = mapOf("kind" to kind.wire, "mime" to mime)
    private fun Image.full(): Map<String, String?> =
        mapOf("kind" to kind.wire, "mime" to mime, "value" to value, "revisedPrompt" to revisedPrompt)

    private fun JsonObject.kindAndMime(): Map<String, String?> = mapOf("kind" to str("kind"), "mime" to strOrNull("mime"))
    private fun JsonObject.full(): Map<String, String?> = mapOf(
        "kind" to str("kind"),
        "mime" to strOrNull("mime"),
        "value" to str("value"),
        "revisedPrompt" to strOrNull("revisedPrompt"),
    )

    private fun okOutcome(): Outcome = Outcome.Ok(StudioImageResponse.DeliveredImage(ByteArray(1), "image/png", 1, 1))

    private fun outcomeOf(wire: String): Outcome =
        if (wire == "ok") okOutcome() else Outcome.Failed(Failure.entries.single { it.wire == wire })

    private val noFetch: suspend (String) -> Outcome = { error("fetch must not be called for inline images") }

    @Test
    fun realSamples() {
        assertEquals("image_response_samples.v1", fixture.str("contractId"))
        val samples = group("samples")
        assertTrue("fixture group must not be empty", samples.isNotEmpty())
        for (sample in samples) {
            val file = sample.str("file")
            val expect = sample.getValue("expect").jsonObject
            val parsed = StudioImageResponse.parse(read(file).jsonObject["response"])
            assertEquals(file, expect.strings("shapes"), parsed.shapes)
            assertEquals(file, expect.strings("deduped"), parsed.deduped)
            assertEquals(
                file,
                expect.getValue("images").jsonArray.map { it.jsonObject.kindAndMime() },
                parsed.images.map { it.kindAndMime() },
            )
            val assembly = StudioImageResponse.assemble(sample.getValue("nRequested").jsonPrimitive.int, parsed.images.map { okOutcome() })
            if (expect.str("result") == "ok") {
                assertEquals(file, Delivery.Ok, assembly.result)
            } else {
                assertNull(file, assembly.result)
            }
        }
    }

    @Test
    fun parserCases() {
        val cases = group("parserCases")
        assertTrue("fixture group must not be empty", cases.isNotEmpty())
        for (case in cases) {
            val name = case.str("name")
            val expect = case.getValue("expect").jsonObject
            val parsed = StudioImageResponse.parse(case.getValue("body"))
            assertEquals(name, expect.strings("shapes"), parsed.shapes)
            assertEquals(name, expect.strings("deduped"), parsed.deduped)
            assertEquals(name, expect.getValue("images").jsonArray.map { it.jsonObject.full() }, parsed.images.map { it.full() })
        }
        // A Kotlin null body (missing response) parses like a JSON null.
        val missing = StudioImageResponse.parse(null)
        assertTrue(missing.images.isEmpty())
        assertNull(missing.usage)
        assertNull(missing.declaredSize)
    }

    @Test
    fun metaExpect() {
        val cases = group("metaExpect")
        assertEquals("metaExpect must cover every real sample", group("samples").size, cases.size)
        for (case in cases) {
            val file = case.str("file")
            val parsed = StudioImageResponse.parse(read(file).jsonObject["response"])
            assertMeta(file, case, parsed)
        }
        // Only whole JSON numbers count: strings and fractions are skipped.
        val loose = StudioImageResponse.parse(
            Json.parseToJsonElement(
                """{"size":"wide","usage":{"input_tokens":"7","prompt_tokens":3.5,"output_tokens":0,"completion_tokens":0,"total_tokens":9,"width":640,"height":480}}""",
            ),
        )
        assertEquals(StudioImageResponse.Usage(inputTokens = null, outputTokens = 0, totalTokens = 9), loose.usage)
        assertEquals(StudioImageResponse.Size(640, 480), loose.declaredSize)
    }

    private fun assertMeta(name: String, case: JsonObject, parsed: StudioImageResponse.Parsed) {
        val usage = case["usage"] as? JsonObject
        val expectedUsage = usage?.let {
            StudioImageResponse.Usage(
                inputTokens = (it["inputTokens"] as? JsonPrimitive)?.longOrNull,
                outputTokens = (it["outputTokens"] as? JsonPrimitive)?.longOrNull,
                totalTokens = (it["totalTokens"] as? JsonPrimitive)?.longOrNull,
            )
        }
        assertEquals(name, expectedUsage, parsed.usage)
        val size = case["declaredSize"] as? JsonObject
        val expectedSize = size?.let {
            StudioImageResponse.Size(it.getValue("width").jsonPrimitive.int, it.getValue("height").jsonPrimitive.int)
        }
        assertEquals(name, expectedSize, parsed.declaredSize)
    }

    @Test
    fun metaCases() {
        val cases = group("metaCases")
        assertTrue("fixture group must not be empty", cases.isNotEmpty())
        for (case in cases) {
            val name = case.str("name")
            assertMeta(name, case, StudioImageResponse.parse(case.getValue("body")))
        }
        // Integral numbers count whatever their JSON spelling.
        val spelled = StudioImageResponse.parse(
            Json.parseToJsonElement("""{"usage":{"input_tokens":14.0,"output_tokens":1e3,"total_tokens":1.5,"width":512.0,"height":768}}"""),
        )
        assertEquals(StudioImageResponse.Usage(inputTokens = 14, outputTokens = 1000, totalTokens = null), spelled.usage)
        assertEquals(StudioImageResponse.Size(512, 768), spelled.declaredSize)
    }

    @Test
    fun materializeCases() = runBlocking {
        val cases = group("materializeCases")
        assertTrue("fixture group must not be empty", cases.isNotEmpty())
        for (case in cases) {
            val name = case.str("name")
            val spec = case.getValue("image").jsonObject
            val image = Image(Kind.entries.single { it.wire == spec.str("kind") }, spec.strOrNull("mime"), spec.str("value"), null)
            val expect = case.getValue("expect").jsonObject
            val outcome = StudioImageResponse.materialize(image, noFetch)
            if (expect.getValue("ok").jsonPrimitive.content == "true") {
                val delivered = (outcome as? Outcome.Ok)?.image ?: error("$name: expected ok, got $outcome")
                assertEquals(
                    name,
                    StudioImageResponse.ImageInfo(expect.str("mime"), expect.getValue("width").jsonPrimitive.int, expect.getValue("height").jsonPrimitive.int),
                    StudioImageResponse.ImageInfo(delivered.mime, delivered.width, delivered.height),
                )
            } else {
                assertEquals(name, Outcome.Failed(Failure.entries.single { it.wire == expect.str("failure") }), outcome)
            }
        }
    }

    @Test
    fun decodeCases() = runBlocking {
        val cases = group("decodeCases")
        assertTrue("fixture group must not be empty", cases.isNotEmpty())
        for (case in cases) {
            val name = case.str("name")
            val b64 = case.str("b64")
            val bytes = Base64.getDecoder().decode(b64)
            val expect = case["expect"] as? JsonObject
            val expected = expect?.let { StudioImageResponse.ImageInfo(it.str("mime"), it.getValue("width").jsonPrimitive.int, it.getValue("height").jsonPrimitive.int) }
            assertEquals(name, expected, StudioImageResponse.decodeImageInfo(bytes))

            // materialize runs the same decode for both inline kinds.
            val inline = listOf(
                Image(Kind.B64, null, b64, null),
                Image(Kind.DATA_URL, "image/png", "data:image/png;base64,$b64", null),
            )
            for (image in inline) {
                val outcome = StudioImageResponse.materialize(image, noFetch)
                if (expected == null) {
                    assertEquals("$name ${image.kind}", Outcome.Failed(Failure.DECODE_FAILED), outcome)
                } else {
                    val delivered = (outcome as Outcome.Ok).image
                    assertEquals("$name ${image.kind}", expected, StudioImageResponse.ImageInfo(delivered.mime, delivered.width, delivered.height))
                    assertTrue(name, bytes.contentEquals(delivered.bytes))
                }
            }
        }
        val badBase64 = StudioImageResponse.materialize(Image(Kind.B64, null, "not*base64", null), noFetch)
        assertEquals(Outcome.Failed(Failure.DECODE_FAILED), badBase64)
        val notBase64DataUrl = StudioImageResponse.materialize(Image(Kind.DATA_URL, null, "data:image/png,plain", null), noFetch)
        assertEquals(Outcome.Failed(Failure.DECODE_FAILED), notBase64DataUrl)

        // URL images are handed to the fetcher untouched.
        var fetched: String? = null
        val timeout = StudioImageResponse.materialize(Image(Kind.URL, null, "https://cdn.example/a.png", null)) {
            fetched = it
            Outcome.Failed(Failure.TIMEOUT)
        }
        assertEquals("https://cdn.example/a.png", fetched)
        assertEquals(Outcome.Failed(Failure.TIMEOUT), timeout)
    }

    @Test
    fun assembleCases() {
        val cases = group("assembleCases")
        assertTrue("fixture group must not be empty", cases.isNotEmpty())
        for (case in cases) {
            val name = case.str("name")
            val expect = case.getValue("expect").jsonObject
            val assembly = StudioImageResponse.assemble(
                case.getValue("nRequested").jsonPrimitive.int,
                case.strings("outcomes").map(::outcomeOf),
            )
            assertEquals(name, expect.strOrNull("result"), assembly.result?.wire)
            assertEquals(name, expect.getValue("delivered").jsonPrimitive.int, assembly.delivered)
            assertEquals(name, expect.strings("failures"), assembly.failures.map { it.wire })
        }
    }
}
