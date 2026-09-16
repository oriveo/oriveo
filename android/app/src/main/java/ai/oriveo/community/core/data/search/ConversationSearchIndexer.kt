package ai.oriveo.community.core.data.search

import ai.oriveo.community.core.data.dao.ConversationSearchDao
import ai.oriveo.community.core.data.dao.ConversationSearchIndexRow
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * Consumer side of the conversation full-text index: tokenises the messages queued in
 * `conversation_search_dirty` and writes them into the FTS table.
 *
 * The producer is a set of SQL triggers on `messages` (see `ConversationSearchSchema`), so *no*
 * write path — streaming checkpoints, backup restore, importers, benchmark seeders — needs to know
 * the index exists, and none of them can forget to update it. The indexer runs from two places:
 *
 * 1. once in the background after process start, which is how an existing database finishes
 *    building its index after an upgrade without blocking the first open;
 * 2. before each search, with a cap, so that something just said is immediately findable.
 *
 * Batching is not optional: tokenising tens of thousands of messages in one go holds the write
 * transaction long enough to stall the first database open outright.
 */
class ConversationSearchIndexer(
    private val dao: ConversationSearchDao,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) {
    private val mutex = Mutex()

    companion object {
        /**
         * Messages per write transaction. 200 takes a few tens of milliseconds on a low-end
         * device, which neither spins on empty queues nor holds the write lock for long.
         */
        const val BATCH_SIZE = 200

        /**
         * How many messages a search may catch up on before querying. Keeps the first search after
         * an upgrade from waiting for the whole backlog.
         */
        const val SEARCH_CATCH_UP_LIMIT = 600
    }

    /**
     * Drains the queue.
     *
     * @param maxMessages how many messages to process at most; [Int.MAX_VALUE] drains it fully.
     * @return the number of messages actually processed.
     */
    suspend fun drain(maxMessages: Int = Int.MAX_VALUE): Int = mutex.withLock {
        withContext(ioDispatcher) {
            var processed = 0
            while (processed < maxMessages) {
                val limit = minOf(BATCH_SIZE, maxMessages - processed)
                val rowIds = dao.pendingRowIds(limit)
                if (rowIds.isEmpty()) break
                val pending = dao.messagesByRowId(rowIds)
                val rows = pending.map { row ->
                    ConversationSearchIndexRow(
                        rowId = row.rowId,
                        conversationId = row.conversationId,
                        accountId = row.accountId,
                        tokens = ConversationFtsQuery.indexText(row.text),
                    )
                }
                dao.applyBatch(rowIds, rows)
                processed += rowIds.size
                // Claiming fewer rows than asked for means the queue is empty; no point in one
                // more round trip that finds nothing.
                if (rowIds.size < limit) break
            }
            processed
        }
    }

    /**
     * Bounded catch-up before a search.
     *
     * @return whether the index is complete (the queue is empty). **When it is not, the caller must
     * fall back to the LIKE path**: an index that is still being built looks to the user like
     * search is broken, which is far worse than search being slow.
     */
    suspend fun catchUpForSearch(): Boolean {
        drain(SEARCH_CATCH_UP_LIMIT)
        return withContext(ioDispatcher) { dao.pendingCount() == 0 }
    }

    /** Whether the index is complete (the queue is empty). */
    suspend fun isIndexComplete(): Boolean = withContext(ioDispatcher) { dao.pendingCount() == 0 }
}
