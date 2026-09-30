package ai.oriveo.community.core.data.entity

import androidx.room.Entity
import androidx.room.PrimaryKey

@Entity(tableName = "metadata_cache")
data class MetadataCacheEntity(
    @PrimaryKey val key: String = SINGLETON_KEY,
    val payload: String,
    val version: Int,
    val contractVersion: Int,
    val updatedAtMs: Long,
) {
    companion object {
        /** The whole lean payload row; kept only as a compatibility snapshot. */
        const val SINGLETON_KEY: String = "metadata"
        const val INDEX_KEY: String = "index"
        const val CATALOG_KEY_PREFIX: String = "catalog:"
        const val MODEL_FACTS_KEY: String = "model_facts"
    }
}
