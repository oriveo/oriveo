package ai.oriveo.community.core.data.repository.streaming

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Flush threshold lock test -- these thresholds (32 chars / 40ms / newline), matching iOS
 * ChatManager, are the core parameters behind fixing choppy streaming; falling back to coarser
 * granularity makes the pacing backlog jagged and the visuals feel rushed again, so they are
 * locked down against regression.
 */
class StreamingTokenBufferTest {

    @Test
    fun `appendDelta does not flush below char threshold`() {
        val b = StreamingTokenBuffer("")
        val now = System.currentTimeMillis() // same instant as construction -> the time threshold does not trigger
        // 31 chars (< 32), no newline -> no flush
        assertFalse(b.appendDelta("x".repeat(FLUSH_BELOW), now))
    }

    @Test
    fun `appendDelta flushes at char threshold`() {
        val b = StreamingTokenBuffer("")
        val now = System.currentTimeMillis()
        assertFalse(b.appendDelta("x".repeat(FLUSH_BELOW), now)) // cumulative 31
        assertTrue(b.appendDelta("x", now))                      // cumulative 32 -> flush
    }

    @Test
    fun `appendDelta flushes on newline`() {
        val b = StreamingTokenBuffer("")
        assertTrue(b.appendDelta("hi\n", System.currentTimeMillis()))
    }

    @Test
    fun `appendDelta flushes after time interval`() {
        val b = StreamingTokenBuffer("")
        val t0 = 1_000_000L
        b.drainTextToAccumulated(t0) // anchors lastFlushTime to t0
        assertFalse(b.appendDelta("x", t0 + StreamingTokenBuffer.FLUSH_INTERVAL_MS - 1)) // 39ms < 40ms
        assertTrue(b.appendDelta("x", t0 + StreamingTokenBuffer.FLUSH_INTERVAL_MS))      // 40ms >= 40ms
    }

    @Test
    fun `appendReasoning shares the same thresholds`() {
        val b = StreamingTokenBuffer("")
        val now = System.currentTimeMillis()
        assertFalse(b.appendReasoning("x".repeat(FLUSH_BELOW), now))
        assertTrue(b.appendReasoning("x", now)) // cumulative 32 -> flush
    }

    // ===== First visible flush strips leading whitespace (fixes a finalize-trim prefix mismatch, matching iOS sanitizedStreamingDelta) =====

    @Test
    fun `drain strips leading whitespace when accumulated is empty`() {
        val b = StreamingTokenBuffer("")
        b.appendDelta("\n\nHello there", System.currentTimeMillis())
        b.drainTextToAccumulated(System.currentTimeMillis())
        assertEquals("Hello there", b.accumulatedText)
    }

    @Test
    fun `drain keeps interior whitespace once accumulated is non-empty`() {
        val b = StreamingTokenBuffer("")
        b.appendDelta("body text", System.currentTimeMillis())
        b.drainTextToAccumulated(System.currentTimeMillis())
        b.appendDelta("\n\n## Heading", System.currentTimeMillis())
        b.drainTextToAccumulated(System.currentTimeMillis())
        assertEquals("body text\n\n## Heading", b.accumulatedText)
    }

    @Test
    fun `whitespace-only first drains keep stripping until first visible char`() {
        val b = StreamingTokenBuffer("")
        b.appendDelta("\n", System.currentTimeMillis())
        b.drainTextToAccumulated(System.currentTimeMillis())
        assertEquals("", b.accumulatedText)
        b.appendDelta(" \tbody starts", System.currentTimeMillis())
        b.drainTextToAccumulated(System.currentTimeMillis())
        assertEquals("body starts", b.accumulatedText)
    }

    @Test
    fun `continue with initialText does not strip leading whitespace`() {
        // continuing an existing message: accumulated starts non-empty from the original text -> the new delta is kept as-is
        val b = StreamingTokenBuffer("original text")
        b.appendDelta("\ncontinuation", System.currentTimeMillis())
        b.drainTextToAccumulated(System.currentTimeMillis())
        assertEquals("original text\ncontinuation", b.accumulatedText)
    }

    @Test
    fun `accumulated stays prefix of trimmed final text`() {
        // Core invariant: at any point during streaming, the accumulated text is a prefix of the
        // final Done text's accumulatedText.trim() (StreamingTextReveal.onTarget relies on this
        // startsWith check; shape mirrors real chunk boundaries from an upstream provider)
        val deltas = listOf("\n\nHere ", "are **Python, ", "Go, and JavaScript**\n", "sorting examples.")
        val b = StreamingTokenBuffer("")
        for (delta in deltas) {
            b.appendDelta(delta, System.currentTimeMillis())
            b.drainTextToAccumulated(System.currentTimeMillis())
            assertTrue(deltas.joinToString("").trim().startsWith(b.accumulatedText.trimEnd()))
        }
        assertEquals(deltas.joinToString("").trim(), b.accumulatedText.trimEnd())
    }

    private companion object {
        const val FLUSH_BELOW = StreamingTokenBuffer.FLUSH_CHAR_THRESHOLD - 1
    }
}
