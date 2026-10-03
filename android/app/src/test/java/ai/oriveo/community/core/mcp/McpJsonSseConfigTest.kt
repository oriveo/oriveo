package ai.oriveo.community.core.mcp

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Resource limits of JSON parsing, the incremental SSE parser and runtime config clamping.
 */
class McpJsonSseConfigTest {

    // ── JSON: out-of-range numbers do not crash ────────────────────────────────────────

    @Test
    fun `longOrNull is total over hostile numbers`() {
        val cases = listOf(
            "1e30" to null, "-1e30" to null, "9223372036854775808" to null, "1.5" to null, "-0.25" to null,
            "\"7\"" to null, "null" to null, "0" to 0L, "-32022" to -32022L, "3" to 3L, "3.0" to 3L, "1e3" to 1000L,
        )
        for ((text, expected) in cases) assertEquals(text, expected, McpJson.parse(text).longOrNull)
    }

    @Test
    fun `non-finite numbers are rejected`() {
        for (text in listOf("""{"id":1e999}""", "-1e999")) {
            try {
                McpJson.parse(text)
                fail(text)
            } catch (expected: McpJsonException) {
            }
        }
    }

    @Test
    fun `nesting at the limit parses and beyond fails`() {
        val depth = McpJson.MAX_NESTING_DEPTH
        var value: JsonElement? = McpJson.parse("[".repeat(depth) + "]".repeat(depth))
        var seen = 0
        while (value is JsonArray) {
            seen += 1
            value = value.firstOrNull()
        }
        assertEquals(depth, seen)

        val over = depth + 1
        for (text in listOf(
            "[".repeat(over) + "]".repeat(over),
            """{"a":""".repeat(over) + "1" + "}".repeat(over),
            """[{"a":""".repeat(over) + "1" + "}]".repeat(over),
            "[".repeat(100_000),
        )) {
            assertNull(text.take(20), McpJson.parseOrNull(text))
        }
    }

    @Test
    fun `sibling containers do not accumulate depth`() {
        val item = "[".repeat(10) + "]".repeat(10)
        val text = "[" + List(200) { item }.joinToString(",") + "]"
        assertEquals(200, (McpJson.parse(text) as JsonArray).size)
    }

    @Test
    fun `canonical escaping follows the contract and repairs lone surrogates`() {
        assertEquals("\"a\\u000ab\\\"c\\\\\"", McpJson.encodeString("a\nb\"c\\"))
        assertEquals("\"😀é\"", McpJson.canonical(McpJson.parse("\"\\ud83d\\ude00é\"")))
        assertEquals("\"\uFFFDx\"", McpJson.canonical(McpJson.parse("\"\\ud83dx\"")))
        assertEquals(McpJson.canonical(McpJson.parse("""{"text":"\ud83d\ude00"}""")), McpJson.canonical(McpJson.parse("{\"text\":\"😀\"}")))
        assertEquals("""{"a":1,"b":[2,{"c":3,"d":4}]}""", McpJson.canonical(McpJson.parse("""{"b":[2,{"d":4,"c":3}],"a":1}""")))
        assertEquals("""{"b":1,"a":2}""", McpJson.ordered(McpJson.parse("""{"b":1,"a":2}""")))
        assertEquals("22.5", McpJson.encodeNumber(22.5))
        assertEquals("72", McpJson.encodeNumber(72.0))
        assertEquals("1e+30", McpJson.encodeNumber(1e30))
        assertEquals("1e-7", McpJson.encodeNumber(1e-7))
    }

    // ── SSE ─────────────────────────────────────────────

    private fun texts(messages: List<JsonElement>) = messages.map { it["v"].stringOrNull ?: McpJson.ordered(it) }

    private fun parse(text: String) = McpSse.messages(text.toByteArray(Charsets.UTF_8))

    @Test
    fun `three line endings parse identically`() {
        for (newline in listOf("\n", "\r\n", "\r")) {
            val stream = listOf("event: message", """data: {"v":"one"}""", "", ": comment", """data: {"v":"two"}""", "")
                .joinToString(newline) + newline
            assertEquals(newline, listOf("one", "two"), texts(parse(stream)))
        }
    }

    @Test
    fun `bom multiline data and missing trailing blank line`() {
        val bom = byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte()) + "data: {\"v\":\"one\"}\n\n".toByteArray()
        assertEquals(listOf("one"), texts(McpSse.messages(bom)))
        assertEquals(listOf("joined"), texts(parse("data: {\"v\":\ndata: \"joined\"}\n\n")))
        val pretty = parse("data: {\ndata:   \"v\": \"pretty\",\ndata:   \"n\": [1,\ndata:   2]\ndata: }\n\n").first()
        assertEquals("pretty", pretty["v"].stringOrNull)
        assertEquals(2, (pretty["n"] as JsonArray).size)
        assertEquals(listOf("one", "two"), texts(parse("data: {\"v\":\"one\"}\n\ndata: {\"v\":\"two\"}\n")))
        assertEquals(listOf("one", "two"), texts(parse("data: {\"v\":\"one\"}\n\ndata: {\"v\":\"two\"}")))
        assertEquals(listOf("tail"), texts(parse("data: {\"v\":\ndata: \"tail\"}")))
    }

    @Test
    fun `single-line event emits once at the end of the data line`() {
        val parser = McpSseParser()
        val emitted = mutableListOf<Pair<Int, JsonElement>>()
        val bytes = "data: {\"v\":\"one\"}\n\n".toByteArray()
        bytes.forEachIndexed { index, byte -> parser.consume(byte)?.let { emitted += index to it } }
        assertNull(parser.finish())
        assertEquals(1, emitted.size)
        assertEquals("emitted at the first line break", "data: {\"v\":\"one\"}".length, emitted.first().first)
    }

    @Test
    fun `invalid utf8 is repaired and malformed frames are skipped`() {
        val data = "data: {\"v\":\"a".toByteArray() + byteArrayOf(0xFF.toByte(), 0xFE.toByte()) +
            "b\"}\n\n".toByteArray() + "data: {\"v\":\"two\"}\n\n".toByteArray()
        assertEquals(listOf("a\uFFFD\uFFFDb", "two"), texts(McpSse.messages(data)))
        assertEquals(listOf("ok"), texts(parse("data: {not json}\n\ndata: {\"v\":\"ok\"}\n\n")))
    }

    @Test
    fun `field parsing rules`() {
        assertEquals(listOf("tight"), texts(parse("data:{\"v\":\"tight\"}\n\n")))
        assertEquals(listOf("spaces"), texts(parse("data:    {\"v\":\"spaces\"}\n\n")))
        assertTrue(parse("event: message\nid: 7\nretry: 1000\n: note\n\n").isEmpty())
        assertEquals(listOf("after-empty"), texts(parse("data\ndata: {\"v\":\"after-empty\"}\n\n")))
        assertTrue(parse("database: {\"v\":\"no\"}\n\n").isEmpty())
        assertTrue(parse("Data: {\"v\":\"no\"}\n\n").isEmpty())
        assertTrue(parse("").isEmpty())
        assertTrue(parse("\n\n\n").isEmpty())
        assertTrue(parse(": ping\n\n: ping\n\n").isEmpty())
    }

    @Test
    fun `fixture streams of both generations parse notification and final response under any newline`() {
        for (name in listOf("protocol/stateless/tools-call.sse.txt", "protocol/session/tools-call.sse.txt")) {
            val original = McpFixture.text(name)
            val messages = parse(original)
            assertEquals(name, 2, messages.size)
            assertEquals("notifications/message", messages.first()["method"].stringOrNull)
            assertEquals(3L, messages.last()["id"].longOrNull)
            assertTrue(messages.last()["result"]["content"].jsonArrayOrNull!!.first()["text"].stringOrNull!!.contains("72°F"))
            for (newline in listOf("\r\n", "\r")) {
                assertEquals(name + newline, messages, parse(original.replace("\n", newline)))
            }
        }
    }

    // ── Runtime config ────────────────────────────────────────

    private fun config(text: String) = McpRuntimeConfig.fromJson(McpJson.parse(text))

    @Test
    fun `fallback matches the built-in defaults and missing or non-object yields fallback`() {
        val fallback = McpRuntimeConfig.fallback
        assertEquals(McpRuntimeConfig(1, true, 20, 40, 16_384, 24_000, 60.0, 6), fallback)
        assertEquals(fallback, McpRuntimeConfig.fromJson(null))
        assertEquals(fallback, config("[1,2]"))
        assertEquals(fallback, config("\"x\""))
    }

    @Test
    fun `configured values are adopted and absent fields keep fallback`() {
        val parsed = config("""{"version":2,"enabled":false,"maxServers":5,"callTimeoutSeconds":90}""")
        assertEquals(2, parsed.version)
        assertEquals(false, parsed.enabled)
        assertEquals(5, parsed.maxServers)
        assertEquals(90.0, parsed.callTimeoutSeconds, 0.0)
        assertEquals(40, parsed.maxToolsPerRequest)
    }

    @Test
    fun `out of range values clamp to bounds without crashing`() {
        val low = config("""{"maxServers":0,"maxToolsPerRequest":-3,"maxToolDefinitionBytes":0,"maxResultChars":-1,"callTimeoutSeconds":0,"maxSteps":0}""")
        assertEquals(1, low.maxServers)
        assertEquals(1, low.maxToolsPerRequest)
        assertEquals(1_024, low.maxToolDefinitionBytes)
        assertEquals(1_000, low.maxResultChars)
        assertEquals(5.0, low.callTimeoutSeconds, 0.0)
        assertEquals(1, low.maxSteps)

        val high = config("""{"version":1e30,"maxServers":1e30,"maxToolsPerRequest":1e9,"maxToolDefinitionBytes":1e12,"maxResultChars":2.5,"callTimeoutSeconds":1e9,"maxSteps":99}""")
        assertEquals("the version is not clamped; out of range falls back to the default", 1, high.version)
        assertEquals(100, high.maxServers)
        assertEquals(128, high.maxToolsPerRequest)
        assertEquals(262_144, high.maxToolDefinitionBytes)
        assertEquals(1_000, high.maxResultChars)
        assertEquals(600.0, high.callTimeoutSeconds, 0.0)
        assertEquals(8, high.maxSteps)
    }

    @Test
    fun `wrong types keep fallback and fractions floor`() {
        val parsed = config("""{"version":"2","enabled":"yes","maxServers":"7","maxResultChars":5000.9,"maxSteps":3.7}""")
        assertEquals(1, parsed.version)
        assertEquals(true, parsed.enabled)
        assertEquals(20, parsed.maxServers)
        assertEquals(5_000, parsed.maxResultChars)
        assertEquals(3, parsed.maxSteps)
        assertEquals(8, McpRuntimeConfig(maxSteps = 12).effectiveMaxSteps)
        assertEquals(6, McpRuntimeConfig.fallback.effectiveMaxSteps)
    }
}
