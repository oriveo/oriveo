package ai.oriveo.community.core.notes

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SelectionSourceMapperTest {

    @Test
    fun `block math selection returns raw dollar-dollar source`() {
        val src = "Intro paragraph here.\n\n\$\$\ntan(30) = \\frac{height}{100}\n\$\$\n\nOutro paragraph."

        val out = SelectionSourceMapper.extractSelectionMarkdown(src, "\$\$tan(30) = \\frac{height}{100}\$\$")
        assertTrue(out != null && out.contains("\$\$"))
        assertTrue(out!!.contains("\\frac{height}{100}"))
    }

    @Test
    fun `inline math selection returns source line`() {
        val src = "The value \$x_1\$ matters in physics today.\n\nAnother paragraph."
        val out = SelectionSourceMapper.extractSelectionMarkdown(src, "value \$x_1\$ matters in physics")
        assertEquals("The value \$x_1\$ matters in physics today.", out)
    }

    @Test
    fun `plain paragraph selection returns null (caller keeps exact selection)`() {
        val src = "This is a normal paragraph with several words in it."
        val sel = "normal paragraph with several words"
        assertNull(SelectionSourceMapper.extractSelectionMarkdown(src, sel))
    }

    @Test
    fun `short selection below signature threshold returns null`() {
        val src = "| Name | Age |\n|---|---|\n| Alice Smith | 30 |"
        assertNull(SelectionSourceMapper.extractSelectionMarkdown(src, "ab"))
    }

    @Test
    fun `fenced code block selection returns whole fenced block`() {
        val src = "Intro text here.\n\n```kotlin\nval x = 1\nval y = 2\n```\n\nOutro."
        val sel = "val x = 1 val y = 2"
        val out = SelectionSourceMapper.extractSelectionMarkdown(src, sel)
        assertEquals("```kotlin\nval x = 1\nval y = 2\n```", out)
    }

    @Test
    fun `table row selection returns sub-table with header and separator`() {
        val src = "| Name | Age |\n|---|---|\n| Alice Smith | 30 |\n| Bob Jones | 25 |"
        val sel = "Alice Smith 30"
        val out = SelectionSourceMapper.extractSelectionMarkdown(src, sel)
        assertEquals("| Name | Age |\n|---|---|\n| Alice Smith | 30 |", out)
    }

    @Test
    fun `list selection returns only selected list lines`() {
        val src = "Intro\n\n- first item here\n- second item here\n- third item here"
        val sel = "first item here second item here"
        val out = SelectionSourceMapper.extractSelectionMarkdown(src, sel)
        assertEquals("- first item here\n- second item here", out)
    }
}
