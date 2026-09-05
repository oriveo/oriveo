package ai.oriveo.community.core.data.entity

import androidx.room.Entity
import androidx.room.PrimaryKey


@Entity(tableName = "preferences")
data class PreferenceEntity(
    @PrimaryKey val key: String,
    val value: String,
)
