package ai.oriveo.community.ui.component.markdown

import androidx.compose.ui.unit.dp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test


class MarkdownBlockSpacingTest {

    @Test
    fun `consecutive blocks have no gap when no blank lines between`() {
        val entries = parseBlocksWithGaps("- a\n- b\n- c")
        assertEquals(3, entries.size)
        
        assertEquals(0, entries[0].gapBefore)
        assertEquals(0, entries[1].gapBefore)
        assertEquals(0, entries[2].gapBefore)
    }

    @Test
    fun `single blank line between blocks captured as gap=1`() {
        val entries = parseBlocksWithGaps("Para A\n\nPara B")
        assertEquals(2, entries.size)
        assertEquals(0, entries[0].gapBefore)
        assertEquals(1, entries[1].gapBefore)
    }

    @Test
    fun `multiple blank lines accumulate`() {
        val entries = parseBlocksWithGaps("Para A\n\n\n\nPara B")
        assertEquals(2, entries.size)
        assertEquals(3, entries[1].gapBefore)
    }

    @Test
    fun `blank lines between list items captured`() {
        val entries = parseBlocksWithGaps("- a\n\n- b")
        assertEquals(2, entries.size)
        assertTrue(entries[0].block is MarkdownBlock.ListItem)
        assertTrue(entries[1].block is MarkdownBlock.ListItem)
        assertEquals(1, entries[1].gapBefore)
    }

    @Test
    fun `heading gets large gap before regardless of blank lines`() {
        val gap = spacerHeightBetween(
            prev = MarkdownBlock.Paragraph("text"),
            curr = MarkdownBlock.Heading("Title", level = 2),
            blankLinesBetween = 0,
        )
        assertEquals(20.dp, gap)
    }

    @Test
    fun `content right after heading is tight`() {
        val gap = spacerHeightBetween(
            prev = MarkdownBlock.Heading("Title", level = 2),
            curr = MarkdownBlock.Paragraph("body"),
            blankLinesBetween = 1,
        )
        assertEquals(6.dp, gap)
    }

    @Test
    fun `tight list items between same list use 4dp`() {
        val gap = spacerHeightBetween(
            prev = MarkdownBlock.ListItem("a", "•"),
            curr = MarkdownBlock.ListItem("b", "•"),
            blankLinesBetween = 0,
        )
        assertEquals(4.dp, gap)
    }

    @Test
    fun `loose list items separated by blank lines use 10dp`() {
        val gap = spacerHeightBetween(
            prev = MarkdownBlock.ListItem("a", "•"),
            curr = MarkdownBlock.ListItem("b", "•"),
            blankLinesBetween = 1,
        )
        assertEquals(10.dp, gap)
    }

    @Test
    fun `paragraphs with blank line between use 16dp`() {
        val gap = spacerHeightBetween(
            prev = MarkdownBlock.Paragraph("a"),
            curr = MarkdownBlock.Paragraph("b"),
            blankLinesBetween = 1,
        )
        assertEquals(16.dp, gap)
    }

    @Test
    fun `paragraphs without blank line use tight 8dp`() {
        val gap = spacerHeightBetween(
            prev = MarkdownBlock.Paragraph("a"),
            curr = MarkdownBlock.Paragraph("b"),
            blankLinesBetween = 0,
        )
        assertEquals(8.dp, gap)
    }

    @Test
    fun `code block boundary uses fixed 12dp`() {
        val before = spacerHeightBetween(
            prev = MarkdownBlock.Paragraph("intro"),
            curr = MarkdownBlock.CodeBlock("x", "kotlin"),
            blankLinesBetween = 1,
        )
        val after = spacerHeightBetween(
            prev = MarkdownBlock.CodeBlock("x", "kotlin"),
            curr = MarkdownBlock.Paragraph("outro"),
            blankLinesBetween = 1,
        )
        assertEquals(12.dp, before)
        assertEquals(12.dp, after)
    }

    @Test
    fun `table boundary uses fixed 12dp`() {
        val gap = spacerHeightBetween(
            prev = MarkdownBlock.Paragraph("intro"),
            curr = MarkdownBlock.Table(headers = listOf("A"), rows = emptyList()),
            blankLinesBetween = 1,
        )
        assertEquals(12.dp, gap)
    }

    @Test
    fun `block quote boundary uses fixed 12dp`() {
        val gap = spacerHeightBetween(
            prev = MarkdownBlock.Paragraph("intro"),
            curr = MarkdownBlock.BlockQuote("hello"),
            blankLinesBetween = 0,
        )
        assertEquals(12.dp, gap)
    }

    @Test
    fun `horizontal rule boundary uses fixed 12dp`() {
        val gap = spacerHeightBetween(
            prev = MarkdownBlock.Paragraph("a"),
            curr = MarkdownBlock.HorizontalRule,
            blankLinesBetween = 0,
        )
        assertEquals(12.dp, gap)
    }

    @Test
    fun `cross-type paragraph to list with blank line is 16dp`() {
        val gap = spacerHeightBetween(
            prev = MarkdownBlock.Paragraph("intro"),
            curr = MarkdownBlock.ListItem("first", "•"),
            blankLinesBetween = 1,
        )
        assertEquals(16.dp, gap)
    }

    @Test
    fun `mixed document captures gaps end-to-end`() {
        val text = """
# Title

Para A

- item 1
- item 2

Para B
        """.trimIndent()
        val entries = parseBlocksWithGaps(text)

        // Heading, Paragraph, ListItem, ListItem, Paragraph
        assertEquals(5, entries.size)
        assertTrue(entries[0].block is MarkdownBlock.Heading)
        assertTrue(entries[1].block is MarkdownBlock.Paragraph)
        assertTrue(entries[2].block is MarkdownBlock.ListItem)
        assertTrue(entries[3].block is MarkdownBlock.ListItem)
        assertTrue(entries[4].block is MarkdownBlock.Paragraph)

        
        assertEquals(1, entries[1].gapBefore)
        
        assertEquals(1, entries[2].gapBefore)
        
        assertEquals(0, entries[3].gapBefore)
        
        assertEquals(1, entries[4].gapBefore)
    }

    @Test
    fun `parseBlocks compatibility wrapper still produces plain blocks`() {
        
        val blocks: List<MarkdownBlock> = parseBlocks("Hello\n\nWorld")
        assertEquals(2, blocks.size)
        assertNotNull(blocks[0])
    }

    

    @Test
    fun `seam between committed code block and streaming code fence is 12dp`() {
        
        val gap = streamingSeamSpacing(
            committed = "```kotlin\nval x = 1\n```\n",
            tail = "```python\nprint(1)",
            tailKind = StreamingSplitter.TailKind.UnclosedCodeFence,
            tailIsTable = false,
        )
        assertEquals(12.dp, gap)
    }

    @Test
    fun `seam between paragraphs with blank line is 16dp`() {
        val gap = streamingSeamSpacing(
            committed = "Para A\n\n",
            tail = "Para B",
            tailKind = StreamingSplitter.TailKind.Paragraph,
            tailIsTable = false,
        )
        assertEquals(16.dp, gap)
    }

    @Test
    fun `seam before streaming table is 12dp`() {
        val gap = streamingSeamSpacing(
            committed = "Intro paragraph.\n\n",
            tail = "| H1 | H2 |\n| --- | --- |",
            tailKind = StreamingSplitter.TailKind.UnclosedTable,
            tailIsTable = true,
        )
        assertEquals(12.dp, gap)
    }

    @Test
    fun `seam is zero when committed empty`() {
        val gap = streamingSeamSpacing(
            committed = "",
            tail = "anything",
            tailKind = StreamingSplitter.TailKind.Paragraph,
            tailIsTable = false,
        )
        assertEquals(0.dp, gap)
    }
}
