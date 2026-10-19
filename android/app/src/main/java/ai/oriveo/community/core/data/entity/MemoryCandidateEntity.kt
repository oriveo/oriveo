package ai.oriveo.community.core.data.entity

import androidx.room.Entity

/**
 * Local row of a memory candidate (v43), keyed by (accountId, id).
 * Stored on this device only: not synced and not part of backups.
 * [status] mirrors the candidate status and [payload] holds the whole candidate as JSON.
 */
@Entity(
    tableName = "memory_candidates",
    primaryKeys = ["accountId", "id"],
)
data class MemoryCandidateEntity(
    val accountId: String,
    val id: String,
    val status: String,
    /** The whole MemoryCandidate as JSON. */
    val payload: String,
)
