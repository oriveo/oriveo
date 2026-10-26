package ai.oriveo.community.core.voice

import android.Manifest
import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.Context.MODE_PRIVATE
import android.content.pm.PackageManager
import android.os.Bundle
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred

/**
 * Production [MicrophonePermission]: returns true immediately if RECORD_AUDIO is already granted; otherwise hands off to the
 * requester attached by the host Activity and suspends until it reports a result. With no requester attached, or a requester
 * that fails to launch, the request counts as denied.
 * If the Activity is recreated by a configuration change while the permission dialog is showing, the old requester calls
 * [RequesterHandle.releaseForConfigChange] and the pending request is left for the next requester to adopt; it completes via
 * that requester's [RequesterHandle.onResult] (the system result delivered to the launcher after recreation) without
 * showing the dialog again.
 * If an Activity is truly destroyed (not a configuration change) before a new requester attaches, the leftover pending
 * request ends as not granted instead of suspending forever.
 */
class AndroidMicrophonePermission(
    context: Context,
    private val settings: VoiceEngineSettings = VoiceEngineSettings {
        context.applicationContext.getSharedPreferences(VoiceEngineSettings.PREFS_NAME, MODE_PRIVATE)
    },
) : MicrophonePermission {
    private val appContext = context.applicationContext
    private val lock = Any()
    private var current: Requester? = null

    /** Pending requests left by a requester released on a configuration change and not yet adopted by another; a null result means the requester left and there is no system result. */
    private val carried = mutableSetOf<CompletableDeferred<Boolean?>>()

    init {
        (appContext as? Application)?.registerActivityLifecycleCallbacks(
            object : Application.ActivityLifecycleCallbacks {
                override fun onActivityDestroyed(activity: Activity) {
                    if (activity.isChangingConfigurations) return
                    val orphaned = synchronized(lock) { carried.toList().also { carried.clear() } }
                    orphaned.forEach { it.complete(null) }
                }

                override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
                override fun onActivityStarted(activity: Activity) = Unit
                override fun onActivityResumed(activity: Activity) = Unit
                override fun onActivityPaused(activity: Activity) = Unit
                override fun onActivityStopped(activity: Activity) = Unit
                override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
            },
        )
    }

    /** Requester handle returned by [attach]. [close] ends the pending requests under it as denied. */
    interface RequesterHandle : AutoCloseable {
        /** Releases the requester for a configuration change: already-issued pending requests are not ended but handed to the next [attach]. */
        fun releaseForConfigChange()

        /** System permission result callback for this requester: completes pending requests adopted from the previous requester. */
        fun onResult(granted: Boolean)
    }

    private class Requester(
        val shouldShowRationale: () -> Boolean,
        val launch: ((Boolean) -> Unit) -> Unit,
    ) {
        /** Requests issued by this requester itself, waiting for the launch callback. */
        val pending = mutableSetOf<CompletableDeferred<Boolean?>>()

        /** Requests adopted from the requester before the configuration change, waiting for [RequesterHandle.onResult]. */
        val adopted = mutableSetOf<CompletableDeferred<Boolean?>>()
        var closed = false
    }

    /**
     * Attaches a system permission requester; a later one overrides earlier ones; adopts pending requests left by a configuration change.
     * [shouldShowRationale] is the host Activity's shouldShowRequestPermissionRationale(RECORD_AUDIO).
     */
    fun attach(
        shouldShowRationale: () -> Boolean = { false },
        launch: ((Boolean) -> Unit) -> Unit,
    ): RequesterHandle {
        val requester = Requester(shouldShowRationale, launch)
        synchronized(lock) {
            current = requester
            requester.adopted += carried
            carried.clear()
        }
        return object : RequesterHandle {
            override fun close() {
                val pending = synchronized(lock) {
                    if (current === requester) current = null
                    requester.closed = true
                    (requester.pending + requester.adopted).also {
                        requester.pending.clear()
                        requester.adopted.clear()
                    }
                }
                pending.forEach { it.complete(null) }
            }

            override fun releaseForConfigChange() {
                synchronized(lock) {
                    if (current === requester) current = null
                    requester.closed = true
                    val inFlight = (requester.pending + requester.adopted).filterNot { it.isCompleted }
                    requester.pending.clear()
                    requester.adopted.clear()
                    // If a new requester is attached before the old one is released, hand over to it directly; otherwise leave for the next attach.
                    current?.takeUnless { it.closed }?.adopted?.addAll(inFlight) ?: carried.addAll(inFlight)
                }
            }

            override fun onResult(granted: Boolean) {
                val adopted = synchronized(lock) {
                    requester.adopted.toList().also { requester.adopted.clear() }
                }
                adopted.forEach { it.complete(granted) }
            }
        }
    }

    override suspend fun request(): Boolean {
        if (isGranted()) return true
        val result = CompletableDeferred<Boolean?>()
        val requester = synchronized(lock) {
            current?.takeUnless { it.closed }?.also { it.pending += result }
        } ?: return false
        try {
            try {
                requester.launch { granted -> result.complete(granted) }
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                // The requester failed to launch (Activity destroyed, launcher not registered, etc.): treat as denied.
                return false
            }
            settings.markMicrophoneRequested()
            // null = the requester left and ended the request; there is no system result.
            return result.await() ?: false
        } finally {
            // The request may have moved to the carried set or the current requester's adopted set after a configuration change.
            synchronized(lock) {
                requester.pending -= result
                carried -= result
                current?.adopted?.remove(result)
            }
        }
    }

    private fun isGranted(): Boolean =
        ContextCompat.checkSelfPermission(appContext, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED
}
