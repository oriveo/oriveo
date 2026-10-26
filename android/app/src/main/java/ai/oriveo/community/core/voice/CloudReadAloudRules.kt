package ai.oriveo.community.core.voice

import io.ktor.http.Url
import java.util.Base64
import kotlin.math.floor
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject

/** One read-aloud request chunk: text is the sentences joined by a single space; firstSentenceIndex is the index of the chunk's first sentence in the input sentence list. */
data class TtsChunk(val text: String, val firstSentenceIndex: Int)

/** One hypothesis from the language detector; language is the BCP-47 tag exactly as the detector returned it. */
data class LanguageHypothesis(val language: String, val confidence: Double)

/** What a JSON-style read-aloud response decodes to: raw audio bytes, or a download URL that needs another GET (dashscope_tts). */
sealed interface TtsAudioResponse {
    class Audio(val bytes: ByteArray) : TtsAudioResponse
    data class Download(val url: String) : TtsAudioResponse
}

/** Where to go once automatic retries stop. */
enum class CloudReadAloudFallback(val rawValue: String) {
    /** Continue with the system engine from the failed chunk, and notify only once. */
    SystemFromFailedChunk("fallback_system_from_failed_chunk"),
}

/** Carries delaySec when autoRetry is true, and then when it is false. */
data class CloudReadAloudFailureDecision(
    val autoRetry: Boolean,
    val delaySec: Double? = null,
    val then: CloudReadAloudFallback? = null,
)

/**
 * Pure cloud read-aloud rules. Lengths are always counted in Unicode code points
 * (not grapheme clusters, not UTF-16 units). Produces decision values only; does no playback.
 */
object CloudReadAloudRules {
    const val FIRST_CHUNK_MAX_CODE_POINTS = 200
    const val FIRST_CHUNK_MAX_SENTENCES = 2
    const val LATER_CHUNK_CAP_CODE_POINTS = 1000
    const val SENTENCE_JOINER = " "
    const val PREFETCH_CHUNKS = 1
    const val LANGUAGE_MIN_CONFIDENCE = 0.5
    const val SPEED_DECIMALS = 2
    const val DEFAULT_SPEED = 1.0
    const val AUTO_LANGUAGE = "auto"
    const val REQUEST_METHOD = "POST"

    val XAI_TTS_LANGUAGES: List<String> = listOf(
        "en", "ar-EG", "ar-SA", "ar-AE", "bn", "zh", "fr", "de", "hi", "id",
        "it", "ja", "ko", "pt-BR", "pt-PT", "ru", "es-MX", "es-ES", "tr", "vi",
    )
    /** dashscope_tts language_type: maps the primary subtag of the reading language; anything else is Auto. */
    val DASHSCOPE_LANGUAGE_TYPES: Map<String, String> = mapOf(
        "zh" to "Chinese", "en" to "English", "de" to "German", "it" to "Italian", "pt" to "Portuguese",
        "es" to "Spanish", "ja" to "Japanese", "ko" to "Korean", "fr" to "French", "ru" to "Russian",
    )
    const val DASHSCOPE_AUTO_LANGUAGE_TYPE = "Auto"
    const val GEMINI_TTS_MIME_TYPE = "audio/wav"
    const val MISTRAL_RESPONSE_FORMAT = "mp3"
    private const val HTTP_SCHEME = "http"
    private const val HTTPS_SCHEME = "https"
    private const val BASE64_BLOCK = 4
    private val URL_HEAD = Regex("^([A-Za-z][A-Za-z0-9+.-]*)://([^/?#]*)")
    private val STRICT_BASE64 = Regex("^[A-Za-z0-9+/]*={0,2}$")

    val XAI_DEFAULT_REGION: Map<String, String> = mapOf("ar" to "ar-SA", "es" to "es-MX", "pt" to "pt-BR")

    // ---- Chunking ----

    /**
     * Sentences are first trimmed with the dictation whitespace set and empty ones dropped. Chunk 1 = sentence 1,
     * plus sentence 2 when "s1 s2" fits within min(200, maxChars);
     * chunk k (k >= 2) packs whole sentences up to min(maxChars, 1000, 200 * 2^(k-1)). Sentences are never split;
     * a single over-limit sentence gets a chunk of its own.
     */
    fun ttsChunks(sentences: List<String>, maxChars: Int): List<TtsChunk> {
        val items = sentences.mapIndexedNotNull { index, raw ->
            val text = DictationRules.trim(raw)
            if (text.isEmpty()) null else Triple(index, text, text.codePointCount(0, text.length))
        }
        val chunks = mutableListOf<TtsChunk>()
        var next = 0
        var growth = FIRST_CHUNK_MAX_CODE_POINTS.toLong()
        while (next < items.size) {
            val isFirst = chunks.isEmpty()
            val limit = if (isFirst) {
                minOf(FIRST_CHUNK_MAX_CODE_POINTS, maxChars)
            } else {
                growth = minOf(growth * 2, LATER_CHUNK_CAP_CODE_POINTS.toLong())
                minOf(maxChars.toLong(), LATER_CHUNK_CAP_CODE_POINTS.toLong(), growth).toInt()
            }
            val maxSentences = if (isFirst) FIRST_CHUNK_MAX_SENTENCES else Int.MAX_VALUE
            val start = next
            var length = items[next].third
            next += 1
            while (next < items.size && next - start < maxSentences) {
                val candidate = length + SENTENCE_JOINER.length + items[next].third
                if (candidate > limit) break
                length = candidate
                next += 1
            }
            chunks += TtsChunk(
                text = items.subList(start, next).joinToString(SENTENCE_JOINER) { it.second },
                firstSentenceIndex = items[start].first,
            )
        }
        return chunks
    }

    // ---- Language ----

    /** The highest-confidence hypothesis (ties go to the lexicographically smallest tag); with none, or below 0.5, use the UI locale. */
    fun readingLanguage(hypotheses: List<LanguageHypothesis>, uiLocale: String): String {
        val top = hypotheses.minWithOrNull(
            compareByDescending<LanguageHypothesis> { it.confidence }.thenBy { it.language },
        )
        return if (top == null || top.confidence < LANGUAGE_MIN_CONFIDENCE) uiLocale else top.language
    }

    /**
     * After replacing `_` with `-` and mapping in / iw / ji to id / he / yi: a case-insensitive whole-string match
     * returns the list's spelling; otherwise the primary subtag if it is in the list; otherwise look up the
     * default region; otherwise auto.
     */
    fun xaiLanguage(language: String): String {
        val dashed = language.replace('_', '-')
        val parts = dashed.split('-')
        val primary = parts.first().lowercase()
        val legacy = DictationRules.LEGACY_LANGUAGE_CODES[primary] ?: primary
        val normalized = (listOf(legacy) + parts.drop(1)).joinToString("-")
        XAI_TTS_LANGUAGES.firstOrNull { it.equals(normalized, ignoreCase = true) }?.let { return it }
        XAI_TTS_LANGUAGES.firstOrNull { it.equals(legacy, ignoreCase = true) }?.let { return it }
        return XAI_DEFAULT_REGION[legacy] ?: AUTO_LANGUAGE
    }

    // ---- Speed ----

    /** The slider value is clamped to the entry's speedRange, then rounded to two decimals via floor(x * 100 + 0.5) / 100; an entry without speedRange is always 1, and a missing value counts as 1. */
    fun effectiveSpeed(entry: VoiceTtsEntry, slider: Double?): Double {
        val range = entry.speedRange ?: return DEFAULT_SPEED
        val clamped = (slider ?: DEFAULT_SPEED).coerceIn(range.min, range.max)
        return floor(clamped * 100 + 0.5) / 100
    }

    /** The Android slider is a Float: convert to Double first, then compute. */
    fun effectiveSpeed(entry: VoiceTtsEntry, slider: Float?): Double = effectiveSpeed(entry, slider?.toDouble())

    // ---- Request ----

    fun requestUrl(baseUrl: String, entry: VoiceTtsEntry): String? = DictationRules.requestUrl(baseUrl, entry.path)

    /** dashscope_tts: normalizes the primary subtag via [DictationRules.languageValue], then looks it up; falls back to Auto. */
    fun dashscopeLanguageType(language: String): String =
        DictationRules.languageValue(language)?.let(DASHSCOPE_LANGUAGE_TYPES::get) ?: DASHSCOPE_AUTO_LANGUAGE_TYPE

    /**
     * openai_speech: {model, input, voice, response_format, speed?};
     * xai_tts: {text, voice_id, language, output_format: {codec}, speed?}, without model. speed is omitted when the effective speed is 1.
     * gemini_tts / mistral_speech / dashscope_tts never send speed.
     */
    fun requestBody(entry: VoiceTtsEntry, text: String, voice: String, slider: Double?, language: String): JsonObject {
        when (entry.transport) {
            VoiceTransport.GeminiTts -> return buildJsonObject {
                put("model", entry.model)
                put("store", false)
                putJsonArray("input") {
                    addJsonObject {
                        put("type", "user_input")
                        putJsonArray("content") {
                            addJsonObject {
                                put("type", "text")
                                put("text", text)
                            }
                        }
                    }
                }
                putJsonObject("response_format") {
                    put("type", "audio")
                    put("mime_type", GEMINI_TTS_MIME_TYPE)
                }
                putJsonObject("generation_config") {
                    putJsonArray("speech_config") { addJsonObject { put("voice", voice) } }
                }
            }
            VoiceTransport.MistralSpeech -> return buildJsonObject {
                put("model", entry.model)
                put("input", text)
                put("voice_id", voice)
                put("response_format", MISTRAL_RESPONSE_FORMAT)
            }
            VoiceTransport.DashscopeTts -> return buildJsonObject {
                put("model", entry.model)
                putJsonObject("input") {
                    put("text", text)
                    put("voice", voice)
                    put("language_type", dashscopeLanguageType(language))
                }
            }
            else -> Unit
        }
        val speed = effectiveSpeed(entry, slider).takeIf { it != DEFAULT_SPEED }
        return buildJsonObject {
            when (entry.transport) {
                VoiceTransport.XaiTts -> {
                    put("text", text)
                    put("voice_id", voice)
                    put("language", xaiLanguage(language))
                    put("output_format", buildJsonObject { put("codec", entry.outputFormat) })
                }
                else -> {
                    put("model", entry.model)
                    put("input", text)
                    put("voice", voice)
                    put("response_format", entry.outputFormat)
                }
            }
            if (speed != null) put("speed", speedValue(speed))
        }
    }

    fun requestBody(entry: VoiceTtsEntry, text: String, voice: String, slider: Float?, language: String): JsonObject =
        requestBody(entry, text, voice, slider?.toDouble(), language)

    /** Transports whose response body is JSON and must be decoded to get the audio; for the rest (openai_speech / xai_tts) the response body is the audio itself. */
    fun isJsonResponse(transport: VoiceTransport): Boolean =
        transport == VoiceTransport.GeminiTts ||
            transport == VoiceTransport.MistralSpeech ||
            transport == VoiceTransport.DashscopeTts

    /**
     * gemini_tts: takes only the first block whose type is audio and strictly base64-decodes its data (empty means invalid; no further search);
     * mistral_speech: strictly base64-decodes audio_data; dashscope_tts: accepts only output.audio.url, parsed as a URL;
     * an http scheme (case-insensitive) is first rewritten to https (the Tongyi OSS address is downloadable over https at the same address), then the scheme must be https and the host non-empty.
     * A missing field, bad base64, or an empty decoded result all yield null (invalidResponse).
     */
    fun audioResponse(transport: VoiceTransport, body: JsonElement?): TtsAudioResponse? = when (transport) {
        VoiceTransport.GeminiTts -> geminiAudioData(body)?.let(::decodeAudio)
        VoiceTransport.MistralSpeech -> (body as? JsonObject)?.stringField("audio_data")?.let(::decodeAudio)
        VoiceTransport.DashscopeTts -> {
            val audio = ((body as? JsonObject)?.get("output") as? JsonObject)?.get("audio") as? JsonObject
            audio?.stringField("url")?.let(::upgradeHttp)?.takeIf(::isHttpsUrl)?.let { TtsAudioResponse.Download(it) }
        }
        else -> null
    }

    private fun geminiAudioData(body: JsonElement?): String? {
        val steps = (body as? JsonObject)?.get("steps") as? JsonArray ?: return null
        for (step in steps) {
            val content = (step as? JsonObject)?.get("content") as? JsonArray ?: continue
            for (part in content) {
                val obj = part as? JsonObject ?: continue
                if (obj.stringField("type") == "audio") return obj.stringField("data")
            }
        }
        return null
    }

    /** Rewrites an http scheme (case-insensitive) to https; anything else is returned unchanged. */
    private fun upgradeHttp(raw: String): String {
        val scheme = URL_HEAD.find(raw)?.groups?.get(1) ?: return raw
        if (!scheme.value.equals(HTTP_SCHEME, ignoreCase = true)) return raw
        return HTTPS_SCHEME + raw.substring(scheme.range.last + 1)
    }

    /**
     * Lenient parsing: java.net.URI returns null for a host containing an underscore, while this allows underscores.
     * The host is taken from the raw string's authority (minus userinfo / port), because Ktor Url fills in
     * localhost when the host is missing; the whole string must still be parseable by Ktor Url.
     */
    private fun isHttpsUrl(raw: String): Boolean {
        val match = URL_HEAD.find(raw) ?: return false
        if (!match.groupValues[1].equals(HTTPS_SCHEME, ignoreCase = true)) return false
        val host = match.groupValues[2].substringAfterLast('@').let { authority ->
            // An IPv6 literal missing its closing bracket is invalid
            if (authority.startsWith("[")) {
                if (!authority.contains(']')) return false
                authority.substringBefore(']').removePrefix("[")
            } else {
                authority.substringBefore(':')
            }
        }
        return host.isNotEmpty() && runCatching { Url(raw) }.isSuccess
    }

    /** Strict base64: length is a multiple of 4, padding is required, and only the standard alphabet is allowed. */
    private fun decodeAudio(base64: String): TtsAudioResponse? {
        if (base64.length % BASE64_BLOCK != 0 || !STRICT_BASE64.matches(base64)) return null
        val bytes = runCatching { Base64.getDecoder().decode(base64) }.getOrNull() ?: return null
        return if (bytes.isEmpty()) null else TtsAudioResponse.Audio(bytes)
    }

    private fun JsonObject.stringField(key: String): String? =
        (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

    /** Integral speeds are written as integers (2 rather than 2.0) so the bytes on the wire stay stable. */
    private fun speedValue(speed: Double): JsonPrimitive =
        if (speed == floor(speed)) JsonPrimitive(speed.toLong()) else JsonPrimitive(speed)

    // ---- Failure ----

    /** Per-chunk automatic retry follows the dictation rules; once retries stop (including 401 / 403), switch to the system engine from the failed chunk. */
    fun failureDecision(failure: DictationFailure, attempt: Int): CloudReadAloudFailureDecision {
        val dictation = DictationRules.failureDecision(failure, attempt)
        return if (dictation.autoRetry) {
            CloudReadAloudFailureDecision(autoRetry = true, delaySec = dictation.delaySec)
        } else {
            CloudReadAloudFailureDecision(autoRetry = false, then = CloudReadAloudFallback.SystemFromFailedChunk)
        }
    }
}
