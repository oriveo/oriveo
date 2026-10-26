package ai.oriveo.community.core.model

import ai.oriveo.community.core.context.MemoryItem
import ai.oriveo.community.core.context.MemoryItemScope
import ai.oriveo.community.core.context.MemoryItemSource
import ai.oriveo.community.core.context.MemoryItems
import ai.oriveo.community.core.context.MemoryKind
import ai.oriveo.community.core.context.MemoryLayer
import ai.oriveo.community.core.context.MemoryScopeType
import ai.oriveo.community.core.context.MemorySensitivity
import ai.oriveo.community.core.context.MemoryServerTime
import ai.oriveo.community.core.context.MemorySourceType
import ai.oriveo.community.core.context.MemoryStatus
import ai.oriveo.community.core.data.repository.ContextCheckpointKind
import ai.oriveo.community.core.data.repository.ContextCheckpointRecord
import ai.oriveo.community.core.context.ContextBudgetCap
import kotlinx.serialization.EncodeDefault
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull

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
    /** Context checkpoints; absent in older backups. */
    val checkpoints: List<BackupContextCheckpoint> = emptyList(),
    /** Memory item contract version (memory-items.v2 backup rule); null in backups written before memory items. */
    val memorySchemaVersion: Int? = null,
    /** Every memory item of the account, tombstones and conflicts included; read only when [memorySchemaVersion] is set. */
    val memoryItems: List<BackupMemoryItem> = emptyList(),
)

/** Memory item scope in a backup (memory-items.v2 wire form). */
@Serializable
data class BackupMemoryItemScope(val type: String = MemoryScopeType.GLOBAL.wire, val id: String? = null)

/** Memory item source in a backup (memory-items.v2 wire form). */
@Serializable
data class BackupMemoryItemSource(
    val type: String = MemorySourceType.MANUAL.wire,
    val conversationId: String? = null,
    val messageIds: List<String> = emptyList(),
    val observedAt: String? = null,
)

/**
 * One memory item in a backup: memory-items.v2 wire form, keys in fieldOrder; server-time fields are RFC3339 or null.
 * Unknown enum values fall back like stored rows (unknown status → paused, so an unreadable item is never injected).
 */
@Serializable
data class BackupMemoryItem(
    val id: String,
    val schemaVersion: Int = MemoryItems.SCHEMA_VERSION,
    val layer: String = MemoryLayer.SEMANTIC.wire,
    val kind: String,
    val status: String = MemoryStatus.ACTIVE.wire,
    val content: String,
    val scope: BackupMemoryItemScope = BackupMemoryItemScope(),
    val source: BackupMemoryItemSource = BackupMemoryItemSource(),
    val sensitivity: String = MemorySensitivity.NORMAL.wire,
    val confidence: Double = 1.0,
    val priority: Int = 0,
    val pinned: Boolean = false,
    val revision: Int = 1,
    val baseRevision: Int = 0,
    val mutationId: String,
    val deviceId: String,
    val conflictGroupId: String? = null,
    val occurredAt: String? = null,
    val validFrom: String? = null,
    val lastConfirmedAt: String? = null,
    val createdAt: String? = null,
    val updatedAt: String? = null,
    val expiresAt: String? = null,
    val deletedAt: String? = null,
    val supersedes: List<String> = emptyList(),
) {
    fun toItem(): MemoryItem = MemoryItem(
        id = id,
        schemaVersion = schemaVersion,
        layer = MemoryLayer.fromWire(layer) ?: MemoryLayer.SEMANTIC,
        kind = MemoryKind.fromWire(kind) ?: MemoryKind.FACT,
        status = MemoryStatus.fromWire(status) ?: MemoryStatus.PAUSED,
        content = content,
        scope = MemoryItemScope(MemoryScopeType.fromWire(scope.type) ?: MemoryScopeType.GLOBAL, scope.id),
        source = MemoryItemSource(
            type = MemorySourceType.fromWire(source.type) ?: MemorySourceType.MANUAL,
            conversationId = source.conversationId,
            messageIds = source.messageIds,
            observedAt = source.observedAt,
        ),
        sensitivity = MemorySensitivity.fromWire(sensitivity) ?: MemorySensitivity.NORMAL,
        confidence = confidence,
        priority = priority,
        pinned = pinned,
        revision = revision,
        baseRevision = baseRevision,
        mutationId = mutationId,
        deviceId = deviceId,
        conflictGroupId = conflictGroupId,
        occurredAt = occurredAt,
        validFrom = validFrom?.let(MemoryServerTime::At),
        lastConfirmedAt = lastConfirmedAt?.let(MemoryServerTime::At),
        createdAt = createdAt?.let(MemoryServerTime::At),
        updatedAt = updatedAt?.let(MemoryServerTime::At),
        expiresAt = expiresAt,
        deletedAt = deletedAt,
        supersedes = supersedes,
    )

    companion object {
        /** [item] comes from MemoryItems.backupSection, so pending server times are already null. */
        fun from(item: MemoryItem) = BackupMemoryItem(
            id = item.id,
            schemaVersion = item.schemaVersion,
            layer = item.layer.wire,
            kind = item.kind.wire,
            status = item.status.wire,
            content = item.content,
            scope = BackupMemoryItemScope(item.scope.type.wire, item.scope.id),
            source = BackupMemoryItemSource(
                type = item.source.type.wire,
                conversationId = item.source.conversationId,
                messageIds = item.source.messageIds,
                observedAt = item.source.observedAt,
            ),
            sensitivity = item.sensitivity.wire,
            confidence = item.confidence,
            priority = item.priority,
            pinned = item.pinned,
            revision = item.revision,
            baseRevision = item.baseRevision,
            mutationId = item.mutationId,
            deviceId = item.deviceId,
            conflictGroupId = item.conflictGroupId,
            occurredAt = item.occurredAt,
            validFrom = item.validFrom.rfc3339(),
            lastConfirmedAt = item.lastConfirmedAt.rfc3339(),
            createdAt = item.createdAt.rfc3339(),
            updatedAt = item.updatedAt.rfc3339(),
            expiresAt = item.expiresAt,
            deletedAt = item.deletedAt,
            supersedes = item.supersedes,
        )

        private fun MemoryServerTime?.rfc3339(): String? = (this as? MemoryServerTime.At)?.rfc3339
    }
}

/**
 * One checkpoint row in a backup. Carries conversationId but no accountId —
 * import writes into the current account. [createdAt] is epoch milliseconds.
 */
@Serializable
data class BackupContextCheckpoint(
    val conversationId: String,
    val checkpointId: String,
    val kind: String,
    val coversFrom: String,
    val coversTo: String,
    val coversDigest: String,
    val messagesCovered: Int,
    val userMessageIds: List<String>,
    val text: String,
    val summary: String? = null,
    val language: String? = null,
    val model: String,
    val packerVersion: String,
    val createdAt: Long,
    val cost: Double? = null,
) {
    /** Null when [kind] is unknown to this build. */
    fun toRecord(): ContextCheckpointRecord? {
        val parsedKind = ContextCheckpointKind.fromWire(kind) ?: return null
        return ContextCheckpointRecord(
            conversationId = conversationId,
            checkpointId = checkpointId,
            kind = parsedKind,
            coversFrom = coversFrom,
            coversTo = coversTo,
            coversDigest = coversDigest,
            messagesCovered = messagesCovered,
            userMessageIds = userMessageIds,
            text = text,
            summary = summary,
            language = language,
            model = model,
            packerVersion = packerVersion,
            createdAt = createdAt,
            cost = cost,
        )
    }

    companion object {
        fun from(record: ContextCheckpointRecord) = BackupContextCheckpoint(
            conversationId = record.conversationId,
            checkpointId = record.checkpointId,
            kind = record.kind.wire,
            coversFrom = record.coversFrom,
            coversTo = record.coversTo,
            coversDigest = record.coversDigest,
            messagesCovered = record.messagesCovered,
            userMessageIds = record.userMessageIds,
            text = record.text,
            summary = record.summary,
            language = record.language,
            model = record.model,
            packerVersion = record.packerVersion,
            createdAt = record.createdAt,
            cost = record.cost,
        )
    }
}

/** A sanitized provider in a backup. */
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

/** A conversation in a backup. */
@OptIn(ExperimentalSerializationApi::class)
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
    /**
     * Non-USD conversation totals (currency code to total). With no non-USD part `{}` is written (reading `{}` clears them); a key missing in an older backup = none (a merge import keeps the local value).
     * This device's "thread complete" marker is not part of backups.
     */
    @EncodeDefault(EncodeDefault.Mode.NEVER)
    val nonUsdCostTotals: Map<String, Double>? = null,
    val messages: List<ChatMessage> = emptyList(),
    val folderID: String? = null,
    val skillId: String? = null,
    val createdAt: Long = 0L,
    val updatedAt: Long = 0L,
    val pinnedNoteIds: List<String> = emptyList(),
    /**
     * Conversation-level instructions (conversation-instructions.v1). Null = a key missing in an older backup: a fresh import stores an empty string,
     * and a merge leaves the local instructions alone; an explicit "" is a real value and clears them as usual when the backup side wins the merge (fixture conversation-backup-merge.v1).
     */
    @EncodeDefault(EncodeDefault.Mode.NEVER)
    val instructions: String? = null,
    /**
     * Raw wire value of the conversation input budget cap: taken as a plain JSON element, and reading goes through [parsedContextCap],
     * which parses leniently: an invalid value (such as "190000", an out-of-range number, a boolean) = follow the global setting instead of failing the whole import;
     * a key missing in an older backup = follow the global setting.
     * When following the global setting the key is omitted on export (no null is written), consistent with iOS and Web.
     */
    @EncodeDefault(EncodeDefault.Mode.NEVER)
    val contextCap: JsonElement? = null,
) {
    /** The parsed cap; null = follow the global setting. */
    val parsedContextCap: ContextBudgetCap?
        get() = contextCapFromWire(contextCap)

    companion object {
        /** Cap -> backup wire: auto / unlimited are written as strings, a custom cap as a number; null when following the global setting. */
        fun contextCapWire(cap: ContextBudgetCap?): JsonElement? = when (cap) {
            null -> null
            is ContextBudgetCap.Custom -> JsonPrimitive(cap.tokens)
            else -> JsonPrimitive(cap.wire as String)
        }

        /** Backup wire -> cap: restores the native value first and then goes through [ContextBudgetCap.parse]; rejection = null. */
        fun contextCapFromWire(element: JsonElement?): ContextBudgetCap? {
            val primitive = element as? JsonPrimitive ?: return null
            val raw: Any? = when {
                primitive.isString -> primitive.content
                primitive.booleanOrNull != null -> return null
                else -> primitive.longOrNull ?: primitive.doubleOrNull
            }
            return ContextBudgetCap.parse(raw)
        }
    }
}

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
