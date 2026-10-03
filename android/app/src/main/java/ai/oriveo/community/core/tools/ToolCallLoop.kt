package ai.oriveo.community.core.tools

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.flow.collect
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

// Protocol adapter: turns the loop's neutral shapes (assistant proposal / tool result) into this protocol's wire shape.
// The loop only knows the neutral `ToolLoopMessage`; wire shapes appear only in adapters, and leg executors build request bodies from them.
// openai_chat is the default implementation; anthropic / responses / gemini can be added behind the same interface.
interface ToolProtocolAdapter {
    /** Protocol name (same vocabulary as the server's `adapterProtocols` set). */
    val transport: String

    /** Message feeding a tool result back to the model (neutral shape). */
    fun encodeToolResult(callId: String, toolName: String, content: String): ToolLoopMessage

    /**
     * Message echoing the model's proposal (placed right before the tool results; must match the upstream tool_calls one to one).
     * [providerContinuation] is the opaque continuation state the decoder captured from this leg's stream.
     */
    fun encodeAssistantToolCalls(
        text: String,
        reasoning: String?,
        toolCalls: List<ToolLoopToolCall>,
        providerContinuation: JsonObject?,
    ): ToolLoopMessage
}

/** openai_chat protocol adapter. Tool results carry no `name` by default; the Moonshot path includes it because its request body expects it. */
class OpenAIChatToolAdapter(
    override val transport: String = "openai_chat",
    private val includesToolNameInResult: Boolean = false,
) : ToolProtocolAdapter {
    override fun encodeToolResult(callId: String, toolName: String, content: String): ToolLoopMessage =
        ToolLoopMessage(
            role = "tool",
            content = kotlinx.serialization.json.JsonPrimitive(content),
            toolCallId = callId,
            name = if (includesToolNameInResult) toolName else null,
        )

    override fun encodeAssistantToolCalls(
        text: String,
        reasoning: String?,
        toolCalls: List<ToolLoopToolCall>,
        providerContinuation: JsonObject?,
    ): ToolLoopMessage = ToolLoopMessage(
        role = "assistant",
        content = kotlinx.serialization.json.JsonPrimitive(text),
        reasoningContent = reasoning,
        toolCalls = toolCalls,
        providerContinuation = providerContinuation,
    )
}

/**
 * Generic tool loop: receive tool_calls → look up the registry → execute → feed back through the adapter → next leg → maxSteps.
 *
 * Moonshot web search and remote MCP tools share this one loop; every feature difference lives in the registry entries
 * (execution and failure handling) and in how the caller consumes progress events. The loop knows no specific tool.
 */
class ToolCallLoop(
    val registry: ToolRegistry,
    private val legRunner: ToolLoopLegRunning,
    private val adapter: ToolProtocolAdapter = OpenAIChatToolAdapter(),
    val limits: Limits,
    private val prompts: Prompts = Prompts(),
    private val includesReasoningInAssistantMessage: Boolean = false,
    private val onUnhandledToolCalls: suspend (List<ToolLoopToolCall>) -> Unit = {},
    private val onLegCompleted: (suspend (LegRecord) -> Unit)? = null,
    /**
     * Prefix for the ids the loop makes up when upstream gave no call id. Callers may pass their own; Moonshot uses the default.
     * The prefix only changes the literal of locally generated ids, which must match the echoed assistant proposal one to one; it does not affect cross-leg uniqueness.
     */
    private val fallbackCallIdPrefix: String = FallbackCallIdPrefix,
) {
    /** The shared contract hard-caps steps at 8: effective value = min(configured value, 8), default 6. */
    class Limits(
        maxSteps: Int,
        /** How many times the model may correct wrong arguments (`ToolCallRejection`); beyond that the whole run throws. */
        val maxSelfCorrections: Int = 3,
        /** Consecutive tool **execution** failures at which the problem is no longer a blip and the whole run throws. */
        val maxConsecutiveToolFailures: Int = 3,
        /** Cumulative token budget for this run; once reached, tool calling stops and the synthesis leg runs. null means unlimited. */
        val tokenBudget: Int? = null,
    ) {
        /**
         * Bounds both the number of legs and the number of tool steps. Steps count **individual calls**: a leg issuing 3 parallel calls uses 3 steps.
         *
         * Negative values are clamped to 0 (same as iOS) instead of throwing: the value can come from remote
         * configuration, and a broken config should degrade to "no tools, answer directly" rather than crash the whole message.
         */
        val maxSteps: Int = maxSteps.coerceAtLeast(0)

        override fun toString(): String =
            "Limits(maxSteps=$maxSteps, maxSelfCorrections=$maxSelfCorrections, " +
                "maxConsecutiveToolFailures=$maxConsecutiveToolFailures, tokenBudget=$tokenBudget)"

        companion object {
            const val HardCap = 8
            const val DefaultMaxSteps = 6

            fun effectiveMaxSteps(serverValue: Int?): Int {
                if (serverValue == null || serverValue <= 0) return DefaultMaxSteps
                return minOf(serverValue, HardCap)
            }
        }
    }

    /**
     * The fixed sentences fed back to the model, and the "stopped" error code.
     *
     * The defaults are **neutrally worded**: the loop knows no specific tool, so the default copy must not mention
     * citations / `[n]` or anything else that belongs to a single feature (web search has no `[n]` citations; borrowing that wording
     * would only make the model invent citation numbers). Features with their own wording and error code pass them in explicitly.
     */
    data class Prompts(
        /** System instruction appended after hitting the cap (steps or legs). */
        val stepLimitReached: String = "The tool call limit was reached. Answer now using the tool results you already have. Do not call another tool.",
        /** System instruction appended after the token budget runs out. */
        val tokenBudgetReached: String = "The token budget for tool calls was reached. Answer now using the tool results you already have and do not call another tool. If they are not enough to answer, say so clearly.",
        /** Explanation fed back to the skipped calls when the cap is hit. */
        val stoppedByStepLimit: String = "The tool call limit was reached.",
        /** Explanation fed back to the skipped calls when the budget runs out. */
        val stoppedByTokenBudget: String = "The token budget for tool calls was reached.",
        /** `ok:false` error code for skipped calls. */
        val stoppedCode: String = DefaultStoppedCode,
    )

    sealed interface ProgressEvent {
        /** A new leg starts (index from 0). Consumers reset per-leg state such as "this leg's text" here. */
        data class LegStarted(val legIndex: Int) : ProgressEvent

        /** Text delta (within the current leg). */
        data class TextDelta(val text: String) : ProgressEvent

        /** Reasoning delta. */
        data class ReasoningDelta(val text: String) : ProgressEvent

        /** Cumulative usage (merged across legs). */
        data class Usage(val usage: ToolLoopUsage) : ProgressEvent

        /** This leg's proposal is fully assembled and passed the allowlist (at least one call hit the registry). */
        data class ToolCallsAccepted(val toolCalls: List<ToolLoopToolCall>) : ProgressEvent
    }

    /** Record handed to the caller when a leg ends (Moonshot persists the continuation from it). */
    data class LegRecord(
        val legIndex: Int,
        val assistantMessage: ToolLoopMessage,
        val toolResultMessages: List<ToolLoopMessage>,
    )

    data class Result(
        /** Text of the last leg (the synthesis leg, or the leg where the model wrapped up on its own). */
        val text: String,
        /** Text of every leg, in leg order. Moonshot joins them into the full reply. */
        val legTexts: List<String>,
        val usage: ToolLoopUsage?,
        /** The first leg answered directly without a single tool call that **hit the registry**. */
        val endedWithoutToolCall: Boolean,
        /** The step cap was hit (the user-facing progress view shows a trailing hint row). */
        val stepLimitReached: Boolean,
        /** Whether structured tool_calls were ever seen (the basis for remembering that native tools work). */
        val receivedStructuredToolCalls: Boolean,
        val executedToolSteps: Int,
    )

    suspend fun run(
        initialMessages: List<ToolLoopMessage>,
        onProgress: suspend (ProgressEvent) -> Unit = {},
    ): Result {
        val tools = registry.definitions
        val history = initialMessages.toMutableList()
        var usage: ToolLoopUsage? = null
        val legTexts = mutableListOf<String>()
        var selfCorrections = 0
        var consecutiveToolFailures = 0
        var executedToolSteps = 0
        var receivedStructuredToolCalls = false
        var forceSynthesis = false
        var stepLimitReached = false

        for (legIndex in 0 until limits.maxSteps) {
            currentCoroutineContext().ensureActive()
            onProgress(ProgressEvent.LegStarted(legIndex))
            val leg = consumeLeg(
                request = ToolLoopLegRequest(history.toList(), tools, ToolLoopToolChoice.Auto),
                legIndex = legIndex,
                receivedStructuredToolCalls = receivedStructuredToolCalls,
                onProgress = onProgress,
            )
            legTexts += leg.text
            usage = ToolLoopUsage.merge(usage, leg.usage)
            usage?.let { onProgress(ProgressEvent.Usage(it)) }

            if (leg.toolCalls.isEmpty()) {
                return Result(
                    text = leg.text,
                    legTexts = legTexts.toList(),
                    usage = usage,
                    endedWithoutToolCall = legIndex == 0,
                    stepLimitReached = false,
                    receivedStructuredToolCalls = receivedStructuredToolCalls,
                    executedToolSteps = executedToolSteps,
                )
            }
            receivedStructuredToolCalls = true

            // Allowlist: proposals missing from the registry are neither executed nor looped on; they go straight to the "no executor" callback.
            val (typedCalls, accepted, unhandled) = partition(leg.toolCalls)
            if (unhandled.isNotEmpty()) onUnhandledToolCalls(unhandled)
            if (accepted.isEmpty()) {
                // The whole leg asks for tools this connection cannot run: we cannot give the model what it wants, and more legs would only spin.
                return Result(
                    text = leg.text,
                    legTexts = legTexts.toList(),
                    usage = usage,
                    endedWithoutToolCall = legIndex == 0,
                    stepLimitReached = false,
                    receivedStructuredToolCalls = true,
                    executedToolSteps = executedToolSteps,
                )
            }
            onProgress(ProgressEvent.ToolCallsAccepted(accepted))

            val assistantMessage = adapter.encodeAssistantToolCalls(
                text = leg.text,
                reasoning = if (includesReasoningInAssistantMessage) leg.reasoning else null,
                toolCalls = typedCalls,
                providerContinuation = leg.providerContinuation,
            )
            history += assistantMessage
            // Tool results are fed back in the upstream proposal order (unmatched entries in a mixed leg are not moved to the front); appended system statements come after all results.
            val resultsByCallId = LinkedHashMap<String, ToolLoopMessage>()
            val trailingSystemMessages = mutableListOf<ToolLoopMessage>()
            fun feed(message: ToolLoopMessage) {
                message.toolCallId?.let { resultsByCallId[it] = message }
            }
            fun appendSystem(content: String) {
                trailingSystemMessages += ToolLoopMessage("system", content)
            }
            suspend fun commitLeg() {
                val ordered = typedCalls.mapNotNull { resultsByCallId[it.id] }
                history += ordered
                history += trailingSystemMessages
                onLegCompleted?.invoke(LegRecord(legIndex, assistantMessage, ordered))
            }
            // The protocol requires a tool message for every tool_call: the unmatched ones in a mixed leg get an unknown_tool reply.
            for (call in unhandled) {
                feed(adapter.encodeToolResult(
                    callId = call.id,
                    toolName = call.function.name,
                    content = errorContent("unknown_tool", "Unsupported tool: ${call.function.name}"),
                ))
            }

            val tokenBudget = limits.tokenBudget
            if (tokenBudget != null && (usage?.resolvedTotalTokens ?: 0) >= tokenBudget) {
                for (call in accepted) {
                    feed(adapter.encodeToolResult(
                        callId = call.id,
                        toolName = call.function.name,
                        content = errorContent(prompts.stoppedCode, prompts.stoppedByTokenBudget),
                    ))
                }
                appendSystem(prompts.tokenBudgetReached)
                forceSynthesis = true
                commitLeg()
                break
            }

            toolCallsLoop@ for ((callIndex, call) in accepted.withIndex()) {
                val entry = registry.entry(call.function.name) ?: continue
                // Check for cancellation before each tool in a leg: once the user hits stop, the remaining write tools of that leg must not run anyway.
                currentCoroutineContext().ensureActive()
                val stepNumber = executedToolSteps + 1
                val context = ToolExecutionContext(callId = call.id, stepNumber = stepNumber, legIndex = legIndex)
                try {
                    val outcome = entry.execute(call, context)
                    executedToolSteps = stepNumber
                    consecutiveToolFailures = 0
                    feed(adapter.encodeToolResult(call.id, call.function.name, outcome.content))
                    val stopReason = outcome.stopReason
                    if (stopReason != null) {
                        appendSystem(stopReason)
                        for (skipped in accepted.drop(callIndex + 1)) {
                            feed(adapter.encodeToolResult(
                                callId = skipped.id,
                                toolName = skipped.function.name,
                                content = errorContent(prompts.stoppedCode, outcome.stoppedMessage ?: stopReason),
                            ))
                        }
                        forceSynthesis = true
                        break@toolCallsLoop
                    }
                } catch (rejection: ToolCallRejection) {
                    selfCorrections += 1
                    feed(adapter.encodeToolResult(
                        callId = call.id,
                        toolName = call.function.name,
                        content = errorContent(rejection.code, rejection.message),
                    ))
                    if (selfCorrections > limits.maxSelfCorrections) throw rejection
                    continue
                } catch (thrown: Throwable) {
                    // Real cancellation (user stopped generation, outer timeout, a cancellation thrown by the tool itself) propagates untouched, with no disposition.
                    // Exactly one CancellationException is not a cancellation: the tool's internal `withTimeout` fired while this
                    // coroutine is still alive. That is a tool failure and goes through failureDisposition; otherwise the layer
                    // above would treat the timeout as "user cancelled" and swallow it silently, with no circuit break and no error card.
                    val toolTimedOut = thrown is TimeoutCancellationException && currentCoroutineContext().isActive
                    if (thrown is CancellationException && !toolTimedOut) throw thrown
                    val error = if (toolTimedOut) ToolExecutionTimeout(call.function.name, thrown) else thrown
                    when (val disposition = entry.failureDisposition(error)) {
                        is ToolFailureDisposition.Fatal -> throw error
                        is ToolFailureDisposition.Neutral -> {
                            // Uses a step and feeds back ok:false, but leaves the consecutive-failure count as is (neither incremented nor reset).
                            executedToolSteps = stepNumber
                            feed(adapter.encodeToolResult(
                                callId = call.id,
                                toolName = call.function.name,
                                content = errorContent(disposition.code, disposition.message),
                            ))
                        }
                        is ToolFailureDisposition.Degrade -> {
                            // A single tool failure only loses that call, not the whole run: the model carries on with other evidence. Throwing
                            // would turn the entire message into an error card, discarding all evidence gathered so far over one unreadable document.
                            executedToolSteps = stepNumber
                            consecutiveToolFailures += 1
                            feed(adapter.encodeToolResult(
                                callId = call.id,
                                toolName = call.function.name,
                                content = errorContent(disposition.code, disposition.message),
                            ))
                            if (consecutiveToolFailures >= limits.maxConsecutiveToolFailures) throw error
                        }
                    }
                }

                if (executedToolSteps >= limits.maxSteps) {
                    for (skipped in accepted.drop(callIndex + 1)) {
                        feed(adapter.encodeToolResult(
                            callId = skipped.id,
                            toolName = skipped.function.name,
                            content = errorContent(prompts.stoppedCode, prompts.stoppedByStepLimit),
                        ))
                    }
                    appendSystem(prompts.stepLimitReached)
                    forceSynthesis = true
                    stepLimitReached = true
                    break@toolCallsLoop
                }
            }
            commitLeg()
            if (forceSynthesis) break
        }

        if (!forceSynthesis) {
            // Legs exhausted: the same "limit reached" outcome as the step cap.
            history += ToolLoopMessage("system", prompts.stepLimitReached)
            stepLimitReached = true
        }
        val finalIndex = maxOf(0, limits.maxSteps)
        onProgress(ProgressEvent.LegStarted(finalIndex))
        val finalLeg = consumeLeg(
            request = ToolLoopLegRequest(history.toList(), tools, ToolLoopToolChoice.None),
            legIndex = finalIndex,
            receivedStructuredToolCalls = receivedStructuredToolCalls,
            onProgress = onProgress,
        )
        legTexts += finalLeg.text
        usage = ToolLoopUsage.merge(usage, finalLeg.usage)
        usage?.let { onProgress(ProgressEvent.Usage(it)) }
        // With toolChoice = none there should be no more proposals; if one arrives anyway there is nowhere to run it, so hand it over rather than swallow it.
        if (finalLeg.toolCalls.isNotEmpty()) onUnhandledToolCalls(finalLeg.toolCalls)
        return Result(
            text = finalLeg.text,
            legTexts = legTexts.toList(),
            usage = usage,
            endedWithoutToolCall = false,
            stepLimitReached = stepLimitReached,
            receivedStructuredToolCalls = receivedStructuredToolCalls,
            executedToolSteps = executedToolSteps,
        )
    }

    data class ConsumedLeg(
        val text: String,
        val reasoning: String,
        val toolCalls: List<ToolLoopToolCall>,
        val usage: ToolLoopUsage?,
        val providerContinuation: JsonObject?,
    )

    /**
     * Splits by the registry; `typed` keeps the upstream order and only swaps the `type` of matched entries for the wire type
     * the entry declares (so the echo lines up item by item).
     */
    private fun partition(
        calls: List<ToolLoopToolCall>,
    ): Triple<List<ToolLoopToolCall>, List<ToolLoopToolCall>, List<ToolLoopToolCall>> {
        val typed = mutableListOf<ToolLoopToolCall>()
        val accepted = mutableListOf<ToolLoopToolCall>()
        val unhandled = mutableListOf<ToolLoopToolCall>()
        for (call in calls) {
            val entry = registry.entry(call.function.name)
            if (entry != null) {
                val typedCall = call.copy(type = entry.wireType)
                typed += typedCall
                accepted += typedCall
            } else {
                typed += call
                unhandled += call
            }
        }
        return Triple(typed, accepted, unhandled)
    }

    private suspend fun consumeLeg(
        request: ToolLoopLegRequest,
        legIndex: Int,
        receivedStructuredToolCalls: Boolean,
        onProgress: suspend (ProgressEvent) -> Unit,
    ): ConsumedLeg {
        var text = ""
        var reasoning = ""
        var usage: ToolLoopUsage? = null
        var providerContinuation: JsonObject? = null
        val accumulated = LinkedHashMap<Int, ToolLoopToolCallDelta>()
        try {
            legRunner.run(request).collect { event ->
                when (event) {
                    is ToolLoopLegEvent.TextDelta -> {
                        text += event.text
                        onProgress(ProgressEvent.TextDelta(event.text))
                    }
                    is ToolLoopLegEvent.ReasoningDelta -> {
                        // Reasoning stays out of leg.text: it is not the model's answer to the user, and must not count
                        // as evidence that "the first leg answered with zero tool calls".
                        reasoning += event.text
                        onProgress(ProgressEvent.ReasoningDelta(event.text))
                    }
                    is ToolLoopLegEvent.ToolCallDeltas -> mergeToolCallDeltas(accumulated, event.deltas)
                    is ToolLoopLegEvent.Usage -> usage = event.usage
                    is ToolLoopLegEvent.ProviderContinuation -> {
                        providerContinuation = buildJsonObject {
                            put("protocol", event.protocol)
                            put("state", event.state)
                        }
                    }
                }
            }
        } catch (error: Throwable) {
            if (error is ToolLoopLegRejection) error.annotate(legIndex, receivedStructuredToolCalls)
            throw error
        }
        return ConsumedLeg(
            text = text,
            reasoning = reasoning,
            toolCalls = finalizeToolCalls(accumulated, legIndex, fallbackCallIdPrefix),
            usage = usage,
            providerContinuation = providerContinuation,
        )
    }

    companion object {
        /** Prefix for the ids the loop makes up when upstream gave no call id. */
        const val FallbackCallIdPrefix = "tool_call_"

        /** Default error code for skipped calls (a neutral name; a feature can pass its own). */
        const val DefaultStoppedCode = "tool_loop_stopped"

        fun mergeToolCallDeltas(
            target: MutableMap<Int, ToolLoopToolCallDelta>,
            deltas: List<ToolLoopToolCallDelta>,
        ) {
            deltas.forEach { delta ->
                val previous = target[delta.index]
                target[delta.index] = ToolLoopToolCallDelta(
                    index = delta.index,
                    // A later chunk carrying an empty id must not overwrite the real id from the first chunk (the echo would fall back to a made-up id that upstream does not know).
                    id = delta.id?.takeIf { it.isNotBlank() } ?: previous?.id,
                    type = delta.type ?: previous?.type,
                    // In the protocol, name arrives whole in the first chunk and is **not** incremental: accumulating it like arguments
                    // would yield "readread" as soon as a relay repeats the name,
                    // the registry would not recognize the tool, and the user would get a pointless notice card. First assignment wins.
                    // An empty string does not count as assigned (same rule as the production parser `NativeToolCallAccumulator.merge`):
                    // some upstreams send `name: ""` in the first chunk and the full name in the second; trusting the empty string would never produce a name.
                    name = previous?.name?.takeIf { it.isNotBlank() } ?: delta.name?.takeIf { it.isNotBlank() },
                    arguments = (previous?.arguments ?: "") + (delta.arguments ?: ""),
                )
            }
        }

        fun finalizeToolCalls(
            target: Map<Int, ToolLoopToolCallDelta>,
            legIndex: Int,
            fallbackCallIdPrefix: String = FallbackCallIdPrefix,
        ): List<ToolLoopToolCall> =
            target.toSortedMap().values.mapIndexed { offset, call ->
                val providedId = call.id?.takeIf { it.isNotBlank() }
                ToolLoopToolCall(
                    id = providedId ?: "$fallbackCallIdPrefix${legIndex + 1}_${offset + 1}",
                    function = ToolLoopToolCallFunction(
                        name = call.name.orEmpty(),
                        arguments = call.arguments.orEmpty(),
                    ),
                )
            }

        /** `{ "ok": false, "error": { "code", "message" } }`. */
        fun errorContent(code: String, message: String): String = buildJsonObject {
            put("ok", false)
            put("error", buildJsonObject {
                put("code", code)
                put("message", message)
            })
        }.toString()
    }
}
