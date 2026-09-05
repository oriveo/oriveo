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

    @Test
    fun `unknown extension is rejected even when mime looks textual`() {
        assertFalse(
            AttachmentImportPolicy.isSupportedFile(
                fileName = "bundle.thirdparty",
                detectedMimeType = "text/plain",
            ),
        )
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
