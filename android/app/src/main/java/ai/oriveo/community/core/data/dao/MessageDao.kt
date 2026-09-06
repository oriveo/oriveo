package ai.oriveo.community.core.data.dao

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Update
import ai.oriveo.community.core.data.entity.MessageEntity
import ai.oriveo.community.core.data.entity.MonthlyCostRow
import ai.oriveo.community.core.data.entity.OversizedAttachmentsJsonRow
import ai.oriveo.community.core.data.entity.MonthlyProviderCostRow
import ai.oriveo.community.core.data.entity.ProviderUsageByModelRow
import kotlinx.coroutines.flow.Flow

@Dao
interface MessageDao {

    @Query("SELECT * FROM messages WHERE accountId = :accountId AND conversationId = :conversationId ORDER BY sortOrder ASC")
    fun observeByConversation(accountId: String, conversationId: String): Flow<List<MessageEntity>>

    // ──────────────────────────────────────────────────────────────────

    // ──────────────────────────────────────────────────────────────────

    @Query("SELECT id, accountId, length(attachmentsJson) AS len FROM messages WHERE length(attachmentsJson) > :thresholdChars")
    suspend fun findOversizedAttachmentsJsonRows(thresholdChars: Int): List<OversizedAttachmentsJsonRow>

    @Query("SELECT substr(attachmentsJson, :start, :length) FROM messages WHERE accountId = :accountId AND id = :id")
    suspend fun readAttachmentsJsonChunk(accountId: String, id: String, start: Int, length: Int): String?

    @Query("UPDATE messages SET attachmentsJson = :attachmentsJson WHERE accountId = :accountId AND id = :id")
    suspend fun updateAttachmentsJson(accountId: String, id: String, attachmentsJson: String?): Int

    @Query("SELECT * FROM messages WHERE accountId = :accountId AND conversationId = :conversationId ORDER BY sortOrder ASC")
    suspend fun getByConversation(accountId: String, conversationId: String): List<MessageEntity>

    // ──────────────────────────────────────────────────────────────────

    // ──────────────────────────────────────────────────────────────────

    @Query(
        """
        SELECT * FROM (
            SELECT * FROM messages
            WHERE accountId = :accountId AND conversationId = :conversationId
            ORDER BY sortOrder DESC, id DESC
            LIMIT :limit
        )
        ORDER BY sortOrder ASC, id ASC
        """,
    )
    fun observeLatestMessageWindow(accountId: String, conversationId: String, limit: Int): Flow<List<MessageEntity>>

    @Query(
        """
        WITH anchor AS (
            SELECT sortOrder, id
            FROM messages
            WHERE accountId = :accountId AND conversationId = :conversationId AND id = :messageId
            LIMIT 1
        ),
        before AS (
            SELECT m.*
            FROM messages AS m, anchor AS a
            WHERE m.accountId = :accountId AND m.conversationId = :conversationId
              AND (m.sortOrder < a.sortOrder
                   OR (m.sortOrder = a.sortOrder AND m.id < a.id))
            ORDER BY m.sortOrder DESC, m.id DESC
            LIMIT :beforeLimit
        ),
        target AS (
            SELECT m.*
            FROM messages AS m, anchor AS a
            WHERE m.accountId = :accountId AND m.conversationId = :conversationId AND m.id = a.id
        ),
        after AS (
            SELECT m.*
            FROM messages AS m, anchor AS a
            WHERE m.accountId = :accountId AND m.conversationId = :conversationId
              AND (m.sortOrder > a.sortOrder
                   OR (m.sortOrder = a.sortOrder AND m.id > a.id))
            ORDER BY m.sortOrder ASC, m.id ASC
            LIMIT :afterLimit
        )
        SELECT * FROM (
            SELECT * FROM before
            UNION ALL
            SELECT * FROM target
            UNION ALL
            SELECT * FROM after
        )
        ORDER BY sortOrder ASC, id ASC
        """,
    )
    fun observeMessageWindowAround(
        accountId: String,
        conversationId: String,
        messageId: String,
        beforeLimit: Int,
        afterLimit: Int,
    ): Flow<List<MessageEntity>>

    @Query(
        """
        SELECT * FROM (
            SELECT * FROM messages
            WHERE accountId = :accountId AND conversationId = :conversationId
            ORDER BY sortOrder DESC, id DESC
            LIMIT :limit
        )
        ORDER BY sortOrder ASC, id ASC
        """,
    )
    suspend fun fetchLatestMessageWindow(accountId: String, conversationId: String, limit: Int): List<MessageEntity>

    @Query(
        """
        SELECT * FROM (
            SELECT * FROM messages
            WHERE accountId = :accountId AND conversationId = :conversationId
              AND (sortOrder < :boundarySortOrder
                   OR (sortOrder = :boundarySortOrder AND id < :boundaryId))
            ORDER BY sortOrder DESC, id DESC
            LIMIT :limit
        )
        ORDER BY sortOrder ASC, id ASC
        """,
    )
    suspend fun fetchMessagesBefore(
        accountId: String,
        conversationId: String,
        boundarySortOrder: Int,
        boundaryId: String,
        limit: Int,
    ): List<MessageEntity>

    @Query(
        """
        SELECT * FROM messages
        WHERE accountId = :accountId AND conversationId = :conversationId
          AND (sortOrder > :boundarySortOrder
               OR (sortOrder = :boundarySortOrder AND id > :boundaryId))
        ORDER BY sortOrder ASC, id ASC
        LIMIT :limit
        """,
    )
    suspend fun fetchMessagesAfter(
        accountId: String,
        conversationId: String,
        boundarySortOrder: Int,
        boundaryId: String,
        limit: Int,
    ): List<MessageEntity>

    @Query(
        """
        SELECT EXISTS(
            SELECT 1 FROM messages
            WHERE accountId = :accountId AND conversationId = :conversationId
              AND (sortOrder < :boundarySortOrder
                   OR (sortOrder = :boundarySortOrder AND id < :boundaryId))
            LIMIT 1
        )
        """,
    )
    suspend fun existsBefore(
        accountId: String,
        conversationId: String,
        boundarySortOrder: Int,
        boundaryId: String,
    ): Boolean

    @Query(
        """
        SELECT EXISTS(
            SELECT 1 FROM messages
            WHERE accountId = :accountId AND conversationId = :conversationId
              AND (sortOrder > :boundarySortOrder
                   OR (sortOrder = :boundarySortOrder AND id > :boundaryId))
            LIMIT 1
        )
        """,
    )
    suspend fun existsAfter(
        accountId: String,
        conversationId: String,
        boundarySortOrder: Int,
        boundaryId: String,
    ): Boolean

    @Query(
        """
        SELECT * FROM messages
        WHERE accountId = :accountId AND id = :id
        ORDER BY sortOrder DESC
        LIMIT 1
        """,
    )
    suspend fun getById(accountId: String, id: String): MessageEntity?

    @Query(
        """
        SELECT * FROM messages
        WHERE accountId = :accountId AND conversationId = :conversationId AND id = :id
        LIMIT 1
        """,
    )
    suspend fun getByIdForConversation(accountId: String, conversationId: String, id: String): MessageEntity?

    @Query(
        """
        SELECT * FROM messages
        WHERE accountId = :accountId AND conversationId = :conversationId AND state = 'Delivered'
        ORDER BY sortOrder DESC, id DESC
        LIMIT 1
        """,
    )
    suspend fun lastDelivered(accountId: String, conversationId: String): MessageEntity?

    @Query(
        """
        SELECT * FROM messages
        WHERE accountId = :accountId AND conversationId = :conversationId AND state = 'Delivered' AND role = 'User'
        ORDER BY sortOrder DESC, id DESC
        LIMIT 1
        """,
    )
    suspend fun lastDeliveredUser(accountId: String, conversationId: String): MessageEntity?

    @Query(
        """
        SELECT * FROM messages
        WHERE accountId = :accountId AND conversationId = :conversationId AND state = 'Delivered' AND role = 'User'
          AND sortOrder < :beforeSortOrder
        ORDER BY sortOrder DESC, id DESC
        LIMIT 1
        """,
    )
    suspend fun lastDeliveredUserBefore(accountId: String, conversationId: String, beforeSortOrder: Int): MessageEntity?

    @Query("SELECT COUNT(*) FROM messages WHERE accountId = :accountId AND conversationId = :conversationId AND state = 'Delivered'")
    suspend fun countDeliveredByConversation(accountId: String, conversationId: String): Int

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(entity: MessageEntity)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertAll(entities: List<MessageEntity>)

    @Update
    suspend fun update(entity: MessageEntity)

    @Query("DELETE FROM messages WHERE accountId = :accountId AND id = :id")
    suspend fun deleteById(accountId: String, id: String)

    /**
     * Marks every message still in Generating as Interrupted, on startup.
     *
     * A stream can be killed without ever reaching its own error path: the process dies, or Doze
     * suspends the socket and the coroutine never resumes. The row is then stuck in Generating
     * forever, showing a spinner nothing will ever stop. Sweeping them at launch turns each one
     * into a message with a retry affordance instead.
     */
    @Query("UPDATE messages SET state = 'Interrupted' WHERE state = 'Generating'")
    suspend fun sanitizeStaleGenerating(): Int

    /**
     * Writes the partial text of a message that is still streaming, without touching `updatedAt`:
     * a half-finished response should not reorder the conversation list on every token.
     */
    @Query("UPDATE messages SET text = :text WHERE accountId = :accountId AND id = :id AND state = 'Generating'")
    suspend fun updatePartialText(accountId: String, id: String, text: String): Int

    /**
     * The reasoning-text counterpart to [updatePartialText].
     *
     * Without it, a model that is still in its reasoning phase when the app goes to the background
     * loses everything it had produced: the flush only persisted the visible text, so the reasoning
     * section came back empty.
     */
    @Query("UPDATE messages SET reasoningText = :reasoningText WHERE accountId = :accountId AND id = :id AND state = 'Generating'")
    suspend fun updatePartialReasoning(accountId: String, id: String, reasoningText: String): Int

    @Query(
        """
        UPDATE messages
        SET inputTokens = :inputTokens,
            outputTokens = :outputTokens,
            cachedInputTokens = :cacheReadTokens,
            cacheCreationInputTokens = :cacheWriteTokens
        WHERE accountId = :accountId AND id = :id
        """,
    )
    suspend fun updateMessageTokenUsage(
        accountId: String,
        id: String,
        inputTokens: Int,
        outputTokens: Int,

        cacheReadTokens: Int?,
        cacheWriteTokens: Int?,
    ): Int

    @Query("DELETE FROM messages WHERE accountId = :accountId AND conversationId = :conversationId")
    suspend fun deleteByConversation(accountId: String, conversationId: String)

    @Query("DELETE FROM messages WHERE accountId = :accountId AND conversationId = :conversationId AND sortOrder > :afterOrder")
    suspend fun deleteAfterOrder(accountId: String, conversationId: String, afterOrder: Int)

    @Query("SELECT MAX(sortOrder) FROM messages WHERE accountId = :accountId AND conversationId = :conversationId")
    suspend fun maxSortOrder(accountId: String, conversationId: String): Int?

    @Query("SELECT MAX(createdAt) FROM messages WHERE accountId = :accountId AND conversationId = :conversationId")
    suspend fun latestMessageTimestamp(accountId: String, conversationId: String): Long?

    @Query("SELECT COUNT(*) FROM messages WHERE accountId = :accountId AND conversationId = :conversationId")
    suspend fun countByConversation(accountId: String, conversationId: String): Int

    @Query(
        """
        SELECT COALESCE(SUM(estimatedCost), 0.0)
        FROM messages
        WHERE accountId = :accountId AND conversationId = :conversationId
          AND role = 'Assistant'
          AND state = 'Delivered'
          AND estimatedCost > :minimumCostExclusive
        """,
    )
    suspend fun sumDeliveredCost(accountId: String, conversationId: String, minimumCostExclusive: Double): Double

    @Query(
        """
        SELECT DISTINCT m.conversationId
        FROM messages m
        INNER JOIN conversations c ON c.accountId = m.accountId AND c.id = m.conversationId
        WHERE c.accountId = :accountId
        ORDER BY c.updatedAt DESC
        LIMIT :limit
        """,
    )
    suspend fun getRecentConversationIdsWithMessages(accountId: String, limit: Int): List<String>

    @Query(
        """
        SELECT COUNT(messages.id) FROM messages
        INNER JOIN conversations ON conversations.accountId = messages.accountId
          AND conversations.id = messages.conversationId
        WHERE conversations.providerID = :providerId
          AND conversations.accountId = :accountId
          AND messages.state = 'Delivered'
        """,
    )
    fun observeCountByProvider(providerId: String, accountId: String): Flow<Int>

    @Query(
        """
        SELECT m.providerKind,
               COALESCE(m.providerID, c.providerID) AS providerID,
               SUM(m.estimatedCost) AS totalCost
        FROM messages m
        INNER JOIN conversations c ON c.accountId = m.accountId AND c.id = m.conversationId
        WHERE c.accountId = :accountId
          AND c.isDraft = 0
          AND m.role = 'Assistant'
          AND m.state = 'Delivered'
          AND m.estimatedCost > :minimumCostExclusive
          AND COALESCE(m.createdAt, c.updatedAt) >= :windowStartMillis
          AND COALESCE(m.createdAt, c.updatedAt) < :windowEndMillis
        GROUP BY m.providerKind, COALESCE(m.providerID, c.providerID)
        """,
    )
    fun observeMonthlyCostByProviderKind(
        accountId: String,
        minimumCostExclusive: Double,
        windowStartMillis: Long,
        windowEndMillis: Long,
    ): Flow<List<MonthlyCostRow>>

    /**
     * One-shot form of [observeMonthlyCostByProviderKind], for callers that only need the current
     * total. Drafts and undelivered messages are excluded, so the figures match what the user sees
     * in the conversation.
     */
    @Query(
        """
        SELECT m.providerKind,
               COALESCE(m.providerID, c.providerID) AS providerID,
               SUM(m.estimatedCost) AS totalCost
        FROM messages m
        INNER JOIN conversations c ON c.accountId = m.accountId AND c.id = m.conversationId
        WHERE c.accountId = :accountId
          AND c.isDraft = 0
          AND m.role = 'Assistant'
          AND m.state = 'Delivered'
          AND m.estimatedCost > :minimumCostExclusive
          AND COALESCE(m.createdAt, c.updatedAt) >= :windowStartMillis
          AND COALESCE(m.createdAt, c.updatedAt) < :windowEndMillis
        GROUP BY m.providerKind, COALESCE(m.providerID, c.providerID)
        """,
    )
    suspend fun getMonthlyCostByProviderKind(
        accountId: String,
        minimumCostExclusive: Double,
        windowStartMillis: Long,
        windowEndMillis: Long,
    ): List<MonthlyCostRow>

    @Query(
        """
        SELECT COALESCE(m.providerID, c.providerID) AS providerId, SUM(m.estimatedCost) AS totalCost
        FROM messages m
        INNER JOIN conversations c ON c.accountId = m.accountId AND c.id = m.conversationId
        WHERE c.accountId = :accountId
          AND c.isDraft = 0
          AND m.role = 'Assistant'
          AND m.state = 'Delivered'
          AND m.estimatedCost > :minimumCostExclusive
          AND COALESCE(m.createdAt, c.updatedAt) >= :windowStartMillis
          AND COALESCE(m.createdAt, c.updatedAt) < :windowEndMillis
        GROUP BY COALESCE(m.providerID, c.providerID)
        """,
    )
    fun observeMonthlyCostByConversationProvider(
        accountId: String,
        minimumCostExclusive: Double,
        windowStartMillis: Long,
        windowEndMillis: Long,
    ): Flow<List<MonthlyProviderCostRow>>

    @Query(
        """
        SELECT m.modelName AS modelName,
               SUM(CASE WHEN COALESCE(m.createdAt, c.updatedAt) >= :windowStartMillis
                         AND COALESCE(m.createdAt, c.updatedAt) <  :windowEndMillis
                        THEN m.estimatedCost ELSE 0 END) AS thisMonthCost,
               SUM(CASE WHEN COALESCE(m.createdAt, c.updatedAt) >= :windowStartMillis
                         AND COALESCE(m.createdAt, c.updatedAt) <  :windowEndMillis
                        THEN 1 ELSE 0 END) AS thisMonthMessages,
               SUM(m.estimatedCost) AS allTimeCost,
               COUNT(*) AS allTimeMessages
        FROM messages m
        INNER JOIN conversations c ON c.accountId = m.accountId AND c.id = m.conversationId
        WHERE c.accountId = :accountId
          AND c.isDraft = 0
          AND m.role = 'Assistant'
          AND m.state = 'Delivered'
          AND m.estimatedCost > :minimumCostExclusive
          AND COALESCE(m.providerID, c.providerID) = :providerId
        GROUP BY m.modelName
        """,
    )
    fun observeProviderUsageByModel(
        accountId: String,
        providerId: String,
        minimumCostExclusive: Double,
        windowStartMillis: Long,
        windowEndMillis: Long,
    ): Flow<List<ProviderUsageByModelRow>>
}
