package ai.oriveo.community.core.provider

/**
 * Escapes a string into a JSON string literal, quotes included.
 * For example: `Hello "world"\n` -> `"Hello \"world\"\\n"`
 */
internal fun escapeJsonString(value: String): String {
    val sb = StringBuilder(value.length + 16)
    sb.append('"')
    for (ch in value) {
        when (ch) {
            '"' -> sb.append("\\\"")
            '\\' -> sb.append("\\\\")
            '\n' -> sb.append("\\n")
            '\r' -> sb.append("\\r")
            '\t' -> sb.append("\\t")
            '\b' -> sb.append("\\b")
            '\u000C' -> sb.append("\\f")
            else -> {
                if (ch.code < 0x20) {
                    sb.append("\\u%04x".format(ch.code))
                } else {
                    sb.append(ch)
                }
            }
        }
    }
    sb.append('"')
    return sb.toString()
}
