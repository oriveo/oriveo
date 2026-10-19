package ai.oriveo.community.core.data.dao

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Transaction
import androidx.room.Upsert
import ai.oriveo.community.core.context.ContextManifestLog
import ai.oriveo.community.core.data.entity.ContextManifestEntity
import ai.oriveo.community.core.data.entity.ContextRhoCalibrationEntity

/** Context ledger: rho calibration table and per-request manifests (local only). */
@Dao
interface ContextLedgerDao {

    @Upsert
    suspend fun upsertRho(entity: ContextRhoCalibrationEntity)

    @Query("SELECT * FROM context_rho_calibration WHERE transportInstanceId = :transportInstanceId AND modelId = :modelId")
    suspend fun rho(transportInstanceId: String, modelId: String): ContextRhoCalibrationEntity?

    @Query("SELECT * FROM context_rho_calibration ORDER BY transportInstanceId, modelId")
    suspend fun allRho(): List<ContextRhoCalibrationEntity>

    /** Insert one manifest, then keep only the newest MAX_PER_CONVERSATION of its conversation. */
    @Transaction
    suspend fun appendManifest(entity: ContextManifestEntity) {
        insertManifest(entity)
        trimManifests(entity.conversationId, ContextManifestLog.MAX_PER_CONVERSATION)
    }

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertManifest(entity: ContextManifestEntity)

    @Query(
        "DELETE FROM context_manifest WHERE conversationId = :conversationId AND rowid NOT IN (" +
            "SELECT rowid FROM context_manifest WHERE conversationId = :conversationId " +
            "ORDER BY createdAt DESC, rowid DESC LIMIT :keep)",
    )
    suspend fun trimManifests(conversationId: String, keep: Int)

    /** Oldest first. */
    @Query("SELECT * FROM context_manifest WHERE conversationId = :conversationId ORDER BY createdAt ASC, rowid ASC")
    suspend fun manifests(conversationId: String): List<ContextManifestEntity>
}
