package ai.oriveo.community.core.notes

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NoteFtsQueryTest {

    @Test
    fun `plain terms become quoted prefix tokens`() {
        assertEquals("\"hello\"* \"world\"*", NoteFtsQuery.build("hello world"))
    }

    @Test
    fun `fts syntax chars are stripped not injected`() {
        // quotes / stars / colons / parens must not leak into the MATCH expression
        val q = NoteFtsQuery.build("foo\" OR bar* : (baz)")
        assertEquals("\"foo\"* \"OR\"* \"bar\"* \"baz\"*", q)
    }

    @Test
    fun `blank or symbol-only query returns null`() {
        assertNull(NoteFtsQuery.build("   "))
        assertNull(NoteFtsQuery.build("\"*:()"))
    }

    @Test
    fun `cjk runs preserved as terms`() {
        val q = NoteFtsQuery.build("にほん りょこう")
        assertTrue(q!!.contains("\"にほん\"*"))
        assertTrue(q.contains("\"りょこう\"*"))
    }

    @Test
    fun `any term prefix joins with OR and drops syntax carriers`() {
        assertEquals(
            "\"kubernetes\"* OR \"うんようけいかく\"*",
            NoteFtsQuery.buildAnyTermPrefix(listOf("kubernetes", "うんようけいかく", "a\"b", "x y", "")),
        )
    }

    @Test
    fun `any term prefix returns null without valid terms`() {
        assertNull(NoteFtsQuery.buildAnyTermPrefix(emptyList()))
        assertNull(NoteFtsQuery.buildAnyTermPrefix(listOf("\"", " ", "a*b")))
    }
}
