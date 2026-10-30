import Foundation

/// The single decision for whether a tool-loop leg really sends reasoning parameters on this request (shared by both leg executors and the external-search send planner).
///
/// Outbound tier = the tier the user picked (auto = the default tier declared by the capability projection), and that tier's `reasoning_level/<tier>` must pass the outbound gate
/// (negative cache / missing evidence / rejection are all folded into the projection's permitsOutbound); failing the gate = the reasoning field is stripped and not sent.
nonisolated enum OutboundReasoning {
    /// The keys requested from the capability projection: auto asks for every concrete tier, an explicit tier is recorded separately as explicit.
    static func capabilityKeys(requested: ReasoningMode) -> (keys: Set<String>, explicit: Set<String>) {
        let modes = requested == .automatic ? ReasoningMode.allCases.filter { $0 != .automatic } : [requested]
        let keys = Set(modes.map { "reasoning_level/\($0.rawValue)" })
        return (keys, requested == .automatic ? [] : ["reasoning_level/\(requested.rawValue)"])
    }

    /// The reasoning tier actually sent; nil = the request carries no reasoning field.
    static func selectedMode(
        requested: ReasoningMode, declaredDefault: ReasoningMode?, permits: (String) -> Bool
    ) -> ReasoningMode? {
        let selected = requested == .automatic ? declaredDefault : requested
        guard let selected, permits("reasoning_level/\(selected.rawValue)") else { return nil }
        return selected
    }

    /// thinking.on of external-search planSearchTurn: this turn's outbound request really carries reasoning parameters, and the tier is not "fast".
    static func thinkingOn(_ selected: ReasoningMode?) -> Bool {
        guard let selected else { return false }
        return selected != .fast
    }
}

/// A leg executor reports "which reasoning tier this connection's leg would send under the current configuration" (the send planner reads it before sending, without issuing a request).
protocol ToolLoopOutboundReasoningReporting {
    func outboundReasoningMode() -> ReasoningMode?
}
