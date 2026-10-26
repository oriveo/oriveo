package ai.oriveo.community.core.voice

import android.os.SystemClock
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.ProcessLifecycleOwner
import ai.oriveo.community.BuildConfig
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.provider.ProviderCredentialResolver
import ai.oriveo.community.core.provider.transport.EndpointResolver
import ai.oriveo.community.core.voice.conversation.CaptureTeardownGate
import ai.oriveo.community.core.voice.conversation.CaptureTeardownTimeoutException
import io.ktor.client.HttpClient
import java.io.File
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.yield

/** Where the primary button goes after a dictation failure: retry, check the connection, or no transcript produced. */
enum class DictationFailedAction {
    Retry,
    CheckConnection,
    NoTranscript,
}

/** Dictation state. */
sealed interface DictationState {
    data object Idle : DictationState

    /** Microphone permission was denied. */
    data object Denied : DictationState

    /** [startedAt] comes from the injected clock; the UI uses it to show the elapsed recording time. */
    data class Recording(val slotKey: String, val startedAt: Long) : DictationState

    data class Transcribing(val slotKey: String, val submit: DictationSubmit) : DictationState

    data class Interrupted(val slotKey: String) : DictationState

    data class Failed(val slotKey: String, val action: DictationFailedAction) : DictationState

    /** The slot with the same key still holds an untranscribed recording, so a new recording cannot start. */
    data class SlotOccupied(val slotKey: String) : DictationState
}

/** How a recording ends: "Transcribe" inserts into the input box, "↑" transcribes and sends directly. */
enum class DictationSubmit {
    Insert,
    Send,
}

/** One-shot events consumed by the UI (insert text, send, show a notice). */
sealed interface DictationEvent {
    data class Insert(val slotKey: String, val text: String) : DictationEvent

    data class Send(val slotKey: String, val text: String) : DictationEvent

    /** The pre-check heard no sound (too short or no voice): the recording was deleted and nothing was uploaded. */
    data class NoSpeech(val slotKey: String) : DictationEvent

    /** Microphone capture could not start (in use, or unsupported by the device): no slot was left behind. */
    data class RecordingUnavailable(val slotKey: String) : DictationEvent

    /**
     * A recording longer than 5 seconds was discarded with ✕: it moved to the recycle area and the UI shows an undo window.
     * The controller commits automatically after [DictationController.UNDO_WINDOW_MILLIS]; a new discard commits the previous one immediately, so only one window is open at a time.
     */
    data class DiscardUndoable(val slotKey: String) : DictationEvent

    /** The stored cloud choice is no longer valid (connection deleted / key cleared / entry withdrawn): this time the system engine is used and the setting was reset to system; emitted once. */
    data class EngineFallback(val slotKey: String, val reason: VoiceFallbackReason) : DictationEvent

    /** No usable system speech recognition on the device: recording was not started and no slot was left. */
    data class SystemUnavailable(val slotKey: String) : DictationEvent

    /** The self-recording recognizer failed: already-recognized text was emitted first as [Insert]; there is no recording to retry, so the state returns to Idle. */
    data class SystemRecognizerFailed(val slotKey: String) : DictationEvent
}

/**
 * Engine information shown by the recording UI: for the cloud, the [Provider.displayName] and [Provider.id] of the selected connection;
 * for the system engine, both are null.
 */
data class DictationEngineInfo(val displayName: String?, val providerId: String?, val isCloud: Boolean) {
    companion object {
        val System = DictationEngineInfo(displayName = null, providerId = null, isCloud = false)
    }
}

/** Dictation engine factory: production uses [DefaultDictationEngineFactory]; tests inject fake engines. */
interface DictationEngineFactory {
    fun system(): STTEngine

    /** Picks the system recognition route; no recording starts on [SystemSTTRoute.Unavailable]. */
    suspend fun systemRoute(language: String?): SystemSTTRoute

    /** Starts a self-recording recognition session (the recognizer opens the microphone itself and produces no recording file); throws if listening cannot start. */
    suspend fun startSelfRecord(route: SystemSTTRoute.SelfRecord): SystemSTTSelfRecordSession

    /** One self-recorded turn of a voice conversation: the recognizer ends it when it decides speech is over (turns do not accumulate). Defaults to [startSelfRecord]. */
    suspend fun startSelfRecordTurn(route: SystemSTTRoute.SelfRecord): SystemSTTSelfRecordSession =
        startSelfRecord(route)

    /** [baseUrl] is the connection address (only the origin is used, followed by the path of [entry]). */
    fun cloud(entry: VoiceSttEntry, baseUrl: String, apiKey: String): STTEngine
}

class DefaultDictationEngineFactory(
    private val httpClient: HttpClient,
    private val cloudCacheDir: File,
    private val systemEngine: SystemSTTEngine,
    private val router: SystemSTTRouter,
) : DictationEngineFactory {
    override fun system(): STTEngine = systemEngine

    override suspend fun systemRoute(language: String?): SystemSTTRoute = router.route(language)

    override suspend fun startSelfRecord(route: SystemSTTRoute.SelfRecord): SystemSTTSelfRecordSession =
        systemEngine.startSelfRecordSession(route)

    override suspend fun startSelfRecordTurn(route: SystemSTTRoute.SelfRecord): SystemSTTSelfRecordSession =
        systemEngine.startSelfRecordSession(route, singleRound = true)

    override fun cloud(entry: VoiceSttEntry, baseUrl: String, apiKey: String): STTEngine =
        CloudSTTEngine(httpClient, entry, baseUrl, apiKey, cloudCacheDir)
}

/** Voice catalog source: production uses [VoiceCatalogClient.asDictationCatalogSource]. */
interface DictationCatalogSource {
    suspend fun loadCached(): VoiceCatalog?

    suspend fun refresh(): VoiceCatalogState
}

fun VoiceCatalogClient.asDictationCatalogSource(): DictationCatalogSource = object : DictationCatalogSource {
    override suspend fun loadCached(): VoiceCatalog? = this@asDictationCatalogSource.loadCached()

    override suspend fun refresh(): VoiceCatalogState = this@asDictationCatalogSource.refresh()
}

/** Microphone permission: returns true immediately if already granted, otherwise shows the system prompt and suspends until the user chooses. */
fun interface MicrophonePermission {
    suspend fun request(): Boolean
}

/** Platform side effects of a dictation session. */
interface DictationEnvironment {
    /** Stops any read-aloud in progress before dictation starts. */
    fun stopReadAloud()

    /** Recognition language (e.g. zh-Hans); null means no language hint. */
    fun recognitionLanguage(): String?

    /**
     * Observes interruptions while recording; closing the returned value unregisters. Called on the main thread, and [onInterrupted] is also invoked on the main thread.
     * Production only hooks into going to the background (ProcessLifecycleOwner ON_STOP); other interruption sources such as phone calls are called back separately by the implementation.
     */
    fun observeInterruptions(onInterrupted: () -> Unit): AutoCloseable {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_STOP) onInterrupted()
        }
        val lifecycle = ProcessLifecycleOwner.get().lifecycle
        lifecycle.addObserver(observer)
        return AutoCloseable { lifecycle.removeObserver(observer) }
    }
}

/** Fixed host identity used by [DictationCommands.bind] / [DictationCommands.detach] when the host passes none. */
data object DefaultDictationOwner

/**
 * The dictation control surface used by the host (input box): the state flows and commands. Implemented by [DictationController]; the host coordinator depends only on this interface, which keeps pure-JVM tests simple.
 */
interface DictationCommands {
    val state: StateFlow<DictationState>
    val engineInfo: StateFlow<DictationEngineInfo?>
    val pendingDurationSec: StateFlow<Double?>
    val levelMeter: StateFlow<List<Float>>

    /** The current host identity: set by [bind], cleared (null) when [detach] takes effect. */
    val boundOwner: StateFlow<Any?>

    fun start(slotKey: String)

    fun finish(submit: DictationSubmit)

    fun discard()

    fun transcribeSaved(submit: DictationSubmit)

    fun discardAndRestart()

    fun dismissDenied()

    fun undoDiscard(slotKey: String): Boolean

    fun bind(slotKey: String, owner: Any = DefaultDictationOwner)

    fun detach(slotKey: String, owner: Any = DefaultDictationOwner)
}

/**
 * Main dictation flow: permission -> pick engine -> record (written into a [RecordingStore] slot) -> pre-check -> transcribe -> result event.
 * Only one session exists at a time; public methods are called on the main thread, and disk and capture operations run serially in submission order on [io] via [onStore].
 * The engine is chosen before recording starts from settings + catalog + connections ([providers], in the connection order from settings); this recording's transcription and retries all use it;
 * it is cleared after [bind] switches slots, and transcribing a saved recording re-resolves it from the current settings.
 *
 * When the UI switches conversation / cold-starts it calls [bind] to bind the slot key: a recording in progress is first wrapped up into Interrupted on the old slot before switching,
 * and if the new slot holds a previous recording (interrupted / failed / transcription killed) it shows Interrupted.
 * A controller has one host: the most recently bound slot receives events; when the host leaves it calls [detach], and a recording / transcription in progress is wrapped up as an interruption.
 * If transcription succeeds after the host has left that slot, nothing is inserted / sent and the recording is not deleted; it stays Interrupted until the host returns.
 *
 * When the system route is self-recording ([SystemSTTRoute.SelfRecord]) the file-less branch runs: the recognizer opens the microphone itself, no slot is created, no [capture] is opened,
 * and nothing counts as lost; there is no recording to retry, so it never enters Interrupted / Failed, and both interruptions and errors wrap up with the recognized text and return to Idle.
 */
class DictationController(
    private val engines: DictationEngineFactory,
    private val settings: VoiceEngineSettings,
    private val catalog: DictationCatalogSource,
    private val providers: suspend () -> List<Provider>,
    private val capture: AudioCapture,
    private val store: RecordingStore,
    private val encoderFactory: () -> AacEncoder,
    private val permission: MicrophonePermission,
    private val environment: DictationEnvironment,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
    private val io: CoroutineDispatcher = Dispatchers.IO,
    private val clock: () -> Long = SystemClock::elapsedRealtime,
    private val disclosure: VoiceDisclosureStore = settings.disclosure,
    private val catalogRefreshTimeoutMillis: Long = CATALOG_REFRESH_TIMEOUT_MILLIS,
    /** Suspends until in-flight capture teardowns of voice / realtime sessions are done (one process-wide gate); returns false on timeout, so we never coexist with an AudioRecord that is still being released. */
    private val awaitCaptureTeardowns: suspend () -> Boolean = { CaptureTeardownGate.Shared.awaitTeardowns() },
    /**
     * Registers a dictation capture teardown on the same gate (registration only, does not block) and returns an idempotent "finished" callback:
     * voice / realtime sessions wait on it before opening capture, so they never coexist with an AudioRecord that dictation is still stopping.
     */
    private val beginCaptureTeardown: () -> () -> Unit = { CaptureTeardownGate.Shared.beginTeardown() },
) : DictationCommands {
    /** Serial lock for slot-store reads and writes: undo restores, bind reads, discards, etc. queue in order and never interleave across two io threads. */
    private val storeLock = Mutex()

    private val _state = MutableStateFlow<DictationState>(DictationState.Idle)
    override val state: StateFlow<DictationState> = _state.asStateFlow()

    private val _engineInfo = MutableStateFlow<DictationEngineInfo?>(null)

    /** The engine selected for this recording (decided when recording starts or a saved recording is transcribed); cleared on return to Idle. */
    override val engineInfo: StateFlow<DictationEngineInfo?> = _engineInfo.asStateFlow()

    private val _pendingDurationSec = MutableStateFlow<Double?>(null)

    /** The slot key that [_pendingDurationSec] belongs to, and the sidecar read in flight. */
    private var pendingDurationKey: String? = null
    private var pendingDurationJob: Job? = null

    /** The recording duration from the slot sidecar while Interrupted / SlotOccupied / Failed (null if unreadable); null in other states. */
    override val pendingDurationSec: StateFlow<Double?> = _pendingDurationSec.asStateFlow()

    private val meter = DictationLevelMeter(clock)

    /** Recent audio levels while recording (up to 24, oldest first, 0..1) for the waveform; cleared on leaving Recording, and stays an empty list when the recognizer self-records without PCM. */
    override val levelMeter: StateFlow<List<Float>> = meter.levels

    private val _events = Channel<DictationEvent>(Channel.BUFFERED)
    val events: Flow<DictationEvent> = _events.receiveAsFlow()

    private var slot: RecordingSlot? = null
    private var job: Job? = null
    private var interruptions: AutoCloseable? = null

    /** The engine selected for this recording; chosen before recording starts and reused for transcription and retries. */
    private var engine: STTEngine? = null

    /** Whether [engine] is a cloud engine; decided together with [engine]. */
    private var engineCloud = false

    /** Start time of the file-less branch recording. */
    private var selfRecordStartedAt = 0L

    /** The self-recording session in progress on the file-less branch; cleared on wrap-up (including discard and interruption), so late results are ignored. */
    private var selfRecord: SystemSTTSelfRecordSession? = null

    /** The coroutine waiting for the self-recording session result: it wraps up both the result after the user stops and a recognizer error during recording. */
    private var selfRecordWatch: Job? = null

    /** The slot key the UI currently shows (host); set by [bind] or [start], cleared by [detach]. */
    private var boundKey: String? = null

    private val _boundOwner = MutableStateFlow<Any?>(null)

    /** The identity of the host bound to [boundKey]: when another host binds the same key the owner changes, and the old owner's [detach] no longer takes effect. */
    override val boundOwner: StateFlow<Any?> = _boundOwner.asStateFlow()

    /** The coroutine of the start flow (permission -> pick engine -> open slot); cancelled when switching conversations. */
    private var startJob: Job? = null

    /** The sweep + slot-read coroutine launched by [bind]; while it runs, [start] waits for it to finish and then acts on the state at that time, instead of treating it as a session in progress. */
    private var bindJob: Job? = null

    /** The discard / undo wrap-up coroutine of the current slot; while it runs, [start] likewise waits for it to finish and then acts on the state at that time. */
    private var storeJob: Job? = null

    /** The open undo window: the slot key waiting in the recycle area to be committed, and the timer that commits it; only one is open at a time. */
    private var undoKey: String? = null
    private var undoTimer: Job? = null

    /**
     * Binds the slot key the UI currently shows (after switching conversation or cold start into a conversation); [owner] becomes the current host.
     * The same key only changes the host (the home page and a new chat without a conversation share one key: when the new page binds first and the old page detaches later, the binding is not cleared).
     * A recording in progress on the old slot is first wrapped up as an interruption (the file-less branch inserts the recognized text); while transcribing, the transcription in flight is cancelled and the sidecar is set to interrupted;
     * a start flow that has not opened a slot yet is cancelled.
     * The undo window is unaffected and commits on time as usual.
     * If the new slot holds a saved recording (interrupted / failed / killed while transcribing) it shows Interrupted, otherwise Idle.
     * Switching slots clears the selected engine: when the saved recording is transcribed it is re-resolved from the settings at that time.
     * Before the first bind in this process, the slot store is swept once (expiry, lost count, crash recovery); see [sweepOnceBeforeFirstBind].
     */
    override fun bind(slotKey: String, owner: Any) {
        if (boundKey == slotKey) {
            _boundOwner.value = owner
            return
        }
        boundKey = slotKey
        _boundOwner.value = owner
        val pending = leaveCurrentSlot()
        engine = null
        setState(DictationState.Idle)
        job = scope.launch {
            pending?.join()
            val saved = onStore {
                sweepOnceBeforeFirstBind()
                store.read(slotKey)
            } != null
            if (saved && boundKey == slotKey && _state.value == DictationState.Idle) {
                setState(DictationState.Interrupted(slotKey))
            }
        }.also { bindJob = it }
    }

    /**
     * Preview sample (DEBUG only): shows [state] directly without starting an engine, requesting recording, or opening a slot; a state with a slot key also makes it the current host key,
     * so a host that binds the same key afterwards only changes owner and does not clear the state set here. While Recording the levels are fixed to [levels]; when not Idle the engine info is [engineInfo].
     */
    fun showForShots(state: DictationState, levels: List<Float> = emptyList(), engineInfo: DictationEngineInfo? = null) {
        if (!BuildConfig.DEBUG) return
        val key = when (state) {
            is DictationState.Recording -> state.slotKey
            is DictationState.Transcribing -> state.slotKey
            is DictationState.Interrupted -> state.slotKey
            is DictationState.Failed -> state.slotKey
            is DictationState.SlotOccupied -> state.slotKey
            DictationState.Idle, DictationState.Denied -> null
        }
        if (key != null) boundKey = key
        setState(state)
        if (state != DictationState.Idle) _engineInfo.value = engineInfo
        if (state is DictationState.Recording) meter.showForShots(levels)
    }

    /** The only entry point for changing state: returning to Idle clears the engine info; leaving Recording clears the levels; entering a saved-recording state reads the sidecar duration. */
    private fun setState(next: DictationState) {
        _state.value = next
        if (next !is DictationState.Recording) meter.reset()
        if (next == DictationState.Idle) _engineInfo.value = null
        val pendingKey = when (next) {
            is DictationState.Interrupted -> next.slotKey
            is DictationState.SlotOccupied -> next.slotKey
            is DictationState.Failed -> next.slotKey
            else -> null
        }
        // The sidecar is read on io and published back on the main thread; the same key keeps the old value until the read finishes, while a new key or leaving clears it first. A new state cancels the previous read.
        pendingDurationJob?.cancel()
        pendingDurationJob = null
        if (pendingKey != pendingDurationKey) _pendingDurationSec.value = null
        pendingDurationKey = pendingKey
        if (pendingKey == null) return
        pendingDurationJob = scope.launch {
            val duration = onStore { runCatching { store.read(pendingKey)?.durationSec }.getOrNull() }
            _pendingDurationSec.value = duration
        }
    }

    /**
     * Stops capture (on io: joins the capture thread and releases the AudioRecord), and once stopped releases the [stopped] registered on the gate (also released if stopping errors).
     * The caller invokes [stopped] once more when its coroutine ends as a safety net: if this was never reached (cancelled), the gate is not held forever.
     */
    private fun stopCapture(stopped: (() -> Unit)?) {
        try {
            capture.stop()
        } finally {
            stopped?.invoke()
        }
    }

    /**
     * Runs a slot-store / capture operation on [io], serialized with other such operations (first come, first served); with [nonCancellable], both queueing and execution are non-cancellable.
     * io.limitedParallelism(1) is not used: the Unconfined dispatcher injected by tests does not support deriving a limited view.
     */
    private suspend fun <T> onStore(nonCancellable: Boolean = false, block: suspend CoroutineScope.() -> T): T =
        if (nonCancellable) {
            withContext(NonCancellable) { storeLock.withLock { withContext(io, block) } }
        } else {
            storeLock.withLock { withContext(io, block) }
        }

    /** Dismisses the permission-denied card: returns to Idle only from Denied, ignored in other states. */
    override fun dismissDenied() {
        if (_state.value == DictationState.Denied) setState(DictationState.Idle)
    }

    /** The same slot-store directory is swept only once per process: only after the original slot has been wrapped up as interrupted, so this process's own recording is never mistaken for crash recovery. */
    private fun sweepOnceBeforeFirstBind() {
        val key = store.root.absoluteFile.normalize().path
        if (!synchronized(sweptRoots) { sweptRoots.add(key) }) return
        runCatching { store.sweepOnLaunch() }
    }

    /** Wraps up the current slot before leaving; returns the task that must finish before switching. */
    private fun leaveCurrentSlot(): Job? {
        val state = _state.value
        if (state is DictationState.Recording) {
            interrupt()
            return null
        }
        if (state is DictationState.Transcribing) return abandonTranscription(state.slotKey)
        val inFlight = job?.takeIf { it.isActive } ?: return null
        // A start flow is cancelled directly; wrap-up tasks such as discard and slot reads are awaited.
        if (inFlight === startJob) inFlight.cancel()
        return inFlight
    }

    /**
     * Wraps up while transcribing (switching away / host leaving): the file-less branch inserts the recognized text; the file branch cancels the transcription in flight and, once it ends, sets the sidecar to interrupted.
     * Returns the task to wait for (null for the file-less branch); the caller sets the state.
     */
    private fun abandonTranscription(slotKey: String): Job? {
        selfRecord?.let { session ->
            // Leaving while waiting for the file-less result: there is no recording to keep, and the recognized text is inserted as for an interruption.
            insertInterruptedSelfRecord(slotKey, abandonSelfRecord(session))
            return null
        }
        val inFlight = job?.takeIf { it.isActive }
        inFlight?.cancel()
        return scope.launch {
            inFlight?.join()
            onStore { store.markInterrupted(slotKey) }
        }
    }

    /**
     * Host leaves (UI destroyed / leaves the conversation): takes effect only if the current slot key is [slotKey] and the host identity is [owner], and clears the host.
     * While recording it wraps up via [interrupt]; while transcribing it cancels the transcription in flight and leaves the recording as Interrupted (the file-less branch inserts the recognized text and returns to Idle, with the event left in the channel).
     * Interrupted / Failed / SlotOccupied / Idle are unchanged; a start flow whose permission returns after the host has left is voided.
     */
    override fun detach(slotKey: String, owner: Any) {
        if (boundKey != slotKey || _boundOwner.value != owner) return
        boundKey = null
        _boundOwner.value = null
        when (val state = _state.value) {
            is DictationState.Recording -> if (state.slotKey == slotKey) interrupt()
            is DictationState.Transcribing -> if (state.slotKey == slotKey) {
                val selfRecording = selfRecord != null
                val pending = abandonTranscription(slotKey)
                if (selfRecording) {
                    setState(DictationState.Idle)
                } else {
                    job = pending
                    setState(DictationState.Interrupted(slotKey))
                }
            }
            else -> Unit
        }
    }

    /**
     * Microphone tap: stops read-aloud first, then checks the slot; if the same key still holds a recording it enters SlotOccupied for the user to choose, without requesting permission or resolving an engine;
     * only if the slot is empty does it request permission, pick an engine, open a slot, and start capture. Ignored while a session is in progress.
     * If binding for the same key (first cold-start sweep, slot read) or a discard / undo wrap-up is still running, the tap is not dropped: read-aloud stops first, and once it finishes the flow above runs against the state at that time.
     */
    override fun start(slotKey: String) {
        val active = job?.takeIf { it.isActive }
        if (active != null && (active === bindJob || active === storeJob) && boundKey == slotKey) {
            environment.stopReadAloud()
            job = scope.launch {
                // Even if cancelled by a conversation switch, still wait for the bind to finish: a later bind waits on this task, so the sweep must not still be running.
                withContext(NonCancellable) { active.join() }
                if (!isActive || boundKey != slotKey) return@launch
                when (_state.value) {
                    DictationState.Idle, DictationState.Denied, is DictationState.Interrupted, is DictationState.Failed -> Unit
                    else -> return@launch
                }
                if (!askIfOccupied(slotKey)) begin(slotKey)
            }.also { startJob = it }
            return
        }
        if (active != null) return
        when (_state.value) {
            DictationState.Idle, DictationState.Denied, is DictationState.Interrupted, is DictationState.Failed -> Unit
            else -> return
        }
        // If the key is already current, the host is not changed; when the key changes, the current host is kept (or the default identity if it has left).
        if (boundKey != slotKey) bind(slotKey, _boundOwner.value ?: DefaultDictationOwner)
        val binding = job?.takeIf { it.isActive }
        environment.stopReadAloud()
        job = scope.launch {
            if (askIfOccupied(slotKey)) return@launch
            // The first-bind sweep must finish first, so a slot just opened is not mistaken for crash recovery.
            binding?.join()
            begin(slotKey)
        }.also { startJob = it }
    }

    /** If the same key still holds a recording, enters SlotOccupied for the user to choose and returns true; returns false if the slot is empty. */
    private suspend fun askIfOccupied(slotKey: String): Boolean {
        if (!onStore { store.isOccupied(slotKey) }) return false
        // Does not go through bind to switch to the occupied key: the engine chosen for the previous recording is not reused, and "Transcribe first" re-resolves from the current settings.
        engine = null
        _engineInfo.value = null
        setState(DictationState.SlotOccupied(slotKey))
        return true
    }

    /** Permission -> pick engine -> open slot and start capture; if the host has left the slot when permission returns, or after the engine is chosen and before the slot is opened, the start is voided (no slot is created). */
    private suspend fun begin(slotKey: String) {
        val granted = permission.request()
        if (abandonedByHost(slotKey)) return
        if (!granted) {
            setState(DictationState.Denied)
            return
        }
        val selection = selectEngine(slotKey) ?: return
        if (abandonedByHost(slotKey)) return
        _engineInfo.value = selection.info
        val selected = when (selection) {
            is EngineSelection.SelfRecord -> {
                beginSelfRecord(slotKey, selection.route)
                return
            }
            is EngineSelection.WithFile -> selection
        }
        engine = selected.engine
        engineCloud = selected.info.isCloud
        val relay = CaptureRelay()
        // Opening the slot and starting capture are non-cancellable: when a conversation switch cancels the start, a slot already opened must be torn down here and not left half-way.
        val opened = onStore(nonCancellable = true) { openAndCapture(slotKey, selected, relay) }
        if (!currentCoroutineContext().isActive) {
            if (opened is OpenResult.Opened) {
                val stopped = beginCaptureTeardown()
                try {
                    onStore(nonCancellable = true) {
                        stopCapture(stopped)
                        runCatching { opened.slot.finish(RecordingSlotStatus.Failed) }
                        store.complete(slotKey)
                    }
                } finally {
                    stopped()
                }
            }
            return
        }
        when (opened) {
            OpenResult.Occupied -> setState(DictationState.SlotOccupied(slotKey))
            OpenResult.Unavailable -> {
                setState(DictationState.Idle)
                _events.trySend(DictationEvent.RecordingUnavailable(slotKey))
            }
            is OpenResult.Opened -> {
                relay.target = opened.slot
                slot = opened.slot
                setState(DictationState.Recording(slotKey, clock()))
                // Levels are collected only after entering Recording: a capture torn down mid-start leaves no value behind.
                meter.start()
                interruptions = environment.observeInterruptions(::interrupt)
                // If capture already errored / was muted before the slot was attached, that report found no slot, so wrap up here.
                if (relay.reported) interrupt()
            }
        }
    }

    /** The host is no longer on [slotKey] while starting: if it left (no host) return to Idle; if it moved to another slot, leave that slot's state alone. */
    private fun abandonedByHost(slotKey: String): Boolean {
        if (boundKey == slotKey) return false
        if (boundKey == null) setState(DictationState.Idle)
        return true
    }

    /** Starts recording on the file-less branch: the recognizer opens the microphone itself; a failure to start listening is treated as capture being unable to start. */
    private suspend fun beginSelfRecord(slotKey: String, route: SystemSTTRoute.SelfRecord) {
        engine = null
        val session = try {
            engines.startSelfRecord(route)
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            setState(DictationState.Idle)
            _events.trySend(DictationEvent.RecordingUnavailable(slotKey))
            return
        }
        if (!currentCoroutineContext().isActive) {
            // Switched away while starting to listen: shut the recognizer down and do not enter recording.
            session.interrupt()
            return
        }
        selfRecord = session
        selfRecordStartedAt = clock()
        setState(DictationState.Recording(slotKey, selfRecordStartedAt))
        // There is no app capture: the recording bar's level comes from the recognizer's onRmsChanged.
        meter.start()
        session.onLevel = meter::onRecognizerRmsDb
        interruptions = environment.observeInterruptions(::interrupt)
        selfRecordWatch = scope.launch { concludeSelfRecord(slotKey, session, session.await()) }
    }

    /** The self-recording session produced a result: on success insert / send according to how it ended (empty text means NoSpeech); on failure first insert the already-recognized text, then report the recognizer failure. */
    private fun concludeSelfRecord(slotKey: String, session: SystemSTTSelfRecordSession, result: STTResult) {
        if (selfRecord !== session) return
        selfRecord = null
        selfRecordWatch = null
        releaseInterruptions()
        val submit = (_state.value as? DictationState.Transcribing)?.submit ?: DictationSubmit.Insert
        setState(DictationState.Idle)
        when (result) {
            is STTResult.Success -> {
                val empty = DictationRules.trim(result.text).isEmpty()
                _events.trySend(
                    when {
                        empty -> DictationEvent.NoSpeech(slotKey)
                        submit == DictationSubmit.Send -> DictationEvent.Send(slotKey, result.text)
                        else -> DictationEvent.Insert(slotKey, result.text)
                    },
                )
            }
            is STTResult.Failed -> {
                // A failed result carries no text; the already-recognized part comes from the text the session accumulated.
                val recognized = session.transcript
                if (DictationRules.trim(recognized).isNotEmpty()) {
                    // Already-recognized text is still inserted.
                    _events.trySend(DictationEvent.Insert(slotKey, recognized))
                }
                _events.trySend(DictationEvent.SystemRecognizerFailed(slotKey))
            }
        }
    }

    /** The file-less branch was interrupted / the host left: insert the recognized text if there is any. */
    private fun insertInterruptedSelfRecord(slotKey: String, recognized: String) {
        if (DictationRules.trim(recognized).isEmpty()) return
        _events.trySend(DictationEvent.Insert(slotKey, recognized))
    }

    /** Early wrap-up of the file-less branch (interruption / discard): abandons the current round, stops waiting for the session result, and returns the recognized text. */
    private fun abandonSelfRecord(session: SystemSTTSelfRecordSession): String {
        selfRecord = null
        selfRecordWatch?.cancel()
        selfRecordWatch = null
        releaseInterruptions()
        session.interrupt()
        return session.transcript
    }

    /** Ends the recording and transcribes: [submit] decides whether success inserts or sends. Ignored when not recording. */
    override fun finish(submit: DictationSubmit) {
        val recording = _state.value as? DictationState.Recording ?: return
        selfRecord?.let { session ->
            // File-less branch: ask the recognizer to end this round; the result is wrapped up by selfRecordWatch.
            setState(DictationState.Transcribing(recording.slotKey, submit))
            session.stop()
            return
        }
        val current = slot ?: return
        slot = null
        releaseInterruptions()
        val slotKey = recording.slotKey
        setState(DictationState.Transcribing(slotKey, submit))
        // The capture stop is registered at the moment stop is tapped; voice / realtime sessions that open capture afterwards wait for it to finish.
        val stopped = beginCaptureTeardown()
        job = scope.launch {
            // ✕ while transcribing cancels this coroutine: closing the file and finalizing the sidecar are non-cancellable, so a discard can judge undoability by the real duration.
            var closed = true
            val meta = onStore(nonCancellable = true) {
                stopCapture(stopped)
                closed = closeSlot(current, RecordingSlotStatus.Ready)
                store.read(slotKey)
            }
            if (!closed) {
                // Closing the file failed: the part already written stays in the slot and the state goes to Failed so the user can retry or discard; it is not treated as a missing sidecar and cleared.
                fail(slotKey, DictationFailedAction.Retry)
                return@launch
            }
            if (meta == null) {
                // The sidecar is gone after finalizing (disk full / deleted): the recording can no longer be transcribed, so clear the orphan audio and return to Idle.
                dropUnreadableSlot(slotKey)
                return@launch
            }
            if (DictationRules.precheck(meta.durationSec, meta.envelope) != DictationPrecheck.Ok) {
                onStore { store.complete(slotKey) }
                setState(DictationState.Idle)
                _events.trySend(DictationEvent.NoSpeech(slotKey))
                return@launch
            }
            transcribe(slotKey, submit, meta)
        }.also { it.invokeOnCompletion { stopped() } }
    }

    /** Tapping "Retry" on Failed: transcribes the recording kept in the slot once more; on success it only inserts and never sends directly (even if "↑" was tapped originally). */
    fun retry() {
        if (_state.value !is DictationState.Failed) return
        transcribeSaved(DictationSubmit.Insert)
    }

    /**
     * Transcribes the recording kept in the slot: "Transcribe" / "↑" on Interrupted, "Transcribe first" on SlotOccupied, or retry on Failed.
     * No pre-check is done (a crash-recovered sidecar has no envelope); the segment's envelope and primingFrames come from the sidecar, and if the sidecar is gone it returns to Idle.
     * On success it inserts or sends per [submit] and deletes the slot; on failure it enters Failed and the recording stays. Ignored in other states.
     */
    override fun transcribeSaved(submit: DictationSubmit) {
        val slotKey = when (val state = _state.value) {
            is DictationState.Interrupted -> state.slotKey
            is DictationState.SlotOccupied -> state.slotKey
            is DictationState.Failed -> state.slotKey
            else -> return
        }
        if (job?.isActive == true) return
        setState(DictationState.Transcribing(slotKey, submit))
        job = scope.launch {
            val meta = onStore { store.read(slotKey) }
            if (meta == null) {
                dropUnreadableSlot(slotKey)
                return@launch
            }
            // Found expired or lost while running (sidecar present, audio missing): clear the slot as the launch sweep does and return to Idle.
            val gone = onStore { store.isExpired(meta) || !store.audioFile(slotKey).exists() }
            if (gone) {
                dropUnreadableSlot(slotKey)
                return@launch
            }
            transcribe(slotKey, submit, meta)
        }
    }

    /** "Discard and re-record" on SlotOccupied: deletes the old recording directly (the new recording takes the same slot, so no undo is offered), then starts a new recording. Ignored in other states. */
    override fun discardAndRestart() {
        val occupied = _state.value as? DictationState.SlotOccupied ?: return
        if (job?.isActive == true) return
        val slotKey = occupied.slotKey
        setState(DictationState.Idle)
        environment.stopReadAloud()
        job = scope.launch {
            onStore { store.complete(slotKey) }
            begin(slotKey)
        }.also { startJob = it }
    }

    /** The recording was interrupted (backgrounded, phone call, etc.): switches to Interrupted synchronously; stopping capture, closing the file, and marking the sidecar interrupted run on io, and the recording stays in the slot. Ignored in other states. */
    fun interrupt() {
        val recording = _state.value as? DictationState.Recording ?: return
        selfRecord?.let { session ->
            // The file-less branch has no recording to keep: the recognized text is inserted directly and the state returns to Idle.
            val recognized = abandonSelfRecord(session)
            setState(DictationState.Idle)
            insertInterruptedSelfRecord(recording.slotKey, recognized)
            return
        }
        val current = slot ?: return
        slot = null
        releaseInterruptions()
        // Stopping capture joins the capture thread, so it must not run on the main thread. ADTS flushes after every frame and has no file trailer, so killing the process before closing loses nothing already written:
        // on the next launch sweepOnLaunch recomputes sidecars still marked recording from the file and sets them to interrupted.
        // UNDISPATCHED: it is already queued on storeLock before returning, so later slot-store operations of a slot switch / new recording queue behind it.
        // Queue the wrap-up before switching state: the sidecar duration read started by setState also goes through storeLock and must queue after the file is closed and the duration finalized.
        val stopped = beginCaptureTeardown()
        scope.launch(start = CoroutineStart.UNDISPATCHED) {
            onStore(nonCancellable = true) {
                stopCapture(stopped)
                if (!closeSlot(current, RecordingSlotStatus.Interrupted)) {
                    // Closing the file failed: the part already written stays in the slot anyway, and we mark the sidecar interrupted on a best-effort basis.
                    runCatching { store.markInterrupted(recording.slotKey) }
                }
            }
        }.invokeOnCompletion { stopped() }
        setState(DictationState.Interrupted(recording.slotKey))
    }

    /**
     * ✕ discards a recording that is recording / transcribing / interrupted / failed / occupying a slot: one longer than 5 seconds goes to the recycle area and emits [DictationEvent.DiscardUndoable]; otherwise it is deleted directly.
     * While transcribing, the transcription in flight is cancelled first and the discard happens after it wraps up.
     */
    override fun discard() {
        selfRecord?.let { session ->
            // File-less branch: there is no recording to undo, so return to Idle immediately.
            commitUndoWindow()
            abandonSelfRecord(session)
            setState(DictationState.Idle)
            return
        }
        val transcribing = _state.value is DictationState.Transcribing
        val slotKey = when (val state = _state.value) {
            is DictationState.Recording -> state.slotKey
            is DictationState.Transcribing -> state.slotKey
            is DictationState.Interrupted -> state.slotKey
            is DictationState.Failed -> state.slotKey
            is DictationState.SlotOccupied -> state.slotKey
            else -> return
        }
        val inFlight = job?.takeIf { it.isActive }
        if (inFlight != null && !transcribing) return
        // A new discard makes the previous undo window take effect immediately: the window closes first, and the recycle area and this discard are handled in order within the same io section.
        val previousUndoKey = undoKey?.also { closeUndoWindow() }
        inFlight?.cancel()
        val current = slot
        slot = null
        releaseInterruptions()
        setState(DictationState.Idle)
        // Discarding while recording: capture is still open, so the capture stop is registered at this moment.
        val stopped = if (current != null) beginCaptureTeardown() else null
        job = scope.launch {
            inFlight?.join()
            val result = onStore {
                previousUndoKey?.let { key -> store.commitDiscard(key) }
                if (current != null) {
                    // Close the file first so the duration is written into the sidecar; only then can the discard judge by duration whether it is undoable.
                    stopCapture(stopped)
                    closeSlot(current, RecordingSlotStatus.Interrupted)
                }
                store.discard(slotKey)
            }
            // If the transcription in flight already deleted the slot successfully (result is null), there is nothing left to wrap up.
            if (result == null) return@launch
            if (result.undoable) {
                openUndoWindow(slotKey)
                _events.trySend(DictationEvent.DiscardUndoable(slotKey))
            }
        }.also { storeJob = it }.also { it.invokeOnCompletion { stopped?.invoke() } }
    }

    /** Opens the undo window: commits automatically after [UNDO_WINDOW_MILLIS]; switching conversations does not affect it. */
    private fun openUndoWindow(slotKey: String) {
        commitUndoWindow()
        undoKey = slotKey
        undoTimer = scope.launch {
            delay(UNDO_WINDOW_MILLIS)
            undoTimer = null
            val key = undoKey ?: return@launch
            closeUndoWindow()
            commitInIo(key)
        }
    }

    /** Commits the open undo window (ignored if there is none). */
    private fun commitUndoWindow() {
        val slotKey = undoKey ?: return
        closeUndoWindow()
        scope.launch { commitInIo(slotKey) }
    }

    /** Clears [slotKey] in the recycle area on io. */
    private suspend fun commitInIo(slotKey: String) {
        onStore { store.commitDiscard(slotKey) }
    }

    /** Closes the undo window. */
    private fun closeUndoWindow() {
        undoTimer?.cancel()
        undoTimer = null
        undoKey = null
    }

    /**
     * Tapping "Undo" in the undo window: the recording is moved back into the slot on [io], then returns to Interrupted. Returns false if another session flow is already underway or the undo window has already committed.
     * If the undone slot is not the currently bound one (we switched away after discarding): the recording is only moved back, the current session's state is left alone, and [bind] shows Interrupted when we switch back.
     */
    override fun undoDiscard(slotKey: String): Boolean {
        val current = slotKey == boundKey
        if (current) {
            when (_state.value) {
                DictationState.Idle, DictationState.Denied -> Unit
                else -> return false
            }
            if (job?.isActive == true) return false
        }
        // The recycle area keeps this slot only while the undo window is open: once the window has committed it can no longer be undone.
        if (undoKey != slotKey) return false
        // Close the window first (the timed commit no longer races the restore for the same slot); the restore runs on io, and if it cannot be restored it is wrapped up as a commit.
        closeUndoWindow()
        val undo = scope.launch {
            val restored = onStore {
                store.undoDiscard(slotKey).also { restored ->
                    if (restored) store.markInterrupted(slotKey) else store.commitDiscard(slotKey)
                }
            }
            if (!restored) return@launch
            if (current && boundKey == slotKey && _state.value == DictationState.Idle) {
                setState(DictationState.Interrupted(slotKey))
            }
        }
        if (current) {
            job = undo
            storeJob = undo
        }
        return true
    }

    /** The undo window ended: clears this slot in the recycle area on io. */
    fun commitDiscard(slotKey: String) {
        if (undoKey == slotKey) closeUndoWindow()
        scope.launch { commitInIo(slotKey) }
    }

    /** Transcribes the audio of [slotKey] with the selected engine and wraps up per [submit]; a saved recording may be transcribed here too. */
    private suspend fun transcribe(
        slotKey: String,
        submit: DictationSubmit,
        meta: RecordingSlotMeta,
    ) {
        val segment = STTSegment(
            aac = store.audioFile(slotKey),
            primingFrames = meta.primingFrames,
            envelope = meta.envelope,
        )
        // No selected engine after a slot switch / cold start: use the same cloud resolution as starting a recording (fall back with a one-time notice and reset to system; if the catalog cannot be fetched, use the system this time without changing or notifying).
        val selected = engine ?: run {
            val resolved = resolveCloud(slotKey)
            _engineInfo.value = resolved?.info ?: DictationEngineInfo.System
            engineCloud = resolved != null
            (resolved?.engine ?: engines.system()).also { engine = it }
        }
        val cloud = engineCloud
        when (val result = selected.transcribe(segment, environment.recognitionLanguage())) {
            is STTResult.Success -> {
                // ✕ discarded / switched away while transcribing: the engine may swallow the cancellation and return a result as usual, and a late result is never applied (no insert, no recording deleted, no Failed written).
                currentCoroutineContext().ensureActive()
                // The pre-check already judged there was voice, so empty text does not delete the recording and leaves it for a retry.
                if (DictationRules.trim(result.text).isEmpty()) {
                    fail(slotKey, DictationFailedAction.NoTranscript)
                    return
                }
                // Deleting the recording and emitting the event are non-cancellable: if a switch / host leave cancelled after the delete, the text would be lost.
                withContext(NonCancellable) {
                    if (boundKey != slotKey) {
                        // The host left this slot: there is no receiver, so nothing is inserted / sent and the recording is not deleted; it is left for when the host returns.
                        // If the host moved to another slot, the state belongs to the new slot and is not overwritten.
                        onStore { runCatching { store.markInterrupted(slotKey) } }
                        if (boundKey == null) setState(DictationState.Interrupted(slotKey))
                        return@withContext
                    }
                    onStore { store.complete(slotKey) }
                    // The host left while the recording was being deleted: the recording is already gone, the text is still sent (the event stays in the channel), and the state returns to Idle.
                    setState(DictationState.Idle)
                    _events.trySend(
                        when (submit) {
                            DictationSubmit.Insert -> DictationEvent.Insert(slotKey, result.text)
                            DictationSubmit.Send -> DictationEvent.Send(slotKey, result.text)
                        },
                    )
                }
            }
            is STTResult.Failed -> {
                fail(slotKey, failedAction(result.primaryAction))
                // The system route cannot transcribe a file (when a failed cloud engine fell back to the system): the recording is still kept for a retry, and a separate notice says the system engine is unavailable.
                if (!cloud && result.failure == DictationFailure.Recognizer(SystemSTTEngine.FILE_UNSUPPORTED_ERROR)) {
                    _events.trySend(DictationEvent.SystemUnavailable(slotKey))
                }
            }
        }
    }

    /** The sidecar is unreadable (disk full / deleted): without duration and envelope it cannot be transcribed, so it is cleared as orphan audio (not counted as lost) and the state returns to Idle, not Failed. */
    private suspend fun dropUnreadableSlot(slotKey: String) {
        onStore { store.complete(slotKey) }
        setState(DictationState.Idle)
    }

    /**
     * Failure does not delete the recording: the sidecar is marked failed (the state enters Failed even if the write fails), and the state carries where the primary button goes.
     */
    private suspend fun fail(
        slotKey: String,
        action: DictationFailedAction,
    ) {
        onStore { runCatching { store.updateStatus(slotKey, RecordingSlotStatus.Failed) } }
        setState(DictationState.Failed(slotKey, action))
    }

    private fun releaseInterruptions() {
        interruptions?.close()
        interruptions = null
    }

    /** The choice made before recording: the file branch carries the engine and the engine id written into the sidecar; the file-less branch carries the self-recording route. */
    private sealed interface EngineSelection {
        val info: DictationEngineInfo

        /** [engineId] is `system` or `<providerKind>/<model>`. */
        data class WithFile(
            val engine: STTEngine,
            val engineId: String,
            override val info: DictationEngineInfo = DictationEngineInfo.System,
        ) : EngineSelection

        data class SelfRecord(val route: SystemSTTRoute.SelfRecord) : EngineSelection {
            override val info: DictationEngineInfo get() = DictationEngineInfo.System
        }
    }

    private sealed interface OpenResult {
        data class Opened(val slot: RecordingSlot) : OpenResult
        data object Occupied : OpenResult
        data object Unavailable : OpenResult
    }

    /**
     * Picks the engine before recording: if the stored choice is system, the system is used directly; a cloud choice first cold-reads the catalog cache and only fetches if there is none,
     * and if the fetch fails (failure / 404) the system is used this time without changing the setting or notifying; when resolution falls back, the setting is reset to system and one [DictationEvent.EngineFallback] is emitted;
     * a fallback first noticed on the settings page is emitted once here; if resolution reaches the cloud but disclosure was not accepted, the system is used this time without rewriting or notifying.
     * If it lands on the system engine but the system route is unavailable, [DictationEvent.SystemUnavailable] is emitted, the state returns to Idle, and null is returned; when the route is self-recording, the file-less branch runs.
     */
    private suspend fun selectEngine(slotKey: String): EngineSelection? {
        val cloud = resolveCloud(slotKey)
        if (cloud != null) return cloud
        return when (val route = engines.systemRoute(environment.recognitionLanguage())) {
            SystemSTTRoute.Unavailable -> {
                setState(DictationState.Idle)
                _events.trySend(DictationEvent.SystemUnavailable(slotKey))
                null
            }
            is SystemSTTRoute.SelfRecord -> EngineSelection.SelfRecord(route)
            is SystemSTTRoute.Pipe -> EngineSelection.WithFile(engines.system(), SystemSTTEngine.ENGINE_NAME)
        }
    }

    private fun noticeFallback(slotKey: String, resolution: VoiceEngineResolution?) {
        val reason = settings.applyResolution(VoiceDirection.Stt, resolution, VoiceNoticeSite.Use) ?: return
        _events.trySend(DictationEvent.EngineFallback(slotKey, reason))
    }

    /** Returns the cloud engine when the cloud is usable, and null otherwise (including fallback). */
    private suspend fun resolveCloud(slotKey: String): EngineSelection.WithFile? {
        val selection = settings.selection(VoiceDirection.Stt) as? VoiceEngineSelection.Cloud
        if (selection == null) {
            // The stored choice is system: a fallback first noticed on the settings page is notified once here.
            noticeFallback(slotKey, VoiceEngineResolution(VoiceEngine.System))
            return null
        }
        // Cache read + cold fetch share one overall time limit (the cache read and the refresh share the catalog lock, so a read also waits when a refresh elsewhere is stuck):
        // a timeout is handled as a fetch failure, so the start flow never hangs and later microphone taps are not silently dropped.
        val voiceCatalog = withTimeoutOrNull(catalogRefreshTimeoutMillis) {
            catalog.loadCached() ?: (catalog.refresh() as? VoiceCatalogState.Available)?.catalog
        }
        if (voiceCatalog == null) {
            noticeFallback(slotKey, null)
            return null
        }
        val connections = providers()
        val resolution = VoiceEngineResolver.resolve(
            catalog = voiceCatalog,
            direction = VoiceDirection.Stt,
            selection = selection,
            connections = connections.map(VoiceConnection::from),
        )
        noticeFallback(slotKey, resolution)
        val resolved = resolution.engine as? VoiceEngine.Cloud ?: return null
        // Resolved to the cloud but disclosure for this (providerKind, stt) was not accepted: use the system this time, without rewriting or notifying.
        if (!disclosure.isAccepted(resolved.providerKind, VoiceDirection.Stt)) return null
        val provider = connections.first { it.id == resolved.connectionId }
        val entry = voiceCatalog.entry(resolved.providerKind, VoiceDirection.Stt, resolved.model) as VoiceSttEntry
        val cloud = engines.cloud(
            entry = entry,
            baseUrl = EndpointResolver.resolveBaseUrl(provider),
            apiKey = ProviderCredentialResolver.apiKey(provider, null),
        )
        return EngineSelection.WithFile(
            engine = cloud,
            engineId = "${resolved.providerKind.rawValue}/${resolved.model}",
            info = DictationEngineInfo(displayName = provider.displayName, providerId = provider.id, isCloud = true),
        )
    }

    private suspend fun openAndCapture(
        slotKey: String,
        selected: EngineSelection.WithFile,
        events: AudioCaptureEvents,
    ): OpenResult {
        val opened = try {
            store.open(slotKey, selected.engineId, encoderFactory())
        } catch (_: RecordingSlotOccupiedException) {
            return OpenResult.Occupied
        } catch (_: Exception) {
            // The encoder could not be created / writing the sidecar failed: store.open already removed the half-open file, so treat it as capture being unable to start.
            return OpenResult.Unavailable
        }
        try {
            // Right after a session closes, its AudioRecord is still being released on io: wait until it lets go of the microphone before opening (suspends, does not occupy the main thread); a timeout is treated as capture being unable to start.
            if (!awaitCaptureTeardowns()) throw CaptureTeardownTimeoutException()
            capture.start(listOf(opened, meter), events)
        } catch (_: Exception) {
            // Capture did not start, so no slot is left behind: close the file, then delete the sidecar together with the audio.
            closeSlot(opened, RecordingSlotStatus.Failed)
            runCatching { store.complete(slotKey) }
            return OpenResult.Unavailable
        }
        return OpenResult.Opened(opened)
    }

    /** Closes the file and finalizes the sidecar; does not throw on error and returns false (the part already written stays in the slot). */
    private fun closeSlot(current: RecordingSlot, status: RecordingSlotStatus): Boolean =
        try {
            current.finish(status)
            true
        } catch (_: Exception) {
            false
        }

    /**
     * Report of a capture error mid-way / the capture being muted by the system: dispatched back to the main thread and wrapped up via [interrupt], with the part already written left in the slot.
     * It only honors the recording it belongs to ([target]); reports arriving after wrap-up are ignored.
     */
    private inner class CaptureRelay : AudioCaptureEvents {
        /** The slot it belongs to: installed on the main thread once opening completes; a report earlier than that only records [reported], and [begin] does the wrap-up afterwards. */
        var target: RecordingSlot? = null

        @Volatile
        var reported = false

        override fun onFailure(error: Throwable) = report()

        override fun onInterrupted() = report()

        private fun report() {
            reported = true
            scope.launch {
                // Main.immediate runs in place on the main thread: yield once and wrap up after the callback returns (calling stop synchronously inside the callback would deadlock).
                yield()
                val owned = target ?: return@launch
                if (slot === owned) interrupt()
            }
        }
    }

    private fun failedAction(action: DictationPrimaryAction): DictationFailedAction = when (action) {
        DictationPrimaryAction.Retry -> DictationFailedAction.Retry
        DictationPrimaryAction.CheckConnection -> DictationFailedAction.CheckConnection
    }

    companion object {
        /** Undo window of 4 s, opened only for discards longer than 5 s. */
        const val UNDO_WINDOW_MILLIS = 4_000L

        /** Overall time limit of 10 s for the cold catalog fetch before recording; a timeout is handled as a fetch failure. */
        const val CATALOG_REFRESH_TIMEOUT_MILLIS = 10_000L

        /** Slot-store directories already swept in this process. */
        private val sweptRoots = mutableSetOf<String>()
    }
}
