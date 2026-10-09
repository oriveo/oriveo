package ai.oriveo.community.ui.component

import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.text.input.TextFieldValue
import ai.oriveo.community.R
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.util.COMPOSER_MAX_INPUT_LENGTH
import ai.oriveo.community.core.util.ComposerLengthLimiter

/** Result of [rememberComposerLengthLimitedField], ready to hand to `BasicTextField(value: TextFieldValue)`. */
internal class ComposerLengthLimitedField(
    val value: TextFieldValue,
    val onValueChange: (TextFieldValue) -> Unit,
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
 */
@Composable
internal fun rememberComposerLengthLimitedField(
    text: String,
    onTextChange: (String) -> Unit,
    limit: Int = COMPOSER_MAX_INPUT_LENGTH,
): ComposerLengthLimitedField {
    val snackbar = rememberGlobalSnackbarManager()
    val limiter = remember { ComposerLengthLimiter(text, limit) }
    var fieldValue by remember { mutableStateOf(TextFieldValue(text)) }
    val value = if (fieldValue.text == text) fieldValue else fieldValue.copy(text = text)
    SideEffect {
        if (value !== fieldValue) {
            fieldValue = value
            limiter.acceptProgrammatic(text)
        }
    }
    val currentText by rememberUpdatedState(text)
    val currentOnTextChange by rememberUpdatedState(onTextChange)
    val onValueChange: (TextFieldValue) -> Unit = remember {
        { incoming ->
            val edit = limiter.onUserEdit(incoming)
            fieldValue = edit.value
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
    return ComposerLengthLimitedField(value, onValueChange)
}
