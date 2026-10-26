package ai.oriveo.community.core.data.database

import android.content.Context
import androidx.room.Room
import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.sqlite.db.SupportSQLiteOpenHelper
import androidx.sqlite.db.framework.FrameworkSQLiteOpenHelperFactory
import ai.oriveo.community.core.data.mapper.MessageMapper.toDomain
import java.io.File
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * v5 to v6: messages gains the nullable nonUsdCost* columns and conversations gains nonUsdCostTotals.
 * Rows written before the migration keep their USD cost, read back with no non-USD part, and are not backfilled;
 * `messages` is not rebuilt, so rowid and the search triggers stay as they were.
 */
@RunWith(RobolectricTestRunner::class)
class CostCurrencyMigrationTest {

    private val context: Context get() = RuntimeEnvironment.getApplication()
    private val dbName = "cost-currency-migration.db"

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
    fun `existing rows keep their USD cost and read back with no non-USD part`() = runBlocking {
        var rowId = -1L
        createDatabaseFromExportedSchema(dbName, 5) { db ->
            seedConversation(db)
            seedMessage(db)
            db.query("SELECT rowid FROM messages WHERE id = '$MSG'").use { cursor ->
                cursor.moveToFirst()
                rowId = cursor.getLong(0)
            }
        }
        val db = openMigrated()
        try {
            val entity = db.messageDao().getById(ACCOUNT, MSG)!!
            assertEquals(0.02, entity.estimatedCost, 0.0)
            assertEquals("LOCAL_ESTIMATE", entity.costSource)
            assertNull(entity.nonUsdCostCurrency)
            assertNull(entity.nonUsdCostAmount)
            assertNull(entity.nonUsdCostSource)
            assertNull(entity.toDomain().nonUsdCost)

            val conversation = db.conversationDao().getById(ACCOUNT, CONV)!!
            assertEquals(0.02, conversation.estimatedCost, 0.0)
            assertNull("existing conversations are not backfilled with non-USD totals", conversation.nonUsdCostTotals)

            val sql = db.openHelper.writableDatabase
            sql.query("SELECT rowid FROM messages WHERE id = '$MSG'").use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals("the search index uses messages.rowid as docid, so it must not change", rowId, cursor.getLong(0))
            }
            sql.query("SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND tbl_name = 'messages'").use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertTrue("the search triggers on messages must survive the migration", cursor.getInt(0) > 0)
            }
        } finally {
            db.close()
        }
    }

    @Test
    fun `migrated database stores and reads a non-USD cost`() = runBlocking {
        createDatabaseFromExportedSchema(dbName, 5) { db ->
            seedConversation(db)
            seedMessage(db)
        }
        val db = openMigrated()
        try {
            val sql = db.openHelper.writableDatabase
            sql.execSQL(
                "UPDATE messages SET nonUsdCostCurrency = 'CNY', nonUsdCostAmount = 0.3, nonUsdCostSource = 'UPSTREAM' " +
                    "WHERE id = '$MSG'",
            )
            val nonUsd = db.messageDao().getById(ACCOUNT, MSG)!!.toDomain().nonUsdCost!!
            assertEquals("CNY", nonUsd.currencyCode)
            assertEquals(0.3, nonUsd.amount, 0.0)
            assertEquals("UPSTREAM", nonUsd.costSource)
        } finally {
            db.close()
        }
    }

    private fun seedConversation(db: SupportSQLiteDatabase) = db.execSQL(
        "INSERT INTO conversations (id, title, hasCustomTitle, providerID, providerKind, modelID, useMemory, " +
            "previewText, estimatedCost, isDraft, draftText, createdAt, updatedAt, accountId) " +
            "VALUES ('$CONV', 't', 0, 'p1', 'OpenAI', 'm1', 1, '', 0.02, 0, '', 1, 1, '$ACCOUNT')",
    )

    private fun seedMessage(db: SupportSQLiteDatabase) = db.execSQL(
        "INSERT INTO messages (id, accountId, conversationId, role, text, providerKind, providerName, " +
            "modelName, estimatedCost, state, createdAt, sortOrder, customRetryWithoutFieldsAvailable, costSource) " +
            "VALUES ('$MSG', '$ACCOUNT', '$CONV', 'Assistant', 'hi', 'OpenAI', 'OpenAI', 'm1', 0.02, 'Delivered', 1, 0, 0, 'LOCAL_ESTIMATE')",
    )

    private fun openMigrated(): OriveoDatabase =
        Room.databaseBuilder(context, OriveoDatabase::class.java, dbName)
            .addMigrations(*OriveoDatabase.allMigrations())
            .allowMainThreadQueries()
            .build()
            .also { it.openHelper.writableDatabase }

    /** Builds a real database (tables and indices) from the exported schema JSON and writes Room's identity hash. */
    private fun createDatabaseFromExportedSchema(name: String, version: Int, seed: (SupportSQLiteDatabase) -> Unit) {
        val schema = JSONObject(
            File("schemas/${OriveoDatabase::class.java.canonicalName}/$version.json").readText(),
        ).getJSONObject("database")
        val identityHash = schema.getString("identityHash")
        val helper = FrameworkSQLiteOpenHelperFactory().create(
            SupportSQLiteOpenHelper.Configuration.builder(context)
                .name(name)
                .callback(
                    object : SupportSQLiteOpenHelper.Callback(version) {
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
                            ConversationSearchSchema.installTriggers(db)
                        }

                        override fun onUpgrade(db: SupportSQLiteDatabase, oldVersion: Int, newVersion: Int) = Unit
                    },
                )
                .build(),
        )
        helper.writableDatabase.use { db -> seed(db) }
        helper.close()
    }

    private fun deleteDatabaseFiles(file: File) {
        listOf(file, File("${file.path}-wal"), File("${file.path}-shm"), File("${file.path}-journal"))
            .forEach { it.delete() }
    }

    private companion object {
        const val ACCOUNT = "local"
        const val CONV = "AAAAAAAA-0000-4000-8000-000000000001"
        const val MSG = "BBBBBBBB-0000-4000-8000-000000000002"
    }
}
