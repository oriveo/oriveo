package ai.oriveo.community.core.context

import ai.oriveo.community.core.context.ContextContractFixture.id
import ai.oriveo.community.core.context.ContextContractFixture.int
import ai.oriveo.community.core.context.ContextContractFixture.intOrNull
import ai.oriveo.community.core.context.ContextContractFixture.stringOrNull
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Conversation instruction normalization contract: runs the shared conversation-instructions.v1 fixture case by case; failure messages start with the case id. */
class ContextContractConversationInstructionsTest {

    private val fixture: JsonObject by lazy { ContextContractFixture.load("conversation-instructions.v1.json") }

    /** parts: each text segment is repeated `repeat` times (default 1) and concatenated in order. */
    private fun parts(element: JsonElement): String = buildString {
        element.jsonArray.forEach { el ->
            val part = el.jsonObject
            append(part.stringOrNull("text")!!.repeat(part.intOrNull("repeat") ?: 1))
        }
    }

    @Test
    fun max_code_points_matches_fixture() {
        assertEquals(fixture.int("maxCodePoints"), ConversationInstructions.MAX_CODE_POINTS)
    }

    @Test
    fun cases() {
        val cases = ContextContractFixture.cases(fixture, "cases")
        assertEquals(12, cases.size)
        val failures = cases.mapNotNull { case ->
            val got = ConversationInstructions.normalize(parts(case["input"]!!))
            val expected = parts(case["expected"]!!)
            if (got == expected) {
                null
            } else {
                "${case.id()}: expected ${expected.length} UTF-16 units, got ${got.length}"
            }
        }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }
}
