package ai.oriveo.community.core.notes

import org.junit.Assert.assertEquals
import org.junit.Test

class NoteTitleTest {

    @Test
    fun `strips heading markers`() {
        assertEquals("Hello world", NoteTitle.placeholderTitle("## Hello world\nbody"))
    }

    @Test
    fun `skips code fence and table separator lines`() {
        
        assertEquals("real title", NoteTitle.placeholderTitle("```\nreal title"))
        assertEquals("Header", NoteTitle.placeholderTitle("| --- | :--: |\nHeader"))
    }

    @Test
    fun `strips quote list and emphasis`() {
        assertEquals("note", NoteTitle.placeholderTitle("> *note*"))
        assertEquals("item", NoteTitle.placeholderTitle("- item"))
        assertEquals("step", NoteTitle.placeholderTitle("1. step"))
    }

    @Test
    fun `empty body yields empty title`() {
        assertEquals("", NoteTitle.placeholderTitle("\n\n   \n"))
    }

    @Test
    fun `truncates to 200 chars`() {
        val long = "a".repeat(500)
        assertEquals(200, NoteTitle.placeholderTitle(long).length)
    }

    @Test
    fun `source prompt takes priority over body`() {
        assertEquals("the question", NoteTitle.placeholderTitleFromSource("the question", "body first line"))
    }

    @Test
    fun `crosscheck title skips internal original answer heading`() {
        val body = "## Original answer\n\nOld answer\n\n## Cross-check (GPT-5)\n\nSecond opinion"
        assertEquals("Second opinion", NoteTitle.placeholderTitle(body))
    }

    @Test
    fun `falls back to body when prompt blank`() {
        assertEquals("body first line", NoteTitle.placeholderTitleFromSource(null, "body first line"))
        assertEquals("body first line", NoteTitle.placeholderTitleFromSource("   ", "body first line"))
    }
}
