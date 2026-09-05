package ai.oriveo.community.core.memory

import ai.oriveo.community.core.app.AppPreferenceKeys
import ai.oriveo.community.core.data.dao.PreferenceDao
import ai.oriveo.community.core.data.entity.PreferenceEntity
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.time.Instant


class MemoryPhase3SyncTest {

    private lateinit var preferenceDao: FakePreferenceDao

    @Before
    fun setUp() {
        preferenceDao = FakePreferenceDao()
    }

    

    @Test
    fun `isMemoryNewer - remote newer returns true`() {
        val result = isMemoryNewer(
            remote = "2026-04-01T11:00:00Z",
            local = "2026-04-01T10:00:00Z",
        )
        assertTrue(result)
    }

    @Test
    fun `isMemoryNewer - remote older returns false`() {
        val result = isMemoryNewer(
            remote = "2026-04-01T09:00:00Z",
            local = "2026-04-01T10:00:00Z",
        )
        assertFalse(result)
    }

    @Test
    fun `isMemoryNewer - same timestamp returns false (strict greater than)`() {
        val result = isMemoryNewer(
            remote = "2026-04-01T10:00:00Z",
            local = "2026-04-01T10:00:00Z",
        )
        assertFalse(result)
    }

    @Test
    fun `isMemoryNewer - remote null returns false`() {
        assertFalse(isMemoryNewer(remote = null, local = "2026-04-01T10:00:00Z"))
    }

    @Test
    fun `isMemoryNewer - local null returns true (first sync)`() {
        assertTrue(isMemoryNewer(remote = "2026-04-01T10:00:00Z", local = null))
    }

    @Test
    fun `isMemoryNewer - both null returns false`() {
        assertFalse(isMemoryNewer(remote = null, local = null))
    }

    @Test
    fun `isMemoryNewer - malformed remote returns false`() {
        assertFalse(isMemoryNewer(remote = "not-a-date", local = "2026-04-01T10:00:00Z"))
    }

    @Test
    fun `isMemoryNewer - malformed local with valid remote returns false`() {
        assertFalse(isMemoryNewer(remote = "2026-04-01T10:00:00Z", local = "not-a-date"))
    }

    

    @Test
    fun `LWW - remote newer overwrites local`() = runTest {
        
        preferenceDao.set(PreferenceEntity(AppPreferenceKeys.MEMORY_TEXT, "old local text"))
        preferenceDao.set(PreferenceEntity(AppPreferenceKeys.MEMORY_ANTI_FORGET_ENABLED, "false"))
        preferenceDao.set(PreferenceEntity(AppPreferenceKeys.MEMORY_ANTI_FORGET_TEXT, ""))
        preferenceDao.set(PreferenceEntity(AppPreferenceKeys.MEMORY_UPDATED_AT, "2026-04-01T10:00:00Z"))

        
        val remoteData = mapOf<String, Any>(
            "memoryText" to "new remote text",
            "memoryAntiForgetEnabled" to true,
            "memoryAntiForgetText" to "remote anti-forget",
            "memoryUpdatedAt" to "2026-04-01T11:00:00Z",
        )

        simulateHandlePreferencesMemory(remoteData)

        assertEquals("new remote text", preferenceDao.get(AppPreferenceKeys.MEMORY_TEXT))
        assertEquals("true", preferenceDao.get(AppPreferenceKeys.MEMORY_ANTI_FORGET_ENABLED))
        assertEquals("remote anti-forget", preferenceDao.get(AppPreferenceKeys.MEMORY_ANTI_FORGET_TEXT))
        assertEquals("2026-04-01T11:00:00Z", preferenceDao.get(AppPreferenceKeys.MEMORY_UPDATED_AT))
    }

    @Test
    fun `LWW - remote older keeps local`() = runTest {
        preferenceDao.set(PreferenceEntity(AppPreferenceKeys.MEMORY_TEXT, "local text"))
        preferenceDao.set(PreferenceEntity(AppPreferenceKeys.MEMORY_ANTI_FORGET_ENABLED, "true"))
        preferenceDao.set(PreferenceEntity(AppPreferenceKeys.MEMORY_ANTI_FORGET_TEXT, "local anti-forget"))
        preferenceDao.set(PreferenceEntity(AppPreferenceKeys.MEMORY_UPDATED_AT, "2026-04-01T12:00:00Z"))

        val remoteData = mapOf<String, Any>(
            "memoryText" to "old remote text",
            "memoryAntiForgetEnabled" to false,
            "memoryAntiForgetText" to "old remote",
            "memoryUpdatedAt" to "2026-04-01T10:00:00Z",
        )

        simulateHandlePreferencesMemory(remoteData)

        
        assertEquals("local text", preferenceDao.get(AppPreferenceKeys.MEMORY_TEXT))
        assertEquals("true", preferenceDao.get(AppPreferenceKeys.MEMORY_ANTI_FORGET_ENABLED))
        assertEquals("local anti-forget", preferenceDao.get(AppPreferenceKeys.MEMORY_ANTI_FORGET_TEXT))
        assertEquals("2026-04-01T12:00:00Z", preferenceDao.get(AppPreferenceKeys.MEMORY_UPDATED_AT))
    }

    @Test
    fun `LWW - remote clears memory with newer timestamp`() = runTest {
        preferenceDao.set(PreferenceEntity(AppPreferenceKeys.MEMORY_TEXT, "some memory"))
        preferenceDao.set(PreferenceEntity(AppPreferenceKeys.MEMORY_ANTI_FORGET_ENABLED, "true"))
        preferenceDao.set(PreferenceEntity(AppPreferenceKeys.MEMORY_ANTI_FORGET_TEXT, "some text"))
        preferenceDao.set(PreferenceEntity(AppPreferenceKeys.MEMORY_UPDATED_AT, "2026-04-01T10:00:00Z"))

        
        val remoteData = mapOf<String, Any>(
            "memoryUpdatedAt" to "2026-04-01T12:00:00Z",
        )

        simulateHandlePreferencesMemory(remoteData)

        assertEquals("", preferenceDao.get(AppPreferenceKeys.MEMORY_TEXT))
        assertEquals("false", preferenceDao.get(AppPreferenceKeys.MEMORY_ANTI_FORGET_ENABLED))
        assertEquals("", preferenceDao.get(AppPreferenceKeys.MEMORY_ANTI_FORGET_TEXT))
        assertEquals("2026-04-01T12:00:00Z", preferenceDao.get(AppPreferenceKeys.MEMORY_UPDATED_AT))
    }

    @Test
    fun `LWW - no remote timestamp ignores memory update`() = runTest {
        preferenceDao.set(PreferenceEntity(AppPreferenceKeys.MEMORY_TEXT, "local text"))
        preferenceDao.set(PreferenceEntity(AppPreferenceKeys.MEMORY_UPDATED_AT, "2026-04-01T10:00:00Z"))

        
        val remoteData = mapOf<String, Any>(
            "memoryText" to "remote text without timestamp",
        )

        simulateHandlePreferencesMemory(remoteData)

        
        assertEquals("local text", preferenceDao.get(AppPreferenceKeys.MEMORY_TEXT))
    }

    @Test
    fun `LWW - same timestamp does not update (idempotent)`() = runTest {
        preferenceDao.set(PreferenceEntity(AppPreferenceKeys.MEMORY_TEXT, "local text"))
        preferenceDao.set(PreferenceEntity(AppPreferenceKeys.MEMORY_ANTI_FORGET_ENABLED, "true"))
        preferenceDao.set(PreferenceEntity(AppPreferenceKeys.MEMORY_UPDATED_AT, "2026-04-01T10:00:00Z"))

        val remoteData = mapOf<String, Any>(
            "memoryText" to "different remote text",
            "memoryAntiForgetEnabled" to false,
            "memoryUpdatedAt" to "2026-04-01T10:00:00Z",
        )

        simulateHandlePreferencesMemory(remoteData)

        
        assertEquals("local text", preferenceDao.get(AppPreferenceKeys.MEMORY_TEXT))
        assertEquals("true", preferenceDao.get(AppPreferenceKeys.MEMORY_ANTI_FORGET_ENABLED))
    }

    @Test
    fun `LWW - first sync with no local timestamp accepts remote`() = runTest {
        

        val remoteData = mapOf<String, Any>(
            "memoryText" to "first sync text",
            "memoryAntiForgetEnabled" to true,
            "memoryAntiForgetText" to "first anti-forget",
            "memoryUpdatedAt" to "2026-04-01T10:00:00Z",
        )

        simulateHandlePreferencesMemory(remoteData)

        assertEquals("first sync text", preferenceDao.get(AppPreferenceKeys.MEMORY_TEXT))
        assertEquals("true", preferenceDao.get(AppPreferenceKeys.MEMORY_ANTI_FORGET_ENABLED))
        assertEquals("first anti-forget", preferenceDao.get(AppPreferenceKeys.MEMORY_ANTI_FORGET_TEXT))
        assertEquals("2026-04-01T10:00:00Z", preferenceDao.get(AppPreferenceKeys.MEMORY_UPDATED_AT))
    }

    // ── Helpers ──

    
    private fun isMemoryNewer(remote: String?, local: String?): Boolean {
        if (remote == null) return false
        if (local == null) return true
        return try {
            Instant.parse(remote).isAfter(Instant.parse(local))
        } catch (_: Exception) {
            false
        }
    }

    
    private suspend fun simulateHandlePreferencesMemory(data: Map<String, Any>) {
        val remoteMemoryUpdatedAt = data["memoryUpdatedAt"] as? String
        if (remoteMemoryUpdatedAt != null) {
            val localMemoryUpdatedAt = preferenceDao.get(AppPreferenceKeys.MEMORY_UPDATED_AT)
            if (isMemoryNewer(remoteMemoryUpdatedAt, localMemoryUpdatedAt)) {
                preferenceDao.set(PreferenceEntity(
                    AppPreferenceKeys.MEMORY_TEXT,
                    (data["memoryText"] as? String) ?: "",
                ))
                preferenceDao.set(PreferenceEntity(
                    AppPreferenceKeys.MEMORY_ANTI_FORGET_ENABLED,
                    ((data["memoryAntiForgetEnabled"] as? Boolean) ?: false).toString(),
                ))
                preferenceDao.set(PreferenceEntity(
                    AppPreferenceKeys.MEMORY_ANTI_FORGET_TEXT,
                    (data["memoryAntiForgetText"] as? String) ?: "",
                ))
                preferenceDao.set(PreferenceEntity(
                    AppPreferenceKeys.MEMORY_UPDATED_AT,
                    remoteMemoryUpdatedAt,
                ))
            }
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
