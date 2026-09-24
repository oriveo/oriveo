package ai.oriveo.community.feature.chat.components

import androidx.compose.ui.unit.dp
import java.text.BreakIterator
import java.util.Locale

/**
 * Folding of very long user messages: the bubble lays out only a prefix and the full text opens in
 * [UserMessageFullTextSheet].
 *
 * Why it has to fold: text shaping (StaticLayout, TextKit, the browser) costs time linear in the
 * number of characters, and scripts with ligatures and positioned marks such as Arabic are
 * especially expensive. A Text is not chunked, so the whole message is laid out at once, inside a
 * LazyColumn or not. The only way to make one bubble's main-thread cost independent of message
 * length is to not lay out the whole text.
 *
 * The rule and its parameters are shared with the other clients (web `user-message-fold.ts`);
 * change them together.
 */
object UserMessageFold {
    /** Messages longer than this fold (UTF-16). 6,000 characters is already 4 to 10 screens on a phone. */
    const val THRESHOLD_UTF16 = 6_000

    /** Prefix length cap: enough to fill the folded viewport with room to spare. */
    const val PREVIEW_UTF16 = 2_000

    /** Most line breaks the prefix may carry: a message of short lines need not lay out thousands of them to fill the viewport. */
    const val PREVIEW_LINE_CAP = 60

    /** Soft cap per chunk in the full-text sheet; chunks go into a LazyColumn so only visible ones are laid out. */
    const val READING_CHUNK_UTF16 = 2_048

    /** Visible height of the folded body (about 14 lines); the rest is clipped. */
    val CollapsedTextHeight = 320.dp

    /** Height of the bottom fade, matching the code block card's mask. */
    val FadeHeight = 44.dp

    fun shouldFold(text: String): Boolean = text.length > THRESHOLD_UTF16

    /**
     * Cuts the prefix on a grapheme boundary, never splitting surrogate pairs, combining marks or emoji
     * sequences. BreakIterator only sees a window around the prefix, so the cost does not depend on the
     * full length; the extra slack lets the grapheme that crosses the limit be recognized whole.
     */
    fun preview(text: String): String {
        val window = text.substring(0, minOf(text.length, PREVIEW_UTF16 + 64))
        val iterator = BreakIterator.getCharacterInstance(Locale.ROOT)
        iterator.setText(window)
        var end = iterator.first()
        var newlines = 0
        var boundary = iterator.next()
        while (boundary != BreakIterator.DONE && boundary <= PREVIEW_UTF16) {
            if (window[end].isLineBreak()) {
                newlines += 1
                if (newlines > PREVIEW_LINE_CAP) break
            }
            end = boundary
            boundary = iterator.next()
        }
        return text.substring(0, end)
    }

    /**
     * Reading chunks for the full-text sheet: split on line breaks first, then break overlong
     * paragraphs at the nearest point within [READING_CHUNK_UTF16] (sentence end, then whitespace,
     * then grapheme boundary). Chunks display as paragraphs.
     */
    fun readingChunks(text: String): List<String> {
        val chunks = ArrayList<String>()
        var paragraphStart = 0
        while (paragraphStart <= text.length) {
            val newline = text.indexOf('\n', paragraphStart)
            val paragraphEnd = if (newline < 0) text.length else newline
            var start = paragraphStart
            while (paragraphEnd - start > READING_CHUNK_UTF16) {
                val cut = breakOffset(text, start, start + READING_CHUNK_UTF16)
                chunks += text.substring(start, cut)
                start = cut
            }
            chunks += text.substring(start, paragraphEnd)
            if (newline < 0) break
            paragraphStart = newline + 1
        }
        return chunks
    }

    /** Finds a break in (start, limit]: after sentence-ending punctuation first, then after whitespace, else on a grapheme boundary. */
    private fun breakOffset(text: String, start: Int, limit: Int): Int {
        val floor = start + READING_CHUNK_UTF16 / 2
        for (i in limit - 1 downTo floor) {
            if (text[i] in SENTENCE_ENDS) {
                // Whitespace after the sentence end stays in this chunk so the next one does not start with it.
                var end = i + 1
                while (end < limit && text[end].isWhitespace()) end += 1
                return end
            }
        }
        for (i in limit - 1 downTo floor) {
            if (text[i].isWhitespace()) return i + 1
        }
        val iterator = BreakIterator.getCharacterInstance(Locale.ROOT)
        iterator.setText(text.substring(start, minOf(text.length, limit + 64)))
        val boundary = iterator.preceding(limit - start + 1)
        return if (boundary == BreakIterator.DONE || boundary <= 0) limit else start + boundary
    }

    private val SENTENCE_ENDS = setOf('.', '!', '?', '。', '！', '？', '؟', '۔', '।', '॥')

    /** Same set of line breaks as Swift's `Character.isNewline`. */
    private fun Char.isLineBreak(): Boolean =
        this == '\n' || this == '\r' || this == '\u000B' || this == '\u000C' ||
            this == '\u0085' || this == '\u2028' || this == '\u2029'
}
