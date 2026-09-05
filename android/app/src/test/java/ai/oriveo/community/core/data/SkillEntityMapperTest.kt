package ai.oriveo.community.core.data


import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.data.entity.SkillEntity
import ai.oriveo.community.core.model.Skill
import ai.oriveo.community.core.model.SkillKnowledgeBase
import ai.oriveo.community.core.model.SkillKnowledgeBaseFile
import ai.oriveo.community.core.model.SkillKnowledgeErrorCode
import ai.oriveo.community.core.model.SkillKnowledgeFile
import ai.oriveo.community.core.model.SkillKnowledgeFileStatus
import ai.oriveo.community.core.model.SkillKnowledgeIngestionMode
import ai.oriveo.community.core.model.SkillKnowledgeSourceType
import ai.oriveo.community.core.model.SkillSource
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SkillEntityMapperTest {

    private inline fun <T> mapper(block: EntityMapper.() -> T): T =
        with(EntityMapper) { block() }

    @Test
    fun `Skill to entity and back preserves all fields`() = mapper {
        val original = Skill(
            id = "skill-1",
            name = "Code Reviewer",
            description = "Reviews code quality",
            icon = "\uD83D\uDCBB",
            color = "#4A90D9",
            systemPrompt = "You are a code reviewer.",
            suggestedProviderId = "provider-1",
            suggestedModelId = "claude-sonnet",
            modelCapabilityHint = "reasoning",
            temperature = 0.7,
            reasoningLevel = "medium",
            webSearchEnabled = true,
            starterMessages = listOf("Review this code", "Find bugs"),
            knowledgeFiles = listOf(
                SkillKnowledgeFile(
                    id = "file-1",
                    name = "guidelines.md",
                    mimeType = "text/markdown",
                    sourceType = SkillKnowledgeSourceType.TEXT,
                    content = "Always check for null safety",
                    charCount = 30,
                    createdAt = "2026-03-01T00:00:00Z",
                    updatedAt = "2026-04-01T12:00:00Z",
                ),
            ),
            knowledgeBase = SkillKnowledgeBase(
                provider = "openai",
                retrievalModel = "gpt-5.4-mini",
                vectorStoreId = "vs_123",
                expiresAfterDays = 90,
                files = listOf(
                    SkillKnowledgeBaseFile(
                        id = "kb-file-1",
                        name = "manual.pdf",
                        mimeType = "application/pdf",
                        sizeBytes = 1024,
                        ingestionMode = SkillKnowledgeIngestionMode.NATIVE_FILE,
                        extractedFrom = null,
                        openAIFileId = "file_123",
                        status = SkillKnowledgeFileStatus.READY,
                        errorCode = SkillKnowledgeErrorCode.KNOWLEDGE_UPLOAD_FAILED,
                        createdAt = "2026-03-01T00:00:00Z",
                        updatedAt = "2026-04-01T12:00:00Z",
                    ),
                ),
                updatedAt = "2026-04-01T12:00:00Z",
            ),
            useMemory = false,
            isPinned = true,
            pinOrder = 1,
            source = SkillSource.USER,
            forkedFromId = "builtin-1",
            category = "coding",
            sortOrder = 5,
            usageCount = 42,
            lastUsedAt = "2026-04-01T12:00:00Z",
            createdAt = "2026-03-01T00:00:00Z",
            updatedAt = "2026-04-01T12:00:00Z",
        )

        val entity = original.toEntity("user-123")
        val restored = entity.toDomain()

        assertEquals(original.id, restored.id)
        assertEquals(original.name, restored.name)
        assertEquals(original.description, restored.description)
        assertEquals(original.icon, restored.icon)
        assertEquals(original.color, restored.color)
        assertEquals(original.systemPrompt, restored.systemPrompt)
        assertEquals(original.suggestedProviderId, restored.suggestedProviderId)
        assertEquals(original.suggestedModelId, restored.suggestedModelId)
        assertEquals(original.modelCapabilityHint, restored.modelCapabilityHint)
        assertEquals(original.temperature, restored.temperature)
        assertEquals(original.reasoningLevel, restored.reasoningLevel)
        assertEquals(original.webSearchEnabled, restored.webSearchEnabled)
        assertEquals(original.starterMessages, restored.starterMessages)
        assertEquals(original.knowledgeFiles.size, restored.knowledgeFiles.size)
        assertEquals(original.knowledgeFiles[0].name, restored.knowledgeFiles[0].name)
        assertEquals(original.knowledgeFiles[0].mimeType, restored.knowledgeFiles[0].mimeType)
        assertEquals(original.knowledgeFiles[0].sourceType, restored.knowledgeFiles[0].sourceType)
        assertEquals(original.knowledgeFiles[0].content, restored.knowledgeFiles[0].content)
        assertEquals(original.knowledgeBase, restored.knowledgeBase)
        assertEquals(original.useMemory, restored.useMemory)
        assertEquals(original.isPinned, restored.isPinned)
        assertEquals(original.pinOrder, restored.pinOrder)
        assertEquals(original.source, restored.source)
        assertEquals(original.forkedFromId, restored.forkedFromId)
        assertEquals(original.category, restored.category)
        assertEquals(original.sortOrder, restored.sortOrder)
        assertEquals(original.usageCount, restored.usageCount)
        assertEquals(original.lastUsedAt, restored.lastUsedAt)
        assertEquals(original.createdAt, restored.createdAt)
        assertEquals(original.updatedAt, restored.updatedAt)
    }

    @Test
    fun `entity preserves accountId`() = mapper {
        val skill = Skill(
            id = "s1",
            name = "Test",
            systemPrompt = "Prompt",
        )
        val entity = skill.toEntity("user-456")
        assertEquals("user-456", entity.accountId)
    }

    @Test
    fun `Skill defaults are correct`() {
        val skill = Skill(
            id = "s2",
            name = "Default",
            systemPrompt = "Hello",
        )
        assertEquals("any", skill.modelCapabilityHint)
        assertEquals(true, skill.useMemory)
        assertEquals(false, skill.isPinned)
        assertEquals(0, skill.pinOrder)
        assertEquals(SkillSource.USER, skill.source)
        assertNull(skill.temperature)
        assertNull(skill.reasoningLevel)
        assertNull(skill.webSearchEnabled)
        assertTrue(skill.starterMessages.isEmpty())
        assertTrue(skill.knowledgeFiles.isEmpty())
        assertNull(skill.knowledgeBase)
    }

    @Test
    fun `isBuiltIn and isEditable computed properties`() {
        val builtin = Skill(id = "b1", name = "B", systemPrompt = "P", source = SkillSource.BUILTIN)
        val user = Skill(id = "u1", name = "U", systemPrompt = "P", source = SkillSource.USER)

        assertTrue(builtin.isBuiltIn)
        assertTrue(!builtin.isEditable)
        assertTrue(!user.isBuiltIn)
        assertTrue(user.isEditable)
    }

    @Test
    fun `SkillSource from string`() {
        assertEquals(SkillSource.BUILTIN, SkillSource.from("builtin"))
        assertEquals(SkillSource.USER, SkillSource.from("user"))
        assertEquals(SkillSource.COMMUNITY, SkillSource.from("community"))
        assertEquals(SkillSource.USER, SkillSource.from("unknown"))
    }

    @Test
    fun `toDomain handles empty JSON arrays`() = mapper {
        val entity = SkillEntity(
            id = "e1",
            accountId = "guest",
            key = null,
            name = "Empty",
            description = "",
            icon = "\uD83E\uDD16",
            color = "#6d38ff",
            systemPrompt = "Prompt",
            suggestedProviderId = null,
            suggestedModelId = null,
            modelCapabilityHint = "any",
            temperature = null,
            reasoningLevel = null,
            webSearchEnabled = null,
            starterMessagesJson = "[]",
            knowledgeFilesJson = "[]",
            knowledgeBaseJson = null,
            useMemory = true,
            isPinned = false,
            pinOrder = 0,
            source = "user",
            forkedFromId = null,
            category = null,
            sortOrder = 0,
            usageCount = 0,
            lastUsedAt = null,
            createdAt = "2026-01-01",
            updatedAt = "2026-01-01",
        )

        val skill = entity.toDomain()
        assertTrue(skill.starterMessages.isEmpty())
        assertTrue(skill.knowledgeFiles.isEmpty())
    }

    @Test
    fun `toDomain handles malformed JSON gracefully`() = mapper {
        val entity = SkillEntity(
            id = "e2",
            accountId = "guest",
            key = null,
            name = "Malformed",
            description = "",
            icon = "\uD83E\uDD16",
            color = "#6d38ff",
            systemPrompt = "Prompt",
            suggestedProviderId = null,
            suggestedModelId = null,
            modelCapabilityHint = "any",
            temperature = null,
            reasoningLevel = null,
            webSearchEnabled = null,
            starterMessagesJson = "not-valid-json",
            knowledgeFilesJson = "also-not-valid",
            knowledgeBaseJson = "{bad-json}",
            useMemory = true,
            isPinned = false,
            pinOrder = 0,
            source = "user",
            forkedFromId = null,
            category = null,
            sortOrder = 0,
            usageCount = 0,
            lastUsedAt = null,
            createdAt = "2026-01-01",
            updatedAt = "2026-01-01",
        )

        
        val skill = entity.toDomain()
        assertTrue(skill.starterMessages.isEmpty())
        assertTrue(skill.knowledgeFiles.isEmpty())
        assertNull(skill.knowledgeBase)
    }

    @Test
    fun `Conversation with skillId round-trip`() = mapper {
        val conv = ai.oriveo.community.core.model.Conversation(
            id = "conv-1",
            title = "Code Review",
            providerID = "p1",
            providerKind = ProviderKind.OpenAI,
            modelID = "m1",
            skillId = "skill-1",
            useMemory = false,
        )

        val entity = conv.toEntity("user-1")
        assertEquals("skill-1", entity.skillId)

        val restored = entity.toDomain()
        assertEquals("skill-1", restored.skillId)
        assertEquals(false, restored.useMemory)
    }
}
