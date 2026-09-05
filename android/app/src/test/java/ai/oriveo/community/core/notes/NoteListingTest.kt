package ai.oriveo.community.core.notes

import ai.oriveo.community.core.model.Note
import ai.oriveo.community.core.model.ProviderKind
import org.junit.Assert.assertEquals
import org.junit.Test

class NoteListingTest {

    private fun note(
        id: String,
        title: String = id,
        tags: List<String> = emptyList(),
        folder: String? = null,
        updatedAt: String = "2026-06-01T00:00:00Z",
        createdAt: String = "2026-06-01T00:00:00Z",
        pinned: Boolean = false,
        provider: ProviderKind? = null,
        deletedAt: String? = null,
    ) = Note(
        id = id,
        title = title,
        body = "b",
        tags = tags,
        noteFolderID = folder,
        isPinned = pinned,
        sourceProviderKind = provider,
        createdAt = createdAt,
        updatedAt = updatedAt,
        deletedAt = deletedAt,
    )

    @Test
    fun `pinned always sorts before unpinned`() {
        val notes = listOf(
            note("old-unpinned", updatedAt = "2026-06-10T00:00:00Z"),
            note("pinned", updatedAt = "2026-01-01T00:00:00Z", pinned = true),
        )
        val sorted = NoteListing.filterAndSort(notes, sort = NoteSort.UpdatedAt)
        assertEquals("pinned", sorted[0].id)
    }

    @Test
    fun `updatedAt sort is descending`() {
        val notes = listOf(
            note("a", updatedAt = "2026-06-01T00:00:00Z"),
            note("b", updatedAt = "2026-06-05T00:00:00Z"),
        )
        assertEquals(listOf("b", "a"), NoteListing.filterAndSort(notes, sort = NoteSort.UpdatedAt).map { it.id })
    }

    @Test
    fun `folder filter restricts results`() {
        val notes = listOf(
            note("in", folder = "33333333-3333-3333-8333-333333333333"),
            note("out", folder = null),
        )
        val r = NoteListing.filterAndSort(notes, folderId = "33333333-3333-3333-8333-333333333333")
        assertEquals(listOf("in"), r.map { it.id })
    }

    @Test
    fun `tag filter is AND`() {
        val notes = listOf(
            note("both", tags = listOf("x", "y")),
            note("one", tags = listOf("x")),
        )
        assertEquals(listOf("both"), NoteListing.filterAndSort(notes, tags = listOf("x", "y")).map { it.id })
    }

    @Test
    fun `deleted notes excluded`() {
        val notes = listOf(note("a"), note("dead", deletedAt = "2026-06-02T00:00:00Z"))
        assertEquals(listOf("a"), NoteListing.filterAndSort(notes).map { it.id })
    }

    @Test
    fun `provider sort ascending by kind then updated desc`() {
        val notes = listOf(
            note("anthropic", provider = ProviderKind.Anthropic, updatedAt = "2026-06-01T00:00:00Z"),
            note("openai", provider = ProviderKind.OpenAI, updatedAt = "2026-06-09T00:00:00Z"),
        )
        // rawValue: "anthropic" < "openAI" -> anthropic first
        assertEquals(
            listOf("anthropic", "openai"),
            NoteListing.filterAndSort(notes, sort = NoteSort.SourceProviderKind).map { it.id },
        )
    }

    @Test
    fun `availableTags dedup sorts alphabetically case-insensitive and caps`() {
        val notes = listOf(
            note("a", tags = listOf("Zebra", "alpha")),
            note("b", tags = listOf("alpha", "mango")),
            note("dead", tags = listOf("ghost"), deletedAt = "2026-06-02T00:00:00Z"),
        )
        
        assertEquals(listOf("alpha", "mango", "Zebra"), NoteListing.availableTags(notes, folderId = null))
    }

    @Test
    fun `availableTags restricted to selected folder`() {
        val folder = "33333333-3333-3333-8333-333333333333"
        val notes = listOf(
            note("in", tags = listOf("kept"), folder = folder),
            note("out", tags = listOf("dropped"), folder = null),
        )
        assertEquals(listOf("kept"), NoteListing.availableTags(notes, folderId = folder))
    }

    @Test
    fun `availableTags respects max cap`() {
        val notes = listOf(note("a", tags = (1..20).map { "t%02d".format(it) }))
        assertEquals(12, NoteListing.availableTags(notes, folderId = null, max = 12).size)
    }

    @Test
    fun `tagSuggestions exclude current note tags case-insensitively and preserve existing spelling`() {
        val notes = listOf(
            note("current", tags = listOf("Vector", "android")),
            note("other", tags = listOf("vector", "compose", "Research")),
            note("third", tags = listOf("research", "ux")),
        )
        assertEquals(
            listOf("compose", "Research", "ux"),
            NoteListing.tagSuggestions(notes, excluding = listOf("Vector", "android")),
        )
    }
}
