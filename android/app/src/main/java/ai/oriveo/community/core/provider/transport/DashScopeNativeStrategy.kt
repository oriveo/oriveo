package ai.oriveo.community.core.provider.transport

import ai.oriveo.community.core.model.Citation
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject

/**
 * Strategy for the native Qwen DashScope protocol, which wraps everything in
 * `input` / `output` envelopes.
 *
 * In a streamed chunk the citations live in output.search_info.search_results[]:
 * ```
 * {
 *   "output": {
 *     "search_info": {
 *       "search_results": [
 *         { "site_name": "...", "icon": "...", "index": 1,
 *           "title": "...", "url": "..." }
 *       ]
 *     }
 *   }
 * }
 * ```
 *
 * Default field paths, which the qwen_web profile's streamShape also publishes:
 *   citationsArrayPath = "output.search_info.search_results"
 *   citationUrlField   = "url"
 *   citationTitleField = "title"
 */
class DashScopeNativeStrategy(private val json: Json) : TransportStrategy {
    override val kind: TransportKind = TransportKind.DashScopeNative

    override fun parseCitations(rawChunk: String, shape: StreamShape?): List<Citation> {
        val root = runCatching { json.parseToJsonElement(rawChunk).jsonObject }.getOrNull()
            ?: return emptyList()

        val arrayPath = shape?.citationsArrayPath ?: "output.search_info.search_results"
        val urlField = shape?.citationUrlField ?: CitationParser.DEFAULT_URL_FIELD
        val titleField = shape?.citationTitleField ?: CitationParser.DEFAULT_TITLE_FIELD
        val snippetField = shape?.citationSnippetField ?: CitationParser.DEFAULT_SNIPPET_FIELD

        val arr = CitationParser.resolveJsonPath(root, arrayPath) as? JsonArray ?: return emptyList()

        return arr.mapNotNull { el ->
            val obj = runCatching { el.jsonObject }.getOrNull() ?: return@mapNotNull null
            val url = CitationParser.extractString(obj, urlField) ?: return@mapNotNull null
            Citation(
                url = url,
                title = CitationParser.extractString(obj, titleField),
                snippet = CitationParser.extractString(obj, snippetField),
                faviconUrl = CitationParser.extractString(obj, "icon"),
                index = CitationParser.extractInt(obj, "index"),
            )
        }
    }
}
