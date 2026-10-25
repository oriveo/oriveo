import Foundation
import OriveoProviderKit

/// The only plan a realtime session opening accepts: it can only be obtained by projecting a RealtimeSessionPlan, and the initializer is visible only in this file.
/// Not constructed when the plan was rejected (instructions_too_long / unknown_window).
nonisolated struct PlannedRealtimeSession: Sendable {
    let plan: RealtimeSessionPlan
    let instructions: String
    let history: [RealtimeSessionHistoryItem]

    fileprivate init(plan: RealtimeSessionPlan, instructions: String, history: [RealtimeSessionHistoryItem]) {
        self.plan = plan
        self.instructions = instructions
        self.history = history
    }

    /// The only entry point: nil when the plan was rejected or lacks instructions / history.
    static func from(_ plan: RealtimeSessionPlan) -> PlannedRealtimeSession? {
        guard plan.reject == nil, let instructions = plan.instructions, let history = plan.history else { return nil }
        return PlannedRealtimeSession(plan: plan, instructions: instructions, history: history)
    }

    /// Arguments for opening a realtime session: only instructions and history[{role, text}].
    func transportInput() -> RealtimeTransportInput {
        RealtimeTransportInput(
            instructions: instructions,
            history: history.map { RealtimeTransportInput.Turn(role: $0.role, text: $0.text) }
        )
    }
}

/// Arguments for opening a realtime session: can only be produced by `PlannedRealtimeSession.transportInput()`.
nonisolated struct RealtimeTransportInput: Sendable, Equatable {
    struct Turn: Sendable, Equatable {
        let role: ContextMessageRole
        let text: String
    }

    let instructions: String
    let history: [Turn]

    fileprivate init(instructions: String, history: [Turn]) {
        self.instructions = instructions
        self.history = history
    }
}
