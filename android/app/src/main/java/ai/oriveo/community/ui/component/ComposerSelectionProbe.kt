package ai.oriveo.community.ui.component

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import ai.oriveo.community.core.util.COMPOSER_MAX_INPUT_LENGTH
import ai.oriveo.community.core.util.limitComposerEdit
import ai.oriveo.community.core.voice.DictationRules
import ai.oriveo.community.core.voice.LiveDictationRules

/**
 * Selection exit of a length-limited composer, used to insert dictation text at the caret.
 *
 * The field ([rememberComposerLengthLimitedField]) writes every selection it settles on into [selection]; the
 * probe outlives the field, so when the field is swapped out the cached selection is still used (clamped to
 * the current text). [insert] leaves a pending caret that the field applies the next time it adopts upstream
 * text (initial composition or external text sync), so the caret lands right after the inserted text.
 *
 * Offsets are UTF-16 units of the raw text. No selection ever recorded -> append at the end.
 *
 * Live dictation region: [beginLive] remembers the text and selection at that moment; every [updateLive]
 * recomputes the whole text from them with [LiveDictationRules.liveInsert], so the region (including the
 * spaces it added) is always rebuilt rather than patched. While a region is tracked the field is read-only
 * ([isTrackingLive]), so the user cannot type into it; [insert] replaces the region with the final transcript
 * and [retractLive] restores the original text and selection, both ending the tracking.
 */
class ComposerSelectionProbe(
    private val limit: Int = COMPOSER_MAX_INPUT_LENGTH,
    /** Called when an insertion is truncated by the length limit (host shows the limit toast). */
    var onLimitExceeded: () -> Unit = {},
) {
    /** Last selection the field settled on; null = never recorded. */
    var selection: TextRange? = null
        private set

    /** Selection to apply when the field next adopts upstream text; null = keep the field's own selection. */
    var pendingSelection: TextRange? = null
        private set

    /** Caret end of [pendingSelection]. */
    val pendingCaret: Int?
        get() = pendingSelection?.end

    /** Text and selection when the live region started; null = no region tracked. Observed by the field. */
    private var liveOrigin by mutableStateOf<String?>(null)
    private var liveOriginSelection: TextRange = TextRange.Zero

    /** Text the live region last wrote and its unconfirmed (volatile) part; observed by the field for styling. */
    private var liveVolatile by mutableStateOf<Pair<String, TextRange>?>(null)

    /** True while a live region is tracked; the field stays read-only meanwhile. */
    val isTrackingLive: Boolean
        get() = liveOrigin != null

    fun record(selection: TextRange) {
        this.selection = selection
    }

    /** Returns the pending caret (clamped to [textLength]) and clears it. */
    fun consumePendingCaret(textLength: Int): Int? = consumePendingSelection(textLength)?.end

    /** Returns the pending selection (clamped to [textLength]) and clears it. */
    fun consumePendingSelection(textLength: Int): TextRange? {
        val pending = pendingSelection ?: return null
        pendingSelection = null
        return TextRange(pending.start.coerceIn(0, textLength), pending.end.coerceIn(0, textLength))
    }

    /** Volatile range to style when the field shows [text]; null when [text] is not what the live region wrote. */
    fun volatileRange(text: String): TextRange? {
        val (written, range) = liveVolatile ?: return null
        return range.takeIf { written == text && !it.collapsed }
    }

    /**
     * Filters a user edit of the field showing [currentText]: while a live region is tracked, text changes are
     * dropped and only the selection is kept (clamped to [currentText]), so the caret stays visible and the IME
     * stays connected; otherwise [incoming] passes through unchanged.
     */
    fun filterUserEdit(currentText: String, incoming: TextFieldValue): TextFieldValue {
        if (!isTrackingLive || incoming.text == currentText) return incoming
        val length = currentText.length
        return TextFieldValue(
            currentText,
            TextRange(incoming.selection.start.coerceIn(0, length), incoming.selection.end.coerceIn(0, length)),
        )
    }

    /** Starts a live region at the cached selection of [currentText] (drops any previous region). */
    fun beginLive(currentText: String) {
        val length = currentText.length
        val range = selection ?: TextRange(length)
        liveOrigin = currentText
        liveOriginSelection = TextRange(range.start.coerceIn(0, length), range.end.coerceIn(0, length))
        liveVolatile = null
    }

    /**
     * Rebuilds the live region from the origin with [finals] and [partial] (truncated to the limit) and returns the
     * new text. Not tracking -> [currentText] is returned unchanged.
     */
    fun updateLive(finals: List<String>, partial: String, currentText: String): String {
        val origin = liveOrigin ?: return currentText
        val live = LiveDictationRules.liveInsert(
            text = origin,
            selectionStart = liveOriginSelection.start,
            selectionEnd = liveOriginSelection.end,
            finals = finals,
            partial = partial,
            maxLength = limit,
        )
        liveVolatile = live.text to TextRange(live.volatileStart, live.volatileEnd)
        if (live.text != currentText) {
            pendingSelection = TextRange(live.cursor)
            selection = TextRange(live.cursor)
        }
        return live.text
    }

    /** Removes the live region: restores the origin text and selection. Not tracking -> unchanged. */
    fun retractLive(currentText: String): String {
        val origin = liveOrigin ?: return currentText
        val originSelection = liveOriginSelection
        stopLive()
        if (origin != currentText) pendingSelection = originSelection
        selection = originSelection
        return origin
    }

    private fun stopLive() {
        liveOrigin = null
        liveVolatile = null
    }

    /**
     * Inserts [transcript] into [currentText] and returns the new text: while a live region is tracked it is
     * replaced by [transcript] (caret after it), otherwise [transcript] goes in at the cached selection.
     */
    fun insert(transcript: String, currentText: String): String {
        liveOrigin?.let { return replaceLive(it, transcript, currentText) }
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
            pendingSelection = TextRange(caret)
            selection = TextRange(caret)
        }
        if (limited.truncated) onLimitExceeded()
        return limited.value.text
    }

    private fun replaceLive(origin: String, transcript: String, currentText: String): String {
        val originSelection = liveOriginSelection
        stopLive()
        val live = LiveDictationRules.liveInsert(
            text = origin,
            selectionStart = originSelection.start,
            selectionEnd = originSelection.end,
            finals = listOf(transcript),
            partial = "",
            maxLength = limit,
        )
        val full = DictationRules.insert(origin, originSelection.start, originSelection.end, transcript).text
        if (live.text != currentText) pendingSelection = TextRange(live.cursor)
        selection = TextRange(live.cursor)
        if (full.length > limit) onLimitExceeded()
        return live.text
    }
}
