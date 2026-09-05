import Combine
import Testing
import UIKit
@testable import Oriveo

/// Returning to a conversation from a note must still land on the anchor message when the initial
/// rebuild is deferred.
///
/// In an expensive conversation the outline scroll request that locates the anchor arrives while
/// `dataSource.rows` is still empty because the initial rebuild is deferred during the transition.
/// The request used to be dropped silently and never retried, so after the flush the view
/// degenerated into a scroll to the bottom and the anchor was neither located nor highlighted.
///
/// Fix: `handleOutlineScrollRequest` parks the request while the rows are not committed, and
/// `rebuildIfReady` replays it through `consumePendingOutlineScroll` at the same deferral-safe
/// point the search target uses.
@Suite("Note jump survives a deferred initial rebuild")
@MainActor
struct ChatNoteJumpDeferralRegressionTests {
    private static let width: CGFloat = 390
    private static let viewport: CGFloat = 844
    private static let topPadding: CGFloat = 16
    private static let tolerance: CGFloat = 20

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

    private func openWithNoteJump(_ vc: ChatListViewController, convID: UUID,
                                  messages: [ChatMessage], anchorID: UUID) {
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
            outlineScrollRequest: 1, outlineScrollMessageID: anchorID, outlineScrollShouldFlash: true)
        vc.view.layoutIfNeeded()
    }

    private func drainSettle(_ vc: ChatListViewController, seconds: TimeInterval = 1.2) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            vc.view.layoutIfNeeded()
        }
    }

    private func giant() -> ChatMessage {
        makeAssistant("```swift\n" + String(repeating: "This is a very long reply body.\n", count: 800) + "```")
    }

    @Test("Note Anchor Survives Deferral And Locates After Flush")
    func noteAnchorSurvivesDeferralAndLocatesAfterFlush() {
        let (vc, window) = makeController()
        defer { window.isHidden = true }

        let anchor = makeUser("take me back to this question")
        let tail = (0..<60).map { _ in makeAssistant("assistant") }
        let messages = [giant(), anchor] + tail
        let convID = UUID()

        openWithNoteJump(vc, convID: convID, messages: messages, anchorID: anchor.id)
        #expect(vc._testNumberOfItems() == 0,
                Comment(rawValue: "an expensive conversation must defer the initial rebuild (built \(vc._testNumberOfItems()) cells)"))

        vc._testEndTransitionDeferral()
        drainSettle(vc)

        #expect(vc._testNumberOfItems() == messages.count,
                Comment(rawValue: "the rebuild must complete after the flush (built \(vc._testNumberOfItems()) cells)"))
        guard let pos = vc._testVisualPosition(of: anchor.id) else {
            Issue.record("the anchor message was not rendered, or the jump was dropped")
            return
        }
        #expect(abs(pos - Self.topPadding) <= Self.tolerance,
                Comment(rawValue: "the anchor should land near the top of the viewport (around 16pt), measured pos=\(pos), offset=\(vc._testContentOffsetY()); a large negative pos means the jump was dropped and the list scrolled to the bottom"))
    }
}
