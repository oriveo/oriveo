package ai.oriveo.community.core.studio

import ai.oriveo.community.core.data.dao.StudioWorkDao
import ai.oriveo.community.core.data.entity.StudioRoundEntity
import ai.oriveo.community.core.data.entity.StudioRoundRefEntity
import ai.oriveo.community.core.data.entity.StudioVersionEntity
import ai.oriveo.community.core.data.entity.StudioWorkEntity
import ai.oriveo.community.core.util.generateUuidString
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json

/** A studio work as callers see it: the studio_works row with its JSON id arrays decoded. */
data class StudioWork(
    val id: String,
    val title: String,
    val currentVersionId: String?,
    val source: String,
    val chatConversationId: String?,
    val chatMessageId: String?,
    val favorite: Boolean,
    val selectedVersionIds: List<String>,
    val deletedVersionIds: List<String>,
    val createdAt: Long,
    val updatedAt: Long,
    val deletedAt: Long?,
    val revision: Long,
    val baseRevision: Long,
    val accountPartition: String,
    val syncState: String,
)

/** A live work with its rounds (by index), versions (by createdAt, id) and refs (by round index, order). */
data class StudioWorkDetail(
    val work: StudioWork,
    val rounds: List<StudioRoundEntity>,
    val versions: List<StudioVersionEntity>,
    val refs: List<StudioRoundRefEntity>,
)

/**
 * Local studio work repository (studio_data_model.v1 repository.rules, versionCasesHarness).
 * Reads and writes only see works of [currentPartition] that are not tombstoned. Every write runs under one
 * mutex and one transaction (lock order: mutex, then transaction). A change to a synced work field bumps
 * revision, sets updatedAt = now and syncState = pending; a write that changes none of them leaves the row
 * untouched. baseRevision is only written by sync. Times are epoch milliseconds.
 */
class StudioWorkRepository(
    private val dao: StudioWorkDao,
    private val currentPartition: () -> String,
    private val now: () -> Long = System::currentTimeMillis,
    /** Local transaction (production injects db.withTransaction). */
    private val runInTransaction: suspend (suspend () -> Unit) -> Unit = { block -> block() },
) {
    private val writeMutex = Mutex()

    /**
     * New work at revision 1, baseRevision 0, pending. [id] null = new upper-case UUID. An existing id
     * (any partition, tombstones included) returns the stored row as is and is never revived.
     */
    suspend fun createWork(
        id: String?,
        source: String,
        title: String,
        chatConversationId: String? = null,
        chatMessageId: String? = null,
    ): StudioWork = write {
        val workId = id?.uppercase() ?: generateUuidString()
        val existing = dao.getWork(workId)
        if (existing != null) return@write existing.toWork()
        val at = now()
        val row = StudioWorkEntity(
            id = workId,
            title = title,
            currentVersionId = null,
            source = source,
            chatConversationId = chatConversationId,
            chatMessageId = chatMessageId,
            favorite = false,
            selectedVersionIds = encodeIds(emptyList()),
            deletedVersionIds = encodeIds(emptyList()),
            createdAt = at,
            updatedAt = at,
            deletedAt = null,
            revision = 1,
            baseRevision = 0,
            accountPartition = currentPartition(),
            syncState = SYNC_PENDING,
        )
        dao.upsertWork(row)
        row.toWork()
    }

    suspend fun rename(workId: String, title: String): Boolean = mutate(workId) { _, work -> work.copy(title = title) }

    suspend fun setFavorite(workId: String, favorite: Boolean): Boolean =
        mutate(workId) { _, work -> work.copy(favorite = favorite) }

    /** Live works of the active partition, newest updatedAt first, then id ascending. */
    suspend fun list(): List<StudioWork> = dao.listWorks(currentPartition()).map { it.toWork() }

    /** Null for an unknown work, a tombstone or a work of another partition. */
    suspend fun detail(workId: String): StudioWorkDetail? {
        val row = activeRow(workId) ?: return null
        return StudioWorkDetail(
            work = row.toWork(),
            rounds = dao.roundsOf(row.id),
            versions = dao.versionsOf(row.id),
            refs = dao.refsOf(row.id),
        )
    }

    /**
     * Writes a round with its delivered versions and refs in one transaction. Rejected (nothing written) when
     * the work is unknown, tombstoned or in another partition. Already stored versions keep their kept flag.
     */
    suspend fun insertRound(
        round: StudioRoundEntity,
        versions: List<StudioVersionEntity>,
        refs: List<StudioRoundRefEntity>,
    ): Boolean = write {
        require(versions.all { it.roundId.equals(round.id, true) && it.workId.equals(round.workId, true) }) {
            "versions must belong to round ${round.id}"
        }
        require(refs.all { it.roundId.equals(round.id, true) }) { "refs must belong to round ${round.id}" }
        if (activeRow(round.workId) == null) return@write false
        dao.upsertRound(round)
        dao.insertVersions(versions)
        dao.upsertRefs(refs)
        true
    }

    /**
     * Keep rule after a round finished: a single candidate is kept and becomes current; several candidates wait
     * for a pick and only become the cover when the work has none yet; no candidate changes nothing.
     */
    suspend fun finishRound(workId: String, roundId: String): Boolean = mutate(workId) { row, work ->
        val candidates = dao.versionsOf(row.id).filter { it.roundId.equals(roundId, true) }
        when {
            candidates.size == 1 -> keep(row, work, candidates[0]).copy(currentVersionId = candidates[0].id)
            candidates.size > 1 && work.currentVersionId == null -> work.copy(currentVersionId = candidates[0].id)
            else -> work
        }
    }

    /** Keeps [versionId] and makes it the current version. */
    suspend fun pick(workId: String, versionId: String): Boolean = mutate(workId) { row, work ->
        val version = dao.getVersion(row.id, versionId) ?: return@mutate work
        keep(row, work, version).copy(currentVersionId = version.id)
    }

    /** Keeps [versionId] as well; the current version stays. */
    suspend fun alsoKeep(workId: String, versionId: String): Boolean = mutate(workId) { row, work ->
        val version = dao.getVersion(row.id, versionId) ?: return@mutate work
        keep(row, work, version)
    }

    /** Makes a kept version the cover; candidates and unknown ids are ignored. */
    suspend fun setCurrent(workId: String, versionId: String): Boolean = mutate(workId) { row, work ->
        val version = dao.getVersion(row.id, versionId)?.takeIf { it.kept } ?: return@mutate work
        work.copy(currentVersionId = version.id)
    }

    /**
     * Before a new round: when the latest round with candidates has more than one and none is kept, the first
     * candidate is picked.
     */
    suspend fun resolvePendingPick(workId: String): Boolean = mutate(workId) { row, work ->
        val byRound = dao.versionsOf(row.id).groupBy { it.roundId.uppercase() }
        val latest = dao.roundsOf(row.id).lastOrNull { byRound[it.id.uppercase()].orEmpty().isNotEmpty() }
            ?: return@mutate work
        val candidates = byRound.getValue(latest.id.uppercase())
        if (candidates.size > 1 && candidates.none { it.kept }) {
            keep(row, work, candidates[0]).copy(currentVersionId = candidates[0].id)
        } else {
            work
        }
    }

    /** Candidate count of the latest finished round when it has more than one and none is kept, else 0. */
    suspend fun pendingPickCount(workId: String): Int {
        val row = activeRow(workId) ?: return 0
        val latest = dao.roundsOf(row.id).lastOrNull { it.status in FINISHED_ROUND_STATUSES } ?: return 0
        val candidates = dao.versionsOf(row.id).filter { it.roundId.equals(latest.id, true) }
        return if (candidates.size > 1 && candidates.none { it.kept }) candidates.size else 0
    }

    /** vN = position in selectedVersionIds + 1 (deleted versions keep their slot); null when never kept. */
    suspend fun versionNumber(workId: String, versionId: String): Int? {
        val row = activeRow(workId) ?: return null
        val index = decodeIds(row.selectedVersionIds).indexOfFirst { it.equals(versionId, true) }
        return if (index < 0) null else index + 1
    }

    // ---- internals ----

    private suspend fun <T> write(block: suspend () -> T): T = writeMutex.withLock {
        var result: Result<T>? = null
        runInTransaction { result = Result.success(block()) }
        requireNotNull(result) { "transaction did not run" }.getOrThrow()
    }

    private suspend fun activeRow(workId: String): StudioWorkEntity? =
        dao.getWork(workId)?.takeIf { it.deletedAt == null && it.accountPartition == currentPartition() }

    /** Applies [change] to the live work; persists with a revision bump only when a synced field changed. */
    private suspend fun mutate(
        workId: String,
        change: suspend (row: StudioWorkEntity, work: StudioWork) -> StudioWork,
    ): Boolean = write {
        val row = activeRow(workId) ?: return@write false
        val before = row.toWork()
        val after = change(row, before)
        if (after == before) return@write false
        dao.upsertWork(
            row.copy(
                title = after.title,
                favorite = after.favorite,
                currentVersionId = after.currentVersionId,
                selectedVersionIds = encodeIds(after.selectedVersionIds),
                deletedVersionIds = encodeIds(after.deletedVersionIds),
                revision = row.revision + 1,
                updatedAt = now(),
                syncState = SYNC_PENDING,
            ),
        )
        true
    }

    /** Marks [version] kept and appends it to the keep order once. */
    private suspend fun keep(row: StudioWorkEntity, work: StudioWork, version: StudioVersionEntity): StudioWork {
        dao.markKept(row.id, version.id)
        if (work.selectedVersionIds.any { it.equals(version.id, true) }) return work
        return work.copy(selectedVersionIds = work.selectedVersionIds + version.id)
    }

    private fun StudioWorkEntity.toWork() = StudioWork(
        id = id,
        title = title,
        currentVersionId = currentVersionId,
        source = source,
        chatConversationId = chatConversationId,
        chatMessageId = chatMessageId,
        favorite = favorite,
        selectedVersionIds = decodeIds(selectedVersionIds),
        deletedVersionIds = decodeIds(deletedVersionIds),
        createdAt = createdAt,
        updatedAt = updatedAt,
        deletedAt = deletedAt,
        revision = revision,
        baseRevision = baseRevision,
        accountPartition = accountPartition,
        syncState = syncState,
    )

    companion object {
        const val SYNC_PENDING = "pending"
        const val SYNC_SYNCED = "synced"

        /** studio_data_model.v1 enums.roundStatusSynced. */
        private val FINISHED_ROUND_STATUSES =
            setOf("completed", "partial", "failed", "cancelled", "interrupted", "expired")

        private val idListSerializer = ListSerializer(String.serializer())

        private fun encodeIds(ids: List<String>): String = Json.encodeToString(idListSerializer, ids)

        private fun decodeIds(raw: String): List<String> =
            if (raw.isBlank()) emptyList() else Json.decodeFromString(idListSerializer, raw)
    }
}
