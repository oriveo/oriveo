package ai.oriveo.community.core.model

import androidx.compose.runtime.Immutable
import kotlinx.serialization.Serializable

/** A conversation, as the rest of the app sees it. */
@Immutable
@Serializable
data class Conversation(
    val id: String,
    val title: String,
    val hasCustomTitle: Boolean = false,
    val providerID: String,
    /**
     * Which provider this conversation belongs to. Only used to pick an icon and a label, so an
     * unrecognized value resolves to a neutral placeholder instead of failing to load the row.
     */
    val providerKind: ProviderKind,
    val modelID: String,
    val useMemory: Boolean = true,
    val previewText: String = "",
    val estimatedCost: Double = 0.0,
    val isDraft: Boolean = false,
    val messages: List<ChatMessage> = emptyList(),
    /** Message count for the list row, read with a COUNT rather than by loading [messages]. */
    @kotlinx.serialization.Transient
    val messageCount: Int = 0,
    val draftText: String = "",
    /** Folder this conversation sits in; null means it is unfiled. */
    val folderID: String? = null,
    /** Skill the conversation was started from, if any. */
    val skillId: String? = null,
    val createdAt: Long = System.currentTimeMillis(),
    val updatedAt: Long = System.currentTimeMillis(),
    /** Soft delete. Null means the conversation is live. */
    @kotlinx.serialization.Transient
    val deletedAt: Long? = null,
    /** Up to three notes pinned into this conversation's prompt. */
    val pinnedNoteIds: List<String> = emptyList(),
) {
    val estimatedCostText: String
        get() = CostFormatter.format(estimatedCost)

    /**
     * Whether two copies of a conversation carry the same user-authored settings.
     *
     * Only the fields the user can change directly are compared. Message content, cost and
     * preview text are derived from the messages themselves, so including them would report a
     * difference for two copies that the user would call identical.
     */
    fun contentEquals(other: Conversation): Boolean {
        return title == other.title &&
            hasCustomTitle == other.hasCustomTitle &&
            folderID == other.folderID &&
            skillId == other.skillId &&
            providerID == other.providerID &&
            providerKind == other.providerKind &&
            modelID == other.modelID &&
            useMemory == other.useMemory &&
            pinnedNoteIds == other.pinnedNoteIds
    }
}

private const val AUTO_CONVERSATION_TITLE_MAX = 50
private const val CONVERSATION_PREVIEW_MAX = 200

data class ConversationDerivedMetadata(
    val title: String,
    val previewText: String,
)

fun makeConversationPreviewText(message: ChatMessage): String {
    var preview = message.text.trim()

    message.attachments?.forEach { attachment ->
        val label = when (attachment.kind) {
            AttachmentKind.Image -> "📷 Photo"
            AttachmentKind.Video -> "🎬 ${attachment.fileName}"
            AttachmentKind.File -> "📎 ${attachment.fileName}"
        }
        preview = if (preview.isEmpty()) label else "$label $preview"
    }

    if (preview.length > CONVERSATION_PREVIEW_MAX) {
        preview = preview.take(CONVERSATION_PREVIEW_MAX)
    }

    return preview
}

fun makeAutoConversationTitle(message: ChatMessage): String {
    var text = message.text.trim().replace(Regex("\\s+"), " ")

    val attachments = message.attachments
    if (!attachments.isNullOrEmpty()) {
        val hasImage = attachments.any { it.kind == AttachmentKind.Image }
        val hasVideo = attachments.any { it.kind == AttachmentKind.Video }
        val hasFile = attachments.any { it.kind == AttachmentKind.File }
        if (text.isEmpty()) {
            text = when {
                hasImage -> "📷 Photo"
                hasVideo -> "🎬 ${attachments.firstOrNull { it.kind == AttachmentKind.Video }?.fileName ?: "Video"}"
                else -> "📎 ${attachments.first()?.fileName ?: "File"}"
            }
        } else {
            var prefix = ""
            if (hasImage) prefix += "📷 "
            if (hasVideo) prefix += "🎬 "
            if (hasFile) prefix += "📎 "
            text = prefix + text
        }
    }

    return text.take(AUTO_CONVERSATION_TITLE_MAX)
}

fun lastDeliveredMessage(messages: List<ChatMessage>): ChatMessage? =
    messages.lastOrNull { it.state == ChatMessageState.Delivered }

fun lastDeliveredUserMessage(messages: List<ChatMessage>): ChatMessage? =
    messages.lastOrNull { it.role == ChatRole.User && it.state == ChatMessageState.Delivered }

fun deriveConversationMetadata(
    conversation: Conversation,
    messages: List<ChatMessage>,
): ConversationDerivedMetadata {
    val previewText = lastDeliveredMessage(messages)?.let(::makeConversationPreviewText)
        ?: conversation.previewText

    val title = if (!conversation.hasCustomTitle) {
        lastDeliveredUserMessage(messages)?.let(::makeAutoConversationTitle)
            ?.takeIf { it.isNotEmpty() }
            ?: conversation.title
    } else {
        conversation.title
    }

    return ConversationDerivedMetadata(
        title = title,
        previewText = previewText,
    )
}

/**
 * When the conversation last saw activity, used for list ordering.
 *
 * This is the last delivered message's timestamp, not `updatedAt`: renaming a conversation or
 * moving it to a folder should not push it to the top of a list sorted by when it was last used.
 */
fun computeConversationActivityAt(
    messages: List<ChatMessage>,
    conversationCreatedAt: Long,
): Long {
    val lastCreatedAt = lastDeliveredMessage(messages)?.createdAt
    return lastCreatedAt ?: conversationCreatedAt
}
