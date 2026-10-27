package ai.oriveo.community.core.app

import ai.oriveo.community.core.data.dao.PreferenceDao
import ai.oriveo.community.core.data.entity.PreferenceEntity
import ai.oriveo.community.core.model.LastUsedModelRef
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ThemeOption
import ai.oriveo.community.core.model.LanguageOption
import ai.oriveo.community.ui.theme.DarkPaletteChoice
import ai.oriveo.community.ui.theme.DarkPaletteId
import ai.oriveo.community.ui.theme.OriveoCustomPalette
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
    fun `setLastUsedModel refreshes a live override so a later write is not masked`() = runTest {
        // After an explicit pick the override is non-null; a later write from send, voice, quick relay add
        // or "set as default" must be what gets read back, not masked by the stale override.
        val scopedRepository = AppPreferencesRepository(preferenceDao)
        scopedRepository.primeLastUsedModel("picked-provider", "picked-model")

        scopedRepository.setLastUsedModel("voice-provider", "voice-model")

        assertEquals(LastUsedModelRef("voice-provider", "voice-model"), scopedRepository.lastUsedModelRefSnapshot)
        assertEquals(LastUsedModelRef("voice-provider", "voice-model"), scopedRepository.lastUsedModelRef.first())
    }

    @Test
    fun `setLastUsedModel without an override leaves it empty and reads the stored value`() = runTest {
        val scopedRepository = AppPreferencesRepository(preferenceDao)

        scopedRepository.setLastUsedModel("p", "m")

        assertNull(scopedRepository.lastUsedModelRefSnapshot)
        assertEquals(LastUsedModelRef("p", "m"), scopedRepository.lastUsedModelRef.first())
    }

    @Test
    fun `darkPalette is null when unset and resolves to default dark`() = runTest {
        assertNull(repository.darkPalette.first())
        assertEquals(DarkPaletteChoice.Preset(DarkPaletteId.Dark), repository.resolvedDarkPalette.first())
    }

    @Test
    fun `setDarkPalette persists raw id and reads back`() = runTest {
        repository.setDarkPalette(DarkPaletteChoice.Preset(DarkPaletteId.Ocean))

        // Stores the raw id string, not the enum name
        assertEquals("dark-ocean", preferenceDao.get(AppPreferenceKeys.DARK_PALETTE))
        assertEquals("dark-ocean", repository.darkPalette.first())
        assertEquals(DarkPaletteChoice.Preset(DarkPaletteId.Ocean), repository.resolvedDarkPalette.first())
    }

    @Test
    fun `setDarkPalette custom writes uppercase seed and keeps seed when back to preset`() = runTest {
        val seed = OriveoCustomPalette.presets.last()

        repository.setDarkPalette(DarkPaletteChoice.Custom(seed))

        val formatted = OriveoCustomPalette.format(seed)
        assertEquals("custom", preferenceDao.get(AppPreferenceKeys.DARK_PALETTE))
        assertEquals(formatted, preferenceDao.get(AppPreferenceKeys.DARK_PALETTE_CUSTOM))
        assertEquals(DarkPaletteChoice.Custom(seed), repository.resolvedDarkPalette.first())

        repository.setDarkPalette(DarkPaletteChoice.Preset(DarkPaletteId.Forest))

        assertEquals("the seed is kept when switching back to a preset", formatted, preferenceDao.get(AppPreferenceKeys.DARK_PALETTE_CUSTOM))
        assertEquals(DarkPaletteChoice.Preset(DarkPaletteId.Forest), repository.resolvedDarkPalette.first())
    }

    @Test
    fun `darkPaletteCustom is null when unset`() = runTest {
        assertNull(repository.darkPaletteCustom.first())
    }

    @Test
    fun `darkPalette keeps unknown raw id and renders default dark`() = runTest {
        preferenceDao.set(PreferenceEntity(AppPreferenceKeys.DARK_PALETTE, "dark-aurora-future"))

        assertEquals("dark-aurora-future", repository.darkPalette.first())
        assertEquals(DarkPaletteChoice.Preset(DarkPaletteId.Dark), repository.resolvedDarkPalette.first())
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
