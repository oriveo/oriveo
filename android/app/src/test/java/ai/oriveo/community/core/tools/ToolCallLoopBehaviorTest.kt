package ai.oriveo.community.core.tools

import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Loop-level behaviour of the generic loop: exhausted self-correction, degrade / fatal, the consecutive-failure breaker, cancellation propagation, the token budget,
 * early return when a whole leg is unhandled, the leg-record callback, running out of legs, a final leg that still carries tool_calls, and how steps are counted.
 *
 * The Moonshot and MCP tests each cover only the paths they use; the loop is shared by both,
 * so this file pins the loop's own contract case by case without borrowing the semantics of any specific feature.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ToolCallLoopBehaviorTest {

    private fun loop(
        runner: ToolLoopLegRunning,
        vararg entries: ToolRegistryEntry,
        limits: ToolCallLoop.Limits = ToolCallLoop.Limits(maxSteps = 6),
        onUnhandled: suspend (List<ToolLoopToolCall>) -> Unit = {},
        onLegCompleted: (suspend (ToolCallLoop.LegRecord) -> Unit)? = null,
    ) = ToolCallLoop(
        registry = ToolRegistry(entries.toList()),
        legRunner = runner,
        limits = limits,
        onUnhandledToolCalls = onUnhandled,
        onLegCompleted = onLegCompleted,
    )

    private val user = listOf(ToolLoopMessage("user", "hi"))

    // ── Self-correction ────────────────────────────────────────

    /** The model got the arguments wrong: ok:false is fed back so it can fix them, without consuming a step; once the attempts run out, the last rejection is thrown as is. */
    @Test
    fun `rejections are fed back for self correction and thrown once exhausted`() = runTest {
        val entry = ScriptedEntry(
            name = "search",
            behavior = { attempt, _ -> throw ToolCallRejection("invalid_arguments", "bad arguments #$attempt") },
        )
        val runner = ScriptedLegs((1..6).map { toolLeg(call(0, "c$it", "search")) })
        val loop = loop(runner, entry, limits = ToolCallLoop.Limits(maxSteps = 8, maxSelfCorrections = 2))

        val error = runCatching { loop.run(user) }.exceptionOrNull()

        assertTrue("got $error", error is ToolCallRejection)
        assertEquals("invalid_arguments", (error as ToolCallRejection).code)
        assertEquals("2 self-corrections are allowed, the 3rd rejection is thrown", "bad arguments #2", error.message)
        assertEquals(3, entry.contexts.size)
        assertEquals(3, runner.requests.size)
        // The first two rejections were both fed back to the model.
        assertEquals(
            ToolCallLoop.errorContent("invalid_arguments", "bad arguments #0"),
            runner.requests[1].toolResult("c1"),
        )
        assertTrue("rejections are not handed to failureDisposition", entry.dispositionInputs.isEmpty())
    }

    /** After a successful self-correction the loop carries on as usual; the rejected attempt is not a step and does not affect the consecutive-failure count. */
    @Test
    fun `a corrected call executes and rejected attempts consume no step`() = runTest {
        val entry = ScriptedEntry(
            name = "search",
            behavior = { attempt, _ ->
                if (attempt == 0) throw ToolCallRejection("invalid_arguments", "bad") else ToolExecutionOutcome(ScriptedEntry.OK)
            },
        )
        val runner = ScriptedLegs(
            listOf(toolLeg(call(0, "c1", "search")), toolLeg(call(0, "c2", "search")), textLeg("answer")),
        )

        val result = loop(runner, entry).run(user)

        assertEquals("answer", result.text)
        assertEquals("only the successfully executed attempt counts as a step", 1, result.executedToolSteps)
        assertEquals("both attempts got the same step number: the rejected one did not take it", listOf(1, 1), entry.contexts.map { it.stepNumber })
    }

    // ── Failure rulings ────────────────────────────────────────

    /** Degrade: this call is fed back as ok:false, the loop continues and the next call runs as usual. */
    @Test
    fun `degraded failure is fed back and the loop keeps going`() = runTest {
        val entry = ScriptedEntry(
            name = "read",
            disposition = { ToolFailureDisposition.Degrade("source_error", "failed") },
            behavior = { attempt, _ -> if (attempt == 0) throw IOException("boom") else ToolExecutionOutcome(ScriptedEntry.OK) },
        )
        val runner = ScriptedLegs(
            listOf(toolLeg(call(0, "c1", "read")), toolLeg(call(0, "c2", "read")), textLeg("answer")),
        )

        val result = loop(runner, entry).run(user)

        assertEquals("answer", result.text)
        assertEquals(ToolCallLoop.errorContent("source_error", "failed"), runner.requests[1].toolResult("c1"))
        assertEquals(ScriptedEntry.OK, runner.requests[2].toolResult("c2"))
        assertEquals("the failed call consumes a step too", 2, result.executedToolSteps)
    }

    /** Fatal: the original error is thrown for the whole run at once, with no feedback and no next leg. Fatal is the default when an entry declares no ruling. */
    @Test
    fun `fatal failure aborts the run with the original error`() = runTest {
        val boom = IllegalStateException("account level failure")
        val entry = ScriptedEntry(name = "read", behavior = { _, _ -> throw boom })
        val runner = ScriptedLegs(listOf(toolLeg(call(0, "c1", "read"), call(1, "c2", "read")), textLeg("never")))

        val error = runCatching { loop(runner, entry).run(user) }.exceptionOrNull()

        assertSame(boom, error)
        assertEquals("later calls in the same leg are not executed", 1, entry.contexts.size)
        assertEquals(1, runner.requests.size)
    }

    /** Consecutive failures reaching the threshold abort the whole run; the threshold comes from Limits, not a hard-coded 3. */
    @Test
    fun `consecutive failures trip the guard at the configured threshold`() = runTest {
        val errors = (0 until 5).map { IOException("failure #$it") }
        val entry = ScriptedEntry(
            name = "read",
            disposition = { ToolFailureDisposition.Degrade("source_error", "failed") },
            behavior = { attempt, _ -> throw errors[attempt] },
        )
        val runner = ScriptedLegs((1..5).map { toolLeg(call(0, "c$it", "read")) })
        val loop = loop(runner, entry, limits = ToolCallLoop.Limits(maxSteps = 8, maxConsecutiveToolFailures = 2))

        val error = runCatching { loop.run(user) }.exceptionOrNull()

        assertSame("what is thrown is the error that tripped the breaker", errors[1], error)
        assertEquals(2, entry.contexts.size)
    }

    /** Parallel calls failing consecutively within one leg count too: the breaker need not wait for the next leg. */
    @Test
    fun `failures within one leg count toward the guard`() = runTest {
        val entry = ScriptedEntry(
            name = "read",
            disposition = { ToolFailureDisposition.Degrade("source_error", "failed") },
            behavior = { _, _ -> throw IOException("down") },
        )
        val runner = ScriptedLegs(
            listOf(toolLeg(call(0, "c1", "read"), call(1, "c2", "read"), call(2, "c3", "read"), call(3, "c4", "read"))),
        )

        val error = runCatching { loop(runner, entry).run(user) }.exceptionOrNull()

        assertTrue(error is IOException)
        assertEquals(3, entry.contexts.size)
    }

    // ── Cancellation ────────────────────────────────────────

    /** Cancelled while a tool is running: propagated as is, with no ruling, no feedback and no further leg. */
    @Test
    fun `cancellation during tool execution propagates untouched`() = runTest {
        val started = CompletableDeferred<Unit>()
        val entry = ScriptedEntry(
            name = "search",
            disposition = { ToolFailureDisposition.Degrade("x", "must not be consulted") },
            behavior = { _, _ ->
                started.complete(Unit)
                awaitCancellation()
            },
        )
        val runner = ScriptedLegs(listOf(toolLeg(call(0, "c1", "search")), textLeg("never")))
        val job = launch { loop(runner, entry).run(user) }

        started.await()
        job.cancelAndJoin()

        assertTrue(job.isCancelled)
        assertTrue("cancellation is not a tool failure", entry.dispositionInputs.isEmpty())
        assertEquals(1, runner.requests.size)
    }

    /** A cancellation thrown by the tool itself (e.g. the user tapped cancel in a confirmation dialog) is likewise thrown as is, with its type unchanged. */
    @Test
    fun `cancellation thrown by a tool keeps its type`() = runTest {
        class UserCancelled : CancellationException("user cancelled")
        val entry = ScriptedEntry(
            name = "read",
            disposition = { ToolFailureDisposition.Degrade("x", "must not be consulted") },
            behavior = { _, _ -> throw UserCancelled() },
        )
        val runner = ScriptedLegs(listOf(toolLeg(call(0, "c1", "read")), textLeg("never")))

        val outcome = async { runCatching { loop(runner, entry).run(user) } }.await()

        assertTrue("got ${outcome.exceptionOrNull()}", outcome.exceptionOrNull() is UserCancelled)
        assertTrue(entry.dispositionInputs.isEmpty())
        assertEquals(1, runner.requests.size)
    }

    /** Liveness is checked at the start of every leg: once the coroutine is cancelled between two legs, no new leg is sent to the model. */
    @Test
    fun `a coroutine cancelled between legs starts no further leg`() = runTest {
        var legs = 0
        val runner = ToolLoopLegRunning {
            flow {
                legs += 1
                emit(ToolLoopLegEvent.ToolCallDeltas(listOf(call(0, "c$legs", "search"))))
                // Cancelled only after the leg was emitted in full: the leg itself ends normally, so the check at the start of the next leg has to catch the cancellation.
                currentCoroutineContext().cancel()
            }
        }
        val job = launch { loop(runner, ScriptedEntry("search")).run(user) }

        job.join()

        assertTrue(job.isCancelled)
        assertEquals("without this check the loop would spin idly all the way to the step limit", 1, legs)
    }

    // ── Token budget ────────────────────────────────────────

    /** Budget exhausted: none of this leg's proposals run, all are fed back as "stopped", then the tool-less synthesis leg runs. */
    @Test
    fun `token budget stops tool execution and forces a synthesis leg`() = runTest {
        val entry = ScriptedEntry("search")
        val runner = ScriptedLegs(
            listOf(
                listOf(
                    ToolLoopLegEvent.ToolCallDeltas(listOf(call(0, "c1", "search"), call(1, "c2", "search"))),
                    ToolLoopLegEvent.Usage(ToolLoopUsage(promptTokens = 60, completionTokens = 40)),
                ),
                listOf(
                    ToolLoopLegEvent.TextDelta("synthesis"),
                    ToolLoopLegEvent.Usage(ToolLoopUsage(promptTokens = 5, completionTokens = 2)),
                ),
            ),
        )
        val loop = loop(runner, entry, limits = ToolCallLoop.Limits(maxSteps = 6, tokenBudget = 100))

        val result = loop.run(user)

        assertEquals("synthesis", result.text)
        assertTrue("no tools run once the budget is reached", entry.contexts.isEmpty())
        assertEquals(0, result.executedToolSteps)
        assertFalse("an exhausted budget is not the same as hitting the step limit", result.stepLimitReached)
        val finalRequest = runner.requests.last()
        assertEquals(ToolLoopToolChoice.None, finalRequest.toolChoice)
        assertEquals(listOf(ToolCallLoop.Prompts().tokenBudgetReached), finalRequest.systemTexts())
        listOf("c1", "c2").forEach { id ->
            assertEquals(
                "the protocol requires a tool message for every tool_call",
                ToolCallLoop.errorContent("tool_loop_stopped", ToolCallLoop.Prompts().stoppedByTokenBudget),
                finalRequest.toolResult(id),
            )
        }
        // usage accumulates across legs; when the upstream gives no total it is derived from prompt + completion.
        assertEquals(65, result.usage?.promptTokens)
        assertEquals(42, result.usage?.completionTokens)
        assertEquals(107, result.usage?.resolvedTotalTokens)
    }

    /** Below the budget, execution proceeds as usual; the budget is judged on cumulative usage and is only crossed after accumulating across legs. */
    @Test
    fun `token budget is judged on usage accumulated across legs`() = runTest {
        val entry = ScriptedEntry("search")
        val runner = ScriptedLegs(
            listOf(
                listOf(
                    ToolLoopLegEvent.ToolCallDeltas(listOf(call(0, "c1", "search"))),
                    ToolLoopLegEvent.Usage(ToolLoopUsage(totalTokens = 60)),
                ),
                listOf(
                    ToolLoopLegEvent.ToolCallDeltas(listOf(call(0, "c2", "search"))),
                    ToolLoopLegEvent.Usage(ToolLoopUsage(totalTokens = 60)),
                ),
                textLeg("synthesis"),
            ),
        )

        val result = loop(runner, entry, limits = ToolCallLoop.Limits(maxSteps = 6, tokenBudget = 100)).run(user)

        assertEquals("first leg 60 < 100 runs as usual; second leg cumulative 120 ≥ 100 stops", 1, entry.contexts.size)
        assertEquals("c1", entry.contexts.single().callId)
        assertEquals("synthesis", result.text)
    }

    // ── Unhandled proposals ────────────────────────────────────────

    /** A whole leg of tools missing from the registry: hand it to the callback and return at once, with no feedback and no further leg (another leg would only spin idly). */
    @Test
    fun `a leg of only unhandled calls returns early through the callback`() = runTest {
        val unhandled = mutableListOf<List<ToolLoopToolCall>>()
        val progress = mutableListOf<ToolCallLoop.ProgressEvent>()
        val runner = ScriptedLegs(
            listOf(
                listOf(
                    ToolLoopLegEvent.TextDelta("let me use a tool"),
                    ToolLoopLegEvent.ToolCallDeltas(
                        listOf(call(0, "u1", "mystery_tool", "{\"q\":1}"), call(1, "u2", "other_tool")),
                    ),
                ),
                textLeg("never"),
            ),
        )

        val result = loop(runner, ScriptedEntry("search"), onUnhandled = { unhandled += it })
            .run(user) { progress += it }

        assertEquals(1, runner.requests.size)
        assertEquals(listOf(listOf("mystery_tool", "other_tool")), unhandled.map { calls -> calls.map { it.function.name } })
        assertEquals("{\"q\":1}", unhandled.single().first().function.arguments)
        assertEquals("let me use a tool", result.text)
        assertTrue("structured tool_calls were seen (a capability fact)", result.receivedStructuredToolCalls)
        assertTrue("but none of them hit the registry", result.endedWithoutToolCall)
        assertEquals(0, result.executedToolSteps)
        assertTrue(
            "with no accepted proposal, ToolCallsAccepted must not be emitted",
            progress.none { it is ToolCallLoop.ProgressEvent.ToolCallsAccepted },
        )
    }

    /** A whole unhandled leg showing up in a later leg: returns early as well, but does not count as "answered on the first leg without retrieving". */
    @Test
    fun `unhandled only leg after a real tool leg is not flagged as first leg`() = runTest {
        val unhandled = mutableListOf<ToolLoopToolCall>()
        val runner = ScriptedLegs(
            listOf(toolLeg(call(0, "c1", "search")), toolLeg(call(0, "u1", "mystery_tool")), textLeg("never")),
        )

        val result = loop(runner, ScriptedEntry("search"), onUnhandled = { unhandled += it }).run(user)

        assertEquals(2, runner.requests.size)
        assertEquals(listOf("mystery_tool"), unhandled.map { it.function.name })
        assertFalse(result.endedWithoutToolCall)
        assertEquals(1, result.executedToolSteps)
    }

    // ── Leg-record callback ────────────────────────────────────────

    /** onLegCompleted fires once per leg that carries tools, with that leg's assistant proposals and the tool results in proposal order. */
    @Test
    fun `leg completed callback reports the assistant proposal and ordered tool results`() = runTest {
        val records = mutableListOf<ToolCallLoop.LegRecord>()
        val continuation = buildJsonObject { put("opaque", "state-1") }
        val runner = ScriptedLegs(
            listOf(
                listOf(
                    ToolLoopLegEvent.TextDelta("thinking aloud"),
                    ToolLoopLegEvent.ToolCallDeltas(
                        listOf(call(0, "u1", "mystery_tool"), call(1, "c1", "search", "{\"q\":\"a\"}")),
                    ),
                    ToolLoopLegEvent.ProviderContinuation("openai_chat", continuation),
                ),
                toolLeg(call(0, "c2", "search")),
                textLeg("answer"),
            ),
        )

        loop(runner, ScriptedEntry("search"), onLegCompleted = { records += it }).run(user)

        assertEquals("the final leg has no tools and does not fire", listOf(0, 1), records.map { it.legIndex })
        val first = records[0]
        assertEquals("assistant", first.assistantMessage.role)
        assertEquals("thinking aloud", first.assistantMessage.textContent)
        assertEquals(listOf("u1", "c1"), first.assistantMessage.toolCalls?.map { it.id })
        assertEquals(
            "the continuation state is carried out as is (protocol name + state body)",
            JsonObject(mapOf("protocol" to JsonPrimitive("openai_chat"), "state" to continuation)),
            first.assistantMessage.providerContinuation,
        )
        assertEquals("tool results follow proposal order; the unmatched one is not moved to the front", listOf("u1", "c1"), first.toolResultMessages.map { it.toolCallId })
        assertTrue(first.toolResultMessages[0].textContent.orEmpty().contains("unknown_tool"))
        assertEquals(ScriptedEntry.OK, first.toolResultMessages[1].textContent)
        assertNull(records[1].assistantMessage.providerContinuation)
        // What the callback receives is exactly the messages actually sent in the next leg.
        val sent = runner.requests[1].messages
        assertEquals(first.assistantMessage, sent[sent.size - 3])
        assertEquals(first.toolResultMessages, sent.takeLast(2))
    }

    /** An error thrown inside the callback is not swallowed (Moonshot uses it to persist the continuation, and a failed persist must fail the whole run). */
    @Test
    fun `an error thrown by the leg completed callback aborts the run`() = runTest {
        val boom = IllegalStateException("cannot persist continuation")
        val runner = ScriptedLegs(listOf(toolLeg(call(0, "c1", "search")), textLeg("never")))

        val error = runCatching {
            loop(runner, ScriptedEntry("search"), onLegCompleted = { throw boom }).run(user)
        }.exceptionOrNull()

        assertSame(boom, error)
        assertEquals(1, runner.requests.size)
    }

    // ── Limits ────────────────────────────────────────

    /** Steps are counted per call: 3 parallel calls in one leg consume 3 steps (same shape as iOS, not counted per leg). */
    @Test
    fun `three parallel calls in one leg consume three steps`() = runTest {
        val entry = ScriptedEntry("search")
        val runner = ScriptedLegs(
            listOf(
                toolLeg(call(0, "c1", "search"), call(1, "c2", "search"), call(2, "c3", "search"), call(3, "c4", "search")),
                textLeg("synthesis"),
            ),
        )

        val result = loop(runner, entry, limits = ToolCallLoop.Limits(maxSteps = 3)).run(user)

        assertEquals(listOf(1, 2, 3), entry.contexts.map { it.stepNumber })
        assertEquals(listOf(0, 0, 0), entry.contexts.map { it.legIndex })
        assertEquals(3, result.executedToolSteps)
        assertTrue("one leg used up all 3 steps", result.stepLimitReached)
        assertEquals("only a tool leg + the synthesis leg were sent, no second tool leg", 2, runner.requests.size)
        val finalRequest = runner.requests.last()
        assertEquals(ToolLoopToolChoice.None, finalRequest.toolChoice)
        assertTrue("the 4th call was skipped", finalRequest.toolResult("c4").orEmpty().contains("tool_loop_stopped"))
        assertEquals(ScriptedEntry.OK, finalRequest.toolResult("c3"))
    }

    /**
     * Running out of legs: when each leg spends less than a step (here, self-correction legs that are all rejected) the step count never reaches
     * the limit, so the leg count is the backstop; it likewise appends "limit reached" and runs the synthesis leg.
     */
    @Test
    fun `running out of legs appends the limit notice and synthesizes`() = runTest {
        val entry = ScriptedEntry(
            name = "search",
            behavior = { _, _ -> throw ToolCallRejection("invalid_arguments", "bad") },
        )
        val progress = mutableListOf<ToolCallLoop.ProgressEvent>()
        val runner = ScriptedLegs(
            listOf(toolLeg(call(0, "c1", "search")), toolLeg(call(0, "c2", "search")), textLeg("best effort")),
        )
        val loop = loop(runner, entry, limits = ToolCallLoop.Limits(maxSteps = 2, maxSelfCorrections = 5))

        val result = loop.run(user) { progress += it }

        assertEquals("best effort", result.text)
        assertTrue(result.stepLimitReached)
        assertEquals("rejections do not consume steps", 0, result.executedToolSteps)
        assertEquals(3, runner.requests.size)
        assertEquals(ToolLoopToolChoice.None, runner.requests.last().toolChoice)
        assertEquals(listOf(ToolCallLoop.Prompts().stepLimitReached), runner.requests.last().systemTexts())
        assertEquals(
            "the synthesis leg's index follows right after the last tool leg",
            listOf(0, 1, 2),
            progress.filterIsInstance<ToolCallLoop.ProgressEvent.LegStarted>().map { it.legIndex },
        )
        assertEquals(listOf("", "", "best effort"), result.legTexts)
    }

    /** The final leg with tool_choice=none still carried tool_calls: there is nowhere to run them, so they go to the callback instead of being swallowed; the text is returned as usual. */
    @Test
    fun `tool calls on the final synthesis leg are handed to the unhandled callback`() = runTest {
        val unhandled = mutableListOf<List<ToolLoopToolCall>>()
        val entry = ScriptedEntry("search")
        val runner = ScriptedLegs(
            listOf(
                toolLeg(call(0, "c1", "search")),
                listOf(
                    ToolLoopLegEvent.TextDelta("partial answer"),
                    // Note: this tool **is** in the registry; the final leg executes no tools, so it counts as unhandled too.
                    ToolLoopLegEvent.ToolCallDeltas(listOf(call(0, "late", "search", "{\"q\":\"again\"}"))),
                ),
            ),
        )

        val result = loop(runner, entry, limits = ToolCallLoop.Limits(maxSteps = 1), onUnhandled = { unhandled += it })
            .run(user)

        assertEquals("partial answer", result.text)
        assertEquals("the final leg's proposal was not executed", 1, entry.contexts.size)
        assertEquals(listOf(listOf("late")), unhandled.map { calls -> calls.map { it.id } })
        assertEquals("{\"q\":\"again\"}", unhandled.single().single().function.arguments)
        assertTrue(result.stepLimitReached)
    }

    /** Errors from the leg executor are thrown as is; ones implementing ToolLoopLegRejection are first tagged with the leg index and whether tool_calls were seen. */
    @Test
    fun `leg runner rejection is annotated with leg index and tool call history`() = runTest {
        class Rejected : Exception("tools rejected"), ToolLoopLegRejection {
            var legIndex = -1
            var sawToolCalls: Boolean? = null
            override fun annotate(legIndex: Int, receivedStructuredToolCalls: Boolean) {
                this.legIndex = legIndex
                sawToolCalls = receivedStructuredToolCalls
            }
        }
        val rejected = Rejected()
        val runner = object : ToolLoopLegRunning {
            var legs = 0
            override fun run(request: ToolLoopLegRequest): Flow<ToolLoopLegEvent> = flow {
                if (legs++ == 0) {
                    emit(ToolLoopLegEvent.ToolCallDeltas(listOf(call(0, "c1", "search"))))
                } else {
                    throw rejected
                }
            }
        }

        val error = runCatching { loop(runner, ScriptedEntry("search")).run(user) }.exceptionOrNull()

        assertSame(rejected, error)
        assertEquals(1, rejected.legIndex)
        assertEquals(true, rejected.sawToolCalls)
    }

    /** The upstream gave no call ID: the IDs the loop fills in are unique across legs, and the assistant proposal and the tool result use the same one. */
    @Test
    fun `fallback call ids are unique across legs and consistent within a leg`() = runTest {
        val entry = ScriptedEntry("search")
        val runner = ScriptedLegs(
            listOf(
                listOf(ToolLoopLegEvent.ToolCallDeltas(listOf(ToolLoopToolCallDelta(0, name = "search", arguments = "{}")))),
                listOf(ToolLoopLegEvent.ToolCallDeltas(listOf(ToolLoopToolCallDelta(0, id = " ", name = "search", arguments = "{}")))),
                textLeg("done"),
            ),
        )

        loop(runner, entry).run(user)

        assertEquals(listOf("tool_call_1_1", "tool_call_2_1"), entry.contexts.map { it.callId })
        val last = runner.requests.last().messages
        val proposed = last.filter { it.role == "assistant" }.flatMap { it.toolCalls.orEmpty() }.map { it.id }
        val answered = last.filter { it.role == "tool" }.mapNotNull { it.toolCallId }
        assertEquals(proposed, answered)
    }
}
