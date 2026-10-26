package ai.oriveo.community.core.voice.conversation

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import ai.oriveo.community.MainActivity
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * On an emulator (-no-audio): the production service started through the production starter.
 * Visible start runs; a start ~10 s after going to the background is refused; denied notifications don't stop it.
 * No audio is opened, nothing is played.
 */
@RunWith(AndroidJUnit4::class)
class VoiceConversationServiceInstrumentedTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context: Context get() = instrumentation.targetContext

    @Before
    fun setUp() {
        instrumentation.uiAutomation.grantRuntimePermission(context.packageName, Manifest.permission.RECORD_AUDIO)
    }

    @After
    fun tearDown() {
        VoiceConversationService.stop(context)
        awaitState(STOP_TIMEOUT_MS) { it != VoiceConversationService.State.Running }
    }

    private fun awaitState(
        timeoutMs: Long,
        predicate: (VoiceConversationService.State) -> Boolean,
    ): VoiceConversationService.State? = runBlocking {
        withTimeoutOrNull(timeoutMs) { VoiceConversationService.state.first(predicate) }
    }

    private fun startFromVisibleActivity(): VoiceConversationServiceStarter.Result {
        var result: VoiceConversationServiceStarter.Result? = null
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { result = VoiceConversationServiceStarter.start(it) }
            awaitState(START_TIMEOUT_MS) { it != VoiceConversationService.State.Stopped }
        }
        return result!!
    }

    @Test
    fun visibleStartRunsInForeground() {
        assertEquals(VoiceConversationServiceStarter.Result.Started, startFromVisibleActivity())
        assertEquals(VoiceConversationService.State.Running, VoiceConversationService.state.value)
    }

    /**
     * The platform's own background rejection can't be reproduced here: the instrumented process carries the
     * background-activity-start privilege (logcat `Background started FGS: Allowed … code:ACTIVITY_STARTER`, even
     * 15 s after the activity was destroyed). So this locks the starter's visibility gate on the real lifecycle;
     * catching SecurityException / ForegroundServiceStartNotAllowedException is locked by
     * VoiceConversationServiceManifestTest (Robolectric, startForegroundService throws).
     */
    @Test
    fun backgroundStartIsRefusedByTheStarter() {
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            var activity: MainActivity? = null
            scenario.onActivity { activity = it }
            instrumentation.uiAutomation.executeShellCommand("input keyevent KEYCODE_HOME").close()
            Thread.sleep(BACKGROUND_WAIT_MS)
            var result: VoiceConversationServiceStarter.Result? = null
            instrumentation.runOnMainSync { result = VoiceConversationServiceStarter.start(activity!!) }
            Log.i(TAG, "background start: $result")
            assertEquals(VoiceConversationServiceStarter.Result.NotVisible, result)
            assertEquals(
                null,
                awaitState(START_TIMEOUT_MS) { it != VoiceConversationService.State.Stopped },
            )
            assertFalse(VoiceConversationService.isRunning)
        }
    }

    @Test
    fun deniedNotificationsDoNotStopTheService() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
            ) {
                instrumentation.uiAutomation.revokeRuntimePermission(
                    context.packageName,
                    Manifest.permission.POST_NOTIFICATIONS,
                )
            }
            assertEquals(
                PackageManager.PERMISSION_DENIED,
                ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS),
            )
        }
        assertEquals(VoiceConversationServiceStarter.Result.Started, startFromVisibleActivity())
        assertEquals(VoiceConversationService.State.Running, VoiceConversationService.state.value)
    }

    private companion object {
        const val TAG = "VoiceConversationFgs"
        const val START_TIMEOUT_MS = 5_000L
        const val STOP_TIMEOUT_MS = 3_000L
        const val BACKGROUND_WAIT_MS = 10_000L
    }
}
