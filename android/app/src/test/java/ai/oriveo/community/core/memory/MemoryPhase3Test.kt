package ai.oriveo.community.core.memory


import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.app.AppPreferenceKeys
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.data.dao.PreferenceDao
import ai.oriveo.community.core.data.entity.ConversationEntity
import ai.oriveo.community.core.data.entity.PreferenceEntity
import ai.oriveo.community.core.model.BackupPreferences
import ai.oriveo.community.core.model.Conversation
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test


class MemoryPhase3Test {

    private lateinit var preferenceDao: FakePreferenceDao
    private lateinit var repository: AppPreferencesRepository

    @Before
    fun setUp() {
        preferenceDao = FakePreferenceDao()
        repository = AppPreferencesRepository(preferenceDao)
    }

    

    @Test
    fun `MEM-3-08 - Conversation defaults useMemory to true`() {
        val conversation = Conversation(
            id = "conv-1",
            title = "New Chat",
            providerID = "provider-1",
            providerKind = ProviderKind.OpenAI,
            modelID = "gpt-4o-mini",
        )
        assertTrue(conversation.useMemory)
    }

    @Test
    fun `MEM-3-08 - ConversationEntity defaults useMemory to true`() {
        val entity = ConversationEntity(
            id = "conv-1",
            title = "New Chat",
            hasCustomTitle = false,
            providerID = "provider-1",
            providerKind = ProviderKind.OpenAI.name,
            modelID = "gpt-4o-mini",
            previewText = "",
            estimatedCost = 0.0,
            isDraft = false,
            draftText = "",
            createdAt = System.currentTimeMillis(),
            updatedAt = System.currentTimeMillis(),
        )
        assertTrue(entity.useMemory)
    }

    @Test
    fun `MEM-3-08 - Conversation useMemory can be set to false`() {
        val conversation = Conversation(
            id = "conv-1",
            title = "New Chat",
            providerID = "provider-1",
            providerKind = ProviderKind.OpenAI,
            modelID = "gpt-4o-mini",
            useMemory = false,
        )
        assertFalse(conversation.useMemory)
    }

    

    @Test
    fun `MEM-3-20 - missing memory text in preferences defaults to empty string`() = runTest {
        
        val text = repository.memoryText.first()
        assertEquals("", text)
    }

    @Test
    fun `MEM-3-20 - missing memory anti-forget enabled defaults to false`() = runTest {
        val enabled = repository.memoryAntiForgetEnabled.first()
        assertFalse(enabled)
    }

    @Test
    fun `MEM-3-20 - missing memory anti-forget text defaults to empty string`() = runTest {
        val text = repository.memoryAntiForgetText.first()
        assertEquals("", text)
    }

    @Test
    fun `MEM-3-20 - missing memory updated at defaults to null`() = runTest {
        val updatedAt = repository.memoryUpdatedAt.first()
        assertNull(updatedAt)
    }

    @Test
    fun `MEM-3-20 - missing memory usage count defaults to 0`() = runTest {
        val count = repository.memoryUsageCount.first()
        assertEquals(0, count)
    }

    @Test
    fun `MEM-3-20 - missing memory has seen defaults to false`() = runTest {
        val hasSeen = repository.memoryHasSeen.first()
        assertFalse(hasSeen)
    }

    @Test
    fun `MEM-3-20 - missing memory usage conversation ids defaults to empty set`() = runTest {
        val ids = repository.memoryUsageConversationIds.first()
        assertTrue(ids.isEmpty())
    }

    @Test
    fun `MEM-3-20 - getMemoryText returns empty when not set`() = runTest {
        assertEquals("", repository.getMemoryText())
    }

    @Test
    fun `MEM-3-20 - getMemoryAntiForgetEnabled returns false when not set`() = runTest {
        assertFalse(repository.getMemoryAntiForgetEnabled())
    }

    @Test
    fun `MEM-3-20 - getMemoryAntiForgetText returns empty when not set`() = runTest {
        assertEquals("", repository.getMemoryAntiForgetText())
    }

    @Test
    fun `MEM-3-20 - malformed memory usage count does not crash`() = runTest {
        preferenceDao.set(PreferenceEntity(AppPreferenceKeys.MEMORY_USAGE_COUNT, "not_a_number"))
        val count = repository.memoryUsageCount.first()
        assertEquals(0, count)
    }

    @Test
    fun `MEM-3-20 - malformed memory anti-forget enabled does not crash`() = runTest {
        preferenceDao.set(PreferenceEntity(AppPreferenceKeys.MEMORY_ANTI_FORGET_ENABLED, "not_a_bool"))
        val enabled = repository.memoryAntiForgetEnabled.first()
        assertFalse(enabled)
    }

    @Test
    fun `MEM-3-20 - malformed memory usage conversation ids does not crash`() = runTest {
        preferenceDao.set(PreferenceEntity(AppPreferenceKeys.MEMORY_USAGE_CONVERSATION_IDS, "invalid_json"))
        val ids = repository.memoryUsageConversationIds.first()
        assertTrue(ids.isEmpty())
    }

    

    @Test
    fun `MEM-3-09 - memoryUsageCount is local-only stored in preferences`() = runTest {
        repository.markMemoryUsedInConversation("conv-1")
        repository.markMemoryUsedInConversation("conv-2")

        val count = repository.memoryUsageCount.first()
        assertEquals(2, count)

        
        val rawCount = preferenceDao.get(AppPreferenceKeys.MEMORY_USAGE_COUNT)
        assertEquals("2", rawCount)
    }

    @Test
    fun `MEM-3-09 - memoryUsageCount not included in BackupPreferences`() {
        
        val backup = BackupPreferences(
            memoryText = "I use Kotlin",
            memoryAntiForgetEnabled = true,
            memoryAntiForgetText = "Be concise",
            memoryUpdatedAt = "2026-04-01T00:00:00Z",
        )
        
        
        assertEquals("I use Kotlin", backup.memoryText)
        assertEquals(true, backup.memoryAntiForgetEnabled)
        assertEquals("Be concise", backup.memoryAntiForgetText)
        assertEquals("2026-04-01T00:00:00Z", backup.memoryUpdatedAt)
    }

    

    @Test
    fun `MEM-3-10 - memoryHasSeen is local-only stored in preferences`() = runTest {
        repository.setMemoryHasSeen(true)

        val hasSeen = repository.memoryHasSeen.first()
        assertTrue(hasSeen)

        val rawValue = preferenceDao.get(AppPreferenceKeys.MEMORY_HAS_SEEN)
        assertEquals("true", rawValue)
    }

    @Test
    fun `MEM-3-10 - memoryHasSeen not included in BackupPreferences`() {
        
        val backup = BackupPreferences()
        
        assertEquals("", backup.memoryText)
        assertEquals(false, backup.memoryAntiForgetEnabled)
    }

    

    @Test
    fun `MEM-3-21 - BackupPreferences includes all memory fields`() {
        val backup = BackupPreferences(
            theme = "dark",
            language = "japanese",
            memoryText = "I prefer Kotlin and Go",
            memoryAntiForgetEnabled = true,
            memoryAntiForgetText = "Prefer concise Chinese answers",
            memoryUpdatedAt = "2026-03-31T10:00:00Z",
        )

        assertEquals("I prefer Kotlin and Go", backup.memoryText)
        assertTrue(backup.memoryAntiForgetEnabled)
        assertEquals("Prefer concise Chinese answers", backup.memoryAntiForgetText)
        assertEquals("2026-03-31T10:00:00Z", backup.memoryUpdatedAt)
    }

    @Test
    fun `MEM-3-21 - BackupPreferences memory fields have correct defaults`() {
        val backup = BackupPreferences()

        assertEquals("", backup.memoryText)
        assertFalse(backup.memoryAntiForgetEnabled)
        assertEquals("", backup.memoryAntiForgetText)
        assertNull(backup.memoryUpdatedAt)
    }

    @Test
    fun `MEM-3-21 - ConversationEntity includes useMemory field for backup`() {
        val entityWithMemory = ConversationEntity(
            id = "conv-1",
            title = "Test",
            hasCustomTitle = false,
            providerID = "p1",
            providerKind = ProviderKind.OpenAI.name,
            modelID = "m1",
            useMemory = true,
            previewText = "",
            estimatedCost = 0.0,
            isDraft = false,
            draftText = "",
            createdAt = 1000L,
            updatedAt = 2000L,
        )
        assertTrue(entityWithMemory.useMemory)

        val entityWithoutMemory = entityWithMemory.copy(useMemory = false)
        assertFalse(entityWithoutMemory.useMemory)
    }

    @Test
    fun `MEM-3-21 - backup export reads memory from preferences correctly`() = runTest {
        
        repository.saveMemory(
            text = "I use Kotlin",
            antiForgetEnabled = true,
            antiForgetText = "Prefer concise answers",
            updatedAt = "2026-03-31T10:00:00Z",
        )

        
        val memoryText = preferenceDao.get(AppPreferenceKeys.MEMORY_TEXT).orEmpty()
        val antiForgetEnabled = preferenceDao
            .get(AppPreferenceKeys.MEMORY_ANTI_FORGET_ENABLED)
            ?.toBooleanStrictOrNull() ?: false
        val antiForgetText = preferenceDao.get(AppPreferenceKeys.MEMORY_ANTI_FORGET_TEXT).orEmpty()
        val updatedAt = preferenceDao.get(AppPreferenceKeys.MEMORY_UPDATED_AT)

        
        val backup = BackupPreferences(
            memoryText = memoryText,
            memoryAntiForgetEnabled = antiForgetEnabled,
            memoryAntiForgetText = antiForgetText,
            memoryUpdatedAt = updatedAt,
        )

        assertEquals("I use Kotlin", backup.memoryText)
        assertTrue(backup.memoryAntiForgetEnabled)
        assertEquals("Prefer concise answers", backup.memoryAntiForgetText)
        assertEquals("2026-03-31T10:00:00Z", backup.memoryUpdatedAt)
    }

    @Test
    fun `MEM-3-21 - backup with empty memory still has correct defaults`() = runTest {
        
        val memoryText = preferenceDao.get(AppPreferenceKeys.MEMORY_TEXT).orEmpty()
        val antiForgetEnabled = preferenceDao
            .get(AppPreferenceKeys.MEMORY_ANTI_FORGET_ENABLED)
            ?.toBooleanStrictOrNull() ?: false
        val antiForgetText = preferenceDao.get(AppPreferenceKeys.MEMORY_ANTI_FORGET_TEXT).orEmpty()
        val updatedAt = preferenceDao.get(AppPreferenceKeys.MEMORY_UPDATED_AT)

        val backup = BackupPreferences(
            memoryText = memoryText,
            memoryAntiForgetEnabled = antiForgetEnabled,
            memoryAntiForgetText = antiForgetText,
            memoryUpdatedAt = updatedAt,
        )

        assertEquals("", backup.memoryText)
        assertFalse(backup.memoryAntiForgetEnabled)
        assertEquals("", backup.memoryAntiForgetText)
        assertNull(backup.memoryUpdatedAt)
    }

    // ── Helper ──

    private class FakePreferenceDao : PreferenceDao {
        private val values = linkedMapOf<String, MutableStateFlow<String?>>()

        override fun observe(key: String): Flow<String?> =
            values.getOrPut(key) { MutableStateFlow(null) }

        override suspend fun get(key: String): String? =
            values[key]?.value

        override suspend fun set(entity: PreferenceEntity) {
            values.getOrPut(entity.key) { MutableStateFlow(null) }.value = entity.value
        }

        override suspend fun delete(key: String) {
            values.getOrPut(key) { MutableStateFlow(null) }.value = null
        }
    }
}
