package ai.oriveo.community.core.voice

import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AudioCaptureTest {

    /** Fake read source: returns scripted readings one by one; blocks once the script is exhausted, and returns ERROR_INVALID_OPERATION after stop (same as a real device after stop). */
    private class FakeSource(script: List<Int>) : PcmSource {
        private val results = LinkedBlockingQueue(script)
        val reads = AtomicInteger()
        var silencedListener: (() -> Unit)? = null
        var unsubscribed = false
        var stopped = false
        var released = false

        override fun read(buffer: ShortArray, offset: Int, size: Int): Int {
            val result = results.take()
            reads.incrementAndGet()
            if (result > 0) buffer.fill(1, offset, offset + result)
            return result
        }

        override fun observeSilenced(onSilenced: () -> Unit): () -> Unit {
            silencedListener = onSilenced
            return { unsubscribed = true }
        }

        override fun stop() {
            stopped = true
            results.put(ERROR_INVALID_OPERATION)
        }

        override fun release() {
            released = true
        }
    }

    private class RecordingEvents : AudioCaptureEvents {
        val failures = mutableListOf<Throwable>()
        var interruptions = 0
        val reported = CountDownLatch(1)

        @Synchronized
        override fun onFailure(error: Throwable) {
            failures += error
            reported.countDown()
        }

        @Synchronized
        override fun onInterrupted() {
            interruptions++
            reported.countDown()
        }
    }

    /** Fake disk-writing sink: the [failOnWrite]-th write throws IOException. */
    private class FakeSink(private val failOnWrite: Int = Int.MAX_VALUE) : PcmSink {
        val writes = AtomicInteger()

        override fun onPcm(samples: ShortArray, count: Int) {
            if (writes.incrementAndGet() == failOnWrite) throw IOException("disk full")
        }
    }

    private class Harness(script: List<Int>) {
        val source = FakeSource(script)
        val threads = mutableListOf<Thread>()
        val uncaught = mutableListOf<Throwable>()
        val capture = AudioRecordCapture(
            openSource = { source },
            newThread = { runnable ->
                Thread(runnable, "test-capture").also { thread ->
                    thread.setUncaughtExceptionHandler { _, error -> synchronized(uncaught) { uncaught += error } }
                    threads += thread
                }
            },
        )

        fun awaitThreadExit() {
            val thread = threads.single()
            thread.join(TIMEOUT_MS)
            assertFalse("capture thread must exit on its own", thread.isAlive)
        }
    }

    @Test
    fun sinkWriteThrowsStopsWritingReportsFailureOnceAndThreadExits() {
        val harness = Harness(List(50) { CHUNK })
        val sink = FakeSink(failOnWrite = 2)
        val recognizer = FakeSink()
        val events = RecordingEvents()

        harness.capture.start(listOf(sink, recognizer), events)

        assertTrue(events.reported.await(TIMEOUT_MS, TimeUnit.MILLISECONDS))
        harness.awaitThreadExit()
        assertEquals(1, events.failures.size)
        assertTrue(events.failures.single() is IOException)
        assertEquals(0, events.interruptions)
        assertEquals("no writes after the first error", 2, sink.writes.get())
        assertEquals("recognizer stops with the writer", 1, recognizer.writes.get())
        assertEquals("loop stops reading after the error", 2, harness.source.reads.get())
        assertTrue(harness.uncaught.isEmpty())

        harness.capture.stop()
        assertTrue(harness.source.released)
        assertEquals(1, events.failures.size)
    }

    @Test
    fun negativeReadReportsFailureOnce() {
        val harness = Harness(listOf(CHUNK, ERROR_DEAD_OBJECT, CHUNK))
        val sink = FakeSink()
        val events = RecordingEvents()

        harness.capture.start(listOf(sink), events)

        assertTrue(events.reported.await(TIMEOUT_MS, TimeUnit.MILLISECONDS))
        harness.awaitThreadExit()
        assertEquals(1, events.failures.size)
        assertTrue(events.failures.single().message.orEmpty().contains("$ERROR_DEAD_OBJECT"))
        assertEquals(0, events.interruptions)
        assertEquals("the chunk read before the error is kept", 1, sink.writes.get())
        assertTrue(harness.uncaught.isEmpty())
        harness.capture.stop()
    }

    @Test
    fun systemSilencingReportsInterruptedOnce() {
        val harness = Harness(listOf(CHUNK))
        val sink = FakeSink()
        val events = RecordingEvents()

        harness.capture.start(listOf(sink), events)
        val silenced = checkNotNull(harness.source.silencedListener) { "silence listener not registered" }
        silenced()
        silenced()
        // The read thread is blocked in read: let read return, and it wakes up, sees it has ended, and exits.
        harness.source.stop()

        harness.awaitThreadExit()
        assertEquals(1, events.interruptions)
        assertTrue(events.failures.isEmpty())
        assertTrue(harness.uncaught.isEmpty())

        harness.capture.stop()
        assertTrue(harness.source.unsubscribed)
        assertEquals(1, events.interruptions)
        assertTrue(events.failures.isEmpty())
    }

    @Test
    fun noCallbacksAfterStop() {
        val harness = Harness(listOf(CHUNK, CHUNK))
        val sink = FakeSink()
        val events = RecordingEvents()

        harness.capture.start(listOf(sink), events)
        harness.capture.stop()

        // stop makes read return an error code and a silencing change follows: neither counts.
        harness.source.silencedListener?.invoke()
        assertFalse(harness.threads.single().isAlive)
        assertTrue(harness.source.stopped)
        assertTrue(harness.source.unsubscribed)
        assertTrue(harness.source.released)
        assertTrue(events.failures.isEmpty())
        assertEquals(0, events.interruptions)
        assertTrue(harness.uncaught.isEmpty())
    }

    private companion object {
        const val CHUNK = 320
        const val ERROR_INVALID_OPERATION = -3
        const val ERROR_DEAD_OBJECT = -6
        const val TIMEOUT_MS = 5_000L
    }
}
