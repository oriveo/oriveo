package ai.oriveo.community.core.voice.conversation

import android.app.Application
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import ai.oriveo.community.core.voice.AudioCapture
import ai.oriveo.community.core.voice.PcmSink
import java.util.concurrent.atomic.AtomicInteger
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * Production [AndroidConversationAudio]: close() returns on the main thread, and stopping capture (joining the capture thread) is not done on the main thread;
 * reopening right after close leaves only one capture instance; after close clears, no more frames are written into the recording buffer.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class AndroidConversationAudioTeardownTest {

    private val app = ApplicationProvider.getApplicationContext<Application>()

    /** Records the thread stop is called on; releases [stopped] once stop has finished. */
    private class ThreadRecordingCapture : AudioCapture {
        var starts = 0
        val stopThreads = mutableListOf<Thread>()
        val stopped = CountDownLatch(1)

        override fun start(sinks: List<PcmSink>) {
            starts++
        }

        override fun stop() {
            synchronized(stopThreads) { stopThreads += Thread.currentThread() }
            stopped.countDown()
        }
    }

    private object SilentListener : ConversationAudioListener {
        override fun onFrame(index: Long, db: Double) = Unit
        override fun onRouteChanged(route: ConversationRoute, privateRouteRemoved: Boolean) = Unit
        override fun onBecomingNoisy() = Unit
        override fun onInterruption(began: Boolean) = Unit
        override fun onFocusLost() = Unit
        override fun onCaptureFailed() = Unit
    }

    @Test
    fun `close stops capture off the main thread`() {
        val capture = ThreadRecordingCapture()
        val audio = AndroidConversationAudio(
            app,
            File(app.cacheDir, "conversation-teardown-turns"),
            encoderFactory = { error("no encoding in this test") },
            newCapture = { capture },
        )
        val main = Looper.getMainLooper().thread
        assertSame(main, Thread.currentThread())

        audio.open(SilentListener, capture = true)
        assertEquals(1, capture.starts)
        audio.close()

        assertTrue("capture stop never ran", capture.stopped.await(5, TimeUnit.SECONDS))
        val threads = synchronized(capture.stopThreads) { capture.stopThreads.toList() }
        assertEquals(1, threads.size)
        assertNotSame(main, threads.single())
    }

    /** Number of instances capturing at once: stop blocks on [release] until the test lets it go. */
    private class Mic {
        val active = AtomicInteger()
        val maxActive = AtomicInteger()
        val release = CountDownLatch(1)
    }

    private class GatedCapture(private val mic: Mic) : AudioCapture {
        val started = CountDownLatch(1)

        override fun start(sinks: List<PcmSink>) {
            val now = mic.active.incrementAndGet()
            mic.maxActive.accumulateAndGet(now) { a, b -> maxOf(a, b) }
            started.countDown()
        }

        override fun stop() {
            mic.release.await(5, TimeUnit.SECONDS)
            mic.active.decrementAndGet()
        }
    }

    @Test
    fun reopen_right_after_close_has_single_capture() {
        val mic = Mic()
        val captures = listOf(GatedCapture(mic), GatedCapture(mic))
        var built = 0
        val audio = AndroidConversationAudio(
            app,
            File(app.cacheDir, "conversation-reopen-turns"),
            encoderFactory = { error("no encoding in this test") },
            newCapture = { captures[built++] },
            teardowns = CaptureTeardownGate(),
        )

        audio.open(SilentListener, capture = true)
        assertEquals(0L, captures[0].started.count)
        audio.close()
        // The previous stop is still stuck on IO: reopen returns immediately, and the new capture waits for the mic to be released before starting.
        audio.open(SilentListener, capture = true)
        assertEquals(2, built)
        assertFalse(
            "second capture opened while the first was still stopping",
            captures[1].started.await(200, TimeUnit.MILLISECONDS),
        )

        mic.release.countDown()
        assertTrue("second capture never started", captures[1].started.await(5, TimeUnit.SECONDS))
        assertEquals(1, mic.maxActive.get())
        audio.close()
    }

    /** The previous stop was stuck past the limit: the new capture is not started (it does not coexist with the stuck AudioRecord) and is reported to the listener via onCaptureFailed. */
    @Test
    fun stuck_teardown_times_out_and_reports_failure() {
        val mic = Mic()
        val captures = listOf(GatedCapture(mic), GatedCapture(mic))
        var built = 0
        val failures = AtomicInteger()
        val listener = object : ConversationAudioListener by SilentListener {
            override fun onCaptureFailed() {
                failures.incrementAndGet()
            }
        }
        val audio = AndroidConversationAudio(
            app,
            File(app.cacheDir, "conversation-stuck-teardown-turns"),
            encoderFactory = { error("no encoding in this test") },
            newCapture = { captures[built++] },
            teardowns = CaptureTeardownGate(joinTimeoutMillis = 100),
        )

        audio.open(SilentListener, capture = true)
        audio.close()
        audio.open(listener, capture = true)
        // After waiting past the limit (100 ms): the second capture never started.
        assertFalse(
            "second capture opened while the first was still stopping",
            captures[1].started.await(500, TimeUnit.MILLISECONDS),
        )
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(1, failures.get())

        // After the stuck stop is released, the start that was dropped on timeout is not started late.
        mic.release.countDown()
        assertFalse(captures[1].started.await(300, TimeUnit.MILLISECONDS))
        assertEquals(1, mic.maxActive.get())
        audio.close()
    }

    /** The capture thread keeps delivering frames while the main thread closes midway: once close has cleared, not a single frame is left in the recording buffer. */
    @Test
    fun no_frame_written_after_close_clear() {
        val frames = AtomicInteger()
        val firstFrame = CountDownLatch(1)
        val listener = object : ConversationAudioListener by SilentListener {
            override fun onFrame(index: Long, db: Double) {
                frames.incrementAndGet()
                firstFrame.countDown()
            }
        }
        val capture = StreamingCapture()
        val audio = AndroidConversationAudio(
            app,
            File(app.cacheDir, "conversation-close-clear-turns"),
            encoderFactory = { error("no encoding in this test") },
            newCapture = { capture },
            teardowns = CaptureTeardownGate(),
        )

        audio.open(listener, capture = true)
        assertTrue("no frame reached the listener", firstFrame.await(5, TimeUnit.SECONDS))
        audio.close()
        assertTrue("capture stop never ran", capture.stopped.await(5, TimeUnit.SECONDS))

        audio.beginTurn(prerollFrame = 0)
        val left = audio.endTurn(endFrame = Long.MAX_VALUE)
        assertEquals("frames written after close cleared the recorder", 0, left?.size)
        assertTrue(frames.get() > 0)
    }

    /** Records the thread that lists the directory / deletes files; releases [deleted] once per deleted file. */
    private class RecordingDir(parent: File, name: String) : File(parent, name) {
        val threads = mutableListOf<Thread>()
        val deletedNames = mutableListOf<String>()
        val deleted = java.util.concurrent.Semaphore(0)

        override fun listFiles(): Array<File>? {
            synchronized(threads) { threads += Thread.currentThread() }
            return super.listFiles()?.map { child ->
                object : File(child.path) {
                    override fun delete(): Boolean {
                        val ok = super.delete()
                        synchronized(threads) {
                            threads += Thread.currentThread()
                            deletedNames += name
                        }
                        deleted.release()
                        return ok
                    }
                }
            }?.toTypedArray()
        }
    }

    // Regression: close listed the directory on the main thread and deleted every file it found (including turns the new session wrote after reopening).
    @Test
    fun close_deletes_only_turns_up_to_snapshot_off_main() {
        // Cleanup goes through a plain File: RecordingDir's listFiles only records the call triggered by close.
        File(app.cacheDir, "conversation-snapshot-turns").apply {
            deleteRecursively()
            mkdirs()
        }
        val dir = RecordingDir(app.cacheDir, "conversation-snapshot-turns")
        val capture = ThreadRecordingCapture()
        val audio = AndroidConversationAudio(
            app,
            dir,
            // The encoder throws: write has already taken a number (turnCounter increments) but writes no file; the test lays out the files itself.
            encoderFactory = { error("no encoding in this test") },
            newCapture = { capture },
            teardowns = CaptureTeardownGate(),
        )
        audio.open(SilentListener, capture = true)
        kotlinx.coroutines.runBlocking {
            repeat(2) { assertEquals(null, audio.writeTurn(ShortArray(1))) }
        }
        // turn-3 stands for a turn the new session wrote after close; other.txt is not a turn file.
        listOf("turn-1.aac", "turn-2.aac", "turn-3.aac", "other.txt").forEach { File(dir, it).writeText("x") }
        val main = Looper.getMainLooper().thread
        assertSame(main, Thread.currentThread())

        audio.close()

        assertTrue("turn files never deleted", dir.deleted.tryAcquire(2, 5, TimeUnit.SECONDS))
        assertFalse("deleted past the snapshot", dir.deleted.tryAcquire(1, 200, TimeUnit.MILLISECONDS))
        assertEquals(setOf("turn-1.aac", "turn-2.aac"), synchronized(dir.threads) { dir.deletedNames.toSet() })
        assertTrue(File(dir, "turn-3.aac").exists())
        assertTrue(File(dir, "other.txt").exists())
        val threads = synchronized(dir.threads) { dir.threads.toList() }
        assertTrue(threads.isNotEmpty())
        threads.forEach { assertNotSame("listed or deleted on the main thread", main, it) }
        File(dir.path).deleteRecursively()
    }

    /** Listing first blocks on [release] and records the listing thread. */
    private class GatedDir(parent: File, name: String) : File(parent, name) {
        val release = CountDownLatch(1)
        @Volatile var listThread: Thread? = null

        override fun listFiles(): Array<File>? {
            listThread = Thread.currentThread()
            release.await(5, TimeUnit.SECONDS)
            return super.listFiles()
        }
    }

    // Regression: close only deleted the turns in its snapshot, so turn-*.aac files left by a crashed process were never cleaned.
    @Test
    fun open_sweeps_stale_turn_files_before_first_turn() {
        File(app.cacheDir, "conversation-stale-turns").apply {
            deleteRecursively()
            mkdirs()
            listOf("turn-1.aac", "turn-42.aac", "other.txt").forEach { File(this, it).writeText("x") }
        }
        val dir = GatedDir(app.cacheDir, "conversation-stale-turns")
        val encoders = AtomicInteger()
        val audio = AndroidConversationAudio(
            app,
            dir,
            // The encoder throws: write counts once when it reaches the encoder lookup, and writes no file.
            encoderFactory = {
                encoders.incrementAndGet()
                error("no encoding in this test")
            },
            newCapture = { ThreadRecordingCapture() },
            teardowns = CaptureTeardownGate(),
        )
        val main = Looper.getMainLooper().thread
        assertSame(main, Thread.currentThread())

        // open still returns while listing is stuck: cleanup is not on the main thread.
        audio.open(SilentListener, capture = true)
        val written = CountDownLatch(1)
        val writer = Thread {
            kotlinx.coroutines.runBlocking { audio.writeTurn(ShortArray(1)) }
            written.countDown()
        }.also { it.start() }
        assertFalse("first turn written before the sweep finished", written.await(200, TimeUnit.MILLISECONDS))
        assertEquals(0, encoders.get())

        dir.release.countDown()
        assertTrue("first turn write never ran", written.await(5, TimeUnit.SECONDS))
        writer.join()
        assertEquals(1, encoders.get())
        assertFalse(File(dir.path, "turn-1.aac").exists())
        assertFalse(File(dir.path, "turn-42.aac").exists())
        assertTrue(File(dir.path, "other.txt").exists())
        assertNotSame("listed on the main thread", main, dir.listThread)
        audio.close()
        File(dir.path).deleteRecursively()
    }

    /** Keeps delivering whole PCM frames on its own thread until stop (stop waits for the thread to exit). */
    private class StreamingCapture : AudioCapture {
        val stopped = CountDownLatch(1)
        @Volatile private var running = true
        private var thread: Thread? = null

        override fun start(sinks: List<PcmSink>) {
            val chunk = ShortArray(ConversationFrames.FRAME_SAMPLES) { 1000 }
            thread = Thread {
                while (running) sinks.forEach { it.onPcm(chunk, chunk.size) }
            }.also { it.start() }
        }

        override fun stop() {
            running = false
            thread?.join()
            stopped.countDown()
        }
    }
}
