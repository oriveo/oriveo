package ai.oriveo.community.feature.chat.composer

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.automirrored.outlined.StickyNote2
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.Note
import ai.oriveo.community.ui.theme.OriveoTheme

@Composable
private fun noteChipTitle(note: Note): String =
    note.title.trim().ifBlank { stringResource(R.string.notes_untitled) }

@Composable
fun NoteContextSection(
    attachedNotes: List<Note>,
    relatedNotes: List<Note>,
    onAttach: (Note) -> Unit,
    onDismissRelated: (Note) -> Unit,
    onDetach: (Note) -> Unit,
    onPreview: (Note) -> Unit,
    modifier: Modifier = Modifier,
) {
    if (attachedNotes.isEmpty() && relatedNotes.isEmpty()) return
    val colors = OriveoTheme.colors
    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        relatedNotes.forEach { note ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .background(colors.surfaceElevated)
                    .padding(horizontal = 12.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Icon(
                    Icons.AutoMirrored.Outlined.StickyNote2,
                    contentDescription = null,
                    tint = colors.primary,
                    modifier = Modifier.size(16.dp),
                )
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = stringResource(R.string.notes_chat_related_notes_title),
                        style = OriveoTheme.typography.footnote,
                        color = colors.textTertiary,
                    )
                    Text(
                        text = noteChipTitle(note),
                        style = OriveoTheme.typography.caption,
                        color = colors.textPrimary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                Text(
                    text = stringResource(R.string.notes_chat_attach_note),
                    style = OriveoTheme.typography.caption,
                    color = colors.primary,
                    modifier = Modifier
                        .clip(RoundedCornerShape(8.dp))
                        .clickable { onAttach(note) }
                        .padding(horizontal = 8.dp, vertical = 4.dp),
                )
                Text(
                    text = stringResource(R.string.notes_chat_dismiss_note_suggestion),
                    style = OriveoTheme.typography.caption,
                    color = colors.textTertiary,
                    modifier = Modifier
                        .clip(RoundedCornerShape(8.dp))
                        .clickable { onDismissRelated(note) }
                        .padding(horizontal = 8.dp, vertical = 4.dp),
                )
            }
        }

        if (attachedNotes.isNotEmpty()) {
            LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                items(attachedNotes, key = { it.id }) { note ->
                    Row(
                        modifier = Modifier
                            .clip(RoundedCornerShape(16.dp))
                            .background(colors.primary.copy(alpha = 0.12f))
                            .clickable { onPreview(note) }
                            .padding(start = 10.dp, end = 4.dp, top = 6.dp, bottom = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        Icon(
                            Icons.AutoMirrored.Outlined.StickyNote2,
                            contentDescription = null,
                            tint = colors.primary,
                            modifier = Modifier.size(14.dp),
                        )
                        Text(
                            text = noteChipTitle(note),
                            style = OriveoTheme.typography.caption,
                            color = colors.textPrimary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.widthIn(max = 140.dp),
                        )
                        Icon(
                            Icons.Outlined.Close,
                            contentDescription = stringResource(
                                R.string.notes_chat_remove_note_context,
                                noteChipTitle(note),
                            ),
                            tint = colors.textSecondary,
                            modifier = Modifier
                                .size(18.dp)
                                .clip(CircleShape)
                                .clickable { onDetach(note) }
                                .padding(2.dp),
                        )
                    }
                }
            }
        }
    }
}
