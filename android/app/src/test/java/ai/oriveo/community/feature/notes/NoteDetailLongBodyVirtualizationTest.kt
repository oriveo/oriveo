package ai.oriveo.community.feature.notes

import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.unit.dp
import ai.oriveo.community.core.model.Note
import ai.oriveo.community.ui.component.markdown.MARKDOWN_BLOCKS_PER_CHUNK
import ai.oriveo.community.ui.component.markdown.markdownBlockChunks
import ai.oriveo.community.ui.theme.OriveoTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.File

/**
 * Note detail used to put the whole body into a non-lazy Column, composing and measuring every block in the first frame,
 * so the cost grew linearly with length (Robolectric: about 25ms for 19 lines, 1s for 1801 lines, 2-2.6s for 28.8k lines).
 * With a page-level LazyColumn and the body split into block chunks, the body composed in the first frame no longer depends on note length.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "w390dp-h844dp-xxhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class NoteDetailLongBodyVirtualizationTest {
    @get:Rule
    val composeRule = createEmptyComposeRule()

    private fun body(sections: Int) = buildString {
        repeat(sections) { i ->
            append("## Heading $i\n\n")
            append("Paragraph marker$i with **bold** and `code`.\n\n")
            append("```kotlin\nval x = $i\n```\n\n")
            append("| a | b |\n|---|---|\n| $i | ${i + 1} |\n\n")
        }
    }

    private fun note(body: String) = Note(
        id = "N1",
        title = "Long note",
        body = body,
        createdAt = "2026-10-28T00:00:00Z",
        updatedAt = "2026-10-28T00:00:00Z",
    )

    /** Number of body paragraphs composed in the first frame (one "Paragraph markerN" per section). */
    private fun composedParagraphs(sections: Int, keep: Boolean = false): Int {
        val controller = Robolectric.buildActivity(ComponentActivity::class.java).setup()
        val activity = controller.get()
        val bean = java.lang.management.ManagementFactory.getThreadMXBean()
        val cpu0 = bean.currentThreadCpuTime
        activity.setContent {
            OriveoTheme {
                NoteDetailBody(
                    note = note(body(sections)),
                    folderName = null,
                    availableTags = emptyList(),
                    screenH = 16.dp,
                    contentPadding = PaddingValues(0.dp),
                    onUpdateTitle = {},
                    onUpdateBody = {},
                    onAddTag = {},
                    onRemoveTag = {},
                    onReturnToConversation = {},
                    onCrosscheck = {},
                    onDeleteClick = {},
                    onRestore = {},
                )
            }
        }
        composeRule.waitForIdle()
        println("NOTE_DETAIL_FIRST_FRAME sections=$sections cpu_ms=${(bean.currentThreadCpuTime - cpu0) / 1_000_000}")
        val count = composeRule.onAllNodesWithText("Paragraph marker", substring = true).fetchSemanticsNodes().size
        if (!keep) {
            controller.pause().stop().destroy()
            composeRule.waitForIdle()
        }
        return count
    }

    @Test
    fun `chunks cover every block in order with a bounded size`() {
        val text = body(50)
        val chunks = markdownBlockChunks(text)
        assertTrue(chunks.size > 1)
        assertEquals(0, chunks.first().first)
        chunks.zipWithNext().forEach { (a, b) -> assertEquals(a.last + 1, b.first) }
        assertTrue(chunks.all { it.count() in 1..MARKDOWN_BLOCKS_PER_CHUNK })
        assertEquals(listOf(0 until 2), markdownBlockChunks("# Title\n\nShort note."))
        assertEquals(emptyList<IntRange>(), markdownBlockChunks("   "))
    }

    @Test
    fun `card span follows the first and last chunk and overscans the hidden ends`() {
        // First and last chunk both visible: card = top of first .. bottom of last.
        assertEquals(
            LongNoteCardSpan(top = 300, bottom = 1500),
            longNoteCardSpan(
                visible = listOf(
                    Triple("source", 0, 300),
                    Triple(noteContentChunkKey(0), 300, 900),
                    Triple(noteContentChunkKey(1), 900, 1500),
                    Triple("danger", 1500, 1600),
                ),
                chunkCount = 2, viewportHeight = 2000, overscanPx = 200,
            ),
        )
        // Only middle chunks visible: both ends extend beyond the viewport so corners and shadow stay off screen.
        assertEquals(
            LongNoteCardSpan(top = -200, bottom = 2200),
            longNoteCardSpan(
                visible = listOf(Triple(noteContentChunkKey(5), -100, 900), Triple(noteContentChunkKey(6), 900, 2100)),
                chunkCount = 10, viewportHeight = 2000, overscanPx = 200,
            ),
        )
        // No body chunk visible: draw nothing.
        assertEquals(null, longNoteCardSpan(listOf(Triple("danger", 0, 100)), chunkCount = 3, viewportHeight = 2000, overscanPx = 200))
    }

    @Test
    fun `long note draws its card once under the list and makes the body selectable across chunks`() {
        composedParagraphs(sections = 300, keep = true)
        // The card look is a single layer (the same brandImmersiveCard), top-aligned with the first chunk.
        val underlays = composeRule.onAllNodesWithTag(LONG_NOTE_CARD_UNDERLAY_TAG).fetchSemanticsNodes()
        assertEquals(1, underlays.size)
        val firstChunk = composeRule.onNodeWithTag(noteContentChunkKey(0)).fetchSemanticsNode()
        assertEquals(firstChunk.boundsInRoot.top, underlays.single().boundsInRoot.top, 0.5f)
        assertEquals(firstChunk.boundsInRoot.left, underlays.single().boundsInRoot.left, 0.5f)

        val source = File("src/main/java/ai/oriveo/community/feature/notes/NoteDetailScreen.kt").readText()
        val chunkItems = source.substringAfter("itemsIndexed(chunks").substringBefore("\n    if (editable && state.selected == 0)")
        // Chunks draw no card look and wrap no selection: selection comes from NoteBodySelection wrapping the whole LazyColumn.
        assertFalse(chunkItems.contains("brandImmersiveCard"))
        assertFalse(chunkItems.contains(".shadow("))
        assertTrue(chunkItems.contains("selectable = false"))
        val body = source.substringAfter("internal fun NoteDetailBody(").substringBefore("/** Page-level section header")
        assertTrue(body.indexOf("NoteBodySelection(enabled = chunked)") in 0 until body.indexOf("LazyColumn("))
    }

    @Test
    fun `first frame composes a bounded slice of a long note regardless of its length`() {
        val short = composedParagraphs(sections = 3)
        val long = composedParagraphs(sections = 300)
        val veryLong = composedParagraphs(sections = 1500)
        // A short note is fully visible.
        assertEquals(3, short)
        // A long note composes only a few chunks near the viewport: a constant cap independent of length, equal for 300 and 1500 sections.
        assertTrue("composed=$long", long in 1..12)
        assertEquals(long, veryLong)
    }

}
