import CoreGraphics
import Testing
@testable import Oriveo

@Suite("Chat Scroll Chat Layout Tests")
struct ChatScrollChatLayoutTests {


    @Test("Following True Never Zeros")
    func followingTrueNeverZeros() {
        #expect(ChatScrollChatLayout.shouldZeroAdjustment(
            isFollowing: true, isStreaming: true, cellMaxY: 1800, viewportTopY: 1200
        ) == false)
    }

    @Test("Following Nil Never Zeros")
    func followingNilNeverZeros() {
        #expect(ChatScrollChatLayout.shouldZeroAdjustment(
            isFollowing: nil, isStreaming: true, cellMaxY: 1800, viewportTopY: 1200
        ) == false)
        #expect(ChatScrollChatLayout.shouldZeroAdjustment(
            isFollowing: nil, isStreaming: true, cellMaxY: 800, viewportTopY: 1200
        ) == false)
    }


    @Test("Non Streaming Inside Viewport Keeps Compensation")
    func nonStreamingInsideViewportKeepsCompensation() {
        #expect(ChatScrollChatLayout.shouldZeroAdjustment(
            isFollowing: false, isStreaming: false, cellMaxY: 1800, viewportTopY: 1200
        ) == false)
    }

    @Test("Non Streaming Above Viewport Keeps Compensation")
    func nonStreamingAboveViewportKeepsCompensation() {
        #expect(ChatScrollChatLayout.shouldZeroAdjustment(
            isFollowing: false, isStreaming: false, cellMaxY: 400, viewportTopY: 1200
        ) == false)
    }


    @Test("Streaming Entirely Above Viewport Keeps Adjustment")
    func streamingEntirelyAboveViewportKeepsAdjustment() {
        #expect(ChatScrollChatLayout.shouldZeroAdjustment(
            isFollowing: false, isStreaming: true, cellMaxY: 800, viewportTopY: 1200
        ) == false)
    }

    @Test("Streaming Straddling Viewport Zeros")
    func streamingStraddlingViewportZeros() {
        #expect(ChatScrollChatLayout.shouldZeroAdjustment(
            isFollowing: false, isStreaming: true, cellMaxY: 1400, viewportTopY: 1200
        ) == true)
    }

    @Test("Streaming Inside Or Below Viewport Zeros")
    func streamingInsideOrBelowViewportZeros() {
        #expect(ChatScrollChatLayout.shouldZeroAdjustment(
            isFollowing: false, isStreaming: true, cellMaxY: 1800, viewportTopY: 1200
        ) == true)
        #expect(ChatScrollChatLayout.shouldZeroAdjustment(
            isFollowing: false, isStreaming: true, cellMaxY: 5400, viewportTopY: 1200
        ) == true)
    }


    @Test("Streaming Viewport At Zero")
    func streamingViewportAtZero() {
        #expect(ChatScrollChatLayout.shouldZeroAdjustment(
            isFollowing: false, isStreaming: true, cellMaxY: 200, viewportTopY: 0
        ) == true)
    }

    @Test("Streaming Subpixel Boundary")
    func streamingSubpixelBoundary() {
        #expect(ChatScrollChatLayout.shouldZeroAdjustment(
            isFollowing: false, isStreaming: true, cellMaxY: 1200, viewportTopY: 1200
        ) == false)
        #expect(ChatScrollChatLayout.shouldZeroAdjustment(
            isFollowing: false, isStreaming: true, cellMaxY: 1200.1, viewportTopY: 1200
        ) == true)
    }


    @Test("Manual Compensate On Post Decel Prepend")
    func manualCompensateOnPostDecelPrepend() {
        #expect(ChatScrollChatLayout.shouldManuallyCompensate(
            isFollowing: false, cellMinY: 320, viewportTopY: 1200,
            heightDiff: 120, adjustmentFromSuper: 0
        ) == true)
    }

    @Test("Skip Compensate When Super Already Adjusted")
    func skipCompensateWhenSuperAlreadyAdjusted() {
        #expect(ChatScrollChatLayout.shouldManuallyCompensate(
            isFollowing: false, cellMinY: 320, viewportTopY: 1200,
            heightDiff: 120, adjustmentFromSuper: 120
        ) == false)
    }

    @Test("Skip Compensate When Following")
    func skipCompensateWhenFollowing() {
        #expect(ChatScrollChatLayout.shouldManuallyCompensate(
            isFollowing: true, cellMinY: 320, viewportTopY: 1200,
            heightDiff: 120, adjustmentFromSuper: 0
        ) == false)
    }

    @Test("Skip Compensate When Following Nil")
    func skipCompensateWhenFollowingNil() {
        #expect(ChatScrollChatLayout.shouldManuallyCompensate(
            isFollowing: nil, cellMinY: 320, viewportTopY: 1200,
            heightDiff: 120, adjustmentFromSuper: 0
        ) == false)
    }

    @Test("Skip Compensate When Cell In Viewport")
    func skipCompensateWhenCellInViewport() {
        #expect(ChatScrollChatLayout.shouldManuallyCompensate(
            isFollowing: false, cellMinY: 1200, viewportTopY: 1200,
            heightDiff: 120, adjustmentFromSuper: 0
        ) == false)
        #expect(ChatScrollChatLayout.shouldManuallyCompensate(
            isFollowing: false, cellMinY: 1600, viewportTopY: 1200,
            heightDiff: 120, adjustmentFromSuper: 0
        ) == false)
    }

    @Test("Skip Compensate On Zero Height Diff")
    func skipCompensateOnZeroHeightDiff() {
        #expect(ChatScrollChatLayout.shouldManuallyCompensate(
            isFollowing: false, cellMinY: 320, viewportTopY: 1200,
            heightDiff: 0, adjustmentFromSuper: 0
        ) == false)
    }

    @Test("Compensate On Negative Height Diff")
    func compensateOnNegativeHeightDiff() {
        #expect(ChatScrollChatLayout.shouldManuallyCompensate(
            isFollowing: false, cellMinY: 320, viewportTopY: 1200,
            heightDiff: -50, adjustmentFromSuper: 0
        ) == true)
    }

    @Test("Skip Compensate On Sub Pixel Height Diff")
    func skipCompensateOnSubPixelHeightDiff() {
        #expect(ChatScrollChatLayout.shouldManuallyCompensate(
            isFollowing: false, cellMinY: 320, viewportTopY: 1200,
            heightDiff: 0.3, adjustmentFromSuper: 0
        ) == false)
        #expect(ChatScrollChatLayout.shouldManuallyCompensate(
            isFollowing: false, cellMinY: 320, viewportTopY: 1200,
            heightDiff: -0.4, adjustmentFromSuper: 0
        ) == false)
        #expect(ChatScrollChatLayout.shouldManuallyCompensate(
            isFollowing: false, cellMinY: 320, viewportTopY: 1200,
            heightDiff: 0.5, adjustmentFromSuper: 0
        ) == true)
    }


    @Test("Breaker Allows Within Streak")
    func breakerAllowsWithinStreak() {
        let first = ChatScrollChatLayout.compensationBreaker(
            item: 7, streakItem: -1, streakCount: 0, maxStreak: 16
        )
        #expect(first.allow == true)
        #expect(first.nextItem == 7)
        #expect(first.nextCount == 1)

        let second = ChatScrollChatLayout.compensationBreaker(
            item: 7, streakItem: first.nextItem, streakCount: first.nextCount, maxStreak: 16
        )
        #expect(second.allow == true)
        #expect(second.nextCount == 2)
    }

    @Test("Breaker Trips Beyond Streak")
    func breakerTripsBeyondStreak() {
        var item = 3, streakItem = -1, streakCount = 0
        var lastAllow = true
        for i in 1...17 {
            let r = ChatScrollChatLayout.compensationBreaker(
                item: item, streakItem: streakItem, streakCount: streakCount, maxStreak: 16
            )
            streakItem = r.nextItem
            streakCount = r.nextCount
            lastAllow = r.allow
            if i <= 16 { #expect(r.allow == true) }
        }
        #expect(lastAllow == false)
        _ = item
    }

    @Test("Breaker Resets On Different Item")
    func breakerResetsOnDifferentItem() {
        let onItem5 = ChatScrollChatLayout.compensationBreaker(
            item: 5, streakItem: 5, streakCount: 15, maxStreak: 16
        )
        #expect(onItem5.allow == true)
        #expect(onItem5.nextCount == 16)
        let onItem6 = ChatScrollChatLayout.compensationBreaker(
            item: 6, streakItem: 5, streakCount: 16, maxStreak: 16
        )
        #expect(onItem6.allow == true)
        #expect(onItem6.nextItem == 6)
        #expect(onItem6.nextCount == 1)
    }
}
