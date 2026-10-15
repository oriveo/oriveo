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

    /// The collection view's effective visible height once the keyboard is accounted for.
    ///
    /// Keyboard notifications report the frame in **screen** coordinates. With Stage Manager, Split
    /// View or a non-full-screen window on a Duo, the window origin is not the screen origin, so
    /// comparing it with the view's window coordinates is off. The keyboard frame is converted into
    /// the view's coordinates through the coordinate space of the window's screen first.
    func effectiveViewport(for view: UIView) -> CGFloat {
        guard let window = view.window else { return view.bounds.height }
        // Without a window scene, fall back to window coordinates (the old full-screen behaviour).
        let screenSpace: UICoordinateSpace = window.windowScene?.screen.coordinateSpace ?? window
        return Self.effectiveViewport(
            for: view, keyboardFrameInScreen: keyboardFrameInScreen,
            screenSpace: screenSpace, window: window)
    }

    /// Coordinate conversion (unit-testable): converts the screen-space keyboard frame and the
    /// window's bottom edge into `view` coordinates, then hands them to the pure function. In tests,
    /// `screenSpace` / `window` can be plain UIViews that simulate a window offset within the screen.
    static func effectiveViewport(
        for view: UIView, keyboardFrameInScreen: CGRect,
        screenSpace: UICoordinateSpace, window: UIView
    ) -> CGFloat {
        let keyboardInView = keyboardFrameInScreen.height > 0
            ? view.convert(keyboardFrameInScreen, from: screenSpace)
            : .zero
        let windowMaxYInView = view.convert(window.bounds, from: window).maxY
        return effectiveViewport(
            viewFrame: view.bounds, keyboardFrame: keyboardInView, windowMaxY: windowMaxYInView)
    }

    /// Pure function (unit-testable); all three arguments must be in one coordinate space. Returns the
    /// height from the view's top to `min(view bottom, keyboard top)`. A hidden keyboard, one that
    /// does not overlap, or one whose bottom edge does not reach the window bottom (a floating or
    /// split iPad keyboard) gives the full view height. It does not depend on whether the collection
    /// view resizes with the keyboard: if the view already sits above the keyboard after resizing,
    /// the intersection is the full resized height, which is equally correct.
    static func effectiveViewport(viewFrame: CGRect, keyboardFrame: CGRect, windowMaxY: CGFloat) -> CGFloat {
        // A docked keyboard sits on the screen bottom, so its bottom edge is at or below the window
        // bottom; otherwise it is floating or split and does not cover the bottom of the window. 0.5pt
        // absorbs conversion error.
        guard keyboardFrame.height > 0,
              keyboardFrame.maxY >= windowMaxY - 0.5,
              keyboardFrame.minY < viewFrame.maxY else {
            return viewFrame.height
        }
        return max(0, keyboardFrame.minY - viewFrame.minY)
    }
}
