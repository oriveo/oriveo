package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.model.Note
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatSavedNoteLinksTest {

    @Test
    fun `groups active note links by source message in the current conversation`() {
        val links = savedNoteLinksByMessage(
            conversationId = "conv-a",
            notes = listOf(
                note(id = "n1", title = "First", sourceConversationId = "conv-a", sourceMessageId = "m1", updatedAt = "2026-06-01T00:00:00Z"),
                note(id = "n2", title = "Second", sourceConversationId = "conv-a", sourceMessageId = "m1", updatedAt = "2026-06-02T00:00:00Z"),
                note(id = "n3", title = "Other message", sourceConversationId = "conv-a", sourceMessageId = "m2"),
                note(id = "n4", title = "Other conversation", sourceConversationId = "conv-b", sourceMessageId = "m1"),
                note(id = "n5", title = "Trashed", sourceConversationId = "conv-a", sourceMessageId = "m1", deletedAt = "2026-06-03T00:00:00Z"),
                note(id = "n6", title = "Missing source", sourceConversationId = "conv-a", sourceMessageId = null),
            ),
        )

        assertEquals(setOf("m1", "m2"), links.keys)
        assertEquals(listOf("n2", "n1"), links.getValue("m1").map { it.noteId })
        assertEquals("Second", links.getValue("m1").first().title)
        assertEquals(listOf("n3"), links.getValue("m2").map { it.noteId })
    }

    @Test
    fun `returns empty map when conversation is blank`() {
        assertTrue(savedNoteLinksByMessage("", listOf(note(id = "n1", sourceConversationId = "c", sourceMessageId = "m"))).isEmpty())
    }

    @Test
    fun `resolves selection replacement target from return note first then saved message links`() {
        val savedLinks = listOf(
            SavedNoteLink(noteId = "recent-note", title = "Recent"),
            SavedNoteLink(noteId = "older-note", title = "Older"),
        )

        assertEquals(
            "return-note",
            replacementNoteIdForSelection(returnToNoteId = "return-note", savedNoteLinks = savedLinks),
        )
        assertEquals(
            "recent-note",
            replacementNoteIdForSelection(returnToNoteId = null, savedNoteLinks = savedLinks),
        )
        assertEquals(
            null,
            replacementNoteIdForSelection(returnToNoteId = null, savedNoteLinks = emptyList()),
        )
    }

    @Test
    fun `finds saved links for raw or normalized message ids`() {
        val raw = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        val normalized = raw.uppercase()
        val links = mapOf(normalized to listOf(SavedNoteLink(noteId = "note-1", title = "Note")))

        assertEquals("note-1", savedNoteLinksForMessage(links, raw).single().noteId)
        assertEquals("note-1", savedNoteLinksForMessage(links, normalized).single().noteId)
    }

    private fun note(
        id: String,
        title: String = id,
        sourceConversationId: String? = null,
        sourceMessageId: String? = null,
        updatedAt: String = "2026-06-01T00:00:00Z",
        deletedAt: String? = null,
    ) = Note(
        id = id,
        title = title,
        body = "body",
        sourceConversationId = sourceConversationId,
        sourceMessageId = sourceMessageId,
        createdAt = "2026-06-01T00:00:00Z",
        updatedAt = updatedAt,
        deletedAt = deletedAt,
    )
}
