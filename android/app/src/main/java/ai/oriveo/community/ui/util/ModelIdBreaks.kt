package ai.oriveo.community.ui.util

/** Zero-width space (U+200B) that permits a line break. */
private const val ZERO_WIDTH_SPACE = '​'

/** Separators after which a model ID may wrap. */
private val MODEL_ID_SEPARATORS = setOf('-', '_', '/')

/**
 * Display only: inserts U+200B after "-", "_" and "/" so long model IDs wrap only at separators
 * instead of mid-word. Accessibility contentDescription and copy always use the raw id.
 */
fun modelIdDisplay(id: String): String {
    if (id.none { it in MODEL_ID_SEPARATORS }) return id
    return buildString(id.length + 8) {
        id.forEach { ch ->
            append(ch)
            if (ch in MODEL_ID_SEPARATORS) append(ZERO_WIDTH_SPACE)
        }
    }
}
