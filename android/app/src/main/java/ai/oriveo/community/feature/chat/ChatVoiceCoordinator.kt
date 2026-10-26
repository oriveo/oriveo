package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.context.ContextDelivery
import ai.oriveo.community.core.model.ChatMessage
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.map

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
    /** A tool approval (MCP) is waiting for the user: the voice bar shows "waiting for you". */
    val approvalPending: Flow<Boolean>,
    private val messages: Flow<List<ChatMessage>>,
) {
    private val requestsFlow = MutableSharedFlow<Unit>(extraBufferCapacity = 1)

    /** ≋ on the chat composer; the voice conversation host subscribes. */
    val requests: SharedFlow<Unit> = requestsFlow

    fun request() {
        requestsFlow.tryEmit(Unit)
    }

    /** One voice turn; false = rejected before dispatch. */
    fun send(text: String): Boolean {
        val trimmed = text.trim()
        if (trimmed.isEmpty() || !conversationReady() || !claimSendSetup()) return false
        val (providerId, modelId) = selection()
        sendCommands.sendMessage(
            text = trimmed,
            attachments = null,
            providerId = providerId,
            modelId = modelId,
            delivery = ContextDelivery.VOICE,
        )
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
