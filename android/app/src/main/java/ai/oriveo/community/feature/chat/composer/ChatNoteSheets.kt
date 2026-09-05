package ai.oriveo.community.feature.chat.composer

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.Note
import ai.oriveo.community.ui.component.markdown.MarkdownMessageView
import ai.oriveo.community.ui.theme.OriveoTheme


@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NotePreviewSheet(note: Note, onDismiss: () -> Unit) {
    val colors = OriveoTheme.colors
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        dragHandle = { ai.oriveo.community.ui.component.OriveoSheetDragHandle() },
        containerColor = colors.backgroundBase,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp)
                .padding(bottom = 24.dp)
                .heightIn(max = 480.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(
                text = note.title.trim().ifBlank { stringResource(R.string.notes_untitled) },
                style = OriveoTheme.typography.title3,
                color = colors.textPrimary,
            )
            val previewBody = note.body.ifBlank { note.bodySnapshot.orEmpty() }
            if (previewBody.isNotBlank()) {
                MarkdownMessageView(text = previewBody, modifier = Modifier.fillMaxWidth())
            }
        }
    }
}
