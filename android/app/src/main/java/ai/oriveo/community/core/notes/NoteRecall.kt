package ai.oriveo.community.core.notes

import ai.oriveo.community.core.model.Note
import java.text.Normalizer


object NoteRecall {

    const val DEFAULT_LIMIT = 2
    const val DEFAULT_MIN_SCORE = 4
    const val MAX_DRAFT_CHARACTERS = 4_096
    const val MAX_TERMS = 128
    const val MAX_TITLE_CHARACTERS = 512
    const val MAX_BODY_CHARACTERS = 32_768
    const val MAX_TAGS = 32
    const val MAX_TAG_CHARACTERS = 128
    const val MAX_CANDIDATES = 128

    
    const val RECENT_CANDIDATE_FLOOR = 24
    private const val TAG_WEIGHT = 8
    private const val TITLE_WEIGHT = 4
    private const val BODY_WEIGHT = 2

    private val STOP_WORDS = setOf(
        "about", "after", "also", "and", "are", "can", "could", "does", "for", "from",
        "how", "into", "should", "that", "the", "this", "use", "what", "when", "where",
        "with", "would",
    )

    private val DASH_UNDERSCORE = Regex("[_-]+")
    private val NON_ALNUM = Regex("[^\\p{L}\\p{N}\\s]+")
    private val WHITESPACE = Regex("\\s+")

    data class Result(val note: Note, val score: Int, val matchedTerms: List<String>)

    private fun normalizeText(value: String): String =
        Normalizer.normalize(value.lowercase(), Normalizer.Form.NFKC)
            .replace(DASH_UNDERSCORE, " ")
            .replace(NON_ALNUM, " ")
            .replace(WHITESPACE, " ")
            .trim()

    private fun tokenizeLatin(value: String): List<String> =
        normalizeText(value).split(" ")
            .map { it.trim() }
            .filter { it.length in 3..64 && it !in STOP_WORDS }

    private fun extractCjkPhrases(value: String): List<String> {
        val phrases = LinkedHashSet<String>()
        val run = mutableListOf<String>()

        fun flushRun() {
            if (run.size < 2) {
                run.clear()
                return
            }
            if (run.size <= 64) phrases.add(run.joinToString(""))
            if (run.size >= 4) {
                for (i in 0..run.size - 4) phrases.add(run.subList(i, i + 4).joinToString(""))
            }
            if (run.size >= 3) {
                for (i in 0..run.size - 3) phrases.add(run.subList(i, i + 3).joinToString(""))
            }
            run.clear()
        }

        val normalized = Normalizer.normalize(value.lowercase(), Normalizer.Form.NFKC)
        var offset = 0
        while (offset < normalized.length) {
            val codePoint = normalized.codePointAt(offset)
            if (isCjkCodePoint(codePoint)) {
                run.add(String(Character.toChars(codePoint)))
            } else {
                flushRun()
            }
            offset += Character.charCount(codePoint)
        }
        flushRun()
        return phrases.toList()
    }

    private fun isCjkCodePoint(codePoint: Int): Boolean =
        when (Character.UnicodeScript.of(codePoint)) {
            Character.UnicodeScript.HAN,
            Character.UnicodeScript.HIRAGANA,
            Character.UnicodeScript.KATAKANA,
            Character.UnicodeScript.HANGUL,
            -> true
            else -> false
        }

    private fun tokenize(value: String): List<String> =
        LinkedHashSet(tokenizeLatin(value) + extractCjkPhrases(value)).take(MAX_TERMS)

    private fun recallSample(value: String): String {
        if (value.length <= MAX_DRAFT_CHARACTERS) return value
        val half = MAX_DRAFT_CHARACTERS / 2
        return value.take(half) + "\n" + value.takeLast(half)
    }

    private data class PreparedNote(
        val note: Note,
        val title: String,
        val body: String,
        val tags: List<String>,
    )

    private class LiteralMultiPatternMatcher(patterns: List<String>) {
        private data class Node(
            val transitions: MutableMap<Char, Int> = mutableMapOf(),
            var failure: Int = 0,
            val outputs: MutableList<Int> = mutableListOf(),
        )

        private val nodes = mutableListOf(Node())
        private val patternCount = patterns.size

        init {
            patterns.forEachIndexed { patternIndex, pattern ->
                var state = 0
                pattern.forEach { character ->
                    state = nodes[state].transitions[character] ?: run {
                        nodes.add(Node())
                        val next = nodes.lastIndex
                        nodes[state].transitions[character] = next
                        next
                    }
                }
                nodes[state].outputs.add(patternIndex)
            }

            val queue = ArrayDeque(nodes[0].transitions.values)
            while (queue.isNotEmpty()) {
                val state = queue.removeFirst()
                nodes[state].transitions.forEach { (character, next) ->
                    queue.addLast(next)
                    var fallback = nodes[state].failure
                    while (fallback != 0 && character !in nodes[fallback].transitions) {
                        fallback = nodes[fallback].failure
                    }
                    val target = nodes[fallback].transitions[character]
                    if (target != null && target != next) nodes[next].failure = target
                    nodes[next].outputs.addAll(nodes[nodes[next].failure].outputs)
                }
            }
        }

        fun matches(text: String, checkpoint: () -> Unit = {}): Set<Int> {
            if (text.isEmpty() || patternCount == 0) return emptySet()
            val matches = mutableSetOf<Int>()
            var state = 0
            text.forEachIndexed { index, character ->
                while (state != 0 && character !in nodes[state].transitions) {
                    state = nodes[state].failure
                }
                nodes[state].transitions[character]?.let { state = it }
                matches.addAll(nodes[state].outputs)
                if (index % 256 == 0) checkpoint()
                if (matches.size == patternCount) return matches
            }
            return matches
        }
    }

    private fun prepare(note: Note): PreparedNote = PreparedNote(
        note = note,
        title = normalizeText(note.title.take(MAX_TITLE_CHARACTERS)),
        body = normalizeText(note.body.take(MAX_BODY_CHARACTERS)),
        tags = note.tags.take(MAX_TAGS)
            .map { normalizeText(it.take(MAX_TAG_CHARACTERS)) }
            .filter { it.isNotEmpty() },
    )

    
    fun termsFor(draftText: String): List<String> = tokenize(recallSample(draftText)).sorted()

    private fun rank(
        draftTerms: List<String>,
        preparedNotes: Collection<PreparedNote>,
        limit: Int,
        minScore: Int,
        checkpoint: () -> Unit = {},
    ): List<Result> {
        if (draftTerms.isEmpty()) return emptyList()
        val matcher = LiteralMultiPatternMatcher(draftTerms)
        return preparedNotes.asSequence()
            .mapNotNull { prepared ->
                checkpoint()
                val titleMatches = matcher.matches(prepared.title, checkpoint)
                val bodyMatches = matcher.matches(prepared.body, checkpoint)
                val tagMatches = mutableSetOf<Int>()
                prepared.tags.forEach { tag ->
                    tagMatches.addAll(matcher.matches(tag, checkpoint))
                    draftTerms.forEachIndexed { index, term ->
                        if (term.contains(tag)) tagMatches.add(index)
                    }
                }
                val score = tagMatches.size * TAG_WEIGHT +
                    titleMatches.size * TITLE_WEIGHT +
                    bodyMatches.size * BODY_WEIGHT
                if (score <= 0) {
                    null
                } else {
                    val matched = (tagMatches + titleMatches + bodyMatches).map { draftTerms[it] }
                    Result(prepared.note, score, matched)
                }
            }
            .filter { it.score >= minScore }
            .sortedWith(
                compareByDescending<Result> { it.score }
                    .thenByDescending { NoteTime.isoToMillisOrNull(it.note.updatedAt) ?: 0L },
            )
            .take(limit)
            .toList()
    }

    fun findRelatedNotes(
        draftText: String,
        notes: List<Note>,
        limit: Int = DEFAULT_LIMIT,
        minScore: Int = DEFAULT_MIN_SCORE,
    ): List<Result> {
        val prepared = notes.asSequence()
            .filter { it.deletedAt == null }
            .take(MAX_CANDIDATES)
            .map(::prepare)
            .toList()
        return rank(termsFor(draftText), prepared, limit, minScore)
    }

    class Index {
        data class CacheMetrics(val cachedNotes: Int, val preparedNotes: Int)

        private data class CacheEntry(val updatedAt: String, val prepared: PreparedNote)
        private val cache = linkedMapOf<String, CacheEntry>()
        private var preparedNoteCount = 0

        fun update(notes: List<Note>, checkpoint: () -> Unit = {}) {
            val candidates = notes.asSequence()
                .filter { it.deletedAt == null }
                .take(MAX_CANDIDATES)
                .toList()
            val activeIDs = candidates.mapTo(mutableSetOf()) { it.id }
            cache.keys.retainAll(activeIDs)
            candidates.forEach { note ->
                checkpoint()
                if (cache[note.id]?.updatedAt != note.updatedAt) {
                    cache[note.id] = CacheEntry(note.updatedAt, prepare(note))
                    preparedNoteCount += 1
                }
            }
        }

        fun find(
            draftText: String,
            limit: Int = DEFAULT_LIMIT,
            minScore: Int = DEFAULT_MIN_SCORE,
            checkpoint: () -> Unit = {},
        ): List<Result> = find(termsFor(draftText), limit, minScore, checkpoint)

        fun find(
            terms: List<String>,
            limit: Int = DEFAULT_LIMIT,
            minScore: Int = DEFAULT_MIN_SCORE,
            checkpoint: () -> Unit = {},
        ): List<Result> = rank(terms, cache.values.map { it.prepared }, limit, minScore, checkpoint)

        fun cacheMetrics(): CacheMetrics = CacheMetrics(cache.size, preparedNoteCount)
    }
}
