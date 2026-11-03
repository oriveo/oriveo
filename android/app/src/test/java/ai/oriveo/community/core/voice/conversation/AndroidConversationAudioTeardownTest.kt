package ai.oriveo.community.core.voice.conversation

import android.app.Application
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import ai.oriveo.community.core.voice.AndroidAudioSessionCoordinator
import ai.oriveo.community.core.voice.AudioCapture
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import ai.oriveo.community.core.voice.PcmSink
import java.util.concurrent.atomic.AtomicInteger
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements
import org.robolectric.shadow.api.Shadow
import org.robolectric.shadows.AudioDeviceInfoBuilder
import org.robolectric.shadows.ShadowAudioManager

/**
 * Production [AndroidConversationAudio]: close() returns on the main thread, and stopping capture (joining the capture thread) is not done on the main thread;
 * reopening right after close leaves only one capture instance; after close clears, no more frames are written into the recording buffer.
 */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], shadows = [AndroidConversationAudioTeardownTest.CallbackHandlerAudioManager::class])
class AndroidConversationAudioTeardownTest {

    /** Records the Looper of the Handler given when the device callback was registered. */
    @Implements(AudioManager::class)
    class CallbackHandlerAudioManager : ShadowAudioManager() {
        @Volatile var deviceCallbackLooper: Looper? = null

        @Implementation
        override fun registerAudioDeviceCallback(callback: AudioDeviceCallback, handler: Handler?) {
            deviceCallbackLooper = handler?.looper
            super.registerAudioDeviceCallback(callback, handler)
        }
    }

    private val app = ApplicationProvider.getApplicationContext<Application>()
    private val sessionThread = HandlerThread("test-audio-session").apply { start() }
    private val sessions = AndroidAudioSessionCoordinator(app, sessionThread.looper)

    @After
    fun quitSessionThread() {
        sessionThread.quitSafely()
    }

    @After
    fun quitSessionThread() {
        sessionThread.quitSafely()
    }

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
            sessions,
            File(app.cacheDir, "conversation-teardown-turns"),
            encoderFactory = { error("no encoding in this test") },
            newCapture = { capture },
        )
        val main = Looper.getMainLooper().thread
        assertSame(main, Thread.currentThread())

        audio.open(SilentListener, capture = true)
        // Activation (including starting capture) finishes on the coordinator thread.
        shadowOf(sessionThread.looper).idle()
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

    // Old behavior: open threw synchronously when focus was denied; now activation runs on the coordinator thread and the result returns to main to report onActivationFailed.
    @Test
    fun focus_denied_reports_activation_failure_on_main_without_capture() {
        shadowOf(audioManager).setNextFocusRequestResponse(AudioManager.AUDIOFOCUS_REQUEST_FAILED)
        val failures = mutableListOf<Thread>()
        val listener = object : ConversationAudioListener by SilentListener {
            override fun onActivationFailed() {
                failures += Thread.currentThread()
            }
        }
        val capture = ActivationProbeCapture()
        val audio = probeAudio("conversation-focus-denied-turns", capture, CaptureTeardownGate())

        audio.open(listener, capture = true)
        shadowOf(sessionThread.looper).idle()
        shadowOf(Looper.getMainLooper()).idle()

        assertEquals(listOf(Looper.getMainLooper().thread), failures)
        assertEquals(0, capture.starts.get())
        audio.close()
    }

    @Test
    fun reopen_right_after_close_has_single_capture() {
        val mic = Mic()
        val captures = listOf(GatedCapture(mic), GatedCapture(mic))
        var built = 0
        val audio = AndroidConversationAudio(
            app,
            sessions,
            File(app.cacheDir, "conversation-reopen-turns"),
            encoderFactory = { error("no encoding in this test") },
            newCapture = { captures[built++] },
            teardowns = CaptureTeardownGate(),
        )

        audio.open(SilentListener, capture = true)
        shadowOf(sessionThread.looper).idle()
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
            sessions,
            File(app.cacheDir, "conversation-stuck-teardown-turns"),
            encoderFactory = { error("no encoding in this test") },
            newCapture = { captures[built++] },
            teardowns = CaptureTeardownGate(joinTimeoutMillis = 100),
        )

        audio.open(SilentListener, capture = true)
        // The first activation (including starting capture) finishes first, so close has a capturing instance to stop.
        shadowOf(sessionThread.looper).idle()
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
            // Production delivers frames through the three-argument onFrame; the `by` delegation forwards its default implementation to SilentListener, so overriding only the two-argument form receives nothing.
            override fun onFrame(index: Long, db: Double, speechProb: Float?) {
                frames.incrementAndGet()
                firstFrame.countDown()
            }
        }
        val capture = StreamingCapture()
        val audio = AndroidConversationAudio(
            app,
            sessions,
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
            sessions,
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
            sessions,
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

    // ───── Teardown: mode / focus / route / device callbacks go through the coordinator ─────

    private val audioManager = app.getSystemService(AudioManager::class.java)

    /** Records the mode and whether focus was requested when capture starts; stop blocks on [release] until released. */
    private inner class ActivationProbeCapture(gated: Boolean = false) : AudioCapture {
        val starts = AtomicInteger()
        @Volatile var modeAtStart: Int? = null
        @Volatile var focusAtStart = false
        val release = CountDownLatch(if (gated) 1 else 0)
        val stopped = CountDownLatch(1)

        override fun start(sinks: List<PcmSink>) {
            modeAtStart = audioManager.mode
            focusAtStart = shadowOf(audioManager).lastAudioFocusRequest != null
            starts.incrementAndGet()
        }

        override fun stop() {
            release.await(5, TimeUnit.SECONDS)
            stopped.countDown()
        }
    }

    private fun probeAudio(
        name: String,
        capture: AudioCapture,
        gate: CaptureTeardownGate,
    ) = AndroidConversationAudio(
        app,
        sessions,
        File(app.cacheDir, name),
        encoderFactory = { error("no encoding in this test") },
        newCapture = { capture },
        teardowns = gate,
    )

    // Old behavior: open changed the mode and requested focus synchronously on the main thread.
    @Test
    fun open_activates_on_the_coordinator_not_main() {
        val capture = ActivationProbeCapture()
        val audio = probeAudio("conversation-activate-turns", capture, CaptureTeardownGate())
        val session = shadowOf(sessionThread.looper)

        session.pause()
        audio.open(SilentListener, capture = true)
        assertEquals("mode changed on the main thread", AudioManager.MODE_NORMAL, audioManager.mode)
        assertNull("focus requested on the main thread", shadowOf(audioManager).lastAudioFocusRequest)
        assertEquals(0, capture.starts.get())

        session.unPause()
        session.idle()
        assertEquals(AudioManager.MODE_IN_COMMUNICATION, audioManager.mode)
        assertNotNull(shadowOf(audioManager).lastAudioFocusRequest)
        assertEquals(1, capture.starts.get())
        audio.close()
    }

    @Test
    fun capture_starts_only_after_activation() {
        val capture = ActivationProbeCapture()
        val audio = probeAudio("conversation-start-order-turns", capture, CaptureTeardownGate())

        audio.open(SilentListener, capture = true)
        shadowOf(sessionThread.looper).idle()

        assertEquals(1, capture.starts.get())
        assertEquals(AudioManager.MODE_IN_COMMUNICATION, capture.modeAtStart)
        assertTrue("capture started before focus was granted", capture.focusAtStart)
        audio.close()
    }

    // Old behavior: close released focus and restored the mode on the main thread, without waiting for capture to stop.
    @Test
    fun close_deactivates_after_capture_stops_off_main() {
        val gate = CaptureTeardownGate()
        val capture = ActivationProbeCapture(gated = true)
        val audio = probeAudio("conversation-deactivate-turns", capture, gate)
        val session = shadowOf(sessionThread.looper)
        audio.open(SilentListener, capture = true)
        session.idle()
        assertEquals(AudioManager.MODE_IN_COMMUNICATION, audioManager.mode)

        audio.close()
        session.idle()
        // Capture's stop is still blocked: neither mode nor focus has been touched.
        assertEquals("deactivated before capture stopped", AudioManager.MODE_IN_COMMUNICATION, audioManager.mode)
        assertNull(shadowOf(audioManager).lastAbandonedAudioFocusRequest)

        capture.release.countDown()
        assertTrue("capture teardown never finished", runBlocking { gate.awaitTeardowns() })
        assertEquals(0L, capture.stopped.count)
        session.idle()
        assertEquals(AudioManager.MODE_NORMAL, audioManager.mode)
        assertNotNull(shadowOf(audioManager).lastAbandonedAudioFocusRequest)
        assertNull(sessions.current)
    }

    @Test
    fun close_after_takeover_keeps_the_new_holders_mode() {
        val audio = probeAudio("conversation-takeover-turns", ActivationProbeCapture(), CaptureTeardownGate())
        val session = shadowOf(sessionThread.looper)
        audio.open(SilentListener, capture = false)
        session.idle()

        val other = sessions.claim(AndroidAudioSessionCoordinator.Client.Realtime)
        audio.close()
        session.idle()

        assertEquals("restored mode under another holder", AudioManager.MODE_IN_COMMUNICATION, audioManager.mode)
        assertSame(other, sessions.current)
        // Focus is released per its own request, regardless of the lease.
        assertNotNull(shadowOf(audioManager).lastAbandonedAudioFocusRequest)
    }

    // Old behavior: A's deactivation ran after B took the lease, and a false release did not restore; B's activation recorded the call mode A left as its own 'before',
    // and after close the mode stayed at MODE_IN_COMMUNICATION.
    @Test
    fun close_then_reopen_then_close_restores_the_idle_baseline() {
        val speaker = AudioDeviceInfoBuilder.newBuilder().setType(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER).build()
        shadowOf(audioManager).setOutputDevices(listOf(speaker))
        shadowOf(audioManager).setAvailableCommunicationDevices(listOf(speaker))
        audioManager.mode = AudioManager.MODE_NORMAL
        val session = shadowOf(sessionThread.looper)
        val first = probeAudio("conversation-baseline-a-turns", ActivationProbeCapture(), CaptureTeardownGate())
        first.open(SilentListener, capture = false)
        session.idle()
        assertEquals(AudioManager.MODE_IN_COMMUNICATION, audioManager.mode)

        first.close()
        val second = probeAudio("conversation-baseline-b-turns", ActivationProbeCapture(), CaptureTeardownGate())
        second.open(SilentListener, capture = false)
        session.idle()
        assertEquals(AudioManager.MODE_IN_COMMUNICATION, audioManager.mode)
        second.close()
        session.idle()

        assertEquals(AudioManager.MODE_NORMAL, audioManager.mode)
        assertNull(audioManager.communicationDevice)
        assertNull(sessions.current)
    }

    // Old behavior: device callbacks were attached to a main-thread Handler and re-selected the route on main.
    @Test
    fun device_change_reroutes_on_the_coordinator_thread() {
        val speaker = AudioDeviceInfoBuilder.newBuilder().setType(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER).build()
        val wired = AudioDeviceInfoBuilder.newBuilder().setType(AudioDeviceInfo.TYPE_WIRED_HEADSET).build()
        shadowOf(audioManager).setOutputDevices(listOf(speaker))
        shadowOf(audioManager).setAvailableCommunicationDevices(listOf(speaker, wired))
        val routes = mutableListOf<Pair<ConversationRoute, Thread>>()
        val listener = object : ConversationAudioListener by SilentListener {
            override fun onRouteChanged(route: ConversationRoute, privateRouteRemoved: Boolean) {
                routes += route to Thread.currentThread()
            }
        }
        val audio = probeAudio("conversation-reroute-turns", ActivationProbeCapture(), CaptureTeardownGate())
        val session = shadowOf(sessionThread.looper)
        audio.open(listener, capture = false)
        session.idle()
        assertEquals(ConversationRoute.SPEAKER, audio.route)
        assertSame(speaker, audioManager.communicationDevice)

        // Device callbacks are attached to the coordinator Handler and the framework delivers through it (Robolectric fires callbacks synchronously on the calling thread, so they are fired from the coordinator thread).
        // Re-selecting on main would throw at AudioSessionOps' thread assertion.
        assertSame(sessionThread.looper, Shadow.extract<CallbackHandlerAudioManager>(audioManager).deviceCallbackLooper)
        sessions.handler.post { shadowOf(audioManager).addOutputDevice(wired, true) }
        session.idle()
        shadowOf(Looper.getMainLooper()).idle()

        assertEquals(ConversationRoute.HEADPHONES, audio.route)
        assertSame(wired, audioManager.communicationDevice)
        assertEquals(listOf(ConversationRoute.HEADPHONES to Looper.getMainLooper().thread), routes)
        audio.close()
    }

    // Old behavior: open threw synchronously when focus was denied; now activation runs on the coordinator thread and the result returns to main to report onActivationFailed.
    @Test
    fun focus_denied_reports_activation_failure_on_main_without_capture() {
        shadowOf(audioManager).setNextFocusRequestResponse(AudioManager.AUDIOFOCUS_REQUEST_FAILED)
        val failures = mutableListOf<Thread>()
        val listener = object : ConversationAudioListener by SilentListener {
            override fun onActivationFailed() {
                failures += Thread.currentThread()
            }
        }
        val capture = ActivationProbeCapture()
        val audio = probeAudio("conversation-focus-denied-turns", capture, CaptureTeardownGate())

        audio.open(listener, capture = true)
        shadowOf(sessionThread.looper).idle()
        shadowOf(Looper.getMainLooper()).idle()

        assertEquals(listOf(Looper.getMainLooper().thread), failures)
        assertEquals(0, capture.starts.get())
        audio.close()
    }

    /** Starts awaitActivation on main: the call returns immediately (suspends rather than blocks main) and completes only once activation has a result. */
    private fun awaitOnMain(audio: AndroidConversationAudio): Deferred<Boolean> {
        assertSame(Looper.getMainLooper().thread, Thread.currentThread())
        return CoroutineScope(Dispatchers.Unconfined).async { audio.awaitActivation() }
    }

    @Test
    fun await_activation_is_true_once_activated() {
        val capture = ActivationProbeCapture()
        val audio = probeAudio("conversation-await-ok-turns", capture, CaptureTeardownGate())
        val session = shadowOf(sessionThread.looper)
        session.pause()
        audio.open(SilentListener, capture = true)
        val result = awaitOnMain(audio)
        assertFalse("awaitActivation finished before activation ran", result.isCompleted)

        session.unPause()
        session.idle()
        shadowOf(Looper.getMainLooper()).idle()
        assertTrue(result.isCompleted)
        assertTrue(result.getCompleted())
        assertEquals(1, capture.starts.get())
        audio.close()
    }

    @Test
    fun await_activation_is_false_when_focus_is_denied() {
        shadowOf(audioManager).setNextFocusRequestResponse(AudioManager.AUDIOFOCUS_REQUEST_FAILED)
        val capture = ActivationProbeCapture()
        val audio = probeAudio("conversation-await-denied-turns", capture, CaptureTeardownGate())
        val session = shadowOf(sessionThread.looper)
        session.pause()
        audio.open(SilentListener, capture = true)
        val result = awaitOnMain(audio)
        assertFalse(result.isCompleted)

        session.unPause()
        session.idle()
        shadowOf(Looper.getMainLooper()).idle()
        assertTrue(result.isCompleted)
        assertFalse(result.getCompleted())
        assertEquals(0, capture.starts.get())
        audio.close()
    }

    @Test
    fun await_activation_is_false_when_closed_before_activation() {
        val gate = CaptureTeardownGate()
        val capture = ActivationProbeCapture()
        val audio = probeAudio("conversation-await-closed-turns", capture, gate)
        val session = shadowOf(sessionThread.looper)

        session.pause()
        audio.open(SilentListener, capture = true)
        val result = awaitOnMain(audio)
        assertFalse(result.isCompleted)
        audio.close()
        assertTrue(result.isCompleted)
        assertFalse(result.getCompleted())
        session.unPause()
        assertTrue("capture teardown never finished", runBlocking { gate.awaitTeardowns() })
        session.idle()
        assertEquals(0, capture.starts.get())
    }

    @Test
    fun close_before_activation_never_starts_capture() {
        val gate = CaptureTeardownGate()
        val capture = ActivationProbeCapture()
        val audio = probeAudio("conversation-early-close-turns", capture, gate)
        val session = shadowOf(sessionThread.looper)

        session.pause()
        audio.open(SilentListener, capture = true)
        audio.close()
        session.unPause()
        assertTrue("capture teardown never finished", runBlocking { gate.awaitTeardowns() })
        session.idle()

        assertEquals(0, capture.starts.get())
        assertEquals(AudioManager.MODE_NORMAL, audioManager.mode)
        assertNull(shadowOf(audioManager).lastAudioFocusRequest)
        assertNull(sessions.current)
    }

    /** Moment the system TTS finishes playing: extrapolated from getTimestamp for the last frame's output; not earlier than the marker callback; without a timestamp it is the marker moment. */
    @Test
    fun system_tts_played_out_time_is_never_before_the_marker() {
        // Timestamp: frame 1000 is output at now - 10 ms; the last frame 1960 comes 960 frames later @ 16 kHz = 60 ms → marker + 50 ms
        val now = 5_000_000_000L
        assertEquals(
            10_050L,
            playedOutAtMs(10_000L, now, timestampFrame = 1_000, timestampNanos = now - 10_000_000L, targetFrame = 1_960, sampleRate = 16_000),
        )
        // A stale timestamp extrapolates to a moment earlier than the callback: use the callback moment
        assertEquals(
            10_000L,
            playedOutAtMs(10_000L, now, timestampFrame = 0, timestampNanos = now - 900_000_000L, targetFrame = 1_600, sampleRate = 16_000),
        )
        // getTimestamp returns false
        assertEquals(10_000L, playedOutAtMs(10_000L, now, timestampFrame = 0, timestampNanos = null, targetFrame = 1_600, sampleRate = 16_000))
    }
}
