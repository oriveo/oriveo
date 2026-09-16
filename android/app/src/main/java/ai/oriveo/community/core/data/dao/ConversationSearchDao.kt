package ai.oriveo.community.core.data.dao

import androidx.room.Dao
import androidx.room.Query
import androidx.room.Transaction

/** A message waiting to be indexed. `rowId` is `messages.rowid`, which is also the FTS `docid`. */
data class PendingSearchIndexRow(
    val rowId: Long,
    val conversationId: String,
    val accountId: String,
    val text: String,
)

/** A tokenised row, ready to be written into the FTS table as is. */
data class ConversationSearchIndexRow(
    val rowId: Long,
    val conversationId: String,
    val accountId: String,
    val tokens: String,
)

/**
 * Maintenance surface of the conversation full-text index.
 *
 * Only [ai.oriveo.community.core.data.search.ConversationSearchIndexer] uses it; business write
 * paths never touch it.
 */
@Dao
interface ConversationSearchDao {

    @Query("SELECT messageRowId FROM conversation_search_dirty ORDER BY messageRowId LIMIT :limit")
    suspend fun pendingRowIds(limit: Int): List<Long>

    @Query("SELECT COUNT(*) FROM conversation_search_dirty")
    suspend fun pendingCount(): Int

    @Query(
        """
        SELECT m.rowid AS rowId, m.conversationId AS conversationId, m.accountId AS accountId, m.text AS text
        FROM messages m
        WHERE m.rowid IN (:rowIds)
        """,
    )
    suspend fun messagesByRowId(rowIds: List<Long>): List<PendingSearchIndexRow>

    @Query("DELETE FROM conversation_search_index WHERE docid IN (:rowIds)")
    suspend fun deleteIndexRows(rowIds: List<Long>)

    @Query(
        "INSERT INTO conversation_search_index(docid, conversationId, accountId, text) " +
            "VALUES (:rowId, :conversationId, :accountId, :tokens)",
    )
    suspend fun insertIndexRow(rowId: Long, conversationId: String, accountId: String, tokens: String)

    @Query("DELETE FROM conversation_search_dirty WHERE messageRowId IN (:rowIds)")
    suspend fun clearDirty(rowIds: List<Long>)

    /** Diagnostics: how many rows the index currently holds. */
    @Query("SELECT COUNT(*) FROM conversation_search_index")
    suspend fun indexedCount(): Int

    /**
     * Atomic write of one batch: delete the old rows by docid first (FTS has no upsert, so a
     * rewritten message must be removed before it is re-inserted), then insert, then clear the
     * queue. A crash in the middle leaves the queue intact and the next start redoes the batch,
     * so there is no window where the queue is cleared but the index was never written.
     *
     * `rowIds` is everything this batch *claimed*; `rows` is only the subset whose messages still
     * exist. Queue entries for deleted messages must be cleared too — their index rows are already
     * gone, removed by the delete trigger.
     */
    @Transaction
    suspend fun applyBatch(rowIds: List<Long>, rows: List<ConversationSearchIndexRow>) {
        if (rowIds.isEmpty()) return
        deleteIndexRows(rowIds)
        rows.forEach { row ->
            if (row.tokens.isNotEmpty()) {
                insertIndexRow(row.rowId, row.conversationId, row.accountId, row.tokens)
            }
        }
        clearDirty(rowIds)
    }
}
