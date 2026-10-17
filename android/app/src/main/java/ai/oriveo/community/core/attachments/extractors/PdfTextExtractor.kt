package ai.oriveo.community.core.attachments.extractors

import ai.oriveo.community.core.attachments.ExtractionDeadline
import ai.oriveo.community.core.attachments.ExtractionErrorCode
import ai.oriveo.community.core.attachments.ExtractionException
import com.tom_roush.pdfbox.io.MemoryUsageSetting
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.text.PDFTextStripper
import java.io.StringWriter
import java.io.Writer

/**
 * PDF text-layer extraction (attachment extraction spec section 12). D24 correction: the TomRoush AAR package name is com.tom_roush.*, not org.apache.*.
 * A scanned document (no text layer on any page and OCR recognized nothing) returns ExtractionErrorCode.ScannedPdf, leaving it to the D1 fallback logic.
 *
 * Memory discipline, because a few large PDFs imported together can fill the heap:
 * - The caller's ByteArray is handed to PDFBox directly. `PDDocument.load(InputStream)` copies
 *   the whole file into a scratch buffer, which puts the same PDF on the heap twice.
 * - Parsed stream bodies are not kept in main memory without bound: anything past
 *   [scratchMainMemoryBytes] spills to a temporary file.
 * - Output stops at the caller's limit (see [BoundedPdfTextWriter]) instead of assembling an
 *   entire book on the heap for a result that keeps only its first 200 KB.
 */
object PdfTextExtractor {

    /**
     * Initializes PDFBox's text engine classes before any file bytes are read.
     *
     * `PDFTextStripper`'s static initializer loads the whole glyph list. An Error thrown during
     * class initialization marks the class erroneous for the rest of the process, and every later
     * use is a `NoClassDefFoundError` with no way to recover in-process. The only thing that can
     * be done is to make initialization happen when the heap is emptiest: before the file is read
     * and while no other import is running.
     *
     * @throws ExtractionException the engine is unavailable in this process (already poisoned, or
     *   initialization cannot be allocated right now)
     */
    @Throws(ExtractionException::class)
    fun warmUp() {
        newStripper()
    }

    /**
     * Spec section 12: output per page "page marker + body", with a blank line between pages.
     *
     * @param maxOutputChars output character cap, accumulated across pages. The excess keeps only newline characters: the caller reports
     *   "how many lines the original has" by newline count, and the body would be truncated anyway, so it need not stay on the heap.
     * @param deadline section 14 deadline: checked at the start of each text-layer page (timeout when expired); the OCR phase is left to [ocr] (writes `[not processed]` when expired).
     * @param ocr pages without a text layer are handed to it for recognition (section 13); when null, those pages are written as `[no text layer]`.
     */
    @Throws(ExtractionException::class)
    fun extractPages(
        data: ByteArray,
        maxOutputChars: Int = Int.MAX_VALUE,
        deadline: ExtractionDeadline = ExtractionDeadline(),
        ocr: PdfPageOcr? = null,
    ): PdfText {
        // Initialize the engine before parsing the document: parsing eats a lot of heap, and ordering class initialization after it was exactly the poisoning scene of 3E.
        val stripper = newStripper()
        val doc: PDDocument
        try {
            doc = PDDocument.load(
                data,
                "",
                null,
                null,
                MemoryUsageSetting.setupMixed(scratchMainMemoryBytes()),
            )
        } catch (e: com.tom_roush.pdfbox.pdmodel.encryption.InvalidPasswordException) {
            // Section 12: only a document that cannot be opened with an empty password (needs a user password) counts as encrypted; one with only an owner password is extracted as usual,
            // neither isEncrypted nor copy permissions is used as the criterion.
            throw ExtractionException(ExtractionErrorCode.EncryptedPdf, e.message)
        } catch (e: Exception) {
            throw ExtractionException(ExtractionErrorCode.CorruptedFile, e.message)
        }
        // Opening the document is a single uninterruptible call; check once after it returns.
        deadline.check()

        // Round one: text layer. Section 14 checks at the start of each page and reports a timeout when expired. The PDFBox document is closed at the end of this round, so it holds no heap during OCR rendering.
        val pages: Array<String?> = doc.use { document ->
            stripper.sortByPosition = true
            stripper.lineSeparator = "\n"
            val budget = PageTextBudget(maxOutputChars)
            Array(document.numberOfPages) { index ->
                deadline.check()
                pageText(stripper, document, index + 1).takeIf { it.isNotEmpty() }?.let(budget::keep)
            }
        }
        val pagesWithText = pages.count { it != null }

        // Round two: output in page order, pages without a text layer go to OCR. Section 13: when the deadline passes in the OCR phase no timeout is reported; the hook returns null and `[not processed]` is written.
        val writer = BoundedPdfTextWriter(maxOutputChars)
        var pagesWithOcrText = 0
        pages.forEachIndexed { index, pageText ->
            val pageNumber = index + 1
            if (pageNumber > 1) writer.write("\n\n")
            if (pageText != null) {
                writer.write("--- Page $pageNumber ---\n")
                writer.write(pageText)
                return@forEachIndexed
            }
            when (val recognized = ocr?.recognize(pageNumber, deadline)) {
                null -> writer.write("--- Page $pageNumber --- ${if (ocr == null) NO_TEXT_LAYER else NOT_PROCESSED}")
                else -> {
                    val text = normalizePageText(recognized)
                    if (text.isEmpty()) {
                        writer.write("--- Page $pageNumber --- $NO_TEXT_LAYER")
                    } else {
                        pagesWithOcrText += 1
                        writer.write("--- Page $pageNumber (OCR) ---\n")
                        writer.write(text)
                    }
                }
            }
        }
        if (pagesWithText == 0 && pagesWithOcrText == 0) {
            // No page has text and OCR recognized nothing -> scanned document; the D1 fallback is handled by AttachmentRouter
            throw ExtractionException(ExtractionErrorCode.ScannedPdf)
        }
        return PdfText(text = writer.text(), scanned = pagesWithText == 0)
    }

    /** For callers that only want text (skill reference file import, tests): equivalent to the body of [extractPages]. */
    @Throws(ExtractionException::class)
    fun extract(data: ByteArray, maxOutputChars: Int = Int.MAX_VALUE): String =
        extractPages(data, maxOutputChars).text

    /** Single-page text: PDFBox runs only this page, then normalization and ligature expansion per section 12. */
    private fun pageText(stripper: PDFTextStripper, document: PDDocument, pageNumber: Int): String {
        stripper.startPage = pageNumber
        stripper.endPage = pageNumber
        val page = StringWriter()
        stripper.writeText(document, page)
        return normalizePageText(page.toString())
    }

    /** Section 12: first section 3.1 normalization, then ligature expansion, finally map radical code points back to unified ideographs (see [unifyRadicals]). */
    internal fun normalizePageText(raw: String): String {
        var text = StructuredText.normalize(raw)
        LIGATURES.forEach { (ligature, expanded) -> text = text.replace(ligature, expanded) }
        return unifyRadicals(text)
    }

    /**
     * When a font's cmap points a radical code point and the identically shaped ideograph to the same glyph, the generator's ToUnicode often lands on the radical
     * (a Chinese PDF exported on macOS writes the characters for "two" and "page" as U+2F06 and U+2EDA), so what is read looks the same but cannot be searched.
     * Section 12: the Radicals Supplement (U+2E80-2EFF) and Kangxi Radicals (U+2F00-2FDF) are mapped back to unified ideographs per [radicalMap]; code points outside the table are left alone.
     */
    private fun unifyRadicals(text: String): String {
        if (text.none { it in '\u2E80'..'\u2FDF' }) return text
        val out = StringBuilder(text.length)
        var index = 0
        while (index < text.length) {
            val codePoint = text.codePointAt(index)
            out.appendCodePoint(radicalMap[codePoint] ?: codePoint)
            index += Character.charCount(codePoint)
        }
        return out.toString()
    }

    /** Radical code point -> unified ideograph (Unicode EquivalentUnifiedIdeograph, UCD 18.0; identical item by item to the fixture cjk-radicals.v1.json). */
    internal val radicalMap: Map<Int, Int> by lazy {
        val pairs = RADICAL_PAIRS
        HashMap<Int, Int>(pairs.size).apply {
            for (i in pairs.indices step 2) put(pairs[i], pairs[i + 1])
        }
    }

    // Laid out in pairs: radical code point, unified ideograph code point (328 pairs in total).
    private val RADICAL_PAIRS = intArrayOf(
        0x2E81, 0x5382, 0x2E82, 0x4E5B, 0x2E83, 0x4E5A, 0x2E84, 0x4E59, 0x2E85, 0x4EBB, 0x2E86, 0x5182,
        0x2E87, 0x20628, 0x2E88, 0x5200, 0x2E89, 0x5202, 0x2E8A, 0x535C, 0x2E8B, 0x353E, 0x2E8C, 0x5C0F,
        0x2E8D, 0x5C0F, 0x2E8E, 0x5140, 0x2E8F, 0x5C23, 0x2E90, 0x5C22, 0x2E91, 0x21BC2, 0x2E92, 0x5DF3,
        0x2E93, 0x5E7A, 0x2E94, 0x5F51, 0x2E95, 0x2B739, 0x2E96, 0x5FC4, 0x2E97, 0x5FC3, 0x2E98, 0x624C,
        0x2E99, 0x6535, 0x2E9B, 0x65E1, 0x2E9C, 0x65E5, 0x2E9D, 0x6708, 0x2E9E, 0x6B7A, 0x2E9F, 0x6BCD,
        0x2EA0, 0x6C11, 0x2EA1, 0x6C35, 0x2EA2, 0x6C3A, 0x2EA3, 0x706C, 0x2EA4, 0x722B, 0x2EA5, 0x722B,
        0x2EA6, 0x4E2C, 0x2EA7, 0x725B, 0x2EA8, 0x72AD, 0x2EA9, 0x738B, 0x2EAA, 0x24D14, 0x2EAB, 0x76EE,
        0x2EAC, 0x793A, 0x2EAD, 0x793B, 0x2EAE, 0x25AD7, 0x2EAF, 0x7CF9, 0x2EB0, 0x7E9F, 0x2EB1, 0x7F53,
        0x2EB2, 0x7F52, 0x2EB3, 0x34C1, 0x2EB4, 0x5197, 0x2EB5, 0x2626B, 0x2EB6, 0x7F8A, 0x2EB7, 0x2634C,
        0x2EB8, 0x2634B, 0x2EB9, 0x8002, 0x2EBA, 0x8080, 0x2EBB, 0x807F, 0x2EBC, 0x8089, 0x2EBD, 0x26951,
        0x2EBE, 0x8279, 0x2EBF, 0x8279, 0x2EC0, 0x8279, 0x2EC1, 0x864E, 0x2EC2, 0x8864, 0x2EC3, 0x8980,
        0x2EC4, 0x897F, 0x2EC5, 0x89C1, 0x2EC6, 0x89D2, 0x2EC7, 0x278B2, 0x2EC8, 0x8BA0, 0x2EC9, 0x8D1D,
        0x2ECA, 0x27FB7, 0x2ECB, 0x8F66, 0x2ECC, 0x8FB6, 0x2ECD, 0x8FB6, 0x2ECE, 0x8FB6, 0x2ECF, 0x9091,
        0x2ED0, 0x9485, 0x2ED1, 0x9577, 0x2ED2, 0x9578, 0x2ED3, 0x957F, 0x2ED4, 0x95E8, 0x2ED5, 0x28E0F,
        0x2ED6, 0x961D, 0x2ED7, 0x96E8, 0x2ED8, 0x9752, 0x2ED9, 0x97E6, 0x2EDA, 0x9875, 0x2EDB, 0x98CE,
        0x2EDC, 0x98DE, 0x2EDD, 0x98DF, 0x2EDE, 0x2967F, 0x2EDF, 0x98E0, 0x2EE0, 0x9963, 0x2EE1, 0x29810,
        0x2EE2, 0x9A6C, 0x2EE3, 0x9AA8, 0x2EE4, 0x9B3C, 0x2EE5, 0x9C7C, 0x2EE6, 0x9E1F, 0x2EE7, 0x5364,
        0x2EE8, 0x9EA6, 0x2EE9, 0x9EC4, 0x2EEA, 0x9EFE, 0x2EEB, 0x6589, 0x2EEC, 0x9F50, 0x2EED, 0x6B6F,
        0x2EEE, 0x9F7F, 0x2EEF, 0x7ADC, 0x2EF0, 0x9F99, 0x2EF1, 0x9F9C, 0x2EF2, 0x4E80, 0x2EF3, 0x9F9F,
        0x2F00, 0x4E00, 0x2F01, 0x4E28, 0x2F02, 0x4E36, 0x2F03, 0x4E3F, 0x2F04, 0x4E59, 0x2F05, 0x4E85,
        0x2F06, 0x4E8C, 0x2F07, 0x4EA0, 0x2F08, 0x4EBA, 0x2F09, 0x513F, 0x2F0A, 0x5165, 0x2F0B, 0x516B,
        0x2F0C, 0x5182, 0x2F0D, 0x5196, 0x2F0E, 0x51AB, 0x2F0F, 0x51E0, 0x2F10, 0x51F5, 0x2F11, 0x5200,
        0x2F12, 0x529B, 0x2F13, 0x52F9, 0x2F14, 0x5315, 0x2F15, 0x531A, 0x2F16, 0x5338, 0x2F17, 0x5341,
        0x2F18, 0x535C, 0x2F19, 0x5369, 0x2F1A, 0x5382, 0x2F1B, 0x53B6, 0x2F1C, 0x53C8, 0x2F1D, 0x53E3,
        0x2F1E, 0x56D7, 0x2F1F, 0x571F, 0x2F20, 0x58EB, 0x2F21, 0x5902, 0x2F22, 0x590A, 0x2F23, 0x5915,
        0x2F24, 0x5927, 0x2F25, 0x5973, 0x2F26, 0x5B50, 0x2F27, 0x5B80, 0x2F28, 0x5BF8, 0x2F29, 0x5C0F,
        0x2F2A, 0x5C22, 0x2F2B, 0x5C38, 0x2F2C, 0x5C6E, 0x2F2D, 0x5C71, 0x2F2E, 0x5DDB, 0x2F2F, 0x5DE5,
        0x2F30, 0x5DF1, 0x2F31, 0x5DFE, 0x2F32, 0x5E72, 0x2F33, 0x5E7A, 0x2F34, 0x5E7F, 0x2F35, 0x5EF4,
        0x2F36, 0x5EFE, 0x2F37, 0x5F0B, 0x2F38, 0x5F13, 0x2F39, 0x5F50, 0x2F3A, 0x5F61, 0x2F3B, 0x5F73,
        0x2F3C, 0x5FC3, 0x2F3D, 0x6208, 0x2F3E, 0x6236, 0x2F3F, 0x624B, 0x2F40, 0x652F, 0x2F41, 0x6534,
        0x2F42, 0x6587, 0x2F43, 0x6597, 0x2F44, 0x65A4, 0x2F45, 0x65B9, 0x2F46, 0x65E0, 0x2F47, 0x65E5,
        0x2F48, 0x66F0, 0x2F49, 0x6708, 0x2F4A, 0x6728, 0x2F4B, 0x6B20, 0x2F4C, 0x6B62, 0x2F4D, 0x6B79,
        0x2F4E, 0x6BB3, 0x2F4F, 0x6BCB, 0x2F50, 0x6BD4, 0x2F51, 0x6BDB, 0x2F52, 0x6C0F, 0x2F53, 0x6C14,
        0x2F54, 0x6C34, 0x2F55, 0x706B, 0x2F56, 0x722A, 0x2F57, 0x7236, 0x2F58, 0x723B, 0x2F59, 0x723F,
        0x2F5A, 0x7247, 0x2F5B, 0x7259, 0x2F5C, 0x725B, 0x2F5D, 0x72AC, 0x2F5E, 0x7384, 0x2F5F, 0x7389,
        0x2F60, 0x74DC, 0x2F61, 0x74E6, 0x2F62, 0x7518, 0x2F63, 0x751F, 0x2F64, 0x7528, 0x2F65, 0x7530,
        0x2F66, 0x758B, 0x2F67, 0x7592, 0x2F68, 0x7676, 0x2F69, 0x767D, 0x2F6A, 0x76AE, 0x2F6B, 0x76BF,
        0x2F6C, 0x76EE, 0x2F6D, 0x77DB, 0x2F6E, 0x77E2, 0x2F6F, 0x77F3, 0x2F70, 0x793A, 0x2F71, 0x79B8,
        0x2F72, 0x79BE, 0x2F73, 0x7A74, 0x2F74, 0x7ACB, 0x2F75, 0x7AF9, 0x2F76, 0x7C73, 0x2F77, 0x7CF8,
        0x2F78, 0x7F36, 0x2F79, 0x7F51, 0x2F7A, 0x7F8A, 0x2F7B, 0x7FBD, 0x2F7C, 0x8001, 0x2F7D, 0x800C,
        0x2F7E, 0x8012, 0x2F7F, 0x8033, 0x2F80, 0x807F, 0x2F81, 0x8089, 0x2F82, 0x81E3, 0x2F83, 0x81EA,
        0x2F84, 0x81F3, 0x2F85, 0x81FC, 0x2F86, 0x820C, 0x2F87, 0x821B, 0x2F88, 0x821F, 0x2F89, 0x826E,
        0x2F8A, 0x8272, 0x2F8B, 0x8278, 0x2F8C, 0x864D, 0x2F8D, 0x866B, 0x2F8E, 0x8840, 0x2F8F, 0x884C,
        0x2F90, 0x8863, 0x2F91, 0x897E, 0x2F92, 0x898B, 0x2F93, 0x89D2, 0x2F94, 0x8A00, 0x2F95, 0x8C37,
        0x2F96, 0x8C46, 0x2F97, 0x8C55, 0x2F98, 0x8C78, 0x2F99, 0x8C9D, 0x2F9A, 0x8D64, 0x2F9B, 0x8D70,
        0x2F9C, 0x8DB3, 0x2F9D, 0x8EAB, 0x2F9E, 0x8ECA, 0x2F9F, 0x8F9B, 0x2FA0, 0x8FB0, 0x2FA1, 0x8FB5,
        0x2FA2, 0x9091, 0x2FA3, 0x9149, 0x2FA4, 0x91C6, 0x2FA5, 0x91CC, 0x2FA6, 0x91D1, 0x2FA7, 0x9577,
        0x2FA8, 0x9580, 0x2FA9, 0x961C, 0x2FAA, 0x96B6, 0x2FAB, 0x96B9, 0x2FAC, 0x96E8, 0x2FAD, 0x9751,
        0x2FAE, 0x975E, 0x2FAF, 0x9762, 0x2FB0, 0x9769, 0x2FB1, 0x97CB, 0x2FB2, 0x97ED, 0x2FB3, 0x97F3,
        0x2FB4, 0x9801, 0x2FB5, 0x98A8, 0x2FB6, 0x98DB, 0x2FB7, 0x98DF, 0x2FB8, 0x9996, 0x2FB9, 0x9999,
        0x2FBA, 0x99AC, 0x2FBB, 0x9AA8, 0x2FBC, 0x9AD8, 0x2FBD, 0x9ADF, 0x2FBE, 0x9B25, 0x2FBF, 0x9B2F,
        0x2FC0, 0x9B32, 0x2FC1, 0x9B3C, 0x2FC2, 0x9B5A, 0x2FC3, 0x9CE5, 0x2FC4, 0x9E75, 0x2FC5, 0x9E7F,
        0x2FC6, 0x9EA5, 0x2FC7, 0x9EBB, 0x2FC8, 0x9EC3, 0x2FC9, 0x9ECD, 0x2FCA, 0x9ED1, 0x2FCB, 0x9EF9,
        0x2FCC, 0x9EFD, 0x2FCD, 0x9F0E, 0x2FCE, 0x9F13, 0x2FCF, 0x9F20, 0x2FD0, 0x9F3B, 0x2FD1, 0x9F4A,
        0x2FD2, 0x9F52, 0x2FD3, 0x9F8D, 0x2FD4, 0x9F9C, 0x2FD5, 0x9FA0,
    )

    private val LIGATURES = listOf(
        "\uFB00" to "ff", "\uFB01" to "fi", "\uFB02" to "fl", "\uFB03" to "ffi",
        "\uFB04" to "ffl", "\uFB05" to "st", "\uFB06" to "st",
    )

    private const val NO_TEXT_LAYER = "[no text layer]"
    private const val NOT_PROCESSED = "[not processed]"

    private fun newStripper(): PDFTextStripper =
        try {
            PDFTextStripper()
        } catch (e: LinkageError) {
            // Class initialization failed earlier, so this path is gone for the process. Report an
            // ordinary extraction failure rather than letting the Error escape and kill the app.
            throw ExtractionException(ExtractionErrorCode.ExtractionError, PDF_ENGINE_UNAVAILABLE)
        } catch (e: OutOfMemoryError) {
            throw ExtractionException(ExtractionErrorCode.ExtractionError, PDF_ENGINE_UNAVAILABLE)
        }

    internal const val PDF_ENGINE_UNAVAILABLE = "pdf_engine_unavailable"
}

/** Result of [PdfTextExtractor.extractPages]; [scanned] = no page has a text layer and the whole body comes from OCR (section 12). */
data class PdfText(val text: String, val scanned: Boolean)

/**
 * OCR extension point for pages without a text layer (attachment extraction spec section 13). The implementer holds the files needed for rendering
 * (e.g. the temp file used by PdfRenderer) itself; called per page, in page order.
 */
fun interface PdfPageOcr {
    /**
     * @param pageNumber 1-based page number
     * @return recognized text (lines joined with `\n` in reading order); empty string = recognition result is empty (writes `[no text layer]`);
     *   null = not processed (deadline reached or page cap exceeded, writes `[not processed]`).
     */
    fun recognize(pageNumber: Int, deadline: ExtractionDeadline): String?
}

private const val MIN_SCRATCH_MAIN_MEMORY_BYTES = 4L * 1024L * 1024L
private const val MAX_SCRATCH_MAIN_MEMORY_BYTES = 16L * 1024L * 1024L

/**
 * How much of PDFBox's parse buffer may stay on the heap: 1/16 of the heap, clamped to 4-16 MB.
 * The rest spills to a temporary file.
 */
internal fun scratchMainMemoryBytes(maxHeapBytes: Long = Runtime.getRuntime().maxMemory()): Long =
    (maxHeapBytes / 16L).coerceIn(MIN_SCRATCH_MAIN_MEMORY_BYTES, MAX_SCRATCH_MAIN_MEMORY_BYTES)

/**
 * Cap on page text staged in round one: the text of each page must be kept between the two rounds until output, but not so much that
 * a whole book piles up on the heap for output that takes only the first [maxChars] characters (ORIVEO-ANDROID-3E).
 *
 * Once the whole-page characters kept reach [maxChars], [BoundedPdfTextWriter] is necessarily already full when it writes these pages (what was written earlier is only more, never less),
 * so only newlines and "whether there is body text" matter: later pages are compressed to newlines plus a placeholder body character, and the output is character-for-character identical to keeping whole pages.
 */
internal class PageTextBudget(private val maxChars: Int) {
    private var kept = 0L

    fun keep(pageText: String): String {
        if (kept < maxChars) {
            kept += pageText.length
            return pageText
        }
        val compact = StringBuilder()
        var lastWasBody = false
        for (c in pageText) {
            if (c == '\n') {
                compact.append(c)
                lastWasBody = false
            } else if (!c.isWhitespace() && !lastWasBody) {
                compact.append('x')
                lastWasBody = true
            }
        }
        return compact.toString()
    }
}

/**
 * A Writer that keeps only the first [maxChars] characters; drops leading and trailing whitespace, equivalent to `trim()` on the full text.
 *
 * Past the limit the body is discarded but line breaks are kept: `FileTextExtractor.truncate`
 * reports the document's total line count from them, so that count stays correct while the heap
 * holds at most one extra character per line.
 */
internal class BoundedPdfTextWriter(private val maxChars: Int) : Writer() {
    private val buffer = StringBuilder()
    private var started = false

    /**
     * Whether any body (non-whitespace) was seen past the limit. If not, everything past the limit
     * was trailing whitespace and the result is the same as an untruncated one.
     */
    private var droppedBody = false

    /**
     * Line breaks kept past the limit since the last body character: the tail that `trim()` on the
     * full text would remove.
     */
    private var trailingLineBreaks = 0

    override fun write(cbuf: CharArray, off: Int, len: Int) {
        for (index in off until off + len) keep(cbuf[index])
    }

    override fun write(c: Int) = keep(c.toChar())

    private fun keep(c: Char) {
        if (!started) {
            if (c.isWhitespace()) return
            started = true
        }
        if (buffer.length < maxChars) {
            buffer.append(c)
            return
        }
        if (c == '\n') {
            buffer.append(c)
            trailingLineBreaks += 1
        } else if (!c.isWhitespace()) {
            droppedBody = true
            trailingLineBreaks = 0
        }
    }

    fun text(): String {
        if (!droppedBody) return buffer.toString().trimEnd()
        // Truncated: the line breaks in the middle account for the lines that follow, so only the
        // run at the very end is removed.
        return buffer.substring(0, buffer.length - trailingLineBreaks)
    }

    override fun flush() = Unit

    override fun close() = Unit
}
