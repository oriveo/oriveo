package ai.oriveo.community.core.provider.transport

import ai.oriveo.community.core.model.Citation
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject

/**
 * Strategy for the OpenAI Chat Completions protocol.
 *
 * Citations arrive in `choices[].delta.annotations[].url_citation`. This covers
 * gpt-5-search-api and every OpenAI-compatible aggregator; with web search off
 * there are simply no annotations.
 */
class OpenAIChatStrategy(private val json: Json) : TransportStrategy {
    override val kind: TransportKind = TransportKind.OpenAIChat

    override fun parseCitations(rawChunk: String, shape: StreamShape?): List<Citation> {
        val root = runCatching { json.parseToJsonElement(rawChunk).jsonObject }.getOrNull()
            ?: return emptyList()

        // A citationsArrayPath from the recipe wins, so a newer catalog can point
        // this at a different path without a client release.
        val arrayPath = shape?.citationsArrayPath ?: "choices.0.delta.annotations"
        val urlField = shape?.citationUrlField ?: CitationParser.DEFAULT_URL_FIELD
        val titleField = shape?.citationTitleField ?: CitationParser.DEFAULT_TITLE_FIELD
        val snippetField = shape?.citationSnippetField ?: CitationParser.DEFAULT_SNIPPET_FIELD

        val arr = CitationParser.resolveJsonPath(root, arrayPath) as? JsonArray ?: return emptyList()

        return arr.mapNotNull { el ->
            val obj = runCatching { el.jsonObject }.getOrNull() ?: return@mapNotNull null
            // An OpenAI Chat annotation looks like
            // { "type": "url_citation", "url_citation": { ... } }, so unwrap the nested
            // object first and fall back to the flat form.
            val inner = obj["url_citation"]?.let { runCatching { it.jsonObject }.getOrNull() } ?: obj
            // The configured field name may itself already carry the nesting prefix: the
            // published recipes for or_web / oai_web_tool set
            // `citationUrlField = "url_citation.url"`. Resolving that against the already
            // unwrapped `inner` can only return null, so mapNotNull would drop every
            // citation, which is exactly why web-search citations came back empty for
            // OpenRouter and OpenAI here. Hence the three-step fallback: `inner`, then the
            // outer object so a nested path still resolves, then the flat default name.
            fun field(name: String, fallback: String): String? =
                CitationParser.extractString(inner, name)
                    ?: CitationParser.extractString(obj, name)
                    ?: CitationParser.extractString(inner, fallback)

            val url = field(urlField, CitationParser.DEFAULT_URL_FIELD) ?: return@mapNotNull null
            Citation(
                url = url,
                title = field(titleField, CitationParser.DEFAULT_TITLE_FIELD),
                snippet = field(snippetField, CitationParser.DEFAULT_SNIPPET_FIELD),
                startIndex = CitationParser.extractInt(inner, "start_index"),
                endIndex = CitationParser.extractInt(inner, "end_index"),
            )
        }
    }
}
