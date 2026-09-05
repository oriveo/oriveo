import Combine
import Testing
import UIKit
@testable import Oriveo

/// Sending the first message in a brand new conversation occasionally left the list blank.
///
/// Symptom: after the first message is sent, the whole message list is empty and only the toolbar
/// (which lives outside the collection view) is visible.
///
/// Two independent defects:
/// - **A. the obligation to reveal the list was attached to a settle loop that could be
///   invalidated.** After the first reload the list starts at `alpha = 0` and is revealed once the
///   settle loop inside `scrollToBottomEnsuringFullLayout` settles. That loop is invalidated by
///   generation, so any call that bumps the generation (a keyboard or frame
///   `reconcileViewportChange`, jump-to-latest) took the loop over: the old loop exited silently on
///   the generation mismatch without revealing, and the loop that took over did not reveal either,
///   so alpha stayed at 0 forever. The fix moves the obligation onto an instance flag
///   (`isAwaitingReveal`) that every terminating branch of every settle loop honours, so it is
///   handed to whichever loop takes over and can never be dropped.
/// - **B. `reset()` cleared `isStreamingMode` while streaming was in progress.** When the first
///   message is sent `streamingMessageID` is already set and `update()` has already called
///   `setStreamingMode(true)`, but `stickController.reset()` on the initial branch of
///   `rebuildIfReady` cleared it again. In the window before the next `update()` restored it,
///   `isStreamingMode == false` with `isFollowing == true` made
///   `reconcileViewportChangeEnsuringFullLayout` believe it was a non-streaming bottom state, bump
///   the generation and take over the reveal loop. The fix re-arms streaming mode right after
///   `reset()` when streaming is still in progress.
@Suite("First message in a new conversation reveals the list")
@MainActor
struct ChatBlankScreenRevealRegressionTests {
    private static let width: CGFloat = 390
    private static let viewport: CGFloat = 844

    private func makeUser(_ text: String, id: UUID = UUID()) -> ChatMessage {
        ChatMessage(id: id, role: .user, text: text, reasoningText: nil,
                    providerKind: .openAI, providerName: "OpenAI", modelName: "GPT-4o",
                    estimatedCost: 0, state: .delivered, attachments: nil, citations: nil)
    }
    private func makeAssistant(_ text: String, id: UUID = UUID(), generating: Bool = false) -> ChatMessage {
        ChatMessage(id: id, role: .assistant, text: text, reasoningText: nil,
                    providerKind: .openAI, providerName: "OpenAI", modelName: "GPT-4o",
                    estimatedCost: 0, state: generating ? .generating : .delivered,
                    attachments: nil, citations: nil)
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

    private func firstSendUpdate(
        _ vc: ChatListViewController,
        convID: UUID,
        user: ChatMessage,
        assistant: ChatMessage
    ) {
        let vm = ChatCollectionViewModel(
            conversationID: convID, messageRevision: 1,
            rows: ChatCollectionProjectionBuilder.makeRows(from: [user, assistant], metadata: .empty),
            isSendingMessage: true, streamingMessageID: assistant.id, streamingText: "",
            pendingAnchorUserMessageID: user.id, pendingSearchScrollTarget: nil,
            isBootstrappingPersistedConversation: false,
            retryCapabilitySelection: ChatCapabilitySelection())
        vc.update(
            viewModel: vm, providerMetadataVersion: 0,
            streamingPublisher: Empty<Void, Never>().eraseToAnyPublisher(),
            streamingReasoningPublisher: Empty<ReasoningStreamDelta, Never>().eraseToAnyPublisher(),
            streamingTextProvider: { "" }, streamingReasoningSnapshotProvider: { nil },
            onRetry: { _ in }, onContinue: { _ in }, onRegenerate: { _ in },
            onEditMessage: { _ in }, onSwitchModel: {},
            pendingAnchorUserMessageID: user.id, onAnchorUserMessageConsumed: { _ in })
    }

    private func drainSettle(_ vc: ChatListViewController, seconds: TimeInterval = 1.2) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            vc.view.layoutIfNeeded()
        }
    }

    @Test("Reset Keeps Active Streaming Mode")
    func resetKeepsActiveStreamingMode() {
        let (vc, window) = makeController()
        defer { window.isHidden = true }
        let convID = UUID()
        let user = makeUser("the first message")
        let assistant = makeAssistant("", generating: true)

        firstSendUpdate(vc, convID: convID, user: user, assistant: assistant)

        #expect(vc._testIsStreamingMode() == true,
                Comment(rawValue: "reset() cleared active streaming back to false, so the trigger window is still open"))
    }

    @Test("Reveal Survives Competing Settle Generation Bump")
    func revealSurvivesCompetingSettleGenerationBump() {
        let (vc, window) = makeController()
        defer { window.isHidden = true }
        let convID = UUID()
        let user = makeUser("the first message")
        let assistant = makeAssistant("", generating: true)

        firstSendUpdate(vc, convID: convID, user: user, assistant: assistant)

        #expect(vc._testCollectionViewAlpha() == 0,
                Comment(rawValue: "the first render must start hidden, measured alpha=\(vc._testCollectionViewAlpha())"))

        vc._testTriggerCompetingScrollSettle()
        drainSettle(vc)

        #expect(vc._testCollectionViewAlpha() == 1,
                Comment(rawValue: "a competing scroll-to-bottom took over and alpha stayed at 0, leaving the list blank. Measured alpha=\(vc._testCollectionViewAlpha())"))
    }

    @Test("Reveal Happens On Normal First Send")
    func revealHappensOnNormalFirstSend() {
        let (vc, window) = makeController()
        defer { window.isHidden = true }
        let convID = UUID()
        let user = makeUser("the first message")
        let assistant = makeAssistant("", generating: true)

        firstSendUpdate(vc, convID: convID, user: user, assistant: assistant)
        drainSettle(vc)

        #expect(vc._testCollectionViewAlpha() == 1,
                Comment(rawValue: "a normal first send must reveal the list once it settles, measured alpha=\(vc._testCollectionViewAlpha())"))
    }

    @Test("First Send Settle Lands At Anchor Not In Runway Blank")
    func firstSendSettleLandsAtAnchorNotInRunwayBlank() {
        let (vc, window) = makeController()
        defer { window.isHidden = true }
        let convID = UUID()
        let user = makeUser("the first message")
        let assistant = makeAssistant("", generating: true)

        firstSendUpdate(vc, convID: convID, user: user, assistant: assistant)
        drainSettle(vc)

        let offset = vc._testContentOffsetY()
        let contentH = vc._testContentHeight()
        #expect(offset < contentH,
                Comment(rawValue: "the viewport scrolled past the bottom of the content, so the screen is blank. offset=\(offset) contentH=\(contentH)"))
        #expect(offset <= 40,
                Comment(rawValue: "the first send should land on the anchor (the top of the user message, around 0), measured offset=\(offset)"))
    }
}
