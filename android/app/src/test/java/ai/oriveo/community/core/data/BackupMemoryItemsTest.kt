package ai.oriveo.community.core.data

import android.content.Context
import androidx.room.Room
import ai.oriveo.community.core.app.AppPreferenceKeys
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.context.ContextContractFixture
import ai.oriveo.community.core.context.MemoryItem
import ai.oriveo.community.core.context.MemoryItems
import ai.oriveo.community.core.context.MemoryKind
import ai.oriveo.community.core.context.MemoryStatus
import ai.oriveo.community.core.data.EntityMapper.toEntity
import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.data.backup.BackupService
import ai.oriveo.community.core.data.database.OriveoDatabase
import ai.oriveo.community.core.data.entity.MemoryItemEntity
import ai.oriveo.community.core.data.entity.PreferenceEntity
import ai.oriveo.community.core.mcp.mcpSha256Hex
import ai.oriveo.community.core.memory.MemoryItemRepository
import ai.oriveo.community.core.memory.toEntity
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.BackupData
import ai.oriveo.community.core.model.BackupError
import ai.oriveo.community.core.model.BackupFile
import ai.oriveo.community.core.model.BackupMemoryItem
import ai.oriveo.community.core.model.BackupPreferences
import ai.oriveo.community.core.model.ImportMode
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.security.SecureKeyStore
import io.mockk.every
import io.mockk.mockk
import java.time.Instant
import java.util.zip.ZipInputStream
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * Memory items are exported and imported with the backup (memory-items.v2 backup rules).
 * A real Room database plus the production BackupService / MemoryItemRepository; item inputs and expectations come from the shared contract fixture backupCases.
 */
@RunWith(RobolectricTestRunner::class)
class BackupMemoryItemsTest {

    private val context: Context get() = RuntimeEnvironment.getApplication()
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true; coerceInputValues = true }
    private val fixture: JsonObject by lazy { ContextContractFixture.load("memory-items.v2.json") }
    private var clock: Instant = Instant.parse("2026-10-16T08:00:00Z")
    private var idCounter = 0
    private val localWrites = mutableListOf<String>()

    private lateinit var db: OriveoDatabase
    private lateinit var repository: MemoryItemRepository
    private lateinit var backupService: BackupService

    @Before
    fun setUp() {
        db = Room.inMemoryDatabaseBuilder(context, OriveoDatabase::class.java).allowMainThreadQueries().build()
        val preferences = AppPreferencesRepository(
            preferenceDao = db.preferenceDao(),
        )
        repository = MemoryItemRepository(
            dao = db.memoryItemDao(),
            preferenceDao = db.preferenceDao(),
            preferences = preferences,
            now = { clock },
            newId = { "f%07d-aaaa-4bbb-8ccc-dddddddddddd".format(++idCounter) },
        )
        repository.onLocalWrite = { localWrites += it }
        backupService = BackupService(
            providerDao = db.providerDao(),
            conversationDao = db.conversationDao(),
            messageDao = db.messageDao(),
            folderDao = db.folderDao(),
            skillDao = db.skillDao(),
            noteDao = db.noteDao(),
            noteFolderDao = db.noteFolderDao(),
            json = json,
            secureKeyStore = mockk<SecureKeyStore>(relaxed = true),
            attachmentStore = mockk<AttachmentStore>(relaxed = true),
            preferenceDao = db.preferenceDao(),
            metadataRefresh = {},
            memoryItemRepository = repository,
        )
    }

    @After
    fun tearDown() {
        db.close()
    }

    @Test
    fun round_trip_replace() = runBlocking {
        seedProvider()
        val kept = repository.create(UID, MemoryKind.FACT, "\u4f4f\u5728\u676d\u5dde")
        clock = clock.plusSeconds(1)
        val dropped = repository.create(UID, MemoryKind.PREFERENCE, "\u559c\u6b22\u7b80\u77ed\u56de\u7b54")
        repository.delete(UID, dropped.id)

        val exported = backupService.exportBackup()
        val data = exportedData(exported)
        assertEquals(MemoryItems.SCHEMA_VERSION, data.memorySchemaVersion)
        val section = MemoryItems.backupSection(repository.list(UID))
        assertEquals(section.memoryItems, data.memoryItems.map { it.toItem() })
        // The legacy memory field is still exported: memoryText is the compiled result of the items
        assertEquals("\u4f4f\u5728\u676d\u5dde", data.preferences!!.memoryText)

        // Edited locally after the export: a replace import returns to the moment of the backup
        repository.edit(UID, kept.id, "\u4f4f\u5728\u4e0a\u6d77")
        repository.create(UID, MemoryKind.FACT, "\u5bfc\u51fa\u540e\u65b0\u5efa")
        backupService.executeImport(mode = ImportMode.ReplaceAll, bytes = exported)

        val restored = repository.list(UID)
        assertEquals("\u4f4f\u5728\u676d\u5dde", restored.single { it.id == kept.id }.content)
        assertEquals(MemoryStatus.DELETED, restored.single { it.id == dropped.id }.status)
        assertEquals(section.memoryItems, restored.filter { it.id == kept.id || it.id == dropped.id })
        assertEquals("\u4f4f\u5728\u676d\u5dde", pref(AppPreferenceKeys.MEMORY_TEXT))
        assertEquals(mcpSha256Hex("\u4f4f\u5728\u676d\u5dde"), pref(AppPreferenceKeys.MEMORY_TEXT_DIGEST))
    }

    @Test
    fun replace_tombstones_local_only_items() = runBlocking {
        val case = backupCase("replace_tombstones_local_items_missing_from_backup")
        val local = seedLocal(case)
        val expected = items(case.expected()["items"]!!)
        val tombstonedIds = case.expected()["tombstonedIds"]!!.jsonArray.map { it.jsonPrimitive.content }

        backupService.executeImport(mode = ImportMode.ReplaceAll, bytes = backupBytes(case))

        val after = repository.list(UID).associateBy { it.id }
        expected.forEach { assertEquals(it, after.getValue(it.id)) }
        // Local live items that the backup lacks become tombstones (new mutationId, pending); existing local tombstones are kept as-is
        tombstonedIds.forEach { id ->
            val tombstone = after.getValue(id)
            assertEquals(MemoryStatus.DELETED, tombstone.status)
            assertEquals("", tombstone.content)
            assertEquals(clock.toString(), tombstone.deletedAt)
            assertTrue(tombstone.mutationId != local.single { it.id == id }.mutationId)
        }
        val untouched = local.filter { it.status == MemoryStatus.DELETED && it.id !in expected.map(MemoryItem::id) }
        assertTrue(untouched.isNotEmpty())
        untouched.forEach { assertEquals(it, after.getValue(it.id)) }
        assertEquals(expected.size + tombstonedIds.size + untouched.size, after.size)
        assertEquals((expected.map { it.id } + tombstonedIds).toSet(), pendingIds())
    }

    @Test
    fun merge_keeps_newer_and_tombstones() = runBlocking {
        val case = backupCase("merge_keeps_newer_and_tombstones")
        seedLocal(case)

        backupService.executeImport(mode = ImportMode.Merge, bytes = backupBytes(case))

        val expected = items(case.expected()["items"]!!)
        assertEquals(expected, repository.list(UID))
        // Newer local items and local tombstones are untouched (no resurrection); only the items the backup wins are written
        val localById = items(case.input()["local"]!!).associateBy { it.id }
        assertEquals(expected.filter { localById[it.id] != it }.map { it.id }.toSet(), pendingIds())
        assertEquals(MemoryStatus.DELETED, repository.list(UID).single { it.content.isEmpty() }.status)
    }

    @Test
    fun import_new_only_adds_missing() = runBlocking {
        val case = backupCase("merge_keeps_newer_and_tombstones")
        val local = seedLocal(case)
        val backupItems = items(case.input()["backup"]!!.jsonObject["memoryItems"]!!)

        backupService.executeImport(mode = ImportMode.ImportNewOnly, bytes = backupBytes(case))

        // Only ids missing locally are added: a local tombstone counts as present, and even a newer backup does not overwrite an existing item
        val missing = backupItems.filter { item -> local.none { it.id == item.id } }
        assertEquals(1, missing.size)
        assertEquals(MemoryItems.listOrder(local + missing), repository.list(UID))
        assertEquals(missing.map { it.id }.toSet(), pendingIds())
    }

    @Test
    fun legacy_backup_migrates() = runBlocking {
        val case = backupCase("legacy_backup_migrates_preferences")
        val input = case.input()
        db.preferenceDao().set(PreferenceEntity(AppPreferenceKeys.MEMORY_DEVICE_ID, input["deviceId"]!!.jsonPrimitive.content))
        val prefs = input["backup"]!!.jsonObject["preferences"]!!.jsonObject
        val preferences = BackupPreferences(
            memoryText = prefs["memoryText"]!!.jsonPrimitive.content,
            memoryAntiForgetEnabled = prefs["antiForgetEnabled"]!!.jsonPrimitive.content.toBooleanStrict(),
            memoryAntiForgetText = prefs["antiForgetText"]!!.jsonPrimitive.content,
            memoryUpdatedAt = prefs["memoryUpdatedAt"]!!.jsonPrimitive.content,
        )

        backupService.executeImport(mode = ImportMode.Merge, bytes = encode(BackupData(preferences = preferences)))

        assertEquals(withoutUidDerivedIds(items(case.expected()["items"]!!)), withoutUidDerivedIds(repository.list(UID)))
        assertEquals(repository.list(UID).map { it.id }.toSet(), pendingIds())
        // Double write: the compiled result equals the restored memoryText, so only the digest is filled in and memoryUpdatedAt is not refreshed
        assertEquals(preferences.memoryText, pref(AppPreferenceKeys.MEMORY_TEXT))
        assertEquals(mcpSha256Hex(preferences.memoryText), pref(AppPreferenceKeys.MEMORY_TEXT_DIGEST))
        assertEquals(preferences.memoryUpdatedAt, pref(AppPreferenceKeys.MEMORY_UPDATED_AT))

        // Importing the same old backup again: create-if-absent, no duplicates
        backupService.executeImport(mode = ImportMode.Merge, bytes = encode(BackupData(preferences = preferences)))
        assertEquals(withoutUidDerivedIds(items(case.expected()["items"]!!)), withoutUidDerivedIds(repository.list(UID)))
    }

    @Test
    fun imported_items_pending() = runBlocking {
        val local = repository.create(UID, MemoryKind.FACT, "\u4f4f\u5728\u676d\u5dde")
        db.memoryItemDao().upsert(repository.get(UID, local.id)!!.toEntity(UID, MemoryItemEntity.SYNC_SYNCED))
        val updatedAtBefore = pref(AppPreferenceKeys.MEMORY_UPDATED_AT)
        localWrites.clear()
        clock = clock.plusSeconds(60)
        val incoming = MemoryItems.canonical(
            MemoryItem(
                id = "30000000-0000-4000-8000-000000000001",
                kind = MemoryKind.PREFERENCE,
                content = "\u559c\u6b22\u7b80\u77ed\u56de\u7b54",
                mutationId = "30000000-0000-4000-8000-0000000000aa",
                deviceId = "other-device",
            ),
        )

        backupService.executeImport(
            mode = ImportMode.ImportNewOnly,
            bytes = encode(BackupData(memorySchemaVersion = 2, memoryItems = listOf(BackupMemoryItem.from(incoming)))),
        )

        // The imported row is pending (pushed by sync) and the locally synced one is untouched; sync is woken
        assertEquals(setOf(incoming.id), pendingIds())
        assertEquals(incoming, repository.get(UID, incoming.id))
        assertEquals(listOf(UID), localWrites)
        // An import is a local change: the compiled memoryText changed, so it is double-written and the timestamp refreshed (list order: items with an empty createdAt come first)
        assertEquals("\u559c\u6b22\u7b80\u77ed\u56de\u7b54\n\n\u4f4f\u5728\u676d\u5dde", pref(AppPreferenceKeys.MEMORY_TEXT))
        assertEquals(clock.toString(), pref(AppPreferenceKeys.MEMORY_UPDATED_AT))
        assertTrue(updatedAtBefore != clock.toString())
    }

    @Test
    fun cross_end_backup_decodes() = runBlocking {
        val case = backupCase("export_section")
        val section = case.expected()
        val other = buildBackupJson(
            JsonObject(
                mapOf(
                    "memorySchemaVersion" to section["memorySchemaVersion"]!!,
                    "memoryItems" to section["memoryItems"]!!,
                ),
            ),
        )

        backupService.executeImport(mode = ImportMode.ReplaceAll, bytes = other.toString().toByteArray())
        seedProvider()
        val exported = exportedDataJson(backupService.exportBackup())

        assertEquals(section["memorySchemaVersion"], exported["memorySchemaVersion"])
        val expectedItems = section["memoryItems"]!!.jsonArray
        val actualItems = exported["memoryItems"]!!.jsonArray
        assertEquals(expectedItems.size, actualItems.size)
        expectedItems.zip(actualItems).forEach { (e, a) ->
            val expectedFields = e.jsonObject
            val actualFields = a.jsonObject
            assertEquals(expectedFields.keys.toList(), actualFields.keys.toList())
            expectedFields.forEach { (key, value) -> assertSameJson(key, value, actualFields.getValue(key)) }
        }
    }

    @Test
    fun import_with_section_marks_migrated() = runBlocking {
        assertEquals(null, pref(AppPreferenceKeys.MEMORY_ITEMS_MIGRATED))
        val item = MemoryItems.canonical(
            MemoryItem(
                id = "40000000-0000-4000-8000-000000000001",
                kind = MemoryKind.PREFERENCE,
                content = "\u559c\u6b22\u7b80\u77ed\u56de\u7b54",
                mutationId = "40000000-0000-4000-8000-0000000000aa",
                deviceId = "other-device",
            ),
        )
        // A backup written by a newer build: the item section plus the double-written memoryText (no digest)
        val data = BackupData(
            preferences = BackupPreferences(memoryText = item.content),
            memorySchemaVersion = 2,
            memoryItems = listOf(BackupMemoryItem.from(item)),
        )

        backupService.executeImport(mode = ImportMode.Merge, bytes = encode(data))

        // The section is authoritative: mark as migrated so the restored memoryText is not migrated into duplicate items
        assertEquals("true", pref(AppPreferenceKeys.MEMORY_ITEMS_MIGRATED))
        assertEquals(listOf(item), repository.list(UID))
        assertEquals(item.content, pref(AppPreferenceKeys.MEMORY_TEXT))
        assertEquals(mcpSha256Hex(item.content), pref(AppPreferenceKeys.MEMORY_TEXT_DIGEST))
    }

    @Test
    fun export_with_only_memory_items() = runBlocking {
        val item = repository.create(UID, MemoryKind.FACT, "\u4f4f\u5728\u676d\u5dde")

        val data = exportedData(backupService.exportBackup())

        assertEquals(MemoryItems.SCHEMA_VERSION, data.memorySchemaVersion)
        assertEquals(listOf(item.id), data.memoryItems.map { it.id })
        assertTrue(data.providers.isEmpty() && data.conversations.isEmpty())

        // Tombstones alone do not count as exportable data
        repository.delete(UID, item.id)
        assertEquals(
            BackupError.NoDataToExport,
            runCatching { backupService.exportBackup() }.exceptionOrNull(),
        )
    }

    // ---- helpers ----

    private fun backupCase(id: String): JsonObject =
        fixture["backupCases"]!!.jsonArray.map { it.jsonObject }.single { it["id"]!!.jsonPrimitive.content == id }

    private fun JsonObject.input(): JsonObject = this["input"]!!.jsonObject

    private fun JsonObject.expected(): JsonObject = this["expected"]!!.jsonObject

    /** Decodes fixture JSON through the production backup item decoder. */
    private fun items(el: JsonElement): List<MemoryItem> =
        json.decodeFromJsonElement(ListSerializer(BackupMemoryItem.serializer()), el).map { it.toItem() }

    /** Stores the fixture's local items as synced rows and returns the stored items. */
    private suspend fun seedLocal(case: JsonObject): List<MemoryItem> {
        db.preferenceDao().set(PreferenceEntity(AppPreferenceKeys.MEMORY_ITEMS_MIGRATED, "true"))
        val local = items(case.input()["local"]!!)
        local.forEach { db.memoryItemDao().upsert(it.toEntity(UID, MemoryItemEntity.SYNC_SYNCED)) }
        return local
    }

    private fun backupBytes(case: JsonObject): ByteArray {
        val backup = case.input()["backup"]!!.jsonObject
        return buildBackupJson(backup).toString().toByteArray()
    }

    /** A backup exported by another platform: data takes the keys of [memory] as-is and is empty otherwise. */
    private fun buildBackupJson(memory: JsonObject): JsonObject {
        val file = json.encodeToJsonElement(BackupFile.serializer(), backupFile(BackupData())).jsonObject
        val data = file.getValue("data").jsonObject - "memorySchemaVersion" - "memoryItems"
        val memoryKeys = memory.filterKeys { it == "memorySchemaVersion" || it == "memoryItems" }
        return JsonObject(file + ("data" to JsonObject(data + memoryKeys)))
    }

    private fun encode(data: BackupData): ByteArray =
        json.encodeToString(BackupFile.serializer(), backupFile(data)).toByteArray()

    private fun backupFile(data: BackupData) = BackupFile(
        version = BackupService.CURRENT_VERSION,
        createdAt = "2026-10-16T10:00:00Z",
        appVersion = "1.0.0",
        platform = "iOS",
        checksum = "",
        containsKeys = false,
        data = data,
    )

    private fun exportedDataJson(bytes: ByteArray): JsonObject {
        ZipInputStream(bytes.inputStream()).use { zis ->
            var entry = zis.nextEntry
            while (entry != null) {
                if (entry.name == "data.json") {
                    return Json.parseToJsonElement(String(zis.readBytes())).jsonObject.getValue("data").jsonObject
                }
                entry = zis.nextEntry
            }
        }
        error("data.json missing from backup zip")
    }

    private fun exportedData(bytes: ByteArray): BackupData =
        json.decodeFromJsonElement(BackupData.serializer(), exportedDataJson(bytes))

    /** Field-by-field comparison: numbers by value (1 equals 1.0), everything else as-is. */
    private fun assertSameJson(path: String, expected: JsonElement, actual: JsonElement) {
        when {
            expected is JsonObject -> {
                val a = actual.jsonObject
                assertEquals(path, expected.keys.toList(), a.keys.toList())
                expected.forEach { (k, v) -> assertSameJson("$path.$k", v, a.getValue(k)) }
            }
            expected is JsonArray -> {
                val a = actual.jsonArray
                assertEquals(path, expected.size, a.size)
                expected.zip(a).forEachIndexed { i, (e, x) -> assertSameJson("$path[$i]", e, x) }
            }
            expected is JsonNull -> assertEquals(path, JsonNull, actual)
            expected is JsonPrimitive && !expected.isString && expected.doubleOrNull != null ->
                assertEquals(path, expected.doubleOrNull!!, actual.jsonPrimitive.doubleOrNull!!, 0.0)
            else -> assertEquals(path, expected, actual)
        }
    }

    /**
     * The fixture ids and mutationIds of migrated items are derived from the fixture uid; the community edition has a single
     * local partition, so the same derivation yields different values. Every other field is still compared against the fixture.
     */
    private fun withoutUidDerivedIds(items: List<MemoryItem>): List<MemoryItem> =
        items.map { it.copy(id = "", mutationId = "") }

    private suspend fun pendingIds(): Set<String> = repository.pending(UID).map { it.id }.toSet()

    private suspend fun pref(key: String): String? = db.preferenceDao().get(key)

    private suspend fun seedProvider() {
        db.providerDao().upsert(
            Provider(
                id = "existing-provider",
                kind = ProviderKind.OpenAI,
                status = ProviderConnectionState.Connected,
                models = listOf(AIModel(id = "gpt-4o", name = "GPT-4o", isDefault = true)),
                catalogModels = emptyList(),
                lastCheckedAt = null,
                apiKey = "",
                apiKeyPreview = "",
                lastError = null,
                baseUrlText = ProviderKind.OpenAI.defaultBaseUrl,
                customName = null,
                updatedAt = 0L,
            ).toEntity(UID),
        )
    }

    private companion object {
        const val UID = LOCAL_PARTITION_ID
    }
}
