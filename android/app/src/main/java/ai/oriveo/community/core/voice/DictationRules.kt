package ai.oriveo.community.core.voice

import java.net.URI
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

/** Recording precheck result; too_short and no_speech both show "no sound heard" and are not uploaded. */
enum class DictationPrecheck(val rawValue: String) {
    Ok("ok"),
    TooShort("too_short"),
    NoSpeech("no_speech"),
}

/** A slice or a silence interval, in seconds, rounded to 3 decimal places. */
data class DictationSpan(val startSec: Double, val endSec: Double)

/** Input field content and cursor (UTF-16 offset) after inserting the transcript. */
data class DictationInsertion(val text: String, val cursor: Int)

/** Reason a dictation request failed; retryAfter is the Retry-After header verbatim. */
sealed interface DictationFailure {
    data object Network : DictationFailure
    data object Timeout : DictationFailure
    data class Http(val status: Int, val retryAfter: String? = null) : DictationFailure

    /** The response lacks text or text is not a string: treated as a permanent failure. */
    data object InvalidResponse : DictationFailure

    /** The connection baseUrl cannot form a request URL: no request is sent, and the primary button goes to check the connection. */
    data object InvalidEndpoint : DictationFailure

    /** Remuxing the slot's .aac to m4a failed: no request is sent and no automatic retry. */
    data object ExportFailed : DictationFailure

    /** The system recognizer reported an error (SpeechRecognizer.ERROR_*, excluding not understood / no speech): no automatic retry, the primary button retries. */
    data class Recognizer(val code: Int) : DictationFailure
}

enum class DictationPrimaryAction(val rawValue: String) {
    Retry("retry"),
    CheckConnection("check_connection"),
}

/** When autoRetry is true it carries delaySec; when false it carries primaryAction and the recording stays in the slot. */
data class DictationFailureDecision(
    val autoRetry: Boolean,
    val delaySec: Double? = null,
    val primaryAction: DictationPrimaryAction? = null,
)

/** One multipart part, in send order; the file part is always last. */
sealed interface DictationRequestPart {
    val name: String

    data class Field(override val name: String, val value: String) : DictationRequestPart

    data class File(
        override val name: String,
        val filename: String,
        val contentType: String,
    ) : DictationRequestPart
}

/**
  * Pure dictation rules, implementing the dictation contract item by item.
  * Text is handled by Unicode code point (not grapheme cluster, not UTF-16), except that the insertion offset is in UTF-16.
 */
object DictationRules {
    const val WINDOW_SEC = 0.05
    const val SPEECH_THRESHOLD_DBFS = -45.0
    const val MIN_DURATION_SEC = 0.5
    const val MIN_VOICED_WINDOWS = 6
    const val MIN_SILENCE_RUN_WINDOWS = 8
    const val BYTE_SAFETY_FACTOR = 0.9
    const val SECONDS_DECIMALS = 3
    const val COMPARE_TOLERANCE = 1e-9
    const val DISCARD_UNDO_ABOVE_SEC = 5.0
    const val PENDING_RETENTION_SEC = 604_800.0
    const val MAX_AUTO_RETRIES = 1
    const val DEFAULT_RETRY_DELAY_SEC = 1.0
    const val MAX_RETRY_AFTER_SEC = 10.0
    val TRANSIENT_HTTP_STATUSES: Set<Int> = setOf(408, 409, 429)
    const val TRANSIENT_HTTP_FROM = 500
    val AUTH_HTTP_STATUSES: Set<Int> = setOf(401, 403)

    const val REQUEST_METHOD = "POST"
    const val MODEL_PART = "model"
    const val FILE_PART = "file"
    const val FILE_NAME = "audio.m4a"
    const val FILE_CONTENT_TYPE = "audio/mp4"
    const val JSON_CONTENT_TYPE = "application/json"
    const val GEMINI_AUDIO_MIME = "audio/m4a"
    const val DASHSCOPE_AUDIO_DATA_PREFIX = "data:audio/mp4;base64,"
    const val DASHSCOPE_AUDIO_FORMAT = "m4a"
    const val DASHSCOPE_LANGUAGE_FIELD = "language_hints"
    val LEGACY_LANGUAGE_CODES: Map<String, String> = mapOf("in" to "id", "iw" to "he", "ji" to "yi")

    /** Only this set of whitespace is recognized (no platform trim: U+0085 / U+FEFF are kept). */
    val WHITESPACE: Set<Int> = setOf(
        0x0020, 0x0009, 0x000A, 0x000B, 0x000C, 0x000D, 0x00A0, 0x1680,
        0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007,
        0x2008, 0x2009, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000,
    )

    /** Code point ranges (inclusive) of writing systems that do not put spaces between words. */
    val NO_SPACE_SCRIPTS: List<IntRange> = listOf(
        0x0E00..0x0E7F,
        0x0E80..0x0EFF,
        0x1000..0x109F,
        0x1780..0x17FF,
        0x2E80..0x2FFF,
        0x3000..0x303F,
        0x3040..0x309F,
        0x30A0..0x30FF,
        0x31F0..0x31FF,
        0x3400..0x4DBF,
        0x4E00..0x9FFF,
        0xF900..0xFAFF,
        0xFF00..0xFFEF,
        0x20000..0x3FFFF,
    )

    val NO_SPACE_BEFORE: Set<Int> = ",.!?;:)]}%…".codePointSet()
    val NO_SPACE_AFTER: Set<Int> = "([{¿¡".codePointSet()

    private const val GEMINI_TRANSPORT_PREFIX = "gemini_"
    private const val GOOG_API_KEY_HEADER = "x-goog-api-key"

    private val RETRY_AFTER_PATTERN = Regex("^[0-9]+(\\.[0-9]+)?$")

    // ---- Precheck and silence ----

    /** RMS dBFS of each 50 ms envelope window; null is digital silence. Counted in windows, not seconds. */
    fun precheck(durationSec: Double, envelope: List<Double?>): DictationPrecheck {
        if (durationSec < MIN_DURATION_SEC) return DictationPrecheck.TooShort
        val voiced = envelope.count { it != null && it >= SPEECH_THRESHOLD_DBFS }
        return if (voiced < MIN_VOICED_WINDOWS) DictationPrecheck.NoSpeech else DictationPrecheck.Ok
    }

    /** Runs of ≥ 8 consecutive silent windows (null or below threshold); boundaries are window boundaries rounded to 3 decimal places. */
    fun silenceRuns(envelope: List<Double?>): List<DictationSpan> {
        val runs = mutableListOf<DictationSpan>()
        var runStart = -1
        fun close(end: Int) {
            if (runStart >= 0 && end - runStart >= MIN_SILENCE_RUN_WINDOWS) {
                runs += DictationSpan(roundSeconds(runStart * WINDOW_SEC), roundSeconds(end * WINDOW_SEC))
            }
            runStart = -1
        }
        envelope.forEachIndexed { index, value ->
            val silent = value == null || value < SPEECH_THRESHOLD_DBFS
            if (silent) {
                if (runStart < 0) runStart = index
            } else {
                close(index)
            }
        }
        close(envelope.size)
        return runs
    }

    // ---- Slicing ----

    fun segmentPlan(
        entry: VoiceSttEntry,
        durationSec: Double,
        uploadBytes: Long,
        silences: List<DictationSpan>,
    ): List<DictationSpan> = segmentPlan(
        maxBytes = entry.maxBytes,
        maxDurationSec = entry.maxDurationSec.toDouble(),
        durationSec = durationSec,
        uploadBytes = uploadBytes,
        silences = silences,
    )

    /**
      * Lmax = min(maxDurationSec, maxBytes × 0.9 / bytesPerSec); starting from 0, while the remainder exceeds Lmax, cut at the
      * latest silence midpoint within [s + Lmax/2, s + Lmax], or hard-cut at s + Lmax if there is none.
     */
    fun segmentPlan(
        maxBytes: Long,
        maxDurationSec: Double,
        durationSec: Double,
        uploadBytes: Long,
        silences: List<DictationSpan>,
    ): List<DictationSpan> {
        val end = roundSeconds(durationSec)
        if (!(durationSec > 0)) return listOf(DictationSpan(0.0, end))
        val bytesPerSec = uploadBytes.toDouble() / durationSec
        val byteBound = if (bytesPerSec > 0) maxBytes * BYTE_SAFETY_FACTOR / bytesPerSec else Double.POSITIVE_INFINITY
        val lmax = minOf(maxDurationSec, byteBound)
        val midpoints = silences.map { roundSeconds((it.startSec + it.endSec) / 2) }
        val segments = mutableListOf<DictationSpan>()
        var start = 0.0
        while (durationSec - start > lmax + COMPARE_TOLERANCE) {
            val lo = start + lmax / 2
            val hi = start + lmax
            val cut = midpoints
                .filter { it >= lo - COMPARE_TOLERANCE && it <= hi + COMPARE_TOLERANCE }
                .maxOrNull()
                ?: roundSeconds(hi)
            // Defensive: stop slicing when Lmax is so small that it does not advance after rounding, to avoid an infinite loop.
            if (cut <= start) break
            segments += DictationSpan(start, cut)
            start = cut
        }
        segments += DictationSpan(start, end)
        return segments
    }

    // ---- Text ----

    /** Each segment is trimmed and empty segments dropped, then needsSpace decides whether to insert one U+0020. */
    fun join(texts: List<String>): String {
        val out = StringBuilder()
        for (raw in texts) {
            val text = trim(raw)
            if (text.isEmpty()) continue
            if (out.isNotEmpty() && needsSpace(lastCodePoint(out), firstCodePoint(text))) out.append(' ')
            out.append(text)
        }
        return out.toString()
    }

    /** Insertion point = max(selectionStart, selectionEnd) (UTF-16); selected text is kept, not overwritten. */
    fun insert(text: String, selectionStart: Int, selectionEnd: Int, transcript: String): DictationInsertion {
        val inserted = trim(transcript)
        if (inserted.isEmpty()) return DictationInsertion(text, selectionEnd.coerceIn(0, text.length))
        val offset = maxOf(selectionStart, selectionEnd).coerceIn(0, text.length)
        val before = if (offset > 0) Character.codePointBefore(text, offset) else null
        val after = if (offset < text.length) text.codePointAt(offset) else null
        val leading = if (needsSpace(before, firstCodePoint(inserted))) " " else ""
        val trailing = if (needsSpace(lastCodePoint(inserted), after)) " " else ""
        val result = text.substring(0, offset) + leading + inserted + trailing + text.substring(offset)
        return DictationInsertion(result, offset + leading.length + inserted.length)
    }

    fun needsSpace(left: Int?, right: Int?): Boolean {
        if (left == null || right == null) return false
        if (left in WHITESPACE || right in WHITESPACE) return false
        if (isNoSpaceScript(left) || isNoSpaceScript(right)) return false
        if (right in NO_SPACE_BEFORE || left in NO_SPACE_AFTER) return false
        return true
    }

    fun isNoSpaceScript(codePoint: Int): Boolean = NO_SPACE_SCRIPTS.any { codePoint in it }

    /** Trims only leading and trailing code points in the WHITESPACE set. */
    fun trim(text: String): String {
        var start = 0
        while (start < text.length) {
            val cp = text.codePointAt(start)
            if (cp !in WHITESPACE) break
            start += Character.charCount(cp)
        }
        var end = text.length
        while (end > start) {
            val cp = Character.codePointBefore(text, end)
            if (cp !in WHITESPACE) break
            end -= Character.charCount(cp)
        }
        return text.substring(start, end)
    }

    // ---- Failure and retry ----

    fun failureDecision(failure: DictationFailure, attempt: Int): DictationFailureDecision {
        val status = (failure as? DictationFailure.Http)?.status
        val transient = when (failure) {
            DictationFailure.Network, DictationFailure.Timeout -> true
            is DictationFailure.Http ->
                failure.status in TRANSIENT_HTTP_STATUSES || failure.status >= TRANSIENT_HTTP_FROM
            DictationFailure.InvalidResponse, DictationFailure.InvalidEndpoint, DictationFailure.ExportFailed,
            is DictationFailure.Recognizer -> false
        }
        if (transient && attempt <= MAX_AUTO_RETRIES) {
            val retryAfter = (failure as? DictationFailure.Http)?.retryAfter?.let(::parseRetryAfter)
            if (retryAfter == null || retryAfter <= MAX_RETRY_AFTER_SEC) {
                return DictationFailureDecision(autoRetry = true, delaySec = retryAfter ?: DEFAULT_RETRY_DELAY_SEC)
            }
        }
        val action = if (failure == DictationFailure.InvalidEndpoint || (status != null && status in AUTH_HTTP_STATUSES)) {
            DictationPrimaryAction.CheckConnection
        } else {
            DictationPrimaryAction.Retry
        }
        return DictationFailureDecision(autoRetry = false, primaryAction = action)
    }

    /** Accepts only non-negative decimal seconds; HTTP-date and the like are treated as absent. */
    fun parseRetryAfter(raw: String): Double? {
        val value = raw.trim()
        if (!RETRY_AFTER_PATTERN.matches(value)) return null
        return value.toDoubleOrNull()
    }

    // ---- Request and response ----

    /** The connection URL keeps only scheme://host[:port], followed by the directory path; an empty string, or one without scheme or host, returns null. */
    fun requestUrl(baseUrl: String, path: String): String? {
        val trimmed = baseUrl.trim()
        if (trimmed.isEmpty()) return null
        val uri = runCatching { URI(trimmed) }.getOrNull() ?: return null
        val scheme = uri.scheme?.takeIf { it.isNotEmpty() } ?: return null
        val host = uri.host?.takeIf { it.isNotEmpty() } ?: return null
        val port = if (uri.port >= 0) ":${uri.port}" else ""
        val normalizedPath = if (path.startsWith("/")) path else "/$path"
        return "$scheme://$host$port$normalizedPath"
    }

    fun requestUrl(baseUrl: String, entry: VoiceSttEntry): String? = requestUrl(baseUrl, entry.path)

    fun authorizationHeader(apiKey: String): Pair<String, String> = "Authorization" to "Bearer $apiKey"

    /** The auth header is decided by transport only: gemini_* uses x-goog-api-key, the rest Bearer (shared by dictation and read-aloud). */
    fun authorizationHeader(transport: VoiceTransport, apiKey: String): Pair<String, String> =
        if (transport.rawValue.startsWith(GEMINI_TRANSPORT_PREFIX)) {
            GOOG_API_KEY_HEADER to apiKey
        } else {
            authorizationHeader(apiKey)
        }

    /** JSON-style dictation (gemini_transcribe / dashscope_asr); other transports use multipart. */
    fun isJsonRequest(transport: VoiceTransport): Boolean =
        transport == VoiceTransport.GeminiTranscribe || transport == VoiceTransport.DashscopeAsr

    fun requestJson(entry: VoiceSttEntry, language: String?, audioBase64: String): JsonObject? =
        requestJson(entry.transport, entry.model, entry.languageField, language, audioBase64)

    /**
      * gemini_transcribe: {model, store:false, input:[{type:audio, mime_type, data}]}, no language sent;
      * dashscope_asr: audio goes into messages as a data URI; when a language is selected and languageField is language_hints, parameters.language_hints is included.
      * Returns null for multipart transports.
     */
    fun requestJson(
        transport: VoiceTransport,
        model: String,
        languageField: String?,
        language: String?,
        audioBase64: String,
    ): JsonObject? = when (transport) {
        VoiceTransport.GeminiTranscribe -> buildJsonObject {
            put("model", model)
            put("store", false)
            putJsonArray("input") {
                addJsonObject {
                    put("type", "audio")
                    put("mime_type", GEMINI_AUDIO_MIME)
                    put("data", audioBase64)
                }
            }
        }
        VoiceTransport.DashscopeAsr -> buildJsonObject {
            put("model", model)
            putJsonObject("input") {
                putJsonArray("messages") {
                    addJsonObject {
                        put("role", "user")
                        putJsonArray("content") {
                            addJsonObject {
                                put("type", "input_audio")
                                putJsonObject("input_audio") { put("data", DASHSCOPE_AUDIO_DATA_PREFIX + audioBase64) }
                            }
                        }
                    }
                }
            }
            putJsonObject("parameters") {
                put("format", DASHSCOPE_AUDIO_FORMAT)
                val hint = language?.let(::languageValue)
                if (languageField == DASHSCOPE_LANGUAGE_FIELD && hint != null) {
                    putJsonArray(DASHSCOPE_LANGUAGE_FIELD) { add(hint) }
                }
            }
        }
        else -> null
    }

    fun requestParts(entry: VoiceSttEntry, language: String?): List<DictationRequestPart> =
        requestParts(entry.model, entry.languageField, language)

    /** model → language hint (sent only when languageField exists and a language is selected) → file always last; response_format is not sent. */
    fun requestParts(model: String, languageField: String?, language: String?): List<DictationRequestPart> {
        val parts = mutableListOf<DictationRequestPart>(DictationRequestPart.Field(MODEL_PART, model))
        val hint = language?.let(::languageValue)
        if (languageField != null && hint != null) parts += DictationRequestPart.Field(languageField, hint)
        parts += DictationRequestPart.File(FILE_PART, FILE_NAME, FILE_CONTENT_TYPE)
        return parts
    }

    /** Recognition language → ISO-639-1 primary subtag: `_` becomes `-`, take the first segment, in / iw / ji become id / he / yi. */
    fun languageValue(language: String): String? {
        val primary = language.replace('_', '-').substringBefore('-').lowercase()
        if (primary.isEmpty()) return null
        return LEGACY_LANGUAGE_CODES[primary] ?: primary
    }

    /**
      * Transcript text by transport: gemini_transcribe concatenates the text of all type=text entries in steps[].content[] then trims, empty is invalid;
      * dashscope_asr takes output.text trimmed; others same as [transcript].
     */
    fun transcript(transport: VoiceTransport?, body: JsonElement?): String? = when (transport) {
        VoiceTransport.GeminiTranscribe -> geminiTranscript(body)
        VoiceTransport.DashscopeAsr -> transcript((body as? JsonObject)?.get("output"))
        else -> transcript(body)
    }

    private fun geminiTranscript(body: JsonElement?): String? {
        val steps = (body as? JsonObject)?.get("steps") as? JsonArray ?: return null
        val out = StringBuilder()
        for (step in steps) {
            val content = (step as? JsonObject)?.get("content") as? JsonArray ?: continue
            for (item in content) {
                val obj = item as? JsonObject ?: continue
                if ((obj["type"] as? JsonPrimitive)?.takeIf { it.isString }?.content != "text") continue
                val text = (obj["text"] as? JsonPrimitive)?.takeIf { it.isString } ?: continue
                out.append(text.content)
            }
        }
        return trim(out.toString()).takeIf { it.isNotEmpty() }
    }

    /** Top-level string field text trimmed; missing or not a string returns null (invalid response). */
    fun transcript(body: JsonElement?): String? {
        val text = (body as? JsonObject)?.get("text") as? JsonPrimitive ?: return null
        if (!text.isString) return null
        return trim(text.content)
    }

    // ---- Thresholds ----

    /** The undo hint is shown only when discarding a recording longer than 5 seconds; exactly 5 seconds does not. */
    fun shouldOfferDiscardUndo(durationSec: Double): Boolean = durationSec > DISCARD_UNDO_ABOVE_SEC

    /** Files pending upload older than 7 days are deleted at startup; exactly 7 days is kept. */
    fun isPendingExpired(ageSec: Double): Boolean = ageSec > PENDING_RETENTION_SEC

    fun roundSeconds(value: Double): Double = Math.round(value * 1000.0) / 1000.0

    private fun firstCodePoint(text: CharSequence): Int? = if (text.isEmpty()) null else Character.codePointAt(text, 0)

    private fun lastCodePoint(text: CharSequence): Int? =
        if (text.isEmpty()) null else Character.codePointBefore(text, text.length)

    private fun String.codePointSet(): Set<Int> = codePoints().toArray().toSet()
}
