package ai.oriveo.community.core.provider.transport

import ai.oriveo.community.core.data.remote.MetadataClient
import kotlinx.serialization.Serializable

/**
 * Field path overrides for streamed responses.
 *
 * Each profile (reasoning / webSearch / imageGen) may carry a [StreamShape] that
 * fine-tunes field paths on top of an already known protocol kind:
 *
 * - `model.transport` picks the main parsing strategy
 * - providers that deviate inside the same kind (Kimi puts reasoning in
 *   `reasoning_content` rather than the usual `delta.content`) are expressed as
 *   streamShape overrides
 * - an override key this build does not recognise is silently ignored, so a newer
 *   catalog cannot break an older client
 *
 * Every field is optional; when one is absent the strategy falls back to its
 * built-in default path.
 *
 * Note that [MetadataClient.StreamShape] is the identically named structure at the
 * catalog deserialization layer; [fromMetadata] converts it into this type for the
 * strategies.
 */
@Serializable
data class StreamShape(
    /** JSON path of the reasoning delta, for example "choices.0.delta.reasoning_content". */
    val reasoningDeltaPath: String? = null,
    /** Anthropic content block type that carries citations, for example "web_search_tool_result". */
    val citationsBlockType: String? = null,
    /** JSON path of the citations array inside a chunk; dot notation supports array indexes. */
    val citationsArrayPath: String? = null,
    /** Field name holding the citation URL: "url" by default, "link" on Zhipu, "web.uri" on Gemini. */
    val citationUrlField: String? = null,
    /** Field name holding the citation title: "title" by default, "web.title" on Gemini. */
    val citationTitleField: String? = null,
    /** Field name holding the citation snippet: "snippet" by default, "cited_text" on Anthropic. */
    val citationSnippetField: String? = null,
    /** JSON path of the image payload, for example "output.images.0.url". */
    val imageDataPath: String? = null,
) {
    companion object {
        /**
         * Converts the catalog-layer shape into the one the transport layer uses.
         * The fields map one to one; forward compatibility is already handled during
         * catalog deserialization, which drops unknown keys.
         */
        fun fromMetadata(meta: MetadataClient.StreamShape?): StreamShape? {
            if (meta == null) return null
            return StreamShape(
                reasoningDeltaPath = meta.reasoningDeltaPath,
                citationsBlockType = meta.citationsBlockType,
                citationsArrayPath = meta.citationsArrayPath,
                citationUrlField = meta.citationUrlField,
                citationTitleField = meta.citationTitleField,
                citationSnippetField = meta.citationSnippetField,
                imageDataPath = meta.imageDataPath,
            )
        }
    }
}

/**
 * Provider endpoint configuration, taken from the catalog's
 * `providers.{kind}.transport` block. EndpointResolver joins [baseUrl] with
 * [endpoints] to build the real request URL.
 */
@Serializable
data class TransportEndpoints(
    val chat: String? = null,
    val responses: String? = null,
    val images: String? = null,
    val embeddings: String? = null,
    val files: String? = null,
)

@Serializable
data class ProviderTransportDefinition(
    val baseUrl: String,
    val endpoints: TransportEndpoints = TransportEndpoints(),
)
