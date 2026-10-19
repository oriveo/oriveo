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
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Before
import org.junit.Test
import java.nio.file.Files
import java.nio.file.Path
import java.util.zip.ZipInputStream

/** A conversation's instructions are exported and imported with the backup, normalised on import, and on merge taken from the same side as the title. */
class ConversationInstructionsBackupTest {

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
        filesDir = Files.createTempDirectory("instructions-backup-test")
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
    fun backup_roundtrip_keeps_instructions() = runTest {
        val instructions = "  Answer in French.\nKeep it short.  "
        coEvery { conversationDao.getAll(LOCAL_PARTITION_ID) } returns
            listOf(conversationEntity(instructions = instructions))

        val exported = backupService.exportBackup()
        assertEquals(instructions, decodeBackupZip(exported).data.conversations.single().instructions)

        // Imported onto a device that does not have this conversation yet
        coEvery { conversationDao.getAll(LOCAL_PARTITION_ID) } returns emptyList()
        backupService.executeImport(mode = ImportMode.ImportNewOnly, bytes = exported)

        // Normalisation does not trim: leading and trailing whitespace is kept as-is
        assertEquals(instructions, upserted.single { it.id == "conversation-1" }.instructions)
    }

    @Test
    fun old_backup_defaults_empty() = runTest {
        val withKey = json.encodeToJsonElement(BackupFile.serializer(), backupFile(backupConversation())).jsonObject
        val data = withKey.getValue("data").jsonObject
        val conversation = data.getValue("conversations").jsonArray.single().jsonObject
        assertEquals(true, "instructions" in conversation)
        val stripped = JsonObject(
            withKey + ("data" to JsonObject(
                data + ("conversations" to kotlinx.serialization.json.JsonArray(
                    listOf(JsonObject(conversation - "instructions")),
                )),
            )),
        )
        val oldBytes = stripped.toString().toByteArray()
        assertEquals("", json.decodeFromString<BackupFile>(String(oldBytes)).data.conversations.single().instructions)

        backupService.executeImport(mode = ImportMode.ImportNewOnly, bytes = oldBytes)
        assertEquals("", upserted.single().instructions)

        // Instructions that are all whitespace are normalised to an empty string on import
        upserted.clear()
        val blank = backupFile(backupConversation(instructions = " \n\t　"))
        backupService.executeImport(mode = ImportMode.ImportNewOnly, bytes = json.encodeToString(blank).toByteArray())
        assertEquals("", upserted.single().instructions)
    }

    @Test
    fun backup_merge_takes_instructions_with_title() = runTest {
        coEvery { conversationDao.getById(LOCAL_PARTITION_ID, "conversation-1") } returns
            conversationEntity(title = "Local title", instructions = "local rules", updatedAt = 100L)

        // Backup is newer: title and instructions both come from the backup side (and are normalised: too long is cut to 8000 code points)
        val longInstructions = "😀".repeat(8_005)
        val newer = backupConversation(title = "Backup title", instructions = longInstructions, updatedAt = 200L)
        backupService.executeImport(mode = ImportMode.Merge, bytes = json.encodeToString(backupFile(newer)).toByteArray())
        val mergedNewer = upserted.last()
        assertEquals("Backup title", mergedNewer.title)
        assertEquals("😀".repeat(8_000), mergedNewer.instructions)

        // Backup is older: title and instructions both keep the local side
        upserted.clear()
        val older = backupConversation(title = "Backup title", instructions = "backup rules", updatedAt = 50L)
        backupService.executeImport(mode = ImportMode.Merge, bytes = json.encodeToString(backupFile(older)).toByteArray())
        val mergedOlder = upserted.last()
        assertEquals("Local title", mergedOlder.title)
        assertEquals("local rules", mergedOlder.instructions)
        assertFalse(mergedOlder.instructions == "backup rules")
    }

    @Test
    fun import_keeps_pinned_note_ids() = runTest {
        val noteA = "aaaaaaaa-1111-4111-8111-111111111111"
        val noteB = "BBBBBBBB-2222-4222-8222-222222222222"
        val backup = backupFile(backupConversation(pinnedNoteIds = listOf(noteA, noteB)))

        backupService.executeImport(mode = ImportMode.ImportNewOnly, bytes = json.encodeToString(backup).toByteArray())

        val restored = with(EntityMapper) { upserted.single().toDomain() }
        assertEquals(listOf(noteA.uppercase(), noteB), restored.pinnedNoteIds)
    }

    @Test
    fun merge_updates_pinned_note_ids() = runTest {
        val localNote = "cccccccc-3333-4333-8333-333333333333"
        val noteA = "aaaaaaaa-1111-4111-8111-111111111111"
        val noteB = "BBBBBBBB-2222-4222-8222-222222222222"
        coEvery { conversationDao.getById(LOCAL_PARTITION_ID, "conversation-1") } returns
            conversationEntity(updatedAt = 100L, pinnedNoteIdsJson = """["${localNote.uppercase()}"]""")

        // Backup is newer: pinned notes come from the backup like the title, encoded as in a fresh import (normalised, de-duplicated)
        val newer = backupConversation(updatedAt = 200L, pinnedNoteIds = listOf(noteA, noteB, noteA))
        backupService.executeImport(mode = ImportMode.Merge, bytes = json.encodeToString(backupFile(newer)).toByteArray())
        val mergedNewer = with(EntityMapper) { upserted.last().toDomain() }
        assertEquals(listOf(noteA.uppercase(), noteB), mergedNewer.pinnedNoteIds)

        // Backup is older: keep the local side
        upserted.clear()
        val older = backupConversation(updatedAt = 50L, pinnedNoteIds = listOf(noteA))
        backupService.executeImport(mode = ImportMode.Merge, bytes = json.encodeToString(backupFile(older)).toByteArray())
        val mergedOlder = with(EntityMapper) { upserted.last().toDomain() }
        assertEquals(listOf(localNote.uppercase()), mergedOlder.pinnedNoteIds)
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
        title: String = "Existing conversation",
        instructions: String = "",
        updatedAt: Long = 10L,
        pinnedNoteIdsJson: String? = null,
    ) = ConversationEntity(
        id = "conversation-1",
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
        pinnedNoteIdsJson = pinnedNoteIdsJson,
        instructions = instructions,
    )

    private fun backupConversation(
        title: String = "Backup conversation",
        instructions: String = "",
        updatedAt: Long = 20L,
        pinnedNoteIds: List<String> = emptyList(),
    ) = BackupConversation(
        id = "conversation-1",
        title = title,
        providerID = "existing-provider",
        providerKind = ProviderKind.OpenAI,
        modelID = "gpt-4o",
        createdAt = 10L,
        updatedAt = updatedAt,
        pinnedNoteIds = pinnedNoteIds,
        instructions = instructions,
    )

    private fun backupFile(conversation: BackupConversation) = BackupFile(
        version = BackupService.CURRENT_VERSION,
        createdAt = "2026-10-15T10:00:00Z",
        appVersion = "1.0.0",
        platform = "Android",
        checksum = "",
        containsKeys = false,
        data = BackupData(conversations = listOf(conversation)),
    )

    private fun decodeBackupZip(bytes: ByteArray): BackupFile {
        ZipInputStream(bytes.inputStream()).use { zis ->
            var entry = zis.nextEntry
            while (entry != null) {
                if (entry.name == "data.json") {
                    return json.decodeFromString(String(zis.readBytes()))
                }
                entry = zis.nextEntry
            }
        }
        error("data.json missing from backup zip")
    }
}
