package ai.oriveo.community.core.data.database

import android.content.Context
import androidx.room.Room
import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.sqlite.db.SupportSQLiteOpenHelper
import androidx.sqlite.db.framework.FrameworkSQLiteOpenHelperFactory
import ai.oriveo.community.core.data.entity.McpConnectionStateEntity
import ai.oriveo.community.core.data.entity.McpConversationSwitchEntity
import ai.oriveo.community.core.data.entity.McpServerEntity
import ai.oriveo.community.core.data.entity.McpStepPayloadEntity
import ai.oriveo.community.core.data.entity.McpToolPermissionEntity
import ai.oriveo.community.core.data.entity.McpToolSnapshotEntity
import java.io.File
import kotlinx.coroutines.flow.first
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
 * A **real migration** test for v2 to v3: [OriveoDatabase.MIGRATION_2_3] runs against a genuine v2 database.
 *
 * `inMemoryDatabaseBuilder` alone is not enough: that path goes through Room's `createAllTables`, so not a single
 * statement of the migration runs, and schema drift and existing data go completely untested. The v2 database here is
 * created statement by statement from the **exported `2.json` schema**, so it matches what an already-installed app
 * holds.
 *
 * Two independent checks, both required:
 * 1. Room opens the migrated database. After a migration Room validates every table against its entity (columns,
 *    types, NOT NULL, primary key, indices); a hand-written CREATE statement that is off by one character is an
 *    `IllegalStateException` on open.
 * 2. The migrated tables are compared `PRAGMA` by `PRAGMA` with a database Room created from scratch, which proves
 *    that an upgraded install ends up with exactly the structure of a fresh one, collations included (Room's own
 *    validation does not look at those).
 */
@RunWith(RobolectricTestRunner::class)
class McpMigrationTest {

    private val context: Context get() = RuntimeEnvironment.getApplication()
    private val dbName = "migration-v2-to-v3.db"
    private val freshDbName = "fresh-v3.db"
    private val account = LOCAL_PARTITION_ID

    @Before
    fun setUp() {
        listOf(dbName, freshDbName).forEach { name ->
            context.getDatabasePath(name).let { file ->
                file.parentFile?.mkdirs()
                deleteDatabaseFiles(file)
            }
        }
    }

    @After
    fun tearDown() {
        listOf(dbName, freshDbName).forEach { deleteDatabaseFiles(context.getDatabasePath(it)) }
    }

    @Test
    fun `migration keeps existing rows and lets room open the database`() = runBlocking {
        createLegacyV2Database { db -> seedLegacyRows(db) }

        val db = openMigrated()
        try {
            val conversations = db.conversationDao().observeAllWithCount(account).first()
            assertEquals(listOf("c1"), conversations.map { it.entity.id })
            assertEquals("old conversation", conversations.single().entity.title)
            assertEquals(
                "the count recorded by the trigger before the upgrade must carry over unchanged",
                1,
                conversations.single().messageCount,
            )
            val message = db.messageDao().getByConversation(account, "c1").single()
            assertEquals("message from before the upgrade", message.text)
            assertNull("an older message reads the new column as null", message.toolStepsJson)
            assertEquals(
                "the old provider's fields are kept as they were",
                "sk-...abcd",
                db.providerDao().getAll(account).single().apiKeyPreview,
            )
        } finally {
            db.close()
        }
    }

    /** The migration leaves `messages` and `conversations` in place, so the count of new messages is maintained as before. */
    @Test
    fun `message count triggers still work after the migration`() = runBlocking {
        createLegacyV2Database { db -> seedLegacyRows(db) }

        val db = openMigrated()
        try {
            // The production DatabaseModule does this in onOpen; it is idempotent when the triggers are already there.
            ConversationSearchSchema.installTriggers(db.openHelper.writableDatabase)
            db.openHelper.writableDatabase.execSQL(
                "INSERT INTO messages (id, accountId, conversationId, role, text, providerKind, providerName, " +
                    "modelName, estimatedCost, state, errorTitle, errorDetail, attachmentsJson, createdAt, " +
                    "sortOrder, customRetryWithoutFieldsAvailable) " +
                    "VALUES ('m-new', '$account', 'c1', 'user', 'new message after the upgrade', 'OpenAI', 'OpenAI', " +
                    "'m1', 0.0, 'delivered', NULL, NULL, NULL, 0, 1, 0)",
            )

            val conversations = db.conversationDao().observeAllWithCount(account).first()
            assertEquals("1 before the upgrade + 1 after", 2, conversations.single().messageCount)
        } finally {
            db.close()
        }
    }

    /**
     * The structure of the six tables matches a fresh install table by table: columns (name, type, NOT NULL, primary
     * key order), collation, and indices (name, uniqueness, columns). Asserting only that the tables exist would not
     * catch a missing `accountId` or a missing unique index.
     */
    @Test
    fun `migrated mcp tables are identical to a freshly created database`() {
        createLegacyV2Database { }
        val migrated = openMigrated()
        val fresh = openFresh()

        try {
            val migratedDb = migrated.openHelper.readableDatabase
            val freshDb = fresh.openHelper.readableDatabase
            MCP_TABLES.forEach { table ->
                val freshShape = tableShape(freshDb, table)
                assertTrue("a fresh database must contain $table", freshShape.columns.isNotEmpty())
                assertEquals("the structure of $table must match a fresh database", freshShape, tableShape(migratedDb, table))
                assertTrue(
                    "$table must carry accountId in its primary key - ${freshShape.columns}",
                    freshShape.columns.any { it.startsWith("accountId|TEXT|notnull=1|pk=") && !it.endsWith("pk=0") },
                )
                assertTrue(
                    "$table must have an index on accountId - ${freshShape.indexes}",
                    "index_${table}_accountId|unique=0|accountId" in tableShape(migratedDb, table).indexes,
                )
            }
            assertTrue(
                "the slug must be unique",
                "index_mcp_server_accountId_slug|unique=1|accountId,slug" in tableShape(migratedDb, "mcp_server").indexes,
            )
            assertEquals(
                "an upgraded database and a fresh one carry the same identity hash",
                identityHash(freshDb),
                identityHash(migratedDb),
            )
        } finally {
            migrated.close()
            fresh.close()
        }
    }

    /**
     * `ALTER TABLE` appends the new column while a fresh database follows the entity's field order, so the columns of
     * `messages` are compared as a set (name, type, nullability, primary key order) together with the indices.
     */
    @Test
    fun `migration adds toolStepsJson to messages and the table matches a fresh database`() = runBlocking {
        createLegacyV2Database { db -> seedLegacyRows(db) }
        val db = openMigrated()
        val fresh = openFresh()
        try {
            assertEquals(
                "progress may only be written while the message is generating",
                0,
                db.messageDao().updateMcpToolStepsProgress(account, "m1", "[]"),
            )
            db.openHelper.writableDatabase.execSQL("UPDATE messages SET state = 'Generating' WHERE id = 'm1'")
            assertEquals(1, db.messageDao().updateMcpToolStepsProgress(account, "m1", "[{\"id\":\"1:c\"}]"))
            assertEquals("[{\"id\":\"1:c\"}]", db.messageDao().getByConversation(account, "c1").single().toolStepsJson)

            val freshShape = tableShape(fresh.openHelper.readableDatabase, "messages")
            val migratedShape = tableShape(db.openHelper.readableDatabase, "messages")
            assertTrue("toolStepsJson|TEXT|notnull=0|pk=0" in migratedShape.columns)
            assertEquals("the columns of messages must match a fresh database", freshShape.columns.toSet(), migratedShape.columns.toSet())
            assertEquals(freshShape.indexes, migratedShape.indexes)
        } finally {
            db.close()
            fresh.close()
        }
    }

    /** The key constraints live in the database: a slug cannot repeat, and ids that differ only in case are one row. */
    @Test
    fun `migrated schema enforces the slug and case-insensitive id constraints`() {
        createLegacyV2Database { }
        val db = openMigrated()
        try {
            val writable = db.openHelper.writableDatabase
            fun insertServer(id: String, slug: String) = writable.execSQL(
                "INSERT INTO mcp_server (id, accountId, name, slug, url, authKind, localOnly, iconURL, " +
                    "createdAt, updatedAt, pendingAdd) " +
                    "VALUES ('$id', '$account', 'n', '$slug', 'https://x.example.com', 'auto', 0, NULL, 1, 1, 0)",
            )
            insertServer("s1", "notion")

            assertTrue(
                "a duplicate slug must be rejected by the unique index",
                runCatching { insertServer("s2", "notion") }.isFailure,
            )
            assertTrue(
                "id is NOCASE - case variants count as the same row",
                runCatching { insertServer("S1", "other") }.isFailure,
            )
            assertEquals(1, rowCount(writable, "mcp_server"))
        } finally {
            db.close()
        }
    }

    /** Every new table can be written and read back through the DAO right after the upgrade. */
    @Test
    fun `dao round trips work on the migrated database`() = runBlocking {
        createLegacyV2Database { db -> seedLegacyRows(db) }
        val db = openMigrated()
        try {
            val dao = db.mcpServerDao()
            val server = McpServerEntity(
                id = "s1",
                accountId = account,
                name = "Notion",
                slug = "notion",
                url = "https://mcp.example.com",
                authKind = "auto",
                localOnly = false,
                iconURL = null,
                createdAt = 1L,
                updatedAt = 2L,
                pendingAdd = true,
            )
            dao.insert(server)
            assertEquals(server, dao.getById(account, "S1"))
            assertEquals(1, dao.countReadable(account, listOf("auto", "token")))
            assertEquals(1, dao.clearPendingAdd(account, "s1"))
            assertEquals(false, dao.getById(account, "s1")?.pendingAdd)

            val state = McpConnectionStateEntity("s1", account, "connected", 5L, "2026-07-28", "stateless", null)
            dao.upsertConnectionState(state)
            assertEquals(state, dao.getConnectionState(account, "s1"))

            val snapshot = McpToolSnapshotEntity(
                serverId = "s1",
                toolName = "search",
                accountId = account,
                title = "Search",
                description = null,
                inputSchema = "{}",
                annotations = "{}",
                contentHash = "h1",
                readOnly = true,
                pendingReview = false,
                oversized = false,
                updatedAt = 3L,
            )
            dao.insertToolSnapshots(listOf(snapshot))
            assertEquals(listOf(snapshot), dao.getToolSnapshots(account, "s1"))

            val permission = McpToolPermissionEntity("s1", "search", account, "ask")
            dao.upsertToolPermission(permission)
            assertEquals(listOf(permission), dao.getToolPermissions(account, "s1"))

            dao.insertConversationSwitch(McpConversationSwitchEntity("c1", "s1", account, 4L))
            assertEquals(listOf("s1"), dao.getEnabledServerIds(account, "C1"))

            val payload = McpStepPayloadEntity("m1", "1:call", account, "{}", "ok", 6L, serverId = "s1")
            dao.upsertStepPayload(payload)
            assertEquals(payload, dao.getStepPayload(account, "m1", "1:call"))

            // Removing the conversation's payloads relies on a join with the pre-existing `messages` table.
            dao.deleteStepPayloadsOfConversation(account, "c1")
            assertNull(dao.getStepPayload(account, "m1", "1:call"))

            assertEquals(server.copy(pendingAdd = false), dao.deleteServerCascade(account, "s1"))
            MCP_TABLES.forEach { table ->
                assertEquals("$table must be empty after the server is removed", 0, rowCount(db.openHelper.readableDatabase, table))
            }
        } finally {
            db.close()
        }
    }

    // ── helpers ──────────────────────────────────────────────────────────

    private fun openMigrated(): OriveoDatabase =
        Room.databaseBuilder(context, OriveoDatabase::class.java, dbName)
            .addMigrations(OriveoDatabase.MIGRATION_2_3)
            .allowMainThreadQueries()
            .build()
            // Open the database right away: the migration and Room's per-table validation both happen here, and a failure throws here.
            .also { it.openHelper.writableDatabase }

    /** A database Room creates from the entities, with no migration involved. */
    private fun openFresh(): OriveoDatabase =
        Room.databaseBuilder(context, OriveoDatabase::class.java, freshDbName)
            .allowMainThreadQueries()
            .build()
            .also { it.openHelper.writableDatabase }

    private fun seedLegacyRows(db: SupportSQLiteDatabase) {
        // A real v2 database carries the message count triggers (installed by the previous migration and on every
        // open). Without them the seed message is not counted and "the migration keeps the count" could not be asserted.
        ConversationSearchSchema.installTriggers(db)
        db.execSQL(
            "INSERT INTO conversations (id, title, hasCustomTitle, providerID, providerKind, modelID, " +
                "useMemory, previewText, estimatedCost, isDraft, draftText, createdAt, updatedAt, accountId) " +
                "VALUES ('c1', 'old conversation', 0, 'p1', 'OpenAI', 'm1', 1, '', 0.0, 0, '', 0, 0, '$account')",
        )
        db.execSQL(
            "INSERT INTO messages (id, accountId, conversationId, role, text, providerKind, providerName, " +
                "modelName, estimatedCost, state, errorTitle, errorDetail, attachmentsJson, createdAt, " +
                "sortOrder, customRetryWithoutFieldsAvailable) " +
                "VALUES ('m1', '$account', 'c1', 'user', 'message from before the upgrade', 'OpenAI', 'OpenAI', " +
                "'m1', 0.0, 'delivered', NULL, NULL, NULL, 0, 0, 0)",
        )
        db.execSQL(
            "INSERT INTO providers (id, kind, status, lastCheckedAt, apiKeyPreview, lastError, baseUrlText, " +
                "customName, modelsJson, catalogModelsJson, updatedAt, accountId, authMode) " +
                "VALUES ('p1', 'OpenAI', '{}', NULL, 'sk-...abcd', NULL, NULL, NULL, '[]', '[]', 0, '$account', 'apiKey')",
        )
    }

    /** Builds a real v2 database from the exported `2.json` and writes Room's identity hash. */
    private fun createLegacyV2Database(seed: (SupportSQLiteDatabase) -> Unit) {
        val schema = JSONObject(File("schemas/${OriveoDatabase::class.java.canonicalName}/2.json").readText())
            .getJSONObject("database")
        val identityHash = schema.getString("identityHash")

        val helper = FrameworkSQLiteOpenHelperFactory().create(
            SupportSQLiteOpenHelper.Configuration.builder(context)
                .name(dbName)
                .callback(
                    object : SupportSQLiteOpenHelper.Callback(2) {
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

    private data class TableShape(val columns: List<String>, val indexes: Set<String>, val collations: List<String>)

    /** The complete structural fingerprint of a table: columns, primary key order, indices (name / uniqueness / columns) and the collation of each key column. */
    private fun tableShape(db: SupportSQLiteDatabase, table: String): TableShape {
        val columns = db.query("PRAGMA table_info(`$table`)").use { cursor ->
            val rows = mutableListOf<String>()
            while (cursor.moveToNext()) {
                rows += "${cursor.getString(1)}|${cursor.getString(2)}|notnull=${cursor.getInt(3)}|pk=${cursor.getInt(5)}"
            }
            rows
        }
        val indexNames = db.query("PRAGMA index_list(`$table`)").use { cursor ->
            val rows = mutableListOf<Pair<String, Int>>()
            while (cursor.moveToNext()) rows += cursor.getString(1) to cursor.getInt(2)
            rows
        }
        val collations = mutableListOf<String>()
        val indexes = indexNames.map { (name, unique) ->
            val indexColumns = db.query("PRAGMA index_xinfo(`$name`)").use { cursor ->
                val rows = mutableListOf<String>()
                while (cursor.moveToNext()) {
                    // Only key columns (column 6 is 1) are part of the index definition; the rest are auxiliary columns such as rowid.
                    if (cursor.getInt(5) == 1) {
                        rows += cursor.getString(2)
                        // The automatic primary key index uses the column's declared COLLATE, which is how NOCASE is checked here.
                        if (name.startsWith("sqlite_autoindex_")) {
                            collations += "${cursor.getString(2)}:${cursor.getString(4)}"
                        }
                    }
                }
                rows
            }
            // The automatic primary key index has a numbered name, so only its columns are compared.
            val label = if (name.startsWith("sqlite_autoindex_")) "pk" else name
            "$label|unique=$unique|${indexColumns.joinToString(",")}"
        }.toSet()
        return TableShape(columns, indexes, collations.sorted())
    }

    private fun identityHash(db: SupportSQLiteDatabase): String =
        db.query("SELECT identity_hash FROM room_master_table WHERE id = 42").use { cursor ->
            cursor.moveToFirst()
            cursor.getString(0)
        }

    private fun rowCount(db: SupportSQLiteDatabase, table: String): Int =
        db.query("SELECT COUNT(*) FROM `$table`").use { cursor ->
            cursor.moveToFirst()
            cursor.getInt(0)
        }

    private fun deleteDatabaseFiles(file: File) {
        listOf(file, File("${file.path}-wal"), File("${file.path}-shm"), File("${file.path}-journal"))
            .forEach { it.delete() }
    }

    private companion object {
        val MCP_TABLES = listOf(
            "mcp_server",
            "mcp_connection_state",
            "mcp_tool_snapshot",
            "mcp_tool_permission",
            "mcp_conversation_switch",
            "mcp_step_payload",
        )
    }
}
