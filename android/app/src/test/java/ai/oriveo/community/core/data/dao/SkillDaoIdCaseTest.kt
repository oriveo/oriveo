package ai.oriveo.community.core.data.dao

import androidx.room.Room
import ai.oriveo.community.core.data.database.OriveoDatabase
import ai.oriveo.community.core.data.entity.SkillEntity
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * A conversation's skillId does not always share the catalog id's UUID case: catalog ids are lowercase,
 * iOS writes an uppercase uuidString. Looking a skill up by id must be case-insensitive, otherwise a skill
 * conversation created on iOS cannot find its skill on Android.
 */
@RunWith(RobolectricTestRunner::class)
class SkillDaoIdCaseTest {

    private lateinit var db: OriveoDatabase

    @Before
    fun setUp() {
        db = Room.inMemoryDatabaseBuilder(RuntimeEnvironment.getApplication(), OriveoDatabase::class.java)
            .allowMainThreadQueries()
            .build()
    }

    @After
    fun tearDown() {
        db.close()
    }

    @Test
    fun `getById matches catalog skill regardless of UUID case`() = runBlocking {
        db.skillDao().upsert(skill("3fa85f64-5717-4562-b3fc-2c963f66afa6"))

        assertEquals(
            "3fa85f64-5717-4562-b3fc-2c963f66afa6",
            db.skillDao().getById("3FA85F64-5717-4562-B3FC-2C963F66AFA6")?.id,
        )
    }

    @Test
    fun `list order ignores legacy pin fields`() = runBlocking {
        val dao = db.skillDao()
        dao.upsert(skill("a", sortOrder = 1))
        dao.upsert(skill("b", sortOrder = 2, isPinned = true, pinOrder = 1))
        dao.upsert(skill("c", sortOrder = 0))

        val expected = listOf("c", "a", "b")
        assertEquals(expected, dao.getAll("guest").map { it.id })
        assertEquals(expected, dao.getBySource("guest", "catalog").map { it.id })
        assertEquals(expected, dao.observeAll("guest").first().map { it.id })
        assertEquals(expected, dao.observeBySource("guest", "catalog").first().map { it.id })
    }

    private fun skill(
        id: String,
        sortOrder: Int = 0,
        isPinned: Boolean = false,
        pinOrder: Int = 0,
    ) = SkillEntity(
        id = id,
        accountId = "guest",
        key = null,
        name = "Catalog",
        description = "",
        icon = "🤖",
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
        isPinned = isPinned,
        pinOrder = pinOrder,
        source = "catalog",
        forkedFromId = null,
        category = null,
        sortOrder = sortOrder,
        usageCount = 0,
        lastUsedAt = null,
        createdAt = "2026-01-01",
        updatedAt = "2026-01-01",
    )
}
