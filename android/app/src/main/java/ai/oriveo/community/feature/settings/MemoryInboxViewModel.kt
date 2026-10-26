package ai.oriveo.community.feature.settings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.context.MemoryCandidate
import ai.oriveo.community.core.memory.MemoryCandidateRepository
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Inbox list state; [loaded] stays false until the first read so the empty state never flashes. */
data class MemoryInboxUiState(
    val loaded: Boolean = false,
    val candidates: List<MemoryCandidate> = emptyList(),
) {
    val count: Int get() = candidates.size
    val showsEmptyState: Boolean get() = loaded && candidates.isEmpty()

    /** Value of the memory page's entry row: the pending count, nothing at 0. */
    val entryValue: String? get() = count.takeIf { it > 0 }?.toString()
}

/** Group a candidate shows under: by proposedKind, About when it maps to none. */
fun MemoryCandidate.inboxGroup(): MemoryItemGroup = MemoryItemGroup.of(proposedKind) ?: MemoryItemGroup.About

/**
 * Memory suggestions inbox: lists pending candidates in pending() order and saves,
 * edits or ignores them like the chat bar. Actions run on the app-level scope so the undo outlives the page.
 * Candidates never become items without accept. The auto-suggest switch sits above the list.
 * The candidate edit / save / accept / reject is [MemoryCandidateActions], shared with the chat bar.
 */
@Suppress("TooManyFunctions")
class MemoryInboxViewModel(
    private val candidates: MemoryCandidateRepository,
    private val accountId: () -> String,
    /** App-level scope for accept / reject / undo. */
    private val actionScope: CoroutineScope,
    showToast: (GlobalSnackbarMessage) -> Unit,
    private val ioContext: CoroutineContext = Dispatchers.IO,
) : ViewModel() {
    private val _state = MutableStateFlow(MemoryInboxUiState())
    val state: StateFlow<MemoryInboxUiState> = _state.asStateFlow()

    /** A failed accept / reject reloads the list so the row comes back. */
    private val actions = MemoryCandidateActions(
        candidates = candidates,
        items = candidates.items,
        accountId = accountId,
        actionScope = actionScope,
        ioContext = ioContext,
        showToast = showToast,
        onWriteFailed = { refresh() },
    )

    val editor: StateFlow<MemoryInboxEditor?> = actions.editor

    /** Auto-suggest switch: per-account local preference, on until read otherwise. */
    private val _autoSuggest = MutableStateFlow(true)
    val autoSuggest: StateFlow<Boolean> = _autoSuggest.asStateFlow()

    init {
        val account = accountId()
        viewModelScope.launch {
            actions.attempt { withContext(ioContext) { candidates.autoSuggestEnabled(account) } }
                ?.let { _autoSuggest.value = it }
        }
        refresh()
    }

    /** Turning it off only stops implicit suggestions; existing pending candidates stay listed. */
    fun setAutoSuggest(on: Boolean) {
        _autoSuggest.value = on
        val account = accountId()
        actionScope.launch {
            actions.attempt { withContext(ioContext) { candidates.setAutoSuggestEnabled(account, on) } }
        }
    }

    /**
     * Re-reads pending candidates (entering the page, returning to the memory page, after a failed write).
     * A failed read keeps the previous list; a first read that fails shows the empty state.
     */
    fun refresh() {
        val account = accountId()
        viewModelScope.launch {
            val pending = actions.attempt { withContext(ioContext) { candidates.pending(account) } }
            _state.update { state ->
                if (pending == null) state.copy(loaded = true) else MemoryInboxUiState(loaded = true, candidates = pending)
            }
        }
    }

    /** Accept as is; the row goes away, then "saved" with undo or "couldn't save". */
    fun save(candidateId: String) {
        take(candidateId) ?: return
        actions.accept(candidateId, edit = null)
    }

    /** Reject; the row goes away right away. A failed write reloads the list (the row comes back) without a toast. */
    fun ignore(candidateId: String) {
        take(candidateId) ?: return
        actions.reject(candidateId)
    }

    /** Opens the item editor in its new state with the candidate text; the group follows proposedKind. */
    fun edit(candidateId: String) {
        val candidate = _state.value.candidates.firstOrNull { it.id == candidateId } ?: return
        actions.openEditor(candidate)
    }

    fun updateEditorText(text: String) = actions.updateEditorText(text)

    fun updateEditorGroup(group: MemoryItemGroup) = actions.updateEditorGroup(group)

    /** Cancel keeps the row. */
    fun dismissEditor() = actions.dismissEditor()

    /** Accepts with the edited text; the kind only when the group changed; the scope never changes. */
    fun saveEditor() {
        actions.saveEditor { editing -> take(editing.candidateId) }
    }

    /** Removes the row; returns its candidate, null when it is already gone. */
    private fun take(candidateId: String): MemoryCandidate? {
        var taken: MemoryCandidate? = null
        _state.update { state ->
            taken = state.candidates.firstOrNull { it.id == candidateId }
            state.copy(candidates = state.candidates.filterNot { it.id == candidateId })
        }
        actions.dismissEditorIf { it.candidateId == candidateId }
        return taken
    }

    companion object {
        const val UNDO_WINDOW_MS = MemoryCandidateActions.UNDO_WINDOW_MS
    }
}
