import CoreGraphics
import Foundation

@MainActor
protocol ChatStickToBottomGeometry: AnyObject {
    var contentHeight: CGFloat { get }

    var viewportHeight: CGFloat { get }

    var distanceFromBottom: CGFloat { get }

    var anchorTopY: CGFloat? { get }

    var bottomObstruction: CGFloat { get }
}
