package ai.oriveo.community.core.voice.realtime.wire

import ai.oriveo.community.core.context.RealtimeHistoryItem
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.voice.realtime.RealtimeSessionEvent
import ai.oriveo.community.core.voice.realtime.RealtimeTransportKind
import ai.oriveo.community.core.voice.realtime.RealtimeTurnStatus
import kotlin.math.floor
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject

/**
 * Pure wire codec for the GA realtime transports (OpenAI / xAI), per
 * shared/voice-contracts/realtime-events.v1.json rules.map and rules.client.
 * Gemini Live is not handled here: every entry point yields nothing for it.
 */
object GARealtimeCodec {
    const val OUTPUT_SAMPLE_RATE_HZ = 24_000
    private const val INPUT_SAMPLE_RATE_HZ = 24_000
    private val sessionEndErrorTypes = setOf("max_duration", "timeout")

    /** Per-connection mapping state; the turn part resets after response.done. */
    class State {
        internal var userText: String = ""
        internal var userItem: String? = null
        internal var userFinal: Boolean = false
        internal var assistantText: String = ""
        internal var assistantItem: String? = null

        internal fun resetTurn() {
            userText = ""
            userItem = null
            userFinal = false
            assistantText = ""
            assistantItem = null
        }
    }

    private fun isGa(kind: RealtimeTransportKind) =
        kind == RealtimeTransportKind.OpenAiRealtime || kind == RealtimeTransportKind.XaiRealtime

    private fun JsonObject.str(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

    /** One server message → unified events (possibly empty). Ignored events and other transports yield nothing. */
    fun map(kind: RealtimeTransportKind, message: JsonObject, state: State): List<RealtimeSessionEvent> {
        if (!isGa(kind)) return emptyList()
        val itemId = message.str("item_id")
        return when (message.str("type")) {
            "session.created" -> listOf(RealtimeSessionEvent.Ready)
            "input_audio_buffer.speech_started" -> listOf(RealtimeSessionEvent.UserSpeechStarted(itemId))
            "input_audio_buffer.speech_stopped" -> listOf(RealtimeSessionEvent.UserSpeechStopped(itemId))
            "conversation.item.input_audio_transcription.delta" -> {
                if (kind != RealtimeTransportKind.OpenAiRealtime) return emptyList()
                if (state.userItem != itemId) {
                    state.userItem = itemId
                    state.userText = ""
                    state.userFinal = false
                }
                state.userText += message.str("delta") ?: ""
                listOf(RealtimeSessionEvent.UserTranscript(itemId, state.userText, final = false))
            }
            "conversation.item.input_audio_transcription.updated" -> {
                if (kind != RealtimeTransportKind.XaiRealtime) return emptyList()
                state.userItem = itemId
                state.userText = message.str("transcript") ?: ""
                state.userFinal = false
                listOf(RealtimeSessionEvent.UserTranscript(itemId, state.userText, final = false))
            }
            "conversation.item.input_audio_transcription.completed" -> {
                state.userItem = itemId
                state.userText = message.str("transcript") ?: ""
                state.userFinal = true
                if (state.userText.isEmpty()) {
                    emptyList()
                } else {
                    listOf(RealtimeSessionEvent.UserTranscript(itemId, state.userText, final = true))
                }
            }
            "response.output_audio.delta" -> {
                state.assistantItem = itemId
                val contentIndex = (message["content_index"] as? JsonPrimitive)?.intOrNull ?: 0
                listOf(
                    RealtimeSessionEvent.AssistantAudio(
                        itemId = itemId,
                        contentIndex = contentIndex,
                        base64 = message.str("delta") ?: "",
                        sampleRateHz = OUTPUT_SAMPLE_RATE_HZ,
                    ),
                )
            }
            "response.output_audio_transcript.delta" -> {
                if (state.assistantItem != itemId) {
                    state.assistantItem = itemId
                    state.assistantText = ""
                }
                state.assistantText += message.str("delta") ?: ""
                listOf(RealtimeSessionEvent.AssistantTranscript(itemId, state.assistantText, final = false))
            }
            "response.output_audio_transcript.done" -> {
                state.assistantItem = itemId
                message.str("transcript")?.let { state.assistantText = it }
                listOf(RealtimeSessionEvent.AssistantTranscript(itemId, state.assistantText, final = true))
            }
            "response.done" -> {
                val response = message["response"] as? JsonObject
                val status = when (response?.str("status")) {
                    "completed" -> RealtimeTurnStatus.Completed
                    "cancelled" -> RealtimeTurnStatus.Interrupted
                    "incomplete" -> RealtimeTurnStatus.Incomplete
                    else -> RealtimeTurnStatus.Failed
                }
                val event = RealtimeSessionEvent.AssistantTurnDone(state.assistantItem, status, state.assistantText)
                state.resetTurn()
                listOf(event)
            }
            "error" -> {
                val error = message["error"] as? JsonObject
                val errorType = error?.str("type")
                if (kind == RealtimeTransportKind.XaiRealtime && errorType in sessionEndErrorTypes) {
                    listOf(RealtimeSessionEvent.SessionEnded(errorType!!))
                } else {
                    listOf(
                        RealtimeSessionEvent.Error(
                            code = error?.str("code") ?: errorType ?: "unknown",
                            message = error?.str("message") ?: "",
                        ),
                    )
                }
            }
            else -> emptyList()
        }
    }

    /** Messages sent right after the socket opens (beforeReady); empty for Gemini. */
    fun openingMessages(
        kind: RealtimeTransportKind,
        instructions: String,
        history: List<RealtimeHistoryItem>,
        voice: String,
        inputTranscriptionModel: String?,
    ): List<JsonObject> {
        if (!isGa(kind)) return emptyList()
        val openAi = kind == RealtimeTransportKind.OpenAiRealtime
        val transcriptionModel = inputTranscriptionModel?.takeIf { it.isNotEmpty() }
        val session = buildJsonObject {
            if (openAi) {
                put("type", "realtime")
                put("instructions", instructions)
                putJsonArray("output_modalities") { add("audio") }
            } else {
                put("instructions", instructions)
                put("voice", voice)
                putJsonObject("turn_detection") { put("type", "server_vad") }
            }
            putJsonObject("audio") {
                putJsonObject("input") {
                    putJsonObject("format") {
                        put("type", "audio/pcm")
                        put("rate", INPUT_SAMPLE_RATE_HZ)
                    }
                    if (transcriptionModel != null) {
                        putJsonObject("transcription") { put("model", transcriptionModel) }
                    }
                    if (openAi) putJsonObject("turn_detection") { put("type", "semantic_vad") }
                }
                putJsonObject("output") {
                    putJsonObject("format") {
                        put("type", "audio/pcm")
                        put("rate", OUTPUT_SAMPLE_RATE_HZ)
                    }
                    if (openAi) put("voice", voice)
                }
            }
        }
        val assistantPart = if (openAi) "output_text" else "text"
        val items = history.map { item ->
            val assistant = item.role == ChatRole.Assistant
            buildJsonObject {
                put("type", "conversation.item.create")
                putJsonObject("item") {
                    put("type", "message")
                    put("role", item.role.rawValue)
                    putJsonArray("content") {
                        addJsonObject {
                            put("type", if (assistant) assistantPart else "input_text")
                            put("text", item.text)
                        }
                    }
                }
            }
        }
        val update = buildJsonObject {
            put("type", "session.update")
            put("session", session)
        }
        return listOf(update) + items
    }

    /** wss://{host}{path}?model={percent-encoded model}; null for Gemini (its host builds the URL). */
    fun connectUrl(kind: RealtimeTransportKind, host: String, path: String, model: String): String? {
        if (!isGa(kind)) return null
        return "wss://$host$path?model=${percentEncode(model)}"
    }

    /** Barge-in truncate; null without an item id or for Gemini. */
    fun truncate(kind: RealtimeTransportKind, itemId: String?, contentIndex: Int, playedMs: Double): JsonObject? {
        if (!isGa(kind) || itemId.isNullOrEmpty()) return null
        return buildJsonObject {
            put("type", "conversation.item.truncate")
            put("item_id", itemId)
            put("content_index", contentIndex)
            put("audio_end_ms", maxOf(0L, floor(playedMs).toLong()))
        }
    }

    /** Microphone PCM16 append; null for Gemini. */
    fun append(kind: RealtimeTransportKind, base64: String): JsonObject? {
        if (!isGa(kind)) return null
        return buildJsonObject {
            put("type", "input_audio_buffer.append")
            put("audio", base64)
        }
    }

    /** Percent-encodes everything except RFC 3986 unreserved characters, byte-wise over UTF-8. */
    private fun percentEncode(value: String): String = buildString {
        for (byte in value.encodeToByteArray()) {
            val c = byte.toInt() and 0xFF
            val ch = c.toChar()
            if (ch in 'A'..'Z' || ch in 'a'..'z' || ch in '0'..'9' || ch == '-' || ch == '.' || ch == '_' || ch == '~') {
                append(ch)
            } else {
                append('%')
                append("0123456789ABCDEF"[c shr 4])
                append("0123456789ABCDEF"[c and 0x0F])
            }
        }
    }
}
