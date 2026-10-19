package ai.oriveo.community.core.context

import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test

/** The full Unicode White_Space set matches the whitespace entry of the shared directive-detector.v2 fixture (the same set on every platform). */
class WhiteSpaceTest {

    /** Fixture notation "U+XXXX" or "U+XXXX..U+YYYY", expanded into a set of code points. */
    private fun fixtureCodePoints(): Set<Int> =
        ContextContractFixture.load("directive-detector.v2.json")["whitespace"]!!.jsonArray
            .flatMap { entry ->
                val bounds = entry.jsonPrimitive.content.split("..").map { it.removePrefix("U+").toInt(16) }
                (bounds.first()..bounds.last()).toList()
            }
            .toSet()

    @Test
    fun white_space_matches_fixture() {
        // Scans the whole BMP: one too many or one too few fails.
        val actual = (0..0xFFFF).filter { it.toChar().isUnicodeWhiteSpace() }.toSet()
        assertEquals(fixtureCodePoints().sorted(), actual.sorted())
    }

    @Test
    fun trim_white_space_uses_same_set() {
        val all = fixtureCodePoints().map { it.toChar() }.joinToString("")
        assertEquals("x", (all + "x" + all).trimWhiteSpace())
        // U+FEFF and U+001C–001F are not white space; trim leaves them alone.
        assertEquals("﻿x\u001C", "﻿x\u001C".trimWhiteSpace())
    }
}
