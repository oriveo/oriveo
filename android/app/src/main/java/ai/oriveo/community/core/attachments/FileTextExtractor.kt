package ai.oriveo.community.core.attachments

import ai.oriveo.community.core.attachments.extractors.EpubTextExtractor
import ai.oriveo.community.core.attachments.extractors.HtmlTextExtractor
import ai.oriveo.community.core.attachments.extractors.OdfTextExtractor
import ai.oriveo.community.core.attachments.extractors.OfficeTextExtractor
import ai.oriveo.community.core.attachments.extractors.PdfTextExtractor
import ai.oriveo.community.core.attachments.extractors.PlainTextExtractor
import ai.oriveo.community.core.attachments.extractors.RtfTextExtractor
import ai.oriveo.community.core.model.AIModel
import android.util.Log
import java.util.concurrent.atomic.AtomicBoolean

data class ExtractedText(
    val content: String,
    val totalLines: Int,
    val truncated: Boolean,
    val truncationReason: TruncationReason? = null,
    val sizeBytes: Int,
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

enum class ExtractionSource(val rawValue: String) {
    FilePicker("file"),
    DragDrop("drag_drop"),
    Paste("paste"),
}

data class FileExtractionLimits(
    val maxLines: Int,
    val maxBytes: Int,
    val totalCap: Int,
    val maxInputFileBytes: Long,
    val maxFiles: Int,
) {
    companion object {

        const val MAX_BYTES = 204_800

        val DEFAULT = FileExtractionLimits(
            maxLines = 500,
            maxBytes = MAX_BYTES,
            totalCap = 204_800,
            maxInputFileBytes = 50L * 1024L * 1024L,
            maxFiles = 3,
        )

        fun resolve(model: AIModel?): FileExtractionLimits {
            val o = model?.attachmentExtraction ?: return DEFAULT
            return DEFAULT.copy(
                maxLines = o.maxLines ?: DEFAULT.maxLines,
                maxBytes = o.maxBytes ?: DEFAULT.maxBytes,
                totalCap = o.totalCap ?: DEFAULT.totalCap,
                maxInputFileBytes = o.maxInputFileBytes?.toLong() ?: DEFAULT.maxInputFileBytes,

            )
        }
    }
}

object FileTextExtractor {

    val supportedMimes: Set<String> = setOf(
        "text/plain", "text/markdown", "text/csv", "text/tab-separated-values",
        "text/x-yaml", "text/x-toml", "text/x-ini",
        "application/json", "application/xml", "application/x-yaml",
        "text/html", "image/svg+xml",
        "application/pdf",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "application/vnd.oasis.opendocument.text",
        "application/vnd.oasis.opendocument.spreadsheet",
        "application/vnd.oasis.opendocument.presentation",
        "application/rtf", "text/rtf",
        "application/epub+zip",
    )

    val textExtensions: Set<String> = setOf(
        "txt", "md", "markdown", "json", "jsonl", "ndjson",
        "csv", "tsv", "xml", "yaml", "yml", "toml", "ini",
        "cfg", "conf", "log", "env", "gitignore", "editorconfig",
        "py", "js", "jsx", "ts", "tsx", "mjs", "cjs",
        "go", "rs", "java", "kt", "kts", "swift", "m", "mm",
        "c", "h", "cpp", "hpp", "cc", "cs", "rb", "php",
        "sh", "bash", "zsh", "ps1", "bat", "cmd", "sql",
        "r", "lua", "dart", "vue", "svelte",
        "scss", "sass", "less", "css",
        "gradle", "groovy", "proto", "graphql",
    )

    @Throws(ExtractionException::class)
    fun extract(
        data: ByteArray,
        fileName: String,
        mimeType: String,
        limits: FileExtractionLimits = FileExtractionLimits.DEFAULT,
        source: ExtractionSource = ExtractionSource.FilePicker,
    ): ExtractedText {
        return guardExtraction(mimeType) { extractInner(data, fileName, mimeType, limits) }
    }

    /**
     * The extractor's fault boundary: the only thing that leaves it is an [ExtractionException].
     *
     * Extractors run third-party parsers (PDFBox, SAX, jsoup) over arbitrary user files, and those
     * can throw far more than `Exception`: [OutOfMemoryError] when the heap runs out,
     * [LinkageError] (`NoClassDefFoundError`) once a class's static initializer has failed, and
     * [StackOverflowError] on deeply nested malformed input. These are `Error`s, so a caller's
     * `catch (Exception)` does not see them and one unreadable attachment would take the whole app
     * down. Every allocation made during extraction is local and is reclaimed when the stack
     * unwinds, so downgrading to "this file could not be processed" is safe.
     *
     * Kept as its own function so tests can feed each kind of failure through it.
     */
    @Throws(ExtractionException::class)
    internal fun <T> guardExtraction(mimeType: String, block: () -> T): T =
        try {
            block()
        } catch (e: ExtractionException) {
            throw e
        } catch (e: kotlin.coroutines.cancellation.CancellationException) {
            throw e
        } catch (e: Exception) {
            // What parsers throw on malformed input: SAXException, ZipException,
            // IllegalArgumentException and the like.
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
     * The whole text of a PDF, untruncated, for callers that store the full text as a knowledge
     * file (skill reference import). It goes through the same failure boundary as [extract].
     */
    @Throws(ExtractionException::class)
    fun extractPdfText(data: ByteArray): String = extractPdfText(data) { PdfTextExtractor.extract(it) }

    internal fun extractPdfText(data: ByteArray, parse: (ByteArray) -> String): String =
        guardExtraction("application/pdf") { parse(data) }

    @Throws(ExtractionException::class)
    private fun extractInner(
        data: ByteArray,
        fileName: String,
        mimeType: String,
        limits: FileExtractionLimits,
    ): ExtractedText {

        if (data.size.toLong() > limits.maxInputFileBytes) {
            throw ExtractionException(ExtractionErrorCode.FileTooLarge)
        }

        val ext = fileName.substringAfterLast('.', "").lowercase()
        val mime = mimeType.lowercase()

        val raw: String = when {
            // One character past maxBytes, so truncate() below still sees that the text ran over
            // and produces the same result it would for the full text.
            mime == "application/pdf" || ext == "pdf" ->
                PdfTextExtractor.extract(
                    data,
                    maxOutputChars = (limits.maxBytes.toLong() + 1L).coerceAtMost(Int.MAX_VALUE.toLong()).toInt(),
                )
            mime == "application/epub+zip" || ext == "epub" -> EpubTextExtractor.extract(data)
            mime == "text/html" || ext in setOf("html", "htm", "xhtml") -> HtmlTextExtractor.extract(data)
            mime == "application/rtf" || mime == "text/rtf" || ext == "rtf" -> RtfTextExtractor.extract(data)
            OfficeTextExtractor.isOfficeFile(ext) ||
                mime.startsWith("application/vnd.openxmlformats-officedocument.") -> {
                OfficeTextExtractor.extractText(data, ext)
                    ?: throw ExtractionException(ExtractionErrorCode.UnsupportedFormat)
            }
            ext in setOf("odt", "ods", "odp") ||
                mime.startsWith("application/vnd.oasis.opendocument.") -> {
                OdfTextExtractor.extract(data)
            }
            mime in supportedMimes || ext in textExtensions -> PlainTextExtractor.extract(data)
            else -> throw ExtractionException(ExtractionErrorCode.UnsupportedFormat)
        }

        return truncate(raw, data.size, limits)
    }

    fun truncate(
        raw: String,
        sizeBytes: Int,
        limits: FileExtractionLimits = FileExtractionLimits.DEFAULT,
    ): ExtractedText {
        // The full text is never split into a list of lines: for a 25 MB log that would put a
        // second, line-by-line copy on the heap when only the first maxLines are wanted.
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
            pickedLines = pickedLines.take(lo)

            pickedLines = alignToLogicalBoundary(pickedLines)
            joined = pickedLines.joinToString("\n")
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

    private fun alignToLogicalBoundary(lines: List<String>): List<String> {
        val patterns = listOf("===Sheet:", "===Slide ", "## ")
        val lookbackMax = 50
        for (i in (lines.size - 1) downTo maxOf(0, lines.size - lookbackMax)) {
            val line = lines[i]
            if (patterns.any { line.startsWith(it) }) {
                return lines.take(i)
            }
        }
        return lines
    }
}
