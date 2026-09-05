import Combine
import Testing
import UIKit
@testable import Oriveo

/// .reconfigureItems` ← `applyIncrementalUpdate` 970/988 ← `rebuildIfReady` 931 ← `update` 458)
/// registration or reuse identifier than the existing cell when reconfiguring an item".
/// Reproduces a fatal crash: when an assistant message goes straight from streaming to failed
/// because the provider request failed, the in-conversation incremental reconfigure in
/// `ChatListViewController.applyIncrementalUpdate` raised `NSInternalInconsistencyException`:
/// "Attempted to dequeue a cell for a different registration or reuse identifier than the existing
/// cell when reconfiguring an item".
///
/// Compare with `ChatFooterActionRowAnimationRegressionTests`, which drives the same reconfigure
/// path for generating to delivered and only leaves an animation artefact. This suite drives
/// generating to **failed**: same id, same position, no inserts or deletes, a pure reconfigure. It
/// asserts that no exception is raised and that the cell is still the same `AssistantMessageCell`
/// instance, which is the reconfigure contract - the cell is kept and only its content is refreshed.
@Suite("Reconfiguring into the failed state does not crash")
@MainActor
struct ChatReconfigureFailedTransitionRegressionTests {
    private static let width: CGFloat = 390
    private static let viewport: CGFloat = 844

    private func user(_ t: String, _ id: UUID = UUID()) -> ChatMessage {
        ChatMessage(id: id, role: .user, text: t, reasoningText: nil, providerKind: .openAI,
                    providerName: "OpenAI", modelName: "GPT-4o", estimatedCost: 0,
                    state: .delivered, attachments: nil, citations: nil)
    }

    private func assistant(
        _ t: String, _ id: UUID, state: ChatMessageState,
        errorTitle: String? = nil, errorDetail: String? = nil,
        reasoningDurationMs: Int64? = nil
    ) -> ChatMessage {
        var m = ChatMessage(id: id, role: .assistant, text: t, reasoningText: nil, providerKind: .grok,
                             providerName: "xAI", modelName: "Grok-4", estimatedCost: 0,
                             state: state, attachments: nil, citations: nil)
        m.errorTitle = errorTitle
        m.errorDetail = errorDetail
        m.reasoningDurationMs = reasoningDurationMs
        return m
    }

    private func spin(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    @Test("Finalize To Failed Reconfigure Does Not Crash")
    func finalizeToFailedReconfigureDoesNotCrash() {
        let vc = ChatListViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: Self.width, height: Self.viewport))
        window.rootViewController = vc
        window.makeKeyAndVisible()
        vc._testCompleteInitialAppearance()
        vc.view.layoutIfNeeded()
        defer { window.isHidden = true }

        let convID = UUID()
        let q1 = user("A first question, long enough to give a stable measured height for self-sizing.")
        let a1ID = UUID()
        let a1 = assistant("A first answer, delivered normally, so the conversation is not empty.", a1ID, state: .delivered)
        let q2 = user("A second question about a longer technical topic, so the answer has real length.")
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

        let longPartial = String(repeating: "Partially generated answer text, simulating a realistically long output.", count: 8)
        let generating = assistant(longPartial, aID, state: .generating)
        drive(messages: [q1, a1, q2, generating], streamingID: aID)
        spin(0.2)

        guard let cellDuringStreaming = vc._testCellForMessage(aID) else {
            Issue.record("the assistant cell should already be reachable while streaming")
            return
        }
        #expect(cellDuringStreaming is AssistantMessageCell)

        let generatingWithReasoning = assistant(longPartial, aID, state: .generating, reasoningDurationMs: 1200)
        drive(messages: [q1, a1, q2, generatingWithReasoning], streamingID: aID)
        spin(0.1)

        let failed = assistant(
            longPartial, aID, state: .failed,
            errorTitle: "Send Failed", errorDetail: "the provider returned 400 Bad Request",
            reasoningDurationMs: 1200
        )
        drive(messages: [q1, a1, q2, failed], streamingID: nil)
        spin(0.3)

        guard let cellAfterFailure = vc._testCellForMessage(aID) else {
            Issue.record("the assistant cell should still exist after the failure; the reconfigure must not drop the row")
            return
        }
        #expect(
            cellAfterFailure is AssistantMessageCell,
            Comment(rawValue: "after the reconfigure the cell for this id must still be an AssistantMessageCell - a different type is exactly the reuse-identifier mismatch that crashes")
        )
        #expect(
            cellAfterFailure === cellDuringStreaming,
            Comment(rawValue: "reconfigure contract: the cell instance for the same id must not be replaced, or state other than the recovery card is lost")
        )
    }
}
