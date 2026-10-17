package ai.oriveo.community.core.attachments.extractors

import org.junit.Assert.assertEquals
import org.junit.Test

/** Details of spec section 11 that golden does not cover. */
class RtfTextExtractorTest {

    private fun rtf(body: String): String = RtfTextExtractor.extract(body.toByteArray(Charsets.ISO_8859_1))

    @Test
    fun `font defaults to deff until a font is selected`() {
        assertEquals("\u4E2D", rtf("{\\rtf1\\ansi\\deff1{\\fonttbl{\\f1\\fcharset134 S;}}\\pard \\'d6\\'d0\\par}"))
    }

    @Test
    fun `double byte segment that fails as a whole decodes unit by unit`() {
        // 0x81 0x20 is not a valid GB18030 sequence: only this one unit becomes U+FFFD, and the following U+4E2D is as normal.
        assertEquals("\uFFFD\u4E2D", rtf("{\\rtf1\\ansi\\ansicpg936 \\'81\\'20\\'d6\\'d0}"))
    }

    @Test
    fun `lone surrogate becomes replacement character`() {
        assertEquals("\uFFFDx", rtf("{\\rtf1 \\u-10179?x}"))
    }

    @Test
    fun `hidden text suppresses line breaks too`() {
        assertEquals("ab", rtf("{\\rtf1 a\\v hidden\\par\\line\\v0 b}"))
    }

    @Test
    fun `ud destination is only let through inside upr`() {
        assertEquals("ac", rtf("{\\rtf1 a{\\*\\ud b}c}"))
        assertEquals("y", rtf("{\\rtf1 {\\upr{x}{\\*\\ud y}}}"))
    }

    @Test
    fun `unknown code page decodes as 1252`() {
        assertEquals("\u00E9\u20AC", rtf("{\\rtf1\\ansi\\ansicpg99999 \\'e9\\'80}"))
    }

    @Test
    fun `plain ends hidden text`() {
        assertEquals("a b", rtf("{\\rtf1 a\\v x\\plain  b}"))
    }
}
