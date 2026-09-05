package ai.oriveo.community.core.provider.transport

import ai.oriveo.community.core.model.Citation
import kotlinx.serialization.json.Json

/**
 * TransportStrategy implementations for the image generation and file upload
 * transports.
 *
 * None of these produce citations, so parseCitations always returns an empty list.
 * Richer parsing, such as pulling the image out of imageDataPath, is not
 * implemented yet. They are registered anyway so the unknown-kind fallback stays
 * correct and these kinds do not raise [UnsupportedTransportException].
 */

class OpenAIImagesStrategy(@Suppress("unused") private val json: Json) : TransportStrategy {
    override val kind: TransportKind = TransportKind.OpenAIImages
    override fun parseCitations(rawChunk: String, shape: StreamShape?): List<Citation> = emptyList()
}

class GeminiImageStrategy(@Suppress("unused") private val json: Json) : TransportStrategy {
    override val kind: TransportKind = TransportKind.GeminiImage
    override fun parseCitations(rawChunk: String, shape: StreamShape?): List<Citation> = emptyList()
}

class QwenImageStrategy(@Suppress("unused") private val json: Json) : TransportStrategy {
    override val kind: TransportKind = TransportKind.QwenImage
    override fun parseCitations(rawChunk: String, shape: StreamShape?): List<Citation> = emptyList()
}

class GrokImageStrategy(@Suppress("unused") private val json: Json) : TransportStrategy {
    override val kind: TransportKind = TransportKind.GrokImage
    override fun parseCitations(rawChunk: String, shape: StreamShape?): List<Citation> = emptyList()
}

class ZhipuImageStrategy(@Suppress("unused") private val json: Json) : TransportStrategy {
    override val kind: TransportKind = TransportKind.ZhipuImage
    override fun parseCitations(rawChunk: String, shape: StreamShape?): List<Citation> = emptyList()
}

class AnthropicFilesStrategy(@Suppress("unused") private val json: Json) : TransportStrategy {
    override val kind: TransportKind = TransportKind.AnthropicFiles
    override fun parseCitations(rawChunk: String, shape: StreamShape?): List<Citation> = emptyList()
}

class OpenAIFilesStrategy(@Suppress("unused") private val json: Json) : TransportStrategy {
    override val kind: TransportKind = TransportKind.OpenAIFiles
    override fun parseCitations(rawChunk: String, shape: StreamShape?): List<Citation> = emptyList()
}
