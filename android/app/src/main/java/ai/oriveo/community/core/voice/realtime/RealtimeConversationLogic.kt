package ai.oriveo.community.core.voice.realtime

import ai.oriveo.community.core.voice.conversation.ConversationStatusKey
import ai.oriveo.community.core.voice.conversation.echoUnits

/**
 * Native realtime conversation state machine, contract realtime-conversation.v1
 * (shared/voice-contracts/realtime-conversation.v1.json). Pure: no IO, no clock; time only enters via [RealtimeConversationInput.Tick].
 * The operation order mirrors the shared contract fixture line by line.
 */
object RealtimeConversationConstants {
    const val IDLE_END_MS = 120_000L
    const val THINKING_EARCON_MS = 3_000L
    const val LATE_USER_TRANSCRIPT_MS = 3_000L
    const val MUTE_SILENCE_MS = 1_000L
}

enum class RealtimePhase { CONNECTING, LISTENING, THINKING, SPEAKING, ENDED }

/** Current turn. userAfterReply: the user spoke after the reply started (barge-in); that utterance belongs to the next turn. */
data class RealtimeTurn(
    val userPending: Boolean = false,
    val userText: String = "",
    val assistantStarted: Boolean = false,
    val assistantDone: Boolean = false,
    val assistantText: String = "",
    val heldMs: Long = 0,
    val userAfterReply: Boolean = false,
)

data class RealtimeConversationState(
    val phase: RealtimePhase = RealtimePhase.CONNECTING,
    val muted: Boolean = false,
    /** The server expired the session while muted (sessionExpired): the connection is dead; unmute reopens it with text history . */
    val dormant: Boolean = false,
    /** Reopened after an expiry with no conversation progress yet: another expiry ends with an error . */
    val reopenAwaitingProgress: Boolean = false,
    /** The screen reader is announcing: the uplink pauses without touching mute; uplink on = not muted and not announcing (mute wins). */
    val screenReaderSpeaking: Boolean = false,
    val userSpeaking: Boolean = false,
    /** assistantTurnDone arrived while speaking: wait for playbackDrained before going back to listening. */
    val drainPending: Boolean = false,
    /** A barge-in utterance went final first: the interrupted reply was already written, its assistantTurnDone writes nothing. */
    val replyFlushed: Boolean = false,
    val turn: RealtimeTurn = RealtimeTurn(),
    val idleMs: Long = 0,
    val thinkingMs: Long = 0,
    val earconDone: Boolean = false,
)

/** Closed input set: the unified session events plus local host inputs. */
sealed interface RealtimeConversationInput {
    data class Session(val event: RealtimeSessionEvent) : RealtimeConversationInput

    data object Mute : RealtimeConversationInput
    data object Unmute : RealtimeConversationInput
    data object TapOrb : RealtimeConversationInput
    data object PlaybackDrained : RealtimeConversationInput
    /** Elapsed time; the host sends one before every other input and when the [RealtimeConversationLogic.nextTickMs] timer fires. */
    data class Tick(val ms: Long) : RealtimeConversationInput
    data object End : RealtimeConversationInput
    data object SystemInterruption : RealtimeConversationInput

    /** Sent by the host when the session stream throws or the connection drops unexpectedly. */
    data class Failed(val code: String?) : RealtimeConversationInput

    /** Sent by the host when a Gemini Live stream ends because the server expired the session (close 1008 after ready). */
    data object SessionExpired : RealtimeConversationInput

    /**
     * Sent by the host when a turn-boundary replan (off the main thread, currentSessionId = the open session) got a
     * fingerprint different from the open session's (realtime-session.v1).
     */
    data object PlanChanged : RealtimeConversationInput

    /** Sent by the host when the screen reader starts / finishes announcing the status word. */
    data class ScreenReaderSpeaking(val speaking: Boolean) : RealtimeConversationInput
}

enum class RealtimePersistRole(val rawValue: String) { USER("user"), ASSISTANT("assistant") }

enum class RealtimeEndReason(val rawValue: String) { USER("user"), SYSTEM("system"), IDLE("idle"), ERROR("error") }

/** Closed effect set. */
sealed interface RealtimeConversationEffect {
    val type: String

    data class Persist(val role: RealtimePersistRole, val text: String) : RealtimeConversationEffect {
        override val type = "persist"
    }

    data object InterruptPlayback : RealtimeConversationEffect {
        override val type = "interruptPlayback"
    }

    data class SendSilence(val ms: Long) : RealtimeConversationEffect {
        override val type = "sendSilence"
    }

    data class SetUplink(val on: Boolean) : RealtimeConversationEffect {
        override val type = "setUplink"
    }

    data object Earcon : RealtimeConversationEffect {
        override val type = "earcon"
    }

    data class ShowError(val code: String?) : RealtimeConversationEffect {
        override val type = "showError"
    }

    data class WriteDraft(val text: String) : RealtimeConversationEffect {
        override val type = "writeDraft"
    }

    data object Close : RealtimeConversationEffect {
        override val type = "close"
    }

    data class Ended(val reason: RealtimeEndReason) : RealtimeConversationEffect {
        override val type = "ended"
    }

    /** Open a new session (history includes the transcripts already persisted); its ready arrives as a session event. */
    data object Reopen : RealtimeConversationEffect {
        override val type = "reopen"
    }
}

data class RealtimeConversationResult(
    val state: RealtimeConversationState,
    val effects: List<RealtimeConversationEffect>,
)

object RealtimeConversationLogic {

    /** showError code when the session expires while not muted. */
    const val SESSION_EXPIRED_CODE = "sessionExpired"

    fun initialState(): RealtimeConversationState = RealtimeConversationState()

    /** ended → null; connecting → thinking; listening while muted → muted; otherwise the phase. */
    fun statusKey(state: RealtimeConversationState): ConversationStatusKey? = when (state.phase) {
        RealtimePhase.ENDED -> null
        RealtimePhase.CONNECTING, RealtimePhase.THINKING -> ConversationStatusKey.THINKING
        RealtimePhase.LISTENING -> if (state.muted) ConversationStatusKey.MUTED else ConversationStatusKey.LISTENING
        RealtimePhase.SPEAKING -> ConversationStatusKey.SPEAKING
    }

    /**
     * Milliseconds until the next [RealtimeConversationInput.Tick] can change anything : the host arms one
     * one-shot timer for it after every reduce. Minimum over the held reply, the thinking earcon and the idle end,
     * clamped at 0; null when ended or none applies.
     */
    fun nextTickMs(state: RealtimeConversationState): Long? {
        if (state.phase == RealtimePhase.ENDED) return null
        val waits = buildList {
            if (state.turn.assistantDone && state.turn.userPending) {
                add(RealtimeConversationConstants.LATE_USER_TRANSCRIPT_MS - state.turn.heldMs)
            }
            if (state.phase == RealtimePhase.THINKING && !state.earconDone) {
                add(RealtimeConversationConstants.THINKING_EARCON_MS - state.thinkingMs)
            }
            if (state.phase == RealtimePhase.LISTENING && !state.muted && !state.userSpeaking) {
                add(RealtimeConversationConstants.IDLE_END_MS - state.idleMs)
            }
        }
        return waits.minOrNull()?.coerceAtLeast(0L)
    }

    fun reduce(state: RealtimeConversationState, input: RealtimeConversationInput): RealtimeConversationResult {
        if (state.phase == RealtimePhase.ENDED) return RealtimeConversationResult(state, emptyList())
        val s = Work(state)
        if (input !is RealtimeConversationInput.Tick) s.idleMs = 0
        // Conversation progress clears the reopen guard; ready is not progress.
        if (input is RealtimeConversationInput.Session && isProgress(input.event)) s.reopenAwaitingProgress = false
        when (input) {
            is RealtimeConversationInput.Session -> s.onEvent(input.event)
            RealtimeConversationInput.TapOrb -> if (s.phase == RealtimePhase.SPEAKING) {
                s.fx += RealtimeConversationEffect.InterruptPlayback
                s.toListening()
            }
            RealtimeConversationInput.PlaybackDrained ->
                if (s.phase == RealtimePhase.SPEAKING && s.drainPending) s.toListening()
            RealtimeConversationInput.Mute -> if (!s.muted) {
                s.muted = true
                if (s.userSpeaking) s.fx += RealtimeConversationEffect.SendSilence(RealtimeConversationConstants.MUTE_SILENCE_MS)
                s.fx += RealtimeConversationEffect.SetUplink(false)
            }
            RealtimeConversationInput.Unmute -> if (s.muted) {
                s.muted = false
                if (s.dormant) {
                    // Reopen first, then open the uplink; statusKey is thinking until the new connection is ready.
                    s.dormant = false
                    s.reopenAwaitingProgress = true
                    s.phase = RealtimePhase.CONNECTING
                    s.fx += RealtimeConversationEffect.Reopen
                }
                // The screen reader is still announcing: the uplink opens when it finishes.
                if (!s.screenReaderSpeaking) s.fx += RealtimeConversationEffect.SetUplink(true)
            }
            is RealtimeConversationInput.ScreenReaderSpeaking -> if (s.screenReaderSpeaking != input.speaking) {
                s.screenReaderSpeaking = input.speaking
                // While muted the uplink is already off; announcement start / end leave it alone.
                if (!s.muted) s.fx += RealtimeConversationEffect.SetUplink(!input.speaking)
            }
            RealtimeConversationInput.SessionExpired -> s.onSessionExpired()
            RealtimeConversationInput.PlanChanged -> s.onPlanChanged()
            is RealtimeConversationInput.Tick -> s.onTick(if (input.ms > 0) input.ms else 0)
            RealtimeConversationInput.End -> s.endSession(RealtimeEndReason.USER)
            RealtimeConversationInput.SystemInterruption -> s.endSession(RealtimeEndReason.SYSTEM)
            is RealtimeConversationInput.Failed -> {
                s.fx += RealtimeConversationEffect.ShowError(input.code)
                s.endSession(RealtimeEndReason.ERROR)
            }
        }
        return RealtimeConversationResult(s.freeze(), s.fx.toList())
    }

    private fun isProgress(event: RealtimeSessionEvent): Boolean = event is RealtimeSessionEvent.UserTranscript ||
        event is RealtimeSessionEvent.AssistantAudio ||
        event is RealtimeSessionEvent.AssistantTranscript ||
        event is RealtimeSessionEvent.AssistantTurnDone

    /** Persist only when trimmed text is non-empty and not punctuation / separators only (same set as voice-conversation.v1 isEcho). */
    private fun meaningful(text: String): Boolean = echoUnits(text).isNotEmpty()

    /** Mutable working copy of one reduce step. */
    private class Work(from: RealtimeConversationState) {
        var phase = from.phase
        var muted = from.muted
        var dormant = from.dormant
        var reopenAwaitingProgress = from.reopenAwaitingProgress
        var screenReaderSpeaking = from.screenReaderSpeaking
        var userSpeaking = from.userSpeaking
        var drainPending = from.drainPending
        var replyFlushed = from.replyFlushed
        var turn = from.turn
        var idleMs = from.idleMs
        var thinkingMs = from.thinkingMs
        var earconDone = from.earconDone
        val fx = mutableListOf<RealtimeConversationEffect>()

        fun freeze() = RealtimeConversationState(
            phase, muted, dormant, reopenAwaitingProgress, screenReaderSpeaking, userSpeaking, drainPending, replyFlushed,
            turn, idleMs, thinkingMs, earconDone,
        )

        fun toListening() {
            phase = RealtimePhase.LISTENING
            drainPending = false
        }

        fun persistAssistant() {
            val text = turn.assistantText.trim()
            if (text.isNotEmpty()) fx += RealtimeConversationEffect.Persist(RealtimePersistRole.ASSISTANT, text)
            // The barge-in utterance carries over to the next turn.
            turn = if (turn.userAfterReply) RealtimeTurn(userPending = turn.userPending, userText = turn.userText) else RealtimeTurn()
        }

        /** Release a held reply → writeDraft (reason user, non-final userText) → close → ended. */
        fun endSession(reason: RealtimeEndReason) {
            val draft = if (turn.userPending && meaningful(turn.userText)) turn.userText.trim() else null
            if (turn.assistantDone) persistAssistant()
            if (reason == RealtimeEndReason.USER && draft != null) fx += RealtimeConversationEffect.WriteDraft(draft)
            fx += RealtimeConversationEffect.Close
            fx += RealtimeConversationEffect.Ended(reason)
            phase = RealtimePhase.ENDED
            userSpeaking = false
            drainPending = false
            turn = RealtimeTurn()
        }

        fun onSessionExpired() {
            if (dormant) return
            if (muted) {
                // Expired while muted: keep the call, release a held reply, then sleep until unmute.
                if (turn.assistantDone) persistAssistant()
                dormant = true
                phase = RealtimePhase.LISTENING
                userSpeaking = false
                drainPending = false
                turn = RealtimeTurn()
                return
            }
            if (!reopenAwaitingProgress) {
                // Expired while unmuted: reopen once with text history, uplink gate unchanged; thinking until ready .
                if (turn.assistantDone) persistAssistant()
                reopenAwaitingProgress = true
                phase = RealtimePhase.CONNECTING
                userSpeaking = false
                drainPending = false
                turn = RealtimeTurn()
                fx += RealtimeConversationEffect.Reopen
                return
            }
            // Expired again after a reopen without progress: end with an error.
            fx += RealtimeConversationEffect.ShowError(SESSION_EXPIRED_CODE)
            endSession(RealtimeEndReason.ERROR)
        }

        /** Reopens only from idle listening; mid-turn or dormant it is ignored and the host compares again next boundary. */
        fun onPlanChanged() {
            if (dormant || phase != RealtimePhase.LISTENING || userSpeaking || turn.userPending || turn.assistantStarted) return
            phase = RealtimePhase.CONNECTING
            drainPending = false
            turn = RealtimeTurn()
            fx += RealtimeConversationEffect.Reopen
        }

        fun onEvent(event: RealtimeSessionEvent) {
            when (event) {
                RealtimeSessionEvent.Ready -> if (phase == RealtimePhase.CONNECTING) toListening()
                is RealtimeSessionEvent.UserSpeechStarted -> {
                    // User spoke during playback: stop local playback first (the server confirms later).
                    if (phase == RealtimePhase.SPEAKING) fx += RealtimeConversationEffect.InterruptPlayback
                    // A held reply is released before the new utterance.
                    if (turn.assistantDone) {
                        persistAssistant()
                    } else if (turn.assistantStarted) {
                        turn = turn.copy(userAfterReply = true)
                    }
                    toListening()
                    userSpeaking = true
                    turn = turn.copy(userPending = true)
                    earconDone = false
                    thinkingMs = 0
                }
                is RealtimeSessionEvent.UserSpeechStopped -> {
                    phase = RealtimePhase.THINKING
                    userSpeaking = false
                    thinkingMs = 0
                }
                is RealtimeSessionEvent.UserTranscript -> onUserTranscript(event.text, event.final)
                is RealtimeSessionEvent.AssistantAudio -> {
                    phase = RealtimePhase.SPEAKING
                    turn = turn.copy(assistantStarted = true)
                }
                is RealtimeSessionEvent.AssistantTranscript ->
                    turn = turn.copy(assistantStarted = true, assistantText = event.text)
                RealtimeSessionEvent.Interrupted -> toListening()
                is RealtimeSessionEvent.AssistantTurnDone -> onTurnDone(event.text)
                is RealtimeSessionEvent.SessionEnded -> endSession(RealtimeEndReason.SYSTEM)
                // goAway / resumable belong to the session layer; error is non-fatal (the connection close decides).
                is RealtimeSessionEvent.GoAway, is RealtimeSessionEvent.Resumable, is RealtimeSessionEvent.Error -> Unit
            }
        }

        fun onUserTranscript(text: String, final: Boolean) {
            turn = turn.copy(userText = text)
            if (!final) {
                turn = turn.copy(userPending = true)
                return
            }
            turn = turn.copy(userPending = false)
            if (turn.userAfterReply && !turn.assistantDone) {
                persistAssistant()
                replyFlushed = true
            }
            if (meaningful(text)) fx += RealtimeConversationEffect.Persist(RealtimePersistRole.USER, text.trim())
            if (turn.assistantDone) persistAssistant()
        }

        fun onTurnDone(eventText: String) {
            if (phase == RealtimePhase.SPEAKING) drainPending = true else toListening()
            // Blank event text (after trim) falls back to the latest assistant transcript.
            val text = if (eventText.isBlank()) turn.assistantText else eventText
            if (replyFlushed) {
                replyFlushed = false
                return
            }
            if (turn.userPending && !turn.userAfterReply) {
                // User transcript not final yet: hold a non-blank reply until the user final or lateUserTranscriptMs.
                turn = turn.copy(assistantText = text, assistantDone = text.isNotBlank(), heldMs = 0)
            } else {
                turn = turn.copy(assistantText = text)
                persistAssistant()
            }
        }

        fun onTick(ms: Long) {
            if (turn.assistantDone && turn.userPending) {
                turn = turn.copy(heldMs = turn.heldMs + ms)
                if (turn.heldMs >= RealtimeConversationConstants.LATE_USER_TRANSCRIPT_MS) persistAssistant()
            }
            if (phase == RealtimePhase.THINKING) {
                thinkingMs += ms
                if (thinkingMs >= RealtimeConversationConstants.THINKING_EARCON_MS && !earconDone) {
                    earconDone = true
                    fx += RealtimeConversationEffect.Earcon
                }
            }
            if (phase == RealtimePhase.LISTENING && !muted && !userSpeaking) {
                idleMs += ms
                if (idleMs >= RealtimeConversationConstants.IDLE_END_MS) endSession(RealtimeEndReason.IDLE)
            }
        }
    }
}
