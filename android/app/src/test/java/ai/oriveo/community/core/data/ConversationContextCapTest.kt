package ai.oriveo.community.core.data

import android.content.Context
import androidx.room.Room
import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.sqlite.db.SupportSQLiteOpenHelper
import androidx.sqlite.db.framework.FrameworkSQLiteOpenHelperFactory
import ai.oriveo.community.core.context.ContextBudgetCap
import ai.oriveo.community.core.context.ContextContractFixture
import ai.oriveo.community.core.context.ContextContractFixture.id
import ai.oriveo.community.core.data.database.OriveoDatabase
import ai.oriveo.community.core.data.mapper.ConversationMapper.toContextBudgetCapOrNull
import ai.oriveo.community.core.data.mapper.ConversationMapper.toDomain
import ai.oriveo.community.core.data.mapper.ConversationMapper.toEntity
import ai.oriveo.community.core.data.mapper.ConversationMapper.toStorageText
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.ProviderKind
import java.io.File
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * The conversation contextCap local column: after migrating an old database it is NULL (follow global), and it survives a Room + mapper round trip once written;
 * the stored-text codec follows the storageCases of conversation-context-cap.v1.json; contentEquals compares contextCap.
 */
@RunWith(RobolectricTestRunner::class)
class ConversationContextCapTest {

    private val context: Context get() = RuntimeEnvironment.getApplication()
    private val dbName = "migration-v4-to-v5.db"
    private val fixture: JsonObject by lazy { ContextContractFixture.load("conversation-context-cap.v1.json") }

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
    fun persist_roundtrip() = runBlocking {
        createDatabaseFromExportedSchema(dbName, version = 4) { db -> seedConversation(db, CONV_A) }
        val db = openMigrated()
        try {
            val dao = db.conversationDao()
            val legacy = dao.getById(ACCOUNT, CONV_A)!!.toDomain()
            listOf(
                ContextBudgetCap.Custom(190_000) to "190000",
                ContextBudgetCap.Unlimited to "unlimited",
                ContextBudgetCap.Auto to "auto",
            ).forEach { (cap, text) ->
                dao.upsert(legacy.copy(contextCap = cap).toEntity(ACCOUNT))
                val stored = dao.getById(ACCOUNT, CONV_A)!!
                assertEquals("the database stores the storage text", text, stored.contextCap)
                assertEquals(cap, stored.toDomain().contextCap)
            }

            val fresh = sample(CONV_B).copy(contextCap = ContextBudgetCap.Custom(32_000))
            dao.upsert(fresh.toEntity(ACCOUNT))
            assertEquals(ContextBudgetCap.Custom(32_000), dao.getById(ACCOUNT, CONV_B)!!.toDomain().contextCap)

            // Clearing back to follow global writes NULL, not "auto".
            dao.upsert(dao.getById(ACCOUNT, CONV_A)!!.toDomain().copy(contextCap = null).toEntity(ACCOUNT))
            assertNull(dao.getById(ACCOUNT, CONV_A)!!.contextCap)
            assertNull(dao.getById(ACCOUNT, CONV_A)!!.toDomain().contextCap)
        } finally {
            db.close()
        }
    }

    @Test
    fun migrated_rows_follow_global() = runBlocking {
        createDatabaseFromExportedSchema(dbName, version = 4) { db -> seedConversation(db, CONV_A) }
        val db = openMigrated()
        try {
            val raw = db.openHelper.writableDatabase
            raw.query("PRAGMA table_info(`conversations`)").use { c ->
                var found = false
                while (c.moveToNext()) {
                    if (c.getString(c.getColumnIndexOrThrow("name")) == "contextCap") {
                        found = true
                        assertEquals("TEXT", c.getString(c.getColumnIndexOrThrow("type")))
                        assertEquals("nullable column", 0, c.getInt(c.getColumnIndexOrThrow("notnull")))
                    }
                }
                assertTrue("the contextCap column exists after the migration", found)
            }
            val legacy = db.conversationDao().getById(ACCOUNT, CONV_A)!!
            assertEquals("other columns of the old conversation are untouched", "\u8001\u4f1a\u8bdd", legacy.title)
            assertNull("old rows are not backfilled", legacy.contextCap)
            assertNull("old rows follow global", legacy.toDomain().contextCap)

            // Text in the database that cannot be decoded (for example an older write by another platform) also reads as follow global.
            raw.execSQL("UPDATE conversations SET contextCap = '64k' WHERE id = '$CONV_A'")
            assertNull(db.conversationDao().getById(ACCOUNT, CONV_A)!!.toDomain().contextCap)
        } finally {
            db.close()
        }
    }

    @Test
    fun storage_codec_matches_fixture() {
        val cases = ContextContractFixture.cases(fixture, "storageCases")
        assertTrue(cases.isNotEmpty())
        cases.forEach { case ->
            val input = case["input"]!!.jsonPrimitive.content
            val expectedEl = case["expected"]!!.jsonObject["cap"]!!
            val expected = if (expectedEl is JsonNull) {
                null
            } else {
                val p = expectedEl.jsonPrimitive
                ContextBudgetCap.parse(if (p.isString) p.content else p.content.toLong())
                    ?: error("fixture expectation cannot be decoded ${case.id()}")
            }
            val decoded = input.toContextBudgetCapOrNull()
            assertEquals(case.id(), expected, decoded)
            // A value that decodes must write back to storage text identical to the input.
            decoded?.let { assertEquals(case.id(), input, it.toStorageText()) }
        }
        assertNull((null as String?).toContextBudgetCapOrNull())
    }

    @Test
    fun content_equal_compares_context_cap() {
        val base = sample(CONV_A).copy(contextCap = ContextBudgetCap.Custom(190_000))
        assertTrue(base.contentEquals(base.copy(updatedAt = base.updatedAt + 1)))
        assertFalse(base.contentEquals(base.copy(contextCap = null)))
        assertFalse(base.contentEquals(base.copy(contextCap = ContextBudgetCap.Custom(190_001))))
        assertFalse(base.contentEquals(base.copy(contextCap = ContextBudgetCap.Unlimited)))
        assertFalse(sample(CONV_A).contentEquals(sample(CONV_A).copy(contextCap = ContextBudgetCap.Auto)))
        // Still equal after an entity round trip (the mapper carries contextCap in both directions).
        assertTrue(base.contentEquals(base.toEntity(ACCOUNT).toDomain()))
    }

    private fun openMigrated(): OriveoDatabase =
        Room.databaseBuilder(context, OriveoDatabase::class.java, dbName)
            .addMigrations(OriveoDatabase.MIGRATION_4_5)
            .allowMainThreadQueries()
            .build()
            .also { it.openHelper.writableDatabase }

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
