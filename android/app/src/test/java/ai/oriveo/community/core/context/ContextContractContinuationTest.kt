package ai.oriveo.community.core.context

import ai.oriveo.community.core.context.ContextContractFixture.bool
import ai.oriveo.community.core.context.ContextContractFixture.id
import ai.oriveo.community.core.context.ContextContractFixture.stringOrNull
import ai.oriveo.community.core.model.ChatRole
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Test

/** Stateful continuation contract: wire-system.v1 continuationPlan + continuationCases, comparing instructions / previous_response_id / input case by case. */
class ContextContractContinuationTest {

    private val fixture: JsonObject by lazy { ContextContractFixture.load("wire-system.v1.json") }

    @Test
    fun `continuation cases`() {
        val plan = fixture["continuationPlan"]!!.jsonObject
        val system = plan.stringOrNull("system")
        val history = plan["history"]!!.jsonArray.map { el ->
            val m = el.jsonObject
            ContinuationTurn(role = role(m.stringOrNull("role")!!), text = m.stringOrNull("text")!!)
        }
        val current = plan.stringOrNull("current")!!
        val cases = ContextContractFixture.cases(fixture, "continuationCases")
        assertEquals(6, cases.size)
        cases.forEach { case ->
            val id = case.id()
            val s = case["state"]!!.jsonObject
            val state = ContinuationState(
                previousResponseId = s.stringOrNull("previousResponseId"),
                instructionsMode = ContinuationInstructionsMode.fromWire(s.stringOrNull("instructionsMode")),
                systemChangedSinceLastLeg = s.bool("systemChangedSinceLastLeg"),
                modelChanged = s.bool("modelChanged"),
                checkpointChanged = s.bool("checkpointChanged"),
            )
            val request = ContextContinuation.project(ContextContinuation.decide(state), system, history, current)
            val expected = case["expected"]!!.jsonObject
            assertEquals("$id: instructions", expected.stringOrNull("instructions"), request.instructions)
            assertEquals("$id: previous_response_id", expected.stringOrNull("previous_response_id"), request.previousResponseId)
            val input = expected["input"]!!.jsonArray.map { el ->
                val m = el.jsonObject
                ContinuationTurn(role = role(m.stringOrNull("role")!!), text = m.stringOrNull("content")!!)
            }
            assertEquals("$id: input", input, request.input)
        }
    }

    private fun role(wire: String): ChatRole = ChatRole.entries.first { it.rawValue == wire }
}
