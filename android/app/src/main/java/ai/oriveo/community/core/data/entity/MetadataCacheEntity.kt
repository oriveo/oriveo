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

        const val SINGLETON_KEY: String = "metadata"
    }
}
