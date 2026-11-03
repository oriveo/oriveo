package ai.oriveo.community.core.voice.conversation

import android.media.AudioDeviceInfo
import ai.oriveo.community.feature.chat.voice.VoiceConversationBarStatus
import ai.oriveo.community.feature.chat.voice.CAPTION_BRIGHT_SCALARS
import ai.oriveo.community.feature.chat.voice.CAPTION_BRIGHT_WORDS
import ai.oriveo.community.feature.chat.voice.CaptionHighlight
import ai.oriveo.community.feature.chat.voice.VoiceConversationPage
import ai.oriveo.community.feature.chat.voice.captionHighlight
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.double
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Compares every case group in shared/voice-contracts/voice-conversation.v1.json (vad / echo / numerals / continuation / amend / captionHighlight / reduce / page reachability states) one by one against the production pure functions. */
class VoiceConversationContractTest {

    private val fixture: JsonObject =
        Json.parseToJsonElement(workspaceFile("shared/voice-contracts/voice-conversation.v1.json").readText()).jsonObject

    private fun cases(key: String): List<JsonObject> = fixture[key]!!.jsonArray.map { it.jsonObject }

    private fun JsonObject.str(key: String): String? = this[key].let { el ->
        if (el == null || el is JsonNull) null else el.jsonPrimitive.content
    }

    @Test
    fun constantsMatchFixture() {
        val c = fixture["constants"]!!.jsonObject
        val k = VoiceConversationConstants
        assertEquals(c["frameMs"]!!.jsonPrimitive.int, k.FRAME_MS)
        assertEquals(c["vadStartMs"]!!.jsonPrimitive.int, k.VAD_START_MS)
        assertEquals(c["vadEndSilenceMs"]!!.jsonPrimitive.int, k.VAD_END_SILENCE_MS)
        assertEquals(c["vadMinUtteranceMs"]!!.jsonPrimitive.int, k.VAD_MIN_UTTERANCE_MS)
        assertEquals(c["vadMaxUtteranceMs"]!!.jsonPrimitive.int, k.VAD_MAX_UTTERANCE_MS)
        assertEquals(c["vadContinueAbsMinDb"]!!.jsonPrimitive.double, k.VAD_CONTINUE_ABS_MIN_DB, 0.0)
        assertEquals(c["postPlaybackGuardMs"]!!.jsonPrimitive.int, k.POST_PLAYBACK_GUARD_MS)
        assertEquals(c["postPlaybackGuardMinSpeechMs"]!!.jsonPrimitive.int, k.POST_PLAYBACK_GUARD_MIN_SPEECH_MS)
        assertEquals(c["echoWindowMs"]!!.jsonPrimitive.long, k.ECHO_WINDOW_MS)
        assertEquals(c["echoMinWeight"]!!.jsonPrimitive.int, k.ECHO_MIN_WEIGHT)
        assertEquals(c["echoHanUnitWeight"]!!.jsonPrimitive.int, k.ECHO_HAN_UNIT_WEIGHT)
        assertEquals(c["echoOtherUnitWeight"]!!.jsonPrimitive.int, k.ECHO_OTHER_UNIT_WEIGHT)
        assertEquals(c["partialStallMs"]!!.jsonPrimitive.long, k.PARTIAL_STALL_MS)
        assertEquals(c["endpointMaxSilenceMs"]!!.jsonPrimitive.long, k.ENDPOINT_MAX_SILENCE_MS)
        assertEquals(c["endpointPartialSettleMs"]!!.jsonPrimitive.long, k.ENDPOINT_PARTIAL_SETTLE_MS)
        assertEquals(c["continuationPunctuation"]!!.jsonArray.map { it.jsonPrimitive.content }, k.CONTINUATION_PUNCTUATION)
        assertEquals(c["continuationWords"]!!.jsonArray.map { it.jsonPrimitive.content }, k.CONTINUATION_WORDS)
        assertEquals(c["sayAgainMinVoicedMs"]!!.jsonPrimitive.int, k.SAY_AGAIN_MIN_VOICED_MS)
        assertEquals(c["checkLanguageMinVoicedMs"]!!.jsonPrimitive.int, k.CHECK_LANGUAGE_MIN_VOICED_MS)
        assertEquals(c["checkLanguageAfterMisses"]!!.jsonPrimitive.int, k.CHECK_LANGUAGE_AFTER_MISSES)
        assertEquals(c["vadPrerollMs"]!!.jsonPrimitive.int, k.VAD_PREROLL_MS)
        assertEquals(c["vadStartOverFloorDb"]!!.jsonPrimitive.double, k.VAD_START_OVER_FLOOR_DB, 0.0)
        assertEquals(c["vadContinueOverFloorDb"]!!.jsonPrimitive.double, k.VAD_CONTINUE_OVER_FLOOR_DB, 0.0)
        assertEquals(c["vadAbsoluteMinDb"]!!.jsonPrimitive.double, k.VAD_ABSOLUTE_MIN_DB, 0.0)
        assertEquals(c["floorInitDb"]!!.jsonPrimitive.double, k.FLOOR_INIT_DB, 0.0)
        assertEquals(c["floorAlpha"]!!.jsonPrimitive.double, k.FLOOR_ALPHA, 0.0)
        assertEquals(c["vadModelStartProb"]!!.jsonPrimitive.double, k.VAD_MODEL_START_PROB, 0.0)
        assertEquals(c["vadModelContinueProb"]!!.jsonPrimitive.double, k.VAD_MODEL_CONTINUE_PROB, 0.0)
        assertEquals(c["vadModelGateOverFloorDb"]!!.jsonPrimitive.double, k.VAD_MODEL_GATE_OVER_FLOOR_DB, 0.0)
        assertEquals(c["vadModelContinueOverFloorDb"]!!.jsonPrimitive.double, k.VAD_MODEL_CONTINUE_OVER_FLOOR_DB, 0.0)
        assertEquals(c["vadModelBgPercentile"]!!.jsonPrimitive.int, k.VAD_MODEL_BG_PERCENTILE)
        assertEquals(c["vadModelStartOverBgDb"]!!.jsonPrimitive.double, k.VAD_MODEL_START_OVER_BG_DB, 0.0)
        assertEquals(c["vadModelContinueOverBgDb"]!!.jsonPrimitive.double, k.VAD_MODEL_CONTINUE_OVER_BG_DB, 0.0)
        assertEquals(c["vadModelFollowUpFloorOverBgDb"]!!.jsonPrimitive.double, k.VAD_MODEL_FOLLOW_UP_FLOOR_OVER_BG_DB, 0.0)
        assertEquals(c["floorWindowMs"]!!.jsonPrimitive.int, k.FLOOR_WINDOW_MS)
        assertEquals(c["floorSmoothMs"]!!.jsonPrimitive.int, k.FLOOR_SMOOTH_MS)
        assertEquals(c["bargeInGraceMs"]!!.jsonPrimitive.int, k.BARGE_IN_GRACE_MS)
        assertEquals(c["bargeInMinSpeechMs"]!!.jsonPrimitive.int, k.BARGE_IN_MIN_SPEECH_MS)
        assertEquals(c["echoOverlapRatio"]!!.jsonPrimitive.double, k.ECHO_OVERLAP_RATIO, 0.0)
        assertEquals(c["falseBargeInsPerConversation"]!!.jsonPrimitive.int, k.FALSE_BARGE_INS_PER_CONVERSATION)
        assertEquals(c["conversationsToRemember"]!!.jsonPrimitive.int, k.CONVERSATIONS_TO_REMEMBER)
        assertEquals(c["idleTimeoutMs"]!!.jsonPrimitive.long, k.IDLE_TIMEOUT_MS)
        assertEquals(c["thinkingEarconMs"]!!.jsonPrimitive.long, k.THINKING_EARCON_MS)
        assertEquals(c["replyAudioGateMs"]!!.jsonPrimitive.long, k.REPLY_AUDIO_GATE_MS)
        assertEquals(c["listenToThinkTapGuardMs"]!!.jsonPrimitive.long, k.LISTEN_TO_THINK_TAP_GUARD_MS)
        assertEquals(c["stopToVoiceGuardMs"]!!.jsonPrimitive.long, k.STOP_TO_VOICE_GUARD_MS)
        assertEquals(c["sttRetries"]!!.jsonPrimitive.int, k.STT_RETRIES)
        val floor = c["floorClampDb"]!!.jsonArray.map { it.jsonPrimitive.double }
        assertEquals(listOf(k.FLOOR_MIN_DB, k.FLOOR_MAX_DB), floor)
        val frame = c["frameDbClampDb"]!!.jsonArray.map { it.jsonPrimitive.double }
        assertEquals(listOf(k.FRAME_MIN_DB, k.FRAME_MAX_DB), frame)
    }

    @Test
    fun vadCases() {
        val all = cases("vad")
        assertTrue(all.isNotEmpty())
        for (case in all) {
            val input = case["input"]!!.jsonObject
            // Each segment is [dB, frames] or [dB, frames, voice probability] (model mode)
            val runs = input["frames"]!!.jsonArray.map { it.jsonArray }
            val frames = runs.flatMap { run ->
                val db = run[0].jsonPrimitive.doubleOrNull ?: Double.NaN
                List(run[1].jsonPrimitive.int) { db }
            }
            val probs = runs.flatMap { run ->
                val prob = run.getOrNull(2)?.jsonPrimitive?.double
                List(run[1].jsonPrimitive.int) { prob }
            }.takeIf { list -> list.any { it != null } }
            val opts = input["opts"]?.jsonObject ?: JsonObject(emptyMap())
            val actual = runVad(
                frames,
                ConversationRoute.from(opts.str("route")),
                opts.long("playbackStartFrame"),
                opts.long("playbackEndedFrame"),
                opts.long("resetFrame"),
                probs,
                opts.long("forceEndFrame"),
            ).map(::vadJson)
            val expected = case["expected"]!!.jsonArray.map { it.jsonObject }
            assertEquals(case.str("id"), expected, actual)
        }
    }

    private fun JsonObject.long(key: String): Long? = (this[key] as? JsonPrimitive)?.longOrNull

    private fun vadJson(event: VadEvent): JsonObject = buildJsonObject {
        when (event) {
            is VadEvent.SpeechStart -> {
                put("type", "speechStart")
                put("frame", event.frame)
                put("prerollFrame", event.prerollFrame)
            }
            is VadEvent.SpeechEnd -> {
                put("type", "speechEnd")
                put("frame", event.frame)
                put("voicedMs", event.voicedMs)
                put("reason", event.reason.rawValue)
            }
            is VadEvent.Discarded -> {
                put("type", "discarded")
                put("frame", event.frame)
            }
        }
    }

    @Test
    fun echoCases() {
        val all = cases("echo")
        assertTrue(all.isNotEmpty())
        for (case in all) {
            val id = case.str("id")
            val input = case["input"]!!.jsonObject
            val verdict = isEcho(input.str("transcript")!!, input["pool"]!!.jsonArray.map { it.jsonPrimitive.content })
            val expected = case["expected"]!!.jsonObject
            assertEquals(id, expected["echo"]!!.jsonPrimitive.booleanOrNull, verdict.echo)
            val overlap = expected["overlap"]
            if (overlap == null || overlap is JsonNull) {
                assertEquals(id, null, verdict.overlap)
            } else {
                assertEquals(id, overlap.jsonPrimitive.double, verdict.overlap!!, 0.00005)
            }
        }
    }

    @Test
    fun numeralCases() {
        val all = cases("numerals")
        assertTrue(all.isNotEmpty())
        for (case in all) {
            val run = case["input"]!!.jsonObject.str("run")!!
            assertEquals(case.str("id"), case.str("expected"), zhNumberRun(run))
        }
    }

    @Test
    fun continuationCases() {
        val all = cases("continuation")
        assertTrue(all.isNotEmpty())
        for (case in all) {
            val text = case["input"]!!.jsonObject.str("text")!!
            assertEquals(case.str("id"), case["expected"]!!.jsonPrimitive.booleanOrNull, endsWithContinuation(text))
        }
    }

    @Test
    fun amendCases() {
        val all = cases("amend")
        assertTrue(all.isNotEmpty())
        for (case in all) {
            val input = case["input"]!!.jsonObject
            assertEquals(case.str("id"), case.str("expected"), joinAmend(input.str("previous")!!, input.str("text")!!))
        }
    }

    @Test
    fun captionHighlightCases() {
        val c = fixture["constants"]!!.jsonObject
        assertEquals(c["captionBrightScalars"]!!.jsonPrimitive.int, CAPTION_BRIGHT_SCALARS)
        assertEquals(c["captionBrightWords"]!!.jsonPrimitive.int, CAPTION_BRIGHT_WORDS)
        val all = cases("captionHighlight")
        assertTrue(all.size >= 12)
        for (case in all) {
            val text = case["input"]!!.jsonObject.str("text")!!
            val expected = case["expected"]!!.jsonObject
            assertEquals(case.str("id"), CaptionHighlight(expected.str("dim")!!, expected.str("bright")!!), captionHighlight(text))
        }
    }

    @Test
    fun pageReachableStatusKeysMatchFixture() {
        val pages = fixture["pageReachableStatusKeys"]!!.jsonObject
        fun keys(page: String) = pages[page]!!.jsonArray.map { it.jsonPrimitive.content }.toSet()
        fun raw(page: VoiceConversationPage) = VoiceConversationBarStatus.reachable(page).map { it.rawValue }.toSet()
        assertEquals(keys("home"), raw(VoiceConversationPage.Home))
        assertEquals(keys("chat"), raw(VoiceConversationPage.Chat))
        // The fixture's full set of state keys is the full set of production enum values
        assertEquals(keys("chat"), ConversationStatusKey.entries.map { it.rawValue }.toSet())
    }

    @Test
    fun reduceCases() {
        val all = cases("reduce")
        assertTrue(all.isNotEmpty())
        for (case in all) {
            val id = case.str("id")
            var state = initialConversationState()
            val events = case["input"]!!.jsonObject["events"]!!.jsonArray.map { it.jsonObject }
            val expected = case["expected"]!!.jsonArray.map { it.jsonObject }
            assertEquals(id, expected.size, events.size)
            events.forEachIndexed { i, raw ->
                val event = parseEvent(raw)
                val effects = if (event == null) {
                    emptyList()
                } else {
                    val r = reduce(state, event)
                    state = r.state
                    r.effects
                }
                val want = expected[i]
                val step = "$id#$i ${raw.str("type")}"
                assertEquals(step, want.str("displayState"), displayState(state)?.rawValue)
                assertEquals(step, want.str("statusKey"), statusKey(state)?.rawValue)
                assertEquals(step, want.str("caption"), caption(state))
                assertEquals(step, want["effects"]!!.jsonArray.map { it.jsonObject }, effects.map(::effectJson))
                assertEquals(step, want["nextDeadlineMs"]!!.jsonPrimitive.longOrNull, nextDeadlineMs(state))
            }
        }
    }

    /** An unrecognized event type returns null (contract: state unchanged, no effects). */
    private fun parseEvent(e: JsonObject): ConversationEvent? {
        val t = e["atMs"]!!.jsonPrimitive.long
        return when (e.str("type")) {
            "start" -> ConversationEvent.Start(
                t,
                ConversationRoute.from(e.str("route")),
                e["deviceRemembersNoSpeakerBargeIn"]?.jsonPrimitive?.booleanOrNull == true,
            )
            "vadSpeechStart" -> ConversationEvent.VadSpeechStart(t)
            "vadSpeechEnd" -> ConversationEvent.VadSpeechEnd(t, e.str("utteranceId")!!, e.long("voicedMs")?.toInt() ?: 0)
            "vadDiscarded" -> ConversationEvent.VadDiscarded(t)
            "bargeInDetected" -> ConversationEvent.BargeInDetected(t)
            "sttPartial" -> ConversationEvent.SttPartial(t, e.str("text").orEmpty())
            "sttResult" -> ConversationEvent.SttResult(t, e.str("utteranceId")!!, e.str("text").orEmpty())
            "sttFailed" -> ConversationEvent.SttFailed(t, e.str("utteranceId")!!)
            "replySentence" -> ConversationEvent.ReplySentence(t, e.str("text").orEmpty())
            "sentenceStarted" -> ConversationEvent.SentenceStarted(t, e.str("text").orEmpty())
            "replyCompleted" -> ConversationEvent.ReplyCompleted(t)
            "playbackDrained" -> ConversationEvent.PlaybackDrained(t)
            "replyFailed" -> ConversationEvent.ReplyFailed(t, e.str("code").orEmpty())
            "approvalPending" -> ConversationEvent.ApprovalPending(t)
            "approvalResolved" -> ConversationEvent.ApprovalResolved(t)
            "tapOrb" -> ConversationEvent.TapOrb(t)
            "toggleMute" -> ConversationEvent.ToggleMute(t)
            "deadline" -> ConversationEvent.Deadline(t)
            "interruptionBegan" -> ConversationEvent.InterruptionBegan(t)
            "interruptionEnded" -> ConversationEvent.InterruptionEnded(t)
            "screenReaderSpeaking" ->
                ConversationEvent.ScreenReaderSpeaking(t, e["speaking"]?.jsonPrimitive?.booleanOrNull == true)
            "routeChanged" -> ConversationEvent.RouteChanged(t, ConversationRoute.from(e.str("route")))
            "playMessage" -> ConversationEvent.PlayMessage(t, e.str("messageId").orEmpty())
            "messagePlaybackEnded" -> ConversationEvent.MessagePlaybackEnded(t)
            "promptStarted" -> ConversationEvent.PromptStarted(t, e.str("text").orEmpty())
            "promptEnded" -> ConversationEvent.PromptEnded(t)
            "end" -> ConversationEvent.End(t, if (e.str("reason") == "user") EndReason.USER else EndReason.SYSTEM)
            else -> null
        }
    }

    private fun effectJson(effect: ConversationEffect): JsonObject {
        val fields: Map<String, JsonElement> = when (effect) {
            ConversationEffect.StartCapture -> mapOf()
            is ConversationEffect.Transcribe -> mapOf("utteranceId" to JsonPrimitive(effect.utteranceId))
            is ConversationEffect.SendMessage -> mapOf("text" to JsonPrimitive(effect.text))
            is ConversationEffect.AmendLastMessage -> mapOf("text" to JsonPrimitive(effect.text))
            ConversationEffect.CancelGeneration -> mapOf()
            is ConversationEffect.EnqueueSpeech -> mapOf("text" to JsonPrimitive(effect.text))
            ConversationEffect.PausePlayback -> mapOf()
            is ConversationEffect.ResumePlayback -> mapOf("from" to JsonPrimitive(effect.from.rawValue))
            ConversationEffect.StopPlayback -> mapOf()
            is ConversationEffect.SpeakPrompt -> mapOf("prompt" to JsonPrimitive(effect.prompt.rawValue))
            is ConversationEffect.Earcon -> mapOf("kind" to JsonPrimitive(effect.kind.rawValue))
            is ConversationEffect.Haptic -> mapOf("kind" to JsonPrimitive(effect.kind.rawValue))
            ConversationEffect.NudgeOrb -> mapOf()
            is ConversationEffect.EndConversation -> buildMap {
                put("reason", JsonPrimitive(effect.reason.rawValue))
                effect.code?.let { put("code", JsonPrimitive(it)) }
            }
            ConversationEffect.RememberFalseBargeInConversation -> mapOf()
            ConversationEffect.ForceEndUtterance -> mapOf()
            is ConversationEffect.ContinueUtterance -> mapOf("utteranceId" to JsonPrimitive(effect.utteranceId))
            is ConversationEffect.ResetVad -> mapOf("playbackEndedAtMs" to (effect.playbackEndedAtMs?.let { JsonPrimitive(it) } ?: JsonNull))
            is ConversationEffect.SetCaptureMuted -> mapOf("muted" to JsonPrimitive(effect.muted))
            ConversationEffect.PauseCapture -> mapOf()
            ConversationEffect.ResumeCapture -> mapOf()
            is ConversationEffect.PlayMessage -> mapOf("messageId" to JsonPrimitive(effect.messageId))
            ConversationEffect.TranscribeToDraft -> mapOf()
        }
        return JsonObject(mapOf("type" to JsonPrimitive(effectType(effect))) + fields)
    }

    private fun effectType(effect: ConversationEffect): String = when (effect) {
        ConversationEffect.StartCapture -> "startCapture"
        is ConversationEffect.Transcribe -> "transcribe"
        is ConversationEffect.SendMessage -> "sendMessage"
        is ConversationEffect.AmendLastMessage -> "amendLastMessage"
        ConversationEffect.CancelGeneration -> "cancelGeneration"
        is ConversationEffect.EnqueueSpeech -> "enqueueSpeech"
        ConversationEffect.PausePlayback -> "pausePlayback"
        is ConversationEffect.ResumePlayback -> "resumePlayback"
        ConversationEffect.StopPlayback -> "stopPlayback"
        is ConversationEffect.SpeakPrompt -> "speakPrompt"
        is ConversationEffect.Earcon -> "earcon"
        is ConversationEffect.Haptic -> "haptic"
        ConversationEffect.NudgeOrb -> "nudgeOrb"
        is ConversationEffect.EndConversation -> "endConversation"
        ConversationEffect.RememberFalseBargeInConversation -> "rememberFalseBargeInConversation"
        ConversationEffect.ForceEndUtterance -> "forceEndUtterance"
        is ConversationEffect.ContinueUtterance -> "continueUtterance"
        is ConversationEffect.ResetVad -> "resetVad"
        is ConversationEffect.SetCaptureMuted -> "setCaptureMuted"
        ConversationEffect.PauseCapture -> "pauseCapture"
        ConversationEffect.ResumeCapture -> "resumeCapture"
        is ConversationEffect.PlayMessage -> "playMessage"
        ConversationEffect.TranscribeToDraft -> "transcribeToDraft"
    }

    /** The outputRoute group runs only platform=android: TYPE_* constant names are read via AudioDeviceInfo field reflection and fed to production routeForOutputs. */
    @Test
    fun outputRouteCases() {
        val all = cases("outputRoute").filter { it["input"]!!.jsonObject.str("platform") == "android" }
        assertTrue(all.isNotEmpty())
        for (case in all) {
            val types = case["input"]!!.jsonObject["outputs"]!!.jsonArray.map { name ->
                AudioDeviceInfo::class.java.getField(name.jsonPrimitive.content).getInt(null)
            }
            assertEquals(case.str("id"), case.str("expected"), routeForOutputs(types).rawValue)
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
