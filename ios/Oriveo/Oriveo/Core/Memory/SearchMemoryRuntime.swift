import Foundation
import OriveoProviderKit

/// search_memory state of one turn (memory-search.v1 rules 4, 6): the L3 item snapshot of this send, the
/// request's recallMax / rhoHi, and the ids already shown to the model ([D] recall plus earlier searches).
///
/// Shared by the plain path (first leg + tail leg) and the MCP / Library tool-loop registry entry. Returned ids
/// are the entries actually rendered into a tool_result; they join excludeIds and the turn's memoryIds.
@MainActor
final class MemorySearchSession {
    let items: [MemoryItem]
    let context: MemoryRecallContext
    let recallMax: Int?
    let rhoHi: Double
    private(set) var excludeIds: [String]
    /// search calls of this turn so far, whatever their outcome (priorInTurn).
    private(set) var callCount = 0
    /// Entries returned to the model, in call order.
    private(set) var returned: [ContextRecallEntry] = []
    /// Ids returned by a tool-loop call: the loop always sends the tool_result on, so they join the request's
    /// memoryIds right away. The plain path reports ids itself, only when the tail leg carries them.
    var onReturnedIds: (([String]) -> Void)?

    init(items: [MemoryItem], context: MemoryRecallContext, recallMax: Int?, rhoHi: Double, recallIds: [String]) {
        self.items = items
        self.context = context
        self.recallMax = recallMax
        self.rhoHi = rhoHi
        self.excludeIds = recallIds
    }

    func reportLoopIds(_ ids: [String]) {
        if !ids.isEmpty { onReturnedIds?(ids) }
    }

    /// Runs one call and returns its tool_result text with the ids rendered into it.
    func run(argumentsJSON: String) async -> (text: String, ids: [String]) {
        let prior = callCount
        callCount += 1
        let outcome = await MemoryRecallIndexCache.shared.search(
            items: items, arguments: argumentsJSON, context: context, excludeIds: excludeIds, priorInTurn: prior
        )
        let kept = MemorySearch.fittedHits(outcome, maxTokens: recallMax, rhoHi: rhoHi)
        let ids = kept.map(\.id).filter { !excludeIds.contains($0) }
        excludeIds.append(contentsOf: ids)
        returned.append(contentsOf: kept.map(\.entry))
        return (MemorySearch.toolResult(outcome, maxTokens: recallMax, rhoHi: rhoHi), ids)
    }
}

/// search_memory as one more MCP / Library tool-loop registry entry, after propose_memory (legRules 4).
/// It takes a loop step like any tool; no tool step row is recorded and nothing is persisted with the message.
nonisolated struct SearchMemoryEntry: ToolRegistryEntry {
    let session: MemorySearchSession

    /// The fixture tool definition (openai_chat shape); each wire protocol projects it through its adapter.
    static let toolDefinition: ToolLoopToolDefinition? = try? JSONDecoder().decode(
        ToolLoopToolDefinition.self, from: Data(MemorySearch.toolJSON.utf8)
    )

    var name: String { MemorySearch.toolName }
    var scope: ToolScope { .memory }
    var definition: ToolLoopToolDefinition? { Self.toolDefinition }

    func execute(_ call: ToolLoopToolCall, context: ToolExecutionContext) async throws -> ToolExecutionOutcome {
        let result = await session.run(argumentsJSON: call.function.arguments)
        await session.reportLoopIds(result.ids)
        return ToolExecutionOutcome(content: result.text)
    }

    /// search never fails the run and never counts toward consecutive failures.
    func failureDisposition(for error: any Error) -> ToolFailureDisposition {
        .neutral(code: "search_memory_failed", message: MemorySearch.emptyResult)
    }
}
