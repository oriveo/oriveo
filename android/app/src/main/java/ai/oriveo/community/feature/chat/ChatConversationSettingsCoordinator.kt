package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.data.repository.ChatContextRejection
import ai.oriveo.community.core.data.repository.ChatContextRejections
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.memory.MemoryCandidateRepository
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.notice.DirectiveSuggestionStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

/**
 * Conversation settings: saving conversation instructions / stashing drafts / the inherit-from source, and the "set as instruction" suggestion strip.
 * Extracted from ChatViewModel; the VM keeps only a one-line forward.
 */
internal class ChatConversationSettingsCoordinator(
    private val scope: CoroutineScope,
    private val conversationRepository: ConversationRepository,
    private val activeConversationId: StateFlow<String?>,
    /** Local dismissal counter for "set as instruction" suggestions; when null (unit tests etc.) no suggestion is shown. */
    directiveSuggestionStore: DirectiveSuggestionStore?,
    showToast: (GlobalSnackbarMessage) -> Unit,
    /** The candidate repository and partition behind the memory strip button; when null the button on the strip does nothing. */
    memoryCandidates: MemoryCandidateRepository? = null,
    memoryAccountId: () -> String = { "" },
    /** App-level scope: saving / dismissing / undoing from the memory strip must still complete after leaving the chat screen. */
    memoryScope: CoroutineScope = scope,
    /** Rejected-send / cancelled-confirmation rollback events; the two suggestion strips attached to the rolled-back send are withdrawn with them. */
    private val contextRejections: Flow<ChatContextRejection> = ChatContextRejections.shared.events,
) {
    /**
     * Instructions written in the settings sheet before the conversation row exists; written into the new conversation on the first send, and cleared when a new chat is started.
     */
    private val _pendingDraftInstructions = MutableStateFlow("")
    val pendingDraftInstructions: StateFlow<String> = _pendingDraftInstructions

    /** The "set as instruction" suggestion below the user message that was just sent. */
    val directiveSuggestions: DirectiveSuggestionController? = directiveSuggestionStore?.let { store ->
        DirectiveSuggestionController(
            scope = scope,
            store = store,
            instructionsOf = { id -> conversationRepository.getWithMessages(id)?.instructions },
            writeInstructions = { id, text -> conversationRepository.updateInstructions(id, text) },
            showToast = showToast,
        )
    }

    /** The pending suggestion of the current conversation; the list draws it below [DirectiveSuggestion.messageId]. */
    val directiveSuggestion: StateFlow<DirectiveSuggestion?> =
        (directiveSuggestions?.pending ?: MutableStateFlow(emptyMap()))
            .combine(activeConversationId) { pending, conversationId -> conversationId?.let(pending::get) }
            .stateIn(scope, SharingStarted.Eagerly, null)

    /** The "Save to memory?" strip and its buttons; discarding on conversation switch follows [activeConversationId] in the controller itself. */
    val memorySuggestions = MemorySuggestionController(
        scope = scope,
        activeConversationId = activeConversationId,
        latestUserMessageId = { id ->
            conversationRepository.getWithMessages(id)?.messages?.lastOrNull { it.role == ChatRole.User }?.id
        },
        actionScope = memoryScope,
        candidates = memoryCandidates,
        items = memoryCandidates?.items,
        accountId = memoryAccountId,
        showToast = showToast,
        observeMessages = { id -> conversationRepository.observeWithMessages(id).map { it?.messages.orEmpty() } },
    )

    init {
        // Drop other conversations' pending suggestions when the conversation switches (not counted as a dismissal).
        directiveSuggestions?.let { controller ->
            activeConversationId.onEach { controller.retainOnly(it) }.launchIn(scope)
        }
        // A cancelled confirmation (including tapping stop while waiting) rolled back this send: the "set as instruction" and "Save to memory?" strips attached to the deleted user message
        // are withdrawn together (not counted as a dismissal); withdrawn by message id, so strips of other messages in the same conversation are untouched.
        contextRejections.filter { it.rolledBack }.onEach { rejection ->
            val messageId = rejection.userMessageId ?: return@onEach
            directiveSuggestions?.withdraw(rejection.conversationId, messageId)
            memorySuggestions.withdraw(rejection.conversationId, messageId)
        }.launchIn(scope)
    }

    fun acceptSuggestion() {
        activeConversationId.value?.let { directiveSuggestions?.accept(it) }
    }

    fun ignoreSuggestion() {
        activeConversationId.value?.let { directiveSuggestions?.ignore(it) }
    }

    /** The draft instructions were written into the new conversation row by create(), or a new chat was opened: clear the stash. */
    fun clearDraftInstructions() {
        _pendingDraftInstructions.value = ""
    }

    /**
     * The settings sheet closed: values unchanged after normalization are not written.
     * With no conversation row, writes only into [pendingDraftInstructions].
     */
    fun saveInstructions(opened: String, edited: String) {
        // Compare against the snapshot taken at open, not the live value: an untouched edit box must not write back remote changes that arrived while the sheet was open.
        val toSave = ConversationSettings.instructionsToSave(opened, edited) ?: return
        val conversationId = activeConversationId.value
        if (conversationId == null) {
            _pendingDraftInstructions.value = toSave
            return
        }
        scope.launch { conversationRepository.updateInstructions(conversationId, toSave) }
    }

    /** The inherit-from source of the settings sheet; when null the shortcut entry is hidden. */
    suspend fun instructionsCarryOver(currentInstructions: String): String? =
        ConversationSettings.carryOverSource(
            conversationRepository.observeAll().first(),
            currentConversationId = activeConversationId.value,
            currentInstructions = currentInstructions,
        )
}
