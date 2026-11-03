package ai.oriveo.community.core.data.dao

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Upsert
import ai.oriveo.community.core.data.entity.StudioRoundEntity
import ai.oriveo.community.core.data.entity.StudioRoundRefEntity
import ai.oriveo.community.core.data.entity.StudioVersionEntity
import ai.oriveo.community.core.data.entity.StudioWorkEntity

/** Studio work tables (v11). */
@Dao
interface StudioWorkDao {

    /**
     * Every asset id the studio tables point at: all version rows (kept and candidate, tombstoned works included)
     * plus all round reference rows. No partition or state filter; orphan sweepers treat these as referenced.
     * UNION ALL on purpose: assetId is NOCASE, so UNION would fold non-UUID keys that differ only by case.
     */
    @Query("SELECT assetId FROM studio_versions UNION ALL SELECT assetId FROM studio_round_refs")
    suspend fun referencedAssetIds(): List<String>

    /** Work row by id in any partition, tombstones included. */
    @Query("SELECT * FROM studio_works WHERE id = :id")
    suspend fun getWork(id: String): StudioWorkEntity?

    /** Live works of one partition, newest updatedAt first, then id ascending. */
    @Query(
        "SELECT * FROM studio_works WHERE accountPartition = :partition AND deletedAt IS NULL " +
            "ORDER BY updatedAt DESC, id ASC",
    )
    suspend fun listWorks(partition: String): List<StudioWorkEntity>

    @Upsert
    suspend fun upsertWork(work: StudioWorkEntity)

    @Upsert
    suspend fun upsertRound(round: StudioRoundEntity)

    /** Existing version rows win, so a repeated delivery never resets the kept flag. */
    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertVersions(versions: List<StudioVersionEntity>)

    @Upsert
    suspend fun upsertRefs(refs: List<StudioRoundRefEntity>)

    @Query("SELECT * FROM studio_rounds WHERE workId = :workId ORDER BY `index` ASC, id ASC")
    suspend fun roundsOf(workId: String): List<StudioRoundEntity>

    /** Versions of a work in candidate order: createdAt, then id. */
    @Query("SELECT * FROM studio_versions WHERE workId = :workId ORDER BY createdAt ASC, id ASC")
    suspend fun versionsOf(workId: String): List<StudioVersionEntity>

    @Query("SELECT * FROM studio_versions WHERE workId = :workId AND id = :versionId")
    suspend fun getVersion(workId: String, versionId: String): StudioVersionEntity?

    /** Marks a candidate kept; returns 0 when the row is missing or already kept. */
    @Query("UPDATE studio_versions SET kept = 1 WHERE workId = :workId AND id = :versionId AND kept = 0")
    suspend fun markKept(workId: String, versionId: String): Int

    /** Reference rows of a work, by round index, then order. */
    @Query(
        "SELECT r.* FROM studio_round_refs r INNER JOIN studio_rounds o ON o.id = r.roundId " +
            "WHERE o.workId = :workId ORDER BY o.`index` ASC, r.`order` ASC",
    )
    suspend fun refsOf(workId: String): List<StudioRoundRefEntity>
}
