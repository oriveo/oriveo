package ai.oriveo.community.core.voice.realtime

import ai.oriveo.community.core.context.RealtimeHistoryItem
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.voice.realtime.wire.GARealtimeCodec
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The openai / xai cases of shared/voice-contracts/realtime-events.v1.json: the GA codec output equals expected key by key. */
class RealtimeGACodecContractTest {

    private val fixture: JsonObject =
        Json.parseToJsonElement(workspaceFile("shared/voice-contracts/realtime-events.v1.json").readText()).jsonObject

    private val gaKinds = setOf(RealtimeTransportKind.OpenAiRealtime, RealtimeTransportKind.XaiRealtime)

    private fun JsonObject.str(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

    /** Picks the cases of a group whose transport is openai / xai: (id, kind, input, expected). */
    private fun gaCases(group: String): List<Triple<String, Pair<RealtimeTransportKind, JsonObject>, kotlinx.serialization.json.JsonElement>> =
        fixture[group]!!.jsonArray.map { it.jsonObject }.mapNotNull { case ->
            val input = case["input"]!!.jsonObject
            val kind = RealtimeTransportKind.fromRawValue(input.str("transport"))!!
            if (kind !in gaKinds) return@mapNotNull null
            Triple(case.str("id")!!, kind to input, case["expected"]!!)
        }.also { assertTrue("$group has no openai / xai cases", it.isNotEmpty()) }

    @Test
    fun `map_cases`() {
        for ((id, ki, expected) in gaCases("mapCases")) {
            val (kind, input) = ki
            val state = GARealtimeCodec.State()
            val events = input["messages"]!!.jsonArray.flatMap { GARealtimeCodec.map(kind, it.jsonObject, state) }
            assertEquals(id, expected.jsonArray, JsonArray(events.map { it.toJson() }))
        }
    }

    @Test
    fun `open_cases`() {
        for ((id, ki, expected) in gaCases("openCases")) {
            val (kind, input) = ki
            val plan = input["plan"]!!.jsonObject
            val entry = input["entry"]!!.jsonObject
            val history = plan["history"]!!.jsonArray.map {
                val h = it.jsonObject
                val role = if (h.str("role") == "assistant") ChatRole.Assistant else ChatRole.User
                RealtimeHistoryItem(role, h.str("text")!!)
            }
            val messages = GARealtimeCodec.openingMessages(
                kind = kind,
                instructions = plan.str("instructions")!!,
                history = history,
                voice = input.str("voice")!!,
                inputTranscriptionModel = entry.str("inputTranscriptionModel"),
            )
            val exp = expected.jsonObject
            assertEquals(id, exp["beforeReady"]!!.jsonArray, JsonArray(messages))
            assertEquals(id, JsonArray(emptyList()), exp["afterReady"]!!.jsonArray)
        }
    }

    @Test
    fun `url_cases`() {
        for ((id, ki, expected) in gaCases("urlCases")) {
            val (kind, input) = ki
            val entry = input["entry"]!!.jsonObject
            val url = GARealtimeCodec.connectUrl(kind, input.str("host")!!, entry.str("path")!!, entry.str("model")!!)
            assertEquals(id, expected.jsonPrimitive.content, url)
        }
    }

    @Test
    fun `truncate_cases`() {
        for ((id, ki, expected) in gaCases("truncateCases")) {
            val (kind, input) = ki
            val message = GARealtimeCodec.truncate(
                kind = kind,
                itemId = input.str("itemId"),
                contentIndex = (input["contentIndex"] as? JsonPrimitive)?.int ?: 0,
                playedMs = input["playedMs"]!!.jsonPrimitive.double,
            )
            if (expected is JsonNull) assertNull(id, message) else assertEquals(id, expected.jsonObject, message)
        }
    }

    @Test
    fun `truncate_gemini_not_sent`() {
        val case = fixture["truncateCases"]!!.jsonArray.map { it.jsonObject }.single { it.str("id") == "truncate_gemini_not_sent" }
        assertEquals(JsonNull, case["expected"])
        val input = case["input"]!!.jsonObject
        val playedMs = input["playedMs"]!!.jsonPrimitive.double
        assertNull(GARealtimeCodec.truncate(RealtimeTransportKind.GeminiLive, input.str("itemId"), 0, playedMs))
        // Not sent even with an item id
        assertNull(GARealtimeCodec.truncate(RealtimeTransportKind.GeminiLive, "msg_010", 0, playedMs))
    }

    @Test
    fun `append_cases`() {
        for ((id, ki, expected) in gaCases("appendCases")) {
            val (kind, input) = ki
            assertEquals(id, expected.jsonObject, GARealtimeCodec.append(kind, input.str("base64")!!))
        }
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
