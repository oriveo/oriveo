package ai.oriveo.community.core.data.database

import android.content.Context
import androidx.room.Room
import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.sqlite.db.SupportSQLiteOpenHelper
import androidx.sqlite.db.framework.FrameworkSQLiteOpenHelperFactory
import ai.oriveo.community.core.context.ContextBasis
import ai.oriveo.community.core.context.ContextManifest
import ai.oriveo.community.core.context.ContextManifestLog
import ai.oriveo.community.core.context.RequestPurpose
import ai.oriveo.community.core.context.RhoCalibration
import ai.oriveo.community.core.context.StopReason
import ai.oriveo.community.core.data.entity.ContextManifestEntity
import ai.oriveo.community.core.data.entity.ContextRhoCalibrationEntity
import ai.oriveo.community.core.data.mapper.MessageMapper.toDomain
import ai.oriveo.community.core.data.mapper.MessageMapper.toEntity
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
 * A real v4 to v5 migration: messages gains a nullable stopReason, and two context Ledger tables are created (rho calibration, request manifests).
 * The v4 database is built statement by statement from the exported `4.json` (same shape as the one an existing user holds), opened by Room after the migration for per-table validation,
 * and then compared table by table with a database freshly created from `5.json`. For the pattern see [McpMigrationTest].
 */
@RunWith(RobolectricTestRunner::class)
class ContextLedgerMigrationTest {

    private val context: Context get() = RuntimeEnvironment.getApplication()
    private val dbName = "migration-v4-to-v5.db"
    private val freshDbName = "fresh-v5.db"

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
    fun `migration_adds_stop_reason_and_ledger`() = runBlocking {
        createDatabaseFromExportedSchema(dbName, version = 4) { db ->
            seedConversation(db, CONV_A)
            seedMessage(db, MSG_LEGACY, CONV_A)
        }
        val db = openMigrated()
        // The migrated database is at the latest version (messages also gains memoryItemIds), so the structure comparison uses the latest schema.
        createDatabaseFromExportedSchema(freshDbName, version = LATEST_VERSION) { }
        val fresh = FrameworkSQLiteOpenHelperFactory().create(
            SupportSQLiteOpenHelper.Configuration.builder(context)
                .name(freshDbName)
                .callback(NoOpCallback(LATEST_VERSION))
                .build(),
        )
        try {
            val row = db.messageDao().getById(ACCOUNT, MSG_LEGACY)!!
            assertEquals("\u5347\u7ea7\u524d\u5c31\u5b58\u5728\u7684\u6d88\u606f", row.text)
            assertNull("an old message does not backfill stopReason", row.stopReason)

            listOf("messages", "context_rho_calibration", "context_manifest").forEach { table ->
                assertEquals(
                    "$table must have the same structure as a fresh install",
                    tableShape(fresh.readableDatabase, table),
                    tableShape(db.openHelper.readableDatabase, table),
                )
            }
        } finally {
            db.close()
            fresh.close()
        }
    }

    @Test
    fun `legacy_null_reads_null`() = runBlocking {
        createDatabaseFromExportedSchema(dbName, version = 4) { db ->
            seedConversation(db, CONV_A)
            seedMessage(db, MSG_LEGACY, CONV_A)
        }
        val db = openMigrated()
        try {
            val message = db.messageDao().getById(ACCOUNT, MSG_LEGACY)!!.toDomain()
            assertNull(message.stopReason)
        } finally {
            db.close()
        }
    }

    @Test
    fun `stop_reason_roundtrip`() = runBlocking {
        createDatabaseFromExportedSchema(dbName, version = 4) { db ->
            seedConversation(db, CONV_A)
            seedMessage(db, MSG_LEGACY, CONV_A)
        }
        val db = openMigrated()
        try {
            val dao = db.messageDao()
            val legacy = dao.getById(ACCOUNT, MSG_LEGACY)!!.toDomain()
            StopReason.entries.forEach { reason ->
                dao.upsert(legacy.copy(stopReason = reason).toEntity(ACCOUNT, CONV_A, 0))
                val stored = dao.getById(ACCOUNT, MSG_LEGACY)!!
                assertEquals("the database stores the wire text", reason.wire, stored.stopReason)
                assertEquals(reason, stored.toDomain().stopReason)
            }
            // An unknown string written by another platform or a future version reads as unknown, not dropped to null.
            db.openHelper.writableDatabase.execSQL(
                "UPDATE messages SET stopReason = 'some_future_reason' WHERE id = '$MSG_LEGACY'",
            )
            assertEquals(StopReason.UNKNOWN, dao.getById(ACCOUNT, MSG_LEGACY)!!.toDomain().stopReason)
        } finally {
            db.close()
        }
    }

    @Test
    fun `rho_table_roundtrip`() = runBlocking {
        createDatabaseFromExportedSchema(dbName, version = 4) { }
        val db = openMigrated()
        try {
            val dao = db.contextLedgerDao()
            val seeded = RhoCalibration()
                .recordingSample(observedInput = 400, mediaTokens = 0, textBytes = 1000)
                .recordingSample(observedInput = 500, mediaTokens = 0, textBytes = 1000)
            dao.upsertRho(ContextRhoCalibrationEntity.of("t1", "m1", seeded))
            dao.upsertRho(ContextRhoCalibrationEntity.of("t1", "m2", RhoCalibration()))
            assertEquals(seeded, dao.rho("t1", "m1")!!.calibration)

            val next = seeded.recordingSample(observedInput = 600, mediaTokens = 0, textBytes = 1000)
            dao.upsertRho(ContextRhoCalibrationEntity.of("t1", "m1", next))
            val stored = dao.rho("t1", "m1")!!
            assertEquals(3, stored.n)
            assertEquals(next, stored.calibration)
            assertEquals(2, dao.allRho().size)
            assertNull(dao.rho("t2", "m1"))
        } finally {
            db.close()
        }
    }

    @Test
    fun `manifest_keeps_latest_50`() = runBlocking {
        createDatabaseFromExportedSchema(dbName, version = 4) { db -> seedConversation(db, CONV_A) }
        val db = openMigrated()
        try {
            val dao = db.contextLedgerDao()
            val max = ContextManifestLog.MAX_PER_CONVERSATION
            (1..max + 5).forEach { i -> dao.appendManifest(ContextManifestEntity.of(manifest(CONV_A, "r$i", i.toLong()))) }
            dao.appendManifest(ContextManifestEntity.of(manifest(CONV_B, "other", 1L)))

            val kept = dao.manifests(CONV_A)
            assertEquals(max, kept.size)
            assertEquals((6..max + 5).map { "r$it" }, kept.map { it.requestId })
            val decoded = kept.last().manifest
            assertEquals(manifest(CONV_A, "r${max + 5}", (max + 5).toLong()), decoded)
            assertEquals("other conversations are not affected by trimming", 1, dao.manifests(CONV_B).size)
        } finally {
            db.close()
        }
    }

    @Test
    fun `manifest_deleted_with_conversation`() = runBlocking {
        createDatabaseFromExportedSchema(dbName, version = 4) { db ->
            seedConversation(db, CONV_A)
            seedConversation(db, CONV_B)
        }
        val db = openMigrated()
        try {
            val dao = db.contextLedgerDao()
            dao.upsertRho(ContextRhoCalibrationEntity.of("t1", "m1", RhoCalibration()))
            dao.appendManifest(ContextManifestEntity.of(manifest(CONV_A, "a1", 1L)))
            dao.appendManifest(ContextManifestEntity.of(manifest(CONV_B, "b1", 1L)))

            db.conversationDao().deleteById(ACCOUNT, CONV_A)

            assertTrue(dao.manifests(CONV_A).isEmpty())
            assertEquals(1, dao.manifests(CONV_B).size)
            assertEquals("the rho table is not deleted with the conversation", 1, dao.allRho().size)
        } finally {
            db.close()
        }
    }

    @Test
    fun `manifest_cleared_with_all_conversations`() = runBlocking {
        createDatabaseFromExportedSchema(dbName, version = 4) { db ->
            seedConversation(db, CONV_A)
            seedConversation(db, CONV_B)
            seedConversation(db, CONV_OTHER_ACCOUNT, account = OTHER_ACCOUNT)
        }
        val db = openMigrated()
        try {
            val dao = db.contextLedgerDao()
            dao.upsertRho(ContextRhoCalibrationEntity.of("t1", "m1", RhoCalibration()))
            dao.appendManifest(ContextManifestEntity.of(manifest(CONV_A, "a1", 1L)))
            dao.appendManifest(ContextManifestEntity.of(manifest(CONV_B, "b1", 1L)))
            dao.appendManifest(ContextManifestEntity.of(manifest(CONV_OTHER_ACCOUNT, "o1", 1L)))

            // Clearing all conversations and an overwrite import of a backup both go through this entry point.
            db.conversationDao().deleteByAccount(ACCOUNT)

            assertTrue(dao.manifests(CONV_A).isEmpty())
            assertTrue(dao.manifests(CONV_B).isEmpty())
            assertEquals("manifests of other accounts are untouched", 1, dao.manifests(CONV_OTHER_ACCOUNT).size)
            assertEquals("the rho table is not cleared", 1, dao.allRho().size)
        } finally {
            db.close()
        }
    }

    // ── helpers ──────────────────────────────────────────────────────────

    private fun manifest(conversationId: String, requestId: String, createdAt: Long) = ContextManifest(
        requestId = requestId,
        conversationId = conversationId,
        purpose = RequestPurpose.CHAT,
        transport = "openai_chat",
        model = "gpt-4o",
        W = 128_000,
        O = 4_096,
        B = 120_000,
        basis = ContextBasis.ESTIMATED,
        estimatedInput = 1_234,
        segments = emptyList(),
        unansweredMerged = 0,
        reminder = false,
        stopReason = StopReason.STOP,
        createdAt = createdAt,
    )

    private fun seedConversation(db: SupportSQLiteDatabase, id: String, account: String = ACCOUNT) = db.execSQL(
        "INSERT INTO conversations (id, title, hasCustomTitle, providerID, providerKind, modelID, " +
            "useMemory, previewText, estimatedCost, isDraft, draftText, createdAt, updatedAt, " +
            "accountId) " +
            "VALUES ('$id', '\u8001\u4f1a\u8bdd', 0, 'p1', 'OpenAI', 'm1', 1, '', 0.0, 0, '', 0, 0, '$account')",
    )

    private fun seedMessage(db: SupportSQLiteDatabase, id: String, conversationId: String) = db.execSQL(
        "INSERT INTO messages (id, accountId, conversationId, role, text, providerKind, providerName, " +
            "modelName, estimatedCost, state, errorTitle, errorDetail, attachmentsJson, createdAt, " +
            "sortOrder, customRetryWithoutFieldsAvailable) " +
            "VALUES ('$id', '$ACCOUNT', '$conversationId', 'Assistant', '\u5347\u7ea7\u524d\u5c31\u5b58\u5728\u7684\u6d88\u606f', 'OpenAI', 'OpenAI', " +
            "'m1', 0.0, 'Delivered', NULL, NULL, NULL, 0, 0, 0)",
    )

    private fun openMigrated(): OriveoDatabase =
        Room.databaseBuilder(context, OriveoDatabase::class.java, dbName)
            .addMigrations(OriveoDatabase.MIGRATION_4_5)
            .allowMainThreadQueries()
            .build()
            .also { it.openHelper.writableDatabase }

    private fun exportedSchema(version: Int): JSONObject =
        JSONObject(File("schemas/${OriveoDatabase::class.java.canonicalName}/$version.json").readText())
            .getJSONObject("database")

    /** Builds a real database from the exported schema JSON (tables + indices) and writes Room's identity hash. */
    private fun createDatabaseFromExportedSchema(name: String, version: Int, seed: (SupportSQLiteDatabase) -> Unit) {
        val schema = exportedSchema(version)
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
        helper.writableDatabase.use { db ->
            db.setForeignKeyConstraintsEnabled(true)
            seed(db)
        }
        helper.close()
    }

    private class NoOpCallback(version: Int) : SupportSQLiteOpenHelper.Callback(version) {
        override fun onCreate(db: SupportSQLiteDatabase) = Unit
        override fun onUpgrade(db: SupportSQLiteDatabase, oldVersion: Int, newVersion: Int) = Unit
    }

    /** Columns (name / type / NOT NULL / primary key order) + indices (name / uniqueness / columns) + foreign keys. */
    private fun tableShape(db: SupportSQLiteDatabase, table: String): Set<String> {
        val shape = mutableSetOf<String>()
        db.query("PRAGMA table_info(`$table`)").use { c ->
            while (c.moveToNext()) {
                shape += "col:${c.getString(1)}|${c.getString(2)}|notnull=${c.getInt(3)}|pk=${c.getInt(5)}"
            }
        }
        val indexNames = db.query("PRAGMA index_list(`$table`)").use { c ->
            val rows = mutableListOf<Pair<String, Int>>()
            while (c.moveToNext()) rows += c.getString(1) to c.getInt(2)
            rows
        }
        indexNames.forEach { (name, unique) ->
            val columns = db.query("PRAGMA index_xinfo(`$name`)").use { c ->
                val rows = mutableListOf<String>()
                while (c.moveToNext()) if (c.getInt(5) == 1) rows += "${c.getString(2)}:${c.getString(4)}"
                rows
            }
            val label = if (name.startsWith("sqlite_autoindex_")) "pk" else name
            shape += "idx:$label|unique=$unique|${columns.joinToString(",")}"
        }
        db.query("PRAGMA foreign_key_list(`$table`)").use { c ->
            while (c.moveToNext()) {
                shape += "fk:${c.getString(2)}|${c.getString(3)}->${c.getString(4)}|delete=${c.getString(6)}"
            }
        }
        return shape
    }

    private fun deleteDatabaseFiles(file: File) {
        listOf(file, File("${file.path}-wal"), File("${file.path}-shm"), File("${file.path}-journal"))
            .forEach { it.delete() }
    }

    private companion object {
        const val LATEST_VERSION = 5
        const val ACCOUNT = "acct-1"
        const val OTHER_ACCOUNT = "acct-2"
        const val CONV_A = "AAAAAAAA-0000-0000-0000-000000000001"
        const val CONV_B = "BBBBBBBB-0000-0000-0000-000000000002"
        const val CONV_OTHER_ACCOUNT = "CCCCCCCC-0000-0000-0000-000000000003"
        const val MSG_LEGACY = "DDDDDDDD-0000-0000-0000-000000000004"
    }
}
