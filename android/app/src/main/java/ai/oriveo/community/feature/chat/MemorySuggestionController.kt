package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.context.MemoryCandidate
import ai.oriveo.community.core.context.MemoryIntent
import ai.oriveo.community.core.context.MemoryIntentSuggestion
import ai.oriveo.community.core.memory.MemoryCandidateRepository
import ai.oriveo.community.core.memory.MemoryItemRepository
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.feature.settings.MemoryCandidateActions
import ai.oriveo.community.feature.settings.MemoryItemGroup
import ai.oriveo.community.feature.settings.MemorySuggestionEditor
import kotlin.coroutines.CoroutineContext
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

/** A "save to memory?" bar anchored under the assistant reply of one fresh send. */
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
 * "Save to memory?" bar. A fresh user send whose classification routes to memory
 * shows the bar once its candidate is generated, or, with memory off for the chat, only the memory-off hint.
 * Bars live in memory only (one per conversation) and vanish on the next user message, on switching conversations,
 * or on restart; vanishing is not an ignore and leaves the candidate pending. Save accepts the candidate and offers
 * a 5 s undo that deletes the new item; edit accepts the edited text; ignore rejects the candidate.
 * The candidate edit / save / accept / reject is [MemoryCandidateActions], shared with the inbox; this class only
 * owns which bar a candidate is taken from. The chat-side editor is held here rather than in the settings
 * MemoryViewModel.
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
    candidates: MemoryCandidateRepository? = null,
    /** Item store used to undo a save. */
    items: MemoryItemRepository? = null,
    accountId: () -> String = { "" },
    showToast: (GlobalSnackbarMessage) -> Unit = {},
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

    /** User message whose turn already turned a propose_memory create into the bar, per conversation. */
    private val proposedTurn = java.util.concurrent.ConcurrentHashMap<String, String>()

    private val actions = MemoryCandidateActions(
        candidates = candidates,
        items = items,
        accountId = accountId,
        actionScope = actionScope,
        ioContext = ioContext,
        showToast = showToast,
    )

    val editor: StateFlow<MemorySuggestionEditor?> = actions.editor

    /**
     * Bar of the active conversation under its turn's assistant reply ([MemorySuggestion.messageId]); null until
     * that reply exists and has finished streaming, on both the tool and the fallback path.
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
     * a propose_memory call of the turn started by user message [messageId] created [candidate]. Only
     * the turn's first create becomes the bar; later ones stay pending candidates without a bar.
     */
    fun onProposedCandidate(conversationId: String, messageId: String, candidate: MemoryCandidate) {
        if (proposedTurn.put(conversationId, messageId) == messageId) return
        scope.launch { show(PendingMemorySuggestion(conversationId, messageId, candidate)) }
    }

    /** Rule 4: accept as is; the bar goes away, then "saved" with undo or "couldn't save". */
    fun save(conversationId: String) {
        val candidate = take(conversationId) ?: return
        actions.accept(candidate.id, edit = null)
    }

    /** Rule 6: reject; the bar goes away whether or not the write succeeds. */
    fun ignore(conversationId: String) {
        val candidate = take(conversationId) ?: return
        actions.reject(candidate.id)
    }

    /** Rule 5: opens the item editor in its new state with the candidate text; the group follows proposedKind. */
    fun edit(conversationId: String) {
        val candidate = _pending.value[conversationId]?.candidate ?: return
        actions.openEditor(candidate, conversationId)
    }

    fun updateEditorText(text: String) = actions.updateEditorText(text)

    fun updateEditorGroup(group: MemoryItemGroup) = actions.updateEditorGroup(group)

    /** Cancel keeps the bar. */
    fun dismissEditor() = actions.dismissEditor()

    /** Accepts with the edited text; the kind only when the group changed; the scope never changes. */
    fun saveEditor() {
        actions.saveEditor { editing ->
            _pending.update { map ->
                val conversationId = editing.conversationId
                if (conversationId != null && map[conversationId]?.candidate?.id == editing.candidateId) {
                    map - conversationId
                } else {
                    map
                }
            }
        }
    }

    /**
     * the turn of [messageId] (its assistant reply, or the user message the rollback reports) was rolled
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

    /** Removes the conversation's bar; returns its candidate (null for the memory-off hint). */
    private fun take(conversationId: String): MemoryCandidate? {
        var taken: PendingMemorySuggestion? = null
        _pending.update { map ->
            taken = map[conversationId]
            map - conversationId
        }
        actions.dismissEditorIf { it.conversationId == conversationId }
        return taken?.candidate
    }

    private suspend fun show(suggestion: PendingMemorySuggestion) {
        val latest = actions.attempt { withContext(ioContext) { latestUserMessageId(suggestion.conversationId) } }
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
        const val UNDO_WINDOW_MS = MemoryCandidateActions.UNDO_WINDOW_MS
    }
}
