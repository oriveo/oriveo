package ai.oriveo.community.core.voice

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioRecordingConfiguration
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.annotation.RequiresApi
import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/** Receives one chunk of PCM (16 kHz mono 16-bit); [samples] is valid only inside the callback, so copy it if you need to keep it. */
fun interface PcmSink {
    fun onPcm(samples: ShortArray, count: Int)
}

/**
  * Events that occur mid-capture: report only, no teardown. The controller switches back to the main thread and handles it as an interruption; the part already written stays in the slot.
  * Called back at most once per start (whichever of the two comes first is reported); no callbacks after stop.
  * onFailure is called on the capture thread and onInterrupted on the main thread: the caller must switch threads itself and must not call stop synchronously inside the callback.
 */
interface AudioCaptureEvents {
    /** A read error, or a sink (disk write / encoder / recognizer) threw; the capture thread has exited and delivers no more PCM. */
    fun onFailure(error: Throwable)

    /** The system silenced this recording (incoming call, another app grabbed the mic); the capture thread stopped delivering PCM. Not detected below API 29. */
    fun onInterrupted()

    /**
     * Diagnostics: the read thread reports the cumulative read count for this capture every [AudioRecordCapture.STATS_INTERVAL_MS] ([zeroReads] = reads that returned 0 samples,
     * [errorReads] = reads that returned a negative error code). It reports one final total before the read thread exits on its own. Callbacks run on the capture thread (on the main thread when exiting due to mute) and must not block.
     * Stats are not reported while read is blocked: no new stats and no [onStopped] after the last report means the read thread is stuck in read.
     */
    fun onStats(reads: Long, zeroReads: Long, errorReads: Long) = Unit

    /** Diagnostics: why the read thread stopped delivering PCM on its own ([AudioRecordCapture.STOP_READ_ERROR] etc.), reported before onFailure / onInterrupted. Exits caused by stop are not reported. */
    fun onStopped(reason: String) = Unit

    companion object {
        val NONE: AudioCaptureEvents = object : AudioCaptureEvents {
            override fun onFailure(error: Throwable) = Unit

            override fun onInterrupted() = Unit
        }
    }
}

/** Microphone capture: hands the same PCM chunk to each sink in turn (disk writer and recognizer). */
interface AudioCapture {
    fun start(sinks: List<PcmSink>)

    /** Same as [start], and also reports mid-capture errors and system silencing to [events]; implementations that cannot report ignore [events]. */
    fun start(sinks: List<PcmSink>, events: AudioCaptureEvents) = start(sinks)

    /** Stops capture and waits for the read thread to exit; no callbacks afterwards. */
    fun stop()
}

/** AudioRecord initialization failed (no permission, in use, or the device does not support 16 kHz mono). */
class AudioCaptureInitException(message: String) : IllegalStateException(message)

/** Capture read source: the few AudioRecord members this class uses, extracted as an interface so tests can use a fake source. */
interface PcmSource {
    /** Same as AudioRecord.read: returns the number of samples read; a negative value is an error code. */
    fun read(buffer: ShortArray, offset: Int, size: Int): Int

    /** Subscribes to system silencing; returns an unsubscribe. Returns a no-op when detection is unsupported. */
    fun observeSilenced(onSilenced: () -> Unit): () -> Unit

    fun stop()

    fun release()
}

/**
  * AudioRecord capture: reads on a dedicated thread; on a read or sink error it stops reading and reports onFailure, and when silenced by the system it stops delivering PCM and reports onInterrupted;
  * the capture thread never throws.
 */
class AudioRecordCapture internal constructor(
    private val openSource: () -> PcmSource,
    private val newThread: (Runnable) -> Thread = { Thread(it, THREAD_NAME) },
    /** Capture source for AudioRecord (MediaRecorder.AudioSource.*): VOICE_RECOGNITION for dictation, default MIC for conversation and realtime. */
    internal val audioSource: Int = MediaRecorder.AudioSource.MIC,
    /** Monotonic clock (ms), used only for the stats reporting interval. */
    private val clock: () -> Long = { System.nanoTime() / 1_000_000 },
    /** Read thread yield (ms) used when read keeps returning 0; test injection records it. */
    private val pause: (Long) -> Unit = { Thread.sleep(it) },
) : AudioCapture {
    constructor(
        context: Context,
        source: Int = MediaRecorder.AudioSource.MIC,
    ) : this({ AudioRecordSource.open(context.applicationContext, source) }, audioSource = source)

    private var session: Session? = null

    override fun start(sinks: List<PcmSink>) = start(sinks, AudioCaptureEvents.NONE)

    @Synchronized
    override fun start(sinks: List<PcmSink>, events: AudioCaptureEvents) {
        check(session == null) { "AudioRecordCapture already started" }
        val source = openSource()
        val current = Session(source, sinks, events, clock, pause)
        current.unsubscribe = source.observeSilenced {
            current.end {
                current.reportStats()
                events.onStopped(STOP_SILENCED)
                events.onInterrupted()
            }
        }
        session = current
        current.thread = newThread { current.readLoop() }.also { it.start() }
    }

    @Synchronized
    override fun stop() {
        val current = session ?: return
        session = null
        // Close reporting first: error codes and silencing changes read after stop do not count.
        current.ended.set(true)
        runCatching { current.unsubscribe() }
        runCatching { current.source.stop() }
        current.thread?.join()
        current.source.release()
    }

    private class Session(
        val source: PcmSource,
        val sinks: List<PcmSink>,
        val events: AudioCaptureEvents,
        val clock: () -> Long,
        val pause: (Long) -> Unit,
    ) {
        val ended = AtomicBoolean(false)

        // The read thread writes and the mute callback (main thread) reads the final value, so use atomic counters; no allocation inside the loop.
        val reads = AtomicLong()
        val zeroReads = AtomicLong()
        val errorReads = AtomicLong()
        var unsubscribe: () -> Unit = {}
        var thread: Thread? = null

        /** The first event ends this capture and is reported; later events and events after stop are not reported. */
        fun end(report: () -> Unit) {
            if (ended.compareAndSet(false, true)) report()
        }

        fun reportStats() = events.onStats(reads.get(), zeroReads.get(), errorReads.get())

        fun readLoop() {
            val buffer = ShortArray(CHUNK_SAMPLES)
            var statsAt = clock()
            var stage = STOP_READ_ERROR
            // Consecutive zero-read count: when the system mutes or the device has no data, read returns 0 immediately; yield from the second time on to avoid a hot loop.
            var zeroRun = 0
            try {
                while (!ended.get()) {
                    stage = STOP_READ_ERROR
                    val read = source.read(buffer, 0, buffer.size)
                    if (ended.get()) return
                    reads.incrementAndGet()
                    if (read < 0) {
                        errorReads.incrementAndGet()
                        throw IOException("AudioRecord.read failed: $read")
                    }
                    if (read == 0) zeroReads.incrementAndGet()
                    val now = clock()
                    if (now - statsAt >= STATS_INTERVAL_MS) {
                        statsAt = now
                        reportStats()
                    }
                    if (read == 0) {
                        if (zeroRun++ > 0) pause(ZERO_READ_YIELD_MS)
                        continue
                    }
                    zeroRun = 0
                    stage = STOP_SINK_ERROR
                    sinks.forEach { it.onPcm(buffer, read) }
                }
            } catch (error: Exception) {
                end {
                    reportStats()
                    events.onStopped(stage)
                    events.onFailure(error)
                }
            }
        }
    }

    companion object {
        const val SAMPLE_RATE = 16_000

        /** 20 ms per chunk. */
        internal const val CHUNK_SAMPLES = 320

        /** Diagnostic stats reporting interval. */
        const val STATS_INTERVAL_MS = 500L

        /** Yield duration per consecutive zero-returning read (at most 10 ms, under half of a 20 ms block). */
        const val ZERO_READ_YIELD_MS = 5L

        /** Read thread exit reasons: read returns a negative value or throws / a sink throws / the system mutes. */
        const val STOP_READ_ERROR = "read_error"
        const val STOP_SINK_ERROR = "sink_error"
        const val STOP_SILENCED = "silenced"
        private const val THREAD_NAME = "oriveo-audio-capture"
    }
}

/** Production read source: AudioRecord at 16 kHz / MONO / PCM_16BIT; silencing is detected with AudioRecordingCallback (API 29+). */
internal class AudioRecordSource private constructor(
    private val record: AudioRecord,
    private val audioManager: AudioManager?,
) : PcmSource {
    override fun read(buffer: ShortArray, offset: Int, size: Int): Int = record.read(buffer, offset, size)

    override fun observeSilenced(onSilenced: () -> Unit): () -> Unit {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return {}
        val manager = audioManager ?: return {}
        return registerSilenceCallback(manager, record.audioSessionId, onSilenced)
    }

    override fun stop() = record.stop()

    override fun release() = record.release()

    companion object {
        private const val CHANNEL = AudioFormat.CHANNEL_IN_MONO
        private const val ENCODING = AudioFormat.ENCODING_PCM_16BIT
        private const val BYTES_PER_SAMPLE = 2

        // The caller confirmed RECORD_AUDIO is granted before start; if not, AudioRecord initialization fails and is thrown as the dedicated error.
        @SuppressLint("MissingPermission")
        fun open(context: Context, source: Int = MediaRecorder.AudioSource.MIC): AudioRecordSource {
            val sampleRate = AudioRecordCapture.SAMPLE_RATE
            val minBuffer = AudioRecord.getMinBufferSize(sampleRate, CHANNEL, ENCODING)
            if (minBuffer <= 0) throw AudioCaptureInitException("getMinBufferSize failed: $minBuffer")
            val bufferBytes = maxOf(minBuffer, AudioRecordCapture.CHUNK_SAMPLES * BYTES_PER_SAMPLE * 2)
            val created = try {
                AudioRecord(source, sampleRate, CHANNEL, ENCODING, bufferBytes)
            } catch (error: Exception) {
                throw AudioCaptureInitException("AudioRecord construction failed: ${error.message}")
            }
            if (created.state != AudioRecord.STATE_INITIALIZED) {
                created.release()
                throw AudioCaptureInitException("AudioRecord not initialized")
            }
            try {
                created.startRecording()
            } catch (error: Exception) {
                created.release()
                throw AudioCaptureInitException("startRecording failed: ${error.message}")
            }
            if (created.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
                created.release()
                throw AudioCaptureInitException("AudioRecord did not enter recording state")
            }
            return AudioRecordSource(created, context.getSystemService(AudioManager::class.java))
        }

        /** Reports as soon as this session is silenced (isClientSilenced); already being silenced at registration counts too. The callback runs on the main thread. */
        @RequiresApi(Build.VERSION_CODES.Q)
        private fun registerSilenceCallback(
            manager: AudioManager,
            sessionId: Int,
            onSilenced: () -> Unit,
        ): () -> Unit {
            fun reportIfSilenced(configs: List<AudioRecordingConfiguration>) {
                if (configs.any { it.clientAudioSessionId == sessionId && it.isClientSilenced }) onSilenced()
            }
            val callback = object : AudioManager.AudioRecordingCallback() {
                override fun onRecordingConfigChanged(configs: MutableList<AudioRecordingConfiguration>) =
                    reportIfSilenced(configs)
            }
            manager.registerAudioRecordingCallback(callback, Handler(Looper.getMainLooper()))
            reportIfSilenced(manager.activeRecordingConfigurations)
            return { manager.unregisterAudioRecordingCallback(callback) }
        }
    }
}
