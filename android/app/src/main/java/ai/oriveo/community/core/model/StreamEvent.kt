package ai.oriveo.community.core.model

import kotlinx.serialization.json.JsonObject

/** One piece of a streamed response, in the order the provider sent it. */
sealed class StreamEvent {
    /** Fragments of a native tool call the model is assembling. */
    data class ToolCallDeltas(val deltas: List<ToolCallDelta>) : StreamEvent()
    data class ToolCall(val tool: String, val label: String, val step: Int) : StreamEvent()
    data class ToolResult(val tool: String, val summary: String, val step: Int) : StreamEvent()

    /** Visible assistant text. */
    data class Delta(val text: String) : StreamEvent()

    /** Reasoning text, for the models that stream it separately from the answer. */
    data class Reasoning(val text: String) : StreamEvent()

    /** An image the model generated. */
    data class ImagePart(val attachment: Attachment) : StreamEvent()

    /**
     * Sources cited so far.
     *
     * Providers re-send the whole list rather than appending to it, so the receiver merges by
     * identity instead of concatenating.
     */
    data class Citations(val citations: List<Citation>) : StreamEvent()

    /**
     * A fully completed recipe continuation leg. It is local-only sidecar data: ChatRepository
     * persists it in Room and only an explicit continue/retry may consume it.
     */
    data class RecipeContinuation(
        val kind: String,
        val variant: String? = null,
        val state: JsonObject,
    ) : StreamEvent()

    /** The stream finished; carries the final totals for the message. */
    data class Done(val result: ProviderChatResult) : StreamEvent()
}

@kotlinx.serialization.Serializable
data class ToolCallDelta(
    val index: Int,
    val id: String? = null,
    val type: String? = null,
    val name: String? = null,
    val arguments: String? = null,
)
