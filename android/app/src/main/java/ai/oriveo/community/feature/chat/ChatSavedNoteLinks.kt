package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.model.Note
import ai.oriveo.community.core.util.normalizeUuid

data class SavedNoteLink(
    val noteId: String,
    val title: String,
)

internal fun replacementNoteIdForSelection(
    returnToNoteId: String?,
    savedNoteLinks: List<SavedNoteLink>,
): String? = returnToNoteId?.takeIf { it.isNotBlank() } ?: savedNoteLinks.firstOrNull()?.noteId

internal fun savedNoteLinksForMessage(
    savedNoteLinksByMessage: Map<String, List<SavedNoteLink>>,
    messageId: String,
): List<SavedNoteLink> =
    savedNoteLinksByMessage[normalizeUuid(messageId)] ?: savedNoteLinksByMessage[messageId].orEmpty()

internal fun savedNoteLinksByMessage(
    conversationId: String?,
    notes: List<Note>,
): Map<String, List<SavedNoteLink>> {
    val normalizedConversationId = conversationId
        ?.takeIf { it.isNotBlank() }
        ?.let(::normalizeUuid)
        ?: return emptyMap()

    return notes
        .asSequence()
        .filter { !it.isTrashed }
        .filter { note -> note.sourceConversationId?.let(::normalizeUuid) == normalizedConversationId }
        .mapNotNull { note ->
            val messageId = note.sourceMessageId?.takeIf { it.isNotBlank() }?.let(::normalizeUuid)
                ?: return@mapNotNull null
            messageId to note
        }
        .groupBy(keySelector = { it.first }, valueTransform = { it.second })
        .mapValues { (_, groupedNotes) ->
            groupedNotes
                .sortedByDescending { it.updatedAt }
                .map { note -> SavedNoteLink(noteId = normalizeUuid(note.id), title = note.title) }
        }
}
