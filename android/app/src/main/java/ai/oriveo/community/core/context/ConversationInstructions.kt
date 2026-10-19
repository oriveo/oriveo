package ai.oriveo.community.core.context

/**
 * Normalization of conversation-level instructions (contract `conversation-instructions.v1`): settings, remote reads and backup imports all go through [normalize].
 * All Unicode White_Space becomes ""; otherwise the text is not trimmed and is cut to the first [MAX_CODE_POINTS] code points.
 */
object ConversationInstructions {
    const val MAX_CODE_POINTS = 8000

    fun normalize(text: String): String {
        if (text.all { it.isUnicodeWhiteSpace() }) return ""
        if (text.length <= MAX_CODE_POINTS) return text
        if (text.codePointCount(0, text.length) <= MAX_CODE_POINTS) return text
        return text.substring(0, text.offsetByCodePoints(0, MAX_CODE_POINTS))
    }
}
