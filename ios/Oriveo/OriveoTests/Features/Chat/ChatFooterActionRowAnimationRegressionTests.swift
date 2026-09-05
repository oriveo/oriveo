import Combine
import Testing
import UIKit
@testable import Oriveo

/// When an assistant message goes from generating to delivered, the footer action row (copy, save
/// as note, more, continue) is revealed for the first time. It occasionally appeared half-clipped
/// at the left edge of the screen and snapped back a frame later - and never reproduced after
/// leaving and re-entering the conversation.
///
/// Cause: finalizing inside the same conversation goes through the incremental diff path, where
/// `collectionView.reconfigureItems(at:)` runs `cellForItemAt` - and therefore
/// `AssistantMetadataView.configure`, which sets `actionRow.isHidden = false` - synchronously
/// inside the default animation context of `performBatchUpdates`. UIStackView deliberately animates
/// an `isHidden` toggle made inside an animation context, so an arranged subview that had never
/// been laid out (its frame still zero) was interpolated from the zero frame to its final one.
/// Re-entering the conversation uses `reloadData`, which has no such animation context, so
/// `isHidden` took effect without animating.
///
/// Fix: the non-prepend branch of the incremental update is wrapped in
/// `UIView.performWithoutAnimation`. This suite probes `actionRow.layer.animationKeys()` directly:
/// Core Animation registers the implicit animation key in the same run loop turn as the property
/// change, so the test can tell whether the toggle was captured by an animation context without
/// waiting for the animation to play.
@Suite("Footer action row is revealed without inheriting the batch animation")
@MainActor
struct ChatFooterActionRowAnimationRegressionTests {
    private static let width: CGFloat = 390
    private static let viewport: CGFloat = 844

    private func user(_ t: String, _ id: UUID = UUID()) -> ChatMessage {
        ChatMessage(id: id, role: .user, text: t, reasoningText: nil, providerKind: .openAI,
                    providerName: "OpenAI", modelName: "GPT-4o", estimatedCost: 0,
                    state: .delivered, attachments: nil, citations: nil)
    }

    private func assistant(_ t: String, _ id: UUID, state: ChatMessageState, cost: Double = 0) -> ChatMessage {
        ChatMessage(id: id, role: .assistant, text: t, reasoningText: nil, providerKind: .openAI,
                    providerName: "OpenAI", modelName: "GPT-5.5", estimatedCost: cost,
                    state: state, attachments: nil, citations: nil)
    }

    @Test("Finalize Reconfigure Does Not Animate Action Row Reveal")
    func finalizeReconfigureDoesNotAnimateActionRowReveal() {
        let vc = ChatListViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: Self.width, height: Self.viewport))
        window.rootViewController = vc
        window.makeKeyAndVisible()
        vc._testCompleteInitialAppearance()
        vc.view.layoutIfNeeded()
        defer { window.isHidden = true }

        let convID = UUID()
        let q1 = user("A question long enough that the answer has a real measured height for stable self-sizing.")
        let aID = UUID()

        func drive(messages: [ChatMessage], streamingID: UUID?) {
            let vm = ChatCollectionViewModel(
                conversationID: convID, messageRevision: UInt(messages.count) + (streamingID == nil ? 100 : 0),
                rows: ChatCollectionProjectionBuilder.makeRows(from: messages, metadata: .empty),
                isSendingMessage: streamingID != nil, streamingMessageID: streamingID, streamingText: "",
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
                onAnchorUserMessageConsumed: { _ in })
            vc.view.layoutIfNeeded()
        }

        let generating = assistant("The answer body…", aID, state: .generating)
        drive(messages: [q1, generating], streamingID: aID)

        guard let metadataViewDuringStreaming = vc._testAssistantMetadataView(for: aID) else {
            Issue.record("the assistant cell metadataView should already be reachable while streaming")
            return
        }
        _ = metadataViewDuringStreaming

        let delivered = assistant("The answer body…", aID, state: .delivered, cost: 0.18)
        drive(messages: [q1, delivered], streamingID: nil)

        guard let metadataView = vc._testAssistantMetadataView(for: aID) else {
            Issue.record("the assistant cell metadataView should be reachable after finalize")
            return
        }

        #expect(
            !metadataView._testActionRowHasImplicitAnimation,
            Comment(rawValue: "the action row reveal was captured by an implicit animation, so the buttons fly in from their zero frame - the left-edge flash")
        )
    }
}
