package ai.oriveo.community.core.voice.realtime

import ai.oriveo.community.core.context.RealtimeHistoryItem
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.voice.realtime.wire.GeminiLiveEventMapper
import ai.oriveo.community.core.voice.realtime.wire.GeminiLiveWire
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonObjectBuilder
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The map / open / url / append cases for gemini_live in shared/voice-contracts/realtime-events.v1.json. */
class GeminiLiveWireTest {

    private val fixture: JsonObject =
        Json.parseToJsonElement(workspaceFile("shared/voice-contracts/realtime-events.v1.json").readText()).jsonObject

    private fun geminiCases(key: String): List<JsonObject> = fixture[key]!!.jsonArray
        .map { it.jsonObject }
        .filter { it["input"]!!.jsonObject["transport"]?.jsonPrimitive?.content == "gemini_live" }

    private fun JsonObject.str(key: String): String = this[key]!!.jsonPrimitive.content

    @Test
    fun `gemini_map_cases_match_fixture`() {
        val cases = geminiCases("mapCases")
        assertEquals(7, cases.size)
        for (case in cases) {
            val mapper = GeminiLiveEventMapper()
            val actual = case["input"]!!.jsonObject["messages"]!!.jsonArray
                .flatMap { mapper.map(it.jsonObject) }
                .map { it.toJson() }
            assertEquals(case.str("id"), case["expected"]!!, JsonArray(actual))
        }
    }

    @Test
    fun `gemini_open_cases_match_fixture`() {
        val cases = geminiCases("openCases")
        assertEquals(3, cases.size)
        for (case in cases) {
            val input = case["input"]!!.jsonObject
            val plan = input["plan"]!!.jsonObject
            val history = plan["history"]!!.jsonArray.map {
                val item = it.jsonObject
                val role = if (item.str("role") == "assistant") ChatRole.Assistant else ChatRole.User
                RealtimeHistoryItem(role, item.str("text"))
            }
            val opening = GeminiLiveWire.openingMessages(
                instructions = plan.str("instructions"),
                history = history,
                model = input["entry"]!!.jsonObject.str("model"),
                voice = input.str("voice"),
                resumeHandle = input["resumeHandle"]?.jsonPrimitive?.content,
            )
            val expected = case["expected"]!!.jsonObject
            val id = case.str("id")
            assertEquals(id, expected["beforeReady"]!!, JsonArray(opening.beforeReady))
            assertEquals(id, expected["afterReady"]!!, JsonArray(opening.afterReady))
        }
    }

    @Test
    fun `gemini_url_case_matches_fixture`() {
        val cases = geminiCases("urlCases")
        assertEquals(1, cases.size)
        val input = cases[0]["input"]!!.jsonObject
        val url = GeminiLiveWire.connectUrl(input.str("host"), input["entry"]!!.jsonObject.str("path"))
        assertEquals(cases[0].str("expected"), url)
    }

    @Test
    fun `gemini_append_case_matches_fixture`() {
        val cases = geminiCases("appendCases")
        assertEquals(1, cases.size)
        val actual = GeminiLiveWire.audioAppendMessage(cases[0]["input"]!!.jsonObject.str("base64"))
        assertEquals(cases[0]["expected"]!!, actual)
    }

    @Test
    fun `authenticated_url_appends_percent_encoded_key`() {
        assertEquals(
            "wss://example.test/ws/path?key=a%2Bb%2Fc%3D~",
            GeminiLiveWire.authenticatedUrl("example.test", "/ws/path", "a+b/c=~"),
        )
        assertEquals(
            "wss://example.test/p?key=Az09-._~%20%25%E4%B8%AD",
            GeminiLiveWire.authenticatedUrl("example.test", "/p", "Az09-._~ %\u4e2d"),
        )
    }

    @Test
    fun `mid_turn_tracks_turn_boundary`() {
        val mapper = GeminiLiveEventMapper()
        fun content(block: JsonObjectBuilder.() -> Unit) = buildJsonObject { putJsonObject("serverContent", block) }
        assertFalse(mapper.midTurn)
        mapper.map(buildJsonObject { putJsonObject("setupComplete") {} })
        assertFalse(mapper.midTurn)
        mapper.map(content { putJsonObject("inputTranscription") { put("text", "Hi") } })
        assertTrue(mapper.midTurn)
        mapper.map(content { put("turnComplete", true) })
        assertFalse(mapper.midTurn)
        mapper.map(
            content {
                putJsonObject("modelTurn") {
                    put("parts", JsonArray(listOf(buildJsonObject { putJsonObject("inlineData") { put("data", "AAAA") } })))
                }
            },
        )
        assertTrue(mapper.midTurn)
        mapper.map(content { put("turnComplete", true) })
        assertFalse(mapper.midTurn)
        mapper.map(content { put("interrupted", true) })
        assertTrue(mapper.midTurn)
        mapper.map(buildJsonObject { putJsonObject("goAway") { put("timeLeft", "10s") } })
        assertTrue(mapper.midTurn)
        mapper.map(content { put("turnComplete", true) })
        assertFalse(mapper.midTurn)
        mapper.map(content { putJsonObject("outputTranscription") { put("text", "") } })
        assertFalse(mapper.midTurn)
        mapper.map(content { putJsonObject("outputTranscription") { put("text", "Ok") } })
        assertTrue(mapper.midTurn)
    }

    @Test
    fun `duration_ms_integer_exact`() {
        fun ms(text: String): Long? = GeminiLiveWire.durationMs(kotlinx.serialization.json.JsonPrimitive(text))
        assertEquals(10_000L, ms("10s"))
        assertEquals(250L, ms("0.250s"))
        // seconds × 1000 + the fractional part rounded to milliseconds
        assertEquals(1_001L, ms("1.0005s"))
        assertEquals(1_000L, ms("1.0004s"))
        assertEquals(1_500L, ms("1.5s"))
        // Overflow is judged exactly: a value that just fits gives the exact result, and 1 ms / 1 s more gives null
        assertEquals(9_223_372_036_854_775_000L, ms("9223372036854775s"))
        assertEquals(Long.MAX_VALUE, ms("9223372036854775.807s"))
        assertNull(ms("9223372036854775.808s"))
        assertNull(ms("9223372036854776s"))
        for (bad in listOf("10", "-1s", "1.s", ".5s", "1.0000000001s", "abc", "")) assertNull(bad, ms(bad))
        assertNull(GeminiLiveWire.durationMs(kotlinx.serialization.json.JsonPrimitive(10)))
        assertNull(GeminiLiveWire.durationMs(null))
    }

    private fun workspaceFile(relative: String): File {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.exists()) return candidate
            dir = dir.parentFile
        }
        throw IllegalStateException("Cannot find $relative")
    }
}
