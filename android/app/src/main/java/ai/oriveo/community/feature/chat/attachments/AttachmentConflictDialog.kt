package ai.oriveo.community.feature.chat.attachments

import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import ai.oriveo.community.R

@Composable
fun AttachmentConflictDialog(
    show: Boolean,
    onDismiss: () -> Unit,
    onRemoveAttachment: () -> Unit,
) {
    if (!show) return

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.attachment_conflict_title)) },
        text = { Text(stringResource(R.string.attachment_conflict_message)) },
        confirmButton = {
            TextButton(
                onClick = {
                    onRemoveAttachment()
                    onDismiss()
                },
                colors = ButtonDefaults.textButtonColors(
                    contentColor = MaterialTheme.colorScheme.error,
                ),
            ) {
                Text(stringResource(R.string.remove_attachment))
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(stringResource(R.string.cancel))
            }
        },
    )
}
