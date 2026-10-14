package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.OutboundHistory
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.mapLatest
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.withContext

/**
 * Outbound history used for pre-send decisions (pre-check, model panel file card): the same [OutboundHistory] trimming chain as ChatRepository sending,
 * so route decisions (whether Gemini goes through Interactions) match what is actually sent.
 */
internal class ChatOutboundHistoryProbe(
    storeProvider: () -> AttachmentStore,
    private val conversationRepository: ConversationRepository,
) {
    // The attachment budget reads file size only.
    private val attachmentStore by lazy(storeProvider)

    /** Pre-check: given "conversation history + the user message about to be sent", produce this request's outbound history. */
    suspend fun trim(raw: List<ChatMessage>): List<ChatMessage> = withContext(Dispatchers.IO) {
        OutboundHistory.prepare(
            rawMessages = raw,
            imageSizeOf = { id -> attachmentStore.imageSizeBytes(id) },
            blobSizeOf = { ref -> attachmentStore.blobSizeBytes(ref) },
        )
    }

    /** Model panel file card: whether the next send's outbound history (conversation history + a placeholder for the current turn) contains a video; draft attachments are not counted. */
    @OptIn(ExperimentalCoroutinesApi::class)
    fun hasVideoFlow(conversation: Flow<ConversationRenderState>, scope: CoroutineScope): StateFlow<Boolean> = conversation
        // The window holds only the trailing messages; when the conversation changes it is recomputed from the whole history. The dedup key includes the last message's state and whether its body is empty:
        // a streaming answer placeholder (empty body, dropped by outbound normalization) keeps its id when persisted as delivered, but the outbound answer changes.
        .map { state ->
            val last = state.conversation?.messages?.lastOrNull()
            OutboundProbeKey(state.conversation?.id, last?.id, last?.state, last?.text.isNullOrBlank())
        }
        .distinctUntilChanged()
        .mapLatest { key ->
            val conversationId = key.conversationId
            val history = conversationId?.let { conversationRepository.getWithMessages(it)?.messages }.orEmpty()
            OutboundHistory.nextSendHasVideo(
                history,
                imageSizeOf = { id -> attachmentStore.imageSizeBytes(id) },
                blobSizeOf = { ref -> attachmentStore.blobSizeBytes(ref) },
            )
        }
        .stateIn(scope, SharingStarted.WhileSubscribed(5000), false)

    private data class OutboundProbeKey(
        val conversationId: String?,
        val lastMessageId: String?,
        val lastState: ChatMessageState?,
        val lastTextBlank: Boolean,
    )
}
