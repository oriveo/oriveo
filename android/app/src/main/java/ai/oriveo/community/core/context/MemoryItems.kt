package ai.oriveo.community.core.context

import ai.oriveo.community.core.mcp.mcpSha256Hex
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.util.DeterministicProviderId
import java.nio.ByteBuffer
import java.time.Instant
import java.time.OffsetDateTime
import java.util.Locale
import java.util.UUID
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

enum class MemoryLayer(val wire: String) {
    SEMANTIC("semantic"),
    EPISODIC("episodic"),
    ;

    companion object {
        fun fromWire(wire: String): MemoryLayer? = entries.firstOrNull { it.wire == wire }
    }
}

enum class MemoryKind(val wire: String) {
    IDENTITY("identity"),
    PREFERENCE("preference"),
    INSTRUCTION("instruction"),
    CONSTRAINT("constraint"),
    PROJECT("project"),
    GOAL("goal"),
    DECISION("decision"),
    FACT("fact"),
    EVENT("event"),
    ;

    companion object {
        fun fromWire(wire: String): MemoryKind? = entries.firstOrNull { it.wire == wire }

        /** The eight semantic kinds an organize response may use; `event` is episodic only. */
        val SEMANTIC: List<MemoryKind> = listOf(IDENTITY, PREFERENCE, INSTRUCTION, CONSTRAINT, PROJECT, GOAL, DECISION, FACT)
    }
}

enum class MemoryStatus(val wire: String) {
    ACTIVE("active"),
    PAUSED("paused"),
    SUPERSEDED("superseded"),
    DELETED("deleted"),
    EXPIRED("expired"),
    CONFLICTED("conflicted"),
    ;

    companion object {
        fun fromWire(wire: String): MemoryStatus? = entries.firstOrNull { it.wire == wire }
    }
}

enum class MemoryScopeType(val wire: String) {
    GLOBAL("global"),
    FOLDER("folder"),
    CONVERSATION("conversation"),
    ;

    companion object {
        fun fromWire(wire: String): MemoryScopeType? = entries.firstOrNull { it.wire == wire }
    }
}

enum class MemorySourceType(val wire: String) {
    MANUAL("manual"),
    CONVERSATION("conversation"),
    IMPORT("import"),
    MIGRATION("migration"),
    ;

    companion object {
        fun fromWire(wire: String): MemorySourceType? = entries.firstOrNull { it.wire == wire }
    }
}

enum class MemorySensitivity(val wire: String) {
    NORMAL("normal"),
    SENSITIVE("sensitive"),
    RESTRICTED("restricted"),
    ;

    companion object {
        fun fromWire(wire: String): MemorySensitivity? = entries.firstOrNull { it.wire == wire }
    }
}

/** Server-time field value: a time read back from the server, or the server timestamp placeholder of a write. */
sealed interface MemoryServerTime {
    data class At(val rfc3339: String) : MemoryServerTime

    data object ServerTimestamp : MemoryServerTime
}

data class MemoryItemScope(val type: MemoryScopeType = MemoryScopeType.GLOBAL, val id: String? = null)

data class MemoryItemSource(
    val type: MemorySourceType = MemorySourceType.MANUAL,
    val conversationId: String? = null,
    val messageIds: List<String> = emptyList(),
    val observedAt: String? = null,
)

/** Memory item v2; property order follows memory-items.v2.json fieldOrder, defaults follow its defaults. */
data class MemoryItem(
    val id: String,
    val schemaVersion: Int = MemoryItems.SCHEMA_VERSION,
    val layer: MemoryLayer = MemoryLayer.SEMANTIC,
    val kind: MemoryKind,
    val status: MemoryStatus = MemoryStatus.ACTIVE,
    val content: String,
    val scope: MemoryItemScope = MemoryItemScope(),
    val source: MemoryItemSource = MemoryItemSource(),
    val sensitivity: MemorySensitivity = MemorySensitivity.NORMAL,
    val confidence: Double = 1.0,
    val priority: Int = 0,
    val pinned: Boolean = false,
    val revision: Int = 1,
    val baseRevision: Int = 0,
    val mutationId: String,
    val deviceId: String,
    val conflictGroupId: String? = null,
    val occurredAt: String? = null,
    val validFrom: MemoryServerTime? = null,
    val lastConfirmedAt: MemoryServerTime? = null,
    val createdAt: MemoryServerTime? = null,
    val updatedAt: MemoryServerTime? = null,
    val expiresAt: String? = null,
    val deletedAt: String? = null,
    val supersedes: List<String> = emptyList(),
)

/** The parts of one item version that sync merge and push compare; `revision` is unset on a pending edit. */
data class MemoryItemVersion(
    val revision: Int?,
    val mutationId: String,
    val status: MemoryStatus,
    val content: String,
    val baseRevision: Int? = null,
    val sensitivity: MemorySensitivity = MemorySensitivity.NORMAL,
)

/** Legacy preference fields (memoryText / Anti-Forget) as stored before memory items. */
data class MemoryLegacyPrefs(
    val memoryText: String,
    val memoryTextDigest: String? = null,
    val antiForgetEnabled: Boolean = false,
    val antiForgetText: String = "",
    val memoryUpdatedAt: String? = null,
)

data class MemoryInjection(val standingInstructions: List<MemoryItem>, val memory: List<MemoryItem>)

enum class MemoryMergeResult(val wire: String) {
    APPLY_REMOTE("applyRemote"),
    NOOP("noop"),
    IGNORE_REMOTE("ignoreRemote"),
    CONFLICT("conflict"),
    PENDING_CONFIRMED("pendingConfirmed"),
    KEEP_PENDING("keepPending"),
}

/** `keep` lists the mutation ids of the versions that survive the merge. */
data class MemoryMergeOutcome(val result: MemoryMergeResult, val keep: List<String>, val status: MemoryStatus)

enum class MemoryPushAction(val wire: String) {
    WRITE("write"),
    CONFIRMED("confirmed"),
    DROP_PENDING("dropPending"),
    CONFLICT("conflict"),
    RETRACT("retract"),
    LOCAL_ONLY("localOnly"),
}

/**
 * `revision` is the revision to write for [MemoryPushAction.WRITE] / [MemoryPushAction.RETRACT],
 * the revision the local item settles on (its baseRevision) for [MemoryPushAction.LOCAL_ONLY], null otherwise.
 */
data class MemoryPushOutcome(val action: MemoryPushAction, val revision: Int? = null)

data class MemoryConflict(val original: MemoryItem, val copy: MemoryItem)

data class MemoryLegacyCompile(val memoryText: String, val memoryTextDigest: String)

/** Legacy preferences to write; `textChanged` is true when the compiled memoryText differs from the local one. */
data class MemoryLegacyWrite(val memoryText: String, val memoryTextDigest: String, val textChanged: Boolean)

/** `writePrefs` null means the legacy preferences already hold the compile. */
data class MemoryLegacySync(
    val create: List<MemoryItem>,
    val update: List<MemoryItem>,
    val writePrefs: MemoryLegacyWrite?,
)

sealed interface MemoryRawOp {
    data class Update(val id: String, val content: String) : MemoryRawOp

    data class Create(val id: String, val kind: MemoryKind, val content: String) : MemoryRawOp

    data class Delete(val id: String) : MemoryRawOp
}

sealed interface MemoryRawApply {
    data class Ops(val ops: List<MemoryRawOp>) : MemoryRawApply

    /** `index` counts the non-empty segments of the edited text. */
    data class TooLong(val index: Int) : MemoryRawApply
}

data class MemoryOrganizeMessage(val role: ChatRole, val text: String)

data class MemoryOrganizeRequest(val system: String, val messages: List<MemoryOrganizeMessage>)

data class MemoryOrganizedItem(val kind: MemoryKind, val content: String)

data class MemoryBackupSection(val memorySchemaVersion: Int, val memoryItems: List<MemoryItem>)

/** A backup file's memory part: `memoryItems` when written by a v2 client, else only the legacy preferences. */
data class MemoryBackup(val memoryItems: List<MemoryItem>?, val preferences: MemoryLegacyPrefs?)

enum class MemoryBackupMode { MERGE, REPLACE }

/** Pure functions of the memory item v2 contract (memory-items.v2.json). */
object MemoryItems {
    const val SCHEMA_VERSION: Int = 2
    const val UUID_NAMESPACE: String = "7b430abd-757c-5561-bdc9-40d1e677748c"
    const val UUID_NAMESPACE_URL: String = "https://oriveo.app/ns/memory-item"
    const val LEGACY_KEY_MEMORY_TEXT: String = "legacy-memoryText"
    const val LEGACY_KEY_ANTI_FORGET: String = "legacy-antiforget"
    const val MIGRATION_MUTATION_SUFFIX: String = "migration-1"
    const val CONFLICT_MUTATION_SUFFIX: String = "conflict-1"
    const val LEGACY_MUTATION_PREFIX: String = "legacy-"
    const val CONTENT_MAX_CODE_POINTS: Int = 2000
    const val ORGANIZE_SYSTEM_PROMPT: String =
        "Split the saved memory below into separate items. Each item states exactly one fact, preference, instruction, " +
            "constraint or project. Keep the user's language and wording; do not add, infer, merge away or drop information. " +
            "Reply with only a JSON array, no prose: [{\"kind\": \"identity|preference|instruction|constraint|project|goal|decision|fact\", " +
            "\"content\": \"...\"}]."
    const val ORGANIZE_MAX_ITEMS: Int = 20
    const val RAW_VIEW_SEPARATOR: String = "---"
    private const val LEGACY_COMPILE_SEPARATOR: String = "\n\n"

    private val namespaceBytes: ByteArray by lazy {
        val uuid = UUID.fromString(UUID_NAMESPACE)
        ByteBuffer.allocate(16).putLong(uuid.mostSignificantBits).putLong(uuid.leastSignificantBits).array()
    }

    /** UUIDv5(namespace, name), lowercase. */
    fun uuid(name: String): String = DeterministicProviderId.uuidV5(namespaceBytes, name).lowercase()

    // ---- canonical ----

    /** Lowercases id / mutationId / conflictGroupId / supersedes; content stays byte for byte. */
    fun canonical(item: MemoryItem): MemoryItem = item.copy(
        id = item.id.lowercase(),
        mutationId = item.mutationId.lowercase(),
        conflictGroupId = item.conflictGroupId?.lowercase(),
        supersedes = item.supersedes.map { it.lowercase() },
    )

    // ---- migration ----

    fun legacyItemId(uid: String, legacyKey: String): String = uuid("$uid\n$legacyKey")

    /** Items for the legacy memoryText / Anti-Forget preferences; ids are deterministic, write with create-if-absent. */
    fun migrate(uid: String, deviceId: String, prefs: MemoryLegacyPrefs): List<MemoryItem> {
        val items = mutableListOf<MemoryItem>()
        val memoryTrimmed = prefs.memoryText.trimWhiteSpace()
        if (memoryTrimmed.isNotEmpty()) {
            items += migrationItem(uid, LEGACY_KEY_MEMORY_TEXT, MemoryKind.FACT, MemoryStatus.ACTIVE, prefs.memoryText, deviceId, prefs.memoryUpdatedAt)
        }
        val antiForgetTrimmed = prefs.antiForgetText.trimWhiteSpace()
        if (antiForgetTrimmed.isNotEmpty() && antiForgetTrimmed != memoryTrimmed) {
            val status = if (prefs.antiForgetEnabled) MemoryStatus.ACTIVE else MemoryStatus.PAUSED
            items += migrationItem(uid, LEGACY_KEY_ANTI_FORGET, MemoryKind.INSTRUCTION, status, prefs.antiForgetText, deviceId, prefs.memoryUpdatedAt)
        }
        return items
    }

    @Suppress("LongParameterList")
    private fun migrationItem(
        uid: String,
        legacyKey: String,
        kind: MemoryKind,
        status: MemoryStatus,
        content: String,
        deviceId: String,
        observedAt: String?,
    ): MemoryItem {
        val id = legacyItemId(uid, legacyKey)
        return MemoryItem(
            id = id,
            kind = kind,
            status = status,
            content = content,
            source = MemoryItemSource(type = MemorySourceType.MIGRATION, observedAt = observedAt),
            mutationId = uuid("$id\n$MIGRATION_MUTATION_SUFFIX"),
            deviceId = deviceId,
        )
    }

    // ---- injection ----

    /** Semantic, active, unexpired items in scope; instruction / constraint → standing, others → memory; pinned first, then input order. */
    fun injectable(items: List<MemoryItem>, conversationId: String, folderId: String?, now: Instant): MemoryInjection {
        // Scope ids compare case-insensitively (iOS stores uppercase UUIDs, Web / Android lowercase).
        val conversationKey = conversationId.lowercase()
        val folderKey = folderId?.lowercase()
        val eligible = items.filter { item ->
            val expires = item.expiresAt
            val scopeKey = item.scope.id?.lowercase()
            val inScope = when (item.scope.type) {
                MemoryScopeType.GLOBAL -> true
                MemoryScopeType.CONVERSATION -> scopeKey == conversationKey
                MemoryScopeType.FOLDER -> folderKey != null && scopeKey == folderKey
            }
            item.layer == MemoryLayer.SEMANTIC &&
                item.status == MemoryStatus.ACTIVE &&
                (expires == null || instant(expires).isAfter(now)) &&
                inScope
        }.map(::canonical)
        val (standing, memory) = eligible.partition { it.kind == MemoryKind.INSTRUCTION || it.kind == MemoryKind.CONSTRAINT }
        return MemoryInjection(pinnedFirst(standing), pinnedFirst(memory))
    }

    private fun pinnedFirst(items: List<MemoryItem>): List<MemoryItem> = items.filter { it.pinned } + items.filterNot { it.pinned }

    // ---- list order ----

    private val listComparator: Comparator<MemoryItem> = Comparator<MemoryItem> { a, b -> b.pinned.compareTo(a.pinned) }
        .thenComparator { a, b -> compareCreatedAt(a.createdAt, b.createdAt) }
        .thenBy { it.id.lowercase() }

    /** Pinned first, then createdAt ascending (null first, compared as instants), then id ascending. */
    fun listOrder(items: List<MemoryItem>): List<MemoryItem> = items.sortedWith(listComparator)

    /** null < any instant < a pending server timestamp (the server sets it to the write time). */
    private fun compareCreatedAt(a: MemoryServerTime?, b: MemoryServerTime?): Int {
        fun rank(t: MemoryServerTime?): Int = when (t) {
            null -> 0
            is MemoryServerTime.At -> 1
            MemoryServerTime.ServerTimestamp -> 2
        }
        if (a is MemoryServerTime.At && b is MemoryServerTime.At) return instant(a.rfc3339).compareTo(instant(b.rfc3339))
        return rank(a).compareTo(rank(b))
    }

    private fun instant(rfc3339: String): Instant = OffsetDateTime.parse(rfc3339).toInstant()

    // ---- tombstone ----

    /** Delete: keeps id, schemaVersion, layer, kind, createdAt; empties the body; revision unchanged until pushed. */
    fun tombstone(item: MemoryItem, mutationId: String, deviceId: String, deletedAt: String): MemoryItem = canonical(
        MemoryItem(
            id = item.id,
            schemaVersion = item.schemaVersion,
            layer = item.layer,
            kind = item.kind,
            status = MemoryStatus.DELETED,
            content = "",
            revision = item.revision,
            baseRevision = item.revision,
            mutationId = mutationId,
            deviceId = deviceId,
            createdAt = item.createdAt,
            deletedAt = deletedAt,
        ),
    )

    // ---- sync merge ----

    /** Merges one remote version into the local one and the pending local mutation, if any. */
    fun merge(local: MemoryItemVersion?, remote: MemoryItemVersion, pending: MemoryItemVersion?): MemoryMergeOutcome {
        val remoteRevision = remote.revision ?: 0
        if (local?.sensitivity == MemorySensitivity.RESTRICTED || pending?.sensitivity == MemorySensitivity.RESTRICTED) {
            // A restricted local item ignores every remote version, including the echo of its own retraction.
            return if (pending != null) {
                MemoryMergeOutcome(MemoryMergeResult.KEEP_PENDING, listOf(pending.mutationId), pending.status)
            } else {
                MemoryMergeOutcome(MemoryMergeResult.IGNORE_REMOTE, listOf(local!!.mutationId), local.status)
            }
        }
        if (pending != null) {
            if (remote.mutationId == pending.mutationId) {
                return MemoryMergeOutcome(MemoryMergeResult.PENDING_CONFIRMED, listOf(pending.mutationId), pending.status)
            }
            val baseRevision = pending.baseRevision ?: 0
            if (remoteRevision <= baseRevision) {
                // The remote is not newer than the base of the pending edit: the edit stays pending.
                return MemoryMergeOutcome(MemoryMergeResult.KEEP_PENDING, listOf(pending.mutationId), pending.status)
            }
            if (baseRevision == 0) {
                // A pending create (create-if-absent) meeting an existing remote: the remote wins, never a conflict.
                return MemoryMergeOutcome(MemoryMergeResult.APPLY_REMOTE, listOf(remote.mutationId), remote.status)
            }
            return when {
                pending.status == MemoryStatus.DELETED ->
                    MemoryMergeOutcome(MemoryMergeResult.KEEP_PENDING, listOf(pending.mutationId), MemoryStatus.DELETED)
                remote.status == MemoryStatus.DELETED || sameBody(remote, pending) ->
                    MemoryMergeOutcome(MemoryMergeResult.APPLY_REMOTE, listOf(remote.mutationId), remote.status)
                else ->
                    MemoryMergeOutcome(MemoryMergeResult.CONFLICT, listOf(remote.mutationId, pending.mutationId), MemoryStatus.CONFLICTED)
            }
        }
        if (local == null) return MemoryMergeOutcome(MemoryMergeResult.APPLY_REMOTE, listOf(remote.mutationId), remote.status)
        val localRevision = local.revision ?: 0
        return when {
            remoteRevision > localRevision -> MemoryMergeOutcome(MemoryMergeResult.APPLY_REMOTE, listOf(remote.mutationId), remote.status)
            remoteRevision == localRevision && remote.mutationId == local.mutationId ->
                MemoryMergeOutcome(MemoryMergeResult.NOOP, listOf(local.mutationId), local.status)
            // Same revision from another mutation cannot happen with transactional writes; the server copy wins.
            remoteRevision == localRevision -> MemoryMergeOutcome(MemoryMergeResult.APPLY_REMOTE, listOf(remote.mutationId), remote.status)
            else -> MemoryMergeOutcome(MemoryMergeResult.IGNORE_REMOTE, listOf(local.mutationId), local.status)
        }
    }

    private fun sameBody(a: MemoryItemVersion, b: MemoryItemVersion): Boolean = a.content == b.content && a.status == b.status

    // ---- push ----

    /** Decision inside the push transaction for one pending mutation against the current remote document. */
    fun push(remote: MemoryItemVersion?, pending: MemoryItemVersion): MemoryPushOutcome {
        if (pending.sensitivity == MemorySensitivity.RESTRICTED) {
            // Restricted is never written as itself: a live remote copy is retracted with a tombstone, otherwise nothing is written.
            if (remote == null || remote.status == MemoryStatus.DELETED) {
                return MemoryPushOutcome(MemoryPushAction.LOCAL_ONLY, remote?.revision ?: 0)
            }
            return MemoryPushOutcome(MemoryPushAction.RETRACT, (remote.revision ?: 0) + 1)
        }
        if (remote == null) return MemoryPushOutcome(MemoryPushAction.WRITE, 1)
        val remoteRevision = remote.revision ?: 0
        return when {
            remote.mutationId == pending.mutationId -> MemoryPushOutcome(MemoryPushAction.CONFIRMED)
            // baseRevision 0 is a create (migration, conflict copy, new item): create-if-absent.
            (pending.baseRevision ?: 0) == 0 -> MemoryPushOutcome(MemoryPushAction.DROP_PENDING)
            remoteRevision == (pending.baseRevision ?: 0) -> MemoryPushOutcome(MemoryPushAction.WRITE, remoteRevision + 1)
            pending.status == MemoryStatus.DELETED -> MemoryPushOutcome(MemoryPushAction.WRITE, remoteRevision + 1)
            remote.status == MemoryStatus.DELETED || sameBody(remote, pending) -> MemoryPushOutcome(MemoryPushAction.DROP_PENDING)
            else -> MemoryPushOutcome(MemoryPushAction.CONFLICT)
        }
    }

    // ---- conflict ----

    /**
     * The original takes the remote body and becomes conflicted (a local edit with [mutationId], pushed);
     * the pending edit becomes a conflicted copy with a deterministic id.
     */
    fun conflictCopy(itemId: String, pending: MemoryItem, remote: MemoryItem, mutationId: String): MemoryConflict {
        val groupId = itemId.lowercase()
        val original = remote.copy(
            id = groupId,
            status = MemoryStatus.CONFLICTED,
            conflictGroupId = groupId,
            baseRevision = remote.revision,
            mutationId = mutationId,
            deviceId = pending.deviceId,
        )
        val copyId = uuid("$groupId\n${pending.mutationId.lowercase()}")
        val copy = pending.copy(
            id = copyId,
            status = MemoryStatus.CONFLICTED,
            conflictGroupId = groupId,
            revision = 1,
            baseRevision = 0,
            mutationId = uuid("$copyId\n$CONFLICT_MUTATION_SUFFIX"),
            createdAt = null,
            updatedAt = null,
        )
        return MemoryConflict(canonical(original), canonical(copy))
    }

    // ---- legacy compile / sync ----

    /** memoryText for old clients: semantic, active, non-restricted, global items except Anti-Forget, in list order. */
    fun compileLegacy(uid: String, items: List<MemoryItem>): MemoryLegacyCompile {
        val antiForgetId = legacyItemId(uid, LEGACY_KEY_ANTI_FORGET)
        val text = listOrder(items)
            .filter {
                it.layer == MemoryLayer.SEMANTIC &&
                    it.status == MemoryStatus.ACTIVE &&
                    it.sensitivity != MemorySensitivity.RESTRICTED &&
                    it.scope.type == MemoryScopeType.GLOBAL &&
                    it.id.lowercase() != antiForgetId
            }
            .joinToString(LEGACY_COMPILE_SEPARATOR) { it.content }
        return MemoryLegacyCompile(text, mcpSha256Hex(text))
    }

    /** Reconciles legacy preferences with the items (`migrated` is the per-account local flag); [deletedAt] stamps a tombstone of the memoryText item. */
    @Suppress("LongParameterList")
    fun legacySync(
        uid: String,
        migrated: Boolean,
        deviceId: String,
        items: List<MemoryItem>,
        prefs: MemoryLegacyPrefs,
        deletedAt: String,
    ): MemoryLegacySync {
        val ids = items.map { it.id.lowercase() }.toSet()
        val digestMatches = prefs.memoryTextDigest == mcpSha256Hex(prefs.memoryText)
        if (!migrated && digestMatches) {
            // Another new client already migrated this account and wrote the prefs: only the local flag is set.
            return MemoryLegacySync(emptyList(), emptyList(), null)
        }
        if (!migrated) {
            val create = migrate(uid, deviceId, prefs).filter { it.id !in ids }
            return MemoryLegacySync(create, emptyList(), writePrefs(prefs, compileLegacy(uid, items + create)))
        }
        if (digestMatches) return MemoryLegacySync(emptyList(), emptyList(), null)
        val before = compileLegacy(uid, items)
        if (prefs.memoryText == before.memoryText) return MemoryLegacySync(emptyList(), emptyList(), writePrefs(prefs, before))

        // An old client edited memoryText: carry it into the memoryText migration item.
        val legacyId = legacyItemId(uid, LEGACY_KEY_MEMORY_TEXT)
        val existing = items.firstOrNull { it.id.lowercase() == legacyId }
        val blank = prefs.memoryText.trimWhiteSpace().isEmpty()
        val mutationId = uuid("$legacyId\n$LEGACY_MUTATION_PREFIX${mcpSha256Hex(if (blank) "" else prefs.memoryText)}")
        val create = mutableListOf<MemoryItem>()
        val update = mutableListOf<MemoryItem>()
        when {
            blank -> if (existing != null && existing.status != MemoryStatus.DELETED) {
                update += tombstone(existing, mutationId, deviceId, deletedAt)
            }
            existing != null -> update += canonical(
                existing.copy(
                    status = MemoryStatus.ACTIVE,
                    content = prefs.memoryText,
                    baseRevision = existing.revision,
                    mutationId = mutationId,
                    deviceId = deviceId,
                    deletedAt = null,
                ),
            )
            else -> create += migrationItem(
                uid, LEGACY_KEY_MEMORY_TEXT, MemoryKind.FACT, MemoryStatus.ACTIVE, prefs.memoryText, deviceId, prefs.memoryUpdatedAt,
            ).copy(mutationId = mutationId)
        }
        val updatedIds = update.map { it.id }.toSet()
        val after = items.filterNot { it.id.lowercase() in updatedIds } + update + create
        return MemoryLegacySync(create, update, writePrefs(prefs, compileLegacy(uid, after)))
    }

    private fun writePrefs(prefs: MemoryLegacyPrefs, compile: MemoryLegacyCompile): MemoryLegacyWrite? =
        if (prefs.memoryText != compile.memoryText || prefs.memoryTextDigest != compile.memoryTextDigest) {
            MemoryLegacyWrite(compile.memoryText, compile.memoryTextDigest, textChanged = prefs.memoryText != compile.memoryText)
        } else {
            null
        }

    // ---- raw view ----

    private fun rawItems(items: List<MemoryItem>): List<MemoryItem> =
        listOrder(items).filter { it.layer == MemoryLayer.SEMANTIC && it.status == MemoryStatus.ACTIVE }

    /** Contents of the semantic active items in list order joined by \n---\n. */
    fun rawRender(items: List<MemoryItem>): String = rawItems(items).joinToString("\n$RAW_VIEW_SEPARATOR\n") { it.content }

    /** Turns the edited raw text into item operations; [newIds] supplies the ids of created items in order. */
    fun rawApply(items: List<MemoryItem>, text: String, newIds: List<String>): MemoryRawApply {
        if (text == rawRender(items)) return MemoryRawApply.Ops(emptyList())
        val segments = rawSegments(text)
        segments.forEachIndexed { index, segment ->
            if (segment.codePointCount(0, segment.length) > CONTENT_MAX_CODE_POINTS) return MemoryRawApply.TooLong(index)
        }
        val candidates = rawItems(items)
        val itemMatched = BooleanArray(candidates.size)
        val segmentMatched = BooleanArray(segments.size)
        // Pass 1: a segment keeps the first unmatched item with the same trimmed content.
        segments.forEachIndexed { s, segment ->
            val i = candidates.indices.firstOrNull { !itemMatched[it] && candidates[it].content.trimWhiteSpace() == segment }
            if (i != null) {
                itemMatched[i] = true
                segmentMatched[s] = true
            }
        }
        // Pass 2: remaining segments update remaining items pairwise; extras create or delete.
        val restSegments = segments.filterIndexed { s, _ -> !segmentMatched[s] }
        val restItems = candidates.filterIndexed { i, _ -> !itemMatched[i] }
        val ops = mutableListOf<MemoryRawOp>()
        restSegments.zip(restItems).forEach { (segment, item) -> ops += MemoryRawOp.Update(item.id.lowercase(), segment) }
        val extraSegments = restSegments.drop(restItems.size)
        require(extraSegments.size <= newIds.size) { "rawApply needs ${extraSegments.size} new ids" }
        extraSegments.forEachIndexed { k, segment -> ops += MemoryRawOp.Create(newIds[k].lowercase(), MemoryKind.FACT, segment) }
        restItems.drop(restSegments.size).forEach { ops += MemoryRawOp.Delete(it.id.lowercase()) }
        return MemoryRawApply.Ops(ops)
    }

    /** Splits on lines equal to --- (one trailing \r ignored), trims each segment, drops empty ones. */
    private fun rawSegments(text: String): List<String> {
        val segments = mutableListOf<String>()
        val current = mutableListOf<String>()
        text.split("\n").forEach { line ->
            if (line.removeSuffix("\r") == RAW_VIEW_SEPARATOR) {
                segments += current.joinToString("\n")
                current.clear()
            } else {
                current += line
            }
        }
        segments += current.joinToString("\n")
        return segments.map { it.trimWhiteSpace() }.filter { it.isNotEmpty() }
    }

    // ---- organize ----

    /** System = organize prompt, one user message = the item content unchanged. */
    fun organizeRequest(content: String): MemoryOrganizeRequest =
        MemoryOrganizeRequest(ORGANIZE_SYSTEM_PROMPT, listOf(MemoryOrganizeMessage(ChatRole.User, content)))

    /** Items from the model reply: the JSON array between the first [ and the last ]; anything unparseable → []. */
    fun organizeParse(response: String): List<MemoryOrganizedItem> {
        val start = response.indexOf('[')
        val end = response.lastIndexOf(']')
        if (start < 0 || end < start) return emptyList()
        val array = try {
            Json.parseToJsonElement(response.substring(start, end + 1)) as? JsonArray
        } catch (_: SerializationException) {
            null
        } catch (_: IllegalArgumentException) {
            null
        } ?: return emptyList()
        val result = mutableListOf<MemoryOrganizedItem>()
        for (element in array) {
            if (result.size >= ORGANIZE_MAX_ITEMS) break
            val obj = element as? JsonObject ?: continue
            val rawContent = (obj["content"] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: continue
            val content = rawContent.trimWhiteSpace()
            if (content.isEmpty() || content.codePointCount(0, content.length) > CONTENT_MAX_CODE_POINTS) continue
            if (result.any { it.content == content }) continue
            val kindWire = (obj["kind"] as? JsonPrimitive)?.takeIf { it.isString }?.content?.lowercase(Locale.ROOT)
            val kind = MemoryKind.SEMANTIC.firstOrNull { it.wire == kindWire } ?: MemoryKind.FACT
            result += MemoryOrganizedItem(kind, content)
        }
        return result
    }

    // ---- backup ----

    /** Every local item (tombstones and conflicts included) in list order, canonical; pending server times → null. */
    fun backupSection(items: List<MemoryItem>): MemoryBackupSection =
        MemoryBackupSection(SCHEMA_VERSION, listOrder(items).map { backupItem(canonical(it)) })

    private fun backupItem(item: MemoryItem): MemoryItem {
        fun MemoryServerTime?.settled(): MemoryServerTime? = this as? MemoryServerTime.At
        return item.copy(
            validFrom = item.validFrom.settled(),
            lastConfirmedAt = item.lastConfirmedAt.settled(),
            createdAt = item.createdAt.settled(),
            updatedAt = item.updatedAt.settled(),
        )
    }

    /** Import: merge keeps per id the higher revision (local wins ties), replace takes the backup list; list order. */
    fun backupMerge(
        mode: MemoryBackupMode,
        local: List<MemoryItem>,
        backup: MemoryBackup,
        uid: String,
        deviceId: String,
    ): List<MemoryItem> {
        val incoming = (backup.memoryItems ?: backup.preferences?.let { migrate(uid, deviceId, it) }.orEmpty()).map(::canonical)
        if (mode == MemoryBackupMode.REPLACE) return listOrder(incoming)
        val merged = LinkedHashMap<String, MemoryItem>()
        local.map(::canonical).forEach { merged[it.id] = it }
        incoming.forEach { item ->
            val current = merged[item.id]
            if (current == null || item.revision > current.revision) merged[item.id] = item
        }
        return listOrder(merged.values.toList())
    }

    /**
     * Replace: ids of live local items missing from [replaced] (the REPLACE result of [backupMerge]), in list order.
     * The caller writes a pending tombstone for each so the cloud and other devices converge; local tombstones stay as they are.
     */
    fun backupReplaceTombstonedIds(local: List<MemoryItem>, replaced: List<MemoryItem>): List<String> {
        val kept = replaced.map { it.id.lowercase() }.toSet()
        return listOrder(local.map(::canonical)).filter { it.status != MemoryStatus.DELETED && it.id !in kept }.map { it.id }
    }
}
