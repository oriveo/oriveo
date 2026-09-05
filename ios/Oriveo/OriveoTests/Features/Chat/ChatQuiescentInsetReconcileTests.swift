import Combine
import Testing
import UIKit
@testable import Oriveo

/// A cell that grows again while the list is quiescent must trigger a bottom-inset recalculation.
///
/// Scenario: after a send the anchor is pinned to the top and the bottom inset makes
/// `maxOffset == anchorTopY`, so the list cannot be dragged any further. If a cell grows after the
/// post-streaming settle window - a finished code block or table remeasuring asynchronously, LaTeX
/// or an image landing, an edited message re-rendering - nothing used to recompute the inset. The
/// content height grew while the inset stayed, `maxOffset` went past the pinned position and the
/// difference became empty space the user could drag into.
///
/// The fix funnels all of those through the content-size observation installed in `viewDidLoad`
/// (`scheduleQuiescentInsetReconcile`). This suite simulates the growth with an incremental
/// reconfigure that lengthens a message, since every source ends up on the same path.
@Suite("Quiescent inset reconcile leaves no draggable slack")
@MainActor
struct ChatQuiescentInsetReconcileTests {
    private static let width: CGFloat = 390
    private static let viewport: CGFloat = 844
    private static let tolerance: CGFloat = 2.0

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
    private func update(
        _ vc: ChatListViewController,
        convID: UUID,
        revision: UInt,
        messages: [ChatMessage],
        pendingAnchorID: UUID? = nil
    ) {
        let vm = ChatCollectionViewModel(
            conversationID: convID, messageRevision: revision,
            rows: ChatCollectionProjectionBuilder.makeRows(from: messages, metadata: .empty),
            isSendingMessage: false, streamingMessageID: nil, streamingText: "",
            pendingAnchorUserMessageID: pendingAnchorID, pendingSearchScrollTarget: nil,
            isBootstrappingPersistedConversation: false,
            retryCapabilitySelection: ChatCapabilitySelection())
        vc.update(
            viewModel: vm, providerMetadataVersion: 0,
            streamingPublisher: Empty<Void, Never>().eraseToAnyPublisher(),
            streamingReasoningPublisher: Empty<ReasoningStreamDelta, Never>().eraseToAnyPublisher(),
            streamingTextProvider: { "" }, streamingReasoningSnapshotProvider: { nil },
            onRetry: { _ in }, onContinue: { _ in }, onRegenerate: { _ in },
            onEditMessage: { _ in }, onSwitchModel: {},
            pendingAnchorUserMessageID: pendingAnchorID, onAnchorUserMessageConsumed: { _ in })
        vc.view.layoutIfNeeded()
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            vc.view.layoutIfNeeded()
        }
    }

    private func slackBeyondAnchor(_ vc: ChatListViewController, anchorID: UUID) -> CGFloat? {
        guard let visual = vc._testVisualPosition(of: anchorID) else { return nil }
        let anchorTopY = visual + vc._testContentOffsetY()
        let maxOffset = vc._testContentHeight() + vc._testBottomInset() - vc._testCollectionBoundsHeight()
        return maxOffset - anchorTopY
    }

    @Test("Late Growth Reconciles Inset Back To Anchor")
    func lateGrowthReconcilesInsetBackToAnchor() {
        let (vc, window) = makeController()
        defer { window.isHidden = true }
        let convID = UUID()
        var msgs: [ChatMessage] = []
        for i in 0..<4 {
            msgs.append(makeUser("Earlier question \(i), long enough to give the conversation some scrollable height."))
            msgs.append(makeAssistant("Earlier answer \(i), also a few lines long so it contributes to the anchor position."))
        }
        update(vc, convID: convID, revision: 1, messages: msgs)

        let q = makeUser("the new question, which is the anchor")
        let aID = UUID()
        msgs.append(q)
        msgs.append(makeAssistant("A short answer.", id: aID))
        update(vc, convID: convID, revision: 2, messages: msgs, pendingAnchorID: q.id)
        let slackAfterPin = slackBeyondAnchor(vc, anchorID: q.id)
        #expect(slackAfterPin != nil)
        if let slackAfterPin {
            #expect(abs(slackAfterPin) <= Self.tolerance,
                    Comment(rawValue: "after pinning, the list must be fully scrolled (slack around 0), measured \(slackAfterPin)"))
        }

        msgs[msgs.count - 1] = makeAssistant(
            "A short answer that later grew: this simulates a finished code block or table remeasuring "
                + "asynchronously after the settle window closes. The text is long enough that the cell height "
                + "increases noticeably, the content size change triggers one quiescent reconcile, and the bottom "
                + "inset must shrink with it - otherwise the extra height is draggable empty space.",
            id: aID)
        update(vc, convID: convID, revision: 3, messages: msgs)

        let slackAfterGrowth = slackBeyondAnchor(vc, anchorID: q.id)
        #expect(slackAfterGrowth != nil)
        if let slackAfterGrowth {
            #expect(abs(slackAfterGrowth) <= Self.tolerance,
                    Comment(rawValue: "growing while quiescent without recomputing the inset leaves draggable slack: slack=\(slackAfterGrowth) (expected around 0)"))
        }
        let anchorVisual = vc._testVisualPosition(of: q.id)
        #expect(anchorVisual != nil)
        if let anchorVisual {
            #expect(abs(anchorVisual) <= 40,
                    Comment(rawValue: "recomputing after growth must not move the viewport: anchor at \(anchorVisual) (expected around 0, the top of the viewport)"))
        }
    }
}
