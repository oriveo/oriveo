package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.attachments.OutboundAttachmentBudget
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.QuotePromptBuilder
import ai.oriveo.community.core.provider.MessageBuilder

/**
 * Outbound history: the messages this request will actually send to the provider (before attachment bytes are backfilled).
 *
 * Sending ([ChatRepository.sendMessage]) and the pre-send check share this one trimming chain, so route decisions (e.g. whether Gemini goes through
 * Interactions) get the same answer in both places.
 */
object OutboundHistory {
    suspend fun prepare(
        rawMessages: List<ChatMessage>,
        keepAssistantId: String? = null,
        imageSizeOf: suspend (String) -> Long,
        blobSizeOf: suspend (String) -> Long,
    ): List<ChatMessage> {
        // Pre-send normalization: drop assistant messages with empty content (to avoid an empty {"role":"assistant","content":""} triggering a persistent RST
        // from relay gateways), keep interrupted/failed assistant messages with partial text as context, and for adjacent user messages drop the older and keep the newer
        // (see MessageBuilder.sanitizeOutboundMessages). The latter fixes "after stopping, a new question gets answered together with the old one".
        val sanitized = MessageBuilder.sanitizeOutboundMessages(rawMessages, keepAssistantId = keepAssistantId)
        val quoted = QuotePromptBuilder.applyToMessages(sanitized)
        // Trim first, then backfill: history attachments over budget are never read from disk. The current input (the last
        // user message) is never trimmed; history images/videos are downgraded to placeholder lines, and history files keep the extracted text and drop the raw bytes.
        return OutboundAttachmentBudget.apply(messages = quoted, imageSizeOf = imageSizeOf, blobSizeOf = blobSizeOf)
    }

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
        return prepare(history + placeholder, imageSizeOf = imageSizeOf, blobSizeOf = blobSizeOf)
            .any { message -> message.attachments.orEmpty().any { it.kind == AttachmentKind.Video } }
    }
}
