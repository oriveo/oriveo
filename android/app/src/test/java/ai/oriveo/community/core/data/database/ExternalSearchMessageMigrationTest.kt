package ai.oriveo.community.core.data.database

import android.content.Context
import androidx.room.Room
import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.sqlite.db.SupportSQLiteOpenHelper
import androidx.sqlite.db.framework.FrameworkSQLiteOpenHelperFactory
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
 * Local diagnostic columns for external search: v6 -> v7 adds `searchErrorCardJson`, `searchNotice` and `searchSourcesLineJson`.
 * After upgrading an old database with data, the new columns are nullable, existing rows read null, other fields and rowid are unchanged; the upgraded messages column set matches the exported 7.json;
 * the new columns round-trip through the DAO.
 */
@RunWith(RobolectricTestRunner::class)
class ExternalSearchMessageMigrationTest {

    private val context: Context get() = RuntimeEnvironment.getApplication()
    private val dbName = "external-search-migration.db"

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
    fun v6_upgrades_to_v7_with_nullable_search_columns() = runBlocking {
        assertUpgrade(seed(6), listOf("searchErrorCardJson", "searchNotice", "searchSourcesLineJson"))
    }

    private suspend fun assertUpgrade(rowId: Long, added: List<String>) {
        val db = Room.databaseBuilder(context, OriveoDatabase::class.java, dbName)
            .addMigrations(*OriveoDatabase.allMigrations())
            .allowMainThreadQueries()
            .build()
        try {
            val sql = db.openHelper.writableDatabase
            val columns = mutableMapOf<String, Triple<String, Int, Boolean>>()
            sql.query("PRAGMA table_info(messages)").use { cursor ->
                while (cursor.moveToNext()) {
                    columns[cursor.getString(cursor.getColumnIndexOrThrow("name"))] = Triple(
                        cursor.getString(cursor.getColumnIndexOrThrow("type")),
                        cursor.getInt(cursor.getColumnIndexOrThrow("notnull")),
                        cursor.isNull(cursor.getColumnIndexOrThrow("dflt_value")),
                    )
                }
            }
            added.forEach { name ->
                val column = checkNotNull(columns[name]) { "messages.$name column missing" }
                assertEquals("TEXT", column.first)
                assertEquals("$name is nullable", 0, column.second)
                assertTrue("$name has no default value", column.third)
            }
            // Column set after upgrade = messages in the exported schema 7.json
            assertEquals(schemaMessageColumns(7), columns.keys)

            val legacy = db.messageDao().getById(UID, MSG)!!
            assertNull(legacy.searchErrorCardJson)
            assertNull(legacy.searchNotice)
            assertNull(legacy.searchSourcesLineJson)
            assertEquals("hi", legacy.text)
            assertEquals(0.02, legacy.estimatedCost, 0.0)
            assertEquals("Delivered", legacy.state)
            sql.query("SELECT rowid FROM messages WHERE id = '$MSG'").use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals("Data is not rewritten: rowid unchanged", rowId, cursor.getLong(0))
            }

            val line = """{"searchCount":1,"serviceName":"DeepSeek","sourceCount":3}"""
            db.messageDao().upsert(legacy.copy(searchSourcesLineJson = line, searchNotice = "tools_rejected"))
            val rewritten = db.messageDao().getById(UID, MSG)!!
            assertEquals(line, rewritten.searchSourcesLineJson)
            assertEquals("tools_rejected", rewritten.searchNotice)
        } finally {
            db.close()
        }
    }

    private fun schemaMessageColumns(version: Int): Set<String> {
        val entities = JSONObject(File("schemas/${OriveoDatabase::class.java.canonicalName}/$version.json").readText())
            .getJSONObject("database").getJSONArray("entities")
        for (i in 0 until entities.length()) {
            val entity = entities.getJSONObject(i)
            if (entity.getString("tableName") != "messages") continue
            val fields = entity.getJSONArray("fields")
            return (0 until fields.length()).map { fields.getJSONObject(it).getString("columnName") }.toSet()
        }
        error("messages not in $version.json")
    }

    /** Writes a conversation plus one delivered assistant message on the v[version] exported schema, and returns the message rowid. */
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
                    "previewText, estimatedCost, isDraft, draftText, createdAt, updatedAt, accountId) " +
                    "VALUES ('$CONV', 't', 0, '$PROVIDER', 'OpenAI', 'm', 1, '', 0.02, 0, '', 1, 1, '$UID')",
            )
            db.execSQL(
                "INSERT INTO messages (id, accountId, conversationId, role, text, providerKind, providerName, " +
                    "modelName, estimatedCost, state, sortOrder, customRetryWithoutFieldsAvailable, " +
                    "createdAt) " +
                    "VALUES ('$MSG', '$UID', '$CONV', 'Assistant', 'hi', 'OpenAI', 'OpenAI', 'm', 0.02, 'Delivered', 0, 0, 1000)",
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
        const val PROVIDER = "CCCCCCCC-0000-4000-8000-000000000003"
    }
}
