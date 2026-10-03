import Foundation

// MARK: - What the step block shows
//
// A pure function: the `toolSteps` on a message plus whether the message is still generating -> what the step
// block should show. The view only draws the result and picks the copy for the current language.

/// What the user can do inside the step block (while parked at a step that needs a new sign-in).
nonisolated enum McpToolStepAction: Sendable, Equatable {
    case reauthorize(McpToolStep)
    case skip(McpToolStep)
}

nonisolated struct McpToolStepsPresentation: Sendable, Equatable {
    enum Header: Sendable, Equatable {
        /// "Using tools".
        case running
        /// "Waiting for reauthorization": the loop is parked at a tool step that needs a new sign-in.
        case waitingForSignIn
        /// "Used N tools": N counts the steps that actually ran to completion (denied, failed and interrupted ones
        /// do not count).
        case finished(usedCount: Int)
    }

    enum Trailing: Sendable, Equatable {
        /// "Step N".
        case step(Int)
        /// Server names, de-duplicated in order of first appearance.
        case servers([String])
        case declined(Int)
        case failed(Int)
    }

    enum RowDetail: Sendable, Equatable {
        /// Argument summary (may be empty).
        case argsSummary(String)
        case declined
        case interrupted
        case signInExpired(serverName: String)
        /// Failure: the explanation is picked by the closed-set error code.
        case failure(code: String?)
    }

    struct Row: Sendable, Equatable, Identifiable {
        var id: String
        var step: McpToolStep
        /// Display status: once the message is no longer generating, `running` is always drawn as `interrupted`.
        var status: McpToolStep.Status
        var detail: RowDetail
        /// A finished step can be opened to see its details.
        var opensDetail: Bool
    }

    /// With more steps than this, the earlier ones collapse into "Show N earlier steps".
    static let collapseThreshold = 5
    /// How many trailing steps stay visible when collapsed.
    static let tailCountWhenCollapsed = 2

    var header: Header
    var trailing: Trailing
    var rows: [Row]
    /// Running / waiting for authorization: expanded by default.
    var isActive: Bool
    /// The step waiting for reauthorization (the block offers "Reauthorize / Skip this step").
    var pausedForSignIn: McpToolStep?
    /// The step limit was reached: explained in the block's last row.
    var limitReached: Bool

    /// Number of rows hidden when the earlier steps are collapsed; 0 when nothing needs collapsing.
    var hiddenEarlierCount: Int {
        rows.count > Self.collapseThreshold ? rows.count - Self.tailCountWhenCollapsed : 0
    }

    /// The step parked at "sign in again": the message is still generating and the step is `needsAuth` +
    /// `needs_auth` (after a skip the error code becomes `auth_skipped`, and after a new sign-in the status goes
    /// back to `running`; neither counts as parked any more).
    static func pausedStep(in steps: [McpToolStep], isGenerating: Bool) -> McpToolStep? {
        guard isGenerating else { return nil }
        return steps.last { $0.status == .needsAuth && $0.errorCode == McpErrorCode.needsAuth.rawValue }
    }

    static func make(
        steps: [McpToolStep],
        isGenerating: Bool,
        limitReached: Bool = false
    ) -> McpToolStepsPresentation {
        let rows = steps.map { step -> Row in
            let status: McpToolStep.Status = (step.status == .running && !isGenerating) ? .interrupted : step.status
            return Row(
                id: step.id,
                step: step,
                status: status,
                detail: detail(for: step, status: status),
                opensDetail: status != .running
            )
        }
        let paused = pausedStep(in: steps, isGenerating: isGenerating)
        let running = rows.contains { $0.status == .running }
        let latestStep = rows.map(\.step.step).max() ?? 0

        let header: Header
        let trailing: Trailing
        if paused != nil {
            header = .waitingForSignIn
            trailing = .step(paused?.step ?? latestStep)
        } else if running {
            header = .running
            trailing = .step(rows.last { $0.status == .running }?.step.step ?? latestStep)
        } else if isGenerating {
            // Between two steps (the model is deciding the next one): still in progress, reusing the latest step number.
            header = .running
            trailing = .step(latestStep)
        } else {
            header = .finished(usedCount: rows.filter { $0.status == .done }.count)
            let failed = rows.filter { $0.status == .failed || $0.status == .needsAuth }.count
            let declined = rows.filter { $0.status == .denied }.count
            if failed > 0 {
                trailing = .failed(failed)
            } else if declined > 0 {
                trailing = .declined(declined)
            } else {
                var seen = Set<String>()
                trailing = .servers(steps.map(\.serverName).filter { !$0.isEmpty && seen.insert($0).inserted })
            }
        }
        return McpToolStepsPresentation(
            header: header,
            trailing: trailing,
            rows: rows,
            isActive: isGenerating,
            pausedForSignIn: paused,
            // The last row only appears once the answer has finished; while generating, the steps are still changing.
            limitReached: limitReached && !isGenerating
        )
    }

    private static func detail(for step: McpToolStep, status: McpToolStep.Status) -> RowDetail {
        switch status {
        case .running, .done: return .argsSummary(step.argsSummary)
        case .denied: return .declined
        case .interrupted: return .interrupted
        case .needsAuth: return .signInExpired(serverName: step.serverName)
        case .failed: return .failure(code: step.errorCode)
        }
    }
}
