package ai.oriveo.community.core.voice.conversation

import java.text.Normalizer

/**
 * Voice conversation turn contract voice-conversation.v1 (shared/voice-contracts/voice-conversation.v1.json).
 * Pure functions: no IO, no clock; time only enters through the events' atMs. The operation order mirrors the contract fixture line by line.
 */
object VoiceConversationConstants {
    const val FRAME_MS = 20
    const val VAD_START_MS = 120
    const val VAD_END_SILENCE_MS = 600
    const val VAD_MIN_UTTERANCE_MS = 250
    const val VAD_PREROLL_MS = 300
    const val VAD_START_OVER_FLOOR_DB = 12.0
    const val VAD_CONTINUE_OVER_FLOOR_DB = 6.0
    const val VAD_ABSOLUTE_MIN_DB = -55.0
    const val FLOOR_INIT_DB = -50.0
    const val FLOOR_ALPHA = 0.05
    const val FLOOR_MIN_DB = -90.0
    const val FLOOR_MAX_DB = -30.0
    const val FRAME_MIN_DB = -120.0
    const val FRAME_MAX_DB = 0.0
    const val BARGE_IN_GRACE_MS = 1000
    const val BARGE_IN_MIN_SPEECH_MS = 300
    const val ECHO_OVERLAP_RATIO = 0.6
    const val FALSE_BARGE_INS_PER_CONVERSATION = 2
    const val CONVERSATIONS_TO_REMEMBER = 2
    const val IDLE_TIMEOUT_MS = 120_000L
    const val THINKING_EARCON_MS = 3_000L
    const val LISTEN_TO_THINK_TAP_GUARD_MS = 600L
    const val STOP_TO_VOICE_GUARD_MS = 500L
    const val STT_RETRIES = 1

    const val PREROLL_FRAMES = VAD_PREROLL_MS / FRAME_MS
}

// ───────────── A. VAD ─────────────

enum class ConversationRoute(val rawValue: String) {
    SPEAKER("speaker"),
    HEADPHONES("headphones"),
    BLUETOOTH("bluetooth"),
    ;

    companion object {
        /** Unknown values map to the speaker. */
        fun from(raw: String?): ConversationRoute = entries.firstOrNull { it.rawValue == raw } ?: SPEAKER
    }
}

sealed interface VadEvent {
    val frame: Long

    data class SpeechStart(override val frame: Long, val prerollFrame: Long) : VadEvent
    data class SpeechEnd(override val frame: Long, val voicedMs: Int) : VadEvent
    data class Discarded(override val frame: Long) : VadEvent
}

/** Streaming VAD: the host feeds it frame by frame; [runVad] is its fold over a whole sequence. */
class VoiceConversationVad {
    private var floor = VoiceConversationConstants.FLOOR_INIT_DB
    private var speaking = false
    private var run = 0
    private var runStart = -1L
    private var silence = 0
    private var voicedMs = 0

    /** Whether we are inside an established stretch of speech. */
    val isSpeaking: Boolean get() = speaking

    /**
     * Feeds frame [index]. [playbackStartFrame] is the frame at which speaker playback started (null = not playing); barge-in candidate mode is only entered when [route] is the speaker.
     */
    fun step(index: Long, rawDb: Double, route: ConversationRoute, playbackStartFrame: Long?): VadEvent? {
        val k = VoiceConversationConstants
        val db = clampFrameDb(rawDb)
        val candidate = route == ConversationRoute.SPEAKER && playbackStartFrame != null
        val inCandidate = candidate && index >= playbackStartFrame
        if (inCandidate && index < playbackStartFrame + GRACE_FRAMES) {
            run = 0
            return null
        }
        if (!speaking) {
            val voiced = db >= floor + k.VAD_START_OVER_FLOOR_DB && db >= k.VAD_ABSOLUTE_MIN_DB
            if (voiced) {
                if (run == 0) runStart = index
                run++
                val need = (if (inCandidate) k.BARGE_IN_MIN_SPEECH_MS else k.VAD_START_MS) / k.FRAME_MS
                if (run >= need) {
                    speaking = true
                    voicedMs = run * k.FRAME_MS
                    silence = 0
                    run = 0
                    return VadEvent.SpeechStart(runStart, maxOf(0L, runStart - k.PREROLL_FRAMES))
                }
            } else {
                run = 0
                floor = updateFloor(floor, db)
            }
        } else if (db >= floor + k.VAD_CONTINUE_OVER_FLOOR_DB) {
            voicedMs += k.FRAME_MS
            silence = 0
        } else {
            silence++
            floor = updateFloor(floor, db)
            if (silence >= END_FRAMES) {
                val event = if (voicedMs >= k.VAD_MIN_UTTERANCE_MS) {
                    VadEvent.SpeechEnd(index, voicedMs)
                } else {
                    VadEvent.Discarded(index)
                }
                speaking = false
                silence = 0
                voicedMs = 0
                return event
            }
        }
        return null
    }

    /** The host force-ends the current speech (tap the orb for "I'm done"): returns the end event and goes back to not speaking; null when nobody is speaking. */
    fun forceEnd(index: Long): VadEvent? {
        if (!speaking) return null
        val event = VadEvent.SpeechEnd(index, voicedMs)
        speaking = false
        silence = 0
        voicedMs = 0
        run = 0
        return event
    }

    /** Drops the speech in progress (mute, capture paused); the noise floor is kept. */
    fun resetUtterance() {
        speaking = false
        silence = 0
        voicedMs = 0
        run = 0
    }

    private companion object {
        val GRACE_FRAMES = VoiceConversationConstants.BARGE_IN_GRACE_MS / VoiceConversationConstants.FRAME_MS
        val END_FRAMES = VoiceConversationConstants.VAD_END_SILENCE_MS / VoiceConversationConstants.FRAME_MS

        fun clampFrameDb(db: Double): Double {
            if (!(db >= VoiceConversationConstants.FRAME_MIN_DB)) return VoiceConversationConstants.FRAME_MIN_DB
            return if (db > VoiceConversationConstants.FRAME_MAX_DB) VoiceConversationConstants.FRAME_MAX_DB else db
        }

        fun updateFloor(floor: Double, db: Double): Double {
            val f = floor + VoiceConversationConstants.FLOOR_ALPHA * (db - floor)
            return when {
                f < VoiceConversationConstants.FLOOR_MIN_DB -> VoiceConversationConstants.FLOOR_MIN_DB
                f > VoiceConversationConstants.FLOOR_MAX_DB -> VoiceConversationConstants.FLOOR_MAX_DB
                else -> f
            }
        }
    }
}

fun runVad(
    frames: List<Double>,
    route: ConversationRoute = ConversationRoute.SPEAKER,
    playbackStartFrame: Long? = null,
): List<VadEvent> {
    val vad = VoiceConversationVad()
    return frames.mapIndexedNotNull { index, db -> vad.step(index.toLong(), db, route, playbackStartFrame) }
}

// ───────────── B. Self-echo detection ─────────────

data class EchoVerdict(val echo: Boolean, val overlap: Double?)

private val SINGLE_UNIT_RANGES = arrayOf(
    0x1100..0x11ff, 0x2e80..0x2fdf, 0x3005..0x3005, 0x3007..0x3007, 0x3021..0x3029, 0x3038..0x303b,
    0x3040..0x30ff, 0x3130..0x318f, 0x31f0..0x31ff, 0x3400..0x4dbf, 0x4e00..0x9fff, 0xa960..0xa97f,
    0xac00..0xd7ff, 0xf900..0xfaff, 0xff66..0xff9f, 0xffa0..0xffdc, 0x1b000..0x1b16f, 0x20000..0x3ffff,
)

private fun isSeparator(cp: Int): Boolean {
    if (cp in 0xFE00..0xFE0F || cp in 0xE0100..0xE01EF) return true
    return when (Character.getType(cp).toByte()) {
        Character.CONNECTOR_PUNCTUATION, Character.DASH_PUNCTUATION, Character.START_PUNCTUATION,
        Character.END_PUNCTUATION, Character.INITIAL_QUOTE_PUNCTUATION, Character.FINAL_QUOTE_PUNCTUATION,
        Character.OTHER_PUNCTUATION,
        Character.MATH_SYMBOL, Character.CURRENCY_SYMBOL, Character.MODIFIER_SYMBOL, Character.OTHER_SYMBOL,
        Character.SPACE_SEPARATOR, Character.LINE_SEPARATOR, Character.PARAGRAPH_SEPARATOR,
        Character.CONTROL, Character.FORMAT,
        -> true
        else -> false
    }
}

private fun isSingleUnit(cp: Int): Boolean = SINGLE_UNIT_RANGES.any { cp in it }

/** Echo comparison units: NFKC, lowercased, walked by code point; separators split and are dropped; each Han / kana / Hangul character is its own unit. */
fun echoUnits(text: String): List<String> {
    val units = mutableListOf<String>()
    val buf = StringBuilder()
    fun flush() {
        if (buf.isNotEmpty()) units += buf.toString()
        buf.setLength(0)
    }
    Normalizer.normalize(text, Normalizer.Form.NFKC).lowercase().codePoints().forEach { cp ->
        when {
            isSeparator(cp) -> flush()
            isSingleUnit(cp) -> {
                flush()
                units += String(Character.toChars(cp))
            }
            else -> buf.appendCodePoint(cp)
        }
    }
    flush()
    return units
}

/** [sentences] are the previous sentence and the one now playing (missing ones are omitted). */
fun isEcho(transcript: String, sentences: List<String>): EchoVerdict {
    val t = echoUnits(transcript)
    if (t.isEmpty()) return EchoVerdict(echo = true, overlap = null)
    val pool = HashMap<String, Int>()
    for (s in sentences) for (u in echoUnits(s)) pool[u] = (pool[u] ?: 0) + 1
    var hit = 0
    for (u in t) {
        val n = pool[u] ?: 0
        if (n > 0) {
            hit++
            pool[u] = n - 1
        }
    }
    val ratio = hit.toDouble() / t.size
    return EchoVerdict(ratio >= VoiceConversationConstants.ECHO_OVERLAP_RATIO, Math.round(ratio * 10000) / 10000.0)
}

// ───────────── C. State machine ─────────────

enum class ConversationPhase { IDLE, LISTENING, THINKING, SPEAKING, ENDED }

enum class ReplyStatus { NONE, STREAMING, COMPLETED }

data class ConversationState(
    val phase: ConversationPhase = ConversationPhase.IDLE,
    val route: ConversationRoute = ConversationRoute.SPEAKER,
    val deviceRemembersNoSpeakerBargeIn: Boolean = false,
    val speakerBargeIn: Boolean = true,
    val userSpeaking: Boolean = false,
    val muted: Boolean = false,
    val awaitingApproval: Boolean = false,
    val error: Boolean = false,
    val interrupted: Boolean = false,
    val screenReaderSpeaking: Boolean = false,
    val messagePlaying: Boolean = false,
    val falseBargeIns: Int = 0,
    val playbackStopped: Boolean = false,
    val sttAttempts: Int = 0,
    val awaitedUtteranceId: String? = null,
    val bargeIn: Boolean = false,
    val reply: ReplyStatus = ReplyStatus.NONE,
    val drained: Boolean = false,
    val thinkingSinceMs: Long? = null,
    val thinkingEarconPlayed: Boolean = false,
    val lastActivityMs: Long? = null,
    val previousSentence: String? = null,
    val currentSentence: String? = null,
)

fun initialConversationState(): ConversationState = ConversationState()

enum class EndReason(val rawValue: String) { USER("user"), SYSTEM("system"), IDLE("idle"), ERROR("error") }

enum class VoicePromptKind(val rawValue: String) { DID_NOT_CATCH("didNotCatch"), APPROVAL_NEEDED("approvalNeeded") }

enum class EarconKind(val rawValue: String) { THINKING("thinking"), END("end") }

enum class ResumeFrom(val rawValue: String) { PAUSE_POINT("pausePoint"), SENTENCE_START("sentenceStart") }

sealed interface ConversationEvent {
    val atMs: Long

    data class Start(
        override val atMs: Long,
        val route: ConversationRoute,
        val deviceRemembersNoSpeakerBargeIn: Boolean,
    ) : ConversationEvent
    data class VadSpeechStart(override val atMs: Long) : ConversationEvent
    data class VadSpeechEnd(override val atMs: Long, val utteranceId: String) : ConversationEvent
    data class VadDiscarded(override val atMs: Long) : ConversationEvent
    data class BargeInDetected(override val atMs: Long) : ConversationEvent
    data class SttResult(override val atMs: Long, val utteranceId: String, val text: String) : ConversationEvent
    data class SttFailed(override val atMs: Long, val utteranceId: String) : ConversationEvent
    data class ReplySentence(override val atMs: Long, val text: String) : ConversationEvent
    data class SentenceStarted(override val atMs: Long, val text: String) : ConversationEvent
    data class ReplyCompleted(override val atMs: Long) : ConversationEvent
    data class PlaybackDrained(override val atMs: Long) : ConversationEvent
    data class ReplyFailed(override val atMs: Long, val code: String) : ConversationEvent
    data class ApprovalPending(override val atMs: Long) : ConversationEvent
    data class ApprovalResolved(override val atMs: Long) : ConversationEvent
    data class TapOrb(override val atMs: Long) : ConversationEvent
    data class ToggleMute(override val atMs: Long) : ConversationEvent
    /** One-shot timer at [nextDeadlineMs]; not activity, so it doesn't refresh lastActivityMs. */
    data class Deadline(override val atMs: Long) : ConversationEvent
    data class InterruptionBegan(override val atMs: Long) : ConversationEvent
    data class InterruptionEnded(override val atMs: Long) : ConversationEvent
    data class ScreenReaderSpeaking(override val atMs: Long, val speaking: Boolean) : ConversationEvent
    data class RouteChanged(override val atMs: Long, val route: ConversationRoute) : ConversationEvent
    data class PlayMessage(override val atMs: Long, val messageId: String) : ConversationEvent
    data class MessagePlaybackEnded(override val atMs: Long) : ConversationEvent

    /** [reason] is only user / system (anything else counts as system). */
    data class End(override val atMs: Long, val reason: EndReason) : ConversationEvent
}

sealed interface ConversationEffect {
    data object StartCapture : ConversationEffect
    data class Transcribe(val utteranceId: String) : ConversationEffect
    data class SendMessage(val text: String) : ConversationEffect
    data object CancelGeneration : ConversationEffect
    data class EnqueueSpeech(val text: String) : ConversationEffect
    data object PausePlayback : ConversationEffect
    data class ResumePlayback(val from: ResumeFrom) : ConversationEffect
    data object StopPlayback : ConversationEffect
    data class SpeakPrompt(val prompt: VoicePromptKind) : ConversationEffect
    data class Earcon(val kind: EarconKind) : ConversationEffect
    data class EndConversation(val reason: EndReason, val code: String? = null) : ConversationEffect
    data object RememberFalseBargeInConversation : ConversationEffect
    data object ForceEndUtterance : ConversationEffect
    data class SetCaptureMuted(val muted: Boolean) : ConversationEffect
    data object PauseCapture : ConversationEffect
    data object ResumeCapture : ConversationEffect
    data class PlayMessage(val messageId: String) : ConversationEffect
    data object TranscribeToDraft : ConversationEffect
}

data class Reduction(val state: ConversationState, val effects: List<ConversationEffect>)

private fun ConversationState.computeSpeakerBargeIn(): Boolean =
    route != ConversationRoute.SPEAKER ||
        !(deviceRemembersNoSpeakerBargeIn || falseBargeIns >= VoiceConversationConstants.FALSE_BARGE_INS_PER_CONVERSATION)

private fun ConversationState.resetTurn(): ConversationState = copy(
    userSpeaking = false,
    playbackStopped = false,
    sttAttempts = 0,
    awaitedUtteranceId = null,
    bargeIn = false,
    reply = ReplyStatus.NONE,
    drained = false,
    thinkingSinceMs = null,
    thinkingEarconPlayed = false,
    previousSentence = null,
    currentSentence = null,
)

private fun ConversationState.toListening(t: Long) =
    resetTurn().copy(phase = ConversationPhase.LISTENING, lastActivityMs = t)

private fun ConversationState.toThinking(t: Long) =
    resetTurn().copy(userSpeaking = userSpeaking, phase = ConversationPhase.THINKING, thinkingSinceMs = t)

private fun ConversationState.maybeFinish(t: Long): ConversationState =
    if (phase == ConversationPhase.SPEAKING && reply == ReplyStatus.COMPLETED && (drained || playbackStopped) && !bargeIn) {
        toListening(t)
    } else {
        this
    }

private fun ConversationState.toggledMute(fx: MutableList<ConversationEffect>): ConversationState {
    val m = !muted
    fx += ConversationEffect.SetCaptureMuted(m)
    return copy(muted = m, userSpeaking = if (m) false else userSpeaking)
}

private fun ConversationState.idleQuiet(): Boolean =
    !muted && !userSpeaking && !awaitingApproval && !interrupted && !screenReaderSpeaking && !messagePlaying

private fun ConversationState.thinkingEarconPending(): Boolean =
    !thinkingEarconPlayed && !awaitingApproval && !interrupted

/**
 * When the host should dispatch the next [ConversationEvent.Deadline]; null = no timer armed.
 * The host re-arms one one-shot timer after every reduce instead of polling.
 */
fun nextDeadlineMs(state: ConversationState): Long? = when {
    state.phase == ConversationPhase.LISTENING && state.idleQuiet() ->
        state.lastActivityMs?.let { it + VoiceConversationConstants.IDLE_TIMEOUT_MS }
    state.phase == ConversationPhase.THINKING && state.thinkingEarconPending() ->
        state.thinkingSinceMs?.let { it + VoiceConversationConstants.THINKING_EARCON_MS }
    else -> null
}

/** Turn state machine: does not mutate its input; returns the new state and the effects to run in order. */
fun reduce(state: ConversationState, event: ConversationEvent): Reduction {
    val unchanged = Reduction(state, emptyList())
    if (state.phase == ConversationPhase.ENDED) return unchanged
    if (state.phase == ConversationPhase.IDLE && event !is ConversationEvent.Start) return unchanged
    val t = event.atMs
    var s = if (event is ConversationEvent.Deadline) state else state.copy(lastActivityMs = t)
    // A dropped event still counts as activity: the original state with only lastActivityMs refreshed.
    val dropped = Reduction(s, emptyList())
    val fx = mutableListOf<ConversationEffect>()

    val isVad = event is ConversationEvent.VadSpeechStart || event is ConversationEvent.VadSpeechEnd ||
        event is ConversationEvent.VadDiscarded || event is ConversationEvent.BargeInDetected
    if (isVad) {
        if (s.muted || s.interrupted || s.screenReaderSpeaking || s.messagePlaying || s.phase == ConversationPhase.THINKING) {
            return dropped
        }
        if (s.phase == ConversationPhase.SPEAKING && (!s.speakerBargeIn || s.awaitedUtteranceId != null)) return dropped
    }

    when (event) {
        is ConversationEvent.Start -> {
            if (s.phase == ConversationPhase.IDLE) {
                s = s.copy(route = event.route, deviceRemembersNoSpeakerBargeIn = event.deviceRemembersNoSpeakerBargeIn)
                s = s.copy(speakerBargeIn = s.computeSpeakerBargeIn(), phase = ConversationPhase.LISTENING)
                fx += ConversationEffect.StartCapture
            }
        }
        is ConversationEvent.VadSpeechStart -> s = s.copy(userSpeaking = true)
        is ConversationEvent.VadSpeechEnd -> {
            if (!s.userSpeaking) return dropped
            s = s.copy(userSpeaking = false)
            if (s.phase == ConversationPhase.LISTENING) {
                s = s.toThinking(t).copy(awaitedUtteranceId = event.utteranceId, sttAttempts = 1)
                fx += ConversationEffect.Transcribe(event.utteranceId)
            } else if (s.bargeIn) {
                s = s.copy(awaitedUtteranceId = event.utteranceId, sttAttempts = 1)
                fx += ConversationEffect.Transcribe(event.utteranceId)
            }
        }
        is ConversationEvent.VadDiscarded -> {
            if (!s.userSpeaking) return dropped
            s = s.copy(userSpeaking = false)
            if (s.phase == ConversationPhase.SPEAKING && s.bargeIn) {
                s = s.copy(bargeIn = false)
                if (!s.playbackStopped) fx += ConversationEffect.ResumePlayback(ResumeFrom.PAUSE_POINT)
                s = s.maybeFinish(t)
            }
        }
        is ConversationEvent.BargeInDetected -> {
            if (s.phase == ConversationPhase.SPEAKING && !s.bargeIn && s.userSpeaking) {
                s = s.copy(bargeIn = true)
                if (!s.playbackStopped) fx += ConversationEffect.PausePlayback
            }
        }
        is ConversationEvent.SttResult -> {
            if (s.awaitedUtteranceId == null || event.utteranceId != s.awaitedUtteranceId) return dropped
            s = s.copy(awaitedUtteranceId = null)
            val text = event.text
            if (s.bargeIn) {
                val spoken = listOfNotNull(s.previousSentence, s.currentSentence)
                if (isEcho(text, spoken).echo) {
                    s = s.copy(bargeIn = false)
                    if (!s.playbackStopped) fx += ConversationEffect.ResumePlayback(ResumeFrom.SENTENCE_START)
                    if (s.route == ConversationRoute.SPEAKER) {
                        s = s.copy(falseBargeIns = s.falseBargeIns + 1)
                        if (s.falseBargeIns == VoiceConversationConstants.FALSE_BARGE_INS_PER_CONVERSATION) {
                            s = s.copy(speakerBargeIn = s.computeSpeakerBargeIn())
                            fx += ConversationEffect.RememberFalseBargeInConversation
                        }
                    }
                    s = s.maybeFinish(t)
                } else {
                    fx += ConversationEffect.CancelGeneration
                    fx += ConversationEffect.SendMessage(text)
                    s = s.toThinking(t).copy(reply = ReplyStatus.STREAMING)
                }
            } else if (echoUnits(text).isEmpty()) {
                s = s.toListening(t)
            } else {
                fx += ConversationEffect.SendMessage(text)
                s = s.copy(reply = ReplyStatus.STREAMING)
            }
        }
        is ConversationEvent.SttFailed -> {
            if (s.awaitedUtteranceId == null || event.utteranceId != s.awaitedUtteranceId) return dropped
            if (s.sttAttempts <= VoiceConversationConstants.STT_RETRIES) {
                s = s.copy(sttAttempts = s.sttAttempts + 1)
                fx += ConversationEffect.Transcribe(event.utteranceId)
            } else {
                if (s.bargeIn) fx += ConversationEffect.CancelGeneration
                fx += ConversationEffect.SpeakPrompt(VoicePromptKind.DID_NOT_CATCH)
                s = s.toListening(t)
            }
        }
        is ConversationEvent.ReplySentence -> {
            if (s.reply != ReplyStatus.STREAMING ||
                (s.phase != ConversationPhase.THINKING && s.phase != ConversationPhase.SPEAKING)
            ) {
                return dropped
            }
            s = s.copy(phase = ConversationPhase.SPEAKING)
            if (!s.playbackStopped) {
                s = s.copy(drained = false)
                fx += ConversationEffect.EnqueueSpeech(event.text)
            }
        }
        is ConversationEvent.SentenceStarted -> {
            if (s.phase != ConversationPhase.SPEAKING) return dropped
            s = s.copy(previousSentence = s.currentSentence, currentSentence = event.text)
        }
        is ConversationEvent.ReplyCompleted -> {
            if (s.reply != ReplyStatus.STREAMING) return dropped
            s = s.copy(reply = ReplyStatus.COMPLETED)
            s = if (s.phase == ConversationPhase.THINKING) s.toListening(t) else s.maybeFinish(t)
        }
        is ConversationEvent.PlaybackDrained -> {
            if (s.phase != ConversationPhase.SPEAKING) return dropped
            s = s.copy(drained = true).maybeFinish(t)
        }
        is ConversationEvent.ReplyFailed -> {
            if (s.reply != ReplyStatus.STREAMING) return dropped
            s = s.copy(error = true, phase = ConversationPhase.ENDED)
            fx += ConversationEffect.EndConversation(EndReason.ERROR, event.code)
        }
        is ConversationEvent.ApprovalPending -> {
            if (!s.awaitingApproval) {
                s = s.copy(awaitingApproval = true)
                fx += ConversationEffect.SpeakPrompt(VoicePromptKind.APPROVAL_NEEDED)
            }
        }
        is ConversationEvent.ApprovalResolved -> s = s.copy(awaitingApproval = false)
        is ConversationEvent.TapOrb -> when {
            s.awaitingApproval -> Unit
            s.muted && s.phase == ConversationPhase.LISTENING -> s = s.toggledMute(fx)
            s.phase == ConversationPhase.LISTENING -> if (s.userSpeaking) fx += ConversationEffect.ForceEndUtterance
            s.phase == ConversationPhase.THINKING -> {
                if (t - (s.thinkingSinceMs ?: 0L) >= VoiceConversationConstants.LISTEN_TO_THINK_TAP_GUARD_MS) {
                    fx += ConversationEffect.CancelGeneration
                    s = s.toListening(t)
                }
            }
            s.phase == ConversationPhase.SPEAKING && !s.playbackStopped -> {
                s = s.copy(playbackStopped = true)
                fx += ConversationEffect.StopPlayback
                s = s.maybeFinish(t)
            }
        }
        is ConversationEvent.ToggleMute -> s = s.toggledMute(fx)
        is ConversationEvent.Deadline -> {
            if (s.phase == ConversationPhase.LISTENING) {
                if (s.idleQuiet() && t - (s.lastActivityMs ?: 0L) >= VoiceConversationConstants.IDLE_TIMEOUT_MS) {
                    s = s.copy(phase = ConversationPhase.ENDED)
                    fx += ConversationEffect.Earcon(EarconKind.END)
                    fx += ConversationEffect.EndConversation(EndReason.IDLE)
                }
            } else if (s.phase == ConversationPhase.THINKING) {
                if (s.thinkingEarconPending() &&
                    t - (s.thinkingSinceMs ?: 0L) >= VoiceConversationConstants.THINKING_EARCON_MS
                ) {
                    s = s.copy(thinkingEarconPlayed = true)
                    fx += ConversationEffect.Earcon(EarconKind.THINKING)
                }
            }
        }
        is ConversationEvent.InterruptionBegan -> {
            if (!s.interrupted) {
                s = s.copy(interrupted = true, userSpeaking = false)
                if (s.phase == ConversationPhase.SPEAKING && !s.playbackStopped) fx += ConversationEffect.PausePlayback
                fx += ConversationEffect.PauseCapture
            }
        }
        is ConversationEvent.InterruptionEnded -> {
            if (s.interrupted) {
                s = s.copy(interrupted = false)
                if (s.phase == ConversationPhase.SPEAKING && !s.playbackStopped) {
                    s = s.copy(playbackStopped = true)
                    fx += ConversationEffect.StopPlayback
                }
                fx += ConversationEffect.ResumeCapture
                s = s.maybeFinish(t)
            }
        }
        is ConversationEvent.ScreenReaderSpeaking -> {
            s = s.copy(screenReaderSpeaking = event.speaking, userSpeaking = if (event.speaking) false else s.userSpeaking)
        }
        is ConversationEvent.RouteChanged -> {
            val prev = s.route
            s = s.copy(route = event.route)
            s = s.copy(speakerBargeIn = s.computeSpeakerBargeIn())
            if (prev != ConversationRoute.SPEAKER && s.route == ConversationRoute.SPEAKER &&
                s.phase == ConversationPhase.SPEAKING && !s.playbackStopped
            ) {
                s = s.copy(playbackStopped = true)
                fx += ConversationEffect.StopPlayback
                s = s.maybeFinish(t)
            }
        }
        is ConversationEvent.PlayMessage -> {
            if (s.phase != ConversationPhase.LISTENING || s.messagePlaying || s.interrupted) return dropped
            s = s.copy(messagePlaying = true, userSpeaking = false)
            fx += ConversationEffect.PauseCapture
            fx += ConversationEffect.PlayMessage(event.messageId)
        }
        is ConversationEvent.MessagePlaybackEnded -> {
            if (s.messagePlaying) {
                s = s.copy(messagePlaying = false)
                fx += ConversationEffect.ResumeCapture
            }
        }
        is ConversationEvent.End -> {
            val reason = if (event.reason == EndReason.USER) EndReason.USER else EndReason.SYSTEM
            if (reason == EndReason.USER && s.userSpeaking) fx += ConversationEffect.TranscribeToDraft
            fx += ConversationEffect.EndConversation(reason)
            s = s.copy(phase = ConversationPhase.ENDED)
        }
    }
    return Reduction(s, fx)
}

/** Display state, read-only for the UI; null for idle / ended (except on error). */
enum class ConversationDisplayState(val rawValue: String) {
    LISTENING("listening"),
    THINKING("thinking"),
    SPEAKING("speaking"),
    MUTED("muted"),
    AWAITING_APPROVAL("awaitingApproval"),
    ERROR("error"),
}

/** Status keys: the display states plus "speaking · tap to interrupt". */
enum class ConversationStatusKey(val rawValue: String) {
    LISTENING("listening"),
    THINKING("thinking"),
    SPEAKING("speaking"),
    SPEAKING_TAP_TO_INTERRUPT("speakingTapToInterrupt"),
    MUTED("muted"),
    AWAITING_APPROVAL("awaitingApproval"),
    ERROR("error"),
}

fun displayState(state: ConversationState): ConversationDisplayState? = when {
    state.error -> ConversationDisplayState.ERROR
    state.phase == ConversationPhase.IDLE || state.phase == ConversationPhase.ENDED -> null
    state.awaitingApproval -> ConversationDisplayState.AWAITING_APPROVAL
    state.muted && state.phase == ConversationPhase.LISTENING -> ConversationDisplayState.MUTED
    state.phase == ConversationPhase.LISTENING -> ConversationDisplayState.LISTENING
    state.phase == ConversationPhase.THINKING -> ConversationDisplayState.THINKING
    else -> ConversationDisplayState.SPEAKING
}

fun statusKey(state: ConversationState): ConversationStatusKey? = when (displayState(state)) {
    null -> null
    ConversationDisplayState.LISTENING -> ConversationStatusKey.LISTENING
    ConversationDisplayState.THINKING -> ConversationStatusKey.THINKING
    ConversationDisplayState.SPEAKING ->
        if (state.route == ConversationRoute.SPEAKER && !state.speakerBargeIn) {
            ConversationStatusKey.SPEAKING_TAP_TO_INTERRUPT
        } else {
            ConversationStatusKey.SPEAKING
        }
    ConversationDisplayState.MUTED -> ConversationStatusKey.MUTED
    ConversationDisplayState.AWAITING_APPROVAL -> ConversationStatusKey.AWAITING_APPROVAL
    ConversationDisplayState.ERROR -> ConversationStatusKey.ERROR
}
