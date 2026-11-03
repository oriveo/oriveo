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
import android.media.AudioRecordingConfiguration
import android.media.AudioTimestamp
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.NoiseSuppressor
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import androidx.annotation.VisibleForTesting
import androidx.core.content.ContextCompat
import ai.oriveo.community.core.voice.AacEncoder
import ai.oriveo.community.core.voice.AndroidAudioSessionCoordinator
import ai.oriveo.community.core.voice.AudioCapture
import ai.oriveo.community.core.voice.AudioCaptureEvents
import ai.oriveo.community.core.voice.AudioCaptureInitException
import ai.oriveo.community.core.voice.AudioRecordCapture
import ai.oriveo.community.core.voice.AudioSessionOps
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
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.merge
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
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

    /** Fixed floor (dBFS) for AI playback levels, which have no VAD floor of their own. */
    const val AI_LEVEL_FLOOR_DB = -50.0

    /** Headroom above the floor before the orb moves, and the dB span from there to full level. */
    private const val LEVEL_FLOOR_MARGIN_DB = 6.0
    private const val LEVEL_SPAN_DB = 30.0

    /** Orb level 0…1 from dBFS relative to [floorDb]: 0 up to floor + 6 dB, 1 from floor + 36 dB. */
    fun levelFromDb(db: Double, floorDb: Double): Float =
        ((db - floorDb - LEVEL_FLOOR_MARGIN_DB) / LEVEL_SPAN_DB).coerceIn(0.0, 1.0).toFloat()
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
    if (written) {
        // The speech model runs on this capture thread; each frame carries the latest chunk's probability.
        val prob = listener.speechModel?.feed(frame)
        listener.onFrame(index, ConversationFrames.frameDb(frame), prob)
    }
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
    private var tap: PcmSink? = null

    @Synchronized
    fun onFrame(index: Long, frame: ShortArray) {
        ring.addLast(index to frame)
        while (ring.size > ringCapacity) ring.removeFirst()
        turn?.let { if (it.size < maxTurnFrames) it += index to frame }
        if (turn != null) tap?.onPcm(frame, frame.size)
    }

    /** Feeds the open turn's frames so far (preroll included) to [sink], then every later frame until the turn ends. */
    @Synchronized
    fun tap(sink: PcmSink) {
        val frames = turn ?: return
        for ((_, f) in frames) sink.onPcm(f, f.size)
        tap = sink
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
        tap = null
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
        tap = null
    }

    /** Drops buffered frames (after mute / pause the preroll must not reach across the gap). */
    @Synchronized
    fun clear() {
        ring.clear()
        turn = null
        tap = null
    }

    companion object {
        /**
         * Preroll plus the farthest onset before the start decision (model-mode backtrack window 1000 ms, which also
         * covers the longest onset run, barge-in 300 ms) plus slack for main-thread latency: 90 frames = 1800 ms.
         */
        const val DEFAULT_RING_FRAMES = VoiceConversationConstants.PREROLL_FRAMES +
            VoiceConversationConstants.VAD_MODEL_ONSET_BACKTRACK_MS / VoiceConversationConstants.FRAME_MS + 25

        /** 3 minutes. */
        const val MAX_TURN_FRAMES = 3 * 60 * 1000 / VoiceConversationConstants.FRAME_MS
    }
}

/**
 * Earcons (contract rules.host): sine segments at about −18 dBFS, phase-continuous across segments, with 10 ms fades
 * at both ends only (no clicks).
 */
internal object Earcons {
    const val LEVEL_DBFS = -18.0
    const val MAX_MS = 250
    private const val FADE_MS = 10

    /** (frequency Hz, duration ms) segments played back to back. */
    fun segments(kind: EarconKind): List<Pair<Double, Int>> = when (kind) {
        EarconKind.START -> listOf(660.0 to 60, 880.0 to 60)
        EarconKind.HEARD -> listOf(880.0 to 60)
        EarconKind.THINKING -> listOf(880.0 to 120)
        EarconKind.END -> listOf(660.0 to 110, 440.0 to 130)
    }

    fun durationMs(kind: EarconKind): Int = segments(kind).sumOf { it.second }

    fun samples(kind: EarconKind, sampleRate: Int = ConversationFrames.SAMPLE_RATE): ShortArray {
        val freqs = DoubleArray(sampleRate * durationMs(kind) / 1000)
        var at = 0
        for ((hz, ms) in segments(kind)) {
            val end = minOf(freqs.size, at + sampleRate * ms / 1000)
            for (i in at until end) freqs[i] = hz
            at = end
        }
        val n = freqs.size
        val fade = sampleRate * FADE_MS / 1000
        val amplitude = 32767.0 * 10.0.pow(LEVEL_DBFS / 20.0)
        var phase = 0.0
        return ShortArray(n) { i ->
            val envelope = when {
                i < fade -> 0.5 - 0.5 * cos(PI * i / fade)
                i >= n - fade -> 0.5 - 0.5 * cos(PI * (n - 1 - i) / fade)
                else -> 1.0
            }
            val sample = amplitude * envelope * sin(phase)
            phase += 2 * PI * freqs[i] / sampleRate
            sample.roundToInt().toShort()
        }
    }
}

/**
 * Route from the current output device types (AudioDeviceInfo.TYPE_*): bluetooth > known in-ear / on-ear > speaker.
 * Everything else (HDMI, cast, BLE speaker, car bus, USB device, unknown, earpiece) counts as speaker: the output list
 * holds every connected device and always includes the earpiece, so only types known to sit on the ear are private.
 */
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
    AudioDeviceInfo.TYPE_BLE_HEARING_AID,
)

/**
 * RMS level 0…1 of 16-bit little-endian PCM bytes: one [PcmWindowAccumulator] window (the recorder's and the realtime
 * uplink's sum of squares and dBFS), mapped by [ConversationFrames.levelFromDb] against
 * [ConversationFrames.AI_LEVEL_FLOOR_DB]; empty or all-zero is 0.
 */
internal fun pcm16Level(bytes: ByteArray): Float {
    val window = PcmWindowAccumulator()
    window.addPcm16Le(bytes)
    return window.level()?.let { ConversationFrames.levelFromDb(it, ConversationFrames.AI_LEVEL_FLOOR_DB) } ?: 0f
}

/**
 * Feeds one AudioTrack from the engine callback thread and lets another thread free it safely.
 *
 * [write] puts all of the bytes through `write` (AudioTrack.write's shape) and returns how many went in. A paused
 * MODE_STREAM track takes only what fits its buffer: on a short write or 0 while [held] the calling thread waits until
 * the hold lifts, then writes the rest. A negative return stops; a 0 while playing stops rather than spin.
 *
 * Each track write runs under a lock together with the closed check; the hold is waited out outside it. [release]
 * marks the gate closed, interrupts a write blocked in the track, then frees the track under the same lock: freeing
 * never overlaps a native write, no write reaches a freed track, and a hold never delays the release.
 */
internal class PcmWriteGate(private val held: StateFlow<Boolean>) {
    private val closed = MutableStateFlow(false)
    private val lock = Any()

    fun write(bytes: ByteArray, write: (ByteArray, Int, Int) -> Int): Int {
        var offset = 0
        while (offset < bytes.size) {
            val n = synchronized(lock) {
                if (closed.value) -1 else write(bytes, offset, bytes.size - offset)
            }
            if (n < 0) break
            offset += n
            if (offset >= bytes.size) break
            if (held.value) {
                runBlocking { combine(held, closed) { h, c -> !h || c }.first { it } }
            } else if (n == 0) {
                break
            }
        }
        return offset
    }

    /** Ends a write waiting out a hold and refuses further writes. */
    fun close() {
        closed.value = true
    }

    /** [interrupt] wakes a write blocked in the track (pause / flush); [free] runs once no write is inside it. */
    fun release(interrupt: () -> Unit, free: () -> Unit) {
        close()
        interrupt()
        synchronized(lock) { free() }
    }
}

// ───────────── Ports used by the controller ─────────────

/** Signals from the audio pipeline. [onFrame] arrives on the capture thread; the rest on the main thread. */
interface ConversationAudioListener {
    fun onFrame(index: Long, db: Double)

    /** [speechProb] = latest speech probability from [speechModel] (null = no model this session). */
    fun onFrame(index: Long, db: Double, speechProb: Float?) = onFrame(index, db)

    /** This session's speech model, fed every captured frame on the capture thread; null = energy VAD (E-365). */
    val speechModel: SpeechProbModel? get() = null

    /** [privateRouteRemoved] = headphones / bluetooth went away (unplugged). */
    fun onRouteChanged(route: ConversationRoute, privateRouteRemoved: Boolean)

    /** ACTION_AUDIO_BECOMING_NOISY: stop the current sentence. */
    fun onBecomingNoisy()

    /** Transient focus loss (call, another app) = interruption began; regained = ended. */
    fun onInterruption(began: Boolean)

    /** AUDIOFOCUS_LOSS: focus is gone for good (another app took over playback); the conversation ends. */
    fun onFocusLost()

    fun onCaptureFailed()

    /**
     * The session could not be activated after [ConversationAudio.open] returned (focus denied, mode / routing
     * failed): no capture was started. Main thread.
     */
    fun onActivationFailed() = Unit

    /** Diagnostics: cumulative capture read counts, every 500 ms while the read thread runs. Main thread. */
    fun onCaptureStats(reads: Long, zeroReads: Long, errorReads: Long) = Unit

    /** Diagnostics: the capture read thread stopped on its own ([AudioRecordCapture.STOP_READ_ERROR] etc.). Main thread. */
    fun onCaptureStopped(reason: String) = Unit

    /** Diagnostics: the software sink gate changed (setMuted / setCapturePaused); [live] = capture not yet closed. Main thread. */
    fun onSinkGate(paused: Boolean, muted: Boolean, live: Boolean) = Unit
}

/** Per-session speech probability model (E-365): fed 20 ms frames on the capture thread. */
interface SpeechProbModel : AutoCloseable {
    /** Feeds one frame; returns the latest chunk's speech probability (0 before the first chunk), null once inference failed. */
    fun feed(frame: ShortArray): Float?

    /** Latest chunk inference time in nanoseconds (diagnostics); 0 before the first chunk. */
    val lastInferenceNanos: Long
}

/** Loads a [SpeechProbModel] off the main thread; throws when the model is unavailable. */
fun interface SpeechProbSource {
    fun load(): SpeechProbModel

    companion object {
        /** Silero VAD from the app assets. */
        fun silero(context: Context): SpeechProbSource {
            val appContext = context.applicationContext
            return SpeechProbSource { SileroSpeechProbModel(SileroVad.create(appContext)) }
        }
    }
}

/**
 * [SileroVad] as a [SpeechProbModel]. Feed (capture thread) and close (main thread) share one monitor, so close
 * never frees tensors under a running inference; frames fed after close or after a failed inference get null.
 */
internal class SileroSpeechProbModel(private val vad: SileroVad) : SpeechProbModel {
    private var usable = true

    @Volatile override var lastInferenceNanos: Long = 0L
        private set

    @Synchronized
    override fun feed(frame: ShortArray): Float? {
        if (!usable) return null
        try {
            vad.feed(frame)
        } catch (_: SileroVadUnavailableException) {
            usable = false
            return null
        }
        lastInferenceNanos = vad.lastInferenceNanos
        return vad.latestProb
    }

    @Synchronized
    override fun close() {
        usable = false
        vad.close()
    }
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

    /**
     * Suspends (never blocks main) until the session opened by [open] is activated: true once focus and routing
     * are in place, false when activation failed (focus denied, mode / routing error) or the session was closed first.
     */
    suspend fun awaitActivation(): Boolean = true

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

    /**
     * Live recognition of the open turn: [sink] gets the turn's samples so far (preroll included), then each captured
     * frame until [endTurn] / [cancelTurn]. Called on the main thread; frames arrive on the capture thread. No-op
     * without an open turn.
     */
    fun tapTurn(sink: PcmSink) = Unit

    /** Writes a turn as AAC (the dictation encoder) and returns the STT segment; null when writing fails. */
    suspend fun writeTurn(samples: ShortArray): STTSegment?

    /** Like [writeTurn] for the ✕ draft, but somewhere [close] doesn't clear, so the draft survives the teardown. */
    suspend fun writeDraft(samples: ShortArray): STTSegment? = writeTurn(samples)

    suspend fun playEarcon(kind: EarconKind)
}

/**
 * How one sentence ended. [endedAtMs] is when its sound actually stopped coming out, on the
 * [SystemClock.elapsedRealtime] clock (may be a little after [ConversationTts.speak] returns); null = unknown, the
 * caller takes the moment speak returned.
 */
data class TtsOutcome(val done: Boolean, val endedAtMs: Long? = null) {
    companion object {
        val DONE = TtsOutcome(done = true)
        val FAILED = TtsOutcome(done = false)

        fun done(endedAtMs: Long?) = TtsOutcome(done = true, endedAtMs = endedAtMs)
    }
}

/**
 * When the last written frame [targetFrame] comes out, extrapolated from an [AudioTrack.getTimestamp] reading
 * ([timestampFrame] played at [timestampNanos], [System.nanoTime] clock); never earlier than [markerAtMs], the
 * marker callback time, which is also the answer when there is no timestamp ([timestampNanos] null).
 */
@VisibleForTesting
internal fun playedOutAtMs(
    markerAtMs: Long,
    nowNanos: Long,
    timestampFrame: Long,
    timestampNanos: Long?,
    targetFrame: Long,
    sampleRate: Int,
): Long {
    if (timestampNanos == null || sampleRate <= 0) return markerAtMs
    val outNanos = timestampNanos + (targetFrame - timestampFrame) * 1_000_000_000L / sampleRate
    return maxOf(markerAtMs, markerAtMs + (outNanos - nowNanos) / 1_000_000L)
}

/** One sentence of speech through the conversation pipeline; cancelling stops it. */
interface ConversationTts {
    val isCloud: Boolean

    suspend fun speak(text: String, onLevel: (Float) -> Unit): TtsOutcome

    /**
     * Holds the sentence in progress at its current position (or makes the next [speak] start held); [resume] carries
     * on from there. The hold ends when [speak] returns or is cancelled. false = this voice can't hold a position:
     * nothing changed, the caller cancels and later restarts the sentence.
     */
    fun pause(): Boolean = false

    fun resume() = Unit

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

/**
 * Merges the interruption sources (transient focus loss, system silencing of the capture) into one began / ended
 * pair: began when the first source becomes active, ended only once every source has cleared, so overlapping
 * sources never repeat began or ended. A silencing still active after [SILENCE_TIMEOUT_MS] goes to
 * [onSilenceTimeout] (the conversation ends). Main thread only.
 */
internal class ConversationInterruptions(
    private val onInterruption: (began: Boolean) -> Unit,
    private val onSilenceTimeout: () -> Unit,
    /** Runs the action after the delay (ms); returns its cancel. */
    private val schedule: (delayMs: Long, action: () -> Unit) -> () -> Unit,
) {
    enum class Source { FOCUS, SILENCED }

    private val active = mutableSetOf<Source>()
    private var cancelSilenceTimeout: (() -> Unit)? = null

    fun update(source: Source, began: Boolean) {
        val wasInterrupted = active.isNotEmpty()
        val changed = if (began) active.add(source) else active.remove(source)
        if (!changed) return
        if (source == Source.SILENCED) {
            if (began) {
                cancelSilenceTimeout = schedule(SILENCE_TIMEOUT_MS) {
                    cancelSilenceTimeout = null
                    onSilenceTimeout()
                }
            } else {
                stopSilenceTimeout()
            }
        }
        val interrupted = active.isNotEmpty()
        if (interrupted != wasInterrupted) onInterruption(interrupted)
    }

    /** Session closed: drop the pending timeout; nothing is reported afterwards. */
    fun cancel() {
        stopSilenceTimeout()
        active.clear()
    }

    private fun stopSilenceTimeout() {
        cancelSilenceTimeout?.invoke()
        cancelSilenceTimeout = null
    }

    companion object {
        const val SILENCE_TIMEOUT_MS = 3_000L
    }
}

/** AudioRecord(VOICE_COMMUNICATION) with per-session AEC / NS: read the default state first, enable only if off. */
internal class CommunicationRecordSource private constructor(
    private val record: AudioRecord,
    private val effects: List<android.media.audiofx.AudioEffect>,
    val echoCancellerAvailable: Boolean,
    private val audioManager: AudioManager?,
    private val onSilenceChanged: (silenced: Boolean) -> Unit,
) : PcmSource {
    override fun read(buffer: ShortArray, offset: Int, size: Int): Int = record.read(buffer, offset, size)

    /**
     * Reports system silencing (isClientSilenced) and its release to [onSilenceChanged] instead of [onSilenced]:
     * the capture keeps reading through the silencing (zeros) so it resumes once released; the conversation treats
     * the silencing as an interruption. Already silenced at subscription counts. API 29+, callbacks on main except
     * the initial check (caller's thread).
     */
    override fun observeSilenced(onSilenced: () -> Unit): () -> Unit {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return {}
        val manager = audioManager ?: return {}
        val sessionId = record.audioSessionId
        fun report(configs: List<AudioRecordingConfiguration>) =
            onSilenceChanged(configs.any { it.clientAudioSessionId == sessionId && it.isClientSilenced })
        val callback = object : AudioManager.AudioRecordingCallback() {
            override fun onRecordingConfigChanged(configs: MutableList<AudioRecordingConfiguration>) = report(configs)
        }
        manager.registerAudioRecordingCallback(callback, Handler(Looper.getMainLooper()))
        report(manager.activeRecordingConfigurations)
        return { manager.unregisterAudioRecordingCallback(callback) }
    }

    override fun stop() = record.stop()

    override fun release() {
        effects.forEach { runCatching { it.release() } }
        record.release()
    }

    companion object {
        @SuppressLint("MissingPermission")
        /** Without [audioManager] (realtime path) silencing is not observed, as before. */
        fun open(
            audioManager: AudioManager? = null,
            onSilenceChanged: (silenced: Boolean) -> Unit = {},
        ): CommunicationRecordSource {
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
            return CommunicationRecordSource(record, effects, aecAvailable, audioManager, onSilenceChanged)
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
    private val sessions: AndroidAudioSessionCoordinator,
    private val turnDir: File,
    private val encoderFactory: () -> AacEncoder,
    private val newCapture: (openSource: () -> PcmSource) -> AudioCapture,
    private val teardowns: CaptureTeardownGate = CaptureTeardownGate.Shared,
) : ConversationAudio {
    constructor(
        context: Context,
        sessions: AndroidAudioSessionCoordinator,
        turnDir: File,
        encoderFactory: () -> AacEncoder = { MediaCodecAacEncoder() },
    ) : this(context, sessions, turnDir, encoderFactory, { AudioRecordCapture(it) })

    private val appContext = context.applicationContext
    private val mainHandler = Handler(Looper.getMainLooper())
    private val recorder = TurnRecorder()
    private val turnCounter = AtomicLong()
    private val ioScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    @Volatile private var muted = false

    @Volatile private var paused = false

    private var capture: AudioCapture? = null

    // Open's sweep of turn files a killed process left behind; the first turn write waits for it.
    @Volatile private var staleSweep: Job? = null

    // Cleared on close so frames read while the capture thread winds down on IO go nowhere.
    private var captureLive: AtomicBoolean? = null
    private var noisyReceiver: BroadcastReceiver? = null
    private var session: Session? = null

    /**
     * One open..close. Mode, routing, focus and device callbacks live on the coordinator thread; [closed] is set on
     * the main thread and read there before capture starts.
     */
    private class Session(
        val listener: ConversationAudioListener,
        val lease: AndroidAudioSessionCoordinator.Lease,
    ) {
        @Volatile var closed = false

        // Completes once activation has started capture or decided not to: close stops capture only after it.
        val activationDone = CompletableDeferred<Unit>()

        // Activation outcome for [awaitActivation]: true only after focus was granted; false on failure or close.
        val activated = CompletableDeferred<Boolean>()

        // A capture start deferred until earlier teardowns finish; written before [activationDone] completes.
        var captureStart: Job? = null
        var focusRequest: AudioFocusRequest? = null
        var deviceCallback: AudioDeviceCallback? = null

        // Focus loss and capture silencing merged into one interruption; main thread only.
        lateinit var interruptions: ConversationInterruptions
    }

    /** Read-only view for instrumented tests: BECOMING_NOISY is protected, so tests deliver to this receiver. */
    @get:VisibleForTesting
    internal val sessionNoisyReceiver: BroadcastReceiver? get() = noisyReceiver

    // Set by the capture source, which a deferred start opens on IO.
    @Volatile
    override var echoCancellerAvailable: Boolean = AcousticEchoCanceler.isAvailable()
        private set

    // Written on the coordinator thread (activation, device callbacks), read on main.
    @Volatile
    override var route: ConversationRoute = ConversationRoute.SPEAKER
        private set

    override fun open(listener: ConversationAudioListener, capture: Boolean) {
        // Drafts normally get deleted after transcription; leftovers from a killed process go after an hour.
        val draftCutoff = System.currentTimeMillis() - STALE_DRAFT_MS
        val drafts = draftDir
        ioScope.launch { drafts.listFiles()?.filter { it.lastModified() < draftCutoff }?.forEach { it.delete() } }
        // Close only deletes turns up to its own counter, so a crash leaves turn files behind: sweep them here.
        val turns = turnDir
        staleSweep = ioScope.launch {
            turns.listFiles()?.forEach { file -> if (TURN_FILE.matches(file.name)) file.delete() }
        }
        val opened = Session(listener, sessions.claim(AndroidAudioSessionCoordinator.Client.Conversation))
        opened.interruptions = ConversationInterruptions(
            onInterruption = { began -> listener.onInterruption(began) },
            onSilenceTimeout = { listener.onCaptureFailed() },
            schedule = { delayMs, action ->
                val runnable = Runnable { if (!opened.closed) action() }
                mainHandler.postDelayed(runnable, delayMs)
                ({ mainHandler.removeCallbacks(runnable) })
            },
        )
        session = opened
        try {
            registerNoisyReceiver(listener)
            val startCapture = if (capture) prepareCapture(opened) else null
            // Mode → route → focus on the coordinator thread; capture starts only once that is done.
            sessions.post { activate(opened, startCapture) }
        } catch (error: Exception) {
            opened.activated.complete(false)
            opened.activationDone.complete(Unit)
            close()
            throw error
        }
    }

    /** Delivers a business callback on the main thread, dropped once the session is closed. */
    private fun Session.deliver(block: ConversationAudioListener.() -> Unit) {
        mainHandler.post { if (!closed) listener.block() }
    }

    /** Feeds one interruption source on the main thread, dropped once the session is closed. */
    private fun Session.interrupt(source: ConversationInterruptions.Source, began: Boolean) {
        mainHandler.post { if (!closed) interruptions.update(source, began) }
    }

    private fun AudioSessionOps.activate(opened: Session, startCapture: (() -> Unit)?) {
        try {
            if (opened.closed) return
            enterSession()
            changeMode(AudioManager.MODE_IN_COMMUNICATION)
            val previous = route
            val next = currentRoute()
            route = next
            applyRoute(opened, next)
            if (!requestFocus(opened)) {
                opened.deliver { onActivationFailed() }
                return
            }
            registerRouteCallbacks(opened)
            // The controller may have read the route before activation picked it.
            if (next != previous) opened.deliver { onRouteChanged(next, privateRouteRemoved = false) }
            if (!opened.closed) startCapture?.invoke()
            opened.activated.complete(true)
        } catch (error: Exception) {
            opened.deliver { onActivationFailed() }
        } finally {
            opened.activated.complete(false)
            opened.activationDone.complete(Unit)
        }
    }

    /** False when focus is denied. */
    private fun AudioSessionOps.requestFocus(opened: Session): Boolean {
        val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE)
            .setAudioAttributes(VOICE_COMMUNICATION_ATTRIBUTES)
            .setOnAudioFocusChangeListener({ change ->
                when (change) {
                    AudioManager.AUDIOFOCUS_GAIN -> opened.interrupt(ConversationInterruptions.Source.FOCUS, began = false)
                    AudioManager.AUDIOFOCUS_LOSS -> opened.deliver { onFocusLost() }
                    AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
                    AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK,
                    -> opened.interrupt(ConversationInterruptions.Source.FOCUS, began = true)
                }
            }, sessions.handler)
            .build()
        if (requestFocus(request) != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) return false
        opened.focusRequest = request
        return true
    }

    /** Builds the capture on main; the returned start runs on the coordinator thread after activation. */
    private fun prepareCapture(opened: Session): () -> Unit {
        val listener = opened.listener
        val live = AtomicBoolean(true)
        val chunker = liveFrameChunker(live, recorder, listener)
        val sink = PcmSink { samples, count -> if (live.get() && !muted && !paused) chunker.add(samples, count) }
        val audioManager = appContext.getSystemService(AudioManager::class.java)
        val started = newCapture {
            CommunicationRecordSource.open(audioManager) { silenced ->
                opened.interrupt(ConversationInterruptions.Source.SILENCED, silenced)
            }.also { echoCancellerAvailable = it.echoCancellerAvailable }
        }
        val events = object : AudioCaptureEvents {
            override fun onFailure(error: Throwable) {
                mainHandler.post { listener.onCaptureFailed() }
            }

            // A capture that stopped on silencing never resumes: interruption began, the silence timeout ends it.
            override fun onInterrupted() = opened.interrupt(ConversationInterruptions.Source.SILENCED, began = true)

            override fun onStats(reads: Long, zeroReads: Long, errorReads: Long) {
                opened.deliver { onCaptureStats(reads, zeroReads, errorReads) }
            }

            override fun onStopped(reason: String) {
                opened.deliver { onCaptureStopped(reason) }
            }
        }
        captureLive = live
        capture = started
        return {
            // A capture closed just before still releases AudioRecord on IO: open the new one only after that.
            opened.captureStart = teardowns.startAfterTeardowns(
                ioScope,
                start = { started.start(listOf(sink), events) },
                onFailure = { mainHandler.post { if (live.get()) listener.onCaptureFailed() } },
            )
        }
    }

    private fun AudioSessionOps.currentRoute(): ConversationRoute =
        routeForOutputs(devices(AudioManager.GET_DEVICES_OUTPUTS).map { it.type })

    /** API 31+: pick the communication device; below: speakerphone on only when no private route exists. */
    private fun AudioSessionOps.applyRoute(opened: Session, target: ConversationRoute) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val devices = availableRoutes()
            val wanted = when (target) {
                ConversationRoute.BLUETOOTH -> devices.firstOrNull { it.type in BLUETOOTH_TYPES }
                ConversationRoute.HEADPHONES -> devices.firstOrNull { it.type in WIRED_TYPES }
                ConversationRoute.SPEAKER -> devices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
            }
            if (wanted != null) runCatching { routeTo(wanted) }
        } else {
            speakerphone(target == ConversationRoute.SPEAKER)
        }
    }

    /** Device callbacks arrive on the coordinator thread, so the route is re-picked there. */
    private fun AudioSessionOps.registerRouteCallbacks(opened: Session) {
        val ops = this
        val callback = object : AudioDeviceCallback() {
            override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) = refresh(removed = false)

            override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) = refresh(removed = true)

            private fun refresh(removed: Boolean) {
                if (opened.closed) return
                val previous = route
                val next = ops.currentRoute()
                if (next == previous) return
                route = next
                ops.applyRoute(opened, next)
                val privateRouteRemoved = removed && previous != ConversationRoute.SPEAKER
                opened.deliver { onRouteChanged(next, privateRouteRemoved) }
            }
        }
        registerDeviceCallback(callback)
        opened.deviceCallback = callback
    }

    private fun registerNoisyReceiver(listener: ConversationAudioListener) {
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

    /** Release focus; the session baseline is restored only while this session still holds the lease. */
    private fun AudioSessionOps.deactivate(closed: Session) {
        closed.deviceCallback?.let { unregisterDeviceCallback(it) }
        closed.deviceCallback = null
        closed.focusRequest?.let { abandonFocus(it) }
        closed.focusRequest = null
        if (sessions.release(closed.lease)) restoreBaseline()
    }

    override fun close() {
        // Same monitor as liveFrameChunker's check-and-write: no frame lands after this clear.
        synchronized(recorder) {
            captureLive?.set(false)
            recorder.clear()
        }
        captureLive = null
        val closing = session
        session = null
        closing?.closed = true
        closing?.interruptions?.cancel()
        closing?.activated?.complete(false)
        val stopping = capture
        capture = null
        if (closing != null) {
            val deactivate = { sessions.post { deactivate(closing) } }
            if (stopping != null) {
                // stop() joins the capture thread and releases AudioRecord: keep that off the main thread. It waits
                // for activation, then drops a deferred start or awaits a running one, so whatever capture opened
                // gets stopped; deactivation follows the stop.
                teardowns.launchTeardown(ioScope) {
                    try {
                        closing.activationDone.await()
                        closing.captureStart?.cancelAndJoin()
                        stopping.stop()
                    } finally {
                        deactivate()
                    }
                }
            } else {
                deactivate()
            }
        }
        noisyReceiver?.let { runCatching { appContext.unregisterReceiver(it) } }
        noisyReceiver = null
        muted = false
        paused = false
        deleteTurnFilesUpTo(turnDir, turnCounter.get(), ioScope)
    }

    override suspend fun awaitActivation(): Boolean = session?.activated?.await() ?: false

    override fun setMuted(muted: Boolean) {
        this.muted = muted
        recorder.clear()
        reportSinkGate()
    }

    override fun setCapturePaused(paused: Boolean) {
        this.paused = paused
        recorder.clear()
        reportSinkGate()
    }

    // Called on main by the controller, so the listener is invoked directly.
    private fun reportSinkGate() {
        val current = session?.takeIf { !it.closed } ?: return
        current.listener.onSinkGate(paused, muted, captureLive?.get() == true)
    }

    override fun beginTurn(prerollFrame: Long) = recorder.begin(prerollFrame)

    override fun endTurn(endFrame: Long): ShortArray? = recorder.end(endFrame)

    override fun cancelTurn() = recorder.cancel()

    override fun tapTurn(sink: PcmSink) = recorder.tap(sink)

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

    // A hold covers the speak in progress (its track or file player) and one that hasn't built its output yet.
    private val held = MutableStateFlow(false)
    @Volatile private var stream: PcmStream? = null
    @Volatile private var filePlayer: ChunkPlayer? = null

    override fun pause(): Boolean {
        held.value = true
        stream?.hold(true)
        filePlayer?.pause()
        return true
    }

    override fun resume() {
        held.value = false
        stream?.hold(false)
        filePlayer?.resume()
    }

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
        val stream = PcmStream(onLevel, held)
        this.stream = stream
        try {
            val synthesized = suspendCancellableCoroutine { cont ->
                listeners[id] = SynthesisListener(id, stream, cont)
                cont.invokeOnCancellation {
                    // A write blocked on a hold would otherwise keep the callback thread until release.
                    stream.close()
                    runCatching { engine.stop() }
                }
                if (engine.synthesizeToFile(text, Bundle(), file, id) != TextToSpeech.SUCCESS && cont.isActive) {
                    cont.resume(false)
                }
            }
            if (!synthesized) return TtsOutcome.FAILED
            return if (stream.framesWritten > 0) {
                TtsOutcome.done(stream.drain())
            } else {
                val player = MediaChunkPlayer(VOICE_COMMUNICATION_ATTRIBUTES, levelProbe = onLevel)
                filePlayer = player
                if (held.value) player.pause()
                if (player.play(file)) {
                    // onCompletion fires a little before the output path has played the tail.
                    TtsOutcome.done(SystemClock.elapsedRealtime() + COMPLETION_TAIL_MS)
                } else {
                    TtsOutcome.FAILED
                }
            }
        } finally {
            listeners.remove(id)
            if (this.stream === stream) this.stream = null
            filePlayer = null
            held.value = false
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

    /**
     * Streams engine PCM into an AudioTrack built from onBeginSynthesis' format. While [held] the track is paused at
     * its head: a write that fills the buffer waits there, and the rest plays from the same frame on resume.
     */
    private class PcmStream(private val onLevel: (Float) -> Unit, private val held: StateFlow<Boolean>) {
        private var track: AudioTrack? = null
        private val gate = PcmWriteGate(held)
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
                    .also { if (!held.value) it.play() }
            }.getOrNull()
        }

        @Synchronized
        fun hold(on: Boolean) {
            val t = track ?: return
            runCatching { if (on) t.pause() else t.play() }
        }

        // Runs on the engine's callback thread; may block there while held (see PcmWriteGate).
        fun write(bytes: ByteArray) {
            val t = synchronized(this) { track } ?: return
            val written = gate.write(bytes) { b, off, size -> t.write(b, off, size) }
            if (written > 0) framesWritten += written / bytesPerFrame
            if (is16Bit) onLevel(pcm16Level(bytes))
        }

        /** Ends a write waiting out a hold; the track is about to go. */
        fun close() {
            gate.close()
        }

        /**
         * Waits until the track has played everything written: a notification marker at the last frame, no polling.
         * A marker the track refuses leaves only the timeout (duration + slack), which still plays the tail.
         * Returns when the last frame actually comes out (see [playedOutAtMs]); null = no track.
         */
        suspend fun drain(): Long? {
            val t = synchronized(this) { track } ?: return null
            val target = framesWritten
            fun head() = t.playbackHeadPosition.toLong() and 0xffffffffL
            fun played() = head() >= target
            if (played()) return playedOutAt(t, target)
            try {
                // A hold stops the clock: the timeout restarts from what is left once playback resumes.
                while (!played()) {
                    held.first { !it }
                    val left = (target - head()).coerceAtLeast(0) * 1000 / t.sampleRate.coerceAtLeast(1)
                    val reached = withTimeoutOrNull(left + DRAIN_SLACK_MS) {
                        merge(flow { awaitMarker(t, target); emit(true) }, held.filter { it }.map { false }).first()
                    }
                    if (reached != false) break
                }
            } finally {
                runCatching { t.setPlaybackPositionUpdateListener(null) }
            }
            return playedOutAt(t, target)
        }

        private suspend fun awaitMarker(t: AudioTrack, target: Long) {
            fun played() = (t.playbackHeadPosition.toLong() and 0xffffffffL) >= target
            if (played()) return
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

        /** The head reached [target]; one timestamp reading says how far the output still lags (false = none). */
        private fun playedOutAt(t: AudioTrack, target: Long): Long {
            val markerAt = SystemClock.elapsedRealtime()
            val stamp = AudioTimestamp()
            val ok = runCatching { t.getTimestamp(stamp) }.getOrDefault(false)
            return playedOutAtMs(
                markerAtMs = markerAt,
                nowNanos = System.nanoTime(),
                timestampFrame = stamp.framePosition,
                timestampNanos = stamp.nanoTime.takeIf { ok },
                targetFrame = target,
                sampleRate = t.sampleRate,
            )
        }

        fun release() {
            val t = synchronized(this) { track.also { track = null } }
            // A callback that read the track before it was cleared may still be writing: the gate frees after it.
            gate.release(
                interrupt = {
                    t?.let {
                        runCatching { it.pause() }
                        runCatching { it.flush() }
                    }
                },
                free = { t?.release() },
            )
        }
    }

    private companion object {
        const val INIT_TIMEOUT_MS = 5_000L
        const val DRAIN_SLACK_MS = 1_000L
        const val COMPLETION_TAIL_MS = 150L
    }
}

/** Cloud TTS for the conversation: [CloudSpeechEngine.synthesizeToFile] (same cache / request) + MediaPlayer. */
class CloudConversationTts(
    private val engine: CloudSpeechEngine,
    private val localeFor: suspend (String) -> Locale,
    /** Builds the player for one speak; it reports the measured playback level through the given callback. */
    private val playerFactory: (onLevel: (Float) -> Unit) -> ChunkPlayer = { onLevel ->
        MediaChunkPlayer(VOICE_COMMUNICATION_ATTRIBUTES, levelProbe = onLevel)
    },
    private val clock: () -> Long = { SystemClock.elapsedRealtime() },
) : ConversationTts {
    override val isCloud: Boolean = true

    // A hold made while the speech is still being synthesized applies to the player once it exists.
    private val lock = Any()
    private var held = false
    private var player: ChunkPlayer? = null

    override fun pause(): Boolean = synchronized(lock) {
        val p = player
        if (p != null && !p.pause()) return false
        held = true
        true
    }

    override fun resume() {
        synchronized(lock) {
            held = false
            player?.resume()
        }
    }

    override suspend fun speak(text: String, onLevel: (Float) -> Unit): TtsOutcome {
        try {
            return play(text, onLevel)
        } finally {
            synchronized(lock) {
                held = false
                player = null
            }
        }
    }

    private suspend fun play(text: String, onLevel: (Float) -> Unit): TtsOutcome {
        val files = engine.synthesizeToFile(text, localeFor(text)) ?: return TtsOutcome.FAILED
        val player = playerFactory(onLevel)
        synchronized(lock) {
            this.player = player
            // A player that can't hold plays on: the sentence was held before it could tell.
            if (held && !player.pause()) held = false
        }
        try {
            for ((index, audio) in files.withIndex()) {
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
            // onCompletion fires a little before the output path has played the tail.
            return TtsOutcome.done(clock() + COMPLETION_TAIL_MS)
        } finally {
            player.stop()
        }
    }

    private companion object {
        const val COMPLETION_TAIL_MS = 150L
    }
}
