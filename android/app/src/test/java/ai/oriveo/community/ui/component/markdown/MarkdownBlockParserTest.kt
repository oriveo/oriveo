package ai.oriveo.community.ui.component.markdown

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MarkdownBlockParserTest {

    @Test
    fun `paragraph is detected`() {
        val blocks = parseBlocks("Hello world")
        assertEquals(1, blocks.size)
        assertTrue(blocks[0] is MarkdownBlock.Paragraph)
        assertEquals("Hello world", (blocks[0] as MarkdownBlock.Paragraph).text)
    }

    @Test
    fun `heading levels are detected`() {
        val blocks = parseBlocks("# H1\n## H2\n### H3")
        assertEquals(3, blocks.size)
        assertTrue(blocks[0] is MarkdownBlock.Heading)
        assertEquals(1, (blocks[0] as MarkdownBlock.Heading).level)
        assertEquals("H1", (blocks[0] as MarkdownBlock.Heading).text)
        assertEquals(2, (blocks[1] as MarkdownBlock.Heading).level)
        assertEquals(3, (blocks[2] as MarkdownBlock.Heading).level)
    }

    @Test
    fun `heading levels 4 to 6 detected (matches iOS)`() {
        // The old version only supported #/##/### -- `####` and beyond would render as a literal
        // paragraph, so the markdown showed up as `#### text`. This locks down that H4/H5/H6
        // must be recognized as Heading blocks.
        val blocks = parseBlocks("#### H4\n##### H5\n###### H6")
        assertEquals(3, blocks.size)
        assertTrue(blocks[0] is MarkdownBlock.Heading)
        assertEquals(4, (blocks[0] as MarkdownBlock.Heading).level)
        assertEquals("H4", (blocks[0] as MarkdownBlock.Heading).text)
        assertEquals(5, (blocks[1] as MarkdownBlock.Heading).level)
        assertEquals("H5", (blocks[1] as MarkdownBlock.Heading).text)
        assertEquals(6, (blocks[2] as MarkdownBlock.Heading).level)
        assertEquals("H6", (blocks[2] as MarkdownBlock.Heading).text)
    }

    @Test
    fun `heading with 7+ hashes is not heading`() {
        // CommonMark caps headings at level 6; 7+ hashes should render as a paragraph
        val blocks = parseBlocks("####### too deep")
        assertEquals(1, blocks.size)
        assertTrue(blocks[0] is MarkdownBlock.Paragraph)
    }

    @Test
    fun `indented headings are detected`() {
        val blocks = parseBlocks("  ## H2\n    ### H3")

        assertEquals(2, blocks.size)
        assertTrue(blocks[0] is MarkdownBlock.Heading)
        assertEquals(2, (blocks[0] as MarkdownBlock.Heading).level)
        assertEquals("H2", (blocks[0] as MarkdownBlock.Heading).text)
        assertEquals(3, (blocks[1] as MarkdownBlock.Heading).level)
        assertEquals("H3", (blocks[1] as MarkdownBlock.Heading).text)
    }

    @Test
    fun `code block is parsed`() {
        val text = "```kotlin\nval x = 1\n```"
        val blocks = parseBlocks(text)
        assertEquals(1, blocks.size)
        assertTrue(blocks[0] is MarkdownBlock.CodeBlock)
        val cb = blocks[0] as MarkdownBlock.CodeBlock
        assertEquals("kotlin", cb.language)
        assertEquals("val x = 1", cb.code)
    }

    @Test
    fun `code block without language`() {
        val text = "```\nsome code\n```"
        val blocks = parseBlocks(text)
        assertEquals(1, blocks.size)
        val cb = blocks[0] as MarkdownBlock.CodeBlock
        assertEquals("", cb.language)
        assertEquals("some code", cb.code)
    }

    @Test
    fun `indented code block is parsed`() {
        val text = "   ```kotlin\nval x = 1\n   ```"
        val blocks = parseBlocks(text)
        assertEquals(1, blocks.size)
        val cb = blocks[0] as MarkdownBlock.CodeBlock
        assertEquals("kotlin", cb.language)
        assertEquals("val x = 1", cb.code)
    }

    @Test
    fun `block quote is parsed`() {
        val blocks = parseBlocks("> This is a quote")
        assertEquals(1, blocks.size)
        assertTrue(blocks[0] is MarkdownBlock.BlockQuote)
        assertEquals("This is a quote", (blocks[0] as MarkdownBlock.BlockQuote).text)
    }

    @Test
    fun `multi-line block quote`() {
        val blocks = parseBlocks("> line 1\n> line 2")
        assertEquals(1, blocks.size)
        assertTrue(blocks[0] is MarkdownBlock.BlockQuote)
        assertEquals("line 1\nline 2", (blocks[0] as MarkdownBlock.BlockQuote).text)
    }

    @Test
    fun `unordered list items are detected`() {
        val blocks = parseBlocks("- item 1\n- item 2")
        assertEquals(2, blocks.size)
        assertTrue(blocks[0] is MarkdownBlock.ListItem)
        assertEquals("item 1", (blocks[0] as MarkdownBlock.ListItem).text)
        assertEquals("•", (blocks[0] as MarkdownBlock.ListItem).bullet)
    }

    @Test
    fun `indented unordered list items are detected`() {
        val blocks = parseBlocks("  + item 1\n    * item 2")
        assertEquals(2, blocks.size)
        assertEquals("item 1", (blocks[0] as MarkdownBlock.ListItem).text)
        assertEquals("item 2", (blocks[1] as MarkdownBlock.ListItem).text)
    }

    @Test
    fun `ordered list items are detected`() {
        val blocks = parseBlocks("1. first\n2. second")
        assertEquals(2, blocks.size)
        assertTrue(blocks[0] is MarkdownBlock.ListItem)
        assertEquals("first", (blocks[0] as MarkdownBlock.ListItem).text)
        assertEquals("1.", (blocks[0] as MarkdownBlock.ListItem).bullet)
    }

    @Test
    fun `indented ordered list items are detected`() {
        val blocks = parseBlocks("  12. first\n   99. second")
        assertEquals(2, blocks.size)
        assertEquals("12.", (blocks[0] as MarkdownBlock.ListItem).bullet)
        assertEquals("first", (blocks[0] as MarkdownBlock.ListItem).text)
        assertEquals("99.", (blocks[1] as MarkdownBlock.ListItem).bullet)
    }

    @Test
    fun `horizontal rule is detected`() {
        val blocks = parseBlocks("---")
        assertEquals(1, blocks.size)
        assertTrue(blocks[0] is MarkdownBlock.HorizontalRule)
    }

    @Test
    fun `horizontal rule with asterisks`() {
        val blocks = parseBlocks("***")
        assertEquals(1, blocks.size)
        assertTrue(blocks[0] is MarkdownBlock.HorizontalRule)
    }

    @Test
    fun `table is parsed`() {
        val text = "| A | B |\n| --- | --- |\n| 1 | 2 |"
        val blocks = parseBlocks(text)
        assertEquals(1, blocks.size)
        assertTrue(blocks[0] is MarkdownBlock.Table)
        val table = blocks[0] as MarkdownBlock.Table
        assertEquals(2, table.headers.size)
        assertEquals(1, table.rows.size)
    }

    @Test
    fun `indented table is parsed`() {
        val text = "  | A | B |\n  | --- | --- |\n  | 1 | 2 |"
        val blocks = parseBlocks(text)
        assertEquals(1, blocks.size)
        assertTrue(blocks[0] is MarkdownBlock.Table)
        val table = blocks[0] as MarkdownBlock.Table
        assertEquals(2, table.headers.size)
        assertEquals(1, table.rows.size)
    }

    @Test
    fun `table with multiple rows`() {
        val text = "| Name | Age | City |\n| --- | --- | --- |\n| Alice | 30 | NYC |\n| Bob | 25 | LA |"
        val blocks = parseBlocks(text)
        assertEquals(1, blocks.size)
        val table = blocks[0] as MarkdownBlock.Table
        assertEquals(3, table.headers.size)
        assertEquals(2, table.rows.size)
        assertEquals(3, table.rows[0].size)
        assertEquals(3, table.rows[1].size)
    }

    @Test
    fun `table row with fewer columns than header`() {
        val text = "| A | B | C |\n| --- | --- | --- |\n| 1 |"
        val blocks = parseBlocks(text)
        assertEquals(1, blocks.size)
        val table = blocks[0] as MarkdownBlock.Table
        assertEquals(3, table.headers.size)
        assertEquals(1, table.rows.size)
        // The row has just 1 column; the UI layer pads it out with getOrElse
        assertTrue(table.rows[0].size < table.headers.size)
    }

    @Test
    fun `table header cells are trimmed by split`() {
        val text = "| **Name** | Value |\n| --- | --- |\n| key | 42 |"
        val blocks = parseBlocks(text)
        val table = blocks[0] as MarkdownBlock.Table
        assertTrue(table.headers[0].contains("Name"))
        assertTrue(table.headers[1].contains("Value"))
    }

    // -- tightened GFM table detection (same semantics as splitTrailingTable / the streaming table card, a monotonic dependency of the block-commit prefix) --

    @Test
    fun `pipe lines without separator parse as literal paragraph`() {
        // Old behavior: any 2+ pipe lines formed a table and the 2nd line was silently dropped -> a jarring handoff plus dropped text between streaming (literal) and settled (table) rendering
        val blocks = parseBlocks("| a |\n| b |\n| c |")
        assertEquals(1, blocks.size)
        val para = blocks[0] as MarkdownBlock.Paragraph
        assertEquals("| a |\n| b |\n| c |", para.text)
    }

    @Test
    fun `single pipe line parses as paragraph not dropped`() {
        // Old behavior: when size>=2 wasn't met, nothing was emitted at all, so a lone pipe line just vanished
        val blocks = parseBlocks("| just | pipes |")
        assertEquals(1, blocks.size)
        assertEquals("| just | pipes |", (blocks[0] as MarkdownBlock.Paragraph).text)
    }

    @Test
    fun `pipe lines before header separator pair split into paragraph and table`() {
        // GFM: a table is a separator immediately below its header; any earlier pipe line is plain text
        val blocks = parseBlocks("| a |\n| H1 | H2 |\n| --- | --- |\n| r1 | r2 |")
        assertEquals(2, blocks.size)
        assertEquals("| a |", (blocks[0] as MarkdownBlock.Paragraph).text)
        val table = blocks[1] as MarkdownBlock.Table
        assertEquals(listOf(" H1 ", " H2 "), table.headers)
        assertEquals(1, table.rows.size)
    }

    @Test
    fun `mixed content is parsed correctly`() {
        val text = """
# Title

Some paragraph text.

```python
print("hello")
```

- item 1
- item 2

> A quote
        """.trimIndent()

        val blocks = parseBlocks(text)
        assertTrue(blocks.size >= 5)
        assertTrue(blocks[0] is MarkdownBlock.Heading)
        assertTrue(blocks.any { it is MarkdownBlock.Paragraph })
        assertTrue(blocks.any { it is MarkdownBlock.CodeBlock })
        assertTrue(blocks.any { it is MarkdownBlock.ListItem })
        assertTrue(blocks.any { it is MarkdownBlock.BlockQuote })
    }

    @Test
    fun `empty string produces no blocks`() {
        val blocks = parseBlocks("")
        assertEquals(0, blocks.size)
    }

    @Test
    fun `whitespace only produces no blocks`() {
        val blocks = parseBlocks("   \n\n   ")
        assertEquals(0, blocks.size)
    }
}
