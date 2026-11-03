package ai.oriveo.community.core.performance

import android.os.Build
import android.os.SystemClock
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.FrameMetrics
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

/**
 * Grace period after navigating to a new route. The first frame of a newly entered route has to
 * compose the whole subtree and decode fonts and images, so a few hundred milliseconds to over a
 * second is normal cost, not an actionable performance defect.
 *
 * [STARTUP_CAPTURE_GRACE_MS] only counts from the moment [AppJankStats] is constructed and covers
 * process cold start. After that, the first frame of every route change is unprotected. The
 * login page has no list to jank: the cost was a one-time initialization on entering the page.
 */
private const val ROUTE_CHANGE_CAPTURE_GRACE_MS = 3_000L

/**
 * Maximum number of captures per foreground session.
 *
 * [CAPTURE_THROTTLE_MS] is a rate limiter, not a total cap: one capture every 15 seconds, so a
 * long scroll could produce captures indefinitely. Jank is a continuous distribution that cannot
 * be understood by enumerating events; beyond the first few, repeats only fill the unprocessed queue.
 */
private const val MAX_CAPTURES_PER_SESSION = 3

/**
 * How long the app must stay in the background before returning counts as a new use. Shorter
 * onPause/onResume pairs are interruptions such as permission dialogs, a glance at the lock screen,
 * or the task switcher, and should not replenish the [MAX_CAPTURES_PER_SESSION] budget.
 */
private const val FOREGROUND_SESSION_GAP_MS = 60_000L

/**
 * A single frame this long is perceived by users as a freeze. Same 2-second floor as the iOS App Hang detector.
 */
private const val FROZEN_FRAME_MS = 2_000.0

/** Window and frame count for sustained jank: this many severe frames inside the window make one actionable defect. */
private const val SUSTAINED_JANK_WINDOW_MS = 10_000L
private const val SUSTAINED_SEVERE_FRAME_COUNT = 3

internal const val JANK_KIND_FREEZE = "freeze"
internal const val JANK_KIND_SUSTAINED = "sustained"

/**
 * Whether a severe frame is an actionable signal; returns null otherwise (breadcrumb only).
 *
 * 700 ms is Play vitals' frozen-frame threshold, but vitals uses it to compute a proportion of
 * frames, not one event per frame. Reporting every single frame as an issue produced a pile of
 * isolated 700 ms to 1 s frames with no second frame nearby, where the only context was one tap or
 * a return from the background. There was no code to locate and no fix to verify. Another group
 * came from one device with 7 consecutive frames of 1.2 to 1.4 s within 4 s during streaming
 * generation, sustained for over 30 s. That was a real defect where the main thread stayed busy,
 * but it was lumped into the same issue as the isolated frames.
 *
 * So only two shapes count:
 * - [JANK_KIND_FREEZE]: a single frame of at least 2 s;
 * - [JANK_KIND_SUSTAINED]: the [SUSTAINED_SEVERE_FRAME_COUNT]th and later severe frames within [SUSTAINED_JANK_WINDOW_MS].
 * Isolated single frames of 700 ms to 2 s still go to breadcrumbs (WARNING level) and are delivered
 * with the next real event; they do not open an issue on their own.
 */
internal fun actionableJankKind(frameDurationMs: Double, severeFramesInWindow: Int): String? = when {
    frameDurationMs < SEVERE_JANK_MS -> null
    frameDurationMs >= FROZEN_FRAME_MS -> JANK_KIND_FREEZE
    severeFramesInWindow >= SUSTAINED_SEVERE_FRAME_COUNT -> JANK_KIND_SUSTAINED
    else -> null
}

/** Sliding count of recent severe frames. Only used on the UI thread (the JankStats listener thread), so no synchronization is needed. */
internal class SevereJankWindow(private val windowMs: Long = SUSTAINED_JANK_WINDOW_MS) {
    private val timestamps = ArrayDeque<Long>()

    /** Records one severe frame and returns the number of severe frames in the window, including this one. */
    fun record(nowElapsedMs: Long): Int {
        while (timestamps.isNotEmpty() && nowElapsedMs - timestamps.first() > windowMs) {
            timestamps.removeFirst()
        }
        timestamps.addLast(nowElapsedMs)
        return timestamps.size
    }

    fun reset() = timestamps.clear()
}

/**
 * Time a frame spends after the UI thread hands it off: waiting for RenderThread to pick it up,
 * sync, issuing commands and acquiring buffers, then swap.
 *
 * JankStats' frameDurationUi only covers UNKNOWN_DELAY through SYNC, so it cannot tell whether 3
 * seconds was our work on the main thread or the main thread blocked in the previous frame's
 * syncAndDraw while RenderThread waits for a system buffer or the GPU. In the frame data, the latter
 * looks like this: the render-side duration of the one or two frames before is roughly the length of
 * the freeze, and the UNKNOWN_DELAY of the following frame absorbs the same amount. Five freezes on
 * one device all fell between 2995 and 3054 ms, so the frame timing alone could not decide the cause.
 */
internal fun renderSideNanos(
    totalNanos: Long,
    unknownDelayNanos: Long,
    inputNanos: Long,
    animationNanos: Long,
    layoutNanos: Long,
    drawNanos: Long,
): Long = (totalNanos - unknownDelayNanos - inputNanos - animationNanos - layoutNanos - drawNanos).coerceAtLeast(0L)

internal const val STALL_SIDE_UI_THREAD = "ui_thread"
internal const val STALL_SIDE_RENDER_THREAD = "render_thread"

/** Render-side durations at or above this threshold are recorded in [RenderStallLog]; normal frames take a few milliseconds and are not worth a slot. */
private const val RENDER_STALL_RECORD_NANOS = 300_000_000L

/** How far back from a freeze to look for render-side stalls. The stall is usually in the one or two frames before, so leave some margin. */
private const val RENDER_STALL_LOOKBACK_NANOS = 5_000_000_000L

/** Render-side segment durations of one frame, in milliseconds. The GPU segment exists only from API 31; it is null on older systems. */
internal data class RenderSegments(
    val syncMs: Double,
    val commandIssueMs: Double,
    val swapBuffersMs: Double,
    val gpuMs: Double?,
) {
    /** Issue context for a render_thread freeze: where it was stuck (sync / texture upload, command issue, buffer acquisition for swap, or which GPU segment). */
    fun toContext(): Map<String, Any> = buildMap {
        put("sync_ms", syncMs)
        put("command_issue_ms", commandIssueMs)
        put("swap_buffers_ms", swapBuffersMs)
        gpuMs?.let { put("gpu_ms", it) }
    }
}

/**
 * The most recent render-side stalls. Written on the frame-metrics thread and read on the JankStats thread, hence the lock.
 */
internal class RenderStallLog(private val capacity: Int = 8) {
    private val intendedVsyncs = LongArray(capacity)
    private val renderNanos = LongArray(capacity)
    private val segments = arrayOfNulls<RenderSegments>(capacity)
    private var size = 0
    private var next = 0

    @Synchronized
    fun record(intendedVsyncNanos: Long, renderSideNanos: Long, segments: RenderSegments? = null) {
        if (renderSideNanos < RENDER_STALL_RECORD_NANOS) return
        intendedVsyncs[next] = intendedVsyncNanos
        renderNanos[next] = renderSideNanos
        this.segments[next] = segments
        next = (next + 1) % capacity
        if (size < capacity) size++
    }

    /** Largest render-side duration among frames whose start falls within [fromNanos, toNanos]; 0 if none. */
    @Synchronized
    fun maxRenderNanos(fromNanos: Long, toNanos: Long): Long = maxIndex(fromNanos, toNanos)?.let { renderNanos[it] } ?: 0L

    /** Segments of the largest render-side frame within the same window. */
    @Synchronized
    fun maxRenderSegments(fromNanos: Long, toNanos: Long): RenderSegments? = maxIndex(fromNanos, toNanos)?.let { segments[it] }

    private fun maxIndex(fromNanos: Long, toNanos: Long): Int? {
        var index: Int? = null
        for (i in 0 until size) {
            if (intendedVsyncs[i] in fromNanos..toNanos && renderNanos[i] > (index?.let { renderNanos[it] } ?: 0L)) index = i
        }
        return index
    }
}

/** Lookup window for render-side stalls (same convention as [jankStallSide]). */
internal fun renderStallSegments(frameStartNanos: Long, frameDurationNanos: Long, log: RenderStallLog): RenderSegments? =
    log.maxRenderSegments(frameStartNanos - RENDER_STALL_LOOKBACK_NANOS, frameStartNanos + frameDurationNanos)

/**
 * Which side the freeze time was spent on. If the render side stalled for at least half the freeze
 * duration within the same period, it is [STALL_SIDE_RENDER_THREAD] (waiting on system buffers, the
 * GPU, or a window transition, not this app's main-thread code). Otherwise it is [STALL_SIDE_UI_THREAD]
 * (work on the main thread, including our code and synchronous binder calls on the main thread).
 */
internal fun jankStallSide(frameStartNanos: Long, frameDurationNanos: Long, log: RenderStallLog): String {
    val maxRender = log.maxRenderNanos(
        fromNanos = frameStartNanos - RENDER_STALL_LOOKBACK_NANOS,
        toNanos = frameStartNanos + frameDurationNanos,
    )
    return if (maxRender * 2 >= frameDurationNanos) STALL_SIDE_RENDER_THREAD else STALL_SIDE_UI_THREAD
}

/** Module and fingerprint prefix for jank issues. */
internal const val JANK_MODULE = "performance.jank"

/**
 * Fixed issue title.
 *
 * **Never put measurements into the message.** Milliseconds are not part of the fingerprint (the
 * grouping key is [JANK_MODULE] plus route), so they cannot split groups, but they would pin the
 * issue title permanently to the first event's value. An issue would keep reading "4341.5ms" even
 * when a hundred later events are 800 ms. Titles must be aggregatable nouns; measurements belong in tags.
 */
internal const val JANK_MESSAGE = "Severe jank frame"

/** Each of the two shapes gets its own fixed title (also without measurements), so they are easy to tell apart in the triage list. */
internal fun jankMessage(kind: String): String = when (kind) {
    JANK_KIND_FREEZE -> "Frozen frame"
    JANK_KIND_SUSTAINED -> "Sustained severe jank"
    else -> JANK_MESSAGE
}

/** Whether chat generation is streaming. Sustained jank during generation and while idle are two different kinds of defect, so grouping and tagging must separate them. */
internal fun jankGenerationState(isStreaming: Boolean): String = if (isStreaming) "streaming" else "idle"

/**
 * Frame duration bucket. Exact values go to tags; this is only a dimension for aggregation
 * ("how many frozen frames over 4 seconds" is answerable, "how many times did 4341.5 ms occur" is not).
 */
internal fun jankDurationBucket(frameDurationMs: Double): String = when {
    frameDurationMs < 1_000.0 -> "700-1000"
    frameDurationMs < 2_000.0 -> "1000-2000"
    frameDurationMs < 4_000.0 -> "2000-4000"
    else -> "4000+"
}

/**
 * Route used for reporting. Empty, blank, or "unknown" are not actionable signals (we cannot tell
 * which page janked), so these return null. [shouldCaptureSevereJankEvent] and the fingerprint share
 * this normalization, so the route that passes the gate and the route in the grouping key are the same value.
 */
internal fun normalizedJankRoute(routeState: String?): String? =
    routeState?.trim()?.takeUnless { it.isEmpty() || it == "unknown" }

internal fun shouldCaptureSevereJankEvent(
    frameDurationMs: Double,
    routeState: String?,
    nowElapsedMs: Long,
    trackingStartedAtMs: Long,
    lastCapturedAtMs: Long,
    startupGraceMs: Long = STARTUP_CAPTURE_GRACE_MS,
    throttleMs: Long = CAPTURE_THROTTLE_MS,
    routeEnteredAtMs: Long = Long.MIN_VALUE,
    capturedThisSession: Int = 0,
    routeChangeGraceMs: Long = ROUTE_CHANGE_CAPTURE_GRACE_MS,
    maxCapturesPerSession: Int = MAX_CAPTURES_PER_SESSION,
): Boolean {
    if (frameDurationMs < SEVERE_JANK_MS) return false

    if (normalizedJankRoute(routeState) == null) return false

    if (nowElapsedMs - trackingStartedAtMs < startupGraceMs) {
        return false
    }

    // A route's first frame carries a one-time cost, which is not a defect. routeEnteredAtMs defaults
    // to Long.MIN_VALUE, meaning "no route change recorded"; subtracting it would overflow, so check it explicitly.
    if (routeEnteredAtMs != Long.MIN_VALUE && nowElapsedMs - routeEnteredAtMs < routeChangeGraceMs) {
        return false
    }

    if (capturedThisSession >= maxCapturesPerSession) return false

    return nowElapsedMs - lastCapturedAtMs >= throttleMs
}

/** Module value for the two freeze-frame entries in the diagnostics issue fixture. */
internal const val JANK_ISSUE_MODULE = "performance"

/** File name for the folded-stack attachment. */
internal const val STALL_ATTACHMENT_NAME = "main-thread-stall.txt"

/** One jank issue to report (plain data, so unit tests can assert on it directly). */
internal class JankIssue(
    val title: String,
    val fingerprint: List<String>,
    val tags: Map<String, String>,
    val context: Map<String, Any>,
    val mainThreadStack: Array<StackTraceElement>?,
    val foldedStacks: String?,
)

/**
 * Builds one jank issue.
 *
 * Fingerprint = [JANK_MODULE, kind, stall point] (per design §3.2), with route demoted to a tag: the
 * same stall point is one issue no matter which page it happens on. The stall point does not use the
 * on-device [StallAnalysis.topFrame] literal. Release class names are obfuscated by R8 and differ per
 * version, so putting them in the fingerprint would split the same stall into a new issue every release.
 * When ui_thread has samples, the representative stack becomes the event's main thread, and the
 * fingerprint uses the server-side variables `{{ stack.module }}` / `{{ stack.function }}`. The server
 * de-obfuscates first, then takes the top-most application frame (in_app is filled in server-side from
 * the package name), which is stable across versions. The on-device topFrame (package name kept, class
 * name obfuscated) is kept only as tag `stall.top_frame`, for filtering and non-empty-rate checks.
 */
internal fun buildJankIssue(
    kind: String,
    route: String,
    frameDurationMs: Double,
    generationState: String,
    stallSide: String,
    stall: StallAnalysis?,
    renderSegments: RenderSegments?,
): JankIssue {
    val hasStack = stallSide == STALL_SIDE_UI_THREAD && stall?.representativeStack != null
    val fingerprint = when {
        hasStack -> listOf(JANK_MODULE, kind, "{{ stack.module }}", "{{ stack.function }}")
        stallSide == STALL_SIDE_RENDER_THREAD -> listOf(JANK_MODULE, kind, STALL_SIDE_RENDER_THREAD)
        // The sampler did not catch up (the stall happened before foreground startup, for example): no stall point,
        // in its own group so it does not mix with the ones that have one.
        else -> listOf(JANK_MODULE, kind, STALL_SIDE_UI_THREAD, "no_samples")
    }
    val tags = buildMap {
        put("module", JANK_ISSUE_MODULE)
        // Tags carry only low-cardinality dimensions: exact milliseconds and the state string go in breadcrumb data.
        put("route", route)
        put("frame_duration_bucket", jankDurationBucket(frameDurationMs))
        put("jank_kind", kind)
        put("chat_generation", generationState)
        put("stall.side", stallSide)
        if (stallSide == STALL_SIDE_UI_THREAD) stall?.topFrame?.let { put("stall.top_frame", it) }
    }
    val context = buildMap<String, Any> {
        put("frame_duration_ms", frameDurationMs)
        if (stallSide == STALL_SIDE_UI_THREAD) put("stall_sample_count", stall?.sampleCount ?: 0)
        if (stallSide == STALL_SIDE_RENDER_THREAD) renderSegments?.let { putAll(it.toContext()) }
    }
    return JankIssue(
        title = jankMessage(kind),
        fingerprint = fingerprint,
        tags = tags,
        context = context,
        mainThreadStack = if (hasStack) stall.representativeStack else null,
        foldedStacks = stall?.foldedStacks?.takeIf { stallSide == STALL_SIDE_UI_THREAD && it.isNotEmpty() },
    )
}

/** Frame-metrics callback thread for render-side stall recording. One thread is shared across the process, so Activity recreation does not start a new one. */
private val frameMetricsHandler: Handler by lazy {
    Handler(HandlerThread("OriveoFrameStall").apply { start() }.looper)
}

class AppJankStats(private val window: Window) {
    private val trackingStartedAtMs = SystemClock.elapsedRealtime()
    private var lastCapturedAtMs = 0L
    private val runsOnEmulator = isEmulatorEnvironment(Build.TAGS, Build.SUPPORTED_ABIS)

    // Route changes can only be observed from the frame data: JankStats' states are written on the UI
    // thread and the listener also runs there, so these fields need no synchronization. Long.MIN_VALUE
    // means no route has been observed yet.
    //
    // Note: the listener is called only for jank frames, so entering a new route is observed only when
    // that route first drops a frame. As a result, the first jank frame of each route always falls
    // inside the grace window and is swallowed, even if it happened long after the page change. This
    // is an accepted cost, and it errs on the conservative side (under-reporting rather than over-reporting).
    // Getting the exact moment of the route change would mean pushing it up from the navigation layer,
    // which would couple this self-contained monitor to NavHost. Not worth it.
    private var lastObservedRoute: String? = null
    private var routeEnteredAtMs = Long.MIN_VALUE
    private var capturedThisSession = 0
    private var pausedAtMs = Long.MIN_VALUE
    private val severeJankWindow = SevereJankWindow()
    private val renderStallLog = RenderStallLog()

    // JankStats does not expose per-phase durations, so a separate FrameMetrics listener records only render-side stalls (see [renderSideNanos]).
    // Several getMetric calls per frame on a background thread; the overhead is negligible.
    private val frameMetricsListener = Window.OnFrameMetricsAvailableListener { _, metrics, _ ->
        val renderSide = renderSideNanos(
            totalNanos = metrics.getMetric(FrameMetrics.TOTAL_DURATION),
            unknownDelayNanos = metrics.getMetric(FrameMetrics.UNKNOWN_DELAY_DURATION),
            inputNanos = metrics.getMetric(FrameMetrics.INPUT_HANDLING_DURATION),
            animationNanos = metrics.getMetric(FrameMetrics.ANIMATION_DURATION),
            layoutNanos = metrics.getMetric(FrameMetrics.LAYOUT_MEASURE_DURATION),
            drawNanos = metrics.getMetric(FrameMetrics.DRAW_DURATION),
        )
        renderStallLog.record(
            intendedVsyncNanos = metrics.getMetric(FrameMetrics.INTENDED_VSYNC_TIMESTAMP),
            renderSideNanos = renderSide,
            // Segments are read only when the record threshold is reached, so normal frames do not pay for 4 extra getMetric calls.
            segments = if (renderSide >= RENDER_STALL_RECORD_NANOS) metrics.renderSegments() else null,
        )
    }

    init {
        window.addOnFrameMetricsAvailableListener(frameMetricsListener, frameMetricsHandler)
    }

    // createAndTrack defaults isTrackingEnabled to true, which installs the FrameMetricsListener right away and
    // puts every frame through the listener during the cold-start window. Tracking is turned on in [onResume]
    // instead, so monitoring overhead during startup stays minimal.
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
            val jankRoute = normalizedJankRoute(routeState)
            if (jankRoute != lastObservedRoute) {
                lastObservedRoute = jankRoute
                routeEnteredAtMs = now
                // "Sustained" holds only within a single page: severe frames from the previous page must not combine with the new page's into one sustained stall.
                severeJankWindow.reset()
            }
            val severeFramesInWindow =
                if (frameDurationMs >= SEVERE_JANK_MS) severeJankWindow.record(now) else 0
            val jankKind = actionableJankKind(frameDurationMs, severeFramesInWindow)
            if (
                !runsOnEmulator &&
                jankRoute != null &&
                jankKind != null &&
                shouldCaptureSevereJankEvent(
                    frameDurationMs = frameDurationMs,
                    routeState = routeState,
                    nowElapsedMs = now,
                    trackingStartedAtMs = trackingStartedAtMs,
                    lastCapturedAtMs = lastCapturedAtMs,
                    routeEnteredAtMs = routeEnteredAtMs,
                    capturedThisSession = capturedThisSession,
                )
            ) {
                lastCapturedAtMs = now
                capturedThisSession += 1
            }
        },
    ).also {
        it.isTrackingEnabled = false
    }

    fun onResume() {
        refreshSessionBudgetIfReturnedFromBackground()
        jankStats.isTrackingEnabled = true
    }

    fun onPause() {
        jankStats.isTrackingEnabled = false
        pausedAtMs = SystemClock.elapsedRealtime()
        // Frames are not captured while paused, so severe frames from before the pause do not count as "sustained" after returning.
        severeJankWindow.reset()
    }

    /**
     * Activity destroyed: remove the FrameMetrics listener. If it is not removed, the Window holds the
     * listener, the listener holds this object, and after a configuration change recreates the Activity
     * the old Window's callbacks keep running on the background thread.
     */
    fun dispose() {
        jankStats.isTrackingEnabled = false
        runCatching { window.removeOnFrameMetricsAvailableListener(frameMetricsListener) }
    }

    /**
     * Replenish the capture budget only when returning to the foreground after being away for a while.
     *
     * It cannot be reset directly in onPause: Android's onPause also fires for permission dialogs, the
     * lock screen, a glance at the task switcher, notification-shade pulls (on some OEMs), and split-screen
     * focus changes. A user repeatedly interrupted on a page that is already janky would keep regaining
     * the 3-capture budget, so the cap would not constrain what it is meant to constrain. The 15-second
     * throttle would be the only thing actually limiting, and it is not enough on its own, which is why the cap exists.
     */
    private fun refreshSessionBudgetIfReturnedFromBackground() {
        val pausedAt = pausedAtMs
        if (pausedAt == Long.MIN_VALUE) return
        pausedAtMs = Long.MIN_VALUE
        if (SystemClock.elapsedRealtime() - pausedAt < FOREGROUND_SESSION_GAP_MS) return
        capturedThisSession = 0
        lastObservedRoute = null
        routeEnteredAtMs = Long.MIN_VALUE
    }
}

/** Reads one frame's render-side segments (nanoseconds to milliseconds). */
private fun FrameMetrics.renderSegments(): RenderSegments = RenderSegments(
    syncMs = getMetric(FrameMetrics.SYNC_DURATION) / 1_000_000.0,
    commandIssueMs = getMetric(FrameMetrics.COMMAND_ISSUE_DURATION) / 1_000_000.0,
    swapBuffersMs = getMetric(FrameMetrics.SWAP_BUFFERS_DURATION) / 1_000_000.0,
    gpuMs = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) getMetric(FrameMetrics.GPU_DURATION) / 1_000_000.0 else null,
)
