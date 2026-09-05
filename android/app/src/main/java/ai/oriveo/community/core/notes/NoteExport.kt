package ai.oriveo.community.core.notes

import ai.oriveo.community.core.model.Note
import ai.oriveo.community.core.model.NoteCaptureKind


object NoteExport {

    private val ILLEGAL_FILENAME = Regex("[/\\\\:*?\"<>|]+")
    private val NEWLINES = Regex("[\\r\\n]+")
    private val WHITESPACE = Regex("\\s+")
    private val DASHES = Regex("-+")
    private val TRIM_DASHES = Regex("^-+|-+$")

    private fun noteTitle(note: Note, untitled: String): String =
        note.title.trim().ifEmpty { untitled }

    private fun noteDate(note: Note): String = NoteTime.isoToDate(note.createdAt)

    private fun sourceLine(note: Note): String? {
        if (note.captureKind == NoteCaptureKind.Blank) return null
        val parts = listOfNotNull(
            note.sourceModelName?.takeIf { it.isNotEmpty() },
            note.sourceProviderName?.takeIf { it.isNotEmpty() },
            noteDate(note).takeIf { it.isNotEmpty() },
        )
        if (parts.isEmpty()) return null
        return "Source: ${parts.joinToString(" · ")}"
    }

    fun buildNoteMarkdown(note: Note, untitled: String): String {
        val sections = mutableListOf("# ${noteTitle(note, untitled)}")
        note.userNote?.trim()?.takeIf { it.isNotEmpty() }?.let { userNote ->
            sections.add(userNote.split("\n").joinToString("\n") { "> $it" })
        }
        if (note.tags.isNotEmpty()) sections.add("Tags: ${note.tags.joinToString(", ")}")
        note.body.trim().takeIf { it.isNotEmpty() }?.let { sections.add(it) }
        val sourceParts = listOfNotNull(
            sourceLine(note),
            note.sourcePrompt?.takeIf { it.isNotEmpty() }?.let { "Prompt: $it" },
        )
        if (sourceParts.isNotEmpty()) sections.add(sourceParts.joinToString("\n"))
        return sections.joinToString("\n\n") + "\n"
    }

    fun sanitizeNoteFilenamePart(value: String): String {
        val cleaned = value
            .replace(ILLEGAL_FILENAME, "-")
            .replace(NEWLINES, " ")
            .replace(WHITESPACE, " ")
            .replace(DASHES, "-")
            .trim()
            .replace(TRIM_DASHES, "")
        return cleaned.take(80)
    }

    fun buildNoteMarkdownFilename(note: Note, untitled: String): String {
        val title = sanitizeNoteFilenamePart(noteTitle(note, untitled)).ifEmpty { untitled }
        val date = noteDate(note)
        return if (date.isNotEmpty()) "$title-$date.md" else "$title.md"
    }
}
