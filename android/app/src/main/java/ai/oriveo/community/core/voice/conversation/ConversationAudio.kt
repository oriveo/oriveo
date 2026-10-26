package ai.oriveo.community.core.voice.conversation

import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.NoiseSuppressor
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import androidx.annotation.VisibleForTesting
import androidx.core.content.ContextCompat
import ai.oriveo.community.core.voice.AacEncoder
import ai.oriveo.community.core.voice.AudioCapture
import ai.oriveo.community.core.voice.AudioCaptureEvents
import ai.oriveo.community.core.voice.AudioCaptureInitException
import ai.oriveo.community.core.voice.AudioRecordCapture
import ai.oriveo.community.core.voice.ChunkPlayer
import ai.oriveo.community.core.voice.CloudSpeechEngine
import ai.oriveo.community.core.voice.MediaChunkPlayer
import ai.oriveo.community.core.voice.MediaCodecAacEncoder
import ai.oriveo.community.core.voice.PcmSink
import ai.oriveo.community.core.voice.PcmWindowAccumulator
import ai.oriveo.community.core.voice.PcmSource
import ai.oriveo.community.core.voice.RecordingWriter
import ai.oriveo.community.core.voice.STTSegment
import java.io.File
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlin.coroutines.cancellation.CancellationException
import kotlin.coroutines.resume
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.log10
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

// ───────────── Pure helpers (JVM-testable) ─────────────

/** 20 ms frames of 16 kHz mono PCM and their dBFS. */
internal object ConversationFrames {
    const val SAMPLE_RATE = AudioRecordCapture.SAMPLE_RATE
    const val FRAME_SAMPLES = SAMPLE_RATE * VoiceConversationConstants.FRAME_MS / 1000
    private const val FULL_SCALE = 32768.0

    /** RMS dBFS of one frame; digital silence maps to the VAD floor of the frame clamp (−120). */
    fun frameDb(samples: ShortArray, count: Int = samples.size): Double {
        var sum = 0.0
        for (i in 0 until count) {
            val v = samples[i].toDouble()
            sum += v * v
        }
        if (count == 0 || sum == 0.0) return VoiceConversationConstants.FRAME_MIN_DB
        return 10 * log10(sum / count / (FULL_SCALE * FULL_SCALE))
    }

    /** Orb level 0…1 from dBFS (−60 dB and below is 0). */
    fun levelFromDb(db: Double): Float = ((db + 60.0) / 60.0).coerceIn(0.0, 1.0).toFloat()
}

/** Cuts arbitrary PCM chunks into numbered 20 ms frames (index from 0). */
internal class FrameChunker(private val onFrame: (index: Long, frame: ShortArray) -> Unit) {
    private val pending = ShortArray(ConversationFrames.FRAME_SAMPLES)
    private var filled = 0
    private var next = 0L

    fun add(samples: ShortArray, count: Int) {
        var offset = 0
        while (offset < count) {
            val n = minOf(pending.size - filled, count - offset)
            System.arraycopy(samples, offset, pending, filled, n)
            filled += n
            offset += n
            if (filled == pending.size) {
                onFrame(next++, pending.copyOf())
                filled = 0
            }
        }
    }
}

/**
 * Chunker for the capture thread: each finished frame re-checks [live], so frames that complete after close
 * (the capture thread winds down on IO) reach neither [recorder] nor [listener]. The check and the write hold
 * the [recorder] monitor; close clears [live] and the recorder under that same monitor, so no frame lands
 * between the two.
 */
internal fun liveFrameChunker(
    live: AtomicBoolean,
    recorder: TurnRecorder,
    listener: ConversationAudioListener,
): FrameChunker = FrameChunker { index, frame ->
    val written = synchronized(recorder) {
        live.get().also { if (it) recorder.onFrame(index, frame) }
    }
    if (written) listener.onFrame(index, ConversationFrames.frameDb(frame))
}

/**
 * Orders capture teardowns before the next capture start, process-wide: a session reopened right after close
 * must not open a second AudioRecord while the previous one is still being stopped / released on IO.
 */
internal class CaptureTeardownGate(
    private val joinTimeoutMillis: Long = TEARDOWN_JOIN_TIMEOUT_MILLIS,
) {
    private val pending = mutableSetOf<Job>()

    /** Runs [stop] on [scope] (NonCancellable, never on the caller's thread); later starts wait for it. */
    fun launchTeardown(scope: CoroutineScope, stop: suspend () -> Unit): Job {
        val job = scope.launch(NonCancellable, start = CoroutineStart.LAZY) { runCatching { stop() } }
        synchronized(pending) { pending += job }
        job.invokeOnCompletion { synchronized(pending) { pending -= job } }
        job.start()
        return job
    }

    /**
     * Registers a teardown the caller runs itself (e.g. dictation stopping under its own store lock); later starts
     * wait until the returned idempotent `stopped` is called. Only registers: never blocks or suspends the caller,
     * which must call `stopped` on every path (a missed call holds starts until [joinTimeoutMillis]).
     */
    fun beginTeardown(): () -> Unit {
        val job = Job()
        synchronized(pending) { pending += job }
        job.invokeOnCompletion { synchronized(pending) { pending -= job } }
        return { job.complete() }
    }

    /**
     * With no teardown in flight, runs [start] on the calling thread (a throw propagates) and returns null.
     * Otherwise runs it on [scope] once those teardowns finish, reporting a throw to [onFailure]; cancelling the
     * returned job drops a start that has not run yet. Nothing blocks the calling thread. Teardowns still running
     * after [joinTimeoutMillis] (one-shot timeout, not a poll) drop the start and report
     * [CaptureTeardownTimeoutException] to [onFailure]: the microphone is not opened twice.
     */
    fun startAfterTeardowns(scope: CoroutineScope, start: () -> Unit, onFailure: (Throwable) -> Unit): Job? {
        val waitFor = synchronized(pending) { pending.toList() }
        if (waitFor.isEmpty()) {
            start()
            return null
        }
        return scope.launch {
            if (withTimeoutOrNull(joinTimeoutMillis) { waitFor.joinAll() } == null) {
                onFailure(CaptureTeardownTimeoutException())
                return@launch
            }
            try {
                start()
            } catch (error: Exception) {
                onFailure(error)
            }
        }
    }

    /**
     * Suspends (never blocks) until the teardowns in flight now finish; false when they are still running after
     * [joinTimeoutMillis], in which case the caller must not open the microphone.
     */
    suspend fun awaitTeardowns(): Boolean {
        val waitFor = synchronized(pending) { pending.toList() }
        if (waitFor.isEmpty()) return true
        return withTimeoutOrNull(joinTimeoutMillis) { waitFor.joinAll() } != null
    }

    companion object {
        /** Upper bound for waiting on a previous capture's stop / release before giving up on the new start. */
        const val TEARDOWN_JOIN_TIMEOUT_MILLIS = 2_000L

        /** Shared by every production capture: they all open the same microphone. */
        val Shared = CaptureTeardownGate()
    }
}

/** The previous capture did not release the microphone within [CaptureTeardownGate.TEARDOWN_JOIN_TIMEOUT_MILLIS]. */
internal class CaptureTeardownTimeoutException : IllegalStateException("previous capture teardown timed out")

/**
 * Keeps the most recent frames so a turn can begin [VoiceConversationConstants.PREROLL_FRAMES] before onset,
 * and records the turn until its end frame. Thread-safe: frames arrive on the capture thread, begin / end on main.
 */
internal class TurnRecorder(
    private val ringCapacity: Int = DEFAULT_RING_FRAMES,
    private val maxTurnFrames: Int = MAX_TURN_FRAMES,
) {
    private val ring = ArrayDeque<Pair<Long, ShortArray>>()
    private var turn: MutableList<Pair<Long, ShortArray>>? = null

    @Synchronized
    fun onFrame(index: Long, frame: ShortArray) {
        ring.addLast(index to frame)
        while (ring.size > ringCapacity) ring.removeFirst()
        turn?.let { if (it.size < maxTurnFrames) it += index to frame }
    }

    /** Starts a turn with buffered frames from [prerollFrame] on. */
    @Synchronized
    fun begin(prerollFrame: Long) {
        turn = ring.filter { it.first >= prerollFrame }.toMutableList()
    }

    /** Ends the turn: samples of frames up to [endFrame] inclusive; null when no turn was open. */
    @Synchronized
    fun end(endFrame: Long): ShortArray? {
        val frames = turn ?: return null
        turn = null
        val kept = frames.filter { it.first <= endFrame }
        val out = ShortArray(kept.sumOf { it.second.size })
        var offset = 0
        for ((_, f) in kept) {
            System.arraycopy(f, 0, out, offset, f.size)
            offset += f.size
        }
        return out
    }

    @Synchronized
    fun cancel() {
        turn = null
    }

    /** Drops buffered frames (after mute / pause the preroll must not reach across the gap). */
    @Synchronized
    fun clear() {
        ring.clear()
        turn = null
    }

    companion object {
        /** Preroll plus the longest onset run (barge-in 300 ms) plus slack for main-thread latency. */
        const val DEFAULT_RING_FRAMES = VoiceConversationConstants.PREROLL_FRAMES +
            VoiceConversationConstants.BARGE_IN_MIN_SPEECH_MS / VoiceConversationConstants.FRAME_MS + 25

        /** 3 minutes. */
        const val MAX_TURN_FRAMES = 3 * 60 * 1000 / VoiceConversationConstants.FRAME_MS
    }
}

/** Earcons: a short sine at about −18 dBFS with 10 ms fades (no clicks). */
internal object Earcons {
    const val LEVEL_DBFS = -18.0
    const val MAX_MS = 250
    private const val FADE_MS = 10

    fun durationMs(kind: EarconKind): Int = when (kind) {
        EarconKind.THINKING -> 120
        EarconKind.END -> 240
    }

    fun frequencyHz(kind: EarconKind): Double = when (kind) {
        EarconKind.THINKING -> 880.0
        EarconKind.END -> 523.25
    }

    fun samples(kind: EarconKind, sampleRate: Int = ConversationFrames.SAMPLE_RATE): ShortArray {
        val n = sampleRate * durationMs(kind) / 1000
        val fade = sampleRate * FADE_MS / 1000
        val amplitude = 32767.0 * 10.0.pow(LEVEL_DBFS / 20.0)
        val freq = frequencyHz(kind)
        return ShortArray(n) { i ->
            val envelope = when {
                i < fade -> 0.5 - 0.5 * cos(PI * i / fade)
                i >= n - fade -> 0.5 - 0.5 * cos(PI * (n - 1 - i) / fade)
                else -> 1.0
            }
            (amplitude * envelope * sin(2 * PI * freq * i / sampleRate)).roundToInt().toShort()
        }
    }
}

/** Route from the current output device types (AudioDeviceInfo.TYPE_*): bluetooth > wired / USB > speaker. */
internal fun routeForOutputs(types: Collection<Int>): ConversationRoute = when {
    types.any { it in BLUETOOTH_TYPES } -> ConversationRoute.BLUETOOTH
    types.any { it in WIRED_TYPES } -> ConversationRoute.HEADPHONES
    else -> ConversationRoute.SPEAKER
}

@SuppressLint("InlinedApi")
internal val BLUETOOTH_TYPES = setOf(
    AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
    AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
    AudioDeviceInfo.TYPE_BLE_HEADSET,
)

@SuppressLint("InlinedApi")
internal val WIRED_TYPES = setOf(
    AudioDeviceInfo.TYPE_WIRED_HEADSET,
    AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
    AudioDeviceInfo.TYPE_USB_HEADSET,
    AudioDeviceInfo.TYPE_HEARING_AID,
)

/**
 * RMS level 0…1 of 16-bit little-endian PCM bytes: one [PcmWindowAccumulator] window (the recorder's and the realtime
 * uplink's sum of squares and dBFS), mapped by [ConversationFrames.levelFromDb]; empty or all-zero is 0.
 */
internal fun pcm16Level(bytes: ByteArray): Float {
    val window = PcmWindowAccumulator()
    window.addPcm16Le(bytes)
    return window.level()?.let(ConversationFrames::levelFromDb) ?: 0f
}

// ───────────── Ports used by the controller ─────────────

/** Signals from the audio pipeline. [onFrame] arrives on the capture thread; the rest on the main thread. */
interface ConversationAudioListener {
    fun onFrame(index: Long, db: Double)

    /** [privateRouteRemoved] = headphones / bluetooth went away (unplugged). */
    fun onRouteChanged(route: ConversationRoute, privateRouteRemoved: Boolean)

    /** ACTION_AUDIO_BECOMING_NOISY: stop the current sentence. */
    fun onBecomingNoisy()

    /** Transient focus loss (call, another app) = interruption began; regained = ended. */
    fun onInterruption(began: Boolean)

    /** AUDIOFOCUS_LOSS: focus is gone for good (another app took over playback); the conversation ends. */
    fun onFocusLost()

    fun onCaptureFailed()
}

/** Conversation audio session: communication mode, focus, routing, capture and turn export . */
interface ConversationAudio {
    /** False when the device has no AcousticEchoCanceler: speaker barge-in starts as tap-only . */
    val echoCancellerAvailable: Boolean

    val route: ConversationRoute

    /**
     * Opens the session after the foreground service runs: MODE_IN_COMMUNICATION, focus, routing and, when
     * [capture] is true, AudioRecord(VOICE_COMMUNICATION). Throws when focus is denied or the recorder can't start.
     */
    fun open(listener: ConversationAudioListener, capture: Boolean)

    /** Releases the session; file cleanup runs off the main thread. */
    fun close()

    /** Muted: samples are dropped in software, the input stays open. */
    fun setMuted(muted: Boolean)

    /** Paused (interruption, prompt, message playback): samples dropped like mute. */
    fun setCapturePaused(paused: Boolean)

    fun beginTurn(prerollFrame: Long)

    /** Ends the turn at [endFrame] (inclusive); null when no turn was open. */
    fun endTurn(endFrame: Long): ShortArray?

    fun cancelTurn()

    /** Writes a turn as AAC (the dictation encoder) and returns the STT segment; null when writing fails. */
    suspend fun writeTurn(samples: ShortArray): STTSegment?

    /** Like [writeTurn] for the ✕ draft, but somewhere [close] doesn't clear, so the draft survives the teardown. */
    suspend fun writeDraft(samples: ShortArray): STTSegment? = writeTurn(samples)

    suspend fun playEarcon(kind: EarconKind)
}

enum class TtsOutcome { DONE, FAILED }

/** One sentence of speech through the conversation pipeline; cancelling stops it. */
interface ConversationTts {
    val isCloud: Boolean

    suspend fun speak(text: String, onLevel: (Float) -> Unit): TtsOutcome

    /** The conversation ended: free engine resources; a later [speak] starts over. */
    fun release() = Unit
}

/** Built on first use so JVM tests of the pure helpers in this file don't touch the Android framework. */
val VOICE_COMMUNICATION_ATTRIBUTES: AudioAttributes by lazy {
    AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
        .build()
}

/** Silence after an earcon's last sample before the track is released, so the tail isn't clipped. */
private const val EARCON_TAIL_MS = 40L

/** Plays [kind] on a static voice-communication track (built off the caller's thread) and releases it when done. */
internal suspend fun playEarconTrack(kind: EarconKind) {
    val samples = Earcons.samples(kind)
    val track = withContext(Dispatchers.IO) {
        runCatching {
            AudioTrack.Builder()
                .setAudioAttributes(VOICE_COMMUNICATION_ATTRIBUTES)
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(ConversationFrames.SAMPLE_RATE)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build(),
                )
                .setTransferMode(AudioTrack.MODE_STATIC)
                .setBufferSizeInBytes(samples.size * 2)
                .build()
                .also {
                    it.write(samples, 0, samples.size)
                    it.play()
                }
        }.getOrNull()
    } ?: return
    try {
        delay(Earcons.durationMs(kind).toLong() + EARCON_TAIL_MS)
    } finally {
        runCatching { track.stop() }
        track.release()
    }
}

// ───────────── Android implementation ─────────────

/** AudioRecord(VOICE_COMMUNICATION) with per-session AEC / NS: read the default state first, enable only if off. */
internal class CommunicationRecordSource private constructor(
    private val record: AudioRecord,
    private val effects: List<android.media.audiofx.AudioEffect>,
    val echoCancellerAvailable: Boolean,
) : PcmSource {
    override fun read(buffer: ShortArray, offset: Int, size: Int): Int = record.read(buffer, offset, size)

    // Interruptions come from audio focus; a silenced client keeps reading zeros until focus returns.
    override fun observeSilenced(onSilenced: () -> Unit): () -> Unit = {}

    override fun stop() = record.stop()

    override fun release() {
        effects.forEach { runCatching { it.release() } }
        record.release()
    }

    companion object {
        @SuppressLint("MissingPermission")
        fun open(): CommunicationRecordSource {
            val rate = ConversationFrames.SAMPLE_RATE
            val channel = AudioFormat.CHANNEL_IN_MONO
            val encoding = AudioFormat.ENCODING_PCM_16BIT
            val minBuffer = AudioRecord.getMinBufferSize(rate, channel, encoding)
            if (minBuffer <= 0) throw AudioCaptureInitException("getMinBufferSize failed: $minBuffer")
            val bufferBytes = maxOf(minBuffer, ConversationFrames.FRAME_SAMPLES * 2 * 4)
            val record = try {
                AudioRecord(MediaRecorder.AudioSource.VOICE_COMMUNICATION, rate, channel, encoding, bufferBytes)
            } catch (error: Exception) {
                throw AudioCaptureInitException("AudioRecord construction failed: ${error.message}")
            }
            if (record.state != AudioRecord.STATE_INITIALIZED) {
                record.release()
                throw AudioCaptureInitException("AudioRecord not initialized")
            }
            val effects = mutableListOf<android.media.audiofx.AudioEffect>()
            val aecAvailable = AcousticEchoCanceler.isAvailable()
            if (aecAvailable) {
                AcousticEchoCanceler.create(record.audioSessionId)?.let { aec ->
                    if (!aec.enabled) runCatching { aec.enabled = true }
                    effects += aec
                }
            }
            if (NoiseSuppressor.isAvailable()) {
                NoiseSuppressor.create(record.audioSessionId)?.let { ns ->
                    if (!ns.enabled) runCatching { ns.enabled = true }
                    effects += ns
                }
            }
            try {
                record.startRecording()
            } catch (error: Exception) {
                effects.forEach { runCatching { it.release() } }
                record.release()
                throw AudioCaptureInitException("startRecording failed: ${error.message}")
            }
            if (record.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
                effects.forEach { runCatching { it.release() } }
                record.release()
                throw AudioCaptureInitException("AudioRecord did not enter recording state")
            }
            return CommunicationRecordSource(record, effects, aecAvailable)
        }
    }
}

private val TURN_FILE = Regex("""turn-(\d+)\.aac""")

/**
 * Deletes, on [scope], the `turn-N.aac` files in [dir] with N ≤ [lastTurn] (the counter read at close): a session
 * reopened right after close writes higher-numbered turn files into the same directory, and those must survive.
 * Listing and deleting both run on [scope], never on the caller's (main) thread.
 */
internal fun deleteTurnFilesUpTo(dir: File, lastTurn: Long, scope: CoroutineScope) {
    if (lastTurn <= 0) return
    scope.launch(NonCancellable) {
        dir.listFiles()?.forEach { file ->
            val turn = TURN_FILE.matchEntire(file.name)?.groupValues?.get(1)?.toLongOrNull() ?: return@forEach
            if (turn <= lastTurn) file.delete()
        }
    }
}

class ConversationAudioException(message: String) : IllegalStateException(message)

/** Production [ConversationAudio]. [newCapture] builds the capture over the given source (tests inject a fake). */
class AndroidConversationAudio internal constructor(
    context: Context,
    private val turnDir: File,
    private val encoderFactory: () -> AacEncoder,
    private val newCapture: (openSource: () -> PcmSource) -> AudioCapture,
    private val teardowns: CaptureTeardownGate = CaptureTeardownGate.Shared,
) : ConversationAudio {
    constructor(
        context: Context,
        turnDir: File,
        encoderFactory: () -> AacEncoder = { MediaCodecAacEncoder() },
    ) : this(context, turnDir, encoderFactory, { AudioRecordCapture(it) })

    private val appContext = context.applicationContext
    private val audioManager = appContext.getSystemService(AudioManager::class.java)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val recorder = TurnRecorder()
    private val turnCounter = AtomicLong()
    private val ioScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    @Volatile private var muted = false

    @Volatile private var paused = false

    private var capture: AudioCapture? = null

    // A capture start deferred until earlier teardowns finish; close cancels it.
    private var captureStart: Job? = null

    // Open's sweep of turn files a killed process left behind; the first turn write waits for it.
    @Volatile private var staleSweep: Job? = null

    // Cleared on close so frames read while the capture thread winds down on IO go nowhere.
    private var captureLive: AtomicBoolean? = null
    private var focusRequest: AudioFocusRequest? = null
    private var deviceCallback: AudioDeviceCallback? = null
    private var noisyReceiver: BroadcastReceiver? = null
    private var previousMode: Int? = null
    private var previousSpeakerphone: Boolean? = null
    private var listener: ConversationAudioListener? = null

    /** Read-only view for instrumented tests: BECOMING_NOISY is protected, so tests deliver to this receiver. */
    @get:VisibleForTesting
    internal val sessionNoisyReceiver: BroadcastReceiver? get() = noisyReceiver

    // Set by the capture source, which a deferred start opens on IO.
    @Volatile
    override var echoCancellerAvailable: Boolean = AcousticEchoCanceler.isAvailable()
        private set

    override var route: ConversationRoute = ConversationRoute.SPEAKER
        private set

    override fun open(listener: ConversationAudioListener, capture: Boolean) {
        this.listener = listener
        // Drafts normally get deleted after transcription; leftovers from a killed process go after an hour.
        val draftCutoff = System.currentTimeMillis() - STALE_DRAFT_MS
        val drafts = draftDir
        ioScope.launch { drafts.listFiles()?.filter { it.lastModified() < draftCutoff }?.forEach { it.delete() } }
        // Close only deletes turns up to its own counter, so a crash leaves turn files behind: sweep them here.
        val turns = turnDir
        staleSweep = ioScope.launch {
            turns.listFiles()?.forEach { file -> if (TURN_FILE.matches(file.name)) file.delete() }
        }
        try {
            previousMode = audioManager.mode
            audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
            requestFocus(listener)
            route = currentRoute()
            applyRoute(route)
            registerRouteCallbacks(listener)
            if (capture) startCapture(listener)
        } catch (error: Exception) {
            close()
            throw error
        }
    }

    private fun requestFocus(listener: ConversationAudioListener) {
        val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE)
            .setAudioAttributes(VOICE_COMMUNICATION_ATTRIBUTES)
            .setOnAudioFocusChangeListener({ change ->
                when (change) {
                    AudioManager.AUDIOFOCUS_GAIN -> listener.onInterruption(began = false)
                    AudioManager.AUDIOFOCUS_LOSS -> listener.onFocusLost()
                    AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
                    AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK,
                    -> listener.onInterruption(began = true)
                }
            }, mainHandler)
            .build()
        if (audioManager.requestAudioFocus(request) != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
            throw ConversationAudioException("audio focus denied")
        }
        focusRequest = request
    }

    private fun startCapture(listener: ConversationAudioListener) {
        val live = AtomicBoolean(true)
        val chunker = liveFrameChunker(live, recorder, listener)
        val sink = PcmSink { samples, count -> if (live.get() && !muted && !paused) chunker.add(samples, count) }
        val started = newCapture {
            CommunicationRecordSource.open().also { echoCancellerAvailable = it.echoCancellerAvailable }
        }
        val events = object : AudioCaptureEvents {
            override fun onFailure(error: Throwable) {
                mainHandler.post { listener.onCaptureFailed() }
            }

            override fun onInterrupted() = Unit
        }
        captureLive = live
        // A capture closed just before still releases AudioRecord on IO: open the new one only after that.
        captureStart = teardowns.startAfterTeardowns(
            ioScope,
            start = { started.start(listOf(sink), events) },
            onFailure = { mainHandler.post { if (live.get()) listener.onCaptureFailed() } },
        )
        capture = started
    }

    private fun currentRoute(): ConversationRoute =
        routeForOutputs(audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).map { it.type })

    /** API 31+: pick the communication device; below: speakerphone on only when no private route exists. */
    @Suppress("DEPRECATION")
    private fun applyRoute(target: ConversationRoute) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val devices = audioManager.availableCommunicationDevices
            val wanted = when (target) {
                ConversationRoute.BLUETOOTH -> devices.firstOrNull { it.type in BLUETOOTH_TYPES }
                ConversationRoute.HEADPHONES -> devices.firstOrNull { it.type in WIRED_TYPES }
                ConversationRoute.SPEAKER -> devices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
            }
            if (wanted != null) runCatching { audioManager.setCommunicationDevice(wanted) }
        } else {
            if (previousSpeakerphone == null) previousSpeakerphone = audioManager.isSpeakerphoneOn
            audioManager.isSpeakerphoneOn = target == ConversationRoute.SPEAKER
        }
    }

    private fun registerRouteCallbacks(listener: ConversationAudioListener) {
        val callback = object : AudioDeviceCallback() {
            override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) = refresh(removed = false)

            override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) = refresh(removed = true)

            private fun refresh(removed: Boolean) {
                val previous = route
                val next = currentRoute()
                if (next == previous) return
                route = next
                applyRoute(next)
                listener.onRouteChanged(next, privateRouteRemoved = removed && previous != ConversationRoute.SPEAKER)
            }
        }
        audioManager.registerAudioDeviceCallback(callback, mainHandler)
        deviceCallback = callback
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (intent.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) listener.onBecomingNoisy()
            }
        }
        ContextCompat.registerReceiver(
            appContext,
            receiver,
            IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        noisyReceiver = receiver
    }

    @Suppress("DEPRECATION")
    override fun close() {
        // Same monitor as liveFrameChunker's check-and-write: no frame lands after this clear.
        synchronized(recorder) {
            captureLive?.set(false)
            recorder.clear()
        }
        captureLive = null
        // stop() joins the capture thread and releases AudioRecord: keep that off the main thread. A deferred
        // start is dropped, or awaited when already running, so the capture it opens gets stopped too.
        val pendingStart = captureStart
        capture?.let { stopping ->
            teardowns.launchTeardown(ioScope) {
                pendingStart?.cancelAndJoin()
                stopping.stop()
            }
        }
        capture = null
        captureStart = null
        deviceCallback?.let { audioManager.unregisterAudioDeviceCallback(it) }
        deviceCallback = null
        noisyReceiver?.let { runCatching { appContext.unregisterReceiver(it) } }
        noisyReceiver = null
        focusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
        focusRequest = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            runCatching { audioManager.clearCommunicationDevice() }
        } else {
            previousSpeakerphone?.let { audioManager.isSpeakerphoneOn = it }
        }
        previousSpeakerphone = null
        previousMode?.let { audioManager.mode = it }
        previousMode = null
        listener = null
        muted = false
        paused = false
        deleteTurnFilesUpTo(turnDir, turnCounter.get(), ioScope)
    }

    override fun setMuted(muted: Boolean) {
        this.muted = muted
        recorder.clear()
    }

    override fun setCapturePaused(paused: Boolean) {
        this.paused = paused
        recorder.clear()
    }

    override fun beginTurn(prerollFrame: Long) = recorder.begin(prerollFrame)

    override fun endTurn(endFrame: Long): ShortArray? = recorder.end(endFrame)

    override fun cancelTurn() = recorder.cancel()

    override suspend fun writeTurn(samples: ShortArray): STTSegment? {
        // The sweep must not delete a turn file this session has just written.
        staleSweep?.join()
        return write(turnDir, samples)
    }

    // The controller deletes the draft file after transcribing it.
    override suspend fun writeDraft(samples: ShortArray): STTSegment? = write(draftDir, samples)

    private val draftDir: File get() = File(turnDir.parentFile ?: turnDir, "${turnDir.name}-draft")

    private suspend fun write(dir: File, samples: ShortArray): STTSegment? = withContext(Dispatchers.IO) {
        runCatching {
            dir.mkdirs()
            val file = File(dir, "turn-${turnCounter.incrementAndGet()}.aac")
            val writer = RecordingWriter(file, encoderFactory())
            writer.use { it.write(samples, samples.size) }
            STTSegment(aac = file, primingFrames = writer.primingFrames, envelope = writer.envelope)
        }.getOrNull()
    }

    override suspend fun playEarcon(kind: EarconKind) = playEarconTrack(kind)

    private companion object {
        const val STALE_DRAFT_MS = 60 * 60 * 1000L
    }
}

/**
 * System TTS for the conversation : synthesizeToFile + onAudioAvailable PCM into our own AudioTrack
 * (USAGE_VOICE_COMMUNICATION), so the AEC has the reference. Engines that don't stream PCM play the file on onDone.
 */
class SystemConversationTts(
    context: Context,
    private val speechRate: () -> Double,
    private val localeFor: suspend (String) -> Locale,
    private val tempDir: File,
) : ConversationTts {
    private val appContext = context.applicationContext
    @Volatile private var tts: TextToSpeech? = null
    private val initLock = Mutex()
    private val counter = AtomicLong()

    // One engine listener routes callbacks by utteranceId, so a later speak can't steal an earlier one's callbacks.
    private val listeners = ConcurrentHashMap<String, UtteranceProgressListener>()
    private val router = object : UtteranceProgressListener() {
        private fun of(id: String?) = id?.let(listeners::get)

        override fun onStart(utteranceId: String?) {
            of(utteranceId)?.onStart(utteranceId)
        }

        override fun onBeginSynthesis(utteranceId: String?, sampleRateInHz: Int, audioFormat: Int, channelCount: Int) {
            of(utteranceId)?.onBeginSynthesis(utteranceId, sampleRateInHz, audioFormat, channelCount)
        }

        override fun onAudioAvailable(utteranceId: String?, audio: ByteArray?) {
            of(utteranceId)?.onAudioAvailable(utteranceId, audio)
        }

        override fun onDone(utteranceId: String?) {
            of(utteranceId)?.onDone(utteranceId)
        }

        @Deprecated("Deprecated in Java")
        override fun onError(utteranceId: String?) {
            @Suppress("DEPRECATION")
            of(utteranceId)?.onError(utteranceId)
        }

        override fun onError(utteranceId: String?, errorCode: Int) {
            of(utteranceId)?.onError(utteranceId, errorCode)
        }

        override fun onStop(utteranceId: String?, interrupted: Boolean) {
            of(utteranceId)?.onStop(utteranceId, interrupted)
        }
    }

    override val isCloud: Boolean = false

    // Concurrent first speaks (a reply sentence and a prompt) share one initialization.
    private suspend fun engine(): TextToSpeech? {
        tts?.let { return it }
        return initLock.withLock { tts ?: initialize()?.also { tts = it } }
    }

    private suspend fun initialize(): TextToSpeech? {
        var created: TextToSpeech? = null
        val ready = try {
            withTimeoutOrNull(INIT_TIMEOUT_MS) {
                suspendCancellableCoroutine { cont ->
                    created = TextToSpeech(appContext) { status ->
                        if (cont.isActive) cont.resume(status == TextToSpeech.SUCCESS)
                    }
                }
            } == true
        } catch (error: CancellationException) {
            created?.shutdown()
            throw error
        }
        val engine = created ?: return null
        if (!ready) {
            engine.shutdown()
            return null
        }
        engine.setOnUtteranceProgressListener(router)
        return engine
    }

    override fun release() {
        val engine = tts ?: return
        tts = null
        runCatching { engine.stop() }
        engine.shutdown()
    }

    override suspend fun speak(text: String, onLevel: (Float) -> Unit): TtsOutcome {
        val engine = engine() ?: return TtsOutcome.FAILED
        val locale = localeFor(text)
        val lang = engine.setLanguage(locale)
        if (lang == TextToSpeech.LANG_MISSING_DATA || lang == TextToSpeech.LANG_NOT_SUPPORTED) {
            engine.setLanguage(engine.defaultVoice?.locale ?: Locale.getDefault())
        }
        engine.setSpeechRate(speechRate().toFloat())
        withContext(Dispatchers.IO) { tempDir.mkdirs() }
        val n = counter.incrementAndGet()
        val file = File(tempDir, "tts-$n.wav")
        val id = "conv-$n"
        val stream = PcmStream(onLevel)
        try {
            val synthesized = suspendCancellableCoroutine { cont ->
                listeners[id] = SynthesisListener(id, stream, cont)
                cont.invokeOnCancellation { runCatching { engine.stop() } }
                if (engine.synthesizeToFile(text, Bundle(), file, id) != TextToSpeech.SUCCESS && cont.isActive) {
                    cont.resume(false)
                }
            }
            if (!synthesized) return TtsOutcome.FAILED
            return if (stream.framesWritten > 0) {
                stream.drain()
                TtsOutcome.DONE
            } else {
                onLevel(CONSTANT_LEVEL)
                if (MediaChunkPlayer(VOICE_COMMUNICATION_ATTRIBUTES).play(file)) TtsOutcome.DONE else TtsOutcome.FAILED
            }
        } finally {
            listeners.remove(id)
            stream.release()
            withContext(NonCancellable + Dispatchers.IO) { file.delete() }
        }
    }

    private class SynthesisListener(
        private val id: String,
        private val stream: PcmStream,
        private val cont: CancellableContinuation<Boolean>,
    ) : UtteranceProgressListener() {
        override fun onStart(utteranceId: String?) = Unit

        override fun onBeginSynthesis(utteranceId: String?, sampleRateInHz: Int, audioFormat: Int, channelCount: Int) {
            if (utteranceId == id) stream.begin(sampleRateInHz, audioFormat, channelCount)
        }

        override fun onAudioAvailable(utteranceId: String?, audio: ByteArray?) {
            if (utteranceId == id && audio != null) stream.write(audio)
        }

        override fun onDone(utteranceId: String?) {
            if (utteranceId == id && cont.isActive) cont.resume(true)
        }

        @Deprecated("Deprecated in Java")
        override fun onError(utteranceId: String?) {
            if (utteranceId == id && cont.isActive) cont.resume(false)
        }

        override fun onError(utteranceId: String?, errorCode: Int) {
            if (utteranceId == id && cont.isActive) cont.resume(false)
        }

        override fun onStop(utteranceId: String?, interrupted: Boolean) {
            if (utteranceId == id && cont.isActive) cont.resume(false)
        }
    }

    /** Streams engine PCM into an AudioTrack built from onBeginSynthesis' format. */
    private class PcmStream(private val onLevel: (Float) -> Unit) {
        private var track: AudioTrack? = null
        private var bytesPerFrame = 2
        private var is16Bit = true

        @Volatile var framesWritten = 0L
            private set

        @Synchronized
        fun begin(sampleRate: Int, format: Int, channels: Int) {
            if (track != null) return
            is16Bit = format == AudioFormat.ENCODING_PCM_16BIT
            val bytesPerSample = when (format) {
                AudioFormat.ENCODING_PCM_8BIT -> 1
                AudioFormat.ENCODING_PCM_FLOAT -> 4
                else -> 2
            }
            bytesPerFrame = bytesPerSample * channels.coerceAtLeast(1)
            val mask = if (channels >= 2) AudioFormat.CHANNEL_OUT_STEREO else AudioFormat.CHANNEL_OUT_MONO
            val min = AudioTrack.getMinBufferSize(sampleRate, mask, format)
            track = runCatching {
                AudioTrack.Builder()
                    .setAudioAttributes(VOICE_COMMUNICATION_ATTRIBUTES)
                    .setAudioFormat(
                        AudioFormat.Builder().setEncoding(format).setSampleRate(sampleRate).setChannelMask(mask).build(),
                    )
                    .setTransferMode(AudioTrack.MODE_STREAM)
                    .setBufferSizeInBytes(maxOf(min, sampleRate * bytesPerFrame / 5))
                    .build()
                    .also { it.play() }
            }.getOrNull()
        }

        fun write(bytes: ByteArray) {
            val t = synchronized(this) { track } ?: return
            if (t.write(bytes, 0, bytes.size) > 0) framesWritten += bytes.size / bytesPerFrame
            if (is16Bit) onLevel(pcm16Level(bytes))
        }

        /**
         * Waits until the track has played everything written: a notification marker at the last frame, no polling.
         * A marker the track refuses leaves only the timeout (duration + slack), which still plays the tail.
         */
        suspend fun drain() {
            val t = synchronized(this) { track } ?: return
            val target = framesWritten
            fun played() = (t.playbackHeadPosition.toLong() and 0xffffffffL) >= target
            if (played()) return
            try {
                withTimeoutOrNull(target * 1000 / t.sampleRate.coerceAtLeast(1) + DRAIN_SLACK_MS) {
                    suspendCancellableCoroutine { cont ->
                        t.setPlaybackPositionUpdateListener(
                            object : AudioTrack.OnPlaybackPositionUpdateListener {
                                override fun onMarkerReached(track: AudioTrack) {
                                    if (cont.isActive) cont.resume(Unit)
                                }

                                override fun onPeriodicNotification(track: AudioTrack) = Unit
                            },
                            Handler(Looper.getMainLooper()),
                        )
                        val armed = t.setNotificationMarkerPosition(target.toInt()) == AudioTrack.SUCCESS
                        // The head may have passed the marker while it was being set.
                        if (armed && played() && cont.isActive) cont.resume(Unit)
                    }
                }
            } finally {
                runCatching { t.setPlaybackPositionUpdateListener(null) }
            }
        }

        @Synchronized
        fun release() {
            track?.let {
                runCatching { it.pause() }
                runCatching { it.flush() }
                it.release()
            }
            track = null
        }
    }

    private companion object {
        const val INIT_TIMEOUT_MS = 5_000L
        const val DRAIN_SLACK_MS = 1_000L
        const val CONSTANT_LEVEL = 0.5f
    }
}

/** Cloud TTS for the conversation: [CloudSpeechEngine.synthesizeToFile] (same cache / request) + MediaPlayer. */
class CloudConversationTts(
    private val engine: CloudSpeechEngine,
    private val localeFor: suspend (String) -> Locale,
    private val playerFactory: () -> ChunkPlayer = { MediaChunkPlayer(VOICE_COMMUNICATION_ATTRIBUTES) },
) : ConversationTts {
    override val isCloud: Boolean = true

    override suspend fun speak(text: String, onLevel: (Float) -> Unit): TtsOutcome {
        val files = engine.synthesizeToFile(text, localeFor(text)) ?: return TtsOutcome.FAILED
        val player = playerFactory()
        try {
            for ((index, audio) in files.withIndex()) {
                onLevel(CLOUD_LEVEL)
                val ok = try {
                    player.play(audio.file)
                } finally {
                    if (audio.temporary) withContext(NonCancellable + Dispatchers.IO) { audio.file.delete() }
                }
                if (!ok) {
                    val rest = files.drop(index + 1).filter { it.temporary }
                    withContext(NonCancellable + Dispatchers.IO) { rest.forEach { it.file.delete() } }
                    return TtsOutcome.FAILED
                }
            }
            return TtsOutcome.DONE
        } finally {
            player.stop()
        }
    }

    private companion object {
        const val CLOUD_LEVEL = 0.5f
    }
}
