package ai.oriveo.community.core.model

import kotlinx.serialization.Serializable

enum class ImportMode(
    val titleResId: Int,
    val descriptionResId: Int,
) {
    ImportNewOnly(
        titleResId = ai.oriveo.community.R.string.import_mode_new_only,
        descriptionResId = ai.oriveo.community.R.string.import_mode_new_only_desc,
    ),
    Merge(
        titleResId = ai.oriveo.community.R.string.import_mode_merge,
        descriptionResId = ai.oriveo.community.R.string.import_mode_merge_desc,
    ),
    ReplaceAll(
        titleResId = ai.oriveo.community.R.string.import_mode_replace_all,
        descriptionResId = ai.oriveo.community.R.string.import_mode_replace_all_desc,
    );

    val isDefault: Boolean
        get() = this == ImportNewOnly
}

data class ImportPreview(
    val backupCreatedAt: String,
    val backupPlatform: String,
    val backupAppVersion: String,
    val containsKeys: Boolean,
    val totalConversations: Int,
    val existingConversations: Int,
    val totalProviders: Int,
    val existingProviders: Int,
    val totalMessages: Int,
    val totalImages: Int,
)

data class BackupInspection(
    val preview: ImportPreview,
    val checksumWarning: Boolean,
    val attachmentWarning: Boolean,
    val requiresKeyPassword: Boolean,
)

data class ImportResult(
    val newConversations: Int = 0,
    val skippedConversations: Int = 0,
    val mergedConversations: Int = 0,
    val newProviders: Int = 0,
    val skippedProviders: Int = 0,
    val newSkills: Int = 0,
    val mergedSkills: Int = 0,
    val skippedSkills: Int = 0,
    val newNotes: Int = 0,
    val mergedNotes: Int = 0,
    val skippedNotes: Int = 0,
    val newNoteFolders: Int = 0,
    val mergedNoteFolders: Int = 0,
    val skippedNoteFolders: Int = 0,
    val restoredKeys: Int = 0,
    val restoredImages: Int = 0,
    val skippedImages: Int = 0,
    val restoredPreferences: Boolean = false,
    val restoredLastUsedModel: Boolean = false,
    val restoredMemory: Boolean = false,
) {
    val hasChanges: Boolean
        get() = newConversations > 0 || mergedConversations > 0 ||
            newProviders > 0 || newSkills > 0 || mergedSkills > 0 ||
            newNotes > 0 || mergedNotes > 0 || newNoteFolders > 0 || mergedNoteFolders > 0 ||
            restoredKeys > 0 || restoredPreferences || restoredLastUsedModel ||
            restoredMemory
}

sealed class BackupError(message: String) : IllegalArgumentException(message) {
    data object UnrecognizedFormat : BackupError("UNRECOGNIZED_FORMAT")
    data class VersionTooNew(val version: Int) : BackupError("VERSION_TOO_NEW")
    data object WrongPassword : BackupError("WRONG_PASSWORD")
    data object NoDataToExport : BackupError("NO_DATA_TO_EXPORT")
    data object AccountChanged : BackupError("ACCOUNT_CHANGED")

    data object ResourceLimitExceeded : BackupError("RESOURCE_LIMIT_EXCEEDED")
}

@Serializable
data class BackupFile(
    val version: Int,
    val createdAt: String,
    val appVersion: String,
    val platform: String,
    val checksum: String,
    val containsKeys: Boolean,
    val data: BackupData,
    val attachmentChecksums: Map<String, String>? = null,
    val encryptedKeys: String? = null,
)

@Serializable
data class BackupData(
    val providers: List<BackupProvider> = emptyList(),
    val folders: List<BackupFolder> = emptyList(),
    val conversations: List<BackupConversation> = emptyList(),
    val skills: List<Skill> = emptyList(),
    val preferences: BackupPreferences? = null,
    val lastUsedModelRef: LastUsedModelRef? = null,
    val notes: List<BackupNote> = emptyList(),
    val noteFolders: List<BackupNoteFolder> = emptyList(),
)

@Serializable
data class BackupProvider(
    val id: String,
    val kind: ProviderKind,
    val baseURLText: String? = null,
    val customName: String? = null,
    val relayKind: RelayKind? = null,
    val models: List<AIModel> = emptyList(),
    val catalogModels: List<AIModel> = emptyList(),
    val relayRequested: RelayRequestedConfig? = null,
    val relayImage: RelayImageConfig? = null,
)

@Serializable
data class BackupFolder(
    val id: String,
    val name: String,
    val sortOrder: Int,
    val createdAt: Long,
    val updatedAt: Long,
)

@Serializable
data class BackupConversation(
    val id: String,
    val title: String,
    val hasCustomTitle: Boolean = false,
    val providerID: String,
    val providerKind: ProviderKind,
    val modelID: String,
    val useMemory: Boolean = true,
    val previewText: String = "",
    val estimatedCost: Double = 0.0,
    val messages: List<ChatMessage> = emptyList(),
    val folderID: String? = null,
    val skillId: String? = null,
    val createdAt: Long = 0L,
    val updatedAt: Long = 0L,
    val pinnedNoteIds: List<String> = emptyList(),
)

@Serializable
data class BackupNote(
    val id: String,
    val title: String,
    val titleSource: String,
    val body: String,
    val bodySnapshot: String? = null,
    val userNote: String? = null,
    val tags: List<String> = emptyList(),
    val noteFolderID: String? = null,
    val sourceConversationId: String? = null,
    val sourceMessageId: String? = null,
    val sourceModelID: String? = null,
    val sourceModelName: String? = null,
    val sourceProviderKind: String? = null,
    val sourceProviderName: String? = null,
    val sourcePrompt: String? = null,
    val captureKind: String,
    val provenance: List<ProvenanceEntry> = emptyList(),
    val isPinned: Boolean = false,
    val createdAt: String,
    val updatedAt: String,
    val deletedAt: String? = null,
)

@Serializable
data class BackupNoteFolder(
    val id: String,
    val name: String,
    val sortOrder: Int,
    val colorTag: String? = null,
    val createdAt: String,
    val updatedAt: String,
    val deletedAt: String? = null,
)

@Serializable
data class BackupPreferences(
    val theme: String = "system",
    val language: String = "system",
    val memoryText: String = "",
    val memoryAntiForgetEnabled: Boolean = false,
    val memoryAntiForgetText: String = "",
    val memoryUpdatedAt: String? = null,
)

@Serializable
data class BackupKeyEntry(
    val providerID: String,
    val apiKey: String,
    val apiKeyPreview: String,
)

@Serializable
data class BackupKeysPayload(
    val keys: List<BackupKeyEntry>,
)
