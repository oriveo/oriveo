import CoreGraphics
import Testing
@testable import Oriveo

@MainActor
@Suite("ChatStickToBottomController")
struct ChatStickToBottomControllerTests {

    final class StubGeometry: ChatStickToBottomGeometry {
        var contentHeight: CGFloat = 0
        var viewportHeight: CGFloat = 800
        var distanceFromBottom: CGFloat = 0
        var anchorTopY: CGFloat?
        var bottomObstruction: CGFloat = 0
    }

    final class Sink {
        var inset: CGFloat = 0
        var offset: CGFloat = 0
        var animated = false
        var offsetWriteCount = 0
    }

    private func makeController(
        hasContent: @escaping () -> Bool = { true }
    ) -> (ChatStickToBottomController, StubGeometry, Sink) {
        let geo = StubGeometry()
        let sink = Sink()
        let controller = ChatStickToBottomController(
            geometry: geo,
            hasStreamingContent: hasContent,
            writeBottomInset: { sink.inset = $0 },
            writeOffset: { y, animated in
                sink.offset = y
                sink.animated = animated
                sink.offsetWriteCount += 1
            }
        )
        return (controller, geo, sink)
    }


    @Test("Short Answer Inset Pads Exactly To Anchor")
    func shortAnswerInsetPadsExactlyToAnchor() {
        let (c, geo, _) = makeController()
        geo.anchorTopY = 1000
        geo.contentHeight = 1200
        geo.viewportHeight = 800
        let inset = c.desiredBottomInset()        // = max(8, 1000+800-1200) = 600
        #expect(inset == 600)
        #expect(c.maxOffset(bottomInset: inset) == 1000)
    }

    @Test("Long Answer Inset Clamps To Min Padding")
    func longAnswerInsetClampsToMinPadding() {
        let (c, geo, _) = makeController()
        geo.anchorTopY = 1000
        geo.contentHeight = 3000
        geo.viewportHeight = 800
        let inset = c.desiredBottomInset()        // = max(8, 1000+800-3000=-1200) = 8
        #expect(inset == 8)
        #expect(c.maxOffset(bottomInset: inset) == 2208)
    }

    @Test("No Anchor Returns Min Padding")
    func noAnchorReturnsMinPadding() {
        let (c, geo, _) = makeController()
        geo.anchorTopY = nil
        geo.contentHeight = 2000
        geo.viewportHeight = 800
        #expect(c.desiredBottomInset() == ChatStickToBottomController.minBottomPadding)
    }

    // MARK: - reconcile / follow-to-max

    @Test("Reconcile While Following Writes Max Offset")
    func reconcileWhileFollowingWritesMaxOffset() {
        let (c, geo, sink) = makeController()
        geo.anchorTopY = 1000
        geo.contentHeight = 1200
        geo.viewportHeight = 800
        c.reconcile(animated: false)
        #expect(sink.inset == 600)
        #expect(sink.offset == 1000)
        #expect(sink.animated == false)
        #expect(sink.offsetWriteCount == 1)
    }

    @Test("Settle Above Threshold Pauses Follow")
    func settleAboveThresholdPausesFollow() {
        let (c, geo, sink) = makeController()
        geo.anchorTopY = 1000
        geo.contentHeight = 1200
        geo.viewportHeight = 800
        geo.distanceFromBottom = 300          // > atBottomThreshold(80)
        c.settle()
        #expect(c.isFollowing == false)

        c.reconcile(animated: false)
        #expect(sink.inset == 600)
        #expect(sink.offsetWriteCount == 0)
    }

    @Test("Settle Below Threshold Resumes Follow")
    func settleBelowThresholdResumesFollow() {
        let (c, geo, _) = makeController()
        geo.distanceFromBottom = 10           // < atBottomThreshold
        c.settle()
        #expect(c.isFollowing == true)
    }

    @Test("Resume Following Forces Follow And Lands")
    func resumeFollowingForcesFollowAndLands() {
        let (c, geo, sink) = makeController()
        geo.anchorTopY = 1000
        geo.contentHeight = 1200
        geo.viewportHeight = 800
        geo.distanceFromBottom = 300
        c.settle()
        #expect(c.isFollowing == false)

        c.resumeFollowing(animated: true)
        #expect(c.isFollowing == true)
        #expect(sink.offsetWriteCount == 1)
        #expect(sink.offset == 1000)
        #expect(sink.animated == true)
    }

    @Test("Reset Returns To Following")
    func resetReturnsToFollowing() {
        let (c, geo, _) = makeController()
        geo.distanceFromBottom = 300
        c.settle()
        #expect(c.isFollowing == false)

        c.reset()
        #expect(c.isFollowing == true)
    }


    @Test("User Did Grab Stops Following")
    func userDidGrabStopsFollowing() {
        let (c, _, _) = makeController()
        #expect(c.isFollowing == true)
        c.userDidGrab()
        #expect(c.isFollowing == false)
    }

    @Test("User Did Grab Prevents Offset Write")
    func userDidGrabPreventsOffsetWrite() {
        let (c, geo, sink) = makeController()
        geo.anchorTopY = 1000
        geo.contentHeight = 1200
        geo.viewportHeight = 800
        c.reconcile(animated: false)
        let writeCountBefore = sink.offsetWriteCount

        c.userDidGrab()
        geo.contentHeight = 1500
        c.reconcile(animated: false)
        c.reconcile(animated: false)
        #expect(sink.offsetWriteCount == writeCountBefore, "reconcile still wrote an offset after the user grabbed the list, fighting the finger")
    }

    @Test("Reconcile Inset Only Never Writes Offset Even While Following")
    func reconcileInsetOnlyNeverWritesOffsetEvenWhileFollowing() {
        let (c, geo, sink) = makeController()
        geo.anchorTopY = 1000
        geo.contentHeight = 1200
        geo.viewportHeight = 800
        #expect(c.isFollowing == true)
        c.reconcileInsetOnly()
        #expect(sink.inset == 600, "the reconcile must still recompute the inset so no draggable slack is left")
        #expect(sink.offsetWriteCount == 0, "a quiescent reconcile wrote an offset and pinned the reading position back to the bottom")

        geo.contentHeight = 1500
        c.reconcileInsetOnly()
        #expect(sink.inset == 300)
        #expect(sink.offsetWriteCount == 0)
    }

    @Test("Reconcile Skips Sub Pixel Rewrites")
    func reconcileSkipsSubPixelRewrites() {
        let (c, geo, sink) = makeController()
        geo.anchorTopY = 1000
        geo.contentHeight = 1200
        geo.viewportHeight = 800

        c.reconcile(animated: false)
        #expect(sink.offsetWriteCount == 1)
        for _ in 0..<5 { c.reconcile(animated: false) }
        #expect(sink.offsetWriteCount == 1, "rewriting the same max offset triggers another observation and jitters the text by a fraction of a point")
    }

    @Test("Reconcile Writes When Delta Exceeds Sub Pixel")
    func reconcileWritesWhenDeltaExceedsSubPixel() {
        let (c, geo, sink) = makeController()
        geo.anchorTopY = 1000
        geo.contentHeight = 3000
        geo.viewportHeight = 800

        c.reconcile(animated: false)
        let baseline = sink.offsetWriteCount

        geo.contentHeight = 3000.05
        c.reconcile(animated: false)
        #expect(sink.offsetWriteCount == baseline)

        geo.contentHeight = 3000.2
        c.reconcile(animated: false)
        #expect(sink.offsetWriteCount == baseline + 1)
    }

    @Test("Resume Following Always Writes")
    func resumeFollowingAlwaysWrites() {
        let (c, geo, sink) = makeController()
        geo.anchorTopY = 1000
        geo.contentHeight = 1200
        geo.viewportHeight = 800
        c.reconcile(animated: false)
        let baseline = sink.offsetWriteCount

        c.resumeFollowing(animated: true)
        #expect(sink.offsetWriteCount == baseline + 1)
        #expect(sink.animated == true)
    }


    @Test("Bottom Obstruction Extends Inset")
    func bottomObstructionExtendsInset() {
        let (c, geo, sink) = makeController()
        geo.anchorTopY = 1000
        geo.contentHeight = 3000
        geo.viewportHeight = 700
        geo.bottomObstruction = 100

        c.reconcile(animated: false)
        #expect(sink.inset == 108)
    }

    @Test("Short Answer Inset Includes Obstruction")
    func shortAnswerInsetIncludesObstruction() {
        let (c, geo, sink) = makeController()
        geo.anchorTopY = 1000
        geo.contentHeight = 1200
        geo.viewportHeight = 700
        geo.bottomObstruction = 100

        c.reconcile(animated: false)
        // baseline needed = 1000 + 700 - 1200 = 500;+ obstruction 100 = 600
        #expect(sink.inset == 600)
        #expect(sink.offset == 1100)
    }

    @Test("Invalidate Offset Baseline Forces Write")
    func invalidateOffsetBaselineForcesWrite() {
        let (c, geo, sink) = makeController()
        geo.anchorTopY = 1000
        geo.contentHeight = 1200
        geo.viewportHeight = 800
        c.reconcile(animated: false)
        let baseline = sink.offsetWriteCount

        c.reconcile(animated: false)
        #expect(sink.offsetWriteCount == baseline)

        c.invalidateOffsetBaseline()
        c.reconcile(animated: false)
        #expect(sink.offsetWriteCount == baseline + 1)
    }

    @Test("Viewport Shrink Near Bottom Resumes Following And Lands")
    func viewportShrinkNearBottomResumesFollowingAndLands() {
        let (c, geo, sink) = makeController()
        geo.anchorTopY = nil
        geo.contentHeight = 1800
        geo.viewportHeight = 800

        c.reconcile(animated: false)
        #expect(sink.offset == 1008)

        c.userDidGrab()
        geo.distanceFromBottom = 32
        geo.viewportHeight = 500
        geo.bottomObstruction = 300

        c.reconcileForViewportChange(animated: false)

        #expect(c.isFollowing == true)
        #expect(sink.inset == 308)
        #expect(sink.offset == 1608)
        #expect(sink.offsetWriteCount == 2)
    }

    @Test("Viewport Grow Near Bottom Resumes Following And Lands")
    func viewportGrowNearBottomResumesFollowingAndLands() {
        let (c, geo, sink) = makeController()
        geo.anchorTopY = nil
        geo.contentHeight = 1800
        geo.viewportHeight = 500
        geo.bottomObstruction = 300

        c.reconcile(animated: false)
        #expect(sink.offset == 1608)

        c.userDidGrab()
        geo.distanceFromBottom = 24
        geo.viewportHeight = 800
        geo.bottomObstruction = 0

        c.reconcileForViewportChange(animated: false)

        #expect(c.isFollowing == true)
        #expect(sink.inset == ChatStickToBottomController.minBottomPadding)
        #expect(sink.offset == 1008)
        #expect(sink.offsetWriteCount == 2)
    }

    @Test("Viewport Shrink Away From Bottom Keeps Detached")
    func viewportShrinkAwayFromBottomKeepsDetached() {
        let (c, geo, sink) = makeController()
        geo.anchorTopY = nil
        geo.contentHeight = 1800
        geo.viewportHeight = 800

        c.reconcile(animated: false)
        let baseline = sink.offsetWriteCount

        c.userDidGrab()
        geo.distanceFromBottom = 260
        geo.viewportHeight = 500
        geo.bottomObstruction = 300

        c.reconcileForViewportChange(animated: false)

        #expect(c.isFollowing == false)
        #expect(sink.inset == 308)
        #expect(sink.offsetWriteCount == baseline)
    }


    @Test("Streaming Mode Stops Following")
    func streamingModeStopsFollowing() {
        let (c, _, _) = makeController()
        #expect(c.isFollowing == true)
        c.setStreamingMode(true)
        #expect(c.isStreamingMode == true)
        #expect(c.isFollowing == false)
    }

    @Test("Settle During Streaming Does Not Resume Follow")
    func settleDuringStreamingDoesNotResumeFollow() {
        let (c, geo, _) = makeController()
        c.setStreamingMode(true)
        geo.distanceFromBottom = 0
        c.settle()
        #expect(c.isFollowing == false, "even at the bottom, streaming must not follow automatically; the viewport belongs to the user")
    }


    @Test("Streaming Inset Includes Runway")
    func streamingInsetIncludesRunway() {
        let (c, geo, sink) = makeController()
        geo.anchorTopY = 1000
        geo.contentHeight = 3000
        geo.viewportHeight = 800
        c.reconcile(animated: false)
        #expect(sink.inset == 8, "no runway outside streaming")

        c.setStreamingMode(true)
        c.reconcile(animated: false)
        #expect(sink.inset == 8 + 800 * 0.75, "while streaming the inset is the base plus the waiting area, so the user can scroll ahead of the rendering")

        c.setStreamingMode(false)
        c.reconcile(animated: false)
        #expect(sink.inset == 8, "the runway is taken back when streaming ends")
    }

    @Test("Pin To Anchor During Streaming Does Not Overshoot")
    func pinToAnchorDuringStreamingDoesNotOvershoot() {
        let (c, geo, sink) = makeController()
        geo.anchorTopY = 1000
        geo.contentHeight = 1200
        geo.viewportHeight = 800
        c.setStreamingMode(true)
        c.pinToAnchor(animated: true)
        #expect(sink.inset == 600 + 800 * 0.75, "bottom padding plus the waiting area")
        #expect(sink.offset == 1000, "the landing offset uses the base measure and must equal the anchor top; the runway may not pollute the pinning arithmetic")
    }

    @Test("Streaming Runway Value")
    func streamingRunwayValue() {
        let (c, geo, _) = makeController()
        geo.viewportHeight = 800
        #expect(c.streamingRunway() == 0, "no waiting area outside streaming")
        c.setStreamingMode(true)
        #expect(c.streamingRunway() == 0, "nothing has been written the instant streaming starts, so the runway is still zero until the first reconcile")
        c.reconcile(animated: false)
        #expect(c.streamingRunway() == 600, "after the reconcile writes, the runway is a constant 0.75 viewports")
    }

    @Test("Reconcile During Streaming Writes Inset Only")
    func reconcileDuringStreamingWritesInsetOnly() {
        let (c, geo, sink) = makeController()
        geo.anchorTopY = 1000
        geo.contentHeight = 1200
        geo.viewportHeight = 800
        c.setStreamingMode(true)
        c.reconcile(animated: false)
        #expect(sink.inset == 600 + 800 * 0.75)
        #expect(sink.offsetWriteCount == 0)
    }


    @Test("Runway Constant While Streaming Regardless Of Backlog")
    func runwayConstantWhileStreamingRegardlessOfBacklog() {
        let (c, geo, sink) = makeController()
        geo.anchorTopY = 1000
        geo.contentHeight = 1200
        geo.viewportHeight = 800
        c.setStreamingMode(true)
        c.reconcile(animated: false)
        #expect(c.streamingRunway() == 600, "content is on screen, so the waiting area is at its constant size")
        #expect(sink.inset == 600 + 800 * 0.75, "bottom padding plus the constant waiting area")
        geo.distanceFromBottom = 200
        c.reconcile(animated: false)
        #expect(c.streamingRunway() == 600, "the waiting area stays constant while generating; it does not shrink with distance or progress")
    }

    @Test("Runway Opens On First Content And Ratchets")
    func runwayOpensOnFirstContentAndRatchets() {
        var hasContent = false
        let (c, geo, sink) = makeController(hasContent: { hasContent })
        geo.viewportHeight = 800
        c.setStreamingMode(true)
        c.reconcile(animated: false)
        #expect(c.streamingRunway() == 0, "while waiting for the first token there is nothing to scroll to, so no draggable empty space is created")
        #expect(sink.inset == 8, "only the minimum padding, so the list is fully scrolled")
        hasContent = true
        c.reconcile(animated: false)
        #expect(c.streamingRunway() == 600, "the first block of content on screen opens the constant waiting area")
        hasContent = false
        c.reconcile(animated: false)
        #expect(c.streamingRunway() == 600, "it ratchets within a round: a flickering signal must not pull the space out from under the user")
        c.setStreamingMode(false)
        #expect(c.streamingRunway() == 0)
        c.setStreamingMode(true)
        c.reconcile(animated: false)
        #expect(c.streamingRunway() == 0, "a new round waits for the gate again")
    }

    @Test("Runway Clears On Mode Transitions And Reset")
    func runwayClearsOnModeTransitionsAndReset() {
        let (c, geo, _) = makeController()
        geo.viewportHeight = 800
        c.setStreamingMode(true)
        c.reconcile(animated: false)
        #expect(c.streamingRunway() == 600)
        c.setStreamingMode(false)
        #expect(c.streamingRunway() == 0, "it drops to zero as soon as streaming ends; the real inset is taken back by the settle window")
        c.setStreamingMode(true)
        #expect(c.streamingRunway() == 0, "nothing has been written the instant streaming starts; the first reconcile opens it")
        c.reconcile(animated: false)
        #expect(c.streamingRunway() == 600)
        c.reset()
        #expect(c.streamingRunway() == 0)
    }

    @Test("Streaming End Near Bottom Resumes Follow")
    func streamingEndNearBottomResumesFollow() {
        let (c, geo, _) = makeController()
        c.setStreamingMode(true)
        geo.distanceFromBottom = 10
        c.setStreamingMode(false)
        #expect(c.isStreamingMode == false)
        #expect(c.isFollowing == true)
    }

    @Test("Streaming End Inside Runway Resumes Follow")
    func streamingEndInsideRunwayResumesFollow() {
        let (c, geo, _) = makeController()
        geo.viewportHeight = 800
        c.setStreamingMode(true)
        c.reconcile(animated: false)
        geo.distanceFromBottom = 300
        c.setStreamingMode(false)
        #expect(c.isFollowing == true, "a user who was waiting must be converged onto the real bottom of the content when streaming ends")
    }

    @Test("Streaming End Away From Bottom Stays Detached")
    func streamingEndAwayFromBottomStaysDetached() {
        let (c, geo, _) = makeController()
        geo.viewportHeight = 800
        c.setStreamingMode(true)
        c.reconcile(animated: false)
        geo.distanceFromBottom = 900
        c.setStreamingMode(false)
        #expect(c.isFollowing == false)
    }

    @Test("Pin To Anchor Short Content Pins To Top")
    func pinToAnchorShortContentPinsToTop() {
        let (c, geo, sink) = makeController()
        geo.anchorTopY = 1000
        geo.contentHeight = 1200
        geo.viewportHeight = 800
        c.pinToAnchor(animated: true)
        #expect(sink.inset == 600)
        #expect(sink.offset == 1000)
        #expect(sink.animated == true)
        #expect(sink.offsetWriteCount == 1)
    }

    @Test("Pin To Anchor Long Content Lands At Max")
    func pinToAnchorLongContentLandsAtMax() {
        let (c, geo, sink) = makeController()
        geo.anchorTopY = 1000
        geo.contentHeight = 3000
        geo.viewportHeight = 800
        c.pinToAnchor(animated: true)
        #expect(sink.inset == ChatStickToBottomController.minBottomPadding)
        #expect(sink.offset == 2208)         // = 3000 + 8 - 800
    }

    @Test("Reset Clears Streaming Mode")
    func resetClearsStreamingMode() {
        let (c, _, _) = makeController()
        c.setStreamingMode(true)
        c.reset()
        #expect(c.isStreamingMode == false)
        #expect(c.isFollowing == true)
    }

    @Test("Reset Writes Min Padding Inset")
    func resetWritesMinPaddingInset() {
        let (c, geo, sink) = makeController()
        geo.anchorTopY = 1000
        geo.contentHeight = 1200
        geo.viewportHeight = 800
        c.reconcile(animated: false)
        #expect(sink.inset == 600)
        c.reset()
        #expect(sink.inset == ChatStickToBottomController.minBottomPadding)
    }

    @Test("Composer Focus Requests Reveal Only When At Bottom")
    func composerFocusRequestsRevealOnlyWhenAtBottom() {
        #expect(ChatMessageList.shouldRevealLatestWhenComposerFocuses(
            oldFocused: false,
            newFocused: true,
            isAtBottom: true,
            hasMessages: true,
            hasMoreBelow: false
        ))
        #expect(!ChatMessageList.shouldRevealLatestWhenComposerFocuses(
            oldFocused: false,
            newFocused: true,
            isAtBottom: false,
            hasMessages: true,
            hasMoreBelow: false
        ))
        #expect(!ChatMessageList.shouldRevealLatestWhenComposerFocuses(
            oldFocused: false,
            newFocused: true,
            isAtBottom: true,
            hasMessages: false,
            hasMoreBelow: false
        ))
        #expect(!ChatMessageList.shouldRevealLatestWhenComposerFocuses(
            oldFocused: true,
            newFocused: true,
            isAtBottom: true,
            hasMessages: true,
            hasMoreBelow: false
        ))
        #expect(!ChatMessageList.shouldRevealLatestWhenComposerFocuses(
            oldFocused: false,
            newFocused: true,
            isAtBottom: true,
            hasMessages: true,
            hasMoreBelow: true
        ))
    }
}
