package ai.oriveo.community.core.voice

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.res.Configuration
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import androidx.annotation.StringRes
import androidx.annotation.VisibleForTesting
import androidx.appcompat.app.AppCompatDelegate
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.ProcessLifecycleOwner
import ai.oriveo.community.R
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.GlobalToastStyle
import ai.oriveo.community.core.app.UiText
import java.util.Locale
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext

/**
 * Production [ReadAloudEnvironment]: audio focus (ducking allowed), headset unplug, and process ON_STOP.
 * Focus request / release run on the [sessions] coordinator thread; focus callbacks switch back to the main thread before handing off to the listener.
 */
class AndroidReadAloudEnvironment(
    context: Context,
    private val snackbar: GlobalSnackbarManager,
    private val sessions: AndroidAudioSessionCoordinator,
) : ReadAloudEnvironment {
    private val appContext = context.applicationContext
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var focusRequest: AudioFocusRequest? = null

    /** The current read-aloud lease, paired with [focusRequest]; claimed synchronously on the calling thread. */
    @Volatile
    private var lease: AndroidAudioSessionCoordinator.Lease? = null
    private var noisyReceiver: BroadcastReceiver? = null
    private var lifecycleObserver: LifecycleEventObserver? = null

    /** Read-only view for instrumented tests: attributes of the focus request held by the current session. */
    @get:VisibleForTesting
    internal val sessionAudioAttributes: AudioAttributes? get() = focusRequest?.audioAttributes

    /** Read-only view for instrumented tests: BECOMING_NOISY is protected, so tests deliver to this receiver. */
    @get:VisibleForTesting
    internal val sessionNoisyReceiver: BroadcastReceiver? get() = noisyReceiver

    override fun uiLocale(): Locale =
        AppCompatDelegate.getApplicationLocales()[0]
            ?: appContext.resources.configuration.locales[0]
            ?: Locale.getDefault()

    override fun placeholderText(kind: SpeakablePlaceholder, appLocale: String): String {
        val config = Configuration(appContext.resources.configuration)
        config.setLocale(resourceLocale(appLocale))
        val localized = appContext.createConfigurationContext(config)
        return localized.getString(
            when (kind) {
                SpeakablePlaceholder.CODE -> R.string.voice_placeholder_code
                SpeakablePlaceholder.TABLE -> R.string.voice_placeholder_table
                SpeakablePlaceholder.MATH -> R.string.voice_placeholder_math
            },
        )
    }

    /** String in the UI language (preview sample sentence). */
    fun uiString(@StringRes resId: Int): String {
        val config = Configuration(appContext.resources.configuration)
        config.setLocale(uiLocale())
        return appContext.createConfigurationContext(config).getString(resId)
    }

    override suspend fun beginSession(listener: ReadAloudEnvironment.SessionListener): Boolean {
        endSession()
        val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            .setOnAudioFocusChangeListener(
                { change ->
                    if (change == AudioManager.AUDIOFOCUS_LOSS || change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) {
                        mainHandler.post { listener.onInterrupted() }
                    }
                },
                sessions.handler,
            )
            .build()
        // Lease is claimed synchronously on the calling thread: claim order matches the call order for conversation and realtime.
        val held = sessions.claim(AndroidAudioSessionCoordinator.Client.ReadAloud)
        focusRequest = request
        lease = held
        val job = currentCoroutineContext()[Job]
        val granted = try {
            sessions.call {
                // Cancelled while queued: do not request focus.
                if (job?.isActive == false) return@call false
                requestFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
            }
        } catch (e: CancellationException) {
            // Cancelled while waiting for focus: the request may still run, and is released after it in the order of this request and lease.
            releaseFocus(request, held)
            if (focusRequest === request) {
                focusRequest = null
                lease = null
            }
            throw e
        }

        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) listener.onInterrupted()
            }
        }
        ContextCompat.registerReceiver(
            appContext,
            receiver,
            IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        noisyReceiver = receiver

        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_STOP) listener.onBackgrounded()
        }
        ProcessLifecycleOwner.get().lifecycle.addObserver(observer)
        lifecycleObserver = observer
        return granted
    }

    override fun endSession() {
        val request = focusRequest
        val held = lease
        if (request != null && held != null) releaseFocus(request, held)
        focusRequest = null
        lease = null
        noisyReceiver?.let { runCatching { appContext.unregisterReceiver(it) } }
        noisyReceiver = null
        lifecycleObserver?.let { ProcessLifecycleOwner.get().lifecycle.removeObserver(it) }
        lifecycleObserver = null
    }

    /** Releases the ([request], [held]) pair; the session baseline is restored only if the lease is still held by its owner. */
    private fun releaseFocus(request: AudioFocusRequest, held: AndroidAudioSessionCoordinator.Lease) {
        sessions.post {
            abandonFocus(request)
            if (sessions.release(held)) restoreBaseline()
        }
    }

    override fun showMessage(resId: Int) {
        snackbar.show(GlobalSnackbarMessage(UiText.Resource(resId), style = GlobalToastStyle.Error))
    }

    internal companion object {
        /** App language tag from the contract -> the Locale matching the res/values-* qualifier. */
        fun resourceLocale(appLocale: String): Locale = when (appLocale) {
            "zh-Hans" -> Locale.forLanguageTag("zh-CN")
            "zh-Hant" -> Locale.forLanguageTag("zh-TW")
            "id" -> Locale.forLanguageTag("in")
            "pt-BR" -> Locale.forLanguageTag("pt-BR")
            else -> Locale.forLanguageTag(appLocale)
        }
    }
}
