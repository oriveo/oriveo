package ai.oriveo.community.core.data.entity

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Index
import ai.oriveo.community.core.context.ContextManifest
import ai.oriveo.community.core.context.RhoCalibration
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json

private val ledgerJson = Json { ignoreUnknownKeys = true }

/**
 * Local-only bytes-to-tokens calibration per (transport instance, model), v38.
 * Not synced and not part of backups.
 */
@Entity(
    tableName = "context_rho_calibration",
    primaryKeys = ["transportInstanceId", "modelId"],
)
data class ContextRhoCalibrationEntity(
    val transportInstanceId: String,
    val modelId: String,
    val n: Int,
    val rho: Double,
    /** JSON array of the seed samples. */
    val seeds: String,
) {
    val calibration: RhoCalibration
        get() = RhoCalibration(
            n = n,
            rho = rho,
            seeds = runCatching { ledgerJson.decodeFromString(ListSerializer(Double.serializer()), seeds) }
                .getOrDefault(emptyList()),
        )

    companion object {
        fun of(transportInstanceId: String, modelId: String, calibration: RhoCalibration) = ContextRhoCalibrationEntity(
            transportInstanceId = transportInstanceId,
            modelId = modelId,
            n = calibration.n,
            rho = calibration.rho,
            seeds = ledgerJson.encodeToString(ListSerializer(Double.serializer()), calibration.seeds),
        )
    }
}

/**
 * Local-only record of what one request sent, v38. Only the latest
 * [ai.oriveo.community.core.context.ContextManifestLog.MAX_PER_CONVERSATION] rows per conversation are kept;
 * rows are removed together with their conversation by the conversation DAO.
 */
@Entity(
    tableName = "context_manifest",
    primaryKeys = ["conversationId", "requestId"],
    indices = [Index(value = ["conversationId", "createdAt"])],
)
data class ContextManifestEntity(
    @ColumnInfo(collate = ColumnInfo.NOCASE)
    val conversationId: String,
    val requestId: String,
    /** Epoch milliseconds. */
    val createdAt: Long,
    /** The full [ContextManifest] as JSON. */
    val json: String,
) {
    val manifest: ContextManifest
        get() = ledgerJson.decodeFromString(ContextManifest.serializer(), json)

    companion object {
        fun of(manifest: ContextManifest) = ContextManifestEntity(
            conversationId = manifest.conversationId,
            requestId = manifest.requestId,
            createdAt = manifest.createdAt,
            json = ledgerJson.encodeToString(ContextManifest.serializer(), manifest),
        )
    }
}

/**
 * One context checkpoint per (account, conversation, checkpointId), v39. Only the newest
 * [ai.oriveo.community.core.data.repository.ContextCompactionStore.MAX_PER_CONVERSATION] rows per conversation are kept;
 * rows cascade with their conversation.
 */
@Entity(
    tableName = "context_checkpoint",
    primaryKeys = ["accountId", "conversationId", "checkpointId"],
    foreignKeys = [
        ForeignKey(
            entity = ConversationEntity::class,
            parentColumns = ["id", "accountId"],
            childColumns = ["conversationId", "accountId"],
            onDelete = ForeignKey.CASCADE,
        ),
    ],
    indices = [Index(value = ["accountId", "conversationId", "createdAt"])],
)
data class ContextCheckpointEntity(
    val accountId: String,
    @ColumnInfo(collate = ColumnInfo.NOCASE)
    val conversationId: String,
    val checkpointId: String,
    /** `summary` or `fallback`. */
    val kind: String,
    val coversFrom: String,
    val coversTo: String,
    val coversDigest: String,
    val messagesCovered: Int,
    /** JSON array of user message ids. */
    val userMessageIds: String,
    val text: String,
    val summary: String?,
    val language: String?,
    val model: String,
    val packerVersion: String,
    /** Epoch milliseconds. */
    val createdAt: Long,
    val cost: Double?,
) {
    val userMessageIdList: List<String>
        get() = runCatching { ledgerJson.decodeFromString(ListSerializer(String.serializer()), userMessageIds) }
            .getOrDefault(emptyList())

    companion object {
        fun encodeUserMessageIds(ids: List<String>): String =
            ledgerJson.encodeToString(ListSerializer(String.serializer()), ids)
    }
}
