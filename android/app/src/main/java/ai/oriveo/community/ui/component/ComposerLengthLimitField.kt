package ai.oriveo.community.ui.component

import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.OffsetMapping
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.input.TransformedText
import androidx.compose.ui.text.input.VisualTransformation
import ai.oriveo.community.R
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.util.COMPOSER_MAX_INPUT_LENGTH
import ai.oriveo.community.core.util.ComposerLengthLimiter
import ai.oriveo.community.ui.theme.OriveoTheme

/** Result of [rememberComposerLengthLimitedField], ready to hand to `BasicTextField(value: TextFieldValue)`. */
internal class ComposerLengthLimitedField(
    val value: TextFieldValue,
    val onValueChange: (TextFieldValue) -> Unit,
    /** Colors the unconfirmed part of a live dictation region; pass to `BasicTextField(visualTransformation)`. */
    val visualTransformation: VisualTransformation = VisualTransformation.None,
)

/**
 * Applies the length limit to a text field whose owner only holds a String (shared by the chat and
 * home composers; the rules live in [ComposerLengthLimiter]).
 *
 * Why not `BasicTextField(value: String)`: that overload can neither read nor write the selection,
 * so the caret would land in the wrong place after a paste in the middle is cut. This does what
 * that overload does internally (selection and composition are local state, the text follows the
 * owner) and runs the limit first in the callback. The selection state stays in the calling
 * composable: reading it invalidates only that composable, and the owner still holds one String.
 *
 * Owner text that differs from the local one means a programmatic write (draft restore, edit
 * restore, clearing after send): accepted as it is, with no truncation and no notice.
 *
 * When [selectionProbe] is non-null: selection changes are written into it; on creation and on external
 * text sync, a pending selection it holds (left by a dictation insert, or the selection restored when a live
 * word is withdrawn) is applied and then cleared, otherwise the original behavior is kept. The unconfirmed
 * part of a live dictation region is colored by dictationVolatile, only while the text is still the one the
 * probe wrote. While the probe tracks a live region, user edits are dropped and only selection changes are
 * taken ([ComposerSelectionProbe.filterUserEdit]).
 */
@Composable
internal fun rememberComposerLengthLimitedField(
    text: String,
    onTextChange: (String) -> Unit,
    limit: Int = COMPOSER_MAX_INPUT_LENGTH,
    selectionProbe: ComposerSelectionProbe? = null,
): ComposerLengthLimitedField {
    val snackbar = rememberGlobalSnackbarManager()
    val limiter = remember { ComposerLengthLimiter(text, limit) }
    var fieldValue by remember {
        val pending = selectionProbe?.consumePendingSelection(text.length)
        if (pending != null) selectionProbe?.record(pending)
        mutableStateOf(if (pending == null) TextFieldValue(text) else TextFieldValue(text, pending))
    }
    // The pending selection is only read during composition; clearing and recording happen in a SideEffect so it is not consumed when the composition is discarded.
    val pending = selectionProbe?.pendingSelection
    val value = when {
        fieldValue.text == text -> fieldValue
        pending != null -> fieldValue.copy(
            text = text,
            selection = TextRange(pending.start.coerceIn(0, text.length), pending.end.coerceIn(0, text.length)),
        )
        else -> fieldValue.copy(text = text)
    }
    SideEffect {
        if (value !== fieldValue) {
            fieldValue = value
            limiter.acceptProgrammatic(text)
            if (pending != null && selectionProbe?.consumePendingSelection(text.length) != null) {
                selectionProbe?.record(value.selection)
            }
        }
    }
    val currentProbe by rememberUpdatedState(selectionProbe)
    val currentText by rememberUpdatedState(text)
    val currentOnTextChange by rememberUpdatedState(onTextChange)
    val onValueChange: (TextFieldValue) -> Unit = remember {
        { raw ->
            // While a live dictation region is tracked, only selection is accepted and edits are not (the caret still shows and the IME stays connected); normal behavior resumes once tracking ends.
            val incoming = currentProbe?.filterUserEdit(currentText, raw) ?: raw
            val edit = limiter.onUserEdit(incoming)
            fieldValue = edit.value
            currentProbe?.record(edit.value.selection)
            if (edit.value.text != currentText) currentOnTextChange(edit.value.text)
            if (edit.shouldNotify) {
                snackbar?.show(
                    GlobalSnackbarMessage(
                        message = UiText.Resource(R.string.chat_input_length_limit_reached, listOf(limit)),
                    ),
                )
            }
        }
    }
    val volatileRange = selectionProbe?.volatileRange(text)
    val volatileColor = OriveoTheme.colors.dictationVolatile
    val transformation = remember(volatileRange, volatileColor) {
        if (volatileRange == null) VisualTransformation.None else LiveVolatileTransformation(volatileRange, volatileColor)
    }
    return ComposerLengthLimitedField(value, onValueChange, transformation)
}

/** Recolors [range] of the field text; offsets are unchanged. Out-of-range text (stale frame) is left plain. */
private class LiveVolatileTransformation(
    private val range: TextRange,
    private val color: androidx.compose.ui.graphics.Color,
) : VisualTransformation {
    override fun filter(text: AnnotatedString): TransformedText {
        if (range.max > text.length) return TransformedText(text, OffsetMapping.Identity)
        val styled = AnnotatedString.Builder(text).apply {
            addStyle(SpanStyle(color = color), range.min, range.max)
        }.toAnnotatedString()
        return TransformedText(styled, OffsetMapping.Identity)
    }
}
