package ai.oriveo.community.core.attachments

import org.junit.Assert.*
import org.junit.Test

class FileTextExtractorTest {

    @Test
    fun noTruncation() {
        val raw = (1..100).joinToString("\n") { "line $it" }
        val r = FileTextExtractor.truncate(raw, raw.toByteArray().size)
        assertFalse(r.truncated)
        assertEquals(100, r.totalLines)
        assertEquals(raw, r.content)
    }

    @Test
    fun truncateByLines() {
        val raw = (1..700).joinToString("\n") { "L$it" }
        val r = FileTextExtractor.truncate(raw, raw.toByteArray().size)
        assertTrue(r.truncated)
        assertEquals(ExtractedText.TruncationReason.Lines, r.truncationReason)
        assertEquals(700, r.totalLines)
        assertEquals(500, r.content.split("\n").size)
    }

    @Test
    fun truncateByBytes() {
        val big = "a".repeat(5000)
        val raw = (1..50).joinToString("\n") { big }
        val r = FileTextExtractor.truncate(raw, raw.toByteArray().size)
        assertTrue(r.truncated)
        assertTrue(r.content.toByteArray(Charsets.UTF_8).size <= FileExtractionLimits.MAX_BYTES)
    }

    /** A document that is a single line over the byte cap: keep the start, cut on a UTF-8 character boundary, and never cut it down to nothing. */
    @Test
    fun aSingleLineOverTheByteCapKeepsItsHeadCutOnACharacterBoundary() {
        val limits = FileExtractionLimits.DEFAULT.copy(maxBytes = 10)
        // Each CJK character takes 3 bytes: 10 bytes fit 3 of them, and the 4th must not be cut in half.
        val cjk = FileTextExtractor.truncate("\u4e00\u4e8c\u4e09\u56db\u4e94\u516d", 18, limits)
        assertEquals("\u4e00\u4e8c\u4e09", cjk.content)
        assertTrue(cjk.truncated)
        assertEquals(ExtractedText.TruncationReason.Bytes, cjk.truncationReason)
        assertEquals(1, cjk.totalLines)
        // A 4-byte emoji (a surrogate pair) is not split either.
        val emoji = FileTextExtractor.truncate("ab😀😀😀", 14, limits)
        assertEquals("ab😀😀", emoji.content)
        // Through the production extraction entry point: minified JSON.
        val json = "{\"k\":\"" + "v".repeat(300_000) + "\"}"
        val extracted = FileTextExtractor.extract(json.toByteArray(), "min.json", "application/json")
        assertTrue(extracted.truncated)
        assertEquals(FileExtractionLimits.MAX_BYTES, extracted.content.toByteArray(Charsets.UTF_8).size)
        assertTrue(extracted.content.startsWith("{\"k\":\"vvv"))
    }

    /** The first line alone is over the cap and more lines follow: the start of the first line is kept the same way. */
    @Test
    fun anOversizedFirstLineIsCutInsideTheLineEvenWhenMoreLinesFollow() {
        val limits = FileExtractionLimits.DEFAULT.copy(maxBytes = 10)
        val r = FileTextExtractor.truncate("0123456789ABCDEF\nsecond", 23, limits)
        assertEquals("0123456789", r.content)
        assertTrue(r.truncated)
        assertEquals(2, r.totalLines)
    }

    @Test
    fun resolveDefaultWhenNoModel() {
        val limits = FileExtractionLimits.resolve(null)
        assertEquals(500, limits.maxLines)
        assertEquals(204_800, limits.maxBytes)
        assertEquals(3, limits.maxFiles)
    }

    @Test
    fun resolveTakesTheAttachmentCountFromTheModel() {
        fun model(maxAttachments: Int?) = ai.oriveo.community.core.model.AIModel(
            id = "m",
            name = "m",
            attachmentExtraction = ai.oriveo.community.core.model.AttachmentExtractionLimits(maxAttachments = maxAttachments),
        )
        assertEquals(5, FileExtractionLimits.resolve(model(5)).maxFiles)
        assertEquals(1, FileExtractionLimits.resolve(model(1)).maxFiles)
        // When it is not set or not positive, the default applies.
        assertEquals(3, FileExtractionLimits.resolve(model(null)).maxFiles)
        assertEquals(3, FileExtractionLimits.resolve(model(0)).maxFiles)
    }

    @Test
    fun unsupportedMimeThrows() {
        var caught: ExtractionException? = null
        try {
            FileTextExtractor.extract(
                "hello".toByteArray(),
                "file.xyz",
                "application/x-unknown-format",
            )
        } catch (e: ExtractionException) {
            caught = e
        }
        assertNotNull(caught)
        assertEquals(ExtractionErrorCode.UnsupportedFormat, caught!!.code)
    }

    @Test
    fun fileTooLargeThrows() {
        val limits = FileExtractionLimits.DEFAULT.copy(maxInputFileBytes = 10L)
        var caught: ExtractionException? = null
        try {
            FileTextExtractor.extract(
                "a".repeat(20).toByteArray(),
                "test.txt",
                "text/plain",
                limits,
            )
        } catch (e: ExtractionException) {
            caught = e
        }
        assertNotNull(caught)
        assertEquals(ExtractionErrorCode.FileTooLarge, caught!!.code)
    }

    // Fault boundary of the extractor, and truncation without a full line table

    @Test
    fun malformedOfficeArchiveIsReportedInsteadOfEscapingAsParserException() {
        // Through the production entry point: word/document.xml is not well-formed XML, so SAX
        // throws SAXParseException. If that left extract() as-is, the caller's catch (Exception)
        // would turn it into a silent failure and the user would be told nothing.
        val docx = zipOf("word/document.xml" to "<w:document><w:p>unclosed")

        val error = runCatching {
            FileTextExtractor.extract(
                docx,
                "broken.docx",
                "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            )
        }.exceptionOrNull()

        assertEquals(ExtractionErrorCode.CorruptedFile, (error as ExtractionException).code)
    }

    @Test
    fun encryptedOoxmlIsReportedAsPasswordProtected() {
        // A password-protected docx/xlsx/pptx is an OLE compound document, not a zip. ZipInputStream
        // used to find no entry at all, so a docx was attached as "extracted successfully, empty
        // content" and the user saw no notice.
        val oleHeader = byteArrayOf(
            0xD0.toByte(), 0xCF.toByte(), 0x11, 0xE0.toByte(), 0xA1.toByte(), 0xB1.toByte(), 0x1A, 0xE1.toByte(),
        )
        val mimes = mapOf(
            "docx" to "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "xlsx" to "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "pptx" to "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        )

        for ((ext, mime) in mimes) {
            val error = runCatching {
                FileTextExtractor.extract(oleHeader + ByteArray(504), "locked.$ext", mime)
            }.exceptionOrNull()

            assertEquals(ext, ExtractionErrorCode.PasswordProtectedOffice, (error as? ExtractionException)?.code)
        }
    }

    @Test
    fun ordinaryDocxIsStillExtracted() {
        val docx = zipOf("word/document.xml" to "<w:document><w:p><w:t>hello</w:t></w:p></w:document>")

        val extracted = FileTextExtractor.extract(
            docx,
            "plain.docx",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        )

        assertEquals("hello", extracted.content.trim())
    }

    @Test
    fun aFileShorterThanTheOleHeaderIsNotMistakenForAnEncryptedOne() {
        val error = runCatching {
            FileTextExtractor.extract(
                byteArrayOf(0xD0.toByte(), 0xCF.toByte(), 0x11),
                "tiny.docx",
                "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            )
        }.exceptionOrNull()

        assertNotEquals(ExtractionErrorCode.PasswordProtectedOffice, (error as? ExtractionException)?.code)
    }

    @Test
    fun errorsFromParsingLibrariesNeverLeaveTheExtractorAsErrors() {
        // Once a class's static initializer has failed, every later use is a
        // NoClassDefFoundError (a LinkageError). It is not an Exception, so callers cannot catch
        // it. The boundary has to downgrade every one of these Errors.
        val cases: List<Pair<() -> Nothing, ExtractionErrorCode>> = listOf(
            { throw NoClassDefFoundError("com.tom_roush.pdfbox.text.PDFTextStripper") } to
                ExtractionErrorCode.ExtractionError,
            { throw ExceptionInInitializerError(OutOfMemoryError("heap")) } to ExtractionErrorCode.ExtractionError,
            { throw OutOfMemoryError("Failed to allocate") } to ExtractionErrorCode.ExtractionError,
            { throw StackOverflowError() } to ExtractionErrorCode.CorruptedFile,
            { throw IllegalStateException("parser state") } to ExtractionErrorCode.CorruptedFile,
        )

        for ((block, expected) in cases) {
            val error = runCatching {
                FileTextExtractor.guardExtraction("application/pdf") { block() }
            }.exceptionOrNull()
            assertEquals(expected, (error as ExtractionException).code)
        }
    }

    @Test
    fun theUntruncatedPdfEntryUsedBySkillImportOnlyEverThrowsExtractionException() {
        // Skill reference import used to call PdfTextExtractor directly, so a LinkageError thrown by another
        // pdfbox class failing to initialise mid-parse bypassed the boundary and the outer catch (Exception).
        val failures: List<() -> Nothing> = listOf(
            { throw NoClassDefFoundError("com.tom_roush.pdfbox.pdmodel.font.PDFont") },
            { throw ExceptionInInitializerError(OutOfMemoryError("heap")) },
            { throw UnsatisfiedLinkError("no pdfbox native") },
            { throw StackOverflowError() },
        )

        for (failure in failures) {
            val error = runCatching { FileTextExtractor.extractPdfText(ByteArray(0)) { failure() } }
                .exceptionOrNull()
            assertTrue("$error", error is ExtractionException)
        }
        // The real parser likewise only produces an ExtractionException on garbage bytes.
        val garbage = runCatching { FileTextExtractor.extractPdfText("not a pdf".toByteArray()) }.exceptionOrNull()
        assertTrue("$garbage", garbage is ExtractionException)
    }

    @Test
    fun skillReferenceImportDoesNotCallThePdfParserAroundTheBoundary() {
        var dir = java.io.File(System.getProperty("user.dir") ?: ".")
        var source: java.io.File? = null
        repeat(8) {
            val candidate = java.io.File(dir, "app/src/main/java/ai/oriveo/community/feature/skills/SkillEditScreen.kt")
            if (source == null && candidate.exists()) source = candidate
            dir = dir.parentFile ?: dir
        }
        val text = requireNotNull(source) { "SkillEditScreen.kt not found" }.readText()

        assertFalse(text.contains("PdfTextExtractor.extract("))
        assertTrue(text.contains("FileTextExtractor.extractPdfText("))
    }

    @Test
    fun guardLeavesDomainFailuresAndCancellationUntouched() {
        val domain = ExtractionException(ExtractionErrorCode.ScannedPdf)
        assertSame(
            domain,
            runCatching { FileTextExtractor.guardExtraction<Unit>("application/pdf") { throw domain } }
                .exceptionOrNull(),
        )
        val cancelled = kotlin.coroutines.cancellation.CancellationException("stop")
        assertSame(
            cancelled,
            runCatching { FileTextExtractor.guardExtraction<Unit>("text/plain") { throw cancelled } }
                .exceptionOrNull(),
        )
    }

    @Test
    fun truncateMatchesTheSplitEverythingReferenceOnEveryShape() {
        // truncate no longer splits the whole text into a list of lines; its result has to match
        // the split-everything-then-take implementation field for field.
        val limits = FileExtractionLimits.DEFAULT.copy(maxLines = 7, maxBytes = 60)
        val inputs = listOf(
            "",
            "single",
            "a\nb\nc",
            "trailing\n",
            "\n\nleading blank lines",
            (1..7).joinToString("\n") { "l$it" },
            (1..8).joinToString("\n") { "l$it" },
            (1..40).joinToString("\n") { "line number $it" },
            // "The first line alone is over the cap" is not in the comparison: the old implementation cut it down to nothing, and now the start of the line is kept
            // (see aSingleLineOverTheByteCapKeepsItsHeadCutOnACharacterBoundary).
            // Multi-byte characters, so the byte limit and the character count disagree.
            "\u77ed\u884c\n" + "\u6c49".repeat(30) + "\n\u5c3e",
            "windows\r\nline\r\nendings",
        )

        for (raw in inputs) {
            assertEquals("input=${raw.take(20)}", referenceTruncate(raw, limits), FileTextExtractor.truncate(raw, 1, limits))
        }
    }

    /** Reference implementation: split the whole text into lines first, then take. */
    private fun referenceTruncate(raw: String, limits: FileExtractionLimits): ExtractedText {
        val lines = raw.split("\n")
        var picked = lines
        var truncated = false
        var reason: ExtractedText.TruncationReason? = null
        if (picked.size > limits.maxLines) {
            picked = picked.take(limits.maxLines)
            truncated = true
            reason = ExtractedText.TruncationReason.Lines
        }
        var joined = picked.joinToString("\n")
        if (joined.toByteArray(Charsets.UTF_8).size > limits.maxBytes) {
            var lo = 0
            var hi = picked.size
            while (lo < hi) {
                val mid = (lo + hi + 1) / 2
                if (picked.take(mid).joinToString("\n").toByteArray(Charsets.UTF_8).size <= limits.maxBytes) {
                    lo = mid
                } else {
                    hi = mid - 1
                }
            }
            joined = picked.take(lo).joinToString("\n")
            truncated = true
            if (reason == null) reason = ExtractedText.TruncationReason.Bytes
        }
        return ExtractedText(joined, lines.size, truncated, reason, 1)
    }

    private fun zipOf(vararg entries: Pair<String, String>): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        java.util.zip.ZipOutputStream(out).use { zip ->
            for ((name, content) in entries) {
                zip.putNextEntry(java.util.zip.ZipEntry(name))
                zip.write(content.toByteArray())
                zip.closeEntry()
            }
        }
        return out.toByteArray()
    }
}
