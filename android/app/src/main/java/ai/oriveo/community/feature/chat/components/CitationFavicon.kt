package ai.oriveo.community.feature.chat.components

import android.graphics.Bitmap
import android.util.LruCache
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import ai.oriveo.community.core.security.isSafeExternalUrl
import ai.oriveo.community.core.util.readBytesLimited
import ai.oriveo.community.feature.chat.mcp.McpServerIconStore
import ai.oriveo.community.ui.component.decodeSampledBitmap
import ai.oriveo.community.ui.theme.OriveoTheme
import java.io.File
import java.net.URI
import java.net.URL
import java.net.URLEncoder
import javax.net.ssl.HttpsURLConnection
import kotlin.math.max
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

// Site favicons for web citations, from the same Google s2 service Web uses, so all clients show the same icon.
// Provider-supplied favicon fields are ignored on purpose: some providers put a site name there.

/** Favicon address for a web citation; null for library sources and anything that is not a plain https link. */
internal fun citationFaviconUrl(rawUrl: String, source: String?): String? {
    if (source == "notion" || source == "google" || source == "mcp") return null
    if (!isSafeExternalUrl(rawUrl)) return null
    val host = runCatching { URI(rawUrl.trim()).host }.getOrNull()?.lowercase()?.takeIf { it.isNotBlank() } ?: return null
    val domain = host.removePrefix("www.")
    return "https://www.google.com/s2/favicons?domain=${URLEncoder.encode(domain, "UTF-8")}&sz=64"
}

/**
 * The s2 endpoint answers with a redirect to gstatic, so unlike server icons this follows redirects,
 * but only https ones (HttpsURLConnection never switches protocol) and checks where it ended up.
 * Unknown sites answer 404 with a generic globe; non-200 is treated as "no favicon" so our own placeholder stays.
 */
internal fun fetchCitationFavicon(url: String): ByteArray? {
    val connection = URL(url).openConnection() as? HttpsURLConnection ?: return null
    return try {
        connection.instanceFollowRedirects = true
        connection.connectTimeout = 10_000
        connection.readTimeout = 10_000
        connection.useCaches = false
        connection.setRequestProperty("Accept", "image/png,image/jpeg,image/webp")
        if (connection.responseCode != 200 || connection.url.protocol != "https") return null
        val declared = connection.contentLengthLong
        if (declared > McpServerIconStore.MAX_ICON_BYTES) return null
        connection.inputStream.use { it.readBytesLimited(McpServerIconStore.MAX_ICON_BYTES.toLong(), declared) }
    } finally {
        connection.disconnect()
    }
}

private object CitationFaviconMemoryCache {
    val cache = object : LruCache<String, Bitmap>(512) {
        override fun sizeOf(key: String, value: Bitmap): Int = max(1, value.byteCount / 1024)
    }
}

@Volatile private var faviconStore: McpServerIconStore? = null

private fun faviconStore(cacheDir: File): McpServerIconStore =
    faviconStore ?: synchronized(CitationFaviconMemoryCache) {
        faviconStore ?: McpServerIconStore(File(cacheDir, "citation-favicons"), fetch = ::fetchCitationFavicon)
            .also { faviconStore = it }
    }

/**
 * 16dp source icon slot shared by citation rows and search source rows: the site favicon when it loads,
 * otherwise the bare 14dp tertiary [fallback] icon with no fill behind it (matches iOS CitationRowView).
 */
@Composable
internal fun CitationSourceIcon(url: String, source: String?, fallback: ImageVector) {
    val colors = OriveoTheme.colors
    val faviconUrl = remember(url, source) { citationFaviconUrl(url, source) }
    // Keyed so a row that moves to another citation never keeps the previous bitmap.
    val favicon = key(faviconUrl) { rememberCitationFavicon(faviconUrl) }
    Box(modifier = Modifier.size(16.dp), contentAlignment = Alignment.Center) {
        val loaded = favicon
        if (loaded != null) {
            Image(
                bitmap = loaded.asImageBitmap(),
                contentDescription = null,
                contentScale = ContentScale.Fit,
                modifier = Modifier.size(16.dp).clip(RoundedCornerShape(3.dp)),
            )
        } else {
            Icon(
                imageVector = fallback,
                contentDescription = null,
                modifier = Modifier.size(14.dp),
                tint = colors.textTertiary,
            )
        }
    }
}

@Composable
private fun rememberCitationFavicon(faviconUrl: String?): Bitmap? {
    val context = LocalContext.current.applicationContext
    val edgePx = with(LocalDensity.current) { 16.dp.roundToPx() * 2 }
    val favicon by produceState(faviconUrl?.let { CitationFaviconMemoryCache.cache.get(it) }) {
        if (value != null || faviconUrl == null) return@produceState
        value = withContext(Dispatchers.IO) {
            val bytes = faviconStore(context.cacheDir).bytes(faviconUrl) ?: return@withContext null
            decodeSampledBitmap(bytes, edgePx, preferRgb565 = false)
                ?.also { CitationFaviconMemoryCache.cache.put(faviconUrl, it) }
        }
    }
    return favicon
}
