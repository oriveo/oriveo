package ai.oriveo.community.core.context

import ai.oriveo.community.core.context.ContextContractFixture.id
import ai.oriveo.community.core.context.ContextContractFixture.stringOrNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test

/** Outbound history sanitization contract: runs the shared sanitize.v1 fixture case by case, comparing text byte for byte. */
class ContextContractSanitizeTest {

    private val fixture: JsonObject by lazy { ContextContractFixture.load("sanitize.v1.json") }

    @Test
    fun `unanswered note and tag match fixture byte for byte`() {
        val envelope = fixture["unansweredEnvelope"]!!.jsonObject
        assertEquals(envelope.stringOrNull("note"), ContextSanitizer.UNANSWERED_NOTE)
        assertEquals(envelope.stringOrNull("tag"), ContextSanitizer.UNANSWERED_TAG)
    }

    @Test
    fun `sanitize cases`() {
        val cases = ContextContractFixture.cases(fixture, "cases")
        assertEquals(11, cases.size)
        cases.forEach { case ->
            val id = case.id()
            val input = case["input"]!!.jsonObject
            val messages = input["messages"]!!.jsonArray.map { ContextContractFixture.message(it.jsonObject) }
            val actual = ContextSanitizer.sanitize(messages, input.stringOrNull("keepAssistantId"))
            val expected = case["expected"]!!.jsonArray.map { it.jsonObject }
            assertEquals("$id: count", expected.size, actual.size)
            expected.zip(actual).forEachIndexed { i, (e, a) ->
                assertEquals("$id[$i]: id", e.stringOrNull("id"), a.id)
                assertEquals("$id[$i]: role", e.stringOrNull("role"), a.role.rawValue)
                assertEquals("$id[$i]: text", e.stringOrNull("text"), a.text)
                assertEquals(
                    "$id[$i]: attachments",
                    e["attachments"]!!.jsonArray.map { it.jsonPrimitive.content },
                    a.attachments.map { it.id },
                )
            }
        }
    }
}
