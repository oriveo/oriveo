package ai.oriveo.community.core.attachments.extractors

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
import com.google.mlkit.vision.text.devanagari.DevanagariTextRecognizerOptions
import com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions
import com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions
import ai.oriveo.community.core.attachments.ExtractionDeadline
import java.io.Closeable
import java.io.File
import java.util.Locale
import java.util.concurrent.TimeUnit
import kotlin.math.max
import kotlin.math.roundToInt

/** Recognizers for spec section 13. The Chinese recognizer is bundled (it also reads Latin letters); the rest come from Play services. */
enum class OcrScript { Chinese, Japanese, Korean, Devanagari }

/** Page rendering + recognition engine: the real implementation is [MlKitPdfOcrEngine]; pure-JVM unit tests pass a fake engine. */
fun interface PdfOcrEngine {
    /** Opens a PDF for page-by-page rendering; throws if it cannot be opened (pages of this file not handled are written as `[not processed]`). */
    fun open(data: ByteArray): PdfOcrDocument
}

/** An opened PDF. Called in page order, rendering only one page at a time. */
interface PdfOcrDocument : Closeable {
    /**
     * Renders page [pageIndex] (0-based) and recognizes it with the [script] recognizer.
     * @param timeoutNanos how long this page may wait at most (remaining deadline)
     * @return lines joined with `\n` in the reading order given by the engine
     * @throws Exception recognizer unavailable (no Play services, model not downloaded), recognition failed, rendering failed, wait timed out
     */
    fun recognize(pageIndex: Int, script: OcrScript, timeoutNanos: Long): String
}

/**
 * Scanned-document OCR (section 13): for pages without a text layer, at most the first [MAX_PAGES] pages are processed, sharing the section 14 deadline with extraction;
 * pages past the deadline or beyond the page cap return null (`[not processed]`) and do not report a timeout.
 *
 * @param uiLanguage UI language (BCP 47), only used to pick the recognizer; unlike the one for encoding detection, `hi` must be recognized here.
 */
class PdfOcr(
    private val engine: PdfOcrEngine,
    private val uiLanguage: () -> String = { Locale.getDefault().toLanguageTag() },
) {
    /** Starts a session for one PDF. The engine is opened only when the first page needs recognition (a PDF with a text layer writes no temp file). */
    fun open(data: ByteArray): PdfOcrSession = PdfOcrSession(engine, data, scriptFor(uiLanguage()))

    companion object {
        const val MAX_PAGES = 50

        /** Section 13: UI language `ja` / `ko` / `hi` use the matching recognizer, all others use the Chinese recognizer. */
        fun scriptFor(languageTag: String): OcrScript =
            when (languageTag.substringBefore('-').substringBefore('_').lowercase(Locale.ROOT)) {
                "ja" -> OcrScript.Japanese
                "ko" -> OcrScript.Korean
                "hi" -> OcrScript.Devanagari
                else -> OcrScript.Chinese
            }
    }
}

/** The OCR session of one PDF, handed to [PdfTextExtractor.extractPages] as its [PdfPageOcr]; call [close] when done. */
class PdfOcrSession internal constructor(
    private val engine: PdfOcrEngine,
    private val data: ByteArray,
    preferred: OcrScript,
) : PdfPageOcr, Closeable {
    private var document: PdfOcrDocument? = null
    private var openFailed = false

    /** The recognizer in use; if the preferred one is unavailable, fall back to Chinese, and later pages do not retry the preferred one. */
    var script: OcrScript = preferred
        private set

    override fun recognize(pageNumber: Int, deadline: ExtractionDeadline): String? {
        if (pageNumber > PdfOcr.MAX_PAGES || deadline.isExpired) return null
        val doc = document() ?: return null
        if (script != OcrScript.Chinese) {
            val recognized = attempt { doc.recognize(pageNumber - 1, script, deadline.remainingNanos) }
            if (recognized != null) return recognized
            // Section 13: if the matching recognizer is unavailable, fall back to the Chinese recognizer without reporting an error.
            script = OcrScript.Chinese
            if (deadline.isExpired) return null
        }
        return attempt { doc.recognize(pageNumber - 1, OcrScript.Chinese, deadline.remainingNanos) }
    }

    private fun document(): PdfOcrDocument? {
        if (openFailed) return null
        document?.let { return it }
        return attempt { engine.open(data) }?.also { document = it } ?: run {
            openFailed = true
            null
        }
    }

    override fun close() {
        attempt { document?.close() }
        document = null
    }

    /** A recognition failure does not fail the whole extraction: this page is written as "not processed". */
    private inline fun <T> attempt(block: () -> T): T? =
        try {
            block()
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
            null
        } catch (e: Exception) {
            null
        }
}

/**
 * ML Kit Text Recognition v2 + `android.graphics.pdf.PdfRenderer` (section 13).
 *
 * Recognition blocks on [Tasks.await] and must be called on a background thread (it throws on the main thread): the only caller
 * `AttachmentProcessor` runs extraction in `Dispatchers.IO`.
 */
class MlKitPdfOcrEngine(private val context: Context) : PdfOcrEngine {
    override fun open(data: ByteArray): PdfOcrDocument {
        // PdfRenderer only accepts a file descriptor: the bytes are written to a temp file in the cache directory and deleted when the session closes.
        val file = File.createTempFile("ocr-", ".pdf", context.cacheDir)
        try {
            file.writeBytes(data)
            val descriptor = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
            val renderer = try {
                PdfRenderer(descriptor)
            } catch (e: Exception) {
                descriptor.close()
                throw e
            }
            return MlKitPdfOcrDocument(file, renderer)
        } catch (e: Throwable) {
            file.delete()
            throw e
        }
    }
}

private class MlKitPdfOcrDocument(
    private val file: File,
    private val renderer: PdfRenderer,
) : PdfOcrDocument {
    private val recognizers = HashMap<OcrScript, TextRecognizer>()

    override fun recognize(pageIndex: Int, script: OcrScript, timeoutNanos: Long): String {
        val recognizer = recognizers.getOrPut(script) { TextRecognition.getClient(options(script)) }
        val bitmap = render(pageIndex)
        val task = recognizer.process(InputImage.fromBitmap(bitmap, 0))
        val text = Tasks.await(task, max(timeoutNanos, 1L), TimeUnit.NANOSECONDS)
        // A recognition that timed out may still be reading the bitmap; recycle it only after the task finishes.
        bitmap.recycle()
        return text.textBlocks.flatMap { it.lines }.joinToString("\n") { it.text }
    }

    /** A white-background bitmap with long side [LONG_SIDE_PX] (PdfRenderer does not paint a background). */
    private fun render(pageIndex: Int): Bitmap {
        val page = renderer.openPage(pageIndex)
        try {
            val scale = LONG_SIDE_PX.toFloat() / max(max(page.width, page.height), 1)
            val width = max((page.width * scale).roundToInt(), 1)
            val height = max((page.height * scale).roundToInt(), 1)
            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            bitmap.eraseColor(Color.WHITE)
            page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
            return bitmap
        } finally {
            page.close()
        }
    }

    override fun close() {
        recognizers.values.forEach { runCatching { it.close() } }
        recognizers.clear()
        runCatching { renderer.close() }
        file.delete()
    }

    private fun options(script: OcrScript) = when (script) {
        OcrScript.Chinese -> ChineseTextRecognizerOptions.Builder().build()
        OcrScript.Japanese -> JapaneseTextRecognizerOptions.Builder().build()
        OcrScript.Korean -> KoreanTextRecognizerOptions.Builder().build()
        OcrScript.Devanagari -> DevanagariTextRecognizerOptions.Builder().build()
    }

    private companion object {
        const val LONG_SIDE_PX = 2000
    }
}
