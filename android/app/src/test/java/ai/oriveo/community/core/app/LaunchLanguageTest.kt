package ai.oriveo.community.core.app

import android.app.LocaleManager
import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import android.os.LocaleList
import androidx.appcompat.app.AppCompatDelegate
import androidx.core.os.LocaleListCompat
import androidx.test.core.app.ApplicationProvider
import ai.oriveo.community.core.data.dao.PreferenceDao
import ai.oriveo.community.core.data.entity.PreferenceEntity
import ai.oriveo.community.core.model.LanguageOption
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** On cold start the language step does not read prefs on API 33+; on API 32 and below it reads once and applies. The one-time migration on 33+ never overwrites the user's choice. */
@RunWith(RobolectricTestRunner::class)
class LaunchLanguageTest {

    private val app: Context = ApplicationProvider.getApplicationContext()

    @After
    fun tearDown() {
        app.getSharedPreferences(LaunchLanguage.PREFS_NAME, Context.MODE_PRIVATE).edit().clear().commit()
        AppCompatDelegate.setApplicationLocales(LocaleListCompat.getEmptyLocaleList())
        // API 32 and below have no LocaleManager, so null is skipped
        app.getSystemService(LocaleManager::class.java)?.applicationLocales = LocaleList.getEmptyLocaleList()
    }

    @Test
    @Config(sdk = [33])
    fun api33_doesNotReadPrefsOnLaunch() {
        storePrefs("Japanese")
        val context = CountingContext(app)
        // Do not advance the scheduler: only the launch sync path is checked
        val scope = TestScope(StandardTestDispatcher())

        LaunchLanguage.applyOnLaunch(context, scope) { null }

        assertEquals(0, context.prefsReads)
    }

    @Test
    @Config(sdk = [32])
    fun api32_readsPrefsAndApplies() {
        storePrefs("Japanese")
        val context = CountingContext(app)

        LaunchLanguage.applyOnLaunch(context, TestScope(StandardTestDispatcher())) { null }

        assertEquals(1, context.prefsReads)
        assertEquals("ja", AppCompatDelegate.getApplicationLocales().toLanguageTags())
    }

    @Test
    @Config(sdk = [33])
    fun api33_reconcilesPrefsToSystemLocaleInBackground() = runTest {
        storePrefs("Japanese")
        val dao = CountingPreferenceDao()
        val repository = AppPreferencesRepository(dao, appContext = app)
        repository.setLanguage(LanguageOption.Japanese)
        val baselineWrites = dao.writes
        markMigrated()
        app.getSystemService(LocaleManager::class.java).applicationLocales = LocaleList.forLanguageTags("fr")

        LaunchLanguage.applyOnLaunch(app, this) { repository }
        advanceUntilIdle()

        assertEquals("French", readPrefs())
        assertEquals(LanguageOption.French, repository.getLanguage())
        assertEquals(baselineWrites + 1, dao.writes)

        // Run again on the same snapshot: already consistent, zero writes
        LaunchLanguage.applyOnLaunch(app, this) { repository }
        advanceUntilIdle()
        assertEquals(baselineWrites + 1, dao.writes)
    }

    @Test
    @Config(sdk = [33])
    fun api33_emptySystemWithStoredChoice_migratesChoiceToSystemOnce() = runTest {
        storePrefs("Japanese")
        val dao = CountingPreferenceDao()
        val repository = AppPreferencesRepository(dao, appContext = app)
        repository.setLanguage(LanguageOption.Japanese)
        val baselineWrites = dao.writes

        LaunchLanguage.applyOnLaunch(app, this) { repository }
        advanceUntilIdle()

        // The user's choice is written to the system; prefs / DB are not overwritten to "follow system"
        assertEquals("ja", localeManager.applicationLocales.toLanguageTags())
        assertEquals("Japanese", readPrefs())
        assertEquals(LanguageOption.Japanese, repository.getLanguage())
        assertEquals(baselineWrites, dao.writes)
        assertTrue(isMigrated())

        // The migration runs only once: if the user later switches to "follow system" in system settings, the system wins
        localeManager.applicationLocales = LocaleList.getEmptyLocaleList()
        LaunchLanguage.applyOnLaunch(app, this) { repository }
        advanceUntilIdle()
        assertTrue(localeManager.applicationLocales.isEmpty)
        assertEquals("System", readPrefs())
        assertEquals(LanguageOption.System, repository.getLanguage())
    }

    @Test
    @Config(sdk = [33])
    fun api33_emptySystemAfterMigration_followsSystem() = runTest {
        storePrefs("Japanese")
        markMigrated()
        val repository = AppPreferencesRepository(CountingPreferenceDao(), appContext = app)
        repository.setLanguage(LanguageOption.Japanese)

        LaunchLanguage.applyOnLaunch(app, this) { repository }
        advanceUntilIdle()

        assertTrue(localeManager.applicationLocales.isEmpty)
        assertEquals("System", readPrefs())
        assertEquals(LanguageOption.System, repository.getLanguage())
    }

    @Test
    @Config(sdk = [33])
    fun api33_emptySystemWithStoredSystem_marksMigratedWithoutWrite() = runTest {
        storePrefs("System")
        val dao = CountingPreferenceDao()
        val repository = AppPreferencesRepository(dao, appContext = app)
        repository.setLanguage(LanguageOption.System)
        val baselineWrites = dao.writes

        LaunchLanguage.applyOnLaunch(app, this) { repository }
        advanceUntilIdle()

        assertTrue(localeManager.applicationLocales.isEmpty)
        assertTrue(isMigrated())
        assertEquals("System", readPrefs())
        assertEquals(baselineWrites, dao.writes)
    }

    @Test
    @Config(sdk = [33])
    fun api33_rechecksSystemBeforeWrite() = runTest {
        storePrefs("Japanese")
        markMigrated()
        val dao = CountingPreferenceDao()
        val repository = AppPreferencesRepository(dao, appContext = app)
        repository.setLanguage(LanguageOption.Japanese)
        val baselineWrites = dao.writes
        localeManager.applicationLocales = LocaleList.forLanguageTags("fr")

        // After reconciliation reads the system value and before the write, the user switches to German in system settings
        LaunchLanguage.applyOnLaunch(app, this) {
            localeManager.applicationLocales = LocaleList.forLanguageTags("de")
            repository
        }
        advanceUntilIdle()

        // Do not write the stale value read at the start (French)
        assertEquals(baselineWrites, dao.writes)
        assertEquals("Japanese", readPrefs())
        assertEquals(LanguageOption.Japanese, repository.getLanguage())
    }

    private val localeManager: LocaleManager
        get() = app.getSystemService(LocaleManager::class.java)

    private fun markMigrated() {
        app.getSharedPreferences(LaunchLanguage.PREFS_NAME, Context.MODE_PRIVATE)
            .edit().putBoolean(LaunchLanguage.KEY_SYSTEM_SYNCED, true).commit()
    }

    private fun isMigrated(): Boolean =
        app.getSharedPreferences(LaunchLanguage.PREFS_NAME, Context.MODE_PRIVATE)
            .getBoolean(LaunchLanguage.KEY_SYSTEM_SYNCED, false)

    private fun storePrefs(value: String) {
        app.getSharedPreferences(LaunchLanguage.PREFS_NAME, Context.MODE_PRIVATE)
            .edit().putString(LaunchLanguage.KEY_APP_LANGUAGE, value).commit()
    }

    private fun readPrefs(): String? =
        app.getSharedPreferences(LaunchLanguage.PREFS_NAME, Context.MODE_PRIVATE)
            .getString(LaunchLanguage.KEY_APP_LANGUAGE, null)

    private class CountingContext(base: Context) : ContextWrapper(base) {
        var prefsReads = 0
        override fun getSharedPreferences(name: String?, mode: Int): SharedPreferences {
            prefsReads++
            return super.getSharedPreferences(name, mode)
        }
    }

    private class CountingPreferenceDao : PreferenceDao {
        private val values = linkedMapOf<String, MutableStateFlow<String?>>()
        var writes = 0

        override fun observe(key: String): Flow<String?> = values.getOrPut(key) { MutableStateFlow(null) }

        override suspend fun get(key: String): String? = values[key]?.value

        override suspend fun set(entity: PreferenceEntity) {
            writes++
            values.getOrPut(entity.key) { MutableStateFlow(null) }.value = entity.value
        }

        override suspend fun delete(key: String) {
            values.getOrPut(key) { MutableStateFlow(null) }.value = null
        }
    }
}
