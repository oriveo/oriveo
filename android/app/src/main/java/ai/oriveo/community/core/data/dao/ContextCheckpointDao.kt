package ai.oriveo.community.core.data.dao

import androidx.room.Dao
import androidx.room.Query
import androidx.room.Transaction
import androidx.room.Upsert
import ai.oriveo.community.core.data.entity.ContextCheckpointEntity

/** Context checkpoints per conversation (v39). */
@Dao
interface ContextCheckpointDao {

    /** Upsert one checkpoint by primary key, then keep only the newest [keep] of its conversation. */
    @Transaction
    suspend fun saveAndTrim(entity: ContextCheckpointEntity, keep: Int) {
        upsert(entity)
        trim(entity.accountId, entity.conversationId, keep)
    }

    /** Lists and deletes every checkpoint of the conversation in one transaction; returns the deleted ids. */
    @Transaction
    suspend fun deleteAll(accountId: String, conversationId: String): List<String> {
        val ids = list(accountId, conversationId).map { it.checkpointId }
        if (ids.isNotEmpty()) delete(accountId, conversationId, ids)
        return ids
    }

    @Upsert
    suspend fun upsert(entity: ContextCheckpointEntity)

    @Query(
        "DELETE FROM context_checkpoint WHERE accountId = :accountId AND conversationId = :conversationId " +
            "AND rowid NOT IN (SELECT rowid FROM context_checkpoint WHERE accountId = :accountId " +
            "AND conversationId = :conversationId ORDER BY createdAt DESC, rowid DESC LIMIT :keep)",
    )
    suspend fun trim(accountId: String, conversationId: String, keep: Int)

    /** Oldest first. */
    @Query(
        "SELECT * FROM context_checkpoint WHERE accountId = :accountId AND conversationId = :conversationId " +
            "ORDER BY createdAt ASC, rowid ASC",
    )
    suspend fun list(accountId: String, conversationId: String): List<ContextCheckpointEntity>

    @Query(
        "DELETE FROM context_checkpoint WHERE accountId = :accountId AND conversationId = :conversationId " +
            "AND checkpointId IN (:checkpointIds)",
    )
    suspend fun delete(accountId: String, conversationId: String, checkpointIds: Collection<String>)
}
