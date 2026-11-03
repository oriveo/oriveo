package ai.oriveo.community.core.performance

import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import androidx.core.os.HandlerCompat

/** Heartbeat period: while idle, post to the main Looper every 200ms (5 Hz, only post + compare). */
internal const val STALL_HEARTBEAT_INTERVAL_MS = 200L

/** A heartbeat this late means the main thread is stuck: earlier than the 700ms single-frame freeze line, so at least 3 stacks are captured within the frozen-frame window. */
internal const val STALL_THRESHOLD_MS = 400L

/** Stack capture interval during a stall. */
internal const val STALL_SAMPLE_INTERVAL_MS = 100L

/** Max stacks kept per stall: 50 × 100ms = 5 seconds; stacks beyond a longer freeze would only repeat. */
internal const val STALL_MAX_SAMPLES = 50

/** One main thread stack snapshot; [atMs] shares the time base of JankStats frame times (CLOCK_MONOTONIC milliseconds). */
internal class StallSample(val atMs: Long, val frames: Array<StackTraceElement>)

/** One stall; [endMs] is null while it has not recovered yet. */
internal class StallRecord(val startMs: Long, val endMs: Long?, val samples: List<StallSample>)

/**
 * Pure state machine for main thread stall detection (no threads or Looper; a fake clock can drive it).
 *
 * The sampler thread calls [tick] periodically, and the main thread calls [onHeartbeat] when it reaches the heartbeat.
 * While a heartbeat is in flight the main thread is busy the whole time, so the stall start is recorded as the moment
 * the heartbeat was posted, not the moment the late heartbeat is noticed.
 */
internal class StallDetector(
    private val clock: () -> Long,
    private val captureMainStack: () -> Array<StackTraceElement>,
) {
    private val lock = Any()
    private var pendingSinceMs = NONE
    private var stallStartMs = NONE
    private var samples = ArrayList<StallSample>()
    private var lastStall: StallRecord? = null

    /**
     * Called once per sampler tick. Returns true = a new heartbeat must be posted (the previous one came back).
     * Stack capture during a stall: capturing needs the main thread to reach a safepoint, so it runs outside the lock;
     * onHeartbeat does not have to wait for it when the main thread recovers.
     */
    fun tick(): Boolean {
        val shouldSample: Boolean
        synchronized(lock) {
            val now = clock()
            if (pendingSinceMs == NONE) {
                pendingSinceMs = now
                return true
            }
            if (now - pendingSinceMs < STALL_THRESHOLD_MS) return false
            if (stallStartMs == NONE) {
                stallStartMs = pendingSinceMs
                samples = ArrayList()
            }
            shouldSample = samples.size < STALL_MAX_SAMPLES
        }
        if (!shouldSample) return false
        val frames = captureMainStack()
        synchronized(lock) {
            // The main thread may have recovered and closed this stall while we were capturing: a late sample belongs to no stall, so drop it.
            if (stallStartMs != NONE && samples.size < STALL_MAX_SAMPLES) samples.add(StallSample(clock(), frames))
        }
        return false
    }

    /** Delay to the next tick: the stack-capture interval during a stall; when a heartbeat is in flight but below the threshold, wake exactly at the threshold. */
    fun nextDelayMs(): Long = synchronized(lock) {
        when {
            stallStartMs != NONE -> STALL_SAMPLE_INTERVAL_MS
            pendingSinceMs != NONE ->
                (STALL_THRESHOLD_MS - (clock() - pendingSinceMs)).coerceIn(1L, STALL_HEARTBEAT_INTERVAL_MS)
            else -> STALL_HEARTBEAT_INTERVAL_MS
        }
    }

    /** The main thread reaches the heartbeat: the in-flight stall ends; only this one is kept (earlier ones are no longer queried). */
    fun onHeartbeat() = synchronized(lock) {
        if (stallStartMs != NONE) {
            lastStall = StallRecord(stallStartMs, clock(), samples)
            samples = ArrayList()
            stallStartMs = NONE
        }
        pendingSinceMs = NONE
    }

    /** Stop sampling (going to background): an in-flight stall is closed at the current time and heartbeat state is reset, so returning to foreground does not count the paused period as a stall. */
    fun reset() = synchronized(lock) {
        if (stallStartMs != NONE) {
            lastStall = StallRecord(stallStartMs, clock(), samples)
            samples = ArrayList()
            stallStartMs = NONE
        }
        pendingSinceMs = NONE
    }

    /** Samples from the latest stall (including an in-flight one) whose capture time falls within [fromMs, toMs]. */
    fun samplesBetween(fromMs: Long, toMs: Long): List<StallSample> = synchronized(lock) {
        val source = if (stallStartMs != NONE) samples.toList() else lastStall?.samples.orEmpty()
        source.filter { it.atMs in fromMs..toMs }
    }

    fun lastStall(): StallRecord? = synchronized(lock) {
        if (stallStartMs != NONE) StallRecord(stallStartMs, null, samples.toList()) else lastStall
    }

    private companion object {
        const val NONE = Long.MIN_VALUE
    }
}

/**
 * Frozen-frame main thread sampler: a background thread posts a heartbeat to the main Looper every [STALL_HEARTBEAT_INTERVAL_MS];
 * once a heartbeat is late by ≥ [STALL_THRESHOLD_MS], the main thread's Java stack is captured every [STALL_SAMPLE_INTERVAL_MS] until the heartbeat returns.
 *
 * Why not profiling: the Developer tier has no profile quota, and a frozen frame only needs to answer "what was the main thread doing during those seconds".
 * Stack sampling during a stall is zero-cost and deterministic. It runs only in the foreground (MainActivity onResume / onPause start and stop it).
 */
class MainThreadStallSampler internal constructor(
    internal val detector: StallDetector,
) {
    private val mainLooper = Looper.getMainLooper()

    // Async Handler: the heartbeat is not blocked by Choreographer's sync barriers; it measures only whether the main thread is free, not queueing.
    private val mainHandler: Handler by lazy { HandlerCompat.createAsync(mainLooper) }
    private val samplerHandler: Handler by lazy {
        Handler(HandlerThread("OriveoStallSampler").apply { start() }.looper)
    }
    private val heartbeat = Runnable { detector.onHeartbeat() }

    @Volatile
    private var running = false

    private val loop = object : Runnable {
        override fun run() {
            if (!running) return
            if (detector.tick()) mainHandler.post(heartbeat)
            samplerHandler.postDelayed(this, detector.nextDelayMs())
        }
    }

    fun start() {
        if (running) return
        running = true
        samplerHandler.post(loop)
    }

    fun stop() {
        if (!running) return
        running = false
        samplerHandler.removeCallbacks(loop)
        mainHandler.removeCallbacks(heartbeat)
        detector.reset()
    }

    internal fun samplesBetween(fromMs: Long, toMs: Long): List<StallSample> = detector.samplesBetween(fromMs, toMs)

    companion object {
        /** The process has one main thread, so there is one sampler per process. */
        val shared: MainThreadStallSampler by lazy {
            MainThreadStallSampler(
                StallDetector(
                    clock = { System.nanoTime() / 1_000_000 },
                    captureMainStack = { Looper.getMainLooper().thread.stackTrace },
                ),
            )
        }
    }
}

/** Summary of stall samples: the stall frame used as the tag, the representative stack for the event's main thread, and the folded-stacks attachment. */
internal class StallAnalysis(
    val topFrame: String?,
    val representativeStack: Array<StackTraceElement>?,
    val foldedStacks: String,
    val sampleCount: Int,
)

/** Package prefix of the app's own code (in release, proguard `-keeppackagenames` keeps package names; class names stay obfuscated and the event stack is deobfuscated server-side). */
internal const val STALL_APP_PACKAGE_PREFIX = "ai.oriveo.community."

/** Sentry tag value limit: 200 characters. */
private const val TOP_FRAME_MAX_CHARS = 200

/** Folded-stacks attachment limit: 64 KB. */
internal const val FOLDED_STACKS_MAX_BYTES = 64 * 1024

internal fun StackTraceElement.frameKey(): String = "$className.$methodName"

/** The first (topmost) app frame in a stack; returns null if there is none. */
internal fun firstAppFrame(frames: Array<StackTraceElement>, appPrefix: String = STALL_APP_PACKAGE_PREFIX): String? =
    frames.firstOrNull { it.className.startsWith(appPrefix) }?.frameKey()

/**
 * Summarize a group of stall samples:
 * - stall frame = the most frequent first app frame across samples (ties go to the one that appeared first);
 * - representative stack = the most frequent full stack among the samples at the stall frame (if there is no app frame, the most frequent across all samples);
 * - folded text has one line per stack, "root→top joined by ; + space + count", sorted by count descending; beyond 64 KB the low-frequency tail lines are cut.
 */
internal fun analyzeStall(samples: List<StallSample>, appPrefix: String = STALL_APP_PACKAGE_PREFIX): StallAnalysis {
    if (samples.isEmpty()) return StallAnalysis(null, null, "", 0)
    val topFrame = samples.mapNotNull { firstAppFrame(it.frames, appPrefix) }
        .groupingBy { it }.eachCount()
        .maxByOrNull { it.value }?.key
    val candidates = if (topFrame == null) samples else samples.filter { firstAppFrame(it.frames, appPrefix) == topFrame }
    val stackCounts = LinkedHashMap<String, Pair<Array<StackTraceElement>, Int>>()
    candidates.forEach { sample ->
        val key = sample.frames.joinToString("\n")
        val existing = stackCounts[key]
        stackCounts[key] = sample.frames to ((existing?.second ?: 0) + 1)
    }
    val representative = stackCounts.values.maxByOrNull { it.second }?.first
    return StallAnalysis(
        topFrame = topFrame?.take(TOP_FRAME_MAX_CHARS),
        representativeStack = representative,
        foldedStacks = foldStacks(samples),
        sampleCount = samples.size,
    )
}

internal fun foldStacks(samples: List<StallSample>, maxBytes: Int = FOLDED_STACKS_MAX_BYTES): String {
    val counts = samples.map { sample -> sample.frames.reversed().joinToString(";") { it.frameKey() } }
        .groupingBy { it }.eachCount()
        .entries.sortedByDescending { it.value }
    val builder = StringBuilder()
    var bytes = 0
    for ((stack, count) in counts) {
        val line = "$stack $count\n"
        val lineBytes = line.toByteArray(Charsets.UTF_8).size
        if (bytes + lineBytes > maxBytes) break
        builder.append(line)
        bytes += lineBytes
    }
    return builder.toString()
}
