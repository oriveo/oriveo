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

    
    @Query(
        """
        SELECT c.*,
               (SELECT COUNT(*) FROM messages m WHERE m.accountId = c.accountId AND m.conversationId = c.id) AS messageCount
        FROM conversations c
        WHERE c.accountId = :accountId
        ORDER BY c.updatedAt DESC
        """,
    )
    fun observeAllWithCount(accountId: String): Flow<List<ConversationWithCount>>

    @Query(
        """
        SELECT c.*,
               (SELECT COUNT(*) FROM messages m WHERE m.accountId = c.accountId AND m.conversationId = c.id) AS messageCount
        FROM conversations c
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
               (SELECT COUNT(*) FROM messages m WHERE m.accountId = c.accountId AND m.conversationId = c.id) AS messageCount
        FROM conversations c
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
        WHERE c.accountId = :accountId
          AND c.folderID IS NULL
          AND c.updatedAt < :recentStartMillis
          AND (
            c.isDraft = 0
            OR EXISTS (SELECT 1 FROM messages m WHERE m.accountId = c.accountId AND m.conversationId = c.id)
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

    @Query(
        """
        SELECT DISTINCT conversations.* FROM conversations
        LEFT JOIN messages ON conversations.accountId = messages.accountId
          AND conversations.id = messages.conversationId
        WHERE conversations.accountId = :accountId
          AND (
            conversations.title LIKE '%' || :query || '%'
            OR conversations.previewText LIKE '%' || :query || '%'
            OR messages.text LIKE '%' || :query || '%'
          )
        ORDER BY conversations.updatedAt DESC
        """
    )
    fun search(query: String, accountId: String): Flow<List<ConversationEntity>>

    
    
    @Query(
        """
        SELECT DISTINCT c.*,
               (SELECT COUNT(*) FROM messages m WHERE m.accountId = c.accountId AND m.conversationId = c.id) AS messageCount
        FROM conversations c
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
    fun searchWithCount(query: String, accountId: String): Flow<List<ConversationWithCount>>

    
    
    
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
            WHERE c.accountId = :accountId
              AND (SELECT COUNT(*) FROM messages m WHERE m.accountId = c.accountId AND m.conversationId = c.id) > 0
            LIMIT 1
        )
        """,
    )
    fun observeHasAnyWithMessages(accountId: String): Flow<Boolean>
}
