package ai.oriveo.community.core.attachments.extractors

import ai.oriveo.community.core.attachments.ExtractionErrorCode
import ai.oriveo.community.core.attachments.ExtractionException
import com.tom_roush.pdfbox.io.MemoryUsageSetting
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.text.PDFTextStripper
import java.io.Writer

/**
 * Extracts the text layer of a PDF. A scanned document (no text layer) is reported as
 * [ExtractionErrorCode.ScannedPdf] so the caller can fall back to sending the file itself.
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
     * @param maxOutputChars upper bound on output characters. Past it only line breaks are kept:
     *   the caller reports the document's total line count from them, and the body would be
     *   truncated away anyway, so it need not stay on the heap.
     */
    @Throws(ExtractionException::class)
    fun extract(data: ByteArray, maxOutputChars: Int = Int.MAX_VALUE): String {
        // Engine first, document second: parsing takes a large share of the heap, and initializing
        // the engine classes after it is exactly when that initialization fails for good.
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

            throw ExtractionException(ExtractionErrorCode.EncryptedPdf, e.message)
        } catch (e: Exception) {
            throw ExtractionException(ExtractionErrorCode.CorruptedFile, e.message)
        }

        doc.use { document ->
            if (document.isEncrypted) {
                throw ExtractionException(ExtractionErrorCode.EncryptedPdf)
            }
            stripper.sortByPosition = true
            val writer = BoundedPdfTextWriter(maxOutputChars)
            stripper.writeText(document, writer)
            val text = writer.text()
            if (text.isEmpty()) {

                throw ExtractionException(ExtractionErrorCode.ScannedPdf)
            }
            return text
        }
    }

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

private const val MIN_SCRATCH_MAIN_MEMORY_BYTES = 4L * 1024L * 1024L
private const val MAX_SCRATCH_MAIN_MEMORY_BYTES = 16L * 1024L * 1024L

/**
 * How much of PDFBox's parse buffer may stay on the heap: 1/16 of the heap, clamped to 4-16 MB.
 * The rest spills to a temporary file.
 */
internal fun scratchMainMemoryBytes(maxHeapBytes: Long = Runtime.getRuntime().maxMemory()): Long =
    (maxHeapBytes / 16L).coerceIn(MIN_SCRATCH_MAIN_MEMORY_BYTES, MAX_SCRATCH_MAIN_MEMORY_BYTES)

/**
 * A Writer that keeps only the first [maxChars] characters and drops leading and trailing
 * whitespace exactly as `trim()` on the full text would.
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
