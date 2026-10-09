package ai.oriveo.community.core.attachments

import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.provider.MessageBuilder
import org.junit.Assert.*
import org.junit.Test
import java.util.Base64

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

    @Test
    fun aTruncatedFileRebuiltAtSendTimeStillTellsTheModelItWasTruncated() {
        // Goes through real import truncation and the send-time rebuild: a persisted attachment records only "truncated" and the total line count, not the reason.
        val extracted = FileTextExtractor.truncate((1..700).joinToString("\n") { "L$it" }, sizeBytes = 4_000)
        val attachment = Attachment(
            id = "1",
            kind = AttachmentKind.File,
            fileName = "big.md",
            mimeType = "text/markdown",
            base64Data = Base64.getEncoder().encodeToString(extracted.content.toByteArray()),
            extractedTotalLines = extracted.totalLines,
            extractedTruncated = extracted.truncated,
            extractedSizeBytes = extracted.sizeBytes,
        )
        val payload = MessageBuilder.toAttachmentPayloads(listOf(attachment)).single()
        assertNull(payload.extracted?.truncationReason)

        val xml = AttachmentInjector.formatAttachmentXml(1, payload)
        assertTrue(xml, xml.contains("<TRUNCATED>showing first 500 of 700 lines</TRUNCATED>"))

        val markdown = AttachmentInjector.formatAttachmentMarkdown(1, payload)
        assertTrue(markdown, markdown.contains("- Lines: 700 (showing first 500"))
    }

    private fun truncatedPayload(reason: ExtractedText.TruncationReason?) = AttachmentInjector.AttachmentPayload(
        fileName = "big.md",
        mimeType = "text/markdown",
        sizeBytes = 50_000,
        extracted = ExtractedText(
            content = (1..500).joinToString("\n") { "L$it" },
            totalLines = 700,
            truncated = true,
            truncationReason = reason,
            sizeBytes = 50_000,
        ),
        errorCode = null,
    )

    /** The truncation marker carries no cap number and no reason: the number does not follow the model's limit, so writing one would tell the model a wrong cap. */
    @Test
    fun theTruncationMarkerCarriesNoSizeNumberWhateverTheReason() {
        for (reason in listOf(ExtractedText.TruncationReason.Lines, ExtractedText.TruncationReason.Bytes, null)) {
            val xml = AttachmentInjector.formatAttachmentXml(1, truncatedPayload(reason))
            assertTrue(xml, xml.contains("<TRUNCATED>showing first 500 of 700 lines</TRUNCATED>"))
            val markdown = AttachmentInjector.formatAttachmentMarkdown(1, truncatedPayload(reason))
            assertTrue(markdown, markdown.contains("- Lines: 700 (showing first 500)\n"))
            assertFalse(xml + markdown, (xml + markdown).contains("200KB"))
        }
    }

    @Test
    fun fileTooLargeInstructionCoversFilesThatOnlyBlowUpOnceUnpacked() {
        val payload = AttachmentInjector.AttachmentPayload(
            fileName = "huge.xlsx", mimeType = "application/zip", sizeBytes = 10, extracted = null,
            errorCode = ExtractionErrorCode.FileTooLarge,
        )
        val expected = "This file is past the size the local extractor will read, either as stored or once unpacked. " +
            "DO NOT fabricate content. Tell the user the file is too large and ask them to split or shorten it."
        assertTrue(AttachmentInjector.formatAttachmentXml(1, payload).contains("[INSTRUCTION: $expected]"))
        assertTrue(AttachmentInjector.formatAttachmentMarkdown(1, payload).contains("> **Instruction to model:** $expected"))
    }

    @Test
    fun fileTypeComesFromTheMimeForOpenDocumentRtfAndSvg() {
        val expected = mapOf(
            "application/vnd.oasis.opendocument.text" to "odt",
            "application/vnd.oasis.opendocument.spreadsheet" to "ods",
            "application/vnd.oasis.opendocument.presentation" to "odp",
            "application/rtf" to "rtf",
            "text/rtf" to "rtf",
            "image/svg+xml" to "svg",
        )
        for ((mime, type) in expected) {
            // A file name without an extension: only the mime can tell.
            val xml = AttachmentInjector.formatAttachmentXml(1, makePayload(fileName = "untitled", mime = mime))
            assertTrue("$mime: $xml", xml.contains("<FILE_TYPE>$type</FILE_TYPE>"))
        }
    }

    @Test
    fun aWhitespaceOnlyMessageBodyIsNotPrependedToTheAttachments() {
        val result = AttachmentInjector.injectAll(" \n ", listOf(makePayload()))
        assertTrue(result.text, result.text.startsWith("<ATTACHMENT_FILE>"))
        // Body text with content is kept as is, without trimming whitespace at either end.
        val kept = AttachmentInjector.injectAll(" hi ", listOf(makePayload()))
        assertTrue(kept.text, kept.text.startsWith(" hi \n\n<ATTACHMENT_FILE>"))
    }

    @Test
    fun totalCapCountsFileContentOnlyNotTheWrapper() {
        val limits = FileExtractionLimits.DEFAULT
        val half = "x".repeat(limits.totalCap / 2)
        for (wrapper in AttachmentWrapperVersion.entries) {
            val r = AttachmentInjector.injectAll(
                "prompt",
                listOf(
                    makePayload(fileName = "a.txt", content = half, sizeBytes = half.length),
                    makePayload(fileName = "b.txt", content = half, sizeBytes = half.length),
                ),
                limits,
                wrapper,
            )
            assertTrue("$wrapper skipped ${r.skipped}", r.skipped.isEmpty())
            assertTrue(r.text.contains("a.txt") && r.text.contains("b.txt"))
        }
    }

    @Test
    fun oneByteOfContentOverTheTotalCapIsStillSkipped() {
        val limits = FileExtractionLimits.DEFAULT
        val half = "x".repeat(limits.totalCap / 2)
        val r = AttachmentInjector.injectAll(
            "prompt",
            listOf(
                makePayload(fileName = "a.txt", content = half),
                makePayload(fileName = "b.txt", content = half + "x"),
            ),
            limits,
        )
        assertEquals(listOf(AttachmentInjector.SkippedAttachment("b.txt", AttachmentInjector.SkipReason.TotalCapExceeded)), r.skipped)
    }
}
