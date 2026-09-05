import Combine
import Testing
import UIKit
@testable import Oriveo

/// Integration tests for the prepend path with a real collection view and real self-sizing cells.
///
/// Contract: the reading position is preserved. When scrolling back through history triggers a
/// prepend, what the user is looking at stays visually still - the viewport does not jump - and the
/// newly loaded history quietly extends above it so they can keep scrolling up. The implementation
/// relocates the anchor across batches by stable message id rather than by index path, which changes
/// after a prepend, and it has to pass a geometry consistency barrier before and after the batch
/// before the layout restores the anchor.
///
/// The unit layer already pins the pure decision matrix for the adjustment functions; this file
/// verifies the end-to-end behaviour with a real view stack in a window.
///
/// Cases:
/// 1. after a prepend the previous reading position stays still, and self-sizing rebound does not
///    push it away;
/// 2. a prepend while streaming: the trailing streaming cell is not tugged back and forth, and the
///    reading position stays still;
/// 3. three prepends in a row: the reading position is preserved each time with no accumulated
///    drift;
/// 4. a prepend in the same runloop turn as a large outline jump: no crash, and the jump target
///    stays pinned to the top;
/// 5. an outline jump during the scroll-to-bottom settle: the jump takes over;
/// 6. returning to the foreground with a changed offset while the visible cells still carry the old
///    geometry: no crash and the reading position is preserved;
/// 7. the geometry barrier itself, as a pure function: it compares positions, not empty rects;
/// 8. the full-reload recovery taken when the barrier really does find an inconsistency: the reading
///    position still holds.
///
/// Self-sizing rebounds asynchronously, so sub-pixel drift is normal; the tolerance is 6pt.
@Suite("Prepend integration")
@MainActor
struct ChatPrependIntegrationTests {
    private static let width: CGFloat = 390
    private static let viewport: CGFloat = 844
    private static let anchorTolerance: CGFloat = 6.0
    private static let streamingEndDistTolerance: CGFloat = 4.0
    private static let cumulativeAnchorTolerance: CGFloat = 12.0
    private static let recoveryAnchorTolerance: CGFloat = 24.0
    private static let additionalInsetTop: CGFloat = 16.0

    private func makeUser(_ text: String, id: UUID = UUID()) -> ChatMessage {
        ChatMessage(id: id, role: .user, text: text, reasoningText: nil,
                    providerKind: .openAI, providerName: "OpenAI", modelName: "GPT-4o",
                    estimatedCost: 0, state: .delivered, attachments: nil, citations: nil)
    }

    private func makeAssistant(_ text: String, id: UUID = UUID()) -> ChatMessage {
        ChatMessage(id: id, role: .assistant, text: text, reasoningText: nil,
                    providerKind: .openAI, providerName: "OpenAI", modelName: "GPT-4o",
                    estimatedCost: 0, state: .delivered, attachments: nil, citations: nil)
    }

    private func makeController() -> (ChatListViewController, UIWindow) {
        let vc = ChatListViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: Self.width, height: Self.viewport))
        window.rootViewController = vc
        window.makeKeyAndVisible()
        vc._testCompleteInitialAppearance()
        vc.view.layoutIfNeeded()
        return (vc, window)
    }

    private func runLoop(seconds: TimeInterval, _ vc: ChatListViewController) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            vc.view.layoutIfNeeded()
        }
    }

    private func update(
        _ vc: ChatListViewController,
        convID: UUID,
        revision: UInt,
        messages: [ChatMessage],
        streamingID: UUID? = nil,
        streamingText: String = "",
        hasMoreAbove: Bool = false
    ) {
        let vm = ChatCollectionViewModel(
            conversationID: convID, messageRevision: revision,
            rows: ChatCollectionProjectionBuilder.makeRows(from: messages, metadata: .empty),
            isSendingMessage: false, streamingMessageID: streamingID, streamingText: streamingText,
            pendingAnchorUserMessageID: nil, pendingSearchScrollTarget: nil,
            isBootstrappingPersistedConversation: false,
            retryCapabilitySelection: ChatCapabilitySelection())
        vc.update(
            viewModel: vm, providerMetadataVersion: 0,
            streamingPublisher: Empty<Void, Never>().eraseToAnyPublisher(),
            streamingReasoningPublisher: Empty<ReasoningStreamDelta, Never>().eraseToAnyPublisher(),
            streamingTextProvider: { streamingText }, streamingReasoningSnapshotProvider: { nil },
            onRetry: { _ in }, onContinue: { _ in }, onRegenerate: { _ in },
            onEditMessage: { _ in }, onSwitchModel: {},
            pendingAnchorUserMessageID: nil, onAnchorUserMessageConsumed: { _ in },
            hasMoreAbove: hasMoreAbove)
        vc.view.layoutIfNeeded()
    }

    private func makePairedMessages(count pairCount: Int, prefix: String) -> [ChatMessage] {
        var msgs: [ChatMessage] = []
        for i in 0..<pairCount {
            msgs.append(makeUser("\(prefix)Q-\(i) a question that wraps to two lines for self-size."))
            msgs.append(makeAssistant("\(prefix)A-\(i) an answer that spans multiple lines so the cell needs real self-sizing to settle properly."))
        }
        return msgs
    }


    @Test("Prepend60 Keeps Original Anchor Visually Static")
    func prepend60KeepsOriginalAnchorVisuallyStatic() {
        let (vc, window) = makeController()
        defer { window.isHidden = true }
        let convID = UUID()

        let initial = makePairedMessages(count: 30, prefix: "")
        update(vc, convID: convID, revision: 1, messages: initial, hasMoreAbove: true)
        runLoop(seconds: 1.0, vc)
        vc._testSetContentOffset(0)
        vc.view.layoutIfNeeded()

        let anchorID = initial.first!.id
        guard let posBefore = vc._testVisualPosition(of: anchorID) else {
            Issue.record("could not read the visual position of the reading anchor before the prepend")
            return
        }

        let prepended = makePairedMessages(count: 30, prefix: "H-")
        let merged = prepended + initial
        update(vc, convID: convID, revision: 2, messages: merged, hasMoreAbove: false)
        runLoop(seconds: 1.0, vc)

        guard let posAfter = vc._testVisualPosition(of: anchorID) else {
            Issue.record("could not read the visual position of the reading anchor after the prepend")
            return
        }
        let drift = abs(posAfter - posBefore)
        #expect(drift <= Self.anchorTolerance,
                Comment(rawValue: "the reading anchor drifted \(drift)pt (before=\(posBefore) after=\(posAfter)), beyond the \(Self.anchorTolerance)pt tolerance"))
        #expect(vc._testPrependGeometryRecoveryCount() == 0, "a normal prepend must not fall back to a full reload recovery")
    }


    @Test("Prepend During Streaming Keeps Streaming Cell At End And Offset Stable")
    func prependDuringStreamingKeepsStreamingCellAtEndAndOffsetStable() {
        let (vc, window) = makeController()
        defer { window.isHidden = true }
        let convID = UUID()

        let initial = makePairedMessages(count: 30, prefix: "")
        let streamingMsg = initial.last!
        update(vc, convID: convID, revision: 1, messages: initial, streamingID: streamingMsg.id, streamingText: streamingMsg.text, hasMoreAbove: true)
        runLoop(seconds: 1.0, vc)

        vc._testSetContentOffset(0)
        vc.view.layoutIfNeeded()

        guard let streamingMaxYBefore = vc._testVisualMaxY(of: streamingMsg.id) else {
            Issue.record("could not read the streaming cell visualMaxY"); return
        }
        let endDistBefore = vc._testContentHeight() - (streamingMaxYBefore + vc._testContentOffsetY())
        let anchorID = initial.first!.id
        guard let anchorPosBefore = vc._testVisualPosition(of: anchorID) else {
            Issue.record("could not read the visual position of the reading anchor before the prepend"); return
        }

        let prepended = makePairedMessages(count: 30, prefix: "H-")
        let merged = prepended + initial
        update(vc, convID: convID, revision: 2, messages: merged, streamingID: streamingMsg.id, streamingText: streamingMsg.text, hasMoreAbove: false)
        runLoop(seconds: 1.0, vc)

        guard let streamingMaxYAfter = vc._testVisualMaxY(of: streamingMsg.id) else {
            Issue.record("could not read the streaming cell visualMaxY after the batch"); return
        }
        let endDistAfter = vc._testContentHeight() - (streamingMaxYAfter + vc._testContentOffsetY())

        let endDistDrift = abs(endDistAfter - endDistBefore)
        #expect(endDistDrift <= Self.streamingEndDistTolerance,
                Comment(rawValue: "the distance from the last item to the end of the content drifted \(endDistDrift)pt, beyond the \(Self.streamingEndDistTolerance)pt tolerance; before=\(endDistBefore) after=\(endDistAfter)"))

        guard let anchorPosAfter = vc._testVisualPosition(of: anchorID) else {
            Issue.record("could not read the visual position of the reading anchor after the prepend"); return
        }
        let anchorDrift = abs(anchorPosAfter - anchorPosBefore)
        #expect(anchorDrift <= Self.anchorTolerance,
                Comment(rawValue: "a prepend while streaming moved the reading anchor by \(anchorDrift)pt (before=\(anchorPosBefore) after=\(anchorPosAfter)), beyond \(Self.anchorTolerance)pt"))
    }


    /// Reproduces a production crash: an outline jump moved the offset a long way in one step
    /// (bottom to top, without animation) and a prepend was applied in the same runloop turn with no
    /// layout pass in between, because the jump synchronously triggered an upward extension and the
    /// rows arrived before the next commit.
    /// When the barrier really does find an inconsistency the code falls back to a full reload.
    /// That self-healing path stays - it is what prevents a UIKit crash - but it must not sacrifice
    /// the reading position along the way: the anchor was captured while the pre-batch barrier still
    /// agreed, and it is still usable once the reload and layout have produced clean geometry.
    /// Without restoring it, scrolling back through history would be yanked away by a prepend.
    ///
    /// The real trigger lives in UIKit's internal state and cannot be constructed from a test, so a
    /// debug seam forces the verdict.
    /// At that moment the visible cell list still contained the old bottom cells - the crash report
    /// showed an offset of 189 alongside a cell whose frame started past 126000 - and the first
    /// forced layout pass of the offset restoration runs with attributes suppressed. For a bounds
    /// change large enough that every visible cell falls outside the new viewport, UIKit asks for
    /// each cell's attributes, gets nil, and raises an internal inconsistency exception about
    /// missing final attributes.
    ///
    /// Two things are asserted: that it does not crash (implicitly, by the test completing), and
    /// that the jump target is still pinned to the top of the viewport once everything settles.
    @Test("Outline Jump Then Immediate Prepend Does Not Crash And Keeps Target")
    func outlineJumpThenImmediatePrependDoesNotCrashAndKeepsTarget() {
        let (vc, window) = makeController()
        defer { window.isHidden = true }
        let convID = UUID()

        let initial = makePairedMessages(count: 30, prefix: "")
        update(vc, convID: convID, revision: 1, messages: initial, hasMoreAbove: true)
        runLoop(seconds: 1.0, vc)

        let target = initial.first!
        vc.scrollToUserMessage(id: target.id, animated: false)

        let prepended = makePairedMessages(count: 30, prefix: "H-")
        let merged = prepended + initial
        update(vc, convID: convID, revision: 2, messages: merged, hasMoreAbove: false)

        runLoop(seconds: 1.0, vc)

        guard let targetPos = vc._testVisualPosition(of: target.id) else {
            Issue.record("could not read the visual position of the outline jump target; the cell was never laid out")
            return
        }
        let drift = abs(targetPos - 16.0)
        #expect(drift <= Self.anchorTolerance,
                Comment(rawValue: "the outline jump target sits at \(targetPos)pt instead of 16pt from the top of the viewport, beyond the \(Self.anchorTolerance)pt tolerance"))
    }


    @Test("Foreground Resume With Stale Visible Geometry Then Prepend Is Safe")
    func foregroundResumeWithStaleVisibleGeometryThenPrependIsSafe() {
        let (vc, window) = makeController()
        defer { window.isHidden = true }
        let convID = UUID()

        let initial = makePairedMessages(count: 50, prefix: "")
        update(vc, convID: convID, revision: 1, messages: initial, hasMoreAbove: true)
        runLoop(seconds: 1.0, vc)

        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        vc._testSetContentOffset(0)
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)

        let prepended = makePairedMessages(count: 30, prefix: "H-")
        update(
            vc,
            convID: convID,
            revision: 2,
            messages: prepended + initial,
            hasMoreAbove: false
        )
        runLoop(seconds: 1.0, vc)

        guard let anchorPosition = vc._testVisualPosition(of: initial[0].id) else {
            Issue.record("could not read the reading anchor after the foreground-restore prepend")
            return
        }
        #expect(abs(anchorPosition - Self.additionalInsetTop) <= Self.anchorTolerance,
                Comment(rawValue: "after the foreground-restore prepend the anchor sits at \(anchorPosition)pt instead of \(Self.additionalInsetTop)pt from the top"))
        #expect(vc._testPrependGeometryRecoveryCount() == 0, "a prepend after a foreground restore must not fall back to a full reload recovery")
    }


    @Test("Outline Jump During Bottom Settle Takes Over")
    func outlineJumpDuringBottomSettleTakesOver() {
        let (vc, window) = makeController()
        defer { window.isHidden = true }
        let convID = UUID()

        let initial = makePairedMessages(count: 30, prefix: "")
        update(vc, convID: convID, revision: 1, messages: initial, hasMoreAbove: false)
        runLoop(seconds: 1.0, vc)

        let target = initial.first!
        vc._testTriggerCompetingScrollSettle()
        vc.scrollToUserMessage(id: target.id, animated: false)

        var pulledBackToBottom = false
        for _ in 0..<20 {
            runLoop(seconds: 0.03, vc)
            let offset = vc._testContentOffsetY()
            let maxOffset = vc._testContentHeight() - vc._testCollectionBoundsHeight()
            if offset > maxOffset - vc._testCollectionBoundsHeight() {
                pulledBackToBottom = true
            }
        }
        #expect(!pulledBackToBottom, "the scroll-to-bottom settle loop dragged the view back down after the outline jump")

        guard let targetPos = vc._testVisualPosition(of: target.id) else {
            Issue.record("could not read the visual position of the outline jump target")
            return
        }
        let drift = abs(targetPos - 16.0)
        #expect(drift <= Self.anchorTolerance,
                Comment(rawValue: "the outline jump target finally sits at \(targetPos)pt instead of 16pt from the top of the viewport, beyond the \(Self.anchorTolerance)pt tolerance"))
    }


    @Test("Viewport Overflow Judges Position Not Emptiness")
    func viewportOverflowJudgesPositionNotEmptiness() {
        let topViewport = CGRect(x: 0, y: 0, width: Self.width, height: Self.viewport)
        let crashViewport = CGRect(x: 0, y: 189, width: Self.width, height: Self.viewport)
        let tolerance = Self.viewport

        #expect(ChatListViewController.viewportOverflow(
            cellFrame: .zero, viewport: topViewport, tolerance: tolerance) == 0)

        #expect(ChatListViewController.viewportOverflow(
            cellFrame: CGRect(x: 0, y: 500, width: Self.width, height: 0),
            viewport: crashViewport, tolerance: tolerance) == 0)

        #expect(ChatListViewController.viewportOverflow(
            cellFrame: CGRect(x: 0, y: 189 - Self.viewport + 10, width: Self.width, height: 40),
            viewport: crashViewport, tolerance: tolerance) == 0)

        let stale = ChatListViewController.viewportOverflow(
            cellFrame: CGRect(x: 0, y: 126_732, width: Self.width, height: 120),
            viewport: crashViewport, tolerance: tolerance)
        #expect((stale ?? 0) > 100_000,
                Comment(rawValue: "the stale viewport cell is \(String(describing: stale)) out of bounds, which should be on the order of a hundred thousand points"))

        #expect(ChatListViewController.viewportOverflow(
            cellFrame: CGRect(origin: CGPoint(x: 0, y: CGFloat.nan), size: CGSize(width: Self.width, height: 40)),
            viewport: crashViewport, tolerance: tolerance) == nil)
    }


    @Test("Post Batch Geometry Recovery Still Conserves Anchor")
    func postBatchGeometryRecoveryStillConservesAnchor() {
        let (vc, window) = makeController()
        defer { window.isHidden = true }
        let convID = UUID()

        let initial = makePairedMessages(count: 30, prefix: "")
        update(vc, convID: convID, revision: 1, messages: initial, hasMoreAbove: true)
        runLoop(seconds: 1.0, vc)
        vc._testSetContentOffset(0)
        vc.view.layoutIfNeeded()

        let anchorID = initial.first!.id
        guard let posBefore = vc._testVisualPosition(of: anchorID) else {
            Issue.record("could not read the reading position before the recovery"); return
        }
        #expect(vc._testPrependGeometryRecoveryCount() == 0, "no recovery should have run before this prepend")

        vc._testForceInconsistentPostBatchGeometry = true
        let prepended = makePairedMessages(count: 30, prefix: "H-")
        update(vc, convID: convID, revision: 2, messages: prepended + initial, hasMoreAbove: false)
        vc._testForceInconsistentPostBatchGeometry = false
        runLoop(seconds: 1.0, vc)

        #expect(vc._testPrependGeometryRecoveryCount() == 1, "forcing an inconsistent verdict must run exactly one full reload recovery")
        guard let posAfter = vc._testVisualPosition(of: anchorID) else {
            Issue.record("could not read the reading position after the recovery"); return
        }
        let drift = abs(posAfter - posBefore)
        #expect(drift <= Self.recoveryAnchorTolerance,
                Comment(rawValue: "the reading position drifted \(drift)pt across the full reload recovery (before=\(posBefore) after=\(posAfter)), beyond \(Self.recoveryAnchorTolerance)pt"))
    }


    @Test("Geometry Recovery Report Throttle")
    func geometryRecoveryReportThrottle() {
        for count in [1, 2, 4, 8, 16, 1024] {
            #expect(ChatListViewController.shouldReportGeometryRecovery(count: count),
                    Comment(rawValue: "occurrence \(count) is a power of two and must be reported"))
        }
        for count in [3, 5, 6, 7, 9, 15, 100] {
            #expect(!ChatListViewController.shouldReportGeometryRecovery(count: count),
                    Comment(rawValue: "occurrence \(count) must be throttled away"))
        }
        #expect(!ChatListViewController.shouldReportGeometryRecovery(count: 0))
        #expect(!ChatListViewController.shouldReportGeometryRecovery(count: -4))
    }


    @Test("Consecutive Prepends Three Batches Anchor Conserved")
    func consecutivePrependsThreeBatchesAnchorConserved() {
        let (vc, window) = makeController()
        defer { window.isHidden = true }
        let convID = UUID()

        let initial = makePairedMessages(count: 30, prefix: "")
        update(vc, convID: convID, revision: 1, messages: initial, hasMoreAbove: true)
        runLoop(seconds: 1.0, vc)
        vc._testSetContentOffset(0)
        vc.view.layoutIfNeeded()

        var cumulative = initial
        var revision: UInt = 2
        var drifts: [CGFloat] = []

        for prefix in ["B1-", "B2-", "B3-"] {
            let anchorID = cumulative.first!.id
            guard let posBefore = vc._testVisualPosition(of: anchorID) else {
                Issue.record("\(prefix) could not read the reading position before the prepend"); return
            }
            let batch = makePairedMessages(count: 30, prefix: prefix)
            cumulative = batch + cumulative
            update(vc, convID: convID, revision: revision, messages: cumulative, hasMoreAbove: prefix != "B3-")
            runLoop(seconds: 1.0, vc)
            guard let posAfter = vc._testVisualPosition(of: anchorID) else {
                Issue.record("\(prefix) could not read the reading position after the prepend"); return
            }
            drifts.append(abs(posAfter - posBefore))
            revision += 1
            vc._testSetContentOffset(0)
            vc.view.layoutIfNeeded()
        }

        let cumulativeDrift = drifts.reduce(0, +)
        #expect(cumulativeDrift <= Self.cumulativeAnchorTolerance,
                Comment(rawValue: "the reading position drifted \(cumulativeDrift)pt across three rounds, beyond the \(Self.cumulativeAnchorTolerance)pt tolerance; drifts=\(drifts)"))
    }
}
