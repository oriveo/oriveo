package ai.oriveo.community.core.context

import java.text.Normalizer
import java.time.Instant
import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeParseException
import java.util.Locale
import kotlin.math.floor
import kotlin.math.ln
import kotlin.math.pow

/** One recall hit (memory-recall.v1 rule 8); `date` is the UTC YYYY-MM-DD of the item time or null. */
data class MemoryRecallHit(
    val id: String,
    val text: String,
    val date: String?,
    val score: Double,
    val coverage: Double,
)

/** How the user settles an L3 conflict (memory-recall.v1 rule 11). */
enum class MemoryConflictResolution(val wire: String) {
    USE_NEW("useNew"),
    KEEP_BOTH("keepBoth"),
    USE_OLD("useOld"),
    ;

    companion object {
        fun fromWire(wire: String): MemoryConflictResolution? = entries.firstOrNull { it.wire == wire }
    }
}

/** Fields [MemoryRecall.resolve] changes on one item. */
data class MemoryConflictPatch(
    val id: String,
    val status: MemoryStatus,
    val conflictGroupId: String?,
    val supersedes: List<String>,
) {
    fun applyTo(item: MemoryItem): MemoryItem =
        item.copy(status = status, conflictGroupId = conflictGroupId, supersedes = supersedes)
}

/** BM25 index over the active episodic items with at least one token (rule 4); immutable once built. */
class MemoryRecallIndex internal constructor(
    internal val docs: List<Doc>,
    internal val idf: Map<String, Double>,
    internal val avgdl: Double,
) {
    internal class Doc(
        val item: MemoryItem,
        /** Term frequency per distinct term, in first-occurrence order. */
        val tf: Map<String, Int>,
        val length: Int,
        val idfTotal: Double,
        val time: Instant?,
    )

    val size: Int get() = docs.size
}

/**
 * L3 recall (memory-recall.v1): one tokenizer + BM25 shared by the three clients; pure, no storage.
 * Constants are read verbatim from the fixture `constants`.
 */
object MemoryRecall {
    const val K1: Double = 1.2
    const val B: Double = 0.75
    const val TOP_K: Int = 5
    const val COVERAGE_MIN: Double = 0.25
    const val MIN_MATCHED_TERMS: Int = 2
    const val IDF_PRIOR_DOCS: Int = 20
    const val SCOPE_FACTOR_CONVERSATION: Double = 1.2
    const val SCOPE_FACTOR_FOLDER: Double = 1.1
    const val SCOPE_FACTOR_GLOBAL: Double = 1.0
    const val PINNED_FACTOR: Double = 1.2
    const val HALF_LIFE_DAYS: Double = 180.0
    const val TIME_FLOOR: Double = 0.5
    const val CONFIDENCE_FLOOR: Double = 0.5
    const val MAX_QUERY_CODE_POINTS: Int = 8000
    const val CONFLICT_JACCARD_MIN: Double = 0.5
    const val JOINERS: String = "_.-/#"

    /** Inclusive code point intervals that count as CJK (rule 2); not the Unicode Script property. */
    val CJK_RANGES: List<IntRange> = listOf(
        4352..4607,
        12352..12447,
        12448..12543,
        12592..12687,
        12784..12799,
        13312..19903,
        19968..40959,
        44032..55215,
        63744..64255,
        131072..201551,
    )

    private const val DAY_MS = 86_400_000.0
    private const val FINAL_SIGMA = 'ς'
    private const val SIGMA = 'σ'

    fun round6(x: Double): Double = floor(x * 1e6 + 0.5) / 1e6

    // ---- tokenizer (rules 1–3) ----

    /** Word tokens in text order, then compound tokens in text order; duplicates kept. */
    fun tokens(text: String): List<String> {
        val normalized = Normalizer.normalize(text, Normalizer.Form.NFKC)
            .lowercase(Locale.ROOT)
            .replace(FINAL_SIGMA, SIGMA)
        val cps = normalized.codePoints().toArray()
        val words = ArrayList<String>()
        val compounds = ArrayList<String>()
        var i = 0
        while (i < cps.size) {
            if (!isWord(cps[i])) {
                i++
                continue
            }
            // Maximal word run [i, end), split where CJK-ness changes.
            var end = i
            while (end < cps.size && isWord(cps[end])) end++
            var start = i
            while (start < end) {
                val cjk = isCjk(cps[start])
                var stop = start
                while (stop < end && isCjk(cps[stop]) == cjk) stop++
                if (!cjk) {
                    words += String(cps, start, stop - start)
                } else if (stop - start == 1) {
                    words += String(cps, start, 1)
                } else {
                    for (k in start until stop - 1) words += String(cps, k, 2)
                }
                start = stop
            }
            i = end
        }
        // Compounds: maximal runs of word chars and joiners, joiners stripped at both ends, still holding a joiner.
        i = 0
        while (i < cps.size) {
            if (!isWord(cps[i]) && !isJoiner(cps[i])) {
                i++
                continue
            }
            var end = i
            while (end < cps.size && (isWord(cps[end]) || isJoiner(cps[end]))) end++
            var a = i
            var z = end
            while (a < z && isJoiner(cps[a])) a++
            while (z > a && isJoiner(cps[z - 1])) z--
            if ((a until z).any { isJoiner(cps[it]) }) compounds += String(cps, a, z - a)
            i = end
        }
        return words + compounds
    }

    private fun isWord(cp: Int): Boolean = when (Character.getType(cp).toByte()) {
        Character.UPPERCASE_LETTER, Character.LOWERCASE_LETTER, Character.TITLECASE_LETTER,
        Character.MODIFIER_LETTER, Character.OTHER_LETTER,
        Character.DECIMAL_DIGIT_NUMBER, Character.LETTER_NUMBER, Character.OTHER_NUMBER,
        Character.NON_SPACING_MARK, Character.ENCLOSING_MARK, Character.COMBINING_SPACING_MARK,
        -> true
        else -> false
    }

    private fun isCjk(cp: Int): Boolean = CJK_RANGES.any { cp in it }

    private fun isJoiner(cp: Int): Boolean = cp < 0x80 && JOINERS.indexOf(cp.toChar()) >= 0

    // ---- index (rule 4) ----

    fun buildIndex(items: List<MemoryItem>): MemoryRecallIndex {
        val docs = ArrayList<Pair<MemoryItem, List<String>>>()
        for (raw in items) {
            if (raw.layer != MemoryLayer.EPISODIC || raw.status != MemoryStatus.ACTIVE) continue
            val toks = tokens(raw.content)
            if (toks.isEmpty()) continue
            docs += MemoryItems.canonical(raw) to toks
        }
        val n = docs.size
        val df = HashMap<String, Int>()
        val tfs = docs.map { (_, toks) ->
            val tf = LinkedHashMap<String, Int>()
            toks.forEach { tf[it] = (tf[it] ?: 0) + 1 }
            tf.keys.forEach { df[it] = (df[it] ?: 0) + 1 }
            tf
        }
        val idf = HashMap<String, Double>(df.size)
        df.forEach { (t, d) -> idf[t] = ln(1.0 + (n + IDF_PRIOR_DOCS - d + 0.5) / (d + 0.5)) }
        val avgdl = if (n == 0) 0.0 else docs.sumOf { it.second.size }.toDouble() / n
        val built = docs.mapIndexed { k, (item, toks) ->
            val tf = tfs[k]
            MemoryRecallIndex.Doc(
                item = item,
                tf = tf,
                length = toks.size,
                idfTotal = tf.keys.sumOf { idf.getValue(it) },
                time = itemTime(item),
            )
        }
        return MemoryRecallIndex(built, idf, avgdl)
    }

    // ---- recall (rules 5–8) ----

    fun recall(index: MemoryRecallIndex, query: String, conversationId: String, folderId: String?, now: Instant): List<MemoryRecallHit> {
        if (index.docs.isEmpty()) return emptyList()
        val q = tokens(truncateCodePoints(query, MAX_QUERY_CODE_POINTS)).toHashSet()
        if (q.isEmpty()) return emptyList()
        return rank(index, q, conversationId, folderId, now, COVERAGE_MIN, MIN_MATCHED_TERMS, emptySet(), TOP_K)
    }

    /**
     * Rules 5–8 for already tokenised [q], with the gate ([coverageMin], [minMatchedTerms]) and Top-K passed in;
     * items whose lowercased id is in [excludeIds] are skipped before Top-K (memory-search.v1 rule 3).
     */
    @Suppress("LongParameterList")
    internal fun rank(
        index: MemoryRecallIndex,
        q: Set<String>,
        conversationId: String,
        folderId: String?,
        now: Instant,
        coverageMin: Double,
        minMatchedTerms: Int,
        excludeIds: Set<String>,
        topK: Int,
    ): List<MemoryRecallHit> {
        if (index.docs.isEmpty() || q.isEmpty()) return emptyList()
        val conversationKey = conversationId.lowercase()
        val folderKey = folderId?.lowercase()
        val hits = ArrayList<MemoryRecallHit>()
        for (doc in index.docs) {
            val item = doc.item
            if (excludeIds.isNotEmpty() && item.id.lowercase() in excludeIds) continue
            val expires = item.expiresAt
            if (expires != null && !(parseTime(expires)?.isAfter(now) ?: true)) continue
            val scopeKey = item.scope.id?.lowercase()
            val scopeFactor = when (item.scope.type) {
                MemoryScopeType.GLOBAL -> SCOPE_FACTOR_GLOBAL
                MemoryScopeType.CONVERSATION -> if (scopeKey == conversationKey) SCOPE_FACTOR_CONVERSATION else continue
                MemoryScopeType.FOLDER -> if (folderKey != null && scopeKey == folderKey) SCOPE_FACTOR_FOLDER else continue
            }
            var bm25 = 0.0
            var matchedIdf = 0.0
            var matched = 0
            val norm = K1 * (1 - B + B * doc.length / index.avgdl)
            for ((t, tf) in doc.tf) {
                if (t !in q) continue
                val idf = index.idf.getValue(t)
                bm25 += idf * tf * (K1 + 1) / (tf + norm)
                matchedIdf += idf
                matched++
            }
            if (bm25 <= 0.0 || matched < minOf(minMatchedTerms, doc.tf.size)) continue
            val coverage = round6(matchedIdf / doc.idfTotal)
            if (coverage < coverageMin) continue
            val ageDays = doc.time?.let { maxOf(0.0, (now.toEpochMilli() - it.toEpochMilli()) / DAY_MS) } ?: 0.0
            val timeFactor = TIME_FLOOR + (1 - TIME_FLOOR) * 0.5.pow(ageDays / HALF_LIFE_DAYS)
            val confidenceFactor = CONFIDENCE_FLOOR + (1 - CONFIDENCE_FLOOR) * item.confidence.coerceIn(0.0, 1.0)
            val pinnedFactor = if (item.pinned) PINNED_FACTOR else 1.0
            val score = round6(bm25 * scopeFactor * pinnedFactor * timeFactor * confidenceFactor)
            hits += MemoryRecallHit(item.id, item.content, doc.time?.let(::utcDate), score, coverage)
        }
        hits.sortWith(compareByDescending<MemoryRecallHit> { it.score }.thenBy { it.id })
        return hits.take(topK)
    }

    // ---- conflict / resolve (rules 10–11) ----

    /** Id of the active episodic item [saved] conflicts with, or null. */
    fun conflict(saved: MemoryItem, items: List<MemoryItem>): String? {
        val savedId = saved.id.lowercase()
        val savedScope = saved.scope.id?.lowercase()
        val savedTokens = tokens(saved.content).toHashSet()
        var best: String? = null
        var bestJaccard = -1.0
        for (other in items) {
            val otherId = other.id.lowercase()
            if (otherId == savedId) continue
            if (other.layer != MemoryLayer.EPISODIC || other.status != MemoryStatus.ACTIVE) continue
            if (other.kind != saved.kind || other.scope.type != saved.scope.type || other.scope.id?.lowercase() != savedScope) continue
            val otherTokens = tokens(other.content).toHashSet()
            val union = (savedTokens + otherTokens).size
            if (union == 0) continue
            val jaccard = round6(savedTokens.count { it in otherTokens }.toDouble() / union)
            if (jaccard < CONFLICT_JACCARD_MIN || jaccard >= 1.0) continue
            if (jaccard > bestJaccard || (jaccard == bestJaccard && otherId < best!!)) {
                best = otherId
                bestJaccard = jaccard
            }
        }
        return best
    }

    /** Patches for [newer] then [older]; both leave the conflict group, nothing is deleted. */
    fun resolve(newer: MemoryItem, older: MemoryItem, resolution: MemoryConflictResolution): List<MemoryConflictPatch> {
        val olderId = older.id.lowercase()
        val newerSupersedes = newer.supersedes.map { it.lowercase() }
        val olderSupersedes = older.supersedes.map { it.lowercase() }
        val (newerStatus, olderStatus) = when (resolution) {
            MemoryConflictResolution.USE_NEW -> MemoryStatus.ACTIVE to MemoryStatus.SUPERSEDED
            MemoryConflictResolution.KEEP_BOTH -> MemoryStatus.ACTIVE to MemoryStatus.ACTIVE
            MemoryConflictResolution.USE_OLD -> MemoryStatus.SUPERSEDED to MemoryStatus.ACTIVE
        }
        val supersedes = if (resolution == MemoryConflictResolution.USE_NEW && olderId !in newerSupersedes) {
            newerSupersedes + olderId
        } else {
            newerSupersedes
        }
        return listOf(
            MemoryConflictPatch(newer.id.lowercase(), newerStatus, null, supersedes),
            MemoryConflictPatch(olderId, olderStatus, null, olderSupersedes),
        )
    }

    // ---- helpers ----

    /** First of occurredAt, source.observedAt, createdAt that parses as RFC 3339 (rule 7). */
    private fun itemTime(item: MemoryItem): Instant? =
        listOfNotNull(item.occurredAt, item.source.observedAt, (item.createdAt as? MemoryServerTime.At)?.rfc3339)
            .firstNotNullOfOrNull(::parseTime)

    private fun parseTime(rfc3339: String): Instant? = try {
        OffsetDateTime.parse(rfc3339).toInstant()
    } catch (_: DateTimeParseException) {
        null
    }

    private fun utcDate(time: Instant): String = time.atOffset(ZoneOffset.UTC).toLocalDate().toString()

    internal fun truncateCodePoints(text: String, max: Int): String {
        if (text.length <= max) return text
        val count = text.codePointCount(0, text.length)
        return if (count <= max) text else text.substring(0, text.offsetByCodePoints(0, max))
    }
}
