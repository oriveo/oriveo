package ai.oriveo.community.ui.component.streaming

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos

/**
 * Pacer for streamed text: block-level commits with a staggered fade-in per block.
 * Block boundaries come from the pure functions in [StreamingBlockChunker].
 *
 * The stream hands us a fresh full-text snapshot roughly every 40ms. This pacer
 * releases those snapshots into [StreamingRevealState.visibleText] in syntactically
 * complete blocks and phrases, so a piece of content is rendered exactly once and
 * appears in its final form: `visible` only ever advances to a chunker safe boundary,
 * and the rendering of a character already on screen - its style and its glyph - never
 * changes afterwards.
 *
 * Each committed block gets per-character reveal timestamps. A block longer than
 * 16 UTF-16 units is cut into 12-unit segments offset by 45ms each, with the total
 * offset capped at 300ms, so a whole-line or multi-line commit ripples open in reading
 * order. The layer above turns those timestamps into a `1-(1-t)^3` ease-out fade over
 * 0.25s. Code and table rows go into their own cards and settle immediately, with no
 * per-character fade.
 *
 * Every timing value - inter-chunk gaps, line-end and paragraph pauses, stagger, the
 * degradation thresholds - lives in [BlockCommitCadence]. Tune there, one value at a time.
 *
 * Deferred finish: when streaming stops, the remaining backlog is not snapped in. The
 * pacer keeps emitting it block by block at the same cadence, with every hold released
 * (`isStreamEnd`), which guarantees convergence in a bounded number of steps - even a
 * stream that was interrupted while held on a table, a fence or a `$$` block still
 * reaches its target. Only a message that never streamed at all is snapped straight in.
 */

/**
 * Language profile. CJK packs more information per character, so its word chunks are
 * shorter and its code cadence is slightly slower.
 */
internal enum class StreamingPacerProfile {
    Ascii,
    Cjk;

    /** Frame interval for the code fast path, in ms, paired with the backlog-scaled step in codeStepSize. */
    val frameDelayMs: Long get() = if (this == Cjk) 40L else 33L

    companion object {
        /** More than 30% of the letter-like characters being CJK selects the CJK profile. */
        fun detect(sample: String): StreamingPacerProfile {
            if (sample.isEmpty()) return Ascii
            var cjk = 0
            var letters = 0
            var i = 0
            while (i < sample.length) {
                val cp = sample.codePointAt(i)
                val isCjk = cp in 0x4E00..0x9FFF || cp in 0x3040..0x30FF || cp in 0xAC00..0xD7AF
                val isLatin = cp in 0x41..0x5A || cp in 0x61..0x7A
                if (isCjk) cjk++
                if (isCjk || isLatin) letters++
                i += Character.charCount(cp)
            }
            if (letters == 0) return Ascii
            return if (cjk.toDouble() / letters > 0.3) Cjk else Ascii
        }
    }
}

/** Pure pacing algorithms, unit-testable on their own. codeStepSize and the fence test are reused by [StreamingBlockChunker]. */
internal object StreamingPacer {

    /** Above this backlog the text is snapped in wholesale rather than spending a long time catching up. A normal long answer should never reach it. */
    const val SNAP_BACKLOG = 20_000

    /** A first target longer than this is shown in full instead of replaying the animation from the start, which is what happens when re-attaching to a conversation already in progress. */
    const val INITIAL_SNAP = 400

    /** Reveal step for code, which does not fade per character; the goal is to look smooth while keeping up with generation at roughly 140 characters per second. */
    fun codeStepSize(backlog: Int): Int = when {
        backlog <= 80 -> 4
        backlog <= 400 -> 8
        backlog <= 1_200 -> 16
        else -> 32
    }

    /** Whether the visible boundary sits inside an unclosed ``` block, i.e. an odd number of lines start with ```. */
    fun isInsideUnclosedCodeFence(text: CharSequence): Boolean {
        if (!text.contains("```")) return false
        var fenceCount = 0
        var lineStart = 0
        var i = 0
        while (i <= text.length) {
            if (i == text.length || text[i] == '\n') {
                // Line [lineStart, i): counts once if it starts with ``` after trimming.
                var s = lineStart
                while (s < i && (text[s] == ' ' || text[s] == '\t')) s++
                if (i - s >= 3 && text[s] == '`' && text[s + 1] == '`' && text[s + 2] == '`') {
                    fenceCount++
                }
                lineStart = i + 1
            }
            i++
        }
        return fenceCount % 2 == 1
    }

}

/** How often the fade frame clock advances, about 30fps. */
private const val FADE_FRAME_INTERVAL_NANOS = 33_000_000L

/**
 * Diagnostics for rare events such as a snap or a broken prefix. These happen once or
 * twice per session, not per tick, so they are cheap enough to keep in release builds.
 * On the JVM, where there is no android.util.Log, it degrades to silence.
 */
internal object BlockCommitDiag {
    fun log(msg: String) {
        try {
            android.util.Log.i("OvBlockCommit", msg)
        } catch (_: Throwable) {
            // No android.util.Log under plain JVM unit tests; stay silent.
        }
    }
}

/**
 * State of the block-level streaming presentation. It holds the pacer's progress
 * ([visibleText]) plus the per-character staggered reveal timestamps the layer above
 * uses to fade a whole block in. Driven by [rememberStreamingReveal] on a
 * `withFrameNanos` frame loop.
 */
@Stable
internal class StreamingRevealState(
    private val cadence: BlockCommitCadence = BlockCommitCadence.Default,
) {

    /** Text released so far, always a prefix of the target and only ever advanced to a chunker safe boundary. */
    var visibleText by mutableStateOf("")
        private set

    /** Frame timestamp in ns, bumped once per fade step; this is what drives recomposition of the fade. */
    var frameNanos by mutableLongStateOf(0L)
        private set

    private val fadeDurationNanos = cadence.fadeDurationMs * 1_000_000L

    private var target: String = ""
    private var streamEnded = false
    private var profile = StreamingPacerProfile.Ascii
    private var lastProfileSampleLen = 0

    private var visibleLen = 0
    private var accumulatedDelayNanos = 0L
    private var lastTickNanos = 0L

    /** Reveal timestamp per character index, in ns; staggering can schedule some of them in the future. 0 means already settled, at alpha 1. */
    private var revealTimes = LongArray(0)

    /**
     * The latest reveal timestamp scheduled so far. Staggering pushes some characters
     * into the future, so the end of the fade window has to be measured against this;
     * otherwise the frame loop exits early and half-transparent characters snap to full
     * opacity the moment they settle.
     */
    private var lastScheduledRevealNanos = 0L

    /** Length of the prefix guaranteed fully settled, both revealed and past its fade window. Monotonic, advanced incrementally inside [onFrame]. */
    private var settledPrefixLen = 0

    /**
     * Frame-independent reading of how long the unsettled tail is: a plain field
     * subtraction that does not subscribe to the frame-clock state.
     *
     * It feeds the fade gate (a committed advance must not swallow a tail that is still
     * fading in) and the per-block fade dispatch (which blocks need to read the frame
     * clock at all). Both only need recomputing when the text changes, which is at the
     * block commit rate of about 8Hz; reading `frameNanos` here instead would subscribe
     * the entire list area to a recomposition on every frame.
     *
     * The value only ever errs conservatively: `settledPrefixLen` lags, so the tail can
     * be overestimated but never underestimated.
     */
    val unsettledTailApprox: Int
        get() = visibleLen - settledPrefixLen

    /** Accepts a new target. A non-streaming update either defers the finish, draining at the same cadence, or snaps; a streaming one snaps if it has to and otherwise keeps pacing. */
    fun onTarget(newTarget: String, isStreaming: Boolean) {
        if (!isStreaming) {
            streamEnded = true
            // Deferred finish: if we were mid-reveal - something is already on screen,
            // there is still backlog, and the prefix grew monotonically - keep draining at
            // the same cadence. The chunker sees isStreamEnd, releases every hold and
            // converges in a bounded number of steps. Otherwise (a history message that
            // never streamed, an already caught-up reveal, or a broken prefix) snap.
            if (visibleLen in 1 until newTarget.length && newTarget.startsWith(visibleText)) {
                target = newTarget
                return
            }
            snap(newTarget)
            return
        }
        streamEnded = false
        if (newTarget == target) return

        if (newTarget.length - lastProfileSampleLen > 200 || lastProfileSampleLen == 0) {
            profile = StreamingPacerProfile.detect(newTarget.take(200))
            lastProfileSampleLen = newTarget.length
        }

        val prefixBroke = !newTarget.startsWith(visibleText)
        val firstLarge = visibleLen == 0 && newTarget.length > StreamingPacer.INITIAL_SNAP
        val backlogExploded = newTarget.length - visibleLen > StreamingPacer.SNAP_BACKLOG
        if (prefixBroke || firstLarge || backlogExploded) {
            if (prefixBroke || backlogExploded) {
                BlockCommitDiag.log(
                    "snap prefixBroke=$prefixBroke firstLarge=$firstLarge " +
                        "backlogExploded=$backlogExploded visible=$visibleLen target=${newTarget.length}",
                )
            }
            snap(newTarget)
            return
        }
        target = newTarget
    }

    /** Pushes visible all the way to [text] at once, everything settled and with no fade. */
    private fun snap(text: String) {
        target = text
        visibleText = text
        visibleLen = text.length
        revealTimes = LongArray(0)
        lastScheduledRevealNanos = 0L
        settledPrefixLen = text.length
        accumulatedDelayNanos = 0L
        lastTickNanos = 0L
    }

    /** Whether any character is still inside its fade window, including ones staggered into the future. The layer above keeps the streaming render path alive until this clears. */
    val isFading: Boolean
        get() = lastScheduledRevealNanos != 0L &&
            frameNanos - lastScheduledRevealNanos < fadeDurationNanos

    /** Whether there is still work: backlog left to release, or characters still fading. */
    fun hasWork(): Boolean = visibleLen < target.length || isFading

    /** Frame callback: bumps `frameNanos` to drive the fade at about 30fps, advances the settled prefix, and releases the next block once its accumulated delay has elapsed. */
    fun onFrame(now: Long) {
        // The fade clock is throttled to ~30fps on purpose. Changing an alpha span goes
        // through Compose's annotationDiff in updateText, which invalidates the whole
        // layout cache and forces a full re-measure (see
        // TextAnnotatedStringNode.updateText/doInvalidations). Advancing it every frame at
        // 120Hz means four times the re-measures for an unstable cadence - and when frames
        // drop, a 250ms fade collapses into a handful of visible steps. At 30fps the
        // brightness staircase is imperceptible. Block commits (step) are not throttled and
        // still run every frame.
        // The settled prefix deliberately shares the throttled clock: the fade gate then
        // advances at most 33ms late, which errs in the safe direction.
        if (now - frameNanos >= FADE_FRAME_INTERVAL_NANOS) {
            frameNanos = now
        }
        advanceSettledPrefix(frameNanos)
        if (lastTickNanos == 0L) {
            lastTickNanos = now
            // Break the shell on the very first frame: try the first boundary immediately
            // rather than burning a frame waiting, which is what time-to-first-visible costs.
            if (visibleLen < target.length) step(now)
            return
        }
        val elapsed = now - lastTickNanos
        lastTickNanos = now
        if (visibleLen >= target.length) return
        accumulatedDelayNanos -= elapsed
        if (accumulatedDelayNanos > 0) return
        step(now)
    }

    private fun step(now: Long) {
        val boundary = StreamingBlockChunker.nextBoundary(visibleText, target, profile, cadence, streamEnded)
        when (boundary.kind) {
            StreamingBlockChunker.BoundaryKind.Held -> {
                // Nothing new is safe yet; while the source is unchanged this repeats and is
                // cheap. Retry after one chunk delay.
                accumulatedDelayNanos += cadence.chunkDelayMs * 1_000_000L
                return
            }
            StreamingBlockChunker.BoundaryKind.Snap -> {
                BlockCommitDiag.log("chunker snap visible=$visibleLen target=${target.length}")
                snap(target)
                return
            }
            else -> Unit
        }

        val newLen = boundary.newVisible.length
        scheduleReveal(from = visibleLen, until = newLen, now = now, kind = boundary.kind)
        visibleLen = newLen
        visibleText = boundary.newVisible

        // Per-kind cadence plus mid-range catch-up. The code fast path already scales its
        // own step size with the backlog, so it is excluded from the delay scaling.
        val baseDelayMs = when (boundary.kind) {
            StreamingBlockChunker.BoundaryKind.LineEnd -> cadence.lineEndDelayMs
            StreamingBlockChunker.BoundaryKind.ParagraphEnd -> cadence.paragraphDelayMs
            StreamingBlockChunker.BoundaryKind.TableRows -> cadence.tableRowDelayMs
            StreamingBlockChunker.BoundaryKind.CodeChunk -> profile.frameDelayMs
            else -> cadence.chunkDelayMs
        }
        val backlog = target.length - visibleLen
        val delayMs = if (
            backlog > cadence.catchupBacklogUtf16 &&
            boundary.kind != StreamingBlockChunker.BoundaryKind.CodeChunk
        ) {
            (baseDelayMs * cadence.catchupDelayScale).toLong()
        } else {
            baseDelayMs
        }
        accumulatedDelayNanos += delayMs * 1_000_000L
    }

    /**
     * Writes the reveal timestamps for a freshly committed block.
     *
     * A block longer than `fadeStaggerThresholdUtf16` is cut into segments of
     * `fadeStaggerSegmentUtf16` characters; segment `i` starts at `now + i * step`, where
     * `step = min(fadeStaggerStepMs, fadeStaggerMaxDelayMs / (segments - 1))`. That gives
     * the ripple effect while keeping the last segment from trailing into whole seconds.
     *
     * Code and table rows live in their own cards and do not fade per character, so they
     * settle immediately and never occupy the fade gate's window.
     */
    private fun scheduleReveal(from: Int, until: Int, now: Long, kind: StreamingBlockChunker.BoundaryKind) {
        ensureRevealCapacity(until)
        if (kind == StreamingBlockChunker.BoundaryKind.CodeChunk ||
            kind == StreamingBlockChunker.BoundaryKind.TableRows
        ) {
            for (idx in from until until) revealTimes[idx] = 0L
            return
        }
        val len = until - from
        if (len > cadence.fadeStaggerThresholdUtf16) {
            val segment = cadence.fadeStaggerSegmentUtf16
            val segCount = (len + segment - 1) / segment
            val stepNs = if (segCount > 1) {
                minOf(
                    cadence.fadeStaggerStepMs * 1_000_000L,
                    cadence.fadeStaggerMaxDelayMs * 1_000_000L / (segCount - 1),
                )
            } else {
                0L
            }
            for (idx in from until until) {
                revealTimes[idx] = now + ((idx - from) / segment) * stepNs
            }
        } else {
            for (idx in from until until) revealTimes[idx] = now
        }
        lastScheduledRevealNanos = maxOf(lastScheduledRevealNanos, revealTimes[until - 1])
    }

    private fun advanceSettledPrefix(now: Long) {
        while (settledPrefixLen < visibleLen) {
            val t = if (settledPrefixLen < revealTimes.size) revealTimes[settledPrefixLen] else 0L
            if (t != 0L && now - t < fadeDurationNanos) break
            settledPrefixLen++
        }
    }

    private fun ensureRevealCapacity(len: Int) {
        if (revealTimes.size >= len) return
        var cap = if (revealTimes.isEmpty()) 256 else revealTimes.size
        while (cap < len) cap *= 2
        revealTimes = revealTimes.copyOf(cap)
    }

    /**
     * Fade alpha of the character [k] positions from the end, where `k = 0` is the newest.
     *
     * @return 1 for a settled character or an index out of range, and 0 for one whose
     *   stagger schedules it in the future - it already occupies its final canonical
     *   layout position and is only waiting on alpha.
     *
     * The layer above maps this by aligning the end of the rendered text with the end of
     * [visibleText]. A block marker stripped from the start of a line sits in the settled
     * region at the head of the window, so the discrepancy is harmless and the alignment
     * at the tail is exact.
     */
    fun alphaFromEnd(k: Int): Float {
        val idx = visibleLen - 1 - k
        if (idx < 0 || idx >= revealTimes.size) return 1f
        val t = revealTimes[idx]
        if (t == 0L) return 1f
        val elapsed = frameNanos - t
        if (elapsed >= fadeDurationNanos) return 1f
        val p = (elapsed.toFloat() / fadeDurationNanos).coerceIn(0f, 1f)
        val inv = 1f - p
        return 1f - inv * inv * inv
    }

    /**
     * Length of the tail at the end of [visibleText] that is still inside its fade window
     * (alpha < 1), measured out to the farthest unsettled character.
     *
     * Staggering makes the timestamps non-monotonic across blocks - the tail segments of
     * an earlier block can be scheduled later than the head of a later one - so this
     * cannot stop at the first settled character. It scans backwards over a bounded
     * window instead and takes the farthest unsettled position. The 512-character bound
     * is comfortable: a 0.25s fade plus 0.3s of stagger covers far fewer characters than
     * that. Overrunning it, which needs an extreme catch-up, only leaves the fade gate
     * unprotecting the oldest few characters, which is cosmetic.
     *
     * Two callers: the fade gate, which must not let a committed advance swallow a tail
     * still fading in, and the fade-window dispatch for the streaming tail region.
     */
    fun fadingTailCount(): Int {
        if (!isFading) return 0
        val maxScan = minOf(visibleLen, 512)
        var farthest = 0
        var k = 0
        while (k < maxScan) {
            if (alphaFromEnd(k) < 1f) farthest = k + 1
            k++
        }
        return farthest
    }
}

/**
 * Remembers and drives a [StreamingRevealState]. The frame loop restarts whenever the
 * target changes or streaming is toggled; it advances the reveal and the fade through
 * `withFrameNanos` and suspends itself once it has caught up and the fade is over, so it
 * never spins.
 */
@Composable
internal fun rememberStreamingReveal(target: String, isStreaming: Boolean): StreamingRevealState {
    val state = remember { StreamingRevealState() }
    LaunchedEffect(target, isStreaming) {
        state.onTarget(target, isStreaming)
        while (state.hasWork()) {
            withFrameNanos { now -> state.onFrame(now) }
        }
    }
    return state
}
