import CoreGraphics
import Testing
@testable import Oriveo

@MainActor
@Suite("Assistant Streaming Height Floor Tests")
struct AssistantStreamingHeightFloorTests {

    @Test("Grows With Natural Height")
    func growsWithNaturalHeight() {
        var floor: CGFloat = 0
        floor = AssistantMessageCell.nextStreamingHeightFloor(natural: 100, current: floor, streaming: true)
        #expect(floor == 100)
        floor = AssistantMessageCell.nextStreamingHeightFloor(natural: 160, current: floor, streaming: true)
        #expect(floor == 160)
    }

    @Test("Holds Floor When Natural Shrinks")
    func holdsFloorWhenNaturalShrinks() {
        var floor: CGFloat = 160
        floor = AssistantMessageCell.nextStreamingHeightFloor(natural: 136, current: floor, streaming: true)
        #expect(floor == 160)
        floor = AssistantMessageCell.nextStreamingHeightFloor(natural: 200, current: floor, streaming: true)
        #expect(floor == 200)
    }

    @Test("Releases When Not Streaming")
    func releasesWhenNotStreaming() {
        let floor = AssistantMessageCell.nextStreamingHeightFloor(natural: 136, current: 200, streaming: false)
        #expect(floor == 0)
    }

    @Test("Starts From Zero")
    func startsFromZero() {
        let floor = AssistantMessageCell.nextStreamingHeightFloor(natural: 80, current: 0, streaming: true)
        #expect(floor == 80)
    }

    @Test("Defers Streaming Invalidate Only While Scrolling Far From Bottom")
    func defersStreamingInvalidateOnlyWhileScrollingFarFromBottom() {
        #expect(AssistantMessageCell.shouldDeferStreamingInvalidate(isStreamingActive: true, isScrolling: true, isNearBottom: false))
        #expect(!AssistantMessageCell.shouldDeferStreamingInvalidate(isStreamingActive: true, isScrolling: true, isNearBottom: true))
        #expect(!AssistantMessageCell.shouldDeferStreamingInvalidate(isStreamingActive: true, isScrolling: false, isNearBottom: false))
        #expect(!AssistantMessageCell.shouldDeferStreamingInvalidate(isStreamingActive: false, isScrolling: true, isNearBottom: false))
        #expect(!AssistantMessageCell.shouldDeferStreamingInvalidate(isStreamingActive: false, isScrolling: false, isNearBottom: true))
    }

    @Test("Throttles Streaming Invalidate Under Min Interval")
    func throttlesStreamingInvalidateUnderMinInterval() {
        #expect(!AssistantMessageCell.shouldThrottleStreamingInvalidate(isStreamingActive: false, now: 100, lastInvalidate: 99.99))
        #expect(!AssistantMessageCell.shouldThrottleStreamingInvalidate(isStreamingActive: true, now: 100, lastInvalidate: 0))
        #expect(AssistantMessageCell.shouldThrottleStreamingInvalidate(isStreamingActive: true, now: 100.05, lastInvalidate: 100.0))
        #expect(AssistantMessageCell.shouldThrottleStreamingInvalidate(isStreamingActive: true, now: 100.066, lastInvalidate: 100.0))
        #expect(!AssistantMessageCell.shouldThrottleStreamingInvalidate(isStreamingActive: true, now: 100.068, lastInvalidate: 100.0))
        #expect(!AssistantMessageCell.shouldThrottleStreamingInvalidate(isStreamingActive: true, now: 100.1, lastInvalidate: 100.0))
    }
}
