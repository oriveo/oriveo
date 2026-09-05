package ai.oriveo.community.core.data

import ai.oriveo.community.core.app.AppPreferenceKeys
import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.EntityMapper.toEntity
import ai.oriveo.community.core.data.EntityMapper.toDomain
import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.data.backup.BackupService
import ai.oriveo.community.core.data.database.OriveoDatabase
import ai.oriveo.community.core.data.dao.ConversationDao
import ai.oriveo.community.core.data.dao.FolderDao
import ai.oriveo.community.core.data.dao.MessageDao
import ai.oriveo.community.core.data.dao.PreferenceDao
import ai.oriveo.community.core.data.dao.ProviderDao
import ai.oriveo.community.core.data.dao.SkillDao
import ai.oriveo.community.core.data.entity.ConversationEntity
import ai.oriveo.community.core.data.entity.MessageEntity
import ai.oriveo.community.core.data.entity.FolderEntity
import ai.oriveo.community.core.data.entity.PreferenceEntity
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.BackupData
import ai.oriveo.community.core.model.BackupConversation
import ai.oriveo.community.core.model.BackupError
import ai.oriveo.community.core.model.BackupFile
import ai.oriveo.community.core.model.BackupFolder
import ai.oriveo.community.core.model.BackupNote
import ai.oriveo.community.core.model.BackupNoteFolder
import ai.oriveo.community.core.model.BackupPreferences
import ai.oriveo.community.core.model.BackupProvider
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ImportMode
import ai.oriveo.community.core.model.LanguageOption
import ai.oriveo.community.core.model.LastUsedModelRef
import ai.oriveo.community.core.model.Note
import ai.oriveo.community.core.model.NoteFolder
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProvenanceEntry
import ai.oriveo.community.core.model.ProvenanceKind
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayImageConfig
import ai.oriveo.community.core.model.RelayImageMode
import ai.oriveo.community.core.model.RelayImageOutputFormat
import ai.oriveo.community.core.model.RelayKeyValue
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.RelayReasoningEffort
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.Skill
import ai.oriveo.community.core.model.SkillKnowledgeBase
import ai.oriveo.community.core.model.SkillKnowledgeBaseFile
import ai.oriveo.community.core.model.SkillKnowledgeFileStatus
import ai.oriveo.community.core.model.SkillKnowledgeIngestionMode
import ai.oriveo.community.core.model.SkillSource
import ai.oriveo.community.core.model.ThemeOption
import ai.oriveo.community.core.security.SecureKeyStore
import io.mockk.Runs
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.just
import io.mockk.mockk
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import io.mockk.verify
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.nio.file.Files
import java.nio.file.Path
import java.util.concurrent.atomic.AtomicInteger
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream

class BackupServiceTest {

    private val providerDao = mockk<ProviderDao>()
    private val conversationDao = mockk<ConversationDao>()
    private val messageDao = mockk<MessageDao>()
    private val folderDao = mockk<FolderDao>()
    private val skillDao = mockk<SkillDao>()
    private val noteDao = mockk<ai.oriveo.community.core.data.dao.NoteDao>(relaxed = true)
    private val noteFolderDao = mockk<ai.oriveo.community.core.data.dao.NoteFolderDao>(relaxed = true)
    private val secureKeyStore = mockk<SecureKeyStore>()
    private val attachmentStore = mockk<AttachmentStore>()
    private val preferenceDao = mockk<PreferenceDao>()
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val accountIdFlow = MutableStateFlow(LOCAL_PARTITION_ID)
    private val metadataRefreshCallCount = AtomicInteger(0)

    private lateinit var filesDir: Path
    private lateinit var backupService: BackupService

    @Before
    fun setUp() {
        
        
        mockkStatic(android.util.Log::class)
        every { android.util.Log.w(any<String>(), any<String>(), any<Throwable>()) } returns 0
        every { android.util.Log.w(any<String>(), any<String>()) } returns 0
        filesDir = Files.createTempDirectory("backup-service-test")
        every { secureKeyStore.getApiKey(any(), any()) } returns null
        every { secureKeyStore.deleteApiKey(any(), any()) } just Runs
        every { secureKeyStore.saveApiKey(any(), any(), any()) } just Runs
        coEvery { attachmentStore.clearAll() } returns Unit
        every { attachmentStore.delete(any()) } just Runs
        every { attachmentStore.loadImageBytes(any()) } returns null
        every { attachmentStore.loadThumbnailBytes(any()) } returns null
        coEvery { preferenceDao.get(any()) } returns null
        coEvery { providerDao.upsert(any()) } returns Unit
        coEvery { providerDao.getAll(any()) } returns emptyList()
        coEvery { conversationDao.upsert(any()) } returns Unit
        coEvery { conversationDao.getAll(any()) } returns emptyList()
        
        coEvery { conversationDao.getById(any(), any()) } returns null
        coEvery { providerDao.getById(any(), any()) } returns null
        coEvery { folderDao.getById(any(), any()) } returns null
        coEvery { conversationDao.deleteByAccount(any()) } returns Unit
        coEvery { providerDao.deleteByAccount(any()) } returns Unit
        coEvery { messageDao.getByConversation(any(), any()) } returns emptyList()
        coEvery { preferenceDao.set(any()) } returns Unit
        coEvery { preferenceDao.delete(any()) } returns Unit
        coEvery { preferenceDao.get(any()) } returns null
        coEvery { folderDao.getAll(any()) } returns emptyList()
        coEvery { folderDao.countByAccount(any()) } returns 0
        coEvery { folderDao.upsert(any()) } returns Unit
        coEvery { folderDao.deleteByAccount(any()) } returns Unit
        coEvery { skillDao.getBySource(any(), any()) } returns emptyList()
        coEvery { skillDao.getById(any()) } returns null
        coEvery { skillDao.upsert(any()) } returns Unit
        coEvery { skillDao.deleteBySource(any(), any()) } returns Unit
        coEvery { noteDao.getAll(any()) } returns emptyList()
        coEvery { noteDao.getById(any(), any()) } returns null
        coEvery { noteDao.upsert(any()) } returns Unit
        coEvery { noteDao.upsertWithIndex(any(), any(), any(), any(), any()) } returns Unit
        coEvery { noteDao.deleteSearchIndex(any(), any()) } returns Unit
        coEvery { noteDao.deleteByAccount(any()) } returns Unit
        coEvery { noteFolderDao.getAll(any()) } returns emptyList()
        coEvery { noteFolderDao.getById(any(), any()) } returns null
        coEvery { noteFolderDao.upsert(any()) } returns Unit
        coEvery { noteFolderDao.deleteByAccount(any()) } returns Unit

        metadataRefreshCallCount.set(0)
        backupService = createBackupService()
    }

    private fun createBackupService(
        metadataRefresh: suspend () -> Unit = { metadataRefreshCallCount.incrementAndGet() },
        runInTransaction: suspend (suspend () -> Unit) -> Unit = { transactionalBlock -> transactionalBlock() },
    ): BackupService {
        return BackupService(
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
            metadataRefresh = metadataRefresh,
            runInTransaction = runInTransaction,
        )
    }

    @After
    fun tearDown() {
        unmockkStatic(android.util.Log::class)
        filesDir.toFile().deleteRecursively()
    }

    @Test
    fun `exportBackup serializes preferences using cross-platform raw values`() = runTest {
        coEvery { providerDao.getAll(LOCAL_PARTITION_ID) } returns listOf(existingProviderEntity())
        coEvery { conversationDao.getAll(LOCAL_PARTITION_ID) } returns emptyList()
        coEvery { preferenceDao.get(AppPreferenceKeys.THEME) } returns ThemeOption.Dark.name
        coEvery { preferenceDao.get(AppPreferenceKeys.LANGUAGE) } returns LanguageOption.ChineseSimplified.name
        coEvery {
            preferenceDao.get(AppPreferenceKeys.LAST_USED_PROVIDER_ID)
        } returns "existing-provider"
        coEvery {
            preferenceDao.get(AppPreferenceKeys.LAST_USED_MODEL_ID)
        } returns "gpt-4o"

        val bytes = backupService.exportBackup()
        val backupFile = decodeBackupZip(bytes)

        assertEquals("dark", backupFile.data.preferences?.theme)
        assertEquals("chineseSimplified", backupFile.data.preferences?.language)
        assertEquals("existing-provider", backupFile.data.lastUsedModelRef?.providerID)
        assertEquals("gpt-4o", backupFile.data.lastUsedModelRef?.modelID)
    }

    @Test
    fun `exportBackup includes memory preferences and conversation memory flag`() = runTest {
        coEvery { providerDao.getAll(LOCAL_PARTITION_ID) } returns listOf(existingProviderEntity())
        coEvery { conversationDao.getAll(LOCAL_PARTITION_ID) } returns listOf(
            existingConversationEntity(useMemory = false),
        )
        coEvery { messageDao.getByConversation(any(), "conversation-1") } returns emptyList()
        coEvery { preferenceDao.get(AppPreferenceKeys.THEME) } returns ThemeOption.System.name
        coEvery { preferenceDao.get(AppPreferenceKeys.LANGUAGE) } returns LanguageOption.English.name
        coEvery {
            preferenceDao.get(AppPreferenceKeys.MEMORY_TEXT)
        } returns "I use Kotlin"
        coEvery {
            preferenceDao.get(AppPreferenceKeys.MEMORY_ANTI_FORGET_ENABLED)
        } returns "true"
        coEvery {
            preferenceDao.get(AppPreferenceKeys.MEMORY_ANTI_FORGET_TEXT)
        } returns "Prefer concise answers"
        coEvery {
            preferenceDao.get(AppPreferenceKeys.MEMORY_UPDATED_AT)
        } returns "2026-03-31T10:00:00Z"

        val backupFile = decodeBackupZip(backupService.exportBackup())

        assertEquals("I use Kotlin", backupFile.data.preferences?.memoryText)
        assertEquals(true, backupFile.data.preferences?.memoryAntiForgetEnabled)
        assertEquals("Prefer concise answers", backupFile.data.preferences?.memoryAntiForgetText)
        assertEquals("2026-03-31T10:00:00Z", backupFile.data.preferences?.memoryUpdatedAt)
        assertEquals(false, backupFile.data.conversations.single().useMemory)
    }

    @Test
    fun `exportBackup ships image bytes as zip entries and never inlines them into data json`() = runTest {
        
        
        every { attachmentStore.loadBase64(any()) } answers {
            throw AssertionError("backup must not inline image base64 into data.json")
        }
        every { attachmentStore.loadImageBytes("local-image-1") } returns "image-bytes".toByteArray()
        every { attachmentStore.loadThumbnailBytes("local-image-1") } returns "thumb-bytes".toByteArray()
        coEvery { conversationDao.getAll(LOCAL_PARTITION_ID) } returns listOf(
            existingConversationEntity(),
        )
        coEvery { messageDao.getByConversation(any(), "conversation-1") } returns listOf(
            ChatMessage(
                id = "message-with-image",
                role = ChatRole.User,
                text = "look",
                providerKind = ProviderKind.OpenAI,
                providerName = "OpenAI",
                modelID = "gpt-4o",
                modelName = "GPT-4o",
                state = ChatMessageState.Delivered,
                createdAt = 20L,
                attachments = listOf(
                    Attachment(
                        id = "attachment-1",
                        kind = AttachmentKind.Image,
                        fileName = "photo.jpg",
                        mimeType = "image/jpeg",
                        localImageId = "local-image-1",
                    ),
                ),
            ).toEntity(LOCAL_PARTITION_ID, "conversation-1", 0),
        )

        val bytes = backupService.exportBackup()

        val attachment = decodeBackupZip(bytes)
            .data.conversations.single()
            .messages.single()
            .attachments!!.single()
        assertNull(attachment.base64Data)
        
        assertEquals("local-image-1", attachment.localImageId)

        val entries = zipEntryNames(bytes)
        assertTrue(entries.contains("attachments/attachment-1.jpg"))
        assertTrue(entries.contains("attachments/attachment-1.thumb.jpg"))
    }

    @Test
    fun `exportBackupToFile streams the same archive without materializing it`() = runTest {
        every { attachmentStore.loadImageBytes("local-image-1") } returns "image-bytes".toByteArray()
        every { attachmentStore.loadThumbnailBytes("local-image-1") } returns "thumb-bytes".toByteArray()
        coEvery { conversationDao.getAll(LOCAL_PARTITION_ID) } returns listOf(
            existingConversationEntity(),
        )
        coEvery { messageDao.getByConversation(any(), "conversation-1") } returns listOf(
            messageWithImageAttachmentEntity(),
        )

        val target = filesDir.resolve("streamed-backup.oriveo").toFile()
        backupService.exportBackupToFile(target = target)

        assertTrue(target.exists())
        val bytes = target.readBytes()
        val entries = zipEntryNames(bytes)
        assertTrue(entries.contains("data.json"))
        assertTrue(entries.contains("attachments/attachment-1.jpg"))
        assertTrue(entries.contains("attachments/attachment-1.thumb.jpg"))
        assertEquals(
            "local-image-1",
            decodeBackupZip(bytes).data.conversations.single().messages.single().attachments!!.single().localImageId,
        )
    }

    @Test
    fun `exportBackupToFile reads image bytes at write time and skips ones that vanished`() = runTest {
        
        
        every { attachmentStore.loadImageBytes("local-image-1") } returnsMany listOf(
            "image-bytes".toByteArray(),
            null,
        )
        every { attachmentStore.loadThumbnailBytes("local-image-1") } returns "thumb-bytes".toByteArray()
        coEvery { conversationDao.getAll(LOCAL_PARTITION_ID) } returns listOf(
            existingConversationEntity(),
        )
        coEvery { messageDao.getByConversation(any(), "conversation-1") } returns listOf(
            messageWithImageAttachmentEntity(),
        )

        val target = filesDir.resolve("vanished-backup.oriveo").toFile()
        backupService.exportBackupToFile(target = target)

        val entries = zipEntryNames(target.readBytes())
        assertFalse(entries.contains("attachments/attachment-1.jpg"))
        
        assertTrue(entries.contains("attachments/attachment-1.thumb.jpg"))
        assertTrue(entries.contains("data.json"))
    }

    @Test
    fun `exportBackup includes folders array`() = runTest {
        coEvery { folderDao.getAll(LOCAL_PARTITION_ID) } returns listOf(
            folderEntity(id = "FOLDER-1", name = "Work", sortOrder = 1000),
            folderEntity(id = "FOLDER-2", name = "Personal", sortOrder = 2000),
        )

        val bytes = backupService.exportBackup()
        val backupFile = decodeBackupZip(bytes)

        assertEquals(2, backupFile.data.folders.size)
        assertEquals("FOLDER-1", backupFile.data.folders[0].id)
        assertEquals("Work", backupFile.data.folders[0].name)
        assertEquals("FOLDER-2", backupFile.data.folders[1].id)
    }

    @Test
    fun `exportBackup preserves relay structured configs`() = runTest {
        coEvery { providerDao.getAll(LOCAL_PARTITION_ID) } returns listOf(
            Provider(
                id = "relay-provider",
                kind = ProviderKind.Relay,
                status = ProviderConnectionState.Connected,
                models = listOf(AIModel(id = "gpt-5.4", name = "GPT-5.4", isDefault = true)),
                catalogModels = listOf(AIModel(id = "gpt-5.4", name = "GPT-5.4", isDefault = true)),
                apiKey = "",
                apiKeyPreview = "",
                baseUrlText = "https://relay.example.com/v1?base_secret=1#fragment",
                customName = "Codex Relay",
                relayRequested = RelayRequestedConfig(
                    transport = RelayTransport.OpenAIResponses,
                    authMode = RelayAuthMode.Bearer,
                    modelID = "gpt-5.4",
                    reasoningEffort = RelayReasoningEffort.XHigh,
                    serviceTier = "fast",
                    stream = true,
                    disableResponseStorage = true,
                    headers = listOf(RelayKeyValue("X-Relay", "secret")),
                    queryParams = listOf(RelayKeyValue("secondary_key", "secret")),
                    resolvedAPIBaseURL = "https://relay.example.com/gateway/v1?token=secret#fragment",
                ),
                relayImage = RelayImageConfig(
                    enabled = true,
                    mode = RelayImageMode.ToolModel,
                    toolModelID = "gpt-image-2",
                    outputFormat = RelayImageOutputFormat.Png,
                ),
            ).toEntity(LOCAL_PARTITION_ID),
        )

        val backupFile = decodeBackupZip(backupService.exportBackup())
        val provider = backupFile.data.providers.single()

        assertEquals(RelayTransport.OpenAIResponses, provider.relayRequested?.transport)
        assertEquals("fast", provider.relayRequested?.serviceTier)
        assertEquals("https://relay.example.com/v1", provider.baseURLText)
        assertNull(provider.relayRequested?.headers)
        assertNull(provider.relayRequested?.queryParams)
        assertEquals("https://relay.example.com/gateway/v1", provider.relayRequested?.resolvedAPIBaseURL)
        assertEquals(true, provider.relayImage?.enabled)
        assertEquals("gpt-image-2", provider.relayImage?.toolModelID)
    }

    @Test
    fun `exportBackup keeps conversation folderID relationship`() = runTest {
        coEvery { conversationDao.getAll(LOCAL_PARTITION_ID) } returns listOf(
            conversationEntity(id = "CONV-1", folderID = "FOLDER-9"),
        )

        val bytes = backupService.exportBackup()
        val backupFile = decodeBackupZip(bytes)

        assertEquals(1, backupFile.data.conversations.size)
        assertEquals("FOLDER-9", backupFile.data.conversations.single().folderID)
    }

    @Test
    fun `exportBackup throws when there is no local data to export`() = runTest {
        coEvery { providerDao.getAll(LOCAL_PARTITION_ID) } returns emptyList()
        coEvery { conversationDao.getAll(LOCAL_PARTITION_ID) } returns emptyList()

        try {
            backupService.exportBackup()
            error("Expected NoDataToExport")
        } catch (error: BackupError.NoDataToExport) {
            assertEquals(BackupError.NoDataToExport.message, error.message)
        }
    }

    @Test
    fun `exportBackup includes user skills and strips live knowledge identifiers`() = runTest {
        coEvery { skillDao.getBySource(LOCAL_PARTITION_ID, SkillSource.USER.value) } returns listOf(
            Skill(
                id = "skill-export-1",
                name = "Backup Skill",
                systemPrompt = "Use grounded knowledge.",
                source = SkillSource.USER,
                knowledgeBase = SkillKnowledgeBase(
                    provider = "openai",
                    retrievalModel = "gpt-5.4-mini",
                    vectorStoreId = "vs_live_123",
                    expiresAfterDays = 90,
                    files = listOf(
                        SkillKnowledgeBaseFile(
                            id = "kb-1",
                            name = "guide.pdf",
                            mimeType = "application/pdf",
                            sizeBytes = 2048,
                            ingestionMode = SkillKnowledgeIngestionMode.NATIVE_FILE,
                            openAIFileId = "file-live-1",
                            status = SkillKnowledgeFileStatus.READY,
                        ),
                    ),
                ),
            ).toEntity(LOCAL_PARTITION_ID),
        )

        val backupFile = decodeBackupZip(backupService.exportBackup())

        assertEquals(1, backupFile.data.skills.size)
        assertEquals("", backupFile.data.skills.single().knowledgeBase?.vectorStoreId)
        assertEquals(null, backupFile.data.skills.single().knowledgeBase?.files?.single()?.openAIFileId)
        assertEquals(
            SkillKnowledgeFileStatus.DISABLED,
            backupFile.data.skills.single().knowledgeBase?.files?.single()?.status,
        )
    }

    @Test
    fun `executeImport throws wrong password instead of silently skipping encrypted keys`() = runTest {
        val backupFile = BackupFile(
            version = BackupService.CURRENT_VERSION,
            createdAt = "2026-03-20T10:00:00Z",
            appVersion = "1.0.0",
            platform = "iOS",
            checksum = "",
            containsKeys = true,
            encryptedKeys = "not-base64",
            data = BackupData(),
        )

        val error = try {
            backupService.executeImport(
                mode = ImportMode.ImportNewOnly,
                password = "bad-password",
                bytes = json.encodeToString(backupFile).toByteArray(),
            )
            error("Expected WrongPassword")
        } catch (error: BackupError.WrongPassword) {
            error
        }

        assertEquals(BackupError.WrongPassword.message, error.message)
    }

    @Test
    fun `replaceAll no longer creates hidden temporary backups but still clears old keys and restores preferences`() = runTest {
        coEvery { providerDao.getAll(LOCAL_PARTITION_ID) } returns listOf(existingProviderEntity())
        coEvery { conversationDao.getAll(LOCAL_PARTITION_ID) } returns emptyList()
        coEvery { preferenceDao.get(AppPreferenceKeys.THEME) } returns ThemeOption.Light.name
        coEvery { preferenceDao.get(AppPreferenceKeys.LANGUAGE) } returns LanguageOption.English.name
        coEvery {
            preferenceDao.get(AppPreferenceKeys.LAST_USED_PROVIDER_ID)
        } returns "existing-provider"
        coEvery {
            preferenceDao.get(AppPreferenceKeys.LAST_USED_MODEL_ID)
        } returns "gpt-4o"

        val backupFile = BackupFile(
            version = BackupService.CURRENT_VERSION,
            createdAt = "2026-03-20T10:00:00Z",
            appVersion = "1.0.0",
            platform = "Web",
            checksum = "",
            containsKeys = false,
            data = BackupData(
                providers = listOf(
                    BackupProvider(
                        id = "backup-provider",
                        kind = ProviderKind.OpenAI,
                        models = listOf(AIModel(id = "gpt-5", name = "GPT-5", isDefault = true)),
                        catalogModels = listOf(AIModel(id = "gpt-5", name = "GPT-5", isDefault = true)),
                    ),
                ),
                preferences = BackupPreferences(theme = "dark", language = "japanese"),
                lastUsedModelRef = LastUsedModelRef(providerID = "backup-provider", modelID = "gpt-5"),
            ),
        )

        val result = backupService.executeImport(
            mode = ImportMode.ReplaceAll,
            bytes = json.encodeToString(backupFile).toByteArray(),
        )

        verify { secureKeyStore.deleteApiKey(any(), "existing-provider") }
        coVerify { preferenceDao.set(PreferenceEntity(AppPreferenceKeys.THEME, ThemeOption.Dark.name)) }
        coVerify { preferenceDao.set(PreferenceEntity(AppPreferenceKeys.LANGUAGE, LanguageOption.Japanese.name)) }
        coVerify {
            preferenceDao.set(
                PreferenceEntity(
                    AppPreferenceKeys.LAST_USED_PROVIDER_ID,
                    "backup-provider",
                ),
            )
        }
        coVerify {
            preferenceDao.set(
                PreferenceEntity(
                    AppPreferenceKeys.LAST_USED_MODEL_ID,
                    "gpt-5",
                ),
            )
        }
        assertTrue(result.restoredPreferences)
        assertTrue(result.restoredLastUsedModel)

        val tempBackupsDir = filesDir.resolve("temp-backups/${LOCAL_PARTITION_ID}").toFile()
        assertFalse(tempBackupsDir.exists())
    }

    @Test
    fun `replaceAll aborts explicit target import when live account already changed`() = runTest {
        val targetAccountId = "user-a"
        val otherAccountId = "user-b"
        accountIdFlow.value = otherAccountId
        coEvery { providerDao.getAll(targetAccountId) } returns emptyList()
        coEvery { conversationDao.getAll(targetAccountId) } returns emptyList()

        val backupFile = BackupFile(
            version = BackupService.CURRENT_VERSION,
            createdAt = "2026-03-20T10:00:00Z",
            appVersion = "1.0.0",
            platform = "Web",
            checksum = "",
            containsKeys = false,
            data = BackupData(),
        )

        try {
            backupService.executeImport(
                mode = ImportMode.ReplaceAll,
                bytes = json.encodeToString(backupFile).toByteArray(),
                targetAccountIdOverride = targetAccountId,
            )
            error("Expected AccountChanged")
        } catch (error: BackupError.AccountChanged) {
            assertEquals(BackupError.AccountChanged.message, error.message)
        }

        coVerify(exactly = 0) { conversationDao.deleteByAccount(targetAccountId) }
        coVerify(exactly = 0) { providerDao.deleteByAccount(targetAccountId) }
        coVerify(exactly = 0) { conversationDao.deleteByAccount(otherAccountId) }
        coVerify(exactly = 0) { providerDao.deleteByAccount(otherAccountId) }
    }

    @Test
    fun `replaceAll restores a matching local key as unverified`() = runTest {
        val existingProvider = Provider(
            id = "cloud-provider",
            kind = ProviderKind.Relay,
            status = ProviderConnectionState.Connected,
            models = listOf(AIModel(id = "relay-model", name = "Relay Model", isDefault = true)),
            catalogModels = listOf(AIModel(id = "relay-model", name = "Relay Model", isDefault = true)),
            lastCheckedAt = null,
            apiKey = "",
            apiKeyPreview = "sk-***1234",
            lastError = null,
            baseUrlText = "https://relay.example/v1",
            customName = null,
            updatedAt = 0L,
        ).toEntity(LOCAL_PARTITION_ID)
        coEvery { providerDao.getAll(LOCAL_PARTITION_ID) } returns listOf(existingProvider)
        coEvery { conversationDao.getAll(LOCAL_PARTITION_ID) } returns emptyList()
        every { secureKeyStore.getApiKey(any(), "cloud-provider") } returns "sk-existing-provider"

        val backupFile = BackupFile(
            version = BackupService.CURRENT_VERSION,
            createdAt = "2026-03-20T10:00:00Z",
            appVersion = "1.0.0",
            platform = "Web",
            checksum = "",
            containsKeys = false,
            data = BackupData(
                providers = listOf(
                    BackupProvider(
                        id = "cloud-provider",
                        kind = ProviderKind.Relay,
                        models = listOf(AIModel(id = "relay-model", name = "Relay Model", isDefault = true)),
                        catalogModels = listOf(AIModel(id = "relay-model", name = "Relay Model", isDefault = true)),
                        baseURLText = "https://relay.example/v1",
                        relayRequested = RelayRequestedConfig(authMode = RelayAuthMode.Bearer),
                    ),
                ),
            ),
        )

        backupService.executeImport(
            mode = ImportMode.ReplaceAll,
            bytes = json.encodeToString(backupFile).toByteArray(),
        )

        verify(exactly = 0) { secureKeyStore.deleteApiKey(any(), "cloud-provider") }
        verify { secureKeyStore.saveApiKey(any(), "cloud-provider", "sk-existing-provider") }
        coVerify {
            providerDao.upsert(
                match {
                    it.id == "cloud-provider" &&
                        it.apiKeyPreview == "sk-***1234" &&
                        it.status.contains("issue", ignoreCase = true) &&
                        it.lastCheckedAt == null
                },
            )
        }
    }

    @Test
    fun `replaceAll does not copy local key to same kind provider with different id`() = runTest {
        val existingProvider = Provider(
            id = "existing-provider",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = listOf(AIModel(id = "gpt-4o", name = "GPT-4o", isDefault = true)),
            catalogModels = emptyList(),
            apiKeyPreview = "sk-***1234",
            baseUrlText = ProviderKind.OpenAI.defaultBaseUrl,
        ).toEntity(LOCAL_PARTITION_ID)
        coEvery { providerDao.getAll(LOCAL_PARTITION_ID) } returns listOf(existingProvider)
        every { secureKeyStore.getApiKey(any(), "existing-provider") } returns "sk-existing-provider"

        val backupFile = BackupFile(
            version = BackupService.CURRENT_VERSION,
            createdAt = "2026-03-20T10:00:00Z",
            appVersion = "1.0.0",
            platform = "Web",
            checksum = "",
            containsKeys = false,
            data = BackupData(
                providers = listOf(
                    BackupProvider(
                        id = "cloud-provider",
                        kind = ProviderKind.OpenAI,
                        models = listOf(AIModel(id = "gpt-5", name = "GPT-5", isDefault = true)),
                    ),
                ),
            ),
        )

        backupService.executeImport(
            mode = ImportMode.ReplaceAll,
            bytes = json.encodeToString(backupFile).toByteArray(),
        )

        verify(exactly = 0) { secureKeyStore.saveApiKey(any(), "cloud-provider", "sk-existing-provider") }
        coVerify {
            providerDao.upsert(
                match {
                    it.id == "cloud-provider" &&
                        it.status.contains("issue", ignoreCase = true)
                },
            )
        }
    }

    @Test
    fun `replaceAll does not delete preserved provider key before import succeeds`() = runTest {
        val existingProvider = Provider(
            id = "existing-provider",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = listOf(AIModel(id = "gpt-4o", name = "GPT-4o", isDefault = true)),
            catalogModels = emptyList(),
            lastCheckedAt = null,
            apiKey = "",
            apiKeyPreview = "sk-***1234",
            lastError = null,
            baseUrlText = ProviderKind.OpenAI.defaultBaseUrl,
            customName = null,
            updatedAt = 0L,
        ).toEntity(LOCAL_PARTITION_ID)
        coEvery { providerDao.getAll(LOCAL_PARTITION_ID) } returns listOf(existingProvider)
        coEvery { conversationDao.getAll(LOCAL_PARTITION_ID) } returns emptyList()
        every { secureKeyStore.getApiKey(any(), "existing-provider") } returns "sk-existing-provider"
        coEvery { providerDao.upsert(any()) } throws IllegalStateException("boom")

        val backupFile = BackupFile(
            version = BackupService.CURRENT_VERSION,
            createdAt = "2026-03-20T10:00:00Z",
            appVersion = "1.0.0",
            platform = "Web",
            checksum = "",
            containsKeys = false,
            data = BackupData(
                providers = listOf(
                    BackupProvider(
                        id = "cloud-provider",
                        kind = ProviderKind.OpenAI,
                        models = listOf(AIModel(id = "gpt-5", name = "GPT-5", isDefault = true)),
                        catalogModels = emptyList(),
                    ),
                ),
            ),
        )

        val error = runCatching {
            backupService.executeImport(
                mode = ImportMode.ReplaceAll,
                bytes = json.encodeToString(backupFile).toByteArray(),
            )
        }.exceptionOrNull()

        assertTrue(error is IllegalStateException)
        verify(exactly = 0) { secureKeyStore.deleteApiKey(any(), "existing-provider") }
    }

    @Test
    fun `executeImport restores relay structured configs`() = runTest {
        val capturedProviders = mutableListOf<ai.oriveo.community.core.data.entity.ProviderEntity>()
        coEvery { providerDao.upsert(capture(capturedProviders)) } returns Unit

        val backupFile = BackupFile(
            version = BackupService.CURRENT_VERSION,
            createdAt = "2026-04-23T10:00:00Z",
            appVersion = "1.0.0",
            platform = "Web",
            checksum = "",
            containsKeys = false,
            data = BackupData(
                providers = listOf(
                    BackupProvider(
                        id = "relay-provider",
                        kind = ProviderKind.Relay,
                        baseURLText = "https://relay.example.com/v1",
                        customName = "Codex Relay",
                        models = listOf(AIModel(id = "gpt-5.4", name = "GPT-5.4", isDefault = true)),
                        catalogModels = listOf(AIModel(id = "gpt-5.4", name = "GPT-5.4", isDefault = true)),
                        relayRequested = RelayRequestedConfig(
                            transport = RelayTransport.OpenAIResponses,
                            authMode = RelayAuthMode.Bearer,
                            modelID = "gpt-5.4",
                            reasoningEffort = RelayReasoningEffort.XHigh,
                            serviceTier = "fast",
                            stream = true,
                            disableResponseStorage = true,
                        ),
                        relayImage = RelayImageConfig(
                            enabled = true,
                            mode = RelayImageMode.ToolModel,
                            toolModelID = "gpt-image-2",
                            outputFormat = RelayImageOutputFormat.Png,
                        ),
                    ),
                ),
            ),
        )

        val result = backupService.executeImport(
            mode = ImportMode.ImportNewOnly,
            bytes = json.encodeToString(backupFile).toByteArray(),
        )

        assertEquals(1, result.newProviders)
        val restored = with(EntityMapper) { capturedProviders.single().toDomain() }
        assertEquals(RelayTransport.OpenAIResponses, restored.relayRequested?.transport)
        assertEquals(RelayReasoningEffort.XHigh, restored.relayRequested?.reasoningEffort)
        assertEquals("gpt-image-2", restored.relayImage?.toolModelID)
    }

    @Test
    fun `merge existing Relay provider restores structured configs`() = runTest {
        val capturedProviders = mutableListOf<ai.oriveo.community.core.data.entity.ProviderEntity>()
        val existingProvider = Provider(
            id = "relay-provider",
            kind = ProviderKind.Relay,
            status = ProviderConnectionState.Connected,
            models = listOf(AIModel(id = "old-model", name = "Old model", isDefault = true)),
            catalogModels = listOf(AIModel(id = "old-model", name = "Old model", isDefault = true)),
            apiKeyPreview = "sk-...old",
            baseUrlText = "https://old-relay.example.com/v1",
            customName = "Old Relay",
            relayKind = RelayKind.OpenAICompatible,
            relayRequested = RelayRequestedConfig(
                transport = RelayTransport.OpenAIChatCompletions,
                modelID = "old-model",
            ),
        ).toEntity(LOCAL_PARTITION_ID)
        coEvery { providerDao.getAll(LOCAL_PARTITION_ID) } returns listOf(existingProvider)
        coEvery { providerDao.upsert(capture(capturedProviders)) } returns Unit

        val backupFile = BackupFile(
            version = BackupService.CURRENT_VERSION,
            createdAt = "2026-04-23T10:00:00Z",
            appVersion = "1.0.0",
            platform = "Web",
            checksum = "",
            containsKeys = false,
            data = BackupData(
                providers = listOf(
                    BackupProvider(
                        id = "relay-provider",
                        kind = ProviderKind.Relay,
                        baseURLText = "https://relay.example.com/v1",
                        customName = "Codex Relay",
                        models = listOf(AIModel(id = "gpt-5.4", name = "GPT-5.4", isDefault = true)),
                        catalogModels = listOf(
                            AIModel(id = "gpt-5.4", name = "GPT-5.4", isDefault = true),
                            AIModel(id = "gpt-image-2", name = "GPT Image 2"),
                        ),
                        relayKind = RelayKind.CodexStyle,
                        relayRequested = RelayRequestedConfig(
                            transport = RelayTransport.OpenAIResponses,
                            authMode = RelayAuthMode.Bearer,
                            modelID = "gpt-5.4",
                            reasoningEffort = RelayReasoningEffort.XHigh,
                            serviceTier = "fast",
                            stream = true,
                            disableResponseStorage = true,
                            headers = listOf(RelayKeyValue("X-Relay", "1")),
                            codexCompatIdentity = false,
                            customUserAgent = "Custom UA",
                        ),
                        relayImage = RelayImageConfig(
                            enabled = true,
                            mode = RelayImageMode.ToolModel,
                            toolModelID = "gpt-image-2",
                            outputFormat = RelayImageOutputFormat.Png,
                        ),
                    ),
                ),
            ),
        )

        val result = backupService.executeImport(
            mode = ImportMode.Merge,
            bytes = json.encodeToString(backupFile).toByteArray(),
        )

        assertEquals(1, result.skippedProviders)
        val restored = with(EntityMapper) { capturedProviders.single().toDomain() }
        assertEquals(RelayKind.CodexStyle, restored.relayKind)
        assertEquals(RelayTransport.OpenAIResponses, restored.relayRequested?.transport)
        assertEquals(false, restored.relayRequested?.codexCompatIdentity)
        assertEquals("Custom UA", restored.relayRequested?.customUserAgent)
        assertEquals("gpt-image-2", restored.relayImage?.toolModelID)
        assertTrue(restored.catalogModels.any { it.id == "gpt-image-2" })
    }

    @Test
    fun `merge imports official provider with same kind and different id as a new instance`() = runTest {
        val capturedProviders = mutableListOf<ai.oriveo.community.core.data.entity.ProviderEntity>()
        val existingProvider = Provider(
            id = "11111111-1111-4111-8111-111111111111",
            kind = ProviderKind.OpenRouter,
            status = ProviderConnectionState.Connected,
            models = listOf(AIModel(id = "openai/gpt-4o", name = "GPT-4o", isDefault = true)),
            customName = "OpenRouter",
        ).toEntity(LOCAL_PARTITION_ID)
        coEvery { providerDao.getAll(LOCAL_PARTITION_ID) } returns listOf(existingProvider)
        coEvery { providerDao.upsert(capture(capturedProviders)) } returns Unit

        val backupFile = BackupFile(
            version = BackupService.CURRENT_VERSION,
            createdAt = "2026-04-23T10:00:00Z",
            appVersion = "1.0.0",
            platform = "Web",
            checksum = "",
            containsKeys = false,
            data = BackupData(
                providers = listOf(
                    BackupProvider(
                        id = "22222222-2222-4222-8222-222222222222",
                        kind = ProviderKind.OpenRouter,
                        customName = "OpenRouter 2",
                        models = listOf(AIModel(id = "anthropic/claude-sonnet-4", name = "Claude Sonnet 4", isDefault = true)),
                    ),
                ),
            ),
        )

        val result = backupService.executeImport(
            mode = ImportMode.Merge,
            bytes = json.encodeToString(backupFile).toByteArray(),
        )

        assertEquals(1, result.newProviders)
        assertEquals(0, result.skippedProviders)
        val restored = with(EntityMapper) { capturedProviders.single().toDomain() }
        assertEquals("22222222-2222-4222-8222-222222222222", restored.id)
        assertEquals("OpenRouter 2", restored.customName)
    }

    @Test
    fun `replaceAll deletes only current account attachments instead of clearing global store`() = runTest {
        val attachmentsJson = json.encodeToString(
            ListSerializer(Attachment.serializer()),
            listOf(
                Attachment(
                    id = "attachment-1",
                    kind = AttachmentKind.Image,
                    fileName = "photo.jpg",
                    mimeType = "image/jpeg",
                    localImageId = "local-image-1",
                ),
            ),
        )
        coEvery {
            conversationDao.getAll(LOCAL_PARTITION_ID)
        } returns listOf(
            ConversationEntity(
                id = "conversation-1",
                title = "Chat",
                hasCustomTitle = false,
                providerID = "provider-1",
                providerKind = ProviderKind.OpenAI.name,
                modelID = "gpt-4o",
                useMemory = true,
                previewText = "",
                estimatedCost = 0.0,
                isDraft = false,
                draftText = "",
                createdAt = 10L,
                updatedAt = 20L,
                folderID = null,
                skillId = null,
                accountId = LOCAL_PARTITION_ID,
            ),
        )
        coEvery { messageDao.getByConversation(any(), "conversation-1") } returns listOf(
            MessageEntity(
                id = "message-1",
                conversationId = "conversation-1",
                role = "User",
                text = "hello",
                providerID = null,
                providerKind = ProviderKind.OpenAI.name,
                providerName = ProviderKind.OpenAI.displayName,
                modelID = "gpt-4o",
                modelName = "GPT-4o",
                servedModelID = null,
                estimatedCost = 0.0,
                state = "Delivered",
                errorTitle = null,
                errorDetail = null,
                attachmentsJson = attachmentsJson,
                createdAt = 10L,
                sortOrder = 0,
            ),
        )

        val backupFile = BackupFile(
            version = BackupService.CURRENT_VERSION,
            createdAt = "2026-03-20T10:00:00Z",
            appVersion = "1.0.0",
            platform = "Web",
            checksum = "",
            containsKeys = false,
            data = BackupData(),
        )

        backupService.executeImport(
            mode = ImportMode.ReplaceAll,
            bytes = json.encodeToString(backupFile).toByteArray(),
        )

        verify { attachmentStore.delete("local-image-1") }
        coVerify(exactly = 0) { attachmentStore.clearAll() }
    }

    @Test
    fun `replaceAll preserves local user skills when explicitly requested`() = runTest {
        val capturedSkills = mutableListOf<ai.oriveo.community.core.data.entity.SkillEntity>()
        coEvery { providerDao.getAll(LOCAL_PARTITION_ID) } returns emptyList()
        coEvery { conversationDao.getAll(LOCAL_PARTITION_ID) } returns emptyList()
        coEvery { skillDao.upsert(capture(capturedSkills)) } returns Unit

        val backupFile = BackupFile(
            version = BackupService.CURRENT_VERSION,
            createdAt = "2026-04-19T10:00:00Z",
            appVersion = "1.0.0",
            platform = "Web",
            checksum = "",
            containsKeys = false,
            data = BackupData(
                skills = listOf(
                    Skill(
                        id = "backup-skill-1",
                        name = "Imported Skill",
                        systemPrompt = "Use the imported instructions.",
                        source = SkillSource.USER,
                    ),
                ),
            ),
        )

        val result = backupService.executeImport(
            mode = ImportMode.ReplaceAll,
            bytes = json.encodeToString(backupFile).toByteArray(),
            preserveUserSkillsOnReplaceAll = true,
        )

        assertEquals(1, result.newSkills)
        assertEquals(listOf("backup-skill-1"), capturedSkills.map { it.id })
        coVerify(exactly = 0) { skillDao.deleteBySource(LOCAL_PARTITION_ID, SkillSource.USER.value) }
    }

    @Test
    fun `replaceAll keeps original local state when import fails after destructive phase`() = runTest {
        val attachmentsJson = json.encodeToString(
            ListSerializer(Attachment.serializer()),
            listOf(
                Attachment(
                    id = "attachment-1",
                    kind = AttachmentKind.Image,
                    fileName = "photo.jpg",
                    mimeType = "image/jpeg",
                    localImageId = "local-image-1",
                ),
            ),
        )
        val providerState = mutableListOf(existingProviderEntity())
        val folderState = mutableListOf(folderEntity(id = "FOLDER-1", name = "Work", sortOrder = 1000))
        val conversationState = mutableListOf(conversationEntity(id = "conversation-1", folderID = "FOLDER-1"))

        coEvery { providerDao.getAll(LOCAL_PARTITION_ID) } answers { providerState.toList() }
        coEvery { folderDao.getAll(LOCAL_PARTITION_ID) } answers { folderState.toList() }
        coEvery { conversationDao.getAll(LOCAL_PARTITION_ID) } answers { conversationState.toList() }
        coEvery { messageDao.getByConversation(any(), "conversation-1") } returns listOf(
            MessageEntity(
                id = "message-1",
                conversationId = "conversation-1",
                role = "User",
                text = "hello",
                providerID = null,
                providerKind = ProviderKind.OpenAI.name,
                providerName = ProviderKind.OpenAI.displayName,
                modelID = "gpt-4o",
                modelName = "GPT-4o",
                servedModelID = null,
                estimatedCost = 0.0,
                state = "Delivered",
                errorTitle = null,
                errorDetail = null,
                attachmentsJson = attachmentsJson,
                createdAt = 10L,
                sortOrder = 0,
            ),
        )
        coEvery { providerDao.deleteByAccount(LOCAL_PARTITION_ID) } answers { providerState.clear() }
        coEvery { folderDao.deleteByAccount(LOCAL_PARTITION_ID) } answers { folderState.clear() }
        coEvery { conversationDao.deleteByAccount(LOCAL_PARTITION_ID) } answers { conversationState.clear() }
        coEvery { providerDao.upsert(any()) } throws IllegalStateException("boom")
        val transactionalService = createBackupService(
            runInTransaction = { block ->
                val providerSnapshot = providerState.toList()
                val folderSnapshot = folderState.toList()
                val conversationSnapshot = conversationState.toList()
                try {
                    block()
                } catch (error: Throwable) {
                    providerState.clear()
                    providerState.addAll(providerSnapshot)
                    folderState.clear()
                    folderState.addAll(folderSnapshot)
                    conversationState.clear()
                    conversationState.addAll(conversationSnapshot)
                    throw error
                }
            },
        )

        val backupFile = BackupFile(
            version = BackupService.CURRENT_VERSION,
            createdAt = "2026-04-19T10:00:00Z",
            appVersion = "1.0.0",
            platform = "Web",
            checksum = "",
            containsKeys = false,
            data = BackupData(
                providers = listOf(
                    BackupProvider(
                        id = "cloud-provider",
                        kind = ProviderKind.OpenAI,
                        models = listOf(AIModel(id = "gpt-5", name = "GPT-5", isDefault = true)),
                    ),
                ),
            ),
        )

        val error = runCatching {
            transactionalService.executeImport(
                mode = ImportMode.ReplaceAll,
                bytes = json.encodeToString(backupFile).toByteArray(),
            )
        }.exceptionOrNull()

        assertTrue(error is IllegalStateException)
        assertEquals(listOf("existing-provider"), providerState.map { it.id })
        assertEquals(listOf("FOLDER-1"), folderState.map { it.id })
        assertEquals(listOf("conversation-1"), conversationState.map { it.id })
        verify(exactly = 0) { attachmentStore.delete("local-image-1") }
    }

    @Test
    fun `replaceAll does not delete restored attachments that reuse the same local image id`() = runTest {
        val attachmentsJson = json.encodeToString(
            ListSerializer(Attachment.serializer()),
            listOf(
                Attachment(
                    id = "attachment-1",
                    kind = AttachmentKind.Image,
                    fileName = "photo.jpg",
                    mimeType = "image/jpeg",
                    localImageId = "local-image-1",
                ),
            ),
        )

        coEvery { conversationDao.getAll(LOCAL_PARTITION_ID) } returns listOf(
            ConversationEntity(
                id = "conversation-1",
                title = "Chat",
                hasCustomTitle = false,
                providerID = "provider-1",
                providerKind = ProviderKind.OpenAI.name,
                modelID = "gpt-4o",
                useMemory = true,
                previewText = "",
                estimatedCost = 0.0,
                isDraft = false,
                draftText = "",
                createdAt = 10L,
                updatedAt = 20L,
                folderID = null,
                skillId = null,
                accountId = LOCAL_PARTITION_ID,
            ),
        )
        coEvery { messageDao.getByConversation(any(), "conversation-1") } returns listOf(
            MessageEntity(
                id = "message-1",
                conversationId = "conversation-1",
                role = "User",
                text = "hello",
                providerID = null,
                providerKind = ProviderKind.OpenAI.name,
                providerName = ProviderKind.OpenAI.displayName,
                modelID = "gpt-4o",
                modelName = "GPT-4o",
                servedModelID = null,
                estimatedCost = 0.0,
                state = "Delivered",
                errorTitle = null,
                errorDetail = null,
                attachmentsJson = attachmentsJson,
                createdAt = 10L,
                sortOrder = 0,
            ),
        )
        coEvery { messageDao.upsert(any()) } returns Unit

        val backupFile = BackupFile(
            version = BackupService.CURRENT_VERSION,
            createdAt = "2026-04-19T10:00:00Z",
            appVersion = "1.0.0",
            platform = "Web",
            checksum = "",
            containsKeys = false,
            data = BackupData(
                conversations = listOf(
                    BackupConversation(
                        id = "conversation-2",
                        title = "Imported chat",
                        providerID = "provider-1",
                        providerKind = ProviderKind.OpenAI,
                        modelID = "gpt-4o",
                        messages = listOf(
                            ChatMessage(
                                id = "message-2",
                                role = ChatRole.User,
                                text = "imported",
                                providerID = "provider-1",
                                providerKind = ProviderKind.OpenAI,
                                providerName = ProviderKind.OpenAI.displayName,
                                modelID = "gpt-4o",
                                modelName = "GPT-4o",
                                state = ChatMessageState.Delivered,
                                attachments = listOf(
                                    Attachment(
                                        id = "attachment-2",
                                        kind = AttachmentKind.Image,
                                        fileName = "photo.jpg",
                                        mimeType = "image/jpeg",
                                        localImageId = "local-image-1",
                                    ),
                                ),
                                createdAt = 20L,
                            ),
                        ),
                        createdAt = 20L,
                        updatedAt = 20L,
                    ),
                ),
            ),
        )

        backupService.executeImport(
            mode = ImportMode.ReplaceAll,
            bytes = json.encodeToString(backupFile).toByteArray(),
        )

        verify(exactly = 0) { attachmentStore.delete("local-image-1") }
    }

    @Test
    fun `executeImport restores memory preferences and conversation useMemory`() = runTest {
        val importedConversations = mutableListOf<ConversationEntity>()
        coEvery { providerDao.getAll(LOCAL_PARTITION_ID) } returns emptyList()
        coEvery { conversationDao.getAll(LOCAL_PARTITION_ID) } returns emptyList()
        coEvery { conversationDao.upsert(capture(importedConversations)) } returns Unit

        val backupFile = BackupFile(
            version = BackupService.CURRENT_VERSION,
            createdAt = "2026-03-20T10:00:00Z",
            appVersion = "1.0.0",
            platform = "Web",
            checksum = "",
            containsKeys = false,
            data = BackupData(
                providers = listOf(
                    BackupProvider(
                        id = "backup-provider",
                        kind = ProviderKind.OpenAI,
                        models = listOf(AIModel(id = "gpt-5", name = "GPT-5", isDefault = true)),
                        catalogModels = listOf(AIModel(id = "gpt-5", name = "GPT-5", isDefault = true)),
                    ),
                ),
                conversations = listOf(
                    BackupConversation(
                        id = "conversation-1",
                        title = "Imported conversation",
                        providerID = "backup-provider",
                        providerKind = ProviderKind.OpenAI,
                        modelID = "gpt-5",
                        useMemory = false,
                    ),
                ),
                preferences = BackupPreferences(
                    theme = "dark",
                    language = "japanese",
                    memoryText = "I use Kotlin",
                    memoryAntiForgetEnabled = true,
                    memoryAntiForgetText = "Prefer concise answers",
                    memoryUpdatedAt = "2026-03-31T10:00:00Z",
                ),
            ),
        )

        val result = backupService.executeImport(
            mode = ImportMode.ImportNewOnly,
            bytes = json.encodeToString(backupFile).toByteArray(),
        )

        coVerify {
            preferenceDao.set(
                PreferenceEntity(
                    AppPreferenceKeys.MEMORY_TEXT,
                    "I use Kotlin",
                ),
            )
        }
        coVerify {
            preferenceDao.set(
                PreferenceEntity(
                    AppPreferenceKeys.MEMORY_ANTI_FORGET_ENABLED,
                    "true",
                ),
            )
        }
        coVerify {
            preferenceDao.set(
                PreferenceEntity(
                    AppPreferenceKeys.MEMORY_ANTI_FORGET_TEXT,
                    "Prefer concise answers",
                ),
            )
        }
        coVerify {
            preferenceDao.set(
                PreferenceEntity(
                    AppPreferenceKeys.MEMORY_UPDATED_AT,
                    "2026-03-31T10:00:00Z",
                ),
            )
        }
        assertEquals(false, importedConversations.single().useMemory)
        assertTrue(result.restoredMemory)
    }

    @Test
    fun `import restores folders and conversation folderID relationship`() = runTest {
        val backupFile = BackupFile(
            version = BackupService.CURRENT_VERSION,
            createdAt = "2026-03-20T10:00:00Z",
            appVersion = "1.0.0",
            platform = "Web",
            checksum = "",
            containsKeys = false,
            data = BackupData(
                folders = listOf(
                    BackupFolder(
                        id = "FOLDER-1",
                        name = "Work",
                        sortOrder = 1000,
                        createdAt = 100L,
                        updatedAt = 200L,
                    ),
                ),
                conversations = listOf(
                    BackupConversation(
                        id = "CONV-1",
                        title = "Folder chat",
                        providerID = "provider-1",
                        providerKind = ProviderKind.OpenAI,
                        modelID = "gpt-4o",
                        folderID = "FOLDER-1",
                        createdAt = 250L,
                        updatedAt = 300L,
                    ),
                ),
            ),
        )

        backupService.executeImport(
            mode = ImportMode.ImportNewOnly,
            bytes = json.encodeToString(backupFile).toByteArray(),
        )

        coVerify {
            folderDao.upsert(
                match {
                    it.id == "FOLDER-1" && it.name == "Work" && it.accountId == LOCAL_PARTITION_ID
                },
            )
        }
        coVerify {
            conversationDao.upsert(
                match {
                    it.id == "CONV-1" &&
                        it.folderID == "FOLDER-1" &&
                        it.createdAt == 250L &&
                        it.accountId == LOCAL_PARTITION_ID
                },
            )
        }
    }

    @Test
    fun `import old backup without folders field remains backward compatible`() = runTest {
        val oldBackupJson = """
            {
              "version": 1,
              "createdAt": "2026-03-20T10:00:00Z",
              "appVersion": "1.0.0",
              "platform": "Web",
              "checksum": "",
              "containsKeys": false,
              "data": {
                "providers": [],
                "conversations": []
              }
            }
        """.trimIndent()

        val result = backupService.executeImport(
            mode = ImportMode.ImportNewOnly,
            bytes = oldBackupJson.toByteArray(),
        )

        assertEquals(0, result.newConversations)
        assertEquals(0, result.newProviders)
        coVerify(exactly = 0) { folderDao.upsert(any()) }
    }

    @Test
    fun `executeImport counts imported notes and note folders`() = runTest {
        val backupFile = BackupFile(
            version = BackupService.CURRENT_VERSION,
            createdAt = "2026-06-26T00:00:00Z",
            appVersion = "1.0.0",
            platform = "Web",
            checksum = "",
            containsKeys = false,
            data = BackupData(
                noteFolders = listOf(
                    BackupNoteFolder(
                        id = "FOLDER-1",
                        name = "Research",
                        sortOrder = 1000,
                        createdAt = "2026-06-25T00:00:00Z",
                        updatedAt = "2026-06-25T00:00:00Z",
                    ),
                ),
                notes = listOf(
                    BackupNote(
                        id = "NOTE-1",
                        title = "Imported note",
                        titleSource = "manual",
                        body = "Body",
                        noteFolderID = "FOLDER-1",
                        captureKind = "blank",
                        createdAt = "2026-06-25T00:00:00Z",
                        updatedAt = "2026-06-25T00:00:00Z",
                    ),
                ),
            ),
        )

        val result = backupService.executeImport(
            mode = ImportMode.ImportNewOnly,
            bytes = json.encodeToString(backupFile).toByteArray(),
        )

        assertEquals(1, result.newNoteFolders)
        assertEquals(1, result.newNotes)
        assertTrue(result.hasChanges)
        coVerify { noteFolderDao.upsert(match { it.id == "FOLDER-1" && it.accountId == LOCAL_PARTITION_ID }) }
        coVerify {
            noteDao.upsertWithIndex(
                match { it.id == "NOTE-1" && it.noteFolderID == "FOLDER-1" },
                any(),
                any(),
                any(),
                any(),
            )
        }
    }

    @Test
    fun `importNew skips deleted note folders and clears imported note folder reference`() = runTest {
        val deletedFolder = backupNoteFolder(
            id = "FOLDER-DELETED",
            deletedAt = "2026-06-26T01:00:00Z",
        )
        val backupFile = BackupFile(
            version = BackupService.CURRENT_VERSION,
            createdAt = "2026-06-26T00:00:00Z",
            appVersion = "1.0.0",
            platform = "Web",
            checksum = "",
            containsKeys = false,
            data = BackupData(
                noteFolders = listOf(deletedFolder),
                notes = listOf(backupNote(id = "NOTE-ORPHAN", noteFolderID = deletedFolder.id)),
            ),
        )

        val result = backupService.executeImport(
            mode = ImportMode.ImportNewOnly,
            bytes = json.encodeToString(backupFile).toByteArray(),
        )

        assertEquals(0, result.newNoteFolders)
        assertEquals(1, result.skippedNoteFolders)
        assertEquals(1, result.newNotes)
        coVerify(exactly = 0) { noteFolderDao.upsert(match { it.id == deletedFolder.id }) }
        coVerify {
            noteDao.upsertWithIndex(
                match { it.id == "NOTE-ORPHAN" && it.noteFolderID == null },
                any(),
                any(),
                any(),
                any(),
            )
        }
    }

    @Test
    fun `merge newer note folder tombstone clears local note folder references`() = runTest {
        val folderId = "FOLDER-MERGE-DELETED"
        coEvery { noteFolderDao.getAll(LOCAL_PARTITION_ID) } returns listOf(
            noteFolder(id = folderId).toEntity(LOCAL_PARTITION_ID),
        )
        coEvery { noteDao.getAll(LOCAL_PARTITION_ID) } returns listOf(
            note(id = "NOTE-LOCAL", noteFolderID = folderId).toEntity(LOCAL_PARTITION_ID),
        )

        val backupFile = BackupFile(
            version = BackupService.CURRENT_VERSION,
            createdAt = "2026-06-26T00:00:00Z",
            appVersion = "1.0.0",
            platform = "Web",
            checksum = "",
            containsKeys = false,
            data = BackupData(
                noteFolders = listOf(
                    backupNoteFolder(
                        id = folderId,
                        updatedAt = "2026-06-27T00:00:00Z",
                        deletedAt = "2026-06-27T00:00:00Z",
                    ),
                ),
            ),
        )

        val result = backupService.executeImport(
            mode = ImportMode.Merge,
            bytes = json.encodeToString(backupFile).toByteArray(),
        )

        assertEquals(1, result.mergedNoteFolders)
        coVerify { noteDao.clearNoteFolder(LOCAL_PARTITION_ID, folderId, any()) }
    }

    @Test
    fun merge_noteTie_keepsLocal() = runTest {
        
        
        coEvery { noteDao.getAll(LOCAL_PARTITION_ID) } returns listOf(
            note(id = "NOTE-TIE", body = "local-content").toEntity(LOCAL_PARTITION_ID),
        )

        val backupFile = BackupFile(
            version = BackupService.CURRENT_VERSION,
            createdAt = "2026-06-26T00:00:00Z",
            appVersion = "1.0.0",
            platform = "Web",
            checksum = "",
            containsKeys = false,
            data = BackupData(
                notes = listOf(
                    backupNote(id = "NOTE-TIE", body = "backup-content"),
                ),
            ),
        )

        val result = backupService.executeImport(
            mode = ImportMode.Merge,
            bytes = json.encodeToString(backupFile).toByteArray(),
        )

        
        assertEquals(0, result.mergedNotes)
        assertEquals(1, result.skippedNotes)
        coVerify(exactly = 0) { noteDao.upsertWithIndex(any(), any(), any(), any(), any()) }
        
        coVerify(exactly = 0) { noteDao.upsertWithIndex(match { it.body == "backup-content" }, any(), any(), any(), any()) }
    }

    @Test
    fun merge_noteFolderTie_keepsLocal() = runTest {
        
        
        coEvery { noteFolderDao.getAll(LOCAL_PARTITION_ID) } returns listOf(
            noteFolder(id = "FOLDER-TIE", name = "local-name").toEntity(LOCAL_PARTITION_ID),
        )

        val backupFile = BackupFile(
            version = BackupService.CURRENT_VERSION,
            createdAt = "2026-06-26T00:00:00Z",
            appVersion = "1.0.0",
            platform = "Web",
            checksum = "",
            containsKeys = false,
            data = BackupData(
                noteFolders = listOf(
                    backupNoteFolder(id = "FOLDER-TIE", name = "backup-name"),
                ),
            ),
        )

        val result = backupService.executeImport(
            mode = ImportMode.Merge,
            bytes = json.encodeToString(backupFile).toByteArray(),
        )

        
        assertEquals(0, result.mergedNoteFolders)
        assertEquals(1, result.skippedNoteFolders)
        coVerify(exactly = 0) { noteFolderDao.upsert(any()) }
        
        coVerify(exactly = 0) { noteFolderDao.upsert(match { it.name == "backup-name" }) }
    }

    @Test
    fun `replaceAll skips deleted note folders and clears imported note folder reference`() = runTest {
        val deletedFolder = backupNoteFolder(
            id = "FOLDER-REPLACE-DELETED",
            deletedAt = "2026-06-26T01:00:00Z",
        )
        val backupFile = BackupFile(
            version = BackupService.CURRENT_VERSION,
            createdAt = "2026-06-26T00:00:00Z",
            appVersion = "1.0.0",
            platform = "Web",
            checksum = "",
            containsKeys = false,
            data = BackupData(
                noteFolders = listOf(deletedFolder),
                notes = listOf(backupNote(id = "NOTE-REPLACE-ORPHAN", noteFolderID = deletedFolder.id)),
            ),
        )

        val result = backupService.executeImport(
            mode = ImportMode.ReplaceAll,
            bytes = json.encodeToString(backupFile).toByteArray(),
        )

        assertEquals(0, result.newNoteFolders)
        assertEquals(1, result.skippedNoteFolders)
        assertEquals(1, result.newNotes)
        coVerify(exactly = 0) { noteFolderDao.upsert(match { it.id == deletedFolder.id }) }
        coVerify {
            noteDao.upsertWithIndex(
                match { it.id == "NOTE-REPLACE-ORPHAN" && it.noteFolderID == null },
                any(),
                any(),
                any(),
                any(),
            )
        }
    }

    @Test
    fun `import legacy OriveoBackup JSON restores providers and conversations`() = runTest {
        val legacyBackupJson = """
            {
              "version": 1,
              "createdAt": 1710000000000,
              "providers": [
                {
                  "kind": "OpenAI",
                  "displayName": "OpenAI",
                  "apiKeyPreview": "sk-***1234",
                  "modelCount": 12
                }
              ],
              "conversations": [
                {
                  "id": "legacy-conversation-1",
                  "title": "Legacy chat",
                  "messageCount": 3
                }
              ]
            }
        """.trimIndent()

        val result = backupService.executeImport(
            mode = ImportMode.ImportNewOnly,
            bytes = legacyBackupJson.toByteArray(),
        )

        assertEquals(1, result.newProviders)
        assertEquals(1, result.newConversations)
        coVerify {
            providerDao.upsert(
                match {
                    it.id == "legacy-provider-0-openai" &&
                        it.kind == ProviderKind.OpenAI.name &&
                        it.accountId == LOCAL_PARTITION_ID
                },
            )
        }
        coVerify {
            conversationDao.upsert(
                match {
                    it.id == "legacy-conversation-1" &&
                        it.title == "Legacy chat" &&
                        it.providerID == "legacy-provider-0-openai" &&
                        it.modelID == "legacy-model" &&
                        it.createdAt == 1710000000000L &&
                        it.updatedAt == 1710000000000L &&
                        it.accountId == LOCAL_PARTITION_ID
                },
            )
        }
    }

    @Test
    fun `merge keeps original messages when merged message rebuild fails`() = runTest {
        val localMessages = mutableListOf(
            MessageEntity(
                id = "local-message-1",
                conversationId = "conversation-1",
                role = "User",
                text = "original",
                providerID = null,
                providerKind = ProviderKind.OpenAI.name,
                providerName = ProviderKind.OpenAI.displayName,
                modelID = "gpt-4o",
                modelName = "GPT-4o",
                servedModelID = null,
                estimatedCost = 0.0,
                state = "Delivered",
                errorTitle = null,
                errorDetail = null,
                attachmentsJson = null,
                createdAt = 10L,
                sortOrder = 0,
            ),
        )
        val localConversation = existingConversationEntity()

        coEvery { providerDao.getAll(LOCAL_PARTITION_ID) } returns emptyList()
        coEvery { folderDao.getAll(LOCAL_PARTITION_ID) } returns emptyList()
        coEvery { skillDao.getBySource(LOCAL_PARTITION_ID, SkillSource.USER.value) } returns emptyList()
        coEvery { conversationDao.getById(any(), "conversation-1") } answers { localConversation }
        coEvery { messageDao.getByConversation(any(), "conversation-1") } answers { localMessages.toList() }
        coEvery { messageDao.deleteByConversation(any(), "conversation-1") } answers { localMessages.clear() }
        coEvery { messageDao.upsert(any()) } throws IllegalStateException("message insert failed")
        val transactionalService = createBackupService(
            runInTransaction = { block ->
                val messageSnapshot = localMessages.toList()
                try {
                    block()
                } catch (error: Throwable) {
                    localMessages.clear()
                    localMessages.addAll(messageSnapshot)
                    throw error
                }
            },
        )

        val backupFile = BackupFile(
            version = BackupService.CURRENT_VERSION,
            createdAt = "2026-04-19T10:00:00Z",
            appVersion = "1.0.0",
            platform = "Web",
            checksum = "",
            containsKeys = false,
            data = BackupData(
                conversations = listOf(
                    BackupConversation(
                        id = "conversation-1",
                        title = "Merged title",
                        providerID = "provider-1",
                        providerKind = ProviderKind.OpenAI,
                        modelID = "gpt-4o",
                        messages = listOf(
                            ChatMessage(
                                id = "backup-message-1",
                                role = ChatRole.Assistant,
                                text = "updated",
                                providerKind = ProviderKind.OpenAI,
                                providerName = ProviderKind.OpenAI.displayName,
                                modelName = "GPT-4o",
                                state = ChatMessageState.Delivered,
                                createdAt = 20L,
                            ),
                        ),
                        createdAt = 10L,
                        updatedAt = 20L,
                    ),
                ),
            ),
        )

        val error = runCatching {
            transactionalService.executeImport(
                mode = ImportMode.Merge,
                bytes = json.encodeToString(backupFile).toByteArray(),
            )
        }.exceptionOrNull()

        assertTrue(error is IllegalStateException)
        assertEquals(listOf("local-message-1"), localMessages.map { it.id })
    }

    @Test
    fun `merge keeps original messages when restoring attachment files fails`() = runTest {
        val localMessages = mutableListOf(
            MessageEntity(
                id = "local-message-1",
                conversationId = "conversation-1",
                role = "User",
                text = "original",
                providerID = null,
                providerKind = ProviderKind.OpenAI.name,
                providerName = ProviderKind.OpenAI.displayName,
                modelID = "gpt-4o",
                modelName = "GPT-4o",
                servedModelID = null,
                estimatedCost = 0.0,
                state = "Delivered",
                errorTitle = null,
                errorDetail = null,
                attachmentsJson = null,
                createdAt = 10L,
                sortOrder = 0,
            ),
        )
        val localConversation = existingConversationEntity()

        coEvery { providerDao.getAll(LOCAL_PARTITION_ID) } returns emptyList()
        coEvery { folderDao.getAll(LOCAL_PARTITION_ID) } returns emptyList()
        coEvery { skillDao.getBySource(LOCAL_PARTITION_ID, SkillSource.USER.value) } returns emptyList()
        coEvery { conversationDao.getById(any(), "conversation-1") } answers { localConversation }
        coEvery { messageDao.getByConversation(any(), "conversation-1") } answers { localMessages.toList() }
        coEvery { messageDao.deleteByConversation(any(), "conversation-1") } answers { localMessages.clear() }
        coEvery { messageDao.upsert(any()) } answers {
            localMessages += firstArg<MessageEntity>()
            Unit
        }
        every { attachmentStore.saveImageRaw("local-image-1", any()) } throws IllegalStateException("image write failed")

        val backupFile = BackupFile(
            version = BackupService.CURRENT_VERSION,
            createdAt = "2026-04-19T10:00:00Z",
            appVersion = "1.0.0",
            platform = "Web",
            checksum = "",
            containsKeys = false,
            data = BackupData(
                conversations = listOf(
                    BackupConversation(
                        id = "conversation-1",
                        title = "Merged title",
                        providerID = "provider-1",
                        providerKind = ProviderKind.OpenAI,
                        modelID = "gpt-4o",
                        messages = listOf(
                            ChatMessage(
                                id = "backup-message-1",
                                role = ChatRole.Assistant,
                                text = "updated",
                                providerID = "provider-1",
                                providerKind = ProviderKind.OpenAI,
                                providerName = ProviderKind.OpenAI.displayName,
                                modelID = "gpt-4o",
                                modelName = "GPT-4o",
                                state = ChatMessageState.Delivered,
                                attachments = listOf(
                                    Attachment(
                                        id = "attachment-2",
                                        kind = AttachmentKind.Image,
                                        fileName = "photo.jpg",
                                        mimeType = "image/jpeg",
                                        localImageId = "local-image-1",
                                    ),
                                ),
                                createdAt = 20L,
                            ),
                        ),
                        createdAt = 10L,
                        updatedAt = 20L,
                    ),
                ),
            ),
        )

        val error = runCatching {
            backupService.executeImport(
                mode = ImportMode.Merge,
                bytes = encodeBackupZip(
                    backupFile = backupFile,
                    attachments = mapOf("attachments/attachment-2.jpg" to "image".toByteArray()),
                ),
            )
        }.exceptionOrNull()

        assertTrue(error is IllegalStateException)
        assertEquals(listOf("local-message-1"), localMessages.map { it.id })
    }

    @Test
    fun `oversized zip entry maps to ResourceLimitExceeded instead of UnrecognizedFormat`() = runTest {
        val backupFile = BackupFile(
            version = BackupService.CURRENT_VERSION,
            createdAt = "2026-07-12T10:00:00Z",
            appVersion = "1.0.0",
            platform = "android",
            checksum = "",
            containsKeys = false,
            data = BackupData(conversations = emptyList()),
        )
        
        
        val oversized = ByteArray(33 * 1024 * 1024)

        try {
            backupService.executeImport(
                mode = ImportMode.Merge,
                bytes = encodeBackupZip(
                    backupFile = backupFile,
                    attachments = mapOf("attachments/huge.jpg" to oversized),
                ),
            )
            error("Expected ResourceLimitExceeded")
        } catch (_: BackupError.ResourceLimitExceeded) {
            
        }
    }

    @Test
    fun `merge restores original attachment bytes when transaction rollback happens after overwrite`() = runTest {
        val localMessages = mutableListOf(
            MessageEntity(
                id = "local-message-1",
                conversationId = "conversation-1",
                role = "User",
                text = "original",
                providerID = null,
                providerKind = ProviderKind.OpenAI.name,
                providerName = ProviderKind.OpenAI.displayName,
                modelID = "gpt-4o",
                modelName = "GPT-4o",
                servedModelID = null,
                estimatedCost = 0.0,
                state = "Delivered",
                errorTitle = null,
                errorDetail = null,
                attachmentsJson = null,
                createdAt = 10L,
                sortOrder = 0,
            ),
        )
        val localConversation = existingConversationEntity()
        var storedImage: ByteArray? = "old-image".toByteArray()
        var storedThumbnail: ByteArray? = "old-thumb".toByteArray()

        coEvery { providerDao.getAll(LOCAL_PARTITION_ID) } returns emptyList()
        coEvery { folderDao.getAll(LOCAL_PARTITION_ID) } returns emptyList()
        coEvery { skillDao.getBySource(LOCAL_PARTITION_ID, SkillSource.USER.value) } returns emptyList()
        coEvery { conversationDao.getById(any(), "conversation-1") } answers { localConversation }
        coEvery { messageDao.getByConversation(any(), "conversation-1") } answers { localMessages.toList() }
        coEvery { messageDao.deleteByConversation(any(), "conversation-1") } answers { localMessages.clear() }
        coEvery { messageDao.upsert(any()) } throws IllegalStateException("message insert failed")
        every { attachmentStore.loadImageBytes("local-image-1") } answers { storedImage }
        every { attachmentStore.loadThumbnailBytes("local-image-1") } answers { storedThumbnail }
        every { attachmentStore.saveImageRaw("local-image-1", any()) } answers {
            storedImage = secondArg()
        }
        every { attachmentStore.saveThumbnailRaw("local-image-1", any()) } answers {
            storedThumbnail = secondArg()
        }
        every { attachmentStore.delete("local-image-1") } answers {
            storedImage = null
            storedThumbnail = null
        }
        val transactionalService = createBackupService(
            runInTransaction = { block ->
                val messageSnapshot = localMessages.toList()
                try {
                    block()
                } catch (error: Throwable) {
                    localMessages.clear()
                    localMessages.addAll(messageSnapshot)
                    throw error
                }
            },
        )

        val backupFile = BackupFile(
            version = BackupService.CURRENT_VERSION,
            createdAt = "2026-04-19T10:00:00Z",
            appVersion = "1.0.0",
            platform = "Web",
            checksum = "",
            containsKeys = false,
            data = BackupData(
                conversations = listOf(
                    BackupConversation(
                        id = "conversation-1",
                        title = "Merged title",
                        providerID = "provider-1",
                        providerKind = ProviderKind.OpenAI,
                        modelID = "gpt-4o",
                        messages = listOf(
                            ChatMessage(
                                id = "backup-message-1",
                                role = ChatRole.Assistant,
                                text = "updated",
                                providerID = "provider-1",
                                providerKind = ProviderKind.OpenAI,
                                providerName = ProviderKind.OpenAI.displayName,
                                modelID = "gpt-4o",
                                modelName = "GPT-4o",
                                state = ChatMessageState.Delivered,
                                attachments = listOf(
                                    Attachment(
                                        id = "attachment-2",
                                        kind = AttachmentKind.Image,
                                        fileName = "photo.jpg",
                                        mimeType = "image/jpeg",
                                        localImageId = "local-image-1",
                                    ),
                                ),
                                createdAt = 20L,
                            ),
                        ),
                        createdAt = 10L,
                        updatedAt = 20L,
                    ),
                ),
            ),
        )

        val error = runCatching {
            transactionalService.executeImport(
                mode = ImportMode.Merge,
                bytes = encodeBackupZip(
                    backupFile = backupFile,
                    attachments = mapOf(
                        "attachments/attachment-2.jpg" to "new-image".toByteArray(),
                        "attachments/attachment-2.thumb.jpg" to "new-thumb".toByteArray(),
                    ),
                ),
            )
        }.exceptionOrNull()

        assertTrue(error is IllegalStateException)
        assertEquals(listOf("local-message-1"), localMessages.map { it.id })
        assertEquals("old-image", storedImage?.toString(Charsets.UTF_8))
        assertEquals("old-thumb", storedThumbnail?.toString(Charsets.UTF_8))
    }

    @Test
    fun `import new conversation does not persist db rows when restoring attachment files fails`() = runTest {
        val insertedConversations = mutableListOf<ConversationEntity>()
        val insertedMessages = mutableListOf<MessageEntity>()

        coEvery { providerDao.getAll(LOCAL_PARTITION_ID) } returns emptyList()
        coEvery { conversationDao.getAll(LOCAL_PARTITION_ID) } returns emptyList()
        coEvery { conversationDao.upsert(any()) } answers {
            insertedConversations += firstArg<ConversationEntity>()
            Unit
        }
        coEvery { messageDao.upsert(any()) } answers {
            insertedMessages += firstArg<MessageEntity>()
            Unit
        }
        every { attachmentStore.saveImageRaw("local-image-1", any()) } throws IllegalStateException("image write failed")

        val backupFile = BackupFile(
            version = BackupService.CURRENT_VERSION,
            createdAt = "2026-04-19T10:00:00Z",
            appVersion = "1.0.0",
            platform = "Web",
            checksum = "",
            containsKeys = false,
            data = BackupData(
                conversations = listOf(
                    BackupConversation(
                        id = "conversation-2",
                        title = "Imported chat",
                        providerID = "provider-1",
                        providerKind = ProviderKind.OpenAI,
                        modelID = "gpt-4o",
                        messages = listOf(
                            ChatMessage(
                                id = "message-2",
                                role = ChatRole.User,
                                text = "imported",
                                providerID = "provider-1",
                                providerKind = ProviderKind.OpenAI,
                                providerName = ProviderKind.OpenAI.displayName,
                                modelID = "gpt-4o",
                                modelName = "GPT-4o",
                                state = ChatMessageState.Delivered,
                                attachments = listOf(
                                    Attachment(
                                        id = "attachment-2",
                                        kind = AttachmentKind.Image,
                                        fileName = "photo.jpg",
                                        mimeType = "image/jpeg",
                                        localImageId = "local-image-1",
                                    ),
                                ),
                                createdAt = 20L,
                            ),
                        ),
                        createdAt = 20L,
                        updatedAt = 20L,
                    ),
                ),
            ),
        )

        val error = runCatching {
            backupService.executeImport(
                mode = ImportMode.ImportNewOnly,
                bytes = encodeBackupZip(
                    backupFile = backupFile,
                    attachments = mapOf("attachments/attachment-2.jpg" to "image".toByteArray()),
                ),
            )
        }.exceptionOrNull()

        assertTrue(error is IllegalStateException)
        assertTrue(insertedConversations.isEmpty())
        assertTrue(insertedMessages.isEmpty())
    }

    @Test
    fun `replaceAll restores original attachment bytes when outer transaction fails after conversation import`() = runTest {
        val attachmentsJson = json.encodeToString(
            ListSerializer(Attachment.serializer()),
            listOf(
                Attachment(
                    id = "attachment-1",
                    kind = AttachmentKind.Image,
                    fileName = "photo.jpg",
                    mimeType = "image/jpeg",
                    localImageId = "local-image-1",
                ),
            ),
        )
        var storedImage: ByteArray? = "old-image".toByteArray()

        coEvery { conversationDao.getAll(LOCAL_PARTITION_ID) } returns listOf(
            ConversationEntity(
                id = "conversation-1",
                title = "Chat",
                hasCustomTitle = false,
                providerID = "provider-1",
                providerKind = ProviderKind.OpenAI.name,
                modelID = "gpt-4o",
                useMemory = true,
                previewText = "",
                estimatedCost = 0.0,
                isDraft = false,
                draftText = "",
                createdAt = 10L,
                updatedAt = 20L,
                folderID = null,
                skillId = null,
                accountId = LOCAL_PARTITION_ID,
            ),
        )
        coEvery { messageDao.getByConversation(any(), "conversation-1") } returns listOf(
            MessageEntity(
                id = "message-1",
                conversationId = "conversation-1",
                role = "User",
                text = "hello",
                providerID = null,
                providerKind = ProviderKind.OpenAI.name,
                providerName = ProviderKind.OpenAI.displayName,
                modelID = "gpt-4o",
                modelName = "GPT-4o",
                servedModelID = null,
                estimatedCost = 0.0,
                state = "Delivered",
                errorTitle = null,
                errorDetail = null,
                attachmentsJson = attachmentsJson,
                createdAt = 10L,
                sortOrder = 0,
            ),
        )
        coEvery { messageDao.upsert(any()) } returns Unit
        coEvery { skillDao.upsert(any()) } throws IllegalStateException("skill import failed")
        every { attachmentStore.loadImageBytes("local-image-1") } answers { storedImage }
        every { attachmentStore.saveImageRaw("local-image-1", any()) } answers {
            storedImage = secondArg()
        }
        every { attachmentStore.delete("local-image-1") } answers {
            storedImage = null
        }

        val backupFile = BackupFile(
            version = BackupService.CURRENT_VERSION,
            createdAt = "2026-04-19T10:00:00Z",
            appVersion = "1.0.0",
            platform = "Web",
            checksum = "",
            containsKeys = false,
            data = BackupData(
                conversations = listOf(
                    BackupConversation(
                        id = "conversation-2",
                        title = "Imported chat",
                        providerID = "provider-1",
                        providerKind = ProviderKind.OpenAI,
                        modelID = "gpt-4o",
                        messages = listOf(
                            ChatMessage(
                                id = "message-2",
                                role = ChatRole.User,
                                text = "imported",
                                providerID = "provider-1",
                                providerKind = ProviderKind.OpenAI,
                                providerName = ProviderKind.OpenAI.displayName,
                                modelID = "gpt-4o",
                                modelName = "GPT-4o",
                                state = ChatMessageState.Delivered,
                                attachments = listOf(
                                    Attachment(
                                        id = "attachment-2",
                                        kind = AttachmentKind.Image,
                                        fileName = "photo.jpg",
                                        mimeType = "image/jpeg",
                                        localImageId = "local-image-1",
                                    ),
                                ),
                                createdAt = 20L,
                            ),
                        ),
                        createdAt = 20L,
                        updatedAt = 20L,
                    ),
                ),
                skills = listOf(
                    Skill(
                        id = "skill-1",
                        name = "Imported Skill",
                        systemPrompt = "Use the imported instructions.",
                        source = SkillSource.USER,
                    ),
                ),
            ),
        )

        val error = runCatching {
            backupService.executeImport(
                mode = ImportMode.ReplaceAll,
                bytes = encodeBackupZip(
                    backupFile = backupFile,
                    attachments = mapOf("attachments/attachment-2.jpg" to "new-image".toByteArray()),
                ),
            )
        }.exceptionOrNull()

        assertTrue(error is IllegalStateException)
        assertEquals("old-image", storedImage?.toString(Charsets.UTF_8))
    }

    @Test
    fun `executeImport restores user skills while clearing knowledgeBase and flagging reupload`() = runTest {
        val capturedSkills = mutableListOf<ai.oriveo.community.core.data.entity.SkillEntity>()
        coEvery { skillDao.upsert(capture(capturedSkills)) } returns Unit

        val backupFile = BackupFile(
            version = BackupService.CURRENT_VERSION,
            createdAt = "2026-03-20T10:00:00Z",
            appVersion = "1.0.0",
            platform = "Web",
            checksum = "",
            containsKeys = false,
            data = BackupData(
                skills = listOf(
                    Skill(
                        id = "skill-import-1",
                        name = "Backup Skill",
                        systemPrompt = "Use grounded knowledge.",
                        source = SkillSource.USER,
                        knowledgeBase = SkillKnowledgeBase(
                            provider = "openai",
                            retrievalModel = "gpt-5.4-mini",
                            vectorStoreId = "",
                            expiresAfterDays = 90,
                            files = listOf(
                                SkillKnowledgeBaseFile(
                                    id = "kb-1",
                                    name = "guide.pdf",
                                    mimeType = "application/pdf",
                                    sizeBytes = 2048,
                                    ingestionMode = SkillKnowledgeIngestionMode.NATIVE_FILE,
                                    status = SkillKnowledgeFileStatus.DISABLED,
                                ),
                            ),
                        ),
                    ),
                ),
            ),
        )

        val result = backupService.executeImport(
            mode = ImportMode.ImportNewOnly,
            bytes = json.encodeToString(backupFile).toByteArray(),
        )

        assertEquals(1, result.newSkills)
        assertEquals(1, result.skillsRequiringKnowledgeReupload)
        assertEquals(1, capturedSkills.size)
        assertEquals(null, capturedSkills.single().knowledgeBaseJson)
    }

    @Test
    fun `executeImport triggers metadata reconcile once after successful import`() = runTest {
        val backupFile = BackupFile(
            version = BackupService.CURRENT_VERSION,
            createdAt = "2026-04-18T10:00:00Z",
            appVersion = "1.0.0",
            platform = "Web",
            checksum = "",
            containsKeys = false,
            data = BackupData(
                providers = listOf(
                    BackupProvider(
                        id = "backup-provider",
                        kind = ProviderKind.OpenAI,
                        models = listOf(AIModel(id = "gpt-5", name = "GPT-5", isDefault = true)),
                        catalogModels = listOf(AIModel(id = "gpt-5", name = "GPT-5", isDefault = true)),
                    ),
                ),
            ),
        )

        backupService.executeImport(
            mode = ImportMode.ImportNewOnly,
            bytes = json.encodeToString(backupFile).toByteArray(),
        )

        assertEquals(1, metadataRefreshCallCount.get())
    }

    @Test
    fun `executeImport still succeeds when metadata reconcile throws`() = runTest {
        val failingService = createBackupService(
            metadataRefresh = { throw RuntimeException("simulated network failure") },
        )

        val backupFile = BackupFile(
            version = BackupService.CURRENT_VERSION,
            createdAt = "2026-04-18T10:00:00Z",
            appVersion = "1.0.0",
            platform = "Web",
            checksum = "",
            containsKeys = false,
            data = BackupData(
                providers = listOf(
                    BackupProvider(
                        id = "backup-provider",
                        kind = ProviderKind.OpenAI,
                        models = listOf(AIModel(id = "gpt-5", name = "GPT-5", isDefault = true)),
                    ),
                ),
            ),
        )

        
        val result = failingService.executeImport(
            mode = ImportMode.ImportNewOnly,
            bytes = json.encodeToString(backupFile).toByteArray(),
        )

        assertEquals(1, result.newProviders)
    }

    private fun existingProviderEntity() = Provider(
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

    private fun backupNote(
        id: String,
        noteFolderID: String? = null,
        updatedAt: String = "2026-06-25T00:00:00Z",
        deletedAt: String? = null,
        body: String = "Body",
    ) = BackupNote(
        id = id,
        title = "Imported note",
        titleSource = "manual",
        body = body,
        noteFolderID = noteFolderID,
        captureKind = "blank",
        createdAt = "2026-06-25T00:00:00Z",
        updatedAt = updatedAt,
        deletedAt = deletedAt,
    )

    private fun backupNoteFolder(
        id: String,
        updatedAt: String = "2026-06-25T00:00:00Z",
        deletedAt: String? = null,
        name: String = "Research",
    ) = BackupNoteFolder(
        id = id,
        name = name,
        sortOrder = 1000,
        createdAt = "2026-06-25T00:00:00Z",
        updatedAt = updatedAt,
        deletedAt = deletedAt,
    )

    private fun note(
        id: String,
        noteFolderID: String? = null,
        updatedAt: String = "2026-06-25T00:00:00Z",
        body: String = "Local body",
    ) = Note(
        id = id,
        title = "Local note",
        body = body,
        noteFolderID = noteFolderID,
        createdAt = "2026-06-25T00:00:00Z",
        updatedAt = updatedAt,
    )

    private fun noteFolder(
        id: String,
        updatedAt: String = "2026-06-25T00:00:00Z",
        deletedAt: String? = null,
        name: String = "Local folder",
    ) = NoteFolder(
        id = id,
        name = name,
        sortOrder = 1000,
        createdAt = "2026-06-25T00:00:00Z",
        updatedAt = updatedAt,
        deletedAt = deletedAt,
    )

    @Test
    fun `executeImport normalizes lowercase uuids so messages keep a consistent parent id`() = runTest {
        
        
        val lowerId = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
        val upsertedConvs = mutableListOf<ConversationEntity>()
        val upsertedMessages = mutableListOf<MessageEntity>()
        coEvery { conversationDao.upsert(capture(upsertedConvs)) } returns Unit
        coEvery { messageDao.upsert(capture(upsertedMessages)) } returns Unit

        val backupFile = BackupFile(
            version = BackupService.CURRENT_VERSION,
            createdAt = "2026-06-11T10:00:00Z",
            appVersion = "1.0.0",
            platform = "Web",
            checksum = "",
            containsKeys = false,
            data = BackupData(
                conversations = listOf(
                    BackupConversation(
                        id = lowerId,
                        title = "Lowercase backup",
                        providerID = "provider-1",
                        providerKind = ProviderKind.OpenAI,
                        modelID = "gpt-4o",
                        messages = listOf(
                            ChatMessage(
                                id = "1f2e3d4c-5b6a-4798-8123-456789abcdef",
                                role = ChatRole.User,
                                text = "hello",
                                providerKind = ProviderKind.OpenAI,
                                providerName = ProviderKind.OpenAI.displayName,
                                modelName = "GPT-4o",
                                state = ChatMessageState.Delivered,
                                createdAt = 20L,
                            ),
                        ),
                        createdAt = 10L,
                        updatedAt = 20L,
                    ),
                ),
            ),
        )

        backupService.executeImport(
            mode = ImportMode.ImportNewOnly,
            bytes = json.encodeToString(backupFile).toByteArray(),
        )

        assertEquals(lowerId.uppercase(), upsertedConvs.single().id)
        assertEquals(lowerId.uppercase(), upsertedMessages.single().conversationId)
        assertEquals("1f2e3d4c-5b6a-4798-8123-456789abcdef".uppercase(), upsertedMessages.single().id)
    }

    @Test
    fun `executeImport preserves id colliding only in another account partition`() = runTest {
        
        val collidingId = "AA1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"
        val originalMessageId = "1F2E3D4C-5B6A-4798-8123-456789ABCDEF"
        coEvery { conversationDao.getById("other-user", collidingId) } returns
            existingConversationEntity().copy(id = collidingId, accountId = "other-user")

        val upsertedConvs = mutableListOf<ConversationEntity>()
        val upsertedMessages = mutableListOf<MessageEntity>()
        val upsertedNotes = mutableListOf<ai.oriveo.community.core.data.entity.NoteEntity>()
        coEvery { conversationDao.upsert(capture(upsertedConvs)) } returns Unit
        coEvery { messageDao.upsert(capture(upsertedMessages)) } returns Unit
        coEvery { noteDao.upsertWithIndex(capture(upsertedNotes), any(), any(), any(), any()) } returns Unit

        val backupFile = BackupFile(
            version = BackupService.CURRENT_VERSION,
            createdAt = "2026-06-11T10:00:00Z",
            appVersion = "1.0.0",
            platform = "iOS",
            checksum = "",
            containsKeys = false,
            data = BackupData(
                conversations = listOf(
                    BackupConversation(
                        id = collidingId,
                        title = "Colliding backup",
                        providerID = "provider-1",
                        providerKind = ProviderKind.OpenAI,
                        modelID = "gpt-4o",
                        messages = listOf(
                            ChatMessage(
                                id = originalMessageId,
                                role = ChatRole.User,
                                text = "hello",
                                providerKind = ProviderKind.OpenAI,
                                providerName = ProviderKind.OpenAI.displayName,
                                modelName = "GPT-4o",
                                state = ChatMessageState.Delivered,
                                createdAt = 20L,
                            ),
                        ),
                        createdAt = 10L,
                        updatedAt = 20L,
                    ),
                ),
                notes = listOf(
                    BackupNote(
                        id = "NOTE-SOURCE",
                        title = "Saved answer",
                        titleSource = "manual",
                        body = "Body",
                        sourceConversationId = collidingId,
                        sourceMessageId = originalMessageId,
                        captureKind = "fullAnswer",
                        provenance = listOf(
                            ProvenanceEntry(
                                kind = ProvenanceKind.Origin,
                                conversationId = collidingId,
                                messageId = originalMessageId,
                                at = "2026-06-11T10:00:00Z",
                            ),
                        ),
                        createdAt = "2026-06-11T10:00:00Z",
                        updatedAt = "2026-06-11T10:00:00Z",
                    ),
                ),
            ),
        )

        backupService.executeImport(
            mode = ImportMode.Merge,
            bytes = json.encodeToString(backupFile).toByteArray(),
        )

        val conv = upsertedConvs.single()
        assertEquals(collidingId, conv.id)
        assertEquals(LOCAL_PARTITION_ID, conv.accountId)
        assertEquals(collidingId, upsertedMessages.single().conversationId)
        assertEquals(originalMessageId, upsertedMessages.single().id)
        val note = upsertedNotes.single()
        assertEquals(collidingId, note.sourceConversationId)
        assertEquals(originalMessageId, note.sourceMessageId)
        assertTrue(note.provenanceJson!!.contains(collidingId))
        assertTrue(note.provenanceJson!!.contains(originalMessageId))
        
        coVerify(exactly = 0) { messageDao.deleteByConversation("other-user", collidingId) }
    }

    private fun existingConversationEntity(
        useMemory: Boolean = true,
    ) = ConversationEntity(
        id = "conversation-1",
        title = "Existing conversation",
        hasCustomTitle = false,
        providerID = "existing-provider",
        providerKind = ProviderKind.OpenAI.name,
        modelID = "gpt-4o",
        useMemory = useMemory,
        previewText = "Hello",
        estimatedCost = 0.0,
        isDraft = false,
        draftText = "",
        createdAt = 0L,
        updatedAt = 0L,
        accountId = LOCAL_PARTITION_ID,
    )

    private fun folderEntity(
        id: String,
        name: String,
        sortOrder: Int,
    ) = FolderEntity(
        id = id,
        name = name,
        sortOrder = sortOrder,
        createdAt = 1700000000000L + sortOrder,
        updatedAt = 1700000000100L + sortOrder,
        accountId = LOCAL_PARTITION_ID,
    )

    private fun conversationEntity(
        id: String,
        folderID: String?,
    ) = ConversationEntity(
        id = id,
        title = "Conversation",
        hasCustomTitle = false,
        providerID = "provider-1",
        providerKind = ProviderKind.OpenAI.name,
        modelID = "gpt-4o",
        previewText = "",
        estimatedCost = 0.0,
        isDraft = false,
        draftText = "",
        createdAt = 1700000000000L,
        updatedAt = 1700000001000L,
        folderID = folderID,
        accountId = LOCAL_PARTITION_ID,
    )

    private fun messageWithImageAttachmentEntity() = ChatMessage(
        id = "message-with-image",
        role = ChatRole.User,
        text = "look",
        providerKind = ProviderKind.OpenAI,
        providerName = "OpenAI",
        modelID = "gpt-4o",
        modelName = "GPT-4o",
        state = ChatMessageState.Delivered,
        createdAt = 20L,
        attachments = listOf(
            Attachment(
                id = "attachment-1",
                kind = AttachmentKind.Image,
                fileName = "photo.jpg",
                mimeType = "image/jpeg",
                localImageId = "local-image-1",
            ),
        ),
    ).toEntity(LOCAL_PARTITION_ID, "conversation-1", 0)

    private fun zipEntryNames(bytes: ByteArray): Set<String> {
        val names = mutableSetOf<String>()
        ZipInputStream(bytes.inputStream()).use { zis ->
            var entry = zis.nextEntry
            while (entry != null) {
                names += entry.name
                entry = zis.nextEntry
            }
        }
        return names
    }

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

    @Test
    fun `importNewOnly restores image entries named by attachment id`() = runTest {
        assertImageRestoredFromArchive(
            attachments = mapOf(
                "attachments/attachment-2.jpg" to "image-bytes".toByteArray(),
                "attachments/attachment-2.thumb.jpg" to "thumb-bytes".toByteArray(),
            ),
        )
    }

    @Test
    fun `importNewOnly restores legacy web archive named by localImageId`() = runTest {
        assertImageRestoredFromArchive(
            attachments = mapOf(
                "attachments/local-image-1.jpg" to "image-bytes".toByteArray(),
                "attachments/local-image-1.thumb.jpg" to "thumb-bytes".toByteArray(),
            ),
        )
    }

    @Test
    fun `importNewOnly restores iOS archive named by attachment id with png extension`() = runTest {
        
        assertImageRestoredFromArchive(
            attachments = mapOf(
                "attachments/attachment-2.png" to "image-bytes".toByteArray(),
                "attachments/attachment-2.thumb.png" to "thumb-bytes".toByteArray(),
            ),
            mimeType = "image/png",
        )
    }

    @Test
    fun `importNewOnly restores png attachment stored with jpg extension`() = runTest {
        
        assertImageRestoredFromArchive(
            attachments = mapOf(
                "attachments/attachment-2.jpg" to "image-bytes".toByteArray(),
                "attachments/attachment-2.thumb.jpg" to "thumb-bytes".toByteArray(),
            ),
            mimeType = "image/png",
        )
    }

    @Test
    fun `importNewOnly restores legacy web archive whose entries use lowercase uuids`() = runTest {
        
        
        
        val lowerId = "6f1c2b7a-9d3e-4c58-8b21-0a5e7d4f1c93"
        val lowerLocalId = "b28d5f04-71a6-4e39-9c7d-3f05a1e6b842"
        var storedImage: ByteArray? = null
        var storedThumbnail: ByteArray? = null
        coEvery { messageDao.upsert(any()) } returns Unit
        every {
            attachmentStore.saveImageRaw(lowerLocalId.uppercase(), any())
        } answers { storedImage = secondArg() }
        every {
            attachmentStore.saveThumbnailRaw(lowerLocalId.uppercase(), any())
        } answers { storedThumbnail = secondArg() }

        val result = backupService.executeImport(
            mode = ImportMode.ImportNewOnly,
            bytes = encodeBackupZip(
                backupFile = imageAttachmentBackupFile(
                    attachmentId = lowerId,
                    localImageId = lowerLocalId,
                ),
                attachments = mapOf(
                    "attachments/$lowerLocalId.jpg" to "image-bytes".toByteArray(),
                    "attachments/$lowerLocalId.thumb.jpg" to "thumb-bytes".toByteArray(),
                ),
            ),
        )

        assertEquals(1, result.restoredImages)
        assertEquals(0, result.skippedImages)
        assertEquals("image-bytes", storedImage?.toString(Charsets.UTF_8))
        assertEquals("thumb-bytes", storedThumbnail?.toString(Charsets.UTF_8))
    }

    @Test
    fun `importNewOnly skips image when neither naming matches`() = runTest {
        var storedImage: ByteArray? = null
        coEvery { messageDao.upsert(any()) } returns Unit
        every { attachmentStore.saveImageRaw(any(), any()) } answers { storedImage = secondArg() }
        every { attachmentStore.saveThumbnailRaw(any(), any()) } just Runs

        val result = backupService.executeImport(
            mode = ImportMode.ImportNewOnly,
            bytes = encodeBackupZip(
                backupFile = imageAttachmentBackupFile(),
                attachments = mapOf("attachments/unrelated.jpg" to "image-bytes".toByteArray()),
            ),
        )

        assertEquals(0, result.restoredImages)
        assertEquals(1, result.skippedImages)
        assertNull(storedImage)
    }

    
    private suspend fun assertImageRestoredFromArchive(
        attachments: Map<String, ByteArray>,
        mimeType: String = "image/jpeg",
    ) {
        var storedImage: ByteArray? = null
        var storedThumbnail: ByteArray? = null
        coEvery { messageDao.upsert(any()) } returns Unit
        every { attachmentStore.saveImageRaw("local-image-1", any()) } answers { storedImage = secondArg() }
        every { attachmentStore.saveThumbnailRaw("local-image-1", any()) } answers { storedThumbnail = secondArg() }

        val result = backupService.executeImport(
            mode = ImportMode.ImportNewOnly,
            bytes = encodeBackupZip(
                backupFile = imageAttachmentBackupFile(mimeType = mimeType),
                attachments = attachments,
            ),
        )

        assertEquals(1, result.restoredImages)
        assertEquals(0, result.skippedImages)
        assertEquals("image-bytes", storedImage?.toString(Charsets.UTF_8))
        assertEquals("thumb-bytes", storedThumbnail?.toString(Charsets.UTF_8))
    }

    private fun imageAttachmentBackupFile(
        mimeType: String = "image/jpeg",
        attachmentId: String = "attachment-2",
        localImageId: String = "local-image-1",
    ): BackupFile = BackupFile(
        version = BackupService.CURRENT_VERSION,
        createdAt = "2026-08-24T10:00:00Z",
        appVersion = "1.0.0",
        platform = "Web",
        checksum = "",
        containsKeys = false,
        data = BackupData(
            conversations = listOf(
                BackupConversation(
                    id = "conversation-2",
                    title = "Imported chat",
                    providerID = "provider-1",
                    providerKind = ProviderKind.OpenAI,
                    modelID = "gpt-4o",
                    messages = listOf(
                        ChatMessage(
                            id = "message-2",
                            role = ChatRole.User,
                            text = "imported",
                            providerID = "provider-1",
                            providerKind = ProviderKind.OpenAI,
                            providerName = ProviderKind.OpenAI.displayName,
                            modelID = "gpt-4o",
                            modelName = "GPT-4o",
                            state = ChatMessageState.Delivered,
                            attachments = listOf(
                                Attachment(
                                    id = attachmentId,
                                    kind = AttachmentKind.Image,
                                    fileName = "photo.jpg",
                                    mimeType = mimeType,
                                    localImageId = localImageId,
                                ),
                            ),
                            createdAt = 20L,
                        ),
                    ),
                    createdAt = 20L,
                    updatedAt = 20L,
                ),
            ),
        ),
    )

    private fun encodeBackupZip(
        backupFile: BackupFile,
        attachments: Map<String, ByteArray> = emptyMap(),
    ): ByteArray {
        return java.io.ByteArrayOutputStream().use { output ->
            ZipOutputStream(output).use { zip ->
                zip.putNextEntry(ZipEntry("data.json"))
                zip.write(json.encodeToString(backupFile).toByteArray())
                zip.closeEntry()

                attachments.forEach { (path, bytes) ->
                    zip.putNextEntry(ZipEntry(path))
                    zip.write(bytes)
                    zip.closeEntry()
                }
            }
            output.toByteArray()
        }
    }
}
