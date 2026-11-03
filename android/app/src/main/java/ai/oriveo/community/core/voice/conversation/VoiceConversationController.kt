package ai.oriveo.community.core.voice.conversation

import ai.oriveo.community.core.voice.realtime.RealtimeVoiceLog
import android.content.SharedPreferences
import android.os.Build
import android.os.SystemClock
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.ProcessLifecycleOwner
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.provider.ProviderCredentialResolver
import ai.oriveo.community.core.provider.transport.EndpointResolver
import ai.oriveo.community.core.voice.CloudSpeechEngine
import ai.oriveo.community.core.voice.DictationCatalogSource
import ai.oriveo.community.core.voice.DictationController
import ai.oriveo.community.core.voice.DictationRules
import ai.oriveo.community.core.voice.DictationEngineFactory
import ai.oriveo.community.core.voice.DictationFailure
import ai.oriveo.community.core.voice.DictationLevelMeter
import ai.oriveo.community.core.voice.DictationLivePreroll
import ai.oriveo.community.core.voice.DictationLiveSession
import ai.oriveo.community.core.voice.LiveDictationRules
import ai.oriveo.community.core.voice.LiveTranscript
import ai.oriveo.community.core.voice.DictationPrimaryAction
import ai.oriveo.community.core.voice.ReadAloudEngineSource
import ai.oriveo.community.core.voice.STTEngine
import ai.oriveo.community.core.voice.STTResult
import ai.oriveo.community.core.voice.SpeakablePlaceholder
import ai.oriveo.community.core.voice.SpeakableSegment
import ai.oriveo.community.core.voice.SystemFailureCondition
import ai.oriveo.community.core.voice.SystemFailureInput
import ai.oriveo.community.core.voice.SystemFailureKind
import ai.oriveo.community.core.voice.SystemSTTEngine
import ai.oriveo.community.core.voice.SystemSTTRoute
import ai.oriveo.community.core.voice.VoiceCatalogState
import ai.oriveo.community.core.voice.VoiceConnection
import ai.oriveo.community.core.voice.VoiceDirection
import ai.oriveo.community.core.voice.VoiceDisclosureStore
import ai.oriveo.community.core.voice.VoiceEngine
import ai.oriveo.community.core.voice.VoiceEngineResolver
import ai.oriveo.community.core.voice.VoiceEngineSelection
import ai.oriveo.community.core.voice.VoiceEngineSettings
import ai.oriveo.community.core.voice.VoiceFallbackReason
import ai.oriveo.community.core.voice.VoiceSttEntry
import ai.oriveo.community.core.voice.speakableSegments
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CompletableDeferred
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

// ───────────── Ports ─────────────

/** One reply event from the chat; [Text] always carries the full text so far. */
sealed interface VoiceReplyEvent {
    data class Text(val full: String) : VoiceReplyEvent
    /** The reply ended; [delivered] is false when it was stopped part-way (interrupted), which is not a turn. */
    data class Completed(val delivered: Boolean = true) : VoiceReplyEvent
    data class Failed(val code: String) : VoiceReplyEvent
    data class ApprovalPending(val pending: Boolean) : VoiceReplyEvent
}

/**
 * The chat the conversation talks to (bridged to ChatViewModel by the host). [replies] must only carry events of the
 * current generation: after [cancel] no event of the cancelled reply may arrive.
 */
interface VoiceConversationChatPort {
    /** Sends [text] as a user message (purpose chat, delivery voice); false when it could not be sent. */
    suspend fun send(text: String): Boolean

    /**
     * Interjection while thinking: replaces the last user message with joinAmend(it, [text]) and regenerates; an empty string regenerates as is.
     * false = not sent (default: the host has not wired it up yet).
     */
    suspend fun amend(text: String): Boolean = false

    /**
     * Same as [send]; the port calls [onDelivered] synchronously just before it hands the text to the page (new user message).
     * Does not report delivery by default: on cancel the host carries the text as undelivered (the old stand-in's behavior).
     */
    suspend fun send(text: String, onDelivered: () -> Unit): Boolean = send(text)

    /** Same as [amend]; the port calls [onDelivered] synchronously just before it hands the text to the page (replacing the user message). Does not report delivery by default. */
    suspend fun amend(text: String, onDelivered: () -> Unit): Boolean = amend(text)

    val replies: Flow<VoiceReplyEvent>

    fun cancel()
}

/** Text the controller speaks or shows that comes from localized resources. */
sealed interface VoicePrompt {
    data object DidNotCatch : VoicePrompt
    data object ApprovalNeeded : VoicePrompt
    data object SayAgain : VoicePrompt
    data object CheckLanguage : VoicePrompt
    data object EchoHint : VoicePrompt
    data class Placeholder(val kind: SpeakablePlaceholder) : VoicePrompt
}

/** A self-recording recognizer turn (system recognizer opens the mic itself; API < 33 path). */
interface SelfRecordTurn {
    /** Recognizer onRmsChanged (dB, recognizer scale); drives the listening level since there is no PCM. */
    var onRmsDb: ((Float) -> Unit)?

    /** Voice the recognizer heard in the finished turn (onBeginningOfSpeech -> onEndOfSpeech), read after [await]; 0 = none. */
    val voicedMs: Int get() = 0

    suspend fun await(): STTResult

    fun interrupt()
}

/** How this conversation transcribes, resolved once at start with the dictation engine settings. */
sealed interface ConversationStt {
    /**
     * [providerKind] = the cloud STT entry's provider kind; null = system engine.
     * [live] opens a live recognition session per sentence (system pipe route): its partials drive the caption and a
     * non-empty result replaces the file transcription; null (or a null / failed open) = file transcription only.
     */
    data class FromFile(
        val engine: STTEngine,
        val language: String?,
        val providerKind: String? = null,
        val live: (suspend () -> DictationLiveSession?)? = null,
        /** Diagnostics only: the system recognition route [live] runs on (recognizer and language); null = unknown. */
        val liveRoute: SystemSTTRoute.Pipe? = null,
    ) : ConversationStt

    /** Recognizer records its own turns: no AudioRecord, no VAD; only tap barge-in while speaking. */
    class SelfRecord(val startTurn: suspend () -> SelfRecordTurn) : ConversationStt

    data object Unavailable : ConversationStt
}

fun interface ConversationSttSource {
    suspend fun resolve(): ConversationStt
}

/** Speech for this conversation: [primary] (cloud or system) and the [system] voice used for prompts and fallback. */
data class ConversationVoices(
    val primary: ConversationTts,
    val system: ConversationTts,
    val providerDisplayName: String? = null,
    val fallbackReason: VoiceFallbackReason? = null,
)

fun interface ConversationTtsSource {
    suspend fun pick(): ConversationVoices
}

interface VoiceConversationEnvironment {
    /** Stops read aloud before the conversation starts. */
    fun stopReadAloud()

    /** Reports app background (true) / foreground (false); closing unregisters. */
    fun observeBackground(onChange: (Boolean) -> Unit): AutoCloseable {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_STOP -> onChange(true)
                Lifecycle.Event.ON_START -> onChange(false)
                else -> Unit
            }
        }
        val lifecycle = ProcessLifecycleOwner.get().lifecycle
        lifecycle.addObserver(observer)
        return AutoCloseable { lifecycle.removeObserver(observer) }
    }
}

/**
 * Per-device memory of "speaker playback can't be voice-interrupted": set after
 * [VoiceConversationConstants.CONVERSATIONS_TO_REMEMBER] consecutive conversations fell back to tap; local only,
 * cleared whenever the OS API level changes.
 */
class SpeakerBargeInMemory(
    prefsProvider: () -> SharedPreferences,
    private val sdkInt: Int = Build.VERSION.SDK_INT,
    /** Where the first prefs read (a disk load) runs. */
    private val io: CoroutineDispatcher = Dispatchers.IO,
) {
    private val prefs by lazy(LazyThreadSafetyMode.PUBLICATION) { prefsProvider() }
    private val background = CoroutineScope(SupervisorJob() + io)

    /** In-memory copy, authoritative once read; disk writes trail it. */
    private var cached: Values? = null

    /** Ends recorded before the first read; folded in by [loaded]. */
    private val pendingEnds = ArrayList<Pair<Boolean, Boolean>>()

    private data class Values(val streak: Int, val remembered: Boolean)

    /** [remembersNoSpeakerBargeIn]; reads memory when already loaded, else does the first read off the main thread. */
    suspend fun load(): Boolean {
        synchronized(this) { cached?.let { return it.remembered } }
        return withContext(io) { remembersNoSpeakerBargeIn() }
    }

    @Synchronized
    fun remembersNoSpeakerBargeIn(): Boolean = loaded().remembered

    /**
     * [fellBackToTap]: this conversation hit the false barge-in limit. [exercisedSpeakerBargeIn]: speaker playback
     * with voice barge-in on happened at all; a conversation that never did leaves the streak untouched.
     * Memory is updated before this returns, so the next conversation's [load] sees it; the disk write follows.
     */
    @Synchronized
    fun conversationEnded(fellBackToTap: Boolean, exercisedSpeakerBargeIn: Boolean) {
        val current = cached
        if (current == null) {
            // Not read yet: reading here would load the prefs on the main thread.
            pendingEnds += fellBackToTap to exercisedSpeakerBargeIn
            background.launch { remembersNoSpeakerBargeIn() }
            return
        }
        val next = current.after(fellBackToTap, exercisedSpeakerBargeIn)
        if (next == current) return
        cached = next
        background.launch { persist() }
    }

    /** Callers hold the lock. */
    private fun loaded(): Values {
        cached?.let { return it }
        if (prefs.getInt(KEY_SDK, -1) != sdkInt) {
            prefs.edit().clear().putInt(KEY_SDK, sdkInt).apply()
        }
        var values = Values(prefs.getInt(KEY_STREAK, 0), prefs.getBoolean(KEY_REMEMBERED, false))
        val disk = values
        for ((fellBack, exercised) in pendingEnds) values = values.after(fellBack, exercised)
        pendingEnds.clear()
        cached = values
        if (values != disk) write(values)
        return values
    }

    @Synchronized
    private fun persist() {
        cached?.let(::write)
    }

    private fun write(values: Values) {
        prefs.edit().putInt(KEY_STREAK, values.streak).putBoolean(KEY_REMEMBERED, values.remembered).apply()
    }

    private fun Values.after(fellBackToTap: Boolean, exercisedSpeakerBargeIn: Boolean): Values = when {
        fellBackToTap -> {
            val streak = streak + 1
            Values(streak, remembered || streak >= VoiceConversationConstants.CONVERSATIONS_TO_REMEMBER)
        }
        exercisedSpeakerBargeIn -> copy(streak = 0)
        else -> this
    }

    companion object {
        const val PREFS_NAME = "oriveo_voice_conversation"
        private const val KEY_SDK = "sdkInt"
        private const val KEY_STREAK = "falseBargeInStreak"
        private const val KEY_REMEMBERED = "noSpeakerBargeIn"
    }
}

/** What the host should surface. */
sealed interface VoiceConversationEvent {
    /** Start refused before entering the conversation; show the existing error toast. */
    data class StartFailed(val reason: StartFailure) : VoiceConversationEvent

    /** Cloud speech failed mid-conversation; the rest is spoken with the system voice. */
    data class EngineFallback(val providerDisplayName: String?) : VoiceConversationEvent

    /** TTS engine resolution fell back at start (notice). */
    data class TtsSelectionFallback(val reason: VoiceFallbackReason) : VoiceConversationEvent

    /** Self-recording path paused because the app went to the background. */
    data object PausedInBackground : VoiceConversationEvent

    /** Ended with ✕ while the user was speaking: the transcript goes to the draft. */
    data class DraftTranscript(val text: String) : VoiceConversationEvent

    data class Ended(val reason: EndReason, val code: String?) : VoiceConversationEvent

    /** Reducer asked for a light system haptic (heard / end); the host performs it with the system setting. */
    data class Haptic(val kind: HapticKind) : VoiceConversationEvent

    /** Reducer asked the orb for a light nudge (an echo was ignored); the host only exposes it as a signal. */
    data object NudgeOrb : VoiceConversationEvent
}

enum class StartFailure { FOREGROUND, STT_UNAVAILABLE, AUDIO }

// ───────────── Controller ─────────────

/**
 * Voice conversation host: turns audio, STT, chat and TTS signals into [ConversationEvent]s, folds them with
 * [reduce] and executes the effects. One conversation at a time; public methods on the main thread.
 * The host starts [VoiceConversationService] (via [VoiceConversationServiceStarter]) before [start]; the controller
 * waits for the foreground service before it requests audio focus.
 */
class VoiceConversationController(
    private val audio: ConversationAudio,
    private val sttSource: ConversationSttSource,
    private val ttsSource: ConversationTtsSource,
    private val foreground: VoiceConversationForeground,
    private val environment: VoiceConversationEnvironment,
    private val memory: SpeakerBargeInMemory,
    private val prompt: (VoicePrompt) -> String,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
    private val clock: () -> Long = { SystemClock.elapsedRealtime() },
    private val levelIntervalMs: Long = LEVEL_INTERVAL_MS,
    /** Where turn / draft audio files are deleted: never on [scope]'s (main) thread. */
    private val io: CoroutineDispatcher = Dispatchers.IO,
    private val deleteFile: (java.io.File) -> Unit = { it.delete() },
    /** Per-turn diagnostics (observation only); not reported by default. */
    private val diagnostics: VoiceConversationDiagnostics = VoiceConversationDiagnostics.NoOp,
    /** Speech probability model: loaded on [io] before each session starts capturing, waiting at most [SPEECH_MODEL_WAIT_MS]; null = no model, this session uses energy mode. */
    private val speechProbs: SpeechProbSource? = null,
    /**
     * Frame stall / consumer backlog watchdog; on by default. Fake capture in unit tests feeds frames in batches under virtual time and stops once fed,
     * so it is turned off except in cases that test the watchdog itself.
     */
    private val frameWatchdog: Boolean = true,
) : VoiceConversationEngine {
    private val _displayState = MutableStateFlow<ConversationDisplayState?>(null)
    private val _statusKey = MutableStateFlow<ConversationStatusKey?>(null)
    private val _level = MutableStateFlow(0f)
    private val _caption = MutableStateFlow("")
    private val _active = MutableStateFlow(false)
    private val _events = MutableSharedFlow<VoiceConversationEvent>(extraBufferCapacity = 16)

    /** The only thing the voice bar reads. */
    val displayState: StateFlow<ConversationDisplayState?> = _displayState.asStateFlow()
    override val statusKey: StateFlow<ConversationStatusKey?> = _statusKey.asStateFlow()

    /** Live caption shown in the status word's place; empty unless [statusKey] is caption. */
    val caption: StateFlow<String> = _caption.asStateFlow()

    /** Orb level 0…1: mic while listening, TTS output while speaking; at most ~15 updates per second. */
    override val level: StateFlow<Float> = _level.asStateFlow()
    override val active: StateFlow<Boolean> = _active.asStateFlow()
    override val events: SharedFlow<VoiceConversationEvent> = _events.asSharedFlow()

    private var session: Session? = null

    // Do not read the clock extra when diagnostics are not reported (clock readings are timing under test too).
    private val diagnosing = diagnostics !== VoiceConversationDiagnostics.NoOp
    private fun diagClock(): Long = if (diagnosing) clock() else 0L

    @Volatile private var lastLevelAt = Long.MIN_VALUE / 2
    @Volatile private var windowPeak = 0f

    override fun start(chat: VoiceConversationChatPort) {
        if (session != null) return
        environment.stopReadAloud()
        val s = Session(chat)
        session = s
        _active.value = true
        s.scope.launch { s.run() }
    }

    override fun tapOrb() {
        session?.dispatch { ConversationEvent.TapOrb(it) }
    }

    override fun toggleMute() {
        session?.dispatch { ConversationEvent.ToggleMute(it) }
    }

    /**
     * Plays an earlier message with the conversation's own voice while listening (capture paused, back to
     * listening when done). Ignored outside listening, like the reducer.
     */
    fun playMessage(messageId: String, text: String) {
        val s = session ?: return
        s.messageTexts[messageId] = text
        s.dispatch { ConversationEvent.PlayMessage(it, messageId) }
    }

    /** The screen reader is speaking the status word; capture is not processed meanwhile. */
    override fun screenReaderSpeaking(speaking: Boolean) {
        session?.screenReaderSpeaking(speaking)
    }

    /** The recognition language changed mid-conversation: the next sentence transcribes with it. */
    override fun recognitionLanguageChanged() {
        session?.recognitionLanguageChanged()
    }

    /**
     * ✕ / leaving the chat (user) or system teardown.
     */
    override fun end(reason: EndReason) {
        val s = session ?: return
        if (s.state.phase == ConversationPhase.IDLE) {
            s.finish(if (reason == EndReason.USER) EndReason.USER else EndReason.SYSTEM, null)
        } else {
            s.dispatch { ConversationEvent.End(it, reason) }
        }
    }

    /**
     * Collects the peak of every level offered within one window and publishes it once the window
     * ([levelIntervalMs]) is full, then starts a new window; [force] publishes [value] as is and resets the window.
     */
    private fun publishLevel(value: Float, force: Boolean = false) {
        val now = clock()
        if (force) {
            windowPeak = 0f
            lastLevelAt = now
            _level.value = value
            return
        }
        if (value > windowPeak) windowPeak = value
        if (now - lastLevelAt < levelIntervalMs) return
        lastLevelAt = now
        _level.value = windowPeak
        windowPeak = 0f
    }

    private sealed interface TurnAudio {
        /** [stt] = how this sentence transcribes, fixed when it opened (a language change mid-sentence does not apply). */
        class File(
            val segment: Deferred<ai.oriveo.community.core.voice.STTSegment?>,
            var live: Session.LiveTurn? = null,
            val stt: ConversationStt,
        ) : TurnAudio
        class Recognized(val result: STTResult) : TurnAudio
    }

    private inner class Session(
        val chat: VoiceConversationChatPort,
    ) : ConversationAudioListener {
        // Child of the controller scope: cancelling the controller also stops the deadline timer and collectors.
        val scope = CoroutineScope(
            this@VoiceConversationController.scope.coroutineContext +
                SupervisorJob(this@VoiceConversationController.scope.coroutineContext[Job]),
        )
        var state = initialConversationState()
        private lateinit var stt: ConversationStt
        private lateinit var voices: ConversationVoices
        private var selfRecord = false
        private var audioOpened = false
        private var ended = false

        // Event queue: effects may dispatch; events are folded strictly one after another.
        private val pending = ArrayDeque<ConversationEvent>()
        private var dispatching = false

        // One one-shot timer at nextDeadlineMs(state); armedDeadlineAt != null iff deadlineJob is pending.
        private var deadlineJob: Job? = null
        private var armedDeadlineAt: Long? = null

        // VAD
        // Replaced with a fresh energy-mode instance if model inference fails midway (see fallBackToEnergy).
        private var vad = VoiceConversationVad()
        private val frames = Channel<CapturedFrame>(Channel.UNLIMITED)

        // Frame watchdog: the capture thread writes the enqueue count and last-enqueue time; only the consumer coroutine writes the consumed count.
        private val enqueuedFrames = AtomicLong()
        @Volatile private var consumedFrames = 0L
        @Volatile private var consuming = false
        @Volatile private var lastFrameAt = 0L
        private val lagReported = AtomicBoolean()
        private val watchdogArmed = AtomicBoolean()

        // Whether the software capture gate is paused in this session (via setCapturePaused); the stall timer runs from the later of the last 'capture not running' time and the last enqueued frame.
        private var capturePaused = false
        private var stallPausedAt = Long.MIN_VALUE / 2

        // Speech probability model for this session: chosen before capture starts and never swapped mid-session (model and energy are not mixed); the capture thread reads it via liveFrameChunker.
        @Volatile override var speechModel: SpeechProbModel? = null
            private set
        private var vadMode = VAD_MODE_ENERGY
        private var lastProb: Float? = null
        private var frameIndex = -1L
        private var levelSampleFrames = 0
        private var utteranceSeq = 0
        private val turns = HashMap<String, TurnAudio>()

        // Sentences moved into turns early by a queued wrap-up: if the queue is cleared before replay and they are not transcribed again, they are removed in place.
        private val queuedTurnIds = LinkedHashSet<String>()
        private var transcribeJob: Job? = null

        // The reply turn being sent (send / amend has not returned yet): CancelGeneration cancels it; if it was not sent, it is not sent.
        private var replyJob: Job? = null

        // Text and kind of the reply turn being sent (lives and dies with replyJob; cleared when the port reports delivery); if it is still set on cancel it was not delivered and moves to carried.
        private var pendingReply: CarriedReply? = null

        // User text that CancelGeneration intercepted before delivery is prepended to the next send / amend, so nothing the user said is lost.
        private var carried: CarriedReply? = null

        // The utterance currently open: SpeechStart assigns the id and a continuation reuses it; audio is collected at Transcribe (the end frame is the latest SpeechEnd).
        private var openUtteranceId: String? = null
        private var openEndFrame: Long? = null
        private var continuedOpenUtterance = false

        // This dispatch replayed a queued utterance and kept it: the ResetVad that follows does not discard it or interrupt the VAD tracking it.
        private var replayKeptOpenUtterance = false

        // Recognition method used when the open utterance started: changing the recognition language midway does not affect it.
        private var openStt: ConversationStt? = null

        // Re-resolution after a recognition language change (through the serial gate, mutually exclusive with live recognition sessions).
        private var sttRefresh: Job? = null

        // Live recognition for the open utterance; the serial gate ensures only one recognition session is open at a time.
        private var openLive: LiveTurn? = null
        private val liveGate = Mutex()

        // Playback
        // Reply sentences and spoken prompts share one queue, so the two never talk over each other.
        private val queue = ArrayDeque<Speech>()
        private var current: Speech? = null
        private var currentReported = false
        private var paused = false
        private var playbackJob: Job? = null

        // The voice currently playing a reply sentence; held = it is paused at a pause point (playbackJob is kept), and resume continues from there.
        private var speakingVoice: ConversationTts? = null
        private var held = false

        // Start of the barge-in candidate window (the grace period counts from this frame): set when a reply starts and on each resume, kept across gaps between sentences, cleared on finish / stop / pause.
        private var playbackStartFrame: Long? = null

        // When the most recent playback actually finished audibly (reported by TTS; defaults to the time speak returned); the lingering-sound window and the self-record mic gate are not earlier than this.
        private var playbackRealEndedAt: Long? = null

        // Frame where playback actually ended (converted by resetVad); opens the speaker lingering-sound window; null = none.
        private var playbackEndedFrame: Long? = null
        private var drainedReported = true

        // Reply
        private var replyEmitted = 0

        // A cloud voice failure moves only the rest of this reply to the system voice; the next send retries cloud.
        private var replyOnSystem = false
        private var fallbackNoticed = false

        // Self-record
        private var selfTurn: SelfRecordTurn? = null
        private var selfTurnJob: Job? = null
        private var background: AutoCloseable? = null

        // Message playback
        val messageTexts = HashMap<String, String>()
        private var messageJob: Job? = null

        // Set once the conversation has started; the activation guard reads it.
        private var startedAt: Long? = null

        // Memory
        private var fellBackToTap = false
        private var exercisedSpeakerBargeIn = false
        private var promptsPlaying = 0

        suspend fun run() {
            // The model loads in parallel with the foreground service and recognition resolution; one not taken by this session (timeout, self-record, start failure) is closed on arrival.
            val modelLoad = speechProbs?.let { source ->
                SpeechModelHandoff().also { handoff ->
                    CoroutineScope(io).launch { handoff.deliver(runCatching { source.load() }) }
                }
            }
            try {
                startSession(modelLoad)
            } finally {
                modelLoad?.take()?.getOrNull()?.close()
            }
        }

        /** Waits for the model to be ready for at most [SPEECH_MODEL_WAIT_MS]: if ready, this session uses model mode; on timeout or failure, it stays in energy mode throughout. */
        private suspend fun chooseVadMode(load: SpeechModelHandoff?) {
            val result = load?.let {
                it.await(SPEECH_MODEL_WAIT_MS)
                it.take()
            }
            val model = result?.getOrNull()
            speechModel = model
            vadMode = if (model != null) VAD_MODE_MODEL else VAD_MODE_ENERGY
            val reason = when {
                model != null -> null
                load == null -> "none"
                result == null -> "timeout"
                else -> result.exceptionOrNull()?.let { it::class.java.simpleName } ?: "unknown"
            }
            diagnostics.vadMode(vadMode, reason)
        }

        private suspend fun startSession(modelLoad: SpeechModelHandoff?) {
            if (!foreground.awaitStarted()) return failStart(StartFailure.FOREGROUND)
            // Through the serial gate: if the language changed during start-up resolution, re-resolution is queued after it.
            stt = liveGate.withLock { sttSource.resolve() }
            if (stt is ConversationStt.Unavailable) return failStart(StartFailure.STT_UNAVAILABLE)
            voices = ttsSource.pick()
            voices.fallbackReason?.let { _events.tryEmit(VoiceConversationEvent.TtsSelectionFallback(it)) }
            selfRecord = stt is ConversationStt.SelfRecord
            if (ended) return
            if (!selfRecord) chooseVadMode(modelLoad)
            if (ended) return
            try {
                audio.open(this, capture = !selfRecord)
                audioOpened = true
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                return failStart(StartFailure.AUDIO)
            }
            if (ended) {
                audio.close()
                return
            }
            // Activation (focus / route) only has a result after open returns: suspend until then; on failure, end as an audio start failure without sending Start.
            if (!audio.awaitActivation()) {
                if (!ended) failStart(StartFailure.AUDIO)
                return
            }
            if (ended) return
            val remembers = memory.load() || !audio.echoCancellerAvailable || selfRecord
            if (ended) return
            scope.launch {
                // Frames enqueued before start also count as consumed: the backlog is judged only after the consumer coroutine starts.
                // Self-record mode (the system recognizer records itself, capture=false): the app receives no frames, so no backlog is counted and no stall watchdog is started.
                consuming = frameWatchdog && !selfRecord
                // Stall detection starts when capture opens: even with no frames at all, it wraps up within FRAME_STALL_MS.
                if (frameWatchdog && !selfRecord) {
                    lastFrameAt = clock()
                    if (watchdogArmed.compareAndSet(false, true)) scope.launch { watchFrames() }
                }
                try {
                    for (frame in frames) {
                        onCapturedFrame(frame.index, frame.db, frame.prob)
                        consumedFrames++
                    }
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Throwable) {
                    // Report but do not swallow: rethrow as before.
                    diagnostics.consumerFailed(diagClock(), error.javaClass.name)
                    throw error
                } finally {
                    diagnostics.consumerExit(diagClock())
                }
            }
            scope.launch { chat.replies.collect(::onReply) }
            scope.launch { foreground.endRequests.collect { dispatch { t -> ConversationEvent.End(t, EndReason.USER) } } }
            if (selfRecord) {
                background = environment.observeBackground { inBackground ->
                    if (inBackground) {
                        _events.tryEmit(VoiceConversationEvent.PausedInBackground)
                        dispatch { ConversationEvent.InterruptionBegan(it) }
                    } else {
                        dispatch { ConversationEvent.InterruptionEnded(it) }
                    }
                }
            }
            dispatch { ConversationEvent.Start(it, audio.route, remembers) }
            startedAt = clock()
        }

        private fun failStart(reason: StartFailure) {
            _events.tryEmit(VoiceConversationEvent.StartFailed(reason))
            finish(EndReason.SYSTEM, null, report = false)
        }

        fun dispatch(make: (Long) -> ConversationEvent) {
            if (ended) return
            pending.addLast(make(clock()))
            if (dispatching) return
            dispatching = true
            try {
                while (!ended) {
                    val event = pending.removeFirstOrNull() ?: break
                    val r = reduce(state, event)
                    val replayed = (event is ConversationEvent.SttResult || event is ConversationEvent.SttFailed) &&
                        state.pendingVad.isNotEmpty()
                    state = r.state
                    // A gap between sentences (the reply is still speaking) remains a candidate and does not restart the grace period; the window closes only when speaking ends (reply finished).
                    if (state.phase != ConversationPhase.SPEAKING) playbackStartFrame = null
                    if (event is ConversationEvent.VadSpeechEnd || event is ConversationEvent.VadDiscarded) settleOpenTurn()
                    // After transcription settles and queued utterances are replayed: an utterance the replay did not pick up is discarded; those it did pick up (speaking / waiting / continuing / still queued) are kept.
                    if (event is ConversationEvent.SttResult || event is ConversationEvent.SttFailed) {
                        settleOpenTurn(keepSpeaking = true)
                    }
                    pruneQueuedTurns()
                    if (replayed) recaptionReplayedUtterance()
                    replayKeptOpenUtterance = replayed && openUtteranceId != null
                    publish()
                    try {
                        for (effect in r.effects) {
                            if (ended) break
                            execute(effect)
                        }
                    } finally {
                        replayKeptOpenUtterance = false
                    }
                }
            } finally {
                dispatching = false
                if (ended) pending.clear()
            }
            if (!ended) syncSelfRecord()
            if (!ended) armDeadline()
        }

        /** Re-arms the single deadline timer only when [nextDeadlineMs] changed; an overdue deadline fires at once. */
        private fun armDeadline() {
            val at = nextDeadlineMs(state)
            if (at == armedDeadlineAt) return
            diagnostics.deadline(at, deadlineReason(at))
            deadlineJob?.cancel()
            deadlineJob = null
            armedDeadlineAt = at
            if (at == null) return
            val job = scope.launch(start = CoroutineStart.LAZY) {
                delay((at - clock()).coerceAtLeast(0L))
                if (deadlineJob === coroutineContext[Job]) {
                    deadlineJob = null
                    armedDeadlineAt = null
                }
                dispatch { ConversationEvent.Deadline(it) }
            }
            deadlineJob = job
            job.start()
        }

        /** Diagnostics: whether the deadline falls on the hold cap or on holdUntil, whichever is earlier; non-sentence-break holds report other. */
        private fun deadlineReason(at: Long?): String = when {
            at == null -> "none"
            state.holdUtteranceId == null -> "other"
            state.holdSilenceStartMs?.let { it + VoiceConversationConstants.ENDPOINT_MAX_SILENCE_MS } == at -> "cap"
            else -> "holdUntil"
        }

        private fun publish() {
            _displayState.value = displayState(state)
            _statusKey.value = statusKey(state)
            _caption.value = caption(state).orEmpty()
            if (state.phase != ConversationPhase.LISTENING && state.phase != ConversationPhase.SPEAKING) {
                publishLevel(0f, force = true)
            }
        }

        // ── effects ──

        private fun execute(effect: ConversationEffect) {
            when (effect) {
                ConversationEffect.StartCapture -> Unit
                is ConversationEffect.Transcribe -> transcribe(effect.utteranceId)
                is ConversationEffect.SendMessage -> requestReply(effect.text, send = true)
                is ConversationEffect.AmendLastMessage -> requestReply(effect.text, send = false)
                ConversationEffect.CancelGeneration -> {
                    // First stop any pending send (once cancelled it is not sent and reports no failure), then cancel generation for the turn already sent;
                    // its text was not delivered and is held for the next send / amend (cancelling only stops generation; user text is not lost).
                    replyJob?.let { job ->
                        if (job.isActive) carried = pendingReply
                        job.cancel()
                    }
                    replyJob = null
                    pendingReply = null
                    chat.cancel()
                    transcribeJob?.cancel()
                    transcribeJob = null
                    clearSpeech()
                }
                is ConversationEffect.EnqueueSpeech -> {
                    queue.addLast(Speech(effect.text, prompt = false))
                    pump()
                }
                ConversationEffect.PausePlayback -> {
                    paused = true
                    playbackStartFrame = null
                    // A reply sentence stays where it is to wait for resume; prompts or sounds that cannot be paused are cancelled as before, and resume restarts from the sentence start.
                    val voice = speakingVoice
                    held = held || (playbackJob != null && current?.prompt == false && voice != null && voice.pause())
                    if (!held) {
                        playbackJob?.cancel()
                        playbackJob = null
                    }
                }
                // Plays from the paused sentence at pausePoint; from sentenceStart (or when it did not pause) replays from the sentence start.
                is ConversationEffect.ResumePlayback -> {
                    paused = false
                    val wasHeld = held
                    held = false
                    if (wasHeld && effect.from == ResumeFrom.PAUSE_POINT && playbackJob != null) {
                        if (playbackStartFrame == null) playbackStartFrame = frameIndex + 1
                        speakingVoice?.resume()
                    } else {
                        if (wasHeld) {
                            playbackJob?.cancel()
                            playbackJob = null
                        }
                        pump()
                    }
                }
                ConversationEffect.StopPlayback -> clearSpeech()
                is ConversationEffect.SpeakPrompt -> speakPrompt(
                    when (effect.prompt) {
                        VoicePromptKind.DID_NOT_CATCH -> VoicePrompt.DidNotCatch
                        VoicePromptKind.APPROVAL_NEEDED -> VoicePrompt.ApprovalNeeded
                        VoicePromptKind.SAY_AGAIN -> VoicePrompt.SayAgain
                        VoicePromptKind.CHECK_LANGUAGE -> VoicePrompt.CheckLanguage
                        VoicePromptKind.ECHO_HINT -> VoicePrompt.EchoHint
                    },
                )
                // Outer scope: the end earcon outlives the session it closes.
                is ConversationEffect.Earcon -> this@VoiceConversationController.scope.launch {
                    runCatching { audio.playEarcon(effect.kind) }
                }
                is ConversationEffect.Haptic -> _events.tryEmit(VoiceConversationEvent.Haptic(effect.kind))
                ConversationEffect.NudgeOrb -> _events.tryEmit(VoiceConversationEvent.NudgeOrb)
                // Continuation: audio with the same id keeps being collected; the next VadSpeechEnd still reports this id.
                is ConversationEffect.ContinueUtterance ->
                    continuedOpenUtterance = effect.utteranceId == openUtteranceId
                is ConversationEffect.ResetVad -> resetVad(
                    effect.playbackEndedAtMs?.let(::notBeforeRealEnd),
                    keepOpen = replayKeptOpenUtterance,
                )
                is ConversationEffect.EndConversation -> finish(effect.reason, effect.code)
                ConversationEffect.RememberFalseBargeInConversation -> fellBackToTap = true
                ConversationEffect.ForceEndUtterance -> vad.forceEnd(frameIndex)?.let(::onVad)
                is ConversationEffect.SetCaptureMuted -> {
                    audio.setMuted(effect.muted)
                    if (!effect.muted) captureResumed()
                    dropOpenUtterance()
                }
                ConversationEffect.PauseCapture -> {
                    setCapturePaused(true)
                    dropOpenUtterance()
                }
                ConversationEffect.ResumeCapture -> setCapturePaused(false)
                is ConversationEffect.PlayMessage -> playMessage(effect.messageId)
                ConversationEffect.TranscribeToDraft -> transcribeToDraft()
            }
        }

        /** The earlier message is spoken sentence by sentence with the conversation's voice. */
        private fun playMessage(messageId: String) {
            val text = messageTexts.remove(messageId)
            messageJob?.cancel()
            messageJob = scope.launch {
                try {
                    for (segment in speakableSegments(text.orEmpty(), final = true)) {
                        val sentence = when (segment) {
                            is SpeakableSegment.Sentence -> segment.text
                            is SpeakableSegment.Placeholder -> prompt(VoicePrompt.Placeholder(segment.kind))
                        }
                        voices.primary.speak(sentence) { publishLevel(it) }
                    }
                } finally {
                    messageJob = null
                    if (!ended) dispatch { ConversationEvent.MessagePlaybackEnded(it) }
                }
            }
        }

        /**
         * Sends / amends the user message; a request that could not go out fails the reply. Text carried over from a
         * request cancelled before it went out goes first; a carried send turns this request into a send.
         */
        private fun requestReply(text: String, send: Boolean) {
            val held = carried
            carried = null
            val reply = if (held == null) {
                CarriedReply(text, send)
            } else {
                CarriedReply(joinAmend(held.text, text), send || held.send)
            }
            pendingReply = reply
            // Once the port hands the text to the page, it is already in the session: a later cancel does not carry it, and the next amend does not repeat it.
            val delivered = { if (pendingReply === reply) pendingReply = null }
            requestReply { if (reply.send) chat.send(reply.text, delivered) else chat.amend(reply.text, delivered) }
        }

        private fun requestReply(request: suspend () -> Boolean) {
            replyEmitted = 0
            replyOnSystem = false
            lastReplyText = null
            // Start sending in place: the CancelGeneration that follows in the same batch must land on this turn and must not overtake send (replay SendMessage -> CancelGeneration).
            val job = scope.launch(start = CoroutineStart.UNDISPATCHED) {
                val sent = try {
                    request()
                } catch (error: CancellationException) {
                    throw error
                } catch (_: Exception) {
                    false
                }
                if (replyJob === coroutineContext[Job]) {
                    replyJob = null
                    pendingReply = null
                }
                if (!sent) dispatch { ConversationEvent.ReplyFailed(it, SEND_FAILED) }
            }
            replyJob = job.takeIf { it.isActive }
            if (replyJob == null) pendingReply = null
        }

        private fun dropOpenUtterance() {
            vad.reset()
            audio.cancelTurn()
            openUtteranceId = null
            openEndFrame = null
            dropLive()
        }

        /** The open sentence was given up: its live session ends now, without waiting for a result. */
        private fun dropLive() {
            openLive?.close()
            openLive = null
        }

        /**
         * Recognition language changed: re-resolved through the serial gate (waits for the open live session to wrap up); utterances started afterwards are recognized in the new language; open / collected utterances
         * keep the method used when they started. The capture mode (self-record / local recording) is fixed at start; if re-resolution changes the method or it is unavailable, the original is kept.
         */
        fun recognitionLanguageChanged() {
            if (ended) return
            sttRefresh?.cancel()
            sttRefresh = scope.launch {
                val next = liveGate.withLock { sttSource.resolve() }
                // Start-up resolution has not settled yet: what it reads behind the gate is already the new language.
                if (ended || !::stt.isInitialized || next is ConversationStt.Unavailable) return@launch
                if ((next is ConversationStt.SelfRecord) != (stt is ConversationStt.SelfRecord)) return@launch
                stt = next
            }
        }

        /** A screen-reader utterance that is open when speech starts is discarded (live session ends, VAD clears the sentence); speaking again after reading finishes starts a new sentence. */
        fun screenReaderSpeaking(speaking: Boolean) {
            dispatch { ConversationEvent.ScreenReaderSpeaking(it, speaking) }
            if (speaking && !ended) dropOpenUtterance()
        }

        /** The later of the finish time from the reducer and the real audible end reported by TTS (the real end may still be in the future). */
        private fun notBeforeRealEnd(reducerAt: Long): Long = maxOf(reducerAt, playbackRealEndedAt ?: reducerAt)

        /** resetVad: discards the sentence and keeps the noise floor; [endedAtMs] is converted from the clock to a frame number (may be in the future), and the speaker lingering-sound window opens from that frame. */
        private fun resetVad(endedAtMs: Long?, keepOpen: Boolean = false) {
            if (!keepOpen) dropOpenUtterance()
            playbackEndedFrame = endedAtMs?.let {
                frameIndex + 1 + (it - clock()) / VoiceConversationConstants.FRAME_MS
            }
        }

        private fun transcribe(id: String) {
            val turn = turns[id] ?: closeOpenTurn(id)
            if (turn == null) {
                // Audio for this sentence is not found: reported as a recognition failure, so the reducer retries or prompts that it was not heard; it does not get stuck waiting for transcription.
                dispatch { ConversationEvent.SttFailed(it, id) }
                return
            }
            // The live session is used once: a retry after SttFailed goes to the file.
            val live = (turn as? TurnAudio.File)?.live
            (turn as? TurnAudio.File)?.live = null
            val job = scope.launch {
                // Diagnostics: the source of the recognized text and the recognizer error code for file recognition.
                var source = "none"
                var recognizerCode: Int? = null
                val result = when (turn) {
                    is TurnAudio.Recognized -> turn.result.also { source = "recognizer" }
                    is TurnAudio.File -> {
                        val file = turn.stt as? ConversationStt.FromFile
                        // Live text first; empty / failed / late falls back to the same audio through the file.
                        // Live text from a session that dropped audio may miss words: the file decides, and the live
                        // text stays only when the file gives nothing (same rule as dictationOutcome).
                        val heard = live?.result()
                        val trusted = heard?.takeUnless { it.droppedAudio }
                        if (trusted != null) turn.segment.cancel()
                        val segment = if (trusted != null) null else turn.segment.await()
                        if (trusted != null) {
                            source = "live"
                            STTResult.Success(trusted.text)
                        } else if (file == null || segment == null) {
                            if (heard != null) source = "live"
                            heard?.let { STTResult.Success(it.text) }
                        } else {
                            val fromFile = try {
                                file.engine.transcribe(segment, file.language)
                            } catch (error: CancellationException) {
                                throw error
                            } catch (_: Exception) {
                                null
                            }
                            val fileText = (fromFile as? STTResult.Success)?.text?.takeUnless { DictationRules.trim(it).isEmpty() }
                            recognizerCode = ((fromFile as? STTResult.Failed)?.failure as? DictationFailure.Recognizer)?.code
                            source = if (heard != null && fileText == null) "live" else "file"
                            if (heard != null && fileText == null) STTResult.Success(heard.text) else fromFile
                        }
                    }
                }
                transcribeJob = null
                diagnostics.transcribed(id, source, recognizerCode, (result as? STTResult.Success)?.text?.length ?: 0)
                if (result is STTResult.Success) {
                    turns.remove(id)?.let(::deleteTurn)
                    dispatch { ConversationEvent.SttResult(it, id, result.text) }
                } else {
                    dispatch { ConversationEvent.SttFailed(it, id) }
                }
            }
            transcribeJob = job.takeIf { it.isActive }
            // Cancelled before it ran (CancelGeneration / end): the live session still has to end.
            if (live != null) job.invokeOnCompletion { live.close() }
        }

        /** Audio for this sentence is collected and encoded only when Transcribe arrives (it includes audio from continuation periods, cut at the latest SpeechEnd frame). */
        private fun closeOpenTurn(id: String): TurnAudio? {
            if (id != openUtteranceId) return null
            val samples = audio.endTurn(openEndFrame ?: frameIndex)
            openUtteranceId = null
            openEndFrame = null
            val live = openLive?.takeIf { it.id == id }
            openLive = null
            val sentenceStt = openStt ?: stt
            openStt = null
            val segment = scope.async(start = CoroutineStart.LAZY) { samples?.let { audio.writeTurn(it) } }
            return TurnAudio.File(segment, live, sentenceStt).also { turns[id] = it }
        }

        /**
         * After VadSpeechEnd / VadDiscarded reduce and before effects run: the sentence the reducer is waiting on (about to Transcribe) or in a continuation wait is kept,
         * the rest are discarded. forceEnd arriving mid-dispatch is only enqueued, which is why this runs here rather than in onVad.
         * A sentence queued while waiting for transcription (its start or wrap-up still in pendingVad) is also kept for replay;
         * [keepSpeaking]: a sentence the reducer treats as speaking after replay is also kept.
         */
        private fun settleOpenTurn(keepSpeaking: Boolean = false) {
            val id = openUtteranceId ?: return
            if (state.awaitedUtteranceId == id || state.holdUtteranceId == id) return
            if (keepSpeaking && state.userSpeaking) return
            if (queuedOpenUtterance(id)) return
            openUtteranceId = null
            openEndFrame = null
            audio.cancelTurn()
            dropLive()
        }

        /**
         * A sentence moved into turns early by a queued wrap-up: if it is neither the one being waited on nor kept, and its wrap-up is not in the queue (cleared by abandon / silence / reset / end
         * queue clearing, or not picked up after replay), it will not be transcribed again: it is removed from turns, the live session ends, and the file is deleted (same as iOS).
         */
        private fun pruneQueuedTurns() {
            val iterator = queuedTurnIds.iterator()
            while (iterator.hasNext()) {
                val id = iterator.next()
                val turn = turns[id]
                if (turn == null) {
                    iterator.remove()
                    continue
                }
                if (state.awaitedUtteranceId == id || state.holdUtteranceId == id) continue
                if (state.pendingVad.any { it is ConversationEvent.VadSpeechEnd && it.utteranceId == id }) continue
                iterator.remove()
                turns.remove(id)
                (turn as? TurnAudio.File)?.let { file ->
                    file.live?.close()
                    file.live = null
                    if (!file.segment.isCompleted) file.segment.cancel()
                }
                deleteTurn(turn)
            }
        }

        /** This sentence's wrap-up is queued, or its start is the queue tail (not yet wrapped up). */
        private fun queuedOpenUtterance(id: String): Boolean =
            state.pendingVad.lastOrNull() is ConversationEvent.VadSpeechStart ||
                state.pendingVad.any { it is ConversationEvent.VadSpeechEnd && it.utteranceId == id }


        /** Model close and inference share one lock: dispatched to [io], and still runs after the session scope is cancelled. */
        private fun closeOffMain(model: SpeechProbModel) {
            this@VoiceConversationController.scope.launch(NonCancellable + io) { runCatching { model.close() } }
        }

        private fun deleteTurn(turn: TurnAudio) {
            if (turn is TurnAudio.File && turn.segment.isCompleted && !turn.segment.isCancelled) {
                val file = turn.segment.getCompleted()?.aac ?: return
                this@VoiceConversationController.scope.launch(NonCancellable + io) { runCatching { deleteFile(file) } }
            }
        }

        private fun transcribeToDraft() {
            val engine = (openStt.takeIf { openUtteranceId != null } ?: stt) as? ConversationStt.FromFile ?: return
            openUtteranceId = null
            openStt = null
            openEndFrame = null
            dropLive()
            val samples = audio.endTurn(frameIndex) ?: return
            this@VoiceConversationController.scope.launch {
                // Written outside the turn directory: closing the session must not delete the draft mid-write.
                val segment = audio.writeDraft(samples) ?: return@launch
                val result = runCatching { engine.engine.transcribe(segment, engine.language) }.getOrNull()
                withContext(NonCancellable + io) { runCatching { deleteFile(segment.aac) } }
                val text = (result as? STTResult.Success)?.text?.trim().orEmpty()
                if (text.isNotEmpty()) _events.tryEmit(VoiceConversationEvent.DraftTranscript(text))
            }
        }

        /**
         * While a reply is being spoken the prompt goes right after the current sentence, ahead of the rest of the
         * reply but behind prompts that arrived earlier (first in, first out); otherwise it queues.
         */
        private fun speakPrompt(which: VoicePrompt) {
            val item = Speech(prompt(which), prompt = true)
            if (state.phase == ConversationPhase.SPEAKING) {
                val firstSentence = queue.indexOfFirst { !it.prompt }
                queue.add(if (firstSentence < 0) queue.size else firstSentence, item)
            } else {
                queue.addLast(item)
            }
            pump()
        }

        private suspend fun playPrompt(text: String) {
            promptsPlaying++
            setCapturePaused(true)
            dropOpenUtterance()
            // The spoken prompt joins the echo pool; its end opens the echo window and the post-playback guard.
            dispatch { ConversationEvent.PromptStarted(it, text) }
            try {
                val outcome = voices.system.speak(text) { publishLevel(it) }
                playbackRealEndedAt = outcome.endedAtMs ?: clock()
            } finally {
                promptsPlaying--
                dispatch { ConversationEvent.PromptEnded(it) }
                if (promptsPlaying == 0 && !state.interrupted && !state.messagePlaying) setCapturePaused(false)
                syncSelfRecord()
            }
        }

        // ── playback ──

        /**
         * Drops the reply's sentences. Spoken prompts (queued or playing) stay unless [all]: stopping a reply must not
         * swallow e.g. the approval prompt; only the conversation's end clears them.
         */
        private fun clearSpeech(all: Boolean = false) {
            if (all) queue.clear() else queue.removeAll { !it.prompt }
            paused = false
            held = false
            val keep = !all && current?.prompt == true
            if (!keep) {
                current = null
                playbackJob?.cancel()
                playbackJob = null
                playbackStartFrame = null
            }
            drainedReported = true
            if (!all) pump()
        }

        private fun pump() {
            if (ended || paused || playbackJob != null) return
            val item = current ?: queue.removeFirstOrNull()
            if (item == null) {
                if (!drainedReported) {
                    drainedReported = true
                    dispatch { ConversationEvent.PlaybackDrained(it) }
                }
                return
            }
            if (current == null) {
                current = item
                currentReported = false
            }
            drainedReported = false
            if (!item.prompt) {
                if (playbackStartFrame == null) playbackStartFrame = frameIndex + 1
                if (!currentReported) {
                    currentReported = true
                    if (state.route == ConversationRoute.SPEAKER && state.speakerBargeIn && !selfRecord) {
                        exercisedSpeakerBargeIn = true
                    }
                    dispatch { ConversationEvent.SentenceStarted(it, item.text) }
                }
                if (ended || paused || playbackJob != null || current !== item) return
            }
            // Assigned before it starts: on an immediate dispatcher a synchronous speak result finishes the body
            // (and its own pump) before launch returns, which must not leave a completed job behind.
            val job = scope.launch(start = CoroutineStart.LAZY) {
                if (item.prompt) {
                    playPrompt(item.text)
                } else {
                    val voice = if (replyOnSystem) voices.system else voices.primary
                    speakingVoice = voice
                    var outcome = try {
                        voice.speak(item.text) { publishLevel(it) }
                    } finally {
                        if (speakingVoice === voice) speakingVoice = null
                    }
                    if (!outcome.done && voice.isCloud) {
                        if (!fallbackNoticed) {
                            fallbackNoticed = true
                            _events.tryEmit(VoiceConversationEvent.EngineFallback(voices.providerDisplayName))
                        }
                        replyOnSystem = true
                        val fallback = voices.system
                        speakingVoice = fallback
                        // Cloud failure while paused at a pause point: system sound also stays paused until resume.
                        if (held && !fallback.pause()) held = false
                        outcome = try {
                            fallback.speak(item.text) { publishLevel(it) }
                        } finally {
                            if (speakingVoice === fallback) speakingVoice = null
                        }
                    }
                    // A failed system sentence is skipped rather than retried.
                    playbackRealEndedAt = outcome.endedAtMs ?: clock()
                }
                if (playbackJob === coroutineContext[Job]) {
                    playbackJob = null
                    held = false
                }
                if (current === item) current = null
                pump()
            }
            playbackJob = job
            job.start()
        }

        // ── capture / VAD ──

        override fun onFrame(index: Long, db: Double) = onFrame(index, db, null)

        override fun onFrame(index: Long, db: Double, speechProb: Float?) {
            if (!frames.trySend(CapturedFrame(index, db, speechProb)).isSuccess) return
            val enqueued = enqueuedFrames.incrementAndGet()
            if (consuming) watchFrame(enqueued)
        }

        /**
         * On the capture thread: records the last enqueue time; when enqueued minus consumed exceeds [CONSUMER_LAG_FRAMES] frames, reports a backlog once and wraps up as a capture failure;
         * the watchdog is already started when the consumer coroutine starts (the first frame still starts it as a fallback). Wrap-up and diagnostics both run back on the host thread.
         */
        private fun watchFrame(enqueued: Long) {
            lastFrameAt = clock()
            val consumed = consumedFrames
            if (enqueued - consumed > CONSUMER_LAG_FRAMES && lagReported.compareAndSet(false, true)) {
                scope.launch {
                    if (ended) return@launch
                    diagnostics.consumerLag(diagClock(), enqueued, consumed)
                    onCaptureFailed()
                }
            }
            if (watchdogArmed.compareAndSet(false, true)) scope.launch { watchFrames() }
        }

        /**
         * Low-frequency watchdog (interval >= [FRAME_WATCHDOG_MIN_MS], normally wakes every [FRAME_STALL_MS]): if capture is running but more than [FRAME_STALL_MS]
         * passes without a new frame enqueued, reports a stall and wraps up as a capture failure. Time does not count during pause / mute / interruption. Ends with the session scope cancellation.
         */
        private suspend fun watchFrames() {
            while (!ended) {
                val now = clock()
                if (!captureRunning()) stallPausedAt = now
                val since = maxOf(lastFrameAt, stallPausedAt)
                if (now - since > FRAME_STALL_MS) {
                    diagnostics.captureStalled(diagClock(), lastFrameAt, enqueuedFrames.get())
                    onCaptureFailed()
                    return
                }
                delay(maxOf(FRAME_WATCHDOG_MIN_MS, since + FRAME_STALL_MS + 1 - now))
            }
        }

        private fun captureRunning(): Boolean = !capturePaused && !state.muted && !state.interrupted

        private fun setCapturePaused(paused: Boolean) {
            capturePaused = paused
            audio.setCapturePaused(paused)
            if (!paused) captureResumed()
        }

        /**
         * After a queued utterance is replayed: live captions that arrived while queued are already recorded in [LiveTurn.shown], so the same text is not dispatched again;
         * when the replayed sentence becomes speaking, it is dispatched once more, so the caption does not wait for the next change.
         */
        private fun recaptionReplayedUtterance() {
            if (!state.userSpeaking) return
            val id = openUtteranceId ?: return
            val caption = openLive?.takeIf { it.id == id }?.shown ?: return
            if (caption.isEmpty() || state.partialText == caption) return
            pending.addLast(ConversationEvent.SttPartial(clock(), caption))
        }

        /** Capture resumes (unpause / unmute / end interruption): the stall timer restarts from this moment. */
        private fun captureResumed() {
            if (frameWatchdog) stallPausedAt = clock()
        }

        private fun onCapturedFrame(index: Long, db: Double, speechProb: Float?) {
            if (ended) return
            frameIndex = index
            // In model mode a null probability means inference failed: the rest of the session is handed to a new energy-mode VAD.
            if (vadMode == VAD_MODE_MODEL && speechProb == null) fallBackToEnergy(index)
            // Energy mode ignores probabilities: the two are not mixed within a session.
            val prob = speechProb.takeIf { vadMode == VAD_MODE_MODEL }
            lastProb = prob
            // Diagnostics: samples one frame every 500 ms (counting only, no allocation).
            if (++levelSampleFrames >= VoiceConversationDiagnostics.LEVEL_SAMPLE_FRAMES) {
                levelSampleFrames = 0
                val inferenceUs = speechModel?.let { it.lastInferenceNanos / 1_000 }
                diagnostics.level(index, db, vad.floorDb, vad.isSpeaking, prob, vadMode, inferenceUs)
            }
            if (state.phase == ConversationPhase.LISTENING && !state.muted) {
                publishLevel(ConversationFrames.levelFromDb(db, vad.floorDb))
            }
            // Nothing the screen reader says is treated as the user speaking.
            if (state.screenReaderSpeaking) return
            val pb = playbackStartFrame.takeIf { state.phase == ConversationPhase.SPEAKING }
            // While speaking through the speaker, only the candidate window is checked; the lingering-sound window applies only when no new playback has started.
            vad.step(index, db, state.route, pb, playbackEndedFrame.takeIf { pb == null }, prob?.toDouble())?.let(::onVad)
        }

        /**
         * Inference fails midway: switches only once and does not return to the model. The new instance is a fresh segment and is not mixed with model frames;
         * the sentence being spoken is discarded by VAD reset (the reducer receives VadDiscarded and gives up that sentence).
         */
        private fun fallBackToEnergy(index: Long) {
            vadMode = VAD_MODE_ENERGY
            lastProb = null
            diagnostics.vadMode(VAD_MODE_ENERGY, "inference_failed")
            if (vad.isSpeaking) {
                onVad(VadEvent.Discarded(index))
                dropOpenUtterance()
            }
            vad = VoiceConversationVad()
            // After close the capture thread feeds null and no more inference runs; close waits for the inference lock, which is not waited on the main thread.
            speechModel?.let(::closeOffMain)
            speechModel = null
        }

        private fun onVad(event: VadEvent) {
            when (event) {
                is VadEvent.SpeechStart ->
                    diagnostics.vadStart(event.frame, event.prerollFrame, vad.floorDb, lastProb, vadMode)
                is VadEvent.SpeechEnd ->
                    diagnostics.vadEnd(event.frame, vad.floorDb, event.voicedMs, event.reason.rawValue, lastProb, vadMode)
                is VadEvent.Discarded -> diagnostics.vadDiscarded(event.frame, vad.floorDb)
            }
            when (event) {
                is VadEvent.SpeechStart -> {
                    continuedOpenUtterance = false
                    var start: ConversationEvent? = null
                    dispatch { ConversationEvent.VadSpeechStart(it).also { e -> start = e } }
                    // Continuation: no audio for the same sentence has been collected yet, so recording continues.
                    if (continuedOpenUtterance) return
                    // A start queued while waiting for transcription still begins recording as usual; after transcription settles, replay decides whether to keep or drop it.
                    val queued = start != null && state.pendingVad.lastOrNull() === start
                    // Speech the reducer didn't take is not recorded.
                    if (!state.userSpeaking && !queued) return
                    audio.beginTurn(event.prerollFrame)
                    val id = "u${++utteranceSeq}"
                    openUtteranceId = id
                    openEndFrame = null
                    openStt = stt
                    startLive(id)
                    // Counts as an interruption only inside the candidate window (from reply start to finish / stop / pause).
                    if (state.phase == ConversationPhase.SPEAKING && playbackStartFrame != null) {
                        dispatch { ConversationEvent.BargeInDetected(it) }
                    }
                }
                is VadEvent.SpeechEnd -> {
                    // No audio is collected here: a finalized utterance goes through Transcribe, is kept during a continuation wait, and the rest are discarded in settleOpenTurn.
                    val id = openUtteranceId ?: "u${++utteranceSeq}"
                    if (openUtteranceId != null) openEndFrame = event.frame
                    var end: ConversationEvent? = null
                    dispatch { ConversationEvent.VadSpeechEnd(it, id, event.voicedMs).also { e -> end = e } }
                    // A wrap-up queued while waiting for transcription is moved into turns on the spot: a later start does not overwrite it, and the replayed Transcribe uses it directly.
                    if (end != null && state.pendingVad.any { it === end } && closeOpenTurn(id) != null) queuedTurnIds += id
                }
                is VadEvent.Discarded -> dispatch { ConversationEvent.VadDiscarded(it) }
            }
        }

        /** System pipe route: the new sentence gets its own live session, fed from the turn's preroll on. */
        private fun startLive(id: String) {
            dropLive()
            val fromFile = stt as? ConversationStt.FromFile
            val open = fromFile?.live ?: return
            val route = fromFile.liveRoute
            diagnostics.liveStart(id, route?.recognizer?.name, null, route?.languageTag ?: fromFile.language)
            val live = LiveTurn(id, open)
            openLive = live
            audio.tapTurn(live.preroll)
            live.begin()
        }

        /**
         * One sentence's live recognition. Frames queue in [preroll] (≤ 10 s) until the session is open, then follow
         * it directly; the session holds [liveGate] from opening until it is closed. Main thread only.
         */
        inner class LiveTurn(val id: String, private val open: suspend () -> DictationLiveSession?) {
            val preroll = DictationLivePreroll()
            private val ready = CompletableDeferred<DictationLiveSession?>()
            private var session: DictationLiveSession? = null
            private var holdsGate = false
            private var closed = false
            var shown = ""
                private set
            private val starter = scope.launch(start = CoroutineStart.LAZY) { openSession() }

            fun begin() {
                starter.start()
            }

            private suspend fun openSession() {
                liveGate.lock()
                holdsGate = true
                val openedAt = diagClock()
                var failure = "null_session"
                val live = try {
                    open()
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Exception) {
                    failure = error.javaClass.simpleName
                    null
                }
                if (live == null || closed) {
                    diagnostics.liveOpenFailed(id, diagClock() - openedAt, if (live == null) failure else "closed")
                    live?.cancel()
                    giveUp()
                    return
                }
                session = live
                // Feeding the backlog may block until the session has room: not on the main thread.
                val attached = withContext(io) { preroll.attach(live) }
                if (!attached || closed) {
                    diagnostics.liveOpenFailed(id, diagClock() - openedAt, if (!attached) "attach_failed" else "closed")
                    giveUp()
                    return
                }
                diagnostics.liveOpened(id, diagClock() - openedAt)
                ready.complete(live)
                live.live.collect(::onTranscript)
            }

            /** Opening failed: this sentence falls back to the file; the gate opens for the next one. */
            private fun giveUp() {
                session?.cancel()
                session = null
                preroll.close()
                ready.complete(null)
                releaseGate()
            }

            private fun onTranscript(transcript: LiveTranscript) {
                diagnostics.transcript(
                    id,
                    diagClock(),
                    transcript.finals.sumOf { it.length },
                    transcript.partial.length,
                )
                if (closed || openLive !== this) return
                val text = LiveDictationRules.livePartial(transcript.finals, transcript.partial).text
                if (text == shown) return
                shown = text
                dispatch { ConversationEvent.SttPartial(it, text) }
            }

            /**
             * Stops the session and waits a bounded time; the success with non-empty text (it may carry droppedAudio),
             * or null (empty / failed / late / none).
             */
            suspend fun result(): STTResult.Success? = try {
                withTimeoutOrNull(LIVE_RESULT_TIMEOUT_MS) {
                    val live = ready.await() ?: return@withTimeoutOrNull null
                    live.stop()
                    (live.await() as? STTResult.Success)?.takeUnless { DictationRules.trim(it.text).isEmpty() }
                }
            } finally {
                close()
            }

            /** Ends the session now (no result wanted, or the result is in). Idempotent. */
            fun close() {
                if (closed) return
                closed = true
                starter.cancel()
                preroll.close()
                session?.cancel()
                session = null
                ready.complete(null)
                releaseGate()
            }

            private fun releaseGate() {
                if (!holdsGate) return
                holdsGate = false
                liveGate.unlock()
            }
        }

        // ── self-record turns (API < 33 system recognizer) ──

        private fun syncSelfRecord() {
            if (!selfRecord || ended) return
            val want = state.phase == ConversationPhase.LISTENING && !state.muted && !state.interrupted &&
                !state.messagePlaying && promptsPlaying == 0
            if (want && selfTurnJob == null) {
                val source = stt as ConversationStt.SelfRecord
                // Mic stays off for 800 ms after playback ends: the recognizer records itself, and lingering sound would be taken as the user speaking.
                val openAt = state.playbackEndedAtMs
                    ?.let(::notBeforeRealEnd)
                    ?.plus(VoiceConversationConstants.POST_PLAYBACK_GUARD_MS)
                    ?.takeIf { it > clock() }
                selfTurnJob = scope.launch {
                    if (openAt != null) delay(openAt - clock())
                    val turn = try {
                        source.startTurn()
                    } catch (error: CancellationException) {
                        throw error
                    } catch (_: Exception) {
                        null
                    }
                    if (turn == null) {
                        selfTurnJob = null
                        dispatch { ConversationEvent.End(it, EndReason.SYSTEM) }
                        return@launch
                    }
                    selfTurn = turn
                    turn.onRmsDb = { db -> onSelfRecordRms(turn, db) }
                    // Bounded wait: if the recognizer never calls back, it times out (busy) and the failure goes to the reducer.
                    val result = withTimeoutOrNull(SELF_RECORD_AWAIT_MS) { turn.await() } ?: run {
                        turn.interrupt()
                        STTResult.Failed(DictationFailure.Timeout, DictationPrimaryAction.Retry)
                    }
                    selfTurn = null
                    selfTurnJob = null
                    onSelfRecordResult(result, turn.voicedMs)
                }
            } else if (!want && selfTurnJob != null) {
                selfTurn?.interrupt()
                selfTurn = null
                selfTurnJob?.cancel()
                selfTurnJob = null
            }
        }

        private fun onSelfRecordRms(turn: SelfRecordTurn, db: Float) {
            if (ended || selfTurn !== turn) return
            if (state.phase == ConversationPhase.LISTENING && !state.muted) {
                publishLevel(DictationLevelMeter.recognizerLevel(db))
            }
        }

        private fun onSelfRecordResult(result: STTResult, voicedMs: Int) {
            // Empty result but the recognizer heard voice: reported to the reducer (not heard / check language); only when there was no voice at all is capture silently reopened.
            if (result is STTResult.Success && DictationRules.trim(result.text).isEmpty() && voicedMs <= 0) {
                syncSelfRecord()
                return
            }
            val id = "u${++utteranceSeq}"
            turns[id] = TurnAudio.Recognized(result)
            dispatch { ConversationEvent.VadSpeechStart(it) }
            dispatch { ConversationEvent.VadSpeechEnd(it, id, voicedMs) }
        }

        // ── chat ──

        private fun onReply(event: VoiceReplyEvent) {
            when (event) {
                is VoiceReplyEvent.Text -> emitSentences(speakableSegments(event.full, final = false))
                is VoiceReplyEvent.Completed -> {
                    // Completed carries no text: the last Text is final once the stream ends.
                    lastReplyText?.let { emitSentences(speakableSegments(it, final = true)) }
                    dispatch { at ->
                        ConversationEvent.ReplyCompleted(at)
                    }
                }
                is VoiceReplyEvent.Failed -> dispatch { ConversationEvent.ReplyFailed(it, event.code) }
                is VoiceReplyEvent.ApprovalPending -> dispatch {
                    if (event.pending) ConversationEvent.ApprovalPending(it) else ConversationEvent.ApprovalResolved(it)
                }
            }
            if (event is VoiceReplyEvent.Text) lastReplyText = event.full
            if (event !is VoiceReplyEvent.Text && event !is VoiceReplyEvent.ApprovalPending) lastReplyText = null
        }

        private var lastReplyText: String? = null

        /** Only newly closed sentences are enqueued (prefix-stable segmentation). */
        private fun emitSentences(segments: List<SpeakableSegment>) {
            if (segments.size <= replyEmitted) return
            val fresh = segments.subList(replyEmitted, segments.size).toList()
            replyEmitted = segments.size
            for (segment in fresh) {
                val text = when (segment) {
                    is SpeakableSegment.Sentence -> segment.text
                    is SpeakableSegment.Placeholder -> prompt(VoicePrompt.Placeholder(segment.kind))
                }
                dispatch { ConversationEvent.ReplySentence(it, text) }
            }
        }

        // ── audio listener (main thread) ──

        override fun onRouteChanged(route: ConversationRoute, privateRouteRemoved: Boolean) {
            dispatch { ConversationEvent.RouteChanged(it, route) }
        }

        /** Becoming noisy = the private route is going away; the reducer stops the sentence. */
        override fun onBecomingNoisy() {
            if (state.route != ConversationRoute.SPEAKER) {
                dispatch { ConversationEvent.RouteChanged(it, ConversationRoute.SPEAKER) }
            }
        }

        override fun onCaptureStats(reads: Long, zeroReads: Long, errorReads: Long) {
            diagnostics.captureStats(diagClock(), reads, zeroReads, errorReads)
        }

        override fun onCaptureStopped(reason: String) {
            diagnostics.captureStopped(diagClock(), reason)
        }

        override fun onSinkGate(paused: Boolean, muted: Boolean, live: Boolean) {
            diagnostics.sinkGate(diagClock(), paused, muted, live)
        }

        override fun onInterruption(began: Boolean) {
            dispatch { if (began) ConversationEvent.InterruptionBegan(it) else ConversationEvent.InterruptionEnded(it) }
            if (!began) captureResumed()
        }

        override fun onFocusLost() {
            dispatch { ConversationEvent.End(it, EndReason.SYSTEM) }
        }

        override fun onCaptureFailed() {
            dispatch { ConversationEvent.End(it, EndReason.SYSTEM) }
        }

        /** Activation failure during start-up is handled by awaitActivation in startSession; once started, it wraps up as a capture failure. */
        override fun onActivationFailed() {
            if (ended || startedAt == null) return
            onCaptureFailed()
        }

        // ── teardown ──

        fun finish(reason: EndReason, code: String?, report: Boolean = true) {
            if (ended) return
            ended = true
            RealtimeVoiceLog.d("cascade end: reason=$reason code=$code")
            if (session === this) session = null
            selfTurn?.interrupt()
            dropLive()
            background?.close()
            clearSpeech(all = true)
            consuming = false
            frames.close()
            deadlineJob?.cancel()
            deadlineJob = null
            armedDeadlineAt = null
            if (audioOpened) audio.close()
            // The capture thread may still feed frames while wrapping up on IO: the model's feed and close share one lock, and feed gets null after close; the lock is not waited on the main thread.
            speechModel?.let(::closeOffMain)
            if (::voices.isInitialized) setOf(voices.primary, voices.system).forEach { it.release() }
            foreground.stop()
            if (report) memory.conversationEnded(fellBackToTap, exercisedSpeakerBargeIn)
            scope.cancel()
            _displayState.value = displayState(state)
            _statusKey.value = statusKey(state)
            _caption.value = caption(state).orEmpty()
            windowPeak = 0f
            _level.value = 0f
            _active.value = false
            if (report) _events.tryEmit(VoiceConversationEvent.Ended(reason, code))
        }
    }

    companion object {
        /** ≤ 15 level updates per second. */
        const val LEVEL_INTERVAL_MS = 67L
        const val SEND_FAILED = "send_failed"

        /** Wait limit for a self-recorded utterance: the longest utterance of 60 s plus the time limit for fetching the result after stopping recording. */
        const val SELF_RECORD_AWAIT_MS = 60_000L + SystemSTTEngine.STOP_RESULT_TIMEOUT_MS

        /** Limit for fetching the result after live recognition stops; after it, the same audio goes through file recognition. */
        const val LIVE_RESULT_TIMEOUT_MS = 1_500L

        /** Limit for waiting for the speech probability model to be ready before capture starts. */
        const val SPEECH_MODEL_WAIT_MS = 500L

        /** Frame consumer backlog limit: when enqueued minus consumed exceeds it (frames worth 1.5 s), wraps up as a capture failure. */
        const val CONSUMER_LAG_FRAMES = 1_500 / VoiceConversationConstants.FRAME_MS

        /** If capture is running but no new frame is enqueued for this long, wraps up as a stall. */
        const val FRAME_STALL_MS = 1_500L

        /** Minimum interval between two watchdog checks. */
        const val FRAME_WATCHDOG_MIN_MS = 500L
        const val VAD_MODE_MODEL = "model"
        const val VAD_MODE_ENERGY = "energy"
    }
}

// ───────────── Production sources ─────────────

/**
 * STT for the conversation, resolved with the dictation settings and engines: cloud when the dictation
 * selection resolves to an accepted cloud engine, otherwise the system route (pipe = file turns, self-record =
 * recognizer turns). Side-effect free: fallback rewrites and notices stay with dictation's own use site.
 * The language pack offer (route.languagePackOffer) belongs to dictation only: a conversation never offers it (as iOS).
 */
class DictationConversationSttSource(
    private val engines: DictationEngineFactory,
    private val settings: VoiceEngineSettings,
    private val catalog: DictationCatalogSource,
    private val providers: suspend () -> List<Provider>,
    private val language: () -> String?,
    private val disclosure: VoiceDisclosureStore = settings.disclosure,
    private val catalogTimeoutMillis: Long = DictationController.CATALOG_REFRESH_TIMEOUT_MILLIS,
) : ConversationSttSource {
    override suspend fun resolve(): ConversationStt {
        val lang = language()
        cloud()?.let { (engine, kind) -> return ConversationStt.FromFile(engine, lang, kind) }
        return when (val route = engines.systemRoute(lang)) {
            SystemSTTRoute.Unavailable -> ConversationStt.Unavailable
            is SystemSTTRoute.Pipe -> ConversationStt.FromFile(
                engines.system(),
                lang,
                live = { engines.startPipeSession(route) },
                liveRoute = route,
            )
            is SystemSTTRoute.SelfRecord -> ConversationStt.SelfRecord {
                val session = engines.startSelfRecordTurn(route)
                object : SelfRecordTurn {
                    override var onRmsDb: ((Float) -> Unit)?
                        get() = session.onLevel
                        set(value) {
                            session.onLevel = value
                        }

                    override val voicedMs: Int get() = session.voicedMs

                    override suspend fun await(): STTResult = session.await()

                    override fun interrupt() = session.interrupt()
                }
            }
        }
    }

    private suspend fun cloud(): Pair<STTEngine, String>? {
        val selection = settings.selection(VoiceDirection.Stt) as? VoiceEngineSelection.Cloud ?: return null
        // Same as dictation: the cache read (which waits on the directory lock) and the cold fetch share a 10 s total limit; on timeout it is treated as the catalog being unavailable and falls back to system recognition.
        val voiceCatalog = withTimeoutOrNull(catalogTimeoutMillis) {
            catalog.loadCached() ?: (catalog.refresh() as? VoiceCatalogState.Available)?.catalog
        } ?: return null
        val connections = providers()
        val resolution = VoiceEngineResolver.resolve(
            catalog = voiceCatalog,
            direction = VoiceDirection.Stt,
            selection = selection,
            connections = connections.map(VoiceConnection::from),
        )
        val resolved = resolution.engine as? VoiceEngine.Cloud ?: return null
        if (!disclosure.isAccepted(resolved.providerKind, VoiceDirection.Stt)) return null
        val provider = connections.firstOrNull { it.id == resolved.connectionId } ?: return null
        val entry = voiceCatalog.entry(resolved.providerKind, VoiceDirection.Stt, resolved.model) as? VoiceSttEntry
            ?: return null
        return engines.cloud(
            entry = entry,
            baseUrl = EndpointResolver.resolveBaseUrl(provider),
            apiKey = ProviderCredentialResolver.apiKey(provider, null),
        ) to resolved.providerKind.rawValue
    }
}

/** TTS for the conversation from the read-aloud engine choice: cloud keeps its cache / request, played here. */
class ReadAloudConversationTtsSource(
    private val readAloud: ReadAloudEngineSource,
    private val system: ConversationTts,
    private val cloud: (CloudSpeechEngine) -> ConversationTts,
) : ConversationTtsSource {
    override suspend fun pick(): ConversationVoices {
        val choice = readAloud.pick()
        val engine = choice.engine as? CloudSpeechEngine
            ?: return ConversationVoices(system, system, fallbackReason = choice.fallbackReason)
        return ConversationVoices(cloud(engine), system, engine.providerDisplayName, choice.fallbackReason)
    }
}

/** One playback queue item: a reply sentence (primary voice) or a spoken prompt (system voice). */
private class Speech(val text: String, val prompt: Boolean)

/** One frame sent from the capture thread to the host: sequence number, level, speech probability (null = no model). */
private class CapturedFrame(val index: Long, val db: Double, val prob: Float?)

/** Hands the model loaded on IO to the session; a result that arrives after [take] is closed on the spot by the loader. */
private class SpeechModelHandoff {
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

    /** Stops accepting; returns the result that has arrived (the caller takes over the model in it), or null if none has arrived. */
    fun take(): Result<SpeechProbModel>? = synchronized(this) {
        taken = true
        result.also { result = null }
    }
}

/** User text of a send / amend that a cancel stopped before it went out; [send] = it was a new turn. */
private data class CarriedReply(val text: String, val send: Boolean)
