package ai.oriveo.community.feature.notes

import android.content.ClipboardManager
import android.content.Context
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.platform.LocalTextToolbar
import androidx.compose.ui.platform.TextToolbar
import androidx.compose.ui.platform.TextToolbarStatus
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import ai.oriveo.community.core.model.Note
import ai.oriveo.community.ui.theme.OriveoTheme
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * After a long note body is split into several LazyColumn items by blocks, a selection must still span chunks (one SelectionContainer for the page).
 * Robolectric cannot drive Compose text-selection gestures (a plain SelectionContainer control shows no toolbar either), so this runs on a device / emulator.
 */
@RunWith(AndroidJUnit4::class)
class NoteDetailCrossChunkSelectionTest {
    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()

    private class CopyingToolbar : TextToolbar {
        @Volatile var copy: (() -> Unit)? = null
        override val status: TextToolbarStatus
            get() = if (copy != null) TextToolbarStatus.Shown else TextToolbarStatus.Hidden

        override fun showMenu(
            rect: Rect,
            onCopyRequested: (() -> Unit)?,
            onPasteRequested: (() -> Unit)?,
            onCutRequested: (() -> Unit)?,
            onSelectAllRequested: (() -> Unit)?,
        ) {
            copy = onCopyRequested
        }

        override fun hide() {}
    }

    // Each section has 4 blocks (heading / paragraph / code / table) and each chunk 8 blocks: marker0 and marker1 are in chunk 0, marker2 in chunk 1.
    private fun body(sections: Int) = buildString {
        repeat(sections) { i ->
            append("## Heading $i\n\n")
            append("Paragraph marker$i with words to select.\n\n")
            append("```kotlin\nval x = $i\n```\n\n")
            append("| a | b |\n|---|---|\n| $i | ${i + 1} |\n\n")
        }
    }

    private fun show(toolbar: TextToolbar) {
        compose.setContent {
            OriveoTheme {
                CompositionLocalProvider(LocalTextToolbar provides toolbar) {
                    NoteDetailBody(
                        note = Note(
                            id = "N1",
                            title = "Long note",
                            body = body(60),
                            createdAt = "2026-10-28T00:00:00Z",
                            updatedAt = "2026-10-28T00:00:00Z",
                        ),
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
        }
        compose.waitForIdle()
    }

    private fun dragSelectAndCopy(fromText: String, toText: String): String {
        val toolbar = CopyingToolbar()
        show(toolbar)
        val from = compose.onNodeWithText(fromText, substring = true).fetchSemanticsNode().boundsInRoot
        val to = compose.onNodeWithText(toText, substring = true).fetchSemanticsNode().boundsInRoot
        compose.onRoot().performTouchInput {
            val start = Offset(from.left + 6f, from.center.y)
            val end = Offset(to.right - 6f, to.center.y)
            down(start)
            advanceEventTime(viewConfiguration.longPressTimeoutMillis + 300)
            repeat(30) { step -> moveTo(start + (end - start) * ((step + 1) / 30f)); advanceEventTime(16) }
            up()
        }
        compose.waitForIdle()
        val copy = toolbar.copy
        assertTrue("selection toolbar never showed for $fromText → $toText", copy != null)
        compose.runOnUiThread { copy!!.invoke() }
        compose.waitForIdle()
        val clipboard = InstrumentationRegistry.getInstrumentation().targetContext
            .getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        var text = ""
        compose.runOnUiThread { text = clipboard.primaryClip?.getItemAt(0)?.text?.toString().orEmpty() }
        return text
    }

    @Test
    fun selectionWithinOneChunk() {
        val copied = dragSelectAndCopy("Paragraph marker0", "Paragraph marker1")
        assertTrue(copied, copied.contains("marker0") && copied.contains("marker1"))
    }

    @Test
    fun selectionAcrossTwoChunks() {
        val copied = dragSelectAndCopy("Paragraph marker1", "Paragraph marker2")
        // marker2 must really be in the second chunk (so the case does not degrade to same-chunk if the chunk size changes).
        val secondChunkTop = compose.onNodeWithTag(noteContentChunkKey(1)).fetchSemanticsNode().boundsInRoot.top
        val marker2Top = compose.onNodeWithText("Paragraph marker2", substring = true).fetchSemanticsNode().boundsInRoot.top
        assertTrue("marker2 not in chunk 1", marker2Top >= secondChunkTop)
        assertTrue(copied, copied.contains("marker1") && copied.contains("marker2"))
    }
}
