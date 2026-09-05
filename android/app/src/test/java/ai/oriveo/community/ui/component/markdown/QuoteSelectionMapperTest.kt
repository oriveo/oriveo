package ai.oriveo.community.ui.component.markdown

import ai.oriveo.community.core.model.QuoteContentKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class QuoteSelectionMapperTest {
    @Test
    fun `prose selection includes adjacent nonempty semantic blocks`() {
        val result = QuoteSelectionMapper.capture("First.\n\nMiddle **target** end.\n\nLast.", "target")
        assertEquals(QuoteContentKind.Prose, result.contentKind)
        assertTrue(result.leadingText.startsWith("First."))
        assertTrue(result.leadingText.endsWith("Middle "))
        assertEquals("target", result.selectedText)
        assertTrue(result.trailingText.endsWith("Last."))
    }

    @Test
    fun `code selection expands to complete code block`() {
        val result = QuoteSelectionMapper.capture("before\n\n```kotlin\nval a = 1\nval b = 2\n```\n\nafter", "a = 1")
        assertEquals(QuoteContentKind.Code, result.contentKind)
        assertEquals("val ", result.leadingText)
        assertEquals("\nval b = 2", result.trailingText)
    }

    @Test
    fun `table selection expands only current row`() {
        val result = QuoteSelectionMapper.capture(
            "| Name | Value |\n| --- | --- |\n| Alpha | 1 |\n| Beta | 2 |",
            "Beta",
        )
        assertEquals(QuoteContentKind.Table, result.contentKind)
        assertEquals("", result.leadingText)
        assertEquals(" | 2", result.trailingText)
    }

    @Test
    fun `ambiguous repeated selection falls back without guessed context`() {
        val result = QuoteSelectionMapper.capture("same\n\nsame", "same")
        assertEquals("", result.leadingText)
        assertEquals("same", result.selectedText)
        assertEquals("", result.trailingText)
    }

    @Test
    fun `formula keeps raw delimiters in context`() {
        val result = QuoteSelectionMapper.capture("\$\$x + y\$\$", "\$\$x + y\$\$")
        assertEquals("\$\$x + y\$\$", result.selectedText)
    }
}
