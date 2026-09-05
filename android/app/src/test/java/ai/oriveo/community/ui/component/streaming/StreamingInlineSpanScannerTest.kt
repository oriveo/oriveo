package ai.oriveo.community.ui.component.streaming

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Unit tests for the inline safety-boundary scanner. The rule to prove stability against:
 * a rendering decision before the boundary must never depend on an as-yet-unseen character.
 * Alignment with the real renderer is locked down by BlockCommitPrefixStabilityTest; this
 * test locks down the state machine itself.
 */
class StreamingInlineSpanScannerTest {

    private fun b(line: String): Int = StreamingInlineSpanScanner.safeBoundary(line)

    @Test
    fun `plain text boundary is full length`() {
        assertEquals(11, b("hello world"))
        assertEquals(4, b("にほんご"))
        assertEquals(0, b(""))
    }

    @Test
    fun `closed spans pass through`() {
        assertEquals(9, b("a **b** c"))
        assertEquals(7, b("*i* and"))
        assertEquals(8, b("~~s~~ ok"))
        assertEquals(5, b("`c` x"))
        assertEquals(8, b("[t](u) x"))
        assertEquals(5, b("\$x\$ y"))
        assertEquals(7, b("\$\$x\$\$ y"))
        assertEquals(9, b("\\(x\\) end"))
        assertEquals(7, b("\\[x\\] z"))
        assertEquals(13, b("***both*** ok"))
    }

    @Test
    fun `unclosed openers stop boundary at opener`() {
        assertEquals(2, b("a **b"))
        assertEquals(2, b("x *i"))
        assertEquals(2, b("a ~~s"))
        assertEquals(2, b("a `code"))
        assertEquals(2, b("a [link](u"))
        assertEquals(2, b("a \$x + y"))
        assertEquals(2, b("a \$\$x"))
        assertEquals(2, b("a \\(x"))
        assertEquals(2, b("a \\[x"))
        assertEquals(2, b("a ***bi"))
    }

    @Test
    fun `code span consumes markers inside`() {
        // ** inside an open code span doesn't count as an opener, only ` closes it
        assertEquals(9, b("`a **b` c"))
        assertEquals(0, b("`a **b ~~"))
    }

    @Test
    fun `italic closer needs known lookahead`() {
        // closer sits at end of line: appending a * would flip `!startsWith("**", end)` -> undecided
        assertEquals(0, b("*i*"))
        // the character right after the closer is already known to not be * -> closed
        assertEquals(5, b("*i* x"))
        // the first closer candidate starts with ** -> the opener is permanently literal (decision is sealed), later ** is handled normally
        assertEquals(12, b("*a**bold** z"))
    }

    @Test
    fun `trailing half markers are ambiguous`() {
        assertEquals(2, b("a ~")) // could become ~~
        assertEquals(2, b("a *")) // could become ** / ***
        assertEquals(2, b("a `")) // could become `` or an opener
        assertEquals(2, b("a \$")) // could become an opener / $$
        assertEquals(2, b("ab\\")) // could become \( / \[
        assertEquals(5, b("a ~ b")) // an isolated ~ followed by a known non-~ -> literal
    }

    @Test
    fun `double backtick first is literal second is opener`() {
        // the first ` of `` is always literal (the guard only looks at the next character); the second ` is an unclosed opener
        assertEquals(1, b("``x"))
        // ``x`: the second ` opens a code span that closes at position 3
        assertEquals(4, b("``x`"))
    }

    @Test
    fun `link bracket without paren is literal`() {
        // the character after the first ] is already known to not be ( -> the link can never form, [ is literal
        assertEquals(4, b("[t]x"))
        // ] sits at end of line: the ( lookahead for `](` is unknown -> undecided
        assertEquals(0, b("[t]"))
    }

    @Test
    fun `inline math respects extractInlineMath rules`() {
        // the character after the closer is a digit -> closing doesn't apply, keep looking -> no more $ -> undecided
        assertEquals(0, b("\$x\$5"))
        // the closer sits at end of line -> a digit could be appended -> undecided
        assertEquals(0, b("\$x\$"))
        // opener followed by a digit = currency, never a formula -> literal
        assertEquals(4, b("\$5 x"))
        // opener preceded by an alphanumeric -> never a formula -> literal
        assertEquals(3, b("a\$x"))
        // escaped \$ is literal
        assertEquals(4, b("\\$5x"))
        // a valid closer (preceded by non-space, followed by non-digit) -> the whole span passes
        assertEquals(9, b("\$x + y\$ z"))
    }

    @Test
    fun `mid-line display math holds until closed`() {
        assertEquals(4, b("see \$\$E=mc^2"))
        assertEquals(14, b("see \$\$E=mc^2\$\$"))
    }

    @Test
    fun `cjk with closed inline spans`() {
        assertEquals(10, b("にほ**んご**あさ"))
        assertEquals(2, b("にほ**んご"))
    }
}
