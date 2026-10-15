import Combine
import Testing
import UIKit
@testable import Oriveo

/// A width change keeps the reading position (folding or half-folding a Duo, rotating an iPhone, resizing an iPad window).
///
/// Contract: when the same `ChatListViewController` changes width
/// 1. reading history → lands back on "the message at the viewport top + how far into it", not pulled to the bottom;
/// 2. at the bottom (not streaming) → lands at the bottom again;
/// 3. pinned to the top while streaming → the pinned user message stays at the top and streaming mode is kept;
/// 4. an injected `pendingReadingAnchor` → the first build lands on it; an anchor whose message is not in the window → the bottom.
/// It also measures the width-change reload + layout (only to guard against regressions).
@Suite("Width change · reading anchor preserved + relayout time")
@MainActor
struct ChatWidthChangeReadingAnchorTests {
    private static let narrowWidth: CGFloat = 466
    private static let wideWidth: CGFloat = 951
    private static let viewport: CGFloat = 844
    /// Maximum progress error after landing back (fixed).
    private static let progressTolerance: CGFloat = 0.05
    /// Tolerance for the pinned user message's visual position: self-sizing bounce + sub-pixel, the same as the prepend integration test.
    private static let pinTolerance: CGFloat = 6

    private func makeUser(_ text: String, id: UUID = UUID()) -> ChatMessage {
        ChatMessage(id: id, role: .user, text: text, reasoningText: nil,
                    providerKind: .openAI, providerName: "OpenAI", modelName: "GPT-4o",
                    estimatedCost: 0, state: .delivered, attachments: nil, citations: nil)
    }

    private func makeAssistant(_ text: String, id: UUID = UUID(), state: ChatMessageState = .delivered) -> ChatMessage {
        ChatMessage(id: id, role: .assistant, text: text, reasoningText: nil,
                    providerKind: .openAI, providerName: "OpenAI", modelName: "GPT-4o",
                    estimatedCost: 0, state: state, attachments: nil, citations: nil)
    }

    private func makeController(width: CGFloat = Self.narrowWidth) -> (ChatListViewController, UIWindow) {
        let vc = ChatListViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: Self.viewport))
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

    /// Change the window width → the root view follows → `viewDidLayoutSubviews` takes the production width-change path.
    private func resize(_ vc: ChatListViewController, _ window: UIWindow, width: CGFloat) {
        window.frame = CGRect(x: 0, y: 0, width: width, height: Self.viewport)
        vc.view.frame = window.bounds
        window.layoutIfNeeded()
        vc.view.layoutIfNeeded()
    }

    private func update(
        _ vc: ChatListViewController,
        convID: UUID,
        revision: UInt,
        messages: [ChatMessage],
        streamingID: UUID? = nil,
        streamingText: String = "",
        anchorID: UUID? = nil
    ) {
        let vm = ChatCollectionViewModel(
            conversationID: convID, messageRevision: revision,
            rows: ChatCollectionProjectionBuilder.makeRows(from: messages, metadata: .empty),
            isSendingMessage: anchorID != nil, streamingMessageID: streamingID, streamingText: streamingText,
            pendingAnchorUserMessageID: anchorID, pendingSearchScrollTarget: nil,
            isBootstrappingPersistedConversation: false,
            retryCapabilitySelection: ChatCapabilitySelection())
        vc.update(
            viewModel: vm, providerMetadataVersion: 0,
            streamingPublisher: Empty<Void, Never>().eraseToAnyPublisher(),
            streamingReasoningPublisher: Empty<ReasoningStreamDelta, Never>().eraseToAnyPublisher(),
            streamingTextProvider: { streamingText }, streamingReasoningSnapshotProvider: { nil },
            onRetry: { _ in }, onContinue: { _ in }, onRegenerate: { _ in },
            onEditMessage: { _ in }, onSwitchModel: {},
            pendingAnchorUserMessageID: anchorID, onAnchorUserMessageConsumed: { _ in })
        vc.view.layoutIfNeeded()
    }

    /// Answers long enough that the line count changes with the width, so a pixel offset is stale after relayout.
    private func makePairedMessages(count pairCount: Int) -> [ChatMessage] {
        let paragraph = "This answer paragraph is deliberately long so that the number of wrapped lines depends on the column width, which makes every cell change height when the width changes."
        var msgs: [ChatMessage] = []
        for i in 0..<pairCount {
            msgs.append(makeUser("Q-\(i) a question that wraps to two lines on a narrow column for self-size."))
            msgs.append(makeAssistant("A-\(i) " + Array(repeating: paragraph, count: 3).joined(separator: " ")))
        }
        return msgs
    }

    /// 200 Markdown messages (headings, lists, code blocks) for timing the relayout.
    private func makeMarkdownMessages(count pairCount: Int) -> [ChatMessage] {
        var msgs: [ChatMessage] = []
        for i in 0..<pairCount {
            msgs.append(makeUser("Q-\(i) how do I structure this module?"))
            let body = """
            ## Answer \(i)

            Here is an overview with **bold** text and `inline code` that wraps across lines on narrow columns.

            - first point about the design, long enough to wrap
            - second point with a [link](https://example.com)
              - nested detail item
            1. ordered step one
            2. ordered step two

            ```swift
            struct Item\(i) {
                let id: Int
                func render() -> String { "item \\(id)" }
            }
            ```

            Closing paragraph that explains the trade-offs in a sentence or two.
            """
            msgs.append(makeAssistant(body))
        }
        return msgs
    }

    /// Puts `progress` of the target message at the viewport top (two passes: one so the surrounding cells materialize, then a precise one with real heights).
    private func placeViewportTop(at id: UUID, progress: CGFloat, _ vc: ChatListViewController) -> Bool {
        for _ in 0..<2 {
            guard let top = vc._testVisualPosition(of: id), let bottom = vc._testVisualMaxY(of: id) else {
                return false
            }
            vc._testSetContentOffset(vc._testContentOffsetY() + top + progress * (bottom - top))
            vc.view.layoutIfNeeded()
            runLoop(seconds: 0.3, vc)
        }
        return true
    }

    private func expectAnchor(
        _ actual: ChatReadingAnchor?,
        matches expected: ChatReadingAnchor,
        _ label: String
    ) {
        guard let actual else {
            Issue.record("\(label): no anchor once settled (pulled to the bottom?)")
            return
        }
        #expect(actual.messageID == expected.messageID,
                Comment(rawValue: "\(label): the message at the viewport top changed"))
        let drift = abs(actual.progress - expected.progress)
        #expect(drift <= Self.progressTolerance,
                Comment(rawValue: "\(label): progress drifted by \(drift) (before=\(expected.progress) after=\(actual.progress))"))
    }

    // MARK: - Width change while reading history

    @Test("Scrolled to the middle → 466→951 → 951→466: the same message stays near the viewport top, not at the bottom")
    func midHistoryWidthChangeKeepsReadingAnchor() {
        let (vc, window) = makeController()
        defer { window.isHidden = true }
        let messages = makePairedMessages(count: 30)
        update(vc, convID: UUID(), revision: 1, messages: messages)
        runLoop(seconds: 1.0, vc)

        let target = messages[31]  // a long assistant answer in the middle
        vc._testSetContentOffset(vc._testContentHeight() * 0.5)
        runLoop(seconds: 0.3, vc)
        guard placeViewportTop(at: target.id, progress: 0.4, vc) else {
            Issue.record("Could not put the target message at the viewport top"); return
        }
        guard let before = vc.captureReadingAnchor() else {
            Issue.record("Scrolled to the middle but no anchor was captured"); return
        }
        #expect(before.messageID == target.id)

        resize(vc, window, width: Self.wideWidth)
        runLoop(seconds: 1.0, vc)
        #expect(vc.distanceFromBottom >= ChatStickToBottomController.atBottomThreshold,
                Comment(rawValue: "Pulled to the bottom after 466→951 (distance from bottom \(vc.distanceFromBottom))"))
        expectAnchor(vc.captureReadingAnchor(), matches: before, "466→951")

        resize(vc, window, width: Self.narrowWidth)
        runLoop(seconds: 1.0, vc)
        #expect(vc.distanceFromBottom >= ChatStickToBottomController.atBottomThreshold,
                Comment(rawValue: "Pulled to the bottom after 951→466 (distance from bottom \(vc.distanceFromBottom))"))
        expectAnchor(vc.captureReadingAnchor(), matches: before, "951→466")
    }

    // MARK: - Width change at the bottom

    @Test("At the bottom (not streaming) → width change → still at the bottom")
    func atBottomWidthChangeStaysAtBottom() {
        let (vc, window) = makeController()
        defer { window.isHidden = true }
        update(vc, convID: UUID(), revision: 1, messages: makePairedMessages(count: 20))
        runLoop(seconds: 1.0, vc)
        #expect(vc.captureReadingAnchor() == nil, Comment(rawValue: "Should count as at the bottom after the initial landing"))

        resize(vc, window, width: Self.wideWidth)
        runLoop(seconds: 1.0, vc)
        #expect(vc.distanceFromBottom < ChatStickToBottomController.atBottomThreshold,
                Comment(rawValue: "\(vc.distanceFromBottom)pt from the bottom after a width change at the bottom"))
        #expect(vc.captureReadingAnchor() == nil)
    }

    // MARK: - Width change while pinned during streaming

    @Test("Pinned while streaming → width change → the pinned user message stays at the top and streaming mode stays on")
    func streamingPinnedWidthChangeKeepsPinnedUserAtTop() {
        let (vc, window) = makeController()
        defer { window.isHidden = true }
        let convID = UUID()
        let history = makePairedMessages(count: 8)
        update(vc, convID: convID, revision: 1, messages: history)
        runLoop(seconds: 1.0, vc)

        let question = makeUser("A fresh question that is sent and pinned to the top of the viewport.")
        let streamingText = "The answer starts streaming in with a couple of words."
        let answer = makeAssistant(streamingText, state: .generating)
        update(vc, convID: convID, revision: 2, messages: history + [question, answer],
               streamingID: answer.id, streamingText: streamingText, anchorID: question.id)
        runLoop(seconds: 1.0, vc)
        guard let pinnedBefore = vc._testVisualPosition(of: question.id) else {
            Issue.record("Could not read the pinned user message position"); return
        }
        #expect(abs(pinnedBefore) <= Self.pinTolerance,
                Comment(rawValue: "Precondition: the user message should be pinned after sending, measured \(pinnedBefore)"))

        resize(vc, window, width: Self.wideWidth)
        runLoop(seconds: 1.0, vc)
        #expect(vc._testIsStreamingMode(), Comment(rawValue: "Streaming mode was cleared by the width change"))
        guard let pinnedAfter = vc._testVisualPosition(of: question.id) else {
            Issue.record("Could not read the pinned user message position after the width change"); return
        }
        #expect(abs(pinnedAfter) <= Self.pinTolerance,
                Comment(rawValue: "The user message is not at the top after the width change: visual position \(pinnedAfter)"))
        #expect(vc.captureReadingAnchor()?.messageID == question.id)
    }

    // MARK: - Injected anchor

    @Test("pendingReadingAnchor injected into a new controller → the first build lands on it")
    func injectedAnchorRestoresOnFirstRebuild() {
        let (vc, window) = makeController()
        defer { window.isHidden = true }
        let messages = makePairedMessages(count: 30)
        let anchor = ChatReadingAnchor(messageID: messages[21].id, progress: 0.3)
        vc.pendingReadingAnchor = anchor
        update(vc, convID: UUID(), revision: 1, messages: messages)
        runLoop(seconds: 1.0, vc)

        #expect(vc.pendingReadingAnchor == nil, Comment(rawValue: "The anchor should be consumed once"))
        #expect(vc._testCollectionViewAlpha() == 1, Comment(rawValue: "The list must be revealed after landing on the anchor"))
        #expect(vc.distanceFromBottom >= ChatStickToBottomController.atBottomThreshold,
                Comment(rawValue: "Given an anchor but landed at the bottom (distance from bottom \(vc.distanceFromBottom))"))
        expectAnchor(vc.captureReadingAnchor(), matches: anchor, "Injected anchor")
    }

    @Test("pendingReadingAnchor whose message is not in the rows → treated as none, lands at the bottom")
    func injectedAnchorOutsideWindowFallsBackToBottom() {
        let (vc, window) = makeController()
        defer { window.isHidden = true }
        vc.pendingReadingAnchor = ChatReadingAnchor(messageID: UUID(), progress: 0.5)
        update(vc, convID: UUID(), revision: 1, messages: makePairedMessages(count: 20))
        runLoop(seconds: 1.0, vc)

        #expect(vc.pendingReadingAnchor == nil)
        #expect(vc._testCollectionViewAlpha() == 1)
        #expect(vc.distanceFromBottom < ChatStickToBottomController.atBottomThreshold,
                Comment(rawValue: "An anchor outside the window should land at the bottom, measured distance \(vc.distanceFromBottom)"))
    }

    // MARK: - Relayout time

    @Test("200 Markdown messages: settled at 466, changed to 951, reload+layout < 1000ms")
    func widthRelayoutDurationGuard() {
        let (vc, window) = makeController()
        defer { window.isHidden = true }
        update(vc, convID: UUID(), revision: 1, messages: makeMarkdownMessages(count: 100))
        runLoop(seconds: 1.5, vc)

        resize(vc, window, width: Self.wideWidth)
        guard let ms = vc._testLastWidthRelayoutMs else {
            Issue.record("The width change did not go through the timed reload+layout interval"); return
        }
        print("[P2-RELAYOUT] ms=\(String(format: "%.1f", ms))")
        #expect(ms < 1000, Comment(rawValue: "Width-change reload+layout took \(ms)ms"))
    }
}
