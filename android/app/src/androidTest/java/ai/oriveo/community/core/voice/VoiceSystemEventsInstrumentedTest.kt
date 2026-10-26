package ai.oriveo.community.core.voice

import android.app.UiAutomation
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.SystemClock
import android.util.Log
import android.view.accessibility.AccessibilityManager
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import ai.oriveo.community.MainActivity
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.voice.conversation.AndroidConversationAudio
import ai.oriveo.community.core.voice.conversation.ConversationAudioListener
import ai.oriveo.community.core.voice.conversation.ConversationRoute
import ai.oriveo.community.feature.chat.voice.isScreenReaderOn
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Read-aloud and conversation audio sessions against the real system services on an emulator:
 * focus taken by another request (real AudioService), BECOMING_NOISY, process going to the background,
 * and the production screen-reader check with TalkBack really on.
 */
@RunWith(AndroidJUnit4::class)
class VoiceSystemEventsInstrumentedTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context: Context get() = instrumentation.targetContext
    private val audioManager: AudioManager get() = context.getSystemService(AudioManager::class.java)

    private class ReadAloudEvents : ReadAloudEnvironment.SessionListener {
        val interrupted = CountDownLatch(1)
        val backgrounded = CountDownLatch(1)

        override fun onInterrupted() = interrupted.countDown()

        override fun onBackgrounded() = backgrounded.countDown()
    }

    private class ConversationEvents : ConversationAudioListener {
        val interruptions = CopyOnWriteArrayList<Boolean>()
        val focusLost = CountDownLatch(1)
        val noisy = CountDownLatch(1)

        override fun onFrame(index: Long, db: Double) = Unit

        override fun onRouteChanged(route: ConversationRoute, privateRouteRemoved: Boolean) = Unit

        override fun onBecomingNoisy() = noisy.countDown()

        override fun onInterruption(began: Boolean) {
            interruptions += began
        }

        override fun onFocusLost() = focusLost.countDown()

        override fun onCaptureFailed() = Unit
    }

    private fun readAloudEnvironment() = AndroidReadAloudEnvironment(context, GlobalSnackbarManager())

    /** beginSession / endSession touch ProcessLifecycleOwner, which must be used on the main thread. */
    private fun AndroidReadAloudEnvironment.beginOnMain(listener: ReadAloudEnvironment.SessionListener): Boolean {
        var granted = false
        instrumentation.runOnMainSync { granted = beginSession(listener) }
        return granted
    }

    private fun AndroidReadAloudEnvironment.endOnMain() = instrumentation.runOnMainSync { endSession() }

    /** Another client takes permanent focus through the real AudioService. */
    private fun <T> withFocusTaken(block: () -> T): T {
        val taker = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build(),
            )
            .setOnAudioFocusChangeListener { }
            .build()
        assertEquals(AudioManager.AUDIOFOCUS_REQUEST_GRANTED, audioManager.requestAudioFocus(taker))
        try {
            return block()
        } finally {
            audioManager.abandonAudioFocusRequest(taker)
        }
    }

    /**
     * ACTION_AUDIO_BECOMING_NOISY is a protected broadcast: an app uid may not send it. Try the real broadcast
     * first; on SecurityException deliver the real Intent to the receiver the class under test registered.
     */
    private fun deliverBecomingNoisy(receiver: BroadcastReceiver?) {
        val intent = Intent(AudioManager.ACTION_AUDIO_BECOMING_NOISY).setPackage(context.packageName)
        try {
            context.sendBroadcast(intent)
        } catch (denied: SecurityException) {
            Log.i(TAG, "BECOMING_NOISY is protected, delivering to the registered receiver: ${denied.message}")
            assertNotNull("session must register a BECOMING_NOISY receiver", receiver)
            instrumentation.runOnMainSync { receiver!!.onReceive(context, intent) }
        }
    }

    /**
     * The default UiAutomation connection suppresses other accessibility services (TalkBack would never bind),
     * so every shell call goes through a connection that keeps them.
     */
    private fun shell(command: String): String {
        val pfd = instrumentation.getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
            .executeShellCommand(command)
        return android.os.ParcelFileDescriptor.AutoCloseInputStream(pfd).use { it.readBytes().decodeToString() }.trim()
    }

    private fun awaitCondition(timeoutMs: Long, condition: () -> Boolean): Boolean {
        val deadline = SystemClock.uptimeMillis() + timeoutMs
        while (SystemClock.uptimeMillis() < deadline) {
            if (condition()) return true
            Thread.sleep(POLL_MS)
        }
        return condition()
    }

    @Test
    fun readAloudUsesMediaSpeechAttributes() {
        val environment = readAloudEnvironment()
        try {
            assertTrue("focus granted", environment.beginOnMain(ReadAloudEvents()))
            val attributes = environment.sessionAudioAttributes
            assertNotNull(attributes)
            assertEquals(AudioAttributes.USAGE_MEDIA, attributes!!.usage)
            assertEquals(AudioAttributes.CONTENT_TYPE_SPEECH, attributes.contentType)
            assertEquals(AudioManager.STREAM_MUSIC, attributes.volumeControlStream)
        } finally {
            environment.endOnMain()
        }
    }

    @Test
    fun readAloudStopsWhenFocusIsTaken() {
        val environment = readAloudEnvironment()
        val events = ReadAloudEvents()
        try {
            assertTrue("focus granted", environment.beginOnMain(events))
            withFocusTaken {
                assertTrue("focus loss reached the session", events.interrupted.await(EVENT_TIMEOUT_S, TimeUnit.SECONDS))
            }
        } finally {
            environment.endOnMain()
        }
    }

    @Test
    fun readAloudStopsOnBecomingNoisy() {
        val environment = readAloudEnvironment()
        val events = ReadAloudEvents()
        try {
            environment.beginOnMain(events)
            deliverBecomingNoisy(environment.sessionNoisyReceiver)
            assertTrue("BECOMING_NOISY reached the session", events.interrupted.await(EVENT_TIMEOUT_S, TimeUnit.SECONDS))
        } finally {
            environment.endOnMain()
        }
    }

    @Test
    fun readAloudStopsInBackground() {
        val environment = readAloudEnvironment()
        val events = ReadAloudEvents()
        ActivityScenario.launch(MainActivity::class.java).use {
            try {
                environment.beginOnMain(events)
                assertEquals(1L, events.backgrounded.count)
                shell("input keyevent KEYCODE_HOME")
                assertTrue(
                    "process ON_STOP reached the session",
                    events.backgrounded.await(BACKGROUND_TIMEOUT_S, TimeUnit.SECONDS),
                )
            } finally {
                environment.endOnMain()
            }
        }
    }

    @Test
    fun conversationPermanentFocusLossEnds() {
        val audio = AndroidConversationAudio(context, File(context.cacheDir, "voice-system-events-turns"))
        val events = ConversationEvents()
        try {
            audio.open(events, capture = false)
            // Permanent GAIN by another client = AUDIOFOCUS_LOSS: the conversation ends, not a pause.
            withFocusTaken {
                assertTrue("focus loss reached the session", events.focusLost.await(EVENT_TIMEOUT_S, TimeUnit.SECONDS))
            }
            assertTrue(events.interruptions.isEmpty())
        } finally {
            audio.close()
        }
    }

    @Test
    fun conversationBecomingNoisyStops() {
        val audio = AndroidConversationAudio(context, File(context.cacheDir, "voice-system-events-turns"))
        val events = ConversationEvents()
        try {
            audio.open(events, capture = false)
            deliverBecomingNoisy(audio.sessionNoisyReceiver)
            assertTrue("BECOMING_NOISY reached the session", events.noisy.await(EVENT_TIMEOUT_S, TimeUnit.SECONDS))
        } finally {
            audio.close()
        }
    }

    @Test
    fun talkBackOnMakesScreenReaderCheckTrue() {
        val accessibility = context.getSystemService(AccessibilityManager::class.java)
        val previousServices = shell("settings get secure enabled_accessibility_services")
        val previousEnabled = shell("settings get secure accessibility_enabled")
        try {
            assertFalse("screen reader off before TalkBack", isScreenReaderOn(context))
            shell("settings put secure enabled_accessibility_services $TALKBACK")
            shell("settings put secure accessibility_enabled 1")
            assertTrue(
                "touch exploration on within 10 s",
                awaitCondition(TALKBACK_TIMEOUT_MS) { accessibility.isTouchExplorationEnabled },
            )
            assertTrue(isScreenReaderOn(context))
        } finally {
            restoreSecureSetting("enabled_accessibility_services", previousServices)
            restoreSecureSetting("accessibility_enabled", previousEnabled)
            check(awaitCondition(TALKBACK_TIMEOUT_MS) { !accessibility.isTouchExplorationEnabled }) {
                "touch exploration still on ${TALKBACK_TIMEOUT_MS}ms after restoring accessibility settings"
            }
        }
    }

    private fun restoreSecureSetting(key: String, value: String) {
        if (value.isEmpty() || value == "null") {
            shell("settings delete secure $key")
        } else {
            shell("settings put secure $key $value")
        }
    }

    private companion object {
        const val TAG = "VoiceSystemEvents"
        const val TALKBACK =
            "com.google.android.marvin.talkback/com.google.android.marvin.talkback.TalkBackService"
        const val EVENT_TIMEOUT_S = 5L
        const val BACKGROUND_TIMEOUT_S = 10L
        const val TALKBACK_TIMEOUT_MS = 10_000L
        const val POLL_MS = 100L
    }
}
