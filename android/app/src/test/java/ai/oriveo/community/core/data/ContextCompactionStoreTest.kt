package ai.oriveo.community.core.data

import android.content.Context
import androidx.room.Room
import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.sqlite.db.SupportSQLiteOpenHelper
import androidx.sqlite.db.framework.FrameworkSQLiteOpenHelperFactory
import ai.oriveo.community.core.context.CheckpointCoveredMessage
import ai.oriveo.community.core.context.ContextCheckpoint
import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.backup.BackupService
import ai.oriveo.community.core.data.database.OriveoDatabase
import ai.oriveo.community.core.data.entity.MessageEntity
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ContextCheckpointKind
import ai.oriveo.community.core.data.repository.ContextCheckpointRecord
import ai.oriveo.community.core.data.repository.ContextCompactionStore
import ai.oriveo.community.core.model.BackupContextCheckpoint
import ai.oriveo.community.core.model.BackupData
import ai.oriveo.community.core.model.BackupFile
import ai.oriveo.community.core.model.ImportMode
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import java.io.File
import java.util.zip.ZipInputStream
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
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
 * The checkpoint table and the save / list / latestValid / invalidate of ContextCompactionStore.
 * The latestValid / invalidate decisions go through the production functions of core/context ContextCheckpoint; here they are only used to compute the expected digest.
 */
@RunWith(RobolectricTestRunner::class)
class ContextCompactionStoreTest {

    private val context: Context get() = RuntimeEnvironment.getApplication()
    private lateinit var db: OriveoDatabase
    private lateinit var store: ContextCompactionStore

    @Before
    fun setUp() {
        db = Room.inMemoryDatabaseBuilder(context, OriveoDatabase::class.java)
            .allowMainThreadQueries()
            .build()
        seedConversation(db.openHelper.writableDatabase, CONV_A)
        seedConversation(db.openHelper.writableDatabase, CONV_B)
        store = ContextCompactionStore(db.contextCheckpointDao())
        deleteDatabaseFiles(context.getDatabasePath(MIGRATION_DB).also { it.parentFile?.mkdirs() })
    }

    @After
    fun tearDown() {
        db.close()
        deleteDatabaseFiles(context.getDatabasePath(MIGRATION_DB))
    }

    @Test
    fun `migration_creates_checkpoint_table`() = runBlocking {
        createV4Database(MIGRATION_DB) { seedConversation(it, CONV_A) }
        val migrated = Room.databaseBuilder(context, OriveoDatabase::class.java, MIGRATION_DB)
            .addMigrations(*OriveoDatabase.allMigrations())
            .allowMainThreadQueries()
            .build()
        try {
            // Room validates every table when the database opens: a table built by the migration that differs from the entity throws right away.
            assertEquals(
                tableShape(db.openHelper.readableDatabase, "context_checkpoint"),
                tableShape(migrated.openHelper.writableDatabase, "context_checkpoint"),
            )
            val migratedStore = ContextCompactionStore(migrated.contextCheckpointDao())
            migratedStore.save(ACCOUNT, record(CONV_A, "m2", createdAt = 1))
            assertEquals(listOf(checkpointId(CONV_A, "m2")), migratedStore.list(ACCOUNT, CONV_A).map { it.checkpointId })
        } finally {
            migrated.close()
        }
    }

    @Test
    fun `save_and_list_roundtrip`() = runBlocking {
        val full = record(CONV_A, "m2", createdAt = 1_700_000_000_123, cost = 0.0042).copy(
            kind = ContextCheckpointKind.SUMMARY,
            summary = "## Goal\nx",
            language = "zh-Hans",
            userMessageIds = listOf("m0", "m2"),
        )
        val bare = record(CONV_A, "m4", createdAt = 1_700_000_000_456).copy(kind = ContextCheckpointKind.FALLBACK)
        store.save(ACCOUNT, full)
        store.save(ACCOUNT, bare)

        val rows = store.list(ACCOUNT, CONV_A)
        assertEquals(setOf(full, bare), rows.toSet())
        val readBare = rows.single { it.checkpointId == bare.checkpointId }
        assertNull(readBare.summary)
        assertNull(readBare.language)
        assertNull(readBare.cost)
        assertTrue(store.list(OTHER_ACCOUNT, CONV_A).isEmpty())
    }

    @Test
    fun `overwrite_same_checkpoint_id`() = runBlocking {
        store.save(ACCOUNT, record(CONV_A, "m2", createdAt = 1).copy(text = "old"))
        store.save(ACCOUNT, record(CONV_A, "m2", createdAt = 2).copy(text = "new"))

        val rows = store.list(ACCOUNT, CONV_A)
        assertEquals(1, rows.size)
        assertEquals("new", rows.single().text)
        assertEquals(2L, rows.single().createdAt)
    }

    @Test
    fun `trim_keeps_newest_8`() = runBlocking {
        (0 until 10).forEach { i -> store.save(ACCOUNT, record(CONV_A, "m$i", createdAt = 100L + i)) }
        store.save(ACCOUNT, record(CONV_B, "m0", createdAt = 1))

        val kept = store.list(ACCOUNT, CONV_A).map { it.coversTo }.toSet()
        assertEquals((2 until 10).map { "m$it" }.toSet(), kept)
        assertEquals(1, store.list(ACCOUNT, CONV_B).size)
    }

    @Test
    fun `latest_valid_skips_stale`() = runBlocking {
        val history = history(6)
        store.save(ACCOUNT, record(CONV_A, "m1", createdAt = 1, history = history))
        // The digest does not match (the text of m2 was edited).
        val edited = history.toMutableList().also { it[2] = CheckpointCoveredMessage("m2", "changed") }
        store.save(ACCOUNT, record(CONV_A, "m3", createdAt = 2, history = edited))
        // coversTo is not in the history.
        store.save(ACCOUNT, record(CONV_A, "gone", createdAt = 3, history = history))

        assertEquals(checkpointId(CONV_A, "m1"), store.latestValid(ACCOUNT, CONV_A, history)?.checkpointId)
        // Skipped, not deleted.
        assertEquals(3, store.list(ACCOUNT, CONV_A).size)
        assertNull(store.latestValid(ACCOUNT, CONV_B, history))
        assertNull(store.latestValid(OTHER_ACCOUNT, CONV_A, history))
    }

    @Test
    fun `latest_valid_prefers_later_covers_to`() = runBlocking {
        val history = history(6)
        store.save(ACCOUNT, record(CONV_A, "m3", createdAt = 5, history = history))
        store.save(ACCOUNT, record(CONV_A, "m1", createdAt = 9, history = history))

        assertEquals(checkpointId(CONV_A, "m3"), store.latestValid(ACCOUNT, CONV_A, history)?.checkpointId)
    }

    @Test
    fun `invalidate_drops_covering_and_later`() = runBlocking {
        val history = history(6)
        listOf("m1", "m3", "m4").forEachIndexed { i, to ->
            store.save(ACCOUNT, record(CONV_A, to, createdAt = i.toLong(), history = history))
        }
        store.save(ACCOUNT, record(CONV_A, "gone", createdAt = 10, history = history))

        val dropped = store.invalidate(ACCOUNT, CONV_A, history.map { it.id }, setOf("m5", "m3"))

        assertEquals(setOf(checkpointId(CONV_A, "m3"), checkpointId(CONV_A, "m4")), dropped.toSet())
        assertEquals(
            setOf(checkpointId(CONV_A, "m1"), checkpointId(CONV_A, "gone")),
            store.list(ACCOUNT, CONV_A).map { it.checkpointId }.toSet(),
        )
    }

    @Test
    fun `delete_all_emits_changes`() = runBlocking {
        val history = history(6)
        val changes = async(start = CoroutineStart.UNDISPATCHED) { store.changes.take(4).toList() }
        store.save(ACCOUNT, record(CONV_A, "m1", createdAt = 1, history = history))
        store.save(ACCOUNT, record(CONV_A, "m3", createdAt = 2, history = history))
        store.save(ACCOUNT, record(CONV_B, "m2", createdAt = 3, history = history))

        val deleted = store.deleteAll(ACCOUNT, CONV_A)

        assertEquals(setOf(checkpointId(CONV_A, "m1"), checkpointId(CONV_A, "m3")), deleted.toSet())
        assertTrue(store.list(ACCOUNT, CONV_A).isEmpty())
        assertEquals(1, store.list(ACCOUNT, CONV_B).size)
        assertTrue(store.deleteAll(OTHER_ACCOUNT, CONV_B).isEmpty())
        assertEquals(1, store.list(ACCOUNT, CONV_B).size)
        assertEquals(listOf(CONV_A, CONV_A, CONV_B, CONV_A), withTimeout(5_000) { changes.await() })
    }

    @Test
    fun `invalidate_keeps_before_branch`() = runBlocking {
        val history = history(6)
        store.save(ACCOUNT, record(CONV_A, "m1", createdAt = 1, history = history))
        store.save(ACCOUNT, record(CONV_A, "m2", createdAt = 2, history = history))

        val dropped = store.invalidate(ACCOUNT, CONV_A, history.map { it.id }, setOf("m3"))

        assertTrue(dropped.isEmpty())
        assertEquals(2, store.list(ACCOUNT, CONV_A).size)
        assertTrue(store.invalidate(ACCOUNT, CONV_A, history.map { it.id }, setOf("unknown")).isEmpty())
        assertTrue(store.invalidate(ACCOUNT, CONV_A, history.map { it.id }, emptySet()).isEmpty())
        assertEquals(2, store.list(ACCOUNT, CONV_A).size)
    }

    @Test
    fun `edit_resend_invalidates_covering_checkpoints`() = runBlocking {
        val history = history(6)
        history.forEachIndexed { i, msg -> db.messageDao().upsert(messageEntity(msg.id, i)) }
        listOf("m1", "m2", "m3", "m4").forEachIndexed { i, to ->
            store.save(ACCOUNT, record(CONV_A, to, createdAt = i.toLong(), history = history))
        }
        val repository = ConversationRepository(
            db.conversationDao(), db.messageDao(),
            contextCompactionStore = store,
        )

        // Edit-resend: deleting from m3 on invalidates the checkpoints that cover m3 or later
        repository.deleteMessagesStartingAt(CONV_A, "m3")
        assertEquals(
            setOf(checkpointId(CONV_A, "m1"), checkpointId(CONV_A, "m2")),
            store.list(ACCOUNT, CONV_A).map { it.checkpointId }.toSet(),
        )

        // Regenerate: after deleting what follows m1, checkpoints covering m2 are invalidated and checkpoints covering m1 are kept
        repository.deleteMessagesAfter(CONV_A, "m1")
        assertEquals(listOf(checkpointId(CONV_A, "m1")), store.list(ACCOUNT, CONV_A).map { it.checkpointId })
    }

    @Test
    fun `delete_conversation_cascades`() = runBlocking {
        store.save(ACCOUNT, record(CONV_A, "m1", createdAt = 1))
        store.save(ACCOUNT, record(CONV_B, "m1", createdAt = 1))

        db.openHelper.writableDatabase.execSQL(
            "DELETE FROM conversations WHERE id = ? AND accountId = ?",
            arrayOf<Any>(CONV_A, ACCOUNT),
        )

        assertTrue(store.list(ACCOUNT, CONV_A).isEmpty())
        assertEquals(1, store.list(ACCOUNT, CONV_B).size)
    }

    // -- Backup export and import --

    @Test
    fun `backup_roundtrip_includes_checkpoints`() = runBlocking {
        val full = record(CONV_A, "m2", createdAt = 1_700_000_000_123, cost = 0.0042).copy(
            kind = ContextCheckpointKind.SUMMARY,
            summary = "## Goal\nx",
            language = "zh-Hans",
            userMessageIds = listOf("m0", "m2"),
        )
        val bare = record(CONV_A, "m4", createdAt = 1_700_000_000_456)
        val other = record(CONV_B, "m1", createdAt = 1_700_000_000_789)
        listOf(full, bare, other).forEach { store.save(ACCOUNT, it) }
        val service = backupService()

        val exported = service.exportBackup()
        val rows = exportedData(exported)["checkpoints"]!!.jsonArray.map { it.jsonObject }
        assertEquals(3, rows.size)
        val fullRow = rows.single { it["checkpointId"]!!.jsonPrimitive.content == full.checkpointId }
        assertEquals(CONV_A, fullRow["conversationId"]!!.jsonPrimitive.content)
        assertFalse("a backup row must not carry accountId", fullRow.containsKey("accountId"))
        assertEquals(1_700_000_000_123L, fullRow["createdAt"]!!.jsonPrimitive.long)

        // Replace all: local conversations are cleared together with their checkpoints, then written back from the backup.
        service.executeImport(mode = ImportMode.ReplaceAll, bytes = exported)
        assertEquals(setOf(full, bare), store.list(ACCOUNT, CONV_A).toSet())
        assertEquals(listOf(other), store.list(ACCOUNT, CONV_B))

        // Merge: rows of an existing conversation are overwritten by primary key, and rows whose conversation does not exist are dropped.
        val updated = BackupContextCheckpoint.from(bare.copy(text = "new"))
        val orphan = BackupContextCheckpoint.from(record(CONV_MISSING, "m1", createdAt = 1))
        service.executeImport(mode = ImportMode.Merge, bytes = backupJson(BackupData(checkpoints = listOf(updated, orphan))))
        assertEquals("new", store.list(ACCOUNT, CONV_A).single { it.checkpointId == bare.checkpointId }.text)
        assertTrue(db.contextCheckpointDaoRowsFor(CONV_MISSING).isEmpty())

        // Import new only: the conversation is already local, and the row is still written.
        val fresh = record(CONV_B, "m3", createdAt = 1_700_000_001_000)
        service.executeImport(
            mode = ImportMode.ImportNewOnly,
            bytes = backupJson(BackupData(checkpoints = listOf(BackupContextCheckpoint.from(fresh)))),
        )
        assertEquals(setOf(other, fresh), store.list(ACCOUNT, CONV_B).toSet())
    }

    @Test
    fun `legacy_backup_imports`() = runBlocking {
        store.save(ACCOUNT, record(CONV_A, "m2", createdAt = 1))
        val encoded = Json.parseToJsonElement(Json.encodeToString(backupFile(BackupData()))).jsonObject
        val legacyData = JsonObject(encoded["data"]!!.jsonObject.filterKeys { it != "checkpoints" })
        val legacy = JsonObject(encoded + ("data" to legacyData)).toString()
        assertFalse(legacy.contains("checkpoints"))

        val result = backupService().executeImport(mode = ImportMode.ImportNewOnly, bytes = legacy.toByteArray())

        assertEquals(0, result.newConversations)
        assertEquals(1, store.list(ACCOUNT, CONV_A).size)
    }

    private fun messageEntity(id: String, sortOrder: Int) = MessageEntity(
        id = id,
        conversationId = CONV_A,
        role = "User",
        text = "text $sortOrder",
        providerKind = "OpenAI",
        providerName = "OpenAI",
        modelName = "GPT-4o",
        estimatedCost = 0.0,
        state = "Delivered",
        errorTitle = null,
        errorDetail = null,
        attachmentsJson = null,
        createdAt = 1_700_000_000_000L + sortOrder,
        sortOrder = sortOrder,
        accountId = ACCOUNT,
    )

    private fun history(n: Int) = (0 until n).map { CheckpointCoveredMessage("m$it", "text $it") }

    private fun checkpointId(conversationId: String, coversTo: String) =
        ContextCheckpoint.checkpointId(conversationId, coversTo)

    private fun backupService() = BackupService(
        providerDao = db.providerDao(),
        conversationDao = db.conversationDao(),
        messageDao = db.messageDao(),
        folderDao = db.folderDao(),
        skillDao = db.skillDao(),
        noteDao = db.noteDao(),
        noteFolderDao = db.noteFolderDao(),
        json = Json { ignoreUnknownKeys = true; encodeDefaults = true },
        secureKeyStore = mockk(relaxed = true),
        attachmentStore = mockk(relaxed = true),
        preferenceDao = db.preferenceDao(),
        metadataRefresh = {},
        contextCompactionStore = store,
    )

    private fun backupFile(data: BackupData) = BackupFile(
        version = BackupService.CURRENT_VERSION,
        createdAt = "2026-10-15T00:00:00Z",
        appVersion = "1.0.0",
        platform = "Web",
        checksum = "",
        containsKeys = false,
        data = data,
    )

    private fun backupJson(data: BackupData): ByteArray =
        Json { encodeDefaults = true }.encodeToString(backupFile(data)).toByteArray()

    private fun exportedData(zip: ByteArray): JsonObject {
        ZipInputStream(zip.inputStream()).use { zis ->
            var entry = zis.nextEntry
            while (entry != null) {
                if (entry.name == "data.json") {
                    return Json.parseToJsonElement(String(zis.readBytes(), Charsets.UTF_8)).jsonObject["data"]!!.jsonObject
                }
                entry = zis.nextEntry
            }
        }
        error("data.json missing")
    }

    private suspend fun OriveoDatabase.contextCheckpointDaoRowsFor(conversationId: String) =
        contextCheckpointDao().list(ACCOUNT, conversationId)

    private fun record(
        conversationId: String,
        coversTo: String,
        createdAt: Long,
        history: List<CheckpointCoveredMessage> = history(10),
        cost: Double? = null,
    ): ContextCheckpointRecord {
        val index = history.indexOfFirst { it.id == coversTo }
        val digest = if (index >= 0) ContextCheckpoint.coversDigest(history.subList(0, index + 1)) else "deadbeef"
        return ContextCheckpointRecord(
            conversationId = conversationId,
            checkpointId = checkpointId(conversationId, coversTo),
            kind = ContextCheckpointKind.FALLBACK,
            coversFrom = "m0",
            coversTo = coversTo,
            coversDigest = digest,
            messagesCovered = index + 1,
            userMessageIds = listOf("m0"),
            text = "<oriveo-context-checkpoint/>",
            summary = null,
            language = null,
            model = "gpt-test",
            packerVersion = ContextCheckpoint.PACKER_VERSION,
            createdAt = createdAt,
            cost = cost,
        )
    }

    private fun seedConversation(db: SupportSQLiteDatabase, id: String) = db.execSQL(
        "INSERT INTO conversations (id, title, hasCustomTitle, providerID, providerKind, modelID, " +
            "useMemory, previewText, estimatedCost, isDraft, draftText, createdAt, updatedAt, " +
            "accountId) " +
            "VALUES ('$id', 'c', 0, 'p1', 'OpenAI', 'm1', 1, '', 0.0, 0, '', 0, 0, '$ACCOUNT')",
    )

    /** Builds a real v4 database from the exported `4.json` (tables + indices + identity hash). */
    private fun createV4Database(name: String, seed: (SupportSQLiteDatabase) -> Unit) {
        val schema = JSONObject(File("schemas/${OriveoDatabase::class.java.canonicalName}/4.json").readText())
            .getJSONObject("database")
        val helper = FrameworkSQLiteOpenHelperFactory().create(
            SupportSQLiteOpenHelper.Configuration.builder(context)
                .name(name)
                .callback(
                    object : SupportSQLiteOpenHelper.Callback(4) {
                        override fun onCreate(db: SupportSQLiteDatabase) {
                            val entities = schema.getJSONArray("entities")
                            for (index in 0 until entities.length()) {
                                val entity = entities.getJSONObject(index)
                                val table = entity.getString("tableName")
                                db.execSQL(entity.getString("createSql").replace("\${TABLE_NAME}", table))
                                val indices = entity.optJSONArray("indices") ?: continue
                                for (i in 0 until indices.length()) {
                                    db.execSQL(
                                        indices.getJSONObject(i).getString("createSql").replace("\${TABLE_NAME}", table),
                                    )
                                }
                            }
                            db.execSQL("CREATE TABLE IF NOT EXISTS room_master_table (id INTEGER PRIMARY KEY, identity_hash TEXT)")
                            db.execSQL(
                                "INSERT OR REPLACE INTO room_master_table (id, identity_hash) " +
                                    "VALUES(42, '${schema.getString("identityHash")}')",
                            )
                        }

                        override fun onUpgrade(db: SupportSQLiteDatabase, oldVersion: Int, newVersion: Int) = Unit
                    },
                )
                .build(),
        )
        helper.writableDatabase.use(seed)
        helper.close()
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
        assertTrue("$table does not exist", shape.isNotEmpty())
        return shape
    }

    private fun deleteDatabaseFiles(file: File) {
        listOf(file, File("${file.path}-wal"), File("${file.path}-shm"), File("${file.path}-journal"))
            .forEach { it.delete() }
    }

    private companion object {
        const val ACCOUNT = LOCAL_PARTITION_ID
        const val OTHER_ACCOUNT = "acct-2"
        const val CONV_A = "AAAAAAAA-0000-0000-0000-000000000001"
        const val CONV_B = "BBBBBBBB-0000-0000-0000-000000000002"
        const val CONV_MISSING = "CCCCCCCC-0000-0000-0000-000000000003"
        const val MIGRATION_DB = "migration-v4-to-v5.db"
    }
}
