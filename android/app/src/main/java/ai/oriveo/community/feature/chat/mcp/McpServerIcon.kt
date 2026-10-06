package ai.oriveo.community.feature.chat.mcp

import android.graphics.Bitmap
import android.util.LruCache
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.painterResource
import androidx.compose.runtime.key
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import ai.oriveo.community.core.mcp.McpOrigin
import ai.oriveo.community.core.mcp.McpBrandIcons
import ai.oriveo.community.core.mcp.mcpSha256Hex
import ai.oriveo.community.core.util.readBytesLimited
import ai.oriveo.community.ui.component.decodeSampledBitmap
import java.io.File
import java.net.URL
import java.util.concurrent.ConcurrentHashMap
import javax.net.ssl.HttpsURLConnection
import kotlin.math.max
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

// Server icon: when the server provides its own icon it is shown as is, with no outline and no backing plate; when there is none,
// it breaks the icon policy or fails to load, the initial tile (`McpServerTile`) is used. Shared by the chat-side tool panel / confirmation sheet / step detail and the management screens.
//
// The app has no image-loading library, so this fetches by itself: https only, no redirects, size-limited, with a small memory cache and a small disk cache.
// URLs passed in have already been through `McpServerIconPolicy` (same host, or parent / child domain).

/**
 * Disk cache and retrieval of icon bytes. [fetch] is injectable so tests stay off the network.
 */
internal class McpServerIconStore(
    private val directory: File,
    private val fetch: (url: String) -> ByteArray? = ::fetchMcpServerIcon,
    private val now: () -> Long = System::currentTimeMillis,
) {
    /** URLs that already failed in this process: do not hit the network again on every recomposition. */
    private val failed = ConcurrentHashMap.newKeySet<String>()

    private fun file(url: String) = File(directory, mcpSha256Hex(url).take(40))

    /** Raw icon bytes, or null when unavailable. No request when a fresh copy is on disk; a stale one is refetched, and kept in use if the refetch fails. */
    fun bytes(url: String): ByteArray? {
        if (!McpOrigin.isHttps(url)) return null
        val cached = file(url)
        val onDisk = runCatching { cached.takeIf { it.isFile }?.readBytes() }.getOrNull()?.takeIf { it.isNotEmpty() }
        if (onDisk != null && now() - cached.lastModified() < MAX_AGE_MILLIS) return onDisk
        if (url in failed) return onDisk
        val fresh = runCatching { fetch(url) }.getOrNull()?.takeIf { it.isNotEmpty() && it.size <= MAX_ICON_BYTES }
        if (fresh == null) {
            failed += url
            return onDisk
        }
        runCatching {
            directory.mkdirs()
            cached.writeBytes(fresh)
            cached.setLastModified(now())
            trim()
        }
        return fresh
    }

    /** Keeps only the most recent [MAX_FILES]. */
    private fun trim() {
        val files = directory.listFiles()?.filter { it.isFile } ?: return
        if (files.size <= MAX_FILES) return
        files.sortedBy { it.lastModified() }.take(files.size - MAX_FILES).forEach { it.delete() }
    }

    companion object {
        const val MAX_ICON_BYTES = 256 * 1024
        const val MAX_FILES = 40
        const val MAX_AGE_MILLIS = 7L * 24 * 60 * 60 * 1000
        const val DIRECTORY_NAME = "mcp-server-icons"
    }
}

/**
 * Fetches one icon: https only, no redirects (a redirect could take the request to a host the policy did not allow), no credentials
 * or cookies, and gives up beyond [McpServerIconStore.MAX_ICON_BYTES].
 */
internal fun fetchMcpServerIcon(url: String): ByteArray? {
    val connection = URL(url).openConnection() as? HttpsURLConnection ?: return null
    return try {
        connection.instanceFollowRedirects = false
        connection.connectTimeout = 10_000
        connection.readTimeout = 10_000
        connection.useCaches = false
        connection.setRequestProperty("Accept", "image/png,image/jpeg,image/webp")
        if (connection.responseCode != 200) return null
        val declared = connection.contentLengthLong
        if (declared > McpServerIconStore.MAX_ICON_BYTES) return null
        connection.inputStream.use { it.readBytesLimited(McpServerIconStore.MAX_ICON_BYTES.toLong(), declared) }
    } finally {
        connection.disconnect()
    }
}

/** Decoded icons (capped at about 1 MB in memory). */
internal object McpServerIconMemoryCache {
    private val cache = object : LruCache<String, Bitmap>(1024) {
        override fun sizeOf(key: String, value: Bitmap): Int = max(1, value.byteCount / 1024)
    }

    fun get(url: String): Bitmap? = cache.get(url)

    fun put(url: String, bitmap: Bitmap) {
        cache.put(url, bitmap)
    }

    fun clear() = cache.evictAll()
}

@Volatile private var sharedStore: McpServerIconStore? = null

/** Test only: swaps the process-wide icon store (production creates it lazily from the cache directory on the first fetch). */
@androidx.annotation.VisibleForTesting
internal fun setMcpServerIconStoreForTest(store: McpServerIconStore?) {
    sharedStore = store
}

private fun iconStore(cacheDir: File): McpServerIconStore =
    sharedStore ?: synchronized(McpServerIconMemoryCache) {
        sharedStore ?: McpServerIconStore(File(cacheDir, McpServerIconStore.DIRECTORY_NAME)).also { sharedStore = it }
    }

/**
 * The server's icon slot. Shows the initial tile when [iconUrl] is null or the icon cannot be fetched / decoded.
 */
@Composable
internal fun McpServerIcon(name: String, iconUrl: String?, size: Dp = 40.dp, modifier: Modifier = Modifier, serverUrl: String? = null) {
    val drawable = McpBrandIcons.drawable(name, serverUrl, isSystemInDarkTheme())
    val shape = RoundedCornerShape(size * 0.3f)
    if (drawable != null) {
        Image(painter = painterResource(drawable), contentDescription = null, contentScale = ContentScale.Fit,
            modifier = modifier.size(size).clip(shape).testTag(MCP_SERVER_ICON_IMAGE_TAG).clearAndSetSemantics { })
        return
    }
    key(iconUrl) { McpRemoteServerIcon(name, iconUrl, size, modifier, shape) }
}

@Composable
private fun McpRemoteServerIcon(name: String, resolvedIconUrl: String?, size: Dp, modifier: Modifier, shape: RoundedCornerShape) {
    if (resolvedIconUrl.isNullOrEmpty()) {
        McpServerTile(name = name, size = size, modifier = modifier.testTag(MCP_SERVER_ICON_FALLBACK_TAG))
        return
    }
    val context = LocalContext.current.applicationContext
    val edgePx = with(LocalDensity.current) { (size.toPx() * 2f).toInt().coerceAtLeast(64) }
    val bitmap by produceState(initialValue = McpServerIconMemoryCache.get(resolvedIconUrl), resolvedIconUrl) {
        if (value != null) return@produceState
        value = withContext(Dispatchers.IO) {
            val bytes = iconStore(context.cacheDir).bytes(resolvedIconUrl) ?: return@withContext null
            // Icons often have a transparent background: keep alpha.
            decodeSampledBitmap(bytes, edgePx, preferRgb565 = false)?.also { McpServerIconMemoryCache.put(resolvedIconUrl, it) }
        }
    }
    val loaded = bitmap
    if (loaded == null) {
        McpServerTile(name = name, size = size, modifier = modifier.testTag(MCP_SERVER_ICON_FALLBACK_TAG))
    } else {
        Image(
            bitmap = loaded.asImageBitmap(),
            contentDescription = null,
            contentScale = ContentScale.Fit,
            modifier = modifier
                .size(size)
                .clip(shape)
                .testTag(MCP_SERVER_ICON_IMAGE_TAG)
                .clearAndSetSemantics { },
        )
    }
}

internal const val MCP_SERVER_ICON_IMAGE_TAG = "mcp_server_icon_image"
internal const val MCP_SERVER_ICON_FALLBACK_TAG = "mcp_server_icon_fallback"
