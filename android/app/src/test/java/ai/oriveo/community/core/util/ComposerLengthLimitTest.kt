package ai.oriveo.community.core.util

import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The composer length limit rules and the notice de-duplication, without a real text field. */
class ComposerLengthLimitTest {

    private val limit = COMPOSER_MAX_INPUT_LENGTH

    private fun caretAt(text: String, caret: Int = text.length) = TextFieldValue(text, TextRange(caret))

    @Test
    fun limit_pasteWithinLimit_passesThrough() {
        val limiter = ComposerLengthLimiter("")
        val pasted = caretAt("a".repeat(limit))

        val edit = limiter.onUserEdit(pasted)

        assertEquals(pasted, edit.value)
        assertFalse(edit.shouldNotify)
    }

    @Test
    fun limit_pasteOverflow_keepsPrefixAndToastsOnce() {
        val limiter = ComposerLengthLimiter("")

        val first = limiter.onUserEdit(caretAt("a".repeat(60_000)))
        assertEquals(50_000, first.value.text.length)
        assertEquals(TextRange(50_000), first.value.selection)
        assertTrue(first.shouldNotify)

        // Pasting again without dropping below the limit first: still cut, but no second notice.
        val second = limiter.onUserEdit(caretAt(first.value.text + "b".repeat(100)))
        assertEquals(first.value.text, second.value.text)
        assertFalse(second.shouldNotify)
    }

    @Test
    fun limit_pasteInMiddle_keepsSurroundingTextAndCaret() {
        val head = "H".repeat(20_000)
        val tail = "T".repeat(20_000)
        val pasted = "p".repeat(30_000)

        val result = limitComposerEdit(
            oldText = head + tail,
            new = caretAt(head + pasted + tail, caret = 50_000),
        )

        assertTrue(result.truncated)
        assertEquals(head + "p".repeat(10_000) + tail, result.value.text)
        assertEquals(TextRange(30_000), result.value.selection)
    }

    @Test
    fun limit_pasteInMiddle_ofRepeatedText_usesCaretToLocateInsertion() {
        // With a single repeated character the shared prefix and suffix are ambiguous; the caret is
        // the only thing that tells where the insertion happened.
        val result = limitComposerEdit(
            oldText = "a".repeat(49_990),
            new = caretAt("a".repeat(50_090), caret = 1_100),
        )

        assertEquals(50_000, result.value.text.length)
        assertEquals(TextRange(1_010), result.value.selection)
    }

    @Test
    fun limit_replaceSelection_countsRemovedRange() {
        val head = "H".repeat(49_000)
        val tail = "T".repeat(900)
        // The old text is exactly at the limit (49,000 + 100 + 900). Replacing the 100 characters in
        // the middle with 500 leaves room only for the 100 that were replaced.
        val result = limitComposerEdit(
            oldText = head + "x".repeat(100) + tail,
            new = caretAt(head + "p".repeat(500) + tail, caret = 49_500),
        )

        assertTrue(result.truncated)
        assertEquals(head + "p".repeat(100) + tail, result.value.text)
        assertEquals(TextRange(49_100), result.value.selection)
    }

    @Test
    fun limit_typingAtLimit_blockedToastOnceUntilRearmed() {
        val full = "a".repeat(limit)
        val limiter = ComposerLengthLimiter("")
        assertFalse(limiter.onUserEdit(caretAt(full)).shouldNotify)

        val blocked = limiter.onUserEdit(caretAt(full + "b"))
        assertEquals(full, blocked.value.text)
        assertTrue(blocked.shouldNotify)

        val blockedAgain = limiter.onUserEdit(caretAt(full + "c"))
        assertEquals(full, blockedAgain.value.text)
        assertFalse(blockedAgain.shouldNotify)

        // Deleting below the limit re-arms the notice; getting back to the limit itself is not over it.
        val shorter = full.dropLast(1)
        assertFalse(limiter.onUserEdit(caretAt(shorter)).shouldNotify)
        assertFalse(limiter.onUserEdit(caretAt(shorter + "d")).shouldNotify)
        assertTrue(limiter.onUserEdit(caretAt(shorter + "de")).shouldNotify)
    }

    @Test
    fun limit_imeComposition_notCutWhileComposing_cutOnCommit() {
        val base = "a".repeat(49_998)
        val limiter = ComposerLengthLimiter("")
        limiter.onUserEdit(caretAt(base))

        val composing = TextFieldValue(
            text = base + "hello",
            selection = TextRange(base.length + 5),
            composition = TextRange(base.length, base.length + 5),
        )
        val whileComposing = limiter.onUserEdit(composing)
        assertEquals(composing, whileComposing.value)
        assertFalse(whileComposing.shouldNotify)

        // Commit: same text as while composing, only the composition is cleared. The check has to
        // compare against the text from before the composition.
        val committed = limiter.onUserEdit(composing.copy(composition = null))
        assertEquals(base + "he", committed.value.text)
        assertEquals(TextRange(limit), committed.value.selection)
        assertNull(committed.value.composition)
        assertTrue(committed.shouldNotify)
    }

    @Test
    fun limit_cutPoint_neverSplitsSurrogateOrGraphemeCluster() {
        val family = "👨‍👩‍👧"
        val base = "a".repeat(49_999)

        // A grapheme cluster that crosses the limit is dropped as a whole, leaving 49,999.
        assertEquals(base, limitComposerEdit("", caretAt(base + family)).value.text)
        // The same goes for surrogate pairs, combining marks and skin-tone modifiers.
        assertEquals(base, limitComposerEdit("", caretAt(base + "😀")).value.text)
        assertEquals(
            "a".repeat(49_998),
            limitComposerEdit("", caretAt("a".repeat(49_998) + "é́x")).value.text,
        )
        assertEquals(
            "a".repeat(49_997),
            limitComposerEdit("", caretAt("a".repeat(49_997) + "👍🏽")).value.text,
        )
        // A whole cluster that fits is kept as usual.
        val fits = "a".repeat(limit - family.length) + family
        assertEquals(fits, limitComposerEdit("", caretAt(fits + "zzz")).value.text)

        assertEquals("ab", "ab😀".takeUtf16Units(3))
        assertEquals("ab😀", "ab😀c".takeUtf16Units(4))
        assertEquals("", family.takeUtf16Units(family.length - 1))
    }

    @Test
    fun limit_replaceEmojiSharingHighSurrogate_doesNotLeaveHalfPair() {
        val head = "a".repeat(49_998)
        // Replacing 😀 with 😁🙂: they share a high surrogate, so the shared prefix ends inside the
        // surrogate pair.
        val result = limitComposerEdit(
            oldText = head + "😀",
            new = caretAt(head + "😁🙂"),
        )

        assertEquals(head + "😁", result.value.text)
    }

    @Test
    fun limit_deleteAtOrAboveLimit_alwaysAllowed() {
        val atLimit = "a".repeat(limit)
        val deleted = limitComposerEdit(atLimit, caretAt(atLimit.dropLast(1)))
        assertFalse(deleted.truncated)
        assertEquals(limit - 1, deleted.value.text.length)

        val overlong = "a".repeat(70_000)
        val stillOver = limitComposerEdit(overlong, caretAt(overlong.dropLast(10)))
        assertFalse(stillOver.truncated)
        assertEquals(69_990, stillOver.value.text.length)
        // A same-length replacement (one character selected, one typed) does not count as growing.
        assertFalse(limitComposerEdit(overlong, caretAt("b" + overlong.drop(1), caret = 1)).truncated)
    }

    @Test
    fun limit_legacyOverlongDraft_restoredIntact_onlyShrinkAllowed() {
        val legacy = "a".repeat(70_000)
        val limiter = ComposerLengthLimiter("")
        limiter.acceptProgrammatic(legacy)
        assertEquals(legacy, limiter.settledText)

        // Growing is refused: the text keeps every character and the notice shows once.
        val grow = limiter.onUserEdit(caretAt(legacy + "b"))
        assertEquals(legacy, grow.value.text)
        assertTrue(grow.shouldNotify)

        // Deleting is allowed; the notice does not re-arm while still above the limit.
        val shrink = limiter.onUserEdit(caretAt(legacy.dropLast(5)))
        assertEquals(69_995, shrink.value.text.length)
        assertFalse(shrink.shouldNotify)
        assertFalse(limiter.onUserEdit(caretAt(shrink.value.text + "b")).shouldNotify)
    }

    @Test
    fun limit_legacyOverlongDraft_replaceSelectionWithLonger_keepsPastePrefixUpToOldLength() {
        val head = "H".repeat(40_000)
        val tail = "T".repeat(29_900)
        val legacy = head + "x".repeat(100) + tail
        val limiter = ComposerLengthLimiter("")
        limiter.acceptProgrammatic(legacy)

        // Replacing 100 selected characters with 500: bounded by the old length, the first 100 of
        // the pasted text are kept and the result is no longer than before.
        val longer = limiter.onUserEdit(caretAt(head + "p".repeat(500) + tail, caret = 40_500))
        assertEquals(head + "p".repeat(100) + tail, longer.value.text)
        assertEquals(TextRange(40_100), longer.value.selection)
        assertTrue(longer.shouldNotify)

        // Same-length and shorter replacements pass as usual, without a notice.
        val same = limitComposerEdit(legacy, caretAt(head + "q".repeat(100) + tail, caret = 40_100))
        assertFalse(same.truncated)
        val shorter = limitComposerEdit(legacy, caretAt(head + "q".repeat(40) + tail, caret = 40_040))
        assertFalse(shorter.truncated)
        assertEquals(69_940, shorter.value.text.length)

        // The cut moves back to a grapheme boundary: room for 3 code units cannot hold "ab" + 😀
        // (4 code units), so the result is slightly shorter than before.
        val cluster = limitComposerEdit(
            oldText = head + "xxx" + tail,
            new = caretAt(head + "ab\uD83D\uDE00zz" + tail, caret = 40_006),
        )
        assertTrue(cluster.truncated)
        assertEquals(head + "ab" + tail, cluster.value.text)

        // A plain insertion without a selection: refused entirely, the text is unchanged.
        val insert = limitComposerEdit(legacy, caretAt(head + "ppp" + "x".repeat(100) + tail, caret = 40_003))
        assertTrue(insert.truncated)
        assertEquals(legacy, insert.value.text)
        assertEquals(TextRange(40_000), insert.value.selection)
    }
}
