package ai.oriveo.community.core.voice.realtime

import ai.oriveo.community.core.voice.conversation.ConversationRoute
import ai.oriveo.community.core.voice.conversation.VoiceConversationConstants
import java.io.File
import kotlin.math.floor
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
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
        assertEquals(c["falseBargeInsPerSession"]!!.jsonPrimitive.long, RealtimeConversationConstants.FALSE_BARGE_INS_PER_SESSION.toLong())
        assertEquals(c["echoRefWindowMs"]!!.jsonPrimitive.int, RealtimeUplinkGate.ECHO_REF_WINDOW_MS)
        assertEquals(c["echoRefDelayWindowMs"]!!.jsonPrimitive.int, RealtimeUplinkGate.ECHO_REF_DELAY_WINDOW_MS)
        assertEquals(c["echoRefMaxDelayMs"]!!.jsonPrimitive.int, RealtimeUplinkGate.ECHO_REF_MAX_DELAY_MS)
        assertEquals(c["echoRefMinCorrelation"]!!.jsonPrimitive.double, RealtimeUplinkGate.ECHO_REF_MIN_CORRELATION, 0.0)
        assertEquals(c["echoRefMinDelayCorrelation"]!!.jsonPrimitive.double, RealtimeUplinkGate.ECHO_REF_MIN_DELAY_CORRELATION, 0.0)
        assertEquals(c["echoRefBargeInMarginDb"]!!.jsonPrimitive.double, RealtimeUplinkGate.ECHO_REF_BARGE_IN_MARGIN_DB, 0.0)
        assertEquals(c["echoRefFloorDb"]!!.jsonPrimitive.double, RealtimeUplinkGate.ECHO_REF_FLOOR_DB, 0.0)

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

    /**
     * uplinkGateCases: frames ([[db, n]] / [[db, n, prob]] expanded) are fed frame by frame to the production streaming gate; playbackStarted / playbackEnded are called before the step of that frame,
     * and the per-frame decisions reconstruct {openAtFrame, openReason, flushFromFrame, dropped}, compared field by field.
     */
    @Test
    fun uplinkGateCasesMatchFixture() {
        val cases = fixture["uplinkGateCases"]!!.jsonArray.map { it.jsonObject }
        assertTrue(cases.isNotEmpty())
        for (case in cases) {
            val id = case.str("id")
            val input = case["input"]!!.jsonObject
            val opts = input["opts"]!!.jsonObject
            // [db, n], [db, n, prob] or [db, n, prob, ref]: prob may be null (inference-failed frame), omitted = no probability;
            // ref = downlink reference dB; null / omitted = not playing.
            val frames = input["frames"]!!.jsonArray.flatMap { el ->
                val a = el.jsonArray
                val db = a[0].jsonPrimitive.double
                val prob = a.getOrNull(2)?.let { if (it is JsonNull) null else it.jsonPrimitive.double }
                val ref = a.getOrNull(3)?.let { if (it is JsonNull) null else it.jsonPrimitive.double }
                List(a[1].jsonPrimitive.int) { Triple(db, prob, ref) }
            }
            val route = ConversationRoute.from(opts.str("route"))
            val pb = opts["playbackStartFrame"].let { if (it == null || it is JsonNull) null else it.jsonPrimitive.long }
            val pe = opts["playbackEndedFrame"].let { if (it == null || it is JsonNull) null else it.jsonPrimitive.long }
            val gate = RealtimeUplinkGate()
            if (opts["bargeIn"]?.jsonPrimitive?.booleanOrNull == false) gate.setBargeIn(false)
            var firstHeld: Long? = null
            var open: UplinkGateStep.Open? = null
            var openAt: Long? = null
            for ((idx, frame) in frames.withIndex()) {
                val (db, prob, ref) = frame
                val i = idx.toLong()
                if (i == pb) gate.playbackStarted(route)
                if (i == pe) gate.playbackEnded()
                when (val step = gate.step(db, prob, ref)) {
                    UplinkGateStep.Send -> Unit
                    UplinkGateStep.Hold -> if (firstHeld == null) firstHeld = i
                    is UplinkGateStep.Open -> {
                        if (firstHeld == null) firstHeld = i
                        if (open == null) {
                            open = step
                            openAt = i
                        }
                    }
                }
            }
            val opened = open
            val held = firstHeld
            val dropped: List<Long>? = when {
                held == null -> null
                opened == null -> listOf(held, frames.size - 1L)
                opened.flushFromFrame > held -> listOf(held, opened.flushFromFrame - 1)
                else -> null
            }
            val want = case["expected"]!!.jsonObject
            fun longOrNull(key: String) = want[key].let { if (it == null || it is JsonNull) null else it.jsonPrimitive.long }
            assertEquals("$id openAtFrame", longOrNull("openAtFrame"), openAt)
            assertEquals("$id openReason", want.str("openReason"), opened?.reason?.rawValue)
            assertEquals("$id flushFromFrame", longOrNull("flushFromFrame"), opened?.flushFromFrame)
            val wantDropped = want["dropped"].let { if (it == null || it is JsonNull) null else (it as JsonArray).map { e -> e.jsonPrimitive.long } }
            assertEquals("$id dropped", wantDropped, dropped)
        }
    }

    /** displayCases: feeds the production reducer step by step, comparing userCaption / assistantShown / stageLine each step (the text and stage line the host renders). */
    @Test
    fun displayCasesMatchFixture() {
        val cases = fixture["displayCases"]!!.jsonArray.map { it.jsonObject }
        assertTrue(cases.isNotEmpty())
        for (case in cases) {
            val id = case.str("id")
            var state = RealtimeConversationLogic.initialState()
            case["steps"]!!.jsonArray.map { it.jsonObject }.forEachIndexed { i, step ->
                val raw = step["input"]!!.jsonObject
                parseInput(raw)?.let { state = RealtimeConversationLogic.reduce(state, it).state }
                val want = step["expected"]!!.jsonObject
                val label = "$id#$i ${raw.str("type")}"
                assertEquals("$label userCaption", want.str("userCaption"), userCaption(state))
                assertEquals("$label assistantShown", want.str("assistantShown"), assistantShown(state))
                assertTrue("$label stageLine expected", "stageLine" in want)
                assertEquals("$label stageLine", want["stageLine"], stageLineJson(stageLine(state)))
            }
        }
    }

    /** revealCases: revealPrefix compared case by case; playedMs may carry decimals, truncated toward zero first per the contract. */
    @Test
    fun revealCasesMatchFixture() {
        val cases = fixture["revealCases"]!!.jsonArray.map { it.jsonObject }
        assertTrue(cases.isNotEmpty())
        for (case in cases) {
            val input = case["input"]!!.jsonObject
            val got = revealPrefix(
                text = input.str("text")!!,
                playedMs = floor(input["playedMs"]!!.jsonPrimitive.double).toLong(),
                audioSamples = input["audioSamples"]!!.jsonPrimitive.long,
                sampleRateHz = input["sampleRateHz"]!!.jsonPrimitive.int,
            )
            assertEquals(case.str("id"), case.str("expected"), got)
        }
    }

    /** Only the first playbackEnded in a cycle counts: repeated calls do not push back the afterglow window (consistent with the reference implementation, one pe per cycle). */
    @Test
    fun gate_playback_ended_first_call_wins() {
        val guard = (VoiceConversationConstants.POST_PLAYBACK_GUARD_MS / VoiceConversationConstants.FRAME_MS).toLong()
        val gate = RealtimeUplinkGate()
        var openAt: Long? = null
        for (i in 0L until 10 + guard + 20) {
            if (i == 0L) gate.playbackStarted(ConversationRoute.SPEAKER)
            if (i == 10L || i == 12L) gate.playbackEnded()
            val step = gate.step(-70.0)
            if (step is UplinkGateStep.Open && openAt == null) {
                assertEquals(UplinkGateOpenReason.GUARD_END, step.reason)
                openAt = i
            }
        }
        assertEquals(10 + guard, openAt)
    }

    /** An unrecognized input type returns null (contract: state unchanged, no effects). */
    private fun stageLineJson(line: StageLine?): JsonElement = when (line) {
        null -> JsonNull
        is StageLine.User -> buildJsonObject { put("kind", "user"); put("text", line.text) }
        is StageLine.Assistant -> buildJsonObject { put("kind", "assistant"); put("text", line.text) }
        is StageLine.Status -> buildJsonObject {
            put("kind", "status")
            put("statusKey", line.statusKey?.rawValue?.let(::JsonPrimitive) ?: JsonNull)
        }
    }

    private fun parseInput(e: JsonObject): RealtimeConversationInput? = when (e.str("type")) {
        "mute" -> RealtimeConversationInput.Mute
        "unmute" -> RealtimeConversationInput.Unmute
        "tapOrb" -> RealtimeConversationInput.TapOrb
        "playbackDrained" -> RealtimeConversationInput.PlaybackDrained
        "playbackProgress" -> RealtimeConversationInput.PlaybackProgress(
            e.str("itemId"),
            floor(e["playedMs"]!!.jsonPrimitive.double).toLong(),
        )
        "tick" -> RealtimeConversationInput.Tick(e["ms"]!!.jsonPrimitive.long)
        "end" -> RealtimeConversationInput.End
        "systemInterruption" -> RealtimeConversationInput.SystemInterruption
        "failed" -> RealtimeConversationInput.Failed(e.str("code"))
        "sessionExpired" -> RealtimeConversationInput.SessionExpired
        "planChanged" -> RealtimeConversationInput.PlanChanged
        "gateOpened" -> RealtimeConversationInput.GateOpened
        "wake" -> RealtimeConversationInput.Wake
        "screenReaderSpeaking" -> RealtimeConversationInput.ScreenReaderSpeaking(e["speaking"]?.jsonPrimitive?.booleanOrNull == true)
        // The unified event's text is non-null: a null in the fixture is treated as "" (contract: if empty after trim, fall back to the most recent assistantTranscript).
        "assistantTurnDone" -> sessionInput(if (e["text"] is JsonNull) JsonObject(e + ("text" to JsonPrimitive(""))) else e)
        else -> sessionInput(e)
    }

    private fun sessionInput(e: JsonObject) = RealtimeSessionEvent.fromJson(e)?.let(RealtimeConversationInput::Session)

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
            RealtimeConversationEffect.DisableBargeIn,
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
        throw IllegalStateException("not found: $relative")
    }
}
