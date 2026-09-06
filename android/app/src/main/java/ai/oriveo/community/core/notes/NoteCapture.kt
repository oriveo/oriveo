package ai.oriveo.community.core.notes

import ai.oriveo.community.core.data.repository.CreateNoteInput
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.NoteCaptureKind
import ai.oriveo.community.core.model.ProvenanceEntry
import ai.oriveo.community.core.model.ProvenanceKind
import ai.oriveo.community.core.model.ProviderKind

object NoteCapture {

    private fun previousUserPrompt(messages: List<ChatMessage>, targetId: String): String? {
        val idx = messages.indexOfFirst { it.id == targetId }
        if (idx <= 0) return null
        for (i in idx - 1 downTo 0) {
            val m = messages[i]
            if (m.role == ChatRole.User && m.text.isNotBlank()) return m.text
        }
        return null
    }

    fun fromMessage(
        message: ChatMessage,
        conversationId: String,
        messages: List<ChatMessage>,
    ): CreateNoteInput {
        val isUser = message.role == ChatRole.User
        return CreateNoteInput(
            body = message.text,
            bodySnapshot = message.text,
            captureKind = if (isUser) NoteCaptureKind.UserMessage else NoteCaptureKind.FullAnswer,
            sourceConversationId = conversationId,
            sourceMessageId = message.id,
            sourceModelID = message.modelID,
            sourceModelName = message.modelName,
            sourceProviderKind = message.providerKind,
            sourceProviderName = message.providerName,
            sourcePrompt = if (isUser) message.text else previousUserPrompt(messages, message.id),
        )
    }

    fun fromSelection(
        message: ChatMessage,
        selectedText: String,
        conversationId: String,
        messages: List<ChatMessage>,
    ): CreateNoteInput {
        val isUser = message.role == ChatRole.User

        val body = SelectionSourceMapper.extractSelectionMarkdown(message.text, selectedText) ?: selectedText
        return CreateNoteInput(
            body = body,
            bodySnapshot = message.text,
            captureKind = NoteCaptureKind.Selection,
            sourceConversationId = conversationId,
            sourceMessageId = message.id,
            sourceModelID = message.modelID,
            sourceModelName = message.modelName,
            sourceProviderKind = message.providerKind,
            sourceProviderName = message.providerName,
            sourcePrompt = if (isUser) message.text else previousUserPrompt(messages, message.id),
        )
    }

    fun fromCrosscheck(
        originalAnswer: String,
        originConversationId: String?,
        originMessageId: String?,
        originModelID: String?,
        originModelName: String?,
        originProviderKind: ProviderKind?,
        originProviderName: String?,
        originPrompt: String?,
        crosscheckProviderKind: ProviderKind,
        crosscheckProviderName: String,
        crosscheckModelID: String?,
        crosscheckModelName: String,
        crosscheckText: String,
        originAtIso: String,
        nowIso: String,
    ): CreateNoteInput {
        val body = buildString {
            append("## Original answer\n\n")
            append(originalAnswer.trim())
            append("\n\n## Cross-check (")
            append(crosscheckModelName)
            append(")\n\n")
            append(crosscheckText.trim())
        }
        return CreateNoteInput(
            body = body,
            bodySnapshot = originalAnswer,
            captureKind = NoteCaptureKind.FullAnswer,
            sourceConversationId = originConversationId,
            sourceMessageId = originMessageId,
            sourceModelID = originModelID,
            sourceModelName = originModelName,
            sourceProviderKind = originProviderKind,
            sourceProviderName = originProviderName,
            sourcePrompt = originPrompt,
            provenance = listOf(
                ProvenanceEntry(
                    kind = ProvenanceKind.Origin,
                    modelID = originModelID,
                    modelName = originModelName,
                    providerKind = originProviderKind,
                    providerName = originProviderName,
                    conversationId = originConversationId,
                    messageId = originMessageId,
                    at = originAtIso,
                ),
                ProvenanceEntry(
                    kind = ProvenanceKind.Crosscheck,
                    modelID = crosscheckModelID,
                    modelName = crosscheckModelName,
                    providerKind = crosscheckProviderKind,
                    providerName = crosscheckProviderName,
                    conversationId = originConversationId,
                    messageId = originMessageId,
                    at = nowIso,
                ),
            ),
        )
    }
}
