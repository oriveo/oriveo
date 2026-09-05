package ai.oriveo.community.ui.component.markdown

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MarkdownPerformanceHeuristicsTest {

    @Test
    fun `plain text skips rich inline markdown rendering`() {
        assertFalse(shouldRenderRichInlineMarkdown("Bench 12"))
        assertFalse(shouldRenderRichInlineMarkdown("  42 ms  ", trim = true))
    }

    @Test
    fun `rich inline markdown is preserved when syntax is present`() {
        assertTrue(shouldRenderRichInlineMarkdown("Use `trace_marker` here"))
        assertTrue(shouldRenderRichInlineMarkdown("**important**"))
        assertTrue(shouldRenderRichInlineMarkdown("[docs](https://example.com)"))
    }

    @Test
    fun `prewarm stays enabled for short markdown`() {
        val text = """
            ## Summary

            Keep the benchmark path deterministic.
            - Measure on device
            - Compare before and after
        """.trimIndent()

        assertTrue(shouldPrewarmMarkdown(text))
    }

    @Test
    fun `prewarm skips oversized tables and code payloads`() {
        val largeTable = buildString {
            appendLine("| A | B |")
            appendLine("| --- | --- |")
            repeat(20) { row ->
                appendLine("| row-$row | value-$row |")
            }
        }
        val largeCode = buildString {
            appendLine("```kotlin")
            repeat(120) { line ->
                appendLine("val metric$line = $line")
            }
            appendLine("```")
        }

        assertFalse(shouldPrewarmMarkdown(largeTable))
        assertFalse(shouldPrewarmMarkdown(largeCode))
    }
}
