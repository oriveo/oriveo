package ai.oriveo.community.feature.notes

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.calculateEndPadding
import androidx.compose.foundation.layout.calculateStartPadding
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.selection.DisableSelection
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.testTag
import androidx.compose.material.icons.filled.ArrowCircleUp
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.History
import androidx.compose.material.icons.outlined.LocalOffer
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.sp
import ai.oriveo.community.ui.component.OriveoBackButton
import ai.oriveo.community.ui.component.markdown.MarkdownBlockRangeView
import ai.oriveo.community.ui.component.markdown.markdownBlockChunks
import ai.oriveo.community.ui.theme.OriveoRadius
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.DriveFileMove
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.IosShare
import androidx.compose.material.icons.outlined.PushPin
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ai.oriveo.community.R
import ai.oriveo.community.core.model.Note
import ai.oriveo.community.core.model.NoteTitleSource
import ai.oriveo.community.ui.theme.providerTintFor
import ai.oriveo.community.ui.component.OriveoEmptyState
import ai.oriveo.community.ui.component.OriveoPrimaryButton
import ai.oriveo.community.feature.chat.crosscheck.CrosscheckSheet
import ai.oriveo.community.ui.component.markdown.MarkdownMessageView
import ai.oriveo.community.ui.theme.OriveoTheme
import kotlinx.coroutines.delay
import org.koin.androidx.compose.koinViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NoteDetailScreen(
    noteID: String,
    onNavigateBack: () -> Unit,
    onNavigateToSource: (conversationId: String, messageId: String?) -> Unit,
    onNavigateToNoteDetail: (noteId: String) -> Unit = {},
    viewModel: NoteDetailViewModel = koinViewModel(),
) {
    val note by viewModel.note.collectAsStateWithLifecycle()
    val folders by viewModel.folders.collectAsStateWithLifecycle()
    val availableTags by viewModel.availableTags.collectAsStateWithLifecycle()
    val context = LocalContext.current
    fun leaveDetail() {
        viewModel.discardEmptyBlankNoteIfNeeded {
            onNavigateBack()
        }
    }
    BackHandler { leaveDetail() }

    LaunchedEffect(Unit) {
        viewModel.navToNoteDetail.collect { id -> onNavigateToNoteDetail(id) }
    }
    val screenH = OriveoTheme.layout.screenH
    val colors = OriveoTheme.colors

    var loadTimedOut by remember(noteID) { mutableStateOf(false) }
    LaunchedEffect(noteID) {
        loadTimedOut = false
        delay(800)
        loadTimedOut = true
    }
    val showNotFound = note == null && loadTimedOut

    var menuExpanded by remember { mutableStateOf(false) }
    var showMoveSheet by remember { mutableStateOf(false) }
    var showCreateFolderDialog by remember { mutableStateOf(false) }
    var showDeleteConfirm by remember { mutableStateOf(false) }

    Box(modifier = Modifier.fillMaxSize()) {
        ai.oriveo.community.ui.theme.OriveoNotesBackground()
        Scaffold(
            containerColor = Color.Transparent,
            topBar = {
                val current = note
                CenterAlignedTopAppBar(
                    colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent),
                    title = {},
                    navigationIcon = {
                        OriveoBackButton(onClick = { leaveDetail() })
                    },
                    actions = {
                        if (current != null && !current.isTrashed) {
                            IconButton(onClick = { viewModel.setPinned(!current.isPinned) }) {
                                Icon(
                                    imageVector = if (current.isPinned) Icons.Filled.PushPin else Icons.Outlined.PushPin,
                                    contentDescription = stringResource(
                                        if (current.isPinned) R.string.notes_action_unpin else R.string.notes_action_pin,
                                    ),
                                    tint = if (current.isPinned) colors.primary else colors.textSecondary,
                                )
                            }
                        }
                        if (current != null) {
                            IconButton(onClick = { menuExpanded = true }) {
                                Icon(Icons.Filled.MoreVert, contentDescription = stringResource(R.string.notes_action_more))
                            }
                            DropdownMenu(expanded = menuExpanded, onDismissRequest = { menuExpanded = false }) {
                                if (!current.isTrashed) {
                                    DropdownMenuItem(
                                        text = { Text(stringResource(R.string.notes_folders_move_to)) },
                                        leadingIcon = { Icon(Icons.AutoMirrored.Outlined.DriveFileMove, contentDescription = null) },
                                        onClick = { menuExpanded = false; showMoveSheet = true },
                                    )
                                }
                                DropdownMenuItem(
                                    text = { Text(stringResource(R.string.notes_action_export)) },
                                    leadingIcon = { Icon(Icons.Outlined.IosShare, contentDescription = null) },
                                    onClick = { menuExpanded = false; viewModel.export(context) },
                                )
                            }
                        }
                    },
                )
            },
        ) { padding ->
            val current = note
            when {
                current != null -> NoteDetailBody(
                    note = current,
                    folderName = folders.firstOrNull { it.id == current.noteFolderID }?.name,
                    availableTags = availableTags,
                    screenH = screenH,
                    contentPadding = padding,
                    onUpdateTitle = viewModel::updateTitle,
                    onUpdateBody = viewModel::updateBody,
                    onAddTag = viewModel::addTag,
                    onRemoveTag = viewModel::removeTag,
                    onReturnToConversation = {
                        current.sourceConversationId?.let { convId ->
                            onNavigateToSource(convId, current.sourceMessageId)
                        }
                    },
                    onCrosscheck = { viewModel.openCrosscheck() },
                    onDeleteClick = { showDeleteConfirm = true },
                    onRestore = viewModel::restore,
                )

                showNotFound -> OriveoEmptyState(
                    icon = Icons.Outlined.Close,
                    title = stringResource(R.string.notes_detail_not_found),
                    description = stringResource(R.string.notes_detail_not_found_description),
                    modifier = Modifier.padding(padding).padding(horizontal = screenH),
                )

                else -> Box(
                    modifier = Modifier.fillMaxSize().padding(padding),
                    contentAlignment = Alignment.Center,
                ) { CircularProgressIndicator(color = colors.primary) }
            }
        }
    }

    if (showMoveSheet) {
        val current = note
        MoveFolderSheet(
            folders = folders,
            currentFolderId = current?.noteFolderID,
            onMove = { folderId -> viewModel.moveToFolder(folderId) },
            onCreateFolder = { showCreateFolderDialog = true },
            onDismiss = { showMoveSheet = false },
        )
    }

    if (showCreateFolderDialog) {
        FolderNameDialog(
            title = stringResource(R.string.notes_folders_new),
            showColorPicker = true,
            onConfirmWithColor = { folderName, colorTag -> viewModel.createFolderAndMoveToIt(folderName, colorTag) },
            onDismiss = { showCreateFolderDialog = false },
        )
    }

    if (showDeleteConfirm) {
        AlertDialog(
            onDismissRequest = { showDeleteConfirm = false },
            title = { Text(stringResource(R.string.notes_delete_title)) },
            text = { Text(stringResource(R.string.notes_delete_message)) },
            confirmButton = {
                TextButton(onClick = {
                    showDeleteConfirm = false
                    viewModel.softDelete(onDone = onNavigateBack)
                }) { Text(stringResource(R.string.delete), color = colors.danger) }
            },
            dismissButton = { TextButton(onClick = { showDeleteConfirm = false }) { Text(stringResource(R.string.cancel)) } },
        )
    }

    if (viewModel.crosscheckActive) {
        val current = note
        val crosscheckState by viewModel.crosscheckState.collectAsStateWithLifecycle()

        val crosscheckProviders by viewModel.providers.collectAsStateWithLifecycle()
        CrosscheckSheet(
            originalAnswer = current?.bodySnapshot?.takeIf { it.isNotBlank() } ?: current?.body.orEmpty(),
            providers = crosscheckProviders,
            options = viewModel.crosscheckOptions(crosscheckProviders),
            state = crosscheckState,
            onRun = viewModel::runCrosscheck,
            onSave = viewModel::saveCrosscheckNote,
            onEnableModel = viewModel::enableModel,
            onDismiss = viewModel::closeCrosscheck,
            sourceProviderKind = current?.sourceProviderKind,
            sourceProviderName = current?.sourceProviderName,
            sourceModelName = current?.sourceModelName,
        )
    }
}

@Composable
internal fun NoteDetailBody(
    note: Note,
    folderName: String?,
    availableTags: List<String>,
    screenH: androidx.compose.ui.unit.Dp,
    contentPadding: androidx.compose.foundation.layout.PaddingValues,
    onUpdateTitle: (String) -> Unit,
    onUpdateBody: (String) -> Unit,
    onAddTag: (String) -> Unit,
    onRemoveTag: (String) -> Unit,
    onReturnToConversation: () -> Unit,
    onCrosscheck: () -> Unit,
    onDeleteClick: () -> Unit,
    onRestore: () -> Unit,
) {
    val colors = colorsOf()
    val editable = !note.isTrashed
    val content = rememberNoteContentState(note)
    val sectionGap = OriveoTheme.spacing.lg
    val layoutDirection = androidx.compose.ui.platform.LocalLayoutDirection.current
    val reading = noteReadingText(note, content)
    val chunks = remember(reading) { reading?.let { markdownBlockChunks(it) }.orEmpty() }
    // Only long bodies are chunked; a note that fits in one chunk keeps the single card (MarkdownMessageView brings its own selection).
    val chunked = !(content.editing && editable) && chunks.size > 1
    val listState = rememberLazyListState()
    val startPadding = contentPadding.calculateStartPadding(layoutDirection) + screenH
    val endPadding = contentPadding.calculateEndPadding(layoutDirection) + screenH
    // The whole page is a LazyColumn: a long body becomes several items and only visible chunks are composed (see [noteContentItems]).
    // Items cannot use an arrangement gap between chunks, so each section carries its own top gap (the old Column's spacedBy(lg)).
    Box(modifier = Modifier.fillMaxSize()) {
        if (chunked) {
            // The card look (shadow / gradient / glow / border) is drawn once under the list, from the top of the first chunk
            // to the bottom of the last; drawing a slice per chunk would leave shadow lines at the seams.
            LongNoteCardUnderlay(listState = listState, chunkCount = chunks.size, startPadding = startPadding, endPadding = endPadding)
        }
        NoteBodySelection(enabled = chunked) {
            LazyColumn(
                state = listState,
                modifier = Modifier.fillMaxSize(),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(
                    start = startPadding,
                    end = endPadding,
                    top = contentPadding.calculateTopPadding(),
                    bottom = contentPadding.calculateBottomPadding() + OriveoTheme.spacing.xl,
                ),
            ) {
                if (note.isTrashed) {
                    plainItem("trash") { TrashBanner() }
                }

                // Hero: source strip + editable title
                plainItem("title") {
                    Box(Modifier.padding(top = if (note.isTrashed) sectionGap else 0.dp)) {
                        NoteTitleSection(note = note, editable = editable, folderName = folderName, onUpdateTitle = onUpdateTitle)
                    }
                }

                // Tags: always visible below the title, even for long bodies.
                plainItem("tags") {
                    Box(Modifier.padding(top = sectionGap)) {
                        NoteTagsSection(
                            note = note,
                            availableTags = availableTags,
                            editable = editable,
                            onAddTag = onAddTag,
                            onRemoveTag = onRemoveTag,
                        )
                    }
                }

                // Source card: back to the conversation + cross-check with another model.
                plainItem("source") {
                    Box(Modifier.padding(top = sectionGap)) {
                        NoteSourceCard(
                            note = note,
                            onReturnToConversation = onReturnToConversation,
                            // Cross-check needs a non-trashed note with a source Q&A and an original model/provider; otherwise the entry is hidden.
                            onCrosscheck = if (note.canCrosscheck) onCrosscheck else null,
                        )
                    }
                }

                noteContentItems(
                    note = note,
                    editable = editable,
                    state = content,
                    reading = reading,
                    chunks = if (chunked) chunks else emptyList(),
                    topGap = sectionGap,
                    onUpdateBody = onUpdateBody,
                )

                // Danger zone / restore (delete is a centered, narrow, soft-red pill: destructive but restrained)
                plainItem("danger") {
                    Box(Modifier.padding(top = sectionGap + OriveoTheme.spacing.md + sectionGap)) {
                        if (note.isTrashed) {
                            OriveoPrimaryButton(text = stringResource(R.string.notes_trash_restore), onClick = onRestore)
                        } else {
                            Box(modifier = Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                                Row(
                                    modifier = Modifier
                                        .clip(RoundedCornerShape(OriveoRadius.full))
                                        .background(colors.dangerSoft)
                                        .clickable(onClick = onDeleteClick)
                                        .padding(horizontal = OriveoTheme.spacing.xl, vertical = OriveoTheme.spacing.md),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                                ) {
                                    Icon(Icons.Outlined.Delete, contentDescription = null, tint = colors.danger, modifier = Modifier.size(16.dp))
                                    Text(
                                        text = stringResource(R.string.notes_detail_delete_this),
                                        style = OriveoTheme.typography.caption.copy(fontWeight = FontWeight.SemiBold),
                                        color = colors.danger,
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/** Page-level section header: brand-colored icon on the left + bold title (the icon is the visual anchor). */
@Composable
private fun NoteSectionHeader(
    title: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    modifier: Modifier = Modifier,
) {
    val colors = colorsOf()
    Row(modifier = modifier, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(7.dp)) {
        Icon(icon, contentDescription = null, tint = colors.primary, modifier = Modifier.size(16.dp))
        Text(
            text = title,
            style = OriveoTheme.typography.title2.copy(fontSize = 19.sp, fontWeight = FontWeight.Bold),
            color = colors.textPrimary,
        )
    }
}

internal fun stripStandaloneRules(text: String): String {
    val kept = text.split("\n").filter { line ->
        val t = line.trim()
        if (t.length < 3) return@filter true
        val first = t.first()
        !((first == '-' || first == '*' || first == '_') && t.all { it == first })
    }
    var result = kept.joinToString("\n")
    while (result.contains("\n\n\n")) {
        result = result.replace("\n\n\n", "\n\n")
    }
    return result.trim()
}

internal fun noteIsCrosscheckDetail(body: String, snapshot: String?): Boolean =
    !snapshot.isNullOrBlank() && body.contains("\n## Cross-check")

internal fun noteHasSecondaryPane(body: String, snapshot: String?): Boolean =
    !snapshot.isNullOrBlank() && snapshot != body

internal fun notePrimaryDetailText(body: String, snapshot: String?): String {
    if (!noteIsCrosscheckDetail(body, snapshot)) return body
    val lines = body.split("\n")
    val index = lines.indexOfFirst { it.startsWith("## Cross-check") }
    if (index < 0) return body
    return lines.drop(index + 1).joinToString("\n").trim()
}

@Composable
private fun TrashBanner() {
    val colors = colorsOf()
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .background(colors.warningSoft, RoundedCornerShape(10.dp))
            .padding(horizontal = 12.dp, vertical = 8.dp),
    ) {
        Text(
            text = stringResource(R.string.notes_detail_in_trash),
            style = OriveoTheme.typography.caption,
            color = colors.textPrimary,
        )
    }
}

@Composable
private fun NoteTitleSection(
    note: Note,
    editable: Boolean,
    folderName: String?,
    onUpdateTitle: (String) -> Unit,
) {
    val colors = colorsOf()
    val untitled = stringResource(R.string.notes_untitled)
    var editing by remember(note.id) { mutableStateOf(false) }
    var draft by remember(note.id) { mutableStateOf(note.title) }

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {

        val date = rememberFormattedNoteDate(note.createdAt)
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (note.showsBadge()) {
                NoteSourceBadge(note)
            } else if (!folderName.isNullOrBlank()) {

                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    Icon(Icons.Outlined.Folder, contentDescription = null, modifier = Modifier.size(14.dp), tint = colors.textTertiary)
                    Text(folderName, style = OriveoTheme.typography.footnote, color = colors.textTertiary, maxLines = 1)
                }
            }
            Spacer(Modifier.weight(1f))
            if (date.isNotBlank()) {
                Text(
                    text = date,
                    style = OriveoTheme.typography.footnote,
                    color = colors.textTertiary,
                    maxLines = 1,
                )
            }
        }
        if (editing && editable) {
            OutlinedTextField(
                value = draft,
                onValueChange = { draft = it },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TextButton(onClick = { onUpdateTitle(draft); editing = false }) {
                    Text(stringResource(R.string.save))
                }
                TextButton(onClick = { draft = note.title; editing = false }) {
                    Text(stringResource(R.string.cancel))
                }
            }
        } else {
            Text(
                text = note.title.ifBlank { untitled },
                style = OriveoTheme.typography.title1.copy(fontSize = 26.sp, lineHeight = 32.sp, fontWeight = FontWeight.ExtraBold),
                color = colors.textPrimary,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier
                    .fillMaxWidth()
                    .then(if (editable) Modifier.clickable { draft = note.title; editing = true } else Modifier),
            )
            if (editable && note.titleSource == NoteTitleSource.Placeholder) {
                Text(
                    text = stringResource(R.string.notes_detail_placeholder_title),
                    style = OriveoTheme.typography.footnote,
                    color = colors.textTertiary,
                )
            }
        }
    }
}

/** Local interaction state of the body (which pane / editing / draft), hoisted to page level so the body can be split into several LazyColumn items. */
private class NoteContentState(note: Note) {
    var selected by mutableStateOf(0)
    var editing by mutableStateOf(false)
    var draft by mutableStateOf(note.body)
}

@Composable
private fun rememberNoteContentState(note: Note): NoteContentState = remember(note.id) { NoteContentState(note) }

/** Text of the reading surface; null while editing or when the body is empty. */
@Composable
private fun noteReadingText(note: Note, state: NoteContentState): String? {
    val text = if (state.selected == 1) note.bodySnapshot.orEmpty() else notePrimaryDetailText(note.body, note.bodySnapshot)
    return remember(text) { text.takeIf { it.isNotBlank() }?.let(::stripStandaloneRules) }
}

/** Items outside the body: when a long body is chunked the whole page sits in one selection container, and these items stay unselectable as before. */
private fun LazyListScope.plainItem(key: String, content: @Composable () -> Unit) {
    item(key) { DisableSelection { content() } }
}

/**
 * When a long body is chunked, wraps the whole page in one [SelectionContainer] so a selection can span chunks
 * (the chunks themselves no longer wrap their own). Without chunking nothing is wrapped; the card's MarkdownMessageView has its own selection.
 */
@Composable
private fun NoteBodySelection(enabled: Boolean, content: @Composable () -> Unit) {
    if (enabled) SelectionContainer { content() } else content()
}

internal fun noteContentChunkKey(index: Int): String = "content-chunk-$index"

/** Vertical extent of the long-body card inside the list viewport (container coordinates, px). */
internal data class LongNoteCardSpan(val top: Int, val bottom: Int)

/**
 * Computes the card extent from the visible items: the top of the first chunk if visible, the bottom of the last chunk if visible;
 * an invisible end extends [overscanPx] beyond the viewport so corners and shadow stay off screen. No chunk visible -> null (draw nothing).
 * Each [visible] entry is (key, top, bottom) in container coordinates.
 */
internal fun longNoteCardSpan(
    visible: List<Triple<Any, Int, Int>>,
    chunkCount: Int,
    viewportHeight: Int,
    overscanPx: Int,
): LongNoteCardSpan? {
    if (chunkCount <= 0) return null
    val chunkKeys = (0 until chunkCount).map(::noteContentChunkKey).toSet()
    val chunks = visible.filter { it.first in chunkKeys }
    if (chunks.isEmpty()) return null
    val first = chunks.firstOrNull { it.first == noteContentChunkKey(0) }
    val last = chunks.firstOrNull { it.first == noteContentChunkKey(chunkCount - 1) }
    return LongNoteCardSpan(
        top = first?.second ?: -overscanPx,
        bottom = last?.third ?: (viewportHeight + overscanPx),
    )
}

/**
 * The single layer of card look for a long body: the same [brandImmersiveCard] as the short-note card,
 * placed under the list by [longNoteCardSpan]. layoutInfo is read only in the layout phase, so scrolling re-places without recomposing.
 */
@Composable
private fun LongNoteCardUnderlay(
    listState: LazyListState,
    chunkCount: Int,
    startPadding: androidx.compose.ui.unit.Dp,
    endPadding: androidx.compose.ui.unit.Dp,
) {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .layout { measurable, constraints ->
                val info = listState.layoutInfo
                val visible = info.visibleItemsInfo.map { item ->
                    val top = item.offset - info.viewportStartOffset
                    Triple(item.key, top, top + item.size)
                }
                val span = longNoteCardSpan(
                    visible = visible,
                    chunkCount = chunkCount,
                    viewportHeight = constraints.maxHeight,
                    overscanPx = 200.dp.roundToPx(),
                )
                val left = startPadding.roundToPx()
                val width = (constraints.maxWidth - left - endPadding.roundToPx()).coerceAtLeast(0)
                if (span == null || width == 0) {
                    layout(constraints.maxWidth, constraints.maxHeight) {}
                } else {
                    val placeable = measurable.measure(
                        androidx.compose.ui.unit.Constraints.fixed(width, (span.bottom - span.top).coerceAtLeast(0)),
                    )
                    layout(constraints.maxWidth, constraints.maxHeight) { placeable.place(left, span.top) }
                }
            }
            .testTag(LONG_NOTE_CARD_UNDERLAY_TAG)
            .brandImmersiveCard(OriveoRadius.card),
    )
}

internal const val LONG_NOTE_CARD_UNDERLAY_TAG = "note_long_card_underlay"

@OptIn(ExperimentalMaterial3Api::class)
private fun LazyListScope.noteContentItems(
    note: Note,
    editable: Boolean,
    state: NoteContentState,
    reading: String?,
    chunks: List<IntRange>,
    topGap: androidx.compose.ui.unit.Dp,
    onUpdateBody: (String) -> Unit,
) {
    val hasSecondary = noteHasSecondaryPane(note.body, note.bodySnapshot)
    val text = if (state.selected == 1) note.bodySnapshot.orEmpty() else notePrimaryDetailText(note.body, note.bodySnapshot)
    val innerGap = 12.dp

    if (hasSecondary) {
        plainItem("content-panes") {
            val panes = listOf(
                stringResource(if (noteIsCrosscheckDetail(note.body, note.bodySnapshot)) R.string.notes_source_crosscheck else R.string.notes_detail_body),
                stringResource(R.string.notes_detail_snapshot),
            )
            SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth().padding(top = topGap)) {
                panes.forEachIndexed { index, label ->
                    SegmentedButton(
                        selected = state.selected == index,
                        onClick = { if (!state.editing) state.selected = index },
                        enabled = !state.editing,
                        shape = SegmentedButtonDefaults.itemShape(index = index, count = panes.size),
                        label = {
                            Text(
                                text = label,
                                style = OriveoTheme.typography.footnote,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        },
                    )
                }
            }
        }
    }
    val bodyTop = if (hasSecondary) innerGap else topGap

    if (state.editing && editable) {
        plainItem("content-editor") {
            OutlinedTextField(
                value = state.draft,
                onValueChange = { state.draft = it },
                modifier = Modifier.fillMaxWidth().padding(top = bodyTop).heightIn(min = 260.dp, max = 420.dp),
                textStyle = OriveoTheme.typography.chatBody,
            )
        }
    } else if (text.isBlank()) {
        plainItem("content-empty") {
            Text(
                text = stringResource(R.string.notes_nothing_written),
                style = OriveoTheme.typography.caption,
                color = colorsOf().textTertiary,
                modifier = Modifier.padding(top = bodyTop + 6.dp),
            )
        }
    } else {
        // Brand immersive card hugging the body height and scrolling with the page (no inner scroll view / fixed height).
        // A long body is split by blocks into several items; putting the whole body into a non-lazy Column
        // makes the first frame cost grow linearly with length. A note that fits one chunk keeps the single card.
        val readingText = reading.orEmpty()
        if (chunks.isEmpty()) {
            plainItem("content-card") {
                Column(
                    modifier = Modifier
                        .padding(top = bodyTop)
                        .fillMaxWidth()
                        .brandImmersiveCard(OriveoRadius.card)
                        .padding(horizontal = 22.dp, vertical = 26.dp),
                    verticalArrangement = Arrangement.spacedBy(30.dp),
                ) {
                    MarkdownMessageView(
                        text = readingText,
                        modifier = Modifier.fillMaxWidth(),
                        emphasizedHeadings = true,
                    )
                    NoteColophon(note)
                }
            }
        } else {
            // The gap above the card is its own item so the top of the first chunk is the top of the card (LongNoteCardUnderlay places the card by it).
            plainItem("content-gap") { Spacer(Modifier.height(bodyTop)) }
            itemsIndexed(chunks, key = { index, _ -> noteContentChunkKey(index) }) { index, range ->
                val first = index == 0
                val last = index == chunks.lastIndex
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .testTag(noteContentChunkKey(index))
                        .padding(
                            start = 22.dp,
                            end = 22.dp,
                            top = if (first) 26.dp else 0.dp,
                            bottom = if (last) 26.dp else 0.dp,
                        ),
                    verticalArrangement = Arrangement.spacedBy(30.dp),
                ) {
                    // Selection comes from the page-level NoteBodySelection; wrapping each chunk would prevent cross-chunk selection.
                    MarkdownBlockRangeView(
                        text = readingText,
                        blockRange = range,
                        modifier = Modifier.fillMaxWidth(),
                        emphasizedHeadings = true,
                        selectable = false,
                    )
                    if (last) DisableSelection { NoteColophon(note) }
                }
            }
        }
    }

    if (editable && state.selected == 0) {
        plainItem("content-actions") {
            Row(
                modifier = Modifier.fillMaxWidth().padding(top = innerGap),
                horizontalArrangement = Arrangement.End,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                val colors = colorsOf()
                if (state.editing) {
                    TextButton(onClick = { state.draft = note.body; state.editing = false }) {
                        Icon(Icons.Outlined.Close, contentDescription = null, modifier = Modifier.size(15.dp))
                        Spacer(Modifier.size(4.dp))
                        Text(stringResource(R.string.cancel))
                    }
                    TextButton(onClick = { onUpdateBody(state.draft); state.editing = false }) {
                        Text(stringResource(R.string.save), color = colors.primary)
                    }
                } else {
                    TextButton(onClick = { state.draft = note.body; state.editing = true }) {
                        Icon(Icons.Outlined.Edit, contentDescription = null, modifier = Modifier.size(16.dp), tint = colors.textSecondary)
                        Spacer(Modifier.size(4.dp))
                        Text(stringResource(R.string.edit), color = colors.textSecondary)
                    }
                }
            }
        }
    }
}

@Composable
private fun Modifier.brandImmersiveCard(radius: androidx.compose.ui.unit.Dp): Modifier {
    val isDark = OriveoTheme.isDark
    val primary = OriveoTheme.colors.primary
    val shadowColor = OriveoTheme.colors.shadow
    val shape = RoundedCornerShape(radius)
    // The dark card face follows the current palette: surface -> surfaceElevated
    val gradientTop = if (isDark) OriveoTheme.colors.surface else Color(0xFFFFFFFF)
    val gradientBottom = if (isDark) OriveoTheme.colors.surfaceElevated else Color(0xFFF1EBFD)

    val topHighlight = if (isDark) Color.White.copy(alpha = 0.04f) else Color.White.copy(alpha = 0.275f)
    return this

        .shadow(
            elevation = if (isDark) 24.dp else 16.dp,
            shape = shape,
            clip = false,
            ambientColor = primary.copy(alpha = 0.10f),
            spotColor = primary.copy(alpha = 0.10f),
        )
        .shadow(
            elevation = if (isDark) 14.dp else 8.dp,
            shape = shape,
            clip = false,
            ambientColor = shadowColor,
            spotColor = shadowColor,
        )
        .clip(shape)
        .drawWithCache {
            val glowRadius = 240.dp.toPx()
            val highlightHeight = 60.dp.toPx()
            val base = Brush.verticalGradient(listOf(gradientTop, gradientBottom))

            val glow = Brush.radialGradient(
                colors = listOf(primary.copy(alpha = 0.12f), Color.Transparent),
                center = Offset(size.width, 0f),
                radius = glowRadius,
            )

            val highlight = Brush.verticalGradient(
                colors = listOf(topHighlight, Color.Transparent),
                startY = 0f,
                endY = highlightHeight,
            )
            onDrawBehind {
                drawRect(base)
                drawRect(glow)
                drawRect(brush = highlight, size = Size(size.width, highlightHeight))
            }
        }
        .border(1.dp, primary.copy(alpha = 0.12f), shape)
}

@Composable
private fun NoteColophon(note: Note) {
    val colors = colorsOf()
    val diamond = (note.sourceProviderKind?.let { providerTintFor(it.rawValue) } ?: colors.primary)
        .copy(alpha = 0.55f)
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.width(28.dp).height(1.dp).background(colors.border))
        Spacer(Modifier.width(12.dp))
        Canvas(modifier = Modifier.size(6.dp)) {
            val path = Path().apply {
                moveTo(size.width / 2f, 0f)
                lineTo(size.width, size.height / 2f)
                lineTo(size.width / 2f, size.height)
                lineTo(0f, size.height / 2f)
                close()
            }
            drawPath(path, color = diamond)
        }
        Spacer(Modifier.width(12.dp))
        Box(Modifier.width(28.dp).height(1.dp).background(colors.border))
    }
}

@OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
@Composable
private fun NoteTagsSection(
    note: Note,
    availableTags: List<String>,
    editable: Boolean,
    onAddTag: (String) -> Unit,
    onRemoveTag: (String) -> Unit,
) {
    var draft by remember { mutableStateOf("") }
    var showEditor by remember(note.id) { mutableStateOf(false) }
    val brand = note.sourceProviderKind?.let { providerTintFor(it.rawValue) } ?: colorsOf().primary
    val hasSource = note.showsBadge()
    val needle = draft.trim().lowercase()
    val existing = remember(note.tags) { note.tags.map { it.trim().lowercase() }.filter { it.isNotEmpty() }.toSet() }
    val suggestions = remember(availableTags, existing, needle) {
        availableTags.asSequence()
            .map { it.trim() }
            .filter { it.isNotEmpty() && it.lowercase() !in existing }
            .distinctBy { it.lowercase() }
            .filter { needle.isEmpty() || it.lowercase().contains(needle) }
            .take(12)
            .toList()
    }
    fun submit(value: String = draft) {
        val clean = value.trim()
        if (clean.isNotEmpty()) {
            onAddTag(clean)
            draft = ""
            showEditor = false
        }
    }

    if (note.tags.isNotEmpty() || editable) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                note.tags.forEach { tag ->
                    InlineTagChip(
                        tag = tag,
                        brand = brand,
                        hasSource = hasSource,
                        editable = editable,
                        onRemove = { onRemoveTag(tag) },
                    )
                }
                if (editable && !showEditor) {
                    val isDark = OriveoTheme.isDark

                    val addTint = if (isDark) Color(0xFFB4BAC6) else Color(0xFF52525B)
                    Row(
                        modifier = Modifier
                            .clip(RoundedCornerShape(OriveoRadius.full))
                            .background(if (isDark) OriveoTheme.colors.surfaceElevated else Color(0xFFF0F1F4))
                            .border(
                                1.dp,
                                if (isDark) Color.White.copy(alpha = 0.10f) else Color.Black.copy(alpha = 0.08f),
                                RoundedCornerShape(OriveoRadius.full),
                            )
                            .clickable { showEditor = true }
                            .padding(horizontal = 10.dp, vertical = 7.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        Icon(Icons.Outlined.Add, contentDescription = null, tint = addTint, modifier = Modifier.size(13.dp))
                        Text(
                            text = stringResource(R.string.notes_tags_add),
                            style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.SemiBold),
                            color = addTint,
                            maxLines = 1,
                        )
                    }
                }
            }

            if (editable && showEditor) {
                TagInputRow(draft = draft, onDraftChange = { draft = it }, onSubmit = { submit() })
                if (suggestions.isNotEmpty()) {
                    androidx.compose.foundation.layout.FlowRow(
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        suggestions.forEach { tag ->
                            TagSuggestionChip(tag = tag, brand = brand, hasSource = hasSource, onClick = { submit(tag) })
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun InlineTagChip(tag: String, brand: Color, hasSource: Boolean, editable: Boolean, onRemove: () -> Unit) =
    NoteTagChip(
        tag = tag,
        brand = brand,
        hasSource = hasSource,
        onRemove = if (editable) onRemove else null,
    )

@Composable
private fun TagInputRow(
    draft: String,
    onDraftChange: (String) -> Unit,
    onSubmit: () -> Unit,
) {
    val colors = colorsOf()
    val canAdd = draft.trim().isNotEmpty()
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(OriveoRadius.inset))
            .background(colors.surfaceInset)
            .padding(horizontal = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        BasicTextField(
            value = draft,
            onValueChange = onDraftChange,
            singleLine = true,
            textStyle = OriveoTheme.typography.body.copy(color = colors.textPrimary),
            cursorBrush = SolidColor(colors.primary),
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(onDone = { onSubmit() }),
            modifier = Modifier.weight(1f).padding(vertical = 14.dp),
            decorationBox = { inner ->
                if (draft.isEmpty()) {
                    Text(
                        text = stringResource(R.string.notes_tags_add),
                        style = OriveoTheme.typography.body,
                        color = colors.textTertiary,
                    )
                }
                inner()
            },
        )
        IconButton(onClick = onSubmit, enabled = canAdd, modifier = Modifier.size(36.dp)) {
            Icon(
                imageVector = Icons.Filled.ArrowCircleUp,
                contentDescription = stringResource(R.string.notes_tags_add),
                tint = if (canAdd) colors.primary else colors.textTertiary,
                modifier = Modifier.size(24.dp),
            )
        }
    }
}

@Composable
private fun TagSuggestionChip(tag: String, brand: Color, hasSource: Boolean, onClick: () -> Unit) =
    NoteTagChip(
        tag = tag,
        brand = brand,
        hasSource = hasSource,
        role = NoteTagChipRole.Suggestion,
        onClick = onClick,
    )

@Composable
private fun colorsOf() = OriveoTheme.colors
