package ai.oriveo.community.core.voice

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Overlong liveInsert truncation is computed in one pass: 49,000 origin chars + 3,000 live chars, 200 calls in < 1 s (per-code-point recomputation would be O(n²)). */
class LiveDictationRulesPerfTest {

    @Test
    fun liveInsert_truncationIsLinear() {
        val origin = "a".repeat(49_000)
        val finals = listOf("b".repeat(1_500))
        val partial = "c".repeat(1_500)

        val first = LiveDictationRules.liveInsert(origin, origin.length, origin.length, finals, partial)
        // Budget = 50,000 - 49,000 - 1 (space between origin and final) - 1,500 final < 0, so all partial text is dropped and the final text is truncated to fit.
        assertEquals(LiveDictationRules.MAX_TEXT_LENGTH, first.text.length)
        assertEquals("$origin " + "b".repeat(999), first.text)
        assertEquals(first.cursor, first.volatileStart)

        val started = System.nanoTime()
        repeat(200) {
            LiveDictationRules.liveInsert(origin, origin.length, origin.length, finals, partial)
        }
        val elapsedMs = (System.nanoTime() - started) / 1_000_000
        assertTrue("200 liveInsert calls took $elapsedMs ms", elapsedMs < 1_000)
    }
}
