import Foundation
import Observation
import SwiftUI

/// Semantic toast type: picks the color and glyph of the round icon (mapped in ToastOverlay).
enum ToastStyle: Sendable {
    case success
    case error
    case warning
    case info
    /// Removal actions (e.g. "Removed X · Undo"): neutral gray circle with a minus glyph.
    case removed
    case neutral
}

struct Toast: Equatable, Sendable {
    let message: String
    let style: ToastStyle
    var actionTitle: String? = nil
}

@MainActor
@Observable
final class ToastManager {
    static let shared = ToastManager()
    private(set) var current: Toast?
    @ObservationIgnored private var currentAction: (@MainActor () -> Void)?
    private var dismissTask: Task<Void, Never>?

    func show(
        _ text: String,
        style: ToastStyle = .neutral,
        duration: TimeInterval = 3,
        actionTitle: String? = nil,
        action: (@MainActor () -> Void)? = nil
    ) {
        dismissTask?.cancel()
        current = Toast(message: text, style: style, actionTitle: actionTitle)
        currentAction = action
        dismissTask = Task {
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                current = nil
            }
            currentAction = nil
        }
    }

    func performCurrentAction() {
        let action = currentAction
        dismissTask?.cancel()
        currentAction = nil
        withAnimation(.easeOut(duration: 0.2)) { current = nil }
        action?()
    }
}
