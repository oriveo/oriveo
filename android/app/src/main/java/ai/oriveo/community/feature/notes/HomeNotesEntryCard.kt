package ai.oriveo.community.feature.notes

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.feature.home.AuroraTheme
import ai.oriveo.community.feature.home.auroraNotesSurface
import ai.oriveo.community.ui.theme.OriveoTheme

private val HOME_NOTES_CORNER_RADIUS = 26.dp

/**
 * The fixed Notes entry card on Home (matches iOS HomeNotesEntryCard): the same material as the hero composer,
 * keeping only the top-right glow.
 *
 * Left: `Notes` 17/semibold + count (mono accent, baseline aligned) + the latest note title (single line);
 * right: a 40dp notebook-pen line glyph (without the binding ticks) in a #C4B5FD → #EC8FEA → #8DB4FF gradient.
 * No chevron, count badge, watermark or solid icon tile; the whole card opens the notes list.
 * The design is a 1dp stroke plus padding 16/18/16/20 (border-box), so content sits 1dp further from the outer
 * edge: 17 / 19 / 17 / 21.
 */
@Composable
fun HomeNotesEntryCard(
    noteCount: Int,
    latestTitle: String?,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val isDark = OriveoTheme.isDark
    val hasNotes = noteCount > 0
    val shape = RoundedCornerShape(HOME_NOTES_CORNER_RADIUS)
    val previewLine = homeNotesPreviewLine(
        count = noteCount,
        latestTitle = latestTitle,
        untitled = stringResource(R.string.notes_untitled),
        invitation = stringResource(R.string.notes_subtitle),
    )
    val title = stringResource(R.string.home_notes_title)
    val countText = if (hasNotes) pluralStringResource(R.plurals.notes_count, noteCount, noteCount) else null
    val accessibilityText = homeNotesAccessibilityText(title = title, countText = countText, previewLine = previewLine)

    Row(
        modifier = modifier
            .fillMaxWidth()
            .auroraNotesSurface(isDark = isDark, cornerRadius = HOME_NOTES_CORNER_RADIUS)
            .clip(shape)
            .clickable(onClick = onClick)
            // With notes, read the latest title shown on the card as well (TalkBack hears what is visible)
            .clearAndSetSemantics {
                contentDescription = accessibilityText
                role = Role.Button
            }
            .padding(start = 21.dp, top = 17.dp, end = 19.dp, bottom = 17.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Row(
                // The design uses line heights 22 / 18; without padding the line boxes the card ends up too short
                modifier = Modifier.heightIn(min = 22.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = title,
                    fontSize = 17.sp,
                    lineHeight = 22.sp,
                    fontWeight = FontWeight.SemiBold,
                    letterSpacing = (-0.3).sp,
                    color = AuroraTheme.textPrimary(),
                    maxLines = 1,
                    modifier = Modifier.alignByBaseline(),
                )
                if (hasNotes) {
                    Text(
                        text = "$noteCount",
                        style = AuroraTheme.Typography.countMono,
                        color = AuroraTheme.accent(),
                        maxLines = 1,
                        modifier = Modifier
                            .padding(start = 8.dp)
                            .alignByBaseline(),
                    )
                }
            }
            Text(
                text = previewLine,
                fontSize = 13.sp,
                lineHeight = 18.sp,
                color = AuroraTheme.textSecondary(),
                // With notes: the latest title on one line; empty: the invitation may wrap to two lines, half a sentence would be unreadable
                maxLines = if (hasNotes) 1 else 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.heightIn(min = 18.dp),
            )
        }
        Icon(
            imageVector = NotesNotebookLineGlyph,
            contentDescription = null,
            modifier = Modifier.size(40.dp),
            tint = Color.Unspecified,
        )
    }
}

/** With notes → the latest title (an empty title after trimming shows "Untitled", matching iOS NoteText.displayTitle); empty → the invitation copy. */
internal fun homeNotesPreviewLine(count: Int, latestTitle: String?, untitled: String, invitation: String): String {
    if (count <= 0) return invitation
    return latestTitle?.trim().orEmpty().ifEmpty { untitled }
}

internal fun homeNotesAccessibilityText(title: String, countText: String?, previewLine: String): String =
    if (countText == null) "$title. $previewLine" else "$title, $countText, $previewLine"
