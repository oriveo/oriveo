package ai.oriveo.community.ui.component.streaming

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure-algorithm unit tests for the pacer -- mirrors iOS's StreamingPacerTests.
 * Character-by-character fade-in is a visual concern (verified on real devices), but the
 * pacing logic behind "reveal character by character" is a deterministic pure function,
 * and that's what this test locks down.
 */
class StreamingTextRevealTest {

    // -- language profile detection --

    @Test
    fun `detect ascii for latin text`() {
        assertEquals(StreamingPacerProfile.Ascii, StreamingPacerProfile.detect("hello world"))
    }

    @Test
    fun `detect cjk when over 30 percent`() {
        assertEquals(StreamingPacerProfile.Cjk, StreamingPacerProfile.detect("おはよう"))
        // Japanese/English mixed, with a high CJK ratio
        assertEquals(StreamingPacerProfile.Cjk, StreamingPacerProfile.detect("はな hi そら"))
    }

    @Test
    fun `detect ascii when cjk under threshold`() {
        // 1 CJK character plus a lot of Latin text -> under 30%
        assertEquals(StreamingPacerProfile.Ascii, StreamingPacerProfile.detect("hello world の again here"))
    }

    @Test
    fun `detect empty is ascii`() {
        assertEquals(StreamingPacerProfile.Ascii, StreamingPacerProfile.detect(""))
    }

    // -- codeStepSize bands --

    @Test
    fun `codeStepSize bands`() {
        assertEquals(4, StreamingPacer.codeStepSize(80))
        assertEquals(8, StreamingPacer.codeStepSize(81))
        assertEquals(8, StreamingPacer.codeStepSize(400))
        assertEquals(16, StreamingPacer.codeStepSize(401))
        assertEquals(16, StreamingPacer.codeStepSize(1_200))
        assertEquals(32, StreamingPacer.codeStepSize(1_201))
    }

    // -- detecting an unclosed code fence --

    @Test
    fun `fence detection`() {
        assertFalse(StreamingPacer.isInsideUnclosedCodeFence("no code here"))
        assertTrue(StreamingPacer.isInsideUnclosedCodeFence("```\nsome code"))
        assertTrue(StreamingPacer.isInsideUnclosedCodeFence("```python\nprint('hi')"))
        assertFalse(StreamingPacer.isInsideUnclosedCodeFence("```\ncode\n```\n"))
        // an indented fence at the start of a line is still recognized
        assertTrue(StreamingPacer.isInsideUnclosedCodeFence("  ```\ncode"))
    }

    // -- StreamingRevealState snap decisions --

    @Test
    fun `non streaming snaps to full target`() {
        val s = StreamingRevealState()
        s.onTarget("full text", isStreaming = false)
        assertEquals("full text", s.visibleText)
        assertFalse(s.hasWork())
    }

    @Test
    fun `first large target snaps to avoid replay`() {
        val s = StreamingRevealState()
        val big = "x".repeat(StreamingPacer.INITIAL_SNAP + 1)
        s.onTarget(big, isStreaming = true)
        assertEquals(big, s.visibleText)
    }

    @Test
    fun `small first target paces from empty`() {
        val s = StreamingRevealState()
        s.onTarget("hi there", isStreaming = true)
        // no frame has been driven yet -> nothing released, but there's a backlog waiting to be paced
        assertEquals("", s.visibleText)
        assertTrue(s.hasWork())
    }

    // -- chunk-level stepping (6th generation) --

    private val t0 = 1_000_000_000L
    private fun ms(v: Long) = v * 1_000_000L

    @Test
    fun `first frame breaks shell with first chunk`() {
        // breaking the shell (TTFV): the first frame releases the first chunk immediately instead of waiting a frame for nothing; the first chunk is exempt from the leftover-word cap
        val s = StreamingRevealState()
        s.onTarget("Hello", isStreaming = true)
        s.onFrame(t0)
        assertEquals("Hello", s.visibleText)
        assertTrue(s.isFading)
    }

    @Test
    fun `word chunks pace at chunkDelay`() {
        val s = StreamingRevealState()
        s.onTarget("The quick brown fox jumps over the lazy dog near here", isStreaming = true)
        s.onFrame(t0) // breaking the shell: the first chunk
        val first = s.visibleText
        assertEquals("The quick brown ", first)
        s.onFrame(t0 + ms(60)) // 60ms < chunkDelay of 100ms -> does not advance
        assertEquals(first, s.visibleText)
        s.onFrame(t0 + ms(110)) // past 100ms -> second chunk
        assertTrue(s.visibleText.length > first.length)
    }

    @Test
    fun `line end applies longer pause`() {
        val s = StreamingRevealState()
        s.onTarget("tiny\nnext line words", isStreaming = true)
        s.onFrame(t0) // breaking the shell: the whole line "tiny\n" (LineEnd, 140ms pause)
        assertEquals("tiny\n", s.visibleText)
        s.onFrame(t0 + ms(110)) // chunkDelay has passed but the lineEnd pause has not -> does not advance
        assertEquals("tiny\n", s.visibleText)
        s.onFrame(t0 + ms(150)) // past 140ms -> advances
        assertTrue(s.visibleText.length > 5)
    }

    @Test
    fun `catchup halves delay when backlog large`() {
        // backlog > 400: word-chunk delay is halved -> the 100ms chunk interval drops to 50ms.
        // note: the first target can't be handed a large text directly (anything over INITIAL_SNAP
        // gets snapped as a whole), so this feeds a realistic growth path instead.
        val s = StreamingRevealState()
        s.onTarget("word word ", isStreaming = true)
        s.onFrame(t0) // breaking the shell releases the whole first (small) target
        assertEquals("word word ", s.visibleText)
        s.onTarget("word ".repeat(90).trimEnd(), isStreaming = true) // backlog ~440 > 400
        s.onFrame(t0 + ms(110)) // past chunkDelay -> advances one chunk, and the interval after it is now halved by catchup
        val mark = s.visibleText.length
        assertTrue(mark > 10)
        s.onFrame(t0 + ms(110) + ms(60)) // 60ms > 50ms (after catchup) -> already advanced; without catchup this would need to wait 100ms
        assertTrue(s.visibleText.length > mark)
    }

    @Test
    fun `large line commit staggers reveal into the future`() {
        val s = StreamingRevealState()
        val longLine = "second line is quite long and should stagger nicely here"
        s.onTarget("first\n$longLine\n", isStreaming = true)
        s.onFrame(t0) // "first\n"
        assertEquals("first\n", s.visibleText)
        s.onFrame(t0 + ms(150)) // the whole line is committed at once (>16 characters -> staggered phase)
        assertEquals("first\n$longLine\n", s.visibleText)
        // the tail segment is scheduled into the future: the last character's alpha is 0 (placeholder, not yet faded in), and the whole chunk unfolds like a wave
        assertEquals(0f, s.alphaFromEnd(0))
        assertTrue(s.fadingTailCount() >= longLine.length)
        assertTrue(s.isFading)
        // after the staggering cap of 300ms plus the 250ms fade, everything has settled
        s.onFrame(t0 + ms(150) + ms(300) + ms(250) + ms(10))
        assertFalse(s.isFading)
        assertEquals(0, s.fadingTailCount())
        assertFalse(s.hasWork())
    }

    @Test
    fun `code chunks settle immediately without fade`() {
        val s = StreamingRevealState()
        s.onTarget("```\nabcdefgh\n```\n", isStreaming = true)
        s.onFrame(t0) // the fence-opening line (LineEnd)
        assertEquals("```\n", s.visibleText)
        s.onFrame(t0 + ms(150)) // a chunk of code characters
        assertTrue(s.visibleText.length > 4)
        assertEquals(1f, s.alphaFromEnd(0)) // code doesn't fade in character by character, it settles immediately
    }

    @Test
    fun `drain after stream end converges with same cadence`() {
        val s = StreamingRevealState()
        s.onTarget("some words here ", isStreaming = true)
        s.onFrame(t0)
        assertTrue(s.visibleText.isNotEmpty())
        // stream ended: the remaining backlog plus any unclosed trailing structure drains at the same cadence (a hold releases it)
        val full = "some words here and **bold tail"
        s.onTarget(full, isStreaming = false)
        var now = t0
        var guard = 0
        while (s.visibleText.length < full.length) {
            now += ms(200)
            s.onFrame(now)
            guard++
            assertTrue("drain must converge", guard < 100)
        }
        assertEquals(full, s.visibleText)
        // once the fade window has passed there's nothing left going on
        s.onFrame(now + ms(600))
        assertFalse(s.hasWork())
    }

    @Test
    fun `aborted mid-table drain converges`() {
        val s = StreamingRevealState()
        s.onTarget("intro line\n| a | b |", isStreaming = true)
        s.onFrame(t0)
        assertEquals("intro line\n", s.visibleText) // the table header is held back
        val full = "intro line\n| a | b |\n| -"
        s.onTarget(full, isStreaming = false)
        var now = t0
        var guard = 0
        while (s.visibleText.length < full.length) {
            now += ms(200)
            s.onFrame(now)
            guard++
            assertTrue("aborted drain must converge", guard < 100)
        }
        assertEquals(full, s.visibleText)
    }

    // -- fade frame clock throttled to ~30fps (rebuilding the alpha span triggers a full Text remeasure, so doing it every frame at 120Hz would cost 4x) --

    @Test
    fun `fade frame clock throttles below 33ms`() {
        val s = StreamingRevealState()
        s.onTarget("Hello world good", isStreaming = true)
        s.onFrame(t0)
        assertEquals(t0, s.frameNanos)
        s.onFrame(t0 + ms(10)) // <33ms -> frameNanos does not bump (fade rendering is throttled; chunk stepping is unaffected)
        assertEquals(t0, s.frameNanos)
        s.onFrame(t0 + ms(40)) // ≥33ms → bump
        assertEquals(t0 + ms(40), s.frameNanos)
    }

    // -- fadingTailCount (the gating window for the fade / for keeping the tail alive) --

    @Test
    fun `fadingTailCount is zero before any reveal`() {
        val s = StreamingRevealState()
        s.onTarget("hello", isStreaming = true)
        assertEquals(0, s.fadingTailCount())
    }

    @Test
    fun `fadingTailCount covers just-committed chunk and clears after window`() {
        val s = StreamingRevealState()
        s.onTarget("ab", isStreaming = true)
        s.onFrame(t0) // breaking the shell commits "ab"
        assertEquals("ab", s.visibleText)
        assertEquals(2, s.fadingTailCount())
        s.onFrame(t0 + ms(250) + 1L) // after the 0.25s fade window everything has settled
        assertEquals(0, s.fadingTailCount())
    }

    @Test
    fun `fadingTailCount is zero after snap`() {
        val s = StreamingRevealState()
        val big = "x".repeat(StreamingPacer.INITIAL_SNAP + 1)
        s.onTarget(big, isStreaming = true) // the first target is already large -> it snaps, with no fade
        assertEquals(big, s.visibleText)
        assertEquals(0, s.fadingTailCount())
        assertFalse(s.hasWork())
    }
}
