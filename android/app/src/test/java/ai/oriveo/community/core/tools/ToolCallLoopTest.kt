package ai.oriveo.community.core.tools

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.buildJsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ToolCallLoopTest {
    private class RecordingEntry(
        override val name: String,
        override val scope: ToolScope = ToolScope.Mcp,
        private val result: ToolExecutionOutcome = ToolExecutionOutcome("{\"ok\":true}"),
    ) : ToolRegistryEntry {
        override val definition = ToolLoopToolDefinition(
            function = ToolLoopToolFunction(name = name, description = "d", parameters = buildJsonObject {}),
        )

        val contexts = mutableListOf<ToolExecutionContext>()

        override suspend fun execute(call: ToolLoopToolCall, context: ToolExecutionContext): ToolExecutionOutcome {
            contexts += context
            return result
        }
    }

    private class ScriptedLegRunner(private val legs: List<List<ToolLoopLegEvent>>) : ToolLoopLegRunning {
        val requests = mutableListOf<ToolLoopLegRequest>()
        private var index = 0

        override fun run(request: ToolLoopLegRequest): Flow<ToolLoopLegEvent> = flow {
            requests += request
            legs.getOrElse(index++) { emptyList() }.forEach { emit(it) }
        }
    }

    private fun delta(index: Int, id: String? = null, name: String? = null, arguments: String? = null) =
        ToolLoopLegEvent.ToolCallDeltas(
            listOf(ToolLoopToolCallDelta(index = index, id = id, type = "function", name = name, arguments = arguments)),
        )

    @Test
    fun `loop executes a proposed tool call and answers on the next leg`() = runTest {
        val entry = RecordingEntry("search")
        val runner = ScriptedLegRunner(
            listOf(
                listOf(
                    delta(0, id = "c1", name = "search", arguments = "{\"query\":\"plan\""),
                    // Later fragments of the same index: name is given in full only in the first fragment, and sending it again must not concatenate it twice.
                    delta(0, name = "search", arguments = "}"),
                ),
                listOf(ToolLoopLegEvent.TextDelta("Answer [1].")),
            ),
        )
        val loop = ToolCallLoop(ToolRegistry(listOf(entry)), runner, limits = ToolCallLoop.Limits(maxSteps = 6))

        val result = loop.run(listOf(ToolLoopMessage("user", "Find the plan")))

        assertEquals("Answer [1].", result.text)
        // The first leg only sent a tool call and no text, so legTexts keeps an empty string as a placeholder.
        assertEquals(listOf("", "Answer [1]."), result.legTexts)
        assertEquals(listOf(1), entry.contexts.map { it.stepNumber })
        assertEquals(listOf(0), entry.contexts.map { it.legIndex })
        assertEquals("c1", entry.contexts.single().callId)
        assertEquals(1, result.executedToolSteps)
        assertTrue(result.receivedStructuredToolCalls)
        assertFalse(result.endedWithoutToolCall)

        val second = runner.requests[1]
        val assistant = second.messages.single { it.role == "assistant" }
        assertEquals("search", assistant.toolCalls?.single()?.function?.name)
        assertEquals("{\"query\":\"plan\"}", assistant.toolCalls?.single()?.function?.arguments)
        val tool = second.messages.single { it.role == "tool" }
        assertEquals("c1", tool.toolCallId)
        assertEquals("{\"ok\":true}", tool.textContent)
        assertEquals(listOf("search"), second.tools.map { it.function.name })
        assertEquals(ToolLoopToolChoice.Auto, second.toolChoice)
    }

    @Test
    fun `unhandled tool calls are not executed and are fed back as unknown_tool`() = runTest {
        val known = RecordingEntry("search")
        val runner = ScriptedLegRunner(
            listOf(
                listOf(
                    ToolLoopLegEvent.ToolCallDeltas(
                        listOf(
                            ToolLoopToolCallDelta(0, id = "u1", name = "mystery_tool", arguments = "{}"),
                            ToolLoopToolCallDelta(1, id = "k1", name = "search", arguments = "{}"),
                        ),
                    ),
                ),
                listOf(ToolLoopLegEvent.TextDelta("done")),
            ),
        )
        val unhandled = mutableListOf<List<ToolLoopToolCall>>()
        val loop = ToolCallLoop(
            registry = ToolRegistry(listOf(known)),
            legRunner = runner,
            limits = ToolCallLoop.Limits(maxSteps = 6),
            onUnhandledToolCalls = { unhandled += it },
        )

        val result = loop.run(listOf(ToolLoopMessage("user", "hi")))

        assertEquals(listOf(listOf("mystery_tool")), unhandled.map { calls -> calls.map { it.function.name } })
        assertEquals(1, known.contexts.size)
        val second = runner.requests[1]
        val unknownResult = second.messages.single { it.role == "tool" && it.toolCallId == "u1" }
        assertTrue(unknownResult.textContent!!.contains("unknown_tool"))
        val knownResult = second.messages.single { it.role == "tool" && it.toolCallId == "k1" }
        assertEquals("{\"ok\":true}", knownResult.textContent)
        assertEquals("done", result.text)
    }

    @Test
    fun `step limit forces a final tool-less synthesis leg`() = runTest {
        val entry = RecordingEntry("search")
        val runner = ScriptedLegRunner(
            listOf(
                listOf(delta(0, id = "c1", name = "search", arguments = "{}")),
                listOf(ToolLoopLegEvent.TextDelta("final synthesis")),
            ),
        )
        val progress = mutableListOf<ToolCallLoop.ProgressEvent>()
        val loop = ToolCallLoop(ToolRegistry(listOf(entry)), runner, limits = ToolCallLoop.Limits(maxSteps = 1))

        val result = loop.run(listOf(ToolLoopMessage("user", "hi")), onProgress = { progress += it })

        assertTrue(result.stepLimitReached)
        assertEquals("final synthesis", result.text)
        assertEquals(1, result.executedToolSteps)
        assertEquals(
            listOf(0, 1),
            progress.filterIsInstance<ToolCallLoop.ProgressEvent.LegStarted>().map { it.legIndex },
        )
        val finalRequest = runner.requests.last()
        assertEquals(ToolLoopToolChoice.None, finalRequest.toolChoice)
        assertEquals("system", finalRequest.messages.last().role)
        assertTrue(finalRequest.messages.last().textContent!!.contains("limit was reached"))
    }

    @Test
    fun `first leg without a tool call ends immediately`() = runTest {
        val runner = ScriptedLegRunner(listOf(listOf(ToolLoopLegEvent.TextDelta("direct answer"))))
        val loop = ToolCallLoop(ToolRegistry.Empty, runner, limits = ToolCallLoop.Limits(maxSteps = 6))

        val result = loop.run(listOf(ToolLoopMessage("user", "hi")))

        assertTrue(result.endedWithoutToolCall)
        assertFalse(result.receivedStructuredToolCalls)
        assertEquals(0, result.executedToolSteps)
        assertEquals("direct answer", result.text)
        assertEquals(1, runner.requests.size)
    }

    @Test
    fun `effective max steps follows the shared client tool loop contract`() {
        assertEquals(6, ToolCallLoop.Limits.effectiveMaxSteps(null))
        assertEquals(6, ToolCallLoop.Limits.effectiveMaxSteps(0))
        assertEquals(3, ToolCallLoop.Limits.effectiveMaxSteps(3))
        assertEquals(8, ToolCallLoop.Limits.effectiveMaxSteps(8))
        assertEquals(8, ToolCallLoop.Limits.effectiveMaxSteps(9))
    }
}
