package ai.oriveo.community.core.voice.realtime

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class RealtimePCMTest {
    @Test
    fun resample_to_24k_length() {
        // 20 ms @16 kHz = 320 samples → 20 ms @24 kHz = 480 samples
        val frame = ShortArray(320) { (it * 10).toShort() }
        val out = RealtimePCM.resample16kTo24k(frame)
        assertEquals(480, out.size)
        // Linear interpolation: output sample 3k lands exactly on input sample 2k
        assertEquals(frame[0], out[0])
        assertEquals(frame[2], out[3])
        assertEquals(frame[100], out[150])
        // Midpoints are interpolated proportionally: position 2/3 → 0 + (10-0)*2/3 ≈ 6
        assertEquals(6.toShort(), out[1])
        assertEquals(0, RealtimePCM.resample16kTo24k(ShortArray(0)).size)
    }

    @Test
    fun pcm16_le_round_trip() {
        val samples = shortArrayOf(0, 1, -1, Short.MAX_VALUE, Short.MIN_VALUE, 0x1234)
        val bytes = RealtimePCM.toLittleEndian(samples)
        assertEquals(samples.size * 2, bytes.size)
        // 0x1234 low byte first
        assertEquals(0x34.toByte(), bytes[10])
        assertEquals(0x12.toByte(), bytes[11])
        assertEquals(0xFF.toByte(), bytes[4])
        assertEquals(0xFF.toByte(), bytes[5])
        assertArrayEquals(samples, RealtimePCM.fromLittleEndian(bytes))
        // An odd trailing byte is dropped
        assertArrayEquals(shortArrayOf(0x1234), RealtimePCM.fromLittleEndian(byteArrayOf(0x34, 0x12, 0x7F)))
    }
}
