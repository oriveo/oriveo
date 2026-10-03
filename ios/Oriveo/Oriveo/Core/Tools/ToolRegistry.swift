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
    /// A failure that would hold for every later call too: the whole turn throws.
    case fatal
    /// A one-off failure: fed back as a structured `ok:false` result and the loop continues. It
    /// counts towards the consecutive-failure limit.
    case degrade(code: String, message: String)
    /// A neutral result: also fed back as `ok:false`, but it neither adds to the consecutive-failure
    /// count nor resets it (it still uses up one tool step). For calls that worked and whose answer
    /// is simply "no": that is not evidence of a broken link, and not a success that should wipe
    /// out earlier real failures either.
    case neutral(code: String, message: String)
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
    private var table: [String: any ToolRegistryEntry]
    private var orderedNames: [String]

    init(entries: [any ToolRegistryEntry]) {
        var table: [String: any ToolRegistryEntry] = [:]
        var order: [String] = []
        for entry in entries where table[entry.name] == nil {
            table[entry.name] = entry
            order.append(entry.name)
        }
        self.table = table
        self.orderedNames = order
    }

    static let empty = ToolRegistry(entries: [])

    func entry(named name: String) -> (any ToolRegistryEntry)? {
        table[name]
    }

    var isEmpty: Bool { table.isEmpty }

    var names: [String] { orderedNames }

    /// Every entry, in registration order. Used to merge registries from two sources.
    var entries: [any ToolRegistryEntry] {
        orderedNames.compactMap { table[$0] }
    }

    var definitions: [ToolLoopToolDefinition] {
        orderedNames.compactMap { table[$0]?.definition }
    }
}
