package ai.oriveo.community.core.voice

import android.app.Application
import android.media.AudioManager
import android.os.HandlerThread
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import ai.oriveo.community.core.app.GlobalSnackbarManager
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements
import org.robolectric.shadow.api.Shadow
import org.robolectric.shadows.ShadowAudioManager

/** Production [AndroidReadAloudEnvironment]: focus request and release run on the coordinator thread; focus callbacks switch back to the main thread. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], shadows = [AndroidReadAloudEnvironmentTest.ThreadRecordingAudioManager::class])
class AndroidReadAloudEnvironmentTest {

    /** Records the threads that request and abandon focus. */
    @Implements(AudioManager::class)
    class ThreadRecordingAudioManager : ShadowAudioManager() {
        val requestThreads = mutableListOf<Thread>()
        val abandonThreads = mutableListOf<Thread>()

        @Implementation
        override fun requestAudioFocus(audioFocusRequest: android.media.AudioFocusRequest): Int {
            synchronized(requestThreads) { requestThreads += Thread.currentThread() }
            return super.requestAudioFocus(audioFocusRequest)
        }

        @Implementation
        override fun abandonAudioFocusRequest(audioFocusRequest: android.media.AudioFocusRequest): Int {
            synchronized(abandonThreads) { abandonThreads += Thread.currentThread() }
            return super.abandonAudioFocusRequest(audioFocusRequest)
        }
    }

    private class RecordingListener : ReadAloudEnvironment.SessionListener {
        val interruptedThreads = mutableListOf<Thread>()
        override fun onInterrupted() {
            interruptedThreads += Thread.currentThread()
        }
        override fun onBackgrounded() = Unit
    }

    private val app = ApplicationProvider.getApplicationContext<Application>()
    private val audioManager = app.getSystemService(AudioManager::class.java)
    private val shadow = Shadow.extract<ThreadRecordingAudioManager>(audioManager)
    private val thread = HandlerThread("test-audio-session").apply { start() }
    private val coordinator = AndroidAudioSessionCoordinator(app, thread.looper)
    private val environment = AndroidReadAloudEnvironment(app, GlobalSnackbarManager(), coordinator)

    @After
    fun quit() {
        environment.endSession()
        shadowOf(thread.looper).idle()
        thread.quitSafely()
    }

    @Test
    fun `focus request and release run off the main thread`() {
        val main = Looper.getMainLooper().thread
        assertSame(main, Thread.currentThread())

        val granted = runBlocking { environment.beginSession(RecordingListener()) }

        assertTrue(granted)
        val requested = synchronized(shadow.requestThreads) { shadow.requestThreads.toList() }
        assertEquals(1, requested.size)
        assertNotSame(main, requested.single())
        assertSame(thread, requested.single())
        val request = shadow.lastAudioFocusRequest?.audioFocusRequest
        assertNotNull(request)
        assertEquals(AndroidAudioSessionCoordinator.Client.ReadAloud, coordinator.current?.client)

        environment.endSession()
        shadowOf(thread.looper).idle()

        val abandoned = synchronized(shadow.abandonThreads) { shadow.abandonThreads.toList() }
        assertEquals(1, abandoned.size)
        assertSame(thread, abandoned.single())
        assertSame(request, shadow.lastAbandonedAudioFocusRequest)
        assertNull(coordinator.current)
    }

    @Test
    fun `focus loss is delivered to the listener on the main thread`() {
        val listener = RecordingListener()
        runBlocking { environment.beginSession(listener) }
        val focusListener = shadow.lastAudioFocusRequest!!.listener

        // The system delivers focus changes on the Handler given at registration (the coordinator thread).
        coordinator.handler.post { focusListener.onAudioFocusChange(AudioManager.AUDIOFOCUS_LOSS) }
        shadowOf(thread.looper).idle()
        assertTrue("listener ran before the main thread", listener.interruptedThreads.isEmpty())
        shadowOf(Looper.getMainLooper()).idle()

        assertEquals(listOf(Looper.getMainLooper().thread), listener.interruptedThreads)
    }

    /** Blocks the coordinator thread until the returned gate is released. */
    private fun blockSessions(): java.util.concurrent.CountDownLatch {
        val gate = java.util.concurrent.CountDownLatch(1)
        coordinator.handler.post { gate.await(5, java.util.concurrent.TimeUnit.SECONDS) }
        return gate
    }

    // Old behavior: the lease was taken inside the coordinator's call block. A block cancelled while waiting for focus still took the lease and requested focus.
    @Test
    fun `cancelled while waiting for focus neither requests focus nor keeps the lease`() {
        val gate = blockSessions()
        runBlocking {
            val waiting = launch { environment.beginSession(RecordingListener()) }
            yield()
            waiting.cancelAndJoin()
        }
        gate.countDown()
        shadowOf(thread.looper).idle()

        assertTrue(synchronized(shadow.requestThreads) { shadow.requestThreads.toList() }.isEmpty())
        assertNull(coordinator.current)
    }

    @Test
    fun `release sent for a cancelled begin leaves the next begin's lease`() {
        val gate = blockSessions()
        val granted = runBlocking {
            val waiting = launch { environment.beginSession(RecordingListener()) }
            yield()
            waiting.cancelAndJoin()
            val next = async { environment.beginSession(RecordingListener()) }
            yield()
            val held = coordinator.current
            assertEquals(AndroidAudioSessionCoordinator.Client.ReadAloud, held?.client)
            gate.countDown()
            next.await().also { shadowOf(thread.looper).idle(); assertSame(held, coordinator.current) }
        }

        assertTrue(granted)
        assertEquals(1, synchronized(shadow.requestThreads) { shadow.requestThreads.size })
    }
}
