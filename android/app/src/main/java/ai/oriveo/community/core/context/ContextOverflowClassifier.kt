package ai.oriveo.community.core.context

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** Protocol families for overflow detection (one more than [StopFamily]: openai_compatible). */
enum class OverflowFamily(val wire: String) {
    OPENAI_CHAT("openai_chat"),
    OPENAI_RESPONSES("openai_responses"),
    OPENAI_COMPATIBLE("openai_compatible"),
    ANTHROPIC("anthropic"),
    GEMINI("gemini"),
    MANAGED("managed"),
    FREE("free"),
    ;

    companion object {
        fun fromWire(wire: String): OverflowFamily = entries.first { it.wire == wire }
    }
}

/** What an overflow verdict was based on (overflow-errors.v1 expected.via). */
enum class OverflowVia(val wire: String) {
    CODE("code"),
    TYPE_REGEX("type+regex"),
    STATUS_REGEX("status+regex"),
    STATUS_413("status413"),
}

data class OverflowVerdict(val overflow: Boolean, val via: OverflowVia?) {
    companion object {
        val NOT_OVERFLOW = OverflowVerdict(false, null)
    }
}

/** Pure function recognizing context overflow; the rules are the rules in overflow-errors.v1.json. */
object ContextOverflowClassifier {

    const val GROUP_OPENAI_COMPATIBLE = "openai_compatible"
    const val GROUP_ANTHROPIC = "anthropic"
    const val GROUP_GEMINI = "gemini"

    /** Identical to the fixture patterns character for character; compilation strips a leading (?i) and matches case-insensitively. */
    val defaultPatterns: Map<String, String> = mapOf(
        GROUP_OPENAI_COMPATIBLE to "(?i)(maximum context length|context length (is|of)|context window|exceeds? the (model'?s? )?(maximum )?context|prompt is too long|too many tokens in (the )?(prompt|input|messages)|exceeded model token limit|reduce the length of the (messages|prompt|input))",
        GROUP_ANTHROPIC to "(?i)(prompt is too long|input length and `?max_tokens`? exceed context limit)",
        GROUP_GEMINI to "(?i)(input token count.*exceeds the maximum number of tokens|exceeds the maximum number of tokens allowed)",
    )

    private const val CASE_INSENSITIVE_PREFIX = "(?i)"
    private const val OPENAI_OVERFLOW_CODE = "context_length_exceeded"
    private const val MANAGED_OVERFLOW_CODE = "CONTEXT_LENGTH_EXCEEDED"
    private const val FREE_OVERFLOW_CODE = "40022"
    private const val FREE_OVERFLOW_REASON = "free_context_length_exceeded"
    private const val ANTHROPIC_INVALID_REQUEST = "invalid_request_error"

    private val defaultCompiled: Map<String, List<Regex>> =
        defaultPatterns.mapValues { (_, p) -> listOfNotNull(compile(p)) }

    /** Overflow in a streaming finish reason: only context_window_exceeded. */
    fun isOverflow(stopReason: StopReason?): Boolean = stopReason == StopReason.CONTEXT_WINDOW_EXCEEDED

    /**
     * [body] is the raw response body string; when it does not parse as JSON only 413 counts.
     * [extraPatterns] maps a group name to extra regexes (OR-ed with the defaults); ones that fail to compile are skipped.
     */
    fun classify(
        family: OverflowFamily,
        status: Int,
        body: String,
        extraPatterns: Map<String, List<String>> = emptyMap(),
    ): OverflowVerdict {
        if (status == 401 || status == 429 || status >= 500) return OverflowVerdict.NOT_OVERFLOW
        val json = runCatching { Json.parseToJsonElement(body) }.getOrNull() as? JsonObject
            ?: return if (status == 413) OverflowVerdict(true, OverflowVia.STATUS_413) else OverflowVerdict.NOT_OVERFLOW
        val error = json["error"] as? JsonObject
        if (hasOverflowCode(json, error)) return OverflowVerdict(true, OverflowVia.CODE)
        if (status == 413) return OverflowVerdict(true, OverflowVia.STATUS_413)
        if (status != 400) return OverflowVerdict.NOT_OVERFLOW
        val group = groupOf(family) ?: return OverflowVerdict.NOT_OVERFLOW
        val message = error?.string("message") ?: json.string("message") ?: return OverflowVerdict.NOT_OVERFLOW
        val regexes = defaultCompiled[group].orEmpty() + extraPatterns[group].orEmpty().mapNotNull(::compile)
        if (regexes.none { it.containsMatchIn(message) }) return OverflowVerdict.NOT_OVERFLOW
        return if (family == OverflowFamily.ANTHROPIC) {
            if (error?.string("type") == ANTHROPIC_INVALID_REQUEST) {
                OverflowVerdict(true, OverflowVia.TYPE_REGEX)
            } else {
                OverflowVerdict.NOT_OVERFLOW
            }
        } else {
            OverflowVerdict(true, OverflowVia.STATUS_REGEX)
        }
    }

    private fun hasOverflowCode(json: JsonObject, error: JsonObject?): Boolean {
        if (error?.string("code") == OPENAI_OVERFLOW_CODE) return true
        val code = json.string("code")
        if (code == MANAGED_OVERFLOW_CODE) return true
        // The free-tier overflow code is only accepted as the number 40022; the string "40022" does not count (same as iOS / Web)
        val rawCode = json["code"] as? JsonPrimitive
        if (rawCode != null && !rawCode.isString && rawCode.content == FREE_OVERFLOW_CODE) return true
        return (json["data"] as? JsonObject)?.string("reason") == FREE_OVERFLOW_REASON
    }

    private fun groupOf(family: OverflowFamily): String? = when (family) {
        OverflowFamily.OPENAI_CHAT, OverflowFamily.OPENAI_RESPONSES, OverflowFamily.OPENAI_COMPATIBLE -> GROUP_OPENAI_COMPATIBLE
        OverflowFamily.ANTHROPIC -> GROUP_ANTHROPIC
        OverflowFamily.GEMINI -> GROUP_GEMINI
        OverflowFamily.MANAGED, OverflowFamily.FREE -> null
    }

    private fun compile(pattern: String): Regex? = runCatching {
        Regex(pattern.removePrefix(CASE_INSENSITIVE_PREFIX), RegexOption.IGNORE_CASE)
    }.getOrNull()

    /** Content of a primitive value (string or number); objects, arrays and null count as missing. */
    private fun JsonObject.string(key: String): String? =
        (this[key] as? JsonPrimitive)?.takeUnless { it is JsonNull }?.content
}
