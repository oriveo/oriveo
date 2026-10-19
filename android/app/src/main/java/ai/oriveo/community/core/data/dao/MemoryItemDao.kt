package ai.oriveo.community.core.data.dao

import androidx.room.Dao
import androidx.room.Query
import androidx.room.Upsert
import ai.oriveo.community.core.data.entity.MemoryItemEntity
import kotlinx.coroutines.flow.Flow

/** Memory items (v41), keyed by partition. */
@Dao
interface MemoryItemDao {

    @Upsert
    suspend fun upsert(entity: MemoryItemEntity)

    @Query("SELECT * FROM memory_items WHERE accountId = :accountId AND id = :id")
    suspend fun get(accountId: String, id: String): MemoryItemEntity?

    /** Includes tombstones and conflict items; the caller orders them for display with MemoryItems.listOrder. */
    @Query("SELECT * FROM memory_items WHERE accountId = :accountId")
    suspend fun list(accountId: String): List<MemoryItemEntity>

    @Query("SELECT * FROM memory_items WHERE accountId = :accountId")
    fun observe(accountId: String): Flow<List<MemoryItemEntity>>

    @Query("SELECT * FROM memory_items WHERE accountId = :accountId AND syncState = :syncState")
    suspend fun listBySyncState(accountId: String, syncState: String): List<MemoryItemEntity>

    @Query("DELETE FROM memory_items WHERE accountId = :accountId")
    suspend fun deleteByAccount(accountId: String)
}
