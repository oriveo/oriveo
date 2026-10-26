package ai.oriveo.community.core.voice.realtime

import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** shared/voice-contracts/realtime-events.v1.json: every expected event of mapCases round-trips, and the three closed sets equal constants. */
class RealtimeEventsContractTest {

    private val fixture: JsonObject =
        Json.parseToJsonElement(workspaceFile("shared/voice-contracts/realtime-events.v1.json").readText()).jsonObject

    private val constants: JsonObject = fixture["constants"]!!.jsonObject

    private fun strings(key: String): List<String> = constants[key]!!.jsonArray.map { it.jsonPrimitive.content }

    @Test
    fun everyExpectedEventRoundTrips() {
        val events = fixture["mapCases"]!!.jsonArray.flatMap { case ->
            val id = case.jsonObject["id"]!!.jsonPrimitive.content
            case.jsonObject["expected"]!!.jsonArray.map { id to it.jsonObject }
        }
        assertTrue(events.isNotEmpty())
        for ((id, expected) in events) {
            val decoded = RealtimeSessionEvent.fromJson(expected)
            assertNotNull("$id cannot decode $expected", decoded)
            assertEquals(id, expected, decoded!!.toJson())
        }
        val covered = events.map { it.second["type"]!!.jsonPrimitive.content }.toSet()
        assertEquals(strings("unifiedEvents").toSet(), covered)
    }

    @Test
    fun goAwayKeepsNullTimeLeft() {
        val json = buildJsonObject {
            put("type", "goAway")
            put("timeLeftMs", JsonNull)
        }
        val event = RealtimeSessionEvent.fromJson(json)
        assertEquals(RealtimeSessionEvent.GoAway(null), event)
        assertEquals(json, event!!.toJson())
    }

    @Test
    fun `goaway_missing_key_is_nil`() {
        assertNull(RealtimeSessionEvent.fromJson(buildJsonObject { put("type", "goAway") }))
        assertNull(
            RealtimeSessionEvent.fromJson(
                buildJsonObject {
                    put("type", "goAway")
                    put("timeLeftMs", "5000")
                },
            ),
        )
        assertEquals(
            RealtimeSessionEvent.GoAway(5000L),
            RealtimeSessionEvent.fromJson(
                buildJsonObject {
                    put("type", "goAway")
                    put("timeLeftMs", 5000)
                },
            ),
        )
    }

    @Test
    fun `integer_fields_reject_fractions`() {
        assertNull(RealtimeSessionEvent.fromJson(audio(contentIndex = JsonPrimitive(1.5))))
        assertNull(RealtimeSessionEvent.fromJson(goAway(JsonPrimitive(1.5))))
        assertEquals(RealtimeSessionEvent.GoAway(500L), RealtimeSessionEvent.fromJson(goAway(JsonPrimitive(500))))
    }

    @Test
    fun `non_string_item_id_only_fails_item_events`() {
        assertEquals(
            RealtimeSessionEvent.Ready,
            RealtimeSessionEvent.fromJson(
                buildJsonObject {
                    put("type", "ready")
                    put("itemId", 5)
                },
            ),
        )
        assertEquals(
            RealtimeSessionEvent.GoAway(500L),
            RealtimeSessionEvent.fromJson(
                buildJsonObject {
                    put("type", "goAway")
                    put("itemId", 5)
                    put("timeLeftMs", 500)
                },
            ),
        )
        assertNull(RealtimeSessionEvent.fromJson(audio(itemId = JsonPrimitive(5))))
    }

    @Test
    fun `integral_float_accepted_fraction_rejected`() {
        assertEquals(
            RealtimeSessionEvent.AssistantAudio(itemId = "i1", contentIndex = 2, base64 = "AA==", sampleRateHz = 24_000),
            RealtimeSessionEvent.fromJson(audio(contentIndex = JsonPrimitive(2.0))),
        )
        assertNull(RealtimeSessionEvent.fromJson(audio(contentIndex = JsonPrimitive(1.5))))
    }

    @Test
    fun `numeric_string_rejected`() {
        assertNull(RealtimeSessionEvent.fromJson(goAway(JsonPrimitive("5000"))))
        assertNull(RealtimeSessionEvent.fromJson(audio(contentIndex = JsonPrimitive("5000"))))
        assertNull(RealtimeSessionEvent.fromJson(goAway(JsonPrimitive(true))))
    }

    private fun audio(itemId: JsonElement = JsonPrimitive("i1"), contentIndex: JsonElement = JsonPrimitive(0)) =
        buildJsonObject {
            put("type", "assistantAudio")
            put("itemId", itemId)
            put("contentIndex", contentIndex)
            put("base64", "AA==")
            put("sampleRateHz", 24_000)
        }

    private fun goAway(timeLeftMs: JsonElement) = buildJsonObject {
        put("type", "goAway")
        put("timeLeftMs", timeLeftMs)
    }

    @Test
    fun unknownTypeDecodesToNull() {
        assertNull(RealtimeSessionEvent.fromJson(buildJsonObject { put("type", "nope") }))
        assertNull(RealtimeSessionEvent.fromJson(buildJsonObject { }))
    }

    @Test
    fun closedSetsEqualConstants() {
        assertEquals(strings("unifiedEvents"), RealtimeSessionEvent.typeNames)
        assertEquals(strings("turnStatuses"), RealtimeTurnStatus.entries.map { it.rawValue })
        assertEquals(strings("transports"), RealtimeTransportKind.entries.map { it.rawValue })
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
