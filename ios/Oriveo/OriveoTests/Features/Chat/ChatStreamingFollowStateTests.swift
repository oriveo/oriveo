import Combine
import Testing
import UIKit
@testable import Oriveo

/// Sending a message must leave `isFollowing` false for the whole streaming phase.
///
/// The defect: `sendBegan` set `isFollowing = true` unconditionally, which kept
/// `keepContentAtBottomOfVisibleArea` engaged and fought the lag of cell self-sizing, so the entire
/// transcript jittered at display rate while streaming. Sending and the scroll-to-bottom button
/// scroll once; they do not enable continuous following.
@Suite("Streaming does not follow continuously")
@MainActor
struct ChatStreamingFollowStateTests {
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

    @Test("Send Does Not Persist Follow During Streaming")
    func sendDoesNotPersistFollowDuringStreaming() {
        let vc = ChatListViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: Self.width, height: Self.viewport))
        window.rootViewController = vc
        window.makeKeyAndVisible()
        vc._testCompleteInitialAppearance()
        vc.view.layoutIfNeeded()
        defer { window.isHidden = true }

        var reported: [Bool] = []
        let convID = UUID()
        let q1 = user("Question one")
        let a1 = assistant("Answer one that wraps onto multiple lines to give real measured height for the history of this conversation.")

        func drive(messages: [ChatMessage], anchorID: UUID?, streamingID: UUID?) {
            let vm = ChatCollectionViewModel(
                conversationID: convID, messageRevision: UInt(messages.count),
                rows: ChatCollectionProjectionBuilder.makeRows(from: messages, metadata: .empty),
                isSendingMessage: anchorID != nil, streamingMessageID: streamingID, streamingText: "",
                pendingAnchorUserMessageID: anchorID, pendingSearchScrollTarget: nil,
                isBootstrappingPersistedConversation: false,
                retryCapabilitySelection: ChatCapabilitySelection())
            vc.update(
                viewModel: vm, providerMetadataVersion: 0,
                streamingPublisher: Empty<Void, Never>().eraseToAnyPublisher(),
                streamingReasoningPublisher: Empty<ReasoningStreamDelta, Never>().eraseToAnyPublisher(),
                streamingTextProvider: { "" }, streamingReasoningSnapshotProvider: { nil },
                onRetry: { _ in }, onContinue: { _ in }, onRegenerate: { _ in },
                onEditMessage: { _ in }, onSwitchModel: {},
                pendingAnchorUserMessageID: anchorID, onAnchorUserMessageConsumed: { _ in },
                onIsAtBottomChanged: { reported.append($0) })
            vc.view.layoutIfNeeded()
            let deadline = Date().addingTimeInterval(0.4)
            while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        }

        drive(messages: [q1, a1], anchorID: nil, streamingID: nil)
        reported.removeAll()

        let q2 = user("Question two")
        let a2 = assistant("", state: .generating)
        drive(messages: [q1, a1, q2, a2], anchorID: q2.id, streamingID: a2.id)

        #expect(reported.last == false,
                Comment(rawValue: "isFollowing must be false while streaming, reported sequence=\(reported)"))
        #expect(!reported.contains(true),
                Comment(rawValue: "isFollowing must never flip to true between send and the end of streaming, reported=\(reported)"))
    }

    @Test("Reconcile Tick Skips During Interaction")
    func reconcileTickSkipsDuringInteraction() {
        #expect(ChatListViewController.shouldRunReconcileTick(isDragging: false, isDecelerating: false))
        #expect(!ChatListViewController.shouldRunReconcileTick(isDragging: true, isDecelerating: false))
        #expect(!ChatListViewController.shouldRunReconcileTick(isDragging: false, isDecelerating: true))
        #expect(!ChatListViewController.shouldRunReconcileTick(isDragging: true, isDecelerating: true))
    }
}
