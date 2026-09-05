package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.dao.NoteDao
import ai.oriveo.community.core.data.dao.NoteFolderDao
import ai.oriveo.community.core.data.mapper.NoteFolderMapper.toDomain
import ai.oriveo.community.core.data.mapper.NoteFolderMapper.toEntity
import ai.oriveo.community.core.data.mapper.NoteMapper
import ai.oriveo.community.core.data.mapper.NoteMapper.toDomain
import ai.oriveo.community.core.data.mapper.NoteMapper.toEntity
import ai.oriveo.community.core.model.FolderColor
import ai.oriveo.community.core.model.Note
import ai.oriveo.community.core.model.NoteCaptureKind
import ai.oriveo.community.core.model.NoteFolder
import ai.oriveo.community.core.model.NoteTitleSource
import ai.oriveo.community.core.model.ProvenanceEntry
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.notes.NoteExport
import ai.oriveo.community.core.notes.NoteFtsQuery
import ai.oriveo.community.core.notes.NoteListing
import ai.oriveo.community.core.notes.NoteRecall
import ai.oriveo.community.core.notes.NoteSort
import ai.oriveo.community.core.notes.NoteTime
import ai.oriveo.community.core.notes.NoteTitle
import ai.oriveo.community.core.util.generateUuidString
import ai.oriveo.community.core.util.normalizeUuid
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.map


class NoteRepository(
    private val noteDao: NoteDao,
    private val noteFolderDao: NoteFolderDao,
) {
    private val accountId: String
        get() = LOCAL_PARTITION_ID

    private fun writeCloudIfBound(expectedAccountId: String, write: () -> Unit) {}

    
    @OptIn(ExperimentalCoroutinesApi::class)
    fun observeActive(): Flow<List<Note>> =
        noteDao.observeActive(accountId).map { list -> list.map { it.toDomain() } }

    @OptIn(ExperimentalCoroutinesApi::class)
    fun observeTrash(): Flow<List<Note>> =
        noteDao.observeTrash(accountId).map { list -> list.map { it.toDomain() } }

    @OptIn(ExperimentalCoroutinesApi::class)
    fun observeNote(id: String): Flow<Note?> =
        noteDao.observeById(accountId, normalizeUuid(id)).map { entity ->
            entity?.toDomain()
        }

    @OptIn(ExperimentalCoroutinesApi::class)
    fun observeFolders(): Flow<List<NoteFolder>> =
        noteFolderDao.observeActive(accountId).map { list -> list.map { it.toDomain() } }

    suspend fun getNote(id: String): Note? = getScopedNoteEntity(id)?.toDomain()

    suspend fun getActiveNotesByIds(ids: List<String>): List<Note> =
        if (ids.isEmpty()) emptyList()
        else noteDao.getActiveByIds(accountId, ids.map(::normalizeUuid)).map { it.toDomain() }

    suspend fun getActiveNotes(): List<Note> = noteDao.getAllActive(accountId).map { it.toDomain() }

    
    suspend fun createNote(input: CreateNoteInput): Note {
        val scopedAccountId = accountId
        val now = NoteTime.nowIso()
        val manual = !input.title.isNullOrBlank()
        val title = if (manual) {
            input.title!!.trim()
        } else {
            NoteTitle.placeholderTitleFromSource(input.sourcePrompt, input.body)
        }
        val note = Note(
            id = generateUuidString(),
            title = title,
            titleSource = if (manual) NoteTitleSource.Manual else NoteTitleSource.Placeholder,
            body = input.body,
            bodySnapshot = input.bodySnapshot,
            userNote = input.userNote,
            tags = input.tags.cleanTags(),
            noteFolderID = input.noteFolderID?.let(::normalizeUuid),
            sourceConversationId = input.sourceConversationId,
            sourceMessageId = input.sourceMessageId,
            sourceModelID = input.sourceModelID,
            sourceModelName = input.sourceModelName,
            sourceProviderKind = input.sourceProviderKind,
            sourceProviderName = input.sourceProviderName,
            sourcePrompt = input.sourcePrompt,
            captureKind = input.captureKind,
            provenance = input.provenance,
            isPinned = false,
            createdAt = now,
            updatedAt = now,
        )
        writeNote(scopedAccountId, note, forUpdate = false)
        return note
    }

    suspend fun createBlankNote(folderId: String? = null): Note = createNote(
        CreateNoteInput(body = "", captureKind = NoteCaptureKind.Blank, noteFolderID = folderId),
    )

    
    suspend fun discardEmptyBlankNoteIfNeeded(id: String): Boolean {
        val scopedAccountId = accountId
        val nid = normalizeUuid(id)
        val existing = getScopedNoteEntity(nid, scopedAccountId)?.toDomain() ?: return false
        if (!existing.isDiscardableEmptyBlankNote()) return false
        if (!isCurrentAccount(scopedAccountId)) return false
        noteDao.hardDeleteWithIndex(scopedAccountId, nid)
        return true
    }

    
    suspend fun updateTitle(id: String, title: String): Note? {
        val scopedAccountId = accountId
        val existing = getScopedNoteEntity(id, scopedAccountId)?.toDomain() ?: return null
        val trimmed = title.trim()
        val (newTitle, newSource) = if (trimmed.isEmpty()) {
            NoteTitle.placeholderTitleFromSource(existing.sourcePrompt, existing.body) to NoteTitleSource.Placeholder
        } else {
            trimmed to NoteTitleSource.Manual
        }
        val updated = existing.copy(
            title = newTitle,
            titleSource = newSource,
            updatedAt = NoteTime.nowIso(),
        )
        if (!writeNote(scopedAccountId, updated, forUpdate = true)) return null
        return updated
    }

    suspend fun updateBody(id: String, body: String): Note? {
        val scopedAccountId = accountId
        val existing = getScopedNoteEntity(id, scopedAccountId)?.toDomain() ?: return null
        val (newTitle, newSource) = if (existing.titleSource == NoteTitleSource.Placeholder) {
            NoteTitle.placeholderTitleFromSource(existing.sourcePrompt, body) to NoteTitleSource.Placeholder
        } else {
            existing.title to existing.titleSource
        }
        val updated = existing.copy(
            body = body,
            title = newTitle,
            titleSource = newSource,
            updatedAt = NoteTime.nowIso(),
        )
        if (!writeNote(scopedAccountId, updated, forUpdate = true)) return null
        return updated
    }

    suspend fun replaceNote(id: String, input: CreateNoteInput): Note? {
        val scopedAccountId = accountId
        val existing = getScopedNoteEntity(id, scopedAccountId)?.toDomain() ?: return null
        val (newTitle, newSource) = if (existing.titleSource == NoteTitleSource.Placeholder) {
            NoteTitle.placeholderTitleFromSource(input.sourcePrompt, input.body) to NoteTitleSource.Placeholder
        } else {
            existing.title to existing.titleSource
        }
        val updated = existing.copy(
            title = newTitle,
            titleSource = newSource,
            body = input.body,
            bodySnapshot = input.bodySnapshot,
            sourceConversationId = input.sourceConversationId,
            sourceMessageId = input.sourceMessageId,
            sourceModelID = input.sourceModelID,
            sourceModelName = input.sourceModelName,
            sourceProviderKind = input.sourceProviderKind,
            sourceProviderName = input.sourceProviderName,
            sourcePrompt = input.sourcePrompt,
            captureKind = input.captureKind,
            provenance = emptyList(),
            updatedAt = NoteTime.nowIso(),
        )
        if (!writeNote(scopedAccountId, updated, forUpdate = true)) return null
        return updated
    }

    suspend fun updateUserNote(id: String, userNote: String?): Note? {
        val scopedAccountId = accountId
        val existing = getScopedNoteEntity(id, scopedAccountId)?.toDomain() ?: return null
        val updated = existing.copy(userNote = userNote?.trim(), updatedAt = NoteTime.nowIso())
        if (!writeNote(scopedAccountId, updated, forUpdate = true)) return null
        return updated
    }

    suspend fun updateTags(id: String, tags: List<String>): Note? {
        val scopedAccountId = accountId
        val existing = getScopedNoteEntity(id, scopedAccountId)?.toDomain() ?: return null
        val updated = existing.copy(tags = tags.cleanTags(), updatedAt = NoteTime.nowIso())
        if (!writeNote(scopedAccountId, updated, forUpdate = true)) return null
        return updated
    }

    suspend fun moveToFolder(id: String, folderId: String?): Note? {
        val scopedAccountId = accountId
        val existing = getScopedNoteEntity(id, scopedAccountId)?.toDomain() ?: return null
        val updated = existing.copy(noteFolderID = folderId?.let(::normalizeUuid), updatedAt = NoteTime.nowIso())
        if (!writeNote(scopedAccountId, updated, forUpdate = true)) return null
        return updated
    }

    suspend fun pinNote(id: String, isPinned: Boolean): Note? {
        val scopedAccountId = accountId
        val existing = getScopedNoteEntity(id, scopedAccountId)?.toDomain() ?: return null
        val updated = existing.copy(isPinned = isPinned, updatedAt = NoteTime.nowIso())
        if (!writeNote(scopedAccountId, updated, forUpdate = true)) return null
        return updated
    }

    
    suspend fun softDeleteNote(id: String) {
        val scopedAccountId = accountId
        val nid = normalizeUuid(id)
        val existing = getScopedNoteEntity(nid, scopedAccountId)?.toDomain() ?: return
        val now = NoteTime.nowIso()
        if (!isCurrentAccount(scopedAccountId)) return
        noteDao.softDeleteWithIndex(scopedAccountId, nid, now, now)
    }

    suspend fun restoreNote(id: String) {
        val scopedAccountId = accountId
        val nid = normalizeUuid(id)
        val existing = getScopedNoteEntity(nid, scopedAccountId)?.toDomain() ?: return
        val now = NoteTime.nowIso()
        if (!isCurrentAccount(scopedAccountId)) return
        noteDao.restoreWithIndex(
            scopedAccountId, nid, now,
            NoteMapper.ftsTitle(existing), NoteMapper.ftsBody(existing),
            NoteMapper.ftsUserNote(existing), NoteMapper.ftsTagsText(existing),
        )
    }

    suspend fun emptyTrash() {
        val scopedAccountId = accountId
        val ids = noteDao.getAllTrashed(scopedAccountId).map { it.id }
        if (ids.isEmpty()) return
        if (!isCurrentAccount(scopedAccountId)) return
        noteDao.hardDeleteTrash(scopedAccountId)
    }

    
    suspend fun permanentlyDeleteNote(id: String) {
        val scopedAccountId = accountId
        val nid = normalizeUuid(id)
        if (getScopedNoteEntity(nid, scopedAccountId) == null) return
        if (!isCurrentAccount(scopedAccountId)) return
        noteDao.hardDeleteWithIndex(scopedAccountId, nid)
    }

    
    suspend fun createFolder(name: String, colorTag: String? = null): NoteFolder? {
        val scopedAccountId = accountId
        val trimmed = name.trim().take(30).takeIf { it.isNotEmpty() } ?: return null
        val now = NoteTime.nowIso()
        val sortOrder = (noteFolderDao.maxSortOrder(scopedAccountId) ?: 0) + SORT_STEP
        val activeCount = noteFolderDao.getActive(scopedAccountId).size
        val color = colorTag ?: nextFolderColorTag(activeCount)
        val folder = NoteFolder(
            id = generateUuidString(),
            name = trimmed,
            sortOrder = sortOrder,
            colorTag = color,
            createdAt = now,
            updatedAt = now,
        )
        if (!isCurrentAccount(scopedAccountId)) return null
        noteFolderDao.upsert(folder.toEntity(scopedAccountId))
        return folder
    }

    suspend fun renameFolder(id: String, name: String): NoteFolder? {
        val scopedAccountId = accountId
        val trimmed = name.trim().take(30).takeIf { it.isNotEmpty() } ?: return null
        val existing = getScopedNoteFolderEntity(id, scopedAccountId)?.toDomain() ?: return null
        val updated = existing.copy(name = trimmed, updatedAt = NoteTime.nowIso())
        if (!isCurrentAccount(scopedAccountId)) return null
        noteFolderDao.upsert(updated.toEntity(scopedAccountId))
        return updated
    }

    suspend fun setFolderColor(id: String, colorTag: String): NoteFolder? {
        val scopedAccountId = accountId
        val existing = getScopedNoteFolderEntity(id, scopedAccountId)?.toDomain() ?: return null
        val updated = existing.copy(colorTag = colorTag, updatedAt = NoteTime.nowIso())
        if (!isCurrentAccount(scopedAccountId)) return null
        noteFolderDao.upsert(updated.toEntity(scopedAccountId))
        return updated
    }

    suspend fun deleteFolder(id: String) {
        val scopedAccountId = accountId
        val nid = normalizeUuid(id)
        val existing = getScopedNoteFolderEntity(nid, scopedAccountId)?.toDomain() ?: return
        val now = NoteTime.nowIso()
        val affectedNoteIds = noteDao.getAll(scopedAccountId)
            .filter { it.noteFolderID?.let(::normalizeUuid) == nid }
            .map { it.id }
        if (!isCurrentAccount(scopedAccountId)) return
        noteFolderDao.markDeleted(scopedAccountId, nid, now, now)
        noteDao.clearNoteFolder(scopedAccountId, nid, now)
    }

    
    suspend fun searchNotes(
        query: String,
        folderId: String? = null,
        tags: List<String> = emptyList(),
        sort: NoteSort = NoteSort.UpdatedAt,
    ): List<Note> {
        val candidates: List<Note> = if (query.isBlank()) {
            noteDao.getAllActive(accountId).map { it.toDomain() }
        } else {
            val fts = NoteFtsQuery.build(query)
            val hits = fts?.let {
                runCatching { noteDao.searchActive(accountId, it) }.getOrDefault(emptyList())
            } ?: emptyList()
            val rows = hits.ifEmpty { noteDao.searchActiveLike(accountId, "%${escapeLike(query)}%") }
            rows.map { it.toDomain() }
        }
        return NoteListing.filterAndSort(candidates, folderId, tags, sort)
    }

    fun findRelatedNotes(
        inputText: String,
        notes: List<Note>,
        limit: Int = NoteRecall.DEFAULT_LIMIT,
        minScore: Int = NoteRecall.DEFAULT_MIN_SCORE,
    ): List<NoteRecall.Result> = NoteRecall.findRelatedNotes(inputText, notes, limit, minScore)

    
    suspend fun recallCandidateIds(terms: List<String>, limit: Int): List<String> {
        if (limit <= 0) return emptyList()
        val query = NoteFtsQuery.buildAnyTermPrefix(terms.filter { it.length >= 3 }) ?: return emptyList()
        return runCatching { noteDao.recallCandidateIds(accountId, query, limit) }.getOrDefault(emptyList())
    }

    fun exportMarkdown(note: Note, untitled: String): String = NoteExport.buildNoteMarkdown(note, untitled)

    fun exportMarkdownFilename(note: Note, untitled: String): String =
        NoteExport.buildNoteMarkdownFilename(note, untitled)

    
    
    private suspend fun writeNote(scopedAccountId: String, note: Note, forUpdate: Boolean): Boolean {
        if (!isCurrentAccount(scopedAccountId)) return false
        noteDao.upsertWithIndex(
            note.toEntity(scopedAccountId),
            NoteMapper.ftsTitle(note),
            NoteMapper.ftsBody(note),
            NoteMapper.ftsUserNote(note),
            NoteMapper.ftsTagsText(note),
        )
        return true
    }

    private fun nextFolderColorTag(activeCount: Int): String {
        val palette = FolderColor.entries
        return palette[activeCount % palette.size].tag
    }

    private suspend fun getScopedNoteEntity(id: String, scopedAccountId: String = accountId) =
        noteDao.getByIdForAccount(scopedAccountId, normalizeUuid(id))

    private suspend fun getScopedNoteFolderEntity(id: String, scopedAccountId: String = accountId) =
        noteFolderDao.getByIdForAccount(scopedAccountId, normalizeUuid(id))

    private fun isCurrentAccount(scopedAccountId: String): Boolean =
        LOCAL_PARTITION_ID == scopedAccountId

    private fun List<String>.cleanTags(): List<String> =
        mapNotNull { it.trim().takeIf(String::isNotEmpty) }.distinct()

    private fun Note.isDiscardableEmptyBlankNote(): Boolean =
        deletedAt == null &&
            captureKind == NoteCaptureKind.Blank &&
            titleSource == NoteTitleSource.Placeholder &&
            title.isBlank() &&
            body.isBlank() &&
            bodySnapshot.isNullOrBlank() &&
            userNote.isNullOrBlank() &&
            tags.all { it.isBlank() } &&
            sourceConversationId.isNullOrBlank() &&
            sourceMessageId.isNullOrBlank() &&
            sourceModelID.isNullOrBlank() &&
            sourceModelName.isNullOrBlank() &&
            sourceProviderKind == null &&
            sourceProviderName.isNullOrBlank() &&
            sourcePrompt.isNullOrBlank() &&
            provenance.isEmpty() &&
            !isPinned

    private fun escapeLike(raw: String): String =
        raw.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")

    companion object {
        private const val SORT_STEP = 1000
    }
}


data class CreateNoteInput(
    val title: String? = null,
    val body: String,
    val bodySnapshot: String? = null,
    val userNote: String? = null,
    val tags: List<String> = emptyList(),
    val noteFolderID: String? = null,
    val sourceConversationId: String? = null,
    val sourceMessageId: String? = null,
    val sourceModelID: String? = null,
    val sourceModelName: String? = null,
    val sourceProviderKind: ProviderKind? = null,
    val sourceProviderName: String? = null,
    val sourcePrompt: String? = null,
    val captureKind: NoteCaptureKind = NoteCaptureKind.Blank,
    val provenance: List<ProvenanceEntry> = emptyList(),
)
