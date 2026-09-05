package ai.oriveo.community.core.util

import org.junit.Assert.assertEquals
import org.junit.Test

class GraphemeUtilsTest {

    @Test
    fun `graphemeCount keeps emoji and combining marks intact`() {
        assertEquals(1, "😀".graphemeCount())
        assertEquals(1, "e\u0301".graphemeCount())
        assertEquals(1, "👍🏽".graphemeCount())
        assertEquals(3, "A😀B".graphemeCount())
    }

    @Test
    fun `takeGraphemes does not split grapheme clusters`() {
        assertEquals("😀", "😀x".takeGraphemes(1))
        assertEquals("e\u0301", "e\u0301x".takeGraphemes(1))
        assertEquals("👍🏽", "👍🏽x".takeGraphemes(1))
    }

    // -- extended grapheme tests --

    @Test
    fun `family emoji counts as 1 grapheme`() {
        // 👨‍👩‍👧‍👦 = U+1F468 U+200D U+1F469 U+200D U+1F467 U+200D U+1F466
        assertEquals(1, "\uD83D\uDC68\u200D\uD83D\uDC69\u200D\uD83D\uDC67\u200D\uD83D\uDC66".graphemeCount())
    }

    @Test
    fun `flag emoji counts as 1 grapheme`() {
        // 🇨🇳 = U+1F1E8 U+1F1F3
        assertEquals(1, "\uD83C\uDDE8\uD83C\uDDF3".graphemeCount())
    }

    @Test
    fun `combining character e-acute counts as 1 grapheme`() {
        // e + combining acute accent = é
        assertEquals(1, "e\u0301".graphemeCount())
    }

    @Test
    fun `takeGraphemes at boundary does not split family emoji`() {
        val familyEmoji = "\uD83D\uDC68\u200D\uD83D\uDC69\u200D\uD83D\uDC67\u200D\uD83D\uDC66"
        val text = "${familyEmoji}ABC"
        // Taking 1 grapheme should keep the family emoji intact
        assertEquals(familyEmoji, text.takeGraphemes(1))
        // Taking 2 graphemes should include the family emoji plus A
        assertEquals("${familyEmoji}A", text.takeGraphemes(2))
    }

    @Test
    fun `takeGraphemes at boundary does not split flag emoji`() {
        val flag = "\uD83C\uDDE8\uD83C\uDDF3"
        val text = "${flag}Hi"
        assertEquals(flag, text.takeGraphemes(1))
        assertEquals("${flag}H", text.takeGraphemes(2))
    }

    @Test
    fun `takeGraphemes 2000 with mixed emoji and text`() {
        // Build a mixed string of emoji and plain text well beyond 2000 graphemes
        val emoji = "😀"
        val segment = "Hello${emoji}" // 6 graphemes
        val repeats = 400 // 2400 graphemes
        val text = segment.repeat(repeats)
        val result = text.takeGraphemes(2000)
        assertEquals(2000, result.graphemeCount())
    }

    @Test
    fun `takeGraphemes with zero returns empty string`() {
        assertEquals("", "Hello".takeGraphemes(0))
    }

    @Test
    fun `takeGraphemes with negative returns empty string`() {
        assertEquals("", "Hello".takeGraphemes(-1))
    }

    @Test
    fun `takeGraphemes on empty string returns empty`() {
        assertEquals("", "".takeGraphemes(5))
    }

    @Test
    fun `takeGraphemes when limit exceeds length returns full string`() {
        assertEquals("ABC", "ABC".takeGraphemes(100))
    }

    @Test
    fun `graphemeCount for mixed CJK and emoji`() {
        // kana characters + emoji + ASCII
        val text = "ねこ😀AB"
        assertEquals(5, text.graphemeCount())
    }

    @Test
    fun `graphemeCount for empty string is 0`() {
        assertEquals(0, "".graphemeCount())
    }
}
