import Foundation

// Stateful continuation decision; spec is continuationCases in `shared/context-contracts/wire-system.v1.json`:
// when the previous leg has a previousResponseId, instructionsMode is known (resend | omit), and system / model / checkpoint
// are all unchanged, only the continuation prompt is sent together with previous_response_id; otherwise fall back to the full plan. Decision and projection only; no request is sent.

/// How instructions are handled alongside previous_response_id: resend sends them as usual, omit does not (some providers return 400 when both are present).
public enum ContextInstructionsMode: String, Codable, Hashable, Sendable, CaseIterable {
    case resend
    case omit
}

public struct ContextContinuationState: Hashable, Sendable {
    public var previousResponseId: String?
    /// nil means the route declares nothing, so send the full plan.
    public var instructionsMode: ContextInstructionsMode?
    public var systemChangedSinceLastLeg: Bool
    public var modelChanged: Bool
    public var checkpointChanged: Bool

    public init(
        previousResponseId: String?,
        instructionsMode: ContextInstructionsMode?,
        systemChangedSinceLastLeg: Bool = false,
        modelChanged: Bool = false,
        checkpointChanged: Bool = false
    ) {
        self.previousResponseId = previousResponseId
        self.instructionsMode = instructionsMode
        self.systemChangedSinceLastLeg = systemChangedSinceLastLeg
        self.modelChanged = modelChanged
        self.checkpointChanged = checkpointChanged
    }
}

public enum ContextContinuationDecision: Hashable, Sendable {
    case fullPlan
    case stateful(previousResponseId: String, sendInstructions: Bool)
}

public struct ContextContinuationMessage: Hashable, Sendable {
    public var role: ContextMessageRole
    public var content: String

    public init(role: ContextMessageRole, content: String) {
        self.role = role
        self.content = content
    }
}

/// Projection result: when instructions / previous_response_id is nil, the request does not carry that field.
public struct ContextContinuationRequest: Hashable, Sendable {
    public var instructions: String?
    public var previousResponseId: String?
    public var input: [ContextContinuationMessage]

    public init(instructions: String?, previousResponseId: String?, input: [ContextContinuationMessage]) {
        self.instructions = instructions
        self.previousResponseId = previousResponseId
        self.input = input
    }
}

public enum ContextContinuation {
    public static func decide(_ state: ContextContinuationState) -> ContextContinuationDecision {
        guard let previousResponseId = state.previousResponseId, !previousResponseId.isEmpty,
              let mode = state.instructionsMode,
              !state.systemChangedSinceLastLeg, !state.modelChanged, !state.checkpointChanged
        else {
            return .fullPlan
        }
        return .stateful(previousResponseId: previousResponseId, sendInstructions: mode == .resend)
    }

    /// fullPlan sends system + history + current; stateful sends only current, with or without instructions per the decision.
    public static func project(
        _ decision: ContextContinuationDecision,
        system: String?,
        history: [ContextContinuationMessage],
        current: String
    ) -> ContextContinuationRequest {
        let currentMessage = ContextContinuationMessage(role: .user, content: current)
        switch decision {
        case .fullPlan:
            return ContextContinuationRequest(
                instructions: system, previousResponseId: nil, input: history + [currentMessage]
            )
        case .stateful(let previousResponseId, let sendInstructions):
            return ContextContinuationRequest(
                instructions: sendInstructions ? system : nil,
                previousResponseId: previousResponseId,
                input: [currentMessage]
            )
        }
    }
}
