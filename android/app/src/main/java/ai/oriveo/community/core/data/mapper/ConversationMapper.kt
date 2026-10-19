package ai.oriveo.community.core.data.mapper

import ai.oriveo.community.core.context.ContextBudgetCap
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
            instructions = instructions,
            contextCap = contextCap.toContextBudgetCapOrNull(),
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
        instructions = instructions,
        contextCap = contextCap?.toStorageText(),
    )

    /** Text stored in the local column: auto and unlimited as is, a custom cap as a decimal token count. */
    fun ContextBudgetCap.toStorageText(): String = when (this) {
        ContextBudgetCap.Auto -> "auto"
        ContextBudgetCap.Unlimited -> "unlimited"
        is ContextBudgetCap.Custom -> tokens.toString()
    }

    /** Stored text to cap; only "auto", "unlimited" and decimal integers without leading zeros (then range-checked by parse) are accepted, anything else gives null and follows the global default. */
    fun String?.toContextBudgetCapOrNull(): ContextBudgetCap? = when {
        this == null -> null
        this == "auto" || this == "unlimited" -> ContextBudgetCap.parse(this)
        STORAGE_DIGITS.matches(this) -> toIntOrNull()?.let(ContextBudgetCap::parse)
        else -> null
    }

    private val STORAGE_DIGITS = Regex("^[1-9][0-9]*$")
}
