package ai.oriveo.community.ui.component.markdown

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * LatexNormalizer test cases mirror the equivalent normalizer test suite maintained
 * elsewhere in the project; add new cases to both to keep the rules in sync.
 */
class LatexNormalizerTest {

    // -- normalizeLatexDelimiters --

    @Test
    fun `inline backslash-paren converts to dollar`() {
        assertEquals(
            "もじ \$x + y\$ あと",
            normalizeLatexDelimiters("もじ \\(x + y\\) あと"),
        )
    }

    @Test
    fun `block backslash-bracket converts to dollar-dollar`() {
        assertEquals(
            "\$\$x^2 + 1\$\$",
            normalizeLatexDelimiters("\\[x^2 + 1\\]"),
        )
    }

    @Test
    fun `block backslash-bracket may span lines`() {
        val input = "まえ\n\\[\nx^2 +\ny^2\n\\]\nあと"
        assertEquals(
            "まえ\n\$\$\nx^2 +\ny^2\n\$\$\nあと",
            normalizeLatexDelimiters(input),
        )
    }

    @Test
    fun `inline backslash-paren may not span lines`() {
        val input = "まえ \\(x +\ny\\) あと"
        assertEquals(input, normalizeLatexDelimiters(input))
    }

    @Test
    fun `already dollar form is unchanged`() {
        val input = "ねだん \$5 や \$x + y\$"
        assertEquals(input, normalizeLatexDelimiters(input))
    }

    @Test
    fun `already dollar-dollar form is unchanged`() {
        val input = "\$\$x^2\$\$"
        assertEquals(input, normalizeLatexDelimiters(input))
    }

    @Test
    fun `LaTeX inside inline code is not converted`() {
        val input = "れい: `\\(x + y\\)` そのまま"
        assertEquals(input, normalizeLatexDelimiters(input))
    }

    @Test
    fun `LaTeX inside a fenced code block is not converted`() {
        val input = "```js\nfoo[i\\]\nbar = \\(1\\)\n```\nそと \\(x\\)"
        assertEquals(
            "```js\nfoo[i\\]\nbar = \\(1\\)\n```\nそと \$x\$",
            normalizeLatexDelimiters(input),
        )
    }

    @Test
    fun `multiple formulas mixed together`() {
        val input = "だん 1 \\(a\\) だん 2 \\[b\\] だん 3 \\(c\\)"
        assertEquals(
            "だん 1 \$a\$ だん 2 \$\$b\$\$ だん 3 \$c\$",
            normalizeLatexDelimiters(input),
        )
    }

    @Test
    fun `inline and block formulas in the same paragraph`() {
        val input = "インライン \\(\\alpha + \\beta\\) とブロック \\[\\sum_{i=0}^n i\\]"
        assertEquals(
            "インライン \$\\alpha + \\beta\$ とブロック \$\$\\sum_{i=0}^n i\$\$",
            normalizeLatexDelimiters(input),
        )
    }

    @Test
    fun `plain text without any LaTeX is unchanged`() {
        val input = "すうしきのないふつうのぶんしょう"
        assertEquals(input, normalizeLatexDelimiters(input))
    }

    @Test
    fun `a code block embeds multiple formula delimiters`() {
        val input = "```\n\\[a\\]\n\\(b\\)\n\$c\$\n```"
        assertEquals(input, normalizeLatexDelimiters(input))
    }

    @Test
    fun `multiple backticks protect inline code`() {
        val input = "``\\(x\\)`` あと \\(y\\)"
        assertEquals(
            "``\\(x\\)`` あと \$y\$",
            normalizeLatexDelimiters(input),
        )
    }

    @Test
    fun `a block formula contains special characters`() {
        val input = "\\[\\frac{a}{b} = \\sqrt{c}\\]"
        assertEquals(
            "\$\$\\frac{a}{b} = \\sqrt{c}\$\$",
            normalizeLatexDelimiters(input),
        )
    }

    @Test
    fun `empty string`() {
        assertEquals("", normalizeLatexDelimiters(""))
    }

    @Test
    fun `a tilde fenced code block is also protected`() {
        val input = "~~~\n\\(x\\)\n~~~"
        assertEquals(input, normalizeLatexDelimiters(input))
    }

    // -- splitClosedAndOpenLatex --

    @Test
    fun `a fully closed formula leaves an empty tail`() {
        val r = splitClosedAndOpenLatex("もじ \\(x\\) あと")
        assertEquals("", r.tail)
        assertEquals("もじ \\(x\\) あと", r.closed)
    }

    @Test
    fun `an unclosed paren is split out as the tail`() {
        val r = splitClosedAndOpenLatex("もじ \\(x + y")
        assertEquals("もじ ", r.closed)
        assertEquals("\\(x + y", r.tail)
    }

    @Test
    fun `an unclosed bracket spanning lines is split out as the tail`() {
        val r = splitClosedAndOpenLatex("まえ\n\\[\nx^2 +")
        assertEquals("まえ\n", r.closed)
        assertEquals("\\[\nx^2 +", r.tail)
    }

    @Test
    fun `an unclosed dollar-dollar is split out as the tail`() {
        val r = splitClosedAndOpenLatex("まえ \$\$x^2")
        assertEquals("まえ ", r.closed)
        assertEquals("\$\$x^2", r.tail)
    }

    @Test
    fun `an unclosed single dollar is split out as the tail`() {
        val r = splitClosedAndOpenLatex("まえ \$x +")
        assertEquals("まえ ", r.closed)
        assertEquals("\$x +", r.tail)
    }

    @Test
    fun `a paren inside a code block doesn't affect the split`() {
        val r = splitClosedAndOpenLatex("```\n\\(unclosed\n```\nあと")
        assertEquals("", r.tail)
        assertEquals("```\n\\(unclosed\n```\nあと", r.closed)
    }

    @Test
    fun `an unclosed paren inside inline code is not split out`() {
        val r = splitClosedAndOpenLatex("`\\(x`")
        assertEquals("", r.tail)
    }

    @Test
    fun `multiple closed formulas plus a trailing unclosed one`() {
        val r = splitClosedAndOpenLatex("a \\(1\\) b \\[2\\] c \\(3")
        assertEquals("a \\(1\\) b \\[2\\] c ", r.closed)
        assertEquals("\\(3", r.tail)
    }

    @Test
    fun `a single dollar spanning a line break is not treated as a formula`() {
        val r = splitClosedAndOpenLatex("ねだん \$5\nつぎのぎょう")
        assertEquals("", r.tail)
    }

    @Test
    fun `a dollar followed by digits is currency, not a formula opening`() {
        // Matches extractInlineMath: a $ immediately followed by a digit is currency.
        // Treating it as an opening would split "$40" into the tail, which during
        // streaming briefly renders as its own trailing text node before folding back
        // into the paragraph once the formula closes -- a visible reflow.
        val r = splitClosedAndOpenLatex("ごうけい \$40")
        assertEquals("", r.tail)
        assertEquals("ごうけい \$40", r.closed)
    }

    @Test
    fun `a dollar immediately preceded by an alphanumeric is not an opening`() {
        // Matches extractInlineMath: a $ whose preceding character is alphanumeric
        // (bar$x / 100$y) is not a formula.
        assertEquals("", splitClosedAndOpenLatex("bar\$x みへいごう").tail)
        assertEquals("", splitClosedAndOpenLatex("100\$y みへいごう").tail)
    }

    @Test
    fun `a single dollar after a space followed by a letter is still an opening`() {
        val r = splitClosedAndOpenLatex("まえ \$x +")
        assertEquals("\$x +", r.tail)
    }
}
