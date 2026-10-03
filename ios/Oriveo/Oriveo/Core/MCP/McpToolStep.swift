import Foundation

// MARK: - Tool steps on a message
//
// Summaries only: server name, tool, argument summary, status. The raw arguments and the result live in
// `mcp_step_payload`.

nonisolated struct McpToolStep: Codable, Hashable, Sendable, Identifiable {
    typealias Status = McpToolStepUpdate.Status

    static let scopeMcp = "mcp"

    var id: String
    /// Always `mcp`; leaves room for other sources later.
    var scope: String = McpToolStep.scopeMcp
    /// The server id as a lowercase UUID string.
    var serverId: String
    /// Stored redundantly so the record stays readable after the server is removed.
    var serverName: String
    var toolName: String
    var title: String
    var argsSummary: String
    var status: Status
    /// A code from the closed set of error codes; the error text returned by the server is never stored.
    var errorCode: String?
    var step: Int
    var durationMs: Int?

    init(
        id: String,
        scope: String = McpToolStep.scopeMcp,
        serverId: String,
        serverName: String,
        toolName: String,
        title: String,
        argsSummary: String,
        status: Status,
        errorCode: String? = nil,
        step: Int,
        durationMs: Int? = nil
    ) {
        self.id = id
        self.scope = scope
        self.serverId = serverId
        self.serverName = serverName
        self.toolName = toolName
        self.title = title
        self.argsSummary = argsSummary
        self.status = status
        self.errorCode = errorCode
        self.step = step
        self.durationMs = durationMs
    }

    /// One status callback from the executor -> the summary on the message. The payload is not carried over.
    init(update: McpToolStepUpdate) {
        self.init(
            id: update.id,
            serverId: update.serverId.uuidString.lowercased(),
            serverName: update.serverName,
            toolName: update.toolName,
            title: update.title,
            argsSummary: update.argsSummary,
            status: update.status,
            errorCode: update.errorCode?.rawValue,
            step: update.step,
            durationMs: update.durationMs
        )
    }

    /// Display title: falls back to the original tool name when the server gave no title.
    var displayTitle: String { title.isEmpty ? toolName : title }

    // MARK: Reloading

    /// Turns a step still marked `running` into `interrupted`: when the process was killed, or the message was
    /// read back from a backup, nobody will ever move it to a terminal state.
    var interruptedIfRunning: McpToolStep {
        guard status == .running else { return self }
        var copy = self
        copy.status = .interrupted
        copy.errorCode = McpErrorCode.interrupted.rawValue
        return copy
    }

    static func interruptingRunning(_ steps: [McpToolStep]) -> [McpToolStep] {
        steps.map(\.interruptedIfRunning)
    }

    /// Merges one callback into the existing steps: replaces the step with the same id, otherwise appends, sorted
    /// by step number.
    static func merging(_ update: McpToolStepUpdate, into steps: [McpToolStep]) -> [McpToolStep] {
        let step = McpToolStep(update: update)
        var result = steps
        if let index = result.firstIndex(where: { $0.id == step.id }) {
            result[index] = step
        } else {
            result.append(step)
        }
        return result
    }
}
