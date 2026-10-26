package ai.oriveo.community.ui.component

import androidx.compose.ui.text.TextRange
import ai.oriveo.community.core.util.COMPOSER_MAX_INPUT_LENGTH
import ai.oriveo.community.core.voice.DictationRules
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
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
}
