package ai.oriveo.community.core.attachments

import ai.oriveo.community.core.app.AppLanguageManager
import ai.oriveo.community.core.attachments.extractors.EpubTextExtractor
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

    /** Attachment extraction spec section 3.4: look back after byte truncation and cut before the nearest page marker / heading line; the old ===Sheet: is no longer recognized. */
    @Test
    fun byteTruncationBacksUpToTheLastPageMarkerOrHeading() {
        val limits = FileExtractionLimits.DEFAULT.copy(maxBytes = 60)
        val pages = "--- Page 1 ---\naaaa\nbbbb\n\n--- Page 2 ---\ncccc\ndddd\neeee\nffff\ngggg"
        assertEquals("--- Page 1 ---\naaaa\nbbbb\n", FileTextExtractor.truncate(pages, pages.length, limits).content)

        val headings = "### One\naaaa\n###### Six\nbbbb\ncccc\ndddd\neeee\nffff\ngggg\nhhhh\niiii"
        assertEquals("### One\naaaa", FileTextExtractor.truncate(headings, headings.length, limits).content)

        val legacy = "===Sheet: A\naaaa\nbbbb\ncccc\ndddd\neeee\nffff\ngggg\nhhhh\niiii\njjjj\nkkkk\nllll"
        assertEquals(
            "===Sheet: A\naaaa\nbbbb\ncccc\ndddd\neeee\nffff\ngggg\nhhhh\niiii",
            FileTextExtractor.truncate(legacy, legacy.length, limits).content,
        )
    }

    /** The whole file is a single line over the byte cap: keep the beginning, cut at a UTF-8 character boundary, never to empty content. */
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
        val docx = zipOf(
            "word/document.xml" to
                "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">" +
                "<w:body><w:p><w:r><w:t>hello</w:t></w:r></w:p></w:body></w:document>",
        )

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

    // -- Supplementary rules from the implementation phase of the attachment extraction spec (sections 3.3 3.4 4A 5 7 9 10), items the shared fixtures do not cover --

    @Test
    fun lookbackHittingTheFirstKeptLineDoesNotAlign() {
        val limits = FileExtractionLimits.DEFAULT.copy(maxBytes = 30)
        val raw = "## Only\naaaa\nbbbb\ncccc\ndddd\neeee\nffff"
        assertEquals("## Only\naaaa\nbbbb\ncccc\ndddd", FileTextExtractor.truncate(raw, raw.length, limits).content)
    }

    @Test
    fun cellParagraphsTrimLineBreaksBeforeJoining() {
        val docx = docxOf(
            "<w:tbl><w:tr><w:tc><w:p><w:r><w:t>a</w:t><w:br/></w:r></w:p><w:p><w:r><w:br/></w:r></w:p>" +
                "<w:p><w:r><w:t>b</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>c</w:t></w:r></w:p></w:tc></w:tr></w:tbl>",
        )
        assertEquals("| a<br>b | c |\n| --- | --- |", extractDocx(docx))
    }

    @Test
    fun docxFieldInstructionSuppressesEveryOutput() {
        val docx = docxOf(
            "<w:p><w:r><w:t>A</w:t></w:r><w:r><w:fldChar w:fldCharType=\"begin\"/></w:r>" +
                "<w:r><w:instrText>REF x</w:instrText><w:t>instr</w:t><w:tab/><w:br/><w:cr/><w:noBreakHyphen/>" +
                "<w:footnoteReference w:id=\"1\"/><w:endnoteReference w:id=\"2\"/>" +
                "<w:txbxContent><w:p><w:r><w:t>Box</w:t></w:r></w:p></w:txbxContent></w:r>" +
                "<w:r><w:fldChar w:fldCharType=\"separate\"/></w:r><w:r><w:t>B</w:t></w:r>" +
                "<w:r><w:fldChar w:fldCharType=\"end\"/></w:r></w:p>",
            "word/footnotes.xml" to "<w:footnotes xmlns:w=\"$W\"><w:footnote w:id=\"1\"><w:p><w:r><w:t>Note</w:t></w:r></w:p></w:footnote></w:footnotes>",
        )
        assertEquals("AB", extractDocx(docx))
    }

    @Test
    fun docxSdtPropertiesAreSkippedEntirely() {
        val docx = docxOf(
            "<w:p><w:sdt><w:sdtPr><w:alias w:val=\"x\"/><w:t>junk</w:t></w:sdtPr><w:sdtEndPr><w:t>junk2</w:t></w:sdtEndPr>" +
                "<w:sdtContent><w:r><w:t>kept</w:t></w:r></w:sdtContent></w:sdt></w:p>",
        )
        assertEquals("kept", extractDocx(docx))
    }

    @Test
    fun pptxSlidesThatDoNotResolveAreSkippedWithoutTakingANumber() {
        fun slide(title: String) = "<p:sld xmlns:p=\"$P\" xmlns:a=\"$A\"><p:cSld><p:spTree><p:sp><p:nvSpPr><p:nvPr>" +
            "<p:ph type=\"title\"/></p:nvPr></p:nvSpPr><p:txBody><a:p><a:r><a:t>$title</a:t></a:r></a:p></p:txBody></p:sp>" +
            "</p:spTree></p:cSld></p:sld>"
        val slideType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide"
        val pptx = zipOf(
            "ppt/presentation.xml" to "<p:presentation xmlns:p=\"$P\" xmlns:r=\"$R\"><p:sldIdLst>" +
                "<p:sldId id=\"256\" r:id=\"rId1\"/><p:sldId id=\"257\" r:id=\"rId9\"/>" +
                "<p:sldId id=\"258\" r:id=\"rId2\"/><p:sldId id=\"259\" r:id=\"rId3\"/></p:sldIdLst></p:presentation>",
            "ppt/_rels/presentation.xml.rels" to "<Relationships xmlns=\"$PKG_RELS\">" +
                "<Relationship Id=\"rId1\" Type=\"$slideType\" Target=\"slides/slide1.xml\"/>" +
                "<Relationship Id=\"rId2\" Type=\"$slideType\" Target=\"slides/slide2.xml\"/>" +
                "<Relationship Id=\"rId3\" Type=\"$slideType\" Target=\"slides/slide3.xml\"/></Relationships>",
            "ppt/slides/slide1.xml" to slide("One"),
            "ppt/slides/slide3.xml" to slide("Three"),
        )
        val content = FileTextExtractor.extract(
            pptx, "deck.pptx", "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        ).content
        assertEquals("## Slide 1: One\n\n## Slide 2: Three", content)
    }

    @Test
    fun missingMainPartsAreCorruptedFiles() {
        val epubContainer = "<container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles>" +
            "<rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>"
        val cases = listOf(
            Triple(zipOf("[Content_Types].xml" to "<Types/>"), "book.xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"),
            Triple(zipOf("mimetype" to "application/epub+zip"), "no-container.epub", "application/epub+zip"),
            Triple(zipOf("mimetype" to "application/epub+zip", "META-INF/container.xml" to epubContainer), "no-opf.epub", "application/epub+zip"),
            Triple(zipOf("mimetype" to "application/vnd.oasis.opendocument.text"), "no-content.odt", "application/vnd.oasis.opendocument.text"),
        )
        for ((bytes, name, mime) in cases) {
            val error = runCatching { FileTextExtractor.extract(bytes, name, mime) }.exceptionOrNull()
            assertEquals(name, ExtractionErrorCode.CorruptedFile, (error as? ExtractionException)?.code)
        }
    }

    @Test
    fun odtTableRepeatsAndCoveredCellsFollowOdsWithoutTrimmingTheRange() {
        val odt = odtOf(
            "<table:table><table:table-row><table:table-cell><text:p>A</text:p></table:table-cell>" +
                "<table:covered-table-cell/><table:table-cell><text:p>B</text:p></table:table-cell></table:table-row>" +
                "<table:table-row table:number-rows-repeated=\"2\"><table:table-cell><text:p>C</text:p></table:table-cell></table:table-row>" +
                "<table:table-row table:number-rows-repeated=\"2\"><table:table-cell table:number-columns-repeated=\"4\"/></table:table-row>" +
                "<table:table-row><table:table-cell table:number-columns-repeated=\"2\"/><table:table-cell><text:p>D</text:p></table:table-cell></table:table-row>" +
                "<table:table-row table:number-rows-repeated=\"9\"><table:table-cell/></table:table-row></table:table>",
        )
        assertEquals(
            "| A |  | B |\n| --- | --- | --- |\n| C |  |  |\n| C |  |  |\n|  |  |  |\n|  |  |  |\n|  |  | D |",
            odt,
        )
    }

    @Test
    fun odtTableWiderThanFiftyColumnsCountsRepeatsInTheNote() {
        val odt = odtOf(
            "<table:table><table:table-row><table:table-cell table:number-columns-repeated=\"55\"><text:p>x</text:p></table:table-cell>" +
                "<table:table-cell table:number-columns-repeated=\"3\"/><table:table-cell><text:p>y</text:p></table:table-cell>" +
                "</table:table-row><table:table-row><table:table-cell><text:p>z</text:p></table:table-cell></table:table-row></table:table>",
        )
        assertTrue(odt, odt.endsWith("\n\n(9 more columns not shown)"))
        assertEquals(50, odt.lines().first().split(" | ").size)
    }

    @Test
    fun epubHrefEscapingThePackageRootIsDroppedWhileWalkingDotDot() {
        assertEquals("x.html", EpubTextExtractor.resolveHref("OEBPS/content.opf", "../x.html"))
        assertEquals(null, EpubTextExtractor.resolveHref("OEBPS/content.opf", "../../x.html"))
        // URL resolution clamps an extra `..` back to the root giving `OEBPS/x.html`; resolving segment by segment, it has already crossed the boundary.
        assertEquals(null, EpubTextExtractor.resolveHref("OEBPS/content.opf", "../../OEBPS/x.html"))
    }

    private fun extractDocx(docx: ByteArray): String =
        FileTextExtractor.extract(docx, "doc.docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document").content

    private fun docxOf(body: String, vararg parts: Pair<String, String>): ByteArray =
        zipOf("word/document.xml" to "<w:document xmlns:w=\"$W\"><w:body>$body</w:body></w:document>", *parts)

    private fun odtOf(text: String): String {
        val content = "<office:document-content xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" " +
            "xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\" " +
            "xmlns:table=\"urn:oasis:names:tc:opendocument:xmlns:table:1.0\"><office:body><office:text>$text" +
            "</office:text></office:body></office:document-content>"
        return FileTextExtractor.extract(
            zipOf("mimetype" to "application/vnd.oasis.opendocument.text", "content.xml" to content),
            "doc.odt",
            "application/vnd.oasis.opendocument.text",
        ).content
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

    // -- Attachment extraction spec section 14 deadline, section 1 UI language --

    @Test
    fun extractionDeadlineExpiresOnlyAfterThirtySecondsOnTheInjectedClock() {
        var now = 1_000L
        val deadline = ExtractionDeadline(nanoTime = { now })
        now += 30_000_000_000L
        assertFalse(deadline.isExpired)
        deadline.check()

        now += 1L
        assertTrue(deadline.isExpired)
        val error = runCatching { deadline.check() }.exceptionOrNull()
        assertEquals(ExtractionErrorCode.ExtractionTimeout, (error as? ExtractionException)?.code)
    }

    @Test
    fun extractionDeadlineSurvivesNanoTimeOverflow() {
        var now = Long.MAX_VALUE - 5L
        val deadline = ExtractionDeadline(budgetNanos = 100L, nanoTime = { now })
        now += 50L // overflows to negative; the difference is still 50
        assertFalse(deadline.isExpired)
        now += 51L
        assertTrue(deadline.isExpired)
    }

    @Test
    fun extractionUiLanguageMapsAppLocaleToTheSpecValues() {
        val cases = mapOf(
            "zh-CN" to "zh-Hans", "zh-Hans-TW" to "zh-Hans", "zh" to "zh-Hans",
            "zh-TW" to "zh-Hant", "zh-HK" to "zh-Hant", "zh-Hant" to "zh-Hant",
            "ja-JP" to "ja", "ko" to "ko", "ru-RU" to "ru",
            "en-US" to "en", "de" to "en", "ar-u-nu-latn" to "en", "pt-BR" to "en",
        )
        cases.forEach { (tag, expected) ->
            assertEquals(tag, expected, AppLanguageManager.extractionUiLanguage(java.util.Locale.forLanguageTag(tag)))
        }
    }
    private companion object {
        const val W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
        const val P = "http://schemas.openxmlformats.org/presentationml/2006/main"
        const val A = "http://schemas.openxmlformats.org/drawingml/2006/main"
        const val R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        const val PKG_RELS = "http://schemas.openxmlformats.org/package/2006/relationships"
    }
}
