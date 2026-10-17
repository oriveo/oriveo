package ai.oriveo.community.core.attachments

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import ai.oriveo.community.core.attachments.extractors.MlKitPdfOcrEngine
import ai.oriveo.community.core.attachments.extractors.PdfOcr
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * On-device (emulator) proof for attachment extraction spec sections 12 / 13: goes through the production entry [FileTextExtractor.extract],
 * with OCR using the same [PdfOcr] + [MlKitPdfOcrEngine] as Koin; no engine is replaced.
 * Fixtures come from the shared directory `shared/test-fixtures/attachments/extraction/files/pdf` (mounted as androidTest assets in build.gradle.kts).
 */
@RunWith(AndroidJUnit4::class)
class PdfOcrInstrumentedTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()

    // The recognizer is picked by UI language; pin zh so the result is device-language independent (the Chinese recognizer also reads Latin letters and digits).
    private val pdfOcr get() = PdfOcr(MlKitPdfOcrEngine(instrumentation.targetContext)) { "zh-Hans" }

    private fun fixture(name: String): ByteArray =
        instrumentation.context.assets.open(name).use { it.readBytes() }

    private fun extract(name: String): ExtractedText =
        FileTextExtractor.extract(
            data = fixture(name),
            fileName = name,
            mimeType = "application/pdf",
            uiLanguage = "zh-Hans",
            pdfOcr = pdfOcr,
        )

    @Test
    fun fullScanPdfIsRecognizedByMlKit() {
        val result = extract("full-scan.pdf")
        Log.i(TAG, "full-scan.pdf content:\n${result.content}")

        assertTrue(result.content, result.content.contains("--- Page 1 (OCR) ---"))
        assertTrue(result.content, result.content.contains("123"))
        assertTrue("scanned flag", result.scanned)
    }

    @Test
    fun imagePagePdfSecondPageIsPlaceholderOrOcr() {
        val result = extract("image-page.pdf")
        Log.i(TAG, "image-page.pdf content:\n${result.content}")

        val page2 = result.content.lines().dropWhile { !it.startsWith("--- Page 2") }
        assertTrue(result.content, page2.isNotEmpty())
        val header = page2.first()
        // Page 2 has no text in its image, so OCR is empty and `[no text layer]` is written; if it had text, the heading would carry (OCR).
        val placeholder = header == "--- Page 2 --- [no text layer]"
        val ocr = header == "--- Page 2 (OCR) ---"
        assertTrue(result.content, placeholder || ocr)
        // Only page 2 of the three has no text layer, so this is not a scanned document.
        assertFalse("scanned flag", result.scanned)
    }

    private companion object {
        const val TAG = "PdfOcrInstrumentedTest"
    }
}
