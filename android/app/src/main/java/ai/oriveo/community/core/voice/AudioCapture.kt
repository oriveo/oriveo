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
) : AudioCapture {
    constructor(context: Context) : this({ AudioRecordSource.open(context.applicationContext) })

    private var session: Session? = null

    override fun start(sinks: List<PcmSink>) = start(sinks, AudioCaptureEvents.NONE)

    @Synchronized
    override fun start(sinks: List<PcmSink>, events: AudioCaptureEvents) {
        check(session == null) { "AudioRecordCapture already started" }
        val source = openSource()
        val current = Session(source, sinks, events)
        current.unsubscribe = source.observeSilenced { current.end { events.onInterrupted() } }
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
    ) {
        val ended = AtomicBoolean(false)
        var unsubscribe: () -> Unit = {}
        var thread: Thread? = null

        /** The first event ends this capture and is reported; later events and events after stop are not reported. */
        fun end(report: () -> Unit) {
            if (ended.compareAndSet(false, true)) report()
        }

        fun readLoop() {
            val buffer = ShortArray(CHUNK_SAMPLES)
            try {
                while (!ended.get()) {
                    val read = source.read(buffer, 0, buffer.size)
                    if (ended.get()) return
                    if (read < 0) throw IOException("AudioRecord.read failed: $read")
                    if (read == 0) continue
                    sinks.forEach { it.onPcm(buffer, read) }
                }
            } catch (error: Exception) {
                end { events.onFailure(error) }
            }
        }
    }

    companion object {
        const val SAMPLE_RATE = 16_000

        /** 20 ms per chunk. */
        internal const val CHUNK_SAMPLES = 320
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
        fun open(context: Context): AudioRecordSource {
            val sampleRate = AudioRecordCapture.SAMPLE_RATE
            val minBuffer = AudioRecord.getMinBufferSize(sampleRate, CHANNEL, ENCODING)
            if (minBuffer <= 0) throw AudioCaptureInitException("getMinBufferSize failed: $minBuffer")
            val bufferBytes = maxOf(minBuffer, AudioRecordCapture.CHUNK_SAMPLES * BYTES_PER_SAMPLE * 2)
            val created = try {
                AudioRecord(MediaRecorder.AudioSource.MIC, sampleRate, CHANNEL, ENCODING, bufferBytes)
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
