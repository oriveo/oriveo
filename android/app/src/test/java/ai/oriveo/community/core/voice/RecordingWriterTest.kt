package ai.oriveo.community.core.voice

import java.io.File
import kotlin.math.PI
import kotlin.math.ceil
import kotlin.math.roundToInt
import kotlin.math.sin
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class RecordingWriterTest {

    @get:Rule
    val temp = TemporaryFolder()

    /** Emits one fixed-length AU per 1024 accumulated samples; emits a CODEC_CONFIG (ASC) before the first output. */
    private class FakeEncoder(override val encoderDelay: Int? = null) : AacEncoder {
        val emittedAus = mutableListOf<ByteArray>()
        var released = false
        private var pending = 0
        private var configSent = false

        override fun encode(samples: ShortArray, count: Int): List<AacEncodedUnit> {
            pending += count
            val out = mutableListOf<AacEncodedUnit>()
            while (pending >= 1024) {
                pending -= 1024
                out += emit()
            }
            return out
        }

        override fun finish(): List<AacEncodedUnit> {
            if (pending == 0) return emptyList()
            pending = 0
            return emit()
        }

        override fun release() {
            released = true
        }

        private fun emit(): List<AacEncodedUnit> {
            val out = mutableListOf<AacEncodedUnit>()
            if (!configSent) {
                configSent = true
                out += AacEncodedUnit(byteArrayOf(0x14, 0x08), isCodecConfig = true)
            }
            val index = emittedAus.size
            val au = ByteArray(AU_LENGTH) { (index * 31 + it).toByte() }
            emittedAus += au
            out += AacEncodedUnit(au, isCodecConfig = false)
            return out
        }
    }

    @Test
    fun `frames are readable before close and match emitted aus`() {
        val file = temp.newFile("rec.aac")
        val encoder = FakeEncoder()
        val writer = RecordingWriter(file, encoder)
        val chunk = ShortArray(320) { 1000 }
        repeat(50) { writer.write(chunk) } // 16000 samples -> 15 whole AUs

        val copied = file.readBytes()
        val partial = AdtsFormat.parse(copied)
        assertEquals(15, encoder.emittedAus.size)
        assertEquals(encoder.emittedAus.size, partial.frames.size)
        assertEquals(writer.frameCount, partial.frames.size)
        assertEquals(copied.size, partial.frames.last().let { it.offset + it.frameLength })
        encoder.emittedAus.zip(partial.frames).forEach { (au, frame) -> assertArrayEquals(au, frame.payload) }
        assertEquals(16000, partial.sampleRate)
        assertEquals(1, partial.channelCount)

        writer.close()
        val full = AdtsFormat.parse(file.readBytes())
        assertEquals(16, encoder.emittedAus.size)
        assertEquals(encoder.emittedAus.size, full.frames.size)
        assertEquals(true, encoder.released)
    }

    @Test
    fun `envelope gives null for digital silence and rms dbfs for sine`() {
        val writer = RecordingWriter(temp.newFile("env.aac"), FakeEncoder())
        writer.write(ShortArray(1600)) // two silent windows
        val amplitude = 0.1 * 32768 // -20 dBFS peak
        val sine = ShortArray(1600) { (amplitude * sin(2 * PI * 440 * it / 16000.0)).roundToInt().toShort() }
        writer.write(sine)
        writer.close()

        val envelope = writer.envelope
        assertEquals(4, envelope.size)
        assertNull(envelope[0])
        assertNull(envelope[1])
        assertEquals(-23.0, envelope[2]!!, 1.0)
        assertEquals(-23.0, envelope[3]!!, 1.0)
    }

    @Test
    fun `window count is ceil of duration including trailing partial window`() {
        val writer = RecordingWriter(temp.newFile("count.aac"), FakeEncoder())
        val total = 16000 + 801 // 1.050 0625 s
        val samples = ShortArray(total) { 500 }
        writer.write(samples, 900)
        writer.write(samples.copyOfRange(900, total), total - 900)
        val expected = ceil(writer.durationSec / DictationRules.WINDOW_SEC).toInt()
        assertEquals(22, expected)
        assertEquals(expected, writer.envelope.size)
        writer.close()
        assertEquals(expected, writer.envelope.size)
    }

    @Test
    fun `priming frames use encoder delay or default 1600`() {
        val reported = RecordingWriter(temp.newFile("a.aac"), FakeEncoder(encoderDelay = 2048))
        assertEquals(2048, reported.primingFrames)
        reported.close()
        val unreported = RecordingWriter(temp.newFile("b.aac"), FakeEncoder())
        assertEquals(1600, unreported.primingFrames)
        unreported.close()
    }

    private companion object {
        const val AU_LENGTH = 120
    }
}
