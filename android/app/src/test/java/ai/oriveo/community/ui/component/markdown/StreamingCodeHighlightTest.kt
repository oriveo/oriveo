package ai.oriveo.community.ui.component.markdown

import androidx.compose.ui.graphics.Color
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test


class StreamingCodeHighlightTest {

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
    fun `completed lines highlight equals final full highlight prefix`() {
        
        val code = "fun main() {\n    val x = \"hi\" // greet\n    println(x)\n}"
        val streaming = highlightStreamingCode(code, "kotlin", testColors)
        val final = SyntaxHighlighter.highlight(code, "kotlin", testColors)

        assertEquals(final.text, streaming.text)
        val stableLen = code.lastIndexOf('\n')
        assertEquals(
            final.spanStyles.filter { it.end <= stableLen },
            streaming.spanStyles.filter { it.end <= stableLen },
        )
    }

    @Test
    fun `partial last line stays plain until its newline arrives`() {
        val stable = "val done = 1"
        val streaming = highlightStreamingCode("$stable\nval typi", "kotlin", testColors)
        
        assertTrue(streaming.spanStyles.none { it.end > stable.length })
        
        assertTrue(streaming.spanStyles.any { it.start < stable.length })
    }

    @Test
    fun `single unfinished line renders plain`() {
        val streaming = highlightStreamingCode("val x", "kotlin", testColors)
        assertEquals("val x", streaming.text)
        assertTrue(streaming.spanStyles.isEmpty())
    }

    @Test
    fun `appending a new line never rewrites earlier spans`() {
        val firstLine = "const greeting = \"hello\"; // 42"
        val earlier = highlightStreamingCode("$firstLine\npartial", "javascript", testColors)
        val later = highlightStreamingCode("$firstLine\nlet n = 42;\npartial2", "javascript", testColors)
        assertEquals(
            earlier.spanStyles.filter { it.end <= firstLine.length },
            later.spanStyles.filter { it.end <= firstLine.length },
        )
    }

    @Test
    fun `empty and whitespace input passes through`() {
        assertEquals(" ", highlightStreamingCode(" ", "kotlin", testColors).text)
        assertEquals("", highlightStreamingCode("", "kotlin", testColors).text)
    }
}
