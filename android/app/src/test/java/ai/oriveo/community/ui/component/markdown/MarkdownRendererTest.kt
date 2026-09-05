package ai.oriveo.community.ui.component.markdown

import androidx.compose.ui.graphics.Color
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MarkdownRendererTest {

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
    fun `plain text renders unchanged`() {
        val result = MarkdownRenderer.render("Hello world", testColors)
        assertEquals("Hello world", result.text)
    }

    @Test
    fun `bold text is rendered`() {
        val result = MarkdownRenderer.render("**bold**", testColors)
        assertEquals("bold", result.text)
        assertTrue(result.spanStyles.any { it.item.fontWeight != null })
    }

    @Test
    fun `italic text is rendered`() {
        val result = MarkdownRenderer.render("*italic*", testColors)
        assertEquals("italic", result.text)
    }

    @Test
    fun `strikethrough is rendered`() {
        val result = MarkdownRenderer.render("~~deleted~~", testColors)
        assertEquals("deleted", result.text)
    }

    @Test
    fun `inline code is rendered`() {
        val result = MarkdownRenderer.render("`code`", testColors)
        assertTrue(result.text.contains("code"))
    }

    @Test
    fun `link is rendered with LinkAnnotation`() {
        val result = MarkdownRenderer.render("[click](https://example.com)", testColors)
        assertEquals("click", result.text)
        val links = result.getLinkAnnotations(0, result.length)
        assertEquals(1, links.size)
        val url = links[0].item as androidx.compose.ui.text.LinkAnnotation.Url
        assertEquals("https://example.com", url.url)
    }

    @Test
    fun `untrusted link schemes remain plain text`() {
        val result = MarkdownRenderer.render(
            "[safe](https://example.com) [plain](http://example.com) [intent](intent://settings) [script](javascript:alert)",
            testColors,
        )

        val links = result.getLinkAnnotations(0, result.length)
        assertEquals(1, links.size)
        assertEquals("https://example.com", (links.single().item as androidx.compose.ui.text.LinkAnnotation.Url).url)
        assertEquals("safe plain intent script", result.text)
    }

    @Test
    fun `raw HTML is inert text`() {
        val result = MarkdownRenderer.render("<script>alert('x')</script>", testColors)

        assertEquals("<script>alert('x')</script>", result.text)
        assertTrue(result.getLinkAnnotations(0, result.length).isEmpty())
    }

    @Test
    fun `mixed formatting is rendered`() {
        val result = MarkdownRenderer.render("Hello **bold** and *italic*", testColors)
        assertEquals("Hello bold and italic", result.text)
    }

    @Test
    fun `table cell markdown is rendered`() {
        val result = MarkdownRenderer.render(" **Scenario** ".trim(), testColors)
        assertEquals("Scenario", result.text)
        assertTrue(result.spanStyles.any { span -> span.item.fontWeight != null })
    }

    @Test
    fun `unclosed bold does not crash`() {
        val result = MarkdownRenderer.render("**unclosed", testColors)
        assertTrue(result.text.contains("*"))
    }

    @Test
    fun `empty string renders empty`() {
        val result = MarkdownRenderer.render("", testColors)
        assertEquals("", result.text)
    }

    // ── Line scoping (an unclosed span at end of line stays literal forever; a closer on a later line must never rewrite the previous line) ──

    @Test
    fun `bold does not close across newline`() {
        val result = MarkdownRenderer.render("**a\nb**", testColors)
        assertEquals("**a\nb**", result.text)
        assertTrue(result.spanStyles.none { it.item.fontWeight != null })
    }

    @Test
    fun `inline code does not close across newline`() {
        val result = MarkdownRenderer.render("`a\nb`", testColors)
        assertEquals("`a\nb`", result.text)
    }

    @Test
    fun `strikethrough does not close across newline`() {
        val result = MarkdownRenderer.render("~~a\nb~~", testColors)
        assertEquals("~~a\nb~~", result.text)
    }

    @Test
    fun `link does not close across newline`() {
        val crossText = MarkdownRenderer.render("[a\nb](u)", testColors)
        assertEquals("[a\nb](u)", crossText.text)
        assertTrue(crossText.getLinkAnnotations(0, crossText.length).isEmpty())

        val crossUrl = MarkdownRenderer.render("[a](u\nv)", testColors)
        assertEquals("[a](u\nv)", crossUrl.text)
        assertTrue(crossUrl.getLinkAnnotations(0, crossUrl.length).isEmpty())
    }

    @Test
    fun `closed spans on second line still render`() {
        // Line scoping only forbids closing across a newline; it doesn't affect normal closing within a later line.
        val result = MarkdownRenderer.render("**a\n**b** c", testColors)
        assertEquals("**a\nb c", result.text)
        assertTrue(result.spanStyles.any { it.item.fontWeight != null })
    }

    @Test
    fun `render of line prefix is stable under extension`() {
        // Prefix monotonicity: an already-rendered prefix must not change once later lines are appended (neither its string nor its styling).
        val p1 = MarkdownRenderer.render("**a", testColors)
        val p2 = MarkdownRenderer.render("**a\nrest **bold**", testColors)
        assertEquals(p1.text, p2.text.substring(0, p1.text.length))
        assertTrue(p1.spanStyles.isEmpty())
    }
}

class SyntaxHighlighterTest {

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
    fun `keywords are highlighted`() {
        val result = SyntaxHighlighter.highlight("val x = 1", "kotlin", testColors)
        assertEquals("val x = 1", result.text)
        assertTrue(result.spanStyles.isNotEmpty())
    }

    @Test
    fun `comments are highlighted`() {
        val result = SyntaxHighlighter.highlight("// comment", "kotlin", testColors)
        assertEquals("// comment", result.text)
        assertTrue(result.spanStyles.isNotEmpty())
    }

    @Test
    fun `inline comments are protected from identifier highlighting`() {
        val code = "val count = 1 // keep count unchanged"
        val result = SyntaxHighlighter.highlight(code, "kotlin", testColors)
        val commentStart = code.indexOf("//")

        assertEquals(code, result.text)
        assertTrue(
            result.spanStyles.any { span ->
                span.start == commentStart &&
                    span.end == code.length &&
                    span.item.color == testColors.syntaxComment
            },
        )
        assertTrue(
            result.spanStyles.none { span ->
                span.start >= commentStart && span.item.color == testColors.syntaxVariable
            },
        )
    }

    @Test
    fun `python hash comments are highlighted`() {
        val result = SyntaxHighlighter.highlight("# comment", "python", testColors)
        assertEquals("# comment", result.text)
        assertTrue(result.spanStyles.isNotEmpty())
    }

    @Test
    fun `strings are highlighted`() {
        val result = SyntaxHighlighter.highlight("val s = \"hello\"", "kotlin", testColors)
        assertEquals("val s = \"hello\"", result.text)
        assertTrue(result.spanStyles.isNotEmpty())
    }

    @Test
    fun `php variables are highlighted`() {
        val code = "$" + "arr[$" + "i] = $" + "temp"
        val result = SyntaxHighlighter.highlight(code, "php", testColors)

        assertEquals(code, result.text)
        for (variable in listOf("$" + "arr", "$" + "i", "$" + "temp")) {
            val start = code.indexOf(variable)
            val end = start + variable.length
            assertTrue(
                result.spanStyles.any { span ->
                    span.start == start && span.end == end && span.item.color == testColors.syntaxVariable
                },
            )
        }
    }

    @Test
    fun `common language identifiers are highlighted`() {
        val code = "fun updateUser(userName: String) { val score = userName.count }"
        val result = SyntaxHighlighter.highlight(code, "kotlin", testColors)

        assertEquals(code, result.text)
        for (identifier in listOf("updateUser", "userName", "score", "count")) {
            val start = code.indexOf(identifier)
            val end = start + identifier.length
            assertTrue(
                result.spanStyles.any { span ->
                    span.start <= start && span.end >= end && span.item.color == testColors.syntaxVariable
                },
            )
        }

        val keywordStart = code.indexOf("fun")
        assertTrue(
            result.spanStyles.any { span ->
                span.start == keywordStart &&
                    span.end == keywordStart + "fun".length &&
                    span.item.color == testColors.syntaxKeyword
            },
        )

        val typeStart = code.indexOf("String")
        assertTrue(
            result.spanStyles.any { span ->
                span.start == typeStart &&
                    span.end == typeStart + "String".length &&
                    span.item.color == testColors.syntaxType
            },
        )
    }

    @Test
    fun `empty code produces empty result`() {
        val result = SyntaxHighlighter.highlight("", "kotlin", testColors)
        assertEquals("", result.text)
    }

    @Test
    fun `multiline code is preserved`() {
        val code = "line1\nline2\nline3"
        val result = SyntaxHighlighter.highlight(code, "kotlin", testColors)
        assertEquals(code, result.text)
    }
}
