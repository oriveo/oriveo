package ai.oriveo.community.core.studio

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import ai.oriveo.community.R

/**
 * Short foreground service that keeps the process alive while Studio images are generating. It only holds the
 * foreground and shows "Generating N images"; the request itself runs elsewhere. The platform caps a shortService
 * at about 3 minutes: [onTimeout] (API 34+) or a self-armed [LEGACY_DEADLINE_SECONDS] deadline (API <= 33) reports
 * to [timeoutListener] once and stops the service.
 */
class StudioGenerationService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private val legacyDeadline = Runnable { handleTimeout() }
    private var inForeground = false
    private var timedOut = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val count = (intent?.getIntExtra(EXTRA_COUNT, 1) ?: 1).coerceAtLeast(1)
        val renew = intent?.getBooleanExtra(EXTRA_RENEW, true) ?: true
        if (timedOut) {
            // A startForegroundService() call must still be answered with startForeground(), or the system
            // treats the app as crashed; then stop right away.
            enterForeground(count)
            stopSelf()
            return START_NOT_STICKY
        }
        if (inForeground && !renew) {
            // Count-only refresh: re-post the notification without renewing the time window.
            StudioGenerationNotifications.post(this, count)
            return START_NOT_STICKY
        }
        if (!enterForeground(count)) {
            // ForegroundServiceStartNotAllowedException / SecurityException: never run without the foreground.
            stopSelf()
            return START_NOT_STICKY
        }
        inForeground = true
        // Every send renews the window: startForeground() above restarts the shortService limit on API 34+,
        // and the self-armed deadline restarts from now on API <= 33.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            handler.removeCallbacks(legacyDeadline)
            handler.postDelayed(legacyDeadline, LEGACY_DEADLINE_SECONDS * 1_000L)
        }
        return START_NOT_STICKY
    }

    override fun onTimeout(startId: Int) = handleTimeout()

    override fun onTimeout(startId: Int, fgsType: Int) = handleTimeout()

    override fun onDestroy() {
        handler.removeCallbacks(legacyDeadline)
        StudioGenerationServiceController.serviceEnded()
        super.onDestroy()
    }

    private fun handleTimeout() {
        if (timedOut) return
        timedOut = true
        handler.removeCallbacks(legacyDeadline)
        try {
            timeoutListener?.invoke()
        } catch (error: Exception) {
            // A failing listener must not crash the main thread.
            Log.w(TAG, "timeout listener failed", error)
        } finally {
            // The service must stop at its limit even when the listener throws.
            stopSelf()
        }
    }

    private fun enterForeground(count: Int): Boolean =
        try {
            StudioGenerationNotifications.ensureChannel(this)
            ServiceCompat.startForeground(
                this,
                NOTIFICATION_ID,
                StudioGenerationNotifications.build(this, count),
                foregroundServiceType(),
            )
            true
        } catch (error: Exception) {
            false
        }

    private fun foregroundServiceType(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_SHORT_SERVICE
        } else {
            0
        }

    companion object {
        private const val TAG = "StudioGenerationService"
        const val NOTIFICATION_ID = 0x73747564
        const val EXTRA_COUNT = "ai.oriveo.community.extra.STUDIO_GENERATION_COUNT"

        /** True (default) for a new send that renews the time window; false for a count-only refresh. */
        const val EXTRA_RENEW = "ai.oriveo.community.extra.STUDIO_GENERATION_RENEW"

        /** Self-imposed cap on API <= 33, matching the shortService limit and the 180 s request timeout. */
        const val LEGACY_DEADLINE_SECONDS = 180L

        /** Called once on the main thread when the service hits its time limit, right before it stops. */
        @Volatile
        var timeoutListener: (() -> Unit)? = null
    }
}

/** Channel `studio_generation` (low importance, named after the Studio tab) and the ongoing progress notification. */
object StudioGenerationNotifications {
    const val CHANNEL_ID = "studio_generation"

    /** Creates the channel, or renames an existing one to the Studio title in the current language. */
    fun ensureChannel(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        val channel = NotificationChannel(
            CHANNEL_ID,
            context.getString(R.string.studio_tab_title),
            NotificationManager.IMPORTANCE_LOW,
        ).apply { setShowBadge(false) }
        manager.createNotificationChannel(channel)
    }

    /** Re-posts the progress notification with [count] without touching the foreground state. */
    fun post(context: Context, count: Int) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        manager.notify(StudioGenerationService.NOTIFICATION_ID, build(context, count))
    }

    fun build(context: Context, count: Int): Notification {
        val open = context.packageManager.getLaunchIntentForPackage(context.packageName)?.let {
            PendingIntent.getActivity(context, 0, it, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        }
        return NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_menu_gallery)
            .setContentTitle(context.resources.getQuantityString(R.plurals.studio_generating_title, count, count))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setContentIntent(open)
            .build()
    }
}

/**
 * Entry point for [StudioGenerationService], gated by [StudioAvailability.compiledIn]: with the gate closed nothing
 * is started and every call returns false.
 */
object StudioGenerationServiceController {
    @Volatile
    private var appContext: Context? = null

    /** Starts the service, or renews its time window for a new send; false when a foreground start is refused. */
    fun start(context: Context, count: Int, isCompiledIn: Boolean = StudioAvailability.compiledIn): Boolean {
        if (!isCompiledIn) return false
        val app = context.applicationContext ?: context
        return try {
            ContextCompat.startForegroundService(app, intent(app, count).putExtra(StudioGenerationService.EXTRA_RENEW, true))
            appContext = app
            true
        } catch (error: SecurityException) {
            false
        } catch (error: IllegalStateException) {
            // ForegroundServiceStartNotAllowedException (API 31+) is an IllegalStateException.
            false
        }
    }

    /**
     * Re-posts the notification with [count] without renewing the time window; false when the service was not
     * started through [start].
     */
    fun update(count: Int): Boolean {
        val app = appContext ?: return false
        return try {
            app.startService(intent(app, count).putExtra(StudioGenerationService.EXTRA_RENEW, false))
            true
        } catch (error: SecurityException) {
            false
        } catch (error: IllegalStateException) {
            false
        }
    }

    fun stop(): Boolean {
        val app = appContext ?: return false
        appContext = null
        app.stopService(Intent(app, StudioGenerationService::class.java))
        return true
    }

    internal fun serviceEnded() {
        appContext = null
    }

    private fun intent(context: Context, count: Int): Intent =
        Intent(context, StudioGenerationService::class.java).putExtra(StudioGenerationService.EXTRA_COUNT, count)
}
