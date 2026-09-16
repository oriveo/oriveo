package ai.oriveo.community.core.data.search

import android.content.Context
import androidx.room.Room
import ai.oriveo.community.core.data.database.ConversationSearchSchema
import ai.oriveo.community.core.data.database.OriveoDatabase
import kotlinx.coroutines.flow.first
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
 * Wall-clock micro-benchmark at the DAO level: on one seeded large corpus, it compares a single
 * search through the **old** shape (`LIKE '%q%'` plus `LEFT JOIN messages`) with the **new** one
 * (the FTS4 bigram inverted index).
 *
 * Why this rather than a frame-timing benchmark: `room-runtime` emits no `Trace.beginSection` at
 * all, so Room is invisible to systrace, and the conversation search SQL runs behind a debounce on
 * a background dispatcher where it never occupies a frame anyway. Counting frames in a typing
 * benchmark would only measure the Compose cost of typing and yield a false conclusion.
 *
 * The "old" SQL is the degraded lane that production still keeps,
 * [ai.oriveo.community.core.data.dao.ConversationDao.searchPendingIndexWithCount], so both sides
 * run over the same data in the same process on the same SQLite. That is a fair comparison rather
 * than two numbers measured apart.
 *
 * The absolute numbers belong in no document — a JVM with Robolectric's SQLite is not a device —
 * and are only ever used relative to each other.
 */
@RunWith(RobolectricTestRunner::class)
class ConversationSearchMicroBenchmarkTest {

    private val context: Context get() = RuntimeEnvironment.getApplication()
    private lateinit var db: OriveoDatabase

    private val account = "local"
    private val conversations = 400
    private val messagesPerConversation = 40

    @Before
    fun setUp() {
        db = Room.inMemoryDatabaseBuilder(context, OriveoDatabase::class.java)
            .allowMainThreadQueries()
            .build()
        ConversationSearchSchema.installTriggers(db.openHelper.writableDatabase)
    }

    @After
    fun tearDown() {
        db.close()
    }

    @Test
    fun `fts search is substantially faster than the legacy like scan on a large corpus`() = runBlocking {
        seedLargeCorpus()
        val indexer = ConversationSearchIndexer(dao = db.conversationSearchDao())
        val indexMillis = measure { indexer.drain() }
        assertTrue("precondition: the index really has to be built", indexer.isIndexComplete())
        assertEquals(conversations * messagesPerConversation, db.conversationSearchDao().indexedCount())

        // Only a few conversations carry the needle in a message body and none carry it in a title,
        // so both lanes genuinely have to search bodies.
        val query = "りょ"
        val ftsQuery = requireNotNull(ConversationFtsQuery.build(query))

        val legacyIds = db.conversationDao().searchPendingIndexWithCount(query, account).first()
            .map { it.entity.id }.toSet()
        val ftsIds = db.conversationDao().searchWithCount(query, ftsQuery, account).first()
            .map { it.entity.id }.toSet()
        assertEquals("both lanes must return the same conversations, or this compares two different things", legacyIds, ftsIds)
        assertTrue("the hit set must not be empty, or both sides are just running empty queries", ftsIds.isNotEmpty())

        val legacy = bestOf(ROUNDS) {
            db.conversationDao().searchPendingIndexWithCount(query, account).first()
        }
        val fts = bestOf(ROUNDS) {
            db.conversationDao().searchWithCount(query, ftsQuery, account).first()
        }

        println(
            "[conversation-search-microbench] corpus=${conversations}x$messagesPerConversation " +
                "(${conversations * messagesPerConversation} messages) " +
                "legacy_like=${legacy}us fts=${fts}us speedup=${"%.1f".format(legacy.toDouble() / fts.coerceAtLeast(1))}x " +
                "index_build=${indexMillis}ms hits=${ftsIds.size}",
        )

        assertTrue(
            "the FTS lane must be clearly faster than the full LIKE scan (legacy=${legacy}us fts=${fts}us)",
            fts * 2 < legacy,
        )
    }

    // ── helpers ──────────────────────────────────────────────────────────

    private companion object {
        const val ROUNDS = 7
    }

    private inline fun measure(block: () -> Unit): Long {
        val start = System.nanoTime()
        block()
        return (System.nanoTime() - start) / 1_000_000
    }

    /** Takes the fastest of several rounds (microseconds): JIT and page-cache jitter dwarf the difference being measured. */
    private suspend fun bestOf(rounds: Int, block: suspend () -> Any?): Long {
        var best = Long.MAX_VALUE
        repeat(rounds) {
            val start = System.nanoTime()
            block()
            best = minOf(best, (System.nanoTime() - start) / 1_000)
        }
        return best
    }

    private fun seedLargeCorpus() {
        val raw = db.openHelper.writableDatabase
        val filler = "これはふつうのかいわのないようでめっせーじてーぶるをおおきくするためのものです"
        raw.beginTransaction()
        try {
            repeat(conversations) { c ->
                raw.execSQL(
                    "INSERT INTO conversations (id, title, hasCustomTitle, providerID, providerKind, modelID, " +
                        "useMemory, previewText, estimatedCost, isDraft, draftText, createdAt, updatedAt, accountId) " +
                        "VALUES ('c$c', 'Conversation $c', 0, 'p1', 'OpenAI', 'm1', 1, '', 0.0, 0, '', 0, $c, '$account')",
                )
                repeat(messagesPerConversation) { m ->
                    // The needle is planted once every fifty conversations: with hits this sparse,
                    // LIKE has to scan the whole table, which is the scenario being measured.
                    val needle = if (c % 50 == 0 && m == 0) "りょうしもつれのはなし" else ""
                    raw.execSQL(
                        "INSERT INTO messages (id, accountId, conversationId, role, text, providerKind, providerName, " +
                            "modelName, estimatedCost, state, errorTitle, errorDetail, attachmentsJson, createdAt, " +
                            "sortOrder, customRetryWithoutFieldsAvailable) " +
                            "VALUES ('c$c-m$m', '$account', 'c$c', 'user', '$filler$needle', 'OpenAI', 'OpenAI', " +
                            "'m1', 0.0, 'delivered', NULL, NULL, NULL, 0, $m, 0)",
                    )
                }
            }
            raw.setTransactionSuccessful()
        } finally {
            raw.endTransaction()
        }
    }
}
