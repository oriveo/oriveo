package ai.oriveo.community.core.provider.transport

import ai.oriveo.community.core.model.Citation
import kotlinx.serialization.json.Json

/**
 * TransportStrategy implementations for the image generation and file upload transports.
 *
 * A strategy's only job here is citation parsing, and none of these transports carry citations, so
 * every one returns an empty list. Image bytes and file handles are read by the provider services
 * that own those requests, not through the registry. They are registered so their kinds resolve
 * instead of raising [UnsupportedTransportException], which would filter working models out of the
 * picker. Each still takes the shared [Json] so [TransportRegistry] can build them all alike.
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
