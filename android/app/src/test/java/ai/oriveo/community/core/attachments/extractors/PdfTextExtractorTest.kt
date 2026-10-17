package ai.oriveo.community.core.attachments.extractors

import androidx.test.core.app.ApplicationProvider
import ai.oriveo.community.core.attachments.ExtractedText
import ai.oriveo.community.core.attachments.ExtractionErrorCode
import ai.oriveo.community.core.attachments.ExtractionException
import ai.oriveo.community.core.attachments.FileExtractionLimits
import ai.oriveo.community.core.attachments.FileTextExtractor
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDPage
import com.tom_roush.pdfbox.pdmodel.PDPageContentStream
import com.tom_roush.pdfbox.pdmodel.font.PDType1Font
import java.io.ByteArrayOutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Memory discipline of PDF extraction: output stops at the limit, and what
 * [FileTextExtractor.truncate] makes of the capped text has to equal, field for field, what it
 * makes of the full text.
 */
@RunWith(RobolectricTestRunner::class)
class PdfTextExtractorTest {

    @Before
    fun setUp() {
        PDFBoxResourceLoader.init(ApplicationProvider.getApplicationContext())
    }

    @Test
    fun `extracts the text layer of a real pdf`() {
        val text = PdfTextExtractor.extract(pdfWithLines(listOf("first line", "second line")))

        assertEquals("--- Page 1 ---\nfirst line\nsecond line", text)
    }

    @Test
    fun `page text expands ligatures and maps radical code points back to ideographs`() {
        assertEquals("office file \u7B2C\u4E8C\u9875", PdfTextExtractor.normalizePageText("o\uFB03ce \uFB01le \u7B2C\u2F06\u2EDA  \n\n"))
    }

    @Test
    fun `pages without a text layer go to the ocr hook and an all-ocr result is flagged scanned`() {
        val asked = mutableListOf<Int>()
        val result = PdfTextExtractor.extractPages(pdfWithLines(emptyList()), ocr = { page, _ -> asked += page; "123" })

        assertEquals(listOf(1), asked)
        assertEquals(PdfText("--- Page 1 (OCR) ---\n123", scanned = true), result)
    }

    @Test
    fun `an ocr hook that recognizes nothing still reports a scanned pdf`() {
        val error = runCatching {
            PdfTextExtractor.extractPages(pdfWithLines(emptyList()), ocr = { _, _ -> "" })
        }.exceptionOrNull()

        assertEquals(ExtractionErrorCode.ScannedPdf, (error as ExtractionException).code)
    }

    @Test
    fun `a capped extraction truncates to exactly what the full text truncates to`() {
        val lines = (1..120).map { "row $it ${"x".repeat(40)}" }
        val pdf = pdfWithLines(lines)
        // A limit far below the full text, to force the path that keeps only line breaks past it.
        val limits = FileExtractionLimits.DEFAULT.copy(maxBytes = 900, maxLines = 50)

        val full = PdfTextExtractor.extract(pdf)
        val capped = PdfTextExtractor.extract(pdf, maxOutputChars = limits.maxBytes + 1)
        val viaProduction = FileTextExtractor.extract(pdf, "report.pdf", "application/pdf", limits)

        assertTrue("cap must actually bite", capped.length < full.length)
        assertEquals(FileTextExtractor.truncate(full, pdf.size, limits), viaProduction)
        // 120 lines of body + the page marker of page 1.
        assertEquals(121, viaProduction.totalLines)
        assertEquals(ExtractedText.TruncationReason.Lines, viaProduction.truncationReason)
        assertTrue(viaProduction.content.toByteArray().size <= limits.maxBytes)
    }

    @Test
    fun `a pdf without a text layer is reported as scanned`() {
        val error = runCatching { PdfTextExtractor.extract(pdfWithLines(emptyList())) }.exceptionOrNull()

        assertEquals(ExtractionErrorCode.ScannedPdf, (error as ExtractionException).code)
    }

    @Test
    fun `bytes that are not a pdf are reported as corrupted`() {
        val error = runCatching { PdfTextExtractor.extract("not a pdf".toByteArray()) }.exceptionOrNull()

        assertEquals(ExtractionErrorCode.CorruptedFile, (error as ExtractionException).code)
    }

    @Test
    fun `bounded writer drops body past the cap but keeps every line break`() {
        val writer = BoundedPdfTextWriter(maxChars = 5)
        writer.write("  \n abcdefg\nsecond\nthird\n")

        // Leading whitespace is dropped. Past the limit the body is dropped, line breaks between
        // lines are kept, and the final line break goes the way trim() would take it: the trimmed
        // full text has 3 lines, and so does this (2 line breaks).
        assertEquals("abcde\n\n", writer.text())
    }

    @Test
    fun `bounded writer trims like the full text when the cap is never reached`() {
        val writer = BoundedPdfTextWriter(maxChars = 100)
        writer.write("\n  hello\nworld \n\n")

        assertEquals("hello\nworld", writer.text())
        assertFalse(writer.text().endsWith("\n"))
    }

    @Test
    fun `scratch budget follows the heap and stays inside its bounds`() {
        assertEquals(4L * 1024 * 1024, scratchMainMemoryBytes(maxHeapBytes = 32L * 1024 * 1024))
        assertEquals(16L * 1024 * 1024, scratchMainMemoryBytes(maxHeapBytes = 256L * 1024 * 1024))
        assertEquals(16L * 1024 * 1024, scratchMainMemoryBytes(maxHeapBytes = 1024L * 1024 * 1024))
        assertEquals(8L * 1024 * 1024, scratchMainMemoryBytes(maxHeapBytes = 128L * 1024 * 1024))
    }

    private fun pdfWithLines(lines: List<String>): ByteArray {
        val out = ByteArrayOutputStream()
        PDDocument().use { document ->
            val page = PDPage()
            document.addPage(page)
            PDPageContentStream(document, page).use { content ->
                if (lines.isNotEmpty()) {
                    content.beginText()
                    content.setFont(PDType1Font.HELVETICA, 4f)
                    content.setLeading(5f)
                    content.newLineAtOffset(20f, 780f)
                    lines.forEach { line ->
                        content.showText(line)
                        content.newLine()
                    }
                    content.endText()
                }
            }
            document.save(out)
        }
        return out.toByteArray()
    }
}
