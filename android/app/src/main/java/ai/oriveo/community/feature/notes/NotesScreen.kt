package ai.oriveo.community.feature.notes

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.StickyNote2
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.CreateNewFolder
import androidx.compose.material.icons.outlined.DeleteOutline
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.KeyboardArrowDown
import androidx.compose.material.icons.outlined.Search
import androidx.compose.foundation.border
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ai.oriveo.community.R
import ai.oriveo.community.core.model.Note
import ai.oriveo.community.core.notes.NoteSort
import ai.oriveo.community.feature.home.HOME_HEADER_ACTION_BUTTON_SIZE_DP
import ai.oriveo.community.feature.home.HOME_HEADER_ACTION_ICON_SIZE_DP
import ai.oriveo.community.ui.component.OriveoEmptyState
import ai.oriveo.community.ui.theme.OriveoBorderWidth
import ai.oriveo.community.ui.theme.OriveoRadius
import ai.oriveo.community.ui.theme.OriveoTheme
import org.koin.androidx.compose.koinViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NotesScreen(
    onNavigateBack: () -> Unit,
    onNavigateToNoteDetail: (String) -> Unit,
    viewModel: NotesViewModel = koinViewModel(),
) {
    val notes by viewModel.displayedNotes.collectAsStateWithLifecycle()
    val trashedNotes by viewModel.trashedNotes.collectAsStateWithLifecycle()
    val displayedTrash by viewModel.displayedTrash.collectAsStateWithLifecycle()
    val folders by viewModel.folders.collectAsStateWithLifecycle()
    val availableTags by viewModel.availableTags.collectAsStateWithLifecycle()
    val selectedTags by viewModel.selectedTags.collectAsStateWithLifecycle()
    val selectedFolderId by viewModel.selectedFolderId.collectAsStateWithLifecycle()
    val sort by viewModel.sort.collectAsStateWithLifecycle()
    val query by viewModel.query.collectAsStateWithLifecycle()
    val syncEnabled by viewModel.syncEnabled.collectAsStateWithLifecycle()
    val syncUpsellDismissed by viewModel.syncUpsellDismissed.collectAsStateWithLifecycle()
    val uncategorizedCount by viewModel.uncategorizedCount.collectAsStateWithLifecycle()
    val folderCounts by viewModel.folderNoteCounts.collectAsStateWithLifecycle()
    val tab = viewModel.tab
    val visibleCount = viewModel.visibleCount
    val screenH = OriveoTheme.layout.screenH
    val colors = OriveoTheme.colors

    var notePendingDelete by remember { mutableStateOf<Note?>(null) }
    var notePendingPermanentDelete by remember { mutableStateOf<Note?>(null) }
    var noteToMove by remember { mutableStateOf<Note?>(null) }
    var showNewFolderDialog by remember { mutableStateOf(false) }
    var showEmptyTrashConfirm by remember { mutableStateOf(false) }
    var folderToManage by remember { mutableStateOf<ai.oriveo.community.core.model.NoteFolder?>(null) }
    var folderToEdit by remember { mutableStateOf<ai.oriveo.community.core.model.NoteFolder?>(null) }
    var folderToDelete by remember { mutableStateOf<ai.oriveo.community.core.model.NoteFolder?>(null) }

    Box(modifier = Modifier.fillMaxSize()) {
        ai.oriveo.community.ui.theme.OriveoNotesBackground()
        Scaffold(
            containerColor = Color.Transparent,
        ) { padding ->
            Column(modifier = Modifier.fillMaxSize().padding(padding)) {
                
                
                NotesHeader(
                    onNavigateBack = onNavigateBack,
                    onNewFolder = { showNewFolderDialog = true },
                    onNewNote = { viewModel.createBlankNote(onNavigateToNoteDetail) },
                    modifier = Modifier.padding(horizontal = screenH),
                )
                
                NotesTabRow(
                    tab = tab,
                    onSelect = viewModel::selectTab,
                    trashCount = trashedNotes.size,
                    modifier = Modifier.padding(horizontal = screenH, vertical = OriveoTheme.spacing.sm),
                )
                
                
                NotesSearchField(
                    query = query,
                    onQueryChange = viewModel::setQuery,
                    modifier = Modifier
                        .padding(horizontal = screenH)
                        .padding(bottom = OriveoTheme.spacing.sm),
                )
                when (tab) {
                    NotesViewModel.Tab.Notes -> NotesListContent(
                        notes = notes,
                        visibleCount = visibleCount,
                        folders = folders,
                        availableTags = availableTags,
                        selectedTags = selectedTags,
                        selectedFolderId = selectedFolderId,
                        sort = sort,
                        folderCounts = folderCounts,
                        uncategorizedCount = uncategorizedCount,
                        screenH = screenH,
                        onSelectFolder = viewModel::selectFolder,
                        onFolderManage = { folderToManage = it },
                        onToggleTag = viewModel::toggleTag,
                        onSetSort = viewModel::setSort,
                        onShowMore = viewModel::showMore,
                        onNoteClick = onNavigateToNoteDetail,
                        onNoteTogglePin = { viewModel.setPinned(it.id, !it.isPinned) },
                        onNoteMove = { noteToMove = it },
                        onNoteDelete = { notePendingDelete = it },
                        onCreateBlank = { viewModel.createBlankNote(onNavigateToNoteDetail) },
                    )

                    NotesViewModel.Tab.Trash -> TrashListContent(
                        trashedNotes = displayedTrash,
                        hasAnyTrash = trashedNotes.isNotEmpty(),
                        screenH = screenH,
                        onEmptyTrash = { showEmptyTrashConfirm = true },
                        onNoteClick = onNavigateToNoteDetail,
                        onRestore = viewModel::restoreNote,
                        onDeletePermanently = { notePendingPermanentDelete = it },
                    )
                }
            }
        }
    }

    notePendingDelete?.let { note ->
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { notePendingDelete = null },
            title = { Text(stringResource(R.string.notes_delete_title)) },
            text = { Text(stringResource(R.string.notes_delete_message)) },
            confirmButton = {
                TextButton(onClick = {
                    viewModel.softDeleteNote(note.id)
                    notePendingDelete = null
                }) { Text(stringResource(R.string.delete), color = colors.danger) }
            },
            dismissButton = {
                TextButton(onClick = { notePendingDelete = null }) { Text(stringResource(R.string.cancel)) }
            },
        )
    }

    notePendingPermanentDelete?.let { note ->
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { notePendingPermanentDelete = null },
            title = { Text(stringResource(R.string.notes_trash_delete_permanently)) },
            text = { Text(stringResource(R.string.notes_trash_delete_permanently_message)) },
            confirmButton = {
                TextButton(onClick = {
                    viewModel.permanentlyDeleteNote(note.id)
                    notePendingPermanentDelete = null
                }) { Text(stringResource(R.string.notes_trash_delete_permanently), color = colors.danger) }
            },
            dismissButton = {
                TextButton(onClick = { notePendingPermanentDelete = null }) { Text(stringResource(R.string.cancel)) }
            },
        )
    }

    if (showEmptyTrashConfirm) {
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { showEmptyTrashConfirm = false },
            title = { Text(stringResource(R.string.notes_trash_empty_confirm_title)) },
            text = { Text(stringResource(R.string.notes_trash_empty_confirm_message)) },
            confirmButton = {
                TextButton(onClick = {
                    viewModel.emptyTrash()
                    showEmptyTrashConfirm = false
                }) { Text(stringResource(R.string.notes_trash_empty), color = colors.danger) }
            },
            dismissButton = {
                TextButton(onClick = { showEmptyTrashConfirm = false }) { Text(stringResource(R.string.cancel)) }
            },
        )
    }

    if (showNewFolderDialog) {
        FolderNameDialog(
            title = stringResource(R.string.notes_folders_new),
            showColorPicker = true,
            onConfirmWithColor = { folderName, colorTag -> viewModel.createFolder(folderName, colorTag) },
            onDismiss = { showNewFolderDialog = false },
        )
    }

    
    folderToManage?.let { folder ->
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { folderToManage = null },
            title = { Text(folder.name) },
            text = {
                Column {
                    TextButton(
                        onClick = { folderToEdit = folder; folderToManage = null },
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Icon(Icons.Outlined.Edit, contentDescription = null, modifier = Modifier.size(20.dp))
                        Spacer(Modifier.size(12.dp))
                        Text(stringResource(R.string.notes_folders_edit), modifier = Modifier.weight(1f))
                    }
                    TextButton(
                        onClick = { folderToDelete = folder; folderToManage = null },
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Icon(Icons.Outlined.DeleteOutline, contentDescription = null, tint = colors.danger, modifier = Modifier.size(20.dp))
                        Spacer(Modifier.size(12.dp))
                        Text(stringResource(R.string.notes_folders_delete), color = colors.danger, modifier = Modifier.weight(1f))
                    }
                }
            },
            confirmButton = {},
            dismissButton = {
                TextButton(onClick = { folderToManage = null }) { Text(stringResource(R.string.cancel)) }
            },
        )
    }

    folderToEdit?.let { folder ->
        FolderNameDialog(
            title = stringResource(R.string.notes_folders_edit),
            initialName = folder.name,
            showColorPicker = true,
            initialColorTag = folder.colorTag ?: ai.oriveo.community.core.model.FolderColor.BLUE.tag,
            onConfirmWithColor = { name, colorTag ->
                viewModel.renameFolder(folder.id, name)
                viewModel.setFolderColor(folder.id, colorTag)
            },
            onDismiss = { folderToEdit = null },
        )
    }

    folderToDelete?.let { folder ->
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { folderToDelete = null },
            title = { Text(stringResource(R.string.notes_folders_delete)) },
            text = { Text(stringResource(R.string.notes_folders_delete_message, folder.name)) },
            confirmButton = {
                TextButton(onClick = {
                    viewModel.deleteFolder(folder.id)
                    folderToDelete = null
                }) { Text(stringResource(R.string.notes_folders_delete), color = colors.danger) }
            },
            dismissButton = {
                TextButton(onClick = { folderToDelete = null }) { Text(stringResource(R.string.cancel)) }
            },
        )
    }

    noteToMove?.let { note ->
        MoveFolderSheet(
            folders = folders,
            currentFolderId = note.noteFolderID,
            onMove = { folderId -> viewModel.moveNoteToFolder(note.id, folderId) },
            onCreateFolder = { showNewFolderDialog = true },
            onDismiss = { noteToMove = null },
        )
    }
}


@Composable
private fun NotesHeader(
    onNavigateBack: () -> Unit,
    onNewFolder: () -> Unit,
    onNewNote: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(top = OriveoTheme.spacing.xs),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClick = onNavigateBack, modifier = Modifier.size(HOME_HEADER_ACTION_BUTTON_SIZE_DP.dp)) {
            Icon(
                Icons.AutoMirrored.Outlined.ArrowBack,
                contentDescription = stringResource(R.string.back),
                modifier = Modifier.size(HOME_HEADER_ACTION_ICON_SIZE_DP.dp),
                tint = colors.textSecondary,
            )
        }
        Spacer(Modifier.size(OriveoTheme.spacing.xs))
        
        Box(
            modifier = Modifier
                .size(36.dp)
                .clip(RoundedCornerShape(OriveoRadius.chip))
                .background(colors.primary),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                
                painter = painterResource(R.drawable.ic_notes_notebook),
                contentDescription = null,
                tint = Color.White,
                modifier = Modifier.size(18.dp),
            )
        }
        Spacer(Modifier.size(OriveoTheme.spacing.sm))
        Text(
            text = stringResource(R.string.notes_title),
            fontSize = 26.sp,
            fontWeight = FontWeight.Bold,
            color = colors.textPrimary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        IconButton(onClick = onNewFolder, modifier = Modifier.size(HOME_HEADER_ACTION_BUTTON_SIZE_DP.dp)) {
            Icon(
                Icons.Outlined.CreateNewFolder,
                contentDescription = stringResource(R.string.notes_folders_new),
                modifier = Modifier.size(HOME_HEADER_ACTION_ICON_SIZE_DP.dp),
                tint = colors.textSecondary,
            )
        }
        IconButton(onClick = onNewNote, modifier = Modifier.size(HOME_HEADER_ACTION_BUTTON_SIZE_DP.dp)) {
            Icon(
                Icons.Outlined.Add,
                contentDescription = stringResource(R.string.notes_action_new_blank),
                modifier = Modifier.size(HOME_HEADER_ACTION_ICON_SIZE_DP.dp),
                tint = colors.textSecondary,
            )
        }
    }
}


@Composable
private fun NotesSearchField(
    query: String,
    onQueryChange: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    val shape = RoundedCornerShape(OriveoRadius.chip)
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clip(shape)
            .background(colors.surface)
            .border(OriveoBorderWidth.standard, colors.border, shape)
            .padding(horizontal = OriveoTheme.spacing.md, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            imageVector = Icons.Outlined.Search,
            contentDescription = null,
            modifier = Modifier.size(18.dp),
            tint = colors.textTertiary,
        )
        Spacer(Modifier.size(OriveoTheme.spacing.sm))
        BasicTextField(
            value = query,
            onValueChange = onQueryChange,
            modifier = Modifier.weight(1f),
            singleLine = true,
            textStyle = OriveoTheme.typography.body.copy(color = colors.textPrimary),
            cursorBrush = SolidColor(colors.primary),
            decorationBox = { innerTextField ->
                Box(contentAlignment = Alignment.CenterStart) {
                    if (query.isEmpty()) {
                        Text(
                            text = stringResource(R.string.notes_search_placeholder),
                            style = OriveoTheme.typography.body,
                            color = colors.textTertiary,
                        )
                    }
                    innerTextField()
                }
            },
        )
        if (query.isNotEmpty()) {
            Spacer(Modifier.size(OriveoTheme.spacing.xs))
            Box(
                modifier = Modifier
                    .size(20.dp)
                    .clip(RoundedCornerShape(999.dp))
                    .background(colors.textTertiary.copy(alpha = 0.2f))
                    .clickable { onQueryChange("") },
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = Icons.Outlined.Close,
                    contentDescription = stringResource(R.string.notes_search_clear),
                    modifier = Modifier.size(12.dp),
                    tint = colors.textSecondary,
                )
            }
        }
    }
}

@Composable
private fun NotesTabRow(
    tab: NotesViewModel.Tab,
    onSelect: (NotesViewModel.Tab) -> Unit,
    trashCount: Int,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    
    
    val trackColor = if (OriveoTheme.isDark) colors.surfaceChrome else colors.border
    Row(
        modifier = modifier
            .background(trackColor, RoundedCornerShape(999.dp))
            .padding(3.dp),
        horizontalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        NotesTab(
            label = stringResource(R.string.notes_tab_notes),
            selected = tab == NotesViewModel.Tab.Notes,
            onClick = { onSelect(NotesViewModel.Tab.Notes) },
            modifier = Modifier.weight(1f),
        )
        NotesTab(
            label = stringResource(R.string.notes_tab_trash).let {
                if (trashCount > 0) "$it ($trashCount)" else it
            },
            selected = tab == NotesViewModel.Tab.Trash,
            onClick = { onSelect(NotesViewModel.Tab.Trash) },
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun NotesTab(
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    Box(
        modifier = modifier
            
            .then(if (selected) Modifier.shadow(3.dp, RoundedCornerShape(999.dp), clip = false) else Modifier)
            .clip(RoundedCornerShape(999.dp))
            .background(if (selected) colors.surfaceElevated else Color.Transparent)
            .clickable(onClick = onClick)
            .padding(vertical = 8.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = label,
            style = OriveoTheme.typography.caption,
            color = if (selected) colors.textPrimary else colors.textSecondary,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
        )
    }
}

@Composable
private fun NotesListContent(
    notes: List<Note>,
    visibleCount: Int,
    folders: List<ai.oriveo.community.core.model.NoteFolder>,
    availableTags: List<String>,
    selectedTags: List<String>,
    selectedFolderId: String?,
    sort: NoteSort,
    folderCounts: Map<String?, Int>,
    uncategorizedCount: Int,
    screenH: androidx.compose.ui.unit.Dp,
    onSelectFolder: (String?) -> Unit,
    onFolderManage: (ai.oriveo.community.core.model.NoteFolder) -> Unit,
    onToggleTag: (String) -> Unit,
    onSetSort: (NoteSort) -> Unit,
    onShowMore: () -> Unit,
    onNoteClick: (String) -> Unit,
    onNoteTogglePin: (Note) -> Unit,
    onNoteMove: (Note) -> Unit,
    onNoteDelete: (Note) -> Unit,
    onCreateBlank: () -> Unit,
) {
    val visible = remember(notes, visibleCount) { notes.take(visibleCount) }
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.md),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(
            top = OriveoTheme.spacing.sm,
            bottom = OriveoTheme.spacing.xl,
        ),
    ) {
        item(key = "folder_chips") {
            FolderFilterChips(
                folders = folders,
                selectedFolderId = selectedFolderId,
                folderCounts = folderCounts,
                uncategorizedCount = uncategorizedCount,
                uncategorizedSentinel = NotesViewModel.UNCATEGORIZED,
                onSelect = onSelectFolder,
                onFolderLongPress = onFolderManage,
                modifier = Modifier.padding(horizontal = screenH),
            )
        }
        item(key = "toolbar") {
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = screenH),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                SortSelector(sort = sort, onSetSort = onSetSort)
            }
        }
        if (availableTags.isNotEmpty()) {
            item(key = "tag_chips") {
                TagFilterChips(
                    availableTags = availableTags,
                    selectedTags = selectedTags,
                    onToggle = onToggleTag,
                    modifier = Modifier.padding(horizontal = screenH),
                )
            }
        }
        if (visible.isEmpty()) {
            item(key = "empty") {
                OriveoEmptyState(
                    icon = Icons.AutoMirrored.Outlined.StickyNote2,
                    title = stringResource(R.string.notes_empty_title),
                    description = stringResource(R.string.notes_empty_description),
                    actionTitle = stringResource(R.string.notes_action_new_blank),
                    onAction = onCreateBlank,
                    modifier = Modifier.padding(horizontal = screenH, vertical = OriveoTheme.spacing.lg),
                )
            }
        } else {
            items(visible, key = { it.id }) { note ->
                NoteCard(
                    note = note,
                    onClick = { onNoteClick(note.id) },
                    onTogglePin = { onNoteTogglePin(note) },
                    onMove = { onNoteMove(note) },
                    onDelete = { onNoteDelete(note) },
                    modifier = Modifier.padding(horizontal = screenH),
                )
            }
            if (notes.size > visibleCount) {
                item(key = "show_more") {
                    Box(
                        modifier = Modifier.fillMaxWidth().padding(horizontal = screenH),
                        contentAlignment = Alignment.Center,
                    ) {
                        TextButton(onClick = onShowMore) {
                            Text(stringResource(R.string.notes_show_more))
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SortSelector(
    sort: NoteSort,
    onSetSort: (NoteSort) -> Unit,
) {
    val colors = OriveoTheme.colors
    var expanded by remember { mutableStateOf(false) }
    val label = stringResource(
        when (sort) {
            NoteSort.UpdatedAt -> R.string.notes_sort_updated
            NoteSort.CreatedAt -> R.string.notes_sort_created
            NoteSort.SourceProviderKind -> R.string.notes_sort_source_model
        },
    )
    Box {
        Row(
            modifier = Modifier
                .clip(RoundedCornerShape(8.dp))
                .clickable { expanded = true }
                .padding(vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Text(
                text = "${stringResource(R.string.notes_sort_title)}: $label",
                style = OriveoTheme.typography.caption,
                color = colors.textSecondary,
            )
            Icon(
                Icons.Outlined.KeyboardArrowDown,
                contentDescription = null,
                tint = colors.textTertiary,
                modifier = Modifier.size(18.dp),
            )
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            SortMenuItem(R.string.notes_sort_updated, NoteSort.UpdatedAt, sort, onSetSort) { expanded = false }
            SortMenuItem(R.string.notes_sort_created, NoteSort.CreatedAt, sort, onSetSort) { expanded = false }
            SortMenuItem(R.string.notes_sort_source_model, NoteSort.SourceProviderKind, sort, onSetSort) { expanded = false }
        }
    }
}

@Composable
private fun SortMenuItem(
    labelRes: Int,
    value: NoteSort,
    current: NoteSort,
    onSetSort: (NoteSort) -> Unit,
    onClose: () -> Unit,
) {
    DropdownMenuItem(
        text = { Text(stringResource(labelRes)) },
        onClick = { onSetSort(value); onClose() },
        trailingIcon = {
            if (value == current) {
                Icon(
                    Icons.Filled.Check,
                    contentDescription = null,
                    tint = OriveoTheme.colors.primary,
                    modifier = Modifier.size(18.dp),
                )
            }
        },
    )
}

@Composable
private fun TrashListContent(
    trashedNotes: List<Note>,
    hasAnyTrash: Boolean,
    screenH: androidx.compose.ui.unit.Dp,
    onEmptyTrash: () -> Unit,
    onNoteClick: (String) -> Unit,
    onRestore: (String) -> Unit,
    onDeletePermanently: (Note) -> Unit,
) {
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.md),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(
            top = OriveoTheme.spacing.sm,
            bottom = OriveoTheme.spacing.xl,
        ),
    ) {
        
        
        if (hasAnyTrash) {
            item(key = "trash_header") {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = screenH),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    Text(
                        text = stringResource(R.string.notes_trash_long_press_hint),
                        style = OriveoTheme.typography.footnote,
                        color = OriveoTheme.colors.textTertiary,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                    TextButton(onClick = onEmptyTrash) {
                        Text(stringResource(R.string.notes_trash_empty), color = OriveoTheme.colors.danger)
                    }
                }
            }
        }
        if (trashedNotes.isEmpty()) {
            item(key = "trash_empty") {
                OriveoEmptyState(
                    icon = Icons.Outlined.Close,
                    title = stringResource(R.string.notes_trash_empty_title),
                    description = stringResource(R.string.notes_trash_empty_description),
                    modifier = Modifier.padding(horizontal = screenH, vertical = OriveoTheme.spacing.lg),
                )
            }
        } else {
            items(trashedNotes, key = { it.id }) { note ->
                TrashNoteCard(
                    note = note,
                    onClick = { onNoteClick(note.id) },
                    onRestore = { onRestore(note.id) },
                    onDeletePermanently = { onDeletePermanently(note) },
                    modifier = Modifier.padding(horizontal = screenH),
                )
            }
        }
    }
}
