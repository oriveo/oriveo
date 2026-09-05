package ai.oriveo.community.core.model

import androidx.compose.runtime.Immutable
import kotlinx.serialization.Serializable

/** A folder that groups conversations. */
@Immutable
@Serializable
data class Folder(
    val id: String,
    val name: String,
    val sortOrder: Int,
    val createdAt: Long = System.currentTimeMillis(),
    val updatedAt: Long = System.currentTimeMillis(),
    val colorTag: String? = null,
)
