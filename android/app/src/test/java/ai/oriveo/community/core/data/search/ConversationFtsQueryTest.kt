package ai.oriveo.community.core.data.search

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Offline proof surface for CJK bigram tokenisation and FTS4 query building.
 *
 * What it pins down is that the index side and the query side follow the same rules. If they ever
 * disagree, searches silently return nothing, and on screen that bug looks exactly like "there are
 * no results" — nothing reports an error.
 */
class ConversationFtsQueryTest {

    // ── Index side ────────────────────────────────────────────────────────

    @Test
    fun `cjk run is split into overlapping bigrams plus the trailing character`() {
        assertEquals("きょ ょう うの のて てん んき き", ConversationFtsQuery.indexText("きょうのてんき"))
    }

    @Test
    fun `two character cjk run yields the bigram and the trailing character`() {
        // The trailing character is what makes a one-character query matchable: without it, "ょ"
        // could only match by prefix, and the sole token of "きょ" is "きょ", which the prefix
        // "ょ*" never reaches.
        assertEquals("きょ ょ", ConversationFtsQuery.indexText("きょ"))
    }

    @Test
    fun `single character cjk run is kept as is`() {
        assertEquals("き", ConversationFtsQuery.indexText("き"))
    }

    @Test
    fun `latin words are kept whole and punctuation separates runs`() {
        assertEquals("hello world 2026", ConversationFtsQuery.indexText("hello, world! (2026)"))
    }

    @Test
    fun `mixed text keeps latin whole and bigrams the cjk part`() {
        assertEquals("AI てん んき きよ よほ ほう う today", ConversationFtsQuery.indexText("AI てんきよほう today"))
    }

    @Test
    fun `fts syntax characters never survive into the index`() {
        val tokens = ConversationFtsQuery.indexText("""a"b* c:d-e""")
        assertEquals("a b c d e", tokens)
    }

    @Test
    fun `empty and punctuation only input index to empty string`() {
        assertEquals("", ConversationFtsQuery.indexText(""))
        assertEquals("", ConversationFtsQuery.indexText("""  "*:-  """))
    }

    @Test
    fun `index text is capped so a pasted book cannot blow up the index`() {
        val huge = "き".repeat(ConversationFtsQuery.MAX_INDEXED_CHARS + 5_000)
        val tokens = ConversationFtsQuery.indexText(huge)
        // Each bigram costs three characters including its separating space, plus one more for the
        // trailing character. The bound has to follow the cap, never the length of the input.
        assertTrue(tokens.length < (ConversationFtsQuery.MAX_INDEXED_CHARS + 2) * 3)
    }

    // ── Query side ────────────────────────────────────────────────────────

    @Test
    fun `two character query becomes a single exact bigram term`() {
        assertEquals("\"てん\"", ConversationFtsQuery.build("てん"))
    }

    @Test
    fun `three character query becomes two anded bigrams`() {
        assertEquals("\"てん\" \"んき\"", ConversationFtsQuery.build("てんき"))
    }

    @Test
    fun `single character query uses an unquoted prefix term`() {
        // It must stay unquoted: `"て"*` parses as a phrase followed by an ignored star, which is
        // an exact match rather than a prefix.
        assertEquals("て*", ConversationFtsQuery.build("て"))
    }

    @Test
    fun `latin query uses a prefix term so hel finds hello`() {
        assertEquals("hel*", ConversationFtsQuery.build("hel"))
    }

    @Test
    fun `mixed query keeps both lanes`() {
        assertEquals("ai* \"てん\"", ConversationFtsQuery.build("ai てん"))
    }

    @Test
    fun `fts syntax characters are dropped instead of escaped into the match string`() {
        val match = ConversationFtsQuery.build("""he"llo* x:y""")
        assertEquals("he* llo* x* y*", match)
    }

    @Test
    fun `blank or punctuation only query returns null so the caller can fall back`() {
        assertNull(ConversationFtsQuery.build(""))
        assertNull(ConversationFtsQuery.build("   "))
        assertNull(ConversationFtsQuery.build("""  "*:-  """))
    }

    @Test
    fun `very long query is sampled instead of producing dozens of and terms`() {
        val match = requireNotNull(ConversationFtsQuery.build("あいうえおかきくけこさしすせそたちつ"))
        val terms = match.split(" ")
        assertTrue("An over-long query must be capped, but it produced ${terms.size} terms", terms.size <= 12)
    }

    // ── Both sides agree (this is the one that guards against silent misses) ──

    @Test
    fun `every query term produced for a phrase exists among that phrase's index tokens`() {
        val corpus = "きょうのてんき hello せかい AI じょしゅ"
        val tokens = ConversationFtsQuery.indexText(corpus).split(" ").toSet()
        listOf("てん", "うの", "せかい", "AI", "じょ", "き", "せ", "hello").forEach { query ->
            val match = requireNotNull(ConversationFtsQuery.build(query)) { "query $query should not return null" }
            match.split(" ").forEach { term ->
                val matched = if (term.endsWith("*")) {
                    val prefix = term.removeSuffix("*")
                    tokens.any { it.startsWith(prefix, ignoreCase = true) }
                } else {
                    tokens.contains(term.trim('"'))
                }
                assertTrue("term $term of query $query is missing from the index tokens: $tokens", matched)
            }
        }
    }
}
