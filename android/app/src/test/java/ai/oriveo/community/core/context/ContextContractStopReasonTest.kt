package ai.oriveo.community.core.context

import ai.oriveo.community.core.context.ContextContractFixture.bool
import ai.oriveo.community.core.context.ContextContractFixture.id
import ai.oriveo.community.core.context.ContextContractFixture.stringOrNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** stopReason contract: runs the shared stop-reason.v1 fixture case by case; failure messages start with the case id. */
class ContextContractStopReasonTest {

    private val fixture: JsonObject by lazy { ContextContractFixture.load("stop-reason.v1.json") }

    @Test
    fun `enum matches fixture verbatim`() {
        val wires = fixture["enum"]!!.jsonArray.map { it.jsonPrimitive.content }
        assertEquals(wires, StopReason.entries.map { it.wire })
    }

    @Test
    fun `fromStored maps null to null and unknown strings to unknown`() {
        assertNull(StopReason.fromStored(null))
        StopReason.entries.forEach { assertEquals(it, StopReason.fromStored(it.wire)) }
        assertEquals(StopReason.UNKNOWN, StopReason.fromStored("eos"))
        assertEquals(StopReason.UNKNOWN, StopReason.fromStored(""))
    }

    @Test
    fun `families and endings cover the fixture`() {
        assertEquals(fixture["mapping"]!!.jsonObject.keys, StopFamily.entries.map { it.wire }.toSet())
        assertEquals(fixture["ended"]!!.jsonObject.keys, StreamEnding.entries.map { it.wire }.toSet())
    }

    @Test
    fun `responses finishRaw joins status and incomplete reason`() {
        assertEquals("completed", StopReasonResolver.responsesFinishRaw("completed", null))
        assertEquals("failed", StopReasonResolver.responsesFinishRaw("failed", null))
        assertEquals("incomplete:max_output_tokens", StopReasonResolver.responsesFinishRaw("incomplete", "max_output_tokens"))
        assertEquals(
            StopReason.LENGTH,
            StopReasonResolver.resolve(
                StopFamily.OPENAI_RESPONSES,
                StreamEnding.CLEAN,
                StopReasonResolver.responsesFinishRaw("incomplete", "max_output_tokens"),
                hadContent = true,
            ),
        )
    }

    @Test
    fun `stop reason cases`() {
        val cases = ContextContractFixture.cases(fixture, "cases")
        assertEquals(79, cases.size)
        val failures = cases.mapNotNull { case ->
            val id = case.id()
            val input = case["input"]!!.jsonObject
            val got = StopReasonResolver.resolve(
                family = StopFamily.fromWire(input.stringOrNull("family")!!),
                ended = StreamEnding.fromWire(input.stringOrNull("ended")!!),
                finishRaw = input.stringOrNull("finishRaw"),
                hadContent = input.bool("hadContent"),
            )
            val expected = case.stringOrNull("expected")
            if (got.wire == expected) null else "$id: expected $expected, got ${got.wire}"
        }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    @Test
    fun `mapping table resolves every entry on a clean end`() {
        val mapping = fixture["mapping"]!!.jsonObject
        mapping.forEach { (family, table) ->
            table.jsonObject.forEach { (raw, expected) ->
                val got = StopReasonResolver.resolve(StopFamily.fromWire(family), StreamEnding.CLEAN, raw, hadContent = true)
                assertEquals("$family/$raw", expected.jsonPrimitive.content, got.wire)
            }
        }
    }

    @Test
    fun `isOverflow is true only for context_window_exceeded`() {
        StopReason.entries.forEach {
            assertEquals(it.wire, it == StopReason.CONTEXT_WINDOW_EXCEEDED, ContextOverflowClassifier.isOverflow(it))
        }
        assertEquals(false, ContextOverflowClassifier.isOverflow(null))
    }
}
