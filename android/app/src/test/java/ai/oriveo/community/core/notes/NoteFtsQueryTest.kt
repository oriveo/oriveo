package ai.oriveo.community.core.notes

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Locks the **shape** of the query string. Whether a MATCH actually hits is
 * [NoteFtsSearchBehaviorTest]'s job, and both layers are needed: on its own, this one once locked
 * in `"term"*` — the spelling that disables prefix matching — as if it were the specification.
 */
class NoteFtsQueryTest {

    @Test
    fun `plain terms become unquoted prefix tokens`() {
        // Leaving the quotes off is deliberate: quotes make FTS read the term as a phrase and
        // ignore the `*`, which turns prefix matching off.
        assertEquals("hello* world*", NoteFtsQuery.build("hello world"))
    }

    @Test
    fun `fts syntax chars are stripped not injected`() {
        // quotes / stars / colons / parens must not leak into the MATCH expression
        val q = NoteFtsQuery.build("foo\" OR bar* : (baz)")
        assertEquals("foo* OR* bar* baz*", q)
    }

    @Test
    fun `blank or symbol-only query returns null`() {
        assertNull(NoteFtsQuery.build("   "))
        assertNull(NoteFtsQuery.build("\"*:()"))
    }

    @Test
    fun `cjk runs preserved as terms`() {
        val q = NoteFtsQuery.build("にほん りょこう")
        assertTrue(q!!.contains("にほん*"))
        assertTrue(q.contains("りょこう*"))
    }

    @Test
    fun `any term prefix joins with OR and drops syntax carriers`() {
        assertEquals(
            "kubernetes* OR うんようけいかく*",
            NoteFtsQuery.buildAnyTermPrefix(listOf("kubernetes", "うんようけいかく", "a\"b", "x y", "")),
        )
    }

    @Test
    fun `any term prefix returns null without valid terms`() {
        assertNull(NoteFtsQuery.buildAnyTermPrefix(emptyList()))
        assertNull(NoteFtsQuery.buildAnyTermPrefix(listOf("\"", " ", "a*b")))
    }
}
