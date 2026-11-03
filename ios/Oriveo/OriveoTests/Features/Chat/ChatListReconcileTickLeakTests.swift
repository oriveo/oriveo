import Combine
import Testing
import UIKit
@testable import Oriveo

/// Locks the reconcile tick lifecycle: once `ChatListViewController` is released, the streaming / settle
/// reconcile ticks it subscribed on its `StreamingDisplayClock` must be gone and the clock paused, so no
/// per-frame display link keeps running forever.
@Suite("Chat list reconcile tick does not outlive the controller")
@MainActor
struct ChatListReconcileTickLeakTests {
    private static let width: CGFloat = 390
    private static let viewport: CGFloat = 844

    private func user(_ t: String, _ id: UUID = UUID()) -> ChatMessage {
        ChatMessage(id: id, role: .user, text: t, reasoningText: nil, providerKind: .openAI,
                    providerName: "OpenAI", modelName: "GPT-4o", estimatedCost: 0,
                    state: .delivered, attachments: nil, citations: nil)
    }
    private func assistant(_ t: String, _ id: UUID = UUID(), state: ChatMessageState = .delivered) -> ChatMessage {
        ChatMessage(id: id, role: .assistant, text: t, reasoningText: nil, providerKind: .openAI,
                    providerName: "OpenAI", modelName: "GPT-4o", estimatedCost: 0,
                    state: state, attachments: nil, citations: nil)
    }

    private func spin(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    private func drive(
        _ vc: ChatListViewController, convID: UUID, messages: [ChatMessage],
        anchorID: UUID?, streamingID: UUID?, settle: TimeInterval
    ) {
        let vm = ChatCollectionViewModel(
            conversationID: convID, messageRevision: UInt(messages.count),
            rows: ChatCollectionProjectionBuilder.makeRows(from: messages, metadata: .empty),
            isSendingMessage: anchorID != nil, streamingMessageID: streamingID, streamingText: "",
            pendingAnchorUserMessageID: anchorID, pendingSearchScrollTarget: nil,
            isBootstrappingPersistedConversation: false, retryCapabilitySelection: ChatCapabilitySelection())
        vc.update(
            viewModel: vm, providerMetadataVersion: 0,
            streamingPublisher: Empty<Void, Never>().eraseToAnyPublisher(),
            streamingReasoningPublisher: Empty<ReasoningStreamDelta, Never>().eraseToAnyPublisher(),
            streamingTextProvider: { "" }, streamingReasoningSnapshotProvider: { nil },
            onRetry: { _ in }, onContinue: { _ in }, onRegenerate: { _ in },
            onEditMessage: { _ in }, onSwitchModel: {},
            pendingAnchorUserMessageID: anchorID, onAnchorUserMessageConsumed: { _ in },
            onIsAtBottomChanged: { _ in })
        vc.view.layoutIfNeeded()
        spin(settle)
    }

    /// Hosts a fresh controller, runs `scenario`, then releases it and returns the weak handle plus its clock.
    private func runAndRelease(
        _ scenario: (ChatListViewController, UUID) -> Void
    ) -> (weakVC: ChatListViewController?, clock: StreamingDisplayClock, liveBeforeRelease: Int, runningBeforeRelease: Bool) {
        weak var weakVC: ChatListViewController?
        var clock: StreamingDisplayClock!
        var liveBeforeRelease = 0
        var runningBeforeRelease = false
        autoreleasepool {
            // Not hosted in a window: keeps UIKit appearance / window bookkeeping out of the release path,
            // so the only owner of the controller is this scope.
            let vc = ChatListViewController()
            vc.loadViewIfNeeded()
            vc.view.frame = CGRect(x: 0, y: 0, width: Self.width, height: Self.viewport)
            vc._testCompleteInitialAppearance()
            vc.view.layoutIfNeeded()
            weakVC = vc
            clock = vc._testDisplayClock
            scenario(vc, UUID())
            liveBeforeRelease = clock.subscriberCountForTesting
            runningBeforeRelease = clock.isRunning
        }
        spin(0.1)
        return (weakVC, clock, liveBeforeRelease, runningBeforeRelease)
    }

    /// Window-hosted variant: the controller is the root of a scene window, goes through viewDidAppear,
    /// then is removed (root cleared, window hidden and dropped) inside an autorelease pool, so neither
    /// the test scope nor autoreleased UIKit bookkeeping can keep it alive past the pool.
    private func runHostedAndRelease(
        _ scenario: (ChatListViewController, UUID) -> Void
    ) async throws -> (weakVC: ChatListViewController?, weakWindow: UIWindow?, clock: StreamingDisplayClock,
                       wasInWindow: Bool, liveBeforeRelease: Int, runningBeforeRelease: Bool) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        weak var weakVC: ChatListViewController?
        weak var weakWindow: UIWindow?
        var clock: StreamingDisplayClock!
        var wasInWindow = false
        var liveBeforeRelease = 0
        var runningBeforeRelease = false
        autoreleasepool {
            var window: UIWindow? = UIWindow(windowScene: scene)
            window?.frame = CGRect(x: 0, y: 0, width: Self.width, height: Self.viewport)
            let vc = ChatListViewController()
            window?.rootViewController = vc
            window?.makeKeyAndVisible()
            vc.view.layoutIfNeeded()
            // Let UIKit deliver viewDidAppear (it flushes the initial rebuild deferral on its own).
            spin(0.1)
            wasInWindow = vc.viewIfLoaded?.window != nil
            weakVC = vc
            weakWindow = window
            clock = vc._testDisplayClock
            scenario(vc, UUID())
            liveBeforeRelease = clock.subscriberCountForTesting
            runningBeforeRelease = clock.isRunning
            window?.rootViewController = nil
            window?.isHidden = true
            window = nil
        }
        // Suspend instead of spinning: UIKit's show / hide bookkeeping enqueues main-queue work that still
        // references the window (and, through it, the root controller). A nested run loop inside this
        // MainActor job cannot drain the main dispatch queue, so only a real suspension lets it run.
        try await Task.sleep(for: .milliseconds(200))
        return (weakVC, weakWindow, clock, wasInWindow, liveBeforeRelease, runningBeforeRelease)
    }

    @Test("Releasing the controller after the settle tick started leaves the clock unsubscribed and paused")
    func releaseDuringSettleTick() {
        let q1 = user("Question one")
        let a1 = assistant("Answer one that wraps onto multiple lines to give real measured height for this conversation.")
        let q2 = user("Question two")
        let a2ID = UUID()
        let result = runAndRelease { vc, convID in
            drive(vc, convID: convID, messages: [q1, a1], anchorID: nil, streamingID: nil, settle: 0.2)
            drive(vc, convID: convID, messages: [q1, a1, q2, assistant("", a2ID, state: .generating)],
                  anchorID: q2.id, streamingID: a2ID, settle: 0.2)
            // Streaming ends -> the ~0.7s settle tick starts; release well inside that window.
            drive(vc, convID: convID, messages: [q1, a1, q2, assistant("Short answer.", a2ID)],
                  anchorID: nil, streamingID: nil, settle: 0)
        }
        #expect(result.liveBeforeRelease > 0 && result.runningBeforeRelease,
                "settle tick should be live before release: subscribers=\(result.liveBeforeRelease) running=\(result.runningBeforeRelease)")
        #expect(result.weakVC == nil, "controller should deallocate once released")
        #expect(result.clock.subscriberCountForTesting == 0,
                "clock subscribers after release: \(result.clock.subscriberCountForTesting)")
        #expect(!result.clock.isRunning, "clock should be paused after release")
    }

    @Test("Releasing the controller while streaming leaves the clock unsubscribed and paused")
    func releaseDuringStreamingTick() {
        let q1 = user("Question one")
        let a1 = assistant("Answer one that wraps onto multiple lines to give real measured height for this conversation.")
        let q2 = user("Question two")
        let a2 = assistant("", state: .generating)
        let result = runAndRelease { vc, convID in
            drive(vc, convID: convID, messages: [q1, a1], anchorID: nil, streamingID: nil, settle: 0.2)
            drive(vc, convID: convID, messages: [q1, a1, q2, a2], anchorID: q2.id, streamingID: a2.id, settle: 0.2)
        }
        #expect(result.liveBeforeRelease > 0 && result.runningBeforeRelease,
                "streaming tick should be live before release: subscribers=\(result.liveBeforeRelease) running=\(result.runningBeforeRelease)")
        #expect(result.weakVC == nil, "controller should deallocate once released")
        #expect(result.clock.subscriberCountForTesting == 0,
                "clock subscribers after release: \(result.clock.subscriberCountForTesting)")
        #expect(!result.clock.isRunning, "clock should be paused after release")
    }

    @Test("Hosted controller with no update deallocates after removal from its window, clock unsubscribed")
    func hostedReleaseWithoutUpdate() async throws {
        let result = try await runHostedAndRelease { _, _ in }
        #expect(result.wasInWindow, "controller should be in a window before removal")
        #expect(result.weakWindow == nil, "window should deallocate once dropped")
        #expect(result.weakVC == nil, "hosted controller should deallocate once removed from its window")
        #expect(result.clock.subscriberCountForTesting == 0,
                "clock subscribers after release: \(result.clock.subscriberCountForTesting)")
        #expect(!result.clock.isRunning, "clock should be paused after release")
    }

    @Test("Hosted controller that streamed then settled deallocates after removal, clock unsubscribed")
    func hostedReleaseAfterStreamingThenSettled() async throws {
        let q1 = user("Question one")
        let a1 = assistant("Answer one that wraps onto multiple lines to give real measured height for this conversation.")
        let q2 = user("Question two")
        let a2ID = UUID()
        let result = try await runHostedAndRelease { vc, convID in
            drive(vc, convID: convID, messages: [q1, a1], anchorID: nil, streamingID: nil, settle: 0.2)
            drive(vc, convID: convID, messages: [q1, a1, q2, assistant("", a2ID, state: .generating)],
                  anchorID: q2.id, streamingID: a2ID, settle: 0.2)
            drive(vc, convID: convID, messages: [q1, a1, q2, assistant("Short answer.", a2ID)],
                  anchorID: nil, streamingID: nil, settle: 0)
        }
        #expect(result.wasInWindow, "controller should be in a window before removal")
        #expect(result.liveBeforeRelease > 0 && result.runningBeforeRelease,
                "settle tick should be live before removal: subscribers=\(result.liveBeforeRelease) running=\(result.runningBeforeRelease)")
        #expect(result.weakWindow == nil, "window should deallocate once dropped")
        #expect(result.weakVC == nil, "hosted controller should deallocate once removed from its window")
        #expect(result.clock.subscriberCountForTesting == 0,
                "clock subscribers after release: \(result.clock.subscriberCountForTesting)")
        #expect(!result.clock.isRunning, "clock should be paused after release")
    }
}
