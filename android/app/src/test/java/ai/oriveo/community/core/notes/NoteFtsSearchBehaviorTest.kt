package ai.oriveo.community.core.notes

import android.content.Context
import androidx.room.Room
import ai.oriveo.community.core.data.database.OriveoDatabase
import ai.oriveo.community.core.data.entity.NoteEntity
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * **Behavioural** proof surface for note search: whether the generated query, fed to a real FTS4
 * virtual table, actually matches anything.
 *
 * Why this layer has to exist: [NoteFtsQueryTest] only asserts what the generated string looks
 * like, and what it used to generate was `"term"*` — quotes that disable the prefix operator, so
 * FTS matched nothing at all. A string assertion faithfully locked that bug in as the
 * specification, and nobody noticed.
 *
 * What made it even harder to spot is that it did **not** look like "search is broken":
 * `NoteRepository.searchNotes` falls back to a `LIKE '%q%'` scan whenever FTS returns nothing, so
 * users still found their notes while the index sat unused and every search took the slow path. No
 * feature-level symptom whatsoever.
 *
 * Hence **real Room, a real FTS4 virtual table and the production DAO**, asserting on what MATCH
 * actually returns.
 */
@RunWith(RobolectricTestRunner::class)
class NoteFtsSearchBehaviorTest {

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
    fun tearDown() = db.close()

    @Test
    fun `english prefix query matches through fts`() = runBlocking {
        seedNote("n1", title = "Deploy runbook", body = "hello world")

        val hits = search("hel")

        assertEquals("the prefix hel must match hello through FTS (the old \"hel\"* never matched)", 1, hits.size)
        assertEquals("n1", hits.first().id)
    }

    @Test
    fun `chinese prefix query matches through fts`() = runBlocking {
        // FTS4's default simple tokenizer treats a whole CJK run as one token, so only prefix
        // matching can reach it.
        seedNote("n1", title = "unrelated title", body = "きょうのてんき")

        val hits = search("きょう")

        assertEquals("a CJK prefix must match the whole token through FTS", 1, hits.size)
        assertEquals("n1", hits.first().id)
    }

    @Test
    fun `multiple terms are combined with implicit and`() = runBlocking {
        seedNote("n1", title = "kubernetes deploy", body = "staging rollout")
        seedNote("n2", title = "kubernetes backup", body = "nothing here")

        val hits = search("kube stag")

        assertEquals("two terms mean AND, so only the note matching both comes back", 1, hits.size)
        assertEquals("n1", hits.first().id)
    }

    @Test
    fun `fts keywords as user input do not blow up the match expression`() = runBlocking {
        seedNote("n1", title = "and or not", body = "near miss")

        // With a `*` suffix, AND / OR / NOT / NEAR are not parsed as operators. This pins down that
        // none of them raises a SQL error.
        listOf("and", "or", "not", "near", "and or", "AND").forEach { raw ->
            val q = NoteFtsQuery.build(raw)
            assertTrue("\"$raw\" should produce a query string", q != null)
            db.noteDao().searchActive(account, q!!)
        }
    }

    @Test
    fun `any term prefix recall also uses real prefix matching`() = runBlocking {
        seedNote("n1", title = "kubernetes", body = "irrelevant")

        val q = NoteFtsQuery.buildAnyTermPrefix(listOf("kube", "zzz"))!!
        val hits = db.noteDao().searchActive(account, q)

        assertEquals("the OR recall lane must use real prefix matching too", 1, hits.size)
    }

    private suspend fun search(raw: String): List<NoteEntity> {
        val q = NoteFtsQuery.build(raw) ?: return emptyList()
        return db.noteDao().searchActive(account, q)
    }

    /** Seeds through the production upsertWithIndex transaction; a hand-built index row would only prove the assertion can read. */
    private suspend fun seedNote(id: String, title: String, body: String) {
        db.noteDao().upsertWithIndex(
            note = NoteEntity(
                id = id,
                title = title,
                titleSource = "manual",
                body = body,
                tagsJson = "[]",
                captureKind = "manual",
                createdAt = "2026-01-01T00:00:00Z",
                updatedAt = "2026-01-01T00:00:00Z",
                accountId = account,
            ),
            ftsTitle = title,
            ftsBody = body,
            ftsUserNote = "",
            ftsTagsText = "",
        )
    }
}
