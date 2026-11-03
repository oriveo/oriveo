package ai.oriveo.community.core.voice.realtime

import android.os.SystemClock
import android.util.Log
import ai.oriveo.community.BuildConfig
import ai.oriveo.community.core.context.RealtimeSessionFingerprint
import ai.oriveo.community.core.context.shouldReopen
import ai.oriveo.community.core.data.repository.PlannedRealtimeSession
import ai.oriveo.community.core.voice.conversation.ConversationDisplayState
import ai.oriveo.community.core.voice.conversation.ConversationFrames
import ai.oriveo.community.core.voice.conversation.ConversationRoute
import ai.oriveo.community.core.voice.conversation.ConversationStatusKey
import ai.oriveo.community.core.voice.conversation.EarconKind
import ai.oriveo.community.core.voice.conversation.SpeechProbModel
import ai.oriveo.community.core.voice.conversation.SpeechProbSource
import ai.oriveo.community.core.voice.conversation.VoiceConversationController
import ai.oriveo.community.core.voice.realtime.wire.GeminiLiveSessionExpiredException
import ai.oriveo.community.core.voice.realtime.wire.RealtimeFailureDetail
import ai.oriveo.community.core.voice.realtime.wire.RealtimeSessionControl
import ai.oriveo.community.core.voice.realtime.wire.RealtimeSocketClosedException
import ai.oriveo.community.core.voice.realtime.wire.RealtimeTransport
import java.util.concurrent.atomic.AtomicReference
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

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

/** A reopen after an expiry could not get a new plan / connection (contract B item 4); classified as network. */
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
    /** Off-main context: turn-boundary replans, and loading / closing the speech model. */
    private val replanContext: CoroutineContext = Dispatchers.IO,
    /**
     * Speech probability model for the speaker uplink gate: loaded on [replanContext] when the session starts, waited
     * for at most [SPEECH_MODEL_WAIT_MS] before capture starts; not ready (or null) = this session gates on energy.
     */
    private val speechProbs: SpeechProbSource? = null,
    /** Catalog single-session limit in seconds: a failure once connected this long is max_duration (E-453). */
    private val maxSessionSec: Long? = null,
    /**
     * Whether the model is still in the refreshed voice catalog; null = unknown. Asked only when a connection fails
     * to open (false = model_gone).
     */
    private val catalogHasModel: suspend () -> Boolean? = { null },
    /** false = playback only, microphone not opened (session opened from typing); [startCapture] later opens it on the same connection. */
    capture: Boolean = true,
) where C : RealtimeTransport, C : RealtimeSessionControl {

    // Microphone: fully opened when the connection is ready; playback-only sessions set this to true after [startCapture], and reconnects follow it.
    @Volatile private var captureWanted = capture

    private val audio = GatedAudio(audio)

    // The audio view of the current driver.
    private var driverAudio: SessionAudio? = null

    // Replaced on reopen; effects always act on the current session.
    @Volatile private var connection: C = connection

    @Volatile private var driver = RealtimeConversationDriver(connection, SessionAudio()) { captureWanted }

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
    private val _caption = MutableStateFlow("")
    private val _drafts = MutableStateFlow(RealtimeDrafts())

    // Persist effects emitted so far per role: the list keeps a cleared bubble until that many stored messages show.
    private var userPersisted = 0
    private var assistantPersisted = 0
    private var userPersistedText: String? = null
    private var assistantPersistedText: String? = null

    val displayState: StateFlow<ConversationDisplayState?> = _displayState.asStateFlow()
    val statusKey: StateFlow<ConversationStatusKey?> = _statusKey.asStateFlow()

    /**
     * Orb level 0…1: latest uplink level window (1/15 s of audio, at most 15 updates per second) while listening,
     * latest downlink playback level window while speaking, 0 otherwise.
     */
    val level: StateFlow<Float> = _level.asStateFlow()

    /**
     * Stage caption from [stageLine], recomputed after every reduce (so it follows playback progress, ≤ 100 ms): the
     * user's not-yet-final transcript wins, then the assistant's text revealed by the played ratio while it speaks;
     * "" = a status line (the bar shows the status word). A state flow, so only changed values are emitted.
     */
    val caption: StateFlow<String> = _caption.asStateFlow()

    /**
     * Live chat-list bubbles, recomputed after every reduce: the user's not-yet-final transcript once it has text, and
     * the assistant's text revealed by the played ratio. A side goes null in the reduce that emits its persist effect
     * (the stored message takes over) and both on end / error; the persist counts of that reduce are already in the
     * same value. A state flow, so only changed values are emitted.
     */
    val drafts: StateFlow<RealtimeDrafts> = _drafts.asStateFlow()

    @Volatile private var state = RealtimeConversationLogic.initialState()

    @Volatile private var uplinkOn = true

    @Volatile private var lastFrameLevel = 0f
    private val levelWindow = UplinkLevelWindow()

    // Level of the downlink PCM actually written to the output (writer thread), peaked per window like the uplink.
    @Volatile private var lastPlaybackLevel = 0f
    private val playbackWindow = PeakLevelWindow()
    private var error = false
    private var started = false
    // Read by the audio writer thread's playback level callback.
    @Volatile private var ended = false
    private var draft: String? = null
    private var streamJob: Job? = null

    // Set once the reducer closed the connection (user end, system interruption, expiry): its stream ending is not
    // an unexpected drop. Cleared when a reopen swaps in a new connection.
    private var closing = false

    // Seconds the connection had been up when it dropped unexpectedly; handed to the reopen the reducer asks for.
    private var dropElapsedSec: Double? = null

    // The audio failed to activate: the connection closing after it is not a network drop.
    @Volatile private var audioFailed = false

    // Seconds the dropped connection had been connected; a failed reopen after it is classified with it (E-453).
    private var reopenElapsedSec: Double? = null

    // The connection this session is on now; null from a reopen until its stream starts. Typed text is sent only
    // once it is Ready (and the reducer is not dormant); until then it waits in [typedQueue], unreduced (E-524 / E-634).
    private var liveAttempt: StreamAttempt? = null
    private val typedQueue = ArrayDeque<String>()
    private var typedFlushing = false

    // Sequence of the synthetic user item ids (typed_N) a typed message is reduced under.
    private var typedSeq = 0

    // The first turn event already asked the sink for its conversation.
    private var conversationEnsured = false

    // The speech model being loaded for this session; taken (or given up) once, before capture first starts.
    private var modelLoad: SpeechModelLoad? = null

    // Capture start deferred until the speech model is decided (transport ready, model not yet arrived).
    private var modelWaitJob: Job? = null

    // Clock reading at start; event logs carry the time relative to it.
    private var startedAt = 0L

    // No periodic tick : one one-shot timer at lastTickAt + nextTickMs(state); armedTickAt != null iff
    // tickJob is pending. lastTickAt is null until the session is ready.
    private var tickJob: Job? = null
    private var armedTickAt: Long? = null
    private var lastTickAt: Long? = null

    // Playback progress timer: runs only while speaking with audio received this turn, stopped on leaving speaking.
    private var progressJob: Job? = null

    // Inputs produced while effects run are folded strictly after the current one; null = the tick timer fired.
    private val pending = ArrayDeque<RealtimeConversationInput?>()
    private var dispatching = false

    fun start() {
        if (started) return
        started = true
        startedAt = clock()
        publish()
        modelLoad = speechProbs?.let { source ->
            SpeechModelLoad().also { load ->
                scope.launch(NonCancellable + replanContext) { load.deliver(runCatching { source.load() }) }
            }
        }
        streamJob = scope.launch { stream(plan, session, reopened = false) }
    }

    /**
     * Waits for the speech model until session start + [SPEECH_MODEL_WAIT_MS] (the transport connects meanwhile):
     * ready = the gate runs in model mode for the whole session; timeout, load failure or the session ending first =
     * energy mode. A model that arrives too late, or while / after the session ends, is closed off the main thread.
     */
    private suspend fun awaitSpeechModel(load: SpeechModelLoad): SpeechProbModel? {
        var model: SpeechProbModel? = null
        var waited = false
        try {
            load.await((startedAt + SPEECH_MODEL_WAIT_MS - clock()).coerceAtLeast(0L))
            waited = true
        } finally {
            val result = load.take()
            model = result?.getOrNull()
            RealtimeVoiceLog.d(
                "gate vad mode=${if (model != null && waited && !ended) "model" else "energy"} reason=" +
                    when {
                        !waited || ended -> "ended"
                        model != null -> "ready"
                        result == null -> "timeout"
                        else -> result.exceptionOrNull()?.let { it::class.java.simpleName } ?: "unknown"
                    },
            )
            if (model != null && (!waited || ended)) {
                closeOffMain(model)
                model = null
            }
        }
        return model
    }

    /** Session end before the model was decided: nothing will take it, so it is closed (now or when it arrives). */
    private fun abandonSpeechModel() {
        modelWaitJob?.cancel()
        modelWaitJob = null
        modelLoad?.take()?.getOrNull()?.let(::closeOffMain)
        modelLoad = null
    }

    /** Model close shares the inference lock: runs on [replanContext], even after the scope is cancelled. */
    private fun closeOffMain(model: SpeechProbModel) {
        scope.launch(NonCancellable + replanContext) { runCatching { model.close() } }
    }

    /** Failure facts of one connection (one [stream] run), kept for the classification when it fails. */
    private class StreamAttempt {
        // Clock reading at this connection's Ready; null = not connected yet.
        var readyAt: Long? = null

        // Code of the latest (non-fatal) error event; used by the close that follows it.
        var errorCode: String? = null
    }

    /**
     * Runs the current driver until the session ends and folds the outcome into the reducer. A failure is folded
     * as one of the six categories (E-453); [reopened]: this connection is an automatic reopen, so failing to
     * connect counts as a failed reopen.
     */
    private suspend fun stream(plan: PlannedRealtimeSession, owner: Int, reopened: Boolean) {
        // A retired session (closed by a plan-change reopen) no longer feeds the reducer.
        fun fold(input: RealtimeConversationInput) {
            if (owner == session) dispatch(input)
        }
        val attempt = StreamAttempt()
        if (owner == session) liveAttempt = attempt
        // One-shot handshake timeout: no Ready within CONNECT_TIMEOUT_MS ends the session as network.
        val connectTimeout = scope.launch {
            delay(RealtimeModel.CONNECT_TIMEOUT_MS)
            if (owner != session || ended || attempt.readyAt != null) return@launch
            val category = classifyFailure(attempt, null, timedOut = true, reopened = reopened)
            if (attempt.readyAt == null) fold(RealtimeConversationInput.Failed(category))
        }
        try {
            driver.run(plan).collect { event ->
                if (event == RealtimeSessionEvent.Ready && attempt.readyAt == null) {
                    attempt.readyAt = clock()
                    if (owner == session) driverAudio?.connected = true
                    connectTimeout.cancel()
                }
                // Non-fatal on its own (the connection close decides); its code classifies that close.
                if (event is RealtimeSessionEvent.Error) attempt.errorCode = event.code
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
            // The connection closed without a session end: an OpenAI / xAI drop reopens with history (design 6.6).
            if (dropped(owner, attempt)) {
                reopenAfterDrop(attempt, null, reopened)
                return
            }
            // A reopened connection closing before Ready is a failed reopen (network, or max_duration).
            if (reopened && owner == session && attempt.readyAt == null && reopensOnDrop()) {
                fold(RealtimeConversationInput.Failed(classifyFailure(attempt, null, timedOut = false, reopened)))
                return
            }
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
            connectTimeout.cancel()
            if (dropped(owner, attempt)) {
                reopenAfterDrop(attempt, failure, reopened)
            } else if (owner == session && !ended) {
                fold(RealtimeConversationInput.Failed(classifyFailure(attempt, failure, timedOut = false, reopened)))
            }
        } finally {
            connectTimeout.cancel()
        }
    }

    /**
     * An OpenAI / xAI connection of the current session went away after Ready without the reducer closing it.
     * Gemini reconnects on its own session handle and is not reopened here.
     */
    private fun dropped(owner: Int, attempt: StreamAttempt): Boolean =
        owner == session && attempt.readyAt != null && reopensOnDrop()

    private fun reopensOnDrop(): Boolean = !ended && !closing && !audioFailed &&
        connection.kind != RealtimeTransportKind.GeminiLive

    /**
     * Where an unexpected drop of [category] leads now (RealtimeModel.afterDrop): muted and the reopen-progress guard
     * come from the reducer state. Shared by [reopenAfterDrop] and [SessionAudio.stop].
     */
    private fun afterDrop(category: String = RealtimeModel.CATEGORY_UNKNOWN): RealtimeModel.AfterDropResult =
        RealtimeModel.afterDrop(
            provider = connection.kind.dropProvider(),
            category = category,
            muted = state.muted,
            reopenedWithoutProgress = state.reopenAwaitingProgress,
        )

    /**
     * An unexpected drop either ends the session with afterDrop's code, or goes to the reducer as sessionExpired: it
     * lands the finished reply and reopens with history (phase connecting), or sleeps while muted until unmute.
     * Ending dispatches Failed, whose Ended effect stops the audio [SessionAudio.stop] kept.
     */
    private suspend fun reopenAfterDrop(attempt: StreamAttempt, failure: Throwable?, reopened: Boolean) {
        val elapsed = attempt.readyAt?.let { (clock() - it) / 1000.0 }
        val category = classifyFailure(attempt, failure, timedOut = false, reopened)
        val next = afterDrop(category)
        RealtimeVoiceLog.d("unexpected close elapsedSec=$elapsed category=$category action=${next.action}")
        if (next.action == RealtimeModel.AFTER_DROP_END) {
            dispatch(RealtimeConversationInput.Failed(next.code ?: category))
            return
        }
        // Frames while dormant or reopening must not reach the dead connection; the new driver rebinds on its Ready.
        audio.unbindUplink()
        dropElapsedSec = elapsed
        dispatch(RealtimeConversationInput.SessionExpired)
    }

    /**
     * Collects the normalized failure signal of one connection and returns its category (RealtimeModel). Only
     * normalized facts are read from [failure], never its message (it may carry URLs or keys).
     */
    private suspend fun classifyFailure(
        attempt: StreamAttempt,
        failure: Throwable?,
        timedOut: Boolean,
        reopened: Boolean,
        reopenFailed: Boolean = false,
    ): String {
        val detail = failure as? RealtimeFailureDetail
        val connected = attempt.readyAt
        val signal = RealtimeModel.FailureSignal(
            httpStatus = detail?.httpStatus,
            errorCode = attempt.errorCode,
            // Only a call that never got Ready refetches the catalog; a reopened connection failing its handshake is
            // network (E-523 / E-592), never model_gone from a fresh catalog lookup.
            catalogHasModel = if (connected == null && !reopened) catalogHasModelOrNull() else null,
            elapsedSec = connected?.let { (clock() - it) / 1000.0 } ?: reopenElapsedSec.takeIf { reopened },
            maxSessionSec = maxSessionSec?.toDouble(),
            connectError = detail?.connectFailed?.takeIf { it },
            connectTimedOut = timedOut.takeIf { it },
            reopenFailed = (reopenFailed || detail?.reconnectsExhausted == true || (reopened && connected == null)).takeIf { it },
            uplinkBacklogMs = detail?.uplinkBacklogMs,
            closeCode = (failure as? RealtimeSocketClosedException)?.code,
        )
        val category = RealtimeModel.classifyFailure(signal).category
        RealtimeVoiceLog.d(
            "failure category=$category type=${failure?.let { it::class.java.simpleName }} http=${signal.httpStatus} " +
                "code=${signal.errorCode} connected=${connected != null} timedOut=$timedOut",
        )
        return category
    }

    private suspend fun catalogHasModelOrNull(): Boolean? = try {
        catalogHasModel()
    } catch (cancel: CancellationException) {
        throw cancel
    } catch (_: Throwable) {
        null
    }

    /**
     * An automatic reopen could not get a new plan / connection: network (E-453 reopenFailed), or max_duration when
     * the dropped connection had reached the session limit.
     */
    private fun reopenFailedCategory(): String = RealtimeModel.classifyFailure(
        RealtimeModel.FailureSignal(
            elapsedSec = reopenElapsedSec,
            maxSessionSec = maxSessionSec?.toDouble(),
            reopenFailed = true,
        ),
    ).category

    /**
     * Swaps in a new connection from [reopen] and runs the driver on it; same controller and sink, no ended.
     * [retireLive]: the open connection is still alive (plan changed): close it without stopping the shared audio.
     * [droppedElapsedSec]: seconds the connection had been up when it dropped unexpectedly; null for other reopens.
     */
    private fun startReopen(retireLive: Boolean, droppedElapsedSec: Double? = null) {
        session++
        liveAttempt = null
        reopenElapsedSec = droppedElapsedSec
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
            dispatch(RealtimeConversationInput.Failed(reopenFailedCategory()))
            return
        }
        val owner = session
        streamJob = scope.launch {
            val (next, nextPlan) = try {
                opener()
            } catch (cancel: CancellationException) {
                throw cancel
            } catch (_: Throwable) {
                dispatch(RealtimeConversationInput.Failed(reopenFailedCategory()))
                return@launch
            }
            if (owner != session || ended) return@launch
            closing = false
            connection = next
            fingerprint = nextPlan.plan.fingerprint
            driver = RealtimeConversationDriver(next, SessionAudio()) { captureWanted }
            stream(nextPlan, owner, reopened = true)
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

    fun tapOrb() {
        dispatch(RealtimeConversationInput.TapOrb)
    }

    /**
     * A typed message mid-session. Sent only while the current connection is Ready and not dormant: the home
     * conversation is ensured first, then it is reduced like a spoken turn (speech started / stopped / final
     * transcript under typed_N, persisted once; started while speaking barges in) and sent on the connection.
     * Otherwise it waits unreduced and is sent after the next Ready, reopens included; while dormant it also wakes
     * the session (reopen, mute kept, E-634 / E-524). Blank text or an ended session sends nothing.
     */
    fun sendUserText(text: String) {
        val trimmed = text.trim()
        if (ended || trimmed.isEmpty()) return
        typedQueue.addLast(trimmed)
        if (state.dormant) dispatch(RealtimeConversationInput.Wake)
        flushTyped()
    }

    private fun typedSendable(): Boolean = !ended && liveAttempt?.readyAt != null && !state.dormant

    /** Sends the queued typed messages in order while sendable; one flush at a time keeps the order. */
    private fun flushTyped() {
        if (typedFlushing || !typedSendable() || typedQueue.isEmpty()) return
        typedFlushing = true
        scope.launch {
            try {
                while (typedSendable() && typedQueue.isNotEmpty()) {
                    if (!conversationEnsured) {
                        conversationEnsured = true
                        if (!sink.ensureConversation()) {
                            typedQueue.clear()
                            dispatch(RealtimeConversationInput.Failed(VoiceConversationController.SEND_FAILED))
                            return@launch
                        }
                        continue
                    }
                    sendTyped(typedQueue.removeFirst())
                }
            } finally {
                typedFlushing = false
            }
        }
    }

    private fun sendTyped(text: String) {
        val itemId = "typed_${++typedSeq}"
        dispatch(RealtimeConversationInput.Session(RealtimeSessionEvent.UserSpeechStarted(itemId)))
        dispatch(RealtimeConversationInput.Session(RealtimeSessionEvent.UserSpeechStopped(itemId)))
        dispatch(RealtimeConversationInput.Session(RealtimeSessionEvent.UserTranscript(itemId, text, final = true)))
        connection.sendUserText(text)
    }

    /** Opens the microphone for a playback-only session (switch to voice panel): starts capture on the same connection without reconnecting; does nothing if already capturing or ended. */
    fun startCapture() {
        if (ended || captureWanted) return
        captureWanted = true
        driver.startCapture()
    }

    fun toggleMute() = dispatch(if (state.muted) RealtimeConversationInput.Unmute else RealtimeConversationInput.Mute)

    fun end() {
        dispatch(RealtimeConversationInput.End)
    }

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
                // E-603: an input that freezes the reveal is preceded by the player's progress, judged here once
                // against the state it is reduced on (only while speaking; an unchanged value is not reported).
                if (freezesReveal(next)) progressInputs().forEach(::reduce)
                reduce(next)
                if (next is RealtimeConversationInput.Session && next.event == RealtimeSessionEvent.Ready) {
                    lastTickAt = clock()
                    // Every Ready (reopens included) sends what was typed while connecting, reopening or dormant.
                    flushTyped()
                }
            }
        } finally {
            dispatching = false
            if (ended) pending.clear() else armTick()
            armProgress()
        }
    }

    /**
     * Feeds the player's played ms of every item that delivered audio this turn (floored, never negative) while
     * speaking; an unchanged value is not sent again.
     */
    private fun sendProgress() {
        val inputs = progressInputs()
        inputs.forEach(::dispatch)
        // Backstop for a completion callback that never comes (A16: tail stuck short of the end on a device):
        // the reply is complete and the head, once moving, has not moved for DRAIN_STALL_MS, so it is played out.
        // A head that never moved is a player not started yet, not a stuck tail.
        if (inputs.isNotEmpty() || !drainAwaited() || state.turn.played.values.none { it > 0L }) {
            stalledSince = null
            return
        }
        val since = stalledSince ?: clock().also { stalledSince = it }
        if (clock() - since >= DRAIN_STALL_MS) {
            stalledSince = null
            RealtimeVoiceLog.d("playback stalled ${clock() - since}ms after turn done: drained")
            dispatch(RealtimeConversationInput.PlaybackDrained)
        }
    }

    // Scope thread: when the played ms last stopped moving while a completed reply waits for its drain.
    private var stalledSince: Long? = null

    private fun progressInputs(): List<RealtimeConversationInput.PlaybackProgress> {
        if (ended || state.phase != RealtimePhase.SPEAKING) return emptyList()
        return state.turn.audioItems.mapNotNull { key ->
            val ms = audio.playedMs(key).coerceAtLeast(0L)
            if (ms == state.turn.played[key]) {
                null
            } else {
                RealtimeVoiceLog.d("progress itemId=$key playedMs=$ms", chatty = true)
                RealtimeConversationInput.PlaybackProgress(key.ifEmpty { null }, ms)
            }
        }
    }

    /** Inputs that freeze the reveal at what was played (E-603): stop, end, failure, barge-in, final user text. */
    private fun freezesReveal(input: RealtimeConversationInput): Boolean = when (input) {
        RealtimeConversationInput.TapOrb,
        RealtimeConversationInput.End,
        RealtimeConversationInput.SystemInterruption,
        RealtimeConversationInput.SessionExpired,
        RealtimeConversationInput.PlanChanged,
        is RealtimeConversationInput.Failed,
        -> true
        is RealtimeConversationInput.Session -> when (val event = input.event) {
            is RealtimeSessionEvent.UserSpeechStarted,
            RealtimeSessionEvent.Interrupted,
            is RealtimeSessionEvent.SessionEnded,
            -> true
            is RealtimeSessionEvent.UserTranscript -> event.final
            else -> false
        }
        else -> false
    }

    /** Keeps the progress timer running exactly while speaking with audio this turn; no timer otherwise. */
    private fun armProgress() {
        val wanted = !ended && state.phase == RealtimePhase.SPEAKING && state.turn.audioItems.isNotEmpty()
        if (!wanted) {
            cancelProgress()
            return
        }
        if (progressJob != null) return
        progressJob = scope.launch {
            while (true) {
                delay(PROGRESS_INTERVAL_MS)
                sendProgress()
            }
        }
    }

    private fun cancelProgress() {
        progressJob?.cancel()
        progressJob = null
    }

    private fun reduce(input: RealtimeConversationInput) {
        val before = state
        val wasDraining = before.drainPending
        val result = RealtimeConversationLogic.reduce(before, input)
        state = result.state
        for (effect in result.effects) {
            if (effect !is RealtimeConversationEffect.Persist) continue
            when (effect.role) {
                RealtimePersistRole.USER -> {
                    userPersisted++
                    userPersistedText = effect.text
                }
                RealtimePersistRole.ASSISTANT -> {
                    assistantPersisted++
                    assistantPersistedText = effect.text
                }
            }
        }
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
                    // Frames captured while the uplink is off are never sent, not even as a later gate flush.
                    audio.clearHeld()
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
                closing = true
                uplinkOn = false
                audio.clearHeld()
                lastFrameLevel = 0f
                levelWindow.reset()
                connection.close()
                cancelTick()
                cancelProgress()
                cancelReplan()
                // Cancelling the collection makes the driver stop the audio; a dormant session has no driver left.
                streamJob?.cancel()
                audio.stopIfRunning()
            }
            RealtimeConversationEffect.Reopen -> {
                val planChanged = input is RealtimeConversationInput.PlanChanged
                val dropped = dropElapsedSec.takeUnless { planChanged }
                dropElapsedSec = null
                startReopen(retireLive = planChanged, droppedElapsedSec = dropped)
            }
            RealtimeConversationEffect.DisableBargeIn -> audio.disableBargeIn()
            is RealtimeConversationEffect.Ended -> {
                ended = true
                cancelTick()
                cancelProgress()
                cancelReplan()
                streamJob?.cancel()
                abandonSpeechModel()
                audio.stopIfRunning()
                audio.closeSpeechModel()
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
            // The realtime engine's state word never produces the three keys below (for exhaustiveness only)
            ConversationStatusKey.CAPTION -> ConversationDisplayState.USER_SPEAKING
            ConversationStatusKey.SAY_AGAIN -> ConversationDisplayState.SAY_AGAIN
            ConversationStatusKey.CHECK_LANGUAGE -> ConversationDisplayState.CHECK_LANGUAGE
            ConversationStatusKey.THINKING -> ConversationDisplayState.THINKING
            ConversationStatusKey.SPEAKING, ConversationStatusKey.SPEAKING_TAP_TO_INTERRUPT -> ConversationDisplayState.SPEAKING
            ConversationStatusKey.MUTED -> ConversationDisplayState.MUTED
            ConversationStatusKey.AWAITING_APPROVAL -> ConversationDisplayState.AWAITING_APPROVAL
            ConversationStatusKey.ERROR -> ConversationDisplayState.ERROR
        }
        _caption.value = if (ended || error) "" else stageLine(state)?.captionText.orEmpty()
        _drafts.value = if (ended || error) {
            RealtimeDrafts(
                userPersisted = userPersisted,
                assistantPersisted = assistantPersisted,
                userPersistedText = userPersistedText,
                assistantPersistedText = assistantPersistedText,
            )
        } else {
            RealtimeDrafts(
                user = userCaption(state),
                assistant = assistantShown(state).ifEmpty { null },
                userAfterAssistant = state.turn.userAfterReply,
                userPersisted = userPersisted,
                assistantPersisted = assistantPersisted,
                userPersistedText = userPersistedText,
                assistantPersistedText = assistantPersistedText,
            )
        }
        publishLevel()
    }

    private fun publishLevel() {
        if (ended || state.phase != RealtimePhase.SPEAKING) {
            // Each speaking stretch starts from silence, not from the last window of the previous one.
            lastPlaybackLevel = 0f
            playbackWindow.reset()
        }
        _level.value = when {
            ended -> 0f
            state.phase == RealtimePhase.LISTENING && !state.muted -> lastFrameLevel
            state.phase == RealtimePhase.SPEAKING -> lastPlaybackLevel
            else -> 0f
        }
    }

    /**
     * Wraps the audio so the uplink can be gated: frames are dropped while the uplink is off (mute / screen reader win
     * over the speaker gate), and on the speaker route frames during playback and its guard window go through the
     * [RealtimeUplinkGate]. The inner audio is single-use, so a reopened driver's start only rebinds the callbacks
     * (contract C item 2) and the inner audio is stopped at most once.
     */
    private inner class GatedAudio(private val inner: RealtimeAudioIO) : RealtimeAudioIO by inner {
        @Volatile private var onFrame: (ByteArray) -> Unit = {}

        @Volatile private var onInterruption: () -> Unit = {}

        @Volatile private var onActivationFailed: (Throwable) -> Unit = {}
        private var innerStarted = false
        private var innerStopped = false

        // Inner audio has started capture (fully or late-opened); false for playback-only.
        private var innerCapturing = false

        // The gate steps on the capture thread; playback cycle changes come from the controller and player threads.
        private val gateLock = Any()
        private val gate = RealtimeUplinkGate()

        // Playback cycle in progress (between isPlaying false→true and its drain / interrupt); guarded by gateLock.
        private var cycleOpen = false

        // Capture thread only: index of the next stepped 20 ms frame and the frames the gate holds back.
        private var nextGateFrame = 0L
        private val held = ArrayDeque<Pair<Long, ByteArray>>()

        // This session's speech model, fed every 16 kHz capture frame on the capture thread; null = energy gate.
        // Cleared exactly once (session end or failed inference), and whoever clears it closes the model.
        private val speechModel = AtomicReference<SpeechProbModel?>(null)

        // Capture thread: latest speech probability stepped with each gate frame (0 before the first chunk);
        // null = no model this session, or inference failed (the gate then stays on energy).
        @Volatile private var speechProb: Float? = null

        init {
            inner.setOnCaptureFrame { samples -> feedSpeechModel(samples) }
            // A device change re-routed the output: retune the live session at once (Gemini records it).
            // E-602: a cycle in progress re-decides its uplink gate for the new route at once (cycle not restarted).
            inner.setOnRouteChanged { route ->
                synchronized(gateLock) { if (cycleOpen) gate.routeChanged(route) }
                scope.launch { if (!ended) connection.updateOutputRoute(route) }
            }
            // playbackDrained comes only from the player's completion callback, folded on the scope's thread.
            inner.setOnDrained {
                endCycle()
                scope.launch { if (drainAwaited()) dispatch(RealtimeConversationInput.PlaybackDrained) }
            }
            inner.setOnPlaybackLevel { db, samples ->
                if (ended || state.phase != RealtimePhase.SPEAKING) return@setOnPlaybackLevel
                playbackWindow.add(db, samples, RealtimePCM.OUTPUT_RATE)?.let { windowLevel ->
                    lastPlaybackLevel = windowLevel
                    if (!ended && state.phase == RealtimePhase.SPEAKING) _level.value = windowLevel
                }
            }
        }

        override fun start(onFrame: (ByteArray) -> Unit, onInterruption: () -> Unit) =
            start(onFrame, onInterruption, RealtimePCM.OUTPUT_RATE)

        override fun start(onFrame: (ByteArray) -> Unit, onInterruption: () -> Unit, uplinkRateHz: Int) =
            start(onFrame, onInterruption, uplinkRateHz) { onInterruption() }

        override fun start(
            onFrame: (ByteArray) -> Unit,
            onInterruption: () -> Unit,
            uplinkRateHz: Int,
            onActivationFailed: (Throwable) -> Unit,
        ) {
            this.onFrame = onFrame
            this.onInterruption = onInterruption
            this.onActivationFailed = onActivationFailed
            // Once stopped, start goes to the inner audio again so its single-use check still applies.
            if (innerStarted && !innerStopped) {
                // The inner layer was playback-only (session opened from typing) and the reconnect needs the microphone: start capture late.
                if (!innerCapturing) beginCapture { inner.startCapture(gatedFrames(uplinkRateHz), uplinkRateHz) }
                return
            }
            innerStarted = true
            beginCapture { startInner(uplinkRateHz) }
        }

        override fun startPlayback(onInterruption: () -> Unit, onActivationFailed: (Throwable) -> Unit) {
            this.onInterruption = onInterruption
            this.onActivationFailed = onActivationFailed
            // A reconnect only rebinds callbacks; after a stop it still hands off to the inner layer so its single-use check takes effect.
            if (innerStarted && !innerStopped) return
            innerStarted = true
            inner.startPlayback(
                onInterruption = {
                    dispatch(RealtimeConversationInput.SystemInterruption)
                    this.onInterruption()
                },
                onActivationFailed = { error ->
                    audioFailed = true
                    this.onActivationFailed(error)
                },
            )
        }

        override fun startCapture(onFrame: (ByteArray) -> Unit, uplinkRateHz: Int) {
            this.onFrame = onFrame
            if (!innerStarted || innerStopped || innerCapturing) return
            beginCapture { inner.startCapture(gatedFrames(uplinkRateHz), uplinkRateHz) }
        }

        /** Start capture: if the voice probability model is still loading, wait for it to settle first (same as full open), then [open]; on startup failure, end with an activation failure. */
        private fun beginCapture(open: () -> Unit) {
            innerCapturing = true
            val load = modelLoad
            if (load == null || innerStopped) {
                open()
                return
            }
            // Capture waits for the speech model decision; a failing start ends the stream like a failed activation.
            modelLoad = null
            modelWaitJob = scope.launch {
                val model = awaitSpeechModel(load)
                modelWaitJob = null
                if (ended || innerStopped) {
                    model?.let(::closeOffMain)
                    return@launch
                }
                model?.let(::useSpeechModel)
                try {
                    open()
                } catch (cancel: CancellationException) {
                    throw cancel
                } catch (failure: Throwable) {
                    this@GatedAudio.onActivationFailed(failure)
                }
            }
        }

        /** Inner capture frames -> level window + uplink gate (on the capture thread). */
        private fun gatedFrames(uplinkRateHz: Int): (ByteArray) -> Unit = { frame ->
            if (uplinkOn) {
                levelWindow.add(frame, uplinkRateHz)?.let { windowLevel ->
                    lastFrameLevel = windowLevel
                    if (state.phase == RealtimePhase.LISTENING) _level.value = windowLevel
                }
            }
            // The gate is stepped on every frame (also while the uplink is off) so its frame clock and noise
            // floor stay current; the uplink switch still decides whether anything is sent.
            gateFrame(frame, uplinkRateHz)
        }

        private fun startInner(uplinkRateHz: Int) {
            inner.start(
                onFrame = gatedFrames(uplinkRateHz),
                onInterruption = {
                    dispatch(RealtimeConversationInput.SystemInterruption)
                    this.onInterruption()
                },
                uplinkRateHz = uplinkRateHz,
                // Activation failure is handed to the currently bound driver: the stream ends with the same exception, matching the failure reason when start threw synchronously.
                onActivationFailed = { error ->
                    audioFailed = true
                    this.onActivationFailed(error)
                },
            )
        }

        override fun enqueue(pcm16: ByteArray, itemId: String) {
            val wasPlaying = inner.isPlaying
            inner.enqueue(pcm16, itemId)
            if (wasPlaying || !inner.isPlaying) return
            // A playback cycle starts: the route is sampled now.
            val route = inner.route
            synchronized(gateLock) {
                cycleOpen = true
                gate.playbackStarted(route)
            }
        }

        override fun stopPlayback() {
            inner.stopPlayback()
            endCycle()
        }

        fun disableBargeIn() = synchronized(gateLock) { gate.setBargeIn(false) }

        /** Model mode for the session: set before capture starts, so the gate's first frame can carry a probability. */
        fun useSpeechModel(model: SpeechProbModel) {
            // The gate gets a probability only once the model has eaten a capture tap frame: an audio without the
            // tap keeps it null, so the session stays on energy instead of a probability stuck at 0.
            speechProb = null
            speechModel.set(model)
        }

        /** Session end: the model is closed off the main thread; later capture frames are not fed. */
        fun closeSpeechModel() {
            speechModel.getAndSet(null)?.let(::closeOffMain)
        }

        /**
         * Capture thread: feeds one 16 kHz frame (fed continuously, also while muted or playing). A failed inference
         * leaves the probability null for good: the gate falls back to energy and the model is closed.
         */
        private fun feedSpeechModel(samples: ShortArray) {
            val model = speechModel.get() ?: return
            val prob = model.feed(samples)
            speechProb = prob
            if (prob == null && speechModel.compareAndSet(model, null)) {
                RealtimeVoiceLog.d("gate vad mode=energy reason=inference_failed")
                closeOffMain(model)
            }
        }

        /** Drops the held frames (the uplink was switched off). */
        fun clearHeld() = synchronized(gateLock) { held.clear() }

        private fun endCycle() = synchronized(gateLock) {
            // A late drained callback of an earlier cycle must not end the cycle that is playing now.
            if (!cycleOpen || inner.isPlaying) return@synchronized
            cycleOpen = false
            gate.playbackEnded()
        }

        /**
         * Steps the gate with each 20 ms frame of [frame] (dBFS as [RealtimePCM.blockDb], digital silence −120) and
         * sends, flushes or holds by its decision. A frame the gate passes whole is sent unchanged. Capture thread.
         */
        private fun gateFrame(frame: ByteArray, rateHz: Int) {
            val frameBytes = RealtimePCM.frameBytes(rateHz)
            val out = ArrayList<ByteArray>(1)
            var passedWhole = true
            var openedOnSpeech = false
            var offset = 0
            synchronized(gateLock) {
                while (offset < frame.size) {
                    val size = minOf(frameBytes, frame.size - offset)
                    val slice = if (offset == 0 && size == frame.size) frame else frame.copyOfRange(offset, offset + size)
                    val index = nextGateFrame++
                    // Read under gateLock: SetUplink(false) switches the flag before clearing the held frames.
                    val on = uplinkOn
                    val db = RealtimePCM.blockDb(frame, offset, size) ?: SILENT_FRAME_DB
                    when (val step = gate.step(db, speechProb?.toDouble(), inner.playbackReferenceDb())) {
                        UplinkGateStep.Send -> {
                            held.clear()
                            out += slice
                        }
                        UplinkGateStep.Hold -> {
                            passedWhole = false
                            // Frames captured while the uplink is off still step the gate but are never held.
                            if (on) held.addLast(index to slice)
                            // The gate never flushes further back than its preroll plus the speech it confirms.
                            if (held.size > MAX_HELD_FRAMES) held.removeFirst()
                        }
                        is UplinkGateStep.Open -> {
                            passedWhole = false
                            held.forEach { (at, bytes) -> if (at >= step.flushFromFrame) out += bytes }
                            held.clear()
                            out += slice
                            if (step.reason == UplinkGateOpenReason.SPEECH) openedOnSpeech = true
                        }
                    }
                    offset += size
                }
            }
            if (!uplinkOn) return
            // Speech opened the gate: the reducer arms its false barge-in check (on the controller's thread) before
            // the flushed frames can make the server answer.
            if (openedOnSpeech) scope.launch { dispatch(RealtimeConversationInput.GateOpened) }
            val send = onFrame
            if (passedWhole && out.size > 1) send(frame) else out.forEach(send)
        }

        override fun stop() {
            if (innerStopped) return
            innerStopped = true
            inner.stop()
            closeSpeechModel()
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

        // This session's connection reached Ready.
        @Volatile var connected = false

        init {
            driverAudio = this
        }

        override fun stop() {
            if (retired) return
            // An unexpected drop afterDrop does not end keeps the audio for the reopened connection (single-use inner).
            // A drop that ends (category or no progress since the reopen) dispatches Failed, whose Ended stops the audio.
            if (connected && reopensOnDrop() && afterDrop().action != RealtimeModel.AFTER_DROP_END) return
            audio.stop()
        }
    }

    companion object {
        /** Provider name RealtimeModel.afterDrop reads. */
        private fun RealtimeTransportKind.dropProvider(): String = when (this) {
            RealtimeTransportKind.OpenAiRealtime -> "openai"
            RealtimeTransportKind.XaiRealtime -> "xai"
            RealtimeTransportKind.GeminiLive -> "gemini"
        }

        /** Events that start or carry a turn's content: the first of them makes a home entry create its chat. */
        internal fun isTurnEvent(event: RealtimeSessionEvent): Boolean =
            event is RealtimeSessionEvent.AssistantAudio ||
                event is RealtimeSessionEvent.AssistantTranscript ||
                event is RealtimeSessionEvent.UserTranscript

        /** Due time of the next tick, [base] + [wait]; null (nothing armed) when [wait] is null or ≤ 0. */
        internal inline fun tickDueAt(wait: Long?, base: () -> Long): Long? =
            if (wait == null || wait <= 0L) null else base() + wait

        /** Longest gap between two playback progress reports while speaking. */
        const val PROGRESS_INTERVAL_MS = 100L

        /** Head standing still this long after the reply completed counts as played out. */
        const val DRAIN_STALL_MS = 300L

        /** dBFS stepped into the uplink gate for a digitally silent frame. */
        private const val SILENT_FRAME_DB = -120.0

        /** Longest wait for the speech model before capture starts (same as the cascade). */
        const val SPEECH_MODEL_WAIT_MS = VoiceConversationController.SPEECH_MODEL_WAIT_MS

        /** Held frames kept for a flush: 2 s, well beyond the preroll plus the longest speech confirmation. */
        private const val MAX_HELD_FRAMES = 100

        /** [ms] of mono PCM16 LE digital silence at [rateHz] (the connection's uplink rate). */
        fun silence(ms: Long, rateHz: Int = RealtimePCM.OUTPUT_RATE): ByteArray =
            ByteArray((rateHz * ms / 1000).toInt() * 2)
    }
}

/**
 * Splits uplink PCM16 LE frames into 20 ms frames at the uplink rate and yields, once per [PeakLevelWindow] window,
 * the level of the loudest of them. Frames arrive on the capture thread, [reset] on the controller's.
 */
internal class UplinkLevelWindow {
    private val window = PeakLevelWindow()

    /** Adds [frame] at [rateHz]; the level of the window it completes, or null while the window is still filling. */
    @Synchronized
    fun add(frame: ByteArray, rateHz: Int): Float? {
        val frameBytes = RealtimePCM.frameBytes(rateHz)
        var level: Float? = null
        var offset = 0
        while (offset < frame.size) {
            val size = minOf(frameBytes, frame.size - offset)
            window.add(RealtimePCM.blockDb(frame, offset, size), size / 2, rateHz)?.let { level = it }
            offset += size
        }
        return level
    }

    /** Drops a partly filled window (uplink gated off / session closed). */
    @Synchronized
    fun reset() {
        window.reset()
    }
}

/**
 * Peak level over windows of 1/[RATE_HZ] s of audio (by sample count at the stream's rate, not wall clock): the
 * orb level updates at most [RATE_HZ] times per second of audio whatever the block size. The window's level is its
 * loudest block's dBFS mapped with [ConversationFrames.levelFromDb] against [ConversationFrames.AI_LEVEL_FLOOR_DB]
 * (realtime has no local VAD noise floor); an all-silent window is 0. Thread-safe.
 */
internal class PeakLevelWindow {
    private var peakDb: Double? = null
    private var samples = 0

    /** Adds one block of [count] samples at [rateHz] with RMS [db] (null = digital silence); level once the window fills. */
    @Synchronized
    fun add(db: Double?, count: Int, rateHz: Int): Float? {
        if (count <= 0) return null
        val peak = peakDb
        if (db != null && (peak == null || db > peak)) peakDb = db
        samples += count
        if (samples < windowSamples(rateHz)) return null
        val level = peakDb?.let { ConversationFrames.levelFromDb(it, ConversationFrames.AI_LEVEL_FLOOR_DB) } ?: 0f
        reset()
        return level
    }

    /** Drops a partly filled window. */
    @Synchronized
    fun reset() {
        peakDb = null
        samples = 0
    }

    companion object {
        const val RATE_HZ = 15

        /** Samples per window, rounded up so a window never spans less than 1/[RATE_HZ] s. */
        fun windowSamples(rateHz: Int): Int = (rateHz + RATE_HZ - 1) / RATE_HZ
    }
}

/** Hands the model loaded off the main thread to the session; a result arriving after [take] is closed on arrival. */
private class SpeechModelLoad {
    private val arrived = CompletableDeferred<Unit>()
    private var result: Result<SpeechProbModel>? = null
    private var taken = false

    fun deliver(loaded: Result<SpeechProbModel>) {
        val accepted = synchronized(this) {
            if (!taken) result = loaded
            !taken
        }
        if (accepted) arrived.complete(Unit) else loaded.getOrNull()?.close()
    }

    suspend fun await(timeoutMs: Long) {
        withTimeoutOrNull(timeoutMs) { arrived.await() }
    }

    /** No longer accepts; returns the result that arrived (the caller owns its model), null when none did. */
    fun take(): Result<SpeechProbModel>? = synchronized(this) {
        taken = true
        result.also { result = null }
    }
}

/**
 * The two live bubbles of a realtime turn (null = not shown): never stored, never synced. [userAfterAssistant] = the
 * user barged in on the reply, so the reply is stored (and listed) first. [userPersisted] / [assistantPersisted] =
 * persist effects emitted so far this session per role, [userPersistedText] / [assistantPersistedText] the text of the
 * latest one: a cleared side still shows that text until the list holds that many of the session's stored messages of
 * the role.
 */
data class RealtimeDrafts(
    val user: String? = null,
    val assistant: String? = null,
    val userAfterAssistant: Boolean = false,
    val userPersisted: Int = 0,
    val assistantPersisted: Int = 0,
    val userPersistedText: String? = null,
    val assistantPersistedText: String? = null,
)
