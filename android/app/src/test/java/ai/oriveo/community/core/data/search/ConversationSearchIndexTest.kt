package ai.oriveo.community.core.data.search

import android.content.Context
import android.os.Looper
import androidx.room.Room
import ai.oriveo.community.core.data.database.ConversationSearchSchema
import ai.oriveo.community.core.data.database.OriveoDatabase
import ai.oriveo.community.core.data.entity.ConversationEntity
import ai.oriveo.community.core.data.entity.ConversationWithCount
import ai.oriveo.community.core.data.entity.MessageEntity
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf

/**
 * **Production-path** proof surface for the FTS4 conversation index and the message count that
 * moved out of the `messages` table.
 *
 * Everything runs against a real [OriveoDatabase] (in memory, same entities, foreign keys and
 * triggers) and the real DAOs, so every assertion reads rows that production SQL actually produced.
 * The test never fabricates an index row or a count: fabricating them would only prove that the
 * assertion can read something, not that the triggers and the indexer write it correctly.
 */
@RunWith(RobolectricTestRunner::class)
class ConversationSearchIndexTest {

    private val context: Context get() = RuntimeEnvironment.getApplication()
    private lateinit var db: OriveoDatabase
    private lateinit var indexer: ConversationSearchIndexer

    private val account = "local"

    @Before
    fun setUp() {
        db = Room.inMemoryDatabaseBuilder(context, OriveoDatabase::class.java)
            .allowMainThreadQueries()
            .build()
        // In production this happens in DatabaseModule's onOpen, which is the only install point a
        // fresh install reaches because it runs no migration. This calls the same production
        // function rather than a copy of the SQL.
        ConversationSearchSchema.installTriggers(db.openHelper.writableDatabase)
        indexer = ConversationSearchIndexer(dao = db.conversationSearchDao())
    }

    @After
    fun tearDown() {
        db.close()
    }

    // ── Triggers: message counts ─────────────────────────────────────────

    @Test
    fun `message count is maintained by triggers across insert delete and cascade`() = runBlocking {
        seedConversation("c1")
        insertMessage("c1", "m1", "hello")
        insertMessage("c1", "m2", "world")

        assertEquals(2, countOf("c1"))

        db.messageDao().deleteById(account, "m1")
        assertEquals(1, countOf("c1"))

        // Deleting the conversation cascades the messages away, and the trigger on `conversations`
        // clears the count row.
        db.conversationDao().deleteById(account, "c1")
        assertEquals(0, rawCount("SELECT COUNT(*) FROM conversation_message_counts"))
    }

    /**
     * The **positive** behavioural proof: when the message count really changes, the conversation
     * list Flow has to re-emit with the right number.
     *
     * It asserts what the user sees, and it doubles as the control for the negative test below: if
     * the whole Flow setup were inert here, this test would fail rather than quietly going green.
     */
    @Test
    fun `inserting a message re-emits the conversation list with the new count`() = runBlocking {
        seedConversation("c1")

        val emissions = CopyOnWriteArrayList<List<ConversationWithCount>>()
        val collector = launch(Dispatchers.IO) {
            db.conversationDao().observeAllWithCount(account).collect { emissions += it }
        }
        try {
            awaitUntil("the first emission") { emissions.isNotEmpty() }
            val baseline = emissions.size

            insertMessage("c1", "m1", "hello")

            awaitUntil("a re-emission after inserting a message") { emissions.size > baseline }
            assertEquals(1, emissions.last().single { it.entity.id == "c1" }.messageCount)
        } finally {
            collector.cancel()
        }
    }

    /**
     * The **negative** behavioural proof: a streaming checkpoint (which only rewrites `text`) must
     * not make the conversation list Flow re-emit.
     *
     * Before the change this fails, because a correlated `COUNT(*) FROM messages` hangs the query
     * off the whole `messages` table.
     *
     * Proving that something did *not* happen means giving the scheduler a fair chance and being
     * able to show the waiting budget was enough. The technique is to put the **positive control in
     * the same test**: first [settle] drains Robolectric's main looper and the real background
     * threads (Room emits on its own query executor, not on the test thread) and asserts the
     * emission count is unchanged after five checkpoints; then, on the **same flow with the same
     * budget**, a message is inserted and an emission is required. If that second half does not
     * emit, "did not emit" merely meant "was not waited for", and the test fails on the spot.
     *
     * Note this deliberately asserts on behaviour rather than on `InvalidationTracker.Observer`:
     * with the driver-based invalidation used by `createFlow`, the observer API delivers no
     * notification in this configuration at all, so "assert zero notifications" would be
     * permanently and silently true.
     */
    @Test
    fun `partial text flush does not re-emit the conversation list`() = runBlocking {
        seedConversation("c1")
        // Checkpoint writes only apply to Generating rows (see MessageDao.updatePartialText).
        insertMessage("c1", "m1", "", state = "Generating")

        val emissions = CopyOnWriteArrayList<List<ConversationWithCount>>()
        val collector = launch(Dispatchers.IO) {
            db.conversationDao().observeAllWithCount(account).collect { emissions += it }
        }
        try {
            awaitUntil("the first emission") { emissions.isNotEmpty() }
            val baseline = emissions.size

            repeat(5) { step ->
                val updated = db.messageDao().updatePartialText(account, "m1", "きょうのてんき $step")
                assertEquals("the checkpoint must really have been written, or this test proves nothing", 1, updated)
            }
            settle()

            assertEquals(
                "a text-only checkpoint must not re-emit the conversation list " +
                    "(it emitted ${emissions.size - baseline} extra times)",
                baseline,
                emissions.size,
            )

            // Positive control: on the same flow with the same waiting budget, a real change in the
            // count has to emit. Without it, "zero emissions" could just mean "not waited for".
            insertMessage("c1", "m2", "hello")
            awaitUntil("positive control: inserting a message must re-emit the same flow") {
                emissions.size > baseline
            }
        } finally {
            collector.cancel()
        }
    }

    /**
     * Control group proving the assertion above has teeth.
     *
     * `searchPendingIndexWithCount` is the degraded query used while the index is being built. It
     * does `LEFT JOIN messages` and therefore **is** hung off that table, so the same five
     * checkpoints must make it re-emit. Without this test, "did not re-emit" could simply mean that
     * nothing re-emits under this setup.
     */
    @Test
    fun `the lane that still joins messages does re-emit on partial flush`() = runBlocking {
        seedConversation("c1", title = "てんき")
        insertMessage("c1", "m1", "", state = "Generating")

        val emissions = CopyOnWriteArrayList<List<ConversationWithCount>>()
        val collector = launch(Dispatchers.IO) {
            db.conversationDao().searchPendingIndexWithCount("てんき", account).collect { emissions += it }
        }
        try {
            awaitUntil("the first emission") { emissions.isNotEmpty() }
            val baseline = emissions.size

            repeat(5) { step ->
                assertEquals(1, db.messageDao().updatePartialText(account, "m1", "きょうのてんき $step"))
            }

            awaitUntil("a query that still joins messages must re-emit on a checkpoint") {
                emissions.size > baseline
            }
        } finally {
            collector.cancel()
        }
    }

    /**
     * Static mechanism lock: the tables observed by the generated conversation-list Flows must
     * **not include `messages`**.
     *
     * Why keep one test that depends on a build artifact: the behavioural tests above prove "it did
     * not re-emit under this seed", whereas the actual mechanism is "this query does not subscribe
     * to the messages table at all". The `createFlow(__db, false, arrayOf(...))` call in
     * `ConversationDao_Impl.kt` *is* that mechanism — it is the set of tables Room derived from the
     * SQL, produced by the production code generator rather than by the test. If `messages` ever
     * creeps back into the SQL (say a correlated COUNT is reintroduced) this fails immediately,
     * while the behavioural tests would merely get slower.
     *
     * When the artifact is absent (no KSP run since a clean) the test is skipped rather than green.
     */
    @Test
    fun `generated flows for the conversation list do not observe the messages table`() {
        val generated = File(
            "build/generated/ksp/debug/kotlin/ai/oriveo/community/core/data/dao/ConversationDao_Impl.kt",
        )
        assumeTrue("KSP output missing, skipping (not passing): ${generated.absolutePath}", generated.exists())
        val source = generated.readText()

        listOf(
            "observeAllWithCount",
            "observeUngroupedRecentWithCount",
            "observeUngroupedEarlierWithCount",
            "observeUngroupedEarlierCount",
            "searchWithCount",
            "observeHasAnyWithMessages",
        ).forEach { function ->
            val tables = observedTablesOf(source, function)
            assertTrue(
                "$function must observe conversation_message_counts (where the count comes from), got $tables",
                tables.contains("conversation_message_counts"),
            )
            assertFalse(
                "$function must no longer observe the messages table: a streaming checkpoint would " +
                    "re-run the whole query. Got $tables",
                tables.contains("messages"),
            )
        }

        // Control: the degraded lane used while the index is being built **does** need to observe
        // messages (it is the one scanning bodies with LIKE). Without this, the assertions above
        // could merely mean the parser found nothing.
        assertTrue(
            "the degraded lane must still observe messages, otherwise this test parsed nothing",
            observedTablesOf(source, "searchPendingIndexWithCount").contains("messages"),
        )
    }

    /** Reads the `createFlow(..., arrayOf(...))` observed-table set of one DAO method out of the KSP output. */
    private fun observedTablesOf(source: String, function: String): Set<String> {
        val declaration = source.indexOf("override fun $function(")
        assertTrue("$function is missing from the generated source", declaration >= 0)
        val flowCall = source.indexOf("createFlow(__db,", declaration)
        assertTrue("$function is not a Flow query?", flowCall >= 0)
        val arrayStart = source.indexOf("arrayOf(", flowCall)
        val arrayEnd = source.indexOf(')', arrayStart)
        return source.substring(arrayStart + "arrayOf(".length, arrayEnd)
            .split(',')
            .map { it.trim().trim('"') }
            .filter { it.isNotEmpty() }
            .toSet()
    }

    /**
     * Drains scheduling that may not have happened yet. Robolectric's main looper is paused by
     * default (Room posts its observer registration there) while Flow emissions run on Room's own
     * query executor on a real thread. Both need a chance, hence alternating idle and real sleep
     * rather than a bare sleep.
     */
    private fun settle(rounds: Int = 25, stepMillis: Long = 20) {
        repeat(rounds) {
            shadowOf(Looper.getMainLooper()).idle()
            Thread.sleep(stepMillis)
        }
        shadowOf(Looper.getMainLooper()).idle()
    }

    /** Waits for a condition; a timeout fails and says what was being waited for, never passes silently. */
    private fun awaitUntil(what: String, timeoutMillis: Long = 5_000, condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + timeoutMillis
        while (System.currentTimeMillis() < deadline) {
            shadowOf(Looper.getMainLooper()).idle()
            if (condition()) return
            Thread.sleep(10)
        }
        shadowOf(Looper.getMainLooper()).idle()
        assertTrue("timed out after ${timeoutMillis}ms waiting for: $what", condition())
    }

    // ── Indexer and FTS search ───────────────────────────────────────────

    @Test
    fun `chinese two character query matches message body through the bigram index`() = runBlocking {
        seedConversation("c1", title = "unrelated title")
        insertMessage("c1", "m1", "きょうのてんき")
        indexer.drain()

        assertEquals(listOf("c1"), searchIds("てん"))
        assertEquals(listOf("c1"), searchIds("うのて"))
        // Single characters match by prefix: the trailing token is what lets a character that only
        // ever appears second in a bigram still be found.
        assertEquals(listOf("c1"), searchIds("き"))
    }

    @Test
    fun `latin query matches by prefix and title keeps substring semantics`() = runBlocking {
        seedConversation("c1", title = "Quarterly Budget")
        insertMessage("c1", "m1", "hello world")
        indexer.drain()

        assertEquals(listOf("c1"), searchIds("hel"))
        // Titles stay on substring LIKE, so searching from the middle of a word still matches.
        assertEquals(listOf("c1"), searchIds("uarterly"))
    }

    @Test
    fun `rewriting a message reindexes it and the old text stops matching`() = runBlocking {
        seedConversation("c1", title = "t")
        insertMessage("c1", "m1", "きょうのてんき", state = "Generating")
        indexer.drain()
        assertEquals(listOf("c1"), searchIds("てん"))

        assertEquals(1, db.messageDao().updatePartialText(account, "m1", "あしたはあめ"))
        indexer.drain()

        assertTrue("the old body must stop matching", searchIds("てん").isEmpty())
        assertEquals(listOf("c1"), searchIds("あめ"))
    }

    @Test
    fun `deleting a message removes its index row`() = runBlocking {
        seedConversation("c1", title = "t")
        insertMessage("c1", "m1", "きょうのてんき")
        indexer.drain()
        assertEquals(1, db.conversationSearchDao().indexedCount())

        db.messageDao().deleteById(account, "m1")

        assertEquals("the delete trigger must drop the index row by docid", 0, db.conversationSearchDao().indexedCount())
        assertTrue(searchIds("てん").isEmpty())
    }

    @Test
    fun `deleting a conversation cascades the index away`() = runBlocking {
        seedConversation("c1", title = "t")
        insertMessage("c1", "m1", "きょうのてんき")
        insertMessage("c1", "m2", "あしたはあめ")
        indexer.drain()
        assertEquals(2, db.conversationSearchDao().indexedCount())

        db.conversationDao().deleteById(account, "c1")

        assertEquals(
            "messages removed by the foreign-key cascade must fire the delete trigger too, " +
                "or the index keeps orphan rows",
            0,
            db.conversationSearchDao().indexedCount(),
        )
    }

    @Test
    fun `indexer drains in bounded batches and is idempotent`() = runBlocking {
        seedConversation("c1", title = "t")
        repeat(5) { insertMessage("c1", "m$it", "きょうのてんき") }

        val first = indexer.drain(maxMessages = 2)
        assertEquals(2, first)
        assertEquals(3, db.conversationSearchDao().pendingCount())

        indexer.drain()
        assertEquals(0, db.conversationSearchDao().pendingCount())
        assertEquals(5, db.conversationSearchDao().indexedCount())

        // Draining again must not duplicate rows (delete before insert).
        indexer.drain()
        assertEquals(5, db.conversationSearchDao().indexedCount())
    }

    @Test
    fun `search result set is capped at two hundred rows`() = runBlocking {
        repeat(230) { index ->
            seedConversation("c$index", title = "budget $index", updatedAt = index.toLong())
        }

        val rows = db.conversationDao()
            .searchWithCount(query = "budget", ftsQuery = "budget*", accountId = account)
            .first()
        assertEquals(200, rows.size)
    }

    @Test
    fun `punctuation only query falls back to the metadata lane instead of crashing fts`() = runBlocking {
        seedConversation("c1", title = "a*b")
        // ConversationFtsQuery.build returns null for pure punctuation, and the caller has to use
        // the metadata query, because an empty string in an FTS4 MATCH raises a syntax error.
        assertEquals(null, ConversationFtsQuery.build("*"))
        val rows = db.conversationDao().searchMetadataWithCount(query = "a*b", accountId = account).first()
        assertEquals(1, rows.size)
    }

    // ── The window while an upgraded database is still backfilling ───────

    /**
     * While an upgraded database has not finished building its index, search must **still find
     * message bodies** by falling back to LIKE, rather than returning nothing and looking broken.
     *
     * Nothing is drained here: the real state of "the queue is not empty" is used, and one of the
     * assertions is that the FTS table genuinely does not hold this message yet.
     */
    @Test
    fun `search falls back to the like lane while the backfill queue is not empty`() = runBlocking {
        seedConversation("c1", title = "unrelated title")
        insertMessage("c1", "m1", "きょうのてんき")

        assertEquals("precondition: the index is empty at this point", 0, db.conversationSearchDao().indexedCount())
        assertFalse(indexer.isIndexComplete())

        val service = ai.oriveo.community.core.data.repository.conversation.ConversationSearchService(
            conversationDao = db.conversationDao(),
            searchIndexer = indexer,
        )
        // The degraded query is the lane the service picks while the queue is not empty, so it is
        // verified directly.
        val degraded = db.conversationDao().searchPendingIndexWithCount("てんき", account).first()
        assertEquals(listOf("c1"), degraded.map { it.entity.id })
        // Either way the production path finds the message: with a single entry queued,
        // catchUpForSearch clears the backlog before it queries.
        assertEquals(1, service.search("てん").first().size)
    }

    @Test
    fun `fts lane is only used once the queue is drained`() = runBlocking {
        seedConversation("c1", title = "unrelated title")
        insertMessage("c1", "m1", "きょうのてんき")

        // Before the backfill, FTS finds nothing — which is exactly why the fallback has to exist.
        assertTrue(searchIds("てん").isEmpty())

        indexer.drain()
        assertTrue(indexer.isIndexComplete())
        assertEquals(listOf("c1"), searchIds("てん"))
    }

    // ── EXPLAIN QUERY PLAN ──────────────────────────────────────────────

    @Test
    fun `search plan no longer scans the messages table`() = runBlocking {
        seedConversation("c1", title = "t")
        insertMessage("c1", "m1", "きょうのてんき")
        indexer.drain()

        val plan = explain(
            """
            SELECT c.*, IFNULL(mc.messageCount, 0) AS messageCount
            FROM conversations c
            LEFT JOIN conversation_message_counts mc
              ON mc.accountId = c.accountId AND mc.conversationId = c.id
            WHERE c.accountId = '$account'
              AND (
                c.title LIKE '%てんき%'
                OR c.previewText LIKE '%てんき%'
                OR c.id IN (
                  SELECT f.conversationId FROM conversation_search_index f
                  WHERE conversation_search_index MATCH '"てん"' AND f.accountId = '$account'
                )
              )
            ORDER BY c.updatedAt DESC
            LIMIT 200
            """.trimIndent(),
        )

        assertFalse("the messages table must not appear in the new plan:\n$plan", plan.contains("messages"))
        assertTrue("body matching must go through the FTS inverted index:\n$plan", plan.contains("VIRTUAL TABLE INDEX"))

        // Control: the old shape (LEFT JOIN messages plus LIKE '%q%') inevitably scans messages.
        val legacyPlan = explain(
            """
            SELECT DISTINCT c.*,
                   (SELECT COUNT(*) FROM messages m WHERE m.accountId = c.accountId AND m.conversationId = c.id) AS messageCount
            FROM conversations c
            LEFT JOIN messages ON c.accountId = messages.accountId AND c.id = messages.conversationId
            WHERE c.accountId = '$account'
              AND (
                c.title LIKE '%てんき%'
                OR c.previewText LIKE '%てんき%'
                OR messages.text LIKE '%てんき%'
              )
            ORDER BY c.updatedAt DESC
            LIMIT 200
            """.trimIndent(),
        )
        assertTrue(
            "the control must scan messages, otherwise the assertion above proves nothing:\n$legacyPlan",
            legacyPlan.contains("messages"),
        )
    }

    @Test
    fun `conversation list plan no longer depends on the messages table`() = runBlocking {
        seedConversation("c1")
        val plan = explain(
            """
            SELECT c.*, IFNULL(mc.messageCount, 0) AS messageCount
            FROM conversations c
            LEFT JOIN conversation_message_counts mc
              ON mc.accountId = c.accountId AND mc.conversationId = c.id
            WHERE c.accountId = '$account'
            ORDER BY c.updatedAt DESC
            """.trimIndent(),
        )
        assertFalse("the conversation list query must not touch messages any more:\n$plan", plan.contains("messages"))
    }

    // ── helpers ──────────────────────────────────────────────────────────

    private fun explain(sql: String): String = buildString {
        db.openHelper.writableDatabase.query("EXPLAIN QUERY PLAN $sql").use { cursor ->
            while (cursor.moveToNext()) {
                for (column in 0 until cursor.columnCount) {
                    append(cursor.getString(column) ?: "").append(' ')
                }
                append('\n')
            }
        }
    }

    private fun rawCount(sql: String): Int =
        db.openHelper.writableDatabase.query(sql).use { cursor ->
            cursor.moveToFirst()
            cursor.getInt(0)
        }

    private suspend fun countOf(conversationId: String): Int =
        db.conversationDao().observeAllWithCount(account).first()
            .single { it.entity.id == conversationId }
            .messageCount

    private suspend fun searchIds(query: String): List<String> {
        val ftsQuery = ConversationFtsQuery.build(query)
        val rows = if (ftsQuery == null) {
            db.conversationDao().searchMetadataWithCount(query, account).first()
        } else {
            db.conversationDao().searchWithCount(query, ftsQuery, account).first()
        }
        return rows.map { it.entity.id }
    }

    private suspend fun seedConversation(
        id: String,
        title: String = id,
        updatedAt: Long = 0L,
    ) {
        db.conversationDao().upsert(
            ConversationEntity(
                id = id,
                title = title,
                hasCustomTitle = false,
                providerID = "p1",
                providerKind = "OpenAI",
                modelID = "m1",
                previewText = "",
                estimatedCost = 0.0,
                isDraft = false,
                draftText = "",
                createdAt = 0L,
                updatedAt = updatedAt,
                accountId = account,
            ),
        )
    }

    private suspend fun insertMessage(
        conversationId: String,
        id: String,
        text: String,
        state: String = "delivered",
    ) {
        db.messageDao().upsert(
            MessageEntity(
                id = id,
                accountId = account,
                conversationId = conversationId,
                role = "user",
                text = text,
                providerKind = "OpenAI",
                providerName = "OpenAI",
                modelName = "m1",
                estimatedCost = 0.0,
                state = state,
                errorTitle = null,
                errorDetail = null,
                attachmentsJson = null,
                createdAt = 0L,
                sortOrder = 0,
            ),
        )
    }
}
