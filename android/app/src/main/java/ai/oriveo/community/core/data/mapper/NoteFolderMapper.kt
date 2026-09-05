package ai.oriveo.community.core.data.mapper

import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.entity.NoteFolderEntity
import ai.oriveo.community.core.model.NoteFolder
import ai.oriveo.community.core.util.normalizeUuid


object NoteFolderMapper {

    fun NoteFolderEntity.toDomain(): NoteFolder = NoteFolder(
        id = id,
        name = name,
        sortOrder = sortOrder,
        colorTag = colorTag,
        createdAt = createdAt,
        updatedAt = updatedAt,
        deletedAt = deletedAt,
    )

    fun NoteFolder.toEntity(accountId: String = LOCAL_PARTITION_ID): NoteFolderEntity = NoteFolderEntity(
        id = normalizeUuid(id),
        name = name,
        sortOrder = sortOrder,
        colorTag = colorTag,
        createdAt = createdAt,
        updatedAt = updatedAt,
        deletedAt = deletedAt,
        accountId = accountId,
    )
}
