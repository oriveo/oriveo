package ai.oriveo.community.core.data.dao

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import ai.oriveo.community.core.data.entity.MessageContinuationEntity

@Dao
interface MessageContinuationDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(entity: MessageContinuationEntity)

    @Query("SELECT * FROM message_continuations WHERE accountId = :accountId AND messageId = :messageId")
    suspend fun get(accountId: String, messageId: String): MessageContinuationEntity?

    @Query("DELETE FROM message_continuations WHERE accountId = :accountId AND messageId = :messageId")
    suspend fun delete(accountId: String, messageId: String)

    @Query("DELETE FROM message_continuations WHERE processSessionToken IS NULL OR processSessionToken != :currentToken")
    suspend fun deleteOtherProcessSessions(currentToken: String)

    @Query("DELETE FROM message_continuations WHERE accountId = :accountId AND messageId IN (:messageIds)")
    suspend fun deleteMessages(accountId: String, messageIds: List<String>)

    @Query("""
        DELETE FROM message_continuations
        WHERE accountId = :accountId AND messageId = :messageId
          AND updatedAt = :updatedAt AND processSessionToken = :processSessionToken
          AND stateJson = :stateJson AND interrupted = 0
    """)
    suspend fun deleteIfUnchanged(
        accountId: String,
        messageId: String,
        updatedAt: Long,
        processSessionToken: String,
        stateJson: String,
    ): Int

    @Query("UPDATE message_continuations SET interrupted = 1, updatedAt = :updatedAt WHERE accountId = :accountId AND messageId = :messageId")
    suspend fun markInterrupted(accountId: String, messageId: String, updatedAt: Long)

    /** Explicit lifecycle cleanup; interruption itself marks the row unusable for any future replay. */
    @Query("DELETE FROM message_continuations WHERE accountId = :accountId AND conversationId = :conversationId")
    suspend fun deleteForConversation(accountId: String, conversationId: String)

    @Query("SELECT * FROM message_continuations WHERE accountId = :accountId")
    suspend fun listForAccount(accountId: String): List<MessageContinuationEntity>
}
