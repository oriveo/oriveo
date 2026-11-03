package ai.oriveo.community.core.data.repository.streaming

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Token buffer and flush policy for streamed text, split out of ChatRepository.sendMessage.
 *
 * Holds the body and reasoning buffers plus the accumulated text, and the throttle counters for
 * L4 partial persistence. Every method is consumed sequentially from the collect block inside
 * sendMessage and is **not thread-safe**; callers must call it serially.
 *
 * Flush policy (aligned with iOS ChatManager.flushBufferedDelta: 32 chars / 40 ms / newline):
 *  - a body buffer flushes to accumulated when any of 32 chars, a newline or 40 ms is reached
 *  - reasoning uses the symmetric 32 chars / newline / 40 ms throttle
 *  - long streams persist partials actively: 4000 chars / 60 s
 *
 * Why the grain is fine (it used to be 100 chars / 180 ms): the pacer [StreamingRevealState] can only
 * advance within the target prefix already received, so a coarse flush makes the target jump in large
 * batches every 180 ms and the backlog saw-tooth upward. With block-level commit rendering, the pacer
 * advances by complete syntax blocks at a steady ~120 utf16/s, and the backlog is absorbed by the
 * BlockCommitCadence catchup (backlog > 400 -> delay x0.5) and multiLine tier-up. 32 chars / 40 ms keeps
 * the target growing in smooth small steps and makes block boundaries (word, line end, table row)
 * decidable sooner, so it is still the right grain for block-level pacing.
 *
 * continue / explicit resend: initialText / initialReasoning are passed at construction, and both
 * accumulation chains start from the content already generated.
 */
internal class StreamingTokenBuffer(initialText: String, initialReasoning: String = "") {
    private val buffer = StringBuilder()
    private val accumulated = StringBuilder(initialText)
    private val accumulatedReasoning = StringBuilder(initialReasoning)
    private val reasoningBuffer = StringBuilder()

    private var lastFlushTime = System.currentTimeMillis()
    private var lastReasoningFlushTime = System.currentTimeMillis()
    private var lastPartialFlushTime = System.currentTimeMillis()
    private var lastPartialFlushLength = 0

    val accumulatedText: String get() = accumulated.toString()
    val accumulatedReasoningText: String get() = accumulatedReasoning.toString()
    val accumulatedTextLength: Int get() = accumulated.length

    fun appendDelta(text: String, now: Long): Boolean {
        buffer.append(text)
        val containsNewline = text.contains("\n")
        return buffer.length >= FLUSH_CHAR_THRESHOLD ||
            containsNewline ||
            (now - lastFlushTime) >= FLUSH_INTERVAL_MS
    }

    /**
     * Milliseconds left until the buffered text tail is due for a time-based flush, or null when the
     * text buffer is empty. Lets the caller schedule a one-shot trailing flush when the stream stalls.
     */
    fun millisUntilFlush(now: Long): Long? {
        if (buffer.isEmpty()) return null
        return (FLUSH_INTERVAL_MS - (now - lastFlushTime)).coerceIn(0L, FLUSH_INTERVAL_MS)
    }

    /** Moves the buffer into accumulated, clears the buffer and updates lastFlushTime. */
    fun drainTextToAccumulated(now: Long) {

        if (accumulated.isEmpty()) {
            var start = 0
            while (start < buffer.length && buffer[start].isWhitespace()) start++
            if (start > 0) buffer.delete(0, start)
        }
        accumulated.append(buffer)
        buffer.clear()
        lastFlushTime = now
    }

    fun appendReasoning(text: String, now: Long): Boolean {
        accumulatedReasoning.append(text)
        reasoningBuffer.append(text)
        val containsNewline = text.contains("\n")
        return reasoningBuffer.length >= FLUSH_CHAR_THRESHOLD ||
            containsNewline ||
            (now - lastReasoningFlushTime) >= FLUSH_INTERVAL_MS
    }

    fun markReasoningFlushed(now: Long) {
        reasoningBuffer.clear()
        lastReasoningFlushTime = now
    }

    fun hasPendingText(): Boolean = buffer.isNotEmpty()

    fun hasPendingReasoning(): Boolean = reasoningBuffer.isNotEmpty()

    fun shouldPartialFlush(now: Long, charThreshold: Int, timeThresholdMs: Long): Boolean {
        val accumLen = accumulated.length
        return accumLen - lastPartialFlushLength >= charThreshold ||
            (now - lastPartialFlushTime) >= timeThresholdMs
    }

    fun markPartialFlushed(now: Long) {
        lastPartialFlushTime = now
        lastPartialFlushLength = accumulated.length
    }

    fun clear() {
        buffer.clear()
    }

    companion object {

        const val FLUSH_CHAR_THRESHOLD = 32

        const val FLUSH_INTERVAL_MS = 40L
    }
}

/**
 * One-shot trailing flush for [StreamingTokenBuffer]: when the stream stalls with a buffered tail,
 * [arm] launches a single delay job in the caller's [scope] that invokes [onFlush] when due.
 * The job only exists while the buffer is non-empty (not a resident timer).
 *
 * Mutual exclusion: the collector must call [cancel] before touching the buffer again. [cancel]
 * cancels and joins, so a flush already past its delay finishes before the collector proceeds, and a
 * pending one never runs afterwards.
 */
internal class TrailingFlushScheduler(
    private val scope: CoroutineScope,
    private val onFlush: () -> Unit,
) {
    private var job: Job? = null

    fun arm(delayMs: Long) {
        job?.cancel()
        job = scope.launch {
            delay(delayMs)
            onFlush()
        }
    }

    suspend fun cancel() {
        val pending = job ?: return
        job = null
        pending.cancelAndJoin()
    }
}
