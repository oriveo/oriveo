package ai.oriveo.community.core.context

/**
 * Unicode White_Space: U+0009–000D, 0020, 0085, 00A0, 1680, 2000–200A, 2028, 2029, 202F, 205F, 3000.
 * U+FEFF and U+001C–001F are not white space (Kotlin's [Char.isWhitespace] counts 001C–001F and misses 0085).
 */
fun Char.isUnicodeWhiteSpace(): Boolean = when (this) {
    in '\u0009'..'\u000D', ' ', '\u0085', ' ', ' ', in ' '..' ',
    ' ', ' ', ' ', ' ', '　' -> true
    else -> false
}

/** Trims the Unicode White_Space set from both ends; the same set on all three clients. */
fun String.trimWhiteSpace(): String = trim { it.isUnicodeWhiteSpace() }
