package ai.oriveo.community.core.app

import ai.oriveo.community.core.context.ContextBudgetCap
import ai.oriveo.community.core.data.dao.PreferenceDao
import ai.oriveo.community.core.data.entity.PreferenceEntity
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Global default cap and over-limit reminder preferences: default auto / true, stored on this device only. */
class ConversationContextCapPreferencesTest {

    @Test
    fun global_prefs_defaults_and_local_storage() = runTest {
        val preferenceDao = FakePreferenceDao()
        val repository = AppPreferencesRepository(preferenceDao)

        // Both keys are user state, not device-level
        listOf(AppPreferenceKeys.CONTEXT_DEFAULT_CAP, AppPreferenceKeys.CONTEXT_PRICE_LINE_REMINDER_ENABLED).forEach { key ->
            assertTrue(AppPreferenceKeys.isUserState(key))
            assertFalse(AppPreferenceKeys.isDeviceScoped(key))
        }

        // Defaults: cap auto, reminder on
        assertEquals(ContextBudgetCap.Auto, repository.contextDefaultCap.first())
        assertEquals(ContextBudgetCap.Auto, repository.getContextDefaultCap())
        assertTrue(repository.contextPriceLineReminderEnabled.first())
        assertTrue(repository.getContextPriceLineReminderEnabled())

        // Writes store text in storage under the plain key
        repository.setContextDefaultCap(ContextBudgetCap.Custom(64_000))
        repository.setContextPriceLineReminderEnabled(false)
        assertEquals("64000", preferenceDao.get(AppPreferenceKeys.CONTEXT_DEFAULT_CAP))
        assertEquals("false", preferenceDao.get(AppPreferenceKeys.CONTEXT_PRICE_LINE_REMINDER_ENABLED))
        assertEquals(ContextBudgetCap.Custom(64_000), repository.contextDefaultCap.first())
        assertEquals(ContextBudgetCap.Custom(64_000), repository.getContextDefaultCap())
        assertFalse(repository.contextPriceLineReminderEnabled.first())
        assertFalse(repository.getContextPriceLineReminderEnabled())

        repository.setContextDefaultCap(ContextBudgetCap.Unlimited)
        assertEquals("unlimited", preferenceDao.get(AppPreferenceKeys.CONTEXT_DEFAULT_CAP))
        assertEquals(ContextBudgetCap.Unlimited, repository.contextDefaultCap.first())

        // Unparseable stored values = auto (leading zeros, old keys, out of range, empty string)
        listOf("64k", "064000", "31999", "", "Auto").forEach { garbage ->
            preferenceDao.set(PreferenceEntity(AppPreferenceKeys.CONTEXT_DEFAULT_CAP, garbage))
            assertEquals(ContextBudgetCap.Auto, repository.contextDefaultCap.first())
            assertEquals(ContextBudgetCap.Auto, repository.getContextDefaultCap())
        }
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
