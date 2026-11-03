package ai.oriveo.community.core.voice

import android.app.Application
import android.media.AudioManager
import android.os.HandlerThread
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** [AndroidAudioSessionCoordinator]: operations run serially on the coordinator thread; a later caller after a lease takes over; calling operations off that thread throws. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class AndroidAudioSessionCoordinatorTest {

    private val app = ApplicationProvider.getApplicationContext<Application>()
    private val thread = HandlerThread("test-audio-session").apply { start() }
    private val coordinator = AndroidAudioSessionCoordinator(app, thread.looper)

    @After
    fun quit() {
        thread.quitSafely()
    }

    @Test
    fun `call runs operations off the main thread`() {
        val main = Looper.getMainLooper().thread
        assertSame(main, Thread.currentThread())

        val (ran, mode) = runBlocking { coordinator.call { Thread.currentThread() to currentMode() } }

        assertNotSame(main, ran)
        assertSame(thread, ran)
        assertEquals(AudioManager.MODE_NORMAL, mode)
    }

    @Test
    fun `post runs blocks in order off the main thread`() {
        val order = mutableListOf<Int>()
        val threads = mutableListOf<Thread>()
        (1..5).forEach { i ->
            coordinator.post {
                synchronized(order) {
                    order += i
                    threads += Thread.currentThread()
                }
                changeMode(if (i % 2 == 0) AudioManager.MODE_IN_COMMUNICATION else AudioManager.MODE_NORMAL)
            }
        }
        shadowOf(thread.looper).idle()

        assertEquals(listOf(1, 2, 3, 4, 5), synchronized(order) { order.toList() })
        synchronized(order) { threads.toList() }.forEach { assertSame(thread, it) }
        assertEquals(AudioManager.MODE_NORMAL, app.getSystemService(AudioManager::class.java).mode)
    }

    @Test
    fun `later claim takes over and the old release is false`() {
        val readAloud = coordinator.claim(AndroidAudioSessionCoordinator.Client.ReadAloud)
        assertSame(readAloud, coordinator.current)
        val conversation = coordinator.claim(AndroidAudioSessionCoordinator.Client.Conversation)
        assertSame(conversation, coordinator.current)

        assertFalse(coordinator.release(readAloud))
        assertSame(conversation, coordinator.current)
        assertTrue(coordinator.release(conversation))
        assertNull(coordinator.current)
        assertFalse(coordinator.release(conversation))
    }

    @Test
    fun `baseline is kept across takeover and restored then cleared by the releasing holder`() {
        val audioManager = app.getSystemService(AudioManager::class.java)
        val session = shadowOf(thread.looper)
        audioManager.mode = AudioManager.MODE_NORMAL
        val conversation = coordinator.claim(AndroidAudioSessionCoordinator.Client.Conversation)
        coordinator.post {
            enterSession()
            changeMode(AudioManager.MODE_IN_COMMUNICATION)
        }
        // Takeover: calling enterSession again does not change the baseline.
        val realtime = coordinator.claim(AndroidAudioSessionCoordinator.Client.Realtime)
        coordinator.post {
            enterSession()
            changeMode(AudioManager.MODE_IN_COMMUNICATION)
        }
        session.idle()
        assertFalse(coordinator.release(conversation))

        // After read-aloud takes over, its release restores the state to true.
        val readAloud = coordinator.claim(AndroidAudioSessionCoordinator.Client.ReadAloud)
        assertFalse(coordinator.release(realtime))
        assertEquals(AudioManager.MODE_IN_COMMUNICATION, audioManager.mode)
        assertTrue(coordinator.release(readAloud))
        coordinator.post { restoreBaseline() }
        session.idle()
        assertEquals(AudioManager.MODE_NORMAL, audioManager.mode)

        // Cleared: with no baseline, restore does nothing; the next activation from idle records it again.
        coordinator.post {
            changeMode(AudioManager.MODE_RINGTONE)
            restoreBaseline()
        }
        session.idle()
        assertEquals(AudioManager.MODE_RINGTONE, audioManager.mode)
        val next = coordinator.claim(AndroidAudioSessionCoordinator.Client.Conversation)
        coordinator.post {
            enterSession()
            changeMode(AudioManager.MODE_IN_COMMUNICATION)
        }
        assertTrue(coordinator.release(next))
        coordinator.post { restoreBaseline() }
        session.idle()
        assertEquals(AudioManager.MODE_RINGTONE, audioManager.mode)
    }

    @Test
    @Config(sdk = [30])
    @Suppress("DEPRECATION")
    fun `below api 31 the baseline restores speakerphone`() {
        val audioManager = app.getSystemService(AudioManager::class.java)
        val session = shadowOf(thread.looper)
        audioManager.mode = AudioManager.MODE_NORMAL
        audioManager.isSpeakerphoneOn = false
        val first = coordinator.claim(AndroidAudioSessionCoordinator.Client.Conversation)
        coordinator.post {
            enterSession()
            changeMode(AudioManager.MODE_IN_COMMUNICATION)
            speakerphone(true)
        }
        val second = coordinator.claim(AndroidAudioSessionCoordinator.Client.Realtime)
        coordinator.post { enterSession() }
        session.idle()
        assertFalse(coordinator.release(first))
        assertTrue(coordinator.release(second))
        coordinator.post { restoreBaseline() }
        session.idle()

        assertEquals(AudioManager.MODE_NORMAL, audioManager.mode)
        assertFalse(audioManager.isSpeakerphoneOn)
    }

    @Test
    fun `operations outside the coordinator thread throw`() {
        val ops = runBlocking { coordinator.call { this } }

        assertThrows(IllegalStateException::class.java) { ops.currentMode() }
        assertThrows(IllegalStateException::class.java) { ops.changeMode(AudioManager.MODE_IN_COMMUNICATION) }
        assertThrows(IllegalStateException::class.java) { ops.speakerphone(true) }
        assertThrows(IllegalStateException::class.java) { ops.devices(AudioManager.GET_DEVICES_OUTPUTS) }
        assertEquals(AudioManager.MODE_NORMAL, app.getSystemService(AudioManager::class.java).mode)
    }
}
