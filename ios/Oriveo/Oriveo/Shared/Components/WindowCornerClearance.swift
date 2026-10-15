import SwiftUI
import UIKit

/// Makes room at the top of the host window for the screen / window corners. Used in the window root view's `.background`.
///
/// With the status bar moved to a side (the unfolded Duo held sideways or half folded, the cover screen) the
/// window's top safe area is 0 and no safe area covers the top-left rounded corner any more, so pages that
/// lay out their own top bar at "safe line + 8pt" put the title and back button into the corner. Only
/// UIKit's layout region (iOS 26) gives a corner-adapted safe area; SwiftUI's `containerCornerInsets`
/// reports 0 there and a root `safeAreaPadding` does not reach pages inside the NavigationStack, so the
/// difference is written into the window root controller's `additionalSafeAreaInsets.top`, moving every
/// page's top safe line down with it. Sheets are presented separately and are unaffected.
///
/// The added height is reported through `onChange`: the iPad floating tab bar test ("top safe line > 0") must subtract it first.
struct WindowCornerClearance: UIViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = onChange
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.onChange = onChange
    }

    /// The corner-adapted top safe line minus the original one; on an iPhone in portrait and on iPad the status bar already clears the corners, so it is 0.
    nonisolated static func topClearance(safeTop: CGFloat, cornerAdaptedTop: CGFloat) -> CGFloat {
        max(0, cornerAdaptedTop - safeTop)
    }

    final class ProbeView: UIView {
        var onChange: ((CGFloat) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        // Rotation, folding and window resizing all change this view's frame
        override func layoutSubviews() {
            super.layoutSubviews()
            apply()
        }

        private func apply() {
            // It reads the window's own safe area, which the root controller's additionalSafeAreaInsets does not affect, so it cannot feed back on itself
            guard #available(iOS 26, *), let window, let root = window.rootViewController else { return }
            let top = WindowCornerClearance.topClearance(
                safeTop: window.safeAreaInsets.top,
                cornerAdaptedTop: window.edgeInsets(for: .safeArea(cornerAdaptation: .vertical)).top
            )
            guard root.additionalSafeAreaInsets.top != top else { return }
            // Do not change the safe area or SwiftUI state from inside a layout callback; defer to the next main-queue turn
            DispatchQueue.main.async { [weak self] in
                root.additionalSafeAreaInsets.top = top
                self?.onChange?(top)
            }
        }
    }
}

private struct WindowCornerTopClearanceKey: EnvironmentKey {
    static var defaultValue: CGFloat { 0 }
}

extension EnvironmentValues {
    /// The extra top safe area this window adds for its rounded corners (`WindowCornerClearance`).
    var windowCornerTopClearance: CGFloat {
        get { self[WindowCornerTopClearanceKey.self] }
        set { self[WindowCornerTopClearanceKey.self] = newValue }
    }
}
