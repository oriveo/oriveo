package ai.oriveo.community.core.attachments

import ai.oriveo.community.core.attachments.extractors.EpubTextExtractor
import ai.oriveo.community.core.attachments.extractors.HtmlTextExtractor
import ai.oriveo.community.core.attachments.extractors.OdfTextExtractor
import ai.oriveo.community.core.attachments.extractors.OfficeTextExtractor
import ai.oriveo.community.core.attachments.extractors.PdfOcr
import ai.oriveo.community.core.attachments.extractors.PdfTextExtractor
import ai.oriveo.community.core.attachments.extractors.PlainTextExtractor
import ai.oriveo.community.core.attachments.extractors.RtfTextExtractor
import ai.oriveo.community.core.app.AppLanguageManager
import ai.oriveo.community.core.model.AIModel
import android.util.Log
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean

// MARK: - Output model

data class ExtractedText(
    val content: String,
    val totalLines: Int,
    val truncated: Boolean,
    val truncationReason: TruncationReason? = null,
    val sizeBytes: Int,
    /** Attachment extraction spec section 12: a PDF where no page has a text layer and the whole body comes from OCR. */
    val scanned: Boolean = false,
) {
    enum class TruncationReason { Lines, Bytes }
}

enum class ExtractionErrorCode(val raw: String) {
    EncryptedPdf("encrypted_pdf"),
    ScannedPdf("scanned_pdf"),
    PasswordProtectedOffice("password_protected_office"),  // D9
    CorruptedFile("corrupted_file"),
    UnsupportedFormat("unsupported_format"),
    FileTooLarge("file_too_large"),
    ExtractionTimeout("extraction_timeout"),               // D9
    ExtractionError("extraction_error"),
}

class ExtractionException(
    val code: ExtractionErrorCode,
    val underlying: String? = null,
) : Exception("[${code.raw}] ${underlying ?: ""}")

/** Where the file extraction was started from (file picker, drag and drop, paste). */
enum class ExtractionSource(val rawValue: String) {
    FilePicker("file"),
    DragDrop("drag_drop"),
    Paste("paste"),
}

// MARK: - Limits (Spec section 2.2, after the D16/D17 revision)

/**
 * FileExtractionLimits - client defaults + the merged result of per-model override (D14).
 * At call time use [FileExtractionLimits.resolve] to get values for the current model.
 */
data class FileExtractionLimits(
    val maxLines: Int,
    val maxBytes: Int,
    val totalCap: Int,           // total attachment cap per message (200KB of Chinese is ≈ 66K tokens worst case; DeepSeek 128K leaves 62K for chat history + output)
    val maxInputFileBytes: Long,
    val maxFiles: Int,           // D17 hard cap on multiple files (Lost in the Middle)
) {
    companion object {
        // for easy reference in tests
        const val MAX_BYTES = 204_800

        val DEFAULT = FileExtractionLimits(
            maxLines = 500,
            maxBytes = MAX_BYTES,                       // 200KB UTF-8 per file (2026Q2 mainstream model context >= 200K)
            totalCap = 204_800,                         // D16 revision -> 200KB total (Chinese worst case ≈ 66K tokens, DeepSeek 128K still leaves 62K)
            maxInputFileBytes = 50L * 1024L * 1024L,    // 50MB hard input cap
            maxFiles = 3,                               // D17 hard cap on multiple files
        )

        /**
         * Merge defaults with the current model's metadata override (D14/D23 send-time check).
         */
        fun resolve(model: AIModel?): FileExtractionLimits {
            val o = model?.attachmentExtraction ?: return DEFAULT
            return DEFAULT.copy(
                maxLines = o.maxLines ?: DEFAULT.maxLines,
                maxBytes = o.maxBytes ?: DEFAULT.maxBytes,
                totalCap = o.totalCap ?: DEFAULT.totalCap,
                maxInputFileBytes = o.maxInputFileBytes?.toLong() ?: DEFAULT.maxInputFileBytes,
                // The count cap is delivered per model; use the default when it is not delivered or not positive.
                maxFiles = o.maxAttachments?.takeIf { it > 0 } ?: DEFAULT.maxFiles,
            )
        }
    }
}

// MARK: - Type classification (attachment extraction spec section 2)

/** Categories of section 2; [raw] has the same name as the kind in the shared fixture classification. */
enum class ExtractionFileKind(val raw: String) {
    Legacy("legacy"),
    Pdf("pdf"),
    Epub("epub"),
    Html("html"),
    Rtf("rtf"),
    Docx("docx"),
    Xlsx("xlsx"),
    Pptx("pptx"),
    Odt("odt"),
    Ods("ods"),
    Odp("odp"),
    Text("text"),
    Unsupported("unsupported"),
}

/**
 * Single source of truth for the type list: entry decisions (picker, drag, paste) and extractors all call [classify], with no more separate copies.
 * Item-by-item comparison of the list with the shared fixture `supported-types.v1.json` is in ExtractionGoldenContractTest.
 */
object ExtractionFileTypes {
    class Category(val kind: ExtractionFileKind, val extensions: Set<String>, val mimes: Set<String>)

    /** Categories other than text, in the order of the section 2 table. */
    val categories: List<Category> = listOf(
        Category(
            ExtractionFileKind.Legacy,
            setOf("doc", "xls", "ppt", "pages", "numbers", "key"),
            setOf(
                "application/msword", "application/vnd.ms-excel", "application/vnd.ms-powerpoint",
                "application/vnd.apple.pages", "application/vnd.apple.numbers", "application/vnd.apple.keynote",
            ),
        ),
        Category(ExtractionFileKind.Pdf, setOf("pdf"), setOf("application/pdf")),
        Category(ExtractionFileKind.Epub, setOf("epub"), setOf("application/epub+zip")),
        Category(ExtractionFileKind.Html, setOf("html", "htm", "xhtml"), setOf("text/html", "application/xhtml+xml")),
        Category(ExtractionFileKind.Rtf, setOf("rtf"), setOf("application/rtf", "text/rtf")),
        Category(
            ExtractionFileKind.Docx,
            setOf("docx"),
            setOf("application/vnd.openxmlformats-officedocument.wordprocessingml.document"),
        ),
        Category(
            ExtractionFileKind.Xlsx,
            setOf("xlsx"),
            setOf("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"),
        ),
        Category(
            ExtractionFileKind.Pptx,
            setOf("pptx"),
            setOf("application/vnd.openxmlformats-officedocument.presentationml.presentation"),
        ),
        Category(ExtractionFileKind.Odt, setOf("odt"), setOf("application/vnd.oasis.opendocument.text")),
        Category(ExtractionFileKind.Ods, setOf("ods"), setOf("application/vnd.oasis.opendocument.spreadsheet")),
        Category(ExtractionFileKind.Odp, setOf("odp"), setOf("application/vnd.oasis.opendocument.presentation")),
    )

    val textExtensions: Set<String> = setOf(
        "txt", "text", "md", "markdown", "mdx", "rst", "adoc", "asciidoc", "org", "tex", "bib", "srt", "vtt",
        "json", "jsonl", "ndjson", "geojson", "ipynb", "csv", "tsv", "xml", "svg", "yaml", "yml", "toml", "ini",
        "cfg", "conf", "properties", "env", "log", "diff", "patch", "gitignore", "editorconfig",
        "py", "pyi", "js", "jsx", "ts", "tsx", "mjs", "cjs", "vue", "svelte", "astro",
        "go", "rs", "java", "kt", "kts", "scala", "groovy", "gradle", "swift", "m", "mm",
        "c", "h", "cpp", "hpp", "cc", "cs", "fs", "vb", "rb", "php", "pl", "pm", "lua", "dart", "r", "jl",
        "hs", "ml", "ex", "exs", "erl", "clj", "zig", "nim",
        "sh", "bash", "zsh", "fish", "ps1", "bat", "cmd", "sql", "graphql", "proto",
        "css", "scss", "sass", "less", "tf", "hcl", "cmake",
    )

    /** For a name with no extension (or only a single leading `.`), the whole file name is compared against this table first. */
    val textFilenames: Set<String> = setOf("dockerfile", "makefile", "license", "readme", "gitignore", "editorconfig")

    /** Text mimes in the list; any mime starting with text/ (except those classified above) also counts as text. */
    val textMimes: Set<String> = setOf(
        "text/plain", "text/markdown", "text/csv", "text/tab-separated-values", "text/xml", "text/css",
        "text/javascript", "text/x-yaml", "text/x-toml", "text/x-ini", "text/x-python", "text/x-go",
        "application/json", "application/xml", "application/x-yaml", "application/javascript",
        "application/typescript", "application/x-sh", "image/svg+xml",
    )

    private val kindByExtension: Map<String, ExtractionFileKind> =
        categories.flatMap { category -> category.extensions.map { it to category.kind } }.toMap() +
            textExtensions.associateWith { ExtractionFileKind.Text }

    /**
     * Section 2: if the extension is recognized, classify by extension; only if it is unknown or empty look at the mime.
     * For a file name with no `.`, or one starting with a single `.` (`.gitignore`), compare the whole file name first against
     * [textFilenames], then against the text extension list.
     */
    fun classify(fileName: String, mimeType: String?): ExtractionFileKind {
        val lastDot = fileName.lastIndexOf('.')
        val bareName = when {
            lastDot < 0 -> fileName
            lastDot == 0 -> fileName.substring(1)
            else -> null
        }
        if (bareName != null) {
            val name = bareName.lowercase(Locale.ROOT)
            if (name in textFilenames || name in textExtensions) return ExtractionFileKind.Text
        } else {
            kindByExtension[fileName.substring(lastDot + 1).lowercase(Locale.ROOT)]?.let { return it }
        }

        val mime = mimeType.orEmpty().substringBefore(';').trim().lowercase(Locale.ROOT)
        if (mime.isEmpty()) return ExtractionFileKind.Unsupported
        categories.firstOrNull { mime in it.mimes }?.let { return it.kind }
        return if (mime in textMimes || mime.startsWith("text/")) ExtractionFileKind.Text else ExtractionFileKind.Unsupported
    }
}

// MARK: - Deadline (attachment extraction spec section 14)

/**
 * A 30-second deadline for one extraction, timed by a monotonic clock (the clock is injectable, for tests).
 * Extractors call [check] at the start of each round of their own loops; an uninterruptible single call inside an engine is checked only after it returns.
 */
class ExtractionDeadline(
    private val budgetNanos: Long = DEFAULT_BUDGET_NANOS,
    private val nanoTime: () -> Long = System::nanoTime,
) {
    private val startedAt: Long = nanoTime()

    /** Elapsed time exceeds the deadline (equal to the deadline does not count as over). */
    val isExpired: Boolean
        get() = nanoTime() - startedAt > budgetNanos

    /** Nanoseconds left on the deadline (0 once expired); for engine calls that can only block with a timeout (OCR). */
    val remainingNanos: Long
        get() = (budgetNanos - (nanoTime() - startedAt)).coerceAtLeast(0L)

    @Throws(ExtractionException::class)
    fun check() {
        if (isExpired) throw ExtractionException(ExtractionErrorCode.ExtractionTimeout)
    }

    companion object {
        const val DEFAULT_BUDGET_NANOS: Long = 30_000_000_000L
    }
}

// MARK: - Unified entry

object FileTextExtractor {

    /**
     * Main entry.
     * @param limits truncation / input thresholds of the current model (D14/D23: callers should pass [FileExtractionLimits.resolve(activeModel)])
     * @param source where the extraction was started from (default file picker; drag-drop / paste callers override it)
     * @param uiLanguage UI language of attachment extraction spec section 1, only used for tie-breaking in encoding detection
     * @param pdfOcr section 13 scanned-document OCR; when null (pure-JVM tests, skill import) pages without a text layer are written as `[no text layer]`
     * @throws ExtractionException
     */
    @Throws(ExtractionException::class)
    fun extract(
        data: ByteArray,
        fileName: String,
        mimeType: String,
        limits: FileExtractionLimits = FileExtractionLimits.DEFAULT,
        source: ExtractionSource = ExtractionSource.FilePicker,
        uiLanguage: String = AppLanguageManager.extractionUiLanguage(),
        pdfOcr: PdfOcr? = null,
    ): ExtractedText {
        return extractGuarded(data, fileName, mimeType, limits, uiLanguage, pdfOcr)
    }

    /**
     * Failure boundary of extractors: **the only thing that leaves here is [ExtractionException]**.
     *
     * Extractors run third-party parsing libraries (PDFBox / SAX / jsoup) on arbitrary user files, and what can be thrown is far more than
     * `Exception`: running out of heap is [OutOfMemoryError], a class whose static initialization failed once gives [LinkageError]
     * (`NoClassDefFoundError`, ORIVEO-ANDROID-3E), and a malformed file nested too deep gives [StackOverflowError].
     * These are all `Error`s that the caller's `catch (Exception)` cannot catch - one attachment parse failure would kill the whole app.
     * All allocations used by extraction are local and reclaimed when the stack unwinds, so degrading to a single "cannot process this file" is safe.
     */
    @Throws(ExtractionException::class)
    private fun extractGuarded(
        data: ByteArray,
        fileName: String,
        mimeType: String,
        limits: FileExtractionLimits,
        uiLanguage: String,
        pdfOcr: PdfOcr?,
    ): ExtractedText = guardExtraction(mimeType) { extractInner(data, fileName, mimeType, limits, uiLanguage, pdfOcr) }

    /** The boundary itself of [extractGuarded], a separate function so tests can feed in each kind of Error. */
    @Throws(ExtractionException::class)
    internal fun <T> guardExtraction(mimeType: String, block: () -> T): T =
        try {
            block()
        } catch (e: ExtractionException) {
            throw e
        } catch (e: kotlin.coroutines.cancellation.CancellationException) {
            throw e
        } catch (e: Exception) {
            // SAXException / ZipException / IllegalArgumentException etc. thrown by parsing libraries on malformed input.
            throw ExtractionException(ExtractionErrorCode.CorruptedFile, e.javaClass.simpleName)
        } catch (e: OutOfMemoryError) {
            throw ExtractionException(ExtractionErrorCode.ExtractionError, "out_of_memory")
        } catch (e: StackOverflowError) {
            throw ExtractionException(ExtractionErrorCode.CorruptedFile, "stack_overflow")
        } catch (e: LinkageError) {
            // A parser class is unusable for the rest of this process. The import still degrades
            // to an ordinary failure, but the cause is worth one log line: every later file of
            // this type will fail the same way, so it is logged once rather than per file.
            if (linkageFailureLogged.compareAndSet(false, true)) {
                Log.w(TAG, "Extraction engine unavailable for $mimeType", e)
            }
            throw ExtractionException(ExtractionErrorCode.ExtractionError, e.javaClass.simpleName)
        }

    private val linkageFailureLogged = AtomicBoolean(false)
    private const val TAG = "FileTextExtractor"

    /**
     * Text of the whole PDF, not truncated - for callers that store the full text as a knowledge file (skill reference file import).
     * Goes through the same failure boundary as [extract].
     */
    @Throws(ExtractionException::class)
    fun extractPdfText(data: ByteArray): String = extractPdfText(data) { PdfTextExtractor.extract(it) }

    internal fun extractPdfText(data: ByteArray, parse: (ByteArray) -> String): String =
        guardExtraction("application/pdf") { parse(data) }

    /** The actual extraction logic */
    @Throws(ExtractionException::class)
    private fun extractInner(
        data: ByteArray,
        fileName: String,
        mimeType: String,
        limits: FileExtractionLimits,
        uiLanguage: String,
        pdfOcr: PdfOcr?,
    ): ExtractedText {
        // D23 send-time file size check (uses the model override's maxInputFileBytes, not a hard-coded 50MB)
        if (data.size.toLong() > limits.maxInputFileBytes) {
            throw ExtractionException(ExtractionErrorCode.FileTooLarge)
        }

        val kind = ExtractionFileTypes.classify(fileName, mimeType)
        // Spec section 14: the 30-second deadline starts counting here, handed to looping extractors to check at the start of each round.
        val deadline = ExtractionDeadline()
        var scanned = false
        val raw: String = when (kind) {
            // The output cap is 1 more than maxBytes: the truncate below can still see "exceeded" and give the same truncation result as the full text.
            ExtractionFileKind.Pdf -> pdfOcr?.open(data).let { ocr ->
                try {
                    PdfTextExtractor.extractPages(
                        data,
                        maxOutputChars = (limits.maxBytes.toLong() + 1L).coerceAtMost(Int.MAX_VALUE.toLong()).toInt(),
                        deadline = deadline,
                        ocr = ocr,
                    ).also { scanned = it.scanned }.text
                } finally {
                    ocr?.close()
                }
            }
            ExtractionFileKind.Epub -> EpubTextExtractor.extract(data, uiLanguage, deadline)
            ExtractionFileKind.Html -> HtmlTextExtractor.extract(data, uiLanguage)
            ExtractionFileKind.Rtf -> RtfTextExtractor.extract(data, deadline)
            // Pass the extension by category name: files recognized only by mime (no extension) also go to the matching parser.
            ExtractionFileKind.Docx, ExtractionFileKind.Xlsx, ExtractionFileKind.Pptx ->
                OfficeTextExtractor.extractText(data, kind.raw, deadline)
                    ?: throw ExtractionException(ExtractionErrorCode.UnsupportedFormat)
            ExtractionFileKind.Odt, ExtractionFileKind.Ods, ExtractionFileKind.Odp ->
                OdfTextExtractor.extract(data, kind.raw, deadline)
            ExtractionFileKind.Text -> PlainTextExtractor.extract(data, uiLanguage)
            // Legacy formats should be blocked at the entry (section 2); even if one gets here it is not extracted, and no new error code is added for the model to see.
            ExtractionFileKind.Legacy, ExtractionFileKind.Unsupported ->
                throw ExtractionException(ExtractionErrorCode.UnsupportedFormat)
        }

        val result = truncate(raw, data.size, limits)
        return if (scanned) result.copy(scanned = true) else result
    }

    fun truncate(
        raw: String,
        sizeBytes: Int,
        limits: FileExtractionLimits = FileExtractionLimits.DEFAULT,
    ): ExtractedText {
        // Do not split the full text into a line table: a 25MB log would first put a whole line-by-line copy on the heap, while only the first maxLines lines are needed here.
        val totalLines = raw.count { it == '\n' } + 1

        var pickedLines = raw.splitToSequence("\n").take(limits.maxLines).toList()
        var truncated = false
        var reason: ExtractedText.TruncationReason? = null

        if (totalLines > limits.maxLines) {
            truncated = true
            reason = ExtractedText.TruncationReason.Lines
        }

        var joined = pickedLines.joinToString("\n")
        if (joined.toByteArray(Charsets.UTF_8).size > limits.maxBytes) {
            // Binary search for the most lines that fit
            var lo = 0
            var hi = pickedLines.size
            while (lo < hi) {
                val mid = (lo + hi + 1) / 2
                val candidate = pickedLines.take(mid).joinToString("\n")
                if (candidate.toByteArray(Charsets.UTF_8).size <= limits.maxBytes) {
                    lo = mid
                } else {
                    hi = mid - 1
                }
            }
            if (lo == 0) {
                // The first line alone does not fit (single-line JSON, a log with no line breaks): truncating by line would give empty content,
                // so keep the beginning within the line at a character boundary instead.
                joined = utf8Prefix(pickedLines.firstOrNull().orEmpty(), limits.maxBytes)
            } else {
                pickedLines = pickedLines.take(lo)
                // D17: logical separator fallback (XLSX sheet / PPTX slide)
                pickedLines = alignToLogicalBoundary(pickedLines)
                joined = pickedLines.joinToString("\n")
            }
            truncated = true
            if (reason == null) reason = ExtractedText.TruncationReason.Bytes
        }

        return ExtractedText(
            content = joined,
            totalLines = totalLines,
            truncated = truncated,
            truncationReason = reason,
            sizeBytes = sizeBytes,
        )
    }

    /** The longest prefix of [text] within [maxBytes] UTF-8 bytes, without splitting a character (including surrogate pairs). */
    private fun utf8Prefix(text: String, maxBytes: Int): String {
        var bytes = 0
        var index = 0
        while (index < text.length) {
            val codePoint = text.codePointAt(index)
            val width = when {
                codePoint < 0x80 -> 1
                codePoint < 0x800 -> 2
                codePoint < 0x10000 -> 3
                else -> 4
            }
            if (bytes + width > maxBytes) break
            bytes += width
            index += Character.charCount(codePoint)
        }
        return text.substring(0, index)
    }

    /**
     * Attachment extraction spec section 3.4: after truncating to whole lines that fit, look back at most 50 lines; on hitting a heading line (`^#{1,6} `)
     * or a page marker (`^--- Page `), cut before that line, so a section's heading is not left at the end while its body is cut off.
     */
    private fun alignToLogicalBoundary(lines: List<String>): List<String> {
        val lookbackMax = 50
        // Section 3.4: when the hit is the first line of the kept part (the result would be an empty body), do not align, so the look-back never reaches index 0.
        for (i in (lines.size - 1) downTo maxOf(1, lines.size - lookbackMax)) {
            val line = lines[i]
            if (sectionStart.containsMatchIn(line) || line.startsWith("--- Page ")) {
                return lines.take(i)
            }
        }
        return lines
    }

    private val sectionStart = Regex("^#{1,6} ")
}
