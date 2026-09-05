package ai.oriveo.community.core.data.backup

import android.util.Base64
import android.util.Log
import ai.oriveo.community.BuildConfig
import ai.oriveo.community.core.app.AppPreferenceKeys
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.attachments.AttachmentHydrator
import ai.oriveo.community.core.attachments.AttachmentSlimmer
import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.EntityMapper
import ai.oriveo.community.core.data.EntityMapper.toDomain
import ai.oriveo.community.core.data.EntityMapper.toEntity
import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.data.dao.ConversationDao
import ai.oriveo.community.core.data.dao.FolderDao
import ai.oriveo.community.core.data.dao.MessageDao
import ai.oriveo.community.core.data.dao.PreferenceDao
import ai.oriveo.community.core.data.dao.ProviderDao
import ai.oriveo.community.core.data.dao.SkillDao
import ai.oriveo.community.core.data.entity.PreferenceEntity
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.BackupError
import ai.oriveo.community.core.model.BackupConversation
import ai.oriveo.community.core.model.BackupData
import ai.oriveo.community.core.model.BackupFile
import ai.oriveo.community.core.model.BackupFolder
import ai.oriveo.community.core.model.BackupNote
import ai.oriveo.community.core.model.BackupNoteFolder
import ai.oriveo.community.core.notes.NoteTime
import ai.oriveo.community.core.model.BackupInspection
import ai.oriveo.community.core.model.BackupKeyEntry
import ai.oriveo.community.core.model.BackupKeysPayload
import ai.oriveo.community.core.model.BackupPreferences
import ai.oriveo.community.core.model.BackupProvider
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.Folder
import ai.oriveo.community.core.model.ImportMode
import ai.oriveo.community.core.model.ImportPreview
import ai.oriveo.community.core.model.ImportResult
import ai.oriveo.community.core.model.LastUsedModelRef
import ai.oriveo.community.core.model.LanguageOption
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.provider.RelayOfficialCatalogResolver
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.Skill
import ai.oriveo.community.core.model.SkillKnowledgeFileStatus
import ai.oriveo.community.core.model.SkillSource
import ai.oriveo.community.core.model.ThemeOption
import ai.oriveo.community.core.model.credentialFreePortableCopy
import ai.oriveo.community.core.model.credentialFreeRelayEndpoint
import ai.oriveo.community.core.security.BackupCrypto
import ai.oriveo.community.core.security.SecureKeyStore
import ai.oriveo.community.core.util.takeGraphemes
import ai.oriveo.community.core.util.generateUuidString
import ai.oriveo.community.core.util.normalizeMessageIds
import ai.oriveo.community.core.util.normalizeUuid
import ai.oriveo.community.core.util.InputSizeLimitExceededException
import ai.oriveo.community.core.util.readBytesLimited
import ai.oriveo.community.core.util.backupMemoryBudgetBytes
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.OutputStream
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream


class BackupService(
    private val providerDao: ProviderDao,
    private val conversationDao: ConversationDao,
    private val messageDao: MessageDao,
    private val folderDao: FolderDao,
    private val skillDao: SkillDao,
    private val noteDao: ai.oriveo.community.core.data.dao.NoteDao,
    private val noteFolderDao: ai.oriveo.community.core.data.dao.NoteFolderDao,
    private val json: Json,
    private val secureKeyStore: SecureKeyStore,
    private val attachmentStore: AttachmentStore,
    private val preferenceDao: PreferenceDao,
    
    private val metadataRefresh: suspend () -> Unit = { MetadataClient.refresh() },
    private val runInTransaction: suspend (suspend () -> Unit) -> Unit = { transactionalBlock -> transactionalBlock() },
) {
    private val accountId: String get() = LOCAL_PARTITION_ID

    companion object {
        const val CURRENT_VERSION = 1
        
        
        private const val MAX_BACKUP_ZIP_ENTRY_COUNT = 65_536
        private const val MAX_BACKUP_ZIP_ENTRY_BYTES = 32L * 1024L * 1024L
        private const val PREF_KEY_THEME = "theme"
        private const val PREF_KEY_LANGUAGE = "language"
    }

    
    private val canonicalJson = Json {
        encodeDefaults = true
        prettyPrint = false
    }

    
    data class DataSummary(
        val conversations: Int,
        val providers: Int,
        val folders: Int,
        val messages: Int,
    )

    private data class BackupArchivePayload(
        val backupFile: BackupFile,
        
        val imageEntries: List<ImageEntryRef>,
    )

    
    private data class ImageEntryRef(
        val filename: String,
        val localImageId: String,
        val thumbnail: Boolean,
    )

    private data class RestoredImageBatch(
        val restoredImages: Int = 0,
        val skippedImages: Int = 0,
        val snapshots: List<AttachmentImageSnapshot> = emptyList(),
    )

    private data class AttachmentImageSnapshot(
        val localImageId: String,
        val imageBytes: ByteArray?,
        val thumbnailBytes: ByteArray?,
    )

    
    suspend fun getDataSummary(): DataSummary {
        val scopedAccountId = accountId
        val providers = providerDao.getAll(scopedAccountId)
        val conversations = conversationDao.getAll(scopedAccountId).filter { conv ->
            !conv.isDraft || messageDao.getByConversation(scopedAccountId, conv.id).isNotEmpty()
        }
        var totalMessages = 0
        conversations.forEach { conv ->
            totalMessages += messageDao.getByConversation(scopedAccountId, conv.id).size
        }
        return DataSummary(
            conversations = conversations.size,
            providers = providers.size,
            folders = folderDao.countByAccount(scopedAccountId),
            messages = totalMessages,
        )
    }

    

    
    suspend fun exportBackupToFile(
        target: java.io.File,
        includeKeys: Boolean = false,
        password: String? = null,
    ) {
        val payload = buildBackupArchivePayload(
            targetAccountId = accountId,
            includeKeys = includeKeys,
            password = password,
        )
        target.outputStream().buffered().use { out ->
            writeBackupArchive(payload, out)
        }
    }

    
    suspend fun exportBackup(
        includeKeys: Boolean = false,
        password: String? = null,
    ): ByteArray {
        return exportBackupForAccount(
            targetAccountId = accountId,
            includeKeys = includeKeys,
            password = password,
        )
    }

    private suspend fun exportBackupForAccount(
        targetAccountId: String,
        includeKeys: Boolean = false,
        password: String? = null,
    ): ByteArray {
        val payload = buildBackupArchivePayload(
            targetAccountId = targetAccountId,
            includeKeys = includeKeys,
            password = password,
        )

        val zipBytes = ByteArrayOutputStream()
        writeBackupArchive(payload, zipBytes)
        return zipBytes.toByteArray()
    }

    suspend fun exportSyntheticBackup(
        providers: List<Provider>,
        folders: List<Folder>,
        conversations: List<Conversation>,
        preferences: Map<String, Any>? = null,
        targetAccountId: String = accountId,
        includeLocalState: Boolean = false,
        allowEmpty: Boolean = false,
    ): ByteArray {
        val payload = buildBackupArchivePayloadFromData(
            targetAccountId = targetAccountId,
            providers = providers,
            folders = folders,
            conversations = conversations,
            preferences = preferences,
            includeKeys = false,
            password = null,
            includeLocalState = includeLocalState,
            allowEmpty = allowEmpty,
        )

        val zipBytes = ByteArrayOutputStream()
        writeBackupArchive(payload, zipBytes)
        return zipBytes.toByteArray()
    }

    private suspend fun buildBackupArchivePayload(
        targetAccountId: String,
        includeKeys: Boolean,
        password: String?,
    ): BackupArchivePayload {
        val providers = providerDao.getAll(targetAccountId).map { it.toDomain() }
        val folders = folderDao.getAll(targetAccountId).map { it.toDomain() }
        val conversations = conversationDao.getAll(targetAccountId).map { conv ->
            conv.toDomain(messageDao.getByConversation(targetAccountId, conv.id).map { it.toDomain() })
        }
        
        val notes = noteDao.getAll(targetAccountId).map { it.toDomain() }
        val noteFolders = noteFolderDao.getAll(targetAccountId).map { it.toDomain() }
        return buildBackupArchivePayloadFromData(
            targetAccountId = targetAccountId,
            providers = providers,
            folders = folders,
            conversations = conversations,
            preferences = null,
            includeKeys = includeKeys,
            password = password,
            includeLocalState = true,
            allowEmpty = false,
            notes = notes,
            noteFolders = noteFolders,
        )
    }

    private suspend fun buildBackupArchivePayloadFromData(
        targetAccountId: String,
        providers: List<Provider>,
        folders: List<Folder>,
        conversations: List<Conversation>,
        preferences: Map<String, Any>?,
        includeKeys: Boolean,
        password: String?,
        includeLocalState: Boolean,
        allowEmpty: Boolean,
        notes: List<ai.oriveo.community.core.model.Note> = emptyList(),
        noteFolders: List<ai.oriveo.community.core.model.NoteFolder> = emptyList(),
    ): BackupArchivePayload {
        val userSkills = if (includeLocalState) {
            skillDao.getBySource(targetAccountId, SkillSource.USER.value)
                .map { sanitizeSkillForBackup(it.toDomain()) }
        } else {
            emptyList()
        }

        val backupProviders = providers.map { provider ->
            BackupProvider(
                id = provider.id,
                kind = provider.kind,
                baseURLText = if (provider.kind == ProviderKind.Relay) {
                    credentialFreeRelayEndpoint(provider.baseUrlText)
                } else {
                    provider.baseUrlText
                },
                customName = provider.customName,
                relayKind = provider.relayKind,
                models = provider.models,
                catalogModels = if (provider.kind == ProviderKind.Relay) provider.catalogModels else emptyList(),
                relayRequested = provider.relayRequested?.credentialFreePortableCopy(),
                relayImage = provider.relayImage,
            )
        }

        val backupConversations = conversations
            .filter { conversation -> !conversation.isDraft || conversation.messages.isNotEmpty() }
            .map { conversation ->
                
                
                
                
                
                
                
                
                
                
                
                
                
                
                val hydratedMessages = AttachmentHydrator.hydrate(
                    messages = conversation.messages,
                    loadImageBase64 = { null },
                    loadBlobBase64 = { ref -> attachmentStore.loadBlobBase64(ref) },
                )
                BackupConversation(
                    id = conversation.id,
                    title = conversation.title,
                    hasCustomTitle = conversation.hasCustomTitle,
                    providerID = conversation.providerID,
                    providerKind = conversation.providerKind,
                    modelID = conversation.modelID,
                    useMemory = conversation.useMemory,
                    previewText = conversation.previewText,
                    estimatedCost = conversation.estimatedCost,
                    messages = hydratedMessages,
                    folderID = conversation.folderID,
                    skillId = conversation.skillId,
                    createdAt = conversation.createdAt,
                    updatedAt = conversation.updatedAt,
                    pinnedNoteIds = conversation.pinnedNoteIds,
                )
            }

        val backupFolders = folders.map { folder ->
            BackupFolder(
                id = folder.id,
                name = folder.name,
                sortOrder = folder.sortOrder,
                createdAt = folder.createdAt,
                updatedAt = folder.updatedAt,
            )
        }

        val backupNotes = notes.map { it.toBackupNote() }
        val backupNoteFolders = noteFolders.map { it.toBackupNoteFolder() }

        if (!allowEmpty &&
            backupProviders.isEmpty() &&
            backupFolders.isEmpty() &&
            backupConversations.isEmpty() &&
            userSkills.isEmpty() &&
            backupNotes.isEmpty() &&
            backupNoteFolders.isEmpty()
        ) {
            throw BackupError.NoDataToExport
        }

        val backupPrefs = when {
            includeLocalState -> buildBackupPreferencesFromLocalState(targetAccountId)
            preferences != null -> buildBackupPreferencesFromSyncPayload(preferences)
            else -> null
        }

        val backupData = BackupData(
            providers = backupProviders,
            folders = backupFolders,
            conversations = backupConversations,
            skills = userSkills,
            preferences = backupPrefs,
            lastUsedModelRef = if (includeLocalState) buildLastUsedModelRef(targetAccountId) else null,
            notes = backupNotes,
            noteFolders = backupNoteFolders,
        )

        val dataJsonBytes = canonicalJson.encodeToString(backupData).toByteArray(Charsets.UTF_8)
        val checksum = sha256Checksum(dataJsonBytes)

        
        
        val attachmentChecksums = mutableMapOf<String, String>()
        val imageEntries = mutableListOf<ImageEntryRef>()
        for (conversation in backupConversations) {
            for (message in conversation.messages) {
                val attachments = message.attachments ?: continue
                for (attachment in attachments) {
                    if (attachment.kind != AttachmentKind.Image) continue
                    val localImageId = attachment.localImageId ?: continue

                    attachmentStore.loadImageBytes(localImageId)?.let { imageBytes ->
                        val filename = "${attachment.id}.jpg"
                        imageEntries.add(ImageEntryRef(filename, localImageId, thumbnail = false))
                        attachmentChecksums[filename] = sha256Checksum(imageBytes)
                    }

                    attachmentStore.loadThumbnailBytes(localImageId)?.let { thumbnailBytes ->
                        val filename = "${attachment.id}.thumb.jpg"
                        imageEntries.add(ImageEntryRef(filename, localImageId, thumbnail = true))
                        attachmentChecksums[filename] = sha256Checksum(thumbnailBytes)
                    }
                }
            }
        }

        var encryptedKeys: String? = null
        if (includeKeys && !password.isNullOrEmpty()) {
            val keyEntries = providers.mapNotNull { provider ->
                val apiKey = secureKeyStore.getApiKey(accountId, provider.id)
                if (apiKey.isNullOrEmpty()) {
                    null
                } else {
                    BackupKeyEntry(
                        providerID = provider.id,
                        apiKey = apiKey,
                        apiKeyPreview = provider.apiKeyPreview,
                    )
                }
            }
            if (keyEntries.isNotEmpty()) {
                val payload = BackupKeysPayload(keys = keyEntries)
                val payloadBytes = json.encodeToString(payload).toByteArray(Charsets.UTF_8)
                encryptedKeys = Base64.encodeToString(
                    BackupCrypto.encrypt(payloadBytes, password),
                    Base64.NO_WRAP,
                )
            }
        }

        val isoFormatter = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).apply {
            timeZone = TimeZone.getTimeZone("UTC")
        }
        return BackupArchivePayload(
            backupFile = BackupFile(
                version = CURRENT_VERSION,
                createdAt = isoFormatter.format(Date()),
                appVersion = BuildConfig.VERSION_NAME,
                platform = "Android",
                checksum = checksum,
                containsKeys = encryptedKeys != null,
                data = backupData,
                attachmentChecksums = attachmentChecksums.ifEmpty { null },
                encryptedKeys = encryptedKeys,
            ),
            imageEntries = imageEntries,
        )
    }

    
    private fun writeBackupArchive(
        payload: BackupArchivePayload,
        output: OutputStream,
    ) {
        ZipOutputStream(output).use { zos ->
            // data.json
            val backupFileJson = json.encodeToString(payload.backupFile).toByteArray(Charsets.UTF_8)
            zos.putNextEntry(ZipEntry("data.json"))
            zos.write(backupFileJson)
            zos.closeEntry()

            
            for (entry in payload.imageEntries) {
                val data = if (entry.thumbnail) {
                    attachmentStore.loadThumbnailBytes(entry.localImageId)
                } else {
                    attachmentStore.loadImageBytes(entry.localImageId)
                }
                if (data == null) {
                    
                    
                    Log.w("BackupService", "backup entry vanished between checksum and write: ${entry.filename}")
                    continue
                }
                zos.putNextEntry(ZipEntry("attachments/${entry.filename}"))
                zos.write(data)
                zos.closeEntry()
            }
        }
    }

    

    
    suspend fun inspectBackup(bytes: ByteArray): BackupInspection {
        val (backupFile, images) = parseBackup(bytes)
        validateVersion(backupFile)

        val localProviders = providerDao.getAll(accountId).map { it.toDomain() }
        val localConversations = conversationDao.getAll(accountId)

        val localConvIDs = localConversations.map { normalizeUuid(it.id) }.toSet()
        val localProviderIDs = localProviders.map { normalizeUuid(it.id) }.toSet()

        
        val existingConvs = backupFile.data.conversations.count { localConvIDs.contains(normalizeUuid(it.id)) }
        var existingProvs = 0
        for (bp in backupFile.data.providers) {
            if (localProviderIDs.contains(normalizeUuid(bp.id))) existingProvs++
        }

        val totalMessages = backupFile.data.conversations.sumOf { it.messages.size }
        val totalImages = backupFile.data.conversations.sumOf { conv ->
            conv.messages.sumOf { msg ->
                msg.attachments?.count { it.kind == AttachmentKind.Image } ?: 0
            }
        }

        return BackupInspection(
            preview = ImportPreview(
                backupCreatedAt = backupFile.createdAt,
                backupPlatform = backupFile.platform,
                backupAppVersion = backupFile.appVersion,
                containsKeys = backupFile.containsKeys,
                totalConversations = backupFile.data.conversations.size,
                existingConversations = existingConvs,
                totalProviders = backupFile.data.providers.size,
                existingProviders = existingProvs,
                totalMessages = totalMessages,
                totalImages = totalImages,
            ),
            checksumWarning = computeChecksumWarning(backupFile),
            attachmentWarning = computeAttachmentIntegrityWarning(backupFile, images),
            requiresKeyPassword = backupFile.containsKeys && !backupFile.encryptedKeys.isNullOrEmpty(),
        )
    }

    

    
    private fun computeChecksumWarning(backupFile: BackupFile): Boolean {
        return try {
            val dataJsonBytes = canonicalJson.encodeToString(backupFile.data)
                .toByteArray(Charsets.UTF_8)
            val computed = sha256Checksum(dataJsonBytes)
            computed != backupFile.checksum
        } catch (_: Exception) {
            true
        }
    }

    
    private fun computeAttachmentIntegrityWarning(
        backupFile: BackupFile,
        images: Map<String, ByteArray>,
    ): Boolean {
        return try {
            val expectedChecksums = backupFile.attachmentChecksums ?: return false
            expectedChecksums.any { (filename, expectedChecksum) ->
                val imageData = images[filename] ?: return@any true
                sha256Checksum(imageData) != expectedChecksum
            }
        } catch (_: Exception) {
            true
        }
    }

    
    suspend fun hasChecksumWarning(bytes: ByteArray): Boolean {
        return try {
            val (backupFile, _) = parseBackup(bytes)
            validateVersion(backupFile)
            computeChecksumWarning(backupFile)
        } catch (_: BackupError) {
            true
        } catch (_: Exception) {
            true
        }
    }

    suspend fun hasAttachmentIntegrityWarning(bytes: ByteArray): Boolean {
        return try {
            val (backupFile, images) = parseBackup(bytes)
            validateVersion(backupFile)
            val expectedChecksums = backupFile.attachmentChecksums ?: return false

            expectedChecksums.any { (filename, expectedChecksum) ->
                val imageData = images[filename] ?: return@any true
                sha256Checksum(imageData) != expectedChecksum
            }
        } catch (_: BackupError) {
            true
        } catch (_: Exception) {
            true
        }
    }

    

    
    suspend fun executeImport(
        mode: ImportMode,
        password: String? = null,
        bytes: ByteArray,
        preserveUserSkillsOnReplaceAll: Boolean = false,
        targetAccountIdOverride: String? = null,
    ): ImportResult {
        val liveAccountId = accountId
        if (targetAccountIdOverride != null && liveAccountId != targetAccountIdOverride) {
            throw BackupError.AccountChanged
        }
        val targetAccountId = targetAccountIdOverride ?: liveAccountId
        val (backupFile, images) = parseBackup(bytes)
        validateVersion(backupFile)

        
        val restoredKeys = mutableMapOf<String, Pair<String, String>>() // providerID → (apiKey, preview)
        if (backupFile.containsKeys && !backupFile.encryptedKeys.isNullOrEmpty() && !password.isNullOrEmpty()) {
            try {
                val encData = Base64.decode(backupFile.encryptedKeys, Base64.NO_WRAP)
                val decrypted = BackupCrypto.decrypt(encData, password)
                val payload = json.decodeFromString<BackupKeysPayload>(String(decrypted, Charsets.UTF_8))
                for (entry in payload.keys) {
                    
                    restoredKeys[normalizeUuid(entry.providerID)] = entry.apiKey to entry.apiKeyPreview
                }
            } catch (_: Exception) {
                throw BackupError.WrongPassword
            }
        }

        val preparedFile = prepareBackupForImport(targetAccountId, backupFile, restoredKeys)

        val finalResult = when (mode) {
            ImportMode.ImportNewOnly -> {
                val result = importNewOnly(targetAccountId, preparedFile, images, restoredKeys)
                applyImportedPreferences(targetAccountId, result, preparedFile.data, replaceAll = false)
            }

            ImportMode.Merge -> {
                val result = importMerge(targetAccountId, preparedFile, images, restoredKeys)
                applyImportedPreferences(targetAccountId, result, preparedFile.data, replaceAll = false)
            }

            ImportMode.ReplaceAll -> importReplaceAll(
                targetAccountId = targetAccountId,
                backupFile = preparedFile,
                images = images,
                restoredKeys = restoredKeys,
                preserveUserSkills = preserveUserSkillsOnReplaceAll,
            )
        }

        
        
        
        
        try {
            metadataRefresh()
        } catch (error: Exception) {
            Log.w("BackupService", "metadata reconcile after import failed; will retry on next launch", error)
        }

        return finalResult
    }

    

    private suspend fun importNewOnly(
        targetAccountId: String,
        backupFile: BackupFile,
        images: Map<String, ByteArray>,
        restoredKeys: Map<String, Pair<String, String>>,
    ): ImportResult {
        var result = ImportResult()

        val localProviders = providerDao.getAll(targetAccountId).map { it.toDomain() }
        val localFolderIDs = folderDao.getAll(targetAccountId).map { normalizeUuid(it.id) }.toSet()
        val localConvIDs = conversationDao.getAll(targetAccountId).map { normalizeUuid(it.id) }.toSet()
        val localProvidersById = localProviders.associateBy { normalizeUuid(it.id) }
        val localUserSkillIDs = skillDao.getBySource(targetAccountId, SkillSource.USER.value).map { it.id }.toSet()

        // Provider
        for (bp in backupFile.data.providers) {
            val matchingProvider = localProvidersById[normalizeUuid(bp.id)]

            if (matchingProvider != null) {
                
                val localKey = secureKeyStore.getApiKey(targetAccountId, matchingProvider.id)
                if (localKey.isNullOrEmpty()) {
                    restoredKeys[bp.id]?.let { (apiKey, preview) ->
                        secureKeyStore.saveApiKey(targetAccountId, matchingProvider.id, apiKey)
                        val updated = matchingProvider.copy(
                            apiKeyPreview = preview,
                            status = ProviderConnectionState.Issue(ProviderRepository.RELAY_UNVERIFIED_MESSAGE),
                        )
                        providerDao.upsert(ai.oriveo.community.core.provider.prepareProviderForUpsert(updated).toEntity(targetAccountId))
                        result = result.copy(restoredKeys = result.restoredKeys + 1)
                    }
                }
                result = result.copy(skippedProviders = result.skippedProviders + 1)
                continue
            }

            val newProvider = bp.toProvider()
            restoredKeys[bp.id]?.let { (apiKey, preview) ->
                secureKeyStore.saveApiKey(targetAccountId, newProvider.id, apiKey)
                val updated = newProvider.copy(
                    apiKeyPreview = preview,
                    status = ProviderConnectionState.Issue(ProviderRepository.RELAY_UNVERIFIED_MESSAGE),
                )
                providerDao.upsert(ai.oriveo.community.core.provider.prepareProviderForUpsert(updated).toEntity(targetAccountId))
                result = result.copy(restoredKeys = result.restoredKeys + 1)
            } ?: providerDao.upsert(ai.oriveo.community.core.provider.prepareProviderForUpsert(newProvider).toEntity(targetAccountId))

            result = result.copy(newProviders = result.newProviders + 1)
        }

        for (backupFolder in backupFile.data.folders) {
            if (backupFolder.id !in localFolderIDs) {
                folderDao.upsert(backupFolder.toFolderEntity(targetAccountId))
            }
        }

        
        val localNoteFolders = noteFolderDao.getAll(targetAccountId)
        val localNoteFolderIDs = localNoteFolders.map { normalizeUuid(it.id) }.toSet()
        val activeNoteFolderIDs = localNoteFolders
            .filter { it.deletedAt == null }
            .map { normalizeUuid(it.id) }
            .toMutableSet()
        for (bnf in backupFile.data.noteFolders) {
            val folderId = normalizeUuid(bnf.id)
            if (bnf.deletedAt != null || folderId in localNoteFolderIDs) {
                result = result.copy(skippedNoteFolders = result.skippedNoteFolders + 1)
            } else {
                noteFolderDao.upsert(bnf.toNoteFolderEntity(targetAccountId))
                activeNoteFolderIDs += folderId
                result = result.copy(newNoteFolders = result.newNoteFolders + 1)
            }
        }
        val localNoteIDs = noteDao.getAll(targetAccountId).map { normalizeUuid(it.id) }.toSet()
        for (bn in backupFile.data.notes) {
            val normalizedNote = bn.withValidNoteFolder(activeNoteFolderIDs)
            if (normalizeUuid(normalizedNote.id) !in localNoteIDs) {
                importNoteEntity(normalizedNote.toNoteEntity(targetAccountId))
                result = result.copy(newNotes = result.newNotes + 1)
            } else {
                result = result.copy(skippedNotes = result.skippedNotes + 1)
            }
        }

        // Conversation
        for (bc in backupFile.data.conversations) {
            if (localConvIDs.contains(bc.id)) {
                result = result.copy(skippedConversations = result.skippedConversations + 1)
                continue
            }
            result = importConversation(targetAccountId, bc, images, result)
            result = result.copy(newConversations = result.newConversations + 1)
        }

        for (backupSkill in backupFile.data.skills) {
            if (localUserSkillIDs.contains(backupSkill.id)) {
                result = result.copy(skippedSkills = result.skippedSkills + 1)
                continue
            }

            val (restoredSkill, requiresKnowledgeReupload) = restoreSkillFromBackup(backupSkill)
            skillDao.upsert(restoredSkill.toEntity(targetAccountId))
            result = result.copy(
                newSkills = result.newSkills + 1,
                skillsRequiringKnowledgeReupload = result.skillsRequiringKnowledgeReupload +
                    if (requiresKnowledgeReupload) 1 else 0,
            )
        }

        return result
    }

    

    private suspend fun importMerge(
        targetAccountId: String,
        backupFile: BackupFile,
        images: Map<String, ByteArray>,
        restoredKeys: Map<String, Pair<String, String>>,
    ): ImportResult {
        var result = ImportResult()

        val localProviders = providerDao.getAll(targetAccountId).map { it.toDomain() }
        val localProvidersById = localProviders.associateBy { normalizeUuid(it.id) }
        val localFoldersById = folderDao.getAll(targetAccountId).associateBy { normalizeUuid(it.id) }
        val localUserSkillsById = skillDao.getBySource(targetAccountId, SkillSource.USER.value)
            .map { it.toDomain() }
            .associateBy { it.id }

        
        for (bp in backupFile.data.providers) {
            val matchingProvider = localProvidersById[normalizeUuid(bp.id)]

            if (matchingProvider != null) {
                
                val existingModelIDs = matchingProvider.models.map { it.id }.toSet()
                val mergedModels = matchingProvider.models +
                    bp.models.filter { it.id !in existingModelIDs }

                val isRelay = bp.kind == ai.oriveo.community.core.model.ProviderKind.Relay
                val mergedCatalog = if (isRelay) {
                    val existingCatalogIDs = matchingProvider.catalogModels.map { it.id }.toSet()
                    matchingProvider.catalogModels +
                        bp.catalogModels.filter { it.id !in existingCatalogIDs }
                } else {
                    emptyList()
                }

                var updated = matchingProvider.copy(
                    customName = bp.customName ?: matchingProvider.customName,
                    baseUrlText = if (isRelay) bp.baseURLText ?: matchingProvider.baseUrlText else matchingProvider.baseUrlText,
                    models = mergedModels,
                    catalogModels = mergedCatalog,
                    relayKind = if (isRelay) bp.relayKind ?: matchingProvider.relayKind else matchingProvider.relayKind,
                    relayRequested = if (isRelay) bp.relayRequested ?: matchingProvider.relayRequested else matchingProvider.relayRequested,
                    relayImage = if (isRelay) bp.relayImage ?: matchingProvider.relayImage else matchingProvider.relayImage,
                )

                
                val localKey = secureKeyStore.getApiKey(targetAccountId, matchingProvider.id)
                if (localKey.isNullOrEmpty()) {
                    restoredKeys[bp.id]?.let { (apiKey, preview) ->
                        secureKeyStore.saveApiKey(targetAccountId, matchingProvider.id, apiKey)
                        updated = updated.copy(
                            apiKeyPreview = preview,
                            status = ProviderConnectionState.Issue(ProviderRepository.RELAY_UNVERIFIED_MESSAGE),
                        )
                        result = result.copy(restoredKeys = result.restoredKeys + 1)
                    }
                }

                providerDao.upsert(ai.oriveo.community.core.provider.prepareProviderForUpsert(updated).toEntity(targetAccountId))
                result = result.copy(skippedProviders = result.skippedProviders + 1)
            } else {
                val newProvider = bp.toProvider()
                restoredKeys[bp.id]?.let { (apiKey, preview) ->
                    secureKeyStore.saveApiKey(targetAccountId, newProvider.id, apiKey)
                    val updated = newProvider.copy(
                        apiKeyPreview = preview,
                        status = ProviderConnectionState.Issue(ProviderRepository.RELAY_UNVERIFIED_MESSAGE),
                    )
                    providerDao.upsert(ai.oriveo.community.core.provider.prepareProviderForUpsert(updated).toEntity(targetAccountId))
                    result = result.copy(restoredKeys = result.restoredKeys + 1)
                } ?: providerDao.upsert(ai.oriveo.community.core.provider.prepareProviderForUpsert(newProvider).toEntity(targetAccountId))

                result = result.copy(newProviders = result.newProviders + 1)
            }
        }

        for (backupFolder in backupFile.data.folders) {
            val existingFolder = localFoldersById[backupFolder.id]
            if (existingFolder == null || backupFolder.updatedAt >= existingFolder.updatedAt) {
                folderDao.upsert(backupFolder.toFolderEntity(targetAccountId))
            }
        }

        
        val localNoteFoldersById = noteFolderDao.getAll(targetAccountId).associateBy { normalizeUuid(it.id) }
        val resolvedNoteFoldersById = localNoteFoldersById.toMutableMap()
        val deletedNoteFolderIDs = mutableSetOf<String>()
        for (bnf in backupFile.data.noteFolders) {
            val folderId = normalizeUuid(bnf.id)
            val existing = localNoteFoldersById[folderId]
            if (existing == null) {
                if (bnf.deletedAt == null) {
                    val entity = bnf.toNoteFolderEntity(targetAccountId)
                    noteFolderDao.upsert(entity)
                    resolvedNoteFoldersById[folderId] = entity
                    result = result.copy(newNoteFolders = result.newNoteFolders + 1)
                } else {
                    result = result.copy(skippedNoteFolders = result.skippedNoteFolders + 1)
                }
            } else if (NoteTime.isoNewer(bnf.updatedAt, existing.updatedAt)) {
                val entity = bnf.toNoteFolderEntity(targetAccountId)
                noteFolderDao.upsert(entity)
                resolvedNoteFoldersById[folderId] = entity
                if (entity.deletedAt != null) {
                    deletedNoteFolderIDs += folderId
                }
                result = result.copy(mergedNoteFolders = result.mergedNoteFolders + 1)
            } else {
                result = result.copy(skippedNoteFolders = result.skippedNoteFolders + 1)
            }
        }
        val activeNoteFolderIDs = resolvedNoteFoldersById.values
            .filter { it.deletedAt == null }
            .map { normalizeUuid(it.id) }
            .toSet()
        val noteFolderCleanupTime = NoteTime.nowIso()
        deletedNoteFolderIDs.forEach { folderId ->
            noteDao.clearNoteFolder(targetAccountId, folderId, noteFolderCleanupTime)
        }
        val localNotesById = noteDao.getAll(targetAccountId).associateBy { normalizeUuid(it.id) }
        for (bn in backupFile.data.notes) {
            val normalizedNote = bn.withValidNoteFolder(activeNoteFolderIDs)
            val existing = localNotesById[normalizeUuid(normalizedNote.id)]
            if (existing == null) {
                importNoteEntity(normalizedNote.toNoteEntity(targetAccountId))
                result = result.copy(newNotes = result.newNotes + 1)
            } else if (NoteTime.isoNewer(normalizedNote.updatedAt, existing.updatedAt)) {
                importNoteEntity(normalizedNote.toNoteEntity(targetAccountId))
                result = result.copy(mergedNotes = result.mergedNotes + 1)
            } else {
                result = result.copy(skippedNotes = result.skippedNotes + 1)
            }
        }

        
        for (bc in backupFile.data.conversations) {
            val localConv = conversationDao.getById(targetAccountId, bc.id)

            if (localConv != null) {
                
                val localMessages = messageDao.getByConversation(targetAccountId, bc.id).map { it.toDomain() }
                val merged = mergeMessages(localMessages, bc.messages)
                val imageBatch = restoreImagesWithTracking(bc, images)

                
                val mergedUpdatedAt = maxOf(localConv.updatedAt, bc.updatedAt)
                val updatedConv = if (bc.updatedAt > localConv.updatedAt) {
                    localConv.copy(
                        title = bc.title,
                        hasCustomTitle = bc.hasCustomTitle,
                        useMemory = bc.useMemory,
                        previewText = bc.previewText,
                        estimatedCost = bc.estimatedCost,
                        folderID = bc.folderID,
                        skillId = bc.skillId,
                        updatedAt = mergedUpdatedAt,
                    )
                } else {
                    localConv.copy(updatedAt = mergedUpdatedAt)
                }

                
                
                val slimmedMerged = merged.map { message -> slimMessageAttachmentsForImport(message) }

                
                try {
                    runAtomically {
                        messageDao.deleteByConversation(targetAccountId, bc.id)
                        slimmedMerged.forEachIndexed { index, msg ->
                            messageDao.upsert(msg.toMessageEntity(targetAccountId, bc.id, index))
                        }
                        conversationDao.upsert(updatedConv)
                    }
                } catch (error: Throwable) {
                    rollbackRestoredImages(imageBatch.snapshots)
                    throw error
                }

                result = result.applyImageBatch(imageBatch)
                result = result.copy(mergedConversations = result.mergedConversations + 1)
            } else {
                result = importConversation(targetAccountId, bc, images, result)
                result = result.copy(newConversations = result.newConversations + 1)
            }
        }

        for (backupSkill in backupFile.data.skills) {
            val localSkill = localUserSkillsById[backupSkill.id]
            if (localSkill == null) {
                val (restoredSkill, requiresKnowledgeReupload) = restoreSkillFromBackup(backupSkill)
                skillDao.upsert(restoredSkill.toEntity(targetAccountId))
                result = result.copy(
                    newSkills = result.newSkills + 1,
                    skillsRequiringKnowledgeReupload = result.skillsRequiringKnowledgeReupload +
                        if (requiresKnowledgeReupload) 1 else 0,
                )
                continue
            }

            if (backupSkill.updatedAt >= localSkill.updatedAt) {
                val (restoredSkill, requiresKnowledgeReupload) = restoreSkillFromBackup(backupSkill)
                skillDao.upsert(restoredSkill.toEntity(targetAccountId))
                result = result.copy(
                    mergedSkills = result.mergedSkills + 1,
                    skillsRequiringKnowledgeReupload = result.skillsRequiringKnowledgeReupload +
                        if (requiresKnowledgeReupload) 1 else 0,
                )
            } else {
                result = result.copy(skippedSkills = result.skippedSkills + 1)
            }
        }

        return result
    }

    

    private suspend fun importReplaceAll(
        targetAccountId: String,
        backupFile: BackupFile,
        images: Map<String, ByteArray>,
        restoredKeys: Map<String, Pair<String, String>>,
        preserveUserSkills: Boolean,
    ): ImportResult {
        val existingProviders = providerDao.getAll(targetAccountId).map { it.toDomain() }
        val attachmentIds = collectAttachmentIds(targetAccountId)
        val originalProviderKeys = existingProviders.associate { provider ->
            provider.id to secureKeyStore.getApiKey(targetAccountId, provider.id)?.takeIf { it.isNotBlank() }
        }
        val replaceAllImageSnapshots = linkedMapOf<String, AttachmentImageSnapshot>()
        val preservedLocalKeys = existingProviders.associate { provider ->
            provider.id to (
                secureKeyStore.getApiKey(targetAccountId, provider.id)?.takeIf { it.isNotBlank() } to provider.apiKeyPreview
                )
        }
        val retainedProviderIds = mutableSetOf<String>()
        val savedProviderIds = mutableSetOf<String>()

        val result = try {
            runAtomically {
                var transactionalResult = ImportResult()

                
                conversationDao.deleteByAccount(targetAccountId)
                providerDao.deleteByAccount(targetAccountId)
                folderDao.deleteByAccount(targetAccountId)
                
                noteDao.getAll(targetAccountId).forEach { noteDao.deleteSearchIndex(targetAccountId, it.id) }
                noteDao.deleteByAccount(targetAccountId)
                noteFolderDao.deleteByAccount(targetAccountId)
                if (!preserveUserSkills) {
                    skillDao.deleteBySource(targetAccountId, SkillSource.USER.value)
                }

                
                for (bp in backupFile.data.providers) {
                    val newProvider = bp.toProvider()
                    val matchingExistingProvider = existingProviders.firstOrNull {
                        normalizeUuid(it.id) == normalizeUuid(bp.id)
                    }
                    val preservedLocalKey = matchingExistingProvider?.let { provider ->
                        preservedLocalKeys[provider.id]
                    }?.first
                    val preservedPreview = matchingExistingProvider?.let { provider ->
                        preservedLocalKeys[provider.id]
                    }?.second

                    when {
                        restoredKeys[bp.id] != null -> {
                            val (apiKey, preview) = restoredKeys.getValue(bp.id)
                            secureKeyStore.saveApiKey(targetAccountId, newProvider.id, apiKey)
                            savedProviderIds += newProvider.id
                            retainedProviderIds += newProvider.id
                            val updated = newProvider.copy(
                                apiKeyPreview = preview,
                                status = ProviderConnectionState.Issue(ProviderRepository.RELAY_UNVERIFIED_MESSAGE),
                            )
                            providerDao.upsert(ai.oriveo.community.core.provider.prepareProviderForUpsert(updated).toEntity(targetAccountId))
                            transactionalResult = transactionalResult.copy(
                                restoredKeys = transactionalResult.restoredKeys + 1,
                            )
                        }

                        !preservedLocalKey.isNullOrBlank() -> {
                            secureKeyStore.saveApiKey(targetAccountId, newProvider.id, preservedLocalKey)
                            savedProviderIds += newProvider.id
                            retainedProviderIds += newProvider.id
                            val updated = newProvider.copy(
                                apiKeyPreview = preservedPreview.orEmpty(),
                                status = ProviderConnectionState.Issue(ProviderRepository.RELAY_UNVERIFIED_MESSAGE),
                            )
                            providerDao.upsert(ai.oriveo.community.core.provider.prepareProviderForUpsert(updated).toEntity(targetAccountId))
                        }

                        else -> providerDao.upsert(ai.oriveo.community.core.provider.prepareProviderForUpsert(newProvider).toEntity(targetAccountId))
                    }

                    transactionalResult = transactionalResult.copy(
                        newProviders = transactionalResult.newProviders + 1,
                    )
                }

                for (backupFolder in backupFile.data.folders) {
                    folderDao.upsert(backupFolder.toFolderEntity(targetAccountId))
                }

                
                val activeNoteFolderIDs = backupFile.data.noteFolders
                    .filter { it.deletedAt == null }
                    .map { normalizeUuid(it.id) }
                    .toSet()
                for (bnf in backupFile.data.noteFolders) {
                    if (bnf.deletedAt != null) {
                        transactionalResult = transactionalResult.copy(
                            skippedNoteFolders = transactionalResult.skippedNoteFolders + 1,
                        )
                        continue
                    }
                    noteFolderDao.upsert(bnf.toNoteFolderEntity(targetAccountId))
                    transactionalResult = transactionalResult.copy(
                        newNoteFolders = transactionalResult.newNoteFolders + 1,
                    )
                }
                for (bn in backupFile.data.notes) {
                    importNoteEntity(bn.withValidNoteFolder(activeNoteFolderIDs).toNoteEntity(targetAccountId))
                    transactionalResult = transactionalResult.copy(
                        newNotes = transactionalResult.newNotes + 1,
                    )
                }

                
                for (bc in backupFile.data.conversations) {
                    transactionalResult = importConversation(
                        targetAccountId = targetAccountId,
                        bc = bc,
                        images = images,
                        currentResult = transactionalResult,
                        databaseAlreadyAtomic = true,
                        onImageBatchCommitted = { batch ->
                            batch.snapshots.forEach { snapshot ->
                                replaceAllImageSnapshots.putIfAbsent(snapshot.localImageId, snapshot)
                            }
                        },
                    )
                    transactionalResult = transactionalResult.copy(
                        newConversations = transactionalResult.newConversations + 1,
                    )
                }

                for (backupSkill in backupFile.data.skills) {
                    val (restoredSkill, requiresKnowledgeReupload) = restoreSkillFromBackup(backupSkill)
                    skillDao.upsert(restoredSkill.toEntity(targetAccountId))
                    transactionalResult = transactionalResult.copy(
                        newSkills = transactionalResult.newSkills + 1,
                        skillsRequiringKnowledgeReupload = transactionalResult.skillsRequiringKnowledgeReupload +
                            if (requiresKnowledgeReupload) 1 else 0,
                    )
                }

                applyImportedPreferences(
                    targetAccountId = targetAccountId,
                    importResult = transactionalResult,
                    backupData = backupFile.data,
                    replaceAll = true,
                )
            }
        } catch (error: Throwable) {
            restoreProviderKeysAfterFailedReplaceAll(
                accountId = targetAccountId,
                originalProviderKeys = originalProviderKeys,
                savedProviderIds = savedProviderIds,
            )
            rollbackRestoredImages(replaceAllImageSnapshots.values)
            throw error
        }

        val restoredAttachmentIds = collectAttachmentIds(backupFile.data.conversations)
        attachmentIds
            .filterNot { attachmentId -> restoredAttachmentIds.contains(attachmentId) }
            .forEach(attachmentStore::delete)
        existingProviders
            .map { provider -> provider.id }
            .filterNot { providerId -> retainedProviderIds.contains(providerId) }
            .forEach { providerId -> secureKeyStore.deleteApiKey(targetAccountId, providerId) }

        return result
    }

    

    
    private fun mergeMessages(
        local: List<ChatMessage>,
        backup: List<ChatMessage>,
    ): List<ChatMessage> {
        
        fun ensureCreatedAt(messages: List<ChatMessage>): List<ChatMessage> {
            val base = messages.mapNotNull { it.createdAt }.maxOrNull() ?: System.currentTimeMillis()
            var offset = 0L
            return messages.map { msg ->
                if (msg.createdAt != null) {
                    msg
                } else {
                    offset += 1
                    msg.copy(createdAt = base + offset)
                }
            }
        }

        return ChatMessage.mergeByIdAndCreatedAt(
            local = ensureCreatedAt(local),
            restored = ensureCreatedAt(backup),
        )
    }

    private fun sanitizeSkillForBackup(skill: Skill): Skill = skill.copy(
        knowledgeBase = skill.knowledgeBase?.copy(
            vectorStoreId = "",
            files = skill.knowledgeBase.files.map { file ->
                file.copy(
                    openAIFileId = null,
                    status = SkillKnowledgeFileStatus.DISABLED,
                )
            },
        ),
    )

    private fun restoreSkillFromBackup(skill: Skill): Pair<Skill, Boolean> {
        val requiresKnowledgeReupload = skill.knowledgeBase?.files?.isNotEmpty() == true
        return skill.copy(
            source = SkillSource.USER,
            knowledgeBase = null,
        ) to requiresKnowledgeReupload
    }

    

    
    private suspend fun prepareBackupForImport(
        targetAccountId: String,
        backupFile: BackupFile,
        restoredKeys: MutableMap<String, Pair<String, String>>,
    ): BackupFile {
        val providerRemap = mutableMapOf<String, String>()
        val providers = backupFile.data.providers.map { bp ->
            val normalizedId = normalizeUuid(bp.id)
            val existing = providerDao.getById(targetAccountId, normalizedId)
            if (existing != null && existing.accountId != targetAccountId) {
                val newId = generateUuidString()
                providerRemap[normalizedId] = newId
                bp.copy(id = newId)
            } else {
                bp.copy(id = normalizedId)
            }
        }

        val folderRemap = mutableMapOf<String, String>()
        val folders = backupFile.data.folders.map { bf ->
            val normalizedId = normalizeUuid(bf.id)
            val existing = folderDao.getById(targetAccountId, normalizedId)
            if (existing != null && existing.accountId != targetAccountId) {
                val newId = generateUuidString()
                folderRemap[normalizedId] = newId
                bf.copy(id = newId)
            } else {
                bf.copy(id = normalizedId)
            }
        }

        
        val noteFolderRemap = mutableMapOf<String, String>()
        val noteFolders = backupFile.data.noteFolders.map { bnf ->
            val normalizedId = normalizeUuid(bnf.id)
            val existing = noteFolderDao.getById(targetAccountId, normalizedId)
            if (existing != null && existing.accountId != targetAccountId) {
                val newId = generateUuidString()
                noteFolderRemap[normalizedId] = newId
                bnf.copy(id = newId)
            } else {
                bnf.copy(id = normalizedId)
            }
        }
        val noteRemap = mutableMapOf<String, String>()
        backupFile.data.notes.forEach { bn ->
            val normalizedId = normalizeUuid(bn.id)
            val existing = noteDao.getById(targetAccountId, normalizedId)
            if (existing != null && existing.accountId != targetAccountId) {
                val newId = generateUuidString()
                noteRemap[normalizedId] = newId
            }
        }

        val conversationRemap = mutableMapOf<String, String>()
        val messageRemap = mutableMapOf<String, String>()
        val conversations = backupFile.data.conversations.map { bc ->
            val normalizedId = normalizeUuid(bc.id)
            val normalizedProvider = normalizeUuid(bc.providerID)
            val normalizedFolder = bc.folderID?.let(::normalizeUuid)
            val resolvedProvider = providerRemap[normalizedProvider] ?: normalizedProvider
            val resolvedFolder = normalizedFolder?.let { folderRemap[it] ?: it }
            val resolvedPinned = bc.pinnedNoteIds.map(::normalizeUuid).map { noteRemap[it] ?: it }
            val existing = conversationDao.getById(targetAccountId, normalizedId)
            if (existing != null && existing.accountId != targetAccountId) {
                val newConversationId = generateUuidString()
                conversationRemap[normalizedId] = newConversationId
                bc.copy(
                    id = newConversationId,
                    providerID = resolvedProvider,
                    folderID = resolvedFolder,
                    pinnedNoteIds = resolvedPinned,
                    
                    
                    messages = bc.messages.map {
                        val normalized = normalizeMessageIds(it)
                        val newMessageId = generateUuidString()
                        messageRemap[normalizeUuid(normalized.id)] = newMessageId
                        normalized.copy(id = newMessageId)
                    },
                )
            } else {
                bc.copy(
                    id = normalizedId,
                    providerID = resolvedProvider,
                    folderID = resolvedFolder,
                    pinnedNoteIds = resolvedPinned,
                    messages = bc.messages.map(::normalizeMessageIds),
                )
            }
        }

        val notes = backupFile.data.notes.map { bn ->
            val normalizedId = normalizeUuid(bn.id)
            val resolvedFolder = bn.noteFolderID?.let(::normalizeUuid)?.let { noteFolderRemap[it] ?: it }
            val resolvedSourceConversation = bn.sourceConversationId
                ?.let(::normalizeUuid)
                ?.let { conversationRemap[it] ?: it }
            val resolvedSourceMessage = bn.sourceMessageId
                ?.let(::normalizeUuid)
                ?.let { messageRemap[it] ?: it }
            val resolvedProvenance = bn.provenance.map { entry ->
                entry.copy(
                    conversationId = entry.conversationId?.let(::normalizeUuid)?.let { conversationRemap[it] ?: it },
                    messageId = entry.messageId?.let(::normalizeUuid)?.let { messageRemap[it] ?: it },
                )
            }
            bn.copy(
                id = noteRemap[normalizedId] ?: normalizedId,
                noteFolderID = resolvedFolder,
                sourceConversationId = resolvedSourceConversation,
                sourceMessageId = resolvedSourceMessage,
                provenance = resolvedProvenance,
            )
        }

        
        providerRemap.forEach { (oldId, newId) ->
            restoredKeys.remove(oldId)?.let { restoredKeys[newId] = it }
        }

        return backupFile.copy(
            data = backupFile.data.copy(
                providers = providers,
                folders = folders,
                conversations = conversations,
                notes = notes,
                noteFolders = noteFolders,
            ),
        )
    }

    
    private suspend fun importConversation(
        targetAccountId: String,
        bc: BackupConversation,
        images: Map<String, ByteArray>,
        currentResult: ImportResult,
        databaseAlreadyAtomic: Boolean = false,
        onImageBatchCommitted: (RestoredImageBatch) -> Unit = {},
    ): ImportResult {
        val imageBatch = restoreImagesWithTracking(bc, images)
        
        
        
        val slimmedMessages = bc.messages.map { message -> slimMessageAttachmentsForImport(message) }

        val convEntity = ai.oriveo.community.core.data.entity.ConversationEntity(
            id = bc.id,
            title = bc.title,
            hasCustomTitle = bc.hasCustomTitle,
            providerID = bc.providerID,
            providerKind = bc.providerKind.name,
            modelID = bc.modelID,
            useMemory = bc.useMemory,
            previewText = bc.previewText,
            estimatedCost = bc.estimatedCost,
            isDraft = false,
            draftText = "",
            createdAt = bc.createdAt.takeIf { createdAt -> createdAt > 0L } ?: bc.updatedAt,
            updatedAt = bc.updatedAt,
            folderID = bc.folderID,
            skillId = bc.skillId,
            accountId = targetAccountId,
        )

        val persistConversation: suspend () -> Unit = {
            conversationDao.upsert(convEntity)
            slimmedMessages.forEachIndexed { index, msg ->
                messageDao.upsert(msg.toMessageEntity(targetAccountId, bc.id, index))
            }
        }

        try {
            if (databaseAlreadyAtomic) {
                persistConversation()
            } else {
                runAtomically {
                    persistConversation()
                }
            }
        } catch (error: Throwable) {
            rollbackRestoredImages(imageBatch.snapshots)
            throw error
        }

        onImageBatchCommitted(imageBatch)
        return currentResult.applyImageBatch(imageBatch)
    }

    
    private fun restoreImages(
        bc: BackupConversation,
        images: Map<String, ByteArray>,
        currentResult: ImportResult,
    ): ImportResult {
        return currentResult.applyImageBatch(restoreImagesWithTracking(bc, images))
    }

    
    private fun parseBackup(bytes: ByteArray): Pair<BackupFile, Map<String, ByteArray>> {
        return try {
            // ZIP magic bytes: PK (0x50 0x4B)
            if (bytes.size >= 2 && bytes[0] == 0x50.toByte() && bytes[1] == 0x4B.toByte()) {
                parseZipBackup(bytes)
            } else if (bytes.isNotEmpty() && bytes[0] == 0x7B.toByte()) {
                
                parseJsonBackup(bytes)
            } else {
                throw BackupError.UnrecognizedFormat
            }
        } catch (error: BackupError) {
            throw error
        } catch (_: Exception) {
            throw BackupError.UnrecognizedFormat
        }
    }

    private fun parseZipBackup(bytes: ByteArray): Pair<BackupFile, Map<String, ByteArray>> {
        val images = mutableMapOf<String, ByteArray>()
        var dataJson: ByteArray? = null
        var totalExpandedBytes = 0L
        val expandedBudget = backupMemoryBudgetBytes()

        try {
            ZipInputStream(ByteArrayInputStream(bytes)).use { zis ->
                var entryCount = 0
                var entry = zis.nextEntry
                while (entry != null) {
                    if (++entryCount > MAX_BACKUP_ZIP_ENTRY_COUNT) throw BackupError.ResourceLimitExceeded
                    val remaining = expandedBudget - totalExpandedBytes
                    val entryBytes = zis.readBytesLimited(minOf(MAX_BACKUP_ZIP_ENTRY_BYTES, remaining))
                    totalExpandedBytes += entryBytes.size
                    if (entry.name == "data.json") {
                        dataJson = entryBytes
                    } else if (entry.name.startsWith("attachments/")) {
                        val filename = entry.name.removePrefix("attachments/")
                        if (filename.isNotEmpty()) {
                            images[filename] = entryBytes
                        }
                    }
                    zis.closeEntry()
                    entry = zis.nextEntry
                }
            }
        } catch (_: InputSizeLimitExceededException) {
            
            throw BackupError.ResourceLimitExceeded
        }

        val jsonBytes = dataJson ?: throw BackupError.UnrecognizedFormat
        val backupFile = json.decodeFromString<BackupFile>(String(jsonBytes, Charsets.UTF_8))
        return backupFile to images
    }

    private fun parseJsonBackup(bytes: ByteArray): Pair<BackupFile, Map<String, ByteArray>> {
        val jsonString = String(bytes, Charsets.UTF_8)

        
        return try {
            val backupFile = json.decodeFromString<BackupFile>(jsonString)
            backupFile to emptyMap()
        } catch (_: Exception) {
            
            val legacy = json.decodeFromString<OriveoBackup>(jsonString)
            val isoFormatter = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).apply {
                timeZone = TimeZone.getTimeZone("UTC")
            }
            val legacyProviders = legacy.providers.mapIndexedNotNull { index, provider ->
                provider.toLegacyBackupProvider(index)
            }
            val fallbackProviderId = legacyProviders.firstOrNull()?.id ?: "legacy-provider"
            val fallbackProviderKind = legacyProviders.firstOrNull()?.kind ?: ProviderKind.OpenAI
            val legacyConversations = legacy.conversations.map { conversation ->
                conversation.toLegacyBackupConversation(
                    fallbackProviderId = fallbackProviderId,
                    fallbackProviderKind = fallbackProviderKind,
                    timestamp = legacy.createdAt,
                )
            }
            val backupFile = BackupFile(
                version = legacy.version,
                createdAt = isoFormatter.format(Date(legacy.createdAt)),
                appVersion = "1.0-legacy",
                platform = "Android Legacy",
                checksum = "",
                containsKeys = false,
                data = BackupData(
                    providers = legacyProviders,
                    conversations = legacyConversations,
                ),
            )
            backupFile to emptyMap()
        }
    }

    private fun validateVersion(backupFile: BackupFile) {
        if (backupFile.version > CURRENT_VERSION) {
            throw BackupError.VersionTooNew(backupFile.version)
        }
    }

    private suspend fun applyImportedPreferences(
        targetAccountId: String,
        importResult: ImportResult,
        backupData: BackupData,
        replaceAll: Boolean,
    ): ImportResult {
        var result = importResult

        if (replaceAll) {
            
            preferenceDao.delete(AppPreferenceKeys.THEME)
            preferenceDao.set(PreferenceEntity(AppPreferenceKeys.LANGUAGE, LanguageOption.System.name))
            clearUserStatePreferences()
        }

        backupData.preferences?.let { preferences ->
            val theme = AppPreferencesRepository.parseThemePreference(preferences.theme) ?: ThemeOption.System
            val language = AppPreferencesRepository.parseLanguagePreference(preferences.language)
                ?: LanguageOption.System
            preferenceDao.set(PreferenceEntity(AppPreferenceKeys.THEME, theme.name))
            preferenceDao.set(PreferenceEntity(AppPreferenceKeys.LANGUAGE, language.name))
            val normalizedMemoryText = preferences.memoryText.trim()
                .takeGraphemes(AppPreferencesRepository.MEMORY_CHARACTER_LIMIT)
            val normalizedAntiForgetText = preferences.memoryAntiForgetText.trim()
                .takeGraphemes(AppPreferencesRepository.MEMORY_ANTI_FORGET_CHARACTER_LIMIT)

            if (normalizedMemoryText.isBlank()) {
                setUserStatePreference(AppPreferenceKeys.MEMORY_TEXT, "")
                setUserStatePreference(AppPreferenceKeys.MEMORY_ANTI_FORGET_ENABLED, "false")
                setUserStatePreference(AppPreferenceKeys.MEMORY_ANTI_FORGET_TEXT, "")
            } else {
                setUserStatePreference(AppPreferenceKeys.MEMORY_TEXT, normalizedMemoryText)
                setUserStatePreference(AppPreferenceKeys.MEMORY_ANTI_FORGET_ENABLED,
                    preferences.memoryAntiForgetEnabled.toString(),
                )
                setUserStatePreference(AppPreferenceKeys.MEMORY_ANTI_FORGET_TEXT, normalizedAntiForgetText)
            }

            preferences.memoryUpdatedAt?.let { updatedAt ->
                setUserStatePreference(AppPreferenceKeys.MEMORY_UPDATED_AT, updatedAt)
            }

            result = result.copy(
                restoredPreferences = true,
                restoredMemory = normalizedMemoryText.isNotBlank(),
            )
        }

        backupData.lastUsedModelRef?.let { lastUsed ->
            setUserStatePreference(AppPreferenceKeys.LAST_USED_PROVIDER_ID, lastUsed.providerID)
            setUserStatePreference(AppPreferenceKeys.LAST_USED_MODEL_ID, lastUsed.modelID)
            result = result.copy(restoredLastUsedModel = true)
        }

        return result
    }

    private suspend fun buildLastUsedModelRef(targetAccountId: String): LastUsedModelRef? {
        val providerId = getUserStatePreference(AppPreferenceKeys.LAST_USED_PROVIDER_ID)
        val modelId = getUserStatePreference(AppPreferenceKeys.LAST_USED_MODEL_ID)
        if (providerId.isNullOrBlank() || modelId.isNullOrBlank()) return null
        return LastUsedModelRef(
            providerID = providerId,
            modelID = modelId,
        )
    }

    private suspend fun <T> runAtomically(block: suspend () -> T): T {
        var result: Result<T>? = null
        runInTransaction {
            result = runCatching { block() }
            result!!.getOrThrow()
        }
        return result!!.getOrThrow()
    }

    private fun restoreProviderKeysAfterFailedReplaceAll(
        accountId: String,
        originalProviderKeys: Map<String, String?>,
        savedProviderIds: Set<String>,
    ) {
        savedProviderIds.forEach { providerId ->
            val originalKey = originalProviderKeys[providerId]
            if (originalKey.isNullOrBlank()) {
                secureKeyStore.deleteApiKey(accountId, providerId)
            } else {
                secureKeyStore.saveApiKey(accountId, providerId, originalKey)
            }
        }
    }

    private fun restoreImagesWithTracking(
        bc: BackupConversation,
        images: Map<String, ByteArray>,
    ): RestoredImageBatch {
        var restoredImages = 0
        var skippedImages = 0
        val snapshots = linkedMapOf<String, AttachmentImageSnapshot>()

        try {
            for (msg in bc.messages) {
                val atts = msg.attachments ?: continue
                for (att in atts) {
                    if (att.kind != AttachmentKind.Image) continue
                    val lid = att.localImageId ?: continue
                    
                    
                    if (!AttachmentStore.isSafeImageId(lid)) {
                        skippedImages += 1
                        continue
                    }

                    
                    
                    
                    
                    
                    
                    val candidateNames = listOf(att.id, lid)
                        .distinct()
                        .filter { AttachmentStore.isSafeImageId(it) }
                    val candidateExtensions = imageExtensionCandidates(att.mimeType)

                    snapshots.getOrPut(lid) {
                        AttachmentImageSnapshot(
                            localImageId = lid,
                            imageBytes = attachmentStore.loadImageBytes(lid),
                            thumbnailBytes = attachmentStore.loadThumbnailBytes(lid),
                        )
                    }

                    val imgData = findAttachmentEntry(images, candidateNames, candidateExtensions, "")
                    if (imgData != null) {
                        attachmentStore.saveImageRaw(lid, imgData)
                        restoredImages += 1
                    } else {
                        skippedImages += 1
                    }

                    findAttachmentEntry(images, candidateNames, candidateExtensions, ".thumb")
                        ?.let { thumbData -> attachmentStore.saveThumbnailRaw(lid, thumbData) }
                }
            }
        } catch (error: Throwable) {
            rollbackRestoredImages(snapshots.values)
            throw error
        }

        return RestoredImageBatch(
            restoredImages = restoredImages,
            skippedImages = skippedImages,
            snapshots = snapshots.values.toList(),
        )
    }

    
    private fun imageExtensionCandidates(mimeType: String): List<String> {
        val mimeExtension = when (mimeType.substringAfter('/', "").lowercase()) {
            "png" -> "png"
            "gif" -> "gif"
            "webp" -> "webp"
            "heic", "heif" -> "heic"
            else -> "jpg"
        }
        return if (mimeExtension == "jpg") listOf("jpg") else listOf(mimeExtension, "jpg")
    }

    
    private fun findAttachmentEntry(
        images: Map<String, ByteArray>,
        names: List<String>,
        extensions: List<String>,
        suffix: String,
    ): ByteArray? {
        for (name in names) {
            for (extension in extensions) {
                images["$name$suffix.$extension"]?.let { return it }
            }
        }
        
        
        
        
        
        val wanted = buildSet {
            for (name in names) {
                for (extension in extensions) add("$name$suffix.$extension".lowercase())
            }
        }
        return images.entries.firstOrNull { it.key.lowercase() in wanted }?.value
    }

    private fun rollbackRestoredImages(snapshots: Iterable<AttachmentImageSnapshot>) {
        snapshots.forEach { snapshot ->
            attachmentStore.delete(snapshot.localImageId)
            snapshot.imageBytes?.let { imageBytes ->
                attachmentStore.saveImageRaw(snapshot.localImageId, imageBytes)
            }
            snapshot.thumbnailBytes?.let { thumbnailBytes ->
                attachmentStore.saveThumbnailRaw(snapshot.localImageId, thumbnailBytes)
            }
        }
    }

    private fun ImportResult.applyImageBatch(batch: RestoredImageBatch): ImportResult {
        return copy(
            restoredImages = restoredImages + batch.restoredImages,
            skippedImages = skippedImages + batch.skippedImages,
        )
    }

    private suspend fun getUserStatePreference(key: String): String? = preferenceDao.get(key)

    private suspend fun setUserStatePreference(key: String, value: String) {
        preferenceDao.set(PreferenceEntity(key, value))
    }

    private suspend fun clearUserStatePreferences() {
        AppPreferenceKeys.USER_STATE_KEYS.forEach { key -> preferenceDao.delete(key) }
    }

    
    private fun BackupProvider.toProvider(): ai.oriveo.community.core.model.Provider {
        val isRelay = kind == ai.oriveo.community.core.model.ProviderKind.Relay
        return ai.oriveo.community.core.model.Provider(
            id = id,
            kind = kind,
            status = ProviderConnectionState.Issue("Needs setup"),
            models = models,
            catalogModels = if (isRelay) catalogModels else emptyList(),
            apiKey = "",
            apiKeyPreview = "",
            baseUrlText = baseURLText,
            customName = customName,
            relayKind = relayKind,
            relayRequested = relayRequested,
            relayImage = relayImage,
        )
    }

    private fun BackupFolder.toFolderEntity(accountId: String) =
        ai.oriveo.community.core.data.entity.FolderEntity(
            id = id,
            name = name,
            sortOrder = sortOrder,
            createdAt = createdAt,
            updatedAt = updatedAt,
            accountId = accountId,
        )

    
    private fun ai.oriveo.community.core.model.Note.toBackupNote() = BackupNote(
        id = id,
        title = title,
        titleSource = titleSource.rawValue,
        body = body,
        bodySnapshot = bodySnapshot,
        userNote = userNote,
        tags = tags,
        noteFolderID = noteFolderID,
        sourceConversationId = sourceConversationId,
        sourceMessageId = sourceMessageId,
        sourceModelID = sourceModelID,
        sourceModelName = sourceModelName,
        sourceProviderKind = sourceProviderKind?.rawValue,
        sourceProviderName = sourceProviderName,
        sourcePrompt = sourcePrompt,
        captureKind = captureKind.rawValue,
        provenance = provenance,
        isPinned = isPinned,
        createdAt = createdAt,
        updatedAt = updatedAt,
        deletedAt = deletedAt,
    )

    private fun BackupNote.toNote(): ai.oriveo.community.core.model.Note = ai.oriveo.community.core.model.Note(
        id = normalizeUuid(id),
        title = title,
        titleSource = ai.oriveo.community.core.model.NoteTitleSource.fromRawValue(titleSource),
        body = body,
        bodySnapshot = bodySnapshot,
        userNote = userNote,
        tags = tags,
        noteFolderID = noteFolderID?.let(::normalizeUuid),
        sourceConversationId = sourceConversationId?.let(::normalizeUuid),
        sourceMessageId = sourceMessageId?.let(::normalizeUuid),
        sourceModelID = sourceModelID,
        sourceModelName = sourceModelName,
        sourceProviderKind = sourceProviderKind?.let { ai.oriveo.community.core.model.ProviderKind.fromRawValue(it) },
        sourceProviderName = sourceProviderName,
        sourcePrompt = sourcePrompt,
        captureKind = ai.oriveo.community.core.model.NoteCaptureKind.fromRawValue(captureKind),
        provenance = provenance,
        isPinned = isPinned,
        createdAt = createdAt,
        updatedAt = updatedAt,
        deletedAt = deletedAt,
    )

    private fun BackupNote.withValidNoteFolder(activeNoteFolderIDs: Set<String>): BackupNote {
        val normalizedFolderId = noteFolderID?.let(::normalizeUuid) ?: return copy(noteFolderID = null)
        return if (normalizedFolderId in activeNoteFolderIDs) {
            copy(noteFolderID = normalizedFolderId)
        } else {
            copy(noteFolderID = null)
        }
    }

    private fun BackupNote.toNoteEntity(accountId: String) =
        EntityMapper.run { toNote().toEntity(accountId) }

    private fun ai.oriveo.community.core.model.NoteFolder.toBackupNoteFolder() = BackupNoteFolder(
        id = id,
        name = name,
        sortOrder = sortOrder,
        colorTag = colorTag,
        createdAt = createdAt,
        updatedAt = updatedAt,
        deletedAt = deletedAt,
    )

    private fun BackupNoteFolder.toNoteFolder() = ai.oriveo.community.core.model.NoteFolder(
        id = normalizeUuid(id),
        name = name,
        sortOrder = sortOrder,
        colorTag = colorTag,
        createdAt = createdAt,
        updatedAt = updatedAt,
        deletedAt = deletedAt,
    )

    private fun BackupNoteFolder.toNoteFolderEntity(accountId: String) =
        EntityMapper.run { toNoteFolder().toEntity(accountId) }

    
    private suspend fun importNoteEntity(entity: ai.oriveo.community.core.data.entity.NoteEntity) {
        if (entity.deletedAt == null) {
            val note = EntityMapper.run { entity.toDomain() }
            noteDao.upsertWithIndex(
                entity,
                ai.oriveo.community.core.data.mapper.NoteMapper.ftsTitle(note),
                ai.oriveo.community.core.data.mapper.NoteMapper.ftsBody(note),
                ai.oriveo.community.core.data.mapper.NoteMapper.ftsUserNote(note),
                ai.oriveo.community.core.data.mapper.NoteMapper.ftsTagsText(note),
            )
        } else {
            noteDao.upsert(entity)
            noteDao.deleteSearchIndex(entity.accountId, entity.id)
        }
    }

    /** ChatMessage → MessageEntity */
    private fun ChatMessage.toMessageEntity(accountId: String, conversationId: String, sortOrder: Int) =
        EntityMapper.run {
            this@toMessageEntity.toEntity(accountId, conversationId, sortOrder)
        }

    
    private suspend fun slimMessageAttachmentsForImport(message: ChatMessage): ChatMessage {
        val attachments = message.attachments
        if (attachments.isNullOrEmpty()) return message
        val slimmed = attachments.map { attachment ->
            runCatching {
                AttachmentSlimmer.slim(
                    attachment = attachment,
                    saveImage = { bytes -> attachmentStore.saveImage(bytes, attachment.mimeType) },
                    saveBlob = { bytes -> attachmentStore.saveBlob(bytes) },
                )
            }.getOrDefault(attachment)
        }
        return message.copy(attachments = slimmed)
    }

    private suspend fun collectAttachmentIds(accountId: String): Set<String> {
        return conversationDao.getAll(accountId)
            .flatMap { conversation -> messageDao.getByConversation(accountId, conversation.id) }
            .flatMap { message ->
                decodeAttachments(message.attachmentsJson)
                    .mapNotNull { attachment -> attachment.localImageId }
            }
            .toSet()
    }

    private fun collectAttachmentIds(conversations: List<BackupConversation>): Set<String> {
        return conversations
            .flatMap { conversation -> conversation.messages }
            .flatMap { message -> message.attachments.orEmpty() }
            .mapNotNull { attachment -> attachment.localImageId }
            .toSet()
    }

    private fun decodeAttachments(raw: String?): List<Attachment> {
        val value = raw?.takeIf { it.isNotBlank() } ?: return emptyList()
        return runCatching {
            json.decodeFromString(ListSerializer(Attachment.serializer()), value)
        }.getOrDefault(emptyList())
    }

    private suspend fun buildBackupPreferencesFromLocalState(
        targetAccountId: String,
    ): BackupPreferences {
        
        val theme = AppPreferencesRepository.parseThemePreference(preferenceDao.get(PREF_KEY_THEME))
            ?: ThemeOption.Dark
        val language = AppPreferencesRepository.parseLanguagePreference(preferenceDao.get(PREF_KEY_LANGUAGE))
            ?: LanguageOption.System
        return BackupPreferences(
            theme = AppPreferencesRepository.serializeThemePreference(theme),
            language = AppPreferencesRepository.serializeLanguagePreference(language),
            memoryText = getUserStatePreference(AppPreferenceKeys.MEMORY_TEXT).orEmpty(),
            memoryAntiForgetEnabled = getUserStatePreference(AppPreferenceKeys.MEMORY_ANTI_FORGET_ENABLED)?.toBooleanStrictOrNull() ?: false,
            memoryAntiForgetText = getUserStatePreference(AppPreferenceKeys.MEMORY_ANTI_FORGET_TEXT).orEmpty(),
            memoryUpdatedAt = getUserStatePreference(AppPreferenceKeys.MEMORY_UPDATED_AT),
        )
    }

    private fun buildBackupPreferencesFromSyncPayload(
        preferences: Map<String, Any>,
    ): BackupPreferences? {
        if (preferences.isEmpty()) return null
        val theme = preferences["theme"]?.toString()
        val language = preferences["language"]?.toString()
        val memoryText = preferences["memoryText"]?.toString().orEmpty()
        val memoryAntiForgetEnabled = when (val value = preferences["memoryAntiForgetEnabled"]) {
            is Boolean -> value
            is String -> value.toBooleanStrictOrNull() ?: false
            else -> false
        }
        val memoryAntiForgetText = preferences["memoryAntiForgetText"]?.toString().orEmpty()
        val memoryUpdatedAt = preferences["memoryUpdatedAt"]?.toString()
        if (theme == null &&
            language == null &&
            memoryText.isBlank() &&
            !memoryAntiForgetEnabled &&
            memoryAntiForgetText.isBlank() &&
            memoryUpdatedAt == null
        ) {
            return null
        }
        return BackupPreferences(
            theme = theme ?: AppPreferencesRepository.serializeThemePreference(ThemeOption.Dark),
            language = language ?: AppPreferencesRepository.serializeLanguagePreference(LanguageOption.System),
            memoryText = memoryText,
            memoryAntiForgetEnabled = memoryAntiForgetEnabled,
            memoryAntiForgetText = memoryAntiForgetText,
            memoryUpdatedAt = memoryUpdatedAt,
        )
    }

    
    private fun sha256Checksum(data: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val hash = digest.digest(data)
        val hex = hash.joinToString("") { "%02x".format(it) }
        return "sha256:$hex"
    }

    

    
    suspend fun createBackup(): String {
        val scopedAccountId = accountId
        val providers = providerDao.getAll(scopedAccountId).map { it.toDomain() }
        val conversations = conversationDao.getAll(scopedAccountId)

        val convBackups = conversations.map { conv ->
            val msgCount = messageDao.getByConversation(scopedAccountId, conv.id).size
            ConversationBackup(
                id = conv.id,
                title = conv.title,
                messageCount = msgCount,
            )
        }

        val backup = OriveoBackup(
            version = 1,
            createdAt = System.currentTimeMillis(),
            providers = providers.map { p ->
                ProviderBackup(
                    kind = p.kind.name,
                    displayName = p.displayName,
                    apiKeyPreview = p.apiKeyPreview,
                    modelCount = p.enabledModelCount,
                )
            },
            conversations = convBackups,
        )

        return json.encodeToString(backup)
    }

    @kotlinx.serialization.Serializable
    data class OriveoBackup(
        val version: Int,
        val createdAt: Long,
        val providers: List<ProviderBackup>,
        val conversations: List<ConversationBackup>,
    )

    @kotlinx.serialization.Serializable
    data class ProviderBackup(
        val kind: String,
        val displayName: String,
        val apiKeyPreview: String,
        val modelCount: Int,
    )

    @kotlinx.serialization.Serializable
    data class ConversationBackup(
        val id: String,
        val title: String,
        val messageCount: Int,
    )

    private fun ProviderBackup.toLegacyBackupProvider(index: Int): BackupProvider? {
        val providerKind = runCatching { ProviderKind.valueOf(kind) }.getOrNull() ?: return null
        return BackupProvider(
            id = "legacy-provider-$index-${providerKind.name.lowercase()}",
            kind = providerKind,
            customName = displayName.takeIf { it.isNotBlank() && it != providerKind.displayName },
            models = emptyList(),
            catalogModels = emptyList(),
        )
    }

    private fun ConversationBackup.toLegacyBackupConversation(
        fallbackProviderId: String,
        fallbackProviderKind: ProviderKind,
        timestamp: Long,
    ): BackupConversation {
        return BackupConversation(
            id = id,
            title = title,
            hasCustomTitle = title.isNotBlank(),
            providerID = fallbackProviderId,
            providerKind = fallbackProviderKind,
            modelID = "legacy-model",
            useMemory = true,
            previewText = title,
            estimatedCost = 0.0,
            messages = emptyList(),
            createdAt = timestamp,
            updatedAt = timestamp,
        )
    }
}
