package ai.oriveo.community.core.voice.conversation

import android.media.AudioDeviceInfo
import java.io.ByteArrayOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread
import kotlin.math.abs
import kotlin.math.log10
import kotlinx.coroutines.flow.MutableStateFlow
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
    }

    @Test
    fun `level is relative to the floor - zero up to six dB above it and full thirty dB later`() {
        val floor = -50.0
        assertEquals(0f, ConversationFrames.levelFromDb(-60.0, floor))
        assertEquals(0f, ConversationFrames.levelFromDb(-44.0, floor), 0.0001f)
        assertEquals(0.5f, ConversationFrames.levelFromDb(-29.0, floor), 0.0001f)
        assertEquals(1f, ConversationFrames.levelFromDb(-14.0, floor), 0.0001f)
        assertEquals(1f, ConversationFrames.levelFromDb(0.0, floor))
        // A quieter room (lower floor) lifts the same frame.
        assertEquals(0.8f, ConversationFrames.levelFromDb(-40.0, -70.0), 0.0001f)
        assertEquals(-50.0, ConversationFrames.AI_LEVEL_FLOOR_DB, 0.0)
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
    fun `earcon segments follow the contract host rules`() {
        assertEquals(listOf(660.0 to 60, 880.0 to 60), Earcons.segments(EarconKind.START))
        assertEquals(listOf(880.0 to 60), Earcons.segments(EarconKind.HEARD))
        assertEquals(listOf(880.0 to 120), Earcons.segments(EarconKind.THINKING))
        assertEquals(listOf(660.0 to 110, 440.0 to 130), Earcons.segments(EarconKind.END))
        assertEquals(120, Earcons.durationMs(EarconKind.START))
        assertEquals(240, Earcons.durationMs(EarconKind.END))
        // Generated sample count equals the sum of the segment lengths
        assertEquals(16_000 * 240 / 1000, Earcons.samples(EarconKind.END, 16_000).size)
    }

    @Test
    fun `segmented earcon changes pitch between segments`() {
        val rate = 16_000
        val samples = Earcons.samples(EarconKind.START, rate)
        // Estimate each segment's pitch from zero crossings mid-segment: first 660 Hz, second 880 Hz
        fun hz(fromMs: Int, toMs: Int): Double {
            val from = rate * fromMs / 1000
            val to = rate * toMs / 1000
            var crossings = 0
            for (i in from + 1 until to) if ((samples[i - 1] < 0) != (samples[i] < 0)) crossings++
            return crossings / 2.0 / ((toMs - fromMs) / 1000.0)
        }
        assertEquals(660.0, hz(15, 55), 40.0)
        assertEquals(880.0, hz(65, 105), 40.0)
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

    /** Fake main-thread scheduler: records pending delays, fires them on demand. */
    private class InterruptionHarness {
        val events = mutableListOf<String>()
        val pending = mutableListOf<Pair<Long, () -> Unit>>()
        val interruptions = ConversationInterruptions(
            onInterruption = { began -> events += if (began) "began" else "ended" },
            onSilenceTimeout = { events += "captureFailed" },
            schedule = { delayMs, action ->
                val entry = delayMs to action
                pending += entry
                ({ pending.remove(entry) })
            },
        )

        fun fireTimers() = pending.toList().forEach { (_, action) -> pending.removeAt(0); action() }
    }

    @Test
    fun `capture silenced begins the interruption and its release ends it`() {
        val harness = InterruptionHarness()
        val silenced = ConversationInterruptions.Source.SILENCED

        harness.interruptions.update(silenced, began = true)
        harness.interruptions.update(silenced, began = true)
        assertEquals(listOf("began"), harness.events)
        assertEquals(listOf(ConversationInterruptions.SILENCE_TIMEOUT_MS), harness.pending.map { it.first })

        harness.interruptions.update(silenced, began = false)
        harness.interruptions.update(silenced, began = false)
        assertEquals(listOf("began", "ended"), harness.events)
        assertTrue("release cancels the timeout", harness.pending.isEmpty())
    }

    @Test
    fun `silenced for three seconds ends with capture failed`() {
        val harness = InterruptionHarness()

        harness.interruptions.update(ConversationInterruptions.Source.SILENCED, began = true)
        assertEquals(3_000L, harness.pending.single().first)
        harness.fireTimers()

        assertEquals(listOf("began", "captureFailed"), harness.events)
        // Released after the timeout already fired: no second failure, ended still reported once.
        harness.interruptions.update(ConversationInterruptions.Source.SILENCED, began = false)
        assertEquals(listOf("began", "captureFailed", "ended"), harness.events)
    }

    @Test
    fun `focus loss and silencing together begin and end the interruption once`() {
        val harness = InterruptionHarness()
        val focus = ConversationInterruptions.Source.FOCUS
        val silenced = ConversationInterruptions.Source.SILENCED

        harness.interruptions.update(focus, began = true)
        harness.interruptions.update(silenced, began = true)
        harness.interruptions.update(focus, began = false)
        assertEquals("still silenced", listOf("began"), harness.events)
        harness.interruptions.update(silenced, began = false)
        assertEquals(listOf("began", "ended"), harness.events)

        // Focus regained without a prior loss is not an interruption end.
        harness.interruptions.update(focus, began = false)
        assertEquals(listOf("began", "ended"), harness.events)
    }

    @Test
    fun `close cancels a pending silence timeout`() {
        val harness = InterruptionHarness()

        harness.interruptions.update(ConversationInterruptions.Source.SILENCED, began = true)
        harness.interruptions.cancel()

        assertTrue(harness.pending.isEmpty())
        assertEquals(listOf("began"), harness.events)
    }

    @Test
    fun `pcm level of little endian bytes`() {
        assertEquals(0f, pcm16Level(ByteArray(64)))
        val loud = ByteArray(64).also { b -> for (i in b.indices step 2) { b[i] = 0xff.toByte(); b[i + 1] = 0x7f } }
        assertTrue(pcm16Level(loud) > 0.99f)
        // Square wave at −29 dBFS RMS sits halfway up from the AI floor (−50 + 6 … −50 + 36).
        val amplitude = (32768 * Math.pow(10.0, -29.0 / 20)).toInt()
        val mid = ByteArray(640).also { b ->
            for (i in b.indices step 2) {
                val v = if ((i / 2) % 2 == 0) amplitude else -amplitude
                b[i] = (v and 0xff).toByte()
                b[i + 1] = (v shr 8).toByte()
            }
        }
        assertEquals(0.5f, pcm16Level(mid), 0.01f)
    }

    /** Fake MODE_STREAM track while paused: [room] bytes of buffer left; once full, writes are short or return 0. While playing, all bytes are accepted. */
    private class FakeTrack(var room: Int, val held: MutableStateFlow<Boolean>) {
        val sink = ByteArrayOutputStream()
        val calls = AtomicInteger()

        @Synchronized
        fun write(bytes: ByteArray, offset: Int, size: Int): Int {
            calls.incrementAndGet()
            val n = if (held.value) minOf(size, room) else size
            room -= n
            sink.write(bytes, offset, n)
            return n
        }
    }

    @Test
    fun `pcm write while held loses no bytes and writes the rest once resumed`() {
        val held = MutableStateFlow(true)
        val track = FakeTrack(room = 300, held = held)
        val bytes = ByteArray(1000) { it.toByte() }
        var written = -1
        val writer = thread { written = PcmWriteGate(held).write(bytes, track::write) }
        writer.join(300)
        // While paused: once the buffer is full, the write waits on the callback thread, dropping nothing and not spinning.
        assertTrue(writer.isAlive)
        assertEquals(300, track.sink.size())
        assertTrue(track.calls.get() <= 3)
        held.value = false
        writer.join(1_000)
        assertTrue(!writer.isAlive)
        assertEquals(1000, written)
        assertTrue(bytes.contentEquals(track.sink.toByteArray()))
    }

    @Test
    fun `pcm write held at a full buffer returns at once when cancelled`() {
        val held = MutableStateFlow(true)
        val gate = PcmWriteGate(held)
        val track = FakeTrack(room = 0, held = held)
        var written = -1
        val writer = thread { written = gate.write(ByteArray(640), track::write) }
        writer.join(200)
        assertTrue(writer.isAlive)
        val start = System.nanoTime()
        gate.close()
        writer.join(1_000)
        assertTrue(!writer.isAlive)
        assertTrue((System.nanoTime() - start) / 1_000_000 < 1_000)
        assertEquals(0, written)
    }

    @Test
    fun `pcm write stops on a negative return and counts only what went in`() {
        val held = MutableStateFlow(false)
        val results = ArrayDeque(listOf(200, -6))
        val written = PcmWriteGate(held).write(ByteArray(640)) { _, _, _ -> results.removeFirst() }
        assertEquals(200, written)
        assertTrue(results.isEmpty())
    }

    @Test
    fun `pcm release during a native write frees the track only after the write left it`() {
        val held = MutableStateFlow(false)
        val gate = PcmWriteGate(held)
        val inWrite = CountDownLatch(1)
        val interrupted = CountDownLatch(1)
        val freed = AtomicBoolean(false)
        val writesAfterFree = AtomicInteger()
        val freedWhileWriting = AtomicBoolean(false)
        val writing = AtomicBoolean(false)
        // Fake track blocked inside a native write: returns a short write only once release interrupts it (pause / flush).
        val writer = thread {
            gate.write(ByteArray(640)) { _, _, size ->
                if (freed.get()) writesAfterFree.incrementAndGet()
                writing.set(true)
                inWrite.countDown()
                interrupted.await(2, TimeUnit.SECONDS)
                writing.set(false)
                size / 2
            }
        }
        assertTrue(inWrite.await(1, TimeUnit.SECONDS))
        val releaser = thread {
            gate.release(
                interrupt = { interrupted.countDown() },
                free = {
                    if (writing.get()) freedWhileWriting.set(true)
                    freed.set(true)
                },
            )
        }
        releaser.join(1_000)
        writer.join(1_000)
        assertTrue(!releaser.isAlive && !writer.isAlive)
        assertTrue(freed.get())
        assertTrue(!freedWhileWriting.get())
        assertEquals(0, writesAfterFree.get())
        // Callbacks arriving after release never touch the track.
        assertEquals(0, gate.write(ByteArray(640)) { _, _, _ -> writesAfterFree.incrementAndGet() })
        assertEquals(0, writesAfterFree.get())
    }

    @Test
    fun `pcm release is not held up by a write waiting out the hold`() {
        val held = MutableStateFlow(true)
        val gate = PcmWriteGate(held)
        val track = FakeTrack(room = 0, held = held)
        var written = -1
        val writer = thread { written = gate.write(ByteArray(640), track::write) }
        writer.join(200)
        assertTrue(writer.isAlive)
        val calls = track.calls.get()
        val start = System.nanoTime()
        val freed = AtomicBoolean(false)
        val releaser = thread { gate.release(interrupt = {}, free = { freed.set(true) }) }
        releaser.join(1_000)
        writer.join(1_000)
        assertTrue(!releaser.isAlive && !writer.isAlive)
        assertTrue((System.nanoTime() - start) / 1_000_000 < 1_000)
        assertTrue(freed.get())
        assertEquals(true, held.value)
        assertEquals(0, written)
        assertEquals(calls, track.calls.get())
    }
}
