import UIKit

@MainActor
final class AssistantStreamingTableRenderer {
    private weak var bodyStack: UIStackView?
    private weak var insertAfterView: UIView?
    private let onHeightChange: () -> Void
    private(set) var card: UIKitStreamingTableCard?
    private var lastLines: [String] = []

    init(bodyStack: UIStackView, insertAfterView: UIView, onHeightChange: @escaping () -> Void) {
        self.bodyStack = bodyStack
        self.insertAfterView = insertAfterView
        self.onHeightChange = onHeightChange
    }

    func update(lines: [String]) {
        guard !lines.isEmpty else {
            hide()
            return
        }
        if lines == lastLines, card != nil { return }

        if let card {
            card.updateLines(lines)
            lastLines = lines
            return
        }

        guard let card = UIKitStreamingTableCard(initialLines: lines) else {
            return
        }
        card.onIntrinsicHeightDidChange = onHeightChange
        guard let bodyStack else { return }
        let insertAfter = insertAfterView.flatMap { bodyStack.arrangedSubviews.firstIndex(of: $0) }
            ?? bodyStack.arrangedSubviews.indices.last
            ?? 0
        bodyStack.insertArrangedSubview(card, at: insertAfter + 1)
        self.card = card
        lastLines = lines
    }

    func hide() {
        guard let card else {
            lastLines = []
            return
        }
        bodyStack?.removeArrangedSubview(card)
        card.removeFromSuperview()
        self.card = nil
        lastLines = []
    }
}
