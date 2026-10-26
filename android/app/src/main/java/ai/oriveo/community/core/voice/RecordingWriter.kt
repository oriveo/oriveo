package ai.oriveo.community.core.voice

import java.io.Closeable
import java.io.File
import java.io.FileOutputStream
import kotlin.math.log10
import kotlin.math.roundToInt

/**
 * Encodes PCM to AAC and writes it frame by frame as ADTS: each frame (7-byte header + AU) is written in one call and flushed immediately, so frames already written remain parseable after the process is killed.
 * It also produces an RMS dBFS envelope in 50 ms windows; digital-silence windows are null and a trailing partial window counts as a window.
 */
class RecordingWriter(
    file: File,
    private val encoder: AacEncoder,
    private val sampleRate: Int = SAMPLE_RATE,
) : PcmSink, Closeable {
    private val output = FileOutputStream(file)
    private val accumulator = EnvelopeAccumulator(sampleRate)
    private var closed = false

    /** Number of ADTS frames written to the file. */
    var frameCount: Int = 0
        private set

    /** Number of PCM samples received. */
    var sampleCount: Long = 0
        private set

    val durationSec: Double
        @Synchronized get() = sampleCount.toDouble() / sampleRate

    /** Uses the encoder-reported delay if there is one, otherwise 1600 as for FDK AAC-LC. */
    val primingFrames: Int
        get() = encoder.encoderDelay ?: DEFAULT_PRIMING_FRAMES

    /** Window count = ceil(duration / 0.05). */
    val envelope: List<Double?>
        @Synchronized get() = accumulator.envelope

    @Synchronized
    override fun onPcm(samples: ShortArray, count: Int) = write(samples, count)

    @Synchronized
    fun write(samples: ShortArray, count: Int = samples.size) {
        check(!closed) { "RecordingWriter is closed" }
        require(count in 0..samples.size) { "count out of range: $count" }
        if (count == 0) return
        accumulator.add(samples, count)
        sampleCount += count
        writeUnits(encoder.encode(samples, count))
    }

    /** Drains the encoder, writes the remaining frames and closes the file; repeated calls have no effect. */
    @Synchronized
    override fun close() {
        if (closed) return
        closed = true
        try {
            writeUnits(encoder.finish())
        } finally {
            try {
                output.close()
            } finally {
                encoder.release()
            }
        }
    }

    private fun writeUnits(units: List<AacEncodedUnit>) {
        for (unit in units) {
            if (unit.isCodecConfig || unit.data.isEmpty()) continue
            output.write(AdtsFormat.header(unit.data.size) + unit.data)
            output.flush()
            frameCount++
        }
    }

    companion object {
        const val SAMPLE_RATE = 16_000
        const val DEFAULT_PRIMING_FRAMES = 1600
        private const val FULL_SCALE = 32768.0

        /** RMS dBFS (full scale 32768); null for all zeros. */
        fun windowLevel(sumSquares: Double, count: Int): Double? {
            if (count == 0 || sumSquares == 0.0) return null
            val meanSquare = sumSquares / count / (FULL_SCALE * FULL_SCALE)
            return 10 * log10(meanSquare)
        }
    }
}

/** Accumulator for the 50 ms-window RMS dBFS envelope: digital-silence windows are null and a trailing partial window counts as a window; shared by normal recording and crash recovery. */
class EnvelopeAccumulator(sampleRate: Int = RecordingWriter.SAMPLE_RATE) {
    private val windowSamples = (sampleRate * DictationRules.WINDOW_SEC).roundToInt()
    private val completedWindows = mutableListOf<Double?>()
    private val window = PcmWindowAccumulator()

    /** Window count = ceil(sample count / window length). */
    val envelope: List<Double?>
        get() {
            val windows = completedWindows.toMutableList()
            if (window.count > 0) windows += window.level()
            return windows
        }

    fun add(samples: ShortArray, count: Int = samples.size) {
        for (i in 0 until count) add(samples[i])
    }

    fun add(sample: Short) {
        window.add(sample)
        if (window.count == windowSamples) completedWindows += window.drain()
    }
}

/**
 * Sum-of-squares accumulator for one window of PCM16 samples: shared by the recording envelope ([EnvelopeAccumulator]), the live uplink level window and the cascade playback level; the level is computed by [RecordingWriter.windowLevel].
 * Not thread-safe: an instance is used on a single thread only, and callers sharing it across threads must lock themselves (e.g. @Synchronized on the live uplink level window).
 */
class PcmWindowAccumulator {
    private var sumSquares = 0.0

    /** Number of samples accumulated in this window. */
    var count = 0
        private set

    fun add(sample: Short) {
        val value = sample.toDouble()
        sumSquares += value * value
        count++
    }

    /** Adds all samples of the little-endian PCM16 frame [frame] to the window. */
    fun addPcm16Le(frame: ByteArray) {
        for (i in 0 until frame.size / 2) {
            add(((frame[2 * i + 1].toInt() shl 8) or (frame[2 * i].toInt() and 0xff)).toShort())
        }
    }

    /** RMS dBFS of this window; null for an empty or all-zero window. */
    fun level(): Double? = RecordingWriter.windowLevel(sumSquares, count)

    /** Takes this window's level and clears it, starting the next window. */
    fun drain(): Double? = level().also { reset() }

    fun reset() {
        sumSquares = 0.0
        count = 0
    }
}
