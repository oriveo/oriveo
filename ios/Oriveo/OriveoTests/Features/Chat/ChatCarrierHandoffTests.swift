import Combine
import Foundation
import Testing
import UIKit
@testable import Oriveo

/// Page state handoff when a conversation changes carrier (two-column detail column ↔ outer stack).
///
/// Contract:
/// 1. Registrations carry a token; unregistering an old token cannot remove a newer registration;
/// 2. A snapshot is consumed once by key; a mismatched key or one older than 2 seconds is discarded;
/// 3. When `updateLayoutWidth` really moves a conversation, the providers are called **before** the move, keyed by conversation id or draft;
/// 4. The anchor captured by the old list controller's `captureReadingAnchor` reaches the new controller through the handoff, whose first build lands on the same message without the entrance delay.
@Suite("Carrier change · page state handoff")
@MainActor
struct ChatCarrierHandoffTests {
    private static let viewport: CGFloat = 844
    private static let progressTolerance: CGFloat = 0.05

    private final class Clock {
        var now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    }

    private func makePage(webEnabled: Bool = false, sheet: ChatCarrierSheet? = nil) -> ChatPageCarrierState {
        ChatPageCarrierState(
            pendingAttachments: [],
            pendingQuoteContext: nil,
            reasoningMode: .automatic,
            reasoningIntentSelection: nil,
            webEnabled: webEnabled,
            generationParameterDraftSessionID: UUID(),
            sheet: sheet
        )
    }

    private func makeComposer(_ text: String) -> ChatComposerCarrierState {
        ChatComposerCarrierState(text: text, isFocused: true, showsModelControls: false)
    }

    // MARK: - The handoff itself

    @Test("Unregistering an old token does not clear a newer registration")
    func staleTokenDoesNotClearNewerRegistration() {
        let handoff = ChatCarrierHandoff()
        let oldPage = handoff.registerPage { self.makePage(webEnabled: false) }
        let oldComposer = handoff.registerComposer { self.makeComposer("old") }
        let newPage = handoff.registerPage { self.makePage(webEnabled: true) }
        let newComposer = handoff.registerComposer { self.makeComposer("new") }
        // The new view appears first, then the old view's onDisappear.
        handoff.unregister(oldPage)
        handoff.unregister(oldComposer)

        handoff.capture(key: .draft)
        let snapshot = handoff.consume(key: .draft, by: newPage)
        #expect(snapshot?.page?.webEnabled == true)
        #expect(snapshot?.composer?.text == "new")
        _ = newComposer
    }

    @Test("After unregistering its own token it no longer provides")
    func ownTokenClearsRegistration() {
        let handoff = ChatCarrierHandoff()
        let page = handoff.registerPage { self.makePage() }
        let composer = handoff.registerComposer { self.makeComposer("x") }
        handoff.unregister(page)
        handoff.unregister(composer)

        handoff.capture(key: .draft)
        let snapshot = handoff.consume(key: .draft, by: page)
        #expect(snapshot != nil)
        #expect(snapshot?.page == nil)
        #expect(snapshot?.composer == nil)
        #expect(snapshot?.hasList == false)
    }

    @Test("Consuming by key works only once")
    func consumesOnce() {
        let handoff = ChatCarrierHandoff()
        let id = UUID()
        let page = handoff.registerPage { self.makePage(webEnabled: true) }
        handoff.capture(key: .conversation(id))

        #expect(handoff.consume(key: .conversation(id), by: page)?.page?.webEnabled == true)
        #expect(handoff.consume(key: .conversation(id), by: page) == nil)
    }

    @Test("A mismatched key discards the snapshot, so the right key gets nothing afterwards")
    func mismatchedKeyVoidsSnapshot() {
        let handoff = ChatCarrierHandoff()
        let id = UUID()
        let page = handoff.registerPage { self.makePage() }
        handoff.capture(key: .conversation(id))

        #expect(handoff.consume(key: .draft, by: page) == nil)
        #expect(handoff.consume(key: .conversation(UUID()), by: page) == nil)
        #expect(handoff.consume(key: .conversation(id), by: page) == nil)
    }

    @Test("Discarded after 2 seconds, valid within them")
    func expiresAfterFreshnessWindow() {
        let clock = Clock()
        let handoff = ChatCarrierHandoff(now: { clock.now })
        let page = handoff.registerPage { self.makePage() }

        handoff.capture(key: .draft)
        clock.now = clock.now.addingTimeInterval(1.9)
        #expect(handoff.consume(key: .draft, by: page) != nil)

        handoff.capture(key: .draft)
        clock.now = clock.now.addingTimeInterval(2.1)
        #expect(handoff.consume(key: .draft, by: page) == nil)
    }

    @Test("List handoff: only when a list existed at capture, taken once, discarded when the consuming page unregisters")
    func listRestoreIsOwnedByConsumingPage() {
        let handoff = ChatCarrierHandoff()
        let anchor = ChatReadingAnchor(messageID: UUID(), progress: 0.4)

        // No list controller (empty conversation): no list handoff.
        let page = handoff.registerPage { self.makePage() }
        handoff.capture(key: .draft)
        #expect(handoff.consume(key: .draft, by: page)?.hasList == false)
        #expect(handoff.takeListRestore() == nil)

        // A list at the bottom: hand over one with a nil anchor (the entrance delay is still skipped).
        let list = handoff.registerReadingAnchor { nil }
        handoff.capture(key: .draft)
        _ = handoff.consume(key: .draft, by: page)
        #expect(handoff.takeListRestore() == ChatListCarrierRestore(readingAnchor: nil))
        #expect(handoff.takeListRestore() == nil)

        // With an anchor; the page unregisters first (it left before messages arrived), and the list handoff goes with it.
        handoff.unregister(list)
        _ = handoff.registerReadingAnchor { anchor }
        handoff.capture(key: .draft)
        let newPage = handoff.registerPage { self.makePage() }
        _ = handoff.consume(key: .draft, by: newPage)
        handoff.unregister(page)  // the old page unregistering does not affect the new page's registration
        handoff.unregister(newPage)
        #expect(handoff.takeListRestore() == nil)
    }

    // MARK: - NavigationManager moves

    /// The provider records the carrier at the moment it is called, proving the capture happens before the move.
    private struct CarrierAtCapture {
        var path: [AppRoute]?
        var chatDetail: ChatDetailState?
    }

    private final class Recorder {
        var seen = CarrierAtCapture()
    }

    @Test("951→669 (conversation): captured before the move, keyed by conversation id")
    func collapseCapturesConversationBeforeMove() {
        let nav = NavigationManager()
        nav.updateLayoutWidth(isRegular: true)
        let id = UUID()
        nav.presentChat(conversationID: id)
        let recorder = Recorder()
        let page = nav.chatHandoff.registerPage {
            recorder.seen = CarrierAtCapture(path: nav.path, chatDetail: nav.chatDetail)
            return self.makePage(webEnabled: true)
        }

        nav.updateLayoutWidth(isRegular: false)

        #expect(recorder.seen.chatDetail == .conversation(id))
        #expect(recorder.seen.path == [])
        #expect(nav.path.last == .chat(conversationID: id))
        #expect(nav.chatHandoff.consume(key: .conversation(id), by: page)?.page?.webEnabled == true)
    }

    @Test("951→669 (draft): keyed by draft")
    func collapseCapturesDraftBeforeMove() {
        let nav = NavigationManager()
        nav.updateLayoutWidth(isRegular: true)
        nav.presentChat(conversationID: nil)
        let recorder = Recorder()
        let composer = nav.chatHandoff.registerComposer {
            recorder.seen = CarrierAtCapture(path: nav.path, chatDetail: nav.chatDetail)
            return self.makeComposer("unsent draft")
        }

        nav.updateLayoutWidth(isRegular: false)

        #expect(recorder.seen.chatDetail == .draft)
        #expect(nav.path.last == .chat(conversationID: nil))
        #expect(nav.chatHandoff.consume(key: .draft, by: composer)?.composer?.text == "unsent draft")
    }

    @Test("669→951 (conversation): captured before the move, keyed by conversation id")
    func expandCapturesConversationBeforeMove() {
        let nav = NavigationManager()
        let id = UUID()
        nav.presentChat(conversationID: id)
        let recorder = Recorder()
        let page = nav.chatHandoff.registerPage {
            recorder.seen = CarrierAtCapture(path: nav.path, chatDetail: nav.chatDetail)
            return self.makePage(sheet: .mcpTools)
        }

        nav.updateLayoutWidth(isRegular: true)

        #expect(recorder.seen.path?.last == .chat(conversationID: id))
        #expect(recorder.seen.chatDetail == .empty)
        #expect(nav.chatDetail == .conversation(id))
        let snapshot = nav.chatHandoff.consume(key: .conversation(id), by: page)
        if case .mcpTools = snapshot?.page?.sheet {} else {
            Issue.record("The tools panel was not handed over with the snapshot")
        }
    }

    @Test("669→951 (draft): keyed by draft")
    func expandCapturesDraftBeforeMove() {
        let nav = NavigationManager()
        nav.presentChat(conversationID: nil)
        let recorder = Recorder()
        let page = nav.chatHandoff.registerPage {
            recorder.seen = CarrierAtCapture(path: nav.path, chatDetail: nav.chatDetail)
            return self.makePage()
        }

        nav.updateLayoutWidth(isRegular: true)

        #expect(recorder.seen.path?.last == .chat(conversationID: nil))
        #expect(nav.chatDetail == .draft)
        #expect(nav.chatHandoff.consume(key: .conversation(UUID()), by: page) == nil)
        nav.updateLayoutWidth(isRegular: false)
        #expect(nav.chatHandoff.consume(key: .draft, by: page) != nil)
    }

    @Test("No snapshot when there is no conversation to move")
    func noMoveNoCapture() {
        let nav = NavigationManager()
        var calls = 0
        let page = nav.chatHandoff.registerPage {
            calls += 1
            return self.makePage()
        }
        nav.attemptNavigate(to: .notesList)
        nav.updateLayoutWidth(isRegular: true)
        nav.updateLayoutWidth(isRegular: false)
        #expect(calls == 0)
        #expect(nav.chatHandoff.consume(key: .draft, by: page) == nil)
    }

    // MARK: - Production path: the old controller's anchor reaches the new one

    private func makeMessages(pairs: Int) -> [ChatMessage] {
        let paragraph = "This answer paragraph is deliberately long so that the number of wrapped lines depends on the column width, which makes every cell change height when the width changes."
        var messages: [ChatMessage] = []
        for i in 0..<pairs {
            messages.append(ChatMessage(
                id: UUID(), role: .user, text: "Q-\(i) a question that wraps to two lines on a narrow column for self-size.",
                reasoningText: nil, providerKind: .openAI, providerName: "OpenAI", modelName: "GPT-4o",
                estimatedCost: 0, state: .delivered, attachments: nil, citations: nil))
            messages.append(ChatMessage(
                id: UUID(), role: .assistant, text: "A-\(i) " + Array(repeating: paragraph, count: 3).joined(separator: " "),
                reasoningText: nil, providerKind: .openAI, providerName: "OpenAI", modelName: "GPT-4o",
                estimatedCost: 0, state: .delivered, attachments: nil, citations: nil))
        }
        return messages
    }

    private func host(_ vc: ChatListViewController, width: CGFloat) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: Self.viewport))
        window.rootViewController = vc
        window.makeKeyAndVisible()
        vc.view.layoutIfNeeded()
        return window
    }

    private func runLoop(seconds: TimeInterval, _ vc: ChatListViewController) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            vc.view.layoutIfNeeded()
        }
    }

    private func update(_ vc: ChatListViewController, convID: UUID, messages: [ChatMessage]) {
        let vm = ChatCollectionViewModel(
            conversationID: convID, messageRevision: 1,
            rows: ChatCollectionProjectionBuilder.makeRows(from: messages, metadata: .empty),
            isSendingMessage: false, streamingMessageID: nil, streamingText: "",
            pendingAnchorUserMessageID: nil, pendingSearchScrollTarget: nil,
            isBootstrappingPersistedConversation: false,
            retryCapabilitySelection: ChatCapabilitySelection())
        vc.update(
            viewModel: vm, providerMetadataVersion: 0,
            streamingPublisher: Empty<Void, Never>().eraseToAnyPublisher(),
            streamingReasoningPublisher: Empty<ReasoningStreamDelta, Never>().eraseToAnyPublisher(),
            streamingTextProvider: { "" }, streamingReasoningSnapshotProvider: { nil },
            onRetry: { _ in }, onContinue: { _ in }, onRegenerate: { _ in },
            onEditMessage: { _ in }, onSwitchModel: {},
            pendingAnchorUserMessageID: nil, onAnchorUserMessageConsumed: { _ in })
        vc.view.layoutIfNeeded()
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

    @Test("951→669: the old controller's anchor reaches the new one, whose first build lands on the same message without the entrance delay")
    func readingAnchorHandsOffToNewController() {
        let nav = NavigationManager()
        let handoff = nav.chatHandoff
        let conversationID = UUID()
        let messages = makeMessages(pairs: 30)
        nav.updateLayoutWidth(isRegular: true)
        nav.presentChat(conversationID: conversationID)

        // Old carrier: the two-column detail column (951 − 360 sidebar).
        let oldVC = ChatListViewController()
        let oldListToken = ChatListViewControllerRepresentable.attachCarrierHandoff(handoff, to: oldVC)
        let oldWindow = host(oldVC, width: 591)
        defer { oldWindow.isHidden = true }
        oldVC._testCompleteInitialAppearance()
        update(oldVC, convID: conversationID, messages: messages)
        runLoop(seconds: 1.0, oldVC)
        let target = messages[31]
        oldVC._testSetContentOffset(oldVC._testContentHeight() * 0.5)
        runLoop(seconds: 0.3, oldVC)
        guard placeViewportTop(at: target.id, progress: 0.4, oldVC),
              let before = oldVC.captureReadingAnchor() else {
            Issue.record("The old controller could not scroll to the middle or capture an anchor"); return
        }
        #expect(before.messageID == target.id)

        // Fold: capture before the move. The new page appears and consumes first; the old list is torn down afterwards.
        nav.updateLayoutWidth(isRegular: false)
        let newPage = handoff.registerPage { self.makePage() }
        let snapshot = handoff.consume(key: .conversation(conversationID), by: newPage)
        #expect(snapshot?.readingAnchor == before)
        handoff.unregister(oldListToken)

        // New carrier: the full-screen outer stack at 669.
        let newVC = ChatListViewController()
        let newListToken = ChatListViewControllerRepresentable.attachCarrierHandoff(handoff, to: newVC)
        #expect(newVC.pendingReadingAnchor == before)
        let newWindow = host(newVC, width: 669)
        defer { newWindow.isHidden = true }
        update(newVC, convID: conversationID, messages: messages)
        #expect(newVC._testNumberOfItems() > 0, Comment(rawValue: "The first build of the handed-over controller was delayed"))
        #expect(!newVC._testSkeletonVisible(), Comment(rawValue: "The handed-over controller flashed the skeleton"))
        runLoop(seconds: 1.0, newVC)

        #expect(newVC.pendingReadingAnchor == nil)
        #expect(newVC.distanceFromBottom >= ChatStickToBottomController.atBottomThreshold,
                Comment(rawValue: "Handed an anchor but landed at the bottom (distance from bottom \(newVC.distanceFromBottom))"))
        guard let after = newVC.captureReadingAnchor() else {
            Issue.record("The new controller has no anchor once settled"); return
        }
        #expect(after.messageID == before.messageID)
        let drift = abs(after.progress - before.progress)
        #expect(drift <= Self.progressTolerance,
                Comment(rawValue: "progress drifted by \(drift) (before=\(before.progress) after=\(after.progress))"))
        _ = newListToken
    }
}
