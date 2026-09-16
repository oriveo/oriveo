package ai.oriveo.community.core.data.database

import android.content.Context
import androidx.room.Room
import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.sqlite.db.SupportSQLiteOpenHelper
import androidx.sqlite.db.framework.FrameworkSQLiteOpenHelperFactory
import ai.oriveo.community.core.data.search.ConversationSearchIndexer
import java.io.File
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * A **real migration** test for v1 to v2: [OriveoDatabase.MIGRATION_1_2] runs against a genuine v1
 * database.
 *
 * Why `inMemoryDatabaseBuilder` is not enough: that path goes through Room's `createAllTables` and
 * executes not one word of the migration, so schema drift and the backfill of existing data are
 * both untested — a table the test built itself can only ever prove itself right. The v1 database
 * here is created statement by statement from the **exported `1.json` schema**, so it matches what
 * an already-installed app holds.
 *
 * Room then has to be able to open the result, which verifies the v2 identity hash and therefore
 * proves that the hand-written CREATE statements in the migration match what the entities generate.
 * One character out of place there is a crash on open in production.
 */
@RunWith(RobolectricTestRunner::class)
class ConversationSearchMigrationTest {

    private val context: Context get() = RuntimeEnvironment.getApplication()
    private val dbName = "migration-v1-to-v2.db"
    private val account = "local"

    @Before
    fun setUp() {
        context.getDatabasePath(dbName).let { file ->
            file.parentFile?.mkdirs()
            deleteDatabaseFiles(file)
        }
    }

    @After
    fun tearDown() {
        deleteDatabaseFiles(context.getDatabasePath(dbName))
    }

    @Test
    fun `migration backfills counts queues the whole corpus and keeps room able to open the database`() =
        runBlocking {
            createLegacyV1Database { db ->
                db.execSQL(
                    "INSERT INTO conversations (id, title, hasCustomTitle, providerID, providerKind, modelID, " +
                        "useMemory, previewText, estimatedCost, isDraft, draftText, createdAt, updatedAt, accountId) " +
                        "VALUES ('c1', 'Old conversation', 0, 'p1', 'OpenAI', 'm1', 1, '', 0.0, 0, '', 0, 0, '$account')",
                )
                db.execSQL(
                    "INSERT INTO conversations (id, title, hasCustomTitle, providerID, providerKind, modelID, " +
                        "useMemory, previewText, estimatedCost, isDraft, draftText, createdAt, updatedAt, accountId) " +
                        "VALUES ('c2', 'Empty conversation', 0, 'p1', 'OpenAI', 'm1', 1, '', 0.0, 0, '', 0, 0, '$account')",
                )
                repeat(3) { index ->
                    db.execSQL(
                        "INSERT INTO messages (id, accountId, conversationId, role, text, providerKind, providerName, " +
                            "modelName, estimatedCost, state, errorTitle, errorDetail, attachmentsJson, createdAt, " +
                            "sortOrder, customRetryWithoutFieldsAvailable) " +
                            "VALUES ('m$index', '$account', 'c1', 'user', 'きょうのてんき $index', 'OpenAI', 'OpenAI', " +
                            "'m1', 0.0, 'delivered', NULL, NULL, NULL, 0, $index, 0)",
                    )
                }
            }

            val db = Room.databaseBuilder(context, OriveoDatabase::class.java, dbName)
                .addMigrations(OriveoDatabase.MIGRATION_1_2)
                .allowMainThreadQueries()
                .build()
            // The production DatabaseModule does this in onOpen too. Calling the same function here
            // also shows that installing again after the migration already did is idempotent.
            ConversationSearchSchema.installTriggers(db.openHelper.writableDatabase)

            try {
                // 1) Existing counts are backfilled immediately, not left to a background pass.
                val rows = db.conversationDao().observeAllWithCount(account).first().associateBy { it.entity.id }
                assertEquals(3, rows.getValue("c1").messageCount)
                assertEquals(0, rows.getValue("c2").messageCount)

                // 2) The whole corpus is queued for indexing (the migration enqueues rowids only,
                //    it does not tokenise while opening the database).
                val searchDao = db.conversationSearchDao()
                assertEquals(3, searchDao.pendingCount())
                assertEquals(0, searchDao.indexedCount())

                // 3) While the backfill runs, search uses the degraded LIKE lane and still finds bodies.
                val degraded = db.conversationDao()
                    .searchPendingIndexWithCount("てんき", account).first()
                assertEquals(listOf("c1"), degraded.map { it.entity.id })

                // 4) Once the background indexer has consumed the queue, the FTS lane matches.
                val indexer = ConversationSearchIndexer(dao = searchDao)
                assertEquals(3, indexer.drain())
                assertTrue(indexer.isIndexComplete())
                val hits = db.conversationDao()
                    .searchWithCount(query = "てんき", ftsQuery = "\"てん\"", accountId = account).first()
                assertEquals(listOf("c1"), hits.map { it.entity.id })

                // 5) The triggers installed by the migration are live: a new message updates both
                //    the count and the queue.
                db.openHelper.writableDatabase.execSQL(
                    "INSERT INTO messages (id, accountId, conversationId, role, text, providerKind, providerName, " +
                        "modelName, estimatedCost, state, errorTitle, errorDetail, attachmentsJson, createdAt, " +
                        "sortOrder, customRetryWithoutFieldsAvailable) " +
                        "VALUES ('m-new', '$account', 'c1', 'user', 'あしたはあめ', 'OpenAI', 'OpenAI', " +
                        "'m1', 0.0, 'delivered', NULL, NULL, NULL, 0, 9, 0)",
                )
                assertEquals(1, searchDao.pendingCount())
                val after = db.conversationDao().observeAllWithCount(account).first().associateBy { it.entity.id }
                assertEquals(4, after.getValue("c1").messageCount)
            } finally {
                db.close()
            }
        }

    // ── helpers ──────────────────────────────────────────────────────────

    /** Builds a real v1 database from the exported `1.json` and writes Room's identity hash. */
    private fun createLegacyV1Database(seed: (SupportSQLiteDatabase) -> Unit) {
        val schema = JSONObject(File("schemas/${OriveoDatabase::class.java.canonicalName}/1.json").readText())
            .getJSONObject("database")
        val identityHash = schema.getString("identityHash")

        val helper = FrameworkSQLiteOpenHelperFactory().create(
            SupportSQLiteOpenHelper.Configuration.builder(context)
                .name(dbName)
                .callback(
                    object : SupportSQLiteOpenHelper.Callback(1) {
                        override fun onCreate(db: SupportSQLiteDatabase) {
                            val entities = schema.getJSONArray("entities")
                            for (index in 0 until entities.length()) {
                                val entity = entities.getJSONObject(index)
                                val table = entity.getString("tableName")
                                db.execSQL(entity.getString("createSql").replace("\${TABLE_NAME}", table))
                                val indices = entity.optJSONArray("indices") ?: continue
                                for (i in 0 until indices.length()) {
                                    db.execSQL(
                                        indices.getJSONObject(i).getString("createSql")
                                            .replace("\${TABLE_NAME}", table),
                                    )
                                }
                            }
                            db.execSQL(
                                "CREATE TABLE IF NOT EXISTS room_master_table " +
                                    "(id INTEGER PRIMARY KEY, identity_hash TEXT)",
                            )
                            db.execSQL(
                                "INSERT OR REPLACE INTO room_master_table (id, identity_hash) " +
                                    "VALUES(42, '$identityHash')",
                            )
                        }

                        override fun onUpgrade(db: SupportSQLiteDatabase, oldVersion: Int, newVersion: Int) = Unit
                    },
                )
                .build(),
        )
        helper.writableDatabase.use { db ->
            db.setForeignKeyConstraintsEnabled(true)
            seed(db)
        }
        helper.close()
    }

    private fun deleteDatabaseFiles(file: File) {
        listOf(file, File("${file.path}-wal"), File("${file.path}-shm"), File("${file.path}-journal"))
            .forEach { it.delete() }
    }
}
