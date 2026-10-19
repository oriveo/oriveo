package ai.oriveo.community.core.data

import android.content.Context
import androidx.room.Room
import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.sqlite.db.SupportSQLiteOpenHelper
import androidx.sqlite.db.framework.FrameworkSQLiteOpenHelperFactory
import ai.oriveo.community.core.data.database.OriveoDatabase
import ai.oriveo.community.core.data.mapper.ConversationMapper.toDomain
import ai.oriveo.community.core.data.mapper.ConversationMapper.toEntity
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.ProviderKind
import java.io.File
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * The conversation instructions local column: after migrating an old database it defaults to "", and it survives a Room + mapper round trip once written;
 * conflict detection compares instructions in contentEquals. For the migration pattern see ContextLedgerMigrationTest.
 */
@RunWith(RobolectricTestRunner::class)
class ConversationInstructionsTest {

    private val context: Context get() = RuntimeEnvironment.getApplication()
    private val dbName = "migration-v4-to-v5.db"

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
    fun instructions_persist_roundtrip() = runBlocking {
        createDatabaseFromExportedSchema(dbName, version = 4) { db -> seedConversation(db, CONV_A) }
        val db = Room.databaseBuilder(context, OriveoDatabase::class.java, dbName)
            .addMigrations(OriveoDatabase.MIGRATION_4_5)
            .allowMainThreadQueries()
            .build()
        try {
            val dao = db.conversationDao()
            val legacy = dao.getById(ACCOUNT, CONV_A)!!
            assertEquals("a conversation from before the upgrade defaults to empty instructions", "", legacy.instructions)
            assertEquals("", legacy.toDomain().instructions)

            val text = "  Reply in Arabic.\n\u6bcf\u7ae0\u81f3\u5c11 2000 \u5b57 😀\n"
            dao.upsert(legacy.toDomain().copy(instructions = text).toEntity(ACCOUNT))
            val stored = dao.getById(ACCOUNT, CONV_A)!!
            assertEquals("the database stores the original text", text, stored.instructions)
            assertEquals(text, stored.toDomain().instructions)

            val fresh = sample(CONV_B).copy(instructions = "Use metric units.")
            dao.upsert(fresh.toEntity(ACCOUNT))
            assertEquals("Use metric units.", dao.getById(ACCOUNT, CONV_B)!!.toDomain().instructions)

            dao.upsert(stored.toDomain().copy(instructions = "").toEntity(ACCOUNT))
            assertEquals("", dao.getById(ACCOUNT, CONV_A)!!.instructions)
        } finally {
            db.close()
        }
    }

    @Test
    fun content_equal_compares_instructions() {
        val base = sample(CONV_A).copy(instructions = "Reply in French.")
        assertTrue(base.contentEquals(base.copy(updatedAt = base.updatedAt + 1)))
        assertFalse(base.contentEquals(base.copy(instructions = "")))
        assertFalse(base.contentEquals(base.copy(instructions = "Reply in French. ")))
        // Still equal after an entity round trip (the mapper carries instructions in both directions).
        assertTrue(base.contentEquals(base.toEntity(ACCOUNT).toDomain()))
    }

    private fun sample(id: String) = Conversation(
        id = id,
        title = "t",
        providerID = "p1",
        providerKind = ProviderKind.OpenAI,
        modelID = "m1",
        createdAt = 1L,
        updatedAt = 1L,
    )

    private fun seedConversation(db: SupportSQLiteDatabase, id: String) = db.execSQL(
        "INSERT INTO conversations (id, title, hasCustomTitle, providerID, providerKind, modelID, " +
            "useMemory, previewText, estimatedCost, isDraft, draftText, createdAt, updatedAt, " +
            "accountId) " +
            "VALUES ('$id', '\u8001\u4f1a\u8bdd', 0, 'p1', 'OpenAI', 'm1', 1, '', 0.0, 0, '', 0, 0, '$ACCOUNT')",
    )

    /** Builds a real database from the exported schema JSON (tables + indices) and writes Room's identity hash. */
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
        const val ACCOUNT = "acct-1"
        const val CONV_A = "AAAAAAAA-0000-0000-0000-000000000001"
        const val CONV_B = "BBBBBBBB-0000-0000-0000-000000000002"
    }
}
