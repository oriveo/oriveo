package ai.oriveo.community.feature.settings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import ai.oriveo.community.R
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.GlobalToastAction
import ai.oriveo.community.core.app.GlobalToastStyle
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.context.MemoryCandidate
import ai.oriveo.community.core.context.MemoryCandidateEdit
import ai.oriveo.community.core.context.MemoryItem
import ai.oriveo.community.core.memory.MemoryCandidateRepository
import ai.oriveo.community.core.memory.MemoryCandidateResult
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.CancellationException
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

/** Item editor in its new state, prefilled from one candidate. */
data class MemoryInboxEditor(
    val candidateId: String,
    /** Group preselected from proposedKind; the kind is only sent when the user changes it. */
    val initialGroup: MemoryItemGroup,
    val state: MemoryItemEditorState,
)

/** Group a candidate shows under: by proposedKind, About when it maps to none. */
fun MemoryCandidate.inboxGroup(): MemoryItemGroup = MemoryItemGroup.of(proposedKind) ?: MemoryItemGroup.About

/**
 * Memory suggestions inbox (contract P6·U4 rules 3, 4): lists pending candidates in pending() order and saves,
 * edits or ignores them like the chat bar (P6·U3). Actions run on the app-level scope so the undo outlives the page.
 * Candidates never become items without accept. The auto-suggest switch sits above the list.
 */
@Suppress("TooManyFunctions")
class MemoryInboxViewModel(
    private val candidates: MemoryCandidateRepository,
    private val accountId: () -> String,
    /** App-level scope for accept / reject / undo. */
    private val actionScope: CoroutineScope,
    private val showToast: (GlobalSnackbarMessage) -> Unit,
    private val ioContext: CoroutineContext = Dispatchers.IO,
) : ViewModel() {
    private val _state = MutableStateFlow(MemoryInboxUiState())
    val state: StateFlow<MemoryInboxUiState> = _state.asStateFlow()

    private val _editor = MutableStateFlow<MemoryInboxEditor?>(null)
    val editor: StateFlow<MemoryInboxEditor?> = _editor.asStateFlow()

    /** Auto-suggest switch (contract P6·U4 rule 2): per-account local preference, on until read otherwise. */
    private val _autoSuggest = MutableStateFlow(true)
    val autoSuggest: StateFlow<Boolean> = _autoSuggest.asStateFlow()

    init {
        val account = accountId()
        viewModelScope.launch {
            attempt { withContext(ioContext) { candidates.autoSuggestEnabled(account) } }?.let { _autoSuggest.value = it }
        }
        refresh()
    }

    /** Turning it off only stops implicit suggestions; existing pending candidates stay listed. */
    fun setAutoSuggest(on: Boolean) {
        _autoSuggest.value = on
        val account = accountId()
        actionScope.launch { attempt { withContext(ioContext) { candidates.setAutoSuggestEnabled(account, on) } } }
    }

    /**
     * Re-reads pending candidates (entering the page, returning to the memory page, after a failed write).
     * A failed read keeps the previous list; a first read that fails shows the empty state.
     */
    fun refresh() {
        val account = accountId()
        viewModelScope.launch {
            val pending = attempt { withContext(ioContext) { candidates.pending(account) } }
            _state.update { state ->
                if (pending == null) state.copy(loaded = true) else MemoryInboxUiState(loaded = true, candidates = pending)
            }
        }
    }

    /** Accept as is; the row goes away, then "saved" with undo or "couldn't save". */
    fun save(candidateId: String) {
        take(candidateId) ?: return
        accept(candidateId, edit = null)
    }

    /** Reject; the row goes away right away. A failed write reloads the list (the row comes back) without a toast. */
    fun ignore(candidateId: String) {
        take(candidateId) ?: return
        val account = accountId()
        actionScope.launch {
            val result = attempt { withContext(ioContext) { candidates.reject(account, candidateId) } }
            if (result !is MemoryCandidateResult.Ok) refresh()
        }
    }

    /** Opens the item editor in its new state with the candidate text; the group follows proposedKind. */
    fun edit(candidateId: String) {
        val candidate = _state.value.candidates.firstOrNull { it.id == candidateId } ?: return
        val group = candidate.inboxGroup()
        _editor.value = MemoryInboxEditor(
            candidateId = candidate.id,
            initialGroup = group,
            state = MemoryItemEditorState(
                itemId = null,
                group = group,
                text = candidate.content,
                originalKind = candidate.proposedKind,
            ),
        )
    }

    fun updateEditorText(text: String) {
        _editor.update { it?.copy(state = it.state.copy(text = text)) }
    }

    fun updateEditorGroup(group: MemoryItemGroup) {
        _editor.update { it?.copy(state = it.state.copy(group = group)) }
    }

    /** Cancel keeps the row. */
    fun dismissEditor() {
        _editor.value = null
    }

    /** Accepts with the edited text; the kind only when the group changed; the scope never changes. */
    fun saveEditor() {
        val editing = _editor.value ?: return
        if (!editing.state.counter.canSave) return
        _editor.value = null
        take(editing.candidateId)
        val kind = editing.state.kind.takeIf { editing.state.group != editing.initialGroup }
        accept(editing.candidateId, MemoryCandidateEdit(content = editing.state.text, kind = kind))
    }

    private fun accept(candidateId: String, edit: MemoryCandidateEdit?) {
        val account = accountId()
        actionScope.launch {
            val result = attempt { withContext(ioContext) { candidates.accept(account, candidateId, edit) } }
            val item = (result as? MemoryCandidateResult.Ok<MemoryItem>)?.value
            if (item == null) {
                showToast(
                    GlobalSnackbarMessage(
                        message = UiText.Resource(R.string.memory_suggestion_failed),
                        style = GlobalToastStyle.Error,
                    ),
                )
                refresh()
                return@launch
            }
            showToast(
                GlobalSnackbarMessage(
                    message = UiText.Resource(R.string.memory_suggestion_saved),
                    style = GlobalToastStyle.Success,
                    action = GlobalToastAction(UiText.Resource(R.string.undo)) {
                        actionScope.launch {
                            attempt { withContext(ioContext) { candidates.items.delete(account, item.id) } }
                        }
                    },
                    durationMs = UNDO_WINDOW_MS,
                ),
            )
        }
    }

    /** Removes the row; returns its candidate, null when it is already gone. */
    private fun take(candidateId: String): MemoryCandidate? {
        var taken: MemoryCandidate? = null
        _state.update { state ->
            taken = state.candidates.firstOrNull { it.id == candidateId }
            state.copy(candidates = state.candidates.filterNot { it.id == candidateId })
        }
        if (_editor.value?.candidateId == candidateId) _editor.value = null
        return taken
    }

    /** A failed read or write only loses the action; it never crashes the page. */
    @Suppress("TooGenericExceptionCaught")
    private suspend fun <T> attempt(block: suspend () -> T): T? = try {
        block()
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        null
    }

    companion object {
        const val UNDO_WINDOW_MS = 5000L
    }
}
