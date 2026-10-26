package ai.oriveo.community.core.voice.conversation

import android.Manifest
import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** The merged manifest: the voice conversation declares only the microphone foreground service and three permissions; plus the visibility / permission gate on the start entry point. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class VoiceConversationServiceManifestTest {
    private val context: Context = ApplicationProvider.getApplicationContext()

    @Test
    fun `declares permissions and a non-exported microphone service`() {
        @Suppress("DEPRECATION")
        val info = context.packageManager.getPackageInfo(context.packageName, PackageManager.GET_PERMISSIONS)
        val requested = info.requestedPermissions.orEmpty().toSet()
        assertTrue(Manifest.permission.FOREGROUND_SERVICE in requested)
        assertTrue(Manifest.permission.FOREGROUND_SERVICE_MICROPHONE in requested)
        assertTrue(Manifest.permission.POST_NOTIFICATIONS in requested)
        assertTrue(Manifest.permission.RECORD_AUDIO in requested)
        assertFalse(Manifest.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK in requested)

        val service = context.packageManager.getServiceInfo(
            ComponentName(context, VoiceConversationService::class.java),
            0,
        )
        assertFalse(service.exported)
        assertEquals(ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE, service.foregroundServiceType)
    }

    @Test
    fun `starter refuses when not visible or without microphone permission`() {
        val created = Robolectric.buildActivity(Activity::class.java).create()
        val app = shadowOf(ApplicationProvider.getApplicationContext<android.app.Application>())
        app.grantPermissions(Manifest.permission.RECORD_AUDIO)
        // Plain Activity is not a LifecycleOwner: visibility falls back to !isFinishing; finish it to hide it.
        created.get().finish()
        assertEquals(VoiceConversationServiceStarter.Result.NotVisible, VoiceConversationServiceStarter.start(created.get()))

        val visible = Robolectric.buildActivity(androidx.activity.ComponentActivity::class.java).setup()
        app.denyPermissions(Manifest.permission.RECORD_AUDIO)
        assertEquals(
            VoiceConversationServiceStarter.Result.MissingPermission,
            VoiceConversationServiceStarter.start(visible.get()),
        )
        app.grantPermissions(Manifest.permission.RECORD_AUDIO)
        assertEquals(VoiceConversationServiceStarter.Result.Started, VoiceConversationServiceStarter.start(visible.get()))
        val started = shadowOf(visible.get()).nextStartedService
        assertEquals(VoiceConversationService::class.java.name, started.component?.className)
    }

    @Test
    fun `notification has the voice conversation channel and an end action`() {
        val app = ApplicationProvider.getApplicationContext<android.app.Application>()
        VoiceConversationNotifications.ensureChannel(app)
        val notification = VoiceConversationNotifications.build(app)
        assertEquals(VoiceConversationNotifications.CHANNEL_ID, notification.channelId)
        assertEquals(1, notification.actions.size)
        assertEquals("End", notification.actions[0].title.toString())
    }

    @Test
    fun `starter reports platform rejections instead of throwing`() {
        val app = ApplicationProvider.getApplicationContext<android.app.Application>()
        fun throwing(error: RuntimeException) = object : android.content.ContextWrapper(app) {
            override fun startForegroundService(service: android.content.Intent?): ComponentName? = throw error
        }
        val security = SecurityException("microphone type not allowed")
        assertEquals(
            VoiceConversationServiceStarter.Result.Rejected(security),
            VoiceConversationServiceStarter.launch(throwing(security)),
        )
        // ForegroundServiceStartNotAllowedException is an IllegalStateException subclass (API 31+).
        val notAllowed = android.app.ForegroundServiceStartNotAllowedException("background")
        assertEquals(
            VoiceConversationServiceStarter.Result.Rejected(notAllowed),
            VoiceConversationServiceStarter.launch(throwing(notAllowed)),
        )
        assertFalse(VoiceConversationService.isRunning)
    }
}
