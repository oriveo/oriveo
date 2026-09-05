package ai.oriveo.community.core.provider.transport

import ai.oriveo.community.core.model.Citation
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * One implementation per [TransportKind], responsible for:
 * 1. parsing a single SSE chunk into normalised [Citation] / text / image output
 * 2. resolving citation field paths, adjusted by the [StreamShape] overrides
 *
 * Only citation parsing has been pushed down to the strategies so far; request
 * body construction and error parsing still live in the service layer.
 */
interface TransportStrategy {
    val kind: TransportKind

    /**
     * Extracts the citation delta carried by a single SSE chunk.
     *
     * The caller passes the raw JSON text of the chunk, with the `data: ` prefix and
     * any event line already stripped. The strategy locates the citations array via
     * the field paths in [shape] and normalises it into [Citation] values.
     *
     * An empty list means this chunk carries no citations, which is the common case:
     * most chunks are plain text deltas.
     */
    fun parseCitations(rawChunk: String, shape: StreamShape?): List<Citation>
}

/**
 * Shared citation parsing helpers: path resolution, field extraction and
 * deduplication, used by every strategy.
 */
object CitationParser {
    /**
     * Resolves a dot-notation path against a JSON tree.
     * A numeric segment indexes into an array, so `foo.bar.0.baz` works.
     * Returns the [JsonElement] at that path, or null.
     */
    fun resolveJsonPath(root: JsonElement, path: String): JsonElement? {
        val parts = path.split('.').filter { it.isNotEmpty() }
        var current: JsonElement? = root
        for (p in parts) {
            val cur = current ?: return null
            current = when {
                p.toIntOrNull() != null -> {
                    val arr = runCatching { cur.jsonArray }.getOrNull() ?: return null
                    val idx = p.toInt()
                    arr.getOrNull(idx)
                }
                else -> {
                    val obj = runCatching { cur.jsonObject }.getOrNull() ?: return null
                    obj[p]
                }
            }
        }
        return current
    }

    /**
     * Reads a string field out of a JSON object, following a nested dot path such as
     * "web.uri". Returns null when the field is missing or has the wrong type.
     */
    fun extractString(obj: JsonElement?, fieldPath: String): String? {
        if (obj == null) return null
        val resolved = if (fieldPath.contains('.')) {
            resolveJsonPath(obj, fieldPath)
        } else {
            runCatching { obj.jsonObject[fieldPath] }.getOrNull()
        }
        return resolved?.let { el ->
            runCatching { el.jsonPrimitive }.getOrNull()?.content
        }?.takeIf { it.isNotBlank() }
    }

    fun extractInt(obj: JsonElement?, fieldPath: String): Int? {
        if (obj == null) return null
        val resolved = if (fieldPath.contains('.')) {
            resolveJsonPath(obj, fieldPath)
        } else {
            runCatching { obj.jsonObject[fieldPath] }.getOrNull()
        }
        return resolved?.let { el ->
            runCatching { el.jsonPrimitive.content.toIntOrNull() }.getOrNull()
        }
    }

    /**
     * Normalises a URL so it can serve as the deduplication key: lowercase scheme
     * and host, drop the fragment, drop a trailing `/`, keep the query.
     */
    fun normalizeUrl(url: String): String {
        val trimmed = url.trim()
        if (trimmed.isEmpty()) return trimmed
        return runCatching {
            val uri = java.net.URI(trimmed)
            val scheme = uri.scheme?.lowercase() ?: return@runCatching trimmed
            val host = uri.host?.lowercase() ?: return@runCatching trimmed
            val port = if (uri.port != -1) ":${uri.port}" else ""
            val path = (uri.rawPath ?: "").trimEnd('/')
            val query = uri.rawQuery?.let { "?$it" } ?: ""
            "$scheme://$host$port$path$query"
        }.getOrElse { trimmed }
    }

    /**
     * Merges newly arrived citations into the list built so far.
     *
     * Deduplication rules:
     * 1. the primary key is normalizeUrl(url); on a repeat the later item is dropped
     *    but its longer snippet/title is folded in
     * 2. ordering follows first arrival
     * 3. when the URL is missing, which is rare, a hash of title+snippet acts as the
     *    secondary key
     */
    fun mergeCitations(existing: List<Citation>, incoming: List<Citation>): List<Citation> {
        if (incoming.isEmpty()) return existing
        val byKey = LinkedHashMap<String, Citation>()

        fun keyOf(c: Citation): String {
            val urlKey = c.url.trim().takeIf { it.isNotEmpty() }?.let { normalizeUrl(it) }
            if (!urlKey.isNullOrEmpty()) return "u:$urlKey"
            val titleSnippet = "${c.title.orEmpty()}|${c.snippet.orEmpty()}"
            return "h:${titleSnippet.hashCode()}"
        }

        existing.forEach { c -> byKey[keyOf(c)] = c }
        incoming.forEach { incoming ->
            val k = keyOf(incoming)
            val prev = byKey[k]
            if (prev == null) {
                byKey[k] = incoming
            } else {
                // Keep the original position but take the longer non-empty title / snippet.
                byKey[k] = prev.copy(
                    title = preferLonger(prev.title, incoming.title),
                    snippet = preferLonger(prev.snippet, incoming.snippet),
                    faviconUrl = prev.faviconUrl ?: incoming.faviconUrl,
                    index = prev.index ?: incoming.index,
                    startIndex = prev.startIndex ?: incoming.startIndex,
                    endIndex = prev.endIndex ?: incoming.endIndex,
                )
            }
        }
        return byKey.values.toList()
    }

    private fun preferLonger(a: String?, b: String?): String? {
        if (a.isNullOrBlank()) return b
        if (b.isNullOrBlank()) return a
        return if (b.length > a.length) b else a
    }

    // Default field names, used when the shape overrides nothing.
    const val DEFAULT_URL_FIELD = "url"
    const val DEFAULT_TITLE_FIELD = "title"
    const val DEFAULT_SNIPPET_FIELD = "snippet"
}
