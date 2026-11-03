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

/**
 * Card shown after a failed dictation: retry, check the connection, or no text was transcribed; system recognizer failures are further classified by the shared code table into network, recognizer busy, language not supported, or no recognition service
 * (anything else in and out of the table stays [Retry]).
 */
enum class DictationFailedAction {
    Retry,
    CheckConnection,
    NoTranscript,
    Network,
    Busy,
    LanguageUnsupported,
    NoService,
}

/** Dictation state; same name as on iOS. */
sealed interface DictationState {
    data object Idle : DictationState

    /** Microphone permission was denied. */
    data object Denied : DictationState

    /** [startedAt] is taken from the injected clock; the UI shows the elapsed recording time from it. */
    data class Recording(val slotKey: String, val startedAt: Long) : DictationState

    data class Transcribing(val slotKey: String, val submit: DictationSubmit) : DictationState

    data class Interrupted(val slotKey: String) : DictationState

    /**
     * [language] is the language tag used for this recognition (set on transcription failure, for the card copy; for cloud auto it is the UI language tag at the moment of failure); null for other failures.
     * [hasRecording] false means the slot holds no recording (self-recorded recognizer failure): it cannot be retried and the card's primary action is to dictate again.
     */
    data class Failed(
        val slotKey: String,
        val action: DictationFailedAction,
        val language: String? = null,
        val hasRecording: Boolean = true,
    ) : DictationState

    /** The same slot still holds an unfinished recording from last time, so a new recording cannot start. */
    data class SlotOccupied(val slotKey: String) : DictationState
}

/** How the recording ends: "to text" inserts into the input box, "up arrow" transcribes and sends directly. */
enum class DictationSubmit {
    Insert,
    Send,
}

/** One-off events, consumed by the UI (insert text, send, show a prompt). */
sealed interface DictationEvent {
    data class Insert(val slotKey: String, val text: String) : DictationEvent

    data class Send(val slotKey: String, val text: String) : DictationEvent

    /** Pre-check heard no speech (too short or no voice): the recording is deleted and nothing was uploaded. */
    data class NoSpeech(val slotKey: String) : DictationEvent

    /** Microphone capture could not start (in use, device unsupported): no slot was kept. */
    data class RecordingUnavailable(val slotKey: String) : DictationEvent

    /**
     * ✕ discarded a recording longer than 5 seconds: it went to the recycle area and the UI shows an undo window.
     * [DictationController.UNDO_WINDOW_MILLIS] commits it when it expires; a new discard commits the previous one immediately, and only one is open at a time.
     */
    data class DiscardUndoable(val slotKey: String) : DictationEvent

    /** The saved cloud choice is no longer valid (connection deleted / key cleared / entry withdrawn): the system engine is used this time and the setting is changed back to system; reported once. */
    data class EngineFallback(val slotKey: String, val reason: VoiceFallbackReason) : DictationEvent

    /** No system speech recognition is available on the device: recording did not start and no slot was kept. */
    data class SystemUnavailable(val slotKey: String) : DictationEvent

    /**
     * Retracts the live text on screen: when ✕ is tapped while recording or transcribing, or the result is no recognized speech / failed; it is sent before the result event or the failure card,
     * and the host uses it to remove the live span (restoring the original text). Not sent if live text never appeared.
     */
    data class LiveRetract(val slotKey: String) : DictationEvent

    /**
     * The on-device language pack for this recognition language is downloadable and the system default recognition is used this time: shown once per language tag, does not block this dictation;
     * when the user accepts, the host calls [DictationCommands.downloadLanguagePack].
     */
    data class LanguagePackOffer(val language: String) : DictationEvent
}

/**
 * One live session route for dictation while recording (production wraps [SystemSTTPipeSession]): attached as a [PcmSink] to capture;
 * after recording stops, [stop] is called and then [await] fetches the result (the implementation has its own wait limit after stopping); [live] emits text as the user speaks.
 */
interface DictationLiveSession : PcmSink {
    val live: StateFlow<LiveTranscript>

    fun stop()

    suspend fun await(): STTResult

    /** Result no longer wanted (✕ / interrupted / switched away / recording start voided): close the recognizer immediately; no-op if a result already exists. */
    fun cancel()

    /**
     * Feeds PCM cached before readiness: may block until the session makes room (no chunks dropped), not called on the recording thread; returns false if the session is stopped / ended and no longer accepts.
     * Defaults to [onPcm].
     */
    fun onBacklogPcm(samples: ShortArray, count: Int): Boolean {
        onPcm(samples, count)
        return true
    }
}

/** Production live session: system recognition pipe session. */
private class PipeDictationLiveSession(private val session: SystemSTTPipeSession) :
    DictationLiveSession,
    PcmSink by session {
    override val live: StateFlow<LiveTranscript> get() = session.live

    override fun stop() = session.stop()

    override suspend fun await(): STTResult = session.await()

    override fun cancel() = session.end(STTResult.Success(""))

    override fun onBacklogPcm(samples: ShortArray, count: Int): Boolean {
        val bytes = ByteArray(count * 2)
        for (index in 0 until count) {
            val sample = samples[index].toInt()
            bytes[index * 2] = sample.toByte()
            bytes[index * 2 + 1] = (sample shr 8).toByte()
        }
        return session.offerFilePcm(bytes)
    }
}

/**
 * Pre-roll before the live session is ready: PCM on the recording thread is buffered first (capped at [maxSamples], the oldest dropped when exceeded);
 * when [attach] becomes ready the buffer is fed to the session in one go, then later frames are forwarded directly; after [close] the buffer is dropped and nothing is accepted or forwarded.
 */
internal class DictationLivePreroll(private val maxSamples: Int = PREROLL_SAMPLES) : PcmSink {
    private val lock = Any()

    // The state below is guarded by lock.
    private val chunks = ArrayDeque<ShortArray>()
    private var buffered = 0
    private var target: DictationLiveSession? = null
    private var closed = false

    /** Called on the recording thread: buffers while not ready, forwards to the session once ready. */
    override fun onPcm(samples: ShortArray, count: Int) {
        if (count <= 0) return
        val forward = synchronized(lock) {
            if (closed) return
            target ?: run {
                chunks.addLast(samples.copyOf(count))
                buffered += count
                while (buffered > maxSamples && chunks.size > 1) buffered -= chunks.removeFirst().size
                return
            }
        }
        forward.onPcm(samples, count)
    }

    /**
     * Feeds the buffer in order first (frames arriving during the feed keep going into the buffer); when the buffer is empty it switches to direct forwarding, so the bytes stay continuous without loss.
     * May block; not called on the main or recording thread; returns false if already [close]d or the session no longer accepts.
     */
    fun attach(live: DictationLiveSession): Boolean {
        while (true) {
            val chunk = synchronized(lock) {
                if (closed) return false
                val next = chunks.removeFirstOrNull()
                if (next == null) {
                    target = live
                    return true
                }
                buffered -= next.size
                next
            }
            if (!live.onBacklogPcm(chunk, chunk.size)) {
                close()
                return false
            }
        }
    }

    fun close() {
        synchronized(lock) {
            closed = true
            target = null
            chunks.clear()
            buffered = 0
        }
    }

    companion object {
        /** 10 s of 16 kHz mono samples. */
        const val PREROLL_SAMPLES = AudioRecordCapture.SAMPLE_RATE * 10
    }
}

/** Default for [DictationCommands.livePartial]: no live text. */
private val NO_LIVE_PARTIAL: StateFlow<LiveTranscript?> = MutableStateFlow<LiveTranscript?>(null).asStateFlow()

/**
 * Engine info shown in the recording UI: for cloud, the selected connection's [Provider.displayName] and [Provider.id];
 * both are null for the system engine.
 */
data class DictationEngineInfo(val displayName: String?, val providerId: String?, val isCloud: Boolean) {
    companion object {
        val System = DictationEngineInfo(displayName = null, providerId = null, isCloud = false)
    }
}

/** Dictation engine factory: production uses [DefaultDictationEngineFactory]; tests inject fake engines. */
interface DictationEngineFactory {
    fun system(): STTEngine

    /** System recognition route selection; no recording starts when [SystemSTTRoute.Unavailable]. */
    suspend fun systemRoute(language: String?): SystemSTTRoute

    /** System route decidable without suspending (unavailable, self-record, cache hit); returns null when undecidable, in which case [systemRoute] runs after recording starts. Defaults to null. */
    fun cachedSystemRoute(language: String?): SystemSTTRoute? = null

    /** Opens one self-recording recognition session (the recognizer opens the mic itself and produces no recording file); throws if listening fails to start. */
    suspend fun startSelfRecord(route: SystemSTTRoute.SelfRecord): SystemSTTSelfRecordSession

    /** One turn of a self-recording in a voice conversation: the recognizer decides when the user has finished speaking (turns are not accumulated). Defaults to [startSelfRecord]. */
    suspend fun startSelfRecordTurn(route: SystemSTTRoute.SelfRecord): SystemSTTSelfRecordSession =
        startSelfRecord(route)

    /**
     * Opens a live session on the pipe route (recognize while recording); throws if listening fails to start. Defaults to null = no live recognition, only recording-then-transcription.
     */
    suspend fun startPipeSession(route: SystemSTTRoute.Pipe): DictationLiveSession? = null

    /** The user accepts the language-pack guidance: triggers the on-device recognizer to download [language]; returns true if downloadable. Defaults to no download. */
    suspend fun downloadLanguagePack(language: String): Boolean = false

    /** [baseUrl] is the connection address (only the origin is used, then [entry]'s path is appended). */
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

    override fun cachedSystemRoute(language: String?): SystemSTTRoute? = router.cachedRoute(language)

    override suspend fun startSelfRecord(route: SystemSTTRoute.SelfRecord): SystemSTTSelfRecordSession =
        systemEngine.startSelfRecordSession(route)

    override suspend fun startSelfRecordTurn(route: SystemSTTRoute.SelfRecord): SystemSTTSelfRecordSession =
        systemEngine.startSelfRecordSession(route, singleRound = true)

    override suspend fun startPipeSession(route: SystemSTTRoute.Pipe): DictationLiveSession =
        PipeDictationLiveSession(systemEngine.startPipeSession(route))

    override suspend fun downloadLanguagePack(language: String): Boolean = router.downloadLanguagePack(language)

    override fun cloud(entry: VoiceSttEntry, baseUrl: String, apiKey: String): STTEngine =
        CloudSTTEngine(httpClient, entry, baseUrl, apiKey, cloudCacheDir)
}

/** Source of the voice catalog: production uses [VoiceCatalogClient.asDictationCatalogSource]. */
interface DictationCatalogSource {
    suspend fun loadCached(): VoiceCatalog?

    suspend fun refresh(): VoiceCatalogState
}

fun VoiceCatalogClient.asDictationCatalogSource(): DictationCatalogSource = object : DictationCatalogSource {
    override suspend fun loadCached(): VoiceCatalog? = this@asDictationCatalogSource.loadCached()

    override suspend fun refresh(): VoiceCatalogState = this@asDictationCatalogSource.refresh()
}

/** Microphone permission: returns true at once if granted, otherwise shows the system prompt and suspends until the user chooses. */
fun interface MicrophonePermission {
    suspend fun request(): Boolean
}

/** Platform side effects of a dictation session. */
interface DictationEnvironment {
    /** Stops any ongoing read-aloud before dictation starts. */
    fun stopReadAloud()

    /** Recognition language saved in settings (e.g. zh-Hans); null = auto: cloud requests send no language (contract dictation.v1 rules.request). */
    fun recognitionLanguage(): String?

    /** App UI language tag: the system engine and system routing use it when auto. */
    fun uiLanguageTag(): String

    /**
     * Listens for interruptions while recording; closing the returned value unregisters it. Called on the main thread; [onInterrupted] is also invoked on the main thread.
     * Production only wires going to background (ProcessLifecycleOwner ON_STOP); other interruption sources such as phone calls are signaled by the implementation separately.
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

/** Fixed host identity used by [DictationCommands.bind] / [DictationCommands.detach] when the host does not pass one. */
data object DefaultDictationOwner

/**
 * Dictation control surface used by the host (input box): state flow and commands. Implemented by [DictationController]; the host coordinator depends only on this interface, to allow pure-JVM tests.
 */
interface DictationCommands {
    val state: StateFlow<DictationState>
    val engineInfo: StateFlow<DictationEngineInfo?>
    val pendingDurationSec: StateFlow<Double?>
    val levelMeter: StateFlow<List<Float>>

    /** Current host identity: set by [bind], cleared (null) when [detach] takes effect. */
    val boundOwner: StateFlow<Any?>

    /** Live text the system engine emits while speaking: non-null while recording (and while waiting for the live result after stopping), null after wrap-up; always null for cloud. */
    val livePartial: StateFlow<LiveTranscript?> get() = NO_LIVE_PARTIAL

    fun start(slotKey: String)

    fun finish(submit: DictationSubmit)

    fun discard()

    fun transcribeSaved(submit: DictationSubmit)

    fun discardAndRestart()

    fun dismissDenied()

    fun undoDiscard(slotKey: String): Boolean

    fun bind(slotKey: String, owner: Any = DefaultDictationOwner)

    fun detach(slotKey: String, owner: Any = DefaultDictationOwner)

    /** The user accepts the language-pack guidance ([DictationEvent.LanguagePackOffer]): downloads the on-device language pack for that language. Defaults to doing nothing. */
    fun downloadLanguagePack(language: String) = Unit
}

/**
 * Main dictation flow: permission -> choose engine -> record (into a [RecordingStore] slot) -> pre-check -> transcribe -> result event.
 * Only one session at a time; public methods are called on the main thread, and disk and capture operations run serially on [io] in submission order via [onStore].
 * The engine is chosen before recording starts from settings + catalog + connection ([providers] in the connection order from settings); transcription and retries of this recording use it;
 * [bind] clears it after switching slots, and kept recordings re-resolve against the current settings when transcribed.
 *
 * When the UI switches session / on cold start it calls [bind] with the slot key: if recording, the original slot is wrapped up as Interrupted before switching;
 * a new slot still holding a previous recording (interrupted / failed / transcription killed) shows Interrupted.
 * A controller has one host: the last bound slot receives events (same as iOS); when the host leaves it calls [detach], and an ongoing recording / transcription is wrapped up as interrupted.
 * When transcription succeeds the host is no longer on that slot: nothing is inserted or sent and the recording is not deleted; it stays Interrupted until the host returns.
 *
 * When the system route is self-record ([SystemSTTRoute.SelfRecord]) the no-file branch is used: the recognizer opens the mic itself, no slot is created and [capture] is not opened,
 * no loss is counted (an exception); there is no recording to retry, so nothing goes to Interrupted / Failed; interruption or error wraps up with the recognized text and returns to Idle.
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
    /** Waits for an ongoing voice / live session capture stop to finish (a process-wide gate); returns false on timeout: never coexists with an AudioRecord still being released. */
    private val awaitCaptureTeardowns: suspend () -> Boolean = { CaptureTeardownGate.Shared.awaitTeardowns() },
    /**
     * Registers a dictation capture stop on the same gate (registers only, does not block) and returns an idempotent "stop done": before a session or live capture starts, they wait for it,
     * so it never coexists with a dictation AudioRecord still stopping.
     */
    private val beginCaptureTeardown: () -> () -> Unit = { CaptureTeardownGate.Shared.beginTeardown() },
) : DictationCommands {
    /** Serial lock for slot store reads/writes: undo-restore, binding reads, discards and so on queue in order and never interleave on two io threads. */
    private val storeLock = Mutex()

    private val _state = MutableStateFlow<DictationState>(DictationState.Idle)
    override val state: StateFlow<DictationState> = _state.asStateFlow()

    private val _engineInfo = MutableStateFlow<DictationEngineInfo?>(null)

    /** Engine chosen for this recording (decided when recording starts or when a kept recording is transcribed); cleared on return to Idle. */
    override val engineInfo: StateFlow<DictationEngineInfo?> = _engineInfo.asStateFlow()

    private val _pendingDurationSec = MutableStateFlow<Double?>(null)

    /** Slot key for [_pendingDurationSec] and the in-flight sidecar read. */
    private var pendingDurationKey: String? = null
    private var pendingDurationJob: Job? = null

    /** Recording duration from the slot sidecar in Interrupted / SlotOccupied / Failed (null if unreadable); null in other states. */
    override val pendingDurationSec: StateFlow<Double?> = _pendingDurationSec.asStateFlow()

    private val meter = DictationLevelMeter(clock)

    /** Recent volume while recording (at most 24, oldest first, 0..1) for the waveform; cleared on leaving Recording, and kept empty when the self-recognizer has no PCM. */
    override val levelMeter: StateFlow<List<Float>> = meter.levels

    private val _events = Channel<DictationEvent>(Channel.BUFFERED)
    val events: Flow<DictationEvent> = _events.receiveAsFlow()

    private var slot: RecordingSlot? = null
    private var job: Job? = null
    private var interruptions: AutoCloseable? = null

    /** Engine chosen for this recording; chosen before recording starts and reused for transcription and retries. */
    private var engine: STTEngine? = null

    /** Whether [engine] is cloud; decided together with [engine]. */
    private var engineCloud = false

    /** Self-record branch start time (the recording duration reported is from start to wrap-up). */
    private var selfRecordStartedAt = 0L

    /** The in-flight self-recording session on the no-file branch; cleared on wrap-up (including discard and interruption), and late results are ignored by it. */
    private var selfRecord: SystemSTTSelfRecordSession? = null

    /** Coroutine waiting for the self-recording session result: wrap-up after the user stops or on a recognizer error during recording. */
    private var selfRecordWatch: Job? = null

    /** The live session for this recording on the pipe route: non-null while recording and while waiting for the live result after stopping; closed and cleared on wrap-up (including discard, interruption and switching away). */
    private var liveSession: DictationLiveSession? = null

    private val _livePartial = MutableStateFlow<LiveTranscript?>(null)
    override val livePartial: StateFlow<LiveTranscript?> = _livePartial.asStateFlow()

    /** Coroutine that picks the route in the background and opens the live session after recording starts; cleared when ready (or abandoned). */
    private var liveStart: Job? = null

    /** Pre-roll of the opening PCM cached before [liveStart] is ready; cleared when ready or abandoned. */
    private var pendingPreroll: DictationLivePreroll? = null

    /** Coroutine forwarding live text from the live session (pipe or self-record) to [_livePartial]. */
    private var liveCollector: Job? = null

    /** This recording's live text was ever non-empty: on wrap-up as no speech / failed, or on ✕, [DictationEvent.LiveRetract] is sent based on this. */
    private var liveShown = false

    /** Slot key currently shown by the host UI; set by [bind] or [start], cleared by [detach]. */
    private var boundKey: String? = null

    private val _boundOwner = MutableStateFlow<Any?>(null)

    /** Host identity bound to [boundKey]: when the same key is bound by another host the owner changes, and the old owner's [detach] no longer takes effect. */
    override val boundOwner: StateFlow<Any?> = _boundOwner.asStateFlow()

    /** Coroutine of the start flow (permission -> engine -> open slot); cancelled when switching sessions. */
    private var startJob: Job? = null

    /** The sweep + slot read coroutine started by [bind]; while it runs, [start] waits for it to finish before handling by the state then, and does not treat it as a session in progress. */
    private var bindJob: Job? = null

    /** The discard / undo wrap-up coroutine of the current slot; while it runs, [start] likewise waits for it to finish before handling by the state then (same as iOS). */
    private var storeJob: Job? = null

    /** The open undo window: slot key waiting to be committed in the recycle area and the timer for committing on expiry; only one is open at a time. */
    private var undoKey: String? = null
    private var undoTimer: Job? = null


    /**
     * Binds the slot key the UI currently shows (switching sessions, entering a session after cold start); [owner] is recorded as the current host.
     * The same key only swaps the owner (the home page and a new chat without a session share one key: when the new page binds first and the old page detaches later, the binding is not cleared).
     * A recording on the original slot is first wrapped up as interrupted (the no-file branch inserts the recognized text); a transcription in flight is cancelled and the sidecar is set to interrupted;
     * if the start flow has not yet opened a slot, it is cancelled. The undo window is unaffected and commits on expiry as usual.
     * A new slot holding a kept recording (interrupted / failed / transcription killed mid-way) shows Interrupted, otherwise Idle.
     * Switching slots clears the selected engine: a kept recording re-resolves against the settings at that time when transcribed (same as iOS bind).
     * The slot store is swept once before the first bind in this process (expired, lost count, crash recovery); see [sweepOnceBeforeFirstBind].
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
     * Sample (DEBUG only): displays [state] directly, without starting the engine, requesting recording or opening a slot; states with a slot key also set it as the current host key,
     * so a host that binds the same key afterwards only swaps the owner and does not clear the state here. Level is fixed at [levels] while recording; engine info is [engineInfo] when not Idle.
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

    /** The only entry point for changing state: clears the engine info when returning to Idle; clears the level on leaving Recording; reads the sidecar duration for kept-recording states. */
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
        // The sidecar is read on io and published back on the main thread; for the same key the old value is kept until the read finishes, and cleared when the key changes or on leaving the state. A new state cancels the previous read.
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
     * Runs a slot store / capture operation on [io], serialized with other such operations (first come, first served); with [nonCancellable], both queuing and execution are non-cancellable.
     * Does not use io.limitedParallelism(1): the Unconfined dispatcher injected by tests does not support deriving a restricted view.
     */
    /**
     * Stops capture (on io: joins the capture thread and releases the AudioRecord); once stopped, releases the [stopped] registered on the gate (also released if stopping errors).
     * The caller calls [stopped] once more when its coroutine wraps up as a safety net: if this was never reached (cancelled), the gate is not held forever.
     */
    private fun stopCapture(stopped: (() -> Unit)?) {
        try {
            capture.stop()
        } finally {
            stopped?.invoke()
        }
    }

    private suspend fun <T> onStore(nonCancellable: Boolean = false, block: suspend CoroutineScope.() -> T): T =
        if (nonCancellable) {
            withContext(NonCancellable) { storeLock.withLock { withContext(io, block) } }
        } else {
            storeLock.withLock { withContext(io, block) }
        }

    /** Starts forwarding [live] to [livePartial] (clears the text first; non-null while recording). */
    private fun followLive(live: StateFlow<LiveTranscript>) {
        liveCollector?.cancel()
        liveShown = false
        _livePartial.value = LiveTranscript()
        liveCollector = scope.launch {
            live.collect { transcript ->
                if (LiveDictationRules.livePartial(transcript.finals, transcript.partial).text.isNotEmpty()) liveShown = true
                _livePartial.value = transcript
            }
        }
    }

    /** Stops forwarding live text; [livePartial] set to null. */
    private fun stopFollowingLive() {
        liveCollector?.cancel()
        liveCollector = null
        _livePartial.value = null
    }

    /** Early wrap-up (interrupt / discard / switch away): closes the pipe live session and stops forwarding; does not retract (call [retractLive] first if retracting). */
    private fun abandonLive() {
        cancelPendingLive()
        liveSession?.cancel()
        liveSession = null
        liveShown = false
        stopFollowingLive()
    }

    /** If live text ever appeared on screen, sends [DictationEvent.LiveRetract] once (not again afterwards). */
    private fun retractLive(slotKey: String) {
        if (!liveShown) return
        liveShown = false
        _events.trySend(DictationEvent.LiveRetract(slotKey))
    }

    /** Dismisses the microphone-denied prompt card: returns to Idle only in Denied; other states are ignored. */
    override fun dismissDenied() {
        if (_state.value == DictationState.Denied) setState(DictationState.Idle)
    }

    /** The same slot store directory is swept only once per process: sweeping happens only after the original slot has been wrapped up as interrupted, so this process's own recording is never mistaken for crash recovery. */
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
        // The start flow is cancelled directly; discard, slot reads and other wrap-up tasks are waited on.
        if (inFlight === startJob) inFlight.cancel()
        return inFlight
    }

    /**
     * Wraps up while transcribing (switching away / host leaving): the no-file branch inserts the recognized text; the file branch cancels the in-flight transcription and sets the sidecar to interrupted once it ends.
     * Returns the task to wait for (null for the no-file branch); the caller sets the state.
     */
    private fun abandonTranscription(slotKey: String): Job? {
        selfRecord?.let { session ->
            // Leaving the no-file branch while waiting for a result: there is no recording to keep, so the recognized text is inserted as an interruption.
            insertInterruptedSelfRecord(slotKey, abandonSelfRecord(session))
            return null
        }
        // The recording is kept and the whole thing will be inserted on later transcription: retract the live text on screen first to avoid duplication.
        retractLive(slotKey)
        abandonLive()
        val inFlight = job?.takeIf { it.isActive }
        inFlight?.cancel()
        return scope.launch {
            inFlight?.join()
            onStore { store.markInterrupted(slotKey) }
        }
    }

    /**
     * Host leaves (UI destroyed / leaving the session): takes effect only if the current slot key is [slotKey] and the host identity is [owner]; clears the host.
     * Wraps up a recording in progress with [interrupt]; cancels an in-flight transcription and leaves the recording as Interrupted (the no-file branch inserts the recognized text and returns to Idle, with the event kept in the channel).
     * Interrupted / Failed / SlotOccupied / Idle are unchanged; the start flow voids itself when it sees the host has left at permission return.
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
     * Tapping the microphone (same as iOS micTapped): stops read-aloud first, then checks the slot; if the same key still holds a recording, goes to SlotOccupied for the user to choose, with no permission and no engine resolution;
     * only when the slot is empty does it request permission, choose the engine, open the slot and start capture. Ignored while a session is in progress.
     * If the same key's binding (first sweep on cold start, slot read) or a discard / undo wrap-up is still running, it does not discard: it stops read-aloud first and waits for those to finish before following the flow above by the state then.
     */
    override fun start(slotKey: String) {
        val active = job?.takeIf { it.isActive }
        if (active != null && (active === bindJob || active === storeJob) && boundKey == slotKey) {
            environment.stopReadAloud()
            job = scope.launch {
                // When the session is cancelled, also wait for the binding to finish: a later bind waits for this task, and the sweep must not still be running.
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
        // When the key is already the current key the host is not changed; when the key changes, the current host is kept (or the default identity if it has left).
        if (boundKey != slotKey) bind(slotKey, _boundOwner.value ?: DefaultDictationOwner)
        val binding = job?.takeIf { it.isActive }
        environment.stopReadAloud()
        job = scope.launch {
            if (askIfOccupied(slotKey)) return@launch
            // The first binding's sweep must finish first, so the slot just opened is not treated as crash recovery.
            binding?.join()
            begin(slotKey)
        }.also { startJob = it }
    }

    /** If the same key still holds a recording, goes to SlotOccupied for the user to choose and returns true; returns false if the slot is empty. */
    private suspend fun askIfOccupied(slotKey: String): Boolean {
        if (!onStore { store.isOccupied(slotKey) }) return false
        // Switching to an occupied key without bind: the engine chosen for the previous recording is not reused; "transcribe first" re-resolves against the current settings.
        engine = null
        _engineInfo.value = null
        setState(DictationState.SlotOccupied(slotKey))
        return true
    }

    /** Permission -> engine -> open slot and start capture; if the host has left the slot when permission returns or before the engine is opened, the start is voided (no slot is created). */
    private suspend fun begin(slotKey: String) {
        // A new dictation: the previous live text has already been wrapped up.
        liveShown = false
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
        // Before the live session is ready, PCM is kept in the pre-roll and fed in one go when it becomes ready.
        val preroll = if (selected.live) DictationLivePreroll() else null
        val relay = CaptureRelay()
        // Slot creation and capture start are not cancellable: when a session switch cancels the start, a slot already opened must be torn down here and not left half-done.
        val opened = onStore(nonCancellable = true) { openAndCapture(slotKey, selected, relay, preroll) }
        if (opened !is OpenResult.Opened || !currentCoroutineContext().isActive) preroll?.close()
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
                // Volume is only collected after entering Recording: a capture torn down midway through starting leaves no value.
                meter.start()
                interruptions = environment.observeInterruptions(::interrupt)
                preroll?.let { prepareLive(it) }
                // Capture already errored / was muted before the slot was installed: that report found no slot, so wrap-up is completed here.
                if (relay.reported) interrupt()
            }
        }
    }

    /**
     * After recording starts, picks the route in the background and opens the live session; when ready it first feeds the opening in [preroll] and then attaches the live frames.
     * If the route is not the pipe (on a cold cache it becomes known to be self-record / unavailable) or listening fails to start, only recording-then-transcription is used this time; the recording itself is unaffected.
     * Finishing / ✕ / interruption before readiness is cancelled by [cancelPendingLive].
     */
    private fun prepareLive(preroll: DictationLivePreroll) {
        pendingPreroll = preroll
        liveStart = scope.launch {
            val route = engines.systemRoute(systemLanguage()) as? SystemSTTRoute.Pipe
            if (route == null) {
                preroll.close()
                return@launch
            }
            offerLanguagePack(route.languagePackOffer, route.languageTag)
            val live = startLive(route)
            if (live == null) {
                preroll.close()
                return@launch
            }
            val attached = try {
                // Feeding may block until the session makes room; not done on the main thread.
                withContext(io) { preroll.attach(live) }
            } catch (error: CancellationException) {
                live.cancel()
                throw error
            }
            if (!attached || !isActive) {
                live.cancel()
                return@launch
            }
            pendingPreroll = null
            liveStart = null
            liveSession = live
            followLive(live.live)
        }
    }

    /** The live session is not ready when wrap-up happens: no longer waited for, and the pre-roll is dropped. */
    private fun cancelPendingLive() {
        liveStart?.cancel()
        liveStart = null
        pendingPreroll?.close()
        pendingPreroll = null
    }

    /** Opens the live session on the pipe route; a failure to start listening does not affect recording, and this time only recording-then-transcription is used. */
    private suspend fun startLive(route: SystemSTTRoute.Pipe): DictationLiveSession? =
        try {
            engines.startPipeSession(route)
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            null
        }

    /** The host is no longer on [slotKey] during recording start: if it left (host empty) returns to Idle; if it switched to another slot, its state is not touched. */
    private fun abandonedByHost(slotKey: String): Boolean {
        if (boundKey == slotKey) return false
        if (boundKey == null) setState(DictationState.Idle)
        return true
    }

    /** No-file-branch recording start: the recognizer opens the mic itself; failure to start listening is handled as capture failing to start. */
    private suspend fun beginSelfRecord(slotKey: String, route: SystemSTTRoute.SelfRecord) {
        engine = null
        offerLanguagePack(route.languagePackOffer, route.languageTag)
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
            // Switched away while listening was starting: the recognizer is shut down and recording is not entered.
            session.interrupt()
            return
        }
        selfRecord = session
        selfRecordStartedAt = clock()
        setState(DictationState.Recording(slotKey, selfRecordStartedAt))
        // No app capture: the recording bar's volume comes from the recognizer's onRmsChanged.
        meter.start()
        session.onLevel = meter::onRecognizerRmsDb
        followLive(session.live)
        interruptions = environment.observeInterruptions(::interrupt)
        selfRecordWatch = scope.launch { concludeSelfRecord(slotKey, session, session.await()) }
    }

    /**
     * Result of a self-recording session: a recognizer permission report first enters the existing microphone-permission card (on-screen text is still inserted, no failure event); otherwise, wrap-up follows
     * [LiveDictationRules.dictationOutcome] (hasRecording=false): the on-screen text (finalized + last unfinalized) is inserted / sent;
     * no recognized speech means NoSpeech, and a failure enters the failure card by failure kind (a timeout counts as busy; with no recording to retry, canRetry=false).
     */
    private fun concludeSelfRecord(slotKey: String, session: SystemSTTSelfRecordSession, result: STTResult) {
        if (selfRecord !== session) return
        selfRecord = null
        selfRecordWatch = null
        releaseInterruptions()
        stopFollowingLive()
        val submit = (_state.value as? DictationState.Transcribing)?.submit ?: DictationSubmit.Insert
        setState(DictationState.Idle)
        val transcript = session.live.value
        if (isPermissionFailure(result)) {
            val shown = LiveDictationRules.livePartial(transcript.finals, transcript.partial).text
            if (shown.isNotEmpty()) {
                deliverSelfRecord(slotKey, DictationSubmit.Insert, shown)
            } else {
                retractLive(slotKey)
            }
            setState(DictationState.Denied)
            return
        }
        val outcome = LiveDictationRules.dictationOutcome(liveSessionResult(result, transcript, hasRecording = false), null)
        when (outcome.result) {
            DictationOutcomeResult.Text ->
                // Failed wrap-up but there is text on screen: inserted as is, no failure event; only a successful wrap-up is sent according to the submit mode.
                deliverSelfRecord(
                    slotKey,
                    if (result is STTResult.Success) submit else DictationSubmit.Insert,
                    checkNotNull(outcome.text),
                )
            DictationOutcomeResult.NoTranscript -> {
                retractLive(slotKey)
                _events.trySend(DictationEvent.NoSpeech(slotKey))
            }
            DictationOutcomeResult.Failed -> {
                retractLive(slotKey)
                // No recording: the failure card does not take a slot, and the primary action is to dictate again.
                setState(
                    DictationState.Failed(
                        slotKey,
                        failedAction(checkNotNull(outcome.failureKind)),
                        systemLanguage(),
                        hasRecording = false,
                    ),
                )
            }
        }
    }

    /** Result of a self-recording lands: records ended, sends insert / send by [submit]. */
    private fun deliverSelfRecord(slotKey: String, submit: DictationSubmit, text: String) {
        _events.trySend(
            when (submit) {
                DictationSubmit.Insert -> DictationEvent.Insert(slotKey, text)
                DictationSubmit.Send -> DictationEvent.Send(slotKey, text)
            },
        )
    }

    /** Recognizer reported permission (code table permission). */
    private fun isPermissionFailure(result: STTResult): Boolean {
        val code = ((result as? STTResult.Failed)?.failure as? DictationFailure.Recognizer)?.code ?: return false
        return SystemFailure.kindOf(SystemFailureInput.Code(code)) == SystemFailureKind.Permission
    }

    /** No-file branch interrupted / host left: if there is recognized text, it is inserted as an interruption; no text means nothing is inserted. */
    private fun insertInterruptedSelfRecord(slotKey: String, recognized: String) {
        if (DictationRules.trim(recognized).isEmpty()) return
        _events.trySend(DictationEvent.Insert(slotKey, recognized))
    }

    /** No-file branch early wrap-up (interrupt / discard): abandons the current turn without waiting for the session result, and returns the recognized text. */
    private fun abandonSelfRecord(session: SystemSTTSelfRecordSession): String {
        selfRecord = null
        selfRecordWatch?.cancel()
        selfRecordWatch = null
        releaseInterruptions()
        stopFollowingLive()
        session.interrupt()
        return session.transcript
    }

    /** Ends recording and transcribes: [submit] decides whether success inserts or sends. Ignored when not recording. */
    override fun finish(submit: DictationSubmit) {
        val recording = _state.value as? DictationState.Recording ?: return
        selfRecord?.let { session ->
            // No-file branch: lets the recognizer end this turn; the result is wrapped up by selfRecordWatch.
            setState(DictationState.Transcribing(recording.slotKey, submit))
            session.stop()
            return
        }
        val current = slot ?: return
        slot = null
        releaseInterruptions()
        val slotKey = recording.slotKey
        // The live session is not ready yet: go straight to recording-then-transcription.
        cancelPendingLive()
        val live = liveSession
        setState(DictationState.Transcribing(slotKey, submit))
        // Capture stop is registered at the moment stop is tapped; live and session capture opened afterwards wait for it to finish stopping.
        val stopped = beginCaptureTeardown()
        job = scope.launch {
            // ✕ during transcription cancels this coroutine: the file is closed and the sidecar finalization is not cancellable, so a discard can judge whether it is undoable by the real duration.
            var closed = true
            val meta = onStore(nonCancellable = true) {
                stopCapture(stopped)
                // Stop the live session after capture stops: the last PCM segment is also sent to the recognizer.
                live?.stop()
                closed = closeSlot(current, RecordingSlotStatus.Ready)
                store.read(slotKey)
            }
            val awaited = live?.let { awaitLive(it) }
            if (awaited != null && isPermissionFailure(awaited.first)) {
                // The live session reported permission: before merging results, enter the existing microphone-permission card with no failure event; on-screen text is retracted, and the recording stays in the slot for a retry.
                retractLive(slotKey)
                if (closed && meta != null) onStore { runCatching { store.updateStatus(slotKey, RecordingSlotStatus.Failed) } }
                setState(DictationState.Denied)
                return@launch
            }
            val liveResult = awaited?.second
            if (liveResult != null && liveResult.ended == LiveEnded.Ok && !liveResult.droppedAudio &&
                DictationRules.join(liveResult.finals).isNotEmpty()
            ) {
                // Live ended normally, the finalized text is non-empty and no audio chunk was dropped: use it directly without recognizing the recording.
                val outcome = LiveDictationRules.dictationOutcome(liveResult, null)
                deliver(slotKey, submit, checkNotNull(outcome.text), meta?.durationSec ?: 0.0)
                return@launch
            }
            // If the recording side cannot produce a result, the live text on screen (finalized + last unfinalized) is kept.
            val shown = liveResult?.let { LiveDictationRules.livePartial(it.finals, it.partial).text }.orEmpty()
            if (!closed) {
                if (shown.isNotEmpty()) {
                    deliver(slotKey, submit, shown, meta?.durationSec ?: 0.0)
                    return@launch
                }
                retractLive(slotKey)
                // File close failed: the partly written data stays in the slot and it enters Failed so the user can retry or discard; it is not cleaned up as a missing sidecar.
                fail(slotKey, DictationFailedAction.Retry)
                return@launch
            }
            if (meta == null) {
                if (shown.isNotEmpty()) {
                    deliver(slotKey, submit, shown, 0.0)
                    return@launch
                }
                retractLive(slotKey)
                // Sidecar missing after finalization (disk full / deleted): the recording can no longer be transcribed, so the orphan audio is cleared and it returns to Idle.
                dropUnreadableSlot(slotKey)
                return@launch
            }
            if (DictationRules.precheck(meta.durationSec, meta.envelope) != DictationPrecheck.Ok) {
                if (shown.isNotEmpty()) {
                    deliver(slotKey, submit, shown, meta.durationSec)
                    return@launch
                }
                retractLive(slotKey)
                onStore { store.complete(slotKey) }
                setState(DictationState.Idle)
                _events.trySend(DictationEvent.NoSpeech(slotKey))
                return@launch
            }
            transcribe(slotKey, submit, meta, live = liveResult)
        }.also {
            it.invokeOnCompletion {
                stopped()
                // Cancelled by ✕ / switching away: the live session is also closed.
                live?.cancel()
            }
        }
    }

    /**
     * Waits for the live session result after stopping (the session has its own limit, plus a further cap of [SystemSTTEngine.STOP_RESULT_TIMEOUT_MS] here);
     * stops forwarding live text, and returns the original result and a [LiveSessionResult] folded with hasRecording=true.
     */
    private suspend fun awaitLive(live: DictationLiveSession): Pair<STTResult, LiveSessionResult> {
        val result = withTimeoutOrNull(SystemSTTEngine.STOP_RESULT_TIMEOUT_MS) { live.await() }
            ?: SystemSTTEngine.TIMEOUT_RESULT
        val transcript = live.live.value
        if (liveSession === live) {
            liveSession = null
            stopFollowingLive()
        }
        live.cancel()
        return result to liveSessionResult(result, transcript, hasRecording = true)
    }

    /** Retry on Failed: transcribes the recording kept in the slot once more; after success it only inserts and does not send directly (even if the original action was "up arrow"). */
    fun retry() {
        if (_state.value !is DictationState.Failed) return
        transcribeSaved(DictationSubmit.Insert)
    }

    /**
     * Transcribes the recording kept in the slot: "Transcribe" / "up arrow" on Interrupted, "transcribe first" on SlotOccupied, or retry on Failed.
     * No pre-check is done (a crash-recovered sidecar has no envelope); envelope and primingFrames come from the sidecar, and if the sidecar is gone it returns to Idle.
     * On success it inserts or sends per [submit] and deletes the slot; on failure it enters Failed and the recording stays. Other states are ignored.
     */
    override fun transcribeSaved(submit: DictationSubmit) {
        val slotKey = when (val state = _state.value) {
            is DictationState.Interrupted -> state.slotKey
            is DictationState.SlotOccupied -> state.slotKey
            // A failure with no recording (self-recording) has nothing to transcribe.
            is DictationState.Failed -> if (state.hasRecording) state.slotKey else return
            else -> return
        }
        if (job?.isActive == true) return
        // A kept recording has no live text to retract.
        liveShown = false
        setState(DictationState.Transcribing(slotKey, submit))
        job = scope.launch {
            val meta = onStore { store.read(slotKey) }
            if (meta == null) {
                dropUnreadableSlot(slotKey)
                return@launch
            }
            // Expired or lost while running (sidecar present, audio missing): cleared like the startup sweep, the slot is removed and each is counted once, returning to Idle.
            val gone = onStore { store.isExpired(meta) || !store.audioFile(slotKey).exists() }
            if (gone) {
                dropUnreadableSlot(slotKey)
                return@launch
            }
            transcribe(slotKey, submit, meta)
        }
    }

    /**
     * "Discard and re-record" on SlotOccupied: deletes the old recording directly (the new recording takes the same slot, so no undo is offered), then starts a new recording.
     * On a Failed with no recording (self-recording failure): closes the card and starts a new dictation at once. Other states are ignored.
     */
    override fun discardAndRestart() {
        val current = _state.value
        if (current is DictationState.Failed && !current.hasRecording) {
            if (job?.isActive == true) return
            setState(DictationState.Idle)
            start(current.slotKey)
            return
        }
        val occupied = current as? DictationState.SlotOccupied ?: return
        if (job?.isActive == true) return
        val slotKey = occupied.slotKey
        setState(DictationState.Idle)
        environment.stopReadAloud()
        job = scope.launch {
            onStore { store.complete(slotKey) }
            begin(slotKey)
        }.also { startJob = it }
    }

    /** Recording interrupted (going to background, phone call, etc.): switches to Interrupted synchronously, stops capture, closes the file, and marks the sidecar interrupted on io; the recording stays in the slot. Other states are ignored. */
    fun interrupt() {
        val recording = _state.value as? DictationState.Recording ?: return
        selfRecord?.let { session ->
            // The no-file branch has no recording to keep: the recognized text is inserted directly and returns to Idle.
            val recognized = abandonSelfRecord(session)
            setState(DictationState.Idle)
            insertInterruptedSelfRecord(recording.slotKey, recognized)
            return
        }
        val current = slot ?: return
        slot = null
        releaseInterruptions()
        // The recording stays in the slot and the whole thing will be inserted on later transcription: retract the live text on screen first to avoid duplication.
        retractLive(recording.slotKey)
        abandonLive()
        // Stopping capture joins the capture thread, so not on the main thread. ADTS is flushed after each frame and has no file trailer, so if the process is killed before close, the written part is not lost:
        // on the next launch sweepOnLaunch recomputes the sidecar still marked recording from the file and sets it to interrupted.
        // UNDISPATCHED: it is already queued on storeLock before returning, so later slot-store operations such as switching slots or starting a recording queue behind it.
        // Queue the wrap-up before switching state: the sidecar duration read triggered by setState also goes through storeLock, and must come after closing the file writes the duration.
        val stopped = beginCaptureTeardown()
        scope.launch(start = CoroutineStart.UNDISPATCHED) {
            onStore(nonCancellable = true) {
                stopCapture(stopped)
                if (!closeSlot(current, RecordingSlotStatus.Interrupted)) {
                    // File close failed: the partly written data stays in the slot and the sidecar is marked interrupted as far as possible.
                    runCatching { store.markInterrupted(recording.slotKey) }
                }
            }
        }.invokeOnCompletion { stopped() }
        setState(DictationState.Interrupted(recording.slotKey))
    }

    /**
     * ✕ discards a recording in progress / transcribing / interrupted / failed / occupied slot: longer than 5 seconds goes to the recycle area and sends [DictationEvent.DiscardUndoable]; otherwise it is deleted directly.
     * While transcribing, the in-flight transcription is cancelled first and the discard happens after it wraps up.
     */
    override fun discard() {
        selfRecord?.let { session ->
            // No-file branch: no recording to undo, returns to Idle immediately.
            commitUndoWindow()
            abandonSelfRecord(session)
            when (val state = _state.value) {
                is DictationState.Recording -> retractLive(state.slotKey)
                is DictationState.Transcribing -> retractLive(state.slotKey)
                else -> Unit
            }
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
        // While recording or transcribing, ✕ also retracts the live text on screen.
        if (_state.value is DictationState.Recording || transcribing) {
            retractLive(slotKey)
            abandonLive()
        }
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
                    // Close the file first so the duration is written to the sidecar, letting the discard decide from the duration whether it can be undone.
                    stopCapture(stopped)
                    closeSlot(current, RecordingSlotStatus.Interrupted)
                }
                store.discard(slotKey)
            }
            // If the in-flight transcription already deleted the slot first (result is null), it has no further action here.
            if (result == null) return@launch
            if (result.undoable) {
                openUndoWindow(slotKey)
                _events.trySend(DictationEvent.DiscardUndoable(slotKey))
            }
        }.also { storeJob = it }.also { it.invokeOnCompletion { stopped?.invoke() } }
    }

    /** Opens the undo window: commits automatically when [UNDO_WINDOW_MILLIS] expires; switching sessions does not affect it. */
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

    /** Commits the open undo window (ignored if none). */
    private fun commitUndoWindow() {
        val slotKey = undoKey ?: return
        closeUndoWindow()
        scope.launch { commitInIo(slotKey) }
    }

    /** Clears [slotKey] from the recycle area on io. */
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
     * "Undo" in the undo window: the recording is moved back into the slot on io and returns to Interrupted. Returns false if another session flow is in progress or the undo window has already been committed.
     * If the discarded slot is no longer the bound one (already switched away): only the recording is moved back and the current session state is not touched; when switching back, [bind] shows Interrupted.
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
        // The recycle area keeps this slot only while the undo window is open: once the window is committed it cannot be undone.
        if (undoKey != slotKey) return false
        // Close the window first (commit on expiry must not race the restore for the same slot); the restore runs on io, and if it fails the discard is committed.
        closeUndoWindow()
        val undo = scope.launch {
            val restored = onStore {
                store.undoDiscard(slotKey).also { restored ->
                    if (restored) store.markInterrupted(slotKey) else store.commitDiscard(slotKey)
                }
            }
            if (!restored) {
                return@launch
            }
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

    /** Undo window ends: clears this slot from the recycle area on io. */
    fun commitDiscard(slotKey: String) {
        if (undoKey == slotKey) closeUndoWindow()
        scope.launch { commitInIo(slotKey) }
    }

    /**
     * [live] non-null means this recording had a live session (the live session gave no finalized text): merges the recording result with the live text on screen per [LiveDictationRules.dictationOutcome];
     * if the merged result is still not text, the live text is retracted before entering failure.
     */
    private suspend fun transcribe(
        slotKey: String,
        submit: DictationSubmit,
        meta: RecordingSlotMeta,
        live: LiveSessionResult? = null,
    ) {
        val segment = STTSegment(
            aac = store.audioFile(slotKey),
            primingFrames = meta.primingFrames,
            envelope = meta.envelope,
        )
        // No engine selected after switching slot / cold start: same cloud resolution as starting a recording (falls back once with a notice and switches to system; if the catalog cannot be fetched, the system is used this time without changing or notifying).
        val selected = engine ?: run {
            val resolved = resolveCloud(slotKey)
            _engineInfo.value = resolved?.info ?: DictationEngineInfo.System
            engineCloud = resolved != null
            (resolved?.engine ?: engines.system()).also { engine = it }
        }
        val cloud = engineCloud
        // Cloud takes the original value (auto = null, no language); the system engine fills in the UI language. Failed.language records the value actually sent to recognition.
        val language = if (cloud) environment.recognitionLanguage() else systemLanguage()
        // The language name on the card: auto (cloud null) records the full UI language tag at the moment of failure, and does not change after the UI language is later changed.
        fun failLanguage() = language ?: environment.uiLanguageTag()
        var attempt = 1
        var result = selected.transcribe(segment, language)
        // Recognizer busy on the system: this time (a manual retry also counts from 1), the first failure rebuilds the recognizer (a new session per file recognition) and retries automatically, without leaving the card or reporting.
        while (!cloud && systemDecision(result, attempt)?.autoRetry == true) {
            currentCoroutineContext().ensureActive()
            attempt++
            result = selected.transcribe(segment, language)
        }
        if (live != null) {
            val file = when (result) {
                is STTResult.Success -> LiveFileResult.Text(result.text)
                is STTResult.Failed -> LiveFileResult.Failed(reportableKind(result.failure))
            }
            val outcome = LiveDictationRules.dictationOutcome(live, file)
            if (outcome.result == DictationOutcomeResult.Text) {
                currentCoroutineContext().ensureActive()
                deliver(slotKey, submit, checkNotNull(outcome.text), meta.durationSec)
                return
            }
            retractLive(slotKey)
        }
        when (result) {
            is STTResult.Success -> {
                // Discarded / switched away by ✕ during transcription: the engine may swallow the cancellation and return the result as usual; late results are never applied (no insert, no recording deleted, no Failed written).
                currentCoroutineContext().ensureActive()
                // The pre-check already judged there was voice, so empty text does not delete the recording and leaves it for a retry.
                if (DictationRules.trim(result.text).isEmpty()) {
                    fail(slotKey, DictationFailedAction.NoTranscript, failLanguage())
                    return
                }
                deliver(slotKey, submit, result.text, meta.durationSec)
            }
            is STTResult.Failed -> {
                val decision = if (cloud) null else systemDecision(result, attempt)
                if (decision?.kind == SystemFailureKind.Permission || decision?.kind == SystemFailureKind.Cancelled) {
                    // Recognizer reported permission: enter the existing microphone-permission card; cancelled: silently return to Idle. Neither shows the failure card nor reports a failure; the recording stays in the slot for a retry.
                    onStore { runCatching { store.updateStatus(slotKey, RecordingSlotStatus.Failed) } }
                    setState(if (decision.kind == SystemFailureKind.Permission) DictationState.Denied else DictationState.Idle)
                    return
                }
                // Failure mapping follows the engine's primary action, as in the community baseline (no telemetry branch).
                fail(slotKey, failedAction(result.primaryAction), failLanguage())
            }
        }
    }

    /**
     * After text comes out: if the host is still on the slot, deletes the recording, returns to Idle and sends insert / send by [submit]; if the host has left, nothing is sent and the recording stays as Interrupted.
     * Deleting the recording and sending the event are not cancellable: if switching away / leaving cancels after the delete, the text would be lost.
     */
    private suspend fun deliver(
        slotKey: String,
        submit: DictationSubmit,
        text: String,
        durationSec: Double,
    ) = withContext(NonCancellable) {
        if (boundKey != slotKey) {
            // The host has left the slot: no receiver, so nothing is inserted or sent and the recording is not deleted; it is left for the host to transcribe when it returns.
            // If the host has moved to another slot, the state belongs to the new slot and is not overwritten.
            onStore { runCatching { store.markInterrupted(slotKey) } }
            if (boundKey == null) setState(DictationState.Interrupted(slotKey))
            return@withContext
        }
        onStore { store.complete(slotKey) }
        // The host left while the recording was being deleted: the recording is gone, the text is still sent (the event stays in the channel), and the state returns to Idle.
        setState(DictationState.Idle)
        _events.trySend(
            when (submit) {
                DictationSubmit.Insert -> DictationEvent.Insert(slotKey, text)
                DictationSubmit.Send -> DictationEvent.Send(slotKey, text)
            },
        )
    }

    /** Folds a live session's [STTResult] into [LiveSessionResult]: a timeout maps to timeout, a failure maps to one of five kinds (anything outside the five maps to other). */
    private fun liveSessionResult(result: STTResult, transcript: LiveTranscript, hasRecording: Boolean) = when {
        result is STTResult.Success ->
            LiveSessionResult(
                transcript.finals,
                transcript.partial,
                LiveEnded.Ok,
                hasRecording = hasRecording,
                droppedAudio = result.droppedAudio,
            )
        (result as STTResult.Failed).failure == DictationFailure.Timeout ->
            LiveSessionResult(transcript.finals, transcript.partial, LiveEnded.Timeout, hasRecording = hasRecording)
        else -> LiveSessionResult(
            transcript.finals,
            transcript.partial,
            LiveEnded.Failed,
            reportableKind(result.failure),
            hasRecording,
        )
    }

    /** Maps a failure cause to one of the five kinds dictationOutcome recognizes: recognizer error codes via the table, network maps to network, timeout maps to busy, and everything else maps to other. */
    private fun reportableKind(failure: DictationFailure): SystemFailureKind {
        val kind = when (failure) {
            is DictationFailure.Recognizer -> SystemFailure.kindOf(SystemFailureInput.Code(failure.code))
            DictationFailure.Network -> SystemFailureKind.Network
            DictationFailure.Timeout -> SystemFailureKind.Busy
            else -> SystemFailureKind.Other
        }
        return if (kind.isReportable) kind else SystemFailureKind.Other
    }

    /** Sidecar unreadable (disk full / deleted): without duration and envelope it cannot be transcribed, so the orphan audio is cleared (not counted as lost) and it returns to Idle without entering Failed. */
    private suspend fun dropUnreadableSlot(slotKey: String) {
        onStore { store.complete(slotKey) }
        setState(DictationState.Idle)
    }

    /**
     * A failure does not delete the recording: the sidecar is marked failed (it still enters Failed even if the write fails), and the state carries the primary-button destination.
     * Each entry into Failed occurs once (automatic retries have already been exhausted inside the engine).
     */
    private suspend fun fail(
        slotKey: String,
        action: DictationFailedAction,
        language: String? = null,
    ) {
        onStore { runCatching { store.updateStatus(slotKey, RecordingSlotStatus.Failed) } }
        setState(DictationState.Failed(slotKey, action, language))
    }

    /**
     * System engine file recognition failures are classified by the shared code table (attempt counts from 1; file recognition can be safely retried): recognizer error codes are looked up in the table;
     * a route that cannot transcribe a file ([SystemSTTEngine.FILE_UNSUPPORTED_ERROR]) maps to no recognition service; a timeout maps to the condition timeout (busy).
     * Returns null if it is neither a recognizer failure nor a timeout.
     */
    private fun systemDecision(result: STTResult, attempt: Int): SystemFailureDecision? {
        val failure = (result as? STTResult.Failed)?.failure ?: return null
        val input = when {
            failure == DictationFailure.Timeout -> SystemFailureInput.Condition(SystemFailureCondition.Timeout)
            failure !is DictationFailure.Recognizer -> return null
            failure.code == SystemSTTEngine.FILE_UNSUPPORTED_ERROR -> SystemFailureInput.Condition(SystemFailureCondition.NoService)
            else -> SystemFailureInput.Code(failure.code)
        }
        return SystemFailure.classify(input, attempt)
    }

    private fun releaseInterruptions() {
        interruptions?.close()
        interruptions = null
    }

    /** Choice made before recording starts: the file branch carries the engine and the engine id written to the sidecar; the no-file branch carries the self-record route. */
    private sealed interface EngineSelection {
        val info: DictationEngineInfo

        /** [engineId] is `system` or `<providerKind>/<model>`. */
        data class WithFile(
            val engine: STTEngine,
            val engineId: String,
            override val info: DictationEngineInfo = DictationEngineInfo.System,
            /** provider_kind for analytics: the providerKind rawValue for cloud, `system` for the system engine. */
            val providerKind: String = SystemSTTEngine.ENGINE_NAME,
            /** System engine: after recording starts, picks the route and opens the live session in the background (when the pipe route is chosen, it recognizes while recording); false for cloud. */
            val live: Boolean = false,
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
     * Chooses the engine before recording: a saved system choice is used directly; a saved cloud choice first reads the catalog cache cold, and fetches only if nothing is cached;
     * if the fetch fails (failure / 404) the system is used this time without changing settings or notifying; on resolving a fallback it switches back to system and sends [DictationEvent.EngineFallback] once;
     * a fallback the settings page already discovered is announced once here; resolving to cloud without consent to disclosure uses the system this time without rewriting or notifying.
     * If it falls back to the system engine and system routing is unavailable, sends [DictationEvent.SystemUnavailable], returns to Idle and returns null; a self-record route goes to the no-file branch.
     */
    /** Language for the system engine / routing: the settings value, or the UI language when auto. */
    private fun systemLanguage(): String = environment.recognitionLanguage() ?: environment.uiLanguageTag()

    private suspend fun selectEngine(slotKey: String): EngineSelection? {
        val cloud = resolveCloud(slotKey)
        if (cloud != null) return cloud
        // Unavailable / self-record must be decided before capture opens: only non-suspending routing is used (cache hit); if it cannot be decided, recording starts first and routing and the live session are set up in the background.
        return when (val route = engines.cachedSystemRoute(systemLanguage())) {
            SystemSTTRoute.Unavailable -> {
                setState(DictationState.Idle)
                _events.trySend(DictationEvent.SystemUnavailable(slotKey))
                null
            }
            is SystemSTTRoute.SelfRecord -> EngineSelection.SelfRecord(route)
            is SystemSTTRoute.Pipe, null -> EngineSelection.WithFile(engines.system(), SystemSTTEngine.ENGINE_NAME, live = true)
        }
    }

    /** On the pipe / self-record route, language-pack guidance ([offer]) for a language not yet prompted: sends [DictationEvent.LanguagePackOffer] once and records it, without blocking this dictation. */
    private fun offerLanguagePack(offer: Boolean, languageTag: String) {
        if (!offer || settings.languagePackOffered(languageTag)) return
        settings.markLanguagePackOffered(languageTag)
        _events.trySend(DictationEvent.LanguagePackOffer(languageTag))
    }

    override fun downloadLanguagePack(language: String) {
        scope.launch { engines.downloadLanguagePack(language) }
    }

    /** Returns the cloud engine when cloud is available; otherwise (including fallbacks) returns null. */
    private fun noticeFallback(slotKey: String, resolution: VoiceEngineResolution?) {
        val reason = settings.applyResolution(VoiceDirection.Stt, resolution, VoiceNoticeSite.Use) ?: return
        _events.trySend(DictationEvent.EngineFallback(slotKey, reason))
    }

    private suspend fun resolveCloud(slotKey: String): EngineSelection.WithFile? {
        val selection = settings.selection(VoiceDirection.Stt) as? VoiceEngineSelection.Cloud
        if (selection == null) {
            // Saved value is the system: a fallback the settings page discovered earlier is announced once here.
            noticeFallback(slotKey, VoiceEngineResolution(VoiceEngine.System))
            return null
        }
        // Cache read + cold fetch share one total time limit (the cache read and the refresh share the catalog lock, so a stuck refresh elsewhere makes the cache read wait too):
        // on timeout it is treated as a fetch failure, so the start flow does not hang and a later tap on the microphone is not silently dropped.
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
        // Resolved to cloud but this (providerKind, stt) has not consented to disclosure: the system is used this time, without rewriting or prompting.
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
            providerKind = resolved.providerKind.rawValue,
        )
    }

    private suspend fun openAndCapture(
        slotKey: String,
        selected: EngineSelection.WithFile,
        events: AudioCaptureEvents,
        preroll: DictationLivePreroll?,
    ): OpenResult {
        val opened = try {
            store.open(slotKey, selected.engineId, encoderFactory())
        } catch (_: RecordingSlotOccupiedException) {
            return OpenResult.Occupied
        } catch (_: Exception) {
            // Encoder could not be built / writing the sidecar failed: store.open has already torn down the half-open file, handled as capture failing to start.
            return OpenResult.Unavailable
        }
        try {
            // The AudioRecord of the just-closed session is still releasing on io: wait for it to release the mic before opening (suspends, does not occupy the main thread); on timeout it is handled as capture failing to start.
            if (!awaitCaptureTeardowns()) throw CaptureTeardownTimeoutException()
            // Recording writes to the slot while also feeding the live session and the volume meter.
            capture.start(listOfNotNull(opened, preroll, meter), events)
        } catch (_: Exception) {
            // Capture did not start: no slot is kept; after closing the file, both the sidecar and the audio are deleted.
            closeSlot(opened, RecordingSlotStatus.Failed)
            runCatching { store.complete(slotKey) }
            return OpenResult.Unavailable
        }
        return OpenResult.Opened(opened)
    }

    /** Closes the file and finalizes the sidecar; errors do not throw, returns false (the partly written data stays in the slot). */
    private fun closeSlot(current: RecordingSlot, status: RecordingSlotStatus): Boolean =
        try {
            current.finish(status)
            true
        } catch (_: Exception) {
            false
        }

    /**
     * Reports a mid-capture error / capture being muted by the system: dispatched back to the main thread and wrapped up with [interrupt]; the partly written data stays in the slot.
     * Only the recording segment it belongs to ([target]) is recognized; reports that arrive after wrap-up are ignored.
     */
    private inner class CaptureRelay : AudioCaptureEvents {
        /** The slot it belongs to: installed on the main thread once recording start completes; a report before that only records [reported], and [begin] completes the wrap-up later. */
        var target: RecordingSlot? = null

        @Volatile
        var reported = false

        override fun onFailure(error: Throwable) = report()

        override fun onInterrupted() = report()

        private fun report() {
            reported = true
            scope.launch {
                // Main.immediate runs it in place on the main thread: yield once first and wrap up after the callback returns (calling stop synchronously inside the callback would deadlock).
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

    /** System recognizer failure kind -> failure card; other remains the retry card. */
    private fun failedAction(kind: SystemFailureKind): DictationFailedAction = when (kind) {
        SystemFailureKind.Network -> DictationFailedAction.Network
        SystemFailureKind.Busy -> DictationFailedAction.Busy
        SystemFailureKind.LanguageUnsupported -> DictationFailedAction.LanguageUnsupported
        SystemFailureKind.NoService -> DictationFailedAction.NoService
        SystemFailureKind.NoTranscript -> DictationFailedAction.NoTranscript
        SystemFailureKind.Other, SystemFailureKind.Permission, SystemFailureKind.Cancelled -> DictationFailedAction.Retry
    }

    companion object {
        /** Undo window duration 4 s ; only opened for discards longer than 5 s. */
        const val UNDO_WINDOW_MILLIS = 4_000L

        /** Total limit of 10 s for the cold fetch of the catalog before starting (same as iOS); on timeout it is handled as a fetch failure. */
        const val CATALOG_REFRESH_TIMEOUT_MILLIS = 10_000L

        /** Slot-store directory already swept in this process (same as iOS sweptRoots). */
        private val sweptRoots = mutableSetOf<String>()
    }
}
