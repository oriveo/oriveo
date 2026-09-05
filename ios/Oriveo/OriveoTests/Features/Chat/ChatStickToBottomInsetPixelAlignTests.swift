import CoreGraphics
import Testing
@testable import Oriveo

/// `ChatStickToBottomController` must pixel-align every inset and offset it writes to a multiple of
/// the display scale.
///
/// The defect: reconcile wrote the raw `desiredBottomInset()` straight into `contentInset.bottom`
/// with a fixed 0.1pt dedup threshold. The reported content height can drift by a fraction of a
/// point when cells self-size, the inset followed that drift, and the accumulated error fired as a
/// sudden sub-point jump - the whole page trembling.
///
/// The fix injects the display scale, aligns the value to a multiple of 1/scale before writing it,
/// and derives the dedup epsilon from the same scale.
@MainActor
@Suite("ChatStickToBottomController - inset pixel-align + scale-aware dedup")
struct ChatStickToBottomInsetPixelAlignTests {

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
        var insetWriteCount = 0
        var offsetWriteCount = 0
    }

    private func makeController(displayScale: CGFloat) -> (ChatStickToBottomController, StubGeometry, Sink) {
        let geo = StubGeometry()
        let sink = Sink()
        let controller = ChatStickToBottomController(
            geometry: geo,
            displayScale: displayScale,
            writeBottomInset: { inset in
                sink.inset = inset
                sink.insetWriteCount += 1
            },
            writeOffset: { y, _ in
                sink.offset = y
                sink.offsetWriteCount += 1
            }
        )
        return (controller, geo, sink)
    }

    // MARK: - displayScale=2.0(@2x)

    @Test("At2x Inset Is Aligned To Half Point")
    func at2xInsetIsAlignedToHalfPoint() {
        let (c, geo, sink) = makeController(displayScale: 2.0)
        geo.anchorTopY = 1000.0
        geo.contentHeight = 1200.37
        geo.viewportHeight = 800.0
        // raw needed = 1000 + 800 - 1200.37 = 599.63 → align @2x = 599.5
        c.reconcile(animated: false)
        let aligned = (sink.inset * 2.0).rounded() / 2.0
        #expect(abs(sink.inset - aligned) < 0.001,
                "inset \(sink.inset) must be a multiple of 0.5pt")
    }

    @Test("At2x Sub Pixel Drift Skipped")
    func at2xSubPixelDriftSkipped() {
        let (c, geo, sink) = makeController(displayScale: 2.0)
        geo.anchorTopY = 1000.0
        geo.contentHeight = 1200.0
        geo.viewportHeight = 800.0
        c.reconcile(animated: false)
        let baseline = sink.insetWriteCount

        geo.contentHeight = 1200.1
        c.reconcile(animated: false)
        #expect(sink.insetWriteCount == baseline,
                "a 0.1pt drift lands in the same aligned bucket and must not be written")
    }

    @Test("At2x Cross Pixel Boundary Writes")
    func at2xCrossPixelBoundaryWrites() {
        let (c, geo, sink) = makeController(displayScale: 2.0)
        geo.anchorTopY = 1000.0
        geo.contentHeight = 1200.0
        geo.viewportHeight = 800.0
        c.reconcile(animated: false)
        let baseline = sink.insetWriteCount

        geo.contentHeight = 1201.0
        c.reconcile(animated: false)
        #expect(sink.insetWriteCount == baseline + 1)
    }

    // MARK: - displayScale=3.0(@3x,iPhone Pro)

    @Test("At3x Inset Is Aligned To One Third Point")
    func at3xInsetIsAlignedToOneThirdPoint() {
        let (c, geo, sink) = makeController(displayScale: 3.0)
        geo.anchorTopY = 1000.0
        geo.contentHeight = 1200.27
        geo.viewportHeight = 800.0
        c.reconcile(animated: false)
        let aligned = (sink.inset * 3.0).rounded() / 3.0
        #expect(abs(sink.inset - aligned) < 0.001)
    }

    @Test("At3x Sub Pixel Drift Skipped")
    func at3xSubPixelDriftSkipped() {
        let (c, geo, sink) = makeController(displayScale: 3.0)
        geo.anchorTopY = 1000.0
        geo.contentHeight = 1200.0
        geo.viewportHeight = 800.0
        c.reconcile(animated: false)
        let baseline = sink.insetWriteCount

        geo.contentHeight = 1200.05
        c.reconcile(animated: false)
        #expect(sink.insetWriteCount == baseline)
    }

    @Test("At3x Accumulated Sub Pixel Drift Across Frames Still Skipped")
    func at3xAccumulatedSubPixelDriftAcrossFramesStillSkipped() {
        let (c, geo, sink) = makeController(displayScale: 3.0)
        geo.anchorTopY = 1000.0
        geo.contentHeight = 1200.0
        geo.viewportHeight = 800.0
        c.reconcile(animated: false)
        let baseline = sink.insetWriteCount

        for i in 1...5 {
            geo.contentHeight = 1200.0 + 0.03 * CGFloat(i)
            c.reconcile(animated: false)
        }
        #expect(sink.insetWriteCount == baseline,
                "0.15pt of drift accumulated over five frames still lands in the same aligned bucket, so nothing may be written - the baseline must be refreshed rather than compared against a stale value")
    }

    @Test("At3x Offset Aligned To Third Point")
    func at3xOffsetAlignedToThirdPoint() {
        let (c, geo, sink) = makeController(displayScale: 3.0)
        geo.anchorTopY = 1000.0
        geo.contentHeight = 1200.27
        geo.viewportHeight = 800.0
        c.reconcile(animated: false)
        let alignedOff = (sink.offset * 3.0).rounded() / 3.0
        #expect(abs(sink.offset - alignedOff) < 0.001)
    }


    @Test("Display Scale1 Is Pass Through For Legacy Tests")
    func displayScale1IsPassThroughForLegacyTests() {
        let (c, geo, sink) = makeController(displayScale: 1.0)
        geo.anchorTopY = 1000.0
        geo.contentHeight = 3000.0
        geo.viewportHeight = 800.0
        c.reconcile(animated: false)
        let baseline = sink.offsetWriteCount

        geo.contentHeight = 3000.05
        c.reconcile(animated: false)
        #expect(sink.offsetWriteCount == baseline)

        geo.contentHeight = 3000.2
        c.reconcile(animated: false)
        #expect(sink.offsetWriteCount == baseline + 1)
    }


    @Test("At3x Pin To Anchor Aligned")
    func at3xPinToAnchorAligned() {
        let (c, geo, sink) = makeController(displayScale: 3.0)
        geo.anchorTopY = 1000.0
        geo.contentHeight = 1200.27
        geo.viewportHeight = 800.0
        c.pinToAnchor(animated: true)
        let alignedInset = (sink.inset * 3.0).rounded() / 3.0
        let alignedOff = (sink.offset * 3.0).rounded() / 3.0
        #expect(abs(sink.inset - alignedInset) < 0.001)
        #expect(abs(sink.offset - alignedOff) < 0.001)
    }

    @Test("At3x Reset Aligned")
    func at3xResetAligned() {
        let (c, _, sink) = makeController(displayScale: 3.0)
        c.reset()
        let aligned = (sink.inset * 3.0).rounded() / 3.0
        #expect(abs(sink.inset - aligned) < 0.001)
    }
}
