package ai.oriveo.community.core.voice.realtime

import android.os.SystemClock
import android.util.Log
import ai.oriveo.community.BuildConfig
import ai.oriveo.community.core.context.RealtimeSessionFingerprint
import ai.oriveo.community.core.context.shouldReopen
import ai.oriveo.community.core.voice.PcmWindowAccumulator
import ai.oriveo.community.core.data.repository.PlannedRealtimeSession
import ai.oriveo.community.core.voice.conversation.ConversationDisplayState
import ai.oriveo.community.core.voice.conversation.ConversationFrames
import ai.oriveo.community.core.voice.conversation.ConversationStatusKey
import ai.oriveo.community.core.voice.conversation.EarconKind
import ai.oriveo.community.core.voice.conversation.VoiceConversationController
import ai.oriveo.community.core.voice.realtime.wire.GeminiLiveSessionExpiredException
import ai.oriveo.community.core.voice.realtime.wire.RealtimeSessionControl
import ai.oriveo.community.core.voice.realtime.wire.RealtimeTransport
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Where persisted turns go; implemented by the host (appends to the chat). */
interface RealtimeConversationSink {
    fun appendUser(text: String)

    fun appendAssistant(text: String)

    /**
     * The first turn event (assistant audio / transcript, user transcript) of the session is about to be reduced:
     * a home entry creates its conversation and moves to the chat page now (realtime-conversation rules.host), so
     * the home bar never shows speaking. Called once per session on the controller's thread; never throws.
     * false = the home conversation could not be created: the session ends with an error.
     */
    suspend fun ensureConversation(): Boolean = true
}

/**
 * Realtime voice diagnostics under one logcat tag. Transcript text only in debug builds; release logs its length.
 * Never audio.
 */
internal object RealtimeVoiceLog {
    const val TAG = "RealtimeVoice"

    /** chatty: per-audio-chunk lines (~30 ms apart); debug builds only. */
    fun d(message: String, chatty: Boolean = false) {
        if (chatty && !BuildConfig.DEBUG) return
        Log.d(TAG, message)
    }

    fun text(value: String): String = if (BuildConfig.DEBUG) "\"$value\"" else "len=${value.length}"

    /** type / itemId / final / text of one unified event; audio only as its base64 length. */
    fun describe(event: RealtimeSessionEvent): String = when (event) {
        is RealtimeSessionEvent.UserSpeechStarted -> "${event.type} itemId=${event.itemId}"
        is RealtimeSessionEvent.UserSpeechStopped -> "${event.type} itemId=${event.itemId}"
        is RealtimeSessionEvent.UserTranscript ->
            "${event.type} itemId=${event.itemId} final=${event.final} text=${text(event.text)}"
        is RealtimeSessionEvent.AssistantAudio -> "${event.type} itemId=${event.itemId} b64len=${event.base64.length}"
        is RealtimeSessionEvent.AssistantTranscript ->
            "${event.type} itemId=${event.itemId} final=${event.final} text=${text(event.text)}"
        is RealtimeSessionEvent.AssistantTurnDone ->
            "${event.type} itemId=${event.itemId} status=${event.status.rawValue} text=${text(event.text)}"
        is RealtimeSessionEvent.GoAway -> "${event.type} timeLeftMs=${event.timeLeftMs}"
        is RealtimeSessionEvent.SessionEnded -> "${event.type} reason=${event.reason}"
        is RealtimeSessionEvent.Error -> "${event.type} code=${event.code}"
        else -> event.type
    }

    /** An effect by kind only: persisted text is logged by the sink. */
    fun describe(effect: RealtimeConversationEffect): String = when (effect) {
        is RealtimeConversationEffect.Persist -> "Persist(${effect.role})"
        else -> effect::class.simpleName ?: "?"
    }
}

/**
 * A reopen after a muted expiry could not get a new plan / connection (contract B item 4). Its type name is the
 * error code, same as iOS `RealtimeReopenError`.
 */
internal class RealtimeReopenError : Exception("Realtime reopen unavailable")

/**
 * Realtime voice conversation host: feeds driver events and local
 * inputs into [RealtimeConversationLogic] and executes its effects. Exposes the same statusKey / displayState /
 * level types as the cascade controller. Single session; public methods on the [scope]'s thread.
 */
internal class RealtimeVoiceConversationController<C>(
    connection: C,
    audio: RealtimeAudioIO,
    private val plan: PlannedRealtimeSession,
    private val sink: RealtimeConversationSink,
    private val scope: CoroutineScope,
    private val onError: (String?) -> Unit,
    private val onEnded: (RealtimeEndReason, String?) -> Unit,
    private val clock: () -> Long = { SystemClock.elapsedRealtime() },
    /** Opens a new connection and plan after an expiry (contract B item 4, F item 3); null makes a reopen fail. */
    private val reopen: (suspend () -> Pair<C, PlannedRealtimeSession>)? = null,
    /**
     * Plans the open session again with currentSessionId = this session (realtime-session.v1) and returns its
     * fingerprint; null = rejected / unavailable, no reopen. Runs on [replanContext], once per turn boundary.
     */
    private val replan: (suspend () -> RealtimeSessionFingerprint?)? = null,
    private val replanContext: CoroutineContext = Dispatchers.IO,
) where C : RealtimeTransport, C : RealtimeSessionControl {

    private val audio = GatedAudio(audio)

    // The audio view of the current driver.
    private var driverAudio: SessionAudio? = null

    // Replaced on reopen; effects always act on the current session.
    @Volatile private var connection: C = connection

    @Volatile private var driver = RealtimeConversationDriver(connection, SessionAudio())

    // Fingerprint of the plan the open session was opened with; replaced on reopen.
    private var fingerprint: RealtimeSessionFingerprint? = plan.plan.fingerprint

    // Bumped on every reopen: outcomes of a retired session (its stream, a replan for it) are dropped.
    private var session = 0

    // Bumped whenever the conversation enters or leaves idle listening: a replan result for an older boundary is dropped.
    private var turnSerial = 0
    private var replanJob: Job? = null

    private val _displayState = MutableStateFlow<ConversationDisplayState?>(null)
    private val _statusKey = MutableStateFlow<ConversationStatusKey?>(null)
    private val _level = MutableStateFlow(0f)

    val displayState: StateFlow<ConversationDisplayState?> = _displayState.asStateFlow()
    val statusKey: StateFlow<ConversationStatusKey?> = _statusKey.asStateFlow()

    /**
     * Orb level 0…1: latest uplink level window (1/15 s of audio, at most 15 updates per second) while listening,
     * fixed 0.5 while speaking, 0 otherwise.
     */
    val level: StateFlow<Float> = _level.asStateFlow()

    @Volatile private var state = RealtimeConversationLogic.initialState()

    @Volatile private var uplinkOn = true

    @Volatile private var lastFrameLevel = 0f
    private val levelWindow = UplinkLevelWindow()
    private var error = false
    private var started = false
    private var ended = false
    private var draft: String? = null
    private var streamJob: Job? = null

    // The first turn event already asked the sink for its conversation.
    private var conversationEnsured = false

    // Clock reading at start; event logs carry the time relative to it.
    private var startedAt = 0L

    // No periodic tick : one one-shot timer at lastTickAt + nextTickMs(state); armedTickAt != null iff
    // tickJob is pending. lastTickAt is null until the session is ready.
    private var tickJob: Job? = null
    private var armedTickAt: Long? = null
    private var lastTickAt: Long? = null

    // Inputs produced while effects run are folded strictly after the current one; null = the tick timer fired.
    private val pending = ArrayDeque<RealtimeConversationInput?>()
    private var dispatching = false

    fun start() {
        if (started) return
        started = true
        startedAt = clock()
        publish()
        streamJob = scope.launch { stream(plan, session) }
    }

    /** Runs the current driver until the session ends and folds the outcome into the reducer. */
    private suspend fun stream(plan: PlannedRealtimeSession, owner: Int) {
        // A retired session (closed by a plan-change reopen) no longer feeds the reducer.
        fun fold(input: RealtimeConversationInput) {
            if (owner == session) dispatch(input)
        }
        try {
            driver.run(plan).collect { event ->
                // Home entry: the conversation and the chat page exist before the first turn event is reduced and
                // its status published (realtime-conversation rules.host).
                if (!conversationEnsured && owner == session && !ended && isTurnEvent(event)) {
                    conversationEnsured = true
                    val ensured = sink.ensureConversation()
                    RealtimeVoiceLog.d("ensureConversation by ${event.type} t=${clock() - startedAt}ms ok=$ensured")
                    if (!ensured) {
                        // Same error the home cascade first send ends with; the event is not reduced, so the home bar
                        // never reaches speaking (realtime-conversation rules.host).
                        fold(RealtimeConversationInput.Failed(VoiceConversationController.SEND_FAILED))
                        return@collect
                    }
                }
                fold(RealtimeConversationInput.Session(event))
            }
            // The connection closed without a session end (e.g. dropped by the system).
            fold(RealtimeConversationInput.SystemInterruption)
        } catch (cancel: CancellationException) {
            throw cancel
        } catch (expired: GeminiLiveSessionExpiredException) {
            // Gemini closed the session with 1008 after ready: the reducer sleeps while muted, otherwise reopens
            // once with text history and ends with an error when it expires again without progress .
            // Unbind the uplink first: frames while dormant or reopening must not reach the dead connection.
            if (owner == session) audio.unbindUplink()
            fold(RealtimeConversationInput.SessionExpired)
        } catch (failure: Throwable) {
            // Only the error type name: messages may carry URLs or keys.
            fold(RealtimeConversationInput.Failed(failure::class.simpleName))
        }
    }

    /**
     * Swaps in a new connection from [reopen] and runs the driver on it; same controller and sink, no ended.
     * [retireLive]: the open connection is still alive (plan changed): close it without stopping the shared audio.
     */
    private fun startReopen(retireLive: Boolean) {
        session++
        cancelReplan()
        if (retireLive) {
            val retired = driverAudio
            retired?.retired = true
            audio.unbindUplink()
            streamJob?.cancel()
            connection.close()
        }
        val opener = reopen
        if (opener == null) {
            dispatch(RealtimeConversationInput.Failed(RealtimeReopenError::class.simpleName))
            return
        }
        val owner = session
        streamJob = scope.launch {
            val (next, nextPlan) = try {
                opener()
            } catch (cancel: CancellationException) {
                throw cancel
            } catch (failure: Throwable) {
                dispatch(RealtimeConversationInput.Failed(failure::class.simpleName))
                return@launch
            }
            if (owner != session || ended) return@launch
            connection = next
            fingerprint = nextPlan.plan.fingerprint
            driver = RealtimeConversationDriver(next, SessionAudio())
            stream(nextPlan, owner)
        }
    }

    /**
     * A turn just ended back in idle listening: replan off the main thread and send planChanged when the
     * fingerprint differs. The result is dropped when the session, the turn or the controller moved on meanwhile.
     */
    private fun replanAtBoundary() {
        val replanner = replan ?: return
        val opened = fingerprint ?: return
        val owner = session
        val boundary = turnSerial
        cancelReplan()
        replanJob = scope.launch {
            val next = try {
                withContext(replanContext) { replanner() }
            } catch (cancel: CancellationException) {
                throw cancel
            } catch (_: Throwable) {
                null
            }
            if (ended || owner != session || boundary != turnSerial || next == null) return@launch
            if (shouldReopen(opened, next)) dispatch(RealtimeConversationInput.PlanChanged)
        }
    }

    private fun cancelReplan() {
        replanJob?.cancel()
        replanJob = null
    }

    fun tapOrb() = dispatch(RealtimeConversationInput.TapOrb)

    fun toggleMute() = dispatch(if (state.muted) RealtimeConversationInput.Unmute else RealtimeConversationInput.Mute)

    fun end() = dispatch(RealtimeConversationInput.End)

    /** The screen reader is announcing the status word: pauses the uplink without muting (mute wins). */
    fun screenReaderSpeaking(speaking: Boolean) = dispatch(RealtimeConversationInput.ScreenReaderSpeaking(speaking))

    /** App went to the background, a call or the system took the audio : closes the connection. */
    fun systemInterruption() = dispatch(RealtimeConversationInput.SystemInterruption)

    private fun dispatch(input: RealtimeConversationInput) = enqueue(input)

    /** [input] null: the tick timer fired, only the catch-up tick runs. */
    private fun enqueue(input: RealtimeConversationInput?) {
        if (ended) return
        pending.addLast(input)
        if (dispatching) return
        dispatching = true
        try {
            while (!ended && pending.isNotEmpty()) {
                val next = pending.removeFirst()
                // Every input is preceded by a tick carrying the time elapsed since the last tick or ready.
                lastTickAt?.let { at ->
                    val now = clock()
                    lastTickAt = now
                    reduce(RealtimeConversationInput.Tick(now - at))
                }
                if (next == null || ended) continue
                reduce(next)
                if (next is RealtimeConversationInput.Session && next.event == RealtimeSessionEvent.Ready) {
                    lastTickAt = clock()
                }
            }
        } finally {
            dispatching = false
            if (ended) pending.clear() else armTick()
        }
    }

    private fun reduce(input: RealtimeConversationInput) {
        val before = state
        val wasDraining = before.drainPending
        val result = RealtimeConversationLogic.reduce(before, input)
        state = result.state
        publish()
        if (input is RealtimeConversationInput.Session) {
            RealtimeVoiceLog.d(
                "event ${RealtimeVoiceLog.describe(input.event)} t=${clock() - startedAt}ms " +
                    "conversation=$conversationEnsured effects=${result.effects.map(RealtimeVoiceLog::describe)}",
                chatty = input.event is RealtimeSessionEvent.AssistantAudio && result.effects.isEmpty(),
            )
        }
        val wasIdle = idleListening(before)
        val idle = idleListening(state)
        if (wasIdle != idle) turnSerial++
        for (effect in result.effects) execute(effect, input)
        // Turn boundary: a turn (not the connection opening) ended back in idle listening.
        if (!ended && !wasIdle && idle && before.phase != RealtimePhase.CONNECTING) {
            replanAtBoundary()
        }
        // The reply finished after the player had already drained: its completion callback will not fire again.
        if (!ended && !wasDraining && drainAwaited() && !audio.isPlaying) {
            pending.addLast(RealtimeConversationInput.PlaybackDrained)
        }
    }

    /** Listening with no turn in progress, not dormant: the only state a planChanged reopens from. */
    private fun idleListening(s: RealtimeConversationState) = s.phase == RealtimePhase.LISTENING && !s.dormant &&
        !s.userSpeaking && !s.turn.userPending && !s.turn.assistantStarted

    private fun drainAwaited() = state.phase == RealtimePhase.SPEAKING && state.drainPending

    /** Re-arms the single tick timer only when its due time changed; no wait (null or ≤ 0) arms nothing. */
    private fun armTick() {
        val wait = RealtimeConversationLogic.nextTickMs(state)
        val at = tickDueAt(wait) { lastTickAt ?: clock() }
        if (at == armedTickAt) return
        cancelTick()
        armedTickAt = at
        if (at == null) return
        val job = scope.launch(start = CoroutineStart.LAZY) {
            delay((at - clock()).coerceAtLeast(0L))
            if (tickJob === coroutineContext[Job]) {
                tickJob = null
                armedTickAt = null
            }
            enqueue(null)
        }
        tickJob = job
        job.start()
    }

    private fun cancelTick() {
        tickJob?.cancel()
        tickJob = null
        armedTickAt = null
    }

    private fun execute(effect: RealtimeConversationEffect, input: RealtimeConversationInput) {
        when (effect) {
            is RealtimeConversationEffect.Persist -> when (effect.role) {
                RealtimePersistRole.USER -> sink.appendUser(effect.text)
                RealtimePersistRole.ASSISTANT -> sink.appendAssistant(effect.text)
            }
            RealtimeConversationEffect.InterruptPlayback -> driver.interruptPlayback()
            is RealtimeConversationEffect.SendSilence -> connection.sendAudio(silence(effect.ms, connection.uplinkSampleRateHz))
            is RealtimeConversationEffect.SetUplink -> {
                uplinkOn = effect.on
                if (!effect.on) {
                    lastFrameLevel = 0f
                    levelWindow.reset()
                }
                publish()
            }
            RealtimeConversationEffect.Earcon -> scope.launch { audio.playEarcon(EarconKind.THINKING) }
            is RealtimeConversationEffect.ShowError -> {
                error = true
                publish()
                onError(effect.code)
            }
            is RealtimeConversationEffect.WriteDraft -> draft = effect.text
            RealtimeConversationEffect.Close -> {
                // Gate the uplink first so frames arriving while closing are not sent.
                uplinkOn = false
                lastFrameLevel = 0f
                levelWindow.reset()
                connection.close()
                cancelTick()
                cancelReplan()
                // Cancelling the collection makes the driver stop the audio; a dormant session has no driver left.
                streamJob?.cancel()
                audio.stopIfRunning()
            }
            RealtimeConversationEffect.Reopen -> startReopen(retireLive = input is RealtimeConversationInput.PlanChanged)
            is RealtimeConversationEffect.Ended -> {
                ended = true
                cancelTick()
                cancelReplan()
                streamJob?.cancel()
                audio.stopIfRunning()
                publish()
                onEnded(effect.reason, draft)
            }
        }
    }

    private fun publish() {
        val key = if (error) ConversationStatusKey.ERROR else RealtimeConversationLogic.statusKey(state)
        _statusKey.value = key
        _displayState.value = when (key) {
            null -> null
            ConversationStatusKey.LISTENING -> ConversationDisplayState.LISTENING
            ConversationStatusKey.THINKING -> ConversationDisplayState.THINKING
            ConversationStatusKey.SPEAKING, ConversationStatusKey.SPEAKING_TAP_TO_INTERRUPT -> ConversationDisplayState.SPEAKING
            ConversationStatusKey.MUTED -> ConversationDisplayState.MUTED
            ConversationStatusKey.AWAITING_APPROVAL -> ConversationDisplayState.AWAITING_APPROVAL
            ConversationStatusKey.ERROR -> ConversationDisplayState.ERROR
        }
        publishLevel()
    }

    private fun publishLevel() {
        _level.value = when {
            ended -> 0f
            state.phase == RealtimePhase.LISTENING && !state.muted -> lastFrameLevel
            state.phase == RealtimePhase.SPEAKING -> SPEAKING_LEVEL
            else -> 0f
        }
    }

    /**
     * Wraps the audio so the uplink can be gated: frames are dropped while the uplink is off. The inner audio is
     * single-use, so a reopened driver's start only rebinds the callbacks (contract C item 2) and the inner audio is
     * stopped at most once.
     */
    private inner class GatedAudio(private val inner: RealtimeAudioIO) : RealtimeAudioIO by inner {
        @Volatile private var onFrame: (ByteArray) -> Unit = {}

        @Volatile private var onInterruption: () -> Unit = {}
        private var innerStarted = false
        private var innerStopped = false

        init {
            // playbackDrained comes only from the player's completion callback, folded on the scope's thread.
            inner.setOnDrained {
                scope.launch { if (drainAwaited()) dispatch(RealtimeConversationInput.PlaybackDrained) }
            }
        }

        override fun start(onFrame: (ByteArray) -> Unit, onInterruption: () -> Unit) =
            start(onFrame, onInterruption, RealtimePCM.OUTPUT_RATE)

        override fun start(onFrame: (ByteArray) -> Unit, onInterruption: () -> Unit, uplinkRateHz: Int) {
            this.onFrame = onFrame
            this.onInterruption = onInterruption
            // Once stopped, start goes to the inner audio again so its single-use check still applies.
            if (innerStarted && !innerStopped) return
            innerStarted = true
            inner.start(
                onFrame = { frame ->
                    if (uplinkOn) {
                        levelWindow.add(frame, uplinkRateHz)?.let { windowLevel ->
                            lastFrameLevel = windowLevel
                            if (state.phase == RealtimePhase.LISTENING) _level.value = windowLevel
                        }
                        this.onFrame(frame)
                    }
                },
                onInterruption = {
                    dispatch(RealtimeConversationInput.SystemInterruption)
                    this.onInterruption()
                },
                uplinkRateHz = uplinkRateHz,
            )
        }

        override fun stop() {
            if (innerStopped) return
            innerStopped = true
            inner.stop()
        }

        /** Drops uplink frames until the next driver's start rebinds the callback (contract D item 2). */
        fun unbindUplink() {
            onFrame = {}
        }

        /** Stops the inner audio when it was started and not yet stopped (contract C item 3). */
        fun stopIfRunning() {
            if (innerStarted) stop()
        }
    }

    /**
     * One session's view of the shared audio: once a plan-change reopen retires the session, its driver's stop
     * (run when its collection is cancelled) no longer stops the audio the next session keeps using.
     */
    private inner class SessionAudio : RealtimeAudioIO by audio {
        @Volatile var retired = false

        init {
            driverAudio = this
        }

        override fun stop() {
            if (!retired) audio.stop()
        }
    }

    companion object {
        const val SPEAKING_LEVEL = 0.5f

        /** Events that start or carry a turn's content: the first of them makes a home entry create its chat. */
        internal fun isTurnEvent(event: RealtimeSessionEvent): Boolean =
            event is RealtimeSessionEvent.AssistantAudio ||
                event is RealtimeSessionEvent.AssistantTranscript ||
                event is RealtimeSessionEvent.UserTranscript

        /** Due time of the next tick, [base] + [wait]; null (nothing armed) when [wait] is null or ≤ 0. */
        internal inline fun tickDueAt(wait: Long?, base: () -> Long): Long? =
            if (wait == null || wait <= 0L) null else base() + wait

        /** [ms] of mono PCM16 LE digital silence at [rateHz] (the connection's uplink rate). */
        fun silence(ms: Long, rateHz: Int = RealtimePCM.OUTPUT_RATE): ByteArray =
            ByteArray((rateHz * ms / 1000).toInt() * 2)
    }
}

/**
 * Accumulates uplink PCM16 LE frames into windows of 1/[RATE_HZ] s of audio (by sample count at the uplink rate,
 * not wall clock) and yields the window's RMS level 0…1 once full: the orb level updates at most [RATE_HZ] times
 * per second of audio whatever the frame size. The sum of squares and the dBFS level are the recorder's
 * ([PcmWindowAccumulator] / [ai.oriveo.community.core.voice.RecordingWriter.windowLevel]). Frames arrive on the
 * capture thread, [reset] on the controller's.
 */
internal class UplinkLevelWindow {
    private val window = PcmWindowAccumulator()

    /** Adds [frame] at [rateHz]; the level of the window it completes, or null while the window is still filling. */
    @Synchronized
    fun add(frame: ByteArray, rateHz: Int): Float? {
        window.addPcm16Le(frame)
        if (window.count == 0 || window.count < windowSamples(rateHz)) return null
        return window.drain()?.let(ConversationFrames::levelFromDb) ?: 0f
    }

    /** Drops a partly filled window (uplink gated off / session closed). */
    @Synchronized
    fun reset() {
        window.reset()
    }

    companion object {
        const val RATE_HZ = 15

        /** Samples per window, rounded up so a window never spans less than 1/[RATE_HZ] s. */
        fun windowSamples(rateHz: Int): Int = (rateHz + RATE_HZ - 1) / RATE_HZ
    }
}
