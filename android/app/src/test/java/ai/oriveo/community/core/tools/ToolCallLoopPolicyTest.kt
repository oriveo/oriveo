package ai.oriveo.community.core.tools

import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * How the generic loop rules on outcomes: the neutral result tier, neutral default wording and error codes, tool timeout vs real cancellation,
 * the step floor, and tool_call fragment assembly. All of these follow directly from the constraint that the loop itself knows no specific tool.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ToolCallLoopPolicyTest {

    // ── Neutral result tier ────────────────────────────────────────

    /** A neutral result does not reset the count: failure, failure, neutral, failure → the breaker trips on the third **failure**. */
    @Test
    fun `neutral result does not reset the consecutive failure count`() = runTest {
        val boom = IOException("source down")
        val entry = ScriptedEntry(
            name = "read",
            disposition = { error ->
                if (error is NoSuchElementException) {
                    ToolFailureDisposition.Neutral("not_found", "gone")
                } else {
                    ToolFailureDisposition.Degrade("source_error", "failed")
                }
            },
            behavior = { attempt, _ -> if (attempt == 2) throw NoSuchElementException("gone") else throw boom },
        )
        val runner = ScriptedLegs((1..5).map { toolLeg(call(0, "c$it", "read")) })
        val loop = ToolCallLoop(ToolRegistry(listOf(entry)), runner, limits = ToolCallLoop.Limits(maxSteps = 8))

        val error = runCatching { loop.run(listOf(ToolLoopMessage("user", "hi"))) }.exceptionOrNull()

        assertSame("the third failure (4th call) throws the tool's own error", boom, error)
        assertEquals("after the neutral one, only one more call runs before the breaker trips", 4, entry.contexts.size)
        // A neutral result is still fed back as ok:false, so the model knows it did not get this one.
        val neutralFeedback = runner.requests[3].toolResult("c3").orEmpty()
        assertTrue(neutralFeedback.contains("\"ok\":false"))
        assertTrue(neutralFeedback.contains("not_found"))
    }

    /** A neutral result is not counted: 3 neutral results in a row do not trip the breaker and the run continues. */
    @Test
    fun `consecutive neutral results never trip the failure guard`() = runTest {
        val entry = ScriptedEntry(
            name = "read",
            disposition = { ToolFailureDisposition.Neutral("not_found", "gone") },
            behavior = { _, _ -> throw NoSuchElementException("gone") },
        )
        val runner = ScriptedLegs((1..3).map { toolLeg(call(0, "c$it", "read")) } + listOf(textLeg("nothing found")))
        val loop = ToolCallLoop(ToolRegistry(listOf(entry)), runner, limits = ToolCallLoop.Limits(maxSteps = 8))

        val result = loop.run(listOf(ToolLoopMessage("user", "hi")))

        assertEquals("nothing found", result.text)
        assertEquals(3, entry.contexts.size)
        assertEquals("a neutral result consumes a step too", 3, result.executedToolSteps)
    }

    /** Only success resets the count: failure, failure, success, failure, failure does not trip the breaker (control case, so that "does not reset" is not implemented as global behaviour). */
    @Test
    fun `a successful call still resets the consecutive failure count`() = runTest {
        val entry = ScriptedEntry(
            name = "read",
            disposition = { ToolFailureDisposition.Degrade("source_error", "failed") },
            behavior = { attempt, _ ->
                if (attempt == 2) ToolExecutionOutcome(ScriptedEntry.OK) else throw IOException("flaky")
            },
        )
        val runner = ScriptedLegs((1..5).map { toolLeg(call(0, "c$it", "read")) } + listOf(textLeg("done")))
        val loop = ToolCallLoop(ToolRegistry(listOf(entry)), runner, limits = ToolCallLoop.Limits(maxSteps = 8))

        val result = loop.run(listOf(ToolLoopMessage("user", "hi")))

        assertEquals("done", result.text)
        assertEquals(5, entry.contexts.size)
    }

    // ── Neutral default wording and error codes ────────────────────────────────────────

    /** Default wording must not carry any feature-specific phrasing: web search has no `[n]` citation scheme. */
    @Test
    fun `default prompts and stop code are feature neutral`() {
        val prompts = ToolCallLoop.Prompts()
        val all = listOf(
            prompts.stepLimitReached,
            prompts.tokenBudgetReached,
            prompts.stoppedByStepLimit,
            prompts.stoppedByTokenBudget,
            prompts.stoppedCode,
        )
        all.forEach { text ->
            assertFalse("must not mention citation numbers: $text", text.contains("[n]"))
            assertFalse("must not mention citations: $text", text.contains("cite", ignoreCase = true))
        }
        assertEquals("tool_loop_stopped", prompts.stoppedCode)
        assertEquals(ToolCallLoop.DefaultStoppedCode, prompts.stoppedCode)
    }

    /** On hitting the limit the loop feeds back exactly the sentences in Prompts: the neutral wording and neutral error codes by default. */
    @Test
    fun `step limit feeds the default neutral wording and stop code`() = runTest {
        val entry = ScriptedEntry("search")
        val runner = ScriptedLegs(
            listOf(toolLeg(call(0, "c1", "search"), call(1, "c2", "search")), textLeg("final")),
        )
        val loop = ToolCallLoop(ToolRegistry(listOf(entry)), runner, limits = ToolCallLoop.Limits(maxSteps = 1))

        loop.run(listOf(ToolLoopMessage("user", "hi")))

        val finalRequest = runner.requests.last()
        assertEquals(listOf(ToolCallLoop.Prompts().stepLimitReached), finalRequest.systemTexts())
        val skipped = finalRequest.toolResult("c2").orEmpty()
        assertTrue(skipped, skipped.contains("\"code\":\"tool_loop_stopped\""))
        assertTrue(skipped, skipped.contains(ToolCallLoop.Prompts().stoppedByStepLimit))
    }

    /** When the caller passes its own wording and error codes, the loop uses them verbatim. */
    @Test
    fun `caller supplied prompts and stop code are used verbatim`() = runTest {
        val prompts = ToolCallLoop.Prompts(
            stepLimitReached = "CUSTOM STEP SYSTEM",
            tokenBudgetReached = "CUSTOM BUDGET SYSTEM",
            stoppedByStepLimit = "custom step stopped",
            stoppedByTokenBudget = "custom budget stopped",
            stoppedCode = "custom_stopped",
        )
        val entry = ScriptedEntry("search")
        val budgetRunner = ScriptedLegs(
            listOf(
                listOf(
                    ToolLoopLegEvent.ToolCallDeltas(listOf(call(0, "c1", "search"))),
                    ToolLoopLegEvent.Usage(ToolLoopUsage(totalTokens = 500)),
                ),
                textLeg("final"),
            ),
        )
        ToolCallLoop(
            registry = ToolRegistry(listOf(entry)),
            legRunner = budgetRunner,
            limits = ToolCallLoop.Limits(maxSteps = 6, tokenBudget = 100),
            prompts = prompts,
        ).run(listOf(ToolLoopMessage("user", "hi")))

        val budgetFinal = budgetRunner.requests.last()
        assertEquals(listOf("CUSTOM BUDGET SYSTEM"), budgetFinal.systemTexts())
        assertEquals(
            ToolCallLoop.errorContent("custom_stopped", "custom budget stopped"),
            budgetFinal.toolResult("c1"),
        )

        val stepRunner = ScriptedLegs(
            listOf(toolLeg(call(0, "c1", "search"), call(1, "c2", "search")), textLeg("final")),
        )
        ToolCallLoop(
            registry = ToolRegistry(listOf(ScriptedEntry("search"))),
            legRunner = stepRunner,
            limits = ToolCallLoop.Limits(maxSteps = 1),
            prompts = prompts,
        ).run(listOf(ToolLoopMessage("user", "hi")))

        val stepFinal = stepRunner.requests.last()
        assertEquals(listOf("CUSTOM STEP SYSTEM"), stepFinal.systemTexts())
        assertEquals(ToolCallLoop.errorContent("custom_stopped", "custom step stopped"), stepFinal.toolResult("c2"))
    }

    /** When an entry asks to stop: system uses stopReason, skipped calls use stoppedMessage (which defaults to stopReason). */
    @Test
    fun `stop reason and stopped message are fed separately`() = runTest {
        suspend fun runWith(outcome: ToolExecutionOutcome): ToolLoopLegRequest {
            val runner = ScriptedLegs(
                listOf(toolLeg(call(0, "c1", "search"), call(1, "c2", "search")), textLeg("final")),
            )
            val entry = ScriptedEntry("search", behavior = { _, _ -> outcome })
            ToolCallLoop(ToolRegistry(listOf(entry)), runner, limits = ToolCallLoop.Limits(maxSteps = 6))
                .run(listOf(ToolLoopMessage("user", "hi")))
            assertEquals("after the stop request, the remaining calls in the same leg are not executed", 1, entry.contexts.size)
            return runner.requests.last()
        }

        val separate = runWith(
            ToolExecutionOutcome(ScriptedEntry.OK, stopReason = "SYSTEM: stop now", stoppedMessage = "limit hit"),
        )
        assertEquals(listOf("SYSTEM: stop now"), separate.systemTexts())
        assertEquals(ToolCallLoop.errorContent("tool_loop_stopped", "limit hit"), separate.toolResult("c2"))
        assertEquals(ToolLoopToolChoice.None, separate.toolChoice)

        val shared = runWith(ToolExecutionOutcome(ScriptedEntry.OK, stopReason = "SYSTEM: stop now"))
        assertEquals(ToolCallLoop.errorContent("tool_loop_stopped", "SYSTEM: stop now"), shared.toolResult("c2"))
    }

    // ── Tool timeout vs real cancellation ────────────────────────────────────────

    /** A tool's internal withTimeout expiring is not cancellation: it degrades per failureDisposition and the run continues. */
    @Test
    fun `tool timeout is a tool failure and follows the failure disposition`() = runTest {
        val entry = ScriptedEntry(
            name = "search",
            disposition = { ToolFailureDisposition.Degrade("timeout", "timed out") },
            behavior = { attempt, _ ->
                if (attempt == 0) withTimeout(10) { delay(1_000) }
                ToolExecutionOutcome(ScriptedEntry.OK)
            },
        )
        val runner = ScriptedLegs(
            listOf(toolLeg(call(0, "c1", "search")), toolLeg(call(0, "c2", "search")), textLeg("done")),
        )
        val loop = ToolCallLoop(ToolRegistry(listOf(entry)), runner, limits = ToolCallLoop.Limits(maxSteps = 6))

        val result = loop.run(listOf(ToolLoopMessage("user", "hi")))

        assertEquals("done", result.text)
        assertEquals(2, entry.contexts.size)
        assertEquals(ToolCallLoop.errorContent("timeout", "timed out"), runner.requests[1].toolResult("c1"))
        // What the entry rules on is the timeout converted to another type; the original cancellation exception stays in cause.
        val judged = entry.dispositionInputs.single()
        assertTrue(judged is ToolExecutionTimeout)
        assertFalse("what is ruled on must no longer be a CancellationException", judged is CancellationException)
        assertTrue(judged.cause is TimeoutCancellationException)
        assertEquals("search", (judged as ToolExecutionTimeout).toolName)
    }

    /** When a timeout is ruled fatal, what is thrown must not be a CancellationException either, or the layer above would silently swallow it as a user cancellation. */
    @Test
    fun `fatal tool timeout surfaces as a real error not a cancellation`() = runTest {
        val entry = ScriptedEntry(name = "search", behavior = { _, _ -> withTimeout(10) { delay(1_000) }; error("unreachable") })
        val runner = ScriptedLegs(listOf(toolLeg(call(0, "c1", "search")), textLeg("never")))
        val loop = ToolCallLoop(ToolRegistry(listOf(entry)), runner, limits = ToolCallLoop.Limits(maxSteps = 6))

        val error = runCatching { loop.run(listOf(ToolLoopMessage("user", "hi"))) }.exceptionOrNull()

        assertTrue("got $error", error is ToolExecutionTimeout)
        assertFalse(error is CancellationException)
        assertEquals(1, runner.requests.size)
    }

    /** Consecutive timeouts still trip the breaker (unreachable if timeouts were rethrown as cancellation). */
    @Test
    fun `repeated tool timeouts trip the consecutive failure guard`() = runTest {
        val entry = ScriptedEntry(
            name = "search",
            disposition = { ToolFailureDisposition.Degrade("timeout", "timed out") },
            behavior = { _, _ -> withTimeout(10) { delay(1_000) }; error("unreachable") },
        )
        val runner = ScriptedLegs((1..5).map { toolLeg(call(0, "c$it", "search")) })
        val loop = ToolCallLoop(ToolRegistry(listOf(entry)), runner, limits = ToolCallLoop.Limits(maxSteps = 8))

        val error = runCatching { loop.run(listOf(ToolLoopMessage("user", "hi"))) }.exceptionOrNull()

        assertTrue("got $error", error is ToolExecutionTimeout)
        assertEquals(3, entry.contexts.size)
    }

    /** An outer timeout cancels the whole loop: that is real cancellation, propagated as is and not handed to the entry to rule on. */
    @Test
    fun `outer timeout cancelling the loop propagates as cancellation`() = runTest {
        val entry = ScriptedEntry(
            name = "search",
            disposition = { ToolFailureDisposition.Degrade("timeout", "timed out") },
            behavior = { _, _ -> delay(10_000); ToolExecutionOutcome(ScriptedEntry.OK) },
        )
        val runner = ScriptedLegs(listOf(toolLeg(call(0, "c1", "search")), textLeg("never")))
        val loop = ToolCallLoop(ToolRegistry(listOf(entry)), runner, limits = ToolCallLoop.Limits(maxSteps = 6))

        try {
            withTimeout(50) { loop.run(listOf(ToolLoopMessage("user", "hi"))) }
            fail("the outer timeout must bring the loop out")
        } catch (error: TimeoutCancellationException) {
            assertTrue("real cancellation does not go through failureDisposition", entry.dispositionInputs.isEmpty())
            assertEquals("no further leg is sent after cancellation", 1, runner.requests.size)
        }
    }

    // ── Step floor ────────────────────────────────────────

    /** Negative values are clamped to 0 (same as iOS): no tools are called and the synthesis leg runs directly, instead of crashing the whole message. */
    @Test
    fun `negative max steps is clamped to zero instead of crashing`() = runTest {
        val limits = ToolCallLoop.Limits(maxSteps = -3)
        assertEquals(0, limits.maxSteps)
        assertEquals(0, ToolCallLoop.Limits(maxSteps = 0).maxSteps)
        assertEquals(4, ToolCallLoop.Limits(maxSteps = 4).maxSteps)

        val entry = ScriptedEntry("search")
        val runner = ScriptedLegs(listOf(textLeg("answer without tools")))
        val result = ToolCallLoop(ToolRegistry(listOf(entry)), runner, limits = limits)
            .run(listOf(ToolLoopMessage("user", "hi")))

        assertEquals("answer without tools", result.text)
        assertEquals(1, runner.requests.size)
        assertEquals(ToolLoopToolChoice.None, runner.requests.single().toolChoice)
        assertTrue(result.stepLimitReached)
        assertTrue(entry.contexts.isEmpty())
    }

    // ── tool_call fragment assembly ────────────────────────────────────────

    /** An empty name in the first fragment does not count as assigned: a later fragment giving the full name must still assemble (same as the production parser). */
    @Test
    fun `blank first name fragment does not pin the tool name`() {
        val target = linkedMapOf<Int, ToolLoopToolCallDelta>()
        ToolCallLoop.mergeToolCallDeltas(target, listOf(ToolLoopToolCallDelta(0, id = "c1", name = "", arguments = "")))
        ToolCallLoop.mergeToolCallDeltas(target, listOf(ToolLoopToolCallDelta(0, name = "read", arguments = "{\"a\"")))
        // name is a full value, not a delta: sending it again must not concatenate it twice.
        ToolCallLoop.mergeToolCallDeltas(target, listOf(ToolLoopToolCallDelta(0, name = "read", arguments = ":1}")))

        val calls = ToolCallLoop.finalizeToolCalls(target, legIndex = 0)

        assertEquals("read", calls.single().function.name)
        assertEquals("{\"a\":1}", calls.single().function.arguments)
        assertEquals("c1", calls.single().id)
    }

    /** A later fragment carrying an empty id must not overwrite the real id from the first fragment. */
    @Test
    fun `blank id on a later fragment keeps the first real id`() {
        val target = linkedMapOf<Int, ToolLoopToolCallDelta>()
        ToolCallLoop.mergeToolCallDeltas(target, listOf(ToolLoopToolCallDelta(0, id = "call_abc", name = "search")))
        ToolCallLoop.mergeToolCallDeltas(target, listOf(ToolLoopToolCallDelta(0, id = "", arguments = "{}")))

        assertEquals("call_abc", ToolCallLoop.finalizeToolCalls(target, legIndex = 0).single().id)
    }

    /** Verified through the loop itself: a call whose first fragment has an empty name hits the registry and is executed, instead of becoming a "no executor" notice card. */
    @Test
    fun `call whose name arrives on the second fragment is executed`() = runTest {
        val entry = ScriptedEntry("read")
        val unhandled = mutableListOf<ToolLoopToolCall>()
        val runner = ScriptedLegs(
            listOf(
                listOf(
                    ToolLoopLegEvent.ToolCallDeltas(listOf(ToolLoopToolCallDelta(0, id = "c1", name = "", arguments = ""))),
                    ToolLoopLegEvent.ToolCallDeltas(listOf(ToolLoopToolCallDelta(0, name = "read", arguments = "{}"))),
                ),
                textLeg("done"),
            ),
        )
        val loop = ToolCallLoop(
            registry = ToolRegistry(listOf(entry)),
            legRunner = runner,
            limits = ToolCallLoop.Limits(maxSteps = 6),
            onUnhandledToolCalls = { unhandled += it },
        )

        val result = loop.run(listOf(ToolLoopMessage("user", "hi")))

        assertEquals("done", result.text)
        assertEquals(1, entry.contexts.size)
        assertTrue(unhandled.isEmpty())
    }
}
