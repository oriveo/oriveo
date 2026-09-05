import Combine
import Testing
import UIKit
@testable import Oriveo

/// Pins the fix for "opening a conversation whose last message is very long does nothing for a
/// while".
///
/// Cause: the push happens immediately, but once the window loader dispatched the first batch of
/// messages synchronously, the initial branch of `rebuildIfReady` ran `reloadData`,
/// `layoutIfNeeded` and the markdown rendering and measurement of a huge message cell **during the
/// push transition**. The main thread was blocked, the transition froze and the list stayed at
/// `alpha = 0`, so the user thought the tap had missed and tapped again.
///
/// Fix: the initial rebuild on first entry is deferred by default. The first attempt - defer only
/// when `viewWillAppear` finds a transition coordinator - did not work, because this controller is
/// mounted after the message data arrives and a child controller added mid-transition has no
/// coordinator, so the deferral never fired. Rather than betting on a signal, the rebuild is always
/// deferred and flushed by three independent triggers (coordinator completion, `viewDidAppear`, and
/// a fallback timer), and the flush waits for the bounded prewarm cache before rebuilding, which
/// removes the synchronous markdown rendering from the flush frame. A skeleton is shown during the
/// deferral and the settle window.
///
/// `_testCompleteInitialAppearance` simulates "the transition already finished" and restores
/// immediate rebuild semantics; `_testEndTransitionDeferral` drives the real flush path, including
/// the prewarm wait, so the queue has to be drained before asserting.
@Suite("Deferred rebuild when opening a conversation")
@MainActor
struct ChatOpenTransitionDeferralTests {
    private static let width: CGFloat = 390
    private static let viewport: CGFloat = 844

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
        vc.view.layoutIfNeeded()
        return (vc, window)
    }

    private func openConversationUpdate(_ vc: ChatListViewController, convID: UUID, messages: [ChatMessage]) {
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
            onEditMessage: { _ in }, onSwitchModel: {})
    }

    private func drainSettle(_ vc: ChatListViewController, seconds: TimeInterval = 1.2) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            vc.view.layoutIfNeeded()
        }
    }

    private func makeHeavyMessages() -> [ChatMessage] {
        [
            makeUser("write me a long piece of code"),
            makeAssistant("```swift\n" + String(repeating: "This is a very long reply body.\n", count: 800) + "```"),
        ]
    }

    private func makeCheapMessages() -> [ChatMessage] {
        [makeUser("what is the weather today"), makeAssistant("Sunny - a good day for a walk.")]
    }

    @Test("Defers Initial Rebuild By Default And Shows Skeleton")
    func defersInitialRebuildByDefaultAndShowsSkeleton() {
        let (vc, window) = makeController()
        defer { window.isHidden = true }

        openConversationUpdate(vc, convID: UUID(), messages: makeHeavyMessages())

        #expect(vc._testNumberOfItems() == 0,
                Comment(rawValue: "an expensive conversation must defer its first rebuild (built \(vc._testNumberOfItems()) cells); this controller is mounted mid-transition and has no coordinator, so betting on that signal would leave the heavy work in the transition frame"))
        #expect(vc._testSkeletonVisible() == true,
                Comment(rawValue: "the deferral window must show the skeleton placeholder rather than a blank list"))
    }

    @Test("Cheap Conversation Builds Immediately Without Skeleton")
    func cheapConversationBuildsImmediatelyWithoutSkeleton() {
        let (vc, window) = makeController()
        defer { window.isHidden = true }

        openConversationUpdate(vc, convID: UUID(), messages: makeCheapMessages())

        #expect(vc._testNumberOfItems() == 2,
                Comment(rawValue: "a cheap conversation must rebuild immediately (built \(vc._testNumberOfItems()) cells); deferring unconditionally makes every conversation flash a skeleton"))
        #expect(vc._testSkeletonVisible() == false,
                Comment(rawValue: "a cheap conversation must not show the skeleton, not even during the settle window"))

        drainSettle(vc)
        #expect(vc._testCollectionViewAlpha() == 1)
        #expect(vc._testSkeletonVisible() == false)
    }

    @Test("Switching Conversation After Cheap Open Is Not Deferred")
    func switchingConversationAfterCheapOpenIsNotDeferred() {
        let (vc, window) = makeController()
        defer { window.isHidden = true }

        openConversationUpdate(vc, convID: UUID(), messages: makeCheapMessages())
        #expect(vc._testNumberOfItems() == 2)

        openConversationUpdate(vc, convID: UUID(), messages: makeHeavyMessages())
        #expect(vc._testNumberOfItems() == 2,
                Comment(rawValue: "switching conversations in place was blocked by a stale deferral flag (built \(vc._testNumberOfItems()) cells)"))
    }

    @Test("Flush After Transition Builds And Reveals Then Hides Skeleton")
    func flushAfterTransitionBuildsAndRevealsThenHidesSkeleton() {
        let (vc, window) = makeController()
        defer { window.isHidden = true }

        openConversationUpdate(vc, convID: UUID(), messages: makeHeavyMessages())
        #expect(vc._testNumberOfItems() == 0)

        vc._testEndTransitionDeferral()
        drainSettle(vc)
        #expect(vc._testNumberOfItems() == 2,
                Comment(rawValue: "the rebuild must complete after the flush (built \(vc._testNumberOfItems()) cells)"))
        #expect(vc._testCollectionViewAlpha() == 1,
                Comment(rawValue: "the list must be revealed once it settles"))
        #expect(vc._testSkeletonVisible() == false,
                Comment(rawValue: "the skeleton must be hidden once the list is revealed"))
    }

    @Test("Builds Immediately After Appearance Completed")
    func buildsImmediatelyAfterAppearanceCompleted() {
        let (vc, window) = makeController()
        defer { window.isHidden = true }

        vc._testCompleteInitialAppearance()
        openConversationUpdate(vc, convID: UUID(), messages: [
            makeUser("a question"), makeAssistant("an answer body"),
        ])
        #expect(vc._testNumberOfItems() == 2,
                Comment(rawValue: "the rebuild must run immediately once the transition has finished"))

        drainSettle(vc)
        #expect(vc._testCollectionViewAlpha() == 1)
        #expect(vc._testSkeletonVisible() == false)
    }

    @Test("Fallback Timer Flushes When No Appearance Signal Arrives")
    func fallbackTimerFlushesWhenNoAppearanceSignalArrives() {
        let (vc, window) = makeController()
        defer { window.isHidden = true }

        openConversationUpdate(vc, convID: UUID(), messages: makeHeavyMessages())

        drainSettle(vc, seconds: 2.5)
        #expect(vc._testNumberOfItems() == 2,
                Comment(rawValue: "the fallback timer did not fire, so the content stays stuck behind the skeleton"))
        #expect(vc._testCollectionViewAlpha() == 1)
        #expect(vc._testSkeletonVisible() == false)
    }


    private func makeRows(_ messages: [ChatMessage]) -> [ChatCollectionProjectionBuilder.MessageRow] {
        ChatCollectionProjectionBuilder.makeRows(from: messages, metadata: .empty)
    }

    @Test("Cost Gate Cheap Conversation")
    func costGateCheapConversation() {
        #expect(ChatListViewController.shouldDeferInitialRebuild(
            rows: makeRows(makeCheapMessages())) == false)
    }

    @Test("Cost Gate Heavy Conversation")
    func costGateHeavyConversation() {
        #expect(ChatListViewController.shouldDeferInitialRebuild(
            rows: makeRows(makeHeavyMessages())) == true)
        let bigPlain = [makeAssistant(String(repeating: "A very long plain-text reply. ", count: 1200))]
        #expect(ChatListViewController.shouldDeferInitialRebuild(rows: makeRows(bigPlain)) == true)
    }

    @Test("Cost Gate Ignores Offscreen Middle Rows")
    func costGateIgnoresOffscreenMiddleRows() {
        let mediumLine = String(repeating: "a medium length message body ", count: 10)
        let few = (0..<8).map { _ in makeAssistant(mediumLine) }
        #expect(ChatListViewController.shouldDeferInitialRebuild(rows: makeRows(few)) == false,
                Comment(rawValue: "a handful of medium messages must not defer"))
        let many = (0..<120).map { _ in makeAssistant(mediumLine) }
        #expect(ChatListViewController.shouldDeferInitialRebuild(rows: makeRows(many)) == false,
                Comment(rawValue: "counting small offscreen middle rows toward the cost makes almost every multi-turn conversation flash a skeleton"))
        let giant = makeAssistant(String(repeating: "A very long plain-text reply. ", count: 1500))
        let middleGiant = (0..<15).map { _ in makeAssistant(mediumLine) }
            + [giant]
            + (0..<30).map { _ in makeAssistant(mediumLine) }
        #expect(ChatListViewController.shouldDeferInitialRebuild(rows: makeRows(middleGiant)) == false,
                Comment(rawValue: "a giant message in the middle is never measured synchronously on entry, so it must not trigger the skeleton"))
    }

    @Test("Cost Gate Still Defers Giant At Either End")
    func costGateStillDefersGiantAtEitherEnd() {
        let giant = makeAssistant(String(repeating: "A very long plain-text reply. ", count: 1500))
        let smalls = (0..<30).map { _ in makeAssistant("Sure.") }
        #expect(ChatListViewController.shouldDeferInitialRebuild(rows: makeRows(smalls + [giant])) == true,
                Comment(rawValue: "a giant message on the last screen is measured in the transition frame, so it must defer"))
        #expect(ChatListViewController.shouldDeferInitialRebuild(rows: makeRows([giant] + smalls)) == true,
                Comment(rawValue: "a giant message on the first screen is measured synchronously in the reload frame, so it must defer"))
    }
}
