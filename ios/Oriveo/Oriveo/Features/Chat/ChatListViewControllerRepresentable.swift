import Combine
import SwiftUI
import UIKit

struct ChatListViewControllerRepresentable: UIViewControllerRepresentable {
    let viewModel: ChatCollectionViewModel
    let requestedAutoScrollEnabled: Bool
    let providerMetadataVersion: UInt
    let scrollToBottomRequest: UInt
    let streamingTextPublisher: AnyPublisher<Void, Never>
    let streamingReasoningPublisher: AnyPublisher<ReasoningStreamDelta, Never>
    let streamingTextProvider: () -> String
    let streamingReasoningSnapshotProvider: () -> ReasoningStreamSnapshot?
    let hasMoreAbove: Bool
    let hasMoreBelow: Bool
    let onRequestExtendUpward: () -> Void

    @Binding var isAtBottom: Bool
    @Binding var autoScrollEnabled: Bool

    var onRetryMessage: (ChatMessage) -> Void
    var onContinueMessage: (ChatMessage) -> Void
    var onSaveNoteMessage: (ChatMessage) -> Void = { _ in }
    var onOpenNoteReferences: ([NoteSummary]) -> Void = { _ in }
    var onSaveSelectionMessage: (ChatMessage, String) -> Void = { _, _ in }
    var onAskSelectionMessage: (ChatMessage, QuoteSelectionContent) -> Void = { _, _ in }
    var canReplaceCurrentNoteSelection = false
    var onReplaceSelectionMessage: (ChatMessage, String) -> Void = { _, _ in }
    var onSaveCodeBlockMessage: (ChatMessage, String, String?) -> Void = { _, _, _ in }
    var onRegenerateMessage: (ChatMessage) -> Void
    var onEditMessage: (ChatMessage) -> Void
    var onSwitchModelRequested: () -> Void
    var onPendingSearchTargetHandled: () -> Void
    var onDismissComposer: () -> Void
    var onAnchorUserMessageConsumed: (UUID) -> Void
    var outlineScrollRequest: UInt = 0
    var outlineScrollMessageID: UUID? = nil
    var outlineScrollShouldFlash: Bool = false
    var onVisibleTopUserMessageChanged: (UUID?) -> Void = { _ in }

    func makeUIViewController(context: Context) -> ChatListViewController {
        ChatListViewController()
    }

    func updateUIViewController(_ controller: ChatListViewController, context: Context) {
        controller.update(
            viewModel: viewModel,
            providerMetadataVersion: providerMetadataVersion,
            streamingPublisher: streamingTextPublisher,
            streamingReasoningPublisher: streamingReasoningPublisher,
            streamingTextProvider: streamingTextProvider,
            streamingReasoningSnapshotProvider: streamingReasoningSnapshotProvider,
            onRetry: onRetryMessage,
            onContinue: onContinueMessage,
            onSaveNote: onSaveNoteMessage,
            onOpenNoteReferences: onOpenNoteReferences,
            onSaveSelection: onSaveSelectionMessage,
            onAskSelection: onAskSelectionMessage,
            canReplaceCurrentNoteSelection: canReplaceCurrentNoteSelection,
            onReplaceSelection: onReplaceSelectionMessage,
            onSaveCodeBlock: onSaveCodeBlockMessage,
            onRegenerate: onRegenerateMessage,
            onEditMessage: onEditMessage,
            onSwitchModel: onSwitchModelRequested,
            pendingAnchorUserMessageID: viewModel.pendingAnchorUserMessageID,
            onAnchorUserMessageConsumed: onAnchorUserMessageConsumed,
            scrollToBottomRequest: scrollToBottomRequest,
            onIsAtBottomChanged: { isAtBottom = $0 },
            onAutoScrollEnabledChanged: { autoScrollEnabled = $0 },
            hasMoreAbove: hasMoreAbove,
            hasMoreBelow: hasMoreBelow,
            onRequestExtendUpward: onRequestExtendUpward,
            onPendingSearchTargetHandled: onPendingSearchTargetHandled,
            outlineScrollRequest: outlineScrollRequest,
            outlineScrollMessageID: outlineScrollMessageID,
            outlineScrollShouldFlash: outlineScrollShouldFlash,
            onVisibleTopUserMessageChanged: onVisibleTopUserMessageChanged
        )
    }
}
