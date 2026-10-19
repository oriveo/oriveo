package ai.oriveo.community.core.memory

import ai.oriveo.community.core.context.MemorySearch
import ai.oriveo.community.core.tools.ToolExecutionContext
import ai.oriveo.community.core.tools.ToolExecutionOutcome
import ai.oriveo.community.core.tools.ToolLoopToolCall
import ai.oriveo.community.core.tools.ToolLoopToolDefinition
import ai.oriveo.community.core.tools.ToolRegistryEntry
import ai.oriveo.community.core.tools.ToolScope

/**
 * memory-search.v1 legRules 4: search_memory as the last registry entry of the MCP / Library tool loops (after
 * propose_memory). Like [ProposeMemoryEntry] it reports no step and never fails.
 */
class MemorySearchEntry(
    private val turn: MemorySearchTurn,
    private val recallIds: List<String>,
    private val recallMax: Int?,
    private val rhoHi: Double,
) : ToolRegistryEntry {
    override val name: String get() = MemorySearch.TOOL_NAME

    // Scope is only a label for the generic loop; search_memory is a client tool outside any remote source.
    override val scope: ToolScope get() = ToolScope.Mcp
    override val definition: ToolLoopToolDefinition get() = MemorySearch.tool

    override suspend fun execute(call: ToolLoopToolCall, context: ToolExecutionContext): ToolExecutionOutcome =
        ToolExecutionOutcome(turn.run(call.function.arguments, recallIds, recallMax, rhoHi))
}
