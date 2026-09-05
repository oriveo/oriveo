package ai.oriveo.community.core.data.attachment

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Base64
import ai.oriveo.community.core.util.generateUuidString
import ai.oriveo.community.ui.component.computeSampleSize
import java.io.File
import kotlin.math.max
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext


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

    
    fun saveImage(data: ByteArray, mimeType: String = "image/jpeg", id: String = generateUuidString()): String {
        
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(data, 0, data.size, bounds)
        val rawMaxEdge = max(bounds.outWidth, bounds.outHeight)
        
        val sampleSize = computeSampleSize(rawMaxEdge, MAX_LONG_EDGE * 2)
        val decodeOptions = BitmapFactory.Options().apply {
            inSampleSize = sampleSize
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        val original = BitmapFactory.decodeByteArray(data, 0, data.size, decodeOptions) ?: return id

        
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

        return id
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
