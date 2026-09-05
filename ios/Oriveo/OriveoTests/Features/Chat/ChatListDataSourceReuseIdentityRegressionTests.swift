import Testing
import UIKit
@testable import Oriveo

/// "Attempted to dequeue a cell for a different registration or reuse identifier than the
/// existing cell when reconfiguring an item".
/// Reproduces a fatal `NSInternalInconsistencyException`: "Attempted to dequeue a cell for a
/// different registration or reuse identifier than the existing cell when reconfiguring an item".
///
/// The crash landed on the `dequeueReusableCell(withReuseIdentifier: userReuseID, ...)` call in the
/// `message.role == .user` branch of `cellForItemAt`, which means the cell already installed at that
/// index path was not registered as a user cell. The only way an index path could change
/// registration between two `cellForItemAt` calls was the defensive fallback taken when the model or
/// the render context was missing: it dequeued the assistant registration unconditionally, ignoring
/// the row's real role. If that fallback hit a user row it poisoned the index path with an assistant
/// registration; the next call passed the guard, dequeued `userReuseID` for the real role, and UIKit
/// raised because it did not match the existing cell.
///
/// Two layers of fix, one test each:
/// 1. the fallback in `ChatListDataSource.cellForItemAt` picks the reuse id from `message.role`, so
///    an index path gets a consistent reuse id whether or not the guard passes;
/// 2. `ChatListDataSource.computeDiff` falls back to a full reload whenever an id present in both
///    snapshots changes `presentationKind` (which decides the reuse id), so the reconfigure branch
///    only ever handles updates that keep the same registration.
@Suite("Chat list data source keeps reuse identifiers consistent")
@MainActor
struct ChatListDataSourceReuseIdentityRegressionTests {
    private func user(_ id: UUID = UUID(), _ t: String = "hello") -> ChatMessage {
        ChatMessage(id: id, role: .user, text: t, reasoningText: nil, providerKind: .openAI,
                    providerName: "OpenAI", modelName: "GPT-4o", estimatedCost: 0,
                    state: .delivered, attachments: nil, citations: nil)
    }

    private func assistant(_ id: UUID = UUID(), _ t: String = "answer", state: ChatMessageState = .delivered) -> ChatMessage {
        ChatMessage(id: id, role: .assistant, text: t, reasoningText: nil, providerKind: .openAI,
                    providerName: "OpenAI", modelName: "GPT-4o", estimatedCost: 0,
                    state: state, attachments: nil, citations: nil)
    }

    private func makeContext() -> ChatListDataSource.RenderContext {
        ChatListDataSource.RenderContext(
            parentViewController: UIViewController(),
            maxBubbleWidth: 300,
            onRetry: { _ in }, onContinue: { _ in },
            onRegenerate: { _ in }, onEditMessage: { _ in }, onSwitchModel: {},
            isSendingMessage: false,
            isErrorDismissed: { _ in false }, isRecoveryDetailExpanded: { _ in false },
            onDismissError: { _ in }, onToggleRecoveryDetail: { _, _ in },
            streamingMessageID: nil, onConfigureStreamingCell: { _ in }
        )
    }

    private func makeCollectionView() -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        let cv = UICollectionView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), collectionViewLayout: layout)
        ChatListDataSource.register(on: cv)
        return cv
    }

    @Test("Fallback Dequeues By Role Not Fixed Assistant")
    func fallbackDequeuesByRoleNotFixedAssistant() {
        let dataSource = ChatListDataSource()
        let cv = makeCollectionView()
        cv.dataSource = dataSource

        let uID = UUID()
        let rows = ChatCollectionProjectionBuilder.makeRows(from: [user(uID)], metadata: .empty)
        dataSource.commit(rows: rows, renderModels: [:], context: makeContext())

        let cell = dataSource.collectionView(cv, cellForItemAt: IndexPath(item: 0, section: 0))
        #expect(
            cell is UserMessageCell,
            Comment(rawValue: "the fallback cell for a user row must be a UserMessageCell; always returning the assistant " +
                    "registration poisons that index path, and the next reconfigure that dequeues userReuseID by role crashes")
        )
    }

    @Test("Fallback Dequeues Assistant For Assistant Row")
    func fallbackDequeuesAssistantForAssistantRow() {
        let dataSource = ChatListDataSource()
        let cv = makeCollectionView()
        cv.dataSource = dataSource

        let aID = UUID()
        let rows = ChatCollectionProjectionBuilder.makeRows(from: [assistant(aID)], metadata: .empty)
        dataSource.commit(rows: rows, renderModels: [:], context: makeContext())

        let cell = dataSource.collectionView(cv, cellForItemAt: IndexPath(item: 0, section: 0))
        #expect(cell is AssistantMessageCell)
    }

    @Test("Compute Diff Forces Full Reload On Presentation Kind Change")
    func computeDiffForcesFullReloadOnPresentationKindChange() {
        let dataSource = ChatListDataSource()
        let id = UUID()

        let oldRows = ChatCollectionProjectionBuilder.makeRows(from: [user(id, "old content")], metadata: .empty)
        let oldPlan = ChatCollectionProjectionBuilder.makeSnapshotPlan(from: oldRows, providerMetadataVersion: 0)
        dataSource.commit(rows: oldRows, renderModels: oldPlan.renderModelsByID, context: makeContext())

        let newRows = ChatCollectionProjectionBuilder.makeRows(from: [assistant(id, "old content")], metadata: .empty)
        let newPlan = ChatCollectionProjectionBuilder.makeSnapshotPlan(from: newRows, providerMetadataVersion: 0)

        let diff = dataSource.computeDiff(newRows: newRows, newRenderModels: newPlan.renderModelsByID)
        #expect(diff.requiresFullReload)
        #expect(diff.reconfigures.isEmpty)
        #expect(diff.deletes.isEmpty)
        #expect(diff.inserts.isEmpty)
    }

    @Test("Compute Diff Still Reconfigures Normal State Change")
    func computeDiffStillReconfiguresNormalStateChange() {
        let dataSource = ChatListDataSource()
        let id = UUID()

        let oldRows = ChatCollectionProjectionBuilder.makeRows(from: [assistant(id, "partial answer", state: .generating)], metadata: .empty)
        let oldPlan = ChatCollectionProjectionBuilder.makeSnapshotPlan(from: oldRows, providerMetadataVersion: 0)
        dataSource.commit(rows: oldRows, renderModels: oldPlan.renderModelsByID, context: makeContext())

        let newRows = ChatCollectionProjectionBuilder.makeRows(from: [assistant(id, "partial answer", state: .failed)], metadata: .empty)
        let newPlan = ChatCollectionProjectionBuilder.makeSnapshotPlan(from: newRows, providerMetadataVersion: 0)

        let diff = dataSource.computeDiff(newRows: newRows, newRenderModels: newPlan.renderModelsByID)
        #expect(!diff.requiresFullReload)
        #expect(diff.reconfigures == [0])
    }
}
