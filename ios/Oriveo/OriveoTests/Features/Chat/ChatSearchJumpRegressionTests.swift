import Combine
import Testing
import UIKit
@testable import Oriveo

/// Opening a conversation from a search result must land on the matched message instead of falling
/// back to the bottom of the current window.
///
/// The jump path is: the home screen writes `pendingSearchScrollTarget`, the chat screen resolves
/// it to a message id, and `MessageWindowLoader` loads the window around that message. The first
/// reload of the list must therefore skip the default scroll-to-bottom, or the matched message in
/// the middle is pushed out of the viewport by the messages loaded after it.
@Suite("Search result opens on the matched message")
@MainActor
struct ChatSearchJumpRegressionTests {
    private static let width: CGFloat = 390
    private static let viewport: CGFloat = 844
    private static let targetTolerance: CGFloat = 6.0
    private static let searchTargetTopPadding: CGFloat = 16.0

    private func makeUser(_ text: String, id: UUID = UUID()) -> ChatMessage {
        ChatMessage(
            id: id,
            role: .user,
            text: text,
            reasoningText: nil,
            providerKind: .openAI,
            providerName: "OpenAI",
            modelName: "GPT-4o",
            estimatedCost: 0,
            state: .delivered,
            attachments: nil,
            citations: nil
        )
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

    private func update(
        _ vc: ChatListViewController,
        convID: UUID,
        messages: [ChatMessage],
        searchTarget: PendingSearchScrollTarget?
    ) {
        let vm = ChatCollectionViewModel(
            conversationID: convID,
            messageRevision: 1,
            rows: ChatCollectionProjectionBuilder.makeRows(from: messages, metadata: .empty),
            isSendingMessage: false,
            streamingMessageID: nil,
            streamingText: "",
            pendingAnchorUserMessageID: nil,
            pendingSearchScrollTarget: searchTarget,
            isBootstrappingPersistedConversation: false,
            retryCapabilitySelection: ChatCapabilitySelection()
        )
        vc.update(
            viewModel: vm,
            providerMetadataVersion: 0,
            streamingPublisher: Empty<Void, Never>().eraseToAnyPublisher(),
            streamingReasoningPublisher: Empty<ReasoningStreamDelta, Never>().eraseToAnyPublisher(),
            streamingTextProvider: { "" },
            streamingReasoningSnapshotProvider: { nil },
            onRetry: { _ in },
            onContinue: { _ in },
            onRegenerate: { _ in },
            onEditMessage: { _ in },
            onSwitchModel: {},
            pendingAnchorUserMessageID: nil,
            onAnchorUserMessageConsumed: { _ in }
        )
        vc.view.layoutIfNeeded()
    }

    private func drainLayout(_ vc: ChatListViewController, seconds: TimeInterval = 1.0) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            vc.view.layoutIfNeeded()
        }
    }

    @Test("Initial Search Window Pins Matched Message Near Top")
    func initialSearchWindowPinsMatchedMessageNearTop() {
        let (vc, window) = makeController()
        defer { window.isHidden = true }
        let convID = UUID()
        let messages = (0..<60).map { index in
            makeUser("Search window message \(index) with enough text to make layout realistic.")
        }
        let target = messages[30]

        update(
            vc,
            convID: convID,
            messages: messages,
            searchTarget: PendingSearchScrollTarget(conversationID: convID, query: "message 30")
        )
        drainLayout(vc)

        guard let targetPosition = vc._testVisualPosition(of: target.id) else {
            Issue.record("the matched message was not rendered in the current window")
            return
        }
        let drift = abs(targetPosition - Self.searchTargetTopPadding)
        #expect(
            drift <= Self.targetTolerance,
            Comment(rawValue: "the match should sit near the top of the viewport, measured targetPosition=\(targetPosition), offset=\(vc._testContentOffsetY()), contentH=\(vc._testContentHeight())")
        )
    }
}
