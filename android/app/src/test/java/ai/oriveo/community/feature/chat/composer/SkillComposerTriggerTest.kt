package ai.oriveo.community.feature.chat.composer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** P4 contract 18: where `/` and `@` open the skill picker. */
class SkillComposerTriggerTest {

    private fun detectAtEnd(text: String) = SkillComposerTrigger.detect(text, text.length)

    @Test
    fun trigger_at_start() {
        assertEquals(SkillTrigger('/', 0, ""), detectAtEnd("/"))
        assertEquals(SkillTrigger('/', 0, "wee"), detectAtEnd("/wee"))
    }

    @Test
    fun trigger_after_space() {
        assertEquals(SkillTrigger('/', 6, "rep"), detectAtEnd("hello /rep"))
        assertEquals(SkillTrigger('/', 6, ""), detectAtEnd("hello\n/"))
        // The query runs only up to the caret.
        assertEquals(SkillTrigger('/', 3, "w"), SkillComposerTrigger.detect("hi /weekly", 5))
    }

    @Test
    fun no_trigger_in_url() {
        assertNull(detectAtEnd("see https://example.com/path"))
        assertNull(detectAtEnd("open /usr/local/bin"))
        assertNull(detectAtEnd("mail me at user@example.com"))
    }

    @Test
    fun no_trigger_mid_word() {
        assertNull(detectAtEnd("and/or"))
        assertNull(detectAtEnd("team@"))
        // A selection never triggers.
        assertNull(SkillComposerTrigger.detect("/abc", 4, selectionStart = 1))
    }

    @Test
    fun query_closes_on_space() {
        assertNull(detectAtEnd("/weekly "))
        assertNull(detectAtEnd("/weekly report"))
        assertNull(detectAtEnd("@writer tone"))
    }

    @Test
    fun at_sign_triggers() {
        val trigger = detectAtEnd("ask @wri")
        assertEquals(SkillTrigger('@', 4, "wri"), trigger)
        assertEquals("at", trigger?.via)
        assertEquals("slash", detectAtEnd("/x")?.via)
        // Picking removes the symbol and the query.
        assertEquals("ask ", SkillComposerTrigger.remove("ask @wri", trigger!!))
        assertEquals("a  b", SkillComposerTrigger.remove("a /x b", SkillTrigger('/', 2, "x")))
    }
}
