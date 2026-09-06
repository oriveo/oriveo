package ai.oriveo.community.ui.component.streaming

import ai.oriveo.community.ui.component.markdown.StreamingSplitter

/**
 * Pure-function state machine that decides where the next block-level commit boundary
 * is. Line-type classification here follows this module's own parseBlocksWithGaps and
 * [StreamingSplitter], because those are what will actually render the committed text.
 *
 * It advances `visible` (the already-committed prefix of `target`) to the next safe
 * commit boundary: once a prefix has been committed its canonical rendering can never
 * change again. The pacer calls this once per tick and picks the delay from the
 * returned [BoundaryKind].
 *
 * Advance rules, in decision order:
 * 1. `visible` sits inside an unclosed ``` fence: code advances by character chunks on
 *    a fast path (see codeStepSize), clamped at the `\n` of the closing fence line so
 *    it never runs on into the prose after the fence.
 * 2. Line-start protocol, applied only when nothing of the current line is committed:
 *    - a fence opening line (``` prefix) is held until the line completes and then
 *      committed whole;
 *    - tables: header plus separator are committed atomically once both are verified
 *      (together with any already-complete data rows); inside an open table each data
 *      row is committed atomically; a `|` line whose successor is not a separator row
 *      is committed as an ordinary line, since the parser will render it as a literal
 *      paragraph;
 *    - block math `$$` / `\[` is held until the closing line completes and then
 *      committed as one block;
 *    - a horizontal-rule candidate (a whole line of the same `-`/`*`/`_`) is held to
 *      end of line;
 *    - ambiguity windows: `^#{1,6}$` (parseHeadingLine requires the space, so an early
 *      commit would flash as literal text), `^\d{1,9}\.?$` (an ordered list turns into
 *      a bullet line), and any run shorter than 4 characters made entirely of marker
 *      candidates.
 * 3. The line is complete (its `\n` is known): the remainder plus the `\n` is committed
 *    in one step; when the backlog is large, up to multiLineMax complete lines are
 *    absorbed at once, never folding in a line that starts a fence, `|`, `$$` or `\[`.
 * 4. The line is incomplete: commit a word chunk. The ceiling is
 *    [StreamingInlineSpanScanner.safeBoundary] - an unclosed inline span is held, and
 *    past maxInlineHoldUtf16 the hold degrades and the text goes out literally. ASCII
 *    scans back to a word boundary and holds the trailing partial word (degrading past
 *    maxWordHoldUtf16, with the very first chunk exempt so first paint is not delayed);
 *    CJK advances by character count.
 * 5. During drain (`isStreamEnd`) every hold is released, so the machine converges on
 *    `target` in a bounded number of steps.
 */
internal object StreamingBlockChunker {

    enum class BoundaryKind {
        /** An in-line word chunk. */
        WordChunk,
        /** One or more whole lines settled. */
        LineEnd,
        /** A blank line, i.e. a paragraph boundary. */
        ParagraphEnd,
        /** Table rows (header plus separator, or data rows) feeding the streaming table card. */
        TableRows,
        /** A character chunk of code inside an unclosed fence. */
        CodeChunk,
        /** `visible` was not a prefix of `target`; fall back to showing everything. */
        Snap,
        /** Nothing new is safe to commit this tick; `newVisible == visible`. */
        Held,
    }

    data class Boundary(val newVisible: String, val kind: BoundaryKind)

    // Main entry point

    fun nextBoundary(
        visible: String,
        target: String,
        profile: StreamingPacerProfile,
        cadence: BlockCommitCadence,
        isStreamEnd: Boolean,
    ): Boundary {
        if (!target.startsWith(visible)) {
            return Boundary(target, BoundaryKind.Snap)
        }
        val tLen = target.length
        val vLen = visible.length
        if (vLen >= tLen) {
            return Boundary(visible, BoundaryKind.Held)
        }

        // 1. Code inside a fence takes the fast path.
        if (StreamingPacer.isInsideUnclosedCodeFence(visible)) {
            return codeChunkBoundary(target, tLen, vLen, isStreamEnd)
        }

        // Locate the current line: lineStart is just after the last \n inside visible, and
        // the terminating \n, if it has arrived at all, is necessarily past vLen.
        val lineStart = if (vLen > 0) target.lastIndexOf('\n', vLen - 1) + 1 else 0
        val nextNL = target.indexOf('\n', vLen)
        val lineEndNL: Int? = if (nextNL >= 0) nextNL else null
        val lineSoFar = target.substring(lineStart, lineEndNL ?: tLen)
        val committedInLine = vLen - lineStart
        val lineComplete = lineEndNL != null

        // 2. Line-start protocol. It only applies while nothing of the line is committed;
        // committedInLine > 0 means the line's type is already frozen.
        if (committedInLine == 0) {
            lineStartProtocol(
                target = target, tLen = tLen,
                lineStart = lineStart, lineSoFar = lineSoFar,
                lineEndNL = lineEndNL, lineComplete = lineComplete,
                visible = visible, isStreamEnd = isStreamEnd,
            )?.let { return it }
        }

        // 3. The line is complete, so commit the rest of it, extending over more lines
        // when the backlog is large.
        if (lineComplete) {
            return commitCompletedLines(
                target = target, tLen = tLen, vLen = vLen,
                firstLineEndNL = lineEndNL, firstLineBlank = lineSoFar.isBlank(),
                cadence = cadence,
            )
        }

        // 4. The line is still open, so commit a word chunk.
        return wordChunkBoundary(
            target = target, lineStart = lineStart, lineSoFar = lineSoFar,
            committedInLine = committedInLine,
            profile = profile, cadence = cadence, isStreamEnd = isStreamEnd,
            isFirstReveal = vLen == 0,
        )
    }

    // Code inside a fence

    private fun codeChunkBoundary(target: String, tLen: Int, vLen: Int, isStreamEnd: Boolean): Boundary {
        val backlog = tLen - vLen
        var end = minOf(vLen + StreamingPacer.codeStepSize(backlog), tLen)
        // Clamp rules, all of which exist to keep the committed prefix monotonic:
        // a) a complete closing line (``` prefix after trimming, matching how
        //    isInsideUnclosedCodeFence classifies lines) must be committed as one whole
        //    line - committing part of it, say "``", makes the parser treat it as code
        //    content, and completing it later would shrink and rewrite what was shown;
        // b) if the trailing incomplete line looks like the prefix of a closing fence,
        //    hold until it has taken its final shape;
        // c) never step past the closing line's \n into the prose after the fence, which
        //    would bypass the scanner's safe boundary altogether.
        // Scan from the start of the line vLen is *on* - vLen may sit mid-line because
        // that line's prefix is already committed, and starting later would miss a fence.
        var cursor = if (vLen == 0) 0 else target.lastIndexOf('\n', vLen - 1) + 1
        while (cursor < tLen) {
            val nl = target.indexOf('\n', cursor)
            val lineEnd = if (nl < 0) tLen else nl
            var s = cursor
            while (s < lineEnd && (target[s] == ' ' || target[s] == '\t')) s++
            val backticks = run {
                var c = s
                while (c < lineEnd && target[c] == '`') c++
                c - s
            }
            if (backticks >= 3) {
                // A closing line, possibly still without its \n: it is all-or-nothing, so
                // either stop before the line starts or commit the whole line at once.
                val fenceBoundary = if (nl < 0) tLen else nl + 1
                end = minOf(end, fenceBoundary)
                if (end > cursor && end < fenceBoundary) {
                    end = if (vLen >= cursor) fenceBoundary else cursor
                }
                break
            }
            if (nl < 0) {
                // Trailing incomplete line: if its non-blank content is a run of one or two
                // backticks (or it is entirely blank) it may still be growing into a closing
                // fence, so hold before the line start. Committing a partial "``" would be
                // read as code content and then rewritten once "```" arrives. Any other
                // character settles it as a content line and the advance proceeds normally.
                if (!isStreamEnd && s + backticks == lineEnd && end > cursor) {
                    end = cursor
                }
                break
            }
            cursor = nl + 1
        }
        end = roundDownToCharBoundary(target, proposed = end, floor = vLen)
        if (end <= vLen) return Boundary(target.substring(0, vLen), BoundaryKind.Held)
        return Boundary(target.substring(0, end), BoundaryKind.CodeChunk)
    }

    // Line-start protocol

    private fun lineStartProtocol(
        target: String, tLen: Int,
        lineStart: Int, lineSoFar: String,
        lineEndNL: Int?, lineComplete: Boolean,
        visible: String, isStreamEnd: Boolean,
    ): Boundary? {
        val trimmed = lineSoFar.trim(' ', '\t')

        // Fence opening line: committed atomically, after which visible sits inside the
        // fence and the code fast path takes over.
        if (trimmed.startsWith("```")) {
            if (lineEndNL != null) {
                return Boundary(target.substring(0, lineEndNL + 1), BoundaryKind.LineEnd)
            }
            if (isStreamEnd) {
                return Boundary(target, BoundaryKind.LineEnd)
            }
            return Boundary(target.substring(0, lineStart), BoundaryKind.Held)
        }

        // Tables.
        if (trimmed.startsWith("|")) {
            return tableProtocol(
                target = target, tLen = tLen, lineStart = lineStart,
                lineEndNL = lineEndNL, visible = visible, isStreamEnd = isStreamEnd,
            )
        }

        // Block math. Normalisation rewrites a closed \[..\] into $$..$$, so committing an
        // unclosed one early would show it as literal text and then turn it into a block.
        if (trimmed.startsWith("$$")) {
            return blockMathProtocol(
                target = target, tLen = tLen, lineStart = lineStart,
                lineSoFar = lineSoFar, lineEndNL = lineEndNL,
                isStreamEnd = isStreamEnd, opener = "$$", closer = "$$",
            )
        }
        if (trimmed.startsWith("\\[")) {
            return blockMathProtocol(
                target = target, tLen = tLen, lineStart = lineStart,
                lineSoFar = lineSoFar, lineEndNL = lineEndNL,
                isStreamEnd = isStreamEnd, opener = "\\[", closer = "\\]",
            )
        }

        // Horizontal-rule candidate: a whole line of one marker character (-, * or _).
        // Held to end of line and then committed whole.
        if (trimmed.isNotEmpty()) {
            val first = trimmed.first()
            if ((first == '-' || first == '*' || first == '_') && trimmed.all { it == first }) {
                if (lineEndNL != null) {
                    return Boundary(target.substring(0, lineEndNL + 1), BoundaryKind.LineEnd)
                }
                if (isStreamEnd) {
                    return Boundary(target, BoundaryKind.LineEnd)
                }
                return Boundary(target.substring(0, lineStart), BoundaryKind.Held)
            }
        }

        if (!lineComplete && !isStreamEnd && lineSoFar.isNotEmpty()) {
            val held = Boundary(target.substring(0, lineStart), BoundaryKind.Held)
            // Ambiguity windows, expressed as patterns.
            // ^#{1,6}$ - parseHeadingLine matches a literal "# " including the space, so
            // committing "####" early paints it as a literal paragraph and the arrival of
            // the space re-classifies the whole line as a heading, jumping the font size.
            if (trimmed.length in 1..6 && trimmed.all { it == '#' }) return held
            // ^\d{1,9}\.?$ - parseOrderedListItem turns "1. x" into a bullet line, so
            // committing "1" or "1." early paints a literal paragraph that jumps its
            // indentation once the space arrives.
            if (isOrderedListAmbiguous(trimmed)) return held
            // General short window: under 4 characters, all of them marker candidates
            // (# > - * _ $ | ` ~ + \ and whitespace).
            if (lineSoFar.length < 4 && isAllMarkerCandidates(lineSoFar)) return held
        }

        return null
    }

    /** `^\d{1,9}\.?$`: digits with an optional trailing dot - an ordered-list prefix that has not settled yet. */
    private fun isOrderedListAmbiguous(trimmed: String): Boolean {
        if (trimmed.isEmpty() || trimmed.length > 10) return false
        val body = if (trimmed.last() == '.') trimmed.dropLast(1) else trimmed
        return body.isNotEmpty() && body.all { it.isDigit() }
    }

    private fun isAllMarkerCandidates(s: String): Boolean =
        s.all { it in "#>-*_$|`~+\\ \t" }

    // Table protocol

    private fun tableProtocol(
        target: String, tLen: Int, lineStart: Int,
        lineEndNL: Int?, visible: String, isStreamEnd: Boolean,
    ): Boundary {
        val held = Boundary(target.substring(0, lineStart), BoundaryKind.Held)

        // Already inside an open table: data rows are committed one whole row at a time.
        if (visibleEndsInOpenTable(visible)) {
            if (lineEndNL == null) {
                return if (isStreamEnd) Boundary(target, BoundaryKind.TableRows) else held
            }
            val end = extendThroughCompleteTableRows(target, tLen, from = lineEndNL + 1)
            return Boundary(target.substring(0, end), BoundaryKind.TableRows)
        }

        // Header candidate: the decision needs both the header line and the following
        // separator line to be complete.
        if (lineEndNL == null) {
            // A dangling | line at end of stream just settles as an ordinary line.
            return if (isStreamEnd) Boundary(target, BoundaryKind.LineEnd) else held
        }
        val sepStart = lineEndNL + 1
        val sepNL = target.indexOf('\n', sepStart)
        val sepComplete = sepNL >= 0
        if (!sepComplete && !isStreamEnd) return held
        val separator = target.substring(sepStart, if (sepComplete) sepNL else tLen)

        if (StreamingSplitter.isSeparatorRow(separator)) {
            val afterSep = if (sepComplete) sepNL + 1 else tLen
            val end = extendThroughCompleteTableRows(target, tLen, from = afterSep)
            return Boundary(target.substring(0, end), BoundaryKind.TableRows)
        }
        // A | line that is not a table: committed as an ordinary single line. The parser
        // renders it as a literal paragraph, so the prefix stays stable.
        return Boundary(target.substring(0, lineEndNL + 1), BoundaryKind.LineEnd)
    }

    /**
     * Extends the commit from [from] across every consecutive line that is complete and
     * starts with a `|` after trimming.
     *
     * @return the commit end offset, with each line's `\n` included.
     */
    private fun extendThroughCompleteTableRows(target: String, tLen: Int, from: Int): Int {
        var end = from
        while (end < tLen) {
            val nl = target.indexOf('\n', end)
            if (nl < 0) break // Hold a partial line.
            val t = target.substring(end, nl).trim(' ', '\t')
            if (t.isEmpty() || !t.startsWith("|")) break
            end = nl + 1
        }
        return end
    }

    /**
     * Whether the run of trailing lines in [visible] that start with `|` after trimming
     * forms an open table, i.e. a committed header plus separator pair.
     *
     * Only called when the current line starts with `|`, which is rare, so the O(visible)
     * scan is acceptable.
     */
    internal fun visibleEndsInOpenTable(visible: String): Boolean {
        val lines = visible.split('\n').toMutableList()
        if (lines.isNotEmpty() && lines.last().isEmpty()) lines.removeAt(lines.size - 1)
        val block = mutableListOf<String>()
        for (line in lines.asReversed()) {
            val t = line.trim(' ', '\t')
            if (t.isEmpty() || !t.startsWith("|")) break
            block.add(0, line)
        }
        if (block.size < 2) return false
        for (k in 1 until block.size) {
            if (StreamingSplitter.isSeparatorRow(block[k])) return true
        }
        return false
    }

    // Block math ($$ and \[..\])

    private fun blockMathProtocol(
        target: String, tLen: Int, lineStart: Int,
        lineSoFar: String, lineEndNL: Int?,
        isStreamEnd: Boolean, opener: String, closer: String,
    ): Boundary {
        val held = Boundary(target.substring(0, lineStart), BoundaryKind.Held)
        val trimmed = lineSoFar.trim(' ', '\t')

        // Single-line $$...$$ or \[...\]: commit as soon as the line completes.
        if (lineEndNL != null && trimmed.length >= opener.length + closer.length &&
            trimmed.endsWith(closer) && trimmed != opener
        ) {
            return Boundary(target.substring(0, lineEndNL + 1), BoundaryKind.LineEnd)
        }

        // Multi-line: find the first line after the opener that contains the closer, and
        // commit the whole block only once that line's \n is known.
        if (lineEndNL != null) {
            var cursor = lineEndNL + 1
            while (cursor < tLen) {
                val nl = target.indexOf('\n', cursor)
                val lineEnd = if (nl < 0) tLen else nl
                val line = target.substring(cursor, lineEnd)
                if (line.contains(closer)) {
                    if (nl >= 0) {
                        return Boundary(target.substring(0, nl + 1), BoundaryKind.LineEnd)
                    }
                    // The closing line exists but its \n has not arrived: release at end of
                    // stream, otherwise wait.
                    return if (isStreamEnd) Boundary(target, BoundaryKind.LineEnd) else held
                }
                if (nl < 0) break
                cursor = nl + 1
            }
        }
        return if (isStreamEnd) Boundary(target, BoundaryKind.LineEnd) else held
    }

    // Whole-line commits, including the multi-line extension

    private fun commitCompletedLines(
        target: String, tLen: Int, vLen: Int,
        firstLineEndNL: Int, firstLineBlank: Boolean,
        cadence: BlockCommitCadence,
    ): Boundary {
        var commitEnd = firstLineEndNL + 1
        var lastBlank = firstLineBlank

        val backlog = tLen - vLen
        if (backlog > cadence.multiLineBacklog) {
            var linesCommitted = 1
            while (linesCommitted < cadence.multiLineMax) {
                val nl = target.indexOf('\n', commitEnd)
                if (nl < 0) break // Only extend across complete lines.
                val t = target.substring(commitEnd, nl).trim(' ', '\t')
                // A line that opens a fence, a table or block math has to go through the
                // line-start protocol, so it is never folded into a multi-line commit.
                if (t.startsWith("```") || t.startsWith("|") || t.startsWith("$$") || t.startsWith("\\[")) break
                commitEnd = nl + 1
                linesCommitted += 1
                lastBlank = t.isEmpty()
            }
        }

        return Boundary(
            target.substring(0, commitEnd),
            if (lastBlank) BoundaryKind.ParagraphEnd else BoundaryKind.LineEnd,
        )
    }

    // Word chunks

    private fun wordChunkBoundary(
        target: String, lineStart: Int, lineSoFar: String,
        committedInLine: Int,
        profile: StreamingPacerProfile,
        cadence: BlockCommitCadence,
        isStreamEnd: Boolean,
        isFirstReveal: Boolean,
    ): Boundary {
        val lineLen = lineSoFar.length
        val held = Boundary(target.substring(0, lineStart + committedInLine), BoundaryKind.Held)

        val markerLen = lineMarkerLength(lineSoFar)
        if (lineLen <= markerLen) return held // Only the marker so far, nothing to commit.

        // Safe boundary from the scanner, measured over the content after the marker.
        val scanInput = lineSoFar.substring(markerLen)
        var safeRel = StreamingInlineSpanScanner.safeBoundary(scanInput)
        val scanLen = scanInput.length
        if (isStreamEnd || (scanLen - safeRel) > cadence.maxInlineHoldUtf16) {
            // End of stream, or the hold has run past its limit: release the text
            // literally. Once committed literally it stays literal, so it cannot flicker.
            safeRel = scanLen
        }
        val safeAbs = markerLen + safeRel
        var committable = safeAbs

        // ASCII on an incomplete line: hold back the trailing partial word by capping at
        // the last whitespace. A very long line with no spaces at all (a URL, base64) has
        // no whitespace to cap at, so past the hold limit this degrades to character
        // chunks rather than leaving the whole line invisible.
        if (profile == StreamingPacerProfile.Ascii && !isStreamEnd) {
            var capped = capAtLastWhitespace(lineSoFar, upTo = committable, floor = markerLen)
            if (capped > markerLen && capped < safeAbs) {
                // The cap must not land inside a closed span: in "...has **more bold**" the
                // last whitespace is inside the span, and committing there would put half a
                // bold marker on screen as literal text. Fall back to the safe boundary of
                // the capped prefix itself.
                capped = markerLen +
                    StreamingInlineSpanScanner.safeBoundary(lineSoFar.substring(markerLen, capped))
            }
            committable = if (safeAbs - capped > cadence.maxWordHoldUtf16) {
                safeAbs
            } else if (capped <= markerLen && isFirstReveal) {
                // First-paint exemption: the message has nothing visible yet and the first
                // word has not reached a space, so release immediately rather than waiting.
                // Half a word appears and the rest is appended in the same style, which is
                // visually seamless. Only the first chunk gets this; after that the word
                // boundary cadence resumes.
                safeAbs
            } else {
                capped
            }
        }
        if (committable <= committedInLine) return held

        var end: Int
        if (isStreamEnd) {
            end = committable
        } else {
            val chunkLen = if (profile == StreamingPacerProfile.Ascii) {
                cadence.wordChunkLenAscii
            } else {
                cadence.wordChunkLenCjk
            }
            // The base is max(committedInLine, markerLen): a marker is not content that can
            // be dribbled out, so the first chunk has to carry the whole marker. Otherwise,
            // when markerLen > chunkLen (a five-digit ordered list, an H6, a deeply indented
            // bullet), end would land inside the marker and the substring(markerLen, end)
            // below would throw.
            val ideal = maxOf(committedInLine, markerLen) + chunkLen
            end = if (ideal >= committable) {
                committable
            } else if (profile == StreamingPacerProfile.Ascii) {
                // Scan forward to a word boundary, including one trailing space. The scan
                // window is bounded so this stays O(1) per tick; if there is no whitespace in
                // the window (the no-space degradation path, or one enormous word) the chunk
                // is cut straight at ideal.
                var w = ideal
                val scanLimit = minOf(committable, ideal + 64)
                while (w < scanLimit && !isWhitespace(lineSoFar[w])) w++
                if (w < scanLimit) w + 1 else minOf(ideal, committable)
            } else {
                roundDownToCharBoundary(lineSoFar, proposed = ideal, floor = committedInLine)
            }
            // Spans are atomic: if the chunk end falls inside an already-closed inline span,
            // say in the middle of **bold**, committing half of it renders the markers
            // literally and then rewrites them, breaking prefix monotonicity. The end must
            // therefore itself be a safe point, so when it lands inside a span it is
            // extended to where that span closes. The loop always terminates because
            // committable is a safe point. Emitting a closed span all at once is also the
            // intended look: styled text appears in its final style, never half-formed.
            while (end > committedInLine && end < committable) {
                val prefix = lineSoFar.substring(markerLen, end)
                if (StreamingInlineSpanScanner.safeBoundary(prefix) == prefix.length) break
                end++
            }
        }
        if (end <= committedInLine) return held

        val kind = if (isStreamEnd && end == lineLen) BoundaryKind.LineEnd else BoundaryKind.WordChunk
        return Boundary(target.substring(0, lineStart + end), kind)
    }

    /**
     * Length of the block-level marker at the start of a line, matching how
     * parseBlocksWithGaps classifies line types.
     *
     * Recognises heading `#{1,6}` plus a space, quote `>` plus a space, bullet
     * `[ \t]*[-*+]` plus a space and ordered list `[ \t]*\d+\.` plus a space.
     *
     * @return the marker length in characters, or 0 when the line has no block marker.
     */
    internal fun lineMarkerLength(line: String): Int {
        val len = line.length
        // Heading: a run of 1..6 # followed by a single space, because parseHeadingLine
        // matches the literal "# ".
        var h = 0
        while (h < len && h < 6 && line[h] == '#') h++
        if (h >= 1) {
            return if (h < len && line[h] == ' ') h + 1 else 0
        }
        // Quote: > plus whitespace at the very start; indentation is not allowed.
        if (len >= 2 && line[0] == '>' && line[1].isWhitespace()) return 2
        // Bullets and ordered lists may be indented, since the parsers start from the
        // first non-whitespace character.
        var k = 0
        while (k < len && (line[k] == ' ' || line[k] == '\t')) k++
        if (k < len && (line[k] == '-' || line[k] == '*' || line[k] == '+') &&
            k + 1 < len && line[k + 1].isWhitespace()
        ) {
            return k + 2
        }
        if (k < len && line[k].isDigit()) {
            var d = k
            while (d < len && line[d].isDigit()) d++
            if (d < len && line[d] == '.' && d + 1 < len && line[d + 1].isWhitespace()) {
                return d + 2
            }
        }
        return 0
    }

    private fun capAtLastWhitespace(line: String, upTo: Int, floor: Int): Int {
        var last = -1
        var i = floor
        while (i < upTo) {
            if (isWhitespace(line[i])) last = i
            i++
        }
        return if (last < 0) floor else last + 1
    }

    private fun isWhitespace(c: Char): Boolean = c == ' ' || c == '\t'

    /**
     * Pulls a proposed boundary back to the start of a surrogate pair when it would split
     * one (emoji and other non-BMP characters), never going below [floor].
     *
     * ZWJ sequences are deliberately not protected: a combined emoji may briefly show its
     * component glyphs while it is still arriving, which matches the existing behaviour.
     */
    private fun roundDownToCharBoundary(s: String, proposed: Int, floor: Int): Int {
        if (proposed <= floor || proposed >= s.length) return proposed
        if (Character.isLowSurrogate(s[proposed]) && Character.isHighSurrogate(s[proposed - 1])) {
            return maxOf(floor, proposed - 1)
        }
        return proposed
    }
}
