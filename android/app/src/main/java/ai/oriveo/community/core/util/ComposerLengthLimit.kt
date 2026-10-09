package ai.oriveo.community.core.util

import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue

/**
 * Maximum raw text length of the chat and home composers, in UTF-16 code units (`String.length`).
 * The same value is used on every platform.
 *
 * Rationale: the Android text field lays out the whole text again on every edit. On an emulator,
 * typing one character into 50,000 characters of non-repeating text costs a frame of roughly 40 ms
 * at worst, and more than 100 ms at 500,000. The limit sits at the size that is still comfortable
 * to type in.
 */
const val COMPOSER_MAX_INPUT_LENGTH = 50_000

data class ComposerLengthLimitResult(
    val value: TextFieldValue,
    /** Part of this edit was dropped because it did not fit. */
    val truncated: Boolean,
)

/**
 * Applies the composer length limit to one edit: [oldText] is the text that was last checked and
 * [new] is the value the field wants to become.
 *
 * - While composing ([TextFieldValue.composition] is non-null) the value passes through untouched:
 *   rewriting the string an input method is composing interrupts the composition. It is checked
 *   once committed.
 * - The edit is accepted when the new length is within [limit], or when it is not longer than the
 *   old one. The second rule keeps an over-long existing draft intact and only lets it shrink.
 *   Together they amount to "bound = max(limit, old length)".
 * - Otherwise only the tail of the segment inserted by this edit is cut so the result fits the
 *   bound: the text before and after the insertion point is left alone and the caret lands after
 *   the kept part. When the old text already exceeds the limit the bound is the old length:
 *   replacing a selection with something longer keeps as much of the head of the pasted text as
 *   fits (the result is no longer than before), and a plain insertion without a selection has no
 *   room, so the text stays as it was. The room must not be computed from the limit: it would be
 *   negative, dropping the whole paste and deleting the selected range as well.
 */
fun limitComposerEdit(
    oldText: String,
    new: TextFieldValue,
    limit: Int = COMPOSER_MAX_INPUT_LENGTH,
): ComposerLengthLimitResult {
    val newText = new.text
    val newLength = newText.length
    val oldLength = oldText.length
    val bound = maxOf(limit, oldLength)
    if (new.composition != null || newLength <= bound) {
        return ComposerLengthLimitResult(new, truncated = false)
    }

    // Inserted segment = what remains of the new text once the prefix and suffix shared with the
    // old text are removed. With repeated characters that split is ambiguous (inserting an "a" in
    // the middle of "aaa"); the caret sits at the end of the inserted segment after an insertion,
    // so the suffix is taken from the caret first.
    val caret = new.selection.max
    val caretSuffix = newLength - caret
    var suffix = if (
        new.selection.collapsed &&
        caretSuffix <= oldLength &&
        newText.regionMatches(caret, oldText, oldLength - caretSuffix, caretSuffix)
    ) {
        caretSuffix
    } else {
        commonSuffixLength(oldText, newText)
    }
    var prefix = commonPrefixLength(oldText, newText, oldLength - suffix)
    // A shared boundary can fall inside a surrogate pair (two emoji that share a high surrogate):
    // count that half code unit as part of the inserted segment.
    if (prefix > 0 && newText[prefix - 1].isHighSurrogate()) prefix--
    if (suffix > 0 && newText[newLength - suffix].isLowSurrogate()) suffix--

    val kept = newText.substring(prefix, newLength - suffix).takeUtf16Units(bound - prefix - suffix)
    val text = buildString(prefix + kept.length + suffix) {
        append(newText, 0, prefix)
        append(kept)
        append(newText, newLength - suffix, newLength)
    }
    return ComposerLengthLimitResult(
        value = TextFieldValue(text = text, selection = TextRange(prefix + kept.length)),
        truncated = true,
    )
}

private fun commonPrefixLength(a: String, b: String, max: Int): Int {
    var index = 0
    while (index < max && a[index] == b[index]) index++
    return index
}

private fun commonSuffixLength(a: String, b: String): Int {
    val max = minOf(a.length, b.length)
    var count = 0
    while (count < max && a[a.length - 1 - count] == b[b.length - 1 - count]) count++
    return count
}

/**
 * Length-limit state of one text field: remembers the text that was last checked and de-duplicates
 * the "limit reached" notice.
 *
 * Why it keeps its own copy of the text: values pass through unchecked while composing, so by the
 * time a composition is committed the field's previous value already holds the full composed text.
 * Using that as the old value would conclude "it did not grow" and miss the check. Edits are
 * always compared against the text that was last **checked**.
 *
 * Notice de-duplication: one notice per over-limit edit. Typing on at the limit does not repeat
 * it; it re-arms once the length drops back below the limit (the global snackbar has a single
 * slot, so without this every keystroke would replace it).
 */
class ComposerLengthLimiter(
    initialText: String,
    private val limit: Int = COMPOSER_MAX_INPUT_LENGTH,
) {
    data class Edit(val value: TextFieldValue, val shouldNotify: Boolean)

    var settledText: String = initialText
        private set
    private var armed = true

    /**
     * Programmatic writes (draft restore, edit restore, clearing): accepted as they are, with no
     * truncation and no notice. Cutting them would silently destroy content the user already has.
     */
    fun acceptProgrammatic(text: String) {
        settledText = text
        armed = true
    }

    fun onUserEdit(new: TextFieldValue): Edit {
        if (new.composition != null) return Edit(new, shouldNotify = false)
        val result = limitComposerEdit(settledText, new, limit)
        settledText = result.value.text
        val notify = result.truncated && armed
        if (result.truncated) {
            armed = false
        } else if (settledText.length < limit) {
            armed = true
        }
        return Edit(result.value, notify)
    }
}
