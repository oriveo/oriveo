package ai.oriveo.community.core.voice

import ai.oriveo.community.core.model.ProviderKind
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * Voice catalog v2 (the data of GET /api/metadata?view=voice, schemaVersion 2).
 * Decoding rules follow rules.decode in the shared engine-resolution.v2.json contract.
 */
enum class VoiceDirection(val rawValue: String) {
    Stt("stt"),
    Tts("tts"),

    /** Conversation engine: engine system = follow the current model (cascaded conversation). */
    Realtime("realtime"),
    ;

    companion object {
        fun fromRawValue(raw: String?): VoiceDirection? = entries.firstOrNull { it.rawValue == raw }
    }
}

/** Transports the client recognizes; each direction only accepts its own, other entries are dropped. */
enum class VoiceTransport(val rawValue: String, val direction: VoiceDirection) {
    OpenAITranscriptions("openai_transcriptions", VoiceDirection.Stt),
    XaiStt("xai_stt", VoiceDirection.Stt),
    GeminiTranscribe("gemini_transcribe", VoiceDirection.Stt),
    DashscopeAsr("dashscope_asr", VoiceDirection.Stt),
    OpenAISpeech("openai_speech", VoiceDirection.Tts),
    XaiTts("xai_tts", VoiceDirection.Tts),
    GeminiTts("gemini_tts", VoiceDirection.Tts),
    MistralSpeech("mistral_speech", VoiceDirection.Tts),
    DashscopeTts("dashscope_tts", VoiceDirection.Tts),
    OpenAIRealtime("openai_realtime", VoiceDirection.Realtime),
    XaiRealtime("xai_realtime", VoiceDirection.Realtime),
    GeminiLive("gemini_live", VoiceDirection.Realtime),
    ;

    companion object {
        fun fromRawValue(raw: String, direction: VoiceDirection): VoiceTransport? =
            entries.firstOrNull { it.rawValue == raw && it.direction == direction }
    }
}

/**
 * The providerKind in the catalog is recognized by the ProviderKind enum as a whole; providers not in the enum are dropped.
 * No allowlist of "which providers have voice": listing is decided only by the server catalog and transport,
 * otherwise a newly listed provider would diverge across clients (tests assert equality with the enum item by item).
 */
object VoiceProviderKinds {
    fun fromRawValue(raw: String?): ProviderKind? = raw?.let { ProviderKind.fromRawValue(it) }
}

sealed interface VoiceCatalogEntry {
    val model: String
    val transport: VoiceTransport
    val path: String
    val isDefault: Boolean
}

data class VoiceSttEntry(
    override val model: String,
    override val transport: VoiceTransport,
    override val path: String,
    val maxBytes: Long,
    val maxDurationSec: Int,
    val languageField: String? = null,
    override val isDefault: Boolean = false,
) : VoiceCatalogEntry

data class VoiceOption(val id: String, val isDefault: Boolean = false)

/** Present only when 0 < min <= 1 <= max; invalid is treated as missing (entry is kept, no speed control). */
data class VoiceSpeedRange(val min: Double, val max: Double)

data class VoiceTtsEntry(
    override val model: String,
    override val transport: VoiceTransport,
    override val path: String,
    val voices: List<VoiceOption>,
    val outputFormat: String,
    val maxChars: Int,
    val speedRange: VoiceSpeedRange? = null,
    override val isDefault: Boolean = false,
) : VoiceCatalogEntry {
    /** Used when the selected voice is not in the list: the one marked isDefault, otherwise the first. */
    val defaultVoice: VoiceOption get() = voices.firstOrNull { it.isDefault } ?: voices.first()
}

/**
 * Conversation engine entry (rules.realtime). An invalid maxSessionSec is treated as missing; when inputTranscriptionModel is missing,
 * openai_realtime / xai_realtime entries are already dropped at decode time, gemini_live may omit it.
 */
data class VoiceRealtimeEntry(
    override val model: String,
    override val transport: VoiceTransport,
    override val path: String,
    val contextWindow: Long,
    val voices: List<VoiceOption>,
    val maxSessionSec: Long? = null,
    val inputTranscriptionModel: String? = null,
    override val isDefault: Boolean = false,
) : VoiceCatalogEntry {
    /** Used when the selected voice is not in the list: the one marked isDefault, otherwise the first. */
    val defaultVoice: VoiceOption get() = voices.firstOrNull { it.isDefault } ?: voices.first()
}

data class VoiceProviderCatalog(
    val stt: List<VoiceSttEntry> = emptyList(),
    val tts: List<VoiceTtsEntry> = emptyList(),
    val realtime: List<VoiceRealtimeEntry> = emptyList(),
) {
    fun entries(direction: VoiceDirection): List<VoiceCatalogEntry> = when (direction) {
        VoiceDirection.Stt -> stt
        VoiceDirection.Tts -> tts
        VoiceDirection.Realtime -> realtime
    }

    companion object {
        val EMPTY = VoiceProviderCatalog()
    }
}

data class VoiceCatalog(
    val schemaVersion: Int? = null,
    val revision: String? = null,
    val providers: Map<ProviderKind, VoiceProviderCatalog> = emptyMap(),
) {
    /** A provider missing from the catalog = empty in every direction. */
    fun provider(kind: ProviderKind): VoiceProviderCatalog = providers[kind] ?: VoiceProviderCatalog.EMPTY

    fun entries(kind: ProviderKind, direction: VoiceDirection): List<VoiceCatalogEntry> =
        provider(kind).entries(direction)

    fun entry(kind: ProviderKind, direction: VoiceDirection, model: String): VoiceCatalogEntry? =
        entries(kind, direction).firstOrNull { it.model == model }
}

/** Lenient decoding: a malformed structure only drops that layer, the whole document never fails; unknown keys are ignored. */
object VoiceCatalogDecoder {
    fun decode(data: JsonElement?): VoiceCatalog {
        val root = data as? JsonObject ?: return VoiceCatalog()
        val providersObj = root["providers"] as? JsonObject
        val providers = linkedMapOf<ProviderKind, VoiceProviderCatalog>()
        providersObj?.forEach { (raw, value) ->
            val kind = VoiceProviderKinds.fromRawValue(raw) ?: return@forEach
            providers[kind] = decodeProvider(value)
        }
        return VoiceCatalog(
            schemaVersion = root["schemaVersion"].integerOrNull()?.toInt(),
            revision = root["revision"].stringOrNull(),
            providers = providers,
        )
    }

    private fun decodeProvider(element: JsonElement): VoiceProviderCatalog {
        val obj = element as? JsonObject ?: return VoiceProviderCatalog.EMPTY
        return VoiceProviderCatalog(
            stt = obj.objects("stt").mapNotNull(::decodeStt),
            tts = obj.objects("tts").mapNotNull(::decodeTts),
            realtime = obj.objects("realtime").mapNotNull(::decodeRealtime),
        )
    }

    private fun decodeStt(obj: JsonObject): VoiceSttEntry? {
        val transport = obj.transport(VoiceDirection.Stt) ?: return null
        return VoiceSttEntry(
            model = obj["model"].stringOrNull() ?: return null,
            transport = transport,
            path = obj["path"].stringOrNull() ?: return null,
            maxBytes = obj["maxBytes"].positiveInteger() ?: return null,
            maxDurationSec = obj["maxDurationSec"].positiveInteger()?.toIntOrNullExact() ?: return null,
            languageField = obj["languageField"].stringOrNull(),
            isDefault = obj["isDefault"].isTrue(),
        )
    }

    private fun decodeTts(obj: JsonObject): VoiceTtsEntry? {
        val transport = obj.transport(VoiceDirection.Tts) ?: return null
        val voices = obj.voices() ?: return null
        return VoiceTtsEntry(
            model = obj["model"].stringOrNull() ?: return null,
            transport = transport,
            path = obj["path"].stringOrNull() ?: return null,
            voices = voices,
            outputFormat = obj["outputFormat"].stringOrNull() ?: return null,
            maxChars = obj["maxChars"].positiveInteger()?.toIntOrNullExact() ?: return null,
            speedRange = decodeSpeedRange(obj["speedRange"]),
            isDefault = obj["isDefault"].isTrue(),
        )
    }

    private fun decodeRealtime(obj: JsonObject): VoiceRealtimeEntry? {
        val transport = obj.transport(VoiceDirection.Realtime) ?: return null
        val voices = obj.voices() ?: return null
        val transcriptionModel = obj["inputTranscriptionModel"].stringOrNull()
        // The two GA providers do not transcribe user speech by default; without a transcription model user turns cannot be stored; gemini_live does not need it.
        if (transcriptionModel == null && transport != VoiceTransport.GeminiLive) return null
        return VoiceRealtimeEntry(
            model = obj["model"].stringOrNull() ?: return null,
            transport = transport,
            path = obj["path"].stringOrNull() ?: return null,
            contextWindow = obj["contextWindow"].positiveInteger() ?: return null,
            voices = voices,
            maxSessionSec = obj["maxSessionSec"].positiveInteger(),
            inputTranscriptionModel = transcriptionModel,
            isDefault = obj["isDefault"].isTrue(),
        )
    }

    /** voices not an array = null (entry dropped); voices whose id is not a string are dropped, and an empty result also returns null. */
    private fun JsonObject.voices(): List<VoiceOption>? {
        val voicesArray = this["voices"] as? JsonArray ?: return null
        val voices = voicesArray.mapNotNull { el ->
            val voice = el as? JsonObject ?: return@mapNotNull null
            val id = voice["id"].stringOrNull() ?: return@mapNotNull null
            VoiceOption(id = id, isDefault = voice["isDefault"].isTrue())
        }
        return voices.ifEmpty { null }
    }

    private fun decodeSpeedRange(element: JsonElement?): VoiceSpeedRange? {
        val obj = element as? JsonObject ?: return null
        val min = obj["min"].finiteNumber() ?: return null
        val max = obj["max"].finiteNumber() ?: return null
        if (!(min > 0.0 && min <= 1.0 && 1.0 <= max)) return null
        return VoiceSpeedRange(min, max)
    }

    private fun JsonObject.transport(direction: VoiceDirection): VoiceTransport? =
        this["transport"].stringOrNull()?.let { VoiceTransport.fromRawValue(it, direction) }

    /** A direction that is not an array = empty; non-object elements in the array are dropped. */
    private fun JsonObject.objects(key: String): List<JsonObject> =
        (this[key] as? JsonArray)?.mapNotNull { it as? JsonObject }.orEmpty()

    private fun JsonElement?.stringOrNull(): String? =
        (this as? JsonPrimitive)?.takeIf { it.isString }?.content

    private fun JsonElement?.isTrue(): Boolean =
        (this as? JsonPrimitive)?.let { !it.isString && it.content == "true" } == true

    private fun JsonElement?.finiteNumber(): Double? {
        val primitive = (this as? JsonPrimitive)?.takeIf { !it.isString } ?: return null
        return primitive.content.toDoubleOrNull()?.takeIf { it.isFinite() }
    }

    /** JSON integer (numerically integral forms such as 1e3 and 600.0 are allowed); strings and decimals do not count. */
    private fun JsonElement?.integerOrNull(): Long? {
        val primitive = (this as? JsonPrimitive)?.takeIf { !it.isString } ?: return null
        primitive.content.toLongOrNull()?.let { return it }
        val number = primitive.content.toDoubleOrNull() ?: return null
        if (!number.isFinite() || number != Math.floor(number)) return null
        if (number < Long.MIN_VALUE.toDouble() || number >= Long.MAX_VALUE.toDouble()) return null
        return number.toLong()
    }

    private fun JsonElement?.positiveInteger(): Long? = integerOrNull()?.takeIf { it >= 1 }

    private fun Long.toIntOrNullExact(): Int? = takeIf { it <= Int.MAX_VALUE }?.toInt()
}
