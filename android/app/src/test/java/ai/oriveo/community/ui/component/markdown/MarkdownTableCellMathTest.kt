package ai.oriveo.community.ui.component.markdown

import androidx.compose.ui.graphics.Color
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MarkdownTableCellMathTest {

    private val testColors = MarkdownColors(
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

    @Test
    fun `table parser keeps inline latex in cells`() {
        val tableMd = "| formula | mnemonic |\n| --- | --- |\n| \$\\log_a(MN) = \\log_a M + \\log_a N$ | たしざんにかえる |"
        val table = parseBlocks(tableMd).filterIsInstance<MarkdownBlock.Table>().single()
        assertEquals(1, table.rows.size)
        val cell = table.rows[0][0].trim()
        val result = renderInlineMarkdownWithMath(cell, testColors)
        assertEquals(1, result.mathSpans.size)
        assertEquals("\\log_a(MN) = \\log_a M + \\log_a N", result.mathSpans[0].latex)
    }

    @Test
    fun `mixed cjk text and latex in a table cell keeps both`() {
        val cell = "とてもべんり, とくに \$\\frac{1}{\\log_a b}\$"
        val result = renderInlineMarkdownWithMath(cell, testColors)
        assertEquals(1, result.mathSpans.size)
        assertEquals("\\frac{1}{\\log_a b}", result.mathSpans[0].latex)
        assertTrue(result.annotated.text.contains("とてもべんり"))
    }

    @Test
    fun `plain table cell has no math spans`() {
        val result = renderInlineMarkdownWithMath("たしざんにかえる", testColors)
        assertTrue(result.mathSpans.isEmpty())
        assertEquals("たしざんにかえる", result.annotated.text)
    }
}
