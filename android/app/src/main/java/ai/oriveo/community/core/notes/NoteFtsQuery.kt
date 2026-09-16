package ai.oriveo.community.core.notes

/**
 * Turns user input into a safe FTS4 MATCH expression. Pure functions, unit-testable on the JVM.
 *
 * Strategy: split on anything that is not a letter, digit or CJK character, append `*` to each term
 * for prefix matching, and join with spaces (FTS's default operator is AND). An empty query returns
 * null so the caller can fall back to a plain listing or LIKE.
 *
 * ## Terms must not be quoted, or prefix matching stops working
 *
 * Quoting a term and then appending a star — `"term"*` — looks like escaping, but against FTS4 it
 * behaves like this:
 *
 * | MATCH expression | against the document `hello world` |
 * |---|---|
 * | `"hel"*` | **no match** |
 * | `hel*`   | matches |
 *
 * The quotes turn the term into a *phrase*, after which the trailing `*` is simply ignored, so the
 * expression degrades into an exact match that only fires when the input happens to equal a whole
 * token in the index. For CJK that is fatal: FTS4's default `simple` tokenizer treats a run of
 * adjacent CJK characters as a **single** token, and nobody types a query that equals the entire
 * run, so note search in those scripts finds nothing at all.
 *
 * Dropping the quotes is safe and needs no other escaping: [TERM] already restricts a term to
 * letters, digits and CJK, so FTS syntax characters (`" * : ( ) - ^`) can never appear inside one.
 * The keywords `AND`, `OR`, `NOT` and `NEAR` are not a problem either — with a `*` suffix they are
 * parsed as prefix terms rather than operators, so `AND*`, `OR* OR hello*` and `NOT* OR a*` all
 * match without error.
 */
object NoteFtsQuery {

    // A term is a run of letters, digits or CJK; everything else is a separator, FTS syntax
    // characters included, so a syntax character can never end up inside a term.
    private val TERM = Regex("[\\p{L}\\p{N}]+")

    /** @return an expression that can be fed to `MATCH`; null when the input holds no usable term. */
    fun build(raw: String): String? {
        val terms = TERM.findAll(raw).map { it.value }.filter { it.isNotBlank() }.toList()
        if (terms.isEmpty()) return null
        return terms.joinToString(" ") { "$it*" }
    }

    /**
     * Recall pre-filter: any term may match (OR with prefixes). Terms have to be normalised to
     * letters, digits or CJK already; anything else is dropped as a potential syntax carrier.
     */
    fun buildAnyTermPrefix(terms: List<String>): String? {
        val valid = terms.filter { TERM.matches(it) }
        if (valid.isEmpty()) return null
        return valid.joinToString(" OR ") { "$it*" }
    }
}
