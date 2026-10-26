package ai.oriveo.community.core.memory

import ai.oriveo.community.core.context.MemoryPropose
import ai.oriveo.community.core.tools.ToolExecutionContext
import ai.oriveo.community.core.tools.ToolExecutionOutcome
import ai.oriveo.community.core.tools.ToolLoopToolCall
import ai.oriveo.community.core.tools.ToolLoopToolDefinition
import ai.oriveo.community.core.tools.ToolRegistryEntry
import ai.oriveo.community.core.tools.ToolScope
import kotlinx.coroutines.CancellationException

/**
 * propose_memory as the last registry entry of the MCP tool loop.
 * Executing hands the arguments to [hook] (candidate + suggestion bar) and always answers [MemoryPropose.TOOL_RESULT];
 * it reports no step and never fails, so it cannot count toward the consecutive-failure guard.
 */
class ProposeMemoryEntry(private val hook: MemoryProposeSendHook) : ToolRegistryEntry {
    override val name: String get() = MemoryPropose.TOOL_NAME

    // Scope is only a label for the generic loop; propose_memory is a client tool outside any remote source.
    override val scope: ToolScope get() = ToolScope.Mcp
    override val definition: ToolLoopToolDefinition get() = MemoryPropose.tool

    override suspend fun execute(call: ToolLoopToolCall, context: ToolExecutionContext): ToolExecutionOutcome {
        try {
            hook.onProposeCall(call.function.arguments)
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            // Rule 4: every call gets the fixed tool_result, whatever the outcome.
        }
        return ToolExecutionOutcome(MemoryPropose.TOOL_RESULT)
    }
}
