package ai.oriveo.community.core.studio

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import ai.oriveo.community.core.data.attachment.applyExifOrientation
import ai.oriveo.community.core.data.attachment.exifOrientation
import java.io.ByteArrayOutputStream
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Re-encodes one reference image to fit the BYOK budget: EXIF orientation applied, long edge capped at
 * [StudioReferenceBudget.SHRINK_MAX_LONG_EDGE] (never upscaled), transparency flattened onto white,
 * JPEG at [StudioReferenceBudget.SHRINK_JPEG_QUALITY] without metadata.
 */
object StudioReferenceShrinker {
    /**
     * Returns the JPEG bytes and their mime, or null when [bytes] cannot be decoded or re-encoded (including
     * running out of memory). Runs on [Dispatchers.Default]. [mime] is the source type as declared by the
     * caller; decoding sniffs the bytes, so it is not needed here.
     */
    @Suppress("UNUSED_PARAMETER")
    suspend fun shrink(bytes: ByteArray, mime: String): Pair<ByteArray, String>? = withContext(Dispatchers.Default) {
        val bitmaps = mutableListOf<Bitmap>()
        fun track(bitmap: Bitmap): Bitmap = bitmap.also { if (bitmaps.none { b -> b === it }) bitmaps += it }
        try {
            encode(bytes, ::track)
        } catch (_: OutOfMemoryError) {
            null
        } catch (_: RuntimeException) {
            null
        } finally {
            bitmaps.forEach { it.recycle() }
        }
    }

    private fun encode(bytes: ByteArray, track: (Bitmap) -> Bitmap): Pair<ByteArray, String>? {
        val maxEdge = StudioReferenceBudget.SHRINK_MAX_LONG_EDGE
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        val rawWidth = bounds.outWidth
        val rawHeight = bounds.outHeight
        if (rawWidth <= 0 || rawHeight <= 0) return null

        val rawLong = max(rawWidth, rawHeight)
        val (targetWidth, targetHeight) = if (rawLong <= maxEdge) {
            rawWidth to rawHeight
        } else {
            val short = (min(rawWidth, rawHeight).toDouble() * maxEdge / rawLong).roundToInt().coerceAtLeast(1)
            if (rawWidth >= rawHeight) maxEdge to short else short to maxEdge
        }

        val decodeOptions = BitmapFactory.Options().apply {
            inSampleSize = sampleSizeKeepingLongEdge(rawLong, maxEdge)
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        val decoded = track(BitmapFactory.decodeByteArray(bytes, 0, bytes.size, decodeOptions) ?: return null)
        val scaled = track(
            if (decoded.width == targetWidth && decoded.height == targetHeight) {
                decoded
            } else {
                Bitmap.createScaledBitmap(decoded, targetWidth, targetHeight, true)
            },
        )
        val oriented = track(applyExifOrientation(scaled, exifOrientation(bytes)))

        val flattened = track(Bitmap.createBitmap(oriented.width, oriented.height, Bitmap.Config.ARGB_8888))
        Canvas(flattened).apply {
            drawColor(Color.WHITE)
            drawBitmap(oriented, 0f, 0f, null)
        }

        return ByteArrayOutputStream().use { out ->
            val quality = (StudioReferenceBudget.SHRINK_JPEG_QUALITY * 100).roundToInt()
            if (!flattened.compress(Bitmap.CompressFormat.JPEG, quality, out)) return null
            out.toByteArray() to StudioReferenceBudget.SHRINK_MIME
        }
    }

    /** Largest power-of-two sample size whose decoded long edge is still at least [targetLongEdge]. */
    private fun sampleSizeKeepingLongEdge(longEdge: Int, targetLongEdge: Int): Int {
        var sampleSize = 1
        while (longEdge / (sampleSize * 2) >= targetLongEdge) sampleSize *= 2
        return sampleSize
    }
}
