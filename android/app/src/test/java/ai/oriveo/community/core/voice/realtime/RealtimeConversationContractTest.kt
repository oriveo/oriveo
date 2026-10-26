package ai.oriveo.community.core.voice.realtime

import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** shared/voice-contracts/realtime-conversation.v1.json, compared case by case and step by step against the production reducer (status key + effect sequence). */
class RealtimeConversationContractTest {

    private val fixture: JsonObject =
        Json.parseToJsonElement(workspaceFile("shared/voice-contracts/realtime-conversation.v1.json").readText()).jsonObject

    private fun JsonObject.str(key: String): String? = this[key].let { el ->
        if (el == null || el is JsonNull) null else el.jsonPrimitive.content
    }

    @Test
    fun realtimeConversationCasesMatchFixture() {
        val c = fixture["constants"]!!.jsonObject
        assertEquals(c["idleEndMs"]!!.jsonPrimitive.long, RealtimeConversationConstants.IDLE_END_MS)
        assertEquals(c["thinkingEarconMs"]!!.jsonPrimitive.long, RealtimeConversationConstants.THINKING_EARCON_MS)
        assertEquals(c["lateUserTranscriptMs"]!!.jsonPrimitive.long, RealtimeConversationConstants.LATE_USER_TRANSCRIPT_MS)
        assertEquals(c["muteSilenceMs"]!!.jsonPrimitive.long, RealtimeConversationConstants.MUTE_SILENCE_MS)

        val cases = fixture["cases"]!!.jsonArray.map { it.jsonObject }
        assertTrue(cases.isNotEmpty())
        for (case in cases) {
            val id = case.str("id")
            var state = RealtimeConversationLogic.initialState()
            case["steps"]!!.jsonArray.map { it.jsonObject }.forEachIndexed { i, step ->
                val raw = step["input"]!!.jsonObject
                val input = parseInput(raw)
                val effects = if (input == null) {
                    emptyList()
                } else {
                    val r = RealtimeConversationLogic.reduce(state, input)
                    state = r.state
                    r.effects
                }
                val want = step["expected"]!!.jsonObject
                val label = "$id#$i ${raw.str("type")}"
                assertEquals(label, want.str("statusKey"), RealtimeConversationLogic.statusKey(state)?.rawValue)
                assertEquals(label, want["effects"]!!.jsonArray.map { it.jsonObject }, effects.map(::effectJson))
                val wantNext = want["nextTickMs"]!!.let { if (it is JsonNull) null else it.jsonPrimitive.long }
                assertEquals("$label nextTickMs", wantNext, RealtimeConversationLogic.nextTickMs(state))
            }
        }
    }

    /** An unrecognized input type returns null (contract: state unchanged, no effects). */
    private fun parseInput(e: JsonObject): RealtimeConversationInput? = when (e.str("type")) {
        "mute" -> RealtimeConversationInput.Mute
        "unmute" -> RealtimeConversationInput.Unmute
        "tapOrb" -> RealtimeConversationInput.TapOrb
        "playbackDrained" -> RealtimeConversationInput.PlaybackDrained
        "tick" -> RealtimeConversationInput.Tick(e["ms"]!!.jsonPrimitive.long)
        "end" -> RealtimeConversationInput.End
        "systemInterruption" -> RealtimeConversationInput.SystemInterruption
        "failed" -> RealtimeConversationInput.Failed(e.str("code"))
        "sessionExpired" -> RealtimeConversationInput.SessionExpired
        "planChanged" -> RealtimeConversationInput.PlanChanged
        "screenReaderSpeaking" -> RealtimeConversationInput.ScreenReaderSpeaking(e["speaking"]?.jsonPrimitive?.booleanOrNull == true)
        // The unified event's text is non-null: a null in the fixture is treated as "" (contract: anything empty after trim falls back to the latest assistantTranscript)
        "assistantTurnDone" -> RealtimeSessionEvent.fromJson(
            if (e["text"] is JsonNull) JsonObject(e + ("text" to JsonPrimitive(""))) else e,
        )?.let(RealtimeConversationInput::Session)
        else -> RealtimeSessionEvent.fromJson(e)?.let(RealtimeConversationInput::Session)
    }

    private fun effectJson(effect: RealtimeConversationEffect): JsonObject = buildJsonObject {
        put("type", effect.type)
        when (effect) {
            is RealtimeConversationEffect.Persist -> {
                put("role", effect.role.rawValue)
                put("text", effect.text)
            }
            is RealtimeConversationEffect.SendSilence -> put("ms", effect.ms)
            is RealtimeConversationEffect.SetUplink -> put("on", effect.on)
            is RealtimeConversationEffect.ShowError -> put("code", effect.code?.let(::JsonPrimitive) ?: JsonNull)
            is RealtimeConversationEffect.WriteDraft -> put("text", effect.text)
            is RealtimeConversationEffect.Ended -> put("reason", effect.reason.rawValue)
            RealtimeConversationEffect.InterruptPlayback,
            RealtimeConversationEffect.Earcon,
            RealtimeConversationEffect.Close,
            RealtimeConversationEffect.Reopen,
            -> Unit
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
