package ai.oriveo.community.core.voice.realtime.wire

import ai.oriveo.community.core.context.RealtimeHistoryItem
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.voice.realtime.RealtimeSessionEvent
import ai.oriveo.community.core.voice.realtime.RealtimeVoiceLog
import ai.oriveo.community.core.voice.realtime.RealtimeTurnStatus
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject

/** Client messages sent when opening a Gemini Live session: setup first, clientContent only after setupComplete. */
internal data class GeminiOpeningMessages(val beforeReady: List<JsonObject>, val afterReady: List<JsonObject>)

/** Pure Gemini Live wire shapes (shared/voice-contracts/realtime-events.v1.json, gemini_live cases). */
internal object GeminiLiveWire {
    /** Uplink microphone format: PCM16 mono at this rate. */
    const val INPUT_SAMPLE_RATE_HZ = 16000
    const val INPUT_MIME_TYPE = "audio/pcm;rate=$INPUT_SAMPLE_RATE_HZ"
    const val OUTPUT_SAMPLE_RATE_HZ = 24000

    /** Connect URL without auth: wss://{host}{path}. */
    fun connectUrl(host: String, path: String): String = "wss://$host$path"

    /** Connect URL with the API key appended as ?key=, percent-encoding everything outside RFC 3986 unreserved. */
    fun authenticatedUrl(host: String, path: String, key: String): String =
        connectUrl(host, path) + "?key=" + percentEncodeUnreserved(key)

    fun openingMessages(
        instructions: String,
        history: List<RealtimeHistoryItem>,
        model: String,
        voice: String,
        resumeHandle: String?,
    ): GeminiOpeningMessages {
        val resuming = !resumeHandle.isNullOrEmpty()
        val withHistory = !resuming && history.isNotEmpty()
        val setup = buildJsonObject {
            put("model", "models/$model")
            putJsonObject("generationConfig") {
                putJsonArray("responseModalities") { add("AUDIO") }
                putJsonObject("speechConfig") {
                    putJsonObject("voiceConfig") {
                        putJsonObject("prebuiltVoiceConfig") { put("voiceName", voice) }
                    }
                }
            }
            putJsonObject("systemInstruction") {
                putJsonArray("parts") { addJsonObject { put("text", instructions) } }
            }
            putJsonObject("inputAudioTranscription") {}
            putJsonObject("outputAudioTranscription") {}
            putJsonObject("sessionResumption") { if (resuming) put("handle", resumeHandle) }
            putJsonObject("contextWindowCompression") { putJsonObject("slidingWindow") {} }
            if (withHistory) putJsonObject("historyConfig") { put("initialHistoryInClientContent", true) }
        }
        val after = if (withHistory) {
            listOf(
                buildJsonObject {
                    putJsonObject("clientContent") {
                        putJsonArray("turns") {
                            for (item in history) {
                                addJsonObject {
                                    put("role", if (item.role == ChatRole.Assistant) "model" else "user")
                                    putJsonArray("parts") { addJsonObject { put("text", item.text) } }
                                }
                            }
                        }
                        put("turnComplete", true)
                    }
                },
            )
        } else {
            emptyList()
        }
        return GeminiOpeningMessages(beforeReady = listOf(buildJsonObject { put("setup", setup) }), afterReady = after)
    }

    /** One chunk of microphone PCM16 already resampled to 16 kHz. */
    fun audioAppendMessage(base64: String): JsonObject = buildJsonObject {
        putJsonObject("realtimeInput") {
            putJsonObject("audio") {
                put("data", base64)
                put("mimeType", INPUT_MIME_TYPE)
            }
        }
    }

    /** Protobuf Duration JSON ("1.5s" / "10s" / "0.250s") to milliseconds; anything else yields null. */
    fun durationMs(value: JsonElement?): Long? {
        val text = (value as? JsonPrimitive)?.takeIf { it.isString }?.content ?: return null
        val match = DURATION.matchEntire(text) ?: return null
        val seconds = match.groupValues[1].toLongOrNull() ?: return null
        // Integer-only: fraction as nanoseconds, rounded half-up to milliseconds; overflow is detected exactly.
        val nanos = match.groupValues[2].padEnd(9, '0').toLong()
        val fractionMs = (nanos + 500_000) / 1_000_000
        return try {
            Math.addExact(Math.multiplyExact(seconds, 1000L), fractionMs)
        } catch (_: ArithmeticException) {
            null
        }
    }

    private val DURATION = Regex("""^(\d+)(?:\.(\d{1,9}))?s$""")

    internal fun percentEncodeUnreserved(value: String): String {
        val out = StringBuilder()
        for (byte in value.toByteArray(Charsets.UTF_8)) {
            val b = byte.toInt() and 0xFF
            val c = b.toChar()
            val unreserved = c in 'A'..'Z' || c in 'a'..'z' || c in '0'..'9' || c == '-' || c == '.' || c == '_' || c == '~'
            if (unreserved) out.append(c) else out.append('%').append(HEX[b shr 4]).append(HEX[b and 0x0F])
        }
        return out.toString()
    }

    private const val HEX = "0123456789ABCDEF"
}

/**
 * Maps Gemini Live server messages to unified events, following the realtime-events contract.
 * One instance per connection. Transcriptions are appended (treated as incremental).
 */
internal class GeminiLiveEventMapper {
    private var userText = ""
    private var assistantText = ""
    private var userFinal = false
    private var interrupted = false
    private var assistantStarted = false
    private var nextUserText = ""
    private var speechSinceReply = false

    /** True once this turn received any transcription / audio / interrupted and before turnComplete. */
    var midTurn: Boolean = false
        private set

    fun map(message: JsonObject): List<RealtimeSessionEvent> {
        val out = mutableListOf<RealtimeSessionEvent>()
        if (message.containsKey("setupComplete")) out += RealtimeSessionEvent.Ready
        when ((message["voiceActivity"] as? JsonObject)?.string("type")) {
            "ACTIVITY_START" -> {
                if (assistantStarted) speechSinceReply = true
                out += RealtimeSessionEvent.UserSpeechStarted(null)
            }
            "ACTIVITY_END" -> out += RealtimeSessionEvent.UserSpeechStopped(null)
        }
        val content = message["serverContent"] as? JsonObject
        // Raw message kinds only (key names, audio part count): never the audio or transcript text.
        RealtimeVoiceLog.d(
            "gemini message=${message.keys} serverContent=${content?.let(::contentKinds)}",
            chatty = content != null && content.keys == setOf("modelTurn"),
        )
        if (content != null) {
            val inputText = (content["inputTranscription"] as? JsonObject)?.string("text")
            if (!inputText.isNullOrEmpty()) {
                midTurn = true
                if (assistantStarted && (userFinal || speechSinceReply)) {
                    // User already finalized, or new speech detected after the reply started (barge-in / speaker
                    // echo): this belongs to the next turn. Otherwise it is a late transcript of this turn.
                    nextUserText += inputText
                    out += RealtimeSessionEvent.UserTranscript(null, nextUserText, final = false)
                } else {
                    userText += inputText
                    out += RealtimeSessionEvent.UserTranscript(null, userText, final = false)
                }
            }
            // First model output of the turn (audio or transcript) means the user finished: emit the user final
            // first so the user message is stored before the assistant's.
            val parts = ((content["modelTurn"] as? JsonObject)?.get("parts") as? JsonArray).orEmpty()
            val outputText = (content["outputTranscription"] as? JsonObject)?.string("text")
            val hasOutput = !outputText.isNullOrEmpty() || parts.any {
                !((it as? JsonObject)?.get("inlineData") as? JsonObject)?.string("data").isNullOrEmpty()
            }
            if (hasOutput && !assistantStarted) {
                emitUserFinal(out)
                assistantStarted = true
            }
            for (part in parts) {
                val data = ((part as? JsonObject)?.get("inlineData") as? JsonObject)?.string("data")
                if (!data.isNullOrEmpty()) {
                    midTurn = true
                    out += RealtimeSessionEvent.AssistantAudio(
                        itemId = null,
                        contentIndex = 0,
                        base64 = data,
                        sampleRateHz = GeminiLiveWire.OUTPUT_SAMPLE_RATE_HZ,
                    )
                }
            }
            if (!outputText.isNullOrEmpty()) {
                assistantText += outputText
                midTurn = true
                out += RealtimeSessionEvent.AssistantTranscript(null, assistantText, final = false)
            }
            if (content.isTrue("interrupted")) {
                interrupted = true
                midTurn = true
                out += RealtimeSessionEvent.Interrupted
            }
            if (content.isTrue("turnComplete")) {
                emitUserFinal(out)
                if (assistantText.isNotEmpty()) {
                    out += RealtimeSessionEvent.AssistantTranscript(null, assistantText, final = true)
                }
                out += RealtimeSessionEvent.AssistantTurnDone(
                    itemId = null,
                    status = if (interrupted) RealtimeTurnStatus.Interrupted else RealtimeTurnStatus.Completed,
                    text = assistantText,
                )
                userText = nextUserText
                nextUserText = ""
                speechSinceReply = false
                assistantText = ""
                assistantStarted = false
                userFinal = false
                interrupted = false
                midTurn = userText.isNotEmpty()
            }
        }
        val goAway = message["goAway"] as? JsonObject
        if (goAway != null) out += RealtimeSessionEvent.GoAway(GeminiLiveWire.durationMs(goAway["timeLeft"]))
        val resumption = message["sessionResumptionUpdate"] as? JsonObject
        if (resumption != null && resumption.isTrue("resumable")) {
            val handle = resumption.string("newHandle")
            if (!handle.isNullOrEmpty()) out += RealtimeSessionEvent.Resumable(handle)
        }
        return out
    }

    /**
     * Connection switch (goAway, resumption, reopen) about to drop this mapper: this turn's not-yet-final user text,
     * then the text carried to the next turn, each as a final userTranscript if non-empty. The assistant text of an
     * unfinished reply is not flushed. Idempotent: the flushed text is cleared.
     */
    fun flushPendingUser(): List<RealtimeSessionEvent> {
        val out = mutableListOf<RealtimeSessionEvent>()
        emitUserFinal(out)
        if (nextUserText.isNotEmpty()) out += RealtimeSessionEvent.UserTranscript(null, nextUserText, final = true)
        userText = ""
        nextUserText = ""
        return out
    }

    private fun emitUserFinal(out: MutableList<RealtimeSessionEvent>) {
        if (userFinal || userText.isEmpty()) return
        userFinal = true
        out += RealtimeSessionEvent.UserTranscript(null, userText, final = true)
    }

    private fun contentKinds(content: JsonObject): List<String> = content.keys.map { key ->
        if (key != "modelTurn") return@map key
        val parts = ((content[key] as? JsonObject)?.get("parts") as? JsonArray).orEmpty()
        val audio = parts.count { ((it as? JsonObject)?.get("inlineData") as? JsonObject) != null }
        "modelTurn(audio=$audio,parts=${parts.size})"
    }

    private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

    private fun JsonObject.isTrue(key: String): Boolean =
        (this[key] as? JsonPrimitive)?.let { !it.isString && it.content == "true" } == true
}
