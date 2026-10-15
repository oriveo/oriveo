import SwiftUI
import UIKit

/// Finds the host UIWindow and reports "the user is working in this window". Used inside `.background`.
///
/// With several windows (iPad, Duo) each window renders its own `NavigationManager`, while app-wide entry points (`appState.openXxx()`, deep links)
/// act on the active window. A touch in this window (including a sheet it presents) or this window becoming key makes it active.
/// The window found is also reported through `onWindowChange` (nil when leaving the window) for UIKit wiring bound per window
/// (the back swipe).
struct WindowActivationProbe: UIViewRepresentable {
    let onActivate: () -> Void
    let onWindowChange: (UIWindow?) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onActivate = onActivate
        view.onWindowChange = onWindowChange
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.onActivate = onActivate
        uiView.onWindowChange = onWindowChange
    }

    final class ProbeView: UIView {
        var onActivate: (() -> Void)?
        var onWindowChange: ((UIWindow?) -> Void)?
        private weak var observedWindow: UIWindow?
        private weak var activationGesture: WindowActivationGestureRecognizer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window !== observedWindow else { return }
            detach()
            if let window {
                attach(to: window)
            }
            let current = window
            // Do not change SwiftUI state from inside a view hierarchy callback; defer to the next main-queue turn
            DispatchQueue.main.async { [weak self] in
                self?.onWindowChange?(current)
            }
        }

        private func attach(to window: UIWindow) {
            let gesture = WindowActivationGestureRecognizer { [weak self] in
                self?.onActivate?()
            }
            window.addGestureRecognizer(gesture)
            activationGesture = gesture
            observedWindow = window
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidBecomeKey(_:)),
                name: UIWindow.didBecomeKeyNotification,
                object: window
            )
        }

        private func detach() {
            if let observedWindow {
                if let activationGesture {
                    observedWindow.removeGestureRecognizer(activationGesture)
                }
                NotificationCenter.default.removeObserver(
                    self,
                    name: UIWindow.didBecomeKeyNotification,
                    object: observedWindow
                )
            }
            activationGesture = nil
            observedWindow = nil
        }

        @objc private func windowDidBecomeKey(_ notification: Notification) {
            onActivate?()
        }
    }
}

/// An observe-only recognizer: it calls back as soon as a touch begins and fails at once, never claiming, delaying or cancelling any other touch in the window.
final class WindowActivationGestureRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private let onTouch: () -> Void

    init(onTouch: @escaping () -> Void) {
        self.onTouch = onTouch
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        onTouch()
        state = .failed
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
