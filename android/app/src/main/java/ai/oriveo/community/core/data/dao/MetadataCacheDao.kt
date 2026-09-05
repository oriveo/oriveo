package ai.oriveo.community.core.data.dao

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import ai.oriveo.community.core.data.entity.MetadataCacheEntity


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

    @Query("DELETE FROM metadata_cache")
    suspend fun clear()
}
