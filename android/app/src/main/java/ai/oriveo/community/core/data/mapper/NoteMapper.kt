package ai.oriveo.community.core.data.mapper

import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.entity.NoteEntity
import ai.oriveo.community.core.model.Note
import ai.oriveo.community.core.model.NoteCaptureKind
import ai.oriveo.community.core.model.NoteTitleSource
import ai.oriveo.community.core.model.ProvenanceEntry
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.util.normalizeUuid
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json


object NoteMapper {

    private val json = Json { ignoreUnknownKeys = true; coerceInputValues = true }

    fun NoteEntity.toDomain(): Note = Note(
        id = id,
        title = title,
        titleSource = NoteTitleSource.fromRawValue(titleSource),
        body = body,
        bodySnapshot = bodySnapshot,
        userNote = userNote,
        tags = runCatching { json.decodeFromString<List<String>>(tagsJson) }.getOrDefault(emptyList()),
        noteFolderID = noteFolderID,
        sourceConversationId = sourceConversationId,
        sourceMessageId = sourceMessageId,
        sourceModelID = sourceModelID,
        sourceModelName = sourceModelName,
        sourceProviderKind = sourceProviderKind?.let { ProviderKind.fromRawValue(it) },
        sourceProviderName = sourceProviderName,
        sourcePrompt = sourcePrompt,
        captureKind = NoteCaptureKind.fromRawValue(captureKind),
        provenance = provenanceJson?.let {
            runCatching { json.decodeFromString<List<ProvenanceEntry>>(it) }.getOrDefault(emptyList())
        } ?: emptyList(),
        isPinned = isPinned,
        createdAt = createdAt,
        updatedAt = updatedAt,
        deletedAt = deletedAt,
    )

    fun Note.toEntity(accountId: String = LOCAL_PARTITION_ID): NoteEntity = NoteEntity(
        id = normalizeUuid(id),
        title = title,
        titleSource = titleSource.rawValue,
        body = body,
        bodySnapshot = bodySnapshot,
        userNote = userNote,
        tagsJson = json.encodeToString(tags),
        noteFolderID = noteFolderID?.let(::normalizeUuid),
        sourceConversationId = sourceConversationId?.let(::normalizeUuid),
        sourceMessageId = sourceMessageId?.let(::normalizeUuid),
        sourceModelID = sourceModelID,
        sourceModelName = sourceModelName,
        sourceProviderKind = sourceProviderKind?.rawValue,
        sourceProviderName = sourceProviderName,
        sourcePrompt = sourcePrompt,
        captureKind = captureKind.rawValue,
        provenanceJson = provenance.takeIf { it.isNotEmpty() }?.let { json.encodeToString(it) },
        isPinned = isPinned,
        createdAt = createdAt,
        updatedAt = updatedAt,
        deletedAt = deletedAt,
        accountId = accountId,
    )

    
    fun ftsTitle(note: Note): String = note.title
    fun ftsBody(note: Note): String = note.body
    fun ftsUserNote(note: Note): String = note.userNote.orEmpty()
    fun ftsTagsText(note: Note): String = note.tags.joinToString(" ")
}
