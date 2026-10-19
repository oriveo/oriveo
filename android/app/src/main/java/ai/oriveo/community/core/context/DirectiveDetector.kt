package ai.oriveo.community.core.context

import java.text.Normalizer
import java.util.Locale

enum class DirectiveKind(val raw: String) { LANGUAGE("language"), FORMAT("format"), STYLE("style"), OTHER("other") }

enum class DirectiveScope(val raw: String) { CONVERSATION("conversation"), GLOBAL("global") }

/** Detector output; when [isDirective] is false the other fields are null. */
data class DirectiveDetection(
    val isDirective: Boolean,
    val span: String? = null,
    val kind: DirectiveKind? = null,
    val scope: DirectiveScope? = null,
) {
    companion object {
        val NONE = DirectiveDetection(isDirective = false)
    }
}

/**
 * Durable-directive detector (directive-detector.v2 `algorithm`, context pipeline §7.4).
 * Pure: works on code points, never changes anything. Lexicon and constants come from the generated [DirectiveLexicon].
 */
object DirectiveDetector {

    fun detect(text: String): DirectiveDetection {
        for (sentence in sentences(text)) {
            if (sentence.isQuestion) continue
            val hit = LANGUAGES.any { l ->
                (l.markers.any { l.matches(it, sentence) } || l.globalMarkers.any { l.matches(it, sentence) }) &&
                    l.verbs.any { l.matches(it, sentence) } &&
                    l.vetoes.none { l.matches(it, sentence) } &&
                    l.passesStarts(sentence)
            }
            if (hit) {
                return DirectiveDetection(
                    isDirective = true,
                    span = sentence.span,
                    kind = kindOf(sentence),
                    scope = if (LANGUAGES.any { l -> l.globalMarkers.any { l.matches(it, sentence) } }) {
                        DirectiveScope.GLOBAL
                    } else {
                        DirectiveScope.CONVERSATION
                    },
                )
            }
        }
        return DirectiveDetection.NONE
    }

    /** Image-generation style prefix from the conversation instructions; empty when nothing qualifies. */
    fun imageStylePrefix(instructions: String?): String {
        if (instructions.isNullOrEmpty()) return ""
        val kept = sentences(instructions).filter { s ->
            !s.isQuestion && kindOf(s) == DirectiveKind.STYLE &&
                LANGUAGES.any { l -> l.imageStyleWords.any { l.matches(it, s) } }
        }.map { it.span }
        if (kept.isEmpty()) return ""
        val max = DirectiveLexicon.IMAGE_STYLE_PREFIX_MAX
        val first = kept.first()
        if (first.cpLength() > max) return first.takeCodePoints(max).trimWhiteSpace()
        val out = StringBuilder(first)
        var total = first.cpLength()
        for (span in kept.drop(1)) {
            val next = total + 1 + span.cpLength()
            if (next > max) break
            out.append(' ').append(span)
            total = next
        }
        return out.toString()
    }

    // ---- sentences ----

    internal class Sentence(val span: String, val masked: String) {
        val norm: String = norm(masked)
        val wordform: String = wordform(norm)
        val isQuestion: Boolean = run {
            val m = masked.trimWhiteSpace()
            if (m.isEmpty()) return@run false
            val last = m.codePointBefore(m.length)
            val firstCp = m.codePointAt(0)
            if (QUESTION_ENDERS.contains(last) || QUESTION_STARTERS.contains(firstCp)) return@run true
            val stripped = m.trimEnd { it in TRAILING_STRIP }.trimWhiteSpace()
            val n = norm(stripped)
            val w = wordform(n)
            LANGUAGES.any { l ->
                l.questionParticlesAtEnd.any { term ->
                    if (l.mode == DirectiveLexicon.Mode.SUBSTRING) n.endsWith(term.norm) else w.endsWith(term.padded)
                }
            }
        }
    }

    internal fun sentences(text: String): List<Sentence> {
        val original = text.codePoints().limit(DirectiveLexicon.MAX_SCAN_CODE_POINTS.toLong()).toArray()
        val masked = mask(original)
        val out = ArrayList<Sentence>()
        var start = 0
        fun cut(end: Int) {
            val span = String(original, start, end - start).trimWhiteSpace()
            if (span.isNotEmpty()) out += Sentence(span, String(masked, start, end - start))
            start = end
        }
        for (i in masked.indices) {
            val c = masked[i]
            val ends = c in SENTENCE_ENDERS || c == NEWLINE ||
                (c == '.'.code && (i + 1 == masked.size || isWhiteSpace(masked[i + 1])))
            if (ends) cut(i + 1)
        }
        if (start < masked.size) cut(masked.size)
        return out
    }

    internal fun mask(cps: IntArray): IntArray {
        val out = cps.copyOf()
        fun blank(from: Int, toExclusive: Int) {
            for (k in from until toExclusive) if (out[k] != NEWLINE) out[k] = ' '.code
        }
        fun indexOf(target: IntArray, from: Int): Int {
            var k = from
            while (k + target.size <= cps.size) {
                if (target.indices.all { cps[k + it] == target[it] }) return k
                k++
            }
            return -1
        }
        var i = 0
        while (i < cps.size) {
            if (i + 3 <= cps.size && cps[i] == BACKTICK && cps[i + 1] == BACKTICK && cps[i + 2] == BACKTICK) {
                val close = indexOf(FENCE, i + 3)
                val end = if (close < 0) cps.size else close + 3
                blank(i, end)
                i = end
                continue
            }
            val closer = if (cps[i] == BACKTICK) BACKTICK else QUOTE_PAIRS.firstOrNull { it.first == cps[i] }?.second
            if (closer != null) {
                val close = indexOf(intArrayOf(closer), i + 1)
                if (close >= 0) {
                    blank(i, close + 1)
                    i = close + 1
                    continue
                }
            }
            i++
        }
        return out
    }

    private fun kindOf(s: Sentence): DirectiveKind = when {
        LANGUAGES.any { l -> l.languageWords.any { l.matches(it, s) } } -> DirectiveKind.LANGUAGE
        LANGUAGES.any { l -> l.formatWords.any { l.matches(it, s) } } -> DirectiveKind.FORMAT
        LANGUAGES.any { l -> l.styleWords.any { l.matches(it, s) } || l.imageStyleWords.any { l.matches(it, s) } } ->
            DirectiveKind.STYLE
        else -> DirectiveKind.OTHER
    }

    // ---- lexicon, normalized once ----

    internal class Term(raw: String) {
        val norm: String = norm(raw)
        val word: String = wordform(norm).trim(' ')
        /** `" word "`, precomputed so matching does not allocate per call (WORD mode / whole-word starts). */
        val padded: String = " $word "
        /** `" word"`, precomputed for PREFIX mode. */
        val leading: String = " $word"
    }

    internal class Lang(source: DirectiveLexicon.Language) {
        val mode = source.mode
        private fun terms(list: List<String>) = list.map(::Term)
        val markers = terms(source.markers)
        val verbs = terms(source.verbs)
        val starts = terms(source.starts)
        val vetoes = terms(source.vetoes)
        val fillers = terms(source.fillers)
        val questionParticlesAtEnd = terms(source.questionParticlesAtEnd)
        val languageWords = terms(source.languageWords)
        val formatWords = terms(source.formatWords)
        val styleWords = terms(source.styleWords)
        val imageStyleWords = terms(source.imageStyleWords)
        val globalMarkers = terms(source.globalMarkers)

        fun matches(term: Term, s: Sentence): Boolean = when (mode) {
            DirectiveLexicon.Mode.SUBSTRING -> s.norm.contains(term.norm)
            DirectiveLexicon.Mode.WORD -> s.wordform.contains(term.padded)
            DirectiveLexicon.Mode.PREFIX -> s.wordform.contains(term.leading)
        }

        fun passesStarts(s: Sentence): Boolean {
            if (mode == DirectiveLexicon.Mode.SUBSTRING) {
                var head = s.norm.trimWhiteSpace()
                while (true) {
                    val f = fillers.firstOrNull { head.startsWith(it.norm) } ?: break
                    head = head.substring(f.norm.length).trimWhiteSpace()
                }
                return starts.any { head.startsWith(it.norm) }
            }
            var head = s.wordform
            while (true) {
                val f = fillers.firstOrNull { head.startsWith(it.padded) } ?: break
                head = head.substring(f.word.length + 1)
            }
            return starts.any {
                if (mode == DirectiveLexicon.Mode.WORD) head.startsWith(it.padded) else head.startsWith(it.leading)
            }
        }
    }

    internal val LANGUAGES: List<Lang> by lazy { DirectiveLexicon.languages.map(::Lang) }

    // ---- norm / wordform ----

    internal fun norm(s: String): String {
        val lowered = Normalizer.normalize(s, Normalizer.Form.NFKC).lowercase(Locale.ROOT)
        val sb = StringBuilder(lowered.length)
        lowered.codePoints().forEach { cp ->
            when {
                cp in 0x064B..0x065F || cp == 0x0670 || cp == 0x0640 || cp == 0x0307 -> Unit
                else -> sb.appendCodePoint(
                    when (cp) {
                        0x0623, 0x0625, 0x0622, 0x0671 -> 0x0627
                        0x0649 -> 0x064A
                        0x0629 -> 0x0647
                        0x0131 -> 'i'.code
                        0x03C2 -> 0x03C3
                        else -> cp
                    },
                )
            }
        }
        return sb.toString()
    }

    /** Word form of an already-normalized string: non L/N/M code points become spaces, runs collapse, one space padding. */
    internal fun wordform(normalized: String): String {
        val sb = StringBuilder(normalized.length + 2).append(' ')
        var lastSpace = true
        normalized.codePoints().forEach { cp ->
            if (isWordCodePoint(cp)) {
                sb.appendCodePoint(cp)
                lastSpace = false
            } else if (!lastSpace) {
                sb.append(' ')
                lastSpace = true
            }
        }
        if (!lastSpace) sb.append(' ')
        return sb.toString()
    }

    internal fun isWordCodePoint(cp: Int): Boolean = when (Character.getType(cp).toByte()) {
        Character.UPPERCASE_LETTER, Character.LOWERCASE_LETTER, Character.TITLECASE_LETTER,
        Character.MODIFIER_LETTER, Character.OTHER_LETTER,
        Character.NON_SPACING_MARK, Character.ENCLOSING_MARK, Character.COMBINING_SPACING_MARK,
        Character.DECIMAL_DIGIT_NUMBER, Character.LETTER_NUMBER, Character.OTHER_NUMBER,
        -> true
        else -> false
    }

    private fun isWhiteSpace(cp: Int): Boolean = cp <= 0xFFFF && cp.toChar().isUnicodeWhiteSpace()

    private fun String.cpLength(): Int = codePointCount(0, length)

    private fun String.takeCodePoints(n: Int): String = substring(0, offsetByCodePoints(0, minOf(n, cpLength())))

    private const val NEWLINE = '\n'.code
    private const val BACKTICK = '`'.code
    private val FENCE = intArrayOf(BACKTICK, BACKTICK, BACKTICK)
    private val TRAILING_STRIP = setOf('。', '！', '!', '.')
    private fun singleCodePoints(list: List<String>): Set<Int> = list.map { it.codePointAt(0) }.toSet()
    private val SENTENCE_ENDERS: Set<Int> = singleCodePoints(DirectiveLexicon.sentenceEnders)
    private val QUESTION_ENDERS: Set<Int> = singleCodePoints(DirectiveLexicon.questionEnders)
    private val QUESTION_STARTERS: Set<Int> = singleCodePoints(DirectiveLexicon.questionStarters)
    private val QUOTE_PAIRS: List<Pair<Int, Int>> =
        DirectiveLexicon.quotePairs.map { it.first.codePointAt(0) to it.second.codePointAt(0) }
}
