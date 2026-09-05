package ai.oriveo.community.feature.chat.attachments

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import ai.oriveo.community.core.attachments.ExtractionErrorCode
import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.model.ProviderKind
import io.mockk.every
import io.mockk.mockk
import java.io.InputStream
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner


@RunWith(RobolectricTestRunner::class)
class AttachmentProcessorImportGuardTest {

    @Test
    fun `file import surfaces an error instead of crashing when the read runs out of memory`() = runTest {
        val processor = AttachmentProcessor(
            attachmentStore = mockk<AttachmentStore>(relaxed = true),
        )

        val outcome = processor.processFile(
            context = contextReading { throw OutOfMemoryError("Failed to allocate") },
            uri = Uri.parse("content://com.example.docs/notes.txt"),
            activeProviderKind = null,
            activeModel = null,
            currentFileCount = 0,
        )

        val error = outcome as AttachmentImportOutcome.FileExtractionError
        assertEquals(ExtractionErrorCode.ExtractionError, error.code)
        assertEquals("notes.txt", error.fileName)
    }

    @Test
    fun `image import stays silent instead of crashing when the read runs out of memory`() = runTest {
        val processor = AttachmentProcessor(
            attachmentStore = mockk<AttachmentStore>(relaxed = true),
        )

        val outcome = processor.processImage(
            context = contextReading { throw OutOfMemoryError("Failed to allocate") },
            uri = Uri.parse("content://com.example.docs/photo.jpg"),
        )

        assertTrue(outcome is AttachmentImportOutcome.Silent)
    }

    @Test
    fun `unsupported video is rejected without ever opening the stream`() = runTest {
        val processor = AttachmentProcessor(
            attachmentStore = mockk<AttachmentStore>(relaxed = true),
        )
        val context = contextRefusingToOpen()

        val outcome = processor.processFile(
            context = context,
            uri = Uri.parse("content://com.example.docs/clip.mp4"),
            activeProviderKind = ProviderKind.OpenAI,
            activeModel = null,
            currentFileCount = 0,
        )

        assertTrue(outcome is AttachmentImportOutcome.AttachmentConflict)
    }

    @Test
    fun `unsupported extension is rejected without ever opening the stream`() = runTest {
        val processor = AttachmentProcessor(
            attachmentStore = mockk<AttachmentStore>(relaxed = true),
        )
        val context = contextRefusingToOpen()

        val outcome = processor.processFile(
            context = context,
            uri = Uri.parse("content://com.example.docs/archive.dmg"),
            activeProviderKind = ProviderKind.OpenAI,
            activeModel = null,
            currentFileCount = 0,
        )

        assertTrue(outcome is AttachmentImportOutcome.UnsupportedFile)
    }

    @Test
    fun `file picker mime list no longer offers video`() {
        assertTrue(AttachmentImportPolicy.pickerMimeTypes.none { it.startsWith("video/") })
        assertTrue(AttachmentImportPolicy.videoPickerMimeTypes.contains("video/*"))
    }

    
    private fun contextRefusingToOpen(): Context {
        val resolver = mockk<ContentResolver> {
            every { query(any(), any(), any(), any(), any()) } returns null
            every { getType(any()) } returns null
            every { openInputStream(any()) } answers {
                throw AssertionError("stream must not be opened for a file that is rejected on metadata alone")
            }
        }
        return mockk<Context> { every { contentResolver } returns resolver }
    }

    
    private fun contextReading(read: () -> Int): Context {
        val stream = object : InputStream() {
            override fun read(): Int = read()
            override fun read(b: ByteArray, off: Int, len: Int): Int = read()
        }
        val resolver = mockk<ContentResolver> {
            every { query(any(), any(), any(), any(), any()) } returns null
            every { getType(any()) } returns "text/plain"
            every { openInputStream(any()) } returns stream
        }
        return mockk<Context> { every { contentResolver } returns resolver }
    }
}
