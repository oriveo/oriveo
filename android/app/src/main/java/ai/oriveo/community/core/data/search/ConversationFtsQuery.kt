package ai.oriveo.community.core.data.search

/**
 * CJK bigram tokenisation and FTS4 MATCH query building for the conversation index.
 * Pure functions, unit-testable on the JVM.
 *
 * ## Why bigrams
 *
 * The system SQLite that ships with minSdk 26 is 3.18, which has no FTS5 and therefore no
 * `trigram` tokenizer. Even with a newer SQLite, trigrams do not help the most common CJK word
 * length: a trigram index only kicks in from three non-wildcard characters, so a two-character
 * word falls back to a row-by-row scan that is slower than a plain `LIKE` over the table.
 * The `simple` tokenizer built into FTS4 is no better, because it treats a whole run of adjacent
 * CJK characters as a *single* token — "きょうのてんき" is one word, so searching for "てんき"
 * finds nothing.
 *
 * Bigrams cover the two-character case exactly, a three-character word still matches as two
 * bigrams joined by AND, and a single character matches by prefix.
 *
 * ## Tokenisation rules
 *
 * - A CJK run `c1..cn` produces `c1c2 c2c3 … c(n-1)cn` **plus a trailing `cn`**.
 *   The trailing single character matters: without it "きょ" only yields the token `きょ`, and a
 *   one-character query can only use the prefix `ょ*`, which never matches a character sitting in
 *   the second position of a bigram. With it, every character has been the first character of some
 *   token at least once.
 * - A run of letters or digits is kept whole. Non-CJK text already has word boundaries, so
 *   splitting it into bigrams would only inflate the index.
 * - Everything else (punctuation, whitespace, FTS syntax characters such as `" * : -`) is a
 *   separator and is dropped. Since those characters never enter the index, they can never leak
 *   from a user query into a MATCH expression and cause a syntax error.
 *
 * ## Query strings
 *
 * - CJK run of two or more characters: one quoted bigram per position (an exact token match);
 *   the space between terms is FTS's implicit AND.
 * - CJK run of exactly one character: the prefix `c*`. **A prefix operator must not be quoted**:
 *   `"c"*` parses as a phrase followed by an ignored star, which is an exact match rather than a
 *   prefix (the same trap as `NoteFtsQuery`).
 * - Letter/digit word: the prefix `word*`, so "hel" finds "hello".
 * - No usable term (pure punctuation or an empty string): returns null, and the caller falls back
 *   to searching titles and preview text only.
 */
object ConversationFtsQuery {

    /**
     * How many terms a query may carry. Beyond this the terms are sampled by stride, which
     * *widens* the result (a subset of an AND chain can only match more, never fewer). Queries
     * this long are rare; the cap exists so hundreds of terms are never handed to FTS at once.
     */
    private const val MAX_QUERY_TERMS = 12

    /**
     * How many characters of one message are tokenised. Guards against someone pasting a whole
     * book into a chat and blowing up the index; the remainder is simply not full-text searchable.
     */
    const val MAX_INDEXED_CHARS = 20_000

    /** Index side: raw text to a space-separated token string, written straight into the FTS4 column. */
    fun indexText(raw: String): String {
        if (raw.isEmpty()) return ""
        val source = if (raw.length > MAX_INDEXED_CHARS) raw.substring(0, MAX_INDEXED_CHARS) else raw
        val out = StringBuilder(source.length * 2)
        forEachRun(source) { run, cjk ->
            if (cjk) {
                if (run.length == 1) {
                    out.appendToken(run)
                } else {
                    for (i in 0 until run.length - 1) {
                        out.appendToken(run.substring(i, i + 2))
                    }
                    // Trailing character: guarantees every character has led some token, which is
                    // what makes prefix matching work for one-character queries.
                    out.appendToken(run.substring(run.length - 1))
                }
            } else {
                out.appendToken(run)
            }
        }
        return out.toString()
    }

    /** Query side: user input to an expression that can be fed to `MATCH`; null when no usable term. */
    fun build(raw: String): String? {
        val terms = mutableListOf<String>()
        forEachRun(raw) { run, cjk ->
            if (cjk) {
                if (run.length == 1) {
                    terms += "$run*"
                } else {
                    for (i in 0 until run.length - 1) {
                        terms += "\"${run.substring(i, i + 2)}\""
                    }
                }
            } else {
                terms += "$run*"
            }
        }
        if (terms.isEmpty()) return null
        return capTerms(terms).joinToString(" ")
    }

    /** Sampling by stride drops AND conditions, so recall widens and no matching conversation is lost. */
    private fun capTerms(terms: List<String>): List<String> {
        if (terms.size <= MAX_QUERY_TERMS) return terms
        val step = (terms.size + MAX_QUERY_TERMS - 1) / MAX_QUERY_TERMS
        return terms.filterIndexed { index, _ -> index % step == 0 }.take(MAX_QUERY_TERMS)
    }

    private fun StringBuilder.appendToken(token: String) {
        if (isNotEmpty()) append(' ')
        append(token)
    }

    /** Walks CJK runs, letter/digit runs and separators once, calling back with (run, isCjk). */
    private inline fun forEachRun(raw: String, onRun: (String, Boolean) -> Unit) {
        var index = 0
        while (index < raw.length) {
            val ch = raw[index]
            when {
                isCjk(ch) -> {
                    val start = index
                    while (index < raw.length && isCjk(raw[index])) index++
                    onRun(raw.substring(start, index), true)
                }
                ch.isLetterOrDigit() -> {
                    val start = index
                    while (index < raw.length && raw[index].isLetterOrDigit() && !isCjk(raw[index])) index++
                    onRun(raw.substring(start, index), false)
                }
                else -> index++
            }
        }
    }

    /**
     * Scripts without word boundaries, which is what bigrams are for: CJK unified ideographs
     * (including extension A and the compatibility block), kana, and Hangul syllables.
     *
     * The ranges are spelled out as code points rather than going through
     * `Character.UnicodeBlock`, whose block granularity differs between JDK and ART versions. If
     * the index side and the query side ever disagree on what counts as CJK, searches silently
     * return nothing.
     */
    private fun isCjk(ch: Char): Boolean {
        val code = ch.code
        return (code in 0x3400..0x4DBF) ||
            (code in 0x4E00..0x9FFF) ||
            (code in 0xF900..0xFAFF) ||
            (code in 0x3040..0x309F) ||
            (code in 0x30A0..0x30FF) ||
            (code in 0xAC00..0xD7AF)
    }
}
