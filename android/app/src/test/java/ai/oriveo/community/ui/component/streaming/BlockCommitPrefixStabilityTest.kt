package ai.oriveo.community.ui.component.streaming

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import ai.oriveo.community.ui.component.markdown.MarkdownBlock
import ai.oriveo.community.ui.component.markdown.MarkdownBlockEntry
import ai.oriveo.community.ui.component.markdown.MarkdownColors
import ai.oriveo.community.ui.component.markdown.MarkdownRenderer
import ai.oriveo.community.ui.component.markdown.parseBlocksWithGaps
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Locks in render-prefix monotonicity (the Compose-side equivalent of the concatenation
 * lock): `visible` only ever advances at chunker-safe boundaries, so for any two adjacent
 * commit boundaries P1 subset of P2:
 *   1. parseBlocksWithGaps(P1) is a block-level prefix of parseBlocksWithGaps(P2) (every
 *      entry matches except the last block, which may grow in place);
 *   2. for text blocks, MarkdownRenderer.render(text1) is a style-level prefix of
 *      render(text2) (the string prefix matches, and every span/link intersecting that
 *      prefix matches too).
 * Pixels already committed to the screen never change -- that is the structural guarantee
 * behind "a block, once committed, is final."
 *
 * Two drivers exercise this: feeding the full target in one shot (the hold resolves
 * immediately) and feeding it character by character (a hold-then-release path). Every
 * intermediate `visible` produced by either driver must satisfy the properties above.
 */
class BlockCommitPrefixStabilityTest {

    private val colors = MarkdownColors(
        text = Color.Black,
        textSecondary = Color.Gray,
        link = Color.Blue,
        inlineCodeText = Color.DarkGray,
        inlineCodeBg = Color.LightGray,
        codeBlockBg = Color.Black,
        codeBlockSurface = Color.DarkGray,
        codeBlockBorder = Color.Gray,
        codeBlockFg = Color.White,
        codeBlockSecondary = Color.Gray,
        syntaxKeyword = Color.Magenta,
        syntaxString = Color.Green,
        syntaxComment = Color.Gray,
        syntaxNumber = Color.Yellow,
        syntaxType = Color.Cyan,
        syntaxVariable = Color(0xFF5EEAD4),
        quoteBorder = Color.Blue,
        quoteText = Color.Gray,
        tableBorder = Color.Gray,
        tableHeaderBg = Color.LightGray,
        tableCellBg = Color.White,
        tableAltRowBg = Color.LightGray,
    )

    private val docs = mapOf(
        "prose-inline" to "Here is **bold** and *italic* with `code` and [link](https://x.com) " +
            "plus ~~strike~~ stuff.\nSecond line has **more bold** in it.\n\nNew paragraph after blank line.",
        "headings-lists" to "# Title\n\nIntro paragraph text.\n\n## Section two\n\n> quoted wisdom here\n\n" +
            "- item one with **bold**\n- item two\n+ item three\n\n1. first entry\n2. second entry\n\n---\n\nAfter rule.",
        "table" to "Before the table.\n\n| H1 | H2 |\n| --- | --- |\n| a | b |\n| c | d |\n\nAfter the table.",
        "code" to "Intro line.\n\n```kotlin\nfun main() {\n    println(\"hi **not bold**\")\n}\n```\n\nAfter code block.",
        "math-currency" to "Block math below:\n\n$$\nE = mc^2\n$$\n\nInline \$x+y\$ math, price \$40 and \\(a\\) done.",
        "cjk" to "かなのだんらくをもじすうですすめます。**ふとじのかな**と`コード`をまぜてつづけます。\nにぎょうめもかなをつづけます。\n\nあたらしいだんらくです。",
        "adversarial" to "| not | a-table |\nplain line after pipe\n\n#### Heading4 text\n\n1. ordered item one\n\n" +
            "URL https://example.com/very/long/path/without/any/spaces/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa end",
    )

    @Test
    fun `full-target chunk sequence keeps render prefix-monotone`() {
        for ((name, doc) in docs) {
            val prefixes = chunkSequence(doc, incremental = false)
            assertStability(name, prefixes, doc)
        }
    }

    @Test
    fun `incremental-arrival chunk sequence keeps render prefix-monotone`() {
        for ((name, doc) in docs) {
            val prefixes = chunkSequence(doc, incremental = true)
            assertStability(name, prefixes, doc)
        }
    }

    // -- drivers --

    private fun chunkSequence(target: String, incremental: Boolean): List<String> {
        val cadence = BlockCommitCadence.Default
        val profile = StreamingPacerProfile.detect(target.take(200))
        val prefixes = mutableListOf<String>()
        var visible = ""
        var guard = 0

        if (incremental) {
            // Feed incrementally in 3-character steps: the hold releases once its content arrives
            var arrived = 0
            while (arrived < target.length) {
                arrived = minOf(arrived + 3, target.length)
                val partial = target.substring(0, arrived)
                var progressing = true
                while (progressing && visible.length < partial.length) {
                    val b = StreamingBlockChunker.nextBoundary(visible, partial, profile, cadence, false)
                    when (b.kind) {
                        StreamingBlockChunker.BoundaryKind.Held -> progressing = false
                        else -> {
                            assertTrue("monotone", b.newVisible.length > visible.length)
                            visible = b.newVisible
                            prefixes.add(visible)
                        }
                    }
                    guard++
                    assertTrue("guard", guard < 50_000)
                }
            }
        } else {
            while (visible.length < target.length) {
                val b = StreamingBlockChunker.nextBoundary(visible, target, profile, cadence, false)
                if (b.kind == StreamingBlockChunker.BoundaryKind.Held) break
                assertTrue("monotone", b.newVisible.length > visible.length)
                visible = b.newVisible
                prefixes.add(visible)
                guard++
                assertTrue("guard", guard < 50_000)
            }
        }
        // drain: release the trailing hold once the stream ends (only a line-end remainder should be left)
        while (visible.length < target.length) {
            val b = StreamingBlockChunker.nextBoundary(visible, target, profile, cadence, true)
            assertTrue("drain monotone", b.newVisible.length > visible.length)
            visible = b.newVisible
            prefixes.add(visible)
            guard++
            assertTrue("drain guard", guard < 50_000)
        }
        assertEquals(target, visible)
        return prefixes
    }

    // -- assertions --

    private fun assertStability(name: String, prefixes: List<String>, target: String) {
        var prev: List<MarkdownBlockEntry>? = null
        var prevText: String? = null
        for (p in prefixes) {
            val cur = parseBlocksWithGaps(p)
            if (prev != null) {
                assertBlocksPrefix(name, prevText!!, prev, cur)
            }
            prev = cur
            prevText = p
        }
        // final state == parsing the full text (no difference remains after drain)
        assertEquals("[$name] final blocks", parseBlocksWithGaps(target), prev)
    }

    private fun assertBlocksPrefix(
        name: String,
        prevVisible: String,
        b1: List<MarkdownBlockEntry>,
        b2: List<MarkdownBlockEntry>,
    ) {
        val ctx = "[$name] after: ${prevVisible.takeLast(48).replace("\n", "\\n")}"
        assertTrue("$ctx block count must not shrink", b2.size >= b1.size)
        for (i in 0 until b1.size - 1) {
            assertEquals("$ctx block#$i must be frozen", b1[i], b2[i])
        }
        if (b1.isEmpty()) return
        val last1 = b1.last()
        val last2 = b2[b1.size - 1]
        assertEquals("$ctx last block gapBefore", last1.gapBefore, last2.gapBefore)
        val blk1 = last1.block
        val blk2 = last2.block
        assertEquals("$ctx last block type", blk1::class, blk2::class)
        when (blk1) {
            is MarkdownBlock.Paragraph -> {
                val t2 = (blk2 as MarkdownBlock.Paragraph).text
                assertTrue("$ctx paragraph text extends", t2.startsWith(blk1.text))
                assertRenderPrefix(ctx, blk1.text, t2)
            }
            is MarkdownBlock.Heading -> {
                val h2 = blk2 as MarkdownBlock.Heading
                assertEquals("$ctx heading level", blk1.level, h2.level)
                assertTrue("$ctx heading text extends", h2.text.startsWith(blk1.text))
                assertRenderPrefix(ctx, blk1.text, h2.text)
            }
            is MarkdownBlock.BlockQuote -> {
                val q2 = blk2 as MarkdownBlock.BlockQuote
                assertTrue("$ctx quote text extends", q2.text.startsWith(blk1.text))
                assertRenderPrefix(ctx, blk1.text, q2.text)
            }
            is MarkdownBlock.ListItem -> {
                val l2 = blk2 as MarkdownBlock.ListItem
                assertEquals("$ctx bullet", blk1.bullet, l2.bullet)
                assertTrue("$ctx item text extends", l2.text.startsWith(blk1.text))
                assertRenderPrefix(ctx, blk1.text, l2.text)
            }
            is MarkdownBlock.Table -> {
                val t2 = blk2 as MarkdownBlock.Table
                assertEquals("$ctx table headers frozen", blk1.headers, t2.headers)
                assertTrue("$ctx table rows extend", t2.rows.size >= blk1.rows.size)
                for (r in blk1.rows.indices) {
                    assertEquals("$ctx table row#$r frozen", blk1.rows[r], t2.rows[r])
                }
            }
            is MarkdownBlock.CodeBlock -> {
                val c2 = blk2 as MarkdownBlock.CodeBlock
                assertEquals("$ctx code language", blk1.language, c2.language)
                assertTrue("$ctx code extends", c2.code.startsWith(blk1.code))
            }
            is MarkdownBlock.HorizontalRule -> assertEquals("$ctx hr", blk1, blk2)
            is MarkdownBlock.MathBlock -> assertEquals("$ctx math frozen", blk1, blk2)
        }
    }

    /** render(text1) must be a style-level prefix of render(text2): the string prefix matches, and every span/link intersecting it matches too. */
    private fun assertRenderPrefix(ctx: String, text1: String, text2: String) {
        if (text1 == text2) return
        val r1 = MarkdownRenderer.render(text1, colors)
        val r2 = MarkdownRenderer.render(text2, colors)
        val len1 = r1.length
        assertTrue(
            "$ctx rendered string must be prefix\n  r1=${r1.text}\n  r2=${r2.text}",
            r2.text.startsWith(r1.text),
        )
        val spans1 = r1.spanStyles.map { Triple(it.start, it.end, it.item) }.toSet()
        val spans2 = r2.spanStyles.filter { it.start < len1 }.map { Triple(it.start, it.end, it.item) }.toSet()
        assertEquals("$ctx spans intersecting prefix must be frozen\n  r1=${r1.text}\n  r2=${r2.text}", spans1, spans2)
        val links1 = linkRanges(r1, r1.length)
        val links2 = linkRanges(r2, len1)
        assertEquals("$ctx links intersecting prefix must be frozen", links1, links2)
    }

    private fun linkRanges(a: AnnotatedString, limit: Int): Set<Triple<Int, Int, String>> =
        a.getLinkAnnotations(0, a.length)
            .filter { it.start < limit }
            .map { Triple(it.start, it.end, (it.item as androidx.compose.ui.text.LinkAnnotation.Url).url) }
            .toSet()
}
