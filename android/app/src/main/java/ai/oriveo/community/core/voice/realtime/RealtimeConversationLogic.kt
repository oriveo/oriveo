package ai.oriveo.community.core.voice.realtime

import ai.oriveo.community.core.voice.conversation.ConversationStatusKey
import ai.oriveo.community.core.voice.conversation.echoUnits
import ai.oriveo.community.core.voice.conversation.isEcho

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

    /** Speaker false barge-ins (gate opened on voice, then an empty or echo transcript) before barge-in is switched off for the session. */
    const val FALSE_BARGE_INS_PER_SESSION = 2
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
    /** The reply finished generating (assistantTurnDone while speaking) but is still playing: persisted on drain (E-451). */
    val awaitingDrain: Boolean = false,
    /** Played ms frozen at interrupt / end (null = not frozen); later text is still revealed and persisted up to it. */
    val frozenPlayedMs: Long? = null,
    /** PCM16 mono samples received this turn. */
    val audioSamples: Long = 0,
    val sampleRateHz: Int = 0,
    /** itemId (null as "") -> played ms reported by the host player. */
    val played: Map<String, Long> = emptyMap(),
    /** Item keys that delivered audio this turn; progress only counts these. */
    val audioItems: List<String> = emptyList(),
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
    /** Echo pool for the next final user transcript after the uplink gate opened on speech; null = nothing to judge. */
    val echoPool: List<String>? = null,
    /** The last persisted assistant reply. */
    val lastReply: String = "",
    val falseBargeIns: Int = 0,
    /** False barge-ins reached the limit: only a tap interrupts playback for the rest of the session. */
    val bargeInOff: Boolean = false,
)

/** Closed input set: the unified session events plus local host inputs. */
sealed interface RealtimeConversationInput {
    data class Session(val event: RealtimeSessionEvent) : RealtimeConversationInput

    data object Mute : RealtimeConversationInput
    data object Unmute : RealtimeConversationInput
    data object TapOrb : RealtimeConversationInput
    data object PlaybackDrained : RealtimeConversationInput

    /** Host player progress for one item: cumulative played ms, floored, never decreasing. */
    data class PlaybackProgress(val itemId: String?, val playedMs: Long) : RealtimeConversationInput
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

    /** Sent by the host when the speaker uplink gate ([RealtimeUplinkGate]) opened on local speech (reason speech). */
    data object GateOpened : RealtimeConversationInput

    /**
     * Sent by the host when the user types while dormant (E-634 overriding E-613): reopens like unmute but leaves mute,
     * the uplink and the screen reader untouched, so the reopened session stays muted. Ignored unless dormant.
     */
    data object Wake : RealtimeConversationInput
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

    /** False barge-ins reached the limit: the host stops opening the uplink gate on speech during playback (setBargeIn(false)). */
    data object DisableBargeIn : RealtimeConversationEffect {
        override val type = "disableBargeIn"
    }
}

data class RealtimeConversationResult(
    val state: RealtimeConversationState,
    val effects: List<RealtimeConversationEffect>,
)

object RealtimeConversationLogic {

    /** showError code when the session expires again after a reopen without progress (E-453: neither network nor quota). */
    const val SESSION_EXPIRED_CODE = "unknown"

    /** Realtime failure categories (E-453, realtime-model.v1 failureCases): showError.code only takes these. */
    val FAILURE_CATEGORIES = listOf("auth", "quota", "model_gone", "max_duration", "network", "unknown")

    private val SESSION_END_LIMIT_REASONS = setOf("max_duration", "timeout")

    fun initialState(): RealtimeConversationState = RealtimeConversationState()

    /** ended → null; connecting → thinking; listening while muted → muted; otherwise the phase. */
    fun statusKey(state: RealtimeConversationState): ConversationStatusKey? = when (state.phase) {
        RealtimePhase.ENDED -> null
        RealtimePhase.CONNECTING, RealtimePhase.THINKING -> ConversationStatusKey.THINKING
        RealtimePhase.LISTENING -> if (state.muted) ConversationStatusKey.MUTED else ConversationStatusKey.LISTENING
        RealtimePhase.SPEAKING ->
            if (state.bargeInOff) ConversationStatusKey.SPEAKING_TAP_TO_INTERRUPT else ConversationStatusKey.SPEAKING
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
        // playbackProgress only arrives during playback; like tick it is not user / session activity.
        if (input !is RealtimeConversationInput.Tick && input !is RealtimeConversationInput.PlaybackProgress) s.idleMs = 0
        // Conversation progress clears the reopen guard; ready is not progress.
        if (input is RealtimeConversationInput.Session && isProgress(input.event)) s.reopenAwaitingProgress = false
        when (input) {
            is RealtimeConversationInput.Session -> s.onEvent(input.event)
            RealtimeConversationInput.TapOrb -> if (s.phase == RealtimePhase.SPEAKING) {
                s.fx += RealtimeConversationEffect.InterruptPlayback
                s.freezeReveal()
                s.toListening()
                s.releaseDrained()
            }
            RealtimeConversationInput.PlaybackDrained -> {
                // A reply waiting for drain is released whatever the phase (speechStopped without started leaves thinking).
                if (s.phase == RealtimePhase.SPEAKING && s.drainPending) s.toListening()
                s.releaseDrained()
            }
            is RealtimeConversationInput.PlaybackProgress -> s.onPlaybackProgress(input.itemId ?: "", input.playedMs)
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
            RealtimeConversationInput.Wake -> if (s.dormant) {
                s.dormant = false
                s.reopenAwaitingProgress = true
                s.phase = RealtimePhase.CONNECTING
                s.fx += RealtimeConversationEffect.Reopen
            }
            is RealtimeConversationInput.ScreenReaderSpeaking -> if (s.screenReaderSpeaking != input.speaking) {
                s.screenReaderSpeaking = input.speaking
                // While muted the uplink is already off; announcement start / end leave it alone.
                if (!s.muted) s.fx += RealtimeConversationEffect.SetUplink(!input.speaking)
            }
            RealtimeConversationInput.SessionExpired -> s.onSessionExpired()
            RealtimeConversationInput.PlanChanged -> s.onPlanChanged()
            RealtimeConversationInput.GateOpened -> if (!s.bargeInOff) {
                // Echo pool = the reply being played + the previous reply.
                s.echoPool = listOf(s.turn.assistantText, s.lastReply).map { it.trim() }.filter { it.isNotEmpty() }
            }
            is RealtimeConversationInput.Tick -> s.onTick(if (input.ms > 0) input.ms else 0)
            RealtimeConversationInput.End -> s.endSession(RealtimeEndReason.USER)
            RealtimeConversationInput.SystemInterruption -> s.endSession(RealtimeEndReason.SYSTEM)
            is RealtimeConversationInput.Failed -> {
                val code = input.code
                s.fx += RealtimeConversationEffect.ShowError(if (code != null && code in FAILURE_CATEGORIES) code else "unknown")
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
        var echoPool = from.echoPool
        var lastReply = from.lastReply
        var falseBargeIns = from.falseBargeIns
        var bargeInOff = from.bargeInOff
        val fx = mutableListOf<RealtimeConversationEffect>()

        fun freeze() = RealtimeConversationState(
            phase, muted, dormant, reopenAwaitingProgress, screenReaderSpeaking, userSpeaking, drainPending, replyFlushed,
            turn, idleMs, thinkingMs, earconDone, echoPool, lastReply, falseBargeIns, bargeInOff,
        )

        fun toListening() {
            phase = RealtimePhase.LISTENING
            drainPending = false
        }

        /** Interrupt / end: freeze the prefix revealed so far as this reply's persisted text (once). */
        fun freezeReveal() {
            if (turn.assistantStarted && turn.frozenPlayedMs == null) turn = turn.copy(frozenPlayedMs = playedTotal(turn))
        }

        /** A generated reply waiting for drain can go now: held while the user is not final (and not a barge-in), else persisted. */
        fun releaseDrained() {
            if (!turn.awaitingDrain) return
            turn = turn.copy(awaitingDrain = false)
            holdOrPersist()
        }

        /** User not final (and not a barge-in): hold only a non-empty reply; an empty one just clears the assistant half. */
        fun holdOrPersist() {
            if (turn.userPending && !turn.userAfterReply) {
                turn = if (trimWs(shownForPersist()).isNotEmpty()) {
                    turn.copy(assistantDone = true, heldMs = 0)
                } else {
                    RealtimeTurn(userPending = turn.userPending, userText = turn.userText)
                }
                return
            }
            persistAssistant()
        }

        fun shownForPersist(): String = turn.frozenPlayedMs?.let { revealAt(turn, it) } ?: turn.assistantText

        fun persistAssistant() {
            val text = trimWs(shownForPersist())
            if (text.isNotEmpty()) {
                fx += RealtimeConversationEffect.Persist(RealtimePersistRole.ASSISTANT, text)
                lastReply = text
            }
            // The barge-in utterance carries over to the next turn.
            turn = if (turn.userAfterReply) RealtimeTurn(userPending = turn.userPending, userText = turn.userText) else RealtimeTurn()
        }

        /** Release a held reply → writeDraft (reason user, non-final userText) → close → ended. */
        fun endSession(reason: RealtimeEndReason) {
            val draft = if (turn.userPending && meaningful(turn.userText)) turn.userText.trim() else null
            // Generated and still playing: persist what the user has heard.
            if (turn.awaitingDrain) {
                freezeReveal()
                turn = turn.copy(awaitingDrain = false, assistantDone = true)
            }
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
            if (reopenAwaitingProgress) {
                // Expired again after a reopen without progress: end with an error, muted or not (E-630, same order as afterDrop).
                fx += RealtimeConversationEffect.ShowError(SESSION_EXPIRED_CODE)
                endSession(RealtimeEndReason.ERROR)
                return
            }
            if (muted) {
                // Expired while muted: keep the call, release a held reply, then sleep until unmute.
                if (turn.awaitingDrain) freezeReveal()
                if (turn.assistantDone || turn.awaitingDrain) persistAssistant()
                dormant = true
                phase = RealtimePhase.LISTENING
                userSpeaking = false
                drainPending = false
                turn = RealtimeTurn()
                return
            }
            // Expired while unmuted: reopen once with text history, uplink gate unchanged; thinking until ready (E-203).
            if (turn.awaitingDrain) freezeReveal()
            if (turn.assistantDone || turn.awaitingDrain) persistAssistant()
            reopenAwaitingProgress = true
            phase = RealtimePhase.CONNECTING
            userSpeaking = false
            drainPending = false
            turn = RealtimeTurn()
            fx += RealtimeConversationEffect.Reopen
        }

        /** Reopens only from idle listening; mid-turn or dormant it is ignored and the host compares again next boundary. */
        fun onPlanChanged() {
            if (dormant || phase != RealtimePhase.LISTENING || userSpeaking || turn.userPending || turn.assistantStarted) return
            phase = RealtimePhase.CONNECTING
            drainPending = false
            turn = RealtimeTurn()
            fx += RealtimeConversationEffect.Reopen
        }

        /** Only while speaking, only for items that delivered audio this turn, ignored once frozen. */
        fun onPlaybackProgress(key: String, ms: Long) {
            if (ms < 0 || turn.frozenPlayedMs != null || phase != RealtimePhase.SPEAKING || key !in turn.audioItems) return
            turn = turn.copy(played = turn.played + (key to maxOf(turn.played[key] ?: 0L, ms)))
        }

        fun onEvent(event: RealtimeSessionEvent) {
            when (event) {
                RealtimeSessionEvent.Ready -> if (phase == RealtimePhase.CONNECTING) toListening()
                is RealtimeSessionEvent.UserSpeechStarted -> {
                    // User spoke during playback: stop local playback first (the server confirms later).
                    if (phase == RealtimePhase.SPEAKING) {
                        fx += RealtimeConversationEffect.InterruptPlayback
                        freezeReveal()
                    }
                    // A new utterance starts from empty text: the previous final text is not its caption or draft.
                    if (!turn.userPending) turn = turn.copy(userText = "")
                    // A held reply is released before the new utterance.
                    if (turn.awaitingDrain) {
                        turn = turn.copy(awaitingDrain = false)
                        persistAssistant()
                    } else if (turn.assistantDone) {
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
                    if (event.sampleRateHz > 0) {
                        val key = event.itemId ?: ""
                        turn = turn.copy(
                            audioSamples = turn.audioSamples + base64Bytes(event.base64) / 2,
                            sampleRateHz = event.sampleRateHz,
                            audioItems = if (key in turn.audioItems) turn.audioItems else turn.audioItems + key,
                        )
                    }
                }
                is RealtimeSessionEvent.AssistantTranscript ->
                    turn = turn.copy(assistantStarted = true, assistantText = event.text)
                RealtimeSessionEvent.Interrupted -> {
                    freezeReveal()
                    toListening()
                    releaseDrained()
                }
                is RealtimeSessionEvent.AssistantTurnDone -> onTurnDone(event.text)
                is RealtimeSessionEvent.SessionEnded -> if (event.reason in SESSION_END_LIMIT_REASONS) {
                    // The server ended on its single-session duration limit (xAI max_duration / timeout): E-453 max_duration.
                    fx += RealtimeConversationEffect.ShowError("max_duration")
                    endSession(RealtimeEndReason.ERROR)
                } else {
                    endSession(RealtimeEndReason.SYSTEM)
                }
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
                // The barge-in went final first: freeze the interrupted reply at what was played and persist it;
                // its assistantTurnDone, if not here yet, writes nothing.
                freezeReveal()
                val turnDoneArrived = turn.awaitingDrain
                turn = turn.copy(awaitingDrain = false)
                persistAssistant()
                if (!turnDoneArrived) replyFlushed = true
            }
            if (meaningful(text)) fx += RealtimeConversationEffect.Persist(RealtimePersistRole.USER, text.trim())
            if (turn.assistantDone) persistAssistant()
            val pool = echoPool ?: return
            echoPool = null
            // An empty or echo transcript after the gate opened on speech is a false barge-in.
            if (!meaningful(text) || isEcho(text, pool).echo) {
                falseBargeIns += 1
                if (falseBargeIns >= RealtimeConversationConstants.FALSE_BARGE_INS_PER_SESSION && !bargeInOff) {
                    bargeInOff = true
                    fx += RealtimeConversationEffect.DisableBargeIn
                }
            }
        }

        fun onTurnDone(eventText: String) {
            val speaking = phase == RealtimePhase.SPEAKING
            if (speaking) drainPending = true else toListening()
            // Blank event text (after trim) falls back to the latest assistant transcript.
            val text = if (eventText.isBlank()) turn.assistantText else eventText
            if (replyFlushed) {
                replyFlushed = false
                return
            }
            turn = turn.copy(assistantText = text)
            if (speaking && turn.frozenPlayedMs == null) {
                // Still playing: persist on playbackDrained (or interrupt / end freeze), only up to what the user heard (E-451).
                turn = turn.copy(awaitingDrain = true)
                return
            }
            // User transcript not final yet: hold a non-blank reply until the user final or lateUserTranscriptMs.
            if (turn.userPending && !turn.userAfterReply) holdOrPersist() else persistAssistant()
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

// ───────────── Assistant text revealed by played ratio (E-451) ─────────────

/** Whitespace set fixed to ECMAScript \s / String.prototype.trim (Kotlin isWhitespace misses NBSP). */
private const val WS =
    "\t\n\u000B\u000C\r                  　﻿"

private fun isSpace(cp: Int): Boolean = cp <= 0xFFFF && WS.indexOf(cp.toChar()) >= 0

/** Combining marks and ZWJ: never cut right before them. */
private fun isJoiner(cp: Int): Boolean = cp == 0x200D || when (Character.getType(cp).toByte()) {
    Character.NON_SPACING_MARK, Character.ENCLOSING_MARK, Character.COMBINING_SPACING_MARK -> true
    else -> false
}

private val UNSPACED_RANGES = arrayOf(
    0x0E00..0x0EFF, 0x1000..0x109F, 0x1100..0x11FF, 0x1780..0x17FF, 0x2E80..0x2FDF, 0x3000..0x303F, 0x3040..0x30FF,
    0x3100..0x31FF, 0x3400..0x4DBF, 0x4E00..0x9FFF, 0xA960..0xA97F, 0xAC00..0xD7FF, 0xF900..0xFAFF, 0xFF00..0xFFEF,
    0x20000..0x2FA1F,
)

/** Scripts not separated by spaces (CJK, kana, hangul, Thai / Lao / Khmer / Myanmar, fullwidth): cut per character. */
private fun isUnspaced(cp: Int): Boolean = UNSPACED_RANGES.any { cp in it }

private fun fromCodePoints(cps: IntArray, from: Int, to: Int): String = String(cps, from, to - from)

private fun trimWs(cps: IntArray, from: Int, to: Int): String {
    var i = from
    var j = to
    while (i < j && isSpace(cps[i])) i += 1
    while (j > i && isSpace(cps[j - 1])) j -= 1
    return fromCodePoints(cps, i, j)
}

private fun trimWs(text: String): String = text.codePoints().toArray().let { trimWs(it, 0, it.size) }

/** Decoded byte count of a base64 string (without decoding); whitespace ignored. */
private fun base64Bytes(b64: String): Long {
    val s = b64.filter { !isSpace(it.code) }
    if (s.isEmpty()) return 0
    val pad = if (s.endsWith("==")) 2 else if (s.endsWith("=")) 1 else 0
    return s.length.toLong() * 3 / 4 - pad
}

/**
 * The first ⌊n × playedMs × rate ÷ (samples × 1000)⌋ code points of [text] (64-bit integer math), backed off to a
 * boundary; negative playedMs counts as 0; playedMs ≥ ⌊samples × 1000 ÷ rate⌋ (all received audio played) or k ≥ n
 * gives the full text; no audio gives "". The result is trimmed with the ECMAScript whitespace set.
 */
fun revealPrefix(text: String, playedMs: Long, audioSamples: Long, sampleRateHz: Int): String {
    val cps = text.codePoints().toArray()
    val n = cps.size
    val rate = sampleRateHz.toLong()
    val played = maxOf(0L, playedMs)
    if (n == 0 || audioSamples <= 0 || rate <= 0) return ""
    if (played >= audioSamples * 1000 / rate) return trimWs(cps, 0, n)
    var k = minOf(n.toLong(), n.toLong() * played * rate / (audioSamples * 1000)).toInt()
    if (k >= n) return trimWs(cps, 0, n)
    while (k > 0 && isJoiner(cps[k])) k -= 1
    fun boundary(i: Int) = i == 0 || isSpace(cps[i - 1]) || isSpace(cps[i]) || isUnspaced(cps[i - 1]) || isUnspaced(cps[i])
    while (k > 0 && !boundary(k)) k -= 1
    return trimWs(cps, 0, k)
}

private fun playedTotal(turn: RealtimeTurn): Long = turn.played.values.sum()

private fun revealAt(turn: RealtimeTurn, playedMs: Long): String =
    revealPrefix(turn.assistantText, playedMs, turn.audioSamples, turn.sampleRateHz)

/**
 * Text of the current reply bubble (host rendering, not an effect): frozen → revealed at the frozen played ms;
 * not frozen and fully played (held for the user transcript) or no audio this turn → full text; otherwise by played ratio.
 */
fun assistantShown(state: RealtimeConversationState): String {
    val t = state.turn
    t.frozenPlayedMs?.let { return revealAt(t, it) }
    if (t.assistantDone || (t.awaitingDrain && t.audioSamples == 0L)) return trimWs(t.assistantText)
    return revealAt(t, playedTotal(t))
}

/** "Your words" bubble (E-450): only while this turn's user speech is not final and has meaningful text; null otherwise. */
fun userCaption(state: RealtimeConversationState): String? {
    val t = state.turn
    return if (t.userPending && echoUnits(t.userText).isNotEmpty()) trimWs(t.userText) else null
}

/** The one line of the voice stage (E-525): a caption ([User] / [Assistant]) or the status word ([Status]). */
sealed interface StageLine {
    data class User(val text: String) : StageLine
    data class Assistant(val text: String) : StageLine
    data class Status(val statusKey: ConversationStatusKey?) : StageLine
}

/** Caption text of this line; null for a status line (the bar shows the status word). */
val StageLine.captionText: String?
    get() = when (this) {
        is StageLine.User -> text
        is StageLine.Assistant -> text
        is StageLine.Status -> null
    }

/**
 * Stage line (E-525): ended → null; the user's not-yet-final words win; then the assistant's revealed text while it
 * is speaking; otherwise the status word.
 */
fun stageLine(state: RealtimeConversationState): StageLine? {
    if (state.phase == RealtimePhase.ENDED) return null
    userCaption(state)?.let { return StageLine.User(it) }
    val shown = assistantShown(state)
    if (state.phase == RealtimePhase.SPEAKING && shown.isNotEmpty()) return StageLine.Assistant(shown)
    return StageLine.Status(RealtimeConversationLogic.statusKey(state))
}
