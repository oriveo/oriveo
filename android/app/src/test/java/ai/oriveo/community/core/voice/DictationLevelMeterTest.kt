package ai.oriveo.community.core.voice

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** [DictationLevelMeter]: dBFS mapping, keeps only the latest 24 values, publishes at most 15 times per second. */
class DictationLevelMeterTest {

    /** Square wave of amplitude [amplitude]: its RMS is amplitude / 32768. */
    private fun square(amplitude: Int, size: Int = 160) =
        ShortArray(size) { if (it % 2 == 0) amplitude.toShort() else (-amplitude).toShort() }

    @Test
    fun `rms dbfs maps minus60 to 0 and 0 to 1`() {
        // 32768 × 10^(-60/20) ≈ 32.77: near −60 dBFS maps to 0.
        assertEquals(0f, DictationLevelMeter.level(square(33), 160), 0.002f)
        // A full-scale square wave ≈ 0 dBFS maps to 1.
        assertEquals(1f, DictationLevelMeter.level(square(32767), 160), 0.001f)
        // −30 dBFS (≈ 1036) is exactly in the middle.
        assertEquals(0.5f, DictationLevelMeter.level(square(1036), 160), 0.002f)
        // Below −60 dBFS clamps to 0; digital silence and an empty chunk are 0.
        assertEquals(0f, DictationLevelMeter.level(square(10), 160), 0f)
        assertEquals(0f, DictationLevelMeter.level(ShortArray(160), 160), 0f)
        assertEquals(0f, DictationLevelMeter.level(ShortArray(0), 0), 0f)
        // Only the first count samples are used.
        val mixed = square(32767) + ShortArray(160)
        assertEquals(1f, DictationLevelMeter.level(mixed, 160), 0.001f)
    }

    @Test
    fun `keeps last 24`() {
        var now = 0L
        val meter = DictationLevelMeter { now }
        meter.start()
        repeat(30) { index ->
            // The first 6 chunks are full scale, then silence: only the last 24 chunks remain (all 0).
            val chunk = if (index < 6) square(32767) else ShortArray(160)
            meter.onPcm(chunk, chunk.size)
            now += 100
        }
        assertEquals(DictationLevelMeter.CAPACITY, meter.levels.value.size)
        assertTrue(meter.levels.value.all { it == 0f })

        meter.reset()
        assertEquals(emptyList<Float>(), meter.levels.value)
        // Chunks arriving after reset are ignored.
        meter.onPcm(square(32767), 160)
        assertEquals(emptyList<Float>(), meter.levels.value)
    }

    @Test
    fun `throttles to 15 per second`() {
        var now = 0L
        val meter = DictationLevelMeter { now }
        meter.start()
        var publishes = 0
        var previous = meter.levels.value
        // One chunk every 10 ms within 1 second.
        repeat(100) {
            meter.onPcm(square(1036), 160)
            if (meter.levels.value !== previous) publishes++
            previous = meter.levels.value
            now += 10
        }
        assertEquals(15, publishes)
        assertEquals(15, meter.levels.value.size)

        // Not published when less than 66 ms since the last publish; published at 66 ms.
        val throttled = DictationLevelMeter { now }
        throttled.start()
        throttled.onPcm(square(1036), 160)
        now += 65
        throttled.onPcm(square(1036), 160)
        assertEquals(1, throttled.levels.value.size)
        now += 1
        throttled.onPcm(square(1036), 160)
        assertEquals(2, throttled.levels.value.size)
    }
}
