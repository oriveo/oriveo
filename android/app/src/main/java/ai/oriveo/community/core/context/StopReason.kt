package ai.oriveo.community.core.context

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Closed set of answer finish reasons (the enum in stop-reason.v1.json); [wire] is the persisted string. */
@Serializable
enum class StopReason(val wire: String) {
    @SerialName("stop") STOP("stop"),
    @SerialName("length") LENGTH("length"),
    @SerialName("content_filter") CONTENT_FILTER("content_filter"),
    @SerialName("tool") TOOL("tool"),
    @SerialName("context_window_exceeded") CONTEXT_WINDOW_EXCEEDED("context_window_exceeded"),
    @SerialName("interrupted") INTERRUPTED("interrupted"),
    @SerialName("incomplete") INCOMPLETE("incomplete"),
    @SerialName("error") ERROR("error"),
    @SerialName("unknown") UNKNOWN("unknown"),
    ;

    companion object {
        /** Reading from storage: null gives null; an unrecognized string gives [UNKNOWN]. */
        fun fromStored(raw: String?): StopReason? = raw?.let { r -> entries.firstOrNull { it.wire == r } ?: UNKNOWN }
    }
}

/** Streaming protocol families (the keys of the stop-reason.v1 mapping). */
enum class StopFamily(val wire: String) {
    OPENAI_CHAT("openai_chat"),
    OPENAI_RESPONSES("openai_responses"),
    ANTHROPIC("anthropic"),
    GEMINI("gemini"),
    MANAGED("managed"),
    FREE("free"),
    GEMINI_INTERACTIONS("gemini_interactions"),
    LLAMA_CPP("llama_cpp"),
    ;

    companion object {
        fun fromWire(wire: String): StopFamily = entries.first { it.wire == wire }
    }
}

/** How the byte stream ended (stop-reason.v1 ended). */
enum class StreamEnding(val wire: String) {
    CLEAN("clean"),
    EOF_WITHOUT_MARKER("eof_without_marker"),
    ERROR_FRAME("error_frame"),
    TRANSPORT_ERROR("transport_error"),
    USER_CANCELLED("user_cancelled"),
    ;

    companion object {
        fun fromWire(wire: String): StreamEnding = entries.first { it.wire == wire }
    }
}

/** Maps each protocol family's termination signal to a [StopReason]; the rules are the stop-reason.v1 rules. */
object StopReasonResolver {

    private const val RESPONSES_INCOMPLETE = "incomplete"
    private const val RESPONSES_INCOMPLETE_PREFIX = "$RESPONSES_INCOMPLETE:"

    private const val GEMINI_BLOCK_REASON_PREFIX = "blockReason:"
    private const val GEMINI_BLOCK_REASON_UNSPECIFIED = "${GEMINI_BLOCK_REASON_PREFIX}BLOCK_REASON_UNSPECIFIED"

    private val mapping: Map<StopFamily, Map<String, StopReason>> = mapOf(
        StopFamily.OPENAI_CHAT to mapOf(
            "stop" to StopReason.STOP,
            "length" to StopReason.LENGTH,
            "content_filter" to StopReason.CONTENT_FILTER,
            "tool_calls" to StopReason.TOOL,
            "function_call" to StopReason.TOOL,
        ),
        StopFamily.OPENAI_RESPONSES to mapOf(
            "completed" to StopReason.STOP,
            "incomplete:max_output_tokens" to StopReason.LENGTH,
            "incomplete:content_filter" to StopReason.CONTENT_FILTER,
            "failed" to StopReason.ERROR,
        ),
        StopFamily.ANTHROPIC to mapOf(
            "end_turn" to StopReason.STOP,
            "stop_sequence" to StopReason.STOP,
            "max_tokens" to StopReason.LENGTH,
            "tool_use" to StopReason.TOOL,
            "pause_turn" to StopReason.INCOMPLETE,
            "refusal" to StopReason.CONTENT_FILTER,
            "model_context_window_exceeded" to StopReason.CONTEXT_WINDOW_EXCEEDED,
        ),
        StopFamily.GEMINI to mapOf(
            "STOP" to StopReason.STOP,
            "MAX_TOKENS" to StopReason.LENGTH,
            "SAFETY" to StopReason.CONTENT_FILTER,
            "RECITATION" to StopReason.CONTENT_FILTER,
            "BLOCKLIST" to StopReason.CONTENT_FILTER,
            "PROHIBITED_CONTENT" to StopReason.CONTENT_FILTER,
            "SPII" to StopReason.CONTENT_FILTER,
            "IMAGE_SAFETY" to StopReason.CONTENT_FILTER,
            "IMAGE_PROHIBITED_CONTENT" to StopReason.CONTENT_FILTER,
            "IMAGE_RECITATION" to StopReason.CONTENT_FILTER,
            "LANGUAGE" to StopReason.CONTENT_FILTER,
            "ESCALATION" to StopReason.CONTENT_FILTER,
            "PUP_LIMITED_DISABLED" to StopReason.CONTENT_FILTER,
            "CONTINUATION" to StopReason.LENGTH,
            "MALFORMED_FUNCTION_CALL" to StopReason.ERROR,
            "MALFORMED_RESPONSE" to StopReason.ERROR,
            "MISSING_THOUGHT_SIGNATURE" to StopReason.ERROR,
            "UNEXPECTED_TOOL_CALL" to StopReason.ERROR,
            "TOO_MANY_TOOL_CALLS" to StopReason.ERROR,
            "OTHER" to StopReason.UNKNOWN,
            "FINISH_REASON_UNSPECIFIED" to StopReason.UNKNOWN,
            "IMAGE_OTHER" to StopReason.UNKNOWN,
            "NO_IMAGE" to StopReason.UNKNOWN,
        ),
        // A managed server sends the persisted enum text directly
        StopFamily.MANAGED to StopReason.entries
            .filter { it != StopReason.INTERRUPTED }
            .associateBy { it.wire },
        StopFamily.FREE to mapOf(
            "stop" to StopReason.STOP,
            "length" to StopReason.LENGTH,
            "content_filter" to StopReason.CONTENT_FILTER,
            "tool_calls" to StopReason.TOOL,
        ),
        // finishRaw = the terminal interaction status; cancelled is not mapped (unknown)
        StopFamily.GEMINI_INTERACTIONS to mapOf(
            "completed" to StopReason.STOP,
            "incomplete" to StopReason.LENGTH,
            "requires_action" to StopReason.TOOL,
            "failed" to StopReason.ERROR,
        ),
        // finishRaw = stop_type; none is not mapped (unknown)
        StopFamily.LLAMA_CPP to mapOf(
            "eos" to StopReason.STOP,
            "word" to StopReason.STOP,
            "limit" to StopReason.LENGTH,
        ),
    )

    fun resolve(family: StopFamily, ended: StreamEnding, finishRaw: String?, hadContent: Boolean): StopReason =
        when (ended) {
            StreamEnding.USER_CANCELLED -> StopReason.INTERRUPTED
            StreamEnding.TRANSPORT_ERROR, StreamEnding.ERROR_FRAME ->
                if (hadContent) StopReason.INCOMPLETE else StopReason.ERROR
            // Having seen a finish value is not a normal end either: the termination marker never arrived
            StreamEnding.EOF_WITHOUT_MARKER -> StopReason.INCOMPLETE
            StreamEnding.CLEAN -> resolveClean(family, finishRaw)
        }

    /** The finishRaw of Responses: the status, with incomplete_details.reason appended when incomplete. */
    fun responsesFinishRaw(status: String, incompleteReason: String?): String =
        if (status == RESPONSES_INCOMPLETE && incompleteReason != null) RESPONSES_INCOMPLETE_PREFIX + incompleteReason else status

    /** The finishRaw when the whole Gemini prompt is blocked (promptFeedback.blockReason); it is not in the mapping and [resolveClean] decides by rule. */
    fun geminiBlockReasonRaw(blockReason: String): String = GEMINI_BLOCK_REASON_PREFIX + blockReason

    private fun resolveClean(family: StopFamily, finishRaw: String?): StopReason {
        if (finishRaw == null) return StopReason.UNKNOWN
        if (family == StopFamily.GEMINI && finishRaw.startsWith(GEMINI_BLOCK_REASON_PREFIX)) {
            return if (finishRaw == GEMINI_BLOCK_REASON_UNSPECIFIED) StopReason.UNKNOWN else StopReason.CONTENT_FILTER
        }
        mapping[family]?.get(finishRaw)?.let { return it }
        // Any other Responses incomplete reason (including an incomplete with no reason) is still an unfinished answer
        if (family == StopFamily.OPENAI_RESPONSES &&
            (finishRaw == RESPONSES_INCOMPLETE || finishRaw.startsWith(RESPONSES_INCOMPLETE_PREFIX))
        ) {
            return StopReason.INCOMPLETE
        }
        return StopReason.UNKNOWN
    }
}
