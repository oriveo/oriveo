package ai.oriveo.community.core.data.mapper

import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.entity.SkillEntity
import ai.oriveo.community.core.model.Skill
import ai.oriveo.community.core.model.SkillKnowledgeBase
import ai.oriveo.community.core.model.SkillKnowledgeFile
import ai.oriveo.community.core.model.SkillSource
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

object SkillMapper {

    private val json = Json { ignoreUnknownKeys = true; coerceInputValues = true }

    private fun decodeLocaleMap(raw: String): Map<String, String> =
        runCatching { json.decodeFromString<Map<String, String>>(raw) }.getOrDefault(emptyMap())

    fun SkillEntity.toDomain(): Skill = Skill(
        id = id,
        key = key,
        name = name,
        description = description,
        icon = icon,
        color = color,
        systemPrompt = systemPrompt,
        whenToUse = whenToUse,
        autoInvoke = autoInvoke,
        iconKey = iconKey,
        whenToUseTranslations = decodeLocaleMap(whenToUseTranslationsJson),
        previewUser = decodeLocaleMap(previewUserJson),
        previewAssistant = decodeLocaleMap(previewAssistantJson),
        suggestedProviderId = suggestedProviderId,
        suggestedModelId = suggestedModelId,
        modelCapabilityHint = modelCapabilityHint,
        temperature = temperature,
        reasoningLevel = reasoningLevel,
        webSearchEnabled = webSearchEnabled,
        starterMessages = runCatching {
            json.decodeFromString<List<String>>(starterMessagesJson)
        }.getOrDefault(emptyList()),
        knowledgeFiles = runCatching {
            json.decodeFromString<List<SkillKnowledgeFile>>(knowledgeFilesJson)
        }.getOrDefault(emptyList()),
        knowledgeBase = knowledgeBaseJson?.let {
            runCatching {
                json.decodeFromString<SkillKnowledgeBase>(it)
            }.getOrNull()
        },
        useMemory = useMemory,
        isPinned = isPinned,
        pinOrder = pinOrder,
        source = SkillSource.from(source),
        forkedFromId = forkedFromId,
        category = category,
        sortOrder = sortOrder,
        usageCount = usageCount,
        lastUsedAt = lastUsedAt,
        createdAt = createdAt,
        updatedAt = updatedAt,
    )

    fun Skill.toEntity(accountId: String = LOCAL_PARTITION_ID): SkillEntity = SkillEntity(
        id = id,
        accountId = accountId,
        key = key,
        name = name,
        description = description,
        icon = icon,
        color = color,
        systemPrompt = systemPrompt,
        whenToUse = whenToUse,
        autoInvoke = autoInvoke,
        iconKey = iconKey,
        whenToUseTranslationsJson = json.encodeToString(whenToUseTranslations),
        previewUserJson = json.encodeToString(previewUser),
        previewAssistantJson = json.encodeToString(previewAssistant),
        suggestedProviderId = suggestedProviderId,
        suggestedModelId = suggestedModelId,
        modelCapabilityHint = modelCapabilityHint,
        temperature = temperature,
        reasoningLevel = reasoningLevel,
        webSearchEnabled = webSearchEnabled,
        starterMessagesJson = json.encodeToString(starterMessages),
        knowledgeFilesJson = json.encodeToString(knowledgeFiles),
        knowledgeBaseJson = knowledgeBase?.let { json.encodeToString(it) },
        useMemory = useMemory,
        isPinned = isPinned,
        pinOrder = pinOrder,
        source = source.value,
        forkedFromId = forkedFromId,
        category = category,
        sortOrder = sortOrder,
        usageCount = usageCount,
        lastUsedAt = lastUsedAt,
        createdAt = createdAt,
        updatedAt = updatedAt,
    )
}
