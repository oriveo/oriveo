package ai.oriveo.community.core.performance

import android.os.Build
import android.os.SystemClock
import android.util.Log
import android.view.Window
import androidx.metrics.performance.JankStats
import java.util.Locale

private const val TAG = "AppJankStats"
private const val SEVERE_JANK_MS = 700.0
private const val CAPTURE_THROTTLE_MS = 15_000L
private const val STARTUP_CAPTURE_GRACE_MS = 8_000L

internal fun isEmulatorEnvironment(
    buildTags: String?,
    supportedAbis: Array<String>?,
): Boolean {
    if (buildTags?.contains("test-keys") == true) return true
    return supportedAbis?.any { it == "x86" || it == "x86_64" } == true
}

internal fun shouldCaptureSevereJankEvent(
    frameDurationMs: Double,
    routeState: String?,
    nowElapsedMs: Long,
    trackingStartedAtMs: Long,
    lastCapturedAtMs: Long,
    startupGraceMs: Long = STARTUP_CAPTURE_GRACE_MS,
    throttleMs: Long = CAPTURE_THROTTLE_MS,
): Boolean {
    if (frameDurationMs < SEVERE_JANK_MS) return false

    val normalizedRoute = routeState?.trim()
    if (normalizedRoute.isNullOrEmpty() || normalizedRoute == "unknown") {
        return false
    }

    if (nowElapsedMs - trackingStartedAtMs < startupGraceMs) {
        return false
    }

    return nowElapsedMs - lastCapturedAtMs >= throttleMs
}

class AppJankStats(window: Window) {
    private val trackingStartedAtMs = SystemClock.elapsedRealtime()
    private var lastCapturedAtMs = 0L
    private val runsOnEmulator = isEmulatorEnvironment(Build.TAGS, Build.SUPPORTED_ABIS)

    @Suppress("MemberVisibilityCanBePrivate")
    private val jankStats = JankStats.createAndTrack(
        window,
        JankStats.OnFrameListener { frameData ->
            if (!frameData.isJank) return@OnFrameListener

            val frameDurationMs = frameData.frameDurationUiNanos / 1_000_000.0
            val routeState = frameData.states.firstOrNull { it.key == "route" }?.value
            val stateSummary = frameData.states
                .joinToString(separator = ",") { "${it.key}=${it.value}" }
                .ifBlank { "route=unknown" }
            val durationText = String.format(Locale.US, "%.1f", frameDurationMs)
            val message = "Jank frame ${durationText}ms ($stateSummary)"

            Log.w(TAG, message)

            val now = SystemClock.elapsedRealtime()
            if (
                !runsOnEmulator &&
                shouldCaptureSevereJankEvent(
                    frameDurationMs = frameDurationMs,
                    routeState = routeState,
                    nowElapsedMs = now,
                    trackingStartedAtMs = trackingStartedAtMs,
                    lastCapturedAtMs = lastCapturedAtMs,
                )
            ) {
                lastCapturedAtMs = now
            }
        },
    ).also {

        it.isTrackingEnabled = false
    }

    fun onResume() {
        jankStats.isTrackingEnabled = true
    }

    fun onPause() {
        jankStats.isTrackingEnabled = false
    }
}
