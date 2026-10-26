package ai.oriveo.community.feature.settings

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
import ai.oriveo.community.core.memory.MemoryItemRepository
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Item editor in its new state, prefilled from one candidate.
 * [conversationId] is the chat bar's conversation; null in the inbox.
 */
data class MemoryCandidateEditor(
    val candidateId: String,
    /** Group preselected from proposedKind; the kind is only sent when the user changes it. */
    val initialGroup: MemoryItemGroup,
    val state: MemoryItemEditorState,
    val conversationId: String? = null,
)

/** Editor of the chat bar's candidate. */
typealias MemorySuggestionEditor = MemoryCandidateEditor

/** Editor of an inbox candidate. */
typealias MemoryInboxEditor = MemoryCandidateEditor

/**
 * Candidate edit / save / accept / reject shared by the chat bar
 * ([ai.oriveo.community.feature.chat.MemorySuggestionController]) and the inbox ([MemoryInboxViewModel]); the callers only own which bar / row a candidate is taken from.
 * Writes run on [actionScope] so the 5 s undo outlives the page; a failed write never crashes the caller's scope.
 */
class MemoryCandidateActions(
    /** Candidate store; null (tests of routing only) disables the writes. */
    private val candidates: MemoryCandidateRepository?,
    /** Item store used to undo a save. */
    private val items: MemoryItemRepository?,
    private val accountId: () -> String,
    private val actionScope: CoroutineScope,
    private val ioContext: CoroutineContext,
    private val showToast: (GlobalSnackbarMessage) -> Unit,
    /** A failed accept or reject (the inbox reloads its list so the row comes back). */
    private val onWriteFailed: () -> Unit = {},
) {
    private val _editor = MutableStateFlow<MemoryCandidateEditor?>(null)
    val editor: StateFlow<MemoryCandidateEditor?> = _editor.asStateFlow()

    /** Opens the item editor in its new state with the candidate text; the group follows proposedKind. */
    fun openEditor(candidate: MemoryCandidate, conversationId: String? = null) {
        val group = candidate.inboxGroup()
        _editor.value = MemoryCandidateEditor(
            candidateId = candidate.id,
            initialGroup = group,
            state = MemoryItemEditorState(
                itemId = null,
                group = group,
                text = candidate.content,
                originalKind = candidate.proposedKind,
            ),
            conversationId = conversationId,
        )
    }

    fun updateEditorText(text: String) {
        _editor.update { it?.copy(state = it.state.copy(text = text)) }
    }

    fun updateEditorGroup(group: MemoryItemGroup) {
        _editor.update { it?.copy(state = it.state.copy(group = group)) }
    }

    /** Cancel keeps the bar / row. */
    fun dismissEditor() {
        _editor.value = null
    }

    /** Closes the editor when it edits what [matches] picks (its bar / row was taken). */
    fun dismissEditorIf(matches: (MemoryCandidateEditor) -> Boolean) {
        _editor.update { editing -> editing?.takeUnless(matches) }
    }

    /**
     * Accepts with the edited text; the kind only when the group changed; the scope never changes.
     * [onSaving] removes the edited candidate's bar / row before the write.
     */
    fun saveEditor(onSaving: (MemoryCandidateEditor) -> Unit) {
        val editing = _editor.value ?: return
        if (!editing.state.counter.canSave) return
        _editor.value = null
        onSaving(editing)
        val kind = editing.state.kind.takeIf { editing.state.group != editing.initialGroup }
        accept(editing.candidateId, MemoryCandidateEdit(content = editing.state.text, kind = kind))
    }

    /** Accept; then "saved" with a 5 s undo that deletes the new item, or "couldn't save". */
    fun accept(candidateId: String, edit: MemoryCandidateEdit?) {
        val repository = candidates ?: return
        val account = accountId()
        actionScope.launch {
            val result = attempt { withContext(ioContext) { repository.accept(account, candidateId, edit) } }
            val item = (result as? MemoryCandidateResult.Ok<MemoryItem>)?.value
            if (item == null) {
                showToast(
                    GlobalSnackbarMessage(
                        message = UiText.Resource(R.string.memory_suggestion_failed),
                        style = GlobalToastStyle.Error,
                    ),
                )
                onWriteFailed()
                return@launch
            }
            showToast(
                GlobalSnackbarMessage(
                    message = UiText.Resource(R.string.memory_suggestion_saved),
                    style = GlobalToastStyle.Success,
                    action = GlobalToastAction(UiText.Resource(R.string.undo)) {
                        actionScope.launch { attempt { withContext(ioContext) { items?.delete(account, item.id) } } }
                    },
                    durationMs = UNDO_WINDOW_MS,
                ),
            )
        }
    }

    /** Reject without a toast; a failed write only reports [onWriteFailed]. */
    fun reject(candidateId: String) {
        val repository = candidates ?: return
        val account = accountId()
        actionScope.launch {
            val result = attempt { withContext(ioContext) { repository.reject(account, candidateId) } }
            if (result !is MemoryCandidateResult.Ok) onWriteFailed()
        }
    }

    /** A failed read or write only loses the action; it never crashes the caller's scope. */
    @Suppress("TooGenericExceptionCaught")
    suspend fun <T> attempt(block: suspend () -> T): T? = try {
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
