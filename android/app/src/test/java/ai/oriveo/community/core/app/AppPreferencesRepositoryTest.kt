package ai.oriveo.community.core.app

import ai.oriveo.community.core.data.dao.PreferenceDao
import ai.oriveo.community.core.data.entity.PreferenceEntity
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ThemeOption
import ai.oriveo.community.core.model.LanguageOption
import io.mockk.every
import io.mockk.verify
import io.mockk.runs
import io.mockk.just
import io.mockk.mockk
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

class AppPreferencesRepositoryTest {

    private lateinit var preferenceDao: FakePreferenceDao
    private lateinit var repository: AppPreferencesRepository

    @Before
    fun setUp() {
        preferenceDao = FakePreferenceDao()
        repository = AppPreferencesRepository(preferenceDao)
    }

    @Test
    fun `saveMemory clears anti forget state when text is blank`() = runTest {
        repository.saveMemory(
            text = "   ",
            antiForgetEnabled = true,
            antiForgetText = "Keep replies concise",
            updatedAt = "2026-03-31T12:00:00Z",
        )

        assertEquals("", preferenceDao.get(AppPreferenceKeys.MEMORY_TEXT))
        assertEquals("false", preferenceDao.get(AppPreferenceKeys.MEMORY_ANTI_FORGET_ENABLED))
        assertEquals("", preferenceDao.get(AppPreferenceKeys.MEMORY_ANTI_FORGET_TEXT))
        assertEquals("2026-03-31T12:00:00Z", preferenceDao.get(AppPreferenceKeys.MEMORY_UPDATED_AT))
    }

    @Test
    fun `markMemoryUsedInConversation deduplicates by conversation id`() = runTest {
        repository.markMemoryUsedInConversation("conversation-1")
        repository.markMemoryUsedInConversation("conversation-1")
        repository.markMemoryUsedInConversation("conversation-2")

        assertEquals("2", preferenceDao.get(AppPreferenceKeys.MEMORY_USAGE_COUNT))
        assertEquals(
            setOf("conversation-1", "conversation-2"),
            repository.memoryUsageConversationIds.first(),
        )
    }

    @Test
    fun `language keys persist the newly added locales with stable storage names`() = runTest {
        val scopedRepository = AppPreferencesRepository(preferenceDao)
        val expected = linkedMapOf(
            ai.oriveo.community.core.model.LanguageOption.Hindi to "Hindi",
            ai.oriveo.community.core.model.LanguageOption.Indonesian to "Indonesian",
            ai.oriveo.community.core.model.LanguageOption.Vietnamese to "Vietnamese",
            ai.oriveo.community.core.model.LanguageOption.Thai to "Thai",
            ai.oriveo.community.core.model.LanguageOption.Turkish to "Turkish",
            ai.oriveo.community.core.model.LanguageOption.Russian to "Russian",
        )

        expected.forEach { (option, storedValue) ->
            scopedRepository.setLanguage(option)
            assertEquals(storedValue, preferenceDao.get(AppPreferenceKeys.LANGUAGE))
            assertEquals(option, scopedRepository.getLanguage())
        }

        assertTrue(expected.values.all { value -> value.isNotBlank() })
    }

    @Test
    fun `setTheme persists and syncs serialized theme`() = runTest {
        val syncedRepository = AppPreferencesRepository(
            preferenceDao = preferenceDao,
        )

        syncedRepository.setTheme(ThemeOption.Dark)

        assertEquals(ThemeOption.Dark.name, preferenceDao.get(AppPreferenceKeys.THEME))
    }

    @Test
    fun `setLanguage persists applies cache and syncs serialized language`() = runTest {
        val syncedRepository = AppPreferencesRepository(
            preferenceDao = preferenceDao,
        )

        syncedRepository.setLanguage(LanguageOption.Japanese)

        assertEquals(LanguageOption.Japanese.name, preferenceDao.get(AppPreferenceKeys.LANGUAGE))
    }

    @Test
    fun `saveMemory persists and syncs normalized memory payload`() = runTest {
        val syncedRepository = AppPreferencesRepository(
            preferenceDao = preferenceDao,
        )

        syncedRepository.saveMemory(
            text = "  remember me  ",
            antiForgetEnabled = true,
            antiForgetText = "  remember me  ",
            updatedAt = "2026-05-31T00:00:00Z",
        )

        assertEquals("remember me", preferenceDao.get(AppPreferenceKeys.MEMORY_TEXT))
    }

    @Test
    fun `togglePinnedConversation persists the updated pin list`() = runTest {
        val repository = AppPreferencesRepository(preferenceDao = preferenceDao)

        val updated = repository.togglePinnedConversation("conversation-1", "2026-05-31T01:00:00Z")

        assertEquals(listOf("conversation-1"), updated)
        assertEquals(listOf("conversation-1"), repository.getPinnedConversationIds())
    }

    @Test
    fun `primeLastUsedModel reflects synchronously and overrides stale room value`() = runTest {
        val scopedRepository = AppPreferencesRepository(preferenceDao)

        preferenceDao.set(PreferenceEntity(AppPreferenceKeys.LAST_USED_PROVIDER_ID, "old-provider"))
        preferenceDao.set(PreferenceEntity(AppPreferenceKeys.LAST_USED_MODEL_ID, "old-model"))

        scopedRepository.primeLastUsedModel("new-provider", "new-model")

        assertEquals("new-provider", scopedRepository.lastUsedModelRefSnapshot?.providerID)
        assertEquals("new-model", scopedRepository.lastUsedModelRefSnapshot?.modelID)

        val ref = scopedRepository.lastUsedModelRef.first()
        assertEquals("new-provider", ref?.providerID)
        assertEquals("new-model", ref?.modelID)
    }

    @Test
    fun `clearLastUsedModel drops the synchronous override`() = runTest {
        val scopedRepository = AppPreferencesRepository(preferenceDao)
        scopedRepository.primeLastUsedModel("provider-1", "model-1")
        assertEquals("model-1", scopedRepository.lastUsedModelRefSnapshot?.modelID)

        scopedRepository.clearLastUsedModel()
        assertNull(scopedRepository.lastUsedModelRefSnapshot)
    }

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
