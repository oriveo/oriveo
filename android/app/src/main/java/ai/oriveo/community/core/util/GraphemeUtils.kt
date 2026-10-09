package ai.oriveo.community.core.util

import java.text.BreakIterator
import java.util.Locale

fun String.graphemeCount(): Int {
    if (isEmpty()) return 0

    if (length <= 64 && all { it.code < 0x80 }) {
        return length
    }

    val iterator = BreakIterator.getCharacterInstance(Locale.getDefault())
    iterator.setText(this)

    var count = 0
    var start = iterator.first()
    while (start != BreakIterator.DONE) {
        val end = iterator.next()
        if (end != BreakIterator.DONE) {
            count++
        }
        start = end
    }
    return count
}

fun String.takeGraphemes(limit: Int): String {
    if (limit <= 0 || isEmpty()) return ""

    if (length <= limit) return this

    val iterator = BreakIterator.getCharacterInstance(Locale.getDefault())
    iterator.setText(this)
    var end = iterator.first()

    repeat(limit) {
        val next = iterator.next()
        if (next == BreakIterator.DONE) {
            return this
        }
        end = next
    }

    return substring(0, end)
}

/**
 * Returns the longest prefix of at most [maxUnits] UTF-16 code units, with the cut moved back to a
 * grapheme boundary (surrogate pairs, combining marks and ZWJ sequences are never split), so the
 * result can be slightly shorter than [maxUnits]. Unlike [takeGraphemes], which counts graphemes,
 * this one measures stored length.
 */
fun String.takeUtf16Units(maxUnits: Int): String {
    if (maxUnits <= 0 || isEmpty()) return ""
    if (length <= maxUnits) return this

    val iterator = BreakIterator.getCharacterInstance(Locale.getDefault())
    iterator.setText(this)
    var cut = if (iterator.isBoundary(maxUnits)) maxUnits else iterator.preceding(maxUnits)
    // BreakIterator's grapheme rules vary with the runtime (older ICU / JDK versions split ZWJ
    // sequences and skin-tone modifiers), so step back once more whenever the two sides of the cut
    // are clearly joined instead of relying on the version of the rule tables.
    while (cut > 0 && cut != BreakIterator.DONE && joinsAcross(cut)) {
        cut = iterator.preceding(cut)
    }
    return if (cut <= 0) "" else substring(0, cut)
}

private fun String.joinsAcross(index: Int): Boolean {
    val before = this[index - 1]
    val after = this[index]
    if (before.isHighSurrogate() && after.isLowSurrogate()) return true
    if (before == ZERO_WIDTH_JOINER || after == ZERO_WIDTH_JOINER) return true
    val next = codePointAt(index)
    if (next in 0xFE00..0xFE0F || next in 0x1F3FB..0x1F3FF) return true
    return when (Character.getType(next)) {
        Character.NON_SPACING_MARK.toInt(),
        Character.ENCLOSING_MARK.toInt(),
        Character.COMBINING_SPACING_MARK.toInt(),
        -> true
        else -> false
    }
}

private const val ZERO_WIDTH_JOINER = '‍'
