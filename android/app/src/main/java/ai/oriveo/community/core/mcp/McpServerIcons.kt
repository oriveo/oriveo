package ai.oriveo.community.core.mcp

import java.util.Locale
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement

/**
 * Rules for accepting a server's self-reported icon. The icon URL comes from a third party and is untrusted:
 *
 * - only `https://` is accepted (never `data:` or `http://`), and it must fit the record field's length limit;
 * - it must be on the **same host as the MCP server, or a parent/child domain of it** (`mcp.linear.app` <->
 *   `linear.app`): the specification requires icons to come from the same domain as the server or a trusted one,
 *   and without this rule a server could make the app request an arbitrary host every time the list opens;
 * - only bitmap formats are used (PNG / JPEG / WebP): there is no SVG decoder here, so entries declared as SVG
 *   are skipped.
 *
 * The same rule applies when writing (picking an icon from `serverInfo`) and when reading (before rendering).
 */
object McpServerIconPolicy {
    /** Whether this icon URL may be loaded for this server; returned unchanged when it may. */
    fun loadable(iconURL: String?, serverUrl: String): String? {
        val icon = iconURL?.takeIf { it.length <= McpServerRecord.MAX_URL_LENGTH } ?: return null
        if (!McpOrigin.isHttps(icon)) return null
        val iconUri = McpOrigin.parse(icon) ?: return null
        if (iconUri.rawUserInfo != null) return null
        val iconHost = iconUri.host?.lowercase(Locale.ROOT) ?: return null
        val serverHost = McpOrigin.parse(serverUrl)?.host?.lowercase(Locale.ROOT)?.takeIf { it.isNotEmpty() } ?: return null
        val related = iconHost == serverHost || iconHost.endsWith(".$serverHost") || serverHost.endsWith(".$iconHost")
        // A parent domain needs at least two labels: `com` is nobody's parent domain.
        if (!related || iconHost.count { it == '.' } < 1) return null
        return icon
    }

    /**
     * Picks a usable entry from `serverInfo.icons` (`[{ src, mimeType?, sizes? }]`): the first one, in the order
     * the server gave, that passes [loadable] and is not SVG.
     */
    fun pick(icons: JsonElement?, serverUrl: String): String? {
        val entries = icons as? JsonArray ?: return null
        for (entry in entries) {
            val src = entry["src"].stringOrNull ?: continue
            val mimeType = entry["mimeType"].stringOrNull?.lowercase(Locale.ROOT)
            if (mimeType != null && mimeType !in BITMAP_MIME_TYPES) continue
            if (mimeType == null && McpOrigin.parse(src)?.path?.lowercase(Locale.ROOT)?.endsWith(".svg") == true) continue
            loadable(src, serverUrl)?.let { return it }
        }
        return null
    }

    private val BITMAP_MIME_TYPES = setOf("image/png", "image/jpeg", "image/jpg", "image/webp")
}
