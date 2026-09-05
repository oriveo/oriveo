package ai.oriveo.community.feature.notes

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.automirrored.outlined.DriveFileMove
import androidx.compose.material.icons.automirrored.outlined.StickyNote2
import androidx.compose.material.icons.automirrored.outlined.Undo
import androidx.compose.material.icons.filled.Autorenew
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material.icons.outlined.Apps
import androidx.compose.material.icons.outlined.ArrowOutward
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.CreateNewFolder
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.filled.Folder as FolderFilled
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Inbox
import androidx.compose.material.icons.outlined.LocalOffer
import androidx.compose.material.icons.outlined.PushPin
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.shadow
import androidx.compose.foundation.layout.offset
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.FolderColor
import ai.oriveo.community.core.model.Note
import ai.oriveo.community.core.model.NoteCaptureKind
import ai.oriveo.community.core.model.NoteFolder
import ai.oriveo.community.core.notes.NoteTime
import ai.oriveo.community.ui.theme.providerTintFor
import ai.oriveo.community.ui.component.OriveoCard
import ai.oriveo.community.ui.component.OriveoSheetDragHandle
import ai.oriveo.community.ui.component.ProviderBadgeIcon
import ai.oriveo.community.ui.component.markdown.MarkdownRenderer
import ai.oriveo.community.ui.component.markdown.MarkdownTheme
import ai.oriveo.community.ui.theme.OriveoRadius
import ai.oriveo.community.ui.theme.OriveoSurfaceStyle
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.oriveoSurface


@Composable
fun rememberFormattedNoteDate(iso: String): String {
    val context = LocalContext.current
    return remember(iso) {
        val millis = NoteTime.isoToMillisOrNull(iso) ?: return@remember ""
        android.text.format.DateUtils.formatDateTime(
            context,
            millis,
            android.text.format.DateUtils.FORMAT_SHOW_DATE or android.text.format.DateUtils.FORMAT_ABBREV_MONTH,
        )
    }
}


@Composable
private fun Modifier.notesFlatCard(radius: androidx.compose.ui.unit.Dp = OriveoRadius.hero): Modifier {
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    return this.oriveoSurface(
        colors = colors,
        isDark = isDark,
        fill = colors.surface,
        borderColor = Color.Transparent,
        radius = radius,
        shadowStyle = OriveoSurfaceStyle.Soft,
    )
}

@Composable
private fun Modifier.notesDocumentCard(
    brand: Color,
    hasSource: Boolean,
    radius: androidx.compose.ui.unit.Dp = OriveoRadius.hero,
): Modifier {
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    return this
        .shadow(
            elevation = if (isDark) 18.dp else 10.dp,
            shape = RoundedCornerShape(radius),
            ambientColor = brand.copy(alpha = if (hasSource) 0.16f else 0.06f),
            spotColor = brand.copy(alpha = if (hasSource) 0.12f else 0.04f),
        )
        .oriveoSurface(
            colors = colors,
            isDark = isDark,
            fill = colors.surfaceElevated,
            
            
            borderColor = Color.Transparent,
            radius = radius,
            shadowStyle = OriveoSurfaceStyle.Soft,
        )
        .background(
            brush = Brush.linearGradient(
                colors = listOf(
                    
                    colors.glassHighlight,
                    brand.copy(alpha = if (hasSource) 0.045f else 0.018f),
                    Color.Transparent,
                ),
            ),
            shape = RoundedCornerShape(radius),
        )
        
        .drawWithCache {
            val r = radius.toPx()
            val glow = Brush.radialGradient(
                colors = listOf(brand.copy(alpha = if (hasSource) 0.13f else 0.035f), Color.Transparent),
                center = Offset(size.width * 0.16f, size.height * 0.12f),
                radius = size.width * 0.6f,
            )
            onDrawBehind { drawRoundRect(brush = glow, cornerRadius = CornerRadius(r, r)) }
        }
}


internal fun Note.showsBadge(): Boolean =
    captureKind != NoteCaptureKind.Blank &&
        (sourceProviderKind != null || !sourceModelName.isNullOrBlank())


@Composable
private fun Note.brandColor(): Color =
    sourceProviderKind?.let { providerTintFor(it.rawValue) } ?: OriveoTheme.colors.primary


@Composable
internal fun NoteSourceBadge(note: Note, modifier: Modifier = Modifier) {
    val brand = note.brandColor()
    val label = note.sourceModelName?.takeIf { it.isNotBlank() }
        ?: note.sourceProviderName?.takeIf { it.isNotBlank() }
    Row(
        modifier = modifier
            .clip(RoundedCornerShape(OriveoRadius.chip))
            .background(brand.copy(alpha = 0.12f))
            
            .border(1.dp, brand.copy(alpha = 0.08f), RoundedCornerShape(OriveoRadius.chip))
            .padding(horizontal = 10.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        note.sourceProviderKind?.let { ProviderBadgeIcon(kind = it, size = 16.dp) }
        if (!label.isNullOrBlank()) {
            Text(
                text = label,
                style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.SemiBold),
                color = brand,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}


@Composable
internal fun NoteTagChip(
    tag: String,
    brand: Color,
    hasSource: Boolean,
    modifier: Modifier = Modifier,
    role: NoteTagChipRole = NoteTagChipRole.Applied,
    selected: Boolean = false,
    onClick: (() -> Unit)? = null,
    onRemove: (() -> Unit)? = null,
) {
    val colors = OriveoTheme.colors
    val chipColors = noteTagChipColors(role, OriveoTheme.isDark, selected)
    val shape = CircleShape
    Row(
        modifier = modifier
            .clip(shape)
            .background(chipColors.background)
            .border(1.dp, chipColors.borderColor, shape)
            .then(if (onClick != null) Modifier.clickable { onClick() } else Modifier)
            .padding(
                start = 9.dp,
                end = if (onRemove != null) 5.dp else 9.dp,
                top = 6.dp,
                bottom = 6.dp,
            ),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Icon(
            imageVector = Icons.Outlined.LocalOffer,
            contentDescription = null,
            modifier = Modifier.size(12.dp),
            tint = chipColors.iconColor,
        )
        Text(
            text = tag,
            style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.SemiBold),
            color = chipColors.tagColor,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        if (onRemove != null) {
            IconButton(onClick = onRemove, modifier = Modifier.size(18.dp)) {
                Icon(
                    Icons.Outlined.Close,
                    contentDescription = stringResource(R.string.notes_tags_remove, tag),
                    modifier = Modifier.size(13.dp),
                    tint = colors.textTertiary,
                )
            }
        }
    }
}

internal enum class NoteTagChipRole {
    Applied,
    Suggestion,
}

internal data class NoteTagChipColors(
    val background: Color,
    val borderColor: Color,
    val iconColor: Color,
    val hashColor: Color,
    val tagColor: Color,
)

internal fun noteTagChipColors(
    role: NoteTagChipRole,
    isDark: Boolean,
    selected: Boolean = false,
): NoteTagChipColors {
    
    val textColor = if (isDark) Color(0xFFEAD9AC) else Color(0xFF6E5518)
    val iconColor = if (isDark) Color(0xFFDCC07C) else Color(0xFFC79A2C)
    val background = when {
        selected -> if (isDark) Color(0xFF4C4027) else Color(0xFFF3E2A8)
        role == NoteTagChipRole.Suggestion -> if (isDark) Color(0xFF322B1D) else Color(0xFFFCF7E8)
        else -> if (isDark) Color(0xFF3A3220) else Color(0xFFFBF1D5)
    }
    val border = if (selected) {
        if (isDark) Color.White.copy(alpha = 0.14f) else Color(0xFFD9BD6C)
    } else {
        if (isDark) Color.White.copy(alpha = 0.07f) else Color(0xFFEAD8A2).copy(alpha = 0.9f)
    }
    
    val dimmed = role == NoteTagChipRole.Suggestion
    val dimmedIcon = iconColor.copy(alpha = if (dimmed) 0.6f else 1.0f)
    return NoteTagChipColors(
        background = background,
        borderColor = border,
        iconColor = dimmedIcon,
        hashColor = dimmedIcon,
        tagColor = if (selected) {
            if (isDark) Color(0xFFF4E7C0) else Color(0xFF55400F)
        } else {
            textColor.copy(alpha = if (dimmed) 0.78f else 1.0f)
        },
    )
}

internal fun noteCardPreviewSource(body: String): String {
    val lines = body.split("\n")
    val index = lines.indexOfFirst { it.trim().startsWith("## Cross-check") }
    if (index < 0) return body
    return lines.drop(index + 1).joinToString("\n").trim().ifEmpty { body }
}


@Composable
private fun rememberNotePreview(body: String): AnnotatedString {
    val mdColors = MarkdownTheme.colors()
    return remember(body, mdColors) {
        val stripped = stripBlockMarkdown(noteCardPreviewSource(body)).take(280)
        if (stripped.isEmpty()) AnnotatedString("") else MarkdownRenderer.render(stripped, mdColors)
    }
}


private val noteFenceRegex = Regex("```[a-zA-Z0-9]*")
private val noteHeadingRegex = Regex("(?m)^#{1,6}\\s+")
private val noteQuoteRegex = Regex("(?m)^>\\s+")
private val noteBulletRegex = Regex("(?m)^[-*+]\\s+")
private val noteOrderedListRegex = Regex("(?m)^\\d+\\.\\s+")
private val noteInlineSpaceRegex = Regex("[ \\t]+")
private val noteEdgeSpaceRegex = Regex("(?m)^[ \\t]+|[ \\t]+$")
private val noteBlankLineRegex = Regex("\\n{2,}")


private fun stripBlockMarkdown(body: String): String {
    var t = body
    t = t.replace(noteFenceRegex, "")
    t = t.replace("~~~", "")
    t = t.replace(noteHeadingRegex, "")
    t = t.replace(noteQuoteRegex, "")
    t = t.replace(noteBulletRegex, "")
    t = t.replace(noteOrderedListRegex, "")
    t = t.replace("|", " ")
    
    t = t.replace(noteInlineSpaceRegex, " ")
    t = t.replace(noteEdgeSpaceRegex, "")
    t = t.replace(noteBlankLineRegex, "\n")
    return t.trim()
}


@Composable
fun HomeNotesEntryCard(
    noteCount: Int,
    latestTitle: String?,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    val hasNotes = noteCount > 0
    val tint = if (isDark) Color(0xFF272140) else Color(0xFFE9E1FB)
    val shape = RoundedCornerShape(OriveoRadius.card)
    val previewLine = if (hasNotes && !latestTitle.isNullOrBlank()) {
        latestTitle
    } else {
        
        stringResource(R.string.notes_subtitle)
    }
    Box(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = 96.dp)
            
            .shadow(
                elevation = if (isDark) 10.dp else 14.dp,
                shape = shape,
                ambientColor = colors.primary,
                spotColor = colors.primary,
            )
            .clip(shape)
            .background(tint)
            .clickable(onClick = onClick),
    ) {
        
        Box(
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .size(104.dp)
                
                
                .offset(x = 26.dp, y = 24.dp)
                .rotate(-8f),
        ) {
            Icon(
                painter = painterResource(R.drawable.ic_notes_notebook),
                contentDescription = null,
                tint = colors.primary.copy(alpha = if (isDark) 0.20f else 0.12f),
                modifier = Modifier.size(104.dp),
            )
        }
        Row(
            modifier = Modifier
                .align(Alignment.CenterStart)
                .fillMaxWidth()
                .padding(horizontal = OriveoTheme.spacing.lg, vertical = OriveoTheme.spacing.md),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.md),
        ) {
            
            Box(
                modifier = Modifier
                    .size(44.dp)
                    .clip(RoundedCornerShape(OriveoRadius.chip))
                    .background(colors.primary),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    painter = painterResource(R.drawable.ic_notes_notebook),
                    contentDescription = null,
                    tint = Color.White,
                    modifier = Modifier.size(23.dp),
                )
            }
            Column(modifier = Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        text = stringResource(R.string.home_notes_title),
                        style = OriveoTheme.typography.title2,
                        color = colors.textPrimary,
                    )
                    if (hasNotes) {
                        Text(
                            text = "$noteCount",
                            style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.Bold),
                            color = colors.primary,
                            modifier = Modifier
                                .clip(CircleShape)
                                .background(colors.primary.copy(alpha = if (isDark) 0.26f else 0.15f))
                                .padding(horizontal = 7.dp, vertical = 2.dp),
                        )
                    }
                }
                Text(
                    text = previewLine,
                    style = OriveoTheme.typography.caption,
                    color = colors.textSecondary,
                    maxLines = if (hasNotes) 1 else 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Icon(
                imageVector = Icons.Filled.ChevronRight,
                contentDescription = null,
                tint = colors.primary.copy(alpha = 0.55f),
                modifier = Modifier.size(18.dp),
            )
        }
    }
}


@OptIn(ExperimentalFoundationApi::class)
@Composable
fun NoteCard(
    note: Note,
    onClick: () -> Unit,
    onTogglePin: () -> Unit,
    onMove: () -> Unit,
    onDelete: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    val untitled = stringResource(R.string.notes_untitled)
    var menuExpanded by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(OriveoRadius.hero)
    val brand = note.brandColor()
    val hasSource = note.showsBadge()
    val preview = rememberNotePreview(note.body)

    Box(modifier = modifier) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .notesDocumentCard(brand, hasSource, OriveoRadius.hero)
                .clip(shape)
                .combinedClickable(onClick = onClick, onLongClick = { menuExpanded = true })
                .padding(horizontal = 18.dp, vertical = 17.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            NoteCardByline(note, hasSource, showChevron = true)
            Text(
                text = note.title.ifBlank { untitled },
                style = OriveoTheme.typography.title2.copy(fontSize = 22.sp, fontWeight = FontWeight.Bold, lineHeight = 28.sp),
                color = colors.textPrimary,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            NoteExcerptPanel(
                preview = preview,
                emptyText = stringResource(R.string.notes_nothing_written),
                brand = brand,
                hasSource = hasSource,
            )
            if (note.tags.isNotEmpty()) {
                Row(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier.padding(top = 1.dp),
                ) {
                    note.tags.take(2).forEach { NoteTagChip(it, brand, hasSource) }
                    if (note.tags.size > 2) {
                        Text(
                            text = "+${note.tags.size - 2}",
                            style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.SemiBold),
                            color = colors.textSecondary,
                            modifier = Modifier
                                .clip(CircleShape)
                                .background(colors.surfaceInset.copy(alpha = 0.76f))
                                .padding(horizontal = 10.dp, vertical = 6.dp),
                        )
                    }
                }
            }
        }
        DropdownMenu(expanded = menuExpanded, onDismissRequest = { menuExpanded = false }) {
            DropdownMenuItem(
                text = {
                    Text(stringResource(if (note.isPinned) R.string.notes_action_unpin else R.string.notes_action_pin))
                },
                leadingIcon = {
                    Icon(
                        if (note.isPinned) Icons.Filled.PushPin else Icons.Outlined.PushPin,
                        contentDescription = null,
                    )
                },
                onClick = { menuExpanded = false; onTogglePin() },
            )
            DropdownMenuItem(
                text = { Text(stringResource(R.string.notes_folders_move_to)) },
                leadingIcon = { Icon(Icons.AutoMirrored.Outlined.DriveFileMove, contentDescription = null) },
                onClick = { menuExpanded = false; onMove() },
            )
            DropdownMenuItem(
                text = { Text(stringResource(R.string.delete), color = colors.danger) },
                leadingIcon = { Icon(Icons.Outlined.Delete, contentDescription = null, tint = colors.danger) },
                onClick = { menuExpanded = false; onDelete() },
            )
        }
    }
}


@Composable
private fun NoteCardByline(
    note: Note,
    hasSource: Boolean,
    showChevron: Boolean = false,
) {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Box(modifier = Modifier.weight(1f), contentAlignment = Alignment.CenterStart) {
            if (hasSource) {
                NoteSourceBadge(note)
            } else {
                ManualNoteToken()
            }
        }
        NotePinMark(note)
        NoteDateText(note.updatedAt)
        if (showChevron) {
            Icon(
                imageVector = Icons.Filled.ChevronRight,
                contentDescription = null,
                tint = colors.textTertiary.copy(alpha = 0.62f),
                modifier = Modifier.size(18.dp),
            )
        }
    }
}

@Composable
private fun ManualNoteToken() {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(OriveoRadius.chip))
            .background(colors.surfaceInset.copy(alpha = 0.72f))
            .padding(horizontal = 9.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Icon(
            imageVector = Icons.AutoMirrored.Outlined.StickyNote2,
            contentDescription = null,
            modifier = Modifier.size(14.dp),
            tint = colors.textTertiary,
        )
        Text(
            text = stringResource(R.string.notes_title),
            style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.SemiBold),
            color = colors.textTertiary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}


internal fun quoteWatermarkAlpha(isDark: Boolean, hasSource: Boolean, large: Boolean = false): Float =
    if (large) {
        if (isDark) (if (hasSource) 0.18f else 0.12f) else (if (hasSource) 0.10f else 0.045f)
    } else {
        if (isDark) (if (hasSource) 0.13f else 0.10f) else (if (hasSource) 0.06f else 0.03f)
    }

@Composable
private fun NoteExcerptPanel(
    preview: AnnotatedString,
    emptyText: String,
    brand: Color,
    hasSource: Boolean,
) {
    val colors = OriveoTheme.colors
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(18.dp))
            .background(
                Brush.linearGradient(
                    colors = listOf(
                        colors.surfaceInset.copy(alpha = 0.78f),
                        brand.copy(alpha = if (hasSource) 0.05f else 0.02f),
                    ),
                ),
            )
            
            
            
            .padding(start = 14.dp, top = 12.dp, end = 40.dp, bottom = 12.dp),
    ) {
        Text(
            text = "”",
            
            style = OriveoTheme.typography.hero.copy(fontSize = 24.sp, lineHeight = 24.sp, fontWeight = FontWeight.Bold),
            color = brand.copy(alpha = quoteWatermarkAlpha(OriveoTheme.isDark, hasSource)),
            modifier = Modifier
                .align(Alignment.TopEnd)
                .offset(x = 28.dp, y = (-5).dp),
        )
        if (preview.isNotEmpty()) {
            Text(
                text = preview,
                style = OriveoTheme.typography.caption.copy(lineHeight = 21.sp),
                color = colors.textSecondary,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
            )
        } else {
            Text(
                text = emptyText,
                style = OriveoTheme.typography.caption.copy(lineHeight = 21.sp),
                color = colors.textTertiary,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
private fun NotePinMark(note: Note) {
    if (note.isPinned) {
        Icon(
            imageVector = Icons.Filled.PushPin,
            contentDescription = stringResource(R.string.notes_label_pinned),
            modifier = Modifier
                .size(24.dp)
                .clip(CircleShape)
                .background(OriveoTheme.colors.primaryPressed)
                .padding(6.dp),
            tint = OriveoTheme.colors.onPrimary,
        )
    }
}

@Composable
private fun NoteDateText(iso: String) {
    Text(
        text = rememberFormattedNoteDate(iso),
        style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.SemiBold),
        color = OriveoTheme.colors.textSecondary,
        maxLines = 1,
        modifier = Modifier
            .clip(RoundedCornerShape(OriveoRadius.chip))
            .background(OriveoTheme.colors.surfaceInset.copy(alpha = 0.76f))
            .padding(horizontal = 10.dp, vertical = 6.dp),
    )
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun TrashNoteCard(
    note: Note,
    onClick: () -> Unit,
    onRestore: () -> Unit,
    onDeletePermanently: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    val untitled = stringResource(R.string.notes_untitled)
    var menuExpanded by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(OriveoRadius.hero)
    val hasSource = note.showsBadge()
    Box(modifier = modifier) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .notesFlatCard(OriveoRadius.hero)
                .clip(shape)
                .combinedClickable(onClick = onClick, onLongClick = { menuExpanded = true })
                .padding(OriveoTheme.spacing.lg),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            NoteCardByline(note, hasSource)
            Text(
                text = note.title.ifBlank { untitled },
                style = OriveoTheme.typography.title2.copy(fontSize = 21.sp, fontWeight = FontWeight.Bold, lineHeight = 27.sp),
                color = colors.textPrimary,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
        DropdownMenu(expanded = menuExpanded, onDismissRequest = { menuExpanded = false }) {
            DropdownMenuItem(
                text = { Text(stringResource(R.string.notes_trash_restore)) },
                leadingIcon = { Icon(Icons.AutoMirrored.Outlined.Undo, contentDescription = null) },
                onClick = { menuExpanded = false; onRestore() },
            )
            DropdownMenuItem(
                text = { Text(stringResource(R.string.notes_trash_delete_permanently), color = colors.danger) },
                leadingIcon = { Icon(Icons.Outlined.Delete, contentDescription = null, tint = colors.danger) },
                onClick = { menuExpanded = false; onDeletePermanently() },
            )
        }
    }
}


@OptIn(ExperimentalFoundationApi::class)
@Composable
fun FolderFilterChips(
    folders: List<NoteFolder>,
    selectedFolderId: String?,
    folderCounts: Map<String?, Int>,
    uncategorizedCount: Int,
    uncategorizedSentinel: String,
    onSelect: (String?) -> Unit,
    modifier: Modifier = Modifier,
    onFolderLongPress: ((NoteFolder) -> Unit)? = null,
) {
    LazyRow(modifier = modifier, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        item(key = "all") {
            FolderChip(
                label = stringResource(R.string.notes_folders_all),
                icon = Icons.Outlined.Apps,
                tint = OriveoTheme.colors.primary,
                count = null,
                active = selectedFolderId == null,
                onClick = { onSelect(null) },
            )
        }
        items(folders, key = { it.id }) { folder ->
            FolderChip(
                label = folder.name,
                icon = Icons.Filled.FolderFilled,
                tint = FolderColor.fromTag(folder.colorTag).toColor(),
                count = folderCounts[folder.id] ?: 0,
                active = selectedFolderId == folder.id,
                onClick = { onSelect(folder.id) },
                onLongClick = onFolderLongPress?.let { cb -> { cb(folder) } },
            )
        }
        item(key = "uncategorized") {
            FolderChip(
                label = stringResource(R.string.notes_folders_uncategorized),
                icon = Icons.Outlined.Inbox,
                tint = OriveoTheme.colors.textSecondary,
                count = uncategorizedCount,
                active = selectedFolderId == uncategorizedSentinel,
                onClick = { onSelect(uncategorizedSentinel) },
            )
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun FolderChip(
    label: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    tint: Color,
    count: Int?,
    active: Boolean,
    onClick: () -> Unit,
    onLongClick: (() -> Unit)? = null,
) {
    val colors = OriveoTheme.colors
    val shape = RoundedCornerShape(OriveoRadius.md)
    Row(
        modifier = Modifier
            .clip(shape)
            .background(if (active) tint else tint.copy(alpha = 0.10f))
            .combinedClickable(onClick = onClick, onLongClick = onLongClick)
            .padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            modifier = Modifier.size(15.dp),
            tint = if (active) Color.White else tint,
        )
        Text(
            text = label,
            style = OriveoTheme.typography.caption.copy(fontWeight = FontWeight.SemiBold),
            color = if (active) Color.White else colors.textPrimary,
            maxLines = 1,
        )
        if (count != null) {
            Text(
                text = "$count",
                style = OriveoTheme.typography.footnote,
                color = if (active) Color.White.copy(alpha = 0.75f) else colors.textTertiary,
            )
        }
    }
}


@Composable
fun TagFilterChips(
    availableTags: List<String>,
    selectedTags: List<String>,
    onToggle: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    if (availableTags.isEmpty()) return
    LazyRow(modifier = modifier, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        items(availableTags, key = { it }) { tag ->
            NoteTagChip(
                tag = tag,
                brand = OriveoTheme.colors.primary,
                hasSource = true,
                selected = tag in selectedTags,
                onClick = { onToggle(tag) },
            )
        }
    }
}


@Composable
fun NoteSourceCard(
    note: Note,
    onReturnToConversation: () -> Unit,
    modifier: Modifier = Modifier,
    onCrosscheck: (() -> Unit)? = null,
) {
    val colors = OriveoTheme.colors
    val brand = note.brandColor()
    val hasSource = note.showsBadge()
    val canReturn = !note.sourceConversationId.isNullOrBlank()
    
    if (!note.hasSource && !canReturn) return

    
    OriveoCard(modifier = modifier, radius = OriveoRadius.card, shadowStyle = OriveoSurfaceStyle.Lifted) {
        Column(verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.md)) {
            Text(
                text = stringResource(R.string.notes_source_title),
                style = OriveoTheme.typography.title3,
                color = colors.textPrimary,
            )
            note.sourcePrompt?.takeIf { it.isNotBlank() }?.let { prompt ->
                
                
                
                
                val barColor = brand.copy(alpha = if (hasSource) 0.5f else 0.42f)
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(OriveoRadius.inset))
                        .background(brand.copy(alpha = if (hasSource) 0.07f else 0.06f))
                        .drawBehind {
                            val inset = 9.dp.toPx()
                            drawRoundRect(
                                color = barColor,
                                topLeft = Offset(6.dp.toPx(), inset),
                                size = Size(3.dp.toPx(), (size.height - inset * 2).coerceAtLeast(0f)),
                                cornerRadius = CornerRadius(2.dp.toPx(), 2.dp.toPx()),
                            )
                        },
                ) {
                    
                    
                    Text(
                        text = prompt,
                        style = OriveoTheme.typography.footnote,
                        color = colors.textSecondary,
                        maxLines = 3,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(start = 18.dp, top = 11.dp, end = 46.dp, bottom = 11.dp),
                    )
                    Box(Modifier.matchParentSize(), contentAlignment = Alignment.TopEnd) {
                        Text(
                            text = "”",
                            style = OriveoTheme.typography.hero.copy(fontSize = 30.sp, lineHeight = 30.sp, fontWeight = FontWeight.Bold),
                            color = brand.copy(alpha = quoteWatermarkAlpha(OriveoTheme.isDark, hasSource, large = true)),
                            modifier = Modifier.padding(top = 7.dp, end = 12.dp),
                        )
                    }
                }
            }
            
            
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (canReturn) {
                    SourceActionPill(
                        text = stringResource(R.string.notes_source_back_to_conversation),
                        icon = Icons.AutoMirrored.Filled.ArrowForward,
                        style = SourceActionStyle.Primary,
                        onClick = onReturnToConversation,
                    )
                }
                
                onCrosscheck?.let {
                    SourceActionPill(
                        text = stringResource(R.string.notes_source_crosscheck),
                        icon = Icons.Filled.Autorenew,
                        style = SourceActionStyle.Neutral,
                        onClick = it,
                    )
                }
            }
        }
    }
}

private enum class SourceActionStyle { Primary, Neutral }


@Composable
private fun SourceActionPill(
    text: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    style: SourceActionStyle,
    onClick: () -> Unit,
    enabled: Boolean = true,
) {
    val colors = OriveoTheme.colors
    val isPrimary = style == SourceActionStyle.Primary
    val fill = if (isPrimary) colors.primary else colors.surfaceInset
    val fg = if (isPrimary) colors.onPrimary else colors.textSecondary
    Row(
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .clip(CircleShape)
            .background(fill)
            .clickable(enabled = enabled, onClick = onClick)
            .alpha(if (enabled) 1f else 0.5f)
            .padding(horizontal = OriveoTheme.spacing.md, vertical = OriveoTheme.spacing.sm),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            modifier = Modifier.size(16.dp),
            tint = fg,
        )
        Text(
            text = text,
            style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.SemiBold),
            color = fg,
            maxLines = 1,
        )
    }
}


@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MoveFolderSheet(
    folders: List<NoteFolder>,
    currentFolderId: String?,
    onMove: (String?) -> Unit,
    onCreateFolder: () -> Unit,
    onDismiss: () -> Unit,
) {
    val colors = OriveoTheme.colors
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        dragHandle = { OriveoSheetDragHandle() },
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = OriveoTheme.spacing.lg)
                .padding(bottom = OriveoTheme.spacing.xl),
            verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm),
        ) {
            Text(
                text = stringResource(R.string.notes_folders_move_to),
                style = OriveoTheme.typography.title3,
                color = colors.textPrimary,
                modifier = Modifier.padding(vertical = OriveoTheme.spacing.sm),
            )
            MoveFolderRow(
                label = stringResource(R.string.notes_folders_uncategorized),
                selected = currentFolderId == null,
                dot = null,
                onClick = { onMove(null); onDismiss() },
            )
            folders.forEach { folder ->
                MoveFolderRow(
                    label = folder.name,
                    selected = currentFolderId == folder.id,
                    dot = FolderColor.fromTag(folder.colorTag).toColor(),
                    onClick = { onMove(folder.id); onDismiss() },
                )
            }
            TextButton(onClick = { onDismiss(); onCreateFolder() }) {
                Icon(Icons.Outlined.CreateNewFolder, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.size(6.dp))
                Text(stringResource(R.string.notes_folders_new))
            }
        }
    }
}

@Composable
private fun MoveFolderRow(
    label: String,
    selected: Boolean,
    dot: Color?,
    onClick: () -> Unit,
) {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 4.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        if (dot != null) {
            Box(modifier = Modifier.size(10.dp).clip(CircleShape).background(dot))
        } else {
            Icon(Icons.Outlined.Folder, contentDescription = null, modifier = Modifier.size(18.dp), tint = colors.textTertiary)
        }
        Text(text = label, style = OriveoTheme.typography.body, color = colors.textPrimary, modifier = Modifier.weight(1f))
        if (selected) {
            Box(modifier = Modifier.size(8.dp).clip(CircleShape).background(colors.primary))
        }
    }
}


@OptIn(ExperimentalLayoutApi::class)
@Composable
fun FolderNameDialog(
    title: String,
    initialName: String = "",
    showColorPicker: Boolean = false,
    initialColorTag: String = FolderColor.BLUE.tag,
    onConfirm: (String) -> Unit = {},
    onConfirmWithColor: ((String, String) -> Unit)? = null,
    onDismiss: () -> Unit,
) {
    var name by remember { mutableStateOf(initialName) }
    var colorTag by remember { mutableStateOf(initialColorTag) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                OutlinedTextField(
                    value = name,
                    onValueChange = { if (it.length <= 30) name = it },
                    singleLine = true,
                    placeholder = { Text(stringResource(R.string.notes_folders_name)) },
                    modifier = Modifier.fillMaxWidth(),
                )
                if (showColorPicker) {
                    FlowRow(
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                        verticalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        FolderColor.entries.forEach { fc ->
                            Box(
                                modifier = Modifier
                                    .size(36.dp)
                                    .clip(CircleShape)
                                    .background(fc.gradientBrush())
                                    .clickable { colorTag = fc.tag },
                                contentAlignment = Alignment.Center,
                            ) {
                                if (fc.tag == colorTag) {
                                    Icon(
                                        Icons.Filled.Check,
                                        contentDescription = null,
                                        modifier = Modifier.size(16.dp),
                                        tint = Color.White,
                                    )
                                }
                            }
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(
                onClick = {
                    if (onConfirmWithColor != null) onConfirmWithColor(name.trim(), colorTag)
                    else onConfirm(name.trim())
                    onDismiss()
                },
                enabled = name.trim().isNotEmpty(),
            ) { Text(stringResource(R.string.save)) }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) }
        },
    )
}
