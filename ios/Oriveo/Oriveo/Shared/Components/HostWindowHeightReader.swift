import SwiftUI
import UIKit

/// Reports the height of the hosting window (not the whole screen); use it inside `.background`.
///
/// On the Duo cover screen or a resized iPad window the window height is not the screen height,
/// so caps computed from `UIScreen.main` overflow the window. A popover's or sheet's own container
/// height follows its content, so measuring it would shrink it in a loop; this measures the host
/// window instead. It works the same for SwiftUI views hosted in UIKit cells. It does not call back
/// before the view is in a window; callers bring their own fallback.
struct HostWindowHeightReader: UIViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: ReaderView, context: Context) {
        uiView.onChange = onChange
    }

    final class ReaderView: UIView {
        var onChange: ((CGFloat) -> Void)?
        private var reportedHeight: CGFloat?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        private func report() {
            guard let height = window?.bounds.height, height > 0, height != reportedHeight else { return }
            reportedHeight = height
            // Do not mutate SwiftUI state inside a layout callback; defer to the next main-queue turn.
            DispatchQueue.main.async { [weak self] in
                self?.onChange?(height)
            }
        }
    }
}
