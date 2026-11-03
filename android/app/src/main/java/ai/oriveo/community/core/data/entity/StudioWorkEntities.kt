package ai.oriveo.community.core.data.entity

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.Index

/**
 * Studio work (studio_data_model.v1 localTables.studio_works, v11). Partitioned by [accountPartition];
 * times are epoch milliseconds, JSON array columns are stored as TEXT.
 */
@Entity(
    tableName = "studio_works",
    primaryKeys = ["id"],
    indices = [Index(value = ["accountPartition", "updatedAt"])],
)
data class StudioWorkEntity(
    @ColumnInfo(collate = ColumnInfo.NOCASE)
    val id: String,
    val title: String,
    @ColumnInfo(collate = ColumnInfo.NOCASE)
    val currentVersionId: String?,
    val source: String,
    val chatConversationId: String?,
    val chatMessageId: String?,
    val favorite: Boolean,
    /** JSON array of version ids. */
    val selectedVersionIds: String,
    /** JSON array of version ids. */
    val deletedVersionIds: String,
    val createdAt: Long,
    val updatedAt: Long,
    val deletedAt: Long?,
    val revision: Long,
    val baseRevision: Long,
    val accountPartition: String,
    val syncState: String,
)

/** One generation round of a work (localTables.studio_rounds, v11). */
@Entity(
    tableName = "studio_rounds",
    primaryKeys = ["id"],
    indices = [Index(value = ["workId"])],
)
data class StudioRoundEntity(
    @ColumnInfo(collate = ColumnInfo.NOCASE)
    val id: String,
    @ColumnInfo(collate = ColumnInfo.NOCASE)
    val workId: String,
    val index: Int,
    @ColumnInfo(collate = ColumnInfo.NOCASE)
    val baseVersionId: String?,
    val operation: String,
    val prompt: String,
    val composedPrompt: String,
    val enhancedPrompt: String?,
    /** JSON array of preset ids. */
    val presetIds: String,
    /** JSON object. */
    val params: String,
    /** JSON object. */
    val modelRef: String?,
    val status: String,
    val errorKind: String?,
    /** JSON object. */
    val adjustments: String,
    val nRequested: Int,
    val nDelivered: Int,
    val costEstimateUsd: Double?,
    val chargedUsd: Double?,
    val fundingSource: String,
    val managedJobId: String?,
    val clientJobId: String?,
    val startedAt: Long,
    val finishedAt: Long?,
)

/** One delivered image of a round (localTables.studio_versions, v11); [kept] = 0 is a candidate. */
@Entity(
    tableName = "studio_versions",
    primaryKeys = ["id"],
    indices = [Index(value = ["workId"]), Index(value = ["roundId"]), Index(value = ["assetId"])],
)
data class StudioVersionEntity(
    @ColumnInfo(collate = ColumnInfo.NOCASE)
    val id: String,
    @ColumnInfo(collate = ColumnInfo.NOCASE)
    val roundId: String,
    @ColumnInfo(collate = ColumnInfo.NOCASE)
    val workId: String,
    @ColumnInfo(collate = ColumnInfo.NOCASE)
    val parentVersionId: String?,
    @ColumnInfo(collate = ColumnInfo.NOCASE)
    val assetId: String,
    val width: Int,
    val height: Int,
    val mime: String,
    val kept: Boolean,
    val createdAt: Long,
)

/** Reference image of a round, ordered by [order] (localTables.studio_round_refs, v11). */
@Entity(
    tableName = "studio_round_refs",
    primaryKeys = ["roundId", "order"],
    indices = [Index(value = ["assetId"])],
)
data class StudioRoundRefEntity(
    @ColumnInfo(collate = ColumnInfo.NOCASE)
    val roundId: String,
    val order: Int,
    @ColumnInfo(collate = ColumnInfo.NOCASE)
    val assetId: String,
    val role: String,
)
