package ai.oriveo.community.ui.component.markdown

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Verifies how parseBlocks recognizes block-level `$$...$$` and its boundaries.
 * Streaming splitClosedAndOpenLatex is covered by LatexNormalizerTest; this file focuses on
 * the block parser.
 */
class MathBlockParserTest {

    @Test
    fun `single line dollar-dollar is recognized as MathBlock`() {
        val blocks = parseBlocks("\$\$x^2 + 1\$\$")
        assertEquals(1, blocks.size)
        assertTrue(blocks[0] is MarkdownBlock.MathBlock)
        assertEquals("x^2 + 1", (blocks[0] as MarkdownBlock.MathBlock).latex)
    }

    @Test
    fun `multiline dollar-dollar is recognized as MathBlock`() {
        val text = "\$\$\nx^2 +\ny^2\n\$\$"
        val blocks = parseBlocks(text)
        assertEquals(1, blocks.size)
        assertTrue(blocks[0] is MarkdownBlock.MathBlock)
        assertEquals("x^2 +\ny^2", (blocks[0] as MarkdownBlock.MathBlock).latex)
    }

    @Test
    fun `multiline block formula with content on the first line`() {
        val text = "\$\$ \\sum_{i=0}^n\n  i\n\$\$"
        val blocks = parseBlocks(text)
        assertEquals(1, blocks.size)
        val math = blocks[0] as MarkdownBlock.MathBlock
        assertEquals("\\sum_{i=0}^n\n  i", math.latex)
    }

    @Test
    fun `paragraphs before and after a block formula are split correctly`() {
        val text = "leading paragraph\n\n\$\$x^2\$\$\n\ntrailing paragraph"
        val blocks = parseBlocks(text)
        assertEquals(3, blocks.size)
        assertTrue(blocks[0] is MarkdownBlock.Paragraph)
        assertEquals("leading paragraph", (blocks[0] as MarkdownBlock.Paragraph).text)
        assertTrue(blocks[1] is MarkdownBlock.MathBlock)
        assertEquals("x^2", (blocks[1] as MarkdownBlock.MathBlock).latex)
        assertTrue(blocks[2] is MarkdownBlock.Paragraph)
        assertEquals("trailing paragraph", (blocks[2] as MarkdownBlock.Paragraph).text)
    }

    @Test
    fun `unclosed block formula falls back to a paragraph instead of swallowing what follows`() {
        val text = "\$\$open\n\nnext paragraph"
        val blocks = parseBlocks(text)
        // should not throw, should not drop content
        assertTrue(blocks.isNotEmpty())
        // "next paragraph" should still be visible somewhere
        val joined = blocks.joinToString("|") { b ->
            when (b) {
                is MarkdownBlock.Paragraph -> b.text
                is MarkdownBlock.MathBlock -> "MATH(${b.latex})"
                else -> b::class.simpleName ?: "?"
            }
        }
        assertTrue("parse result should retain 'next paragraph': $joined", joined.contains("next paragraph"))
    }

    @Test
    fun `a paragraph containing an inline dollar is not recognized as block level`() {
        val text = "paragraph with \$x\$ inline formula"
        val blocks = parseBlocks(text)
        assertEquals(1, blocks.size)
        assertTrue(blocks[0] is MarkdownBlock.Paragraph)
    }

    @Test
    fun `dollar-dollar inside a code block is not recognized as a block formula`() {
        val text = "```\n\$\$x\$\$\n```"
        val blocks = parseBlocks(text)
        assertEquals(1, blocks.size)
        assertTrue(blocks[0] is MarkdownBlock.CodeBlock)
    }

    @Test
    fun `two consecutive block formulas are recognized separately`() {
        val text = "\$\$a\$\$\n\$\$b\$\$"
        val blocks = parseBlocks(text)
        assertEquals(2, blocks.size)
        assertTrue(blocks.all { it is MarkdownBlock.MathBlock })
        assertEquals("a", (blocks[0] as MarkdownBlock.MathBlock).latex)
        assertEquals("b", (blocks[1] as MarkdownBlock.MathBlock).latex)
    }
}
