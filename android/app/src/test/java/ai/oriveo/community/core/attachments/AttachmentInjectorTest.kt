package ai.oriveo.community.core.attachments

import org.junit.Assert.*
import org.junit.Test

class AttachmentInjectorTest {

    private fun makePayload(
        fileName: String = "a.txt",
        mime: String = "text/plain",
        sizeBytes: Int = 11,
        content: String? = "hello\nworld",
        errorCode: ExtractionErrorCode? = null,
    ) = AttachmentInjector.AttachmentPayload(
        fileName = fileName,
        mimeType = mime,
        sizeBytes = sizeBytes,
        extracted = content?.let {
            ExtractedText(it, it.split("\n").size, false, null, it.toByteArray().size)
        },
        errorCode = errorCode,
    )

    @Test
    fun formatXmlNoTruncation() {
        val s = AttachmentInjector.formatAttachmentXml(1, makePayload())
        assertTrue(s.contains("<FILE_INDEX>1</FILE_INDEX>"))
        assertTrue(s.contains("<FILE_NAME>a.txt</FILE_NAME>"))
        assertTrue(s.contains("<FILE_LINES>2</FILE_LINES>"))
        assertTrue(s.contains("hello\nworld"))
        assertFalse(s.contains("<TRUNCATED>"))
    }

    @Test
    fun formatXmlTruncated() {
        val payload = AttachmentInjector.AttachmentPayload(
            fileName = "big.md",
            mimeType = "text/markdown",
            sizeBytes = 50000,
            extracted = ExtractedText(
                content = (1..500).joinToString("\n") { "L$it" },
                totalLines = 700,
                truncated = true,
                truncationReason = ExtractedText.TruncationReason.Lines,
                sizeBytes = 50000,
            ),
            errorCode = null,
        )
        val s = AttachmentInjector.formatAttachmentXml(2, payload)
        assertTrue(s.contains("<TRUNCATED>showing first 500 of 700 lines"))
    }

    @Test
    fun formatXmlError() {
        val s = AttachmentInjector.formatAttachmentXml(
            1,
            makePayload(
                fileName = "p.pdf",
                mime = "application/pdf",
                content = null,
                errorCode = ExtractionErrorCode.ScannedPdf,
            ),
        )
        assertTrue(s.contains("[ERROR: extraction failed - scanned_pdf]"))
        assertTrue(s.contains("[INSTRUCTION:"))
    }

    @Test
    fun formatMarkdownBasic() {
        val s = AttachmentInjector.formatAttachmentMarkdown(1, makePayload())
        assertTrue(s.contains("## Attachment 1: a.txt"))
        assertTrue(s.contains("hello\nworld"))
        assertTrue(s.startsWith("---"))
    }

    @Test
    fun injectAllD17MaxFiles() {
        val payload = makePayload(content = "x")
        val r = AttachmentInjector.injectAll(
            "prompt",
            listOf(
                payload.copy(fileName = "a.txt"),
                payload.copy(fileName = "b.txt"),
                payload.copy(fileName = "c.txt"),
                payload.copy(fileName = "d.txt"),
            ),
        )
        assertEquals(1, r.skipped.size)
        assertEquals("d.txt", r.skipped[0].fileName)
        assertEquals(AttachmentInjector.SkipReason.TooManyFiles, r.skipped[0].reason)
    }

    @Test
    fun injectAllD16TotalCap() {
        val bigContent = "x".repeat(120_000)
        val payload = makePayload(content = bigContent, sizeBytes = 120_000)
        val r = AttachmentInjector.injectAll(
            "prompt",
            listOf(
                payload.copy(fileName = "a.txt"),
                payload.copy(fileName = "b.txt"),
            ),
        )

        assertTrue(r.skipped.isNotEmpty())
        assertEquals(AttachmentInjector.SkipReason.TotalCapExceeded, r.skipped[0].reason)
    }

    @Test
    fun injectAllEmptyAttachments() {
        val r = AttachmentInjector.injectAll("hello", emptyList())
        assertEquals("hello", r.text)
        assertTrue(r.skipped.isEmpty())
    }
}
