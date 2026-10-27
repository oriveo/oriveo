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
    let streamingActivityPublisher: AnyPublisher<StreamActivityState, Never>
    let streamingActivityProvider: () -> StreamActivityState?
    let hasMoreAbove: Bool
    let hasMoreBelow: Bool
    let onRequestExtendUpward: () -> Void

    @Binding var isAtBottom: Bool
    @Binding var autoScrollEnabled: Bool

    var onRetryMessage: (ChatMessage) -> Void
    var onContinueMessage: (ChatMessage) -> Void
    var onSaveNoteMessage: (ChatMessage) -> Void = { _ in }
    var onOpenNoteReferences: ([NoteSummary]) -> Void = { _ in }
    var onCrosscheckMessage: (ChatMessage) -> Void = { _ in }
    var onMcpStepAction: (ChatMessage, McpToolStepAction) -> Void = { _, _ in }
    var onSearchAction: (ChatMessage, ExternalSearchCardAction) -> Void = { _, _ in }
    var onOpenMemoryUsed: (ChatMessage) -> Void = { _ in }
    var onSaveSelectionMessage: (ChatMessage, String) -> Void = { _, _ in }
    var onAskSelectionMessage: (ChatMessage, QuoteSelectionContent) -> Void = { _, _ in }
    var canReplaceCurrentNoteSelection = false
    var onReplaceSelectionMessage: (ChatMessage, String) -> Void = { _, _ in }
    var onSaveCodeBlockMessage: (ChatMessage, String, String?) -> Void = { _, _, _ in }
    var onOpenCompactionDetail: () -> Void = {}
    var onAcceptDirectiveSuggestion: () -> Void = {}
    var onIgnoreDirectiveSuggestion: () -> Void = {}
    var onSaveMemorySuggestion: () -> Void = {}
    var onEditMemorySuggestion: () -> Void = {}
    var onIgnoreMemorySuggestion: () -> Void = {}
    var onRegenerateMessage: (ChatMessage) -> Void
    var onEditMessage: (ChatMessage) -> Void
    var onSwitchModelRequested: () -> Void
    /// Whether a failed message offers "switch to another key", and where tapping it goes.
    var offersSwitchKey: (ChatMessage) -> Bool = { _ in false }
    var onSwitchKeyRequested: (ChatMessage) -> Void = { _ in }
    var onPendingSearchTargetHandled: () -> Void
    var onDismissComposer: () -> Void
    var onAnchorUserMessageConsumed: (UUID) -> Void
    var outlineScrollRequest: UInt = 0
    var outlineScrollMessageID: UUID? = nil
    var outlineScrollShouldFlash: Bool = false
    var onVisibleTopUserMessageChanged: (UUID?) -> Void = { _ in }
    /// This window's carrier handoff: registers the reading anchor provider and, when a controller is created, takes back the old carrier's reading position.
    var carrierHandoff: ChatCarrierHandoff? = nil

    final class Coordinator {
        weak var carrierHandoff: ChatCarrierHandoff?
        var carrierHandoffToken: ChatCarrierHandoff.Token?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> ChatListViewController {
        let controller = ChatListViewController()
        if let carrierHandoff {
            context.coordinator.carrierHandoff = carrierHandoff
            context.coordinator.carrierHandoffToken = Self.attachCarrierHandoff(carrierHandoff, to: controller)
        }
        return controller
    }

    /// Connects a new controller to the handoff: with a carrier handoff it sets the reading anchor and skips the entrance delay, then registers this controller's anchor provider
    /// for the next move to capture. Returns the registration token, used to unregister when the controller is torn down.
    static func attachCarrierHandoff(
        _ handoff: ChatCarrierHandoff,
        to controller: ChatListViewController
    ) -> ChatCarrierHandoff.Token {
        if let restore = handoff.takeListRestore() {
            controller.pendingReadingAnchor = restore.readingAnchor
            controller.skipInitialTransitionDeferral()
        }
        return handoff.registerReadingAnchor { [weak controller] in
            controller?.captureReadingAnchor()
        }
    }

    /// Leaving the chat screen: pooled rich cards only serve scrolling back within the current
    /// conversation, so they are released with the screen.
    static func dismantleUIViewController(_ uiViewController: ChatListViewController, coordinator: Coordinator) {
        ChatRichCardRecycling.purgeAll()
        if let token = coordinator.carrierHandoffToken {
            coordinator.carrierHandoff?.unregister(token)
        }
    }

    func updateUIViewController(_ controller: ChatListViewController, context: Context) {
        controller.update(
            viewModel: viewModel,
            providerMetadataVersion: providerMetadataVersion,
            streamingPublisher: streamingTextPublisher,
            streamingReasoningPublisher: streamingReasoningPublisher,
            streamingTextProvider: streamingTextProvider,
            streamingReasoningSnapshotProvider: streamingReasoningSnapshotProvider,
            streamingActivityPublisher: streamingActivityPublisher,
            streamingActivityProvider: streamingActivityProvider,
            onRetry: onRetryMessage,
            onContinue: onContinueMessage,
            onSaveNote: onSaveNoteMessage,
            onOpenNoteReferences: onOpenNoteReferences,
            onCrosscheck: onCrosscheckMessage,
            onMcpStepAction: onMcpStepAction,
            onSearchAction: onSearchAction,
            onOpenMemoryUsed: onOpenMemoryUsed,
            onSaveSelection: onSaveSelectionMessage,
            onAskSelection: onAskSelectionMessage,
            canReplaceCurrentNoteSelection: canReplaceCurrentNoteSelection,
            onReplaceSelection: onReplaceSelectionMessage,
            onSaveCodeBlock: onSaveCodeBlockMessage,
            onOpenCompactionDetail: onOpenCompactionDetail,
            onAcceptDirectiveSuggestion: onAcceptDirectiveSuggestion,
            onIgnoreDirectiveSuggestion: onIgnoreDirectiveSuggestion,
            onSaveMemorySuggestion: onSaveMemorySuggestion,
            onEditMemorySuggestion: onEditMemorySuggestion,
            onIgnoreMemorySuggestion: onIgnoreMemorySuggestion,
            onRegenerate: onRegenerateMessage,
            onEditMessage: onEditMessage,
            onSwitchModel: onSwitchModelRequested,
            offersSwitchKey: offersSwitchKey,
            onSwitchKey: onSwitchKeyRequested,
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
