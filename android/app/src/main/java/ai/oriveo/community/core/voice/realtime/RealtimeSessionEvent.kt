package ai.oriveo.community.core.voice.realtime

import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/** Realtime transport wire names (shared/voice-contracts/realtime-events.v1.json constants.transports). */
enum class RealtimeTransportKind(val rawValue: String) {
    OpenAiRealtime("openai_realtime"),
    XaiRealtime("xai_realtime"),
    GeminiLive("gemini_live"),
    ;

    companion object {
        fun fromRawValue(raw: String?): RealtimeTransportKind? = entries.firstOrNull { it.rawValue == raw }
    }
}

/** Final status of an assistant turn (constants.turnStatuses). */
enum class RealtimeTurnStatus(val rawValue: String) {
    Completed("completed"),
    Interrupted("interrupted"),
    Incomplete("incomplete"),
    Failed("failed"),
    ;

    companion object {
        fun fromRawValue(raw: String?): RealtimeTurnStatus? = entries.firstOrNull { it.rawValue == raw }
    }
}

/**
 * Unified realtime session event: a closed set of 12 kinds shared by all transports.
 * JSON keys match the contract fixture mapCases.expected exactly.
 * itemId is null for transports without item ids (Gemini); the key is kept as null when encoding.
 */
sealed interface RealtimeSessionEvent {
    val type: String

    data object Ready : RealtimeSessionEvent {
        override val type = "ready"
    }

    data class UserSpeechStarted(val itemId: String?) : RealtimeSessionEvent {
        override val type = "userSpeechStarted"
    }

    data class UserSpeechStopped(val itemId: String?) : RealtimeSessionEvent {
        override val type = "userSpeechStopped"
    }

    data class UserTranscript(val itemId: String?, val text: String, val final: Boolean) : RealtimeSessionEvent {
        override val type = "userTranscript"
    }

    data class AssistantAudio(
        val itemId: String?,
        val contentIndex: Int,
        val base64: String,
        val sampleRateHz: Int,
    ) : RealtimeSessionEvent {
        override val type = "assistantAudio"
    }

    data class AssistantTranscript(val itemId: String?, val text: String, val final: Boolean) : RealtimeSessionEvent {
        override val type = "assistantTranscript"
    }

    data object Interrupted : RealtimeSessionEvent {
        override val type = "interrupted"
    }

    data class AssistantTurnDone(
        val itemId: String?,
        val status: RealtimeTurnStatus,
        val text: String,
    ) : RealtimeSessionEvent {
        override val type = "assistantTurnDone"
    }

    /** timeLeftMs may be null; the key is kept as null when encoding. */
    data class GoAway(val timeLeftMs: Long?) : RealtimeSessionEvent {
        override val type = "goAway"
    }

    data class Resumable(val handle: String) : RealtimeSessionEvent {
        override val type = "resumable"
    }

    data class SessionEnded(val reason: String) : RealtimeSessionEvent {
        override val type = "sessionEnded"
    }

    data class Error(val code: String, val message: String) : RealtimeSessionEvent {
        override val type = "error"
    }

    fun toJson(): JsonObject = buildJsonObject {
        fun putItemId(itemId: String?) = put("itemId", itemId?.let(::JsonPrimitive) ?: JsonNull)
        put("type", type)
        when (val event = this@RealtimeSessionEvent) {
            Ready, Interrupted -> Unit
            is UserSpeechStarted -> putItemId(event.itemId)
            is UserSpeechStopped -> putItemId(event.itemId)
            is UserTranscript -> {
                putItemId(event.itemId)
                put("text", event.text)
                put("final", event.final)
            }
            is AssistantAudio -> {
                putItemId(event.itemId)
                put("contentIndex", event.contentIndex)
                put("base64", event.base64)
                put("sampleRateHz", event.sampleRateHz)
            }
            is AssistantTranscript -> {
                putItemId(event.itemId)
                put("text", event.text)
                put("final", event.final)
            }
            is AssistantTurnDone -> {
                putItemId(event.itemId)
                put("status", event.status.rawValue)
                put("text", event.text)
            }
            is GoAway -> put("timeLeftMs", event.timeLeftMs?.let(::JsonPrimitive) ?: JsonNull)
            is Resumable -> put("handle", event.handle)
            is SessionEnded -> put("reason", event.reason)
            is Error -> {
                put("code", event.code)
                put("message", event.message)
            }
        }
    }

    private class ItemIdField(val value: String?)

    companion object {
        /** Event names of the closed set, in contract order. */
        val typeNames: List<String> = listOf(
            "ready", "userSpeechStarted", "userSpeechStopped", "userTranscript", "assistantAudio",
            "assistantTranscript", "interrupted", "assistantTurnDone", "goAway", "resumable",
            "sessionEnded", "error",
        )

        /** Decodes a unified event; unknown type or missing/mistyped fields yield null (never throws). */
        fun fromJson(json: JsonObject): RealtimeSessionEvent? {
            fun str(key: String): String? = (json[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
            fun bool(key: String): Boolean? = (json[key] as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull
            // Gemini has no item ids: the key must be present, as a string or null.
            fun itemId(): ItemIdField? = when (val v = json["itemId"]) {
                null -> null
                is JsonNull -> ItemIdField(null)
                is JsonPrimitive -> if (v.isString) ItemIdField(v.content) else null
                else -> null
            }
            // JS producers cannot tell 1 from 1.0: accept integral floats, reject fractions and numeric strings.
            fun integral(v: JsonPrimitive): Long? {
                if (v.isString) return null
                v.longOrNull?.let { return it }
                val d = v.doubleOrNull ?: return null
                return d.takeIf { it % 1.0 == 0.0 && it >= Long.MIN_VALUE.toDouble() && it < Long.MAX_VALUE.toDouble() }
                    ?.toLong()
            }
            fun int(key: String): Int? = (json[key] as? JsonPrimitive)?.let(::integral)
                ?.takeIf { it in Int.MIN_VALUE..Int.MAX_VALUE }?.toInt()
            return when (str("type")) {
                "ready" -> Ready
                "userSpeechStarted" -> UserSpeechStarted((itemId() ?: return null).value)
                "userSpeechStopped" -> UserSpeechStopped((itemId() ?: return null).value)
                "userTranscript" -> {
                    UserTranscript((itemId() ?: return null).value, str("text") ?: return null, bool("final") ?: return null)
                }
                "assistantAudio" -> AssistantAudio(
                    itemId = (itemId() ?: return null).value,
                    contentIndex = int("contentIndex") ?: return null,
                    base64 = str("base64") ?: return null,
                    sampleRateHz = int("sampleRateHz") ?: return null,
                )
                "assistantTranscript" -> {
                    AssistantTranscript((itemId() ?: return null).value, str("text") ?: return null, bool("final") ?: return null)
                }
                "interrupted" -> Interrupted
                "assistantTurnDone" -> AssistantTurnDone(
                    itemId = (itemId() ?: return null).value,
                    status = RealtimeTurnStatus.fromRawValue(str("status")) ?: return null,
                    text = str("text") ?: return null,
                )
                "goAway" -> when (val v = json["timeLeftMs"]) {
                    is JsonNull -> GoAway(null)
                    is JsonPrimitive -> integral(v)?.let { GoAway(it) }
                    else -> null
                }
                "resumable" -> str("handle")?.let(::Resumable)
                "sessionEnded" -> str("reason")?.let(::SessionEnded)
                "error" -> Error(str("code") ?: return null, str("message") ?: return null)
                else -> null
            }
        }
    }
}
