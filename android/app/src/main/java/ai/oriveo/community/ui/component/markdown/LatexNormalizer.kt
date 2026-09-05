package ai.oriveo.community.ui.component.markdown

/**
 * Normalises LaTeX-style delimiters into the markdown dollar form, so that everything
 * downstream only has to recognise one syntax.
 *
 *   inline: `\(text\)` becomes `$text$`     (may not span lines)
 *   block:  `\[text\]` becomes `$$text$$`   (may span lines)
 *
 * The protection rules run in this order, and the order matters:
 *   1. mask fenced code blocks (``` or ~~~) behind placeholders;
 *   2. mask inline code (`...`);
 *   3. rewrite `\[...\]` into `$$...$$`, block form first;
 *   4. rewrite `\(...\)` into `$...$`;
 *   5. restore the placeholders.
 *
 * Doing block before inline matters because otherwise the `\[` and `\]` characters get
 * mis-paired with `\(` and `\)` while scanning.
 */

private const val PLACEHOLDER_PREFIX = " LATEXGUARD"

private fun makePlaceholder(idx: Int): String = "$PLACEHOLDER_PREFIX$idx"

/** Fenced code block, ``` or ~~~; the fence must close with the same character and be at least 3 long. */
private val fencedCodeRegex = Regex(
    "(^|\\n)([ \\t]{0,3})(`{3,}|~{3,})([^\\n]*)\\n([\\s\\S]*?)(?:\\n[ \\t]{0,3}\\3[ \\t]*(?=\\n|$)|$)",
)

/** Inline code: a backtick pair, allowing multi-backtick delimiters, never spanning lines. */
private val inlineCodeRegex = Regex("(`+)([^`\\n]|[^`\\n]*?[^`\\n])\\1")

/** Block formula `\[...\]`: may span lines, matched non-greedily. */
private val blockMathRegex = Regex("\\\\\\[([\\s\\S]+?)\\\\\\]")

/** Inline formula `\(...\)`: may not span lines. */
private val inlineMathRegex = Regex("\\\\\\(([^\\n]+?)\\\\\\)")

private val placeholderRestoreRegex = Regex(" LATEXGUARD(\\d+)")

/**
 * Equivalent of the Java regex `(?=\n|$)` without MULTILINE, evaluated at [at]: a
 * newline, the end of the input, or the final line terminator just before the end of the
 * input (which includes `\r\n`, `\u0085`, `\u2028` and `\u2029`).
 *
 * The fence-closing test in [splitClosedAndOpenLatex] used to do this by compiling a
 * fresh Regex for every line. Reproducing the semantics by hand keeps a streamed message
 * from running Pattern.compile once per newline, which it re-scans on every commit.
 */
private fun atLineEndOrInputEnd(text: String, at: Int): Boolean {
    val len = text.length
    if (at >= len) return true
    val ch = text[at]
    if (ch == '\n') return true
    if (at == len - 1) return ch == '\r' || ch == '\u0085' || ch == '\u2028' || ch == '\u2029'
    return at == len - 2 && ch == '\r' && text[at + 1] == '\n'
}

/**
 * Consumes at most 3 spaces or tabs starting at [start], matching `[ \t]{0,3}`.
 *
 * @return the index of the first character that is not part of that indent.
 */
private fun skipFenceIndent(text: String, start: Int): Int {
    var p = start
    var taken = 0
    while (p < text.length && taken < 3 && (text[p] == ' ' || text[p] == '\t')) {
        p++
        taken++
    }
    return p
}

/**
 * Replaces fenced code blocks and inline code with placeholders.
 *
 * @return the masked text paired with the list of original substrings, indexed by the
 *   number embedded in each placeholder.
 */
private fun maskCodeRegions(text: String): Pair<String, List<String>> {
    val restore = mutableListOf<String>()

    var masked = fencedCodeRegex.replace(text) { match ->
        val idx = restore.size
        restore.add(match.value)
        makePlaceholder(idx)
    }

    masked = inlineCodeRegex.replace(masked) { match ->
        val idx = restore.size
        restore.add(match.value)
        makePlaceholder(idx)
    }

    return masked to restore
}

private fun unmask(text: String, restore: List<String>): String {
    if (restore.isEmpty()) return text
    return placeholderRestoreRegex.replace(text) { match ->
        val idx = match.groupValues[1].toIntOrNull() ?: return@replace match.value
        restore.getOrNull(idx) ?: ""
    }
}

private fun replaceBlockDelimiters(text: String): String =
    blockMathRegex.replace(text) { match ->
        val inner = match.groupValues[1]
        "\$\$" + inner + "\$\$"
    }

private fun replaceInlineDelimiters(text: String): String =
    inlineMathRegex.replace(text) { match ->
        val inner = match.groupValues[1]
        "\$" + inner + "\$"
    }

/** Main entry point: normalises the LaTeX delimiters in [text]. */
fun normalizeLatexDelimiters(text: String): String {
    if (text.isEmpty()) return text
    // Short-circuit: with no \( or \[ anywhere there is nothing to rewrite, so skip the
    // regex work entirely.
    if (!text.contains("\\(") && !text.contains("\\[")) return text

    val (masked, restore) = maskCodeRegions(text)
    // Block form first, so \[ and \] cannot be mis-paired against \( and \).
    val withBlock = replaceBlockDelimiters(masked)
    val withInline = replaceInlineDelimiters(withBlock)
    return unmask(withInline, restore)
}

/**
 * Splits streamed text into the part whose formulas are all closed and a trailing part
 * that is still mid-formula.
 *
 * The scan runs left to right tracking any unclosed formula opener. If it ends while
 * still inside a formula, everything from the last opener to the end is peeled off as
 * [SplitLatexResult.tail] and rendered as plain text, so a half-written formula does not
 * twitch on screen as the layout engine tries to typeset it.
 *
 * Recognised openers: `\(`, `\[`, `$$` and a lone `$`.
 *
 * @param text the text received so far.
 * @return the closed prefix and the still-open tail; the tail is empty when nothing is
 *   left open.
 */
fun splitClosedAndOpenLatex(text: String): SplitLatexResult {
    if (text.isEmpty()) return SplitLatexResult(closed = text, tail = "")

    var i = 0
    val len = text.length
    var lastOpenStart = -1
    var mode: LatexMode = LatexMode.Normal
    var fenceMarker = ""

    while (i < len) {
        val ch = text[i]

        when (mode) {
            LatexMode.FencedCode -> {
                if (ch == '\n') {
                    // This replaces a per-line
                    // `Regex("^[ \t]{0,3}<closeChar>{n,}[ \t]*(?=\n|$)")` applied to the
                    // remaining text. Without MULTILINE the `^` can only match at position 0,
                    // so the rule is exactly: after a newline, up to 3 characters of indent, at
                    // least n fence characters of the same kind, trailing blanks, then end of
                    // line or end of input. It is scanned by hand because the regex version
                    // copied the whole remaining text and compiled a fresh Pattern at every
                    // newline, and a streamed message re-scans in full on every block commit.
                    // The greedy scan is equivalent to the regex backtracking: giving back one
                    // fence character leaves another fence character next, which satisfies
                    // neither `[ \t]*` nor `(?=\n|$)`.
                    val closeChar = if (fenceMarker[0] == '`') '`' else '~'
                    val runStart = skipFenceIndent(text, i + 1)
                    var runEnd = runStart
                    while (runEnd < len && text[runEnd] == closeChar) runEnd++
                    if (runEnd - runStart >= fenceMarker.length) {
                        var lineEnd = runEnd
                        while (lineEnd < len && (text[lineEnd] == ' ' || text[lineEnd] == '\t')) lineEnd++
                        if (atLineEndOrInputEnd(text, lineEnd)) {
                            i = lineEnd
                            mode = LatexMode.Normal
                            continue
                        }
                    }
                }
                i++
                continue
            }

            LatexMode.InlineCode -> {
                // Find the closing backtick run of the same length.
                val idxClose = text.indexOf(fenceMarker, i)
                if (idxClose == -1 || text.substring(i, idxClose).contains('\n')) {
                    mode = LatexMode.Normal
                    continue
                }
                i = idxClose + fenceMarker.length
                mode = LatexMode.Normal
                continue
            }

            LatexMode.Paren -> {
                if (ch == '\n') {
                    // Crossing a line means this `\(` was never valid inline math; back out.
                    mode = LatexMode.Normal
                    lastOpenStart = -1
                    i++
                    continue
                }
                if (ch == '\\' && i + 1 < len && text[i + 1] == ')') {
                    i += 2
                    mode = LatexMode.Normal
                    lastOpenStart = -1
                    continue
                }
                i++
                continue
            }

            LatexMode.Bracket -> {
                if (ch == '\\' && i + 1 < len && text[i + 1] == ']') {
                    i += 2
                    mode = LatexMode.Normal
                    lastOpenStart = -1
                    continue
                }
                i++
                continue
            }

            LatexMode.DollarDollar -> {
                if (ch == '$' && i + 1 < len && text[i + 1] == '$') {
                    i += 2
                    mode = LatexMode.Normal
                    lastOpenStart = -1
                    continue
                }
                i++
                continue
            }

            LatexMode.Dollar -> {
                if (ch == '\n') {
                    mode = LatexMode.Normal
                    lastOpenStart = -1
                    i++
                    continue
                }
                if (ch == '\\' && i + 1 < len && text[i + 1] == '$') {
                    i += 2
                    continue
                }
                if (ch == '$') {
                    i++
                    mode = LatexMode.Normal
                    lastOpenStart = -1
                    continue
                }
                i++
                continue
            }

            LatexMode.Normal -> {
                // Fence detection at the start of a line. This replaces
                // `Regex("^[ \t]{0,3}(`{3,}|~{3,})")` applied to the remaining text: without
                // MULTILINE the `^` can only match at position 0, so the rule is up to 3
                // characters of indent followed by at least 3 fence characters of one kind.
                // Scanned by hand for the same reason as the closing test - the regex version
                // took a substring of everything left and compiled a Pattern at every newline,
                // which is hundreds of compiles per tick on one long answer.
                if (ch == '\n' || i == 0) {
                    val start = if (ch == '\n') i + 1 else i
                    val runStart = skipFenceIndent(text, start)
                    val fenceChar = if (runStart < len) text[runStart] else ' '
                    if (fenceChar == '`' || fenceChar == '~') {
                        var runEnd = runStart
                        while (runEnd < len && text[runEnd] == fenceChar) runEnd++
                        if (runEnd - runStart >= 3) {
                            fenceMarker = text.substring(runStart, runEnd)
                            i = runEnd
                            mode = LatexMode.FencedCode
                            continue
                        }
                    }
                }

                // inline code
                if (ch == '`') {
                    var j = i
                    while (j < len && text[j] == '`') j++
                    fenceMarker = text.substring(i, j)
                    i = j
                    mode = LatexMode.InlineCode
                    continue
                }

                // \( inline math
                if (ch == '\\' && i + 1 < len && text[i + 1] == '(') {
                    lastOpenStart = i
                    i += 2
                    mode = LatexMode.Paren
                    continue
                }

                // \[ block math
                if (ch == '\\' && i + 1 < len && text[i + 1] == '[') {
                    lastOpenStart = i
                    i += 2
                    mode = LatexMode.Bracket
                    continue
                }

                // $$ block math
                if (ch == '$' && i + 1 < len && text[i + 1] == '$') {
                    lastOpenStart = i
                    i += 2
                    mode = LatexMode.DollarDollar
                    continue
                }

                // Lone $ opening inline math, using the same conservative rule as
                // extractInlineMath. The preceding character must not be alphanumeric, so
                // `bar$x` and `100$x` are not formulas. The following character must not be
                // whitespace, another $ or a digit, so `$40` and `$5.99` stay currency: peeling
                // a price into the tail would park it in a separate Text at the bottom during
                // streaming and then flow it back into the paragraph when the text settles,
                // which is a visible reflow. And it must not be backslash-escaped.
                if (ch == '$' && (i == 0 || text[i - 1] != '\\')) {
                    val prevCh = if (i > 0) text[i - 1] else null
                    val next = if (i + 1 < len) text[i + 1] else null
                    if ((prevCh == null || !prevCh.isLetterOrDigit()) &&
                        next != null && next != ' ' && next != '\t' && next != '\n' &&
                        next != '$' && !next.isDigit()
                    ) {
                        lastOpenStart = i
                        i++
                        mode = LatexMode.Dollar
                        continue
                    }
                }

                i++
            }
        }
    }

    return if (
        mode == LatexMode.Paren ||
        mode == LatexMode.Bracket ||
        mode == LatexMode.Dollar ||
        mode == LatexMode.DollarDollar
    ) {
        if (lastOpenStart >= 0) {
            SplitLatexResult(
                closed = text.substring(0, lastOpenStart),
                tail = text.substring(lastOpenStart),
            )
        } else {
            SplitLatexResult(closed = text, tail = "")
        }
    } else {
        SplitLatexResult(closed = text, tail = "")
    }
}

data class SplitLatexResult(
    val closed: String,
    val tail: String,
)

private enum class LatexMode {
    Normal,
    FencedCode,
    InlineCode,
    Paren,
    Bracket,
    Dollar,
    DollarDollar,
}
