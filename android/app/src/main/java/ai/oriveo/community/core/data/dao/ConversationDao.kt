package ai.oriveo.community.core.data.dao

import androidx.room.Dao
import androidx.room.Query
import androidx.room.Update
import androidx.room.Upsert
import ai.oriveo.community.core.data.entity.ConversationEntity
import ai.oriveo.community.core.data.entity.ConversationWithCount
import kotlinx.coroutines.flow.Flow

@Dao
interface ConversationDao {

    @Query("SELECT * FROM conversations WHERE accountId = :accountId ORDER BY updatedAt DESC")
    fun observeAll(accountId: String): Flow<List<ConversationEntity>>

    @Query("SELECT COUNT(*) FROM conversations WHERE accountId = :accountId")
    fun observeCount(accountId: String): Flow<Int>

    /**
     * The conversation list, with message counts.
     *
     * The count comes from `conversation_message_counts`, a small trigger-maintained table read by
     * primary key, rather than a correlated `COUNT(*) FROM messages`. What changes is the
     * *subscription surface*: a correlated subquery hangs this Flow off invalidation of the whole
     * `messages` table, so a streaming checkpoint that only rewrites `text` made SQLite re-run a
     * full count for the entire list.
     */
    @Query(
        """
        SELECT c.*,
               IFNULL(mc.messageCount, 0) AS messageCount
        FROM conversations c
        LEFT JOIN conversation_message_counts mc
          ON mc.accountId = c.accountId AND mc.conversationId = c.id
        WHERE c.accountId = :accountId
        ORDER BY c.updatedAt DESC
        """,
    )
    fun observeAllWithCount(accountId: String): Flow<List<ConversationWithCount>>

    @Query(
        """
        SELECT c.*,
               IFNULL(mc.messageCount, 0) AS messageCount
        FROM conversations c
        LEFT JOIN conversation_message_counts mc
          ON mc.accountId = c.accountId AND mc.conversationId = c.id
        WHERE c.accountId = :accountId
          AND c.folderID IS NULL
          AND c.updatedAt >= :recentStartMillis
        ORDER BY c.updatedAt DESC
        """,
    )
    fun observeUngroupedRecentWithCount(
        accountId: String,
        recentStartMillis: Long,
    ): Flow<List<ConversationWithCount>>

    @Query(
        """
        SELECT c.*,
               IFNULL(mc.messageCount, 0) AS messageCount
        FROM conversations c
        LEFT JOIN conversation_message_counts mc
          ON mc.accountId = c.accountId AND mc.conversationId = c.id
        WHERE c.accountId = :accountId
          AND c.folderID IS NULL
          AND c.updatedAt < :recentStartMillis
        ORDER BY c.updatedAt DESC
        LIMIT :limit
        """,
    )
    fun observeUngroupedEarlierWithCount(
        accountId: String,
        recentStartMillis: Long,
        limit: Int,
    ): Flow<List<ConversationWithCount>>

    @Query(
        """
        SELECT COUNT(*)
        FROM conversations c
        LEFT JOIN conversation_message_counts mc
          ON mc.accountId = c.accountId AND mc.conversationId = c.id
        WHERE c.accountId = :accountId
          AND c.folderID IS NULL
          AND c.updatedAt < :recentStartMillis
          AND (
            c.isDraft = 0
            OR IFNULL(mc.messageCount, 0) > 0
          )
        """,
    )
    fun observeUngroupedEarlierCount(
        accountId: String,
        recentStartMillis: Long,
    ): Flow<Int>

    @Query(
        """
        SELECT * FROM conversations
        WHERE accountId = :accountId AND id = :id
        ORDER BY updatedAt DESC
        LIMIT 1
        """,
    )
    fun observeById(accountId: String, id: String): Flow<ConversationEntity?>

    @Query(
        """
        SELECT * FROM conversations
        WHERE accountId = :accountId AND id = :id
        ORDER BY updatedAt DESC
        LIMIT 1
        """,
    )
    suspend fun getById(accountId: String, id: String): ConversationEntity?

    @Query("SELECT * FROM conversations WHERE accountId = :accountId ORDER BY updatedAt DESC")
    suspend fun getAll(accountId: String): List<ConversationEntity>

    /**
     * Search, with message counts.
     *
     * Message bodies are matched through `conversation_search_index` (FTS4, CJK tokenised as
     * bigrams) instead of scanning `messages.text` with `LIKE '%q%'`. In `EXPLAIN QUERY PLAN` the
     * `LIST SUBQUERY` reads `SCAN … VIRTUAL TABLE INDEX` (the inverted index) and `messages` no
     * longer appears in the plan at all.
     *
     * Titles and preview text deliberately keep their substring `LIKE`: `conversations` has few
     * rows with short fields so scanning it is not the bottleneck, and a title search is expected
     * to match substrings — token matching would be a regression there.
     *
     * `ftsQuery` is built by [ai.oriveo.community.core.data.search.ConversationFtsQuery], which
     * drops FTS syntax characters from the user's input as separators, so a malformed MATCH
     * expression cannot be constructed.
     *
     * LIMIT 200: search results have no paging semantics (the one consumer lays them all out at
     * once), so a user with thousands of conversations typing one common character would otherwise
     * pull every match back and render it in a single frame. 200 is already far past what anyone
     * scrolls through by eye; beyond that it is memory and first-frame cost for nothing.
     */
    @Query(
        """
        SELECT c.*,
               IFNULL(mc.messageCount, 0) AS messageCount
        FROM conversations c
        LEFT JOIN conversation_message_counts mc
          ON mc.accountId = c.accountId AND mc.conversationId = c.id
        WHERE c.accountId = :accountId
          AND (
            c.title LIKE '%' || :query || '%'
            OR c.previewText LIKE '%' || :query || '%'
            OR c.id IN (
              SELECT f.conversationId FROM conversation_search_index f
              WHERE conversation_search_index MATCH :ftsQuery AND f.accountId = :accountId
            )
          )
        ORDER BY c.updatedAt DESC
        LIMIT 200
        """
    )
    fun searchWithCount(query: String, ftsQuery: String, accountId: String): Flow<List<ConversationWithCount>>

    /**
     * Search when the input holds nothing indexable (pure punctuation or symbols): titles and
     * preview text only.
     *
     * This is a separate query rather than passing an empty MATCH parameter, because an empty
     * string handed to FTS4 raises a syntax error.
     */
    @Query(
        """
        SELECT c.*,
               IFNULL(mc.messageCount, 0) AS messageCount
        FROM conversations c
        LEFT JOIN conversation_message_counts mc
          ON mc.accountId = c.accountId AND mc.conversationId = c.id
        WHERE c.accountId = :accountId
          AND (
            c.title LIKE '%' || :query || '%'
            OR c.previewText LIKE '%' || :query || '%'
          )
        ORDER BY c.updatedAt DESC
        LIMIT 200
        """
    )
    fun searchMetadataWithCount(query: String, accountId: String): Flow<List<ConversationWithCount>>

    /**
     * Search on the **degraded path used while the index is still being built**: message bodies are
     * still matched with `LIKE '%q%'` over `messages.text`.
     *
     * Used only while `conversation_search_dirty` is not yet empty, which is the window right after
     * an existing database is upgraded. During that window, not finding message bodies at all would
     * read as "search is broken", which is much worse than search being slow, so this slow path has
     * to stay;
     * [ai.oriveo.community.core.data.repository.conversation.ConversationSearchService] switches to
     * it automatically. The count still comes from the join, never from a correlated subquery.
     */
    @Query(
        """
        SELECT DISTINCT c.*,
               IFNULL(mc.messageCount, 0) AS messageCount
        FROM conversations c
        LEFT JOIN conversation_message_counts mc
          ON mc.accountId = c.accountId AND mc.conversationId = c.id
        LEFT JOIN messages ON c.accountId = messages.accountId AND c.id = messages.conversationId
        WHERE c.accountId = :accountId
          AND (
            c.title LIKE '%' || :query || '%'
            OR c.previewText LIKE '%' || :query || '%'
            OR messages.text LIKE '%' || :query || '%'
          )
        ORDER BY c.updatedAt DESC
        LIMIT 200
        """
    )
    fun searchPendingIndexWithCount(query: String, accountId: String): Flow<List<ConversationWithCount>>

    @Upsert
    suspend fun upsert(entity: ConversationEntity)

    @Upsert
    suspend fun upsertAll(entities: List<ConversationEntity>)

    @Update
    suspend fun update(entity: ConversationEntity)

    @Update
    suspend fun updateAll(entities: List<ConversationEntity>)

    @Query("DELETE FROM conversations WHERE accountId = :accountId AND id = :id")
    suspend fun deleteById(accountId: String, id: String)

    @Query("DELETE FROM conversations WHERE accountId = :accountId AND id IN (:ids) COLLATE NOCASE")
    suspend fun deleteByIds(accountId: String, ids: Collection<String>)

    @Query("DELETE FROM conversations WHERE accountId = :accountId")
    suspend fun deleteByAccount(accountId: String)

    @Query("UPDATE conversations SET folderID = :folderID WHERE accountId = :accountId AND id = :id")
    suspend fun updateFolderID(accountId: String, id: String, folderID: String?)

    @Query("UPDATE conversations SET folderID = :folderID WHERE accountId = :accountId AND id IN (:ids)")
    suspend fun batchUpdateFolderID(accountId: String, ids: List<String>, folderID: String?)

    @Query("UPDATE conversations SET folderID = NULL WHERE accountId = :accountId AND id IN (:ids)")
    suspend fun batchClearFolderID(accountId: String, ids: List<String>)

    @Query("UPDATE conversations SET pinnedNoteIdsJson = :pinnedNoteIdsJson WHERE accountId = :accountId AND id = :id")
    suspend fun updatePinnedNoteIds(accountId: String, id: String, pinnedNoteIdsJson: String?)

    @Query("UPDATE conversations SET useMemory = :useMemory WHERE accountId = :accountId AND id = :id")
    suspend fun updateUseMemory(accountId: String, id: String, useMemory: Boolean)

    @Query("UPDATE conversations SET folderID = NULL WHERE accountId = :accountId AND folderID = :folderID")
    suspend fun clearFolderID(accountId: String, folderID: String)

    @Query("SELECT COUNT(*) FROM conversations WHERE accountId = :accountId")
    suspend fun count(accountId: String): Int

    @Query("SELECT * FROM conversations WHERE isDraft = 1 AND accountId = :accountId ORDER BY updatedAt DESC")
    suspend fun getAllDrafts(accountId: String): List<ConversationEntity>

    @Query(
        """
        SELECT * FROM conversations
        WHERE isDraft = 1
          AND accountId = :accountId
          AND draftText = ''
              AND NOT EXISTS (
              SELECT 1 FROM messages
              WHERE messages.accountId = conversations.accountId
                AND messages.conversationId = conversations.id LIMIT 1
          )
        ORDER BY updatedAt DESC
        LIMIT 1
        """,
    )
    suspend fun findFirstEmptyDraft(accountId: String): ConversationEntity?

    @Query("SELECT COUNT(*) FROM conversations WHERE accountId = :accountId")
    suspend fun countByAccount(accountId: String): Int

    @Query(
        """
        SELECT EXISTS(
            SELECT 1 FROM conversations c
            LEFT JOIN conversation_message_counts mc
              ON mc.accountId = c.accountId AND mc.conversationId = c.id
            WHERE c.accountId = :accountId
              AND IFNULL(mc.messageCount, 0) > 0
            LIMIT 1
        )
        """,
    )
    fun observeHasAnyWithMessages(accountId: String): Flow<Boolean>
}
