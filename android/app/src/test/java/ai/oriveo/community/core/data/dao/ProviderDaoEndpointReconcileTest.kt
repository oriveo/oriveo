package ai.oriveo.community.core.data.dao

import androidx.room.Room
import ai.oriveo.community.core.data.database.OriveoDatabase
import ai.oriveo.community.core.data.entity.ProviderEntity
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * and it writes only when both columns still hold the values that were read, so it never overwrites concurrent writes.
 */
@RunWith(RobolectricTestRunner::class)
class ProviderDaoEndpointReconcileTest {

    private lateinit var db: OriveoDatabase
    private val account = "acct-reconcile"

    @Before
    fun setUp() {
        db = Room.inMemoryDatabaseBuilder(RuntimeEnvironment.getApplication(), OriveoDatabase::class.java)
            .allowMainThreadQueries()
            .build()
    }

    @After
    fun tearDown() = db.close()

    @Test
    fun `reconcile rewrites source and literal without touching updatedAt`() = runBlocking {
        val dao = db.providerDao()
        dao.upsert(entity(baseUrlText = "https://dashscope-us.aliyuncs.com", endpointSource = null))

        dao.reconcileEndpointSource(
            accountId = account,
            id = "PQ",
            expectedSource = null,
            expectedBaseUrlText = "https://dashscope-us.aliyuncs.com",
            source = "region:sg",
            baseUrlText = "https://dashscope-intl.aliyuncs.com",
        )

        val row = dao.getById(account, "PQ")!!
        assertEquals("region:sg", row.endpointSource)
        assertEquals("https://dashscope-intl.aliyuncs.com", row.baseUrlText)
        assertEquals(42L, row.updatedAt)
    }

    @Test
    fun `reconcile skips a row that changed since it was read`() = runBlocking {
        val dao = db.providerDao()
        dao.upsert(entity(baseUrlText = "https://proxy.example.com", endpointSource = "custom"))

        dao.reconcileEndpointSource(
            accountId = account,
            id = "PQ",
            expectedSource = "region:us",
            expectedBaseUrlText = "https://dashscope-us.aliyuncs.com",
            source = "region:sg",
            baseUrlText = "https://dashscope-intl.aliyuncs.com",
        )

        val row = dao.getById(account, "PQ")!!
        assertEquals("custom", row.endpointSource)
        assertEquals("https://proxy.example.com", row.baseUrlText)
    }

    private fun entity(baseUrlText: String?, endpointSource: String?) = ProviderEntity(
        id = "PQ",
        kind = "Qwen",
        status = "{}",
        lastCheckedAt = null,
        apiKeyPreview = "sk-…abcd",
        lastError = null,
        baseUrlText = baseUrlText,
        customName = null,
        modelsJson = "[]",
        catalogModelsJson = "[]",
        updatedAt = 42,
        accountId = account,
        endpointSource = endpointSource,
    )
}
