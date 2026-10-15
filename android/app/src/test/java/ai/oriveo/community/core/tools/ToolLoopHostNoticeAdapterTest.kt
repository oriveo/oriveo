package ai.oriveo.community.core.tools

import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Host loop notices: the notice appended after the tool loop hits its cap must be a user message
 * and must never rewrite system. Runs the production ToolCallLoop up to the step limit, encodes
 * every leg's request with the four wire protocols, and asserts that system stays byte-identical
 * and the notice lands after the tool results (sharing the tool result user turn on Anthropic /
 * Gemini).
 */
class ToolLoopHostNoticeAdapterTest {
    private val notice = ToolCallLoop.Prompts().stepLimitReached

    private suspend fun legRequests(): List<ToolLoopLegRequest> {
        val legs = ScriptedLegs(listOf(
            toolLeg(call(0, "c1", "web_search")),
            toolLeg(call(0, "c2", "web_search"), call(1, "c3", "web_search")),
            textLeg("final"),
        ))
        val loop = ToolCallLoop(
            ToolRegistry(listOf(ScriptedEntry("web_search"))),
            legs,
            limits = ToolCallLoop.Limits(maxSteps = 2),
        )
        val result = loop.run(listOf(
            ToolLoopMessage("system", "SYSTEM PROMPT"),
            ToolLoopMessage("user", "Find the plan"),
        ))
        assertTrue(result.stepLimitReached)
        assertEquals(3, legs.requests.size)
        return legs.requests
    }

    private fun bodies(protocol: ToolWireProtocol, requests: List<ToolLoopLegRequest>) =
        requests.map { ToolWireProtocolAdapter.buildBody(protocol, "model", it) }

    @Test
    fun `openai chat keeps leading system and appends notice as user after tool results`() = runTest {
        val bodies = bodies(ToolWireProtocol.OpenAIChat, legRequests())
        val systems = bodies.map { body -> body.getValue("messages").jsonArray.filter { role(it) == "system" }.toString() }
        systems.forEach { assertEquals(systems.first(), it) }
        val messages = bodies.last().getValue("messages").jsonArray
        assertEquals("user", role(messages.last()))
        assertEquals(notice, messages.last().jsonObject["content"]!!.jsonPrimitive.content)
        assertEquals("tool", role(messages[messages.size - 2]))
        assertEquals(1, messages.count { role(it) == "system" })
    }

    @Test
    fun `responses instructions are byte identical and notice follows function outputs`() = runTest {
        val bodies = bodies(ToolWireProtocol.OpenAIResponses, legRequests())
        bodies.forEach { assertEquals(bodies.first()["instructions"].toString(), it["instructions"].toString()) }
        assertEquals("SYSTEM PROMPT", bodies.first()["instructions"]!!.jsonPrimitive.content)
        val input = bodies.last().getValue("input").jsonArray
        val last = input.last().jsonObject
        assertEquals("user", last["role"]!!.jsonPrimitive.content)
        assertEquals(notice, last["content"]!!.jsonArray.single().jsonObject["text"]!!.jsonPrimitive.content)
        assertEquals("function_call_output", input[input.size - 2].jsonObject["type"]!!.jsonPrimitive.content)
    }

    @Test
    fun `anthropic system is byte identical and notice shares the tool_result user turn`() = runTest {
        val bodies = bodies(ToolWireProtocol.AnthropicMessages, legRequests())
        bodies.forEach { assertEquals(bodies.first()["system"].toString(), it["system"].toString()) }
        assertEquals("SYSTEM PROMPT", bodies.first()["system"]!!.jsonPrimitive.content)
        val messages = bodies.last().getValue("messages").jsonArray
        assertNoAdjacentUserTurns(messages)
        val content = messages.last().jsonObject["content"]!!.jsonArray.map { it.jsonObject }
        assertEquals("user", role(messages.last()))
        assertEquals(listOf("tool_result", "tool_result", "text"), content.map { it["type"]!!.jsonPrimitive.content })
        assertEquals(notice, content.last()["text"]!!.jsonPrimitive.content)
    }

    @Test
    fun `gemini systemInstruction is byte identical and notice shares the functionResponse user turn`() = runTest {
        val bodies = bodies(ToolWireProtocol.GeminiGenerate, legRequests())
        bodies.forEach {
            assertEquals(bodies.first()["systemInstruction"].toString(), it["systemInstruction"].toString())
        }
        val contents = bodies.last().getValue("contents").jsonArray
        assertNoAdjacentUserTurns(contents)
        val parts = contents.last().jsonObject["parts"]!!.jsonArray.map { it.jsonObject }
        assertEquals("user", role(contents.last()))
        assertTrue(parts.dropLast(1).all { it.containsKey("functionResponse") })
        assertEquals(2, parts.size - 1)
        assertEquals(notice, parts.last()["text"]!!.jsonPrimitive.content)
        assertFalse(bodies.last().toString().contains("\"role\":\"system\""))
    }

    private fun role(element: JsonElement): String? = (element as? JsonObject)?.get("role")?.jsonPrimitive?.content

    private fun assertNoAdjacentUserTurns(turns: JsonArray) {
        turns.zipWithNext().forEach { (a, b) ->
            assertFalse("Two adjacent user turns must not appear: $turns", role(a) == "user" && role(b) == "user")
        }
    }
}
