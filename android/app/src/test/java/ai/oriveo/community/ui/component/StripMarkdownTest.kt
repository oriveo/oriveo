package ai.oriveo.community.ui.component

import org.junit.Assert.assertEquals
import org.junit.Test

class StripMarkdownTest {

    @Test
    fun `bold text is stripped`() {
        assertEquals("hello world", stripMarkdown("**hello world**"))
    }

    @Test
    fun `italic text is stripped`() {
        assertEquals("hello", stripMarkdown("*hello*"))
    }

    @Test
    fun `underline bold is stripped`() {
        assertEquals("hello", stripMarkdown("__hello__"))
    }

    @Test
    fun `strikethrough is stripped`() {
        assertEquals("deleted", stripMarkdown("~~deleted~~"))
    }

    @Test
    fun `inline code is stripped`() {
        assertEquals("some code", stripMarkdown("`some code`"))
    }

    @Test
    fun `code block is replaced with placeholder`() {
        assertEquals("", stripMarkdown("```kotlin\nval x = 1\n```"))
    }

    @Test
    fun `heading prefix is stripped`() {
        assertEquals("Title", stripMarkdown("## Title"))
    }

    @Test
    fun `link is replaced with text`() {
        assertEquals("click here", stripMarkdown("[click here](https://example.com)"))
    }

    @Test
    fun `image link is replaced with alt text`() {
        assertEquals("photo", stripMarkdown("![photo](https://example.com/img.png)"))
    }

    @Test
    fun `block quote prefix is stripped`() {
        assertEquals("quoted text", stripMarkdown("> quoted text"))
    }

    @Test
    fun `plain text is unchanged`() {
        assertEquals("hello world", stripMarkdown("hello world"))
    }

    @Test
    fun `empty string is unchanged`() {
        assertEquals("", stripMarkdown(""))
    }

    @Test
    fun `multiple paragraphs are joined`() {
        val input = "first\n\nsecond"
        val result = stripMarkdown(input)
        assertEquals("first second", result)
    }

    @Test
    fun `complex mixed markdown is stripped`() {
        val input = "**bold** and *italic* with `code` and [link](url)"
        val result = stripMarkdown(input)
        assertEquals("bold and italic with code and link", result)
    }
}
