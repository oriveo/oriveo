import UIKit

@MainActor
final class ChatListDataSource: NSObject, UICollectionViewDataSource {
    static let assistantReuseID = "ChatAssistantMessageCell"
    static let userReuseID = "ChatUserMessageCell"

    struct RenderContext {
        weak var parentViewController: UIViewController?
        let maxBubbleWidth: CGFloat
        let onRetry: (ChatMessage) -> Void
        let onContinue: (ChatMessage) -> Void
        var onSaveNote: (ChatMessage) -> Void = { _ in }
        var onOpenNoteReferences: ([NoteSummary]) -> Void = { _ in }
        var onSaveSelection: (ChatMessage, String) -> Void = { _, _ in }
        var onAskSelection: (ChatMessage, QuoteSelectionContent) -> Void = { _, _ in }
        var canReplaceCurrentNoteSelection = false
        var onReplaceSelection: (ChatMessage, String) -> Void = { _, _ in }
        var onSaveCodeBlock: (ChatMessage, String, String?) -> Void = { _, _, _ in }
        let onRegenerate: (ChatMessage) -> Void
        let onEditMessage: (ChatMessage) -> Void
        let onSwitchModel: () -> Void
        let isSendingMessage: Bool
        let isErrorDismissed: (UUID) -> Bool
        let isRecoveryDetailExpanded: (UUID) -> Bool
        let onDismissError: (UUID) -> Void
        let onToggleRecoveryDetail: (UUID, Bool) -> Void
        let streamingMessageID: UUID?
        let onConfigureStreamingCell: (AssistantMessageCell) -> Void
    }

    private(set) var rows: [ChatCollectionProjectionBuilder.MessageRow] = []
    private var renderModelsByID: [UUID: ChatCollectionProjectionBuilder.MessageRenderModel] = [:]
    private var context: RenderContext?

    static func register(on collectionView: UICollectionView) {
        collectionView.register(AssistantMessageCell.self, forCellWithReuseIdentifier: assistantReuseID)
        collectionView.register(UserMessageCell.self, forCellWithReuseIdentifier: userReuseID)
    }

    func computeDiff(
        newRows: [ChatCollectionProjectionBuilder.MessageRow],
        newRenderModels: [UUID: ChatCollectionProjectionBuilder.MessageRenderModel]
    ) -> ChatListDiff.Result {
        let oldModels = self.renderModelsByID
        // "Attempted to dequeue a cell for a different registration or reuse identifier than the
        let oldIDSet = Set(self.rows.map(\.id))
        let hasPresentationKindChange = newRows.contains { row in
            guard oldIDSet.contains(row.id),
                  let old = oldModels[row.id],
                  let new = newRenderModels[row.id] else { return false }
            return old.presentationKind != new.presentationKind
        }
        if hasPresentationKindChange {
            return ChatListDiff.Result(deletes: [], inserts: [], reconfigures: [], requiresFullReload: true)
        }
        return ChatListDiff.diff(oldIDs: self.rows.map(\.id), newIDs: newRows.map(\.id)) { id in
            guard let old = oldModels[id], let new = newRenderModels[id] else { return false }
            return old != new
        }
    }

    func commit(
        rows: [ChatCollectionProjectionBuilder.MessageRow],
        renderModels: [UUID: ChatCollectionProjectionBuilder.MessageRenderModel],
        context: RenderContext
    ) {
        self.rows = rows
        self.renderModelsByID = renderModels
        self.context = context
    }

    // MARK: - UICollectionViewDataSource

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        rows.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        guard indexPath.item < rows.count else {
            return collectionView.dequeueReusableCell(
                withReuseIdentifier: Self.assistantReuseID, for: indexPath
            )
        }

        let row = rows[indexPath.item]
        let message = row.message

        // "Attempted to dequeue a cell for a different registration or reuse identifier than the
        guard let model = renderModelsByID[row.id],
              let context,
              let parentViewController = context.parentViewController else {
            let fallbackReuseID = message.role == .user ? Self.userReuseID : Self.assistantReuseID
            return collectionView.dequeueReusableCell(
                withReuseIdentifier: fallbackReuseID, for: indexPath
            )
        }

        let messageID = model.messageID

        if message.role == .user {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: Self.userReuseID, for: indexPath
            ) as! UserMessageCell
            cell.configure(
                model: model,
                maxBubbleWidth: context.maxBubbleWidth,
                parentViewController: parentViewController,
                onSaveNote: { context.onSaveNote(message) },
                onSaveSelection: { text in context.onSaveSelection(message, text) },
                onAskSelection: { content in context.onAskSelection(message, content) },
                onOpenNoteReferences: model.noteReferences.isEmpty
                    ? nil
                    : { context.onOpenNoteReferences(model.noteReferences) }
            )
            return cell
        }

        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: Self.assistantReuseID, for: indexPath
        ) as! AssistantMessageCell
        let canReplaceSelection = ChatNoteReferences.canShowReplaceSelection(
            canReplaceCurrentNoteSelection: context.canReplaceCurrentNoteSelection,
            noteReferences: model.noteReferences
        )
        let replaceSelection: ((String) -> Void)? = message.state == .delivered && canReplaceSelection
            ? { text in context.onReplaceSelection(message, text) }
            : nil

        cell.configure(
            model: model,
            parentViewController: parentViewController,
            onContentHeightDidChange: nil,
            onRetry: { context.onRetry(message) },
            onContinue: { context.onContinue(message) },
            onSaveNote: { context.onSaveNote(message) },
            onOpenNoteReferences: model.noteReferences.isEmpty
                ? nil
                : { context.onOpenNoteReferences(model.noteReferences) },
            onSaveSelection: { text in context.onSaveSelection(message, text) },
            onAskSelection: message.state == .generating
                || message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : { content in context.onAskSelection(message, content) },
            onReplaceSelection: replaceSelection,
            onSaveCodeBlock: { code, lang in context.onSaveCodeBlock(message, code, lang) }
        )
        // `notifyContentDidChange` → `invalidateIntrinsicContentSize` → ChatLayout `supportSelfSizingInvalidation`
        if let config = AssistantMessageRecoveryBuilder.makeConfig(
            for: model,
            isSendingMessage: context.isSendingMessage,
            isDismissed: context.isErrorDismissed(messageID),
            isTechnicalDetailExpanded: context.isRecoveryDetailExpanded(messageID),
            onRetry: { context.onRetry(message) },
            onContinue: { context.onContinue(message) },
            onRegenerate: { context.onRegenerate(message) },
            onEditMessage: { context.onEditMessage(message) },
            onSwitchModelRequested: { context.onSwitchModel() },
            onDismiss: { context.onDismissError(messageID) },
            onTechnicalDetailVisibilityChanged: { expanded in
                context.onToggleRecoveryDetail(messageID, expanded)
            }
        ) {
            cell.embedRecoveryCard(config)
        }
        if model.isStreaming, messageID == context.streamingMessageID {
            context.onConfigureStreamingCell(cell)
        }
        return cell
    }
}
