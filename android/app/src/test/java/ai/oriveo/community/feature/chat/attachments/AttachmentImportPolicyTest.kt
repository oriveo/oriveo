package ai.oriveo.community.feature.chat.attachments

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AttachmentImportPolicyTest {

    @Test
    fun `known text extension falls back to text plain`() {
        assertEquals(
            "text/plain",
            AttachmentImportPolicy.resolveMimeType(
                fileName = "script.zsh",
                detectedMimeType = "application/octet-stream",
            ),
        )
    }

    /** Attachment extraction spec section 2: only look at the mime if the extension is unknown; any text-type mime is treated as plain text (fixture a.weird + text/x-whatever). */
    @Test
    fun `unknown extension falls back to a textual mime`() {
        assertTrue(
            AttachmentImportPolicy.isSupportedFile(
                fileName = "bundle.thirdparty",
                detectedMimeType = "text/x-whatever",
            ),
        )
        assertEquals("text/plain", AttachmentImportPolicy.resolveMimeType("bundle.thirdparty", "text/x-whatever"))
        assertFalse(AttachmentImportPolicy.isSupportedFile("bundle.thirdparty", "application/octet-stream"))
        // Legacy formats are blocked by processFile before this with a dedicated prompt, so they do not count as supported here.
        assertFalse(AttachmentImportPolicy.isSupportedFile("report.doc", null))
    }

    @Test
    fun `mime only fallback allows explicit supported types`() {
        assertTrue(
            AttachmentImportPolicy.isSupportedFile(
                fileName = "README",
                detectedMimeType = "application/json",
            ),
        )
    }

    @Test
    fun `office extension resolves canonical mime`() {
        assertEquals(
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            AttachmentImportPolicy.resolveMimeType(
                fileName = "notes.docx",
                detectedMimeType = null,
            ),
        )
    }

    @Test
    fun `attachment size limit allows 25 MB and rejects larger files D31 v3 dot 1 heap defense`() {

        assertTrue(AttachmentImportPolicy.isWithinSizeLimit(25L * 1024L * 1024L))
        assertFalse(AttachmentImportPolicy.isWithinSizeLimit(25L * 1024L * 1024L + 1L))
    }
}
