package ai.oriveo.community.feature.notes

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import ai.oriveo.community.R
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.GlobalToastAction
import ai.oriveo.community.core.app.GlobalToastStyle
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.data.repository.NoteRepository
import ai.oriveo.community.core.model.Note
import ai.oriveo.community.core.model.NoteFolder
import ai.oriveo.community.core.notes.NoteListing
import ai.oriveo.community.core.notes.NoteSort
import ai.oriveo.community.core.notes.NoteTime
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

@OptIn(ExperimentalCoroutinesApi::class, FlowPreview::class)
class NotesViewModel(
    private val noteRepository: NoteRepository,
    private val globalSnackbarManager: GlobalSnackbarManager,
    private val appPreferencesRepository: ai.oriveo.community.core.app.AppPreferencesRepository,
) : ViewModel() {

    enum class Tab { Notes, Trash }

    var tab by mutableStateOf(Tab.Notes)
        private set

    private val _query = MutableStateFlow("")
    private val _selectedFolderId = MutableStateFlow<String?>(null) // null = All
    private val _selectedTags = MutableStateFlow<List<String>>(emptyList())
    private val _sort = MutableStateFlow(NoteSort.UpdatedAt)

    val query: StateFlow<String> = _query
    val selectedFolderId: StateFlow<String?> = _selectedFolderId
    val selectedTags: StateFlow<List<String>> = _selectedTags
    val sort: StateFlow<NoteSort> = _sort

    var visibleCount by mutableStateOf(PAGE_SIZE)
        private set

    private val activeNotes: StateFlow<List<Note>> = noteRepository.observeActive()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val folders: StateFlow<List<NoteFolder>> = noteRepository.observeFolders()
        .map { list -> list.sortedBy { it.sortOrder } }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val trashedNotes: StateFlow<List<Note>> = noteRepository.observeTrash()
        .map { list ->

            list.map { note -> note to (NoteTime.isoToMillisOrNull(note.updatedAt) ?: 0L) }
                .sortedByDescending { it.second }
                .map { it.first }
        }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val syncEnabled: StateFlow<Boolean> = kotlinx.coroutines.flow.flowOf(Unit)
        .map { false }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), false)

    val uncategorizedCount: StateFlow<Int> = activeNotes
        .map { notes -> notes.count { it.noteFolderID == null } }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), 0)

    val folderNoteCounts: StateFlow<Map<String?, Int>> = activeNotes
        .map { notes -> notes.groupingBy { it.noteFolderID }.eachCount() }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyMap())

    val syncUpsellDismissed: StateFlow<Boolean> = MutableStateFlow(true)

    val availableTags: StateFlow<List<String>> = combine(activeNotes, _selectedFolderId) { notes, folder ->
        val uncategorized = folder == UNCATEGORIZED
        NoteListing.availableTags(notes, if (uncategorized) null else folder, MAX_TAG_CHIPS, uncategorizedOnly = uncategorized)
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val displayedNotes: StateFlow<List<Note>> = combine(
        _query.debounce(SEARCH_DEBOUNCE_MS),
        _selectedFolderId,
        _selectedTags,
        _sort,
        activeNotes,
    ) { q, folder, tags, sort, active ->
        Filters(q.trim(), folder, tags, sort, active)
    }.flatMapLatest { f ->
        flow {
            val uncategorized = f.folderId == UNCATEGORIZED
            val realFolder = if (uncategorized) null else f.folderId
            if (f.query.isBlank()) {
                emit(NoteListing.filterAndSort(f.active, realFolder, f.tags, f.sort, uncategorizedOnly = uncategorized))
            } else {
                val results = noteRepository.searchNotes(f.query, realFolder, f.tags, f.sort)

                emit(if (uncategorized) results.filter { it.noteFolderID == null } else results)
            }
        }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val displayedTrash: StateFlow<List<Note>> = combine(
        _query.debounce(SEARCH_DEBOUNCE_MS),
        trashedNotes,
    ) { q, trash ->
        val needle = q.trim().lowercase()
        if (needle.isEmpty()) {
            trash
        } else {
            trash.filter { note ->
                note.title.lowercase().contains(needle) ||
                    note.body.lowercase().contains(needle) ||
                    note.userNote?.lowercase()?.contains(needle) == true ||
                    note.tags.any { it.lowercase().contains(needle) }
            }
        }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    init {
    }

    fun selectTab(value: Tab) {
        tab = value
    }

    fun setQuery(value: String) {
        _query.value = value
        resetPaging()
    }

    fun selectFolder(folderId: String?) {
        _selectedFolderId.value = folderId
        _selectedTags.value = emptyList()
        resetPaging()
    }

    fun toggleTag(tag: String) {
        val current = _selectedTags.value
        _selectedTags.value = if (tag in current) current - tag else current + tag
        resetPaging()
    }

    fun clearTags() {
        _selectedTags.value = emptyList()
        resetPaging()
    }

    fun setSort(value: NoteSort) {
        _sort.value = value
        resetPaging()
    }

    fun showMore() {
        visibleCount += PAGE_SIZE
    }

    private fun resetPaging() {
        visibleCount = PAGE_SIZE
    }

    fun createBlankNote(onCreated: (String) -> Unit) {
        viewModelScope.launch {
            val folderId = _selectedFolderId.value.takeUnless { it == UNCATEGORIZED }
            val note = noteRepository.createBlankNote(folderId = folderId)
            onCreated(note.id)
        }
    }

    fun createFolder(name: String, colorTag: String? = null) {
        viewModelScope.launch {
            val folder = noteRepository.createFolder(name, colorTag) ?: return@launch
            globalSnackbarManager.show(
                GlobalSnackbarMessage(
                    message = UiText.Resource(R.string.notes_toast_folder_created, listOf(folder.name)),
                    style = GlobalToastStyle.Success,
                ),
            )
        }
    }

    fun renameFolder(id: String, name: String) {
        viewModelScope.launch { noteRepository.renameFolder(id, name) }
    }

    fun deleteFolder(id: String) {
        viewModelScope.launch {

            if (_selectedFolderId.value == id) selectFolder(null)
            noteRepository.deleteFolder(id)
        }
    }

    fun setFolderColor(id: String, colorTag: String) {
        viewModelScope.launch { noteRepository.setFolderColor(id, colorTag) }
    }

    fun moveNoteToFolder(noteId: String, folderId: String?) {
        viewModelScope.launch { noteRepository.moveToFolder(noteId, folderId) }
    }

    fun softDeleteNote(id: String) {
        viewModelScope.launch {
            noteRepository.softDeleteNote(id)

            globalSnackbarManager.show(
                GlobalSnackbarMessage(
                    message = UiText.Resource(R.string.notes_toast_deleted),
                    style = GlobalToastStyle.Success,
                    action = GlobalToastAction(UiText.Resource(R.string.notes_actions_undo)) { restoreNote(id) },
                    durationMs = 5000,
                ),
            )
        }
    }

    fun setPinned(id: String, isPinned: Boolean) {
        viewModelScope.launch { noteRepository.pinNote(id, isPinned) }
    }

    fun permanentlyDeleteNote(id: String) {
        viewModelScope.launch { noteRepository.permanentlyDeleteNote(id) }
    }

    fun dismissSyncUpsell() {}

    fun restoreNote(id: String) {
        viewModelScope.launch {
            noteRepository.restoreNote(id)
            globalSnackbarManager.show(
                GlobalSnackbarMessage(UiText.Resource(R.string.notes_toast_restored), GlobalToastStyle.Success),
            )
        }
    }

    fun emptyTrash() {
        viewModelScope.launch {
            noteRepository.emptyTrash()
            globalSnackbarManager.show(
                GlobalSnackbarMessage(UiText.Resource(R.string.notes_toast_trash_emptied), GlobalToastStyle.Success),
            )
        }
    }

    private data class Filters(
        val query: String,
        val folderId: String?,
        val tags: List<String>,
        val sort: NoteSort,
        val active: List<Note>,
    )

    companion object {
        const val PAGE_SIZE = 10

        const val UNCATEGORIZED = "__uncategorized__"
        private const val MAX_TAG_CHIPS = 12
        private const val SEARCH_DEBOUNCE_MS = 200L
    }
}
