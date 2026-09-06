package ai.oriveo.community.core.data.dao

import androidx.room.Dao
import androidx.room.Delete
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Update
import ai.oriveo.community.core.data.entity.ProviderEntity
import kotlinx.coroutines.flow.Flow

@Dao
interface ProviderDao {

    @Query("SELECT * FROM providers WHERE accountId = :accountId ORDER BY kind ASC")
    fun observeAll(accountId: String): Flow<List<ProviderEntity>>

    @Query(
        """
        SELECT * FROM providers
        WHERE accountId = :accountId AND id = :id
        ORDER BY updatedAt DESC
        LIMIT 1
        """,
    )
    fun observeById(accountId: String, id: String): Flow<ProviderEntity?>

    @Query(
        """
        SELECT * FROM providers
        WHERE accountId = :accountId AND id = :id
        ORDER BY updatedAt DESC
        LIMIT 1
        """,
    )
    suspend fun getById(accountId: String, id: String): ProviderEntity?

    @Query("SELECT * FROM providers WHERE accountId = :accountId")
    suspend fun getAll(accountId: String): List<ProviderEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(entity: ProviderEntity)

    @Update
    suspend fun update(entity: ProviderEntity)

    @Query("DELETE FROM providers WHERE accountId = :accountId AND id = :id")
    suspend fun deleteById(accountId: String, id: String)

    @Delete
    suspend fun delete(entity: ProviderEntity)

    @Query("DELETE FROM providers WHERE accountId = :accountId")
    suspend fun deleteByAccount(accountId: String)

    @Query("SELECT COUNT(*) FROM providers WHERE accountId = :accountId")
    suspend fun countByAccount(accountId: String): Int
}
