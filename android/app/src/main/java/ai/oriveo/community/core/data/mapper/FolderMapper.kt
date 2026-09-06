package ai.oriveo.community.core.data.mapper

import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.entity.FolderEntity
import ai.oriveo.community.core.model.Folder
import ai.oriveo.community.core.util.normalizeUuid

object FolderMapper {

    fun FolderEntity.toDomain(): Folder = Folder(
        id = id,
        name = name,
        sortOrder = sortOrder,
        colorTag = colorTag,
        createdAt = createdAt,
        updatedAt = updatedAt,
    )

    fun Folder.toEntity(accountId: String = LOCAL_PARTITION_ID): FolderEntity = FolderEntity(
        id = normalizeUuid(id),
        name = name,
        sortOrder = sortOrder,
        colorTag = colorTag,
        createdAt = createdAt,
        updatedAt = updatedAt,
        accountId = accountId,
    )
}
