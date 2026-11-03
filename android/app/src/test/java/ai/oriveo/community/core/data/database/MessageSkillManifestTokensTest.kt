package ai.oriveo.community.core.data.database

import android.content.Context
import androidx.room.Room
import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.sqlite.db.SupportSQLiteOpenHelper
import androidx.sqlite.db.framework.FrameworkSQLiteOpenHelperFactory
import ai.oriveo.community.core.data.EntityMapper.toDomain
import ai.oriveo.community.core.data.EntityMapper.toEntity
import ai.oriveo.community.core.sync.SyncAdapter
import ai.oriveo.community.core.sync.SyncManager
import java.io.File
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * Local-only messages.skillManifestTokens (skill_manifest_cost.v1, v10): the 9 -> 10 migration adds a nullable column
 * that old rows read as null; upsert from a domain-rebuilt entity and remote merge keep the local value; the
 * Firestore message map never carries it.
 */
@RunWith(RobolectricTestRunner::class)
class MessageSkillManifestTokensTest {

    private val context: Context get() = RuntimeEnvironment.getApplication()
    private val dbName = "skill-manifest-tokens.db"

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
    fun v54_upgrades_to_v55_with_nullable_column_and_null_legacy_rows() = runBlocking {
        val rowId = seed(9)
        withDatabase { db ->
            val sql = db.openHelper.writableDatabase
            var found = false
            sql.query("PRAGMA table_info(messages)").use { cursor ->
                while (cursor.moveToNext()) {
                    if (cursor.getString(cursor.getColumnIndexOrThrow("name")) != "skillManifestTokens") continue
                    found = true
                    assertEquals("INTEGER", cursor.getString(cursor.getColumnIndexOrThrow("type")))
                    assertEquals("nullable", 0, cursor.getInt(cursor.getColumnIndexOrThrow("notnull")))
                    assertTrue("no default", cursor.isNull(cursor.getColumnIndexOrThrow("dflt_value")))
                }
            }
            assertTrue("messages.skillManifestTokens missing", found)
            val legacy = db.messageDao().getById(UID, MSG)!!
            assertNull(legacy.skillManifestTokens)
            assertEquals("hi", legacy.text)
            sql.query("SELECT rowid FROM messages WHERE id = '$MSG'").use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals("no data rewrite: rowid unchanged", rowId, cursor.getLong(0))
            }

            assertEquals(1, db.messageDao().updateSkillManifestTokens(UID, MSG, 715))
            assertEquals(715, db.messageDao().getById(UID, MSG)!!.skillManifestTokens)
        }
    }

    @Test
    fun upsert_of_domain_rebuilt_entity_keeps_local_value() = runBlocking {
        seed(9)
        withDatabase { db ->
            val dao = db.messageDao()
            dao.updateSkillManifestTokens(UID, MSG, 446)
            val stored = dao.getById(UID, MSG)!!
            val rebuilt = stored.toDomain().copy(text = "edited").toEntity(UID, CONV, stored.sortOrder)
            assertNull("domain model does not carry the column", rebuilt.skillManifestTokens)

            dao.upsert(rebuilt)
            val afterUpsert = dao.getById(UID, MSG)!!
            assertEquals("edited", afterUpsert.text)
            assertEquals(446, afterUpsert.skillManifestTokens)

            dao.upsertAll(listOf(rebuilt.copy(text = "again")))
            assertEquals(446, dao.getById(UID, MSG)!!.skillManifestTokens)

            dao.update(rebuilt.copy(text = "third"))
            assertEquals(446, dao.getById(UID, MSG)!!.skillManifestTokens)

            dao.upsert(rebuilt.copy(skillManifestTokens = 713))
            assertEquals("an explicit value still wins", 713, dao.getById(UID, MSG)!!.skillManifestTokens)
        }
    }

    @Test
    fun remote_merge_keeps_local_value_and_is_quiescent() = runBlocking {
        seed(9)
        withDatabase { db ->
            val dao = db.messageDao()
            dao.updateSkillManifestTokens(UID, MSG, 120)
            val existing = dao.getById(UID, MSG)!!
            val remote = existing.toDomain().copy(text = "remote edit")

            val merged = SyncManager.remoteMessageEntityToWrite(existing, remote, UID, CONV, existing.sortOrder)
            assertNotNull(merged)
            assertEquals("remote edit", merged!!.text)
            assertEquals(120, merged.skillManifestTokens)

            val again = SyncManager.remoteMessageEntityToWrite(merged, remote, UID, CONV, merged.sortOrder)
            assertNull("same remote document merges to zero writes", again)

            val fresh = SyncManager.remoteMessageEntityToWrite(null, remote.copy(id = MSG_NEW), UID, CONV, 1)
            assertNull("a new remote row has no local estimate", fresh!!.skillManifestTokens)
        }
    }

    @Test
    fun message_to_firestore_never_carries_the_column() = runBlocking {
        seed(9)
        withDatabase { db ->
            db.messageDao().updateSkillManifestTokens(UID, MSG, 95)
            val message = db.messageDao().getById(UID, MSG)!!.toDomain()
            val data = SyncAdapter().messageToFirestore(message)
            assertFalse(data.containsKey("skillManifestTokens"))
            assertFalse(data.values.any { it == 95 || it == 95L })
        }
    }

    @Test
    fun range_query_skips_rows_outside_the_window_and_rows_without_a_value() = runBlocking {
        seed(9)
        withDatabase { db ->
            val dao = db.messageDao()
            dao.updateSkillManifestTokens(UID, MSG, 300) // createdAt 1000
            val sql = db.openHelper.writableDatabase
            insertMessage(sql, "BBBBBBBB-0000-4000-8000-000000000010", UID, "Assistant", 2000, 40)
            insertMessage(sql, "BBBBBBBB-0000-4000-8000-000000000011", UID, "Assistant", 3000, 7) // end is exclusive
            insertMessage(sql, "BBBBBBBB-0000-4000-8000-000000000012", UID, "Assistant", 999, 5) // before start
            insertMessage(sql, "BBBBBBBB-0000-4000-8000-000000000013", UID, "Assistant", 1500, null) // no value
            insertMessage(sql, "BBBBBBBB-0000-4000-8000-000000000014", UID, "User", 1500, 9) // not an assistant row
            sql.execSQL(
                "INSERT INTO conversations (id, title, hasCustomTitle, providerID, providerKind, modelID, useMemory, " +
                    "previewText, estimatedCost, isDraft, draftText, createdAt, updatedAt, accountId, " +
                    "firestoreUpdatedAt, firestoreMetadataUpdatedAt, remoteMessageCount, isConflictCopy) " +
                    "VALUES ('$CONV', 't', 0, '$PROVIDER', 'OpenAI', 'm', 1, '', 0.0, 0, '', 1, 1, 'user-2', 0, 0, 1, 0)",
            )
            insertMessage(sql, "BBBBBBBB-0000-4000-8000-000000000015", "user-2", "Assistant", 1500, 11) // other account

            assertEquals(listOf(40, 300), dao.skillManifestTokensBetween(UID, 1000, 3000).sorted())
            assertEquals(listOf(40), dao.skillManifestTokensBetween(UID, 1001, 3000))
            assertEquals(emptyList<Int>(), dao.skillManifestTokensBetween(UID, 4000, 5000))
        }
    }

    @Test
    fun manifest_row_excludes_deleted_conversation() = runBlocking {
        seed(9)
        withDatabase { db ->
            val dao = db.messageDao()
            dao.updateSkillManifestTokens(UID, MSG, 300)
            val sql = db.openHelper.writableDatabase
            sql.execSQL(
                "INSERT INTO conversations (id, title, hasCustomTitle, providerID, providerKind, modelID, useMemory, " +
                    "previewText, estimatedCost, isDraft, draftText, createdAt, updatedAt, accountId, " +
                    "firestoreUpdatedAt, firestoreMetadataUpdatedAt, remoteMessageCount, isConflictCopy, deletedAt) " +
                    "VALUES ('$CONV_DELETED', 't', 0, '$PROVIDER', 'OpenAI', 'm', 1, '', 0.0, 0, '', 1, 1, '$UID', 0, 0, 1, 0, 2000)",
            )
            sql.execSQL(
                "INSERT INTO messages (id, accountId, conversationId, role, text, providerKind, providerName, " +
                    "modelName, estimatedCost, state, sortOrder, customRetryWithoutFieldsAvailable, " +
                    "libraryResearchEnabled, createdAt, remoteConfirmedAt, skillManifestTokens) " +
                    "VALUES ('BBBBBBBB-0000-4000-8000-000000000020', '$UID', '$CONV_DELETED', 'Assistant', 'x', 'OpenAI', " +
                    "'OpenAI', 'm', 0.0, 'Delivered', 0, 0, 0, 1500, 5, 77)",
            )

            assertEquals(listOf(300), dao.skillManifestTokensBetween(UID, 0, 3000))
        }
    }

    private fun insertMessage(db: SupportSQLiteDatabase, id: String, account: String, role: String, createdAt: Long, tokens: Int?) {
        db.execSQL(
            "INSERT INTO messages (id, accountId, conversationId, role, text, providerKind, providerName, " +
                "modelName, estimatedCost, state, sortOrder, customRetryWithoutFieldsAvailable, " +
                "libraryResearchEnabled, createdAt, remoteConfirmedAt, skillManifestTokens) " +
                "VALUES ('$id', '$account', '$CONV', '$role', 'x', 'OpenAI', 'OpenAI', 'm', 0.0, 'Delivered', ${id.takeLast(2).toInt()}, 0, 0, " +
                "$createdAt, 5, ${tokens ?: "NULL"})",
        )
    }

    private suspend fun withDatabase(block: suspend (OriveoDatabase) -> Unit) {
        val db = Room.databaseBuilder(context, OriveoDatabase::class.java, dbName)
            .addMigrations(*OriveoDatabase.allMigrations(null))
            .allowMainThreadQueries()
            .build()
        try {
            block(db)
        } finally {
            db.close()
        }
    }

    /** Writes one conversation and one delivered assistant message on the v[version] exported schema; returns rowid. */
    private fun seed(version: Int): Long {
        var rowId = -1L
        val schema = JSONObject(
            File("schemas/${OriveoDatabase::class.java.canonicalName}/$version.json").readText(),
        ).getJSONObject("database")
        val identityHash = schema.getString("identityHash")
        val helper = FrameworkSQLiteOpenHelperFactory().create(
            SupportSQLiteOpenHelper.Configuration.builder(context)
                .name(dbName)
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
                                    db.execSQL(indices.getJSONObject(i).getString("createSql").replace("\${TABLE_NAME}", table))
                                }
                            }
                            db.execSQL("CREATE TABLE IF NOT EXISTS room_master_table (id INTEGER PRIMARY KEY, identity_hash TEXT)")
                            db.execSQL("INSERT OR REPLACE INTO room_master_table (id, identity_hash) VALUES(42, '$identityHash')")
                        }

                        override fun onUpgrade(db: SupportSQLiteDatabase, oldVersion: Int, newVersion: Int) = Unit
                    },
                )
                .build(),
        )
        helper.writableDatabase.use { db ->
            db.execSQL(
                "INSERT INTO conversations (id, title, hasCustomTitle, providerID, providerKind, modelID, useMemory, " +
                    "previewText, estimatedCost, isDraft, draftText, createdAt, updatedAt, accountId, " +
                    "firestoreUpdatedAt, firestoreMetadataUpdatedAt, remoteMessageCount, isConflictCopy) " +
                    "VALUES ('$CONV', 't', 0, '$PROVIDER', 'OpenAI', 'm', 1, '', 0.02, 0, '', 1, 1, '$UID', 0, 0, 1, 0)",
            )
            db.execSQL(
                "INSERT INTO messages (id, accountId, conversationId, role, text, providerKind, providerName, " +
                    "modelName, estimatedCost, state, sortOrder, customRetryWithoutFieldsAvailable, " +
                    "libraryResearchEnabled, createdAt, remoteConfirmedAt) " +
                    "VALUES ('$MSG', '$UID', '$CONV', 'Assistant', 'hi', 'OpenAI', 'OpenAI', 'm', 0.02, 'Delivered', 0, 0, 0, 1000, 5)",
            )
            db.query("SELECT rowid FROM messages WHERE id = '$MSG'").use { cursor ->
                cursor.moveToFirst()
                rowId = cursor.getLong(0)
            }
        }
        helper.close()
        return rowId
    }

    private fun deleteDatabaseFiles(file: File) {
        listOf(file, File("${file.path}-wal"), File("${file.path}-shm"), File("${file.path}-journal"))
            .forEach { it.delete() }
    }

    private companion object {
        const val UID = "user-1"
        const val CONV = "AAAAAAAA-0000-4000-8000-000000000001"
        const val MSG = "BBBBBBBB-0000-4000-8000-000000000002"
        const val MSG_NEW = "BBBBBBBB-0000-4000-8000-000000000003"
        const val CONV_DELETED = "AAAAAAAA-0000-4000-8000-000000000009"
        const val PROVIDER = "CCCCCCCC-0000-4000-8000-000000000003"
    }
}
