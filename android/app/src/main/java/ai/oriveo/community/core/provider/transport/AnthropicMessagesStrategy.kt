package ai.oriveo.community.core.provider.transport

import ai.oriveo.community.core.model.Citation
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Strategy for the Anthropic Messages protocol.
 *
 * In a streamed chunk the citation array sits inside a web_search_tool_result
 * block:
 * ```
 * {
 *   "type": "content_block_start",
 *   "content_block": {
 *     "type": "web_search_tool_result",
 *     "content": [
 *       { "url": "...", "title": "...", "cited_text": "..." }
 *     ]
 *   }
 * }
 * ```
 *
 * Shape defaults: citationsBlockType="web_search_tool_result" and
 * citationSnippetField="cited_text".
 */
class AnthropicMessagesStrategy(private val json: Json) : TransportStrategy {
    override val kind: TransportKind = TransportKind.AnthropicMessages

    override fun parseCitations(rawChunk: String, shape: StreamShape?): List<Citation> {
        val root = runCatching { json.parseToJsonElement(rawChunk).jsonObject }.getOrNull()
            ?: return emptyList()

        val blockType = shape?.citationsBlockType ?: "web_search_tool_result"
        val urlField = shape?.citationUrlField ?: CitationParser.DEFAULT_URL_FIELD
        val titleField = shape?.citationTitleField ?: CitationParser.DEFAULT_TITLE_FIELD
        val snippetField = shape?.citationSnippetField ?: "cited_text"

        // Prefer the content_block carried by a content_block_start event.
        val contentBlock = root["content_block"]?.let { runCatching { it.jsonObject }.getOrNull() }
        if (contentBlock != null) {
            val type = contentBlock["type"]?.let { runCatching { it.jsonPrimitive.content }.getOrNull() }
            if (type == blockType) {
                val contentArr = contentBlock["content"]?.let { runCatching { it.jsonArray }.getOrNull() }
                if (contentArr != null) {
                    return parseContentArray(contentArr, urlField, titleField, snippetField)
                }
            }
        }

        // Otherwise scan the whole content[] array of a message_start, which also covers
        // non-streaming responses and self-contained chunks.
        val message = root["message"]?.let { runCatching { it.jsonObject }.getOrNull() }
        val contentArr = (message?.get("content") ?: root["content"])?.let {
            runCatching { it.jsonArray }.getOrNull()
        } ?: return emptyList()

        val results = mutableListOf<Citation>()
        contentArr.forEach { el ->
            val obj = runCatching { el.jsonObject }.getOrNull() ?: return@forEach
            val type = obj["type"]?.let { runCatching { it.jsonPrimitive.content }.getOrNull() }
            if (type == blockType) {
                val inner = obj["content"]?.let { runCatching { it.jsonArray }.getOrNull() } ?: return@forEach
                results += parseContentArray(inner, urlField, titleField, snippetField)
            }
        }
        return results
    }

    private fun parseContentArray(
        arr: JsonArray,
        urlField: String,
        titleField: String,
        snippetField: String,
    ): List<Citation> = arr.mapNotNull { el ->
        val obj = runCatching { el.jsonObject }.getOrNull() ?: return@mapNotNull null
        val url = CitationParser.extractString(obj, urlField) ?: return@mapNotNull null
        Citation(
            url = url,
            title = CitationParser.extractString(obj, titleField),
            snippet = CitationParser.extractString(obj, snippetField),
        )
    }
}
