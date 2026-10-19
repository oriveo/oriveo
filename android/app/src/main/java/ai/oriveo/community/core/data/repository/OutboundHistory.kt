package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.attachments.OutboundAttachmentBudget
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.context.ChatContextRequest
import ai.oriveo.community.core.context.ContextBudget
import ai.oriveo.community.core.context.ContextConversation
import ai.oriveo.community.core.context.ContextMaxOutput
import ai.oriveo.community.core.context.ContextWindowInput
import ai.oriveo.community.core.context.ContextWindowKind

/**
 * Outbound history: the messages this request will actually send to the provider (before attachment bytes are backfilled).
 *
 * Sending ([ChatRepository.sendMessage]) and the pre-send check share one assembler projection and one attachment budget, so route
 * decisions (e.g. whether Gemini goes through Interactions) get the same answer in both places.
 */
object OutboundHistory {
    /**
     * Outbound history for the pre-send check: the same ContextAssembler projection as sending (normalization,
     * quotes and the unanswered envelope all live in the projection), then the same attachment budget.
     * The check ignores system prompt, memory and window, so it uses an empty context and an unwindowed projection.
     * When the last message is not a user message (the projection yields no plan), there is no outbound history.
     */
    suspend fun projected(
        rawMessages: List<ChatMessage>,
        imageSizeOf: suspend (String) -> Long,
        blobSizeOf: suspend (String) -> Long,
    ): List<ChatMessage> {
        val projection = ChatContextProjector.project(
            request = ChatContextRequest(conversation = ContextConversation(id = PROBE_CONVERSATION_ID, useMemory = false)),
            rawMessages = rawMessages,
            window = ContextWindowInput(W = null, windowKind = ContextWindowKind.TOTAL, maxOutput = ContextMaxOutput(null, null, null)),
            rhoHi = ContextBudget.RHO0,
        )
        return budgetProjected(messages = projection?.messages.orEmpty(), imageSizeOf = imageSizeOf, blobSizeOf = blobSizeOf)
    }

    private const val PROBE_CONVERSATION_ID = "outbound-history-probe"

    /**
     * Main chat path: normalization and quotes are already done by the ContextAssembler projection; this only applies the attachment budget.
     */
    suspend fun budgetProjected(
        messages: List<ChatMessage>,
        imageSizeOf: suspend (String) -> Long,
        blobSizeOf: suspend (String) -> Long,
    ): List<ChatMessage> = OutboundAttachmentBudget.apply(messages = messages, imageSizeOf = imageSizeOf, blobSizeOf = blobSizeOf)

    /**
     * Before the current turn is typed, whether the next send's outbound history contains a video: a placeholder user message (no attachments) is appended to the conversation history
     * to represent the current turn and goes through the same trimming chain. Draft attachments that are unavailable are not counted (same rule as iOS).
     */
    suspend fun nextSendHasVideo(
        history: List<ChatMessage>,
        imageSizeOf: suspend (String) -> Long,
        blobSizeOf: suspend (String) -> Long,
    ): Boolean {
        if (history.none { message -> message.attachments.orEmpty().any { it.kind == AttachmentKind.Video } }) return false
        val anchor = history.last()
        // The placeholder body must not be empty: an empty user message is dropped by normalization, the current turn would no longer be the last user message, and the budget exemption would fall on history.
        val placeholder = ChatMessage(
            id = "outbound-history-probe",
            role = ChatRole.User,
            text = "…",
            providerKind = anchor.providerKind,
            providerName = anchor.providerName,
            modelName = anchor.modelName,
            state = ChatMessageState.Delivered,
        )
        return projected(history + placeholder, imageSizeOf = imageSizeOf, blobSizeOf = blobSizeOf)
            .any { message -> message.attachments.orEmpty().any { it.kind == AttachmentKind.Video } }
    }
}
