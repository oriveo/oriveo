package ai.oriveo.community.ui.component

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Base64
import android.util.LruCache
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlin.math.max

private const val THUMBNAIL_CACHE_SIZE_KB = 24 * 1024
private const val DISPLAY_CACHE_SIZE_KB = 48 * 1024
private const val DEFAULT_MAX_DECODE_EDGE_PX = 1024

private object AttachmentThumbnailMemoryCache : LruCache<String, Bitmap>(THUMBNAIL_CACHE_SIZE_KB) {
    override fun sizeOf(key: String, value: Bitmap): Int = max(1, value.byteCount / 1024)
}

private object AttachmentDisplayMemoryCache : LruCache<String, Bitmap>(DISPLAY_CACHE_SIZE_KB) {
    override fun sizeOf(key: String, value: Bitmap): Int = max(1, value.byteCount / 1024)
}

/** Which of an image attachment's on-device payloads is worth decoding for a full-size view. */
enum class AttachmentImageDisplaySource {
    LocalOriginal,
    InlineOriginal,
    Thumbnail,
    None,
}

/**
 * Picks the best available payload for an image attachment, preferring the full original over the
 * small preview.
 *
 * [hasImage] is passed in rather than queried here so the decision stays pure and testable: the
 * original may be listed on the attachment but already evicted from the store on disk.
 */
fun resolveAttachmentDisplaySource(
    attachment: Attachment,
    hasImage: (String) -> Boolean,
): AttachmentImageDisplaySource {
    if (attachment.kind != AttachmentKind.Image) return AttachmentImageDisplaySource.None

    attachment.localImageId
        ?.takeIf { it.isNotBlank() && hasImage(it) }
        ?.let { return AttachmentImageDisplaySource.LocalOriginal }

    // A base64Data that starts with "http" is a URL the model handed back, not inline bytes, so it
    // would decode to nothing.
    if (attachment.base64Data?.let { it.isNotBlank() && !it.startsWith("http") } == true) {
        return AttachmentImageDisplaySource.InlineOriginal
    }

    if (!attachment.thumbnailBase64.isNullOrBlank() || !attachment.localImageId.isNullOrBlank()) {
        return AttachmentImageDisplaySource.Thumbnail
    }

    return AttachmentImageDisplaySource.None
}

@Composable
fun rememberAttachmentThumbnailBitmap(
    attachment: Attachment,
    maxDecodeEdgePx: Int = DEFAULT_MAX_DECODE_EDGE_PX,
): ImageBitmap? {
    val context = LocalContext.current.applicationContext
    val cacheKey = attachmentThumbnailCacheKey(attachment)
    val cached = AttachmentThumbnailMemoryCache.get(cacheKey)?.asImageBitmap()
    val bitmap by produceState<ImageBitmap?>(initialValue = cached, cacheKey, maxDecodeEdgePx) {
        if (value != null) return@produceState
        value = loadAttachmentThumbnailBitmap(
            context = context,
            attachment = attachment,
            cacheKey = cacheKey,
            maxDecodeEdgePx = maxDecodeEdgePx,
        )
    }
    return bitmap
}

@Composable
fun rememberAttachmentDisplayBitmap(
    attachment: Attachment,
    maxDecodeEdgePx: Int = DEFAULT_MAX_DECODE_EDGE_PX,
): ImageBitmap? {
    val context = LocalContext.current.applicationContext
    val cacheKey = attachmentDisplayCacheKey(attachment)
    val cached = AttachmentDisplayMemoryCache.get(cacheKey)?.asImageBitmap()
    val bitmap by produceState<ImageBitmap?>(initialValue = cached, cacheKey, maxDecodeEdgePx) {
        if (value != null) return@produceState
        value = loadAttachmentThumbnailBitmap(
            context = context,
            attachment = attachment,
            cacheKey = attachmentThumbnailCacheKey(attachment),
            maxDecodeEdgePx = maxDecodeEdgePx,
        )
        value = loadAttachmentDisplayBitmap(
            context = context,
            attachment = attachment,
            cacheKey = cacheKey,
            maxDecodeEdgePx = maxDecodeEdgePx,
        )
    }
    return bitmap
}

private suspend fun loadAttachmentThumbnailBitmap(
    context: Context,
    attachment: Attachment,
    cacheKey: String,
    maxDecodeEdgePx: Int,
): ImageBitmap? = withContext(Dispatchers.IO) {
    AttachmentThumbnailMemoryCache.get(cacheKey)?.let { return@withContext it.asImageBitmap() }

    val bytes = loadAttachmentThumbnailBytes(context, attachment) ?: return@withContext null
    val decoded = decodeSampledBitmap(bytes, maxDecodeEdgePx) ?: return@withContext null
    AttachmentThumbnailMemoryCache.put(cacheKey, decoded)
    decoded.asImageBitmap()
}

private suspend fun loadAttachmentDisplayBitmap(
    context: Context,
    attachment: Attachment,
    cacheKey: String,
    maxDecodeEdgePx: Int,
): ImageBitmap? = withContext(Dispatchers.IO) {
    AttachmentDisplayMemoryCache.get(cacheKey)?.let { return@withContext it.asImageBitmap() }

    val attachmentStore = AttachmentStore(context)
    val source = resolveAttachmentDisplaySource(attachment) { localImageId ->
        attachmentStore.hasImage(localImageId)
    }
    val bytes = when (source) {
        AttachmentImageDisplaySource.LocalOriginal ->
            attachment.localImageId?.let(attachmentStore::loadImageBytes)
        AttachmentImageDisplaySource.InlineOriginal ->
            attachment.base64Data
                ?.takeIf { it.isNotBlank() && !it.startsWith("http") }
                ?.let { base64 -> runCatching { Base64.decode(base64, Base64.DEFAULT) }.getOrNull() }
        AttachmentImageDisplaySource.Thumbnail ->
            loadAttachmentThumbnailBytes(context, attachment)
        AttachmentImageDisplaySource.None ->
            null
    }
    // The chosen payload can still fail to load if the store entry was evicted between the check and
    // the read, so the small preview remains the last resort.
    val displayBytes = bytes ?: loadAttachmentThumbnailBytes(context, attachment) ?: return@withContext null

    val decoded = decodeSampledBitmap(displayBytes, maxDecodeEdgePx) ?: return@withContext null
    AttachmentDisplayMemoryCache.put(cacheKey, decoded)
    decoded.asImageBitmap()
}

private fun loadAttachmentThumbnailBytes(
    context: Context,
    attachment: Attachment,
): ByteArray? {
    attachment.thumbnailBase64?.let { base64 ->
        runCatching { Base64.decode(base64, Base64.DEFAULT) }.getOrNull()?.let { return it }
    }

    attachment.localImageId?.let { localImageId ->
        runCatching { AttachmentStore(context).loadThumbnailBytes(localImageId) }
            .getOrNull()
            ?.let { return it }
    }

    val inlineBase64 = attachment.base64Data
        ?.takeIf { it.isNotBlank() && !it.startsWith("http") }
        ?: return null
    return runCatching { Base64.decode(inlineBase64, Base64.DEFAULT) }.getOrNull()
}

/**
 * Decodes bytes into a Bitmap sampled down to a target edge length, so a full-resolution camera
 * original (24, 48, even 100MP) never gets decoded at full size and blows the heap.
 *
 * Two passes: the first reads only the bounds via inJustDecodeBounds, which allocates nothing; from
 * those dimensions a power-of-two sampleSize is derived, and the second pass decodes straight to
 * roughly the target edge. BitmapFactory only honours powers of two, hence the doubling loop.
 *
 * The default inPreferredConfig is RGB_565, two bytes per pixel instead of the four ARGB_8888 uses.
 * That halves the memory for anything whose transparency and colour precision do not matter, which
 * covers thumbnails and avatars; the full-size viewer opts back into ARGB_8888.
 *
 * @param maxDecodeEdgePx target length of the longest edge; anything larger is sampled down near it
 * @param preferRgb565 true for previews and avatars, false where banding would be visible
 */
internal fun decodeSampledBitmap(
    bytes: ByteArray,
    maxDecodeEdgePx: Int,
    preferRgb565: Boolean = true,
): Bitmap? {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)

    val maxEdge = max(bounds.outWidth, bounds.outHeight)
    val sampleSize = computeSampleSize(maxEdge, maxDecodeEdgePx)
    val options = BitmapFactory.Options().apply {
        inSampleSize = sampleSize
        inPreferredConfig = if (preferRgb565) Bitmap.Config.RGB_565 else Bitmap.Config.ARGB_8888
    }
    return runCatching { BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options) }.getOrNull()
}

internal fun computeSampleSize(maxEdge: Int, targetMaxEdge: Int): Int {
    if (maxEdge <= 0 || maxEdge <= targetMaxEdge) return 1

    var sampleSize = 1
    while (maxEdge / sampleSize > targetMaxEdge) {
        sampleSize *= 2
    }
    return sampleSize
}

// String.length is O(1) where String.hashCode() is O(n), and an original image encoded as base64 can
// run to several megabytes: hashing it would mean a full pass over that string on every
// recomposition. attachment.id already identifies the attachment, so the length only has to separate
// the different payload paths of one attachment (thumbnail vs inline base64 vs stored original) and
// never has to be a content-level digest.
private fun attachmentThumbnailCacheKey(attachment: Attachment): String {
    val sourceKey = when {
        !attachment.thumbnailBase64.isNullOrBlank() -> "thumb:${attachment.thumbnailBase64.length}"
        !attachment.localImageId.isNullOrBlank() -> "local:${attachment.localImageId}"
        !attachment.base64Data.isNullOrBlank() && !attachment.base64Data.startsWith("http") ->
            "base64:${attachment.base64Data.length}"
        else -> "empty"
    }
    return "${attachment.id}:$sourceKey"
}

private fun attachmentDisplayCacheKey(attachment: Attachment): String {
    val sourceKey = listOf(
        attachment.localImageId.orEmpty(),
        attachment.thumbnailBase64?.length?.toString().orEmpty(),
        attachment.base64Data?.length?.toString().orEmpty(),
    ).joinToString(":")
    return "${attachment.id}:display:$sourceKey"
}
