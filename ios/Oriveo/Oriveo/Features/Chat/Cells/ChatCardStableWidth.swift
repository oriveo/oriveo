import UIKit

enum ChatCardStableWidth {

    static let contentChrome: CGFloat = 48

    static let tolerance: CGFloat = 2.0

    static func anchor(for view: UIView) -> CGFloat? {
        var cursor: UIView? = view.superview
        while let candidate = cursor {
            if let collectionView = candidate as? UICollectionView {
                return collectionView.bounds.width - contentChrome
            }
            cursor = candidate.superview
        }
        return nil
    }

    static func isTrustworthy(width: CGFloat, anchor: CGFloat?) -> Bool {
        guard let anchor, anchor > 0 else { return true }
        return abs(width - anchor) <= tolerance
    }
}
