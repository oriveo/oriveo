import Foundation
import Observation
import SwiftUI

enum ToastStyle: Sendable {
    case success
    case error
    case warning
    case info
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
