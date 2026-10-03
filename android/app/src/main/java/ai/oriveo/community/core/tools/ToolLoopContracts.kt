package ai.oriveo.community.core.tools

import kotlinx.coroutines.flow.Flow
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.Transient
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

// Neutral contract of the generic tool loop.
//
// Moonshot web search and remote MCP tools run on the same `ToolCallLoop`, so the shapes of messages,
// tool definitions and leg events are a contract shared across features.
// The types only express role / content / reasoning / toolCalls / toolResult / continuation state. Each protocol's wire shape
// (anthropic tool_use, responses function_call, gemini functionCall) is translated by `ToolProtocolAdapter`;
// no protocol branches are added here.
//
// Registry entries and the registry are the loop's execution-side contract, in `ToolRegistry.kt`; the loop itself is in `ToolCallLoop.kt`.

/** Tool definition (a function entry of OpenAI `tools[]`). */
@Serializable
data class ToolLoopToolDefinition(
    val type: String = "function",
    val function: ToolLoopToolFunction,
)

@Serializable
data class ToolLoopToolFunction(
    val name: String,
    val description: String,
    val parameters: JsonObject,
)

/** One fully assembled tool call (in the openai_chat wire shape, an assistant `tool_calls[]` entry). */
@Serializable
data class ToolLoopToolCall(
    val id: String,
    val type: String = "function",
    val function: ToolLoopToolCallFunction,
)

@Serializable
data class ToolLoopToolCallFunction(
    val name: String,
    val arguments: String,
)

/**
 * Neutral message: `role` ∈ system / user / assistant / tool.
 *
 * [content] is the text; [reasoningContent] is the reasoning attached to an assistant proposal (Kimi contract: with thinking
 * on, an assistant tool-call message without this field gets a 400, an empty string is accepted); [toolCalls] is the assistant
 * proposal; [toolCallId] (+ [name]) marks a tool result. [providerContinuation] is an opaque block the protocol requires to be
 * sent back verbatim on the next leg; only the matching local protocol adapter reads it.
 */
@Serializable
data class ToolLoopMessage(
    val role: String,
    val content: JsonElement? = null,
    @SerialName("reasoning_content") val reasoningContent: String? = null,
    @SerialName("tool_calls") val toolCalls: List<ToolLoopToolCall>? = null,
    @SerialName("tool_call_id") val toolCallId: String? = null,
    val name: String? = null,
    @Transient val providerContinuation: JsonObject? = null,
) {
    constructor(role: String, text: String) : this(role = role, content = JsonPrimitive(text))

    val textContent: String?
        get() = (content as? JsonPrimitive)?.contentOrNull
}

@Serializable
enum class ToolLoopToolChoice(val wireValue: String) {
    @SerialName("auto")
    Auto("auto"),

    @SerialName("none")
    None("none"),
}

/** Request for one model leg: full history + tool definitions + tool_choice. The leg executor encodes it into the protocol's request body. */
data class ToolLoopLegRequest(
    val messages: List<ToolLoopMessage>,
    val tools: List<ToolLoopToolDefinition>,
    val toolChoice: ToolLoopToolChoice,
)

@Serializable
data class ToolLoopUsage(
    @SerialName("prompt_tokens") val promptTokens: Int? = null,
    @SerialName("completion_tokens") val completionTokens: Int? = null,
    @SerialName("total_tokens") val totalTokens: Int? = null,
) {
    val resolvedTotalTokens: Int
        get() = maxOf(totalTokens ?: 0, (promptTokens ?: 0) + (completionTokens ?: 0))

    fun merging(other: ToolLoopUsage?): ToolLoopUsage {
        if (other == null) return this
        fun sum(left: Int?, right: Int?): Int? =
            if (left == null && right == null) null else (left ?: 0) + (right ?: 0)
        return ToolLoopUsage(
            promptTokens = sum(promptTokens, other.promptTokens),
            completionTokens = sum(completionTokens, other.completionTokens),
            totalTokens = sum(totalTokens, other.totalTokens),
        )
    }

    companion object {
        fun merge(current: ToolLoopUsage?, next: ToolLoopUsage?): ToolLoopUsage? =
            current?.merging(next) ?: next
    }
}

/** A tool_call chunk emitted by the leg executor (not yet assembled). Assembly rules: `ToolCallLoop.mergeToolCallDeltas`. */
data class ToolLoopToolCallDelta(
    val index: Int,
    val id: String? = null,
    val type: String? = null,
    val name: String? = null,
    val arguments: String? = null,
)

sealed interface ToolLoopLegEvent {
    data class TextDelta(val text: String) : ToolLoopLegEvent

    /** Reasoning delta. Reasoning stays out of the text: it is not the model's answer to the user, and must not count as evidence that the first leg answered with zero tool calls. */
    data class ReasoningDelta(val text: String) : ToolLoopLegEvent

    data class ToolCallDeltas(val deltas: List<ToolLoopToolCallDelta>) : ToolLoopLegEvent

    data class Usage(val usage: ToolLoopUsage) : ToolLoopLegEvent

    /** Opaque continuation state this leg must send back verbatim (protocol name + state body); handed over once when the leg ends. */
    data class ProviderContinuation(val protocol: String, val state: JsonObject) : ToolLoopLegEvent
}

/** One leg = one request to the model. Implementations only "send the request → decode the stream → emit events" and must not handle tool_calls themselves. */
fun interface ToolLoopLegRunning {
    fun run(request: ToolLoopLegRequest): Flow<ToolLoopLegEvent>
}

/**
 * Implemented by the error a leg executor throws when upstream rejects native tools with a deterministic 4xx.
 * The loop adds "which leg this was, and whether structured tool_calls had been seen before" and rethrows to the caller.
 */
interface ToolLoopLegRejection {
    fun annotate(legIndex: Int, receivedStructuredToolCalls: Boolean)
}
