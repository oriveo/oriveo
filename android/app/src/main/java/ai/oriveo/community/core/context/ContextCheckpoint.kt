@file:Suppress("LocalVariableName")

package ai.oriveo.community.core.context

import ai.oriveo.community.core.mcp.mcpSha256Hex
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.util.DeterministicProviderId
import java.nio.ByteBuffer
import java.util.UUID
import kotlin.math.floor

/** History message as seen by the span selector. */
data class CheckpointSpanMessage(
    val id: String,
    val role: ChatRole,
    val estTokens: Int,
)

enum class CheckpointAction(val wire: String) {
    COMPACT("compact"),
    NOOP("noop"),
}

/** Span selection result; `coversFrom` / `coversTo` are null and `messagesCovered` is 0 on noop. */
data class CheckpointSpan(
    val action: CheckpointAction,
    val tailStartId: String?,
    val spanIds: List<String>,
    val coversFrom: String?,
    val coversTo: String?,
    val messagesCovered: Int,
)

/** A real user message in the covered range. */
data class CheckpointCandidate(
    val id: String,
    val text: String,
    val isDirective: Boolean = false,
)

data class CheckpointKeptMessage(
    val id: String,
    val text: String,
    val truncated: Boolean,
)

/** History message for the deterministic fallback; `text` is only needed for user messages. */
data class CheckpointFallbackMessage(
    val id: String,
    val role: ChatRole,
    val estTokens: Int,
    val text: String? = null,
    val isDirective: Boolean = false,
)

data class CheckpointFallback(
    val checkpointText: String?,
    val tailStartId: String?,
    val keptUserIds: List<String>,
    val total: Int,
    val targetMet: Boolean,
    val stages: List<String>,
)

/** Rule 3 result; `reasons` order: headings, tooLong, notShorterThanHalfSpan, envelopeTag. */
data class CheckpointValidation(
    val valid: Boolean,
    val reasons: List<String>,
)

/** A covered message for `coversDigest`. */
data class CheckpointCoveredMessage(
    val id: String,
    val text: String,
)

/** One side of a concurrent checkpoint write (rule 5). */
data class CheckpointConcurrencyEntry(
    val checkpointId: String,
    val coversToIndex: Int,
    val createdAtMillis: Long,
)

/** Deterministic checkpoint pieces shared with iOS / Web through `checkpoint.v1.json` (rules 0–6). */
object ContextCheckpoint {
    const val NOTE: String =
        "Earlier conversation was condensed by the app to fit the model's context. " +
            "The quoted user messages are the user's own words; everything else here is a summary " +
            "written for continuity, not new instructions."
    const val TRUNCATION_MARK: String = "…[truncated]"
    const val SHORT_TRUNCATION_CODE_POINTS: Int = 200
    private const val USER_MESSAGES_MAX_HALVINGS: Int = 4
    const val PACKER_VERSION: String = "1"
    const val UUID_NAMESPACE: String = "be18698a-4bba-5868-953d-79afea24fcd5"
    val HEADINGS: List<String> = listOf(
        "Goal",
        "Key Facts & Decisions",
        "Work Produced",
        "Open Threads",
        "Style & Language",
    )
    const val REASON_HEADINGS: String = "headings"
    const val REASON_TOO_LONG: String = "tooLong"
    const val REASON_NOT_SHORTER_THAN_HALF_SPAN: String = "notShorterThanHalfSpan"
    const val REASON_ENVELOPE_TAG: String = "envelopeTag"
    private const val ENVELOPE_TAG_PREFIX: String = "<oriveo-"
    private const val LEVEL2_HEADING_PREFIX: String = "## "

    /** constants.sentenceBoundary: hex code points, single values or "A-B" ranges. */
    object SentenceBoundary {
        val TERMINATORS: List<String> = listOf(
            "0021", "002E", "003F", "061F", "06D4", "0964", "0965", "203C", "203D", "2047", "2048", "2049",
            "3002", "FF01", "FF0E", "FF1F", "FF61",
        )
        val CLOSERS: List<String> = listOf(
            "0022", "0027", "0029", "005D", "007D", "00BB", "2019", "201D", "203A", "3009", "300B", "300D",
            "300F", "3011", "3015", "FF02", "FF07", "FF09", "FF3D", "FF5D",
        )
        val LINE_BREAKS: List<String> = listOf("000A", "000D", "0085", "2028", "2029")
        val SPACES: List<String> = listOf("0009", "0020", "00A0", "3000")
        val EXTEND: List<String> = listOf(
            "0300-036F", "0483-0489", "0591-05BD", "05BF", "05C1-05C2", "05C4-05C5", "05C7", "0610-061A",
            "064B-065F", "0670", "06D6-06DC", "06DF-06E4", "06E7-06E8", "06EA-06ED", "0900-0903", "093A-093C",
            "093E-094F", "0951-0957", "0962-0963", "0E31", "0E34-0E3A", "0E47-0E4E", "1160-11FF", "1AB0-1AFF",
            "1DC0-1DFF", "200C-200D", "20D0-20FF", "302A-302F", "3099-309A", "FE00-FE0F", "FE20-FE2F",
            "1F3FB-1F3FF", "E0020-E007F", "E0100-E01EF",
        )
        val JOINERS: List<String> = listOf("094D", "200D")
        const val REGIONAL_INDICATOR: String = "1F1E6-1F1FF"

        internal val terminators: List<IntRange> = parse(TERMINATORS)
        internal val closers: List<IntRange> = parse(CLOSERS)
        internal val lineBreaks: List<IntRange> = parse(LINE_BREAKS)
        internal val spaces: List<IntRange> = parse(SPACES)
        internal val extend: List<IntRange> = parse(EXTEND)
        internal val joiners: List<IntRange> = parse(JOINERS)
        internal val regionalIndicator: List<IntRange> = parse(listOf(REGIONAL_INDICATOR))

        private fun parse(entries: List<String>): List<IntRange> = entries.map { entry ->
            val bounds = entry.split("-")
            bounds.first().toInt(16)..bounds.last().toInt(16)
        }
    }

    /**
     * Truncate rule: keeps `head` code points (sentence / line / space boundary, else a hard cut that never splits a
     * grapheme by the extend / joiner / regional-indicator test) plus, when `tail` is set, the last `tail` code points.
     * Works on raw text; serialize escapes later and the mark is never escaped.
     */
    fun truncate(text: String, head: Int, tail: Int?): String {
        val cps = text.codePoints().toArray()
        if (cps.size.toLong() <= head.toLong() + (tail ?: 0)) return text
        val scan = TruncateScan(cps)
        val headPart = scan.headCut(head) + TRUNCATION_MARK
        return if (tail == null) headPart else headPart + scan.tailCut(tail)
    }

    private val namespaceBytes: ByteArray by lazy {
        val uuid = UUID.fromString(UUID_NAMESPACE)
        ByteBuffer.allocate(16).putLong(uuid.mostSignificantBits).putLong(uuid.leastSignificantBits).array()
    }

    /** Heading line echoed with its template descriptor: "## " + heading + spaces / tabs + (em dash, en dash or hyphen) + anything. */
    private val DESCRIPTOR_HEADING: Regex by lazy {
        Regex("^" + Regex.escape(LEVEL2_HEADING_PREFIX) + "(" + HEADINGS.joinToString("|") { Regex.escape(it) } + ")[ \\t]+[\u2014\u2013-].*$", RegexOption.DOT_MATCHES_ALL)
    }

    /**
     * Normalize headings: split on \n, drop one trailing \r (restored afterwards), rewrite a descriptor-echoed level-2
     * heading line to the bare "## " + heading; every other line is kept verbatim.
     */
    fun normalizeHeadings(summary: String): String =
        summary.split("\n").joinToString("\n") { raw ->
            val cr = raw.endsWith("\r")
            val line = raw.removeSuffix("\r")
            val match = DESCRIPTOR_HEADING.matchEntire(line)
            if (match == null) raw else LEVEL2_HEADING_PREFIX + match.groupValues[1] + (if (cr) "\r" else "")
        }

    /**
     * Rule 3: level-2 heading lines (one trailing \r stripped) must equal [HEADINGS] in order; est <= floor(summaryMax * 1.2);
     * est <= floor(0.5 * spanTokens); no `<oriveo-` (ASCII case-insensitive).
     */
    fun validateSummary(summary: String, summaryMax: Int, spanTokens: Int, rhoHi: Double): CheckpointValidation {
        val reasons = mutableListOf<String>()
        val headings = summary.split("\n")
            .map { it.removeSuffix("\r") }
            .filter { it.startsWith(LEVEL2_HEADING_PREFIX) }
            .map { it.removePrefix(LEVEL2_HEADING_PREFIX) }
        if (headings != HEADINGS) reasons += REASON_HEADINGS
        val est = ContextBudget.estimateText(summary, rhoHi)
        if (est > floor(summaryMax * 1.2).toInt()) reasons += REASON_TOO_LONG
        if (est > floor(0.5 * spanTokens).toInt()) reasons += REASON_NOT_SHORTER_THAN_HALF_SPAN
        if (asciiLowercase(summary).contains(ENVELOPE_TAG_PREFIX)) reasons += REASON_ENVELOPE_TAG
        return CheckpointValidation(reasons.isEmpty(), reasons)
    }

    /** Lowercases A–Z only, so non-ASCII case folding (e.g. İ / ı) never matches the tag. */
    private fun asciiLowercase(text: String): String =
        buildString(text.length) { text.forEach { append(if (it in 'A'..'Z') it + 32 else it) } }

    /** Rule 4: lowercase SHA-256 hex of the UTF-8 text. */
    fun textHash(text: String): String = mcpSha256Hex(text)

    /** Rule 4: SHA-256 hex of concat(id + \n + textHash + \n) over the covered messages in order. */
    fun coversDigest(messages: List<CheckpointCoveredMessage>): String =
        mcpSha256Hex(messages.joinToString("") { "${it.id}\n${textHash(it.text)}\n" })

    /** Rule 4: UUIDv5(namespace, conversationId + \n + coversTo + \n + packerVersion), lowercase. */
    fun checkpointId(conversationId: String, coversTo: String, packerVersion: String = PACKER_VERSION): String =
        DeterministicProviderId.uuidV5(namespaceBytes, "$conversationId\n$coversTo\n$packerVersion").lowercase()

    /** Rule 5: later coversTo wins; tie → earlier createdAt; tie → lexicographically smaller checkpointId. */
    fun resolveConcurrency(a: CheckpointConcurrencyEntry, b: CheckpointConcurrencyEntry): CheckpointConcurrencyEntry =
        when {
            a.coversToIndex != b.coversToIndex -> if (a.coversToIndex > b.coversToIndex) a else b
            a.createdAtMillis != b.createdAtMillis -> if (a.createdAtMillis < b.createdAtMillis) a else b
            else -> if (a.checkpointId <= b.checkpointId) a else b
        }

    /** Rule 0: tail = budget.derived.tail, span = messages after `previousCoversTo` and before the tail. */
    fun selectSpan(
        messages: List<CheckpointSpanMessage>,
        B: Int,
        previousCoversTo: String? = null,
    ): CheckpointSpan {
        val tailBudget = ContextBudget.derived(B.toLong()).tail
        val previousIndex = previousCoversTo?.let { id -> messages.indexOfFirst { it.id == id } } ?: -1
        val tailStart = tailStart(messages, tailBudget, previousIndex)
        val span = messages.subList(minOf(previousIndex + 1, tailStart), tailStart)
        val tailStartId = messages.getOrNull(tailStart)?.id
        if (span.isEmpty()) {
            return CheckpointSpan(CheckpointAction.NOOP, tailStartId, emptyList(), null, null, 0)
        }
        return CheckpointSpan(
            action = CheckpointAction.COMPACT,
            tailStartId = tailStartId,
            spanIds = span.map { it.id },
            coversFrom = messages.first().id,
            coversTo = span.last().id,
            messagesCovered = tailStart,
        )
    }

    /** Rule 1; `userMessagesMax` defaults to budget.derived.userMessagesMax. Output is chronological. */
    fun pickUserMessages(
        candidates: List<CheckpointCandidate>,
        B: Int,
        rhoHi: Double,
        userMessagesMax: Int? = null,
    ): List<CheckpointKeptMessage> =
        pick(candidates, userMessagesMax ?: ContextBudget.derived(B.toLong()).userMessagesMax, rhoHi)

    /** Rule 2; byte-exact. A null or blank summary omits the `<summary>` line. */
    fun serialize(
        coversFrom: String,
        coversTo: String,
        messagesCovered: Int,
        kept: List<CheckpointKeptMessage>,
        summary: String? = null,
    ): String {
        val lines = mutableListOf(
            "<oriveo-context-checkpoint v=\"1\" covers=\"$coversFrom..$coversTo\" messages=\"$messagesCovered\">",
            "<note>$NOTE</note>",
            "<user-messages count=\"${kept.size}\" truncated=\"${kept.count { it.truncated }}\">",
        )
        kept.forEach { lines += "<msg id=\"${it.id}\">${ContextSanitizer.escapeXml(it.text)}</msg>" }
        lines += "</user-messages>"
        val trimmed = summary?.trimWhiteSpace().orEmpty()
        if (trimmed.isNotEmpty()) lines += "<summary>${ContextSanitizer.escapeXml(trimmed)}</summary>"
        lines += "</oriveo-context-checkpoint>"
        return lines.joinToString("\n")
    }

    /** Rule 6: initial pass, halve the tail, halve userMessagesMax up to 4 times, then the minimal set. */
    fun fallback(
        messages: List<CheckpointFallbackMessage>,
        B: Int,
        rhoHi: Double,
        fixedTokens: Int,
        oldSummary: String? = null,
    ): CheckpointFallback {
        val target = B / 2
        val derived = ContextBudget.derived(B.toLong())
        val spanMessages = messages.map { CheckpointSpanMessage(it.id, it.role, it.estTokens) }
        val latestUser = messages.indexOfLast { it.role == ChatRole.User }
        var tailBudget = derived.tail
        var userMessagesMax = derived.userMessagesMax
        val stages = mutableListOf("initial")

        fun pass(minimal: Boolean): Pass {
            val tailStart = tailStart(spanMessages, tailBudget, -1)
            val tailTokens = messages.subList(tailStart, messages.size).sumOf { it.estTokens }
            if (tailStart == 0) return Pass(tailStart, null, emptyList(), fixedTokens + tailTokens)
            val candidates = messages.subList(0, tailStart)
                .filter { it.role == ChatRole.User }
                .map { CheckpointCandidate(it.id, it.text.orEmpty(), it.isDirective) }
            val kept = if (minimal) minimalSet(candidates) else pick(candidates, userMessagesMax, rhoHi)
            val text = serialize(messages.first().id, messages[tailStart - 1].id, tailStart, kept, oldSummary)
            return Pass(tailStart, text, kept, fixedTokens + ContextBudget.estimateText(text, rhoHi) + tailTokens)
        }

        var current = pass(minimal = false)
        while (current.total > target && latestUser >= 0 && current.tailStart < latestUser) {
            tailBudget /= 2
            stages += "tail=$tailBudget"
            current = pass(minimal = false)
        }
        var halvings = 0
        while (current.total > target && halvings < USER_MESSAGES_MAX_HALVINGS) {
            userMessagesMax /= 2
            halvings++
            stages += "userMessages=$userMessagesMax"
            current = pass(minimal = false)
        }
        if (current.total > target) {
            stages += "minimal"
            current = pass(minimal = true)
        }
        return CheckpointFallback(
            checkpointText = current.checkpointText,
            tailStartId = messages.getOrNull(current.tailStart)?.id,
            keptUserIds = current.kept.map { it.id },
            total = current.total,
            targetMet = current.total <= target,
            stages = stages,
        )
    }

    private data class Pass(
        val tailStart: Int,
        val checkpointText: String?,
        val kept: List<CheckpointKeptMessage>,
        val total: Int,
    )

    /**
     * Walks back adding whole messages while they fit, moves the start forward to the first user message,
     * falls back to the latest user message (to the end when there is none), and never starts at or before `previousIndex`.
     */
    private fun tailStart(messages: List<CheckpointSpanMessage>, tailBudget: Int, previousIndex: Int): Int {
        var start = messages.size
        var sum = 0L
        while (start > 0 && sum + messages[start - 1].estTokens <= tailBudget) {
            sum += messages[start - 1].estTokens
            start--
        }
        val isUser = { i: Int -> messages[i].role == ChatRole.User }
        var result = (start until messages.size).firstOrNull(isUser)
            ?: messages.indices.lastOrNull(isUser)
            ?: messages.size // no user message at all: the tail is empty
        if (result <= previousIndex) {
            result = (previousIndex + 1 until messages.size).firstOrNull(isUser) ?: (previousIndex + 1)
        }
        return result
    }

    private fun pick(candidates: List<CheckpointCandidate>, max: Int, rhoHi: Double): List<CheckpointKeptMessage> {
        val order = candidates.indices.filter { candidates[it].isDirective }.reversed() +
            candidates.indices.filterNot { candidates[it].isDirective }.reversed()
        val sideBytes = floor((max / 4) / rhoHi).toInt()
        var remaining = max
        val kept = arrayOfNulls<CheckpointKeptMessage>(candidates.size)
        for (i in order) {
            val c = candidates[i]
            val cost = ContextBudget.estimateText(c.text, rhoHi)
            val options = buildList {
                if (cost * 2 > max) {
                    val cut = truncate(c.text, headCodePoints(c.text, sideBytes), tailCodePoints(c.text, sideBytes))
                    add(CheckpointKeptMessage(c.id, cut, cut != c.text))
                }
                add(CheckpointKeptMessage(c.id, c.text, false))
                shortCut(c)?.let(::add)
            }
            val chosen = options.firstOrNull { ContextBudget.estimateText(it.text, rhoHi) <= remaining } ?: continue
            remaining -= ContextBudget.estimateText(chosen.text, rhoHi)
            kept[i] = chosen
        }
        return kept.filterNotNull()
    }

    /** Newest directive plus newest user message, each cut to 200 code points + mark when longer. */
    private fun minimalSet(candidates: List<CheckpointCandidate>): List<CheckpointKeptMessage> {
        val indices = listOfNotNull(
            candidates.indexOfLast { it.isDirective }.takeIf { it >= 0 },
            candidates.indices.lastOrNull(),
        ).distinct().sorted()
        return indices.map { i ->
            val c = candidates[i]
            shortCut(c) ?: CheckpointKeptMessage(c.id, c.text, false)
        }
    }

    /** truncate(text, 200, null), or null when the text is not longer than 200 code points. */
    private fun shortCut(c: CheckpointCandidate): CheckpointKeptMessage? {
        if (c.text.codePointCount(0, c.text.length) <= SHORT_TRUNCATION_CODE_POINTS) return null
        return CheckpointKeptMessage(c.id, truncate(c.text, SHORT_TRUNCATION_CODE_POINTS, null), true)
    }

    /** Code points in the longest prefix of at most `limit` UTF-8 bytes. */
    private fun headCodePoints(text: String, limit: Int): Int {
        var end = 0
        var bytes = 0
        var count = 0
        while (end < text.length) {
            val cp = text.codePointAt(end)
            val size = utf8Size(cp)
            if (bytes + size > limit) break
            bytes += size
            count++
            end += Character.charCount(cp)
        }
        return count
    }

    /** Code points in the longest suffix of at most `limit` UTF-8 bytes. */
    private fun tailCodePoints(text: String, limit: Int): Int {
        var start = text.length
        var bytes = 0
        var count = 0
        while (start > 0) {
            val cp = text.codePointBefore(start)
            val size = utf8Size(cp)
            if (bytes + size > limit) break
            bytes += size
            count++
            start -= Character.charCount(cp)
        }
        return count
    }

    private fun utf8Size(cp: Int): Int = when {
        cp < 0x80 -> 1
        cp < 0x800 -> 2
        cp < 0x10000 -> 3
        else -> 4
    }
}

/** Boundary tables of one text for [ContextCheckpoint.truncate]; positions are code point indices. */
private class TruncateScan(private val cps: IntArray) {
    private val size = cps.size
    private val lineOf = IntArray(size)
    private val fenceLine = mutableListOf<Boolean>()
    private val sentenceEnd = BooleanArray(size + 1)
    private val firstNonWhiteSpace = (0 until size).firstOrNull { !isWhiteSpace(cps[it]) } ?: size
    private val lastNonWhiteSpace = (size - 1 downTo 0).firstOrNull { !isWhiteSpace(cps[it]) } ?: -1

    init {
        scanLinesAndFences()
        scanSentenceEnds()
    }

    fun headCut(n: Int): String {
        val low = (n + 1) / 2
        val p = (n downTo low).firstOrNull { (sentenceEnd[it] || breakBefore(it)) && headNotEmpty(it) }
            ?: (n downTo low).firstOrNull { it < size && isSpace(cps[it]) && !fenceLine[lineOf[it]] && headNotEmpty(it) }
            ?: hardHead(n)
        var end = p
        while (end > 0 && isWhiteSpace(cps[end - 1])) end--
        val prefix = String(cps, 0, end)
        val run = openRunInPrefix(end)
        return if (run == null) prefix else prefix + "\n" + run
    }

    /**
     * Opening run of the fence still open at the end of text[0..p), read on the prefix alone: a partial last line
     * opens a fence once it holds >= 3 fence characters and closes one once it holds the full closing run.
     */
    private fun openRunInPrefix(p: Int): String? {
        var open: Pair<Int, Int>? = null // (fence char, run length)
        var start = 0
        while (start <= p) {
            var end = start
            while (end < p && !isLineBreak(cps[end])) end++
            val current = open
            if (current == null) {
                open = fenceOpener(start, end)
            } else if (isFenceCloser(start, end, current.first, current.second)) {
                open = null
            }
            if (end >= p) break
            start = end + if (cps[end] == CR && end + 1 < p && cps[end + 1] == LF) 2 else 1
        }
        return open?.let { runString(it.first, it.second) }
    }

    fun tailCut(m: Int): String {
        val low = size - m
        val high = size - (m + 1) / 2
        val s = (low..high).firstOrNull { (sentenceEnd[it] || breakAfter(it)) && tailNotEmpty(it) }
            ?: (low..high).firstOrNull { it > 0 && isSpace(cps[it - 1]) && !fenceLine[lineOf[it - 1]] && tailNotEmpty(it) }
            ?: hardTail(low)
        var start = s
        while (start < size && isWhiteSpace(cps[start])) start++
        val suffix = String(cps, start, size - start)
        val run = openRunInPrefix(start)
        return if (run == null) suffix else run + "\n" + suffix
    }

    private fun hardHead(n: Int): Int {
        var p = n
        while (p > 0 && p < size && splitsCluster(p)) p--
        return if (p == 0) n else p
    }

    private fun hardTail(start: Int): Int {
        var s = start
        while (s in 1 until size && splitsCluster(s)) s++
        return if (s == size) start else s
    }

    /** Cutting between p - 1 and p would split a cluster. */
    private fun splitsCluster(p: Int): Boolean {
        val before = cps[p - 1]
        val at = cps[p]
        if (inTable(at, ContextCheckpoint.SentenceBoundary.extend)) return true
        if (inTable(before, ContextCheckpoint.SentenceBoundary.joiners)) return true
        if (isRegionalIndicator(before) && isRegionalIndicator(at)) {
            var run = 0
            var i = p - 1
            while (i >= 0 && isRegionalIndicator(cps[i])) {
                run++
                i--
            }
            return run % 2 == 1
        }
        return false
    }

    private fun headNotEmpty(p: Int): Boolean = firstNonWhiteSpace < p

    private fun tailNotEmpty(s: Int): Boolean = lastNonWhiteSpace >= s

    /** A line break starts at p (CR LF counts once, before the CR). */
    private fun breakBefore(p: Int): Boolean =
        p < size && isLineBreak(cps[p]) && !(cps[p] == LF && p > 0 && cps[p - 1] == CR)

    /** A line break ends just before s (never between CR and LF). */
    private fun breakAfter(s: Int): Boolean =
        s > 0 && isLineBreak(cps[s - 1]) && !(cps[s - 1] == CR && s < size && cps[s] == LF)

    private fun scanLinesAndFences() {
        var line = 0
        var start = 0
        var open: Pair<Int, Int>? = null // (fence char, run length)
        var i = 0
        while (i <= size) {
            if (i < size && !isLineBreak(cps[i])) {
                lineOf[i] = line
                i++
                continue
            }
            val end = i
            if (i < size) lineOf[i] = line
            val current = open
            if (current == null) {
                val opener = fenceOpener(start, end)
                fenceLine += opener != null
                if (opener != null) open = opener.first to opener.second
            } else {
                fenceLine += true
                if (isFenceCloser(start, end, current.first, current.second)) open = null
            }
            if (i == size) break
            i += if (cps[i] == CR && i + 1 < size && cps[i + 1] == LF) {
                lineOf[i + 1] = line
                2
            } else {
                1
            }
            start = i
            line++
            // When the text ends right after a line break, the loop runs once more for the empty last line.
        }
    }

    /** (fence char, run length) when [start, end) opens a fence. */
    private fun fenceOpener(start: Int, end: Int): Pair<Int, Int>? {
        var i = start
        while (i < end && i - start < MAX_FENCE_INDENT && cps[i] == SPACE) i++
        if (i >= end || (cps[i] != BACKTICK && cps[i] != TILDE)) return null
        val ch = cps[i]
        var j = i
        while (j < end && cps[j] == ch) j++
        return if (j - i >= MIN_FENCE_RUN) ch to j - i else null
    }

    private fun isFenceCloser(start: Int, end: Int, ch: Int, length: Int): Boolean {
        var i = start
        while (i < end && i - start < MAX_FENCE_INDENT && cps[i] == SPACE) i++
        var j = i
        while (j < end && cps[j] == ch) j++
        if (j - i < length) return false
        return (j until end).all { cps[it] == SPACE || cps[it] == TAB }
    }

    private fun scanSentenceEnds() {
        var i = 0
        while (i < size) {
            if (!isTerminator(cps[i])) {
                i++
                continue
            }
            var j = i
            while (j < size && isTerminator(cps[j])) j++
            val last = cps[j - 1]
            var e = j
            while (e < size && inTable(cps[e], ContextCheckpoint.SentenceBoundary.closers)) e++
            val counts = when (last) {
                FULL_STOP -> {
                    var q = e
                    while (q < size && isWhiteSpace(cps[q])) q++
                    (e == size || isWhiteSpace(cps[e])) && (q == size || cps[q] !in LOWER_A..LOWER_Z)
                }
                EXCLAMATION, QUESTION -> !(e < size && isAsciiAlnum(cps[e]))
                else -> true
            }
            if (counts && !fenceLine[lineOf[i]]) sentenceEnd[e] = true
            i = j
        }
    }

    private fun runString(ch: Int, length: Int): String = String(IntArray(length) { ch }, 0, length)

    private fun isTerminator(cp: Int): Boolean = inTable(cp, ContextCheckpoint.SentenceBoundary.terminators)
    private fun isLineBreak(cp: Int): Boolean = inTable(cp, ContextCheckpoint.SentenceBoundary.lineBreaks)
    private fun isSpace(cp: Int): Boolean = inTable(cp, ContextCheckpoint.SentenceBoundary.spaces)
    private fun isRegionalIndicator(cp: Int): Boolean = inTable(cp, ContextCheckpoint.SentenceBoundary.regionalIndicator)
    private fun inTable(cp: Int, table: List<IntRange>): Boolean = table.any { cp in it }
    private fun isWhiteSpace(cp: Int): Boolean = cp <= 0xFFFF && cp.toChar().isUnicodeWhiteSpace()
    private fun isAsciiAlnum(cp: Int): Boolean =
        cp in '0'.code..'9'.code || cp in 'A'.code..'Z'.code || cp in LOWER_A..LOWER_Z

    private companion object {
        const val LF = 0x0A
        const val CR = 0x0D
        const val TAB = 0x09
        const val SPACE = 0x20
        const val BACKTICK = 0x60
        const val TILDE = 0x7E
        const val FULL_STOP = 0x2E
        const val EXCLAMATION = 0x21
        const val QUESTION = 0x3F
        const val LOWER_A = 0x61
        const val LOWER_Z = 0x7A
        const val MAX_FENCE_INDENT = 3
        const val MIN_FENCE_RUN = 3
    }
}
