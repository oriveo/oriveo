import Foundation
import OriveoProviderKit

nonisolated enum ToolScope: String, Sendable, Equatable {
    case web
    case mcp
}

nonisolated struct ToolCallRejection: Error, Equatable, Sendable {
    var code: String
    var message: String
}

nonisolated enum ToolFailureDisposition: Equatable, Sendable {
    case fatal
    case degrade(code: String, message: String)
}

nonisolated struct ToolExecutionOutcome: Sendable {
    var content: String
    var stopReason: String?

    init(content: String, stopReason: String? = nil) {
        self.content = content
        self.stopReason = stopReason
    }
}

nonisolated struct ToolExecutionContext: Sendable {
    var callID: String
    var stepNumber: Int
    var legIndex: Int
}

nonisolated protocol ToolRegistryEntry: Sendable {
    var name: String { get }
    var scope: ToolScope { get }
    var definition: ToolLoopToolDefinition? { get }
    var wireType: String { get }
    func execute(_ call: ToolLoopToolCall, context: ToolExecutionContext) async throws -> ToolExecutionOutcome
    func failureDisposition(for error: any Error) -> ToolFailureDisposition
}

extension ToolRegistryEntry {
    var wireType: String { "function" }
    func failureDisposition(for error: any Error) -> ToolFailureDisposition { .fatal }
}

/// (`ToolCallLoop.onUnhandledToolCalls` → ChatManager `recordUnhandledToolCalls`).
nonisolated struct ToolRegistry: Sendable {
    private var entries: [String: any ToolRegistryEntry]
    private var orderedNames: [String]

    init(entries: [any ToolRegistryEntry]) {
        var table: [String: any ToolRegistryEntry] = [:]
        var order: [String] = []
        for entry in entries where table[entry.name] == nil {
            table[entry.name] = entry
            order.append(entry.name)
        }
        self.entries = table
        self.orderedNames = order
    }

    static let empty = ToolRegistry(entries: [])

    func entry(named name: String) -> (any ToolRegistryEntry)? {
        entries[name]
    }

    var isEmpty: Bool { entries.isEmpty }

    var names: [String] { orderedNames }

    var definitions: [ToolLoopToolDefinition] {
        orderedNames.compactMap { entries[$0]?.definition }
    }
}
