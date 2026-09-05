package ai.oriveo.community.core.data.dao

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Transaction
import ai.oriveo.community.core.data.entity.SkillEntity
import kotlinx.coroutines.flow.Flow

@Dao
interface SkillDao {

    @Query(
        """SELECT * FROM skills
        WHERE accountId = :accountId AND source = :source
        ORDER BY isPinned DESC, pinOrder ASC, sortOrder ASC, usageCount DESC"""
    )
    fun observeBySource(accountId: String, source: String): Flow<List<SkillEntity>>

    @Query(
        """SELECT * FROM skills
        WHERE accountId = :accountId
        ORDER BY isPinned DESC, pinOrder ASC, sortOrder ASC, usageCount DESC"""
    )
    fun observeAll(accountId: String): Flow<List<SkillEntity>>

    @Query("SELECT * FROM skills WHERE id = :id LIMIT 1")
    suspend fun getById(id: String): SkillEntity?

    @Query(
        """SELECT * FROM skills
        WHERE accountId = :accountId
        ORDER BY isPinned DESC, pinOrder ASC, sortOrder ASC, usageCount DESC"""
    )
    suspend fun getAll(accountId: String): List<SkillEntity>

    @Query(
        """SELECT * FROM skills
        WHERE accountId = :accountId AND source = :source
        ORDER BY isPinned DESC, pinOrder ASC, sortOrder ASC, usageCount DESC"""
    )
    suspend fun getBySource(accountId: String, source: String): List<SkillEntity>

    @Query("SELECT COUNT(*) FROM skills WHERE accountId = :accountId")
    suspend fun countByAccount(accountId: String): Int

    @Query("SELECT COUNT(*) FROM skills WHERE accountId = :accountId AND source = :source")
    suspend fun countBySource(accountId: String, source: String): Int

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertAll(entities: List<SkillEntity>)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(entity: SkillEntity)

    @Query("DELETE FROM skills WHERE accountId = :accountId AND source = :source")
    suspend fun deleteBySource(accountId: String, source: String)

    @Query("DELETE FROM skills WHERE accountId = :accountId")
    suspend fun deleteByAccount(accountId: String)

    @Query("DELETE FROM skills WHERE id = :id")
    suspend fun deleteById(id: String)

    @Transaction
    suspend fun replaceBySource(accountId: String, source: String, entities: List<SkillEntity>) {
        deleteBySource(accountId, source)
        upsertAll(entities)
    }
}
