package ai.oriveo.community.core.voice.realtime

import android.content.Context
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Handler
import android.os.Looper
import ai.oriveo.community.core.voice.AudioCapture
import ai.oriveo.community.core.voice.AudioCaptureEvents
import ai.oriveo.community.core.voice.AudioRecordCapture
import ai.oriveo.community.core.voice.PcmSink
import ai.oriveo.community.core.voice.PcmSource
import ai.oriveo.community.core.voice.conversation.CaptureTeardownGate
import ai.oriveo.community.core.voice.conversation.CommunicationRecordSource
import ai.oriveo.community.core.voice.conversation.ConversationAudioException
import ai.oriveo.community.core.voice.conversation.ConversationFrames
import ai.oriveo.community.core.voice.conversation.EarconKind
import ai.oriveo.community.core.voice.conversation.FrameChunker
import ai.oriveo.community.core.voice.conversation.VOICE_COMMUNICATION_ATTRIBUTES
import ai.oriveo.community.core.voice.conversation.playEarconTrack
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch

/**
 * Realtime voice audio IO: communication-source capture uplinked as PCM16 LE frames at the rate the transport
 * declares (16 kHz passed through, or resampled to 24 kHz), plus 24 kHz PCM16 streaming playback with per-item
 * played-duration tracking.
 */
interface RealtimeAudioIO {
    /**
     * Starts capture and playback. [onFrame] gets 24 kHz PCM16 LE frames; [onInterruption] fires on focus loss.
     * An instance serves one session only: once [stop] has been called it cannot be started again.
     */
    fun start(onFrame: (ByteArray) -> Unit, onInterruption: () -> Unit)

    /**
     * [start] with [onFrame] getting PCM16 LE frames at [uplinkRateHz] ([RealtimePCM.INPUT_RATE] passes the
     * microphone through, [RealtimePCM.OUTPUT_RATE] resamples). Implementations without a real microphone may
     * ignore the rate; the default does.
     */
    fun start(onFrame: (ByteArray) -> Unit, onInterruption: () -> Unit, uplinkRateHz: Int) =
        start(onFrame, onInterruption)

    /** Queues 24 kHz PCM16 LE audio belonging to [itemId] for playback. */
    fun enqueue(pcm16: ByteArray, itemId: String)

    /** Milliseconds of [itemId] actually played so far; 0 when unknown. */
    fun playedMs(itemId: String): Long

    /** True while queued samples have not finished playing. */
    val isPlaying: Boolean

    /**
     * Registers the player's own completion callback: [onDrained] fires (on any thread) when the last queued sample
     * has played. Never fires after [stopPlayback] until more audio is queued. Hosts never poll [isPlaying] for this.
     */
    fun setOnDrained(onDrained: () -> Unit) = Unit

    /**
     * Drops everything queued and silences the output immediately.
     * Milliseconds already played per item are frozen and still reported by [playedMs].
     */
    fun stopPlayback()

    /** Stops capture and playback and releases audio focus. */
    fun stop()

    /** Plays a short earcon outside the assistant playback queue; returns when it has finished. */
    suspend fun playEarcon(kind: EarconKind) = Unit
}

/** Pure PCM helpers for the realtime path. */
object RealtimePCM {
    const val INPUT_RATE = 16_000
    const val OUTPUT_RATE = 24_000

    /**
     * Linear-interpolation 16 kHz → 24 kHz of the first [count] samples of [input] into the caller's [out] (at
     * least count * 3 / 2 long), so a capture loop reuses one buffer; returns the number of samples written.
     */
    fun resample16kTo24k(input: ShortArray, count: Int, out: ShortArray): Int {
        if (count == 0) return 0
        val outSize = count * OUTPUT_RATE / INPUT_RATE
        require(out.size >= outSize) { "output buffer holds ${out.size} samples, needs $outSize" }
        for (i in 0 until outSize) {
            // Source position = i * 2 / 3, split into integer index and fraction (in thirds).
            val num = i * INPUT_RATE
            val index = num / OUTPUT_RATE
            val frac = (num % OUTPUT_RATE).toDouble() / OUTPUT_RATE
            val a = input[index.coerceAtMost(count - 1)].toInt()
            val b = input[(index + 1).coerceAtMost(count - 1)].toInt()
            out[i] = (a + (b - a) * frac).toInt().coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort()
        }
        return outSize
    }

    fun toLittleEndian(samples: ShortArray, count: Int = samples.size): ByteArray {
        val out = ByteArray(count * 2)
        for (i in 0 until count) {
            val v = samples[i].toInt()
            out[i * 2] = (v and 0xFF).toByte()
            out[i * 2 + 1] = ((v shr 8) and 0xFF).toByte()
        }
        return out
    }
}

/**
 * Runs a blocking teardown step ([stop] joins the capture thread / releases native audio) on [scope] so the
 * calling (main) thread never waits for it; NonCancellable so a cancelled scope still finishes the teardown.
 */
internal fun launchTeardown(scope: CoroutineScope, stop: () -> Unit): Job =
    scope.launch(NonCancellable) { runCatching { stop() } }

/**
 * Production [RealtimeAudioIO]: AudioRecord(VOICE_COMMUNICATION) + AudioTrack(24 kHz, MODE_STREAM).
 * Single use: not reusable across sessions, [start] after [stop] throws.
 */
class AndroidRealtimeAudio internal constructor(
    context: Context,
    private val newCapture: (openSource: () -> PcmSource) -> AudioCapture,
    private val newTrack: () -> AudioTrack = ::buildPlaybackTrack,
    private val teardowns: CaptureTeardownGate = CaptureTeardownGate.Shared,
) : RealtimeAudioIO {
    constructor(context: Context) : this(context, { AudioRecordCapture(it) })

    private val audioManager = context.applicationContext.getSystemService(AudioManager::class.java)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val writer = Executors.newSingleThreadExecutor { Thread(it, "realtime-audio-out").apply { isDaemon = true } }
    private val lock = Any()
    private val stopped = AtomicBoolean(false)
    private val ioScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    // Guarded by [lock].
    private var capture: AudioCapture? = null
    private var captureStart: Job? = null
    private var track: AudioTrack? = null
    private var focusRequest: AudioFocusRequest? = null
    private var previousMode: Int? = null

    @Volatile private var onDrained: () -> Unit = {}

    // Guarded by [lock]. Frame counts are relative to the last flush (playbackHeadPosition resets there).
    private var framesQueued = 0L
    private var generation = 0L
    private val itemRanges = HashMap<String, LongArray>() // itemId -> [startFrame, endFrame)
    private val frozenMs = HashMap<String, Long>() // itemId -> ms played before earlier stopPlayback() calls

    override fun start(onFrame: (ByteArray) -> Unit, onInterruption: () -> Unit) =
        start(onFrame, onInterruption, RealtimePCM.OUTPUT_RATE)

    override fun start(onFrame: (ByteArray) -> Unit, onInterruption: () -> Unit, uplinkRateHz: Int) {
        require(uplinkRateHz == RealtimePCM.INPUT_RATE || uplinkRateHz == RealtimePCM.OUTPUT_RATE) {
            "unsupported uplink rate $uplinkRateHz"
        }
        check(!stopped.get()) { "AndroidRealtimeAudio is single use; create a new instance per session" }
        try {
            synchronized(lock) {
                check(!stopped.get()) { "stopped while starting" }
                previousMode = audioManager.mode
                audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
                requestFocus(onInterruption)
                track = newTrack().also {
                    attachDrainListener(it)
                    it.play()
                }
            }
            startCapture(onFrame, onInterruption, uplinkRateHz)
        } catch (error: Exception) {
            stop()
            throw error
        }
    }

    private fun requestFocus(onInterruption: () -> Unit) {
        val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE)
            .setAudioAttributes(VOICE_COMMUNICATION_ATTRIBUTES)
            .setOnAudioFocusChangeListener({ change ->
                when (change) {
                    AudioManager.AUDIOFOCUS_LOSS,
                    AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
                    AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK,
                    -> onInterruption()
                }
            }, mainHandler)
            .build()
        if (audioManager.requestAudioFocus(request) != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
            throw ConversationAudioException("audio focus denied")
        }
        synchronized(lock) { focusRequest = request }
    }

    override fun setOnDrained(onDrained: () -> Unit) {
        this.onDrained = onDrained
    }

    /** Maps the track's marker callback to [onDrained]: only the current track, before stop, queue fully played. */
    private fun attachDrainListener(built: AudioTrack) {
        built.setPlaybackPositionUpdateListener(
            object : AudioTrack.OnPlaybackPositionUpdateListener {
                override fun onMarkerReached(reached: AudioTrack) {
                    // A marker from before a flush or stop must not report a drain of the new queue.
                    val drained = synchronized(lock) {
                        !stopped.get() && track === reached && framesQueued > 0 && headFrames() >= framesQueued
                    }
                    if (drained) onDrained()
                }

                override fun onPeriodicNotification(track: AudioTrack) = Unit
            },
            mainHandler,
        )
    }

    private fun startCapture(onFrame: (ByteArray) -> Unit, onInterruption: () -> Unit, uplinkRateHz: Int) {
        // The microphone runs at 16 kHz: a 16 kHz uplink is encoded as is; 24 kHz reuses one buffer for the
        // resampled frame (frames arrive one at a time on the capture thread).
        val upsampled = if (uplinkRateHz == RealtimePCM.INPUT_RATE) {
            null
        } else {
            ShortArray(ConversationFrames.FRAME_SAMPLES * RealtimePCM.OUTPUT_RATE / RealtimePCM.INPUT_RATE)
        }
        val chunker = FrameChunker { _, frame ->
            if (upsampled == null) {
                onFrame(RealtimePCM.toLittleEndian(frame))
            } else {
                val count = RealtimePCM.resample16kTo24k(frame, frame.size, upsampled)
                onFrame(RealtimePCM.toLittleEndian(upsampled, count))
            }
        }
        val started = newCapture { CommunicationRecordSource.open() }
        val events = object : AudioCaptureEvents {
            override fun onFailure(error: Throwable) {
                mainHandler.post { onInterruption() }
            }

            override fun onInterrupted() = Unit
        }
        // A capture stopped just before (this or an earlier session) still releases AudioRecord on IO:
        // open the new one only after that.
        val startJob = teardowns.startAfterTeardowns(
            ioScope,
            start = { started.start(listOf(PcmSink { samples, count -> chunker.add(samples, count) }), events) },
            onFailure = { mainHandler.post { if (!stopped.get()) onInterruption() } },
        )
        val keep = synchronized(lock) {
            if (stopped.get()) false else {
                capture = started
                captureStart = startJob
                true
            }
        }
        // stop() raced with start(): the capture it could not see is stopped here.
        if (!keep) stopCapture(started, startJob)
    }

    /** Off the calling thread: drops a deferred start (or awaits one already running), then stops [stopping]. */
    private fun stopCapture(stopping: AudioCapture, pendingStart: Job?) {
        teardowns.launchTeardown(ioScope) {
            pendingStart?.cancelAndJoin()
            stopping.stop()
        }
    }

    override fun enqueue(pcm16: ByteArray, itemId: String) {
        val frames = (pcm16.size / BYTES_PER_FRAME).toLong()
        if (frames == 0L) return
        val gen = synchronized(lock) {
            val range = itemRanges.getOrPut(itemId) { longArrayOf(framesQueued, framesQueued) }
            framesQueued += frames
            range[1] = framesQueued
            // Completion callback when the head reaches the end of everything queued so far.
            track?.let { runCatching { it.setNotificationMarkerPosition(framesQueued.toInt()) } }
            generation
        }
        val bytes = pcm16.copyOf(frames.toInt() * BYTES_PER_FRAME)
        try {
            writer.execute {
                // Written in slices of at most 20 ms, re-checking the generation before each one so
                // stopPlayback()/stop() cut playback within one slice.
                var offset = 0
                while (offset < bytes.size) {
                    val t = synchronized(lock) { if (gen == generation) track else null } ?: return@execute
                    val size = minOf(SLICE_BYTES, bytes.size - offset)
                    // Blocking write on the writer thread; a concurrent pause+flush unblocks it.
                    val written = runCatching { t.write(bytes, offset, size) }.getOrDefault(-1)
                    if (written <= 0) return@execute
                    offset += written
                }
            }
        } catch (_: RejectedExecutionException) {
            // Writer already shut down by stop().
        }
    }

    private fun headFrames(): Long = track?.let { it.playbackHeadPosition.toLong() and 0xffffffffL } ?: 0L

    override fun playedMs(itemId: String): Long = synchronized(lock) {
        (frozenMs[itemId] ?: 0L) + livePlayedMs(itemId)
    }

    // Guarded by [lock]: ms of [itemId] played since the last flush.
    private fun livePlayedMs(itemId: String): Long {
        val range = itemRanges[itemId] ?: return 0L
        val played = (headFrames() - range[0]).coerceIn(0L, range[1] - range[0])
        return played * 1000 / RealtimePCM.OUTPUT_RATE
    }

    override val isPlaying: Boolean
        get() = synchronized(lock) { track != null && headFrames() < framesQueued }

    override fun stopPlayback() {
        synchronized(lock) {
            // Freeze what each item has played before the flush resets the playback head.
            for (itemId in itemRanges.keys) {
                frozenMs[itemId] = (frozenMs[itemId] ?: 0L) + livePlayedMs(itemId)
            }
            itemRanges.clear()
            generation++
            framesQueued = 0L
            track?.let {
                runCatching { it.pause() }
                runCatching { it.flush() }
                // The head restarts at 0: clear the marker so the old end position cannot fire.
                runCatching { it.setNotificationMarkerPosition(0) }
                runCatching { it.play() }
            }
        }
    }

    override fun stop() {
        if (!stopped.compareAndSet(false, true)) return
        // Drop the drain callback first: a marker posted before stop must not reach the controller.
        onDrained = {}
        val (stoppedCapture, pendingStart) = synchronized(lock) {
            (capture to captureStart).also {
                capture = null
                captureStart = null
            }
        }
        // AudioRecordCapture.stop() joins the capture thread and releases AudioRecord: keep it off the main thread.
        stoppedCapture?.let { stopCapture(it, pendingStart) }
        val released = synchronized(lock) {
            generation++
            framesQueued = 0L
            itemRanges.clear()
            frozenMs.clear()
            track?.let {
                // Unblocks a write in flight; the writer then sees the new generation and exits.
                runCatching { it.pause() }
                runCatching { it.flush() }
            }
            track.also { track = null }
        }
        // Released on the writer thread so it never races a write; then the writer is retired.
        if (released != null) {
            try {
                writer.execute { runCatching { released.release() } }
            } catch (_: RejectedExecutionException) {
                launchTeardown(ioScope) { released.release() }
            }
        }
        writer.shutdown()
        synchronized(lock) {
            focusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
            focusRequest = null
            previousMode?.let { audioManager.mode = it }
            previousMode = null
        }
    }

    override suspend fun playEarcon(kind: EarconKind) {
        if (stopped.get()) return
        playEarconTrack(kind)
    }

    private companion object {
        const val BYTES_PER_FRAME = 2

        /** 20 ms of 24 kHz mono PCM16. */
        const val SLICE_BYTES = RealtimePCM.OUTPUT_RATE / 50 * BYTES_PER_FRAME
    }
}

/** Production playback track: 24 kHz mono PCM16, MODE_STREAM, at least 200 ms of buffer. */
private fun buildPlaybackTrack(): AudioTrack {
    val rate = RealtimePCM.OUTPUT_RATE
    val mask = AudioFormat.CHANNEL_OUT_MONO
    val encoding = AudioFormat.ENCODING_PCM_16BIT
    val min = AudioTrack.getMinBufferSize(rate, mask, encoding)
    return AudioTrack.Builder()
        .setAudioAttributes(VOICE_COMMUNICATION_ATTRIBUTES)
        .setAudioFormat(AudioFormat.Builder().setEncoding(encoding).setSampleRate(rate).setChannelMask(mask).build())
        .setTransferMode(AudioTrack.MODE_STREAM)
        .setBufferSizeInBytes(maxOf(min, rate * PLAYBACK_BYTES_PER_FRAME / 5))
        .build()
}

private const val PLAYBACK_BYTES_PER_FRAME = 2
