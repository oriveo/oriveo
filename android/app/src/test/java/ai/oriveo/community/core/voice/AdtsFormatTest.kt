package ai.oriveo.community.core.voice

import java.io.File
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AdtsFormatTest {

    private val appleSample = File("src/test/resources/voice/sine-silence-16k.aac").readBytes()

    @Test
    fun `parses apple encoded adts file with id 1`() {
        val stream = AdtsFormat.parse(appleSample)
        assertEquals(1, (appleSample[1].toInt() shr 3) and 0x1)
        assertEquals(49, stream.frames.size)
        assertEquals(16000, stream.sampleRate)
        assertEquals(1, stream.channelCount)
        assertEquals(3.136, stream.durationSeconds!!, 1e-9)
        assertEquals(appleSample.size, stream.frames.last().let { it.offset + it.frameLength })
    }

    @Test
    fun `header bytes follow aosp aac writer layout`() {
        val auLength = 300
        val frameLength = 7 + auLength
        val expected = byteArrayOf(
            0xFF.toByte(),
            0xF1.toByte(),
            0x60,
            (0x40 or (frameLength shr 11)).toByte(),
            ((frameLength shr 3) and 0xFF).toByte(),
            (((frameLength and 0x7) shl 5) or 0x1F).toByte(),
            0xFC.toByte(),
        )
        assertArrayEquals(expected, AdtsFormat.header(auLength))
    }

    @Test
    fun `written frames round trip through parse`() {
        val aus = listOf(ByteArray(5) { it.toByte() }, ByteArray(0), ByteArray(2000) { (it * 7).toByte() }, ByteArray(1) { 0x42 })
        val bytes = aus.fold(ByteArray(0)) { acc, au -> acc + AdtsFormat.header(au.size) + au }
        val stream = AdtsFormat.parse(bytes)
        assertEquals(aus.size, stream.frames.size)
        aus.zip(stream.frames).forEach { (au, frame) -> assertArrayEquals(au, frame.payload) }
        assertEquals(16000, stream.sampleRate)
        assertEquals(1, stream.channelCount)
    }

    @Test
    fun `truncated trailing frame or residue counts only complete frames`() {
        val lastFrame = AdtsFormat.parse(appleSample).frames.last()
        val halfLast = appleSample.copyOf(lastFrame.offset + lastFrame.frameLength / 2)
        assertEquals(48, AdtsFormat.parse(halfLast).frames.size)
        val residue = appleSample + byteArrayOf(0xFF.toByte(), 0xF1.toByte(), 0x60)
        assertEquals(49, AdtsFormat.parse(residue).frames.size)
        val empty = AdtsFormat.parse(ByteArray(3))
        assertEquals(0, empty.frames.size)
        assertNull(empty.durationSeconds)
    }

    @Test
    fun `nine byte header with crc is parsed`() {
        val au = byteArrayOf(1, 2, 3, 4)
        val header = AdtsFormat.header(au.size + 2)
        header[1] = (header[1].toInt() and 0xFE).toByte()
        val crc = byteArrayOf(0x12, 0x34)
        val stream = AdtsFormat.parse(header + crc + au)
        assertEquals(1, stream.frames.size)
        assertEquals(9, stream.frames[0].headerLength)
        assertArrayEquals(au, stream.frames[0].payload)
    }

    @Test
    fun `audio specific config for lc 16k mono`() {
        val written = AdtsFormat.parse(AdtsFormat.header(3) + ByteArray(3)).frames.single()
        assertArrayEquals(byteArrayOf(0x14, 0x08), AdtsFormat.audioSpecificConfig(written))
        val apple = AdtsFormat.parse(appleSample).frames.first()
        assertArrayEquals(byteArrayOf(0x14, 0x08), AdtsFormat.audioSpecificConfig(apple))
    }
}
