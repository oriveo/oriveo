package ai.oriveo.community.core.app

import ai.oriveo.community.core.data.dao.PreferenceDao
import ai.oriveo.community.core.data.entity.PreferenceEntity
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Android unit tests for the new-feature badge contract. */
class FeatureBadgesTest {

    private val memoryId = FeatureBadges.SETTINGS_MEMORY

    @Test
    fun `fresh install shows the badge`() = runTest {
        val repository = AppPreferencesRepository(FakePreferenceDao())

        assertTrue(repository.featureBadgeUnseen(memoryId).first())
    }

    @Test
    fun `markSeen hides the badge and persists on the device`() = runTest {
        val dao = FakePreferenceDao()
        AppPreferencesRepository(dao).markFeatureBadgeSeen(memoryId)

        // A fresh repository instance reading the same storage = still hidden after a restart
        val reopened = AppPreferencesRepository(dao)
        assertFalse(reopened.featureBadgeUnseen(memoryId).first())
        assertEquals(memoryId, dao.get(AppPreferenceKeys.FEATURE_BADGES_SEEN))
    }

    @Test
    fun `ids outside the registry are pruned and never shown`() = runTest {
        val dao = FakePreferenceDao()
        dao.set(PreferenceEntity(AppPreferenceKeys.FEATURE_BADGES_SEEN, "settings.old.2025-01,$memoryId"))
        val repository = AppPreferencesRepository(dao)

        assertEquals(setOf(memoryId), repository.featureBadgesSeen.first())
        assertFalse(FeatureBadges.isUnseen("settings.old.2025-01", emptySet()))

        dao.set(PreferenceEntity(AppPreferenceKeys.FEATURE_BADGES_SEEN, "settings.old.2025-01"))
        repository.markFeatureBadgeSeen(memoryId)
        assertEquals(memoryId, dao.get(AppPreferenceKeys.FEATURE_BADGES_SEEN))

        repository.markFeatureBadgeSeen("settings.unknown.2026-10")
        assertEquals(memoryId, dao.get(AppPreferenceKeys.FEATURE_BADGES_SEEN))
    }

    @Test
    fun `registered ids match the shared registry`() {
        val registry = Json.parseToJsonElement(
            File(repoRoot(), "shared/ui-contracts/feature-badges.v1.json").readText(),
        ).jsonObject
        val sharedIds = registry.getValue("badges").jsonArray.map {
            it.jsonObject.getValue("id").jsonPrimitive.content
        }

        assertEquals(sharedIds, FeatureBadges.REGISTERED_IDS)
    }

    @Test
    fun `seen key is device scoped`() {
        assertTrue(AppPreferenceKeys.FEATURE_BADGES_SEEN in AppPreferenceKeys.DEVICE_SCOPED_KEYS)
        assertFalse(AppPreferenceKeys.isUserState(AppPreferenceKeys.FEATURE_BADGES_SEEN))
    }

    private fun repoRoot(): File =
        File(System.getProperty("user.dir") ?: ".").absoluteFile.parentFile!!.parentFile!!

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
