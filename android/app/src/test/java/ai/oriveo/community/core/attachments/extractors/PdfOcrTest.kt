package ai.oriveo.community.core.attachments.extractors

import androidx.test.core.app.ApplicationProvider
import ai.oriveo.community.core.attachments.ExtractionDeadline
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
 * Scanned-document OCR (attachment extraction spec section 13): a fake engine replaces ML Kit + PdfRenderer,
 * locking the 50-page cap, deadline expiry, empty recognition, recognizer selection and fallback, and the output format of fully scanned documents.
 */
@RunWith(RobolectricTestRunner::class)
class PdfOcrTest {

    @Before
    fun setUp() {
        PDFBoxResourceLoader.init(ApplicationProvider.getApplicationContext())
    }

    @Test
    fun `a full scan recognized by ocr returns ocr markers and is flagged scanned`() {
        val engine = FakeEngine { page, _ -> "line one $page\nline two $page" }
        val pdf = pdf(listOf(null, null))

        val result = PdfTextExtractor.extractPages(pdf, ocr = PdfOcr(engine) { "en" }.open(pdf))
        val viaProduction = FileTextExtractor.extract(pdf, "scan.pdf", "application/pdf", pdfOcr = PdfOcr(engine) { "en" })

        val expected = "--- Page 1 (OCR) ---\nline one 0\nline two 0\n\n--- Page 2 (OCR) ---\nline one 1\nline two 1"
        assertEquals(PdfText(expected, scanned = true), result)
        assertEquals(expected, viaProduction.content)
        assertTrue(viaProduction.scanned)
    }

    @Test
    fun `only pages without a text layer go to ocr and the result is not flagged scanned`() {
        val engine = FakeEngine { _, _ -> "recognized" }
        val pdf = pdf(listOf("Page one text", null, "Page three text"))

        val result = FileTextExtractor.extract(pdf, "mixed.pdf", "application/pdf", pdfOcr = PdfOcr(engine) { "en" })

        assertEquals(
            "--- Page 1 ---\nPage one text\n\n--- Page 2 (OCR) ---\nrecognized\n\n--- Page 3 ---\nPage three text",
            result.content,
        )
        assertFalse(result.scanned)
        assertEquals(listOf(1), engine.pages)
    }

    @Test
    fun `pages past the fiftieth are not processed`() {
        val engine = FakeEngine { page, _ -> "p${page + 1}" }
        val pdf = pdf(List(52) { null })

        val result = PdfTextExtractor.extractPages(pdf, ocr = PdfOcr(engine) { "en" }.open(pdf))

        assertEquals((0 until 50).toList(), engine.pages)
        assertTrue(result.text.contains("--- Page 50 (OCR) ---\np50\n\n--- Page 51 --- [not processed]\n\n--- Page 52 --- [not processed]"))
        assertTrue(result.scanned)
    }

    @Test
    fun `pages left when the deadline expires are not processed and nothing throws`() {
        var now = 0L
        val deadline = ExtractionDeadline(budgetNanos = 10L, nanoTime = { now })
        val engine = FakeEngine { page, _ ->
            now += 6L
            "page ${page + 1}"
        }
        val pdf = pdf(listOf(null, null, null))

        val result = PdfTextExtractor.extractPages(pdf, deadline = deadline, ocr = PdfOcr(engine) { "en" }.open(pdf))

        assertEquals(
            PdfText(
                "--- Page 1 (OCR) ---\npage 1\n\n--- Page 2 (OCR) ---\npage 2\n\n--- Page 3 --- [not processed]",
                scanned = true,
            ),
            result,
        )
        // Each page waits only for the time left on the deadline.
        assertEquals(listOf(10L, 4L), engine.timeouts)
    }

    @Test
    fun `the text layer pass still reports a timeout`() {
        val deadline = ExtractionDeadline(budgetNanos = -1L)
        val pdf = pdf(listOf("text"))

        val error = runCatching {
            PdfTextExtractor.extractPages(pdf, deadline = deadline, ocr = PdfOcr(FakeEngine { _, _ -> "x" }) { "en" }.open(pdf))
        }.exceptionOrNull()

        assertEquals(ExtractionErrorCode.ExtractionTimeout, (error as ExtractionException).code)
    }

    @Test
    fun `an empty recognition is written as no text layer and an all-empty scan is still scanned_pdf`() {
        val pdf = pdf(listOf(null, null))
        val partly = PdfTextExtractor.extractPages(
            pdf,
            ocr = PdfOcr(FakeEngine { page, _ -> if (page == 0) " \n " else "abc" }) { "en" }.open(pdf),
        )
        val error = runCatching {
            PdfTextExtractor.extractPages(pdf, ocr = PdfOcr(FakeEngine { _, _ -> "" }) { "en" }.open(pdf))
        }.exceptionOrNull()

        assertEquals(PdfText("--- Page 1 --- [no text layer]\n\n--- Page 2 (OCR) ---\nabc", scanned = true), partly)
        assertEquals(ExtractionErrorCode.ScannedPdf, (error as ExtractionException).code)
    }

    @Test
    fun `ja ko hi pick their recognizer and every other language uses the chinese one`() {
        assertEquals(OcrScript.Japanese, PdfOcr.scriptFor("ja"))
        assertEquals(OcrScript.Japanese, PdfOcr.scriptFor("ja-JP"))
        assertEquals(OcrScript.Korean, PdfOcr.scriptFor("ko-KR"))
        assertEquals(OcrScript.Devanagari, PdfOcr.scriptFor("hi-IN"))
        listOf("zh-Hans-CN", "zh-Hant", "en-US", "ru", "fr", "").forEach {
            assertEquals(it, OcrScript.Chinese, PdfOcr.scriptFor(it))
        }

        val engine = FakeEngine { _, _ -> "ok" }
        val pdf = pdf(listOf(null))
        PdfTextExtractor.extractPages(pdf, ocr = PdfOcr(engine) { "ko-KR" }.open(pdf))
        assertEquals(listOf(OcrScript.Korean), engine.scripts)
    }

    @Test
    fun `an unavailable recognizer falls back to the chinese one for this and later pages`() {
        val engine = FakeEngine { page, script ->
            if (script != OcrScript.Chinese) error("module not downloaded")
            "page ${page + 1}"
        }
        val pdf = pdf(listOf(null, null))

        val result = PdfTextExtractor.extractPages(pdf, ocr = PdfOcr(engine) { "ja-JP" }.open(pdf))

        assertEquals(PdfText("--- Page 1 (OCR) ---\npage 1\n\n--- Page 2 (OCR) ---\npage 2", scanned = true), result)
        assertEquals(listOf(OcrScript.Japanese, OcrScript.Chinese, OcrScript.Chinese), engine.scripts)
    }

    @Test
    fun `an engine that cannot recognize leaves the pages not processed`() {
        val pdf = pdf(listOf("text", null))
        val failing = FakeEngine { _, _ -> error("recognizer crashed") }
        val unopenable = PdfOcrEngine { error("renderer refused the file") }

        val recognizeFails = PdfTextExtractor.extractPages(pdf, ocr = PdfOcr(failing) { "en" }.open(pdf))
        val openFails = PdfTextExtractor.extractPages(pdf, ocr = PdfOcr(unopenable) { "en" }.open(pdf))

        val expected = PdfText("--- Page 1 ---\ntext\n\n--- Page 2 --- [not processed]", scanned = false)
        assertEquals(expected, recognizeFails)
        assertEquals(expected, openFails)
    }

    @Test
    fun `the engine opens only when a page needs ocr and closes with the session`() {
        val textOnly = FakeEngine { _, _ -> "unused" }
        val scanned = FakeEngine { _, _ -> "123" }

        FileTextExtractor.extract(pdf(listOf("text")), "text.pdf", "application/pdf", pdfOcr = PdfOcr(textOnly) { "en" })
        FileTextExtractor.extract(pdf(listOf(null)), "scan.pdf", "application/pdf", pdfOcr = PdfOcr(scanned) { "en" })

        assertEquals(0, textOnly.opened)
        assertEquals(1, scanned.opened)
        assertEquals(1, scanned.closed)
    }

    @Test
    fun `a capped multi-page extraction with ocr truncates like the full text`() {
        val pages = (1..6).map { page -> if (page == 3) null else (1..30).joinToString("\n") { "p$page row $it ${"x".repeat(30)}" } }
        val pdf = pdf(pages)
        val engine = FakeEngine { _, _ -> "ocr line a\nocr line b" }
        val limits = FileExtractionLimits.DEFAULT.copy(maxBytes = 900, maxLines = 50)

        val full = PdfTextExtractor.extractPages(pdf, ocr = PdfOcr(engine) { "en" }.open(pdf)).text
        val capped = PdfTextExtractor.extractPages(pdf, maxOutputChars = limits.maxBytes + 1, ocr = PdfOcr(engine) { "en" }.open(pdf)).text
        val viaProduction = FileTextExtractor.extract(pdf, "report.pdf", "application/pdf", limits, pdfOcr = PdfOcr(engine) { "en" })

        assertTrue("cap must actually bite", capped.length < full.length)
        assertEquals(full.count { it == '\n' }, capped.count { it == '\n' })
        assertEquals(FileTextExtractor.truncate(full, pdf.size, limits), viaProduction)
    }

    /** Fake engine: records open / close counts and, per recognition, the page index (0-based), recognizer and wait cap. */
    private class FakeEngine(private val answer: (Int, OcrScript) -> String) : PdfOcrEngine {
        val pages = mutableListOf<Int>()
        val scripts = mutableListOf<OcrScript>()
        val timeouts = mutableListOf<Long>()
        var opened = 0
        var closed = 0

        override fun open(data: ByteArray): PdfOcrDocument {
            opened += 1
            return object : PdfOcrDocument {
                override fun recognize(pageIndex: Int, script: OcrScript, timeoutNanos: Long): String {
                    pages += pageIndex
                    scripts += script
                    timeouts += timeoutNanos
                    return answer(pageIndex, script)
                }

                override fun close() {
                    closed += 1
                }
            }
        }
    }

    /** One element per page: a string = that page's text layer (multiple lines with `\n`), null = a blank page without a text layer. */
    private fun pdf(pages: List<String?>): ByteArray {
        val out = ByteArrayOutputStream()
        PDDocument().use { document ->
            pages.forEach { text ->
                val page = PDPage()
                document.addPage(page)
                PDPageContentStream(document, page).use { content ->
                    if (text != null) {
                        content.beginText()
                        content.setFont(PDType1Font.HELVETICA, 6f)
                        content.setLeading(8f)
                        content.newLineAtOffset(20f, 760f)
                        text.lines().forEach { line ->
                            content.showText(line)
                            content.newLine()
                        }
                        content.endText()
                    }
                }
            }
            document.save(out)
        }
        return out.toByteArray()
    }
}
