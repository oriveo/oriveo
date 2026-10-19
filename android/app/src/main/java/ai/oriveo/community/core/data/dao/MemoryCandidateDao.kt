package ai.oriveo.community.core.data.dao

import androidx.room.Dao
import androidx.room.Query
import androidx.room.Upsert
import ai.oriveo.community.core.data.entity.MemoryCandidateEntity

/** Memory candidates (v43), keyed by partition. */
@Dao
interface MemoryCandidateDao {

    @Upsert
    suspend fun upsert(entity: MemoryCandidateEntity)

    @Query("SELECT * FROM memory_candidates WHERE accountId = :accountId AND id = :id")
    suspend fun get(accountId: String, id: String): MemoryCandidateEntity?

    @Query("SELECT * FROM memory_candidates WHERE accountId = :accountId ORDER BY id ASC")
    suspend fun list(accountId: String): List<MemoryCandidateEntity>

    @Query("DELETE FROM memory_candidates WHERE accountId = :accountId AND id = :id")
    suspend fun delete(accountId: String, id: String)

    @Query("DELETE FROM memory_candidates WHERE accountId = :accountId")
    suspend fun deleteByAccount(accountId: String)
}
