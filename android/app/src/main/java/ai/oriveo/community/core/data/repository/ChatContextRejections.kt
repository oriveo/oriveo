package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.context.ContextReject
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.QuoteContext
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow

/**
 * A chat send refused by the context budget: no request was made and no user / assistant message was persisted;
 * or rolled back after the pre-send confirmation was cancelled ([rolledBack] is true and [reject] is null): no request was made, and this turn's user / assistant placeholders were deleted from the device.
 */
data class ChatContextRejection(
    val conversationId: String,
    /** Reason for the refusal; null when rolled back after a cancelled confirmation. */
    val reject: ContextReject?,
    /** The original input text and attachments of this turn; the chat screen puts them back into the composer when [restoresComposer] is true. */
    val text: String,
    val attachments: List<Attachment>?,
    /** The quote of this turn: restored into the composer exactly as before sending. */
    val quoteContext: QuoteContext? = null,
    /** True for send / edit-and-send; for retry / regenerate the user message is already in the history, so there is no input to put back. */
    val restoresComposer: Boolean,
    /** Rollback after the pre-send confirmation was cancelled (or stop was tapped while waiting): the chat screen shows no refusal notice and only refills the draft when it is empty. */
    val rolledBack: Boolean = false,
    /** The user message deleted by the rollback: suggestion chips hanging under it are withdrawn by this id; null when no user message was deleted. */
    val userMessageId: String? = null,
)

/**
 * Refusal event channel from ChatRepository to the chat screen (an in-process singleton, like RelayWebReplyNotices).
 * Sending runs inside a streaming session on the ApplicationScope, so the chat screen can only subscribe here to get the result.
 */
class ChatContextRejections {
    private val flow = MutableSharedFlow<ChatContextRejection>(extraBufferCapacity = 8)

    val events: SharedFlow<ChatContextRejection> = flow.asSharedFlow()

    fun emit(rejection: ChatContextRejection) {
        flow.tryEmit(rejection)
    }

    companion object {
        val shared = ChatContextRejections()
    }
}
