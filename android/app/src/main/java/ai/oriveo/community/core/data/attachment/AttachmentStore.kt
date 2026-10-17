package ai.oriveo.community.core.data.attachment

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Base64
import ai.oriveo.community.core.util.generateUuidString
import ai.oriveo.community.ui.component.computeSampleSize
import java.io.ByteArrayOutputStream
import java.io.File
import kotlin.math.max
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Result of storing an image: an attachment's localImageId and mimeType both come from here, so the mimeType always describes the bytes on disk. */
data class StoredImage(val id: String, val mimeType: String)

class AttachmentStore(private val context: Context) {

    private val imageDir: File by lazy(LazyThreadSafetyMode.NONE) {
        File(context.filesDir, "attachments/images")
    }

    private val thumbnailDir: File by lazy(LazyThreadSafetyMode.NONE) {
        File(context.filesDir, "attachments/thumbnails")
    }

    private val blobDir: File by lazy(LazyThreadSafetyMode.NONE) {
        File(context.filesDir, "attachments/blobs")
    }

    companion object {
        private const val MAX_LONG_EDGE = 1536
        private const val THUMBNAIL_LONG_EDGE = 120
        private const val JPEG_QUALITY = 70
        private const val THUMBNAIL_QUALITY = 60
        private const val COMPRESSED_MIME_TYPE = "image/jpeg"

        // Only used when an original carries a rotation EXIF tag and must be re-encoded upright:
        // keeps it sharp while capping decode memory.
        private const val ORIGINAL_MAX_LONG_EDGE = 4096
        private const val ORIGINAL_REENCODE_QUALITY = 95

        private val SAFE_IMAGE_ID = Regex("^[A-Za-z0-9_-]+$")

        fun isSafeImageId(localImageId: String): Boolean = SAFE_IMAGE_ID.matches(localImageId)
    }

    private fun ensureImageDir(): File = imageDir.also {
        if (!it.exists()) {
            it.mkdirs()
        }
    }

    private fun ensureThumbnailDir(): File = thumbnailDir.also {
        if (!it.exists()) {
            it.mkdirs()
        }
    }

    private fun ensureBlobDir(): File = blobDir.also {
        if (!it.exists()) {
            it.mkdirs()
        }
    }

    private fun blobFile(id: String): File =
        if (isSafeImageId(id)) File(blobDir, id) else File(blobDir, ".invalid")

    private fun imageFile(localImageId: String): File =
        if (isSafeImageId(localImageId)) File(imageDir, "$localImageId.jpg") else File(imageDir, ".invalid")

    private fun thumbnailFile(localImageId: String): File =
        if (isSafeImageId(localImageId)) File(thumbnailDir, "$localImageId.jpg") else File(thumbnailDir, ".invalid")

    /**
     * Images the user sends to a model: rotated upright and shrunk to a 1536px long edge / JPEG 0.7
     * (the same cost budget on every platform). Only the photo picker and the avatar use this;
     * model-generated, synced and imported images go through [saveOriginalImage] so they are never
     * re-compressed. Not main-thread safe. Returns null, writing nothing, when the bytes don't decode.
     */
    fun saveCompressedImage(data: ByteArray, id: String = generateUuidString()): StoredImage? {

        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(data, 0, data.size, bounds)
        val rawMaxEdge = max(bounds.outWidth, bounds.outHeight)
        if (rawMaxEdge <= 0) return null

        val sampleSize = computeSampleSize(rawMaxEdge, MAX_LONG_EDGE * 2)
        val decodeOptions = BitmapFactory.Options().apply {
            inSampleSize = sampleSize
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        val decoded = BitmapFactory.decodeByteArray(data, 0, data.size, decodeOptions) ?: return null
        // Camera photos store pixels in sensor order and rely on the EXIF Orientation tag.
        // Re-encoding to JPEG drops EXIF, so rotate the pixels first; the written file carries
        // no orientation tag and viewers won't rotate it a second time.
        val original = applyExifOrientation(decoded, exifOrientation(data))
        if (original !== decoded) decoded.recycle()

        val scaled = scaleToFit(original, MAX_LONG_EDGE)
        File(ensureImageDir(), "$id.jpg").outputStream().use { out ->
            scaled.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, out)
        }
        if (scaled !== original) scaled.recycle()

        val thumb = scaleToFit(original, THUMBNAIL_LONG_EDGE)
        File(ensureThumbnailDir(), "$id.jpg").outputStream().use { out ->
            thumb.compress(Bitmap.CompressFormat.JPEG, THUMBNAIL_QUALITY, out)
        }
        if (thumb !== original) thumb.recycle()
        original.recycle()

        return StoredImage(id, COMPRESSED_MIME_TYPE)
    }

    /**
     * Finished images (model-generated, imported from a backup): the bytes are stored as-is and only a
     * thumbnail is generated, matching iOS `ImageStore.save` and the web `saveImage`. The MIME is the
     * format the decoder actually recognised; callers must copy it onto the attachment because
     * providers validate the bytes against it.
     *
     * Images on disk must be upright (the viewers decode without reading EXIF), so input carrying a
     * non-normal EXIF orientation is rotated and stored as a high-quality JPEG.
     * Not main-thread safe. Returns null, writing nothing, when the bytes don't decode.
     */
    fun saveOriginalImage(data: ByteArray, id: String = generateUuidString()): StoredImage? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(data, 0, data.size, bounds)
        val rawMaxEdge = max(bounds.outWidth, bounds.outHeight)
        val mimeType = bounds.outMimeType
        if (rawMaxEdge <= 0 || mimeType.isNullOrBlank()) return null

        if (exifOrientationMatrix(exifOrientation(data)) != null) {
            val upright = encodeUprightJpeg(data, rawMaxEdge) ?: return null
            return saveOriginalImage(upright, id)
        }

        val decodeOptions = BitmapFactory.Options().apply {
            inSampleSize = computeSampleSize(rawMaxEdge, THUMBNAIL_LONG_EDGE * 2)
        }
        val decoded = BitmapFactory.decodeByteArray(data, 0, data.size, decodeOptions) ?: return null
        val thumb = scaleToFit(decoded, THUMBNAIL_LONG_EDGE)
        if (thumb !== decoded) decoded.recycle()

        File(ensureImageDir(), "$id.jpg").writeBytes(data)
        File(ensureThumbnailDir(), "$id.jpg").outputStream().use { out ->
            thumb.compress(Bitmap.CompressFormat.JPEG, THUMBNAIL_QUALITY, out)
        }
        thumb.recycle()

        return StoredImage(id, mimeType)
    }

    private fun encodeUprightJpeg(data: ByteArray, rawMaxEdge: Int): ByteArray? {
        val decodeOptions = BitmapFactory.Options().apply {
            inSampleSize = computeSampleSize(rawMaxEdge, ORIGINAL_MAX_LONG_EDGE * 2)
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        val decoded = BitmapFactory.decodeByteArray(data, 0, data.size, decodeOptions) ?: return null
        val scaled = scaleToFit(decoded, ORIGINAL_MAX_LONG_EDGE)
        if (scaled !== decoded) decoded.recycle()
        val upright = applyExifOrientation(scaled, exifOrientation(data))
        if (upright !== scaled) scaled.recycle()
        return try {
            ByteArrayOutputStream().use { out ->
                if (!upright.compress(Bitmap.CompressFormat.JPEG, ORIGINAL_REENCODE_QUALITY, out)) return null
                out.toByteArray()
            }
        } finally {
            upright.recycle()
        }
    }

    fun loadImageBytes(localImageId: String): ByteArray? {
        val file = imageFile(localImageId)
        if (!file.exists()) return null
        return file.readBytes()
    }

    fun loadThumbnailBytes(localImageId: String): ByteArray? {
        val file = thumbnailFile(localImageId)
        if (!file.exists()) return null
        return file.readBytes()
    }

    fun saveImageRaw(localImageId: String, data: ByteArray) {
        require(isSafeImageId(localImageId)) { "unsafe localImageId rejected" }
        val file = File(ensureImageDir(), "$localImageId.jpg")
        file.writeBytes(data)
    }

    fun saveThumbnailRaw(localImageId: String, data: ByteArray) {
        require(isSafeImageId(localImageId)) { "unsafe localImageId rejected" }
        val file = File(ensureThumbnailDir(), "$localImageId.jpg")
        file.writeBytes(data)
    }

    suspend fun clearAll() = withContext(Dispatchers.IO) {
        imageDir.listFiles()?.forEach { it.delete() }
        thumbnailDir.listFiles()?.forEach { it.delete() }
    }

    fun hasImage(localImageId: String): Boolean = imageFile(localImageId).exists()

    fun imageSizeBytes(localImageId: String): Long {
        val file = imageFile(localImageId)
        return if (file.exists()) file.length() else 0L
    }

    fun loadBase64(localImageId: String): String? {
        val file = imageFile(localImageId)
        if (!file.exists()) return null
        return Base64.encodeToString(file.readBytes(), Base64.NO_WRAP)
    }

    fun loadThumbnailBase64(localImageId: String): String? {
        val file = thumbnailFile(localImageId)
        if (!file.exists()) return null
        return Base64.encodeToString(file.readBytes(), Base64.NO_WRAP)
    }

    fun delete(localImageId: String) {
        imageFile(localImageId).delete()
        thumbnailFile(localImageId).delete()
    }

    fun saveBlob(data: ByteArray, id: String = generateUuidString()): String {
        File(ensureBlobDir(), id).writeBytes(data)
        return id
    }

    fun loadBlobBytes(id: String): ByteArray? {
        val file = blobFile(id)
        if (!file.exists()) return null
        return file.readBytes()
    }

    fun loadBlobBase64(id: String): String? {
        val bytes = loadBlobBytes(id) ?: return null
        return Base64.encodeToString(bytes, Base64.NO_WRAP)
    }

    fun hasBlob(id: String): Boolean = blobFile(id).exists()

    fun blobSizeBytes(id: String): Long {
        val file = blobFile(id)
        return if (file.exists()) file.length() else 0L
    }

    fun saveBlobRaw(id: String, data: ByteArray) {
        require(isSafeImageId(id)) { "unsafe blob id rejected" }
        File(ensureBlobDir(), id).writeBytes(data)
    }

    fun deleteBlob(id: String) {
        blobFile(id).delete()
    }

    private fun scaleToFit(bitmap: Bitmap, maxEdge: Int): Bitmap {
        val w = bitmap.width
        val h = bitmap.height
        val longEdge = maxOf(w, h)
        if (longEdge <= maxEdge) return bitmap

        val scale = maxEdge.toFloat() / longEdge
        val newW = (w * scale).toInt()
        val newH = (h * scale).toInt()
        return Bitmap.createScaledBitmap(bitmap, newW, newH, true)
    }
}
