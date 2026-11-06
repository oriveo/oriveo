package ai.oriveo.community.ui.component.markdown

import androidx.compose.ui.text.AnnotatedString
import java.text.BreakIterator
import java.util.Locale

/**
 * Most style ranges one Text may carry.
 *
 * Text layout is quadratic in style ranges, not linear in length: `flattenFontStylesAndApply` rescans
 * every range per transition, `SpannableStringInternal` finds each span by linear search (`setSpan`,
 * `getSpanStart/End/Flags`), and `TextLine.handleRun` walks every span per run. None of it can leave
 * the main thread, and a list cell measures its whole Text in one pass, so a reply with thousands of
 * inline styles froze a low-end device for 30+ seconds. Many small Texts cost linearly.
 */
internal const val MAX_SPANS_PER_TEXT = 128

/** Most UTF-16 units one Text may carry; prose paragraphs stay well below it and are never split. */
internal const val MAX_CHARS_PER_TEXT = 4_096

/**
 * One Text's worth of a rendered inline string. [charsAfter] is how far it sits from the end of the
 * block, which is what the tail fade measures distance from.
 */
internal data class InlineTextSegment(val text: AnnotatedString, val charsAfter: Int)

/**
 * Splits [rendered] into segments within the budgets; a string already within them comes back whole.
 *
 * Breaks prefer a line break (dropped: stacked Texts already start a new line, and selection copies
 * a newline between Texts), then a sentence end, then whitespace, then any grapheme boundary outside
 * a style range. Each cut depends only on text before it, so a growing streamed block keeps its
 * earlier segments equal and Compose skips relaying them.
 */
internal fun inlineTextSegments(
    rendered: AnnotatedString,
    maxSpans: Int = MAX_SPANS_PER_TEXT,
    maxChars: Int = MAX_CHARS_PER_TEXT,
): List<InlineTextSegment> {
    require(maxSpans > 0 && maxChars > 0)
    val length = rendered.length
    val styles = StyleRanges.of(rendered)
    if (length <= maxChars && styles.count <= maxSpans) return listOf(InlineTextSegment(rendered, 0))

    val text = rendered.text
    val cuts = ArrayList<IntArray>()
    var start = 0
    while (start < length) {
        val limit = minOf(start + maxChars, styles.startOfSpanAfter(start, maxSpans) ?: length)
            .coerceAtLeast(start + 1)
        if (limit >= length) {
            cuts += intArrayOf(start, length)
            break
        }
        val newline = lastNewline(text, start, limit)
        if (newline >= 0) {
            cuts += intArrayOf(start, newline)
            start = newline + 1
        } else {
            val end = softBreak(text, start, limit, styles)
            cuts += intArrayOf(start, end)
            start = end
        }
    }
    return cuts.map { (from, to) -> InlineTextSegment(rendered.subSequence(from, to), length - to) }
}

private fun floorOf(start: Int, limit: Int): Int = (start + (limit - start) / 2).coerceAtLeast(start + 1)

/** Last newline in the upper half of (start, limit): a cut this close to the budget wastes no Text. */
private fun lastNewline(text: String, start: Int, limit: Int): Int {
    for (i in limit - 1 downTo floorOf(start, limit)) {
        if (text[i] == '\n') return i
    }
    return -1
}

private fun softBreak(text: String, start: Int, limit: Int, styles: StyleRanges): Int {
    val floor = floorOf(start, limit)
    for (i in limit - 1 downTo floor) {
        if (text[i] !in SENTENCE_ENDS) continue
        var end = i + 1
        while (end < limit && text[end].isWhitespace() && text[end] != '\n') end += 1
        if (!styles.covers(end)) return end
    }
    for (i in limit - 1 downTo floor) {
        if (text[i].isWhitespace() && !styles.covers(i + 1)) return i + 1
    }
    val boundary = graphemeBoundary(text, start, limit)
    return styles.startOfRangeCovering(boundary)?.takeIf { it > start } ?: boundary
}

private fun graphemeBoundary(text: String, start: Int, limit: Int): Int {
    val iterator = BreakIterator.getCharacterInstance(Locale.ROOT)
    iterator.setText(text.substring(start, minOf(text.length, limit + 64)))
    val boundary = iterator.preceding(limit - start + 1)
    return if (boundary == BreakIterator.DONE || boundary <= 0) limit else start + boundary
}

private val SENTENCE_ENDS = setOf('.', '!', '?', '\u3002', '\uFF01', '\uFF1F', '\u061F', '\u06D4', '\u0964', '\u0965')

/** Span starts in order, plus the same ranges merged, so a cut can be tested without rescanning. */
private class StyleRanges(
    private val starts: IntArray,
    private val mergedStarts: IntArray,
    private val mergedEnds: IntArray,
) {
    val count: Int get() = starts.size

    /** Start of the first span past the [budget] that begin at or after [from]; null when none is. */
    fun startOfSpanAfter(from: Int, budget: Int): Int? {
        var low = 0
        var high = starts.size
        while (low < high) {
            val mid = (low + high) ushr 1
            if (starts[mid] < from) low = mid + 1 else high = mid
        }
        return starts.getOrNull(low + budget)
    }

    fun covers(offset: Int): Boolean = mergedIndexCovering(offset) >= 0

    fun startOfRangeCovering(offset: Int): Int? =
        mergedIndexCovering(offset).takeIf { it >= 0 }?.let { mergedStarts[it] }

    /** A cut at [offset] falls between units `offset - 1` and `offset`; range edges don't count. */
    private fun mergedIndexCovering(offset: Int): Int {
        var low = 0
        var high = mergedStarts.size - 1
        while (low <= high) {
            val mid = (low + high) ushr 1
            when {
                offset <= mergedStarts[mid] -> high = mid - 1
                offset >= mergedEnds[mid] -> low = mid + 1
                else -> return mid
            }
        }
        return -1
    }

    companion object {
        fun of(rendered: AnnotatedString): StyleRanges {
            val length = rendered.length
            val ranges = buildList {
                rendered.spanStyles.forEach { add(it.start to it.end) }
                rendered.getLinkAnnotations(0, length).forEach { add(it.start to it.end) }
                rendered.getStringAnnotations(0, length).forEach { add(it.start to it.end) }
            }.filter { (from, to) -> from < to }.sortedBy { it.first }

            val mergedStarts = IntArray(ranges.size)
            val mergedEnds = IntArray(ranges.size)
            var merged = 0
            ranges.forEach { (from, to) ->
                if (merged > 0 && from < mergedEnds[merged - 1]) {
                    mergedEnds[merged - 1] = maxOf(mergedEnds[merged - 1], to)
                } else {
                    mergedStarts[merged] = from
                    mergedEnds[merged] = to
                    merged += 1
                }
            }
            return StyleRanges(
                starts = IntArray(ranges.size) { ranges[it].first },
                mergedStarts = mergedStarts.copyOf(merged),
                mergedEnds = mergedEnds.copyOf(merged),
            )
        }
    }
}
