package ai.oriveo.community.core.data.dao

import androidx.room.Dao
import androidx.room.Query
import androidx.room.Upsert
import ai.oriveo.community.core.data.entity.NoteFolderEntity
import kotlinx.coroutines.flow.Flow


@Dao
interface NoteFolderDao {

    @Query("SELECT * FROM note_folders WHERE accountId = :accountId AND deletedAt IS NULL ORDER BY sortOrder ASC")
    fun observeActive(accountId: String): Flow<List<NoteFolderEntity>>

    @Query("SELECT * FROM note_folders WHERE accountId = :accountId AND deletedAt IS NULL ORDER BY sortOrder ASC")
    suspend fun getActive(accountId: String): List<NoteFolderEntity>

    
    @Query("SELECT * FROM note_folders WHERE accountId = :accountId")
    suspend fun getAll(accountId: String): List<NoteFolderEntity>

    @Query("SELECT * FROM note_folders WHERE accountId = :accountId AND id = :id LIMIT 1")
    suspend fun getById(accountId: String, id: String): NoteFolderEntity?

    @Query("SELECT * FROM note_folders WHERE accountId = :accountId AND id = :id LIMIT 1")
    suspend fun getByIdForAccount(accountId: String, id: String): NoteFolderEntity?

    @Query("SELECT MAX(sortOrder) FROM note_folders WHERE accountId = :accountId AND deletedAt IS NULL")
    suspend fun maxSortOrder(accountId: String): Int?

    @Upsert
    suspend fun upsert(folder: NoteFolderEntity)

    @Upsert
    suspend fun upsertAll(folders: List<NoteFolderEntity>)

    @Query("UPDATE note_folders SET deletedAt = :deletedAt, updatedAt = :updatedAt WHERE accountId = :accountId AND id = :id")
    suspend fun markDeleted(accountId: String, id: String, deletedAt: String, updatedAt: String)

    
    @Query("DELETE FROM note_folders WHERE accountId = :accountId AND id = :id")
    suspend fun hardDelete(accountId: String, id: String)

    @Query("DELETE FROM note_folders WHERE accountId = :accountId")
    suspend fun deleteByAccount(accountId: String)
}
