package ai.oriveo.community.core.voice.conversation

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import ai.oriveo.community.R
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Microphone-only foreground service for the voice conversation . It only holds the process in the
 * foreground; the conversation itself lives in [VoiceConversationController]. The notification's End action is
 * reported through [endRequests].
 */
class VoiceConversationService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_END) {
            endRequestsFlow.tryEmit(Unit)
            stopSelf()
            return START_NOT_STICKY
        }
        try {
            VoiceConversationNotifications.ensureChannel(this)
            val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            } else {
                0
            }
            ServiceCompat.startForeground(this, NOTIFICATION_ID, VoiceConversationNotifications.build(this), type)
            stateFlow.value = State.Running
        } catch (error: Exception) {
            // SecurityException (microphone type without while-in-use access) or
            // ForegroundServiceStartNotAllowedException: never enter the conversation.
            stateFlow.value = State.Failed(error)
            stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        if (stateFlow.value == State.Running) stateFlow.value = State.Stopped
        super.onDestroy()
    }

    sealed interface State {
        data object Stopped : State
        data object Running : State
        data class Failed(val error: Exception) : State
    }

    companion object {
        const val ACTION_END = "ai.oriveo.community.action.END_VOICE_CONVERSATION"
        const val NOTIFICATION_ID = 0x766f6963

        private val stateFlow = MutableStateFlow<State>(State.Stopped)
        private val endRequestsFlow = MutableSharedFlow<Unit>(extraBufferCapacity = 1)

        val state: StateFlow<State> = stateFlow.asStateFlow()
        val endRequests: Flow<Unit> = endRequestsFlow.asSharedFlow()

        val isRunning: Boolean get() = stateFlow.value == State.Running

        fun stop(context: Context) {
            context.stopService(Intent(context, VoiceConversationService::class.java))
        }

        /** Marks a new start attempt so a stale Failed / Running value from an earlier session isn't read. */
        internal fun resetForStart() {
            if (stateFlow.value !is State.Running) stateFlow.value = State.Stopped
        }
    }
}

/** Minimal notification helper: channel `voice_conversation`, one ongoing notification with End. */
object VoiceConversationNotifications {
    const val CHANNEL_ID = "voice_conversation"

    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            context.getString(R.string.voice_conversation_channel_name),
            NotificationManager.IMPORTANCE_LOW,
        ).apply { setShowBadge(false) }
        manager.createNotificationChannel(channel)
    }

    fun build(context: Context): Notification {
        val end = PendingIntent.getService(
            context,
            0,
            Intent(context, VoiceConversationService::class.java).setAction(VoiceConversationService.ACTION_END),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val open = context.packageManager.getLaunchIntentForPackage(context.packageName)?.let {
            PendingIntent.getActivity(context, 0, it, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        }
        return NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle(context.getString(R.string.voice_conversation_notification_title))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setContentIntent(open)
            .addAction(0, context.getString(R.string.voice_conversation_notification_end), end)
            .build()
    }
}

/** Starts [VoiceConversationService] only while an Activity is visible and RECORD_AUDIO is granted . */
object VoiceConversationServiceStarter {
    sealed interface Result {
        data object Started : Result
        data object NotVisible : Result
        data object MissingPermission : Result

        /** SecurityException / ForegroundServiceStartNotAllowedException; show the existing error toast. */
        data class Rejected(val error: Exception) : Result
    }

    fun start(activity: Activity): Result {
        val visible = (activity as? LifecycleOwner)?.lifecycle?.currentState?.isAtLeast(Lifecycle.State.STARTED)
            ?: !activity.isFinishing
        if (!visible) return Result.NotVisible
        if (ContextCompat.checkSelfPermission(activity, Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return Result.MissingPermission
        }
        return launch(activity)
    }

    /** The raw start, without the visibility gate (instrumentation exercises the background rejection with it). */
    internal fun launch(context: Context): Result {
        VoiceConversationService.resetForStart()
        return try {
            ContextCompat.startForegroundService(context, Intent(context, VoiceConversationService::class.java))
            Result.Started
        } catch (error: SecurityException) {
            Result.Rejected(error)
        } catch (error: IllegalStateException) {
            // ForegroundServiceStartNotAllowedException (API 31+) is an IllegalStateException.
            Result.Rejected(error)
        }
    }
}

/** What the controller needs from the foreground service. */
interface VoiceConversationForeground {
    /** Suspends until the service runs in the foreground (true) or failed / timed out (false). */
    suspend fun awaitStarted(): Boolean

    /** Notification End taps. */
    val endRequests: Flow<Unit>

    fun stop()
}

class ServiceConversationForeground(context: Context) : VoiceConversationForeground {
    private val appContext = context.applicationContext

    override suspend fun awaitStarted(): Boolean =
        withTimeoutOrNull(START_TIMEOUT_MS) {
            VoiceConversationService.state.first { it != VoiceConversationService.State.Stopped }
        } == VoiceConversationService.State.Running

    override val endRequests: Flow<Unit> = VoiceConversationService.endRequests

    override fun stop() = VoiceConversationService.stop(appContext)

    private companion object {
        const val START_TIMEOUT_MS = 5_000L
    }
}
