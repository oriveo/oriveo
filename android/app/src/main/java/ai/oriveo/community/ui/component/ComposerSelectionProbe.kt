package ai.oriveo.community.ui.component

import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import ai.oriveo.community.core.util.COMPOSER_MAX_INPUT_LENGTH
import ai.oriveo.community.core.util.limitComposerEdit
import ai.oriveo.community.core.voice.DictationRules

/**
 * Selection exit of a length-limited composer, used to insert dictation text at the caret.
 *
 * The field ([rememberComposerLengthLimitedField]) writes every selection it settles on into [selection]; the
 * probe outlives the field, so when the field is swapped out the cached selection is still used (clamped to
 * the current text). [insert] leaves a pending caret that the field applies the next time it adopts upstream
 * text (initial composition or external text sync), so the caret lands right after the inserted text.
 *
 * Offsets are UTF-16 units of the raw text. No selection ever recorded -> append at the end.
 */
class ComposerSelectionProbe(
    private val limit: Int = COMPOSER_MAX_INPUT_LENGTH,
    /** Called when an insertion is truncated by the length limit (host shows the limit toast). */
    var onLimitExceeded: () -> Unit = {},
) {
    /** Last selection the field settled on; null = never recorded. */
    var selection: TextRange? = null
        private set

    /** Caret to apply when the field next adopts upstream text; null = keep the field's own selection. */
    var pendingCaret: Int? = null
        private set

    fun record(selection: TextRange) {
        this.selection = selection
    }

    /** Returns the pending caret (clamped to [textLength]) and clears it. */
    fun consumePendingCaret(textLength: Int): Int? {
        val caret = pendingCaret ?: return null
        pendingCaret = null
        return caret.coerceIn(0, textLength)
    }

    /** Inserts [transcript] into [currentText] at the cached selection and returns the new text. */
    fun insert(transcript: String, currentText: String): String {
        val length = currentText.length
        val range = selection ?: TextRange(length)
        val insertion = DictationRules.insert(
            text = currentText,
            selectionStart = range.start.coerceIn(0, length),
            selectionEnd = range.end.coerceIn(0, length),
            transcript = transcript,
        )
        if (insertion.text == currentText) return currentText
        val limited = limitComposerEdit(
            oldText = currentText,
            new = TextFieldValue(insertion.text, TextRange(insertion.cursor)),
            limit = limit,
        )
        if (limited.value.text != currentText) {
            val caret = limited.value.selection.max
            pendingCaret = caret
            selection = TextRange(caret)
        }
        if (limited.truncated) onLimitExceeded()
        return limited.value.text
    }
}
