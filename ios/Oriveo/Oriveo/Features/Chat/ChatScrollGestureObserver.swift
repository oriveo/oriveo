import UIKit

@MainActor
final class ChatScrollGestureObserver: NSObject, UICollectionViewDelegate {
    private let onUserGrabbed: () -> Void
    private let onSettle: () -> Void
    private let hasMoreAbove: () -> Bool
    private let onRequestExtendUpward: () -> Void
    private let onDidScroll: () -> Void
    /// A cell is about to appear on screen (a reused user bubble anchors its gradient to the current position first, without waiting for the next scroll).
    private let onWillDisplay: (UICollectionViewCell) -> Void

    static let atBottomThreshold: CGFloat = 80
    static let nearTopThreshold: CGFloat = 200
    private var didRequestExtend = false

    init(onUserGrabbed: @escaping () -> Void = {},
         onSettle: @escaping () -> Void,
         hasMoreAbove: @escaping () -> Bool = { false },
         onRequestExtendUpward: @escaping () -> Void = {},
         onDidScroll: @escaping () -> Void = {},
         onWillDisplay: @escaping (UICollectionViewCell) -> Void = { _ in }) {
        self.onUserGrabbed = onUserGrabbed
        self.onSettle = onSettle
        self.hasMoreAbove = hasMoreAbove
        self.onRequestExtendUpward = onRequestExtendUpward
        self.onDidScroll = onDidScroll
        self.onWillDisplay = onWillDisplay
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        onWillDisplay(cell)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let nearTop = scrollView.contentOffset.y < Self.nearTopThreshold
        if nearTop, hasMoreAbove(), !didRequestExtend {
            didRequestExtend = true
            onRequestExtendUpward()
        } else if !nearTop {
            didRequestExtend = false
        }
        ChatRenderDiagnostics.recordScrollTick(
            off: scrollView.contentOffset.y,
            contentH: scrollView.contentSize.height,
            vH: scrollView.bounds.height,
            drag: scrollView.isDragging,
            decel: scrollView.isDecelerating,
            track: scrollView.isTracking
        )
        onDidScroll()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        ChatRenderDiagnostics.recordUserDragBegan(off: scrollView.contentOffset.y)
        onUserGrabbed()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        ChatRenderDiagnostics.recordUserDragEnded(off: scrollView.contentOffset.y, willDecel: decelerate)
        if !decelerate { onSettle() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        ChatRenderDiagnostics.recordUserSettled(off: scrollView.contentOffset.y, distBottom: Self.distance(scrollView))
        onSettle()
    }

    static func distance(_ scrollView: UIScrollView) -> CGFloat {
        let maxOffset = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        return max(0, maxOffset - scrollView.contentOffset.y)
    }
}
