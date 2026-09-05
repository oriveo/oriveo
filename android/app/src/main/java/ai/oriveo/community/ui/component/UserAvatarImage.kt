package ai.oriveo.community.ui.component

import android.graphics.Bitmap
import android.util.LruCache
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.util.readBytesLimited
import ai.oriveo.community.ui.theme.OriveoTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlin.math.max
import org.koin.compose.koinInject
import java.net.URL

// The cache is bounded by bytes, not by entry count. An LruCache(20) sized by entries would happily
// hold twenty full-resolution images - a 1536px ARGB_8888 bitmap is about 9MB - and sit at a 180MB
// high-water mark. Avatars render at 72dp or less, so a sampled one is under 100KB and 2MB is plenty.
private const val AVATAR_CACHE_SIZE_KB = 2 * 1024
private const val MAX_REMOTE_AVATAR_BYTES = 5L * 1024L * 1024L
private val avatarCache: LruCache<String, Bitmap> = object : LruCache<String, Bitmap>(AVATAR_CACHE_SIZE_KB) {
    override fun sizeOf(key: String, value: Bitmap): Int = max(1, value.byteCount / 1024)
}

/**
 * Circular user avatar.
 *
 * Three sources are tried in order: an image already in the on-device attachment store, then the
 * avatar URL if one was supplied, and finally a coloured placeholder bearing the first initial.
 */
@Composable
fun UserAvatarImage(
    size: Dp,
    avatarURL: String?,
    avatarLocalID: String?,
    fallbackName: String,
    modifier: Modifier = Modifier,
) {
    val attachmentStore: AttachmentStore = koinInject()
    val cacheKey = avatarLocalID ?: avatarURL
    var bitmap by remember(avatarLocalID, avatarURL) {
        mutableStateOf(cacheKey?.let { avatarCache.get(it) })
    }
    var loadFailed by remember(avatarLocalID, avatarURL) { mutableStateOf(false) }

    // Sample to three times the rendered size, which covers the densest screens on the market.
    // A 40-72dp avatar therefore decodes to 120-216px rather than to whatever the source happens
    // to be.
    val maxDecodeEdgePx = with(LocalDensity.current) { (size.toPx() * 3f).toInt().coerceAtLeast(64) }

    LaunchedEffect(avatarLocalID, avatarURL, maxDecodeEdgePx) {
        // Already resolved from the cache; nothing to load.
        if (bitmap != null) return@LaunchedEffect
        loadFailed = false

        // Local store first, preferring the 120px thumbnail the store writes alongside each image so
        // the full-resolution original never has to be held in memory for a 40dp circle.
        if (!avatarLocalID.isNullOrBlank()) {
            val bytes = withContext(Dispatchers.IO) {
                attachmentStore.loadThumbnailBytes(avatarLocalID)
                    ?: attachmentStore.loadImageBytes(avatarLocalID)
            }
            if (bytes != null) {
                val decoded = withContext(Dispatchers.Default) {
                    decodeSampledBitmap(bytes, maxDecodeEdgePx)
                }
                if (decoded != null) {
                    avatarCache.put(avatarLocalID, decoded)
                    bitmap = decoded
                    return@LaunchedEffect
                }
            }
        }

        // Then the remote URL, sampled to the same target edge. readBytesLimited caps the download so
        // a wrong or hostile URL cannot stream an unbounded body into memory.
        if (!avatarURL.isNullOrBlank()) {
            try {
                val bytes = withContext(Dispatchers.IO) {
                    URL(avatarURL).openConnection().apply {
                        connectTimeout = 15_000
                        readTimeout = 15_000
                    }.getInputStream().use { it.readBytesLimited(MAX_REMOTE_AVATAR_BYTES) }
                }
                val decoded = withContext(Dispatchers.Default) {
                    decodeSampledBitmap(bytes, maxDecodeEdgePx)
                }
                if (decoded != null) {
                    avatarCache.put(avatarURL, decoded)
                    bitmap = decoded
                }
            } catch (_: Exception) {
                loadFailed = true
            }
        }
    }

    val loadedBitmap = bitmap
    // With no image and no name there is no initial to draw, so the generic silhouette is used
    // instead of a blank circle.
    val hasNothingToRender = avatarLocalID.isNullOrBlank() && avatarURL.isNullOrBlank() && fallbackName.isBlank()
    if (loadedBitmap != null) {
        Image(
            bitmap = loadedBitmap.asImageBitmap(),
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = modifier
                .size(size)
                .clip(CircleShape),
        )
    } else if (hasNothingToRender) {
        Image(
            painter = rememberBrandPainter(R.drawable.ic_guest_avatar, size),
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = modifier
                .size(size)
                .clip(CircleShape),
        )
    } else {
        val initial = fallbackName.ifBlank { "?" }.take(1).uppercase()
        Box(
            modifier = modifier
                .size(size)
                .clip(CircleShape)
                .background(
                    Brush.linearGradient(
                        // The placeholder gradient is built from the primary tokens, so it follows
                        // the theme into dark mode instead of carrying its own fixed colours.
                        colors = listOf(
                            OriveoTheme.colors.primary,
                            OriveoTheme.colors.primaryPressed,
                        ),
                    ),
                ),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = initial,
                color = Color.White,
                fontWeight = FontWeight.Bold,
                fontSize = (size.value * 0.4f).sp,
            )
        }
    }
}
