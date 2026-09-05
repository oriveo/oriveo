package ai.oriveo.community.core.notes

import ai.oriveo.community.core.model.Note
import ai.oriveo.community.core.model.NoteCaptureKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NoteExportTest {

    private fun note(
        title: String = "My Title",
        body: String = "the body",
        userNote: String? = null,
        tags: List<String> = emptyList(),
        captureKind: NoteCaptureKind = NoteCaptureKind.FullAnswer,
        sourceModelName: String? = "GPT-5",
        sourceProviderName: String? = "OpenAI",
        sourcePrompt: String? = "the question",
        bodySnapshot: String? = "ORIGINAL SNAPSHOT",
    ) = Note(
        id = "11111111-1111-1111-8111-111111111111",
        title = title,
        body = body,
        userNote = userNote,
        tags = tags,
        captureKind = captureKind,
        sourceModelName = sourceModelName,
        sourceProviderName = sourceProviderName,
        sourcePrompt = sourcePrompt,
        bodySnapshot = bodySnapshot,
        createdAt = "2026-06-10T08:00:00Z",
        updatedAt = "2026-06-10T08:00:00Z",
    )

    @Test
    fun `markdown has expected field order and excludes snapshot`() {
        val md = NoteExport.buildNoteMarkdown(
            note(userNote = "why I saved it", tags = listOf("a", "b")),
            untitled = "Untitled",
        )
        assertTrue(md.startsWith("# My Title"))
        assertTrue(md.contains("> why I saved it"))
        assertTrue(md.contains("Tags: a, b"))
        assertTrue(md.contains("the body"))
        assertTrue(md.contains("Source: GPT-5 · OpenAI · 2026-06-10"))
        assertTrue(md.contains("Prompt: the question"))
        assertFalse(md.contains("ORIGINAL SNAPSHOT")) // bodySnapshot never exported
        assertTrue(md.endsWith("\n"))
    }

    @Test
    fun `blank capture omits source line`() {
        val md = NoteExport.buildNoteMarkdown(
            note(captureKind = NoteCaptureKind.Blank, sourcePrompt = null),
            untitled = "Untitled",
        )
        assertFalse(md.contains("Source:"))
    }

    @Test
    fun `empty title falls back to untitled`() {
        val md = NoteExport.buildNoteMarkdown(note(title = "  "), untitled = "Untitled note")
        assertTrue(md.startsWith("# Untitled note"))
    }

    @Test
    fun `filename sanitizes illegal chars and appends date`() {
        val name = NoteExport.buildNoteMarkdownFilename(note(title = "a/b:c*?\"<>|d"), untitled = "Untitled")
        assertFalse(name.contains("/"))
        assertFalse(name.contains(":"))
        assertTrue(name.endsWith("-2026-06-10.md"))
    }
}
