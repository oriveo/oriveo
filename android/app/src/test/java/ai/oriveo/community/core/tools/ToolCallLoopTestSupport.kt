package ai.oriveo.community.core.tools

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.serialization.json.buildJsonObject

// Shared fixtures for the generic loop tests: an executor that emits leg events from a script, and registry entries with scriptable behaviour.
// The loop itself knows no specific tool, so the entries here only describe "this call succeeds / is rejected / throws" and carry no business meaning.

/** Emits one group of events per leg from the script; once the script runs out it returns empty legs (= the model said nothing more). */
internal class ScriptedLegs(private val legs: List<List<ToolLoopLegEvent>>) : ToolLoopLegRunning {
    val requests = mutableListOf<ToolLoopLegRequest>()
    private var index = 0

    override fun run(request: ToolLoopLegRequest): Flow<ToolLoopLegEvent> = flow {
        requests += request
        legs.getOrElse(index++) { emptyList() }.forEach { emit(it) }
    }
}

/** One complete tool call within a leg (given whole in a single fragment). */
internal fun call(index: Int, id: String, name: String, arguments: String = "{}") =
    ToolLoopToolCallDelta(index = index, id = id, type = "function", name = name, arguments = arguments)

/** One leg = several parallel tool calls. */
internal fun toolLeg(vararg calls: ToolLoopToolCallDelta): List<ToolLoopLegEvent> =
    listOf(ToolLoopLegEvent.ToolCallDeltas(calls.toList()))

internal fun textLeg(text: String): List<ToolLoopLegEvent> = listOf(ToolLoopLegEvent.TextDelta(text))

/**
 * An entry with scriptable behaviour: [behavior] receives how many times it has been called so far (starting at 0) and the call itself,
 * and returns a result or throws; [disposition] decides how a thrown non-cancellation exception is ruled on.
 */
internal class ScriptedEntry(
    override val name: String,
    override val scope: ToolScope = ToolScope.Mcp,
    private val disposition: (Throwable) -> ToolFailureDisposition = { ToolFailureDisposition.Fatal },
    private val behavior: suspend (attempt: Int, call: ToolLoopToolCall) -> ToolExecutionOutcome =
        { _, _ -> ToolExecutionOutcome(OK) },
) : ToolRegistryEntry {
    override val definition = ToolLoopToolDefinition(
        function = ToolLoopToolFunction(name = name, description = "d", parameters = buildJsonObject {}),
    )

    val contexts = mutableListOf<ToolExecutionContext>()
    val dispositionInputs = mutableListOf<Throwable>()

    override suspend fun execute(call: ToolLoopToolCall, context: ToolExecutionContext): ToolExecutionOutcome {
        val attempt = contexts.size
        contexts += context
        return behavior(attempt, call)
    }

    override fun failureDisposition(error: Throwable): ToolFailureDisposition {
        dispositionInputs += error
        return disposition(error)
    }

    companion object {
        const val OK = "{\"ok\":true}"
    }
}

/** Tool results fed back to the model in a given request (by call id). */
internal fun ToolLoopLegRequest.toolResult(callId: String): String? =
    messages.lastOrNull { it.role == "tool" && it.toolCallId == callId }?.textContent

internal fun ToolLoopLegRequest.systemTexts(): List<String> =
    messages.filter { it.role == "system" }.mapNotNull { it.textContent }
