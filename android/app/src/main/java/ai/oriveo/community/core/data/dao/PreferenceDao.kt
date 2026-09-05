package ai.oriveo.community.core.data.dao

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import ai.oriveo.community.core.data.entity.PreferenceEntity
import kotlinx.coroutines.flow.Flow

@Dao
interface PreferenceDao {

    @Query("SELECT value FROM preferences WHERE `key` = :key")
    fun observe(key: String): Flow<String?>

    @Query("SELECT value FROM preferences WHERE `key` = :key")
    suspend fun get(key: String): String?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun set(entity: PreferenceEntity)

    @Query("DELETE FROM preferences WHERE `key` = :key")
    suspend fun delete(key: String)
}
