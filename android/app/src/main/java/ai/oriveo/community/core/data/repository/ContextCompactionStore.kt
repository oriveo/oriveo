package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.context.CheckpointConcurrencyEntry
import ai.oriveo.community.core.context.CheckpointCoveredMessage
import ai.oriveo.community.core.context.ContextCheckpoint
import ai.oriveo.community.core.data.dao.ContextCheckpointDao
import ai.oriveo.community.core.data.entity.ContextCheckpointEntity
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow

enum class ContextCheckpointKind(val wire: String) {
    SUMMARY("summary"),
    FALLBACK("fallback"),
    ;

    companion object {
        fun fromWire(wire: String): ContextCheckpointKind? = entries.firstOrNull { it.wire == wire }
    }
}

/** A stored checkpoint; the account partition is passed separately. */
data class ContextCheckpointRecord(
    val conversationId: String,
    val checkpointId: String,
    val kind: ContextCheckpointKind,
    val coversFrom: String,
    val coversTo: String,
    val coversDigest: String,
    val messagesCovered: Int,
    val userMessageIds: List<String>,
    val text: String,
    val summary: String?,
    val language: String?,
    val model: String,
    val packerVersion: String,
    /** Epoch milliseconds. */
    val createdAt: Long,
    val cost: Double?,
)

/** Local checkpoint storage. */
class ContextCompactionStore(private val dao: ContextCheckpointDao) {

    private val _changes = MutableSharedFlow<String>(extraBufferCapacity = CHANGES_BUFFER)

    /** Emits the conversation id once after every [save], [deleteAll], [delete] and [invalidate]. */
    val changes: SharedFlow<String> = _changes.asSharedFlow()

    /** Overwrites by checkpointId and trims the conversation to [MAX_PER_CONVERSATION] in one transaction. */
    suspend fun save(accountId: String, record: ContextCheckpointRecord) {
        dao.saveAndTrim(record.toEntity(accountId), MAX_PER_CONVERSATION)
        _changes.emit(record.conversationId)
    }

    /** Deletes every checkpoint of the conversation. Returns the deleted checkpoint ids. */
    suspend fun deleteAll(accountId: String, conversationId: String): List<String> {
        val ids = dao.deleteAll(accountId, conversationId)
        _changes.emit(conversationId)
        return ids
    }

    /** Deletes the given rows. */
    suspend fun delete(accountId: String, conversationId: String, checkpointIds: List<String>) {
        if (checkpointIds.isNotEmpty()) dao.delete(accountId, conversationId, checkpointIds)
        _changes.emit(conversationId)
    }

    /** Oldest first; rows with an unknown kind are skipped. */
    suspend fun list(accountId: String, conversationId: String): List<ContextCheckpointRecord> =
        dao.list(accountId, conversationId).mapNotNull { it.toRecord() }

    /**
     * Rule 2: skips (without deleting) rows whose coversTo is not in [history] or whose digest does not match
     * the covered prefix; picks one of the rest with [ContextCheckpoint.resolveConcurrency].
     */
    suspend fun latestValid(
        accountId: String,
        conversationId: String,
        history: List<CheckpointCoveredMessage>,
    ): ContextCheckpointRecord? {
        val valid = list(accountId, conversationId).mapNotNull { record ->
            val index = history.indexOfFirst { it.id == record.coversTo }
            if (index < 0) return@mapNotNull null
            if (ContextCheckpoint.coversDigest(history.subList(0, index + 1)) != record.coversDigest) return@mapNotNull null
            record to CheckpointConcurrencyEntry(record.checkpointId, index, record.createdAt)
        }
        if (valid.isEmpty()) return null
        val winner = valid.map { it.second }.reduce(ContextCheckpoint::resolveConcurrency)
        return valid.first { it.second == winner }.first
    }

    /**
     * Rule 3: k = smallest index of [affectedIds] in [historyIds]; deletes rows whose coversTo index is >= k.
     * Rows whose coversTo is not in [historyIds] are kept. Returns the deleted checkpoint ids.
     */
    suspend fun invalidate(
        accountId: String,
        conversationId: String,
        historyIds: List<String>,
        affectedIds: Collection<String>,
    ): List<String> {
        val k = historyIds.indices.firstOrNull { historyIds[it] in affectedIds } ?: return emptyList()
        val dropped = dao.list(accountId, conversationId)
            .filter { historyIds.indexOf(it.coversTo) >= k }
            .map { it.checkpointId }
        if (dropped.isNotEmpty()) dao.delete(accountId, conversationId, dropped)
        _changes.emit(conversationId)
        return dropped
    }

    /**
     * Shared by the local edit hooks (edit-resend / regenerate): [invalidate], then hand the dropped ids to
     * [deleteRemote] so the remote copies go too. Not called when nothing dropped.
     */
    suspend fun invalidateAndDeleteRemote(
        accountId: String,
        conversationId: String,
        historyIds: List<String>,
        affectedIds: Collection<String>,
        deleteRemote: (List<String>) -> Unit,
    ): List<String> {
        val dropped = invalidate(accountId, conversationId, historyIds, affectedIds)
        if (dropped.isNotEmpty()) deleteRemote(dropped)
        return dropped
    }

    companion object {
        const val MAX_PER_CONVERSATION: Int = 8
        private const val CHANGES_BUFFER: Int = 64
    }
}

private fun ContextCheckpointRecord.toEntity(accountId: String) = ContextCheckpointEntity(
    accountId = accountId,
    conversationId = conversationId,
    checkpointId = checkpointId,
    kind = kind.wire,
    coversFrom = coversFrom,
    coversTo = coversTo,
    coversDigest = coversDigest,
    messagesCovered = messagesCovered,
    userMessageIds = ContextCheckpointEntity.encodeUserMessageIds(userMessageIds),
    text = text,
    summary = summary,
    language = language,
    model = model,
    packerVersion = packerVersion,
    createdAt = createdAt,
    cost = cost,
)

private fun ContextCheckpointEntity.toRecord(): ContextCheckpointRecord? {
    val kind = ContextCheckpointKind.fromWire(kind) ?: return null
    return ContextCheckpointRecord(
        conversationId = conversationId,
        checkpointId = checkpointId,
        kind = kind,
        coversFrom = coversFrom,
        coversTo = coversTo,
        coversDigest = coversDigest,
        messagesCovered = messagesCovered,
        userMessageIds = userMessageIdList,
        text = text,
        summary = summary,
        language = language,
        model = model,
        packerVersion = packerVersion,
        createdAt = createdAt,
        cost = cost,
    )
}
