package ai.oriveo.community.core.provider.relay

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull

/**
 * Extracts the only safe subset of an upstream error body for user-visible failure UI.
 *
 * This is deliberately not a request-debug store: both RelayErrorMapper and SseParser
 * consume it on their production error paths, so keeping it separate makes its live
 * security responsibility explicit.
 */
object RelayDebugSnippet {
    private const val MAX_BYTES = 2048
    private val json = Json { ignoreUnknownKeys = true }

    /**
     * Only extracts `error.{message,code,type}`. Parse failure or an unrecognised shape
     * returns null; a raw upstream body must never reach a card, screenshot, or log.
     */
    fun extract(
        body: String?,
        maxBytes: Int = MAX_BYTES,
        redacting: Collection<String> = emptyList(),
    ): String? {
        if (body.isNullOrEmpty()) return null
        val element = try {
            json.parseToJsonElement(body)
        } catch (_: Exception) {
            return null
        }
        val snippet = whitelistedSnippet(element) ?: return null
        if (snippet.isEmpty()) return null
        val redacted = ai.oriveo.community.core.provider.RelayEndpointPolicy
            .redactCredentials(snippet, redacting)
        return truncateUtf8(redacted, maxBytes)
    }

    private fun whitelistedSnippet(element: JsonElement): String? {
        val obj = element as? JsonObject ?: return null
        val err = obj["error"]
        if (err is JsonPrimitive && err.isString) {
            err.contentOrNull?.takeIf { it.isNotEmpty() }?.let { return it }
        }
        if (err is JsonObject) {
            whitelistedFromFields(err)?.let { return it }
        }
        return whitelistedFromFields(obj)
    }

    private fun whitelistedFromFields(dict: JsonObject): String? {
        for (key in listOf("message", "msg")) {
            (dict[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull?.takeIf { it.isNotEmpty() }
                ?.let { return it }
        }
        (dict["type"] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull?.takeIf { it.isNotEmpty() }
            ?.let { return it }
        val codePrim = dict["code"] as? JsonPrimitive ?: return null
        if (codePrim.isString) return codePrim.contentOrNull?.takeIf { it.isNotEmpty() }
        return codePrim.intOrNull?.toString()
    }

    fun truncateUtf8(s: String, maxBytes: Int): String {
        val bytes = s.toByteArray(Charsets.UTF_8)
        if (bytes.size <= maxBytes) return s
        var cut = maxBytes
        while (cut > 0 && (bytes[cut].toInt() and 0xC0) == 0x80) {
            cut -= 1
        }
        return bytes.copyOf(cut).toString(Charsets.UTF_8) + "…"
    }
}
