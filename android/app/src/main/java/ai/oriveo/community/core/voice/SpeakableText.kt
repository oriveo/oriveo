package ai.oriveo.community.core.voice

/**
 * Speakable text (shared/voice-contracts/speakable-text.v1.json): implements the rules one by one.
 * All positions are Unicode code points.
 */
enum class SpeakablePlaceholder(val rawValue: String) { CODE("code"), TABLE("table"), MATH("math") }

sealed interface SpeakableSegment {
    data class Sentence(val text: String) : SpeakableSegment
    data class Placeholder(val kind: SpeakablePlaceholder) : SpeakableSegment
}

const val MAX_SENTENCE_CODE_POINTS = 200

val APP_VOICE_LOCALES = listOf(
    "ar", "de", "en", "es", "fr", "hi", "id", "ja", "ko", "pt-BR", "ru", "th", "tr", "vi", "zh-Hans", "zh-Hant",
)

/** Splits an assistant reply (Markdown) into speakable segments; final=false means a streaming prefix whose last line is incomplete. */
fun speakableSegments(text: String, final: Boolean): List<SpeakableSegment> {
    val lines = text.replace("\r\n", "\n").replace('\r', '\n').split("\n").toMutableList()
    val openLine = if (final) null else lines.removeAt(lines.size - 1)
    val state = BlockState()
    val raw = mutableListOf<SpeakableSegment>()
    for (line in lines) processLine(line, true, state, raw)
    if (openLine != null) processLine(openLine, false, state, raw)
    val out = mutableListOf<SpeakableSegment>()
    for (seg in raw) {
        val last = out.lastOrNull()
        if (seg is SpeakableSegment.Placeholder && last is SpeakableSegment.Placeholder && last.kind == seg.kind) continue
        out += seg
    }
    return out
}

/** BCP-47 → one of the 16 app languages; null when nothing matches. */
fun appLocaleFor(tag: String?): String? {
    if (tag.isNullOrEmpty()) return null
    val parts = tag.replace('_', '-').split('-')
    val lang = parts[0].lowercase()
    val rest = parts.drop(1).map { it.lowercase() }
    if (lang == "zh") {
        return if ("hant" in rest || rest.any { it == "tw" || it == "hk" || it == "mo" }) "zh-Hant" else "zh-Hans"
    }
    if (lang == "pt") return "pt-BR"
    if (lang == "in") return "id"
    return if (lang in APP_VOICE_LOCALES) lang else null
}

/** Placeholder sentences use the reading language; the UI language is used only when the reading language is not one of the 16 app languages. */
fun placeholderLocale(readingLanguage: String?, uiLocale: String?): String =
    appLocaleFor(readingLanguage) ?: appLocaleFor(uiLocale) ?: "en"

// ───────────── code point helpers ─────────────

private val WS: Set<Int> = buildSet {
    addAll(listOf(0x20, 0x09, 0x0b, 0x0c, 0xa0, 0x1680, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000))
    for (c in 0x2000..0x200a) add(c)
}
private val WEAK: Set<Int> = ".!?;".codePointSet()
private val STRONG: Set<Int> = "。！？；｡؟۔؛।॥".codePointSet()
private val CLOSERS: Set<Int> = "\"')]}”’」』）】》〉»›〕〗］｝".codePointSet()
private val OPENERS: Set<Int> = "(\"'“‘「『（【《".codePointSet()
private val ABBREVIATIONS = setOf(
    "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc", "e.g", "i.e", "inc", "ltd", "co", "fig",
    "approx", "u.s", "a.m", "p.m",
)
private val REMOVED_RANGES = listOf(
    0x200b..0x200d, 0x2060..0x2060, 0xfe0e..0xfe0f, 0x20e3..0x20e3,
    0x231a..0x231b, 0x23e9..0x23f3, 0x23f8..0x23fa, 0x25fd..0x25fe,
    0x2600..0x27bf, 0x2b1b..0x2b1c, 0x2b50..0x2b50, 0x2b55..0x2b55,
    0x1f000..0x1faff, 0xe0020..0xe007f,
)

// Whitespace set of JS `\s` and String.prototype.trim (the rules follow JS regex semantics).
private const val JS_WS_CLASS = "\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF"
private val JS_TRIM: Set<Int> = buildSet {
    addAll(listOf(0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x20, 0xa0, 0x1680, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff))
    for (c in 0x2000..0x200a) add(c)
}

private fun String.codePointSet(): Set<Int> = codePoints().toArray().toSet()
private fun cp(c: Char): Int = c.code

private fun isWS(c: Int): Boolean = c >= 0 && c in WS
private fun isRemoved(c: Int): Boolean = REMOVED_RANGES.any { c in it }
private fun isLetterOrNumber(c: Int): Boolean {
    if (c < 0) return false
    return when (Character.getType(c).toByte()) {
        Character.UPPERCASE_LETTER, Character.LOWERCASE_LETTER, Character.TITLECASE_LETTER,
        Character.MODIFIER_LETTER, Character.OTHER_LETTER,
        Character.DECIMAL_DIGIT_NUMBER, Character.LETTER_NUMBER, Character.OTHER_NUMBER -> true
        else -> false
    }
}
private fun isMark(c: Int): Boolean {
    if (c < 0) return false
    return when (Character.getType(c).toByte()) {
        Character.NON_SPACING_MARK, Character.COMBINING_SPACING_MARK, Character.ENCLOSING_MARK -> true
        else -> false
    }
}
private fun isAsciiPunct(c: Int): Boolean =
    c in 0x21..0x2f || c in 0x3a..0x40 || c in 0x5b..0x60 || c in 0x7b..0x7e
private fun isDigit(c: Int): Boolean = c in 0x30..0x39
private fun isAsciiLetter(c: Int): Boolean = c in 0x41..0x5a || c in 0x61..0x7a

// Each item of u: a code point (>= 0) or a formula placeholder (PH).
private const val PH = -1
private fun isPH(x: Int): Boolean = x == PH

private fun IntArray.str(from: Int, to: Int): String = String(this, from, to - from)
private fun List<Int>.str(): String = buildString { for (c in this@str) appendCodePoint(c) }

private object Pending : RuntimeException(null, null, false, false) {
    private fun readResolve(): Any = Pending
}

// ───────────── inline ─────────────

private class Inline(private val cs: IntArray, private val u: MutableList<Int>) {

    fun run(from: Int, to: Int, open: Boolean) {
        val avail = { k: Int -> k < to }
        fun push(ch: Int) {
            if (isWS(ch)) {
                if (u.isEmpty() || isWS(u.last())) return
                u += cp(' ')
                return
            }
            if (isRemoved(ch)) return
            u += ch
        }
        fun pushStr(s: String) = s.codePoints().forEach { push(it) }
        fun pend(): Nothing = throw Pending
        // true / false / null (undecided)
        fun startsWith(i: Int, s: String): Boolean? {
            val arr = s.codePoints().toArray()
            for (k in arr.indices) {
                if (!avail(i + k)) return if (open) null else false
                if (cs[i + k] != arr[k]) return false
            }
            return true
        }
        fun runLength(i: Int, ch: Int): Int {
            var j = i
            while (avail(j) && cs[j] == ch) j++
            if (!avail(j) && open) pend()
            return j - i
        }

        var i = from
        while (i < to) {
            val c = cs[i]

            if (c == cp('\\')) {
                if (!avail(i + 1)) { if (open) pend(); i++; continue }
                val n = cs[i + 1]
                if (n == cp('(') || n == cp('[')) {
                    val close = if (n == cp('(')) cp(')') else cp(']')
                    var j = -1
                    var k = i + 2
                    while (k + 1 < to) { if (cs[k] == cp('\\') && cs[k + 1] == close) { j = k; break }; k++ }
                    if (j >= 0) { u += PH; i = j + 2; continue }
                    if (open) pend()
                    push(n); i += 2; continue
                }
                if (isAsciiPunct(n)) { push(n); i += 2; continue }
                push(cp('\\')); i++; continue
            }

            if (c == cp('`')) {
                val run = runLength(i, cp('`'))
                var k = i + run
                var found = -1
                while (k < to) {
                    if (cs[k] == cp('`')) {
                        val r = runLength(k, cp('`'))
                        if (r == run) { found = k; break }
                        k += r
                    } else k++
                }
                if (found >= 0) {
                    for (q in i + run until found) push(cs[q])
                    i = found + run; continue
                }
                if (open) pend()
                i += run; continue
            }

            if (c == cp('$')) {
                if (!avail(i + 1)) { if (open) pend(); push(cp('$')); i++; continue }
                if (cs[i + 1] == cp('$')) {
                    var j = -1
                    var k = i + 2
                    while (k + 1 < to) { if (cs[k] == cp('$') && cs[k + 1] == cp('$')) { j = k; break }; k++ }
                    if (j >= 0) { u += PH; i = j + 2; continue }
                    if (open) pend()
                    i += 2; continue
                }
                val n = cs[i + 1]
                if (isWS(n) || isDigit(n)) { push(cp('$')); i++; continue }
                var j = -1
                for (k in i + 2 until to) {
                    if (cs[k] != cp('$') || isWS(cs[k - 1]) || cs[k - 1] == cp('\\')) continue
                    if (!avail(k + 1)) { if (open) pend(); j = k; break }
                    if (!isDigit(cs[k + 1])) { j = k; break }
                }
                if (j >= 0) { u += PH; i = j + 1; continue }
                if (open) pend()
                push(cp('$')); i++; continue
            }

            if (c == cp('!')) {
                if (!avail(i + 1)) { if (open) pend(); push(cp('!')); i++; continue }
                if (cs[i + 1] == cp('[')) {
                    val r = parseBracket(i + 1, to, open)
                    if (r != null && r.link) {
                        Inline(cs, u).run(r.labelFrom, r.labelTo, false)
                        i = r.end; continue
                    }
                }
                push(cp('!')); i++; continue
            }

            if (c == cp('[')) {
                val r = parseBracket(i, to, open)
                if (r == null) { i++; continue }
                val label = cs.str(r.labelFrom, r.labelTo)
                if (!FOOTNOTE.containsMatchIn(label) && !CITATION.containsMatchIn(label)) {
                    Inline(cs, u).run(r.labelFrom, r.labelTo, false)
                }
                i = r.end; continue
            }

            if (c == cp('<')) {
                if (!avail(i + 1)) { if (open) pend(); push(cp('<')); i++; continue }
                val n = cs[i + 1]
                if (isAsciiLetter(n) || n == cp('/')) {
                    var gt = -1
                    for (k in i + 1 until to) {
                        if (cs[k] == cp('>')) { gt = k; break }
                        if (cs[k] == cp('<')) break
                    }
                    if (gt < 0) {
                        if (open) {
                            var sawLt = false
                            for (k in i + 1 until to) if (cs[k] == cp('<')) sawLt = true
                            if (!sawLt) pend()
                        }
                        push(cp('<')); i++; continue
                    }
                    val body = cs.str(i, gt + 1)
                    val auto = AUTOLINK.find(body)
                    if (auto != null) { pushStr(hostOf(auto.groupValues[1])); i = gt + 1; continue }
                    val tag = HTML_TAG.find(body)
                    if (tag != null) {
                        if (tag.groupValues[1].lowercase() == "br") push(cp(' '))
                        i = gt + 1; continue
                    }
                }
                push(cp('<')); i++; continue
            }

            if (c == cp('h') && (i == 0 || !isLetterOrNumber(cs[i - 1]))) {
                val http = startsWith(i, "http://")
                val https = startsWith(i, "https://")
                if (http != true && https != true && (http == null || https == null)) pend()
                if (http == true || https == true) {
                    var j = i
                    while (j < to && cs[j] in 0x21..0x7e && cs[j] !in URL_EXCLUDED) j++
                    if (j == to && open) pend()
                    var end = j
                    while (end > i && cs[end - 1] in URL_TRAILING) end--
                    pushStr(hostOf(cs.str(i, end)))
                    i = end; continue
                }
            }

            if (c == cp('*') || c == cp('_') || c == cp('~')) {
                val run = runLength(i, c)
                if (c == cp('~') && run != 2) { repeat(run) { push(cp('~')) }; i += run; continue }
                val prev = if (i > 0) cs[i - 1] else cp(' ')
                if (!avail(i + run) && open) pend()
                val next = if (avail(i + run)) cs[i + run] else cp(' ')
                val canOpen = !isWS(next) && (c != cp('_') || !isLetterOrNumber(prev))
                fun canCloseAt(k: Int, r: Int): Boolean {
                    val p = cs[k - 1]
                    if (!avail(k + r) && open) pend()
                    val nx = if (avail(k + r)) cs[k + r] else cp(' ')
                    return !isWS(p) && (c != cp('_') || !isLetterOrNumber(nx))
                }
                if (canOpen) {
                    var k = i + run
                    var found = -1
                    while (k < to) {
                        if (cs[k] == c) {
                            val r = runLength(k, c)
                            if (r == run && canCloseAt(k, r)) { found = k; break }
                            k += r
                        } else k++
                    }
                    if (found >= 0) {
                        Inline(cs, u).run(i + run, found, false)
                        i = found + run; continue
                    }
                    if (open) pend()
                    i += run; continue
                }
                val canClose = !isWS(prev) && (c != cp('_') || !isLetterOrNumber(next))
                if (canClose) { i += run; continue }
                repeat(run) { push(c) }
                i += run; continue
            }

            push(c)
            i++
        }
    }

    private class Bracket(val labelFrom: Int, val labelTo: Int, val end: Int, val link: Boolean)

    /** [label](url) / [label]; null = no match. On an incomplete line, a missing closing bracket or next code point is Pending. */
    private fun parseBracket(i: Int, to: Int, open: Boolean): Bracket? {
        var depth = 0
        var j = -1
        var k = i
        while (k < to) {
            if (cs[k] == cp('\\')) { k += 2; continue }
            if (cs[k] == cp('[')) depth++
            else if (cs[k] == cp(']')) { depth--; if (depth == 0) { j = k; break } }
            k++
        }
        if (j < 0) {
            if (open) throw Pending
            return null
        }
        if (j + 1 >= to) {
            if (open) throw Pending
            return Bracket(i + 1, j, j + 1, false)
        }
        if (cs[j + 1] == cp('(')) {
            var d = 0
            var k2 = -1
            for (q in j + 1 until to) {
                if (cs[q] == cp('(')) d++
                else if (cs[q] == cp(')')) { d--; if (d == 0) { k2 = q; break } }
            }
            if (k2 >= 0) return Bracket(i + 1, j, k2 + 1, true)
            if (open) throw Pending
        }
        return Bracket(i + 1, j, j + 1, false)
    }

    private companion object {
        val FOOTNOTE = Regex("^[$JS_WS_CLASS]*\\^")
        val CITATION = Regex("^[$JS_WS_CLASS]*\\d+(?:[$JS_WS_CLASS]*[,，、\\-–][$JS_WS_CLASS]*\\d+)*[$JS_WS_CLASS]*\\z")
        val AUTOLINK = Regex("^<(https?://[^$JS_WS_CLASS<>]*)>\\z", RegexOption.IGNORE_CASE)
        val HTML_TAG = Regex("^</?([A-Za-z][A-Za-z0-9-]*)(?:[$JS_WS_CLASS][^<>]*)?/?>\\z")
        val URL_EXCLUDED: Set<Int> = "<>\"`".codePointSet()
        val URL_TRAILING: Set<Int> = ".,:;!?'\")]}*_~".codePointSet()
        val HOST = Regex("^[A-Za-z]+://([^/?#:]*)")
        val WWW = Regex("^www\\.", RegexOption.IGNORE_CASE)

        fun hostOf(url: String): String {
            val host = HOST.find(url)?.groupValues?.get(1).orEmpty()
            return host.replaceFirst(WWW, "")
        }
    }
}

// ───────────── sentence splitting ─────────────

private fun isTerminator(x: Int): Boolean = x in WEAK || x in STRONG

private fun isAbbreviation(u: List<Int>, s: Int, i: Int): Boolean {
    var k = i
    while (k > s && !isWS(u[k - 1]) && !isPH(u[k - 1])) k--
    while (k < i && u[k] in OPENERS) k++
    val w = u.subList(k, i)
    if (w.size == 1 && isAsciiLetter(w[0])) return true
    val lowered = w.map { if (it in 0x41..0x5a) it + 0x20 else it }.str()
    return lowered in ABBREVIATIONS
}

private sealed interface Closure {
    data object Wait : Closure
    data class Placeholder(val c: Int) : Closure
    data class At(val c: Int) : Closure
    data class End(val c: Int) : Closure
}

private fun findClosure(u: List<Int>, s: Int, blockEnd: Boolean): Closure {
    val n = u.size
    var i = s
    while (i < n) {
        val x = u[i]
        if (isPH(x)) return Closure.Placeholder(i)
        if (isTerminator(x)) {
            var j = i
            while (j < n && !isPH(u[j]) && isTerminator(u[j])) j++
            if (j == n && !blockEnd) return Closure.Wait
            val run = u.subList(i, j)
            if (run.size >= 2 && run.all { it == cp('.') }) { i = j; continue }
            val strong = run.any { it in STRONG }
            if (!strong && run.size == 1 && run[0] == cp('.') && isAbbreviation(u, s, i)) { i = j; continue }
            var k = j
            while (k < n && !isPH(u[k]) && u[k] in CLOSERS) k++
            if (k == n) return if (blockEnd) Closure.At(n) else Closure.Wait
            if (strong || isWS(u[k]) || isPH(u[k])) return Closure.At(k)
            i = j
            continue
        }
        i++
    }
    return if (blockEnd) Closure.End(n) else Closure.Wait
}

private val MULTI_SPACE = Regex(" +")
private val SPACE_BEFORE_TERMINATOR = Regex(" (?=[.!?;。！？；｡؟۔؛।॥])")

private fun emitSentence(out: MutableList<SpeakableSegment>, chars: List<Int>) {
    val joined = chars.str().replace(MULTI_SPACE, " ").replace(SPACE_BEFORE_TERMINATOR, "")
    val cps = joined.codePoints().toArray()
    var a = 0
    var b = cps.size
    while (a < b && cps[a] in JS_TRIM) a++
    while (b > a && cps[b - 1] in JS_TRIM) b--
    if ((a until b).none { isLetterOrNumber(cps[it]) }) return
    out += SpeakableSegment.Sentence(cps.str(a, b))
}

private fun split(u: List<Int>, blockEnd: Boolean, out: MutableList<SpeakableSegment>) {
    val n = u.size
    val l = MAX_SENTENCE_CODE_POINTS
    var s = 0
    while (true) {
        while (s < n && isWS(u[s])) s++
        if (s >= n) return
        val r = findClosure(u, s, blockEnd)
        val c = when (r) {
            Closure.Wait -> null
            is Closure.Placeholder -> r.c
            is Closure.At -> r.c
            is Closure.End -> r.c
        }
        if (c != null && c - s <= l) {
            if (c > s) emitSentence(out, u.subList(s, c))
            if (r is Closure.Placeholder) {
                out += SpeakableSegment.Placeholder(SpeakablePlaceholder.MATH)
                s = c + 1
                continue
            }
            if (r is Closure.End) return
            s = c
            continue
        }
        if (n - s > l) {
            var q = -1
            var k = s + l
            while (k > s) { if (isWS(u[k])) { q = k; break }; k-- }
            if (q > 0) { emitSentence(out, u.subList(s, q)); s = q; continue }
            var p = s + l
            while (p > s + 1 && isMark(u[p])) p--
            emitSentence(out, u.subList(s, p))
            s = p
            continue
        }
        return
    }
}

// ───────────── blocks ─────────────

private class Fence(val ch: Char, val len: Int)

private class BlockState {
    var fence: Fence? = null
    var math: String? = null
}

// JS `.` does not match \n \r U+2028 U+2029; `$` without m only matches the end of input, mirrored here with \z.
private const val JS_DOT = "[^\\n\\r\\u2028\\u2029]"
private val RE_QUOTE = Regex("^[ \\t]{0,3}>[ \\t]?")
private val RE_FENCE = Regex("^[ \\t]{0,3}(`{3,}|~{3,})($JS_DOT*)\\z")
private val RE_MATH = Regex("^[ \\t]*(\\$\\$|\\\\\\[)($JS_DOT*)\\z")
private val RE_TABLE = Regex("^[ \\t]*\\|")
private val RE_RULE = Regex("^[ \\t]{0,3}([-*_=])(?:[ \\t]*\\1){2,}[ \\t]*\\z")
private val RE_HEADING = Regex("^[ \\t]{0,3}#{1,6}(?:[ \\t]+|\\z)")
private val RE_HEADING_TAIL = Regex("(?:^|[ \\t]+)#+[ \\t]*\\z")
private val RE_LIST = Regex("^[ \\t]*(?:[-*+]|\\d{1,9}[.)])[ \\t]+(?:\\[[ xX]\\][ \\t]+)?")

private fun processLine(raw: String, complete: Boolean, state: BlockState, out: MutableList<SpeakableSegment>) {
    var line = raw
    while (true) {
        val m = RE_QUOTE.find(line) ?: break
        line = line.substring(m.value.length)
    }

    state.fence?.let { fence ->
        if (complete) {
            val f = Regex("^[ \\t]{0,3}${if (fence.ch == '`') "`" else "~"}{${fence.len},}[ \\t]*\\z")
            if (f.containsMatchIn(line)) state.fence = null
        }
        return
    }
    state.math?.let { closer ->
        if (complete && line.contains(closer)) state.math = null
        return
    }

    val fence = RE_FENCE.find(line)
    if (fence != null && !(fence.groupValues[1][0] == '`' && fence.groupValues[2].contains('`'))) {
        if (!complete) return
        out += SpeakableSegment.Placeholder(SpeakablePlaceholder.CODE)
        state.fence = Fence(fence.groupValues[1][0], fence.groupValues[1].length)
        return
    }
    val math = RE_MATH.find(line)
    if (math != null) {
        if (!complete) return
        out += SpeakableSegment.Placeholder(SpeakablePlaceholder.MATH)
        val closer = if (math.groupValues[1] == "$$") "$$" else "\\]"
        if (!math.groupValues[2].contains(closer)) state.math = closer
        return
    }
    if (RE_TABLE.containsMatchIn(line)) {
        if (complete) out += SpeakableSegment.Placeholder(SpeakablePlaceholder.TABLE)
        return
    }
    if (RE_RULE.containsMatchIn(line)) return

    var content = line
    val heading = RE_HEADING.find(line)
    if (heading != null) {
        content = line.substring(heading.value.length)
        if (complete) content = content.replaceFirst(RE_HEADING_TAIL, "")
    } else {
        val list = RE_LIST.find(line)
        if (list != null) content = line.substring(list.value.length)
    }

    val cs = content.codePoints().toArray()
    val u = mutableListOf<Int>()
    var pending = false
    try {
        Inline(cs, u).run(0, cs.size, !complete)
    } catch (signal: Pending) {
        pending = signal === Pending
    }
    split(u, complete && !pending, out)
}
