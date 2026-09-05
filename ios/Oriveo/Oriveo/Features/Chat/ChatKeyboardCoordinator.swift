import UIKit

@MainActor
final class ChatKeyboardCoordinator {
    private(set) var keyboardFrameInScreen: CGRect = .zero
    var onViewportSettled: (() -> Void)?

    init() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)),
                       name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        nc.addObserver(self, selector: #selector(keyboardWillHide(_:)),
                       name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    nonisolated deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func keyboardWillChangeFrame(_ note: Notification) {
        guard let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        keyboardFrameInScreen = end
        onViewportSettled?()
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        keyboardFrameInScreen = .zero
        onViewportSettled?()
    }

    func effectiveViewport(for view: UIView) -> CGFloat {
        Self.effectiveViewport(
            viewFrameInScreen: view.convert(view.bounds, to: nil),
            keyboardFrameInScreen: keyboardFrameInScreen)
    }

    static func effectiveViewport(viewFrameInScreen: CGRect, keyboardFrameInScreen: CGRect) -> CGFloat {
        guard keyboardFrameInScreen.height > 0,
              keyboardFrameInScreen.minY < viewFrameInScreen.maxY else {
            return viewFrameInScreen.height
        }
        return max(0, keyboardFrameInScreen.minY - viewFrameInScreen.minY)
    }
}
