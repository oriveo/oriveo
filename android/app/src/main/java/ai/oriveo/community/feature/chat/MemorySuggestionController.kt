package ai.oriveo.community.feature.chat

import ai.oriveo.community.R
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.GlobalToastAction
import ai.oriveo.community.core.app.GlobalToastStyle
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.context.MemoryCandidate
import ai.oriveo.community.core.context.MemoryCandidateEdit
import ai.oriveo.community.core.context.MemoryIntent
import ai.oriveo.community.core.context.MemoryIntentSuggestion
import ai.oriveo.community.core.context.MemoryItem
import ai.oriveo.community.core.memory.MemoryCandidateRepository
import ai.oriveo.community.core.memory.MemoryCandidateResult
import ai.oriveo.community.core.memory.MemoryItemRepository
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.feature.settings.MemoryItemEditorState
import ai.oriveo.community.feature.settings.MemoryItemGroup
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** A "save to memory?" bar anchored under the assistant reply of one fresh send (contract P10 rule 7). */
data class MemorySuggestion(
    val conversationId: String,
    /** Assistant message of the turn; the bar shows only once that reply is no longer streaming. */
    val messageId: String,
    /** The freshly generated candidate; null when memory is off for the chat and the bar is only a hint. */
    val candidate: MemoryCandidate?,
) {
    val memoryOff: Boolean get() = candidate == null
}

/**
 * A bar waiting for its turn's reply, keyed by the fresh user message (the candidate's source.messageIds stay the
 * user message); [MemorySuggestionController.current] resolves it to the assistant reply that follows.
 */
data class PendingMemorySuggestion(
    val conversationId: String,
    val userMessageId: String,
    val candidate: MemoryCandidate?,
)

/**
 * Chat-side editor for a bar's candidate (contract P6·U3 rule 5), held here rather than in the settings
 * MemoryViewModel: the item editor in its new state, prefilled with the candidate.
 */
data class MemorySuggestionEditor(
    val conversationId: String,
    val candidateId: String,
    /** Group preselected from the candidate's proposedKind; the kind is only sent when the user changes it. */
    val initialGroup: MemoryItemGroup,
    val state: MemoryItemEditorState,
)

/**
 * "Save to memory?" bar (contract P6·U3 rules 1, 2, 4-7). A fresh user send whose classification routes to memory
 * shows the bar once its candidate is generated, or, with memory off for the chat, only the memory-off hint.
 * Bars live in memory only (one per conversation) and vanish on the next user message, on switching conversations,
 * or on restart; vanishing is not an ignore and leaves the candidate pending. Save accepts the candidate and offers
 * a 5 s undo that deletes the new item; edit accepts the edited text; ignore rejects the candidate.
 */
@Suppress("LongParameterList", "TooManyFunctions")
@OptIn(ExperimentalCoroutinesApi::class)
class MemorySuggestionController(
    private val scope: CoroutineScope,
    activeConversationId: StateFlow<String?>,
    /**
     * Id of the conversation's last user message in its persisted message list (rule 2); a bar only shows under it.
     */
    private val latestUserMessageId: suspend (conversationId: String) -> String?,
    /** App-level scope for accept / reject / undo: they must survive leaving the chat within the undo window. */
    private val actionScope: CoroutineScope = scope,
    /** Scope of the long-lived state collectors; tests pass their background scope. */
    stateScope: CoroutineScope = scope,
    private val ioContext: CoroutineContext = Dispatchers.IO,
    private val classify: (String) -> MemoryIntentSuggestion = { MemoryIntent.classify(it).suggestion },
    /** Candidate store behind the bar's actions; null (tests of routing only) disables them. */
    private val candidates: MemoryCandidateRepository? = null,
    /** Item store used to undo a save. */
    private val items: MemoryItemRepository? = null,
    private val accountId: () -> String = { "" },
    private val showToast: (GlobalSnackbarMessage) -> Unit = {},
    /**
     * Persisted messages of a conversation; only observed while that conversation has a pending bar, to find the
     * turn's assistant reply and whether it is still streaming.
     */
    private val observeMessages: (conversationId: String) -> Flow<List<ChatMessage>> = { emptyFlow() },
) {
    private val _pending = MutableStateFlow<Map<String, PendingMemorySuggestion>>(emptyMap())
    val pending: StateFlow<Map<String, PendingMemorySuggestion>> = _pending.asStateFlow()

    /**
     * Latest fresh send per conversation, dropped on switching away: a late result for an older send, or for a
     * conversation the user left, must not bring a bar back.
     */
    private val latestSend = java.util.concurrent.ConcurrentHashMap<String, String>()

    /** User message whose turn already turned a propose_memory create into the bar, per conversation (P10 rule 4). */
    private val proposedTurn = java.util.concurrent.ConcurrentHashMap<String, String>()

    private val _editor = MutableStateFlow<MemorySuggestionEditor?>(null)
    val editor: StateFlow<MemorySuggestionEditor?> = _editor.asStateFlow()

    /**
     * Bar of the active conversation under its turn's assistant reply ([MemorySuggestion.messageId]); null until
     * that reply exists and has finished streaming (P10 rule 7), on both the tool and the fallback path.
     */
    val current: StateFlow<MemorySuggestion?> =
        _pending.combine(activeConversationId) { pending, conversationId -> conversationId?.let(pending::get) }
            .distinctUntilChanged()
            .flatMapLatest { bar ->
                if (bar == null) flowOf(null) else observeMessages(bar.conversationId).map { anchor(bar, it) }
            }
            .distinctUntilChanged()
            .stateIn(stateScope, SharingStarted.Eagerly, null)

    init {
        // Switching conversations drops every other conversation's bar (not an ignore).
        activeConversationId.onEach { retainOnly(it) }.launchIn(stateScope)
    }

    /**
     * A fresh user message was persisted. Clears this conversation's bar; with memory off, a message routed to
     * memory shows the hint right away (no candidate is generated). With memory on the bar waits for
     * [onCandidateGenerated].
     */
    fun onUserMessageCreated(conversationId: String, messageId: String, text: String, useMemory: Boolean) {
        latestSend[conversationId] = messageId
        proposedTurn.remove(conversationId)
        _pending.update { it - conversationId }
        if (useMemory) return
        scope.launch {
            val suggestion = withContext(ioContext) { classify(text) }
            if (suggestion != MemoryIntentSuggestion.MEMORY) return@launch
            show(PendingMemorySuggestion(conversationId, messageId, candidate = null))
        }
    }

    /** Generation finished for [messageId]; only a new candidate for the still-latest user message shows the bar. */
    fun onCandidateGenerated(conversationId: String, messageId: String, candidate: MemoryCandidate?) {
        candidate ?: return
        scope.launch { show(PendingMemorySuggestion(conversationId, messageId, candidate)) }
    }

    /**
     * P10 rule 4: a propose_memory call of the turn started by user message [messageId] created [candidate]. Only
     * the turn's first create becomes the bar; later ones stay pending candidates without a bar.
     */
    fun onProposedCandidate(conversationId: String, messageId: String, candidate: MemoryCandidate) {
        if (proposedTurn.put(conversationId, messageId) == messageId) return
        scope.launch { show(PendingMemorySuggestion(conversationId, messageId, candidate)) }
    }

    /** Rule 4: accept as is; the bar goes away, then "saved" with undo or "couldn't save". */
    fun save(conversationId: String) {
        val candidate = take(conversationId) ?: return
        accept(candidate.id, edit = null)
    }

    /** Rule 6: reject; the bar goes away whether or not the write succeeds. */
    fun ignore(conversationId: String) {
        val candidate = take(conversationId) ?: return
        val repository = candidates ?: return
        val account = accountId()
        actionScope.launch { attempt { withContext(ioContext) { repository.reject(account, candidate.id) } } }
    }

    /** Rule 5: opens the item editor in its new state with the candidate text; the group follows proposedKind. */
    fun edit(conversationId: String) {
        val candidate = _pending.value[conversationId]?.candidate ?: return
        val group = MemoryItemGroup.of(candidate.proposedKind) ?: MemoryItemGroup.About
        _editor.value = MemorySuggestionEditor(
            conversationId = conversationId,
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

    /** Cancel keeps the bar. */
    fun dismissEditor() {
        _editor.value = null
    }

    /** Accepts with the edited text; the kind only when the group changed; the scope never changes. */
    fun saveEditor() {
        val editing = _editor.value ?: return
        if (!editing.state.counter.canSave) return
        _editor.value = null
        _pending.update { map ->
            if (map[editing.conversationId]?.candidate?.id == editing.candidateId) map - editing.conversationId else map
        }
        val kind = editing.state.kind.takeIf { editing.state.group != editing.initialGroup }
        accept(editing.candidateId, MemoryCandidateEdit(content = editing.state.text, kind = kind))
    }

    /**
     * P9·U8: the turn of [messageId] (its assistant reply, or the user message the rollback reports) was rolled
     * back; its bar goes away (not an ignore, the candidate stays pending) and a late candidate for it no longer
     * shows. A bar under any other message stays.
     */
    fun withdraw(conversationId: String, messageId: String) {
        latestSend.remove(conversationId, messageId)
        val bar = _pending.value[conversationId] ?: return
        val shown = current.value
        val underReply = shown?.conversationId == conversationId && shown.messageId == messageId
        if (bar.userMessageId != messageId && !underReply) return
        latestSend.remove(conversationId, bar.userMessageId)
        take(conversationId)
    }

    fun retainOnly(conversationId: String?) {
        latestSend.keys.retainAll { it == conversationId }
        proposedTurn.keys.retainAll { it == conversationId }
        _pending.update { map -> map.filterKeys { it == conversationId } }
    }

    private fun accept(candidateId: String, edit: MemoryCandidateEdit?) {
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

    /** Removes the conversation's bar; returns its candidate (null for the memory-off hint). */
    private fun take(conversationId: String): MemoryCandidate? {
        var taken: PendingMemorySuggestion? = null
        _pending.update { map ->
            taken = map[conversationId]
            map - conversationId
        }
        if (_editor.value?.conversationId == conversationId) _editor.value = null
        return taken?.candidate
    }

    /** A failed write only loses the action; it never crashes the chat scope. */
    @Suppress("TooGenericExceptionCaught")
    private suspend fun <T> attempt(block: suspend () -> T): T? = try {
        block()
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        null
    }

    private suspend fun show(suggestion: PendingMemorySuggestion) {
        val latest = attempt { withContext(ioContext) { latestUserMessageId(suggestion.conversationId) } }
        if (!suggestion.userMessageId.equals(latest, ignoreCase = true)) return
        if (latestSend[suggestion.conversationId] != suggestion.userMessageId) return
        _pending.update { it + (suggestion.conversationId to suggestion) }
    }

    /** The first assistant message after the bar's user message, once it is no longer streaming. */
    private fun anchor(bar: PendingMemorySuggestion, messages: List<ChatMessage>): MemorySuggestion? {
        val userIndex = messages.indexOfLast { it.id.equals(bar.userMessageId, ignoreCase = true) }
        if (userIndex < 0) return null
        val reply = messages.drop(userIndex + 1).firstOrNull { it.role == ChatRole.Assistant } ?: return null
        if (reply.state == ChatMessageState.Generating) return null
        return MemorySuggestion(bar.conversationId, reply.id, bar.candidate)
    }

    companion object {
        const val UNDO_WINDOW_MS = 5000L
    }
}
