package ai.oriveo.community.core.memory

import android.util.Log
import ai.oriveo.community.core.app.AppPreferenceKeys
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.context.MemoryBackup
import ai.oriveo.community.core.context.MemoryBackupMode
import ai.oriveo.community.core.context.MemoryConflictResolution
import ai.oriveo.community.core.context.MemoryItem
import ai.oriveo.community.core.context.MemoryItemDraft
import ai.oriveo.community.core.context.MemoryItemScope
import ai.oriveo.community.core.context.MemoryItemSource
import ai.oriveo.community.core.context.MemoryItems
import ai.oriveo.community.core.context.MemoryKind
import ai.oriveo.community.core.context.MemoryLayer
import ai.oriveo.community.core.context.MemoryLegacyPrefs
import ai.oriveo.community.core.context.MemoryLegacySync
import ai.oriveo.community.core.context.MemoryMergeResult
import ai.oriveo.community.core.context.MemoryRecall
import ai.oriveo.community.core.context.MemoryScopeType
import ai.oriveo.community.core.context.MemorySensitivity
import ai.oriveo.community.core.context.MemoryServerTime
import ai.oriveo.community.core.context.MemorySourceType
import ai.oriveo.community.core.context.MemoryStatus
import ai.oriveo.community.core.data.dao.MemoryItemDao
import ai.oriveo.community.core.data.dao.PreferenceDao
import ai.oriveo.community.core.data.entity.MemoryItemEntity
import ai.oriveo.community.core.data.entity.PreferenceEntity
import ai.oriveo.community.core.model.ImportMode
import java.time.Instant
import java.time.temporal.ChronoUnit
import java.util.UUID
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json

/**
 * Local repository of memory items: create, read, update, delete and observe, per account.
 * Every write gets a fresh mutationId (random lowercase UUID), baseRevision = the current revision, the local deviceId, and is marked pending;
 * a new item's createdAt is the local time; deleting writes a tombstone and never hard-deletes the row.
 * The legacy preference (memoryText) is aligned both ways: when an account is activated or its memoryText changes, legacySync runs (migration / edits made by an older client flowing back),
 * and after a local item write the compiled result and its digest are written back to memoryText.
 */
class MemoryItemRepository(
    private val dao: MemoryItemDao,
    private val preferenceDao: PreferenceDao,
    private val preferences: AppPreferencesRepository,
    private val now: () -> Instant = Instant::now,
    private val newId: () -> String = { UUID.randomUUID().toString() },
    /** Local transaction (production injects db.withTransaction): insert opens it under the write lock when `alongside` is given; the lock order is always write lock -> transaction. */
    private val runInTransaction: suspend (suspend () -> Unit) -> Unit = { block -> block() },
) {
    private val deviceIdMutex = Mutex()

    // Item writes and legacy alignment are serialized so the double write never reads a half-done state. Applying sync results locally takes this lock too, so it never interleaves with local edits.
    private val writeMutex = Mutex()

    /** Callback after a local write leaves an item pending (the memory sync engine pushes on it); the argument is the account id. */
    @Volatile var onLocalWrite: ((accountId: String) -> Unit)? = null

    /** All items (tombstones included), ordered by MemoryItems.listOrder. */
    fun observe(accountId: String): Flow<List<MemoryItem>> =
        dao.observe(accountId).map { rows -> MemoryItems.listOrder(rows.map { it.toItem() }) }

    /** All items following the current account (same as [observe]); chat sends inject memory from it. */
    @OptIn(ExperimentalCoroutinesApi::class)
    fun observeCurrent(accountIds: Flow<String>): Flow<List<MemoryItem>> =
        accountIds.distinctUntilChanged().flatMapLatest { accountId -> observe(accountId) }

    suspend fun list(accountId: String): List<MemoryItem> =
        MemoryItems.listOrder(dao.list(accountId).map { it.toItem() })

    suspend fun get(accountId: String, id: String): MemoryItem? = dao.get(accountId, id.lowercase())?.toItem()

    /** Local writes waiting to be pushed. */
    suspend fun pending(accountId: String): List<MemoryItem> =
        MemoryItems.listOrder(dao.listBySyncState(accountId, MemoryItemEntity.SYNC_PENDING).map { it.toItem() })

    @Suppress("LongParameterList")
    suspend fun create(
        accountId: String,
        kind: MemoryKind,
        content: String,
        layer: MemoryLayer = MemoryLayer.SEMANTIC,
        scope: MemoryItemScope = MemoryItemScope(),
        source: MemoryItemSource = MemoryItemSource(),
        pinned: Boolean = false,
        /** L3 only: when the event happened; null = now (memory-recall.v1 rule 9). */
        occurredAt: String? = null,
    ): MemoryItem {
        val createdAt = now().toString()
        val item = MemoryItems.canonical(
            MemoryItem(
                id = newId(),
                layer = layer,
                kind = kind,
                content = content,
                scope = scope,
                source = source,
                pinned = pinned,
                mutationId = newId(),
                deviceId = deviceId(),
                occurredAt = l3OccurredAt(layer, occurredAt, createdAt),
                createdAt = MemoryServerTime.At(createdAt),
            ),
        )
        return insert(accountId, item)
    }

    /**
     * Creates an item after a candidate is accepted: the same creation path as [create] (new id, pending, double write, notification),
     * additionally carrying the draft's status / sensitivity / confidence; source.observedAt is observedAtMs as UTC RFC 3339 (truncated to seconds, with Z).
     * [alongside]: an extra write in the same write lock and the same transaction as the creation (deleting the candidate row on accept); any failure rolls everything back and the exception is rethrown.
     */
    suspend fun createFromDraft(
        accountId: String,
        draft: MemoryItemDraft,
        alongside: (suspend () -> Unit)? = null,
    ): MemoryItem {
        val createdAt = now().toString()
        val item = MemoryItems.canonical(
            MemoryItem(
                id = newId(),
                layer = draft.layer,
                kind = draft.kind,
                status = draft.status,
                content = draft.content,
                scope = draft.scope,
                source = MemoryItemSource(
                    type = draft.source.type,
                    conversationId = draft.source.conversationId,
                    messageIds = draft.source.messageIds,
                    observedAt = draft.source.observedAtMs?.let {
                        Instant.ofEpochMilli(it).truncatedTo(ChronoUnit.SECONDS).toString()
                    },
                ),
                sensitivity = draft.sensitivity,
                confidence = draft.confidence,
                mutationId = newId(),
                deviceId = deviceId(),
                occurredAt = l3OccurredAt(draft.layer, null, createdAt),
                createdAt = MemoryServerTime.At(createdAt),
            ),
        )
        return insert(accountId, item, alongside)
    }

    private fun l3OccurredAt(layer: MemoryLayer, given: String?, nowText: String): String? =
        if (layer == MemoryLayer.EPISODIC) given ?: nowText else given

    /**
     * The new item is stored; an L3 item is checked for conflicts after saving (memory-recall.v1 rule 10): on a hit both the new and the old item become conflicted,
     * conflictGroupId = the old item's id, written as ordinary local edits (L3 is not synced). Returns the new item as stored.
     * When [alongside] is non-null the whole block runs in one transaction under the write lock (the lock is taken before the transaction, the same lock order as applying sync results locally, so they never wait on each other).
     */
    private suspend fun insert(
        accountId: String,
        item: MemoryItem,
        alongside: (suspend () -> Unit)? = null,
    ): MemoryItem = writeMutex.withLock {
        if (alongside == null) return@withLock insertLocked(accountId, item)
        lateinit var saved: MemoryItem
        runInTransaction {
            saved = insertLocked(accountId, item)
            alongside()
        }
        saved
    }

    private suspend fun insertLocked(accountId: String, item: MemoryItem): MemoryItem {
        dao.upsert(item.toEntity(accountId, MemoryItemEntity.SYNC_PENDING))
        var saved = item
        if (item.layer == MemoryLayer.EPISODIC) {
            val olderId = MemoryRecall.conflict(item, list(accountId))
            val older = olderId?.let { live(accountId, it) }
            if (older != null) {
                saved = localEdit(item, item.copy(status = MemoryStatus.CONFLICTED, conflictGroupId = older.id))
                dao.upsert(saved.toEntity(accountId, MemoryItemEntity.SYNC_PENDING))
                val olderConflicted = localEdit(older, older.copy(status = MemoryStatus.CONFLICTED, conflictGroupId = older.id))
                dao.upsert(olderConflicted.toEntity(accountId, MemoryItemEntity.SYNC_PENDING))
            }
        }
        afterLocalWrite(accountId)
        return saved
    }

    /**
     * Resolves an L3 conflict (memory-recall.v1 rule 11): writes the two patches of [MemoryRecall.resolve] locally and deletes nothing.
     * Returns null when either item does not exist, is deleted, or is not L3; otherwise returns [newer, older] as written.
     */
    suspend fun resolveL3Conflict(
        accountId: String,
        newerId: String,
        olderId: String,
        resolution: MemoryConflictResolution,
    ): List<MemoryItem>? = writeMutex.withLock {
        val newer = live(accountId, newerId)?.takeIf { it.layer == MemoryLayer.EPISODIC } ?: return@withLock null
        val older = live(accountId, olderId)?.takeIf { it.layer == MemoryLayer.EPISODIC } ?: return@withLock null
        val written = MemoryRecall.resolve(newer, older, resolution).zip(listOf(newer, older)).map { (patch, current) ->
            localEdit(current, patch.applyTo(current)).also { dao.upsert(it.toEntity(accountId, MemoryItemEntity.SYNC_PENDING)) }
        }
        afterLocalWrite(accountId)
        written
    }

    /** Metadata of one local edit: a new mutationId, baseRevision = the current revision, the local deviceId. */
    private suspend fun localEdit(current: MemoryItem, changed: MemoryItem): MemoryItem = MemoryItems.canonical(
        changed.copy(baseRevision = current.revision, mutationId = newId(), deviceId = deviceId()),
    )

    /** Changes the body (kind can change with it; for L3 occurredAt can change too, null leaves it alone); returns null when the item does not exist or is deleted. */
    suspend fun edit(
        accountId: String,
        id: String,
        content: String,
        kind: MemoryKind? = null,
        occurredAt: String? = null,
    ): MemoryItem? = mutate(accountId, id) {
        it.copy(content = content, kind = kind ?: it.kind, occurredAt = occurredAt ?: it.occurredAt)
    }

    suspend fun setPinned(accountId: String, id: String, pinned: Boolean): MemoryItem? =
        mutate(accountId, id) { it.copy(pinned = pinned) }

    /** Pause = status paused, resume = active. */
    suspend fun setPaused(accountId: String, id: String, paused: Boolean): MemoryItem? =
        mutate(accountId, id) { it.copy(status = if (paused) MemoryStatus.PAUSED else MemoryStatus.ACTIVE) }

    /** Writes a tombstone; returns null when the item does not exist or is deleted. */
    suspend fun delete(accountId: String, id: String): MemoryItem? = writeMutex.withLock {
        val current = live(accountId, id) ?: return@withLock null
        val tombstone = MemoryItems.tombstone(current, newId(), deviceId(), now().toString())
        dao.upsert(tombstone.toEntity(accountId, MemoryItemEntity.SYNC_PENDING))
        afterLocalWrite(accountId)
        tombstone
    }

    /**
     * Aligns the legacy preference and the items once: migrates when not yet migrated (when another client already migrated and the digest matches, only the flag is set),
     * and when already migrated but memoryText was edited by an older client, flows it back into memoryText and migrates the items; when needed writes the compiled result and its digest back to the preference.
     */
    suspend fun reconcileLegacy(accountId: String): MemoryLegacySync = writeMutex.withLock {
        reconcileLocked(accountId).also { if (it.create.isNotEmpty() || it.update.isNotEmpty()) onLocalWrite?.invoke(accountId) }
    }

    /**
     * Resolves a conflict: the kept item returns to active with conflictGroupId cleared, the others in the group get tombstones; all become pending for push.
     * Returns null when [keepId] does not exist, is deleted, or is not in the conflict group.
     */
    suspend fun resolveConflict(accountId: String, keepId: String): MemoryItem? = writeMutex.withLock {
        val keep = live(accountId, keepId) ?: return@withLock null
        val groupId = keep.conflictGroupId ?: return@withLock null
        val device = deviceId()
        val kept = MemoryItems.canonical(
            keep.copy(
                status = MemoryStatus.ACTIVE,
                conflictGroupId = null,
                baseRevision = keep.revision,
                mutationId = newId(),
                deviceId = device,
            ),
        )
        dao.upsert(kept.toEntity(accountId, MemoryItemEntity.SYNC_PENDING))
        list(accountId)
            .filter { it.conflictGroupId == groupId && it.id != kept.id && it.status != MemoryStatus.DELETED }
            .forEach { other ->
                val tombstone = MemoryItems.tombstone(other, newId(), device, now().toString())
                dao.upsert(tombstone.toEntity(accountId, MemoryItemEntity.SYNC_PENDING))
            }
        afterLocalWrite(accountId)
        kept
    }

    /**
     * Applies a push result locally: the local row is replaced by [settled] and marked synced only if it is still the mutation that was pushed.
     * If it was edited locally during the push and this write already reached the remote ([settled] is the pushed mutation), the new edit moves onto the written revision and stays pending.
     */
    internal suspend fun syncSettle(accountId: String, pushed: MemoryItem, settled: MemoryItem): Unit = writeMutex.withLock {
        val current = get(accountId, pushed.id) ?: return@withLock
        if (current.mutationId == pushed.mutationId) {
            dao.upsert(MemoryItems.canonical(settled).toEntity(accountId, MemoryItemEntity.SYNC_SYNCED))
        } else if (settled.mutationId == pushed.mutationId && current.baseRevision == pushed.baseRevision) {
            val rebased = current.copy(revision = settled.revision, baseRevision = settled.revision, createdAt = settled.createdAt)
            dao.upsert(rebased.toEntity(accountId, MemoryItemEntity.SYNC_PENDING))
        }
    }

    /** The tombstone to write when restricted is revoked: this item, with mutationId and deviceId taken from the pending item, deletedAt = now. */
    internal fun syncRetraction(pending: MemoryItem): MemoryItem =
        MemoryItems.tombstone(pending, pending.mutationId, pending.deviceId, now().toString())

    /** A push hit a conflict: the original item takes the remote body as the conflict item (with a new local mutationId) and the local edit becomes the conflict copy, both marked pending; a local change, so double write. */
    internal suspend fun syncConflict(accountId: String, pending: MemoryItem, remote: MemoryItem): Unit = writeMutex.withLock {
        val current = get(accountId, pending.id) ?: return@withLock
        if (current.mutationId != pending.mutationId) return@withLock
        writeConflict(accountId, current, remote)
    }

    /** Merges one remote item into the local store (MemoryItems.merge); items merged in from remote do not recompile memoryText, only a conflict produced by the merge double-writes as a local change. */
    internal suspend fun syncApplyRemote(accountId: String, remote: MemoryItem): Unit = writeMutex.withLock {
        val incoming = MemoryItems.canonical(remote)
        val row = dao.get(accountId, incoming.id)
        val current = row?.toItem()
        val pending = current?.takeIf { row.syncState == MemoryItemEntity.SYNC_PENDING }
        val outcome = MemoryItems.merge(current?.version(), incoming.version(), pending?.version())
        when (outcome.result) {
            MemoryMergeResult.APPLY_REMOTE, MemoryMergeResult.PENDING_CONFIRMED ->
                dao.upsert(incoming.toEntity(accountId, MemoryItemEntity.SYNC_SYNCED))
            MemoryMergeResult.CONFLICT -> if (pending != null) writeConflict(accountId, pending, incoming)
            MemoryMergeResult.NOOP, MemoryMergeResult.IGNORE_REMOTE, MemoryMergeResult.KEEP_PENDING -> Unit
        }
    }

    private suspend fun writeConflict(accountId: String, pending: MemoryItem, remote: MemoryItem) {
        val conflict = MemoryItems.conflictCopy(pending.id, pending, remote, newId())
        dao.upsert(conflict.original.toEntity(accountId, MemoryItemEntity.SYNC_PENDING))
        dao.upsert(conflict.copy.toEntity(accountId, MemoryItemEntity.SYNC_PENDING))
        afterLocalWrite(accountId)
    }

    /**
     * Backup import (called after the legacy preference is restored): ReplaceAll lands the backup items as a whole, local live items missing from the backup become tombstones (existing local tombstones are kept as is);
     * Merge takes the higher revision per MemoryItems.backupMerge (never resurrects a local tombstone); ImportNewOnly only adds ids the device lacks (a tombstone counts as present).
     * An older backup without memoryItems migrates from its preference, create-if-absent under Merge / ImportNewOnly; a backup with the section marks this account migrated after import. Imported rows are always pending;
     * afterwards memoryText is double-written for local changes (the timestamp is refreshed only when textChanged) and the sync engine is woken. Returns the number of rows written.
     */
    suspend fun importBackup(accountId: String, mode: ImportMode, backup: MemoryBackup): Int = writeMutex.withLock {
        val local = list(accountId).map(MemoryItems::canonical)
        val device = deviceId()
        val written = when {
            mode == ImportMode.ReplaceAll -> {
                val incoming = MemoryItems.backupMerge(MemoryBackupMode.REPLACE, local, backup, accountId, device)
                val missing = MemoryItems.backupReplaceTombstonedIds(local, incoming).toSet()
                val deletedAt = now().toString()
                incoming + local.filter { it.id in missing }.map { MemoryItems.tombstone(it, newId(), device, deletedAt) }
            }
            mode == ImportMode.Merge && backup.memoryItems != null -> {
                val localById = local.associateBy { it.id }
                MemoryItems.backupMerge(MemoryBackupMode.MERGE, local, backup, accountId, device).filter { localById[it.id] != it }
            }
            else -> {
                val localIds = local.map { it.id }.toSet()
                val incoming = backup.memoryItems ?: backup.preferences?.let { MemoryItems.migrate(accountId, device, it) }.orEmpty()
                incoming.map(MemoryItems::canonical).filter { it.id !in localIds }.distinctBy { it.id }
            }
        }
        written.forEach { dao.upsert(it.toEntity(accountId, MemoryItemEntity.SYNC_PENDING)) }
        // A backup that carries the items section is authoritative (the client that wrote it already migrated), so every mode sets the migrated flag; otherwise the restored memoryText would be migrated again into duplicate items. A backup without the section migrates as before.
        if (backup.memoryItems != null) preferences.setMemoryItemsMigrated()
        afterLocalWrite(accountId)
        written.size
    }

    /** Reconciles whenever the current account or this account's memoryText changes; suspends until cancelled. */
    @OptIn(ExperimentalCoroutinesApi::class)
    suspend fun runLegacyReconcile(accountIds: Flow<String>) {
        accountIds
            .distinctUntilChanged()
            .flatMapLatest { accountId -> preferences.observeMemoryText().map { accountId to it } }
            .distinctUntilChanged()
            .collect { (accountId, _) ->
                try {
                    reconcileLegacy(accountId)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    // One failed alignment does not stop the listener: it retries on the next memoryText change or restart.
                    Log.w(TAG, "legacy reconcile failed", e)
                }
            }
    }

    /** The local memory device id: shared across accounts, generated on first use. */
    suspend fun deviceId(): String = deviceIdMutex.withLock {
        preferenceDao.get(AppPreferenceKeys.MEMORY_DEVICE_ID)
            ?: newId().lowercase().also { preferenceDao.set(PreferenceEntity(AppPreferenceKeys.MEMORY_DEVICE_ID, it)) }
    }

    private suspend fun live(accountId: String, id: String): MemoryItem? =
        get(accountId, id)?.takeIf { it.status != MemoryStatus.DELETED }

    private suspend fun mutate(accountId: String, id: String, change: (MemoryItem) -> MemoryItem): MemoryItem? = writeMutex.withLock {
        val current = live(accountId, id) ?: return@withLock null
        val updated = MemoryItems.canonical(
            change(current).copy(
                baseRevision = current.revision,
                mutationId = newId(),
                deviceId = deviceId(),
            ),
        )
        dao.upsert(updated.toEntity(accountId, MemoryItemEntity.SYNC_PENDING))
        afterLocalWrite(accountId)
        updated
    }

    private suspend fun reconcileLocked(accountId: String): MemoryLegacySync {
        val migrated = preferences.getMemoryItemsMigrated()
        val prefs = MemoryLegacyPrefs(
            memoryText = preferences.getMemoryText(),
            memoryTextDigest = preferences.getMemoryTextDigest(),
            antiForgetEnabled = preferences.getMemoryAntiForgetEnabled(),
            antiForgetText = preferences.getMemoryAntiForgetText(),
            memoryUpdatedAt = preferences.getMemoryUpdatedAt(),
        )
        val result = MemoryItems.legacySync(
            uid = accountId,
            migrated = migrated,
            deviceId = deviceId(),
            items = list(accountId),
            prefs = prefs,
            deletedAt = now().toString(),
        )
        (result.create + result.update).forEach { dao.upsert(it.toEntity(accountId, MemoryItemEntity.SYNC_PENDING)) }
        if (!migrated) preferences.setMemoryItemsMigrated()
        result.writePrefs?.let { writeLegacy(accountId, it.memoryText, it.memoryTextDigest, it.textChanged) }
        return result
    }

    /** After a local write: migrates first if not yet migrated, then double-writes only when the compiled result or digest differs from the preference; finally wakes the sync engine. */
    private suspend fun afterLocalWrite(accountId: String) {
        if (!preferences.getMemoryItemsMigrated()) reconcileLocked(accountId)
        val compile = MemoryItems.compileLegacy(accountId, list(accountId))
        val textChanged = preferences.getMemoryText() != compile.memoryText
        if (textChanged || preferences.getMemoryTextDigest() != compile.memoryTextDigest) {
            writeLegacy(accountId, compile.memoryText, compile.memoryTextDigest, textChanged)
        }
        onLocalWrite?.invoke(accountId)
    }

    /** Refreshes memoryUpdatedAt and pushes only when the body changed; when only the digest is filled in, writes locally only. */
    private suspend fun writeLegacy(accountId: String, memoryText: String, memoryTextDigest: String, textChanged: Boolean) {
        if (textChanged) {
            preferences.saveMemoryCompile(memoryText, memoryTextDigest, now().toString())
        } else {
            preferences.saveMemoryTextDigest(memoryTextDigest)
        }
    }

    private companion object {
        const val TAG = "MemoryItemRepository"
    }
}

private val memoryRowJson = Json { ignoreUnknownKeys = true }
private val stringList = ListSerializer(String.serializer())

private fun encodeList(values: List<String>): String = memoryRowJson.encodeToString(stringList, values)

private fun decodeList(raw: String): List<String> =
    runCatching { memoryRowJson.decodeFromString(stringList, raw) }.getOrDefault(emptyList())

private fun MemoryServerTime?.encode(): String? = when (this) {
    null -> null
    is MemoryServerTime.At -> rfc3339
    MemoryServerTime.ServerTimestamp -> MemoryItemEntity.SERVER_TIMESTAMP
}

private fun String?.decodeServerTime(): MemoryServerTime? = when (this) {
    null -> null
    MemoryItemEntity.SERVER_TIMESTAMP -> MemoryServerTime.ServerTimestamp
    else -> MemoryServerTime.At(this)
}

internal fun MemoryItem.toEntity(accountId: String, syncState: String): MemoryItemEntity = MemoryItemEntity(
    accountId = accountId,
    id = id,
    schemaVersion = schemaVersion,
    layer = layer.wire,
    kind = kind.wire,
    status = status.wire,
    content = content,
    scopeType = scope.type.wire,
    scopeId = scope.id,
    sourceType = source.type.wire,
    sourceConversationId = source.conversationId,
    sourceMessageIds = encodeList(source.messageIds),
    sourceObservedAt = source.observedAt,
    sensitivity = sensitivity.wire,
    confidence = confidence,
    priority = priority,
    pinned = pinned,
    revision = revision,
    baseRevision = baseRevision,
    mutationId = mutationId,
    deviceId = deviceId,
    conflictGroupId = conflictGroupId,
    occurredAt = occurredAt,
    validFrom = validFrom.encode(),
    lastConfirmedAt = lastConfirmedAt.encode(),
    createdAt = createdAt.encode(),
    updatedAt = updatedAt.encode(),
    expiresAt = expiresAt,
    deletedAt = deletedAt,
    supersedes = encodeList(supersedes),
    syncState = syncState,
)

/** Unknown enum values fall back to the default (so rows from old or newer versions do not crash reads); an unknown status falls back to paused so an item nobody understands is never injected. */
internal fun MemoryItemEntity.toItem(): MemoryItem = MemoryItem(
    id = id,
    schemaVersion = schemaVersion,
    layer = MemoryLayer.fromWire(layer) ?: MemoryLayer.SEMANTIC,
    kind = MemoryKind.fromWire(kind) ?: MemoryKind.FACT,
    status = MemoryStatus.fromWire(status) ?: MemoryStatus.PAUSED,
    content = content,
    scope = MemoryItemScope(MemoryScopeType.fromWire(scopeType) ?: MemoryScopeType.GLOBAL, scopeId),
    source = MemoryItemSource(
        type = MemorySourceType.fromWire(sourceType) ?: MemorySourceType.MANUAL,
        conversationId = sourceConversationId,
        messageIds = decodeList(sourceMessageIds),
        observedAt = sourceObservedAt,
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
    validFrom = validFrom.decodeServerTime(),
    lastConfirmedAt = lastConfirmedAt.decodeServerTime(),
    createdAt = createdAt.decodeServerTime(),
    updatedAt = updatedAt.decodeServerTime(),
    expiresAt = expiresAt,
    deletedAt = deletedAt,
    supersedes = decodeList(supersedes),
)

internal fun MemoryItem.version(): ai.oriveo.community.core.context.MemoryItemVersion =
    ai.oriveo.community.core.context.MemoryItemVersion(
        revision = revision,
        mutationId = mutationId,
        status = status,
        content = content,
        baseRevision = baseRevision,
        sensitivity = sensitivity,
    )
