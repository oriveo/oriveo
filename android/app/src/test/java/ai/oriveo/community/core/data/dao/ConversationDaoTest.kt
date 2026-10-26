package ai.oriveo.community.core.data.dao

import android.content.Context
import androidx.room.Room
import ai.oriveo.community.core.data.database.OriveoDatabase
import ai.oriveo.community.core.data.entity.ConversationEntity
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

@RunWith(RobolectricTestRunner::class)
class ConversationDaoTest {

    private lateinit var db: OriveoDatabase

    @Before
    fun setUp() {
        val context: Context = RuntimeEnvironment.getApplication()
        db = Room.inMemoryDatabaseBuilder(context, OriveoDatabase::class.java)
            .allowMainThreadQueries()
            .build()
    }

    @After
    fun tearDown() {
        db.close()
    }

    @Test
    fun `conversation dao exposes home pagination query methods`() {
        val methodNames = ConversationDao::class.java.methods.map { it.name }.toSet()

        assertTrue(methodNames.contains("observeUngroupedRecentWithCount"))
        assertTrue(methodNames.contains("observeUngroupedEarlierWithCount"))
        assertTrue(methodNames.contains("observeUngroupedEarlierCount"))
    }

    @Test
    fun `first empty draft only matches pure home drafts`() = runBlocking {
        val dao = db.conversationDao()
        // Skill drafts, folder drafts and drafts with a renamed title are newer, yet the home screen must not reuse them as its blank draft
        dao.upsert(draft("skill", updatedAt = 40, title = "Translator", skillId = "skill-1"))
        dao.upsert(draft("folder", updatedAt = 30, folderID = "folder-1"))
        dao.upsert(draft("renamed", updatedAt = 20, title = "Trip", hasCustomTitle = true))
        assertNull(dao.findFirstEmptyDraft(ACCOUNT))

        dao.upsert(draft("home", updatedAt = 10))
        assertEquals("home", dao.findFirstEmptyDraft(ACCOUNT)?.id)
    }

    private fun draft(
        id: String,
        updatedAt: Long,
        title: String = "New Chat",
        hasCustomTitle: Boolean = false,
        skillId: String? = null,
        folderID: String? = null,
    ) = ConversationEntity(
        id = id,
        title = title,
        hasCustomTitle = hasCustomTitle,
        providerID = "provider-1",
        providerKind = "OpenAI",
        modelID = "gpt-4.1",
        previewText = "",
        estimatedCost = 0.0,
        isDraft = true,
        draftText = "",
        createdAt = updatedAt,
        updatedAt = updatedAt,
        folderID = folderID,
        skillId = skillId,
        accountId = ACCOUNT,
    )

    private companion object {
        const val ACCOUNT = "local"
    }
}
