package ai.oriveo.community.ui.component.streaming

import ai.oriveo.community.ui.component.streaming.StreamingBlockChunker.Boundary
import ai.oriveo.community.ui.component.streaming.StreamingBlockChunker.BoundaryKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Unit tests for the block-commit boundary state machine -- mirrors iOS's StreamingBlockChunkerTests plus Android-specific rules. */
class StreamingBlockChunkerTest {

    private val cadence = BlockCommitCadence.Default

    private fun next(
        visible: String,
        target: String,
        profile: StreamingPacerProfile = StreamingPacerProfile.Ascii,
        streamEnd: Boolean = false,
    ): Boundary = StreamingBlockChunker.nextBoundary(visible, target, profile, cadence, streamEnd)

    // -- word chunks --

    @Test
    fun `ascii word chunk advances to word boundary with trailing space`() {
        val b = next("", "The quick brown fox jumps over")
        assertEquals(BoundaryKind.WordChunk, b.kind)
        assertEquals("The quick brown ", b.newVisible)
    }

    @Test
    fun `cjk chunk advances by char count`() {
        val b = next("", "アイウエオカキクケコサシ", profile = StreamingPacerProfile.Cjk)
        assertEquals(BoundaryKind.WordChunk, b.kind)
        assertEquals("アイウエオカ", b.newVisible)
    }

    @Test
    fun `first reveal exempts partial word hold`() {
        // time-to-first-visible: the first chunk is released immediately even without a trailing space
        val b = next("", "Hello")
        assertEquals(BoundaryKind.WordChunk, b.kind)
        assertEquals("Hello", b.newVisible)
    }

    @Test
    fun `cjk chunk on long ordered marker line commits marker atomically`() {
        // Regression guard: when markerLen(7) > wordChunkLenCjk(6), the boundary could land
        // inside the marker itself, causing an out-of-bounds substring(7, 6) crash.
        val b = next("", "12345. カカカカカカ", profile = StreamingPacerProfile.Cjk)
        assertEquals(BoundaryKind.WordChunk, b.kind)
        assertTrue(b.newVisible.startsWith("12345. "))
    }

    @Test
    fun `cjk chunk on h6 heading line commits marker atomically`() {
        val b = next("", "###### カカカカカカ", profile = StreamingPacerProfile.Cjk)
        assertEquals(BoundaryKind.WordChunk, b.kind)
        assertTrue(b.newVisible.startsWith("###### "))
    }

    @Test
    fun `late materialized marker after committed prefix stays safe`() {
        // The line prefix is first committed as plain text (committedInLine < markerLen) before
        // the marker forms; this must never go out of bounds.
        val b = next("12345", "12345. カカカカカカ", profile = StreamingPacerProfile.Cjk)
        assertTrue(b.newVisible.length >= "12345".length)
        assertTrue("12345. カカカカカカ".startsWith(b.newVisible))
    }

    @Test
    fun `partial trailing word held when not first reveal`() {
        val b = next("Hello world ", "Hello world aga")
        assertEquals(BoundaryKind.Held, b.kind)
        assertEquals("Hello world ", b.newVisible)
    }

    @Test
    fun `hold at unclosed bold then extend through closed span`() {
        // Unclosed **: the word-chunk limit stops right before the opener
        val held = next("", "say **bold")
        assertEquals("say ", held.newVisible)
        // Once closed, the whole span is released
        val closed = next("say ", "say **bold** x")
        assertTrue(closed.newVisible.endsWith("**bold** "))
    }

    @Test
    fun `span atomization extends chunk end past closed inline span`() {
        // When the ideal end point lands inside a closed span, extend to the close (committing
        // half a bold marker would render literally)
        val b = next("", "alpha **bold span** tail more after")
        assertEquals(BoundaryKind.WordChunk, b.kind)
        assertTrue(b.newVisible.endsWith("span**") || b.newVisible.endsWith("span** "))
    }

    @Test
    fun `inline hold degrades after maxInlineHoldUtf16`() {
        val line = "**" + "a".repeat(125)
        val b = next("", line)
        assertEquals(BoundaryKind.WordChunk, b.kind)
        assertTrue(b.newVisible.isNotEmpty()) // past the limit it's released literally instead of stalling the whole line
    }

    @Test
    fun `no-space long line degrades to char blocks`() {
        val line = "x".repeat(80)
        val b = next("x".repeat(12), line)
        assertEquals(BoundaryKind.WordChunk, b.kind)
        assertEquals("x".repeat(24), b.newVisible)
    }

    @Test
    fun `surrogate pair never split`() {
        val target = "a🎉🎉🎉🎉"
        val b = next("", target, profile = StreamingPacerProfile.Cjk)
        // ideal=6 lands inside the 5-6 surrogate pair, so it falls back to 5
        assertEquals(5, b.newVisible.length)
    }

    // -- line end / paragraph --

    @Test
    fun `line completion commits remainder with newline`() {
        val b = next("Hello ", "Hello world\nNext")
        assertEquals(BoundaryKind.LineEnd, b.kind)
        assertEquals("Hello world\n", b.newVisible)
    }

    @Test
    fun `blank line is paragraph end`() {
        val b = next("Para\n", "Para\n\nNext")
        assertEquals(BoundaryKind.ParagraphEnd, b.kind)
        assertEquals("Para\n\n", b.newVisible)
    }

    @Test
    fun `multi-line expansion under big backlog`() {
        val target = (1..300).joinToString("") { "line $it\n" }
        val b = next("", target)
        assertEquals(BoundaryKind.LineEnd, b.kind)
        assertEquals("line 1\nline 2\nline 3\n", b.newVisible)
    }

    @Test
    fun `multi-line expansion stops before fence start`() {
        val filler = "x".repeat(1600)
        val target = "first line\n```\n$filler\n```\n"
        val b = next("", target)
        assertEquals("first line\n", b.newVisible)
    }

    // -- line-start protocol --

    @Test
    fun `fence opener line commits atomically`() {
        val held = next("", "```kotlin")
        assertEquals(BoundaryKind.Held, held.kind)
        val b = next("", "```kotlin\ncode")
        assertEquals(BoundaryKind.LineEnd, b.kind)
        assertEquals("```kotlin\n", b.newVisible)
    }

    @Test
    fun `code chunks inside fence and clamp at closing fence line`() {
        val target = "```kotlin\ncode here\nmore\n```\nafter prose"
        var visible = "```kotlin\n"
        var guard = 0
        while (true) {
            val b = next(visible, target)
            if (b.kind != BoundaryKind.CodeChunk) break
            assertTrue(b.newVisible.length > visible.length)
            visible = b.newVisible
            // never advances past the closing fence line into the body
            assertTrue(visible.length <= target.indexOf("```\n", 10) + 4)
            guard++
            assertTrue(guard < 100)
        }
        assertEquals("```kotlin\ncode here\nmore\n```\n", visible)
    }

    @Test
    fun `hr candidate held until line end`() {
        assertEquals(BoundaryKind.Held, next("", "---").kind)
        val b = next("", "---\nx")
        assertEquals(BoundaryKind.LineEnd, b.kind)
        assertEquals("---\n", b.newVisible)
    }

    @Test
    fun `heading hashes held until space arrives`() {
        // Android's parseHeadingLine requires a space; #### (4 characters) is outside iOS's <4
        // ambiguity window, so it must be held deterministically
        assertEquals(BoundaryKind.Held, next("", "####").kind)
        assertEquals(BoundaryKind.Held, next("", "######").kind)
        val b = next("", "#### Title")
        assertEquals(BoundaryKind.WordChunk, b.kind)
        assertEquals("#### Title", b.newVisible)
    }

    @Test
    fun `seven hashes is plain text not held`() {
        val b = next("", "#######x more words here")
        assertNotEquals(BoundaryKind.Held, b.kind)
    }

    @Test
    fun `ordered list prefix held until decidable`() {
        assertEquals(BoundaryKind.Held, next("", "1").kind)
        assertEquals(BoundaryKind.Held, next("", "12.").kind)
        val b = next("", "1. first item")
        assertEquals(BoundaryKind.WordChunk, b.kind)
        assertTrue(b.newVisible.startsWith("1. "))
    }

    @Test
    fun `short marker ambiguity window holds`() {
        assertEquals(BoundaryKind.Held, next("", ">").kind)
        assertEquals(BoundaryKind.Held, next("", "``").kind)
        assertEquals(BoundaryKind.Held, next("", "\\").kind)
    }

    // -- table protocol --

    @Test
    fun `table header and separator commit atomically with complete data rows`() {
        val target = "| a | b |\n| --- | --- |\n| 1 | 2 |\npartial"
        val b = next("", target)
        assertEquals(BoundaryKind.TableRows, b.kind)
        assertEquals("| a | b |\n| --- | --- |\n| 1 | 2 |\n", b.newVisible)
    }

    @Test
    fun `table header held until separator line decidable`() {
        assertEquals(BoundaryKind.Held, next("", "| a | b |").kind)
        assertEquals(BoundaryKind.Held, next("", "| a | b |\n| -").kind)
    }

    @Test
    fun `pipe line followed by non-separator commits as plain line`() {
        val b = next("", "| a | b |\nplain text\n")
        assertEquals(BoundaryKind.LineEnd, b.kind)
        assertEquals("| a | b |\n", b.newVisible)
    }

    @Test
    fun `open table data rows commit row atomically`() {
        val committed = "| a |\n| --- |\n"
        val b = next(committed, committed + "| 1 |\n| 2")
        assertEquals(BoundaryKind.TableRows, b.kind)
        assertEquals(committed + "| 1 |\n", b.newVisible)
    }

    @Test
    fun `open table holds incomplete data row`() {
        val committed = "| a |\n| --- |\n"
        val b = next(committed, committed + "| 1")
        assertEquals(BoundaryKind.Held, b.kind)
    }

    // -- block math --

    @Test
    fun `block math held until closing line complete`() {
        assertEquals(BoundaryKind.Held, next("", "\$\$\nE=mc^2").kind)
        val b = next("", "\$\$\nE=mc^2\n\$\$\nafter")
        assertEquals(BoundaryKind.LineEnd, b.kind)
        assertEquals("$$\nE=mc^2\n$$\n", b.newVisible)
    }

    @Test
    fun `single line block math commits at line end`() {
        val b = next("", "\$\$x^2\$\$\nrest")
        assertEquals(BoundaryKind.LineEnd, b.kind)
        assertEquals("\$\$x^2\$\$\n", b.newVisible)
    }

    @Test
    fun `latex bracket block held until closing line`() {
        assertEquals(BoundaryKind.Held, next("", "\\[\nx + y").kind)
        val b = next("", "\\[\nx + y\n\\]\nafter")
        assertEquals(BoundaryKind.LineEnd, b.kind)
        assertEquals("\\[\nx + y\n\\]\n", b.newVisible)
    }

    // ── snap / held / drain ──

    @Test
    fun `snap on non-prefix visible`() {
        val b = next("abc", "xyz longer target")
        assertEquals(BoundaryKind.Snap, b.kind)
        assertEquals("xyz longer target", b.newVisible)
    }

    @Test
    fun `held when caught up`() {
        val b = next("done", "done")
        assertEquals(BoundaryKind.Held, b.kind)
    }

    @Test
    fun `drain converges monotonically on aborted structures`() {
        val targets = listOf(
            "| a | b |\n| -- incomplete",
            "**unclosed bold at the very end",
            "\$\$\nnever closed math",
            "```python\nno closing fence",
            "```py\ncode\n``",
            "1",
            "####",
            "normal text then \\(half formula",
        )
        for (target in targets) {
            var visible = ""
            var guard = 0
            while (visible.length < target.length) {
                val b = next(visible, target, streamEnd = true)
                assertNotEquals("drain held on: $target", BoundaryKind.Held, b.kind)
                assertTrue("drain must advance on: $target", b.newVisible.length > visible.length)
                visible = b.newVisible
                guard++
                assertTrue("drain did not converge on: $target", guard < 1_000)
            }
            assertEquals(target, visible)
        }
    }

    @Test
    fun `streaming progression is monotone and converges with full target`() {
        val target = "# Title\n\nIntro **bold** text.\n\n- item one\n- item two\n\n" +
            "| H | K |\n| --- | --- |\n| 1 | 2 |\n\n```js\nlet x = 1\n```\n\ndone"
        var visible = ""
        var guard = 0
        while (visible.length < target.length) {
            val b = next(visible, target)
            if (b.kind == BoundaryKind.Held) {
                // With the full target already in hand, only a trailing line remainder may be
                // held; drain finishes it off
                val drained = next(visible, target, streamEnd = true)
                assertTrue(drained.newVisible.length > visible.length)
                visible = drained.newVisible
            } else {
                assertTrue(b.newVisible.length > visible.length)
                visible = b.newVisible
            }
            guard++
            assertTrue(guard < 1_000)
        }
        assertEquals(target, visible)
    }
}
