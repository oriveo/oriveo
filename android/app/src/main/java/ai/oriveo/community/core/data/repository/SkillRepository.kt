package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.EntityMapper.toDomain
import ai.oriveo.community.core.data.EntityMapper.toEntity
import ai.oriveo.community.core.data.dao.SkillDao
import ai.oriveo.community.core.model.Skill
import ai.oriveo.community.core.model.SkillCategory
import ai.oriveo.community.core.model.SkillKnowledgeFile
import ai.oriveo.community.core.model.SkillSource
import ai.oriveo.community.core.util.generateUuidString
import java.time.Instant
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.map

@OptIn(ExperimentalCoroutinesApi::class)
class SkillRepository(
    private val dao: SkillDao,
    private val catalogStore: SkillCatalogPrefsStore,
) {
    private val _categories = MutableStateFlow<List<SkillCategory>>(emptyList())
    val categories: StateFlow<List<SkillCategory>> = _categories.asStateFlow()

    private val accountId: String get() = LOCAL_PARTITION_ID

    fun prewarm() {
        val snapshot = catalogStore.load()
        _categories.value = snapshot.categories
    }

    fun observeCatalogSkills(): Flow<List<Skill>> =
        dao.observeBySource(accountId, "builtin").map { entities ->
            entities.map { it.toDomain() }
        }

    fun observeUserSkills(): Flow<List<Skill>> =
        dao.observeBySource(accountId, "user").map { entities ->
            entities.map { it.toDomain() }
        }

    fun observeAllSkills(): Flow<List<Skill>> =
        dao.observeAll(accountId).map { entities ->
            entities.map { it.toDomain() }
        }

    suspend fun refreshAll() {
        // Local-only: Room is already the source of truth.
    }

    suspend fun create(request: CreateSkillRequest): Skill {
        val now = Instant.now().toString()
        val skill = Skill(
            id = generateUuidString(),
            name = request.name,
            description = request.description,
            icon = request.icon,
            color = request.color,
            systemPrompt = request.systemPrompt,
            suggestedProviderId = request.suggestedProviderId,
            suggestedModelId = request.suggestedModelId,
            modelCapabilityHint = request.modelCapabilityHint,
            temperature = request.temperature,
            reasoningLevel = request.reasoningLevel,
            webSearchEnabled = request.webSearchEnabled,
            starterMessages = request.starterMessages,
            knowledgeFiles = request.knowledgeFiles.map { file ->
                SkillKnowledgeFile(
                    id = generateUuidString(),
                    name = file.name,
                    content = file.content,
                    charCount = file.content.length,
                )
            },
            knowledgeBase = null,
            useMemory = request.useMemory,
            source = SkillSource.USER,
            createdAt = now,
            updatedAt = now,
        )
        dao.upsert(skill.toEntity(accountId))
        return skill
    }

    suspend fun update(id: String, request: UpdateSkillRequest): Skill {
        val existing = dao.getById(id)?.toDomain()
            ?: throw IllegalStateException("Skill not found")
        val now = Instant.now().toString()
        val updated = existing.copy(
            name = request.name ?: existing.name,
            description = request.description ?: existing.description,
            icon = request.icon ?: existing.icon,
            color = request.color ?: existing.color,
            systemPrompt = request.systemPrompt ?: existing.systemPrompt,
            suggestedProviderId = request.suggestedProviderId ?: existing.suggestedProviderId,
            suggestedModelId = request.suggestedModelId ?: existing.suggestedModelId,
            modelCapabilityHint = request.modelCapabilityHint ?: existing.modelCapabilityHint,
            temperature = request.temperature ?: existing.temperature,
            reasoningLevel = request.reasoningLevel ?: existing.reasoningLevel,
            webSearchEnabled = request.webSearchEnabled ?: existing.webSearchEnabled,
            starterMessages = request.starterMessages ?: existing.starterMessages,
            knowledgeFiles = request.knowledgeFiles?.map { file ->
                SkillKnowledgeFile(
                    id = generateUuidString(),
                    name = file.name,
                    content = file.content,
                    charCount = file.content.length,
                )
            } ?: existing.knowledgeFiles,
            knowledgeBase = request.knowledgeBase ?: existing.knowledgeBase,
            useMemory = request.useMemory ?: existing.useMemory,
            isPinned = request.isPinned ?: existing.isPinned,
            pinOrder = request.pinOrder ?: existing.pinOrder,
            updatedAt = now,
        )
        dao.upsert(updated.toEntity(accountId))
        return updated
    }

    suspend fun delete(id: String) {
        dao.deleteById(id)
    }

    suspend fun fork(id: String): Skill {
        val existing = dao.getById(id)?.toDomain()
            ?: throw IllegalStateException("Skill not found")
        val now = Instant.now().toString()
        val forked = existing.copy(
            id = generateUuidString(),
            source = SkillSource.USER,
            forkedFromId = existing.id,
            isPinned = false,
            pinOrder = 0,
            usageCount = 0,
            lastUsedAt = null,
            createdAt = now,
            updatedAt = now,
        )
        dao.upsert(forked.toEntity(accountId))
        return forked
    }

    suspend fun togglePin(id: String, pinned: Boolean, pinOrder: Int) {
        val existing = dao.getById(id) ?: return
        val nextPinOrder = if (pinned) pinOrder else existing.pinOrder
        dao.upsert(existing.copy(isPinned = pinned, pinOrder = nextPinOrder))
    }

    suspend fun recordUse(id: String) {
        dao.getById(id)?.let { entity ->
            dao.upsert(
                entity.copy(
                    usageCount = entity.usageCount + 1,
                    lastUsedAt = Instant.now().toString(),
                ),
            )
        }
    }

    suspend fun getById(id: String): Skill? =
        dao.getById(id)?.toDomain()

    suspend fun getAllUserSkills(): List<Skill> =
        dao.getBySource(accountId, "user").map { it.toDomain() }

    fun checkQuota(): Boolean = true
}
