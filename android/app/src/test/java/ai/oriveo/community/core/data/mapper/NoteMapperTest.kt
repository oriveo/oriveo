package ai.oriveo.community.core.data.mapper

import ai.oriveo.community.core.data.entity.NoteEntity
import ai.oriveo.community.core.data.mapper.NoteMapper.toDomain
import ai.oriveo.community.core.data.mapper.NoteMapper.toEntity
import ai.oriveo.community.core.model.Note
import ai.oriveo.community.core.model.NoteCaptureKind
import ai.oriveo.community.core.model.NoteTitleSource
import ai.oriveo.community.core.model.ProvenanceEntry
import ai.oriveo.community.core.model.ProvenanceKind
import ai.oriveo.community.core.model.ProviderKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NoteMapperTest {

    @Test
    fun `domain to entity to domain roundtrip preserves fields`() {
        val note = Note(
            id = "AAAAAAAA-AAAA-AAAA-8AAA-AAAAAAAAAAAA",
            title = "Title",
            titleSource = NoteTitleSource.Manual,
            body = "body",
            bodySnapshot = "snap",
            userNote = "mine",
            tags = listOf("x", "y"),
            sourceProviderKind = ProviderKind.OpenAI,
            captureKind = NoteCaptureKind.FullAnswer,
            provenance = listOf(
                ProvenanceEntry(kind = ProvenanceKind.Origin, modelName = "GPT-5", at = "2026-06-01T00:00:00Z"),
                ProvenanceEntry(kind = ProvenanceKind.Crosscheck, modelName = "Claude", at = "2026-06-02T00:00:00Z"),
            ),
            isPinned = true,
            createdAt = "2026-06-01T00:00:00Z",
            updatedAt = "2026-06-02T00:00:00Z",
        )
        val back = note.toEntity("acct").toDomain()
        assertEquals(note.tags, back.tags)
        assertEquals(2, back.provenance.size)
        assertEquals(ProvenanceKind.Crosscheck, back.provenance[1].kind)
        assertEquals(NoteTitleSource.Manual, back.titleSource)
        assertEquals(NoteCaptureKind.FullAnswer, back.captureKind)
        assertEquals(ProviderKind.OpenAI, back.sourceProviderKind)
        assertTrue(back.isPinned)
    }

    @Test
    fun `id normalized to uppercase on write`() {
        val note = Note(
            id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", // valid v4 UUID
            title = "t", body = "b",
            createdAt = "2026-06-01T00:00:00Z", updatedAt = "2026-06-01T00:00:00Z",
        )
        assertEquals("AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", note.toEntity().id)
    }

    @Test
    fun `unknown enum strings downgrade safely`() {
        val entity = NoteEntity(
            id = "AAAAAAAA-AAAA-AAAA-8AAA-AAAAAAAAAAAA",
            title = "t",
            titleSource = "??unknown",
            body = "b",
            tagsJson = "[]",
            captureKind = "??unknown",
            createdAt = "2026-06-01T00:00:00Z",
            updatedAt = "2026-06-01T00:00:00Z",
        )
        val domain = entity.toDomain()
        assertEquals(NoteTitleSource.Placeholder, domain.titleSource)
        assertEquals(NoteCaptureKind.Blank, domain.captureKind)
    }

    @Test
    fun `corrupt tags json falls back to empty`() {
        val entity = NoteEntity(
            id = "AAAAAAAA-AAAA-AAAA-8AAA-AAAAAAAAAAAA",
            title = "t", titleSource = "manual", body = "b",
            tagsJson = "{not valid", captureKind = "blank",
            createdAt = "2026-06-01T00:00:00Z", updatedAt = "2026-06-01T00:00:00Z",
        )
        assertTrue(entity.toDomain().tags.isEmpty())
    }

    @Test
    fun `empty provenance maps to null json`() {
        val note = Note(
            id = "AAAAAAAA-AAAA-AAAA-8AAA-AAAAAAAAAAAA",
            title = "t", body = "b",
            createdAt = "2026-06-01T00:00:00Z", updatedAt = "2026-06-01T00:00:00Z",
        )
        assertEquals(null, note.toEntity().provenanceJson)
    }
}
