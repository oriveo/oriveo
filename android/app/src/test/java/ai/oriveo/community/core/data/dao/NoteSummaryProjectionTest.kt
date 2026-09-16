package ai.oriveo.community.core.data.dao

import android.content.Context
import androidx.room.Room
import ai.oriveo.community.core.data.database.OriveoDatabase
import ai.oriveo.community.core.data.entity.NoteEntity
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * Production-path proof surface for `NoteDao.observeActiveSummary`, the single-row projection
 * behind the notes card on the home screen.
 *
 * Every assertion reads what real SQL produced in a real Room database, because a projection that
 * computes the wrong thing — counting soft-deleted notes, picking the wrong title — shows up on
 * screen as one wrong number and reports no error at all.
 */
@RunWith(RobolectricTestRunner::class)
class NoteSummaryProjectionTest {

    private val context: Context get() = RuntimeEnvironment.getApplication()
    private lateinit var db: OriveoDatabase

    private val account = "local"

    @Before
    fun setUp() {
        db = Room.inMemoryDatabaseBuilder(context, OriveoDatabase::class.java)
            .allowMainThreadQueries()
            .build()
    }

    @After
    fun tearDown() {
        db.close()
    }

    @Test
    fun `summary counts only active notes and takes the most recently updated title`() = runBlocking {
        db.noteDao().upsert(note("n1", title = "Older note", updatedAt = "2026-09-01T00:00:00Z"))
        db.noteDao().upsert(note("n2", title = "Newer note", updatedAt = "2026-09-10T00:00:00Z"))
        db.noteDao().upsert(
            note("n3", title = "In the trash", updatedAt = "2026-09-20T00:00:00Z", deletedAt = "2026-09-20T00:00:00Z"),
        )
        // Notes in another partition must not be counted.
        db.noteDao().upsert(note("n4", title = "Other partition", updatedAt = "2026-09-30T00:00:00Z", accountId = "other"))

        val summary = db.noteDao().observeActiveSummary(account).first()

        assertEquals(2, summary.activeCount)
        assertEquals("Newer note", summary.latestTitle)
    }

    @Test
    fun `summary distinguishes no notes from an untitled note`() = runBlocking {
        val empty = db.noteDao().observeActiveSummary(account).first()
        assertEquals(0, empty.activeCount)
        assertNull("with no notes the title must be null, which is how the card knows to hide its subtitle", empty.latestTitle)

        db.noteDao().upsert(note("n1", title = "", updatedAt = "2026-09-01T00:00:00Z"))
        val untitled = db.noteDao().observeActiveSummary(account).first()
        assertEquals(1, untitled.activeCount)
        assertEquals("a note with an empty title yields \"\", which the card renders as its untitled placeholder", "", untitled.latestTitle)
    }

    private fun note(
        id: String,
        title: String,
        updatedAt: String,
        deletedAt: String? = null,
        accountId: String = account,
    ) = NoteEntity(
        id = id,
        title = title,
        titleSource = "manual",
        body = "body",
        tagsJson = "[]",
        captureKind = "manual",
        createdAt = updatedAt,
        updatedAt = updatedAt,
        deletedAt = deletedAt,
        accountId = accountId,
    )
}
