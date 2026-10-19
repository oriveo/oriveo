package ai.oriveo.community.core.data

import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.EntityMapper.toEntity
import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.data.backup.BackupService
import ai.oriveo.community.core.data.dao.ConversationDao
import ai.oriveo.community.core.data.dao.FolderDao
import ai.oriveo.community.core.data.dao.MessageDao
import ai.oriveo.community.core.data.dao.NoteDao
import ai.oriveo.community.core.data.dao.NoteFolderDao
import ai.oriveo.community.core.data.dao.PreferenceDao
import ai.oriveo.community.core.data.dao.ProviderDao
import ai.oriveo.community.core.data.dao.SkillDao
import ai.oriveo.community.core.data.entity.ConversationEntity
import ai.oriveo.community.core.context.ContextBudgetCap
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.BackupConversation
import ai.oriveo.community.core.model.BackupData
import ai.oriveo.community.core.model.BackupFile
import ai.oriveo.community.core.model.ImportMode
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.security.SecureKeyStore
import io.mockk.Runs
import io.mockk.coEvery
import io.mockk.every
import io.mockk.just
import io.mockk.mockk
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.nio.file.Files
import java.nio.file.Path
import java.util.zip.ZipInputStream

/** A conversation's contextCap is exported and imported with the backup, decoded leniently, and on merge taken from the same side as the title. */
class ConversationContextCapBackupTest {

    private val providerDao = mockk<ProviderDao>()
    private val conversationDao = mockk<ConversationDao>()
    private val messageDao = mockk<MessageDao>()
    private val folderDao = mockk<FolderDao>()
    private val skillDao = mockk<SkillDao>()
    private val noteDao = mockk<NoteDao>(relaxed = true)
    private val noteFolderDao = mockk<NoteFolderDao>(relaxed = true)
    private val secureKeyStore = mockk<SecureKeyStore>()
    private val attachmentStore = mockk<AttachmentStore>()
    private val preferenceDao = mockk<PreferenceDao>()
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val upserted = mutableListOf<ConversationEntity>()

    private lateinit var filesDir: Path
    private lateinit var backupService: BackupService

    @Before
    fun setUp() {
        mockkStatic(android.util.Log::class)
        every { android.util.Log.w(any<String>(), any<String>(), any<Throwable>()) } returns 0
        every { android.util.Log.w(any<String>(), any<String>()) } returns 0
        filesDir = Files.createTempDirectory("context-cap-backup-test")
        every { secureKeyStore.getApiKey(any(), any()) } returns null
        every { secureKeyStore.deleteApiKey(any(), any()) } just Runs
        every { secureKeyStore.saveApiKey(any(), any(), any()) } just Runs
        coEvery { attachmentStore.clearAll() } returns Unit
        every { attachmentStore.delete(any()) } just Runs
        every { attachmentStore.loadImageBytes(any()) } returns null
        every { attachmentStore.loadThumbnailBytes(any()) } returns null
        coEvery { preferenceDao.get(any()) } returns null
        coEvery { preferenceDao.set(any()) } returns Unit
        coEvery { preferenceDao.delete(any()) } returns Unit
        coEvery { providerDao.upsert(any()) } returns Unit
        coEvery { providerDao.getAll(any()) } returns listOf(providerEntity())
        coEvery { providerDao.getById(any(), any()) } returns null
        coEvery { providerDao.deleteByAccount(any()) } returns Unit
        coEvery { conversationDao.upsert(capture(upserted)) } returns Unit
        coEvery { conversationDao.getAll(any()) } returns emptyList()
        coEvery { conversationDao.getById(any(), any()) } returns null
        coEvery { conversationDao.deleteByAccount(any()) } returns Unit
        coEvery { messageDao.getByConversation(any(), any()) } returns emptyList()
        coEvery { messageDao.deleteRowsByConversation(any(), any()) } returns Unit
        coEvery { messageDao.upsert(any()) } returns Unit
        coEvery { folderDao.getAll(any()) } returns emptyList()
        coEvery { folderDao.countByAccount(any()) } returns 0
        coEvery { folderDao.upsert(any()) } returns Unit
        coEvery { folderDao.getById(any(), any()) } returns null
        coEvery { folderDao.deleteByAccount(any()) } returns Unit
        coEvery { skillDao.getBySource(any(), any()) } returns emptyList()
        coEvery { skillDao.getById(any()) } returns null
        coEvery { skillDao.upsert(any()) } returns Unit
        coEvery { skillDao.deleteBySource(any(), any()) } returns Unit
        coEvery { noteDao.getAll(any()) } returns emptyList()
        coEvery { noteDao.getById(any(), any()) } returns null
        coEvery { noteFolderDao.getAll(any()) } returns emptyList()
        coEvery { noteFolderDao.getById(any(), any()) } returns null

        backupService = BackupService(
            providerDao = providerDao,
            conversationDao = conversationDao,
            messageDao = messageDao,
            folderDao = folderDao,
            skillDao = skillDao,
            noteDao = noteDao,
            noteFolderDao = noteFolderDao,
            json = json,
            secureKeyStore = secureKeyStore,
            attachmentStore = attachmentStore,
            preferenceDao = preferenceDao,
            metadataRefresh = {},
            runInTransaction = { block -> block() },
        )
    }

    @After
    fun tearDown() {
        unmockkStatic(android.util.Log::class)
        filesDir.toFile().deleteRecursively()
    }

    @Test
    fun backup_roundtrip_keeps_context_cap() = runTest {
        coEvery { conversationDao.getAll(LOCAL_PARTITION_ID) } returns listOf(
            conversationEntity(contextCap = "64000"),
            conversationEntity(id = "conversation-2", contextCap = "unlimited"),
            conversationEntity(id = "conversation-3", contextCap = null),
        )

        val exported = backupService.exportBackup()
        val conversations = decodeBackupZip(exported).data.conversations.associateBy { it.id }
        // wire: a custom value is written as a number, a named tier as a string, and "follow global" carries no value
        val customWire = conversations.getValue("conversation-1").contextCap as JsonPrimitive
        assertFalse(customWire.isString)
        assertEquals("64000", customWire.content)
        assertEquals(JsonPrimitive("unlimited"), conversations.getValue("conversation-2").contextCap)
        assertNull(conversations.getValue("conversation-3").parsedContextCap)
        // Follow global: the conversation JSON has no contextCap key (same as iOS / Web, never null)
        val rawConversations = decodeBackupJson(exported).getValue("data").jsonObject
            .getValue("conversations").jsonArray.associateBy { it.jsonObject.getValue("id").jsonPrimitive.content }
        assertFalse("contextCap" in rawConversations.getValue("conversation-3").jsonObject)
        assertTrue("contextCap" in rawConversations.getValue("conversation-1").jsonObject)
        assertEquals(ContextBudgetCap.Custom(64_000), conversations.getValue("conversation-1").parsedContextCap)

        // Imported onto a device that has none of these conversations yet
        coEvery { conversationDao.getAll(LOCAL_PARTITION_ID) } returns emptyList()
        backupService.executeImport(mode = ImportMode.ImportNewOnly, bytes = exported)

        val restored = upserted.associateBy { it.id }
        assertEquals("64000", restored.getValue("conversation-1").contextCap)
        assertEquals("unlimited", restored.getValue("conversation-2").contextCap)
        assertNull(restored.getValue("conversation-3").contextCap)
    }

    @Test
    fun old_backup_follows_global() = runTest {
        val withKey = json.encodeToJsonElement(
            BackupFile.serializer(),
            backupFile(backupConversation(contextCap = JsonPrimitive("unlimited"))),
        ).jsonObject
        val data = withKey.getValue("data").jsonObject
        val conversation = data.getValue("conversations").jsonArray.single().jsonObject
        assertTrue("contextCap" in conversation)
        val stripped = JsonObject(
            withKey + ("data" to JsonObject(
                data + ("conversations" to JsonArray(listOf(JsonObject(conversation - "contextCap")))),
            )),
        )
        val oldBytes = stripped.toString().toByteArray()
        val decoded = json.decodeFromString<BackupFile>(String(oldBytes)).data.conversations.single()
        assertNull(decoded.contextCap)
        assertNull(decoded.parsedContextCap)

        backupService.executeImport(mode = ImportMode.ImportNewOnly, bytes = oldBytes)
        assertNull(upserted.single().contextCap)
    }

    @Test
    fun backup_invalid_cap_follows_global() = runTest {
        val invalid = listOf(
            JsonPrimitive("190000"),
            JsonPrimitive(31_999),
            JsonPrimitive(true),
            JsonPrimitive(64_000.5),
            JsonPrimitive("64k"),
            buildJsonObject { put("tokens", 64_000) },
        )
        val backup = backupFile(
            *invalid.mapIndexed { index, wire ->
                backupConversation(id = "invalid-$index", contextCap = wire)
            }.toTypedArray(),
            backupConversation(id = "valid-auto", contextCap = JsonPrimitive("auto")),
            backupConversation(id = "valid-integral", contextCap = JsonPrimitive(128_000.0)),
        )
        val bytes = json.encodeToString(backup).toByteArray()
        // The illegal values are present as-is in the raw JSON (they were not filtered out on the export side)
        val raw = String(bytes)
        assertTrue(raw.contains("\"contextCap\":\"190000\""))
        assertTrue(raw.contains("\"contextCap\":31999"))
        assertTrue(raw.contains("\"contextCap\":true"))

        // The whole import does not fail: every conversation is stored, and an illegal value means follow global
        backupService.executeImport(mode = ImportMode.ImportNewOnly, bytes = bytes)
        val restored = upserted.associateBy { it.id }
        assertEquals(invalid.size + 2, restored.size)
        invalid.indices.forEach { index -> assertNull(restored.getValue("invalid-$index").contextCap) }
        assertEquals("auto", restored.getValue("valid-auto").contextCap)
        assertEquals("128000", restored.getValue("valid-integral").contextCap)
    }

    @Test
    fun backup_merge_takes_cap_with_title() = runTest {
        coEvery { conversationDao.getById(LOCAL_PARTITION_ID, "conversation-1") } returns
            conversationEntity(title = "Local title", contextCap = "unlimited", updatedAt = 100L)

        // Backup is newer: title and contextCap both come from the backup side
        val newer = backupConversation(title = "Backup title", contextCap = JsonPrimitive(64_000), updatedAt = 200L)
        backupService.executeImport(mode = ImportMode.Merge, bytes = json.encodeToString(backupFile(newer)).toByteArray())
        assertEquals("Backup title", upserted.last().title)
        assertEquals("64000", upserted.last().contextCap)

        // Backup is newer but the value is illegal: taken from the backup like title, and a parse rejection means follow global
        upserted.clear()
        val newerInvalid = backupConversation(title = "Backup title", contextCap = JsonPrimitive("190000"), updatedAt = 200L)
        backupService.executeImport(mode = ImportMode.Merge, bytes = json.encodeToString(backupFile(newerInvalid)).toByteArray())
        assertEquals("Backup title", upserted.last().title)
        assertNull(upserted.last().contextCap)

        // Backup is older: title and contextCap both keep the local side
        upserted.clear()
        val older = backupConversation(title = "Backup title", contextCap = JsonPrimitive("auto"), updatedAt = 50L)
        backupService.executeImport(mode = ImportMode.Merge, bytes = json.encodeToString(backupFile(older)).toByteArray())
        assertEquals("Local title", upserted.last().title)
        assertEquals("unlimited", upserted.last().contextCap)
    }

    private fun providerEntity() = Provider(
        id = "existing-provider",
        kind = ProviderKind.OpenAI,
        status = ProviderConnectionState.Connected,
        models = listOf(AIModel(id = "gpt-4o", name = "GPT-4o", isDefault = true)),
        catalogModels = listOf(AIModel(id = "gpt-4o", name = "GPT-4o", isDefault = true)),
        lastCheckedAt = null,
        apiKey = "",
        apiKeyPreview = "",
        lastError = null,
        baseUrlText = ProviderKind.OpenAI.defaultBaseUrl,
        customName = null,
        updatedAt = 0L,
    ).toEntity(LOCAL_PARTITION_ID)

    private fun conversationEntity(
        id: String = "conversation-1",
        title: String = "Existing conversation",
        contextCap: String? = null,
        updatedAt: Long = 10L,
    ) = ConversationEntity(
        id = id,
        title = title,
        hasCustomTitle = false,
        providerID = "existing-provider",
        providerKind = ProviderKind.OpenAI.name,
        modelID = "gpt-4o",
        useMemory = true,
        previewText = "Hello",
        estimatedCost = 0.0,
        isDraft = false,
        draftText = "",
        createdAt = 10L,
        updatedAt = updatedAt,
        accountId = LOCAL_PARTITION_ID,
        contextCap = contextCap,
    )

    private fun backupConversation(
        id: String = "conversation-1",
        title: String = "Backup conversation",
        contextCap: JsonElement? = null,
        updatedAt: Long = 20L,
    ) = BackupConversation(
        id = id,
        title = title,
        providerID = "existing-provider",
        providerKind = ProviderKind.OpenAI,
        modelID = "gpt-4o",
        createdAt = 10L,
        updatedAt = updatedAt,
        contextCap = contextCap,
    )

    private fun backupFile(vararg conversations: BackupConversation) = BackupFile(
        version = BackupService.CURRENT_VERSION,
        createdAt = "2026-10-15T10:00:00Z",
        appVersion = "1.0.0",
        platform = "Android",
        checksum = "",
        containsKeys = false,
        data = BackupData(conversations = conversations.toList()),
    )

    private fun decodeBackupZip(bytes: ByteArray): BackupFile =
        json.decodeFromString(readBackupDataJson(bytes))

    private fun decodeBackupJson(bytes: ByteArray): JsonObject =
        json.parseToJsonElement(readBackupDataJson(bytes)).jsonObject

    private fun readBackupDataJson(bytes: ByteArray): String {
        ZipInputStream(bytes.inputStream()).use { zis ->
            var entry = zis.nextEntry
            while (entry != null) {
                if (entry.name == "data.json") {
                    return String(zis.readBytes())
                }
                entry = zis.nextEntry
            }
        }
        error("data.json missing from backup zip")
    }
}
