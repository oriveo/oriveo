package ai.oriveo.community.feature.notes

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import ai.oriveo.community.R
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.GlobalToastAction
import ai.oriveo.community.core.app.GlobalToastStyle
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.data.repository.NoteRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.Note
import ai.oriveo.community.core.model.NoteFolder
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.notes.NoteCapture
import ai.oriveo.community.core.notes.NoteListing
import ai.oriveo.community.core.notes.NoteTime
import ai.oriveo.community.core.provider.ModelSelectionUtils
import ai.oriveo.community.core.provider.ProviderSelectionSnapshot
import ai.oriveo.community.core.util.TextShareLauncher
import ai.oriveo.community.core.util.normalizeUuid
import ai.oriveo.community.feature.chat.crosscheck.CrosscheckCoordinator
import ai.oriveo.community.feature.chat.crosscheck.CrosscheckModelIdentity
import ai.oriveo.community.feature.chat.crosscheck.CrosscheckOption
import ai.oriveo.community.feature.chat.crosscheck.CrosscheckState
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch


class NoteDetailViewModel(
    savedStateHandle: SavedStateHandle,
    private val noteRepository: NoteRepository,
    private val providerRepository: ProviderRepository,
    private val appPreferencesRepository: AppPreferencesRepository,
    private val globalSnackbarManager: GlobalSnackbarManager,
) : ViewModel() {

    val noteID: String = savedStateHandle.get<String>("noteID")?.let(::normalizeUuid).orEmpty()

    val note: StateFlow<Note?> = noteRepository.observeNote(noteID)
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)

    val folders: StateFlow<List<NoteFolder>> = noteRepository.observeFolders()
        .map { list -> list.sortedBy { it.sortOrder } }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val availableTags: StateFlow<List<String>> = combine(noteRepository.observeActive(), note) { notes, current ->
        NoteListing.tagSuggestions(notes, excluding = current?.tags ?: emptyList())
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    fun updateTitle(title: String) {
        viewModelScope.launch { noteRepository.updateTitle(noteID, title) }
    }

    fun updateBody(body: String) {
        viewModelScope.launch { noteRepository.updateBody(noteID, body) }
    }

    fun addTag(tag: String) {
        val clean = tag.trim()
        if (clean.isEmpty()) return
        viewModelScope.launch {
            val current = note.value?.tags ?: emptyList()
            if (current.any { it.equals(clean, ignoreCase = true) }) return@launch
            noteRepository.updateTags(noteID, current + clean)
        }
    }

    fun removeTag(tag: String) {
        viewModelScope.launch {
            val current = note.value?.tags ?: return@launch
            noteRepository.updateTags(noteID, current - tag)
        }
    }

    fun moveToFolder(folderId: String?) {
        viewModelScope.launch { noteRepository.moveToFolder(noteID, folderId) }
    }

    fun createFolderAndMoveToIt(name: String, colorTag: String? = null) {
        viewModelScope.launch {
            val folder = noteRepository.createFolder(name, colorTag) ?: return@launch
            noteRepository.moveToFolder(noteID, folder.id)
            globalSnackbarManager.show(
                GlobalSnackbarMessage(
                    message = UiText.Resource(R.string.notes_toast_folder_created, listOf(folder.name)),
                    style = GlobalToastStyle.Success,
                ),
            )
        }
    }

    fun setPinned(isPinned: Boolean) {
        viewModelScope.launch { noteRepository.pinNote(noteID, isPinned) }
    }

    fun discardEmptyBlankNoteIfNeeded(onDone: () -> Unit = {}) {
        viewModelScope.launch {
            try {
                noteRepository.discardEmptyBlankNoteIfNeeded(noteID)
            } finally {
                onDone()
            }
        }
    }

    fun softDelete(onDone: () -> Unit) {
        viewModelScope.launch {
            noteRepository.softDeleteNote(noteID)
            globalSnackbarManager.show(
                GlobalSnackbarMessage(UiText.Resource(R.string.notes_toast_deleted), GlobalToastStyle.Success),
            )
            onDone()
        }
    }

    fun restore() {
        viewModelScope.launch {
            noteRepository.restoreNote(noteID)
            globalSnackbarManager.show(
                GlobalSnackbarMessage(UiText.Resource(R.string.notes_toast_restored), GlobalToastStyle.Success),
            )
        }
    }

    
    fun export(context: Context) {
        val n = note.value ?: return
        val untitled = context.getString(R.string.notes_untitled)
        val markdown = noteRepository.exportMarkdown(n, untitled)
        val filename = noteRepository.exportMarkdownFilename(n, untitled)
        viewModelScope.launch {
            TextShareLauncher.shareTextFile(
                context = context,
                text = markdown,
                fileName = filename,
                mimeType = "text/markdown",
            ).onSuccess {
                globalSnackbarManager.show(
                    GlobalSnackbarMessage(UiText.Resource(R.string.notes_toast_exported), GlobalToastStyle.Success),
                )
            }.onFailure {
                globalSnackbarManager.show(
                    GlobalSnackbarMessage(UiText.Resource(R.string.notes_toast_export_failed), GlobalToastStyle.Error),
                )
            }
        }
    }

    

    
    
    
    
    
    val providers: StateFlow<List<Provider>> = providerRepository.observeAll()
        .stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

    private val crosscheckCoordinator = CrosscheckCoordinator(
        scope = viewModelScope,
        providerRepository = providerRepository,
        appLanguageTag = {
            AppPreferencesRepository.serializeLanguageSyncTag(appPreferencesRepository.getLanguage())
                ?: CrosscheckCoordinator.currentSystemLanguageTag()
        },
    )
    val crosscheckState: StateFlow<CrosscheckState> = crosscheckCoordinator.state

    
    private val _navToNoteDetail = MutableSharedFlow<String>(extraBufferCapacity = 1)
    val navToNoteDetail: SharedFlow<String> = _navToNoteDetail.asSharedFlow()

    var crosscheckActive: Boolean by mutableStateOf(false)
        private set

    fun crosscheckOptions(providerList: List<Provider> = providers.value): List<CrosscheckOption> {
        val n = note.value
        val pk = n?.sourceProviderKind
        val mid = n?.sourceModelID
        val origin = if (pk != null && !mid.isNullOrBlank()) {
            CrosscheckModelIdentity(providerKind = pk, modelId = mid)
        } else null
        return CrosscheckCoordinator.eligibleOptions(providerList, excluding = origin)
    }

    fun crosscheckProviders(): List<Provider> = providers.value

    fun enableModel(providerId: String, modelId: String) {
        viewModelScope.launch {
            try {
                val provider = providerRepository.getById(providerId) ?: return@launch
                val model = ProviderSelectionSnapshot.selectedModel(provider, modelId) ?: return@launch
                providerRepository.updateProvider(
                    ModelSelectionUtils.enableModel(provider, model),
                )
            } catch (_: Exception) {
                globalSnackbarManager.show(
                    GlobalSnackbarMessage(
                        message = UiText.Resource(R.string.snackbar_model_enable_failed),
                    ),
                )
            }
        }
    }

    
    private fun originalAnswerText(n: Note): String = n.bodySnapshot?.takeIf { it.isNotBlank() } ?: n.body

    fun openCrosscheck() {
        crosscheckCoordinator.reset()
        crosscheckActive = true
    }

    fun runCrosscheck(option: CrosscheckOption) {
        val n = note.value ?: return
        crosscheckCoordinator.start(
            originalQuestion = n.sourcePrompt ?: "",
            originalAnswer = originalAnswerText(n),
            priorMessages = emptyList(),
            provider = option.provider,
            model = option.model,
        )
    }

    fun saveCrosscheckNote(option: CrosscheckOption) {
        val n = note.value ?: return
        val text = crosscheckState.value.text
        if (text.isBlank()) return
        val input = NoteCapture.fromCrosscheck(
            originalAnswer = originalAnswerText(n),
            originConversationId = n.sourceConversationId,
            originMessageId = n.sourceMessageId,
            originModelID = n.sourceModelID,
            originModelName = n.sourceModelName ?: "",
            originProviderKind = n.sourceProviderKind,
            originProviderName = n.sourceProviderName ?: "",
            originPrompt = n.sourcePrompt,
            crosscheckProviderKind = option.provider.kind,
            crosscheckProviderName = option.provider.displayName,
            crosscheckModelID = option.model.id,
            crosscheckModelName = option.model.name,
            crosscheckText = text,
            originAtIso = n.createdAt,
            nowIso = NoteTime.nowIso(),
        )
        viewModelScope.launch {
            val created = noteRepository.createNote(input)
            closeCrosscheck()
            globalSnackbarManager.show(
                GlobalSnackbarMessage(
                    message = if (created.title.isBlank()) {
                        UiText.Resource(R.string.notes_untitled)
                    } else {
                        UiText.Dynamic(created.title)
                    },
                    style = GlobalToastStyle.Success,
                    action = GlobalToastAction(UiText.Resource(R.string.notes_toast_view)) {
                        _navToNoteDetail.tryEmit(created.id)
                    },
                    durationMs = 4000L,
                ),
            )
        }
    }

    fun closeCrosscheck() {
        crosscheckActive = false
        crosscheckCoordinator.reset()
    }
}
