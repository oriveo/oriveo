package ai.oriveo.community.core.voice.conversation

import android.media.AudioDeviceInfo
import kotlin.math.abs
import kotlin.math.log10
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pure helpers for conversation audio: frame accumulation, pre-roll ring, earcons, route detection, levels. */
class VoiceConversationAudioTest {

    @Test
    fun `chunker cuts arbitrary chunks into numbered 20 ms frames`() {
        val frames = mutableListOf<Pair<Long, ShortArray>>()
        val chunker = FrameChunker { index, frame -> frames += index to frame }
        chunker.add(ShortArray(500) { it.toShort() }, 500)
        assertEquals(1, frames.size)
        chunker.add(ShortArray(500) { (500 + it).toShort() }, 140)
        assertEquals(2, frames.size)
        assertEquals(listOf(0L, 1L), frames.map { it.first })
        assertEquals(320, frames[1].second.size)
        assertEquals(320.toShort(), frames[1].second[0])
        assertEquals(639.toShort(), frames[1].second[319])
    }

    @Test
    fun `frame dB is RMS dBFS and digital silence is the clamp floor`() {
        assertEquals(VoiceConversationConstants.FRAME_MIN_DB, ConversationFrames.frameDb(ShortArray(320)), 0.0)
        val full = ShortArray(320) { if (it % 2 == 0) 32767 else -32768 }
        assertTrue(abs(ConversationFrames.frameDb(full)) < 0.01)
        assertEquals(0f, ConversationFrames.levelFromDb(-70.0))
        assertEquals(1f, ConversationFrames.levelFromDb(0.0))
    }

    @Test
    fun `turn starts at the preroll frame and ends inclusive at the end frame`() {
        val recorder = TurnRecorder(ringCapacity = 40)
        fun frame(i: Long) = ShortArray(320) { i.toShort() }
        for (i in 0L until 50L) recorder.onFrame(i, frame(i))
        // Ring keeps 10..49; the turn begins at 30 (speech at 45 minus 15 preroll frames).
        recorder.begin(30)
        for (i in 50L until 60L) recorder.onFrame(i, frame(i))
        val samples = recorder.end(55)!!
        assertEquals((55 - 30 + 1) * 320, samples.size)
        assertEquals(30.toShort(), samples.first())
        assertEquals(55.toShort(), samples.last())
        assertNull(recorder.end(60))
    }

    @Test
    fun `preroll older than the ring is not available and cancel drops the turn`() {
        val recorder = TurnRecorder(ringCapacity = 5)
        for (i in 0L until 10L) recorder.onFrame(i, ShortArray(320) { i.toShort() })
        recorder.begin(0)
        assertEquals(5 * 320, recorder.end(9)!!.size)
        recorder.begin(8)
        recorder.cancel()
        assertNull(recorder.end(9))
    }

    @Test
    fun `default ring covers preroll plus the barge-in onset run`() {
        assertTrue(
            TurnRecorder.DEFAULT_RING_FRAMES >= VoiceConversationConstants.PREROLL_FRAMES +
                VoiceConversationConstants.BARGE_IN_MIN_SPEECH_MS / VoiceConversationConstants.FRAME_MS,
        )
    }

    @Test
    fun `earcons are short sines at about minus 18 dBFS with silent edges`() {
        for (kind in EarconKind.entries) {
            val samples = Earcons.samples(kind, 16_000)
            val ms = samples.size * 1000 / 16_000
            assertTrue("$kind $ms ms", ms in 1..Earcons.MAX_MS)
            val peak = samples.maxOf { abs(it.toInt()) }
            val peakDb = 20 * log10(peak / 32767.0)
            assertEquals(kind.name, -18.0, peakDb, 0.2)
            assertTrue(abs(samples.first().toInt()) < 50)
            assertTrue(abs(samples.last().toInt()) < 50)
        }
    }

    @Test
    fun `route prefers bluetooth then wired then speaker`() {
        assertEquals(ConversationRoute.SPEAKER, routeForOutputs(listOf(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER)))
        assertEquals(
            ConversationRoute.HEADPHONES,
            routeForOutputs(listOf(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER, AudioDeviceInfo.TYPE_WIRED_HEADSET)),
        )
        assertEquals(
            ConversationRoute.BLUETOOTH,
            routeForOutputs(listOf(AudioDeviceInfo.TYPE_WIRED_HEADPHONES, AudioDeviceInfo.TYPE_BLUETOOTH_A2DP)),
        )
    }

    @Test
    fun `pcm level of little endian bytes`() {
        assertEquals(0f, pcm16Level(ByteArray(64)))
        val loud = ByteArray(64).also { b -> for (i in b.indices step 2) { b[i] = 0xff.toByte(); b[i + 1] = 0x7f } }
        assertTrue(pcm16Level(loud) > 0.99f)
    }
}
