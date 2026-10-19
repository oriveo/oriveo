package ai.oriveo.community.core.data.database

import android.content.Context
import androidx.room.Room
import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.sqlite.db.SupportSQLiteOpenHelper
import androidx.sqlite.db.framework.FrameworkSQLiteOpenHelperFactory
import java.io.File
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * A real v3 to v4 migration: [OriveoDatabase.MIGRATION_3_4] adds the nullable relay columns to `providers`
 * (address source, setup field values, relay key list) and must keep the existing rows readable.
 */
@RunWith(RobolectricTestRunner::class)
class ProviderRelayColumnsMigrationTest {

    private val context: Context get() = RuntimeEnvironment.getApplication()
    private val dbName = "migration-v3-to-v4.db"

    @Before
    fun setUp() {
        context.getDatabasePath(dbName).let { file ->
            file.parentFile?.mkdirs()
            file.delete()
        }
    }

    @After
    fun tearDown() {
        context.getDatabasePath(dbName).delete()
    }

    @Test
    fun `migration adds the relay columns and keeps existing providers`() {
        createV3Database { db ->
            db.execSQL(
                "INSERT INTO providers (id, kind, status, lastCheckedAt, apiKeyPreview, lastError, baseUrlText, " +
                    "customName, modelsJson, catalogModelsJson, updatedAt, accountId, authMode) " +
                    "VALUES ('p1', 'OpenAI', '{}', NULL, 'sk-...abcd', NULL, NULL, NULL, '[]', '[]', 0, " +
                    "'$LOCAL_PARTITION_ID', 'apiKey')",
            )
        }

        val db = Room.databaseBuilder(context, OriveoDatabase::class.java, dbName)
            .addMigrations(OriveoDatabase.MIGRATION_3_4, OriveoDatabase.MIGRATION_4_5)
            .allowMainThreadQueries()
            .build()
        try {
            // Opening runs the migration and Room's schema validation against 4.json.
            val sqlite = db.openHelper.writableDatabase
            val columns = sqlite.query("PRAGMA table_info(`providers`)").use { cursor ->
                val nameIndex = cursor.getColumnIndexOrThrow("name")
                generateSequence { if (cursor.moveToNext()) cursor.getString(nameIndex) else null }.toList()
            }
            assertEquals(true, columns.containsAll(listOf("endpointSource", "setupValuesJson", "relayKeysJson")))
            sqlite.query("SELECT id, endpointSource, setupValuesJson, relayKeysJson FROM providers").use { cursor ->
                assertEquals(true, cursor.moveToFirst())
                assertEquals("p1", cursor.getString(0))
                assertNull(cursor.getString(1))
                assertNull(cursor.getString(2))
                assertNull(cursor.getString(3))
            }
        } finally {
            db.close()
        }
    }

    /** Builds a real v3 database from the exported `3.json` and writes Room's identity hash. */
    private fun createV3Database(seed: (SupportSQLiteDatabase) -> Unit) {
        val schema = JSONObject(File("schemas/${OriveoDatabase::class.java.canonicalName}/3.json").readText())
            .getJSONObject("database")
        val identityHash = schema.getString("identityHash")
        val helper = FrameworkSQLiteOpenHelperFactory().create(
            SupportSQLiteOpenHelper.Configuration.builder(context)
                .name(dbName)
                .callback(
                    object : SupportSQLiteOpenHelper.Callback(3) {
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
                            db.execSQL("CREATE TABLE IF NOT EXISTS room_master_table (id INTEGER PRIMARY KEY, identity_hash TEXT)")
                            db.execSQL("INSERT OR REPLACE INTO room_master_table (id, identity_hash) VALUES(42, '$identityHash')")
                        }

                        override fun onUpgrade(db: SupportSQLiteDatabase, oldVersion: Int, newVersion: Int) = Unit
                    },
                )
                .build(),
        )
        helper.writableDatabase.use { db -> seed(db) }
        helper.close()
    }
}
