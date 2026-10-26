package ai.oriveo.community.core.voice.conversation

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
import ai.oriveo.community.core.voice.DictationEngineFactory
import ai.oriveo.community.core.voice.DictationLevelMeter
import ai.oriveo.community.core.voice.ReadAloudEngineSource
import ai.oriveo.community.core.voice.STTEngine
import ai.oriveo.community.core.voice.STTResult
import ai.oriveo.community.core.voice.SpeakablePlaceholder
import ai.oriveo.community.core.voice.SpeakableSegment
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

    val replies: Flow<VoiceReplyEvent>

    fun cancel()
}

/** Text the controller speaks or shows that comes from localized resources. */
sealed interface VoicePrompt {
    data object DidNotCatch : VoicePrompt
    data object ApprovalNeeded : VoicePrompt
    data class Placeholder(val kind: SpeakablePlaceholder) : VoicePrompt
}

/** A self-recording recognizer turn (system recognizer opens the mic itself; API < 33 path). */
interface SelfRecordTurn {
    /** Recognizer onRmsChanged (dB, recognizer scale); drives the listening level since there is no PCM. */
    var onRmsDb: ((Float) -> Unit)?

    suspend fun await(): STTResult

    fun interrupt()
}

/** How this conversation transcribes, resolved once at start with the dictation engine settings. */
sealed interface ConversationStt {
    /** [providerKind] = the cloud STT entry's provider kind ; null = system engine. */
    data class FromFile(val engine: STTEngine, val language: String?, val providerKind: String? = null) : ConversationStt

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
 * Per-device memory of "speaker playback can't be voice-interrupted" : set after
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

    /** TTS engine resolution fell back at start. */
    data class TtsSelectionFallback(val reason: VoiceFallbackReason) : VoiceConversationEvent

    /** Self-recording path paused because the app went to the background . */
    data object PausedInBackground : VoiceConversationEvent

    /** Ended with ✕ while the user was speaking: the transcript goes to the draft. */
    data class DraftTranscript(val text: String) : VoiceConversationEvent

    data class Ended(val reason: EndReason, val code: String?) : VoiceConversationEvent
}

enum class StartFailure { FOREGROUND, STT_UNAVAILABLE, AUDIO }

// ───────────── Controller ─────────────

/**
 * Voice conversation host: turns audio, STT, chat and TTS signals into [ConversationEvent]s, folds them with
 * [reduce] and executes the effects. One conversation at a time; public methods on the main thread.
 * The host starts [VoiceConversationService] (via [VoiceConversationServiceStarter]) before [start]; the controller
 * waits for the foreground service before it requests audio focus .
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
) : VoiceConversationEngine {
    private val _displayState = MutableStateFlow<ConversationDisplayState?>(null)
    private val _statusKey = MutableStateFlow<ConversationStatusKey?>(null)
    private val _level = MutableStateFlow(0f)
    private val _active = MutableStateFlow(false)
    private val _events = MutableSharedFlow<VoiceConversationEvent>(extraBufferCapacity = 16)

    /** The only thing the voice bar reads . */
    val displayState: StateFlow<ConversationDisplayState?> = _displayState.asStateFlow()
    override val statusKey: StateFlow<ConversationStatusKey?> = _statusKey.asStateFlow()

    /** Orb level 0…1: mic while listening, TTS output while speaking; at most ~15 updates per second. */
    override val level: StateFlow<Float> = _level.asStateFlow()
    override val active: StateFlow<Boolean> = _active.asStateFlow()
    override val events: SharedFlow<VoiceConversationEvent> = _events.asSharedFlow()

    private var session: Session? = null

    @Volatile private var lastLevelAt = Long.MIN_VALUE / 2

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
     * plays an earlier message with the conversation's own voice while listening (capture paused, back to
     * listening when done). Ignored outside listening, like the reducer.
     */
    fun playMessage(messageId: String, text: String) {
        val s = session ?: return
        s.messageTexts[messageId] = text
        s.dispatch { ConversationEvent.PlayMessage(it, messageId) }
    }

    /** the screen reader is speaking the status word; capture is not processed meanwhile. */
    override fun screenReaderSpeaking(speaking: Boolean) {
        session?.dispatch { ConversationEvent.ScreenReaderSpeaking(it, speaking) }
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

    private fun publishLevel(value: Float, force: Boolean = false) {
        val now = clock()
        if (!force && now - lastLevelAt < levelIntervalMs) return
        lastLevelAt = now
        _level.value = value
    }

    private sealed interface TurnAudio {
        class File(val segment: Deferred<ai.oriveo.community.core.voice.STTSegment?>) : TurnAudio
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
        private val vad = VoiceConversationVad()
        private val frames = Channel<Pair<Long, Double>>(Channel.UNLIMITED)
        private var frameIndex = -1L
        private var utteranceSeq = 0
        private val turns = HashMap<String, TurnAudio>()
        private var transcribeJob: Job? = null

        // Playback
        // Reply sentences and spoken prompts share one queue, so the two never talk over each other.
        private val queue = ArrayDeque<Speech>()
        private var current: Speech? = null
        private var currentReported = false
        private var paused = false
        private var playbackJob: Job? = null
        private var playbackStartFrame: Long? = null
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


        // Memory
        private var fellBackToTap = false
        private var exercisedSpeakerBargeIn = false
        private var promptsPlaying = 0

        suspend fun run() {
            if (!foreground.awaitStarted()) return failStart(StartFailure.FOREGROUND)
            stt = sttSource.resolve()
            if (stt is ConversationStt.Unavailable) return failStart(StartFailure.STT_UNAVAILABLE)
            voices = ttsSource.pick()
            voices.fallbackReason?.let { _events.tryEmit(VoiceConversationEvent.TtsSelectionFallback(it)) }
            selfRecord = stt is ConversationStt.SelfRecord
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
            val remembers = memory.load() || !audio.echoCancellerAvailable || selfRecord
            if (ended) return
            scope.launch { for ((index, db) in frames) onCapturedFrame(index, db) }
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
                    state = r.state
                    if (event is ConversationEvent.VadSpeechEnd) settleTurn(event.utteranceId)
                    publish()
                    for (effect in r.effects) {
                        if (ended) break
                        execute(effect)
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

        private fun publish() {
            _displayState.value = displayState(state)
            _statusKey.value = statusKey(state)
            if (state.phase != ConversationPhase.LISTENING && state.phase != ConversationPhase.SPEAKING) {
                publishLevel(0f, force = true)
            }
        }

        // ── effects ──

        private fun execute(effect: ConversationEffect) {
            when (effect) {
                ConversationEffect.StartCapture -> Unit
                is ConversationEffect.Transcribe -> transcribe(effect.utteranceId)
                is ConversationEffect.SendMessage -> {
                    replyEmitted = 0
                    replyOnSystem = false
                    lastReplyText = null
                    scope.launch {
                        val sent = try {
                            chat.send(effect.text)
                        } catch (error: CancellationException) {
                            throw error
                        } catch (_: Exception) {
                            false
                        }
                        if (!sent) dispatch { ConversationEvent.ReplyFailed(it, SEND_FAILED) }
                    }
                }
                ConversationEffect.CancelGeneration -> {
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
                    playbackJob?.cancel()
                    playbackJob = null
                    playbackStartFrame = null
                }
                // Both resume points restart the paused sentence from its beginning.
                is ConversationEffect.ResumePlayback -> {
                    paused = false
                    pump()
                }
                ConversationEffect.StopPlayback -> clearSpeech()
                is ConversationEffect.SpeakPrompt -> speakPrompt(
                    when (effect.prompt) {
                        VoicePromptKind.DID_NOT_CATCH -> VoicePrompt.DidNotCatch
                        VoicePromptKind.APPROVAL_NEEDED -> VoicePrompt.ApprovalNeeded
                    },
                )
                // Outer scope: the end earcon outlives the session it closes.
                is ConversationEffect.Earcon -> this@VoiceConversationController.scope.launch {
                    runCatching { audio.playEarcon(effect.kind) }
                }
                is ConversationEffect.EndConversation -> finish(effect.reason, effect.code)
                ConversationEffect.RememberFalseBargeInConversation -> fellBackToTap = true
                ConversationEffect.ForceEndUtterance -> vad.forceEnd(frameIndex)?.let(::onVad)
                is ConversationEffect.SetCaptureMuted -> {
                    audio.setMuted(effect.muted)
                    dropOpenUtterance()
                }
                ConversationEffect.PauseCapture -> {
                    audio.setCapturePaused(true)
                    dropOpenUtterance()
                }
                ConversationEffect.ResumeCapture -> audio.setCapturePaused(false)
                is ConversationEffect.PlayMessage -> playMessage(effect.messageId)
                ConversationEffect.TranscribeToDraft -> transcribeToDraft()
            }
        }

        /** the earlier message is spoken sentence by sentence with the conversation's voice. */
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

        private fun dropOpenUtterance() {
            vad.resetUtterance()
            audio.cancelTurn()
        }

        private fun transcribe(id: String) {
            val turn = turns[id] ?: return
            transcribeJob = scope.launch {
                val result = when (turn) {
                    is TurnAudio.Recognized -> turn.result
                    is TurnAudio.File -> {
                        val file = (stt as? ConversationStt.FromFile)
                        val segment = turn.segment.await()
                        if (file == null || segment == null) {
                            null
                        } else {
                            try {
                                file.engine.transcribe(segment, file.language)
                            } catch (error: CancellationException) {
                                throw error
                            } catch (_: Exception) {
                                null
                            }
                        }
                    }
                }
                transcribeJob = null
                if (result is STTResult.Success) {
                    turns.remove(id)?.let(::deleteTurn)
                    dispatch { ConversationEvent.SttResult(it, id, result.text) }
                } else {
                    dispatch { ConversationEvent.SttFailed(it, id) }
                }
            }
        }

        /** Right after [ConversationEvent.VadSpeechEnd] reduces: encode the awaited file turn, drop any other. */
        private fun settleTurn(id: String) {
            val turn = turns[id] as? TurnAudio.File ?: return
            if (state.awaitedUtteranceId == id) {
                turn.segment.start()
            } else {
                turns.remove(id)
                turn.segment.cancel()
            }
        }

        private fun deleteTurn(turn: TurnAudio) {
            if (turn is TurnAudio.File && turn.segment.isCompleted) {
                val file = turn.segment.getCompleted()?.aac ?: return
                this@VoiceConversationController.scope.launch(NonCancellable + io) { runCatching { deleteFile(file) } }
            }
        }

        private fun transcribeToDraft() {
            val engine = stt as? ConversationStt.FromFile ?: return
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

        /** While a reply is being spoken the prompt goes next (after the current sentence); otherwise it queues. */
        private fun speakPrompt(which: VoicePrompt) {
            val item = Speech(prompt(which), prompt = true)
            if (state.phase == ConversationPhase.SPEAKING) queue.addFirst(item) else queue.addLast(item)
            pump()
        }

        private suspend fun playPrompt(text: String) {
            promptsPlaying++
            audio.setCapturePaused(true)
            dropOpenUtterance()
            try {
                voices.system.speak(text) { publishLevel(it) }
            } finally {
                promptsPlaying--
                if (promptsPlaying == 0 && !state.interrupted && !state.messagePlaying) audio.setCapturePaused(false)
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
            if (item.prompt) {
                playbackStartFrame = null
            } else {
                playbackStartFrame = frameIndex + 1
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
                    val outcome = voice.speak(item.text) { publishLevel(it) }
                    if (outcome == TtsOutcome.FAILED && voice.isCloud) {
                        if (!fallbackNoticed) {
                            fallbackNoticed = true
                            _events.tryEmit(VoiceConversationEvent.EngineFallback(voices.providerDisplayName))
                        }
                        replyOnSystem = true
                        voices.system.speak(item.text) { publishLevel(it) }
                    }
                    // A failed system sentence is skipped rather than retried.
                }
                if (playbackJob === coroutineContext[Job]) {
                    playbackJob = null
                    playbackStartFrame = null
                }
                if (current === item) current = null
                pump()
            }
            playbackJob = job
            job.start()
        }

        // ── capture / VAD ──

        override fun onFrame(index: Long, db: Double) {
            frames.trySend(index to db)
        }

        private fun onCapturedFrame(index: Long, db: Double) {
            if (ended) return
            frameIndex = index
            if (state.phase == ConversationPhase.LISTENING && !state.muted) {
                publishLevel(ConversationFrames.levelFromDb(db))
            }
            // nothing the screen reader says is treated as the user speaking.
            if (state.screenReaderSpeaking) return
            val pb = playbackStartFrame.takeIf { state.phase == ConversationPhase.SPEAKING }
            vad.step(index, db, state.route, pb)?.let(::onVad)
        }

        private fun onVad(event: VadEvent) {
            when (event) {
                is VadEvent.SpeechStart -> {
                    audio.beginTurn(event.prerollFrame)
                    dispatch { ConversationEvent.VadSpeechStart(it) }
                    // Speech the reducer didn't take is not recorded.
                    if (!state.userSpeaking) {
                        audio.cancelTurn()
                        return
                    }
                    if (state.phase == ConversationPhase.SPEAKING) dispatch { ConversationEvent.BargeInDetected(it) }
                }
                is VadEvent.SpeechEnd -> {
                    val id = "u${++utteranceSeq}"
                    if (!state.userSpeaking) {
                        audio.cancelTurn()
                        dispatch { ConversationEvent.VadSpeechEnd(it, id) }
                        return
                    }
                    val samples = audio.endTurn(event.frame)
                    // Lazy: AAC is only encoded for an utterance the reducer awaits (or when transcribe awaits it).
                    val segment = scope.async(start = CoroutineStart.LAZY) { samples?.let { audio.writeTurn(it) } }
                    turns[id] = TurnAudio.File(segment)
                    // Whether the reducer awaits it is settled once it reduces this event ([settleTurn]): a forced end
                    // from a tap arrives here mid-dispatch, so the event is only queued at this point.
                    dispatch { ConversationEvent.VadSpeechEnd(it, id) }
                }
                is VadEvent.Discarded -> {
                    audio.cancelTurn()
                    dispatch { ConversationEvent.VadDiscarded(it) }
                }
            }
        }

        // ── self-record turns (API < 33 system recognizer) ──

        private fun syncSelfRecord() {
            if (!selfRecord || ended) return
            val want = state.phase == ConversationPhase.LISTENING && !state.muted && !state.interrupted &&
                !state.messagePlaying && promptsPlaying == 0
            if (want && selfTurnJob == null) {
                val source = stt as ConversationStt.SelfRecord
                selfTurnJob = scope.launch {
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
                    val result = turn.await()
                    selfTurn = null
                    selfTurnJob = null
                    onSelfRecordResult(result)
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

        private fun onSelfRecordResult(result: STTResult) {
            if (result is STTResult.Success && result.text.isBlank()) {
                syncSelfRecord()
                return
            }
            val id = "u${++utteranceSeq}"
            turns[id] = TurnAudio.Recognized(result)
            dispatch { ConversationEvent.VadSpeechStart(it) }
            dispatch { ConversationEvent.VadSpeechEnd(it, id) }
        }

        // ── chat ──

        private fun onReply(event: VoiceReplyEvent) {
            when (event) {
                is VoiceReplyEvent.Text -> emitSentences(speakableSegments(event.full, final = false))
                is VoiceReplyEvent.Completed -> {
                    // Completed carries no text: the last Text is final once the stream ends.
                    lastReplyText?.let { emitSentences(speakableSegments(it, final = true)) }
                    dispatch { at -> ConversationEvent.ReplyCompleted(at) }
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

        override fun onInterruption(began: Boolean) {
            dispatch { if (began) ConversationEvent.InterruptionBegan(it) else ConversationEvent.InterruptionEnded(it) }
        }

        override fun onFocusLost() {
            dispatch { ConversationEvent.End(it, EndReason.SYSTEM) }
        }

        override fun onCaptureFailed() {
            dispatch { ConversationEvent.End(it, EndReason.SYSTEM) }
        }

        // ── teardown ──

        fun finish(reason: EndReason, code: String?, report: Boolean = true) {
            if (ended) return
            ended = true
            if (session === this) session = null
            selfTurn?.interrupt()
            background?.close()
            clearSpeech(all = true)
            frames.close()
            deadlineJob?.cancel()
            deadlineJob = null
            armedDeadlineAt = null
            if (audioOpened) audio.close()
            if (::voices.isInitialized) setOf(voices.primary, voices.system).forEach { it.release() }
            foreground.stop()
            if (report) memory.conversationEnded(fellBackToTap, exercisedSpeakerBargeIn)
            scope.cancel()
            _displayState.value = displayState(state)
            _statusKey.value = statusKey(state)
            _level.value = 0f
            _active.value = false
            if (report) _events.tryEmit(VoiceConversationEvent.Ended(reason, code))
        }
    }

    companion object {
        /** ≤ 15 level updates per second. */
        const val LEVEL_INTERVAL_MS = 67L
        const val SEND_FAILED = "send_failed"
    }
}

// ───────────── Production sources ─────────────

/**
 * STT for the conversation, resolved with the dictation settings and engines: cloud when the dictation
 * selection resolves to an accepted cloud engine, otherwise the system route (pipe = file turns, self-record =
 * recognizer turns). Side-effect free: fallback rewrites and notices stay with dictation's own use site.
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
            is SystemSTTRoute.Pipe -> ConversationStt.FromFile(engines.system(), lang)
            is SystemSTTRoute.SelfRecord -> ConversationStt.SelfRecord {
                val session = engines.startSelfRecordTurn(route)
                object : SelfRecordTurn {
                    override var onRmsDb: ((Float) -> Unit)?
                        get() = session.onLevel
                        set(value) {
                            session.onLevel = value
                        }

                    override suspend fun await(): STTResult = session.await()

                    override fun interrupt() = session.interrupt()
                }
            }
        }
    }

    private suspend fun cloud(): Pair<STTEngine, String>? {
        val selection = settings.selection(VoiceDirection.Stt) as? VoiceEngineSelection.Cloud ?: return null
        // Same as dictation: the cached read (may wait on the catalog lock) and the cold fetch share one 10 s budget; on timeout treat the catalog as unavailable and use system recognition.
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
