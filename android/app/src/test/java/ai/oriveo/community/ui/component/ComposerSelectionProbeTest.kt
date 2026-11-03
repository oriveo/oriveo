package ai.oriveo.community.ui.component

import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import ai.oriveo.community.core.util.COMPOSER_MAX_INPUT_LENGTH
import ai.oriveo.community.core.voice.DictationRules
import ai.oriveo.community.core.voice.LiveDictationRules
import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Dictation inserts go through the field selection probe: insert rules live in DictationRules.insert, the length cap in limitComposerEdit. */
class ComposerSelectionProbeTest {

    private var exceeded = 0
    private val probe = ComposerSelectionProbe(onLimitExceeded = { exceeded++ })

    @Test
    fun insert_atCaret() {
        probe.record(TextRange(5))

        val result = probe.insert("there", "hello world")

        assertEquals("hello there world", result)
        assertEquals(DictationRules.insert("hello world", 5, 5, "there").text, result)
        assertEquals(0, exceeded)
    }

    @Test
    fun insert_withSelection_insertsAfterSelectionEndKeepingSelectedText() {
        probe.record(TextRange(0, 5))
        assertEquals("hello hi world", probe.insert("hi", "hello world"))

        // A reversed selection (anchor after focus) also inserts at the larger end.
        val reversed = ComposerSelectionProbe()
        reversed.record(TextRange(5, 0))
        assertEquals("hello hi world", reversed.insert("hi", "hello world"))
    }

    @Test
    fun insert_neverRecorded_appendsAtEnd() {
        assertNull(probe.selection)

        assertEquals("hello world", probe.insert("world", "hello"))
        assertEquals(11, probe.pendingCaret)
    }

    @Test
    fun insert_cachedSelectionClampedToLength() {
        probe.record(TextRange(50, 100))

        assertEquals("abc x", probe.insert("x", "abc"))
        assertEquals(5, probe.pendingCaret)
    }

    @Test
    fun insert_overLimit_truncatesAndNotifies() {
        val base = "a".repeat(COMPOSER_MAX_INPUT_LENGTH - 2)

        val result = probe.insert("bcd", base)

        assertEquals(base + " b", result)
        assertEquals(COMPOSER_MAX_INPUT_LENGTH, result.length)
        assertEquals(COMPOSER_MAX_INPUT_LENGTH, probe.pendingCaret)
        assertEquals(1, exceeded)
    }

    @Test
    fun insert_legacyOverlongText_unchangedNotifiesNoPendingCaret() {
        val legacy = "a".repeat(COMPOSER_MAX_INPUT_LENGTH + 10)
        probe.record(TextRange(3))

        assertEquals(legacy, probe.insert("bcd", legacy))
        assertEquals(1, exceeded)
        assertNull(probe.pendingCaret)
        assertEquals(TextRange(3), probe.selection)
    }

    @Test
    fun insert_returnsCaretAfterInsertedText() {
        probe.record(TextRange(5))

        probe.insert("there", "hello world")

        assertEquals(11, probe.pendingCaret)
        assertEquals(TextRange(11), probe.selection)
        assertEquals(11, probe.consumePendingCaret(17))
        assertNull(probe.pendingCaret)
        assertNull(probe.consumePendingCaret(17))
    }

    @Test
    fun insert_blankTranscript_unchangedNoPendingCaret() {
        probe.record(TextRange(2))

        assertEquals("hello", probe.insert(" \n", "hello"))
        assertNull(probe.pendingCaret)
        assertEquals(TextRange(2), probe.selection)
        assertEquals(0, exceeded)
    }

    // ── Live dictation range: recomputed each time as a whole from the original text and selection at start (LiveDictationRules.liveInsert) ──

    @Test
    fun live_recomputesWholeRegionFromOrigin() {
        probe.record(TextRange(5))
        probe.beginLive("hello world")

        val first = probe.updateLive(listOf("there"), "", "hello world")
        assertEquals("hello there world", first)

        val second = probe.updateLive(listOf("there"), "you", first)
        val expected = LiveDictationRules.liveInsert("hello world", 5, 5, listOf("there"), "you")
        assertEquals("hello there you world", second)
        assertEquals(expected.text, second)
        assertEquals(expected.cursor, probe.pendingCaret)
        assertEquals(TextRange(expected.volatileStart, expected.volatileEnd), probe.volatileRange(second))
        // If the unfinalized segment gets shorter, still recompute from the original text so no characters from the previous pass remain.
        assertEquals("hello there world", probe.updateLive(listOf("there"), "", second))
        assertNull(probe.volatileRange("hello there world"))
        assertTrue(probe.isTrackingLive)
    }

    @Test
    fun live_insertReplacesRegionWithFinalText() {
        probe.record(TextRange(5))
        probe.beginLive("hello world")
        val shown = probe.updateLive(listOf("thee"), "yu", "hello world")

        val result = probe.insert("there you", shown)

        val expected = LiveDictationRules.liveInsert("hello world", 5, 5, listOf("there you"), "")
        assertEquals("hello there you world", result)
        assertEquals(expected.text, result)
        assertEquals(expected.cursor, probe.pendingCaret)
        assertEquals(TextRange(expected.cursor), probe.selection)
        assertFalse(probe.isTrackingLive)
        assertNull(probe.volatileRange(result))
        assertEquals(0, exceeded)
    }

    @Test
    fun live_retractRestoresOriginTextAndSelection() {
        probe.record(TextRange(0, 5))
        probe.beginLive("hello world")
        val shown = probe.updateLive(listOf("hi"), "there", "hello world")
        assertEquals("hello hi there world", shown)

        assertEquals("hello world", probe.retractLive(shown))
        assertEquals(TextRange(0, 5), probe.pendingSelection)
        assertEquals(TextRange(0, 5), probe.selection)
        assertFalse(probe.isTrackingLive)
        // Not tracked after retract: further retracts and updates leave the text untouched.
        assertEquals("hello world", probe.retractLive("hello world"))
        assertEquals("hello world", probe.updateLive(listOf("x"), "", "hello world"))
    }

    @Test
    fun live_readOnlyWhileTrackingThenEditableAfterInsert() {
        probe.record(TextRange(5))
        assertFalse(probe.isTrackingLive)
        probe.beginLive("hello world")
        // Read-only as soon as dictation starts, until Insert / Send (both go through insert) or LiveRetract.
        assertTrue(probe.isTrackingLive)
        val first = probe.updateLive(listOf("there"), "yo", "hello world")
        assertTrue(probe.isTrackingLive)
        val second = probe.updateLive(listOf("there"), "you", first)
        assertTrue(probe.isTrackingLive)

        val result = probe.insert("there you", second)

        // Live text replaced as a whole by the finalized text: the user's original text appears once, with no leftover unfinalized text.
        assertEquals("hello there you world", result)
        assertEquals(DictationRules.insert("hello world", 5, 5, "there you").text, result)
        assertFalse(probe.isTrackingLive)
        assertNull(probe.volatileRange(result))
        // After ending, normal insertion resumes: the cursor sits after the finalized text.
        assertEquals(DictationRules.insert(result, 15, 15, "ok").text, probe.insert("ok", result))
    }

    @Test
    fun live_userTextEditDroppedWhileTrackingSelectionKept() {
        val idle = TextFieldValue("hello", TextRange(5))
        // Untracked: user edits pass through unchanged.
        val typed = TextFieldValue("hellox", TextRange(6))
        assertEquals(typed, probe.filterUserEdit("hello", typed))

        probe.record(TextRange(5))
        probe.beginLive("hello")
        val shown = probe.updateLive(listOf("there"), "", "hello")
        assertEquals("hello there", shown)

        // Edits made while tracking are discarded; the selection is kept (clamped to the current text).
        assertEquals(TextFieldValue(shown, TextRange(11)), probe.filterUserEdit(shown, TextFieldValue("${shown}xyz", TextRange(14))))
        assertEquals(TextFieldValue(shown, TextRange(0, 3)), probe.filterUserEdit(shown, TextFieldValue("Xhello there", TextRange(0, 3))))
        // Selection-only changes are accepted.
        val moved = TextFieldValue(shown, TextRange(2))
        assertEquals(moved, probe.filterUserEdit(shown, moved))

        // Normal input works after ending.
        val result = probe.insert("there", shown)
        assertFalse(probe.isTrackingLive)
        val after = TextFieldValue("${result}!", TextRange(result.length + 1))
        assertEquals(after, probe.filterUserEdit(result, after))
        assertEquals(idle, probe.filterUserEdit("hello", idle))
    }

    @Test
    fun live_retractLeavesNoResidueAndEndsTracking() {
        probe.record(TextRange(5))
        probe.beginLive("hello world")
        val first = probe.updateLive(listOf("there"), "you", "hello world")
        val second = probe.updateLive(listOf("there", "you"), "all", first)
        assertEquals("hello there you all world", second)

        assertEquals("hello world", probe.retractLive(second))
        assertFalse(probe.isTrackingLive)
        assertNull(probe.volatileRange(second))
        assertEquals(TextRange(5), probe.selection)
    }

    @Test
    fun live_truncatesToLimitVolatileFirst() {
        val limited = ComposerSelectionProbe(limit = 10, onLimitExceeded = { exceeded++ })
        limited.beginLive("abc")

        val shown = limited.updateLive(listOf("de"), "fghijklmn", "abc")

        assertEquals(LiveDictationRules.liveInsert("abc", 3, 3, listOf("de"), "fghijklmn", maxLength = 10).text, shown)
        assertEquals("abc de fgh", shown)
        assertEquals(0, exceeded)

        val result = limited.insert("de fghijklmn", shown)
        assertEquals("abc de fgh", result)
        assertEquals(1, exceeded)
    }
}
