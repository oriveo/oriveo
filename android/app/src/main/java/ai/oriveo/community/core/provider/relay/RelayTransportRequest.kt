package ai.oriveo.community.core.provider.relay

import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ReasoningMode

internal data class RelayTransportRequest(
    val apiKey: String,
    val modelID: String,
    val messages: List<ChatMessage>,
    val baseUrl: String?,
    val supportsImageGen: Boolean,
    val reasoningMode: ReasoningMode,
    val webSearchEnabled: Boolean,
    val requestOptions: ChatRequestOptions,
)

/** The effective protocol, final URL and request body of this chat streaming send (without headers; headers are added by applyRelayHeaders at send time). */
internal data class RelayChatWireRequest(
    val transport: ai.oriveo.community.core.model.RelayTransport,
    val url: String,
    val body: String,
)
