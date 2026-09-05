package ai.oriveo.community.core.attachments

import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64


class AttachmentContentTransferTest {

    private fun b64(text: String): String = Base64.getEncoder().encodeToString(text.toByteArray())

    // ── Hydrator ─────────────────────────────────────────────

    @Test
    fun `hydrate image fills base64Data from localImageId`() = runTest {
        val attachment = Attachment(
            id = "a1",
            kind = AttachmentKind.Image,
            fileName = "photo.jpg",
            mimeType = "image/jpeg",
            localImageId = "local-1",
        )
        val result = AttachmentHydrator.hydrateOne(
            attachment,
            loadImageBase64 = { id -> if (id == "local-1") "IMG_BASE64" else null },
            loadBlobBase64 = { null },
        )
        assertEquals("IMG_BASE64", result.base64Data)
    }

    @Test
    fun `hydrate image is no-op when base64Data already present`() = runTest {
        val attachment = Attachment(
            id = "a1",
            kind = AttachmentKind.Image,
            fileName = "photo.jpg",
            mimeType = "image/jpeg",
            base64Data = "ALREADY_THERE",
            localImageId = "local-1",
        )
        val result = AttachmentHydrator.hydrateOne(
            attachment,
            loadImageBase64 = { error("should not be called") },
            loadBlobBase64 = { null },
        )
        assertEquals("ALREADY_THERE", result.base64Data)
    }

    @Test
    fun `hydrate video fills base64Data from rawContentRef`() = runTest {
        val attachment = Attachment(
            id = "a2",
            kind = AttachmentKind.Video,
            fileName = "clip.mp4",
            mimeType = "video/mp4",
            rawContentRef = "blob-1",
        )
        val result = AttachmentHydrator.hydrateOne(
            attachment,
            loadImageBase64 = { null },
            loadBlobBase64 = { ref -> if (ref == "blob-1") "VIDEO_BASE64" else null },
        )
        assertEquals("VIDEO_BASE64", result.base64Data)
    }

    @Test
    fun `hydrate native file fills originalBase64Data without touching extracted text`() = runTest {
        val attachment = Attachment(
            id = "a3",
            kind = AttachmentKind.File,
            fileName = "doc.pdf",
            mimeType = "application/pdf",
            base64Data = b64("extracted text"),
            rawContentRef = "blob-2",
        )
        val result = AttachmentHydrator.hydrateOne(
            attachment,
            loadImageBase64 = { null },
            loadBlobBase64 = { ref -> if (ref == "blob-2") "RAW_PDF_BASE64" else null },
        )
        assertEquals(b64("extracted text"), result.base64Data)
        assertEquals("RAW_PDF_BASE64", result.originalBase64Data)
    }

    @Test
    fun `hydrate generic fallback file fills base64Data from rawContentRef`() = runTest {
        val attachment = Attachment(
            id = "a4",
            kind = AttachmentKind.File,
            fileName = "data.bin",
            mimeType = "text/plain",
            rawContentRef = "blob-3",
        )
        val result = AttachmentHydrator.hydrateOne(
            attachment,
            loadImageBase64 = { null },
            loadBlobBase64 = { ref -> if (ref == "blob-3") "RAW_FILE_BASE64" else null },
        )
        assertEquals("RAW_FILE_BASE64", result.base64Data)
        assertNull(result.originalBase64Data)
    }

    @Test
    fun `hydrate scanned pdf keeps explicit empty base64Data marker`() = runTest {
        
        
        val attachment = Attachment(
            id = "a5",
            kind = AttachmentKind.File,
            fileName = "scanned.pdf",
            mimeType = "application/pdf",
            base64Data = "",
            rawContentRef = "blob-4",
            extractionErrorCode = "scanned_pdf",
        )
        val result = AttachmentHydrator.hydrateOne(
            attachment,
            loadImageBase64 = { null },
            loadBlobBase64 = { "RAW_PDF_BASE64" },
        )
        assertEquals("", result.base64Data)
        assertEquals("RAW_PDF_BASE64", result.originalBase64Data)
    }

    @Test
    fun `hydrate is no-op without any reference`() = runTest {
        val attachment = Attachment(
            id = "a6",
            kind = AttachmentKind.File,
            fileName = "orphan.txt",
            mimeType = "text/plain",
        )
        val result = AttachmentHydrator.hydrateOne(
            attachment,
            loadImageBase64 = { error("should not be called") },
            loadBlobBase64 = { error("should not be called") },
        )
        assertEquals(attachment, result)
    }

    // ── Slimmer ──────────────────────────────────────────────

    @Test
    fun `slim image with existing localImageId only strips base64 without re-saving`() = runTest {
        var saveImageCalls = 0
        val attachment = Attachment(
            id = "b1",
            kind = AttachmentKind.Image,
            fileName = "photo.jpg",
            mimeType = "image/jpeg",
            base64Data = b64("fake-bytes"),
            localImageId = "existing-local-id",
        )
        val result = AttachmentSlimmer.slim(
            attachment,
            saveImage = { saveImageCalls++; "new-id" },
            saveBlob = { error("should not be called") },
        )
        assertNull(result.base64Data)
        assertEquals("existing-local-id", result.localImageId)
        assertEquals(0, saveImageCalls)
    }

    @Test
    fun `slim image without localImageId saves to store and assigns new id`() = runTest {
        val attachment = Attachment(
            id = "b2",
            kind = AttachmentKind.Image,
            fileName = "photo.jpg",
            mimeType = "image/jpeg",
            base64Data = b64("fake-bytes"),
        )
        val result = AttachmentSlimmer.slim(
            attachment,
            saveImage = { "generated-id" },
            saveBlob = { error("should not be called") },
        )
        assertNull(result.base64Data)
        assertEquals("generated-id", result.localImageId)
    }

    @Test
    fun `slim image with undecodable base64 strips content without crashing`() = runTest {
        val attachment = Attachment(
            id = "b3",
            kind = AttachmentKind.Image,
            fileName = "photo.jpg",
            mimeType = "image/jpeg",
            base64Data = "not valid base64!!!",
        )
        val result = AttachmentSlimmer.slim(
            attachment,
            saveImage = { error("should not be called") },
            saveBlob = { error("should not be called") },
        )
        assertNull(result.base64Data)
        assertNull(result.localImageId)
    }

    @Test
    fun `slim video moves base64Data to blob store`() = runTest {
        val attachment = Attachment(
            id = "b4",
            kind = AttachmentKind.Video,
            fileName = "clip.mp4",
            mimeType = "video/mp4",
            base64Data = b64("video-bytes"),
        )
        val result = AttachmentSlimmer.slim(
            attachment,
            saveImage = { error("should not be called") },
            saveBlob = { "video-blob-id" },
        )
        assertNull(result.base64Data)
        assertEquals("video-blob-id", result.rawContentRef)
    }

    @Test
    fun `slim file moves originalBase64Data but keeps small extracted text inline`() = runTest {
        val attachment = Attachment(
            id = "b5",
            kind = AttachmentKind.File,
            fileName = "doc.pdf",
            mimeType = "application/pdf",
            base64Data = b64("extracted text"),
            originalBase64Data = b64("raw pdf bytes"),
        )
        val result = AttachmentSlimmer.slim(
            attachment,
            saveImage = { error("should not be called") },
            saveBlob = { "pdf-blob-id" },
        )
        assertEquals(b64("extracted text"), result.base64Data)
        assertNull(result.originalBase64Data)
        assertEquals("pdf-blob-id", result.rawContentRef)
    }

    @Test
    fun `slim file moves oversized base64Data raw bytes to blob store`() = runTest {
        val bigContent = "x".repeat(AttachmentSlimmer.RAW_FILE_TEXT_THRESHOLD_CHARS + 1)
        val attachment = Attachment(
            id = "b6",
            kind = AttachmentKind.File,
            fileName = "generic.bin",
            mimeType = "text/plain",
            base64Data = b64(bigContent),
        )
        val result = AttachmentSlimmer.slim(
            attachment,
            saveImage = { error("should not be called") },
            saveBlob = { "generic-blob-id" },
        )
        assertNull(result.base64Data)
        assertEquals("generic-blob-id", result.rawContentRef)
    }

    @Test
    fun `slim file keeps small base64Data inline without touching blob store`() = runTest {
        val attachment = Attachment(
            id = "b7",
            kind = AttachmentKind.File,
            fileName = "small.txt",
            mimeType = "text/plain",
            base64Data = b64("tiny content"),
        )
        val result = AttachmentSlimmer.slim(
            attachment,
            saveImage = { error("should not be called") },
            saveBlob = { error("should not be called") },
        )
        assertEquals(b64("tiny content"), result.base64Data)
        assertNull(result.rawContentRef)
    }

    @Test
    fun `hydrate then slim roundtrip preserves image content reference`() = runTest {
        val store = mutableMapOf<String, String>()
        val original = Attachment(
            id = "c1",
            kind = AttachmentKind.Image,
            fileName = "photo.jpg",
            mimeType = "image/jpeg",
            localImageId = "loc-1",
        ).also { store["loc-1"] = b64("bytes") }

        val hydrated = AttachmentHydrator.hydrateOne(
            original,
            loadImageBase64 = { id -> store[id] },
            loadBlobBase64 = { null },
        )
        assertTrue(!hydrated.base64Data.isNullOrEmpty())

        
        val slimmed = AttachmentSlimmer.slim(
            hydrated,
            saveImage = { error("should not be called — localImageId already present") },
            saveBlob = { error("should not be called") },
        )
        assertNull(slimmed.base64Data)
        assertEquals("loc-1", slimmed.localImageId)
    }
}
