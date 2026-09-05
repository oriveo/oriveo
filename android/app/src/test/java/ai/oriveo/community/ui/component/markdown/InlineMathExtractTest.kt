package ai.oriveo.community.ui.component.markdown

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class InlineMathExtractTest {

    @Test
    fun `detects a basic inline formula`() {
        val spans = extractInlineMath("note \$x + y\$ follows")
        assertEquals(1, spans.size)
        assertEquals("x + y", spans[0].latex)
    }

    @Test
    fun `detects multiple inline formulas`() {
        val spans = extractInlineMath("\$a\$ and \$b\$ also \$c\$")
        assertEquals(3, spans.size)
        assertEquals(listOf("a", "b", "c"), spans.map { it.latex })
    }

    @Test
    fun `currency dollar-5 is not recognized`() {
        val spans = extractInlineMath("price \$5 total")
        assertTrue(spans.isEmpty())
    }

    @Test
    fun `cross-line dollar is not recognized`() {
        val spans = extractInlineMath("\$x +\ny\$")
        assertTrue(spans.isEmpty())
    }

    @Test
    fun `dollar inside inline code is not recognized`() {
        val spans = extractInlineMath("sample `\$x\$` after")
        assertTrue(spans.isEmpty())
    }

    @Test
    fun `escaped backslash-dollar does not count as closing`() {
        val spans = extractInlineMath("\$x = \\\$ donut\$")
        assertEquals(1, spans.size)
        assertEquals("x = \\\$ donut", spans[0].latex)
    }

    @Test
    fun `empty formula is not recognized`() {
        val spans = extractInlineMath("\$\$ after")
        assertTrue(spans.isEmpty())
    }

    @Test
    fun `not recognized when preceded by a letter`() {
        // foo$bar$baz can easily be mistaken for a code string
        val spans = extractInlineMath("foo\$bar\$baz")
        assertTrue(spans.isEmpty())
    }

    @Test
    fun `empty string does not throw`() {
        assertTrue(extractInlineMath("").isEmpty())
    }
}
