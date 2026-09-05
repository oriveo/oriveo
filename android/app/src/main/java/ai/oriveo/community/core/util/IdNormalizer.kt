package ai.oriveo.community.core.util

import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.Provider
import java.util.UUID

private val UUID_REGEX =
    Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", RegexOption.IGNORE_CASE)

fun normalizeUuid(id: String): String =
    if (UUID_REGEX.matches(id)) id.uppercase() else id

fun sameNormalizedUuid(a: String?, b: String?): Boolean {
    if (a == null || b == null) return a == b
    return normalizeUuid(a) == normalizeUuid(b)
}


fun canonicalSyncId(raw: String): String =
    raw.split(':').joinToString(":") { if (UUID_REGEX.matches(it)) it.lowercase() else it }

fun generateUuidString(): String = UUID.randomUUID().toString().uppercase()

fun normalizeAttachmentIds(attachment: Attachment): Attachment = attachment.copy(
    id = normalizeUuid(attachment.id),
    localImageId = attachment.localImageId?.let(::normalizeUuid),
)

fun normalizeMessageIds(message: ChatMessage): ChatMessage = message.copy(
    id = normalizeUuid(message.id),
    providerID = message.providerID?.let(::normalizeUuid),
    
    
    attachments = message.attachments?.map(::normalizeAttachmentIds)?.distinctBy { it.id },
)

fun normalizeConversationIds(conversation: Conversation): Conversation = conversation.copy(
    id = normalizeUuid(conversation.id),
    providerID = normalizeUuid(conversation.providerID),
    folderID = conversation.folderID?.let(::normalizeUuid),
    messages = conversation.messages.map(::normalizeMessageIds),
)

fun normalizeProviderIds(provider: Provider): Provider = provider.copy(
    id = normalizeUuid(provider.id),
)

fun <T> dedupeByNormalizedId(
    items: Iterable<T>,
    idSelector: (T) -> String,
    pickPreferred: (T, T) -> T,
): List<T> {
    val result = LinkedHashMap<String, T>()
    for (item in items) {
        val key = normalizeUuid(idSelector(item))
        val existing = result[key]
        result[key] = if (existing == null) item else pickPreferred(existing, item)
    }
    return result.values.toList()
}
