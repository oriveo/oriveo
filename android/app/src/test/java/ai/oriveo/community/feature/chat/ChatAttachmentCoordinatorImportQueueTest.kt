package ai.oriveo.community.feature.chat

import android.content.Context
import android.net.Uri
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.feature.chat.attachments.AttachmentImportOutcome
import ai.oriveo.community.feature.chat.attachments.AttachmentProcessor
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * A multi-select import has to queue.
 *
 * The picker starts one coroutine per URI. Unqueued, N files are read into the heap in full and
 * parsed at the same time, which can fill the heap within seconds; the count limit also stops
 * working because every coroutine sees zero attachments already present.
 */
class ChatAttachmentCoordinatorImportQueueTest {

    @Test
    fun `files picked together are imported one at a time and each sees the ones before it`() = runTest {
        val pending = mutableListOf<Attachment>()
        var inFlight = 0
        var peakInFlight = 0
        val seenCounts = mutableListOf<Int>()
        val processor = mockk<AttachmentProcessor>()
        coEvery { processor.processFile(any(), any(), any(), any(), any()) } coAnswers {
            inFlight += 1
            peakInFlight = maxOf(peakInFlight, inFlight)
            seenCounts += arg<Int>(4)
            // The first is the slowest: unqueued, later ones would finish first, which would show
            // up in both the order and the concurrency count.
            delay(if (seenCounts.size == 1) 300 else 10)
            inFlight -= 1
            AttachmentImportOutcome.Success(fileAttachment(arg<Uri>(1).toString()), "file")
        }
        val coordinator = coordinator(processor, pending)
        val context = mockk<Context>()

        listOf("a.pdf", "b.pdf", "c.pdf", "d.pdf").forEach { name ->
            launch { coordinator.processFile(context, uriNamed(name)) }
        }
        advanceUntilIdle()

        assertEquals(1, peakInFlight)
        assertEquals(listOf(0, 1, 2, 3), seenCounts)
        assertEquals(listOf("a.pdf", "b.pdf", "c.pdf", "d.pdf"), pending.map { it.fileName })
    }

    @Test
    fun `an image import waits for the file import in front of it`() = runTest {
        val pending = mutableListOf<Attachment>()
        var inFlight = 0
        var peakInFlight = 0
        val processor = mockk<AttachmentProcessor>()
        coEvery { processor.processFile(any(), any(), any(), any(), any()) } coAnswers {
            inFlight += 1
            peakInFlight = maxOf(peakInFlight, inFlight)
            delay(200)
            inFlight -= 1
            AttachmentImportOutcome.Silent
        }
        coEvery { processor.processImage(any(), any()) } coAnswers {
            inFlight += 1
            peakInFlight = maxOf(peakInFlight, inFlight)
            delay(10)
            inFlight -= 1
            AttachmentImportOutcome.Silent
        }
        val coordinator = coordinator(processor, pending)
        val context = mockk<Context>()

        launch { coordinator.processFile(context, uriNamed("big.pdf")) }
        launch { coordinator.processImage(context, uriNamed("photo.jpg")) }
        advanceUntilIdle()

        assertEquals(1, peakInFlight)
    }

    private fun coordinator(
        processor: AttachmentProcessor,
        pending: MutableList<Attachment>,
    ) = ChatAttachmentCoordinator(
        attachmentProcessor = processor,
        globalSnackbarManager = GlobalSnackbarManager(),
        activeProviderKind = { null },
        activeModel = { null },
        pendingAttachments = { pending.toList() },
        addAttachment = { attachment, _ -> pending += attachment },
        presentAttachmentSizeLimitDialog = {},
    )

    private fun uriNamed(name: String): Uri = mockk { every { this@mockk.toString() } returns name }

    private fun fileAttachment(name: String) = Attachment(
        id = name,
        kind = AttachmentKind.File,
        fileName = name,
        mimeType = "application/pdf",
    )
}
