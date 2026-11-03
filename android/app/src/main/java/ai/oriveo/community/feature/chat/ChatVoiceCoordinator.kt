package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.context.ContextDelivery
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.voice.conversation.joinAmend
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map

/**
 * Builds the chat page's [ChatVoiceCoordinator] from [ChatViewModel]'s raw sources: the approval-pending signal
 * (MCP, library, pre-send confirmation) and the open conversation's rejections are assembled here.
 */
internal fun chatVoiceCoordinator(
    conversationReady: () -> Boolean,
    claimSendSetup: () -> Boolean,
    sendCommands: ChatSendCommandCoordinator,
    selection: () -> Pair<String?, String?>,
    mcpPending: Flow<List<*>>?,
    libraryPending: Flow<List<*>>,
    /** Pre-send confirmation of the shown conversation; read on collect (the VM declares compaction later). */
    contextCapPending: () -> Flow<Any?>?,
    conversation: Flow<ConversationRenderState>,
    currentConversation: () -> ai.oriveo.community.core.model.Conversation?,
    amendLast: (String, VoiceAmendTarget?, () -> Unit) -> Boolean,
    rejections: Flow<ai.oriveo.community.core.data.repository.ChatContextRejection>,
    activeConversationId: () -> String?,
): ChatVoiceCoordinator = ChatVoiceCoordinator(
    sendCommands = sendCommands,
    conversationReady = conversationReady,
    claimSendSetup = claimSendSetup,
    selection = selection,
    approvalPending = combine(
        mcpPending ?: flowOf(emptyList<Any>()),
        libraryPending,
        flow { emitAll(contextCapPending() ?: flowOf(null)) },
    ) { mcp, library, contextCap -> mcp.isNotEmpty() || library.isNotEmpty() || contextCap != null },
    messages = conversation.map { it.conversation?.messages.orEmpty() },
    currentMessages = { currentConversation()?.messages.orEmpty() },
    amendLast = amendLast,
    rejections = rejections.filter { it.conversationId == activeConversationId() },
)

/**
 * Voice conversation of the chat page, kept out of [ChatViewModel]: the ≋ requests,
 * the entry gates and the `delivery = VOICE` turn. A turn passes the same gates as a typed send
 * ([conversationReady], then [claimSendSetup] = setup guard + busy stream), never reads or clears the composer.
 */
internal class ChatVoiceCoordinator(
    private val sendCommands: ChatSendCommandCoordinator,
    /** False also records the blocked send (conversation not ready). */
    private val conversationReady: () -> Boolean,
    /** True = the send setup guard was free and the conversation is not streaming; the guard is now taken. */
    private val claimSendSetup: () -> Boolean,
    private val selection: () -> Pair<String?, String?>,
    /**
     * A tool approval (MCP or library) or the pre-send confirmation is waiting for the user: the voice bar shows
     * "waiting for you".
     */
    val approvalPending: Flow<Boolean>,
    private val messages: Flow<List<ChatMessage>>,
    /** The open conversation's messages right now (the same list [messages] emits). */
    private val currentMessages: () -> List<ChatMessage> = { emptyList() },
    /**
     * Appends to the target user message and regenerates; false = nothing to amend. The callback fires when,
     * after true, the amend still could not go out.
     */
    private val amendLast: (String, VoiceAmendTarget?, () -> Unit) -> Boolean = { _, _, _ -> false },
    /** Context rejections of the open conversation (ChatContextRejections); rollbacks end a voice turn. */
    private val rejections: Flow<ai.oriveo.community.core.data.repository.ChatContextRejection> = kotlinx.coroutines.flow.emptyFlow(),
) {
    /**
     * The latest voice turn: what it sent, the user messages that existed before it, and the message it rewrote
     * (an amend). Its user message is the rewritten one while the conversation still has it, else the first user
     * message that was not there before (a send landing, or the new send an amend fell back to).
     */
    private class Turn(val text: String, val priorUserIds: Set<String>, val userMessageId: String?) {
        fun userMessage(list: List<ChatMessage>): String? =
            userMessageId?.takeIf { id -> list.any { it.id == id } }
                ?: list.firstOrNull { it.role == ChatRole.User && it.id !in priorUserIds }?.id
    }

    private var turn: Turn? = null

    private fun userMessageIds(): Set<String> =
        currentMessages().filter { it.role == ChatRole.User }.mapTo(mutableSetOf()) { it.id }

    /**
     * The user message of the latest voice turn once the conversation has it; null while it has not landed (or was
     * rolled back). Before any voice turn: the last user message, the target an amend had before turns were tracked.
     */
    val turnUserMessageId: Flow<String?> = messages.map { list ->
        turn?.userMessage(list) ?: list.takeIf { turn == null }?.lastOrNull { it.role == ChatRole.User }?.id
    }

    /**
     * The latest voice turn never reaches a reply: its new user message was rolled back at the pre-send confirmation
     * (the user cancelled the dialog, or stopped while it waited), or the context plan refused the send (no user
     * message to name; the open conversation and the turn's text identify it).
     */
    val turnRolledBack: Flow<Unit> = rejections
        .filter { rejection ->
            val current = turn ?: return@filter false
            if (rejection.text != current.text) return@filter false
            val id = rejection.userMessageId ?: return@filter true
            rejection.rolledBack && id !in current.priorUserIds
        }
        .map { }

    private val requestsFlow = MutableSharedFlow<Unit>(extraBufferCapacity = 1)

    /** ≋ on the chat composer; the voice conversation host subscribes. */
    val requests: SharedFlow<Unit> = requestsFlow

    fun request() {
        requestsFlow.tryEmit(Unit)
    }

    /**
     * One voice turn; false = rejected before dispatch. [attachments] and [quoteContext] are only set by the amend
     * fallback, which resends a rolled-back message with what it carried. [onBlocked] = after true, the send
     * was refused on its async path (a gate, the disclosure, an error) and never went out.
     */
    fun send(
        text: String,
        attachments: List<ai.oriveo.community.core.model.Attachment>? = null,
        quoteContext: ai.oriveo.community.core.model.QuoteContext? = null,
        onBlocked: () -> Unit = {},
    ): Boolean {
        val trimmed = text.trim()
        if (trimmed.isEmpty() || !conversationReady() || !claimSendSetup()) return false
        val (providerId, modelId) = selection()
        turn = Turn(trimmed, userMessageIds(), null)
        sendCommands.sendMessage(
            text = trimmed,
            attachments = attachments,
            providerId = providerId,
            modelId = modelId,
            quoteContext = quoteContext,
            delivery = ContextDelivery.VOICE,
            onBlocked = onBlocked,
        )
        return true
    }

    /**
     * Barge-in while thinking: [text] joins the turn's user message [userMessageId] in place (null = it never
     * landed), then the reply regenerates; a turn rolled back meanwhile is sent anew as joinAmend(its text, [text]).
     * [onFailed] = after true, the amend could not go out after all.
     */
    fun amend(text: String, userMessageId: String?, onFailed: () -> Unit = {}): Boolean {
        val current = turn
        val original = current?.text ?: currentMessages().firstOrNull { it.id == userMessageId }?.text
        val target = original?.let { VoiceAmendTarget(userMessageId, it) }
        val prior = userMessageIds()
        if (!amendLast(text, target, onFailed)) return false
        if (target != null) turn = Turn(joinAmend(target.originalText, text), prior, userMessageId)
        return true
    }

    /** the send gates, in send order, for entering a voice conversation (prompts shown on a block). */
    suspend fun entryAllowed(): Boolean {
        if (!conversationReady()) return false
        val (providerId, modelId) = selection()
        return sendCommands.voiceEntryAllowed(providerId, modelId)
    }

    /** The message [messageId] as the open conversation has it (voice reply outcome). */
    fun replyMessage(messageId: String): Flow<ChatMessage?> =
        messages.map { list -> list.firstOrNull { it.id == messageId } }
}
