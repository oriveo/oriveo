package ai.oriveo.community.core.data.entity

import androidx.room.Entity

/**
 * Local row of a memory item v2 (v41), keyed by (accountId, id).
 * Deleting writes a tombstone (status = deleted, text cleared) instead of removing the row.
 * Time fields are RFC 3339 text and [SERVER_TIMESTAMP] means "the server has yet to stamp the time"; list fields are JSON arrays.
 */
@Entity(
    tableName = "memory_items",
    primaryKeys = ["accountId", "id"],
)
data class MemoryItemEntity(
    val accountId: String,
    val id: String,
    val schemaVersion: Int,
    val layer: String,
    val kind: String,
    val status: String,
    val content: String,
    val scopeType: String,
    val scopeId: String?,
    val sourceType: String,
    val sourceConversationId: String?,
    /** JSON array. */
    val sourceMessageIds: String,
    val sourceObservedAt: String?,
    val sensitivity: String,
    val confidence: Double,
    val priority: Int,
    val pinned: Boolean,
    val revision: Int,
    val baseRevision: Int,
    val mutationId: String,
    val deviceId: String,
    val conflictGroupId: String?,
    val occurredAt: String?,
    val validFrom: String?,
    val lastConfirmedAt: String?,
    val createdAt: String?,
    val updatedAt: String?,
    val expiresAt: String?,
    val deletedAt: String?,
    /** JSON array. */
    val supersedes: String,
    /** [SYNC_PENDING] or [SYNC_SYNCED]. */
    val syncState: String,
) {
    companion object {
        const val SYNC_PENDING = "pending"
        const val SYNC_SYNCED = "synced"
        const val SERVER_TIMESTAMP = "serverTimestamp"
    }
}
