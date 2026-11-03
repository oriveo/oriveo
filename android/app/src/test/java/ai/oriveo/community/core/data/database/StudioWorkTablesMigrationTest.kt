package ai.oriveo.community.core.data.database

import android.content.Context
import androidx.room.Room
import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.sqlite.db.SupportSQLiteOpenHelper
import androidx.sqlite.db.framework.FrameworkSQLiteOpenHelperFactory
import java.io.File
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
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
 * Studio work tables (studio_data_model.v1 localTables, v11): the 10 -> 11 migration only creates the four empty
 * tables and their indexes, the columns match the shared fixture, an upgraded database is structurally identical
 * to a fresh install from 11.json, and the orphan-sweep reference read unions versions and round refs.
 */
@RunWith(RobolectricTestRunner::class)
class StudioWorkTablesMigrationTest {

    private val context: Context get() = RuntimeEnvironment.getApplication()
    private val dbName = "studio-work-tables.db"
    private val freshDbName = "studio-work-tables-fresh.db"

    private val contracts: Path by lazy {
        val shared = String(charArrayOf(0x5171.toChar(), 0x4eab.toChar()))
        generateSequence(Paths.get("").toAbsolutePath().normalize()) { it.parent }
            .take(8)
            .map { it.resolve("$shared/studio-contracts") }
            .firstOrNull { Files.exists(it.resolve("studio_data_model.v1.json")) }
            ?: error("studio_data_model.v1.json not found")
    }

    private val dataModel: JSONObject by lazy {
        JSONObject(contracts.resolve("studio_data_model.v1.json").toFile().readText())
    }

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
    fun v55_upgrades_to_v56_with_empty_studio_tables() = runBlocking {
        createFromSchema(dbName, 10, seedLegacyRows = true)
        withDatabase { db ->
            val sql = db.openHelper.writableDatabase
            assertEquals(11, sql.version)
            STUDIO_TABLES.forEach { table ->
                assertTrue("$table missing after migration", tableExists(sql, table))
                assertEquals("$table must start empty", 0L, count(sql, table))
            }
            assertEquals("legacy message survives", "hi", db.messageDao().getById(UID, MSG)!!.text)

            val indexes = STUDIO_TABLES.flatMap { table -> namedIndexes(sql, table) }.toSet()
            assertEquals(EXPECTED_INDEXES, indexes)
            assertEquals(listOf("id"), primaryKey(sql, "studio_works"))
            assertEquals(listOf("id"), primaryKey(sql, "studio_rounds"))
            assertEquals(listOf("id"), primaryKey(sql, "studio_versions"))
            assertEquals(listOf("roundId", "order"), primaryKey(sql, "studio_round_refs"))
        }
    }

    @Test
    fun studio_columns_match_fixture_localTables() = runBlocking {
        createFromSchema(dbName, 10, seedLegacyRows = true)
        withDatabase { db ->
            val sql = db.openHelper.writableDatabase
            val localTables = dataModel.getJSONObject("localTables")
            assertEquals(STUDIO_TABLES.toSet(), localTables.keys().asSequence().toSet())
            STUDIO_TABLES.forEach { table ->
                val fixtureColumns = localTables.getJSONArray(table).let { array ->
                    (0 until array.length()).map { array.getString(it) }.toSet()
                }
                val columns = columnInfo(sql, table)
                assertEquals("$table columns", fixtureColumns, columns.map { it.name }.toSet())
                val createSql = createSql(sql, table)
                columns.forEach { column ->
                    assertEquals("$table.${column.name} type", expectedType(column.name), column.type)
                    assertEquals(
                        "$table.${column.name} nullability",
                        column.name !in NULLABLE_COLUMNS,
                        column.notNull,
                    )
                    assertTrue("$table.${column.name} must have no default", column.defaultValue == null)
                    val nocase = Regex("`${column.name}` TEXT( NOT NULL)? COLLATE NOCASE").containsMatchIn(createSql)
                    assertEquals("$table.${column.name} NOCASE", column.name in NOCASE_COLUMNS, nocase)
                }
            }
            assertTrue(
                "accountPartition only lives on studio_works",
                STUDIO_TABLES.filter { it != "studio_works" }
                    .none { table -> columnInfo(sql, table).any { it.name == "accountPartition" } },
            )
        }
    }

    @Test
    fun migrated_studio_tables_match_fresh_install() = runBlocking {
        assertTrue("11.json must be exported", schemaFile(11).exists())
        createFromSchema(dbName, 10, seedLegacyRows = true)
        createFromSchema(freshDbName, 11, seedLegacyRows = false)
        val fresh = FrameworkSQLiteOpenHelperFactory().create(
            SupportSQLiteOpenHelper.Configuration.builder(context)
                .name(freshDbName)
                .callback(NoOpCallback(11))
                .build(),
        )
        try {
            withDatabase { db ->
                val migrated = db.openHelper.readableDatabase
                val freshDb = fresh.readableDatabase
                STUDIO_TABLES.forEach { table ->
                    val freshShape = tableShape(freshDb, table)
                    assertTrue("11.json must contain $table", freshShape.isNotEmpty())
                    assertEquals("$table shape", freshShape, tableShape(migrated, table))
                    assertEquals(
                        "$table hand-written SQL must equal the 11.json createSql",
                        masterSql(freshDb, table),
                        masterSql(migrated, table),
                    )
                }
            }
        } finally {
            fresh.close()
        }
    }

    @Test
    fun referencedAssetIds_unionsVersionsAndRefs() = runBlocking {
        createFromSchema(dbName, 10, seedLegacyRows = true)
        val case = dataModel.getJSONObject("orphanSweep").getJSONObject("case")
        val versions = case.getJSONArray("studioVersions").let { a -> (0 until a.length()).map { a.getString(it) } }
        val refs = case.getJSONArray("studioRefs").let { a -> (0 until a.length()).map { a.getString(it) } }
        assertEquals(3, versions.size)
        assertTrue("fixture must carry a ref-only asset", refs.any { it !in versions })
        withDatabase { db ->
            val sql = db.openHelper.writableDatabase
            versions.forEachIndexed { i, assetId ->
                val kept = if (i == 2) 0 else 1
                sql.execSQL(
                    "INSERT INTO studio_versions (id, roundId, workId, parentVersionId, assetId, width, height, mime, " +
                        "kept, createdAt) VALUES ('EEEEEEEE-0000-4000-8000-00000000000$i', '$ROUND', '$WORK', NULL, " +
                        "'$assetId', 1024, 1024, 'image/png', $kept, ${1000 + i})",
                )
            }
            refs.forEachIndexed { i, assetId ->
                sql.execSQL(
                    "INSERT INTO studio_round_refs (roundId, `order`, assetId, role) " +
                        "VALUES ('$ROUND', $i, '$assetId', 'reference')",
                )
            }

            assertEquals((versions + refs).toSet(), db.studioWorkDao().referencedAssetIds().toSet())
        }
    }

    // NOCASE columns must not fold non-UUID keys that differ only by case: both files exist on a case-sensitive disk.
    @Test
    fun referencedAssetIds_keepsCaseVariantsOfNonUuidKeys() = runBlocking {
        createFromSchema(dbName, 10, seedLegacyRows = true)
        withDatabase { db ->
            val sql = db.openHelper.writableDatabase
            sql.execSQL(
                "INSERT INTO studio_versions (id, roundId, workId, parentVersionId, assetId, width, height, mime, " +
                    "kept, createdAt) VALUES ('EEEEEEEE-0000-4000-8000-000000000009', '$ROUND', '$WORK', NULL, " +
                    "'asset-a', 1024, 1024, 'image/png', 1, 1000)",
            )
            sql.execSQL(
                "INSERT INTO studio_round_refs (roundId, `order`, assetId, role) VALUES ('$ROUND', 0, 'ASSET-A', 'subject')",
            )

            assertEquals(setOf("asset-a", "ASSET-A"), db.studioWorkDao().referencedAssetIds().toSet())
        }
    }

    private suspend fun withDatabase(block: suspend (OriveoDatabase) -> Unit) {
        val db = Room.databaseBuilder(context, OriveoDatabase::class.java, dbName)
            .addMigrations(*OriveoDatabase.allMigrations())
            .allowMainThreadQueries()
            .build()
        try {
            block(db)
        } finally {
            db.close()
        }
    }

    private fun schemaFile(version: Int): File =
        File("schemas/${OriveoDatabase::class.java.canonicalName}/$version.json")

    /** Builds [name] from the exported v[version] schema; optionally writes one conversation and one message. */
    private fun createFromSchema(name: String, version: Int, seedLegacyRows: Boolean) {
        val schema = JSONObject(schemaFile(version).readText()).getJSONObject("database")
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
        if (seedLegacyRows) {
            helper.writableDatabase.let { db ->
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
            }
        } else {
            helper.writableDatabase
        }
        helper.close()
    }

    private class NoOpCallback(version: Int) : SupportSQLiteOpenHelper.Callback(version) {
        override fun onCreate(db: SupportSQLiteDatabase) = Unit
        override fun onUpgrade(db: SupportSQLiteDatabase, oldVersion: Int, newVersion: Int) = Unit
    }

    private data class Column(val name: String, val type: String, val notNull: Boolean, val defaultValue: String?, val pk: Int)

    private fun columnInfo(db: SupportSQLiteDatabase, table: String): List<Column> =
        db.query("PRAGMA table_info(`$table`)").use { c ->
            val rows = mutableListOf<Column>()
            while (c.moveToNext()) {
                rows += Column(
                    name = c.getString(c.getColumnIndexOrThrow("name")),
                    type = c.getString(c.getColumnIndexOrThrow("type")),
                    notNull = c.getInt(c.getColumnIndexOrThrow("notnull")) == 1,
                    defaultValue = c.getColumnIndexOrThrow("dflt_value").let { if (c.isNull(it)) null else c.getString(it) },
                    pk = c.getInt(c.getColumnIndexOrThrow("pk")),
                )
            }
            rows
        }

    private fun primaryKey(db: SupportSQLiteDatabase, table: String): List<String> =
        columnInfo(db, table).filter { it.pk > 0 }.sortedBy { it.pk }.map { it.name }

    private fun tableExists(db: SupportSQLiteDatabase, table: String): Boolean =
        db.query("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?", arrayOf(table)).use { c ->
            c.moveToFirst() && c.getLong(0) == 1L
        }

    private fun count(db: SupportSQLiteDatabase, table: String): Long =
        db.query("SELECT COUNT(*) FROM `$table`").use { c ->
            c.moveToFirst()
            c.getLong(0)
        }

    private fun createSql(db: SupportSQLiteDatabase, table: String): String =
        db.query("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", arrayOf(table)).use { c ->
            assertTrue("$table missing", c.moveToFirst())
            c.getString(0)
        }

    /** Table and index DDL as stored by SQLite, sorted by object name. */
    private fun masterSql(db: SupportSQLiteDatabase, table: String): List<String> =
        db.query(
            "SELECT name, sql FROM sqlite_master WHERE tbl_name = ? AND sql IS NOT NULL ORDER BY name",
            arrayOf(table),
        ).use { c ->
            val rows = mutableListOf<String>()
            while (c.moveToNext()) rows += "${c.getString(0)}:${c.getString(1)}"
            rows
        }

    /** Non-autoindex indexes as `name|unique=N|col,col`. */
    private fun namedIndexes(db: SupportSQLiteDatabase, table: String): List<String> {
        val names = db.query("PRAGMA index_list(`$table`)").use { c ->
            val rows = mutableListOf<Pair<String, Int>>()
            while (c.moveToNext()) rows += c.getString(1) to c.getInt(2)
            rows
        }
        return names.filterNot { it.first.startsWith("sqlite_autoindex_") }.map { (name, unique) ->
            "$name|unique=$unique|${indexColumns(db, name).joinToString(",") { it.substringBefore(':') }}"
        }
    }

    private fun indexColumns(db: SupportSQLiteDatabase, index: String): List<String> =
        db.query("PRAGMA index_xinfo(`$index`)").use { c ->
            val rows = mutableListOf<String>()
            while (c.moveToNext()) if (c.getInt(5) == 1) rows += "${c.getString(2)}:${c.getString(4)}"
            rows
        }

    /** Full structural fingerprint: columns, primary key order, indexes with collations, foreign keys. */
    private fun tableShape(db: SupportSQLiteDatabase, table: String): Set<String> {
        val shape = mutableSetOf<String>()
        columnInfo(db, table).forEach { shape += "col:${it.name}|${it.type}|notnull=${it.notNull}|pk=${it.pk}|dflt=${it.defaultValue}" }
        db.query("PRAGMA index_list(`$table`)").use { c ->
            val rows = mutableListOf<Pair<String, Int>>()
            while (c.moveToNext()) rows += c.getString(1) to c.getInt(2)
            rows
        }.forEach { (name, unique) ->
            val label = if (name.startsWith("sqlite_autoindex_")) "pk" else name
            shape += "idx:$label|unique=$unique|${indexColumns(db, name).joinToString(",")}"
        }
        db.query("PRAGMA foreign_key_list(`$table`)").use { c ->
            while (c.moveToNext()) shape += "fk:${c.getString(2)}|${c.getString(3)}->${c.getString(4)}"
        }
        return shape
    }

    private fun expectedType(column: String): String = when (column) {
        in INTEGER_COLUMNS -> "INTEGER"
        in REAL_COLUMNS -> "REAL"
        else -> "TEXT"
    }

    private fun deleteDatabaseFiles(file: File) {
        listOf(file, File("${file.path}-wal"), File("${file.path}-shm"), File("${file.path}-journal"))
            .forEach { it.delete() }
    }

    private companion object {
        const val UID = "user-1"
        const val CONV = "AAAAAAAA-0000-4000-8000-000000000001"
        const val MSG = "BBBBBBBB-0000-4000-8000-000000000002"
        const val PROVIDER = "CCCCCCCC-0000-4000-8000-000000000003"
        const val WORK = "FFFFFFFF-0000-4000-8000-000000000001"
        const val ROUND = "FFFFFFFF-0000-4000-8000-000000000002"

        val STUDIO_TABLES = listOf("studio_works", "studio_rounds", "studio_versions", "studio_round_refs")

        val NOCASE_COLUMNS = setOf(
            "id", "workId", "roundId", "currentVersionId", "baseVersionId", "parentVersionId", "assetId",
        )
        val INTEGER_COLUMNS = setOf(
            "createdAt", "updatedAt", "deletedAt", "startedAt", "finishedAt", "favorite", "kept",
            "index", "order", "width", "height", "nRequested", "nDelivered", "revision", "baseRevision",
        )
        val REAL_COLUMNS = setOf("costEstimateUsd", "chargedUsd")
        val NULLABLE_COLUMNS = setOf(
            "currentVersionId", "chatConversationId", "chatMessageId", "deletedAt", "baseVersionId", "enhancedPrompt",
            "modelRef", "errorKind", "costEstimateUsd", "chargedUsd", "managedJobId", "clientJobId", "finishedAt",
            "parentVersionId",
        )
        val EXPECTED_INDEXES = setOf(
            "index_studio_works_accountPartition_updatedAt|unique=0|accountPartition,updatedAt",
            "index_studio_rounds_workId|unique=0|workId",
            "index_studio_versions_workId|unique=0|workId",
            "index_studio_versions_roundId|unique=0|roundId",
            "index_studio_versions_assetId|unique=0|assetId",
            "index_studio_round_refs_assetId|unique=0|assetId",
        )
    }
}
