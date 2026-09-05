package ai.oriveo.community.core.provider

/**
 * Character validation for API key entry.
 *
 * The API keys of the mainstream providers (OpenAI, Anthropic, Gemini, DeepSeek and the rest) are
 * all printable ASCII, from 0x20 (space) to 0x7e (tilde). They never contain newlines, tabs,
 * non-Latin characters, full-width spaces or zero-width whitespace.
 *
 * If any of those slip in while pasting - most commonly a whole block copied out of a terminal,
 * dragging a newline and some extra text along with it - Ktor validates the Authorization and
 * other header values while building the request and throws `IllegalHeaderValueException` (error
 * code 10 is the newline `\n`). `String.trim()` only removes leading and trailing whitespace and
 * cannot catch a newline or stray character sitting in the middle, so the key is validated
 * explicitly before it is saved or probed, and the user gets a localized hint instead of the raw
 * low-level failure.
 */
object ProviderKeyInput {
    private val PRINTABLE_ASCII = 0x20..0x7e

    /**
     * Whether every character of the key falls inside the printable ASCII range.
     *
     * An empty string returns `false`; emptiness itself is handled by the non-empty check each entry
     * point already has, so that meaning is not duplicated here. Any character with code < 0x20 or
     * > 0x7e - newlines, tabs and anything non-ASCII included - returns `false`.
     */
    fun isPrintableAsciiKey(key: String): Boolean {
        if (key.isEmpty()) return false
        return key.all { it.code in PRINTABLE_ASCII }
    }
}
