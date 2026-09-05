package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.EntityMapper.toDomain
import ai.oriveo.community.core.data.EntityMapper.toEntity
import ai.oriveo.community.core.data.dao.ConversationDao
import ai.oriveo.community.core.data.dao.FolderDao
import ai.oriveo.community.core.model.Folder
import ai.oriveo.community.core.model.FolderColor
import ai.oriveo.community.core.util.generateUuidString
import ai.oriveo.community.core.util.normalizeUuid
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.map

class FolderRepository(
    private val folderDao: FolderDao,
    private val conversationDao: ConversationDao,
) {
    private val accountId: String
        get() = LOCAL_PARTITION_ID

    @OptIn(ExperimentalCoroutinesApi::class)
    fun observeAll(): Flow<List<Folder>> =
        folderDao.observeAll(accountId).map { entities ->
            entities.map { it.toDomain() }
        }

    suspend fun create(name: String): Folder? {
        val scopedAccountId = accountId
        val trimmed = sanitizeFolderName(name) ?: return null
        val sortOrder = (folderDao.maxSortOrder(scopedAccountId) ?: 0) + 1000
        val existingFolders = folderDao.getAll(scopedAccountId).map { it.toDomain() }
        val colorTag = FolderColor.nextColor(existingFolders).tag
        val folder = Folder(
            id = generateUuidString(),
            name = trimmed,
            sortOrder = sortOrder,
            colorTag = colorTag,
        )
        folderDao.upsert(folder.toEntity(scopedAccountId))
        return folder
    }

    suspend fun rename(id: String, newName: String): Folder? {
        val scopedAccountId = accountId
        val trimmed = sanitizeFolderName(newName) ?: return null
        val existing = folderDao.getById(scopedAccountId, normalizeUuid(id))?.toDomain() ?: return null
        val updated = existing.copy(
            name = trimmed,
            updatedAt = System.currentTimeMillis(),
        )
        folderDao.upsert(updated.toEntity(scopedAccountId))
        return updated
    }

    suspend fun delete(id: String) {
        val scopedAccountId = accountId
        val normalizedId = normalizeUuid(id)
        val existing = folderDao.getById(scopedAccountId, normalizedId) ?: return
        conversationDao.clearFolderID(scopedAccountId, normalizedId)
        folderDao.deleteById(scopedAccountId, existing.id)
    }

    suspend fun updateColor(id: String, colorTag: String) {
        val scopedAccountId = accountId
        val existing = folderDao.getById(scopedAccountId, normalizeUuid(id))?.toDomain() ?: return
        val updated = existing.copy(
            colorTag = colorTag,
            updatedAt = System.currentTimeMillis(),
        )
        folderDao.upsert(updated.toEntity(scopedAccountId))
    }

    suspend fun migrateColorTags() {
        val scopedAccountId = accountId
        val all = folderDao.getAll(scopedAccountId).map { it.toDomain() }
            .sortedBy { it.sortOrder }
        if (all.all { it.colorTag != null }) return

        val palette = FolderColor.entries
        var previousIndex = -1
        for (folder in all) {
            if (folder.colorTag == null) {
                val nextIndex = (previousIndex + 1) % palette.size
                val color = palette[nextIndex]
                val updated = folder.copy(
                    colorTag = color.tag,
                    updatedAt = System.currentTimeMillis(),
                )
                folderDao.upsert(updated.toEntity(scopedAccountId))
                previousIndex = nextIndex
            } else {
                previousIndex = palette.indexOfFirst { it.tag == folder.colorTag }
                    .takeIf { it >= 0 } ?: previousIndex
            }
        }
    }

    private fun sanitizeFolderName(raw: String): String? {
        val trimmed = raw.trim().take(30)
        return trimmed.takeIf { it.isNotEmpty() }
    }
}
