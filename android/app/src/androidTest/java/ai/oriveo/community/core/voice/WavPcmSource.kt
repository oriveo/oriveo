package ai.oriveo.community.core.voice

import android.os.SystemClock
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch

/**
 * Test [PcmSource] that plays a 16 kHz mono PCM_16BIT WAV at real-time pace, then [trailingSilenceMs] of silence,
 * then keeps returning silence until stopped. [drained] opens once the speech and the trailing silence were read.
 */
class WavPcmSource(
    wav: ByteArray,
    private val trailingSilenceMs: Long = 1_500,
) : PcmSource {
    private val samples: ShortArray = parse(wav)
    private val totalSamples = samples.size + (trailingSilenceMs * SAMPLE_RATE / 1_000).toInt()
    private var position = 0
    private var startedAt = -1L

    @Volatile
    private var stopped = false

    val drained = CountDownLatch(1)

    val speechSamples: Int get() = samples.size

    override fun read(buffer: ShortArray, offset: Int, size: Int): Int {
        if (stopped) return 0
        if (startedAt < 0) startedAt = SystemClock.uptimeMillis()
        // Pace like a microphone: chunk n is available once its audio time has elapsed.
        val dueAt = startedAt + (position + size).toLong() * 1_000 / SAMPLE_RATE
        val wait = dueAt - SystemClock.uptimeMillis()
        if (wait > 0) Thread.sleep(wait)
        for (index in 0 until size) {
            val at = position + index
            buffer[offset + index] = if (at < samples.size) samples[at] else 0
        }
        position += size
        if (position >= totalSamples) drained.countDown()
        return size
    }

    override fun observeSilenced(onSilenced: () -> Unit): () -> Unit = {}

    override fun stop() {
        stopped = true
    }

    override fun release() = Unit

    private companion object {
        const val SAMPLE_RATE = AudioRecordCapture.SAMPLE_RATE

        /** Walks RIFF chunks (afconvert inserts a FLLR chunk) and returns the `data` chunk as samples. */
        fun parse(wav: ByteArray): ShortArray {
            val bytes = ByteBuffer.wrap(wav).order(ByteOrder.LITTLE_ENDIAN)
            require(String(wav, 0, 4, Charsets.US_ASCII) == "RIFF" && String(wav, 8, 4, Charsets.US_ASCII) == "WAVE") {
                "not a WAVE file"
            }
            var at = 12
            while (at + 8 <= wav.size) {
                val id = String(wav, at, 4, Charsets.US_ASCII)
                val length = bytes.getInt(at + 4)
                val body = at + 8
                if (id == "fmt ") {
                    val channels = bytes.getShort(body + 2).toInt()
                    val rate = bytes.getInt(body + 4)
                    val bits = bytes.getShort(body + 14).toInt()
                    require(channels == 1 && rate == SAMPLE_RATE && bits == 16) { "expected 16 kHz mono 16-bit, got $channels/$rate/$bits" }
                } else if (id == "data") {
                    val count = minOf(length, wav.size - body) / 2
                    return ShortArray(count) { bytes.getShort(body + it * 2) }
                }
                at = body + length + (length and 1)
            }
            error("no data chunk")
        }
    }
}
