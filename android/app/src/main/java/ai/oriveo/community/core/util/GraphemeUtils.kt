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
