package ai.oriveo.community.core.data.dao

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import ai.oriveo.community.core.data.entity.MetadataCacheEntity

/**
 * Rows are keyed by purpose: `index`, one `catalog:<provider>` row per provider, and
 * `model_facts`. The older single `metadata` row (the whole lean payload) is still read as a
 * compatibility snapshot. The table layout is unchanged.
 */
@Dao
interface MetadataCacheDao {

    @Query("SELECT length(payload) FROM metadata_cache WHERE `key` = :key")
    suspend fun payloadLength(key: String = MetadataCacheEntity.SINGLETON_KEY): Int?

    @Query("SELECT substr(payload, :start, :count) FROM metadata_cache WHERE `key` = :key")
    suspend fun payloadChunk(
        start: Int,
        count: Int,
        key: String = MetadataCacheEntity.SINGLETON_KEY,
    ): String?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(entity: MetadataCacheEntity)

    /** When the row was last written or confirmed; null when the row is absent. */
    @Query("SELECT updatedAtMs FROM metadata_cache WHERE `key` = :key")
    suspend fun updatedAtMs(key: String): Long?

    /**
     * A 304 refreshes the timestamp only and never rewrites the body. Returns the number of rows
     * touched; 0 means the row does not exist and the caller decides whether to write it.
     */
    @Query("UPDATE metadata_cache SET updatedAtMs = :updatedAtMs WHERE `key` = :key")
    suspend fun touch(key: String, updatedAtMs: Long): Int

    @Query("DELETE FROM metadata_cache WHERE `key` = :key")
    suspend fun delete(key: String)

    /** Deletes every row except [keep]; used when falling back to lean drops the split rows. */
    @Query("DELETE FROM metadata_cache WHERE `key` != :keep")
    suspend fun deleteAllExcept(keep: String)

    @Query("DELETE FROM metadata_cache")
    suspend fun clear()
}
