package ai.oriveo.community.core.provider.transport

import ai.oriveo.community.core.model.Citation
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Strategy for the OpenAI Responses API protocol, used by the gpt-4o / 4.1 / 5
 * families and Grok 4.1 and later.
 *
 * Streamed events carry annotations either nested inside
 * `response.output_text.delta`, or as the result of a type=web_search_call item in
 * `response.output_item.added`.
 *
 * The annotation entries this parses look like:
 *   { "type": "url_citation", "url": "...", "title": "...",
 *     "start_index": N, "end_index": M }
 */
class OpenAIResponsesStrategy(private val json: Json) : TransportStrategy {
    override val kind: TransportKind = TransportKind.OpenAIResponses

    override fun parseCitations(rawChunk: String, shape: StreamShape?): List<Citation> {
        val root = runCatching { json.parseToJsonElement(rawChunk).jsonObject }.getOrNull()
            ?: return emptyList()

        val urlField = shape?.citationUrlField ?: CitationParser.DEFAULT_URL_FIELD
        val titleField = shape?.citationTitleField ?: CitationParser.DEFAULT_TITLE_FIELD
        val snippetField = shape?.citationSnippetField ?: CitationParser.DEFAULT_SNIPPET_FIELD

        // An explicit citationsArrayPath from the shape wins.
        shape?.citationsArrayPath?.let { customPath ->
            val arr = CitationParser.resolveJsonPath(root, customPath) as? JsonArray
            if (arr != null) {
                return arr.mapNotNull { el ->
                    val obj = runCatching { el.jsonObject }.getOrNull() ?: return@mapNotNull null
                    val url = CitationParser.extractString(obj, urlField) ?: return@mapNotNull null
                    Citation(
                        url = url,
                        title = CitationParser.extractString(obj, titleField),
                        snippet = CitationParser.extractString(obj, snippetField),
                        startIndex = CitationParser.extractInt(obj, "start_index"),
                        endIndex = CitationParser.extractInt(obj, "end_index"),
                    )
                }
            }
        }

        // Otherwise scan the chunk for annotations. The Responses event layout is not
        // fixed, so walk the whole tree and pick up every type=url_citation node wherever
        // it happens to sit.
        val results = mutableListOf<Citation>()
        collectAnnotations(root, urlField, titleField, snippetField, results)
        return results
    }

    /** Walks the JSON tree collecting every node whose type is "url_citation". */
    private fun collectAnnotations(
        element: kotlinx.serialization.json.JsonElement,
        urlField: String,
        titleField: String,
        snippetField: String,
        out: MutableList<Citation>,
    ) {
        when (element) {
            is kotlinx.serialization.json.JsonObject -> {
                val type = element["type"]?.let {
                    runCatching { it.jsonPrimitive.content }.getOrNull()
                }
                if (type == "url_citation") {
                    val url = CitationParser.extractString(element, urlField)
                    if (!url.isNullOrBlank()) {
                        out += Citation(
                            url = url,
                            title = CitationParser.extractString(element, titleField),
                            snippet = CitationParser.extractString(element, snippetField),
                            startIndex = CitationParser.extractInt(element, "start_index"),
                            endIndex = CitationParser.extractInt(element, "end_index"),
                        )
                    }
                }
                element.values.forEach { collectAnnotations(it, urlField, titleField, snippetField, out) }
            }
            is JsonArray -> {
                element.forEach { collectAnnotations(it, urlField, titleField, snippetField, out) }
            }
            else -> { /* primitives cannot contain annotations */ }
        }
    }
}
