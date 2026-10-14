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

    /**
     * Write-back of the address source for unclassified records: touches only this column, does not change updatedAt, does not go through sync, and only fills empty values,
     * so it never overwrites a classification result written concurrently.
     */
    @Query(
        "UPDATE providers SET endpointSource = :source " +
            "WHERE accountId = :accountId AND id = :id AND endpointSource IS NULL",
    )
    suspend fun backfillEndpointSource(accountId: String, id: String, source: String)

    /**
     * Write-back for address-source backfill and lazy migration: touches only the source and literal-address columns, does not change updatedAt and does not go through sync.
     * It writes only if both columns still hold the values that were read (`IS` also works for NULL), so it never overwrites a concurrent edit or sync write.
     */
    @Query(
        "UPDATE providers SET endpointSource = :source, baseUrlText = :baseUrlText " +
            "WHERE accountId = :accountId AND id = :id " +
            "AND endpointSource IS :expectedSource AND baseUrlText IS :expectedBaseUrlText",
    )
    suspend fun reconcileEndpointSource(
        accountId: String,
        id: String,
        expectedSource: String?,
        expectedBaseUrlText: String?,
        source: String,
        baseUrlText: String?,
    )

    @Delete
    suspend fun delete(entity: ProviderEntity)

    @Query("DELETE FROM providers WHERE accountId = :accountId")
    suspend fun deleteByAccount(accountId: String)

    @Query("SELECT COUNT(*) FROM providers WHERE accountId = :accountId")
    suspend fun countByAccount(accountId: String): Int
}
