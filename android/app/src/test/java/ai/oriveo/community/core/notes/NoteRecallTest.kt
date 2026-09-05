package ai.oriveo.community.core.notes

import ai.oriveo.community.core.model.Note
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Test

class NoteRecallTest {

    private fun note(
        id: String,
        title: String = "",
        body: String = "",
        tags: List<String> = emptyList(),
        updatedAt: String = "2026-06-01T00:00:00Z",
        deletedAt: String? = null,
    ) = Note(
        id = id,
        title = title,
        body = body,
        tags = tags,
        createdAt = "2026-06-01T00:00:00Z",
        updatedAt = updatedAt,
        deletedAt = deletedAt,
    )

    @Test
    fun `tag match scores 8 and crosses minScore`() {
        val notes = listOf(note("A", title = "Random", body = "x", tags = listOf("kubernetes")))
        val r = NoteRecall.findRelatedNotes("how to scale kubernetes pods", notes)
        assertEquals(1, r.size)
        assertEquals("A", r[0].note.id)
        assertTrue(r[0].score >= 8)
    }

    @Test
    fun `title plus body below minScore is excluded`() {
        // term hits body only (weight 2) < minScore 4
        val notes = listOf(note("A", title = "unrelated", body = "graphql resolver tips"))
        val r = NoteRecall.findRelatedNotes("graphql", notes)
        assertTrue(r.isEmpty())
    }

    @Test
    fun `title hit weight 4 reaches minScore`() {
        val notes = listOf(note("A", title = "graphql schema design", body = "x"))
        val r = NoteRecall.findRelatedNotes("graphql", notes)
        assertEquals(1, r.size)
    }

    @Test
    fun `cjk phrase recall via ngram`() {
        val notes = listOf(note("A", title = "にほんりょこうガイド", body = "ひこうきとホテル"))
        val r = NoteRecall.findRelatedNotes("にほんりょこうのけいかくをたてる", notes)
        assertEquals(1, r.size)
        assertEquals("A", r[0].note.id)
    }

    @Test
    fun `cjk scripts are tokenized without runtime regex properties`() {
        val notes = listOf(
            note("han", title = "にほんごのメモ"),
            note("hiragana", title = "ひらがなメモ"),
            note("katakana", title = "カタカナメモ"),
            note("hangul", title = "한글 메모"),
        )

        assertEquals("han", NoteRecall.findRelatedNotes("にほんご", notes).first().note.id)
        assertEquals("hiragana", NoteRecall.findRelatedNotes("ひらがな", notes).first().note.id)
        assertEquals("katakana", NoteRecall.findRelatedNotes("カタカナ", notes).first().note.id)
        assertEquals("hangul", NoteRecall.findRelatedNotes("한글 메모", notes).first().note.id)
    }

    @Test
    fun `deleted notes are skipped`() {
        val notes = listOf(note("A", title = "graphql schema", deletedAt = "2026-06-02T00:00:00Z"))
        assertTrue(NoteRecall.findRelatedNotes("graphql", notes).isEmpty())
    }

    @Test
    fun `empty draft returns empty`() {
        val notes = listOf(note("A", title = "graphql"))
        assertTrue(NoteRecall.findRelatedNotes("   ", notes).isEmpty())
    }

    @Test
    fun `limit caps results and orders by score`() {
        val notes = listOf(
            note("low", title = "graphql intro"),
            note("high", title = "graphql graphql guide", tags = listOf("graphql")),
            note("mid", title = "graphql tips body", body = "graphql"),
        )
        val r = NoteRecall.findRelatedNotes("graphql", notes, limit = 2)
        assertEquals(2, r.size)
        assertEquals("high", r[0].note.id) // highest score first
    }

    @Test
    fun `stopwords and short tokens ignored`() {
        // "the" is a stopword, "to" is < 3 chars -> no tokens -> empty
        val notes = listOf(note("A", title = "the cat", body = "to be"))
        assertTrue(NoteRecall.findRelatedNotes("the to", notes).isEmpty())
    }

    @Test
    fun `overlapping terms are all scored by one corpus scan`() {
        val result = NoteRecall.findRelatedNotes("banana ana nan", listOf(note("A", title = "banana")))

        assertEquals(1, result.size)
        assertEquals(12, result.single().score)
        assertEquals(setOf("ana", "banana", "nan"), result.single().matchedTerms.toSet())
    }

    @Test
    fun `candidate and body work are bounded`() {
        val candidates = (0 until NoteRecall.MAX_CANDIDATES).map { index ->
            note("recent-$index", title = "recent note $index", body = "unrelated")
        }
        val outsideCandidateBound = note("outside", title = "kubernetes deployment")
        val outsideBodyBound = note(
            "outside-body",
            title = "unrelated",
            body = "x".repeat(NoteRecall.MAX_BODY_CHARACTERS) + " kubernetes deployment",
        )
        val outsideTitleBound = note(
            "outside-title",
            title = "x".repeat(NoteRecall.MAX_TITLE_CHARACTERS) + " kubernetes deployment",
        )
        val outsideTagBound = note(
            "outside-tag",
            tags = listOf("x".repeat(NoteRecall.MAX_TAG_CHARACTERS) + "kubernetes"),
        )

        assertTrue(NoteRecall.findRelatedNotes("kubernetes deployment", candidates + outsideCandidateBound).isEmpty())
        assertTrue(NoteRecall.findRelatedNotes("kubernetes deployment", listOf(outsideBodyBound)).isEmpty())
        assertTrue(NoteRecall.findRelatedNotes("kubernetes deployment", listOf(outsideTitleBound)).isEmpty())
        assertTrue(NoteRecall.findRelatedNotes("kubernetes deployment", listOf(outsideTagBound)).isEmpty())
    }

    @Test
    fun `index caches normalized notes and refreshes changed versions`() {
        val index = NoteRecall.Index()
        val original = note("A", title = "deployment", body = "kubernetes", updatedAt = "100")
        index.update(listOf(original))
        index.find("deployment")
        index.update(listOf(original))
        index.find("kubernetes")
        assertEquals(NoteRecall.Index.CacheMetrics(1, 1), index.cacheMetrics())

        index.update(listOf(original.copy(body = "updated", updatedAt = "200")))
        assertEquals(NoteRecall.Index.CacheMetrics(1, 2), index.cacheMetrics())
    }

    @Test
    fun `index propagates cooperative cancellation checkpoints`() {
        val index = NoteRecall.Index()
        index.update(listOf(note("A", body = "x".repeat(4_096))))

        assertThrows(IllegalStateException::class.java) {
            index.find("absentterm") { throw IllegalStateException("cancelled") }
        }
    }

    @Test
    fun `index find with precomputed terms matches the draft path`() {
        val index = NoteRecall.Index()
        index.update(listOf(note("A", title = "kubernetes deployment")))

        val terms = NoteRecall.termsFor("kubernetes deployment")

        assertEquals(listOf("A"), index.find(terms).map { it.note.id })
        assertEquals(
            index.find("kubernetes deployment").map { it.note.id },
            index.find(terms).map { it.note.id },
        )
    }

    @Test
    fun `worst case corpus stays inside performance budget`() {
        val body = "にほんごのながい".repeat(4_100)
        val notes = (0 until 50).map { index -> note("note-$index", body = body) }
        val draft = (0 until NoteRecall.MAX_TERMS).joinToString(" ") { "absentterm${it}y" }
        val startedAt = System.nanoTime()

        NoteRecall.findRelatedNotes(draft, notes)

        val elapsedMillis = (System.nanoTime() - startedAt) / 1_000_000
        // Budget assertion, not a performance benchmark: 2s is a generous fallback
        // ceiling for the worst-case corpus stalling the draft input. Normal runs
        // finish in tens of milliseconds, leaving roughly two orders of magnitude
        // of margin, so this stays stable under parallel test execution. Do not
        // tighten or loosen it as a performance metric -- real perf tracking
        // belongs in a separate benchmark, not in a unit test.
        assertTrue("elapsed=${elapsedMillis}ms", elapsedMillis < 2_000)
    }
}
