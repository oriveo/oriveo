package ai.oriveo.community.core.studio

import android.app.Application
import android.app.ForegroundServiceStartNotAllowedException
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.time.Duration

/** Studio generation foreground service: shortService manifest entry, notification, timeout, availability gate. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class StudioGenerationServiceTest {
    private val app: Application = ApplicationProvider.getApplicationContext()
    private var timeouts = 0

    @After
    fun tearDown() {
        StudioGenerationService.timeoutListener = null
        StudioGenerationServiceController.stop()
    }

    private fun startIntent(count: Int): Intent =
        Intent(app, StudioGenerationService::class.java).putExtra(StudioGenerationService.EXTRA_COUNT, count)

    private fun updateIntent(count: Int): Intent =
        startIntent(count).putExtra(StudioGenerationService.EXTRA_RENEW, false)

    private fun title(notification: Notification?): String? =
        notification?.extras?.getCharSequence(Notification.EXTRA_TITLE)?.toString()

    private fun postedTitle(): String? =
        title(shadowOf(app.getSystemService(NotificationManager::class.java)).getNotification(StudioGenerationService.NOTIFICATION_ID))

    @Test
    fun `manifest declares a non-exported shortService`() {
        val service = app.packageManager.getServiceInfo(ComponentName(app, StudioGenerationService::class.java), 0)
        assertFalse(service.exported)
        assertEquals(ServiceInfo.FOREGROUND_SERVICE_TYPE_SHORT_SERVICE, service.foregroundServiceType)
    }

    @Test
    fun `start posts the generating notification on the studio channel`() {
        val controller = Robolectric.buildService(StudioGenerationService::class.java, startIntent(2)).create()
        controller.startCommand(0, 1)
        val service = shadowOf(controller.get())

        val notification = service.lastForegroundNotification
        assertNotNull(notification)
        assertEquals(StudioGenerationNotifications.CHANNEL_ID, notification.channelId)
        assertEquals("studio_generation", notification.channelId)
        assertEquals("Generating 2 images", notification.extras.getCharSequence(Notification.EXTRA_TITLE).toString())
        assertTrue(notification.flags and Notification.FLAG_ONGOING_EVENT != 0)
        assertEquals(StudioGenerationService.NOTIFICATION_ID, service.lastForegroundNotificationId)

        val channel = app.getSystemService(NotificationManager::class.java).getNotificationChannel("studio_generation")
        assertNotNull(channel)
        assertEquals(NotificationManager.IMPORTANCE_LOW, channel.importance)
        assertEquals("Images", channel.name.toString())
    }

    @Test
    fun `singular count uses the one form`() {
        val notification = StudioGenerationNotifications.build(app, 1)
        assertEquals("Generating 1 image", notification.extras.getCharSequence(Notification.EXTRA_TITLE).toString())
    }

    @Test
    fun `controller starts the service with the count when compiled in`() {
        assertTrue(StudioGenerationServiceController.start(app, 2, isCompiledIn = true))
        val started = shadowOf(app).nextStartedService
        assertEquals(StudioGenerationService::class.java.name, started.component?.className)
        assertEquals(2, started.getIntExtra(StudioGenerationService.EXTRA_COUNT, -1))
        assertTrue(started.getBooleanExtra(StudioGenerationService.EXTRA_RENEW, false))

        assertTrue(StudioGenerationServiceController.update(3))
        val updated = shadowOf(app).nextStartedService
        assertEquals(3, updated.getIntExtra(StudioGenerationService.EXTRA_COUNT, -1))
        assertFalse(updated.getBooleanExtra(StudioGenerationService.EXTRA_RENEW, true))

        assertTrue(StudioGenerationServiceController.stop())
        assertEquals(StudioGenerationService::class.java.name, shadowOf(app).nextStoppedService.component?.className)
        assertFalse(StudioGenerationServiceController.update(4))
    }

    @Test
    fun `gate closed starts nothing`() {
        assertFalse(StudioGenerationServiceController.start(app, 2, isCompiledIn = false))
        assertNull(shadowOf(app).nextStartedService)
        assertFalse(StudioGenerationServiceController.update(2))
        assertFalse(StudioGenerationServiceController.stop())
    }

    @Test
    fun `system timeout notifies the listener once and stops the service`() {
        StudioGenerationService.timeoutListener = { timeouts++ }
        val controller = Robolectric.buildService(StudioGenerationService::class.java, startIntent(2)).create()
        controller.startCommand(0, 1)
        val service = controller.get()

        service.onTimeout(1)
        service.onTimeout(1, ServiceInfo.FOREGROUND_SERVICE_TYPE_SHORT_SERVICE)

        assertEquals(1, timeouts)
        assertTrue(shadowOf(service).isStoppedBySelf)
    }

    @Test
    fun `api 34 does not arm the legacy deadline`() {
        StudioGenerationService.timeoutListener = { timeouts++ }
        val controller = Robolectric.buildService(StudioGenerationService::class.java, startIntent(2)).create()
        controller.startCommand(0, 1)

        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(StudioGenerationService.LEGACY_DEADLINE_SECONDS + 1))

        assertEquals(0, timeouts)
        assertFalse(shadowOf(controller.get()).isStoppedBySelf)
    }

    @Test
    fun `controller start returns false when a foreground start is not allowed`() {
        val refusing = object : ContextWrapper(app) {
            override fun getApplicationContext(): Context = this

            override fun startForegroundService(service: Intent?) =
                throw ForegroundServiceStartNotAllowedException("background start")
        }
        assertFalse(StudioGenerationServiceController.start(refusing, 2, isCompiledIn = true))
        assertFalse(StudioGenerationServiceController.update(3))
    }

    @Test
    fun `timeout listener throwing is swallowed and the service still stops`() {
        StudioGenerationService.timeoutListener = { throw IllegalStateException("listener failure") }
        val controller = Robolectric.buildService(StudioGenerationService::class.java, startIntent(2)).create()
        controller.startCommand(0, 1)
        val service = controller.get()

        // Must not propagate to the main thread.
        service.onTimeout(1, ServiceInfo.FOREGROUND_SERVICE_TYPE_SHORT_SERVICE)

        assertTrue(shadowOf(service).isStoppedBySelf)
    }

    @Test
    fun `start after timeout enters the foreground before stopping`() {
        val controller = Robolectric.buildService(StudioGenerationService::class.java, startIntent(2)).create()
        controller.startCommand(0, 1)
        val service = controller.get()
        service.onTimeout(1, ServiceInfo.FOREGROUND_SERVICE_TYPE_SHORT_SERVICE)

        controller.withIntent(startIntent(5)).startCommand(0, 2)

        assertEquals("Generating 5 images", title(shadowOf(service).lastForegroundNotification))
        assertTrue(shadowOf(service).isStoppedBySelf)
    }

    @Test
    fun `api 34 every start renews the foreground while an update only refreshes the notification`() {
        val controller = Robolectric.buildService(StudioGenerationService::class.java, startIntent(2)).create()
        controller.startCommand(0, 1)
        val service = shadowOf(controller.get())

        controller.withIntent(updateIntent(3)).startCommand(0, 2)
        assertEquals("Generating 2 images", title(service.lastForegroundNotification))
        assertEquals("Generating 3 images", postedTitle())

        controller.withIntent(startIntent(4)).startCommand(0, 3)
        assertEquals("Generating 4 images", title(service.lastForegroundNotification))
        assertEquals("Generating 4 images", postedTitle())
    }

    @Test
    fun `existing channel is renamed to the current studio title`() {
        val manager = app.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(StudioGenerationNotifications.CHANNEL_ID, "Stale name", NotificationManager.IMPORTANCE_LOW),
        )

        StudioGenerationNotifications.ensureChannel(app)

        assertEquals("Images", manager.getNotificationChannel(StudioGenerationNotifications.CHANNEL_ID).name.toString())
    }

    @Test
    @Config(sdk = [33])
    fun `api 33 second start restarts the deadline from the second start`() {
        StudioGenerationService.timeoutListener = { timeouts++ }
        val controller = Robolectric.buildService(StudioGenerationService::class.java, startIntent(2)).create()
        controller.startCommand(0, 1)
        val looper = shadowOf(Looper.getMainLooper())
        looper.idleFor(Duration.ofSeconds(100))

        controller.withIntent(startIntent(3)).startCommand(0, 2)
        looper.idleFor(Duration.ofSeconds(179))
        assertEquals(0, timeouts)
        assertFalse(shadowOf(controller.get()).isStoppedBySelf)

        looper.idleFor(Duration.ofSeconds(2))
        assertEquals(1, timeouts)
        assertTrue(shadowOf(controller.get()).isStoppedBySelf)
    }

    @Test
    @Config(sdk = [33])
    fun `api 33 self deadline after 180 seconds takes the same timeout path`() {
        assertEquals(180L, StudioGenerationService.LEGACY_DEADLINE_SECONDS)
        StudioGenerationService.timeoutListener = { timeouts++ }
        val controller = Robolectric.buildService(StudioGenerationService::class.java, startIntent(2)).create()
        controller.startCommand(0, 1)
        // A count update must neither re-arm nor double the deadline.
        controller.withIntent(updateIntent(3)).startCommand(0, 2)
        val looper = shadowOf(Looper.getMainLooper())

        looper.idleFor(Duration.ofSeconds(179))
        assertEquals(0, timeouts)
        assertFalse(shadowOf(controller.get()).isStoppedBySelf)

        looper.idleFor(Duration.ofSeconds(2))
        assertEquals(1, timeouts)
        assertTrue(shadowOf(controller.get()).isStoppedBySelf)
        assertEquals("Generating 3 images", postedTitle())

        looper.idleFor(Duration.ofSeconds(StudioGenerationService.LEGACY_DEADLINE_SECONDS))
        assertEquals(1, timeouts)
    }
}
