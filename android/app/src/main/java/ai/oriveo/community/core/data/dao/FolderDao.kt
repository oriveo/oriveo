package ai.oriveo.community.core.data.dao

import androidx.room.Dao
import androidx.room.Query
import androidx.room.Upsert
import ai.oriveo.community.core.data.entity.FolderEntity
import kotlinx.coroutines.flow.Flow

@Dao
interface FolderDao {

    @Query("SELECT * FROM folders WHERE accountId = :accountId ORDER BY sortOrder ASC")
    fun observeAll(accountId: String): Flow<List<FolderEntity>>

    @Query("SELECT * FROM folders WHERE accountId = :accountId AND id = :id LIMIT 1")
    fun observeById(accountId: String, id: String): Flow<FolderEntity?>

    @Query("SELECT * FROM folders WHERE accountId = :accountId ORDER BY sortOrder ASC")
    suspend fun getAll(accountId: String): List<FolderEntity>

    @Query("SELECT * FROM folders WHERE accountId = :accountId AND id = :id LIMIT 1")
    suspend fun getById(accountId: String, id: String): FolderEntity?

    @Query("SELECT COUNT(*) FROM folders WHERE accountId = :accountId")
    suspend fun countByAccount(accountId: String): Int

    @Query("SELECT MAX(sortOrder) FROM folders WHERE accountId = :accountId")
    suspend fun maxSortOrder(accountId: String): Int?

    @Upsert
    suspend fun upsert(entity: FolderEntity)

    @Upsert
    suspend fun upsertAll(entities: List<FolderEntity>)

    @Query("DELETE FROM folders WHERE accountId = :accountId AND id = :id")
    suspend fun deleteById(accountId: String, id: String)

    @Query("DELETE FROM folders WHERE accountId = :accountId")
    suspend fun deleteByAccount(accountId: String)
}
