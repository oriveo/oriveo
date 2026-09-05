package ai.oriveo.community.core.data.entity

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.Index

/** A conversation folder. */
@Entity(
    tableName = "folders",
    primaryKeys = ["id", "accountId"],
    indices = [Index("accountId")],
)
data class FolderEntity(
    @ColumnInfo(collate = ColumnInfo.NOCASE)
    val id: String,
    val name: String,
    val sortOrder: Int,
    val createdAt: Long,
    val updatedAt: Long,
    /** See [ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID]. */
    val accountId: String = "local",
    val colorTag: String? = null,
)
