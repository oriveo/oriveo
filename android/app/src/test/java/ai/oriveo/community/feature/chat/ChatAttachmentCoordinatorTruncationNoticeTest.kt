package ai.oriveo.community.feature.chat

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import ai.oriveo.community.R
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.attachments.FileExtractionLimits
import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.feature.chat.attachments.AttachmentProcessor
import kotlinx.coroutines.launch
import io.mockk.every
import io.mockk.mockk
import java.io.ByteArrayInputStream
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * When only the head of a long text attachment is added, the user is told on the spot how many lines were added and how many the original has.
 *
 * Import goes through the real [AttachmentProcessor] and extractor, so the line counts in the notice come from their actual output.
 */
@RunWith(RobolectricTestRunner::class)
class ChatAttachmentCoordinatorTruncationNoticeTest {

    @Test
    fun `a text file over the line limit is added marked truncated and announced`() = runTest {
        val maxLines = FileExtractionLimits.DEFAULT.maxLines
        val import = importText((1..maxLines + 100).joinToString("\n") { "L$it" })

        val added = import.added.single()
        assertEquals(true, added.extractedTruncated)
        assertEquals(maxLines + 100, added.extractedTotalLines)
        val notice = import.shown as UiText.Resource
        assertEquals(R.string.file_extraction_truncated_notice, notice.resId)
        assertEquals(listOf<Any>("notes.txt", maxLines, maxLines + 100), notice.args)
    }

    @Test
    fun `a file that fits is added without any notice`() = runTest {
        val import = importText("one\ntwo")

        assertEquals(false, import.added.single().extractedTruncated)
        assertNull(import.shown)
    }

    @Test
    fun `a truncated file the composer refuses is not announced as added`() = runTest {
        val maxLines = FileExtractionLimits.DEFAULT.maxLines
        val import = importText((1..maxLines + 1).joinToString("\n") { "L$it" }, composerAccepts = false)

        assertTrue(import.added.isEmpty())
        assertNull(import.shown)
    }

    /** Several files picked at once: the truncation notices merge into one multi-line notice instead of each replacing the previous one. */
    @Test
    fun `truncation notices from one batch of files are shown as a single multi-line notice`() = runTest {
        val maxLines = FileExtractionLimits.DEFAULT.maxLines
        val long = (1..maxLines + 5).joinToString("\n") { "L$it" }
        val shown = mutableListOf<UiText>()
        val (coordinator, context, snackbars) = coordinator(mapOf("a.txt" to long, "b.txt" to "short", "c.txt" to long))
        val collector = launch { snackbars.active.collect { it?.message?.message?.let(shown::add) } }

        // Like the picker callback: each file starts its own coroutine, and all of them queue up on the same tick.
        val jobs = listOf("a.txt", "b.txt", "c.txt").map { name ->
            launch { coordinator.processFile(context, Uri.parse("content://com.example.docs/$name")) }
        }
        jobs.forEach { it.join() }
        testScheduler.advanceUntilIdle()
        collector.cancel()

        assertEquals(
            listOf<UiText>(
                UiText.Lines(
                    listOf(
                        UiText.Resource(R.string.file_extraction_truncated_notice, listOf("a.txt", maxLines, maxLines + 5)),
                        UiText.Resource(R.string.file_extraction_truncated_notice, listOf("c.txt", maxLines, maxLines + 5)),
                    ),
                ),
            ),
            shown.distinct(),
        )
    }

    private fun coordinator(files: Map<String, String>): Triple<ChatAttachmentCoordinator, Context, GlobalSnackbarManager> {
        val processor = AttachmentProcessor(
            attachmentStore = mockk<AttachmentStore>(relaxed = true),
        )
        val resolver = mockk<ContentResolver> {
            every { query(any(), any(), any(), any(), any()) } returns null
            every { getType(any()) } returns "text/plain"
            every { openInputStream(any()) } answers {
                ByteArrayInputStream(files.getValue(firstArg<Uri>().lastPathSegment!!).toByteArray())
            }
        }
        val pending = mutableListOf<Attachment>()
        val snackbars = GlobalSnackbarManager()
        val coordinator = ChatAttachmentCoordinator(
            attachmentProcessor = processor,
            globalSnackbarManager = snackbars,
            activeProviderKind = { null },
            activeModel = { null },
            pendingAttachments = { pending },
            addAttachment = { attachment, _ -> pending += attachment },
            presentAttachmentSizeLimitDialog = {},
        )
        return Triple(coordinator, mockk<Context> { every { contentResolver } returns resolver }, snackbars)
    }

    private class Import(val added: List<Attachment>, val shown: UiText?)

    private suspend fun importText(text: String, composerAccepts: Boolean = true): Import {
        val processor = AttachmentProcessor(
            attachmentStore = mockk<AttachmentStore>(relaxed = true),
        )
        // query returns null -> the file name falls back to lastPathSegment and the size is unknown, which reaches the read branch.
        val resolver = mockk<ContentResolver> {
            every { query(any(), any(), any(), any(), any()) } returns null
            every { getType(any()) } returns "text/plain"
            every { openInputStream(any()) } returns ByteArrayInputStream(text.toByteArray())
        }
        val pending = mutableListOf<Attachment>()
        val snackbars = GlobalSnackbarManager()
        val coordinator = ChatAttachmentCoordinator(
            attachmentProcessor = processor,
            globalSnackbarManager = snackbars,
            activeProviderKind = { null },
            activeModel = { null },
            pendingAttachments = { pending },
            addAttachment = { attachment, _ -> if (composerAccepts) pending += attachment },
            presentAttachmentSizeLimitDialog = {},
        )

        coordinator.processFile(
            mockk<Context> { every { contentResolver } returns resolver },
            Uri.parse("content://com.example.docs/notes.txt"),
        )

        return Import(pending.toList(), snackbars.active.value?.message?.message)
    }
}
