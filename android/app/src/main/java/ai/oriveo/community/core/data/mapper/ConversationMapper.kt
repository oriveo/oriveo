package ai.oriveo.community.core.data.mapper

import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.entity.ConversationEntity
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.util.normalizeConversationIds
import ai.oriveo.community.core.util.normalizeUuid
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

object ConversationMapper {

    private val json = Json { ignoreUnknownKeys = true; coerceInputValues = true }

    fun ConversationEntity.toDomain(
        messages: List<ChatMessage> = emptyList(),
        messageCount: Int = messages.size,
    ): Conversation =
        normalizeConversationIds(Conversation(
            id = id,
            title = title,
            hasCustomTitle = hasCustomTitle,
            providerID = providerID,
            providerKind = ProviderKind.valueOf(providerKind),
            modelID = modelID,
            useMemory = useMemory,
            previewText = previewText,
            estimatedCost = estimatedCost,
            isDraft = isDraft,
            messages = messages,
            messageCount = messageCount,
            draftText = draftText,
            folderID = folderID,
            skillId = skillId,
            createdAt = createdAt,
            updatedAt = updatedAt,
            pinnedNoteIds = pinnedNoteIdsJson?.let {
                runCatching { json.decodeFromString<List<String>>(it) }.getOrDefault(emptyList())
            }?.map(::normalizeUuid) ?: emptyList(),
        ))

    fun Conversation.toEntity(accountId: String = LOCAL_PARTITION_ID): ConversationEntity = ConversationEntity(
        id = normalizeUuid(id),
        title = title,
        hasCustomTitle = hasCustomTitle,
        providerID = normalizeUuid(providerID),
        providerKind = providerKind.name,
        modelID = modelID,
        useMemory = useMemory,
        previewText = previewText,
        estimatedCost = estimatedCost,
        isDraft = isDraft,
        draftText = draftText,
        folderID = folderID?.let(::normalizeUuid),
        skillId = skillId,
        createdAt = createdAt,
        updatedAt = updatedAt,
        accountId = accountId,
        pinnedNoteIdsJson = pinnedNoteIds.map(::normalizeUuid).distinct()
            .takeIf { it.isNotEmpty() }
            ?.let { json.encodeToString(it) },
    )
}
