package ai.oriveo.community.ui.component.streaming

/**
 * Inline safe-boundary scanner for block-level commit rendering.
 *
 * The semantics here mirror this module's own rendering pipeline (the sequential
 * character scan in MarkdownRenderer, plus extractInlineMath and
 * splitClosedAndOpenLatex). It is deliberately not a regex family: a regex would
 * agree with the renderer only by accident, and any disagreement shows up as text
 * that visibly rewrites itself mid-stream.
 *
 * Given the content of a single line whose block-level leading marker has already
 * been stripped (so no `\n`), it returns the largest offset that is safe to commit:
 * every rendering decision before that offset is already sealed, depends on no
 * unknown future character, and therefore cannot be rewritten by later appends.
 * [StreamingBlockChunker] uses it as the ceiling for a word chunk - the prefix up to
 * the boundary can be committed and will never be rewritten, while the remaining
 * span waits for its span to close (or settles literally at end of line, which
 * line-scoped parsing makes permanent).
 *
 * Stability rules, mirroring the renderer's per-character decisions:
 * - the first closer found by `indexOf` keeps its position under append, so a closed
 *   span is stable;
 * - a failed `indexOf` is a dependency on the future - a later append could make it
 *   hit and force the already-rendered text to change - so everything from that
 *   opener on is unstable;
 * - a decision that needs lookahead (the `!startsWith("**", end)` on an italic
 *   closer, the `(` after `[..]`, the "next character is not a digit" rule on a `$`
 *   closer) is only sealed once the lookahead character itself is known; if it falls
 *   at end of line, the decision is unstable.
 *
 * When in doubt the boundary is placed early rather than late. An early boundary
 * costs one extra beat of holding; a late one forces a commit to be rewritten, which
 * breaks the invariant that the rendered prefix only ever grows.
 */
internal object StreamingInlineSpanScanner {

    fun safeBoundary(line: String): Int {
        val n = line.length
        var i = 0

        while (i < n) {
            when (line[i]) {
                '*' -> {
                    // *** / ** / *, in the same branch order the renderer uses.
                    if (i + 2 < n && line[i + 1] == '*' && line[i + 2] == '*') {
                        val e = line.indexOf("***", i + 3)
                        if (e < 0) return i
                        i = e + 3
                    } else if (i + 1 < n && line[i + 1] == '*') {
                        val e = line.indexOf("**", i + 2)
                        if (e < 0) return i
                        i = e + 2
                    } else if (i + 1 == n) {
                        // Lone * at end of line: the next character is unknown and could turn
                        // this into ** or ***, so the opener's shape is not decided yet.
                        return i
                    } else {
                        // Italic: the renderer takes the first * and requires the character
                        // after it to be known and not a *.
                        val e = line.indexOf('*', i + 1)
                        when {
                            e < 0 -> return i
                            // The closer's lookahead is unknown - appending a * would turn the
                            // pair into bold and invalidate this closer.
                            e + 1 >= n -> return i
                            // The first candidate closer starts a **, so this opener stays
                            // literal forever; the decision is already sealed.
                            line[e + 1] == '*' -> i++
                            else -> i = e + 1
                        }
                    }
                }

                '~' -> {
                    // Half a marker at end of line: it could still become a ~~ opener.
                    if (i + 1 == n) return i
                    if (line[i + 1] == '~') {
                        val e = line.indexOf("~~", i + 2)
                        if (e < 0) return i
                        i = e + 2
                    } else {
                        // A lone ~ is always literal: there is no single-~ syntax and the
                        // following character is already known not to be a ~.
                        i++
                    }
                }

                '`' -> {
                    // Trailing `: it is literal if a second ` follows and an opener if
                    // anything else does. Undecided either way.
                    if (i + 1 == n) return i
                    if (line[i + 1] == '`') {
                        // The first ` of a `` pair is always literal - the renderer's guard
                        // only looks at the next character, which is known.
                        i++
                    } else {
                        val e = line.indexOf('`', i + 1)
                        if (e < 0) return i
                        // A code closer needs no lookahead, so it is stable.
                        i = e + 1
                    }
                }

                '[' -> {
                    val cb = line.indexOf(']', i + 1)
                    if (cb < 0) return i
                    // The ( of `](` is the lookahead and it is not known yet.
                    if (cb + 1 >= n) return i
                    if (line[cb + 1] != '(') {
                        // The character after the first ] is known and is not a (, so this can
                        // never become a link and the [ stays literal.
                        i++
                    } else {
                        val cp = line.indexOf(')', cb + 2)
                        if (cp < 0) return i
                        i = cp + 1
                    }
                }

                '$' -> {
                    // Trailing $: could become an opener or the first half of $$.
                    if (i + 1 == n) return i
                    if (line[i + 1] == '$') {
                        // Mid-line $$..$$ goes through the DollarDollar path of
                        // splitClosedAndOpenLatex. While unclosed it is peeled out into a
                        // separate Text at the bottom and it jumps back into place the moment
                        // it closes, so it has to be held until then.
                        val e = line.indexOf("$$", i + 2)
                        if (e < 0) return i
                        i = e + 2
                    } else {
                        val prev = if (i > 0) line[i - 1] else null
                        val next = line[i + 1]
                        val escaped = prev == '\\'
                        val invalidOpen = escaped ||
                            (prev != null && prev.isLetterOrDigit()) ||
                            next == ' ' || next == '\t' || next.isDigit()
                        if (invalidOpen) {
                            // By the extractInlineMath rules this can never open a formula, and
                            // every character the rule looks at is already known, so it is literal.
                            i++
                        } else {
                            val close = findInlineMathClose(line, i)
                            if (close < 0) return i
                            i = close + 1
                        }
                    }
                }

                '\\' -> {
                    // Trailing backslash: could still become \( or \[.
                    if (i + 1 == n) return i
                    when (line[i + 1]) {
                        '(' -> {
                            val e = line.indexOf("\\)", i + 2)
                            // An unclosed \( is peeled into the tail by splitClosedAndOpenLatex.
                            if (e < 0) return i
                            i = e + 2
                        }
                        '[' -> {
                            val e = line.indexOf("\\]", i + 2)
                            if (e < 0) return i
                            i = e + 2
                        }
                        // Escapes such as \$: both characters are known, always literal.
                        else -> i += 2
                    }
                }

                else -> i++
            }
        }

        return n
    }

    /**
     * Mirrors the closer-eligibility scan in extractInlineMath: the character before a
     * candidate `$` must not be whitespace, the character after it must be known and be
     * neither a digit nor another `$`, and `\$` is skipped as an escape.
     *
     * @return the index of the first eligible closer, or -1 when there is none or when
     *   eligibility would depend on a character past the end of the line.
     */
    private fun findInlineMathClose(line: String, openIdx: Int): Int {
        var j = openIdx + 1
        val n = line.length
        while (j < n) {
            val cj = line[j]
            if (cj == '\\' && j + 1 < n && line[j + 1] == '$') {
                j += 2
                continue
            }
            if (cj == '$') {
                // Next character unknown: a digit there would disqualify this closer.
                if (j + 1 >= n) return -1
                val prevCh = line[j - 1]
                val nextCh = line[j + 1]
                if (prevCh != ' ' && prevCh != '\t' && nextCh != '$' && !nextCh.isDigit() && j > openIdx + 1) {
                    return j
                }
            }
            j++
        }
        return -1
    }
}
