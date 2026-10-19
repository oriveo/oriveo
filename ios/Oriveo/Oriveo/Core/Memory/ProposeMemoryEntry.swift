import Foundation
import OriveoProviderKit

/// propose_memory as the last entry of the MCP / Library tool-loop registries (P10 contract items 3, 4).
///
/// Every call is answered with the fixed tool_result; only a `create` outcome writes a candidate, and the first
/// candidate of the turn becomes the suggestion bar. No tool step row is recorded and nothing is persisted with the
/// message; the call still takes one loop step like any other tool.
nonisolated struct ProposeMemoryEntry: ToolRegistryEntry {
    let sink: ProposeMemoryLoopSink

    /// The fixture tool definition (openai_chat shape); each wire protocol projects it through its adapter.
    static let toolDefinition: ToolLoopToolDefinition? = try? JSONDecoder().decode(
        ToolLoopToolDefinition.self, from: Data(MemoryPropose.toolJSON.utf8)
    )

    var name: String { MemoryPropose.toolName }
    var scope: ToolScope { .memory }
    var definition: ToolLoopToolDefinition? { Self.toolDefinition }

    func execute(_ call: ToolLoopToolCall, context: ToolExecutionContext) async throws -> ToolExecutionOutcome {
        await sink.propose(argumentsJSON: call.function.arguments)
        return ToolExecutionOutcome(content: MemoryPropose.toolResult)
    }

    /// propose never fails the run and never counts toward consecutive failures.
    func failureDisposition(for error: any Error) -> ToolFailureDisposition {
        .neutral(code: "propose_memory_failed", message: "The memory proposal was not saved.")
    }
}

/// Per-turn state behind `ProposeMemoryEntry`: counts this turn's calls (priorInTurn) and hands created
/// candidates to the turn context (MemorySuggestionController.presentProposed via `onCandidate`).
@MainActor
final class ProposeMemoryLoopSink {
    let context: ProposeMemoryTurnContext
    let userMessageID: UUID
    let assistantMessageID: UUID
    let conversationID: UUID
    /// propose calls of this turn so far, whatever their outcome.
    private(set) var callCount = 0

    init(context: ProposeMemoryTurnContext, userMessageID: UUID, assistantMessageID: UUID, conversationID: UUID) {
        self.context = context
        self.userMessageID = userMessageID
        self.assistantMessageID = assistantMessageID
        self.conversationID = conversationID
    }

    func propose(argumentsJSON: String) async {
        let prior = callCount
        callCount += 1
        do {
            let candidate = try await context.repository.propose(
                argumentsJSON: argumentsJSON,
                priorInTurn: prior,
                userText: context.userText,
                messageId: userMessageID.uuidString,
                conversationId: conversationID.uuidString,
                folderId: context.folderID,
                nowMs: Int64(Date().timeIntervalSince1970 * 1000)
            )
            if let candidate { context.onCandidate(candidate, assistantMessageID) }
        } catch {
            #if DEBUG
            print("[ProposeMemory] loop propose failed: \(error)")
            #endif
        }
    }
}
