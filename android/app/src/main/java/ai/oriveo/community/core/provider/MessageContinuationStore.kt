package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.dao.MessageContinuationDao
import ai.oriveo.community.core.data.entity.MessageContinuationEntity
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import java.util.UUID
import java.util.concurrent.atomic.AtomicLong

/**
 * Local-only repository for message continuation state. Callers may only reach [loadForExplicit]
 * when the user explicitly resends; there is no background worker, no sync or export hook, and no
 * automatic resume path.
 */
class MessageContinuationStore(
    private val dao: MessageContinuationDao,
    private val json: Json,
) {
    private val processSessionToken = UUID.randomUUID().toString()
    private val writeRevision = AtomicLong(System.currentTimeMillis())
    private val startupCleanupMutex = Mutex()
    @Volatile private var startupCleanupComplete = false

    data class Loaded(
        val accountId: String,
        val messageId: String,
        val state: JsonObject,
        val updatedAt: Long,
        val processSessionToken: String,
        val stateJson: String,
    )

    suspend fun save(accountId: String, conversationId: String, messageId: String, kind: String, state: JsonObject, interrupted: Boolean = false) {
        clearPreviousProcessRowsOnce()
        val completed = if (interrupted) JsonObject(state.filterKeys { it != "pendingToolCallId" }) else state
        val revision = nextRevision()
        dao.upsert(MessageContinuationEntity(accountId, messageId, conversationId, kind, processSessionToken, completed.toString(), interrupted, revision))
    }

    /**
     * Corrupt/missing state restarts clean and removes poison record; never synthesize historical
     * opaque data. Background/lock interruption invalidates the round entirely, so even a later
     * explicit retry restarts clean instead of replaying completed legs.
     */
    suspend fun loadForExplicit(accountId: String, messageId: String): Loaded? {
        clearPreviousProcessRowsOnce()
        val record = dao.get(accountId, messageId) ?: return null
        if (record.interrupted ||
            record.processSessionToken != processSessionToken
        ) {
            dao.delete(accountId, messageId)
            return null
        }
        val decoded = runCatching { json.parseToJsonElement(record.stateJson) as? JsonObject }.getOrNull()
        if (decoded == null) {
            dao.delete(accountId, messageId)
        }
        return decoded?.let {
            Loaded(accountId, messageId, it, record.updatedAt, record.processSessionToken, record.stateJson)
        }
    }

    /** Compare-and-delete only the snapshot accepted by the provider round; a newer producer wins. */
    suspend fun acknowledge(loaded: Loaded): Boolean {
        clearPreviousProcessRowsOnce()
        val deleted = dao.deleteIfUnchanged(
            loaded.accountId, loaded.messageId, loaded.updatedAt, loaded.processSessionToken, loaded.stateJson,
        ) == 1
        return deleted
    }

    /** Cancellation/background records invalidation and never schedules a resume. */
    suspend fun markInterrupted(accountId: String, messageId: String) {
        clearPreviousProcessRowsOnce()
        dao.markInterrupted(accountId, messageId, nextRevision())
    }

    private fun nextRevision(): Long = writeRevision.updateAndGet { previous ->
        maxOf(System.currentTimeMillis(), previous + 1)
    }

    private suspend fun clearPreviousProcessRowsOnce() {
        if (startupCleanupComplete) return
        startupCleanupMutex.withLock {
            if (startupCleanupComplete) return
            dao.deleteOtherProcessSessions(processSessionToken)
            startupCleanupComplete = true
        }
    }
}
