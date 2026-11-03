package ai.oriveo.community.core.voice.realtime.wire

import ai.oriveo.community.core.voice.realtime.RealtimeTransportKind
import java.util.Locale

private val LEGACY_LANGUAGE = mapOf("in" to "id", "iw" to "he", "ji" to "yi")
private val PRIMARY = Regex("^[a-z]{2}$")
private val SCRIPT = Regex("^[a-z]{4}$", RegexOption.IGNORE_CASE)
private val REGION = Regex("^([a-z]{2}|[0-9]{3})$", RegexOption.IGNORE_CASE)
private val HANT_REGIONS = setOf("TW", "HK", "MO")

/**
 * Converts the host recognition language (BCP-47 or null) into the input transcription language hint for each provider's opening frame; returns null when nothing should be sent.
 * The primary language must be two letters; in / iw / ji normalize to id / he / yi; xAI's es / pt without a region are not sent; Gemini Chinese only sends zh-Hans / zh-Hant.
 */
internal fun transcriptionLanguage(kind: RealtimeTransportKind, tag: String?): String? {
    if (tag == null) return null
    val parts = tag.trim().replace('_', '-').split('-')
    val primary = parts[0].lowercase(Locale.ROOT)
    if (!PRIMARY.matches(primary)) return null
    val lang = LEGACY_LANGUAGE[primary] ?: primary
    var i = 1
    var script: String? = null
    val scriptPart = parts.getOrNull(i).orEmpty()
    if (SCRIPT.matches(scriptPart)) {
        script = scriptPart.lowercase(Locale.ROOT)
        i += 1
    }
    val regionPart = parts.getOrNull(i).orEmpty()
    val region = if (REGION.matches(regionPart)) regionPart.uppercase(Locale.ROOT) else null
    return when (kind) {
        RealtimeTransportKind.OpenAiRealtime -> lang
        RealtimeTransportKind.XaiRealtime ->
            if (lang == "es" || lang == "pt") region?.let { "$lang-$it" } else lang
        RealtimeTransportKind.GeminiLive -> when {
            lang == "zh" -> {
                val hant = script == "hant" || (script == null && region in HANT_REGIONS)
                if (hant) "zh-Hant" else "zh-Hans"
            }
            region != null -> "$lang-$region"
            else -> lang
        }
    }
}
