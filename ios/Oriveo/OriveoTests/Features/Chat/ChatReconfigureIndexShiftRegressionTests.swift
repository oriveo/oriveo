import Combine
import Testing
import UIKit
@testable import Oriveo

/// Regression for a fatal crash: while a conversation opens, history pages are written continuously, so a
/// prepend and a content update of an on-screen message land in the same `performBatchUpdates`, and
/// `reconfigureItems` throws "Attempted to dequeue a cell for a different registration or reuse identifier
/// than the existing cell when reconfiguring an item" (dequeued ChatUserMessageCell, original
/// ChatAssistantMessageCell).
///
/// Root cause: a reconfigure inside the batch closure is executed by UIKit **immediately**: it takes the
/// existing cell by the given index in the pre-update visible table, then asks the already-committed
/// dataSource with the same number. The old code passed old indexes, so a row shifted by an insert or delete
/// in the same batch was mismatched: with the same role the cell silently showed another message, with a
/// different role it crashed.
///
/// These go through the production entry `ChatListViewController.update` and assert that the on-screen cell
/// is bound to the message of its row; the odd-count prepend case crashed before the fix.
@Suite("reconfigure shifted by an insert or delete in the same batch does not mismatch cells")
@MainActor
struct ChatReconfigureIndexShiftRegressionTests {
    private static let width: CGFloat = 390
    private static let viewport: CGFloat = 844

    private func user(_ text: String) -> ChatMessage {
        ChatMessage(id: UUID(), role: .user, text: text, reasoningText: nil,
                    providerKind: .openAI, providerName: "OpenAI", modelName: "GPT-4o",
                    estimatedCost: 0, state: .delivered, attachments: nil, citations: nil)
    }

    private func assistant(_ text: String) -> ChatMessage {
        ChatMessage(id: UUID(), role: .assistant, text: text, reasoningText: nil,
                    providerKind: .openAI, providerName: "OpenAI", modelName: "GPT-4o",
                    estimatedCost: 0, state: .delivered, attachments: nil, citations: nil)
    }

    private func pairs(_ count: Int, prefix: String) -> [ChatMessage] {
        (0..<count).flatMap { i in
            [user("\(prefix)Q-\(i) a question that wraps to two lines for self-size."),
             assistant("\(prefix)A-\(i) an answer that spans multiple lines so the cell needs real self-sizing.")]
        }
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

    private func runLoop(_ seconds: TimeInterval, _ vc: ChatListViewController) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            vc.view.layoutIfNeeded()
        }
    }

    private func update(_ vc: ChatListViewController, convID: UUID, revision: UInt,
                        messages: [ChatMessage], hasMoreAbove: Bool = false) {
        let vm = ChatCollectionViewModel(
            conversationID: convID, messageRevision: revision,
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
            pendingAnchorUserMessageID: nil, onAnchorUserMessageConsumed: { _ in },
            hasMoreAbove: hasMoreAbove)
        vc.view.layoutIfNeeded()
    }

    /// Stay at the top so the first messages' cells are on screen (reconfigure only affects on-screen cells).
    private func settleAtTop(_ vc: ChatListViewController, convID: UUID, messages: [ChatMessage]) {
        update(vc, convID: convID, revision: 1, messages: messages, hasMoreAbove: true)
        runLoop(1.0, vc)
        vc._testSetContentOffset(0)
        vc.view.layoutIfNeeded()
    }

    private func edited(_ message: ChatMessage, _ suffix: String) -> ChatMessage {
        var m = message
        m.text += suffix
        return m
    }

    /// The reconfigured assistant row: its on-screen cell must still be bound to itself.
    private func expectBound(_ vc: ChatListViewController, _ id: UUID, sourceLocation: SourceLocation = #_sourceLocation) {
        let cell = vc._testCellForMessage(id) as? AssistantMessageCell
        #expect(cell != nil, "The target row should be on screen as an AssistantMessageCell", sourceLocation: sourceLocation)
        #expect(cell?.boundMessageID == id,
                "The on-screen cell is bound to another message \(String(describing: cell?.boundMessageID)), expected \(id)",
                sourceLocation: sourceLocation)
    }

    @Test("an even-count prepend plus a content update of an on-screen assistant keeps every cell bound to its own message")
    func evenPrependWithReconfigureKeepsCellBinding() {
        let (vc, window) = makeController()
        defer { window.isHidden = true }
        let convID = UUID()
        let initial = pairs(20, prefix: "")
        settleAtTop(vc, convID: convID, messages: initial)
        let target = initial[1]
        expectBound(vc, target.id)

        var merged = pairs(1, prefix: "H-") + initial
        merged[3] = edited(target, " (page appended)")
        update(vc, convID: convID, revision: 2, messages: merged)
        runLoop(0.5, vc)

        #expect(vc._testPrependGeometryRecoveryCount() == 0, "This case must not take the full rebuild path (it would hide the mismatch)")
        expectBound(vc, target.id)
    }

    @Test("an odd-count prepend plus a content update of an on-screen assistant does not throw the reuse identifier crash")
    func oddPrependWithReconfigureDoesNotCrash() {
        let (vc, window) = makeController()
        defer { window.isHidden = true }
        let convID = UUID()
        let initial = pairs(20, prefix: "")
        settleAtTop(vc, convID: convID, messages: initial)
        let target = initial[1]

        // Prepend a single message: old index 1 (assistant) lands on a user row in the new data.
        var merged = [assistant("H-A an older answer whose question is outside the window.")] + initial
        merged[2] = edited(target, " (page appended)")
        update(vc, convID: convID, revision: 2, messages: merged)
        runLoop(0.5, vc)

        #expect(vc._testPrependGeometryRecoveryCount() == 0)
        expectBound(vc, target.id)
    }

    @Test("non-prepend: a delete at the top plus a content update of an on-screen assistant keeps every cell bound to its own message")
    func deleteShiftWithReconfigureKeepsCellBinding() {
        let (vc, window) = makeController()
        defer { window.isHidden = true }
        let convID = UUID()
        let initial = pairs(20, prefix: "")
        settleAtTop(vc, convID: convID, messages: initial)
        let target = initial[3]
        expectBound(vc, target.id)

        // Drop the first pair (window slides down or a remote delete) and edit initial[3] in the same
        // update: old index 3 becomes new index 1.
        var next = Array(initial.dropFirst(2))
        next[1] = edited(target, " (synced edit)")
        update(vc, convID: convID, revision: 2, messages: next)
        runLoop(0.5, vc)

        expectBound(vc, target.id)
    }
}
