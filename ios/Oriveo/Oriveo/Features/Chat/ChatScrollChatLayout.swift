import ChatLayout
import UIKit

/// ```swift
///    (keepContentOffsetAtBottomOnBatchUpdates && contentHeight > viewport)
///     context.contentOffsetAdjustment.y += offsetCompensation
/// ```
@MainActor
final class ChatScrollChatLayout: CollectionViewChatLayout {

    var isFollowingProvider: (() -> Bool)?

    var isStreamingProvider: (() -> Bool)?

    private var compStreakItem: Int = -1
    private var compStreakCount: Int = 0

    override func invalidationContext(
        forPreferredLayoutAttributes preferredAttributes: UICollectionViewLayoutAttributes,
        withOriginalAttributes originalAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutInvalidationContext {
        let context = super.invalidationContext(
            forPreferredLayoutAttributes: preferredAttributes,
            withOriginalAttributes: originalAttributes
        )
        let heightDiff = preferredAttributes.size.height - originalAttributes.size.height
        let adjBefore = context.contentOffsetAdjustment.y
        let isFollow = isFollowingProvider?()
        let isStreaming = isStreamingProvider?() ?? false
        let viewportTopY = collectionView?.bounds.origin.y ?? 0
        let cellMinY = originalAttributes.frame.minY
        let cellMaxY = originalAttributes.frame.maxY
        let shouldZero = Self.shouldZeroAdjustment(
            isFollowing: isFollow,
            isStreaming: isStreaming,
            cellMaxY: cellMaxY,
            viewportTopY: viewportTopY
        )
        let shouldCompensate = Self.shouldManuallyCompensate(
            isFollowing: isFollow,
            cellMinY: cellMinY,
            viewportTopY: viewportTopY,
            heightDiff: heightDiff,
            adjustmentFromSuper: adjBefore
        )
        if shouldZero {
            context.contentOffsetAdjustment = .zero
            compStreakItem = -1
            compStreakCount = 0
        } else if shouldCompensate {
            let breaker = Self.compensationBreaker(
                item: preferredAttributes.indexPath.item,
                streakItem: compStreakItem,
                streakCount: compStreakCount,
                maxStreak: Self.maxCompensationStreak
            )
            compStreakItem = breaker.nextItem
            compStreakCount = breaker.nextCount
            if breaker.allow {
                context.contentOffsetAdjustment.y = heightDiff
            }
        } else {
            compStreakItem = -1
            compStreakCount = 0
        }
        ChatRenderDiagnostics.recordLayoutInval(
            idx: preferredAttributes.indexPath.item,
            heightDiff: heightDiff,
            adjBefore: adjBefore,
            wasZeroed: shouldZero,
            isFollow: isFollow
        )
        return context
    }

    nonisolated static func shouldZeroAdjustment(
        isFollowing: Bool?,
        isStreaming: Bool,
        cellMaxY: CGFloat,
        viewportTopY: CGFloat
    ) -> Bool {
        guard isFollowing == false else { return false }
        guard isStreaming else { return false }
        return cellMaxY > viewportTopY
    }

    nonisolated static func shouldManuallyCompensate(
        isFollowing: Bool?,
        cellMinY: CGFloat,
        viewportTopY: CGFloat,
        heightDiff: CGFloat,
        adjustmentFromSuper: CGFloat
    ) -> Bool {
        guard isFollowing == false else { return false }
        guard cellMinY < viewportTopY else { return false }
        guard abs(heightDiff) >= 0.5 else { return false }
        return adjustmentFromSuper == 0
    }

    nonisolated static let maxCompensationStreak = 16

    nonisolated static func compensationBreaker(
        item: Int,
        streakItem: Int,
        streakCount: Int,
        maxStreak: Int
    ) -> (allow: Bool, nextItem: Int, nextCount: Int) {
        let count = (item == streakItem) ? streakCount + 1 : 1
        return (count <= maxStreak, item, count)
    }
}
