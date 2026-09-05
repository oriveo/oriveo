package ai.oriveo.community.core.provider.transport

import ai.oriveo.community.core.model.Citation
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject

/**
 * Strategy for the Gemini generateContent protocol.
 *
 * In a streamed chunk the citations live in
 * candidates[].groundingMetadata.groundingChunks[]:
 * ```
 * {
 *   "candidates": [{
 *     "groundingMetadata": {
 *       "groundingChunks": [
 *         { "web": { "uri": "...", "title": "..." } }
 *       ]
 *     }
 *   }]
 * }
 * ```
 *
 * Default field paths, which the gem_web profile's streamShape also publishes:
 *   citationsArrayPath = "candidates.0.groundingMetadata.groundingChunks"
 *   citationUrlField   = "web.uri"
 *   citationTitleField = "web.title"
 *
 * Note that the REST API returns camelCase response fields, not snake_case.
 */
class GeminiGenerateStrategy(private val json: Json) : TransportStrategy {
    override val kind: TransportKind = TransportKind.GeminiGenerate

    override fun parseCitations(rawChunk: String, shape: StreamShape?): List<Citation> {
        val root = runCatching { json.parseToJsonElement(rawChunk).jsonObject }.getOrNull()
            ?: return emptyList()

        val arrayPath = shape?.citationsArrayPath
            ?: "candidates.0.groundingMetadata.groundingChunks"
        val urlField = shape?.citationUrlField ?: "web.uri"
        val titleField = shape?.citationTitleField ?: "web.title"
        val snippetField = shape?.citationSnippetField ?: CitationParser.DEFAULT_SNIPPET_FIELD

        val arr = CitationParser.resolveJsonPath(root, arrayPath) as? JsonArray ?: return emptyList()

        return arr.mapNotNull { el ->
            val obj = runCatching { el.jsonObject }.getOrNull() ?: return@mapNotNull null
            val url = CitationParser.extractString(obj, urlField) ?: return@mapNotNull null
            Citation(
                url = url,
                title = CitationParser.extractString(obj, titleField),
                snippet = CitationParser.extractString(obj, snippetField),
            )
        }
    }
}
