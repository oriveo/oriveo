package ai.oriveo.community.core.context

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull

/** How one stream ended; the parser attaches it to the Done event (or to the error thrown by a termination frame) and it is handed to [StopReasonResolver.resolve] when persisting. */
data class StreamFinish(
    val family: StopFamily,
    val ended: StreamEnding,
    /** The termination text that was seen (finish_reason, Responses status and so on); still carried when the stream ends at EOF. */
    val finishRaw: String? = null,
)

/**
 * Records termination signals while the stream is read; call [finish] once it has been read.
 *
 * Clean criteria: openai_chat sees `[DONE]` or a non-empty finish_reason;
 * Responses sees completed / incomplete / failed; free accepts only `[DONE]`; Anthropic sees message_stop
 * (finishRaw = the last stop_reason); Gemini sees any candidate finishReason.
 */
class StreamFinishTracker(private val family: StopFamily) {
    private var sawMarker = false
    private var finishRaw: String? = null

    /** The explicit protocol termination marker `[DONE]`. */
    fun markDoneMarker() {
        sawMarker = true
    }

    /** Observes one raw payload frame; anything that is not a JSON object is ignored. [eventType] is the SSE `event:` line; by default the `type` field is read. */
    fun observePayload(payload: String, json: Json, eventType: String? = null) {
        // Substring pre-check: a frame with no termination signal text (almost every delta frame) is not parsed as JSON, with the same result as parsing every frame
        if (!mayCarryFinish(payload, eventType)) return
        val root = runCatching { json.parseToJsonElement(payload) as? JsonObject }.getOrNull() ?: return
        observe(root, eventType)
    }

    fun observe(root: JsonObject, eventType: String? = null) {
        when (family) {
            StopFamily.OPENAI_CHAT, StopFamily.FREE -> {
                val reason = (root["choices"] as? JsonArray)
                    ?.firstNotNullOfOrNull { choice ->
                        ((choice as? JsonObject)?.get("finish_reason") as? JsonPrimitive)
                            ?.takeIf { it.isString }
                            ?.contentOrNull
                            ?.takeIf { it.isNotEmpty() }
                    }
                if (reason != null) {
                    finishRaw = reason
                    if (family == StopFamily.OPENAI_CHAT) sawMarker = true
                }
            }
            StopFamily.OPENAI_RESPONSES -> {
                responsesTerminalRaw(root, eventType)?.let {
                    finishRaw = it
                    sawMarker = true
                }
            }
            StopFamily.ANTHROPIC -> {
                val type = eventType?.takeIf { it.isNotEmpty() } ?: (root["type"] as? JsonPrimitive)?.contentOrNull
                when (type) {
                    "message_delta" -> ((root["delta"] as? JsonObject)?.get("stop_reason") as? JsonPrimitive)
                        ?.takeIf { it.isString }
                        ?.contentOrNull
                        ?.takeIf { it.isNotEmpty() }
                        ?.let { finishRaw = it }
                    "message_stop" -> sawMarker = true
                }
            }
            StopFamily.GEMINI -> {
                val reason = (root["candidates"] as? JsonArray)
                    ?.firstNotNullOfOrNull { candidate ->
                        ((candidate as? JsonObject)?.get("finishReason") as? JsonPrimitive)
                            ?.takeIf { it.isString }
                            ?.contentOrNull
                            ?.takeIf { it.isNotEmpty() }
                    }
                if (reason != null) {
                    finishRaw = reason
                    sawMarker = true
                }
            }
            StopFamily.LLAMA_CPP -> {
                // Only the last chunk with stop:true is a termination marker; finishRaw = stop_type, derived from the stopped_* booleans for older servers
                if ((root["stop"] as? JsonPrimitive)?.booleanOrNull == true) {
                    finishRaw = llamaCppStopType(root)
                    sawMarker = true
                }
            }
            else -> Unit
        }
    }

    /** A termination marker decided by an outer protocol layer (such as interaction.completed in Gemini Interactions). */
    fun markClean(raw: String?) {
        sawMarker = true
        if (raw != null) finishRaw = raw
    }

    fun finish(): StreamFinish = StreamFinish(
        family = family,
        ended = if (sawMarker) StreamEnding.CLEAN else StreamEnding.EOF_WITHOUT_MARKER,
        finishRaw = finishRaw,
    )

    companion object {
        /** [observe] looks only at these fields and event names; a payload containing none of them cannot change the termination state. */
        private val FINISH_HINTS = listOf("finish_reason", "stop_reason", "finishReason", "message_stop", "response.")

        private fun mayCarryFinish(payload: String, eventType: String?): Boolean {
            // When eventType comes from the SSE `event:` line, the payload may carry no event name
            if (eventType == "message_stop" || eventType?.startsWith("response.") == true) return true
            return FINISH_HINTS.any { payload.contains(it) }
        }

        private val RESPONSES_TERMINAL_EVENTS = setOf("response.completed", "response.incomplete", "response.failed")

        /** The finishRaw of a Responses termination frame (completed / incomplete / failed); null for any other frame. */
        fun responsesTerminalRaw(root: JsonObject, eventType: String? = null): String? {
            val type = eventType?.takeIf { it.isNotEmpty() }
                ?: (root["type"] as? JsonPrimitive)?.contentOrNull
                ?: return null
            if (type !in RESPONSES_TERMINAL_EVENTS) return null
            val response = root["response"] as? JsonObject
            val status = (response?.get("status") as? JsonPrimitive)?.contentOrNull
                ?: type.removePrefix("response.")
            val reason = ((response?.get("incomplete_details") as? JsonObject)?.get("reason") as? JsonPrimitive)
                ?.contentOrNull
            return StopReasonResolver.responsesFinishRaw(status, reason)
        }

        /** A blocked Gemini finishReason still throws as before; this is the finish carried on the error (clean plus the blocking text). */
        fun geminiBlockedFinish(finishReason: String): StreamFinish =
            StreamFinish(StopFamily.GEMINI, StreamEnding.CLEAN, finishReason)

        /** The stop_type of the last chunk of native llama.cpp /completion; older servers without the field derive it from stopped_eos / word / limit, and none of them set means none. */
        private fun llamaCppStopType(root: JsonObject): String {
            (root["stop_type"] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull?.takeIf { it.isNotEmpty() }?.let { return it }
            fun flag(key: String) = (root[key] as? JsonPrimitive)?.booleanOrNull == true
            return when {
                flag("stopped_eos") -> "eos"
                flag("stopped_word") -> "word"
                flag("stopped_limit") -> "limit"
                else -> "none"
            }
        }

        /** A blocked Gemini prompt (promptFeedback.blockReason) still throws as before; this is the finish carried on the error (clean plus "blockReason:<value>"). */
        fun geminiPromptBlockedFinish(blockReason: String): StreamFinish =
            StreamFinish(StopFamily.GEMINI, StreamEnding.CLEAN, StopReasonResolver.geminiBlockReasonRaw(blockReason))

        /** The finish of a Gemini Interactions terminal state (completed / incomplete / failed / requires_action / cancelled). */
        fun geminiInteractionsFinish(status: String): StreamFinish =
            StreamFinish(StopFamily.GEMINI_INTERACTIONS, StreamEnding.CLEAN, status)

        /** `response.failed` still throws as before; this is the finish carried on the error (clean plus the failed text). */
        fun responsesFailedFinish(root: JsonObject?, eventType: String? = null): StreamFinish = StreamFinish(
            family = StopFamily.OPENAI_RESPONSES,
            ended = StreamEnding.CLEAN,
            finishRaw = root?.let { responsesTerminalRaw(it, eventType) } ?: "failed",
        )
    }
}
