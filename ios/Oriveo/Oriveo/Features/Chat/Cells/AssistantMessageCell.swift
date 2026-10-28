import SwiftUI
import UIKit

final class AssistantMessageCell: UICollectionViewCell {
    static let assistantBodyLeadingInset: CGFloat = 0

    // MARK: - Subviews

    let outerStack = UIStackView() // horizontal: badge | content | spacer
    let providerBadge = UIKitProviderBadge()
    let contentStack = UIStackView() // vertical: header | bodyStack | metadata

    let headerStack = UIStackView()
    let modelNameLabel = UILabel()
    let statusPillLabel = UILabel()
    let statusPillContainer = UIView()

    let bodyStack = UIStackView()
    let reasoningBlock = UIKitReasoningBlock()
    let textView = ChatPassiveTextView()
    let typingIndicator = UIKitTypingIndicator()
    let typingContainer = UIView()

    weak var parentViewController: UIViewController?

    let attachmentsHost = UIView()
    var attachmentViews: [UIKitAssistantImageView] = []
    var attachmentLayoutConstraints: [NSLayoutConstraint] = []
    var configuredImageAttachments: [Attachment] = []

    var citationsBlock: CitationsBlock?
    /// Citations of the currently bound message; used to attach the block once the final streaming render finishes.
    var boundCitations: [Citation] = []
    /// Title of the external search sources card (the stored sourcesLine); when non-nil the citations block becomes
    /// the sources card, and the title shows even with 0 sources.
    var boundSearchHeader: SearchSourcesHeaderPresentation?
    /// Resident slot for the external search error card: after the citations, before the reply notice; hidden when there is no card.
    let searchErrorCard = UIKitSearchErrorCard()
    /// Search query chips below the external search activity line, and their resident slot.
    let searchQueryChips = UIKitSearchQueryChips()
    let searchQueryChipsHost = UIView()
    /// External search activity context of the currently bound message (transient, from the activity channel).
    var externalSearchTrail: ExternalSearchActivityTrail?
    /// Actions of the external search card / menu.
    var onSearchAction: ((ExternalSearchCardAction) -> Void)?
    let citationsHost = UIView()

    // Stream activity status line: directly below the body text, above the tool-call card,
    // citations and metadata.
    let streamActivityLine = UIKitStreamActivityLine()
    /// A **permanent** slot for the status line, collapsed with `isHidden`, for the same reason as
    /// `recoveryCardHost`: nothing gets inserted into a stack that has already been laid out.
    let streamActivityLineHost = UIView()
    /// The activity observed for the bound message. Transient: it comes from ChatManager's
    /// activity channel, not from the `ChatMessage`.
    var streamActivity: StreamActivity?
    /// Pause detection: nothing visible has changed for 1500 ms. One cancellable timer, cancelled
    /// on reuse and when the stream ends.
    let streamQuietTimer = StreamQuietTimer()
    /// Covers the few frames after the activity channel reported the session gone and before the
    /// message state is reconfigured: no waiting feedback is shown. Reset when a new subscription
    /// is set up.
    var streamSessionEnded = false
    /// The presentation last applied to the views; `refreshStreamActivityPresentation` uses it to
    /// skip redundant updates.
    var streamActivityPresentation: StreamActivityPresentation = .hidden
    /// Gap between the body text and the status line.
    static let streamActivityLineTopSpacing: CGFloat = 8

    /// The remote MCP step block (after the header, before the body).
    let toolStepsView = UIKitToolStepsView()
    /// Activity caption of the step that is running now ("Using <server> · <tool title>"). The `mcp_tool`
    /// activity reads its display context from here: the activity event itself is a plain enum case and
    /// carries neither the server nor the tool.
    var runningToolStepCaption: String?
    /// The activity text last put on screen; when the caption changes under the same activity (another
    /// step started) the view still has to refresh.
    var presentedStreamActivityText: String?
    let unhandledToolCallView = UIKitUnhandledToolCallView()
    // One secondary-colour line under the reply (e.g. the relay did not use web search): a permanent slot, hidden when there is no notice.
    let replyNoticeLabel = UILabel()
    // Compaction separator row: the first item of outerStack, above contentStack; hidden when there is no separator.
    let compactionSeparatorView = ContextCompactionSeparatorView()

    var recoveryCard: UIKitRecoveryCard?
    let recoveryCardHost = UIView()

    let metadataView = AssistantMetadataView()
    /// "Save to memory?" bar: after the metadata action row; hidden unless this assistant
    /// message carries the pending bar and is no longer streaming. Toggled via isHidden only.
    let memorySuggestionView = MemorySuggestionBarView()
    /// Minimum-height constraint on bodyStack while streaming: when reasoning and the typing dots are mutually exclusive,
    /// bodyStack would be only as tall as the reasoning header and the metadata would sit flush under it, looking cut off.
    var bodyStackMinHeightConstraint: NSLayoutConstraint?
    var topPaddingConstraint: NSLayoutConstraint!

    var boundMessageID: UUID?
    var currentMessageState: ChatMessageState?
    var currentRenderMode: MarkdownStaticRenderingMode = .plainText
    var currentMessageText: String = ""
    var pendingRenderGeneration: UInt = 0
    var onContentHeightDidChange: ((CGFloat) -> Void)?
    var onRetry: (() -> Void)?
    /// Actions on the MCP step block (re-authorize / skip this step).
    var onToolStepAction: ((McpToolStepAction) -> Void)?
    var onContinue: (() -> Void)?

    #if DEBUG
    var _testContentDidChangeCount = 0
    var _testLastContentDidChangeID: UUID?
    var _testScheduledStreamingHeightFlushCount = 0
    #endif

    let streamingController = AssistantStreamingController()
    var onFinalStreamingRenderCompleted: (() -> Void)?

    var hasPendingFinalStreamingRenderForCurrentMessage: Bool {
        pendingFinalStreamingRender != nil
    }

    var lastStreamingText = ""
    var pendingFinalStreamingRender: PendingFinalStreamingRender?

    weak var displayClock: StreamingDisplayClock? {
        didSet {
            pacer.displayClock = displayClock
            chunkFader.displayClock = displayClock
        }
    }

    let pacer = StreamingPacer(displayClock: nil)

    let blockWriter = BlockCommitTextWriter()

    let incrementalParser = IncrementalStreamingSegmentParser()

    // MARK: - Chunk fade

    let chunkFader = ChunkFadeAnimator()

    var isNearBottomProvider: () -> Bool = { false }


    struct PendingFinalStreamingRender {
        let messageID: UUID
        let text: String
        let renderHint: MarkdownRenderHint?
    }

    lazy var staticBodyRenderer = AssistantStaticBodyRenderer(
        bodyStack: bodyStack,
        textView: textView,
        streamingAnchorProvider: { [weak self] in
            self?.streamingCodeRenderer.view
        },
        hostNotifier: { [weak self] in self?.notifyContentDidChange() }
    )

    var isStreamingActive: Bool {
        streamingController.isSubscribed || pendingFinalStreamingRender != nil
    }

    var hasVisibleStreamingContent: Bool {
        isStreamingActive && !pacer.visibleText.isEmpty
    }

    var streamingHeightFloor: CGFloat = 0

    var pendingStreamingHeightFlush = false
    var pendingStreamingHeightWorkItem: DispatchWorkItem?
    var streamingHeightFlushGeneration: UInt = 0

    var lastStreamingInvalidateTimestamp: CFTimeInterval = 0

    nonisolated static let minStreamingInvalidateInterval: CFTimeInterval = 1.0 / 15.0

    static func nextStreamingHeightFloor(natural: CGFloat, current: CGFloat, streaming: Bool) -> CGFloat {
        streaming ? max(current, natural) : 0
    }

    /// The self-size target width: only finite positive values pass (clamped to `maxFittingWidth`);
    /// otherwise the first usable fallback from the same sources, and 1pt as a last resort.
    nonisolated static func sanitizedFittingWidth(proposed: CGFloat, fallbacks: [CGFloat]) -> CGFloat {
        let usable = ([proposed] + fallbacks).first { $0.isFinite && $0 > 0 } ?? 1
        return min(max(usable, 1), maxFittingWidth)
    }

    /// A width no screen or split view can reach; an astronomical width in a required constraint also
    /// drives the layout engine to inf.
    nonisolated static let maxFittingWidth: CGFloat = 100_000

    /// When the measured height is not finite, fall back to the previous height (1pt at worst) instead
    /// of reporting inf/NaN to the layout.
    nonisolated static func sanitizedFittedHeight(_ fitted: CGFloat, fallback: CGFloat) -> CGFloat {
        if fitted.isFinite { return max(ceil(fitted), 1) }
        return fallback.isFinite ? max(ceil(fallback), 1) : 1
    }

    let streamingCodeRenderer = AssistantStreamingCodeRenderer()

    var streamingTableRenderer: AssistantStreamingTableRenderer?

    var latexRenderObserver: NSObjectProtocol?
    var resolvedLatexAwaitingReconcile: Set<String> = []
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
        textView.accessibilityIdentifier = "chat_message_assistant"
        pacer.delegate = self
        chunkFader.textStorageProvider = { [weak self] in self?.textView.textStorage }
        blockWriter.textViewProvider = { [weak self] in self?.textView }
        blockWriter.chunkFader = chunkFader
        streamQuietTimer.onQuietChanged = { [weak self] in
            self?.refreshStreamActivityPresentation()
        }
        latexRenderObserver = NotificationCenter.default.addObserver(
            forName: LatexImageCache.didRenderNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.handleLatexImageDidRender(note)
        }
    }

    deinit {
        if let latexRenderObserver {
            NotificationCenter.default.removeObserver(latexRenderObserver)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Configure

    func configure(
        model: ChatCollectionProjectionBuilder.MessageRenderModel,
        parentViewController: UIViewController,
        onContentHeightDidChange: ((CGFloat) -> Void)?,
        onRetry: (() -> Void)?,
        onContinue: (() -> Void)?,
        onSaveNote: (() -> Void)? = nil,
        onOpenNoteReferences: (() -> Void)? = nil,
        onCrosscheck: (() -> Void)? = nil,
        onOpenMemoryUsed: (() -> Void)? = nil,
        onToolStepAction: ((McpToolStepAction) -> Void)? = nil,
        onSearchAction: ((ExternalSearchCardAction) -> Void)? = nil,
        onSaveSelection: ((String) -> Void)? = nil,
        onAskSelection: ((QuoteSelectionContent) -> Void)? = nil,
        onReplaceSelection: ((String) -> Void)? = nil,
        onSaveCodeBlock: ((String, String?) -> Void)? = nil,
        onOpenCompactionDetail: (() -> Void)? = nil,
        onSaveMemorySuggestion: (() -> Void)? = nil,
        onEditMemorySuggestion: (() -> Void)? = nil,
        onIgnoreMemorySuggestion: (() -> Void)? = nil
    ) {
        self.onToolStepAction = onToolStepAction
        self.onSearchAction = onSearchAction
        configureCompactionSeparator(model.compactionSeparator, onTap: onOpenCompactionDetail)
        let previousMessageID = boundMessageID
        let previousMessageState = currentMessageState
        let effectiveText = model.displayText ?? model.message.text
        let isGenerating = model.message.state == .generating
        let didExitGenerating = previousMessageID == model.messageID
            && previousMessageState == .generating
            && !isGenerating
        let hadStreamingPacer = streamingController.isSubscribed || pendingFinalStreamingRender != nil
        let shouldDeferFinalBody = shouldDeferFinalStreamingRender(
            previousMessageID: previousMessageID,
            nextMessageID: model.messageID,
            isGenerating: isGenerating,
            targetText: effectiveText,
            hadStreamingPacer: hadStreamingPacer
        )
        let wasStreaming = hadStreamingPacer

        // A streaming reconfigure must leave the live streaming state alone: the pacer's visible
        // text, the last rendered snapshot, the streaming height floor and the controller
        // subscription all have to survive it.
        // upsertConversationProjection → messageRevision &+= 1 → isStreamingOnlyChange fast path
        let isStreamingReconfigure = previousMessageID == model.messageID
            && isGenerating
            && hadStreamingPacer
            && !shouldDeferFinalBody

        if !isStreamingReconfigure {
            cancelPendingStreamingHeightFlush(resetTimestamp: true)
            streamingController.cancel()
            // With the subscription gone, the activity and the pause timer have no source left.
            // Stream end, a different message and retry all start from an empty state; a new
            // subscription reads the current activity once and restarts the timer. The views are
            // settled at the end of configure.
            streamActivity = nil
            streamSessionEnded = false
            streamQuietTimer.cancel()
            if shouldDeferFinalBody {
                prepareFinalStreamingRender(
                    text: effectiveText,
                    renderHint: model.renderHint,
                    messageID: model.messageID
                )
            } else {
                pendingFinalStreamingRender = nil
                pacer.cancel()
                if previousMessageID != model.messageID || (isGenerating && model.isStreaming) {
                    clearFrozenViews()
                    resetStreamingIncrementalState()
                }
                hideStreamingCodeBlock()
                hideStreamingTableCard()
            }
        }
        tearDownRecoveryCard()
        if wasStreaming && !isStreamingReconfigure {
            bodyStackMinHeightConstraint?.isActive = false
            if !shouldDeferFinalBody {
                blockWriter.reset()
                streamingController.resetReasoning()
                textView.text = nil
                textView.invalidateIntrinsicContentSize()
            }
        }

        let messageID = model.messageID
        boundMessageID = messageID
        currentMessageState = model.message.state
        currentMessageText = model.message.text
        self.parentViewController = parentViewController
        staticBodyRenderer.setParentViewController(parentViewController)
        staticBodyRenderer.onSaveSelection = onSaveSelection
        staticBodyRenderer.onAskSelection = onAskSelection
        staticBodyRenderer.onReplaceSelection = onReplaceSelection
        staticBodyRenderer.onSaveCodeBlock = onSaveCodeBlock
        // While generating, the data source passes nil (no ask or replace). Finalize reuses the views
        // frozen during streaming as they are, so without rebinding here the menu would only come back
        // once the cell is reused.
        staticBodyRenderer.rebindFrozenViewCallbacks()
        textView.onSaveSelection = onSaveSelection
        textView.onAskSelection = onAskSelection
        textView.quoteContentKind = .prose
        textView.onReplaceSelection = onReplaceSelection
        self.onContentHeightDidChange = onContentHeightDidChange
        self.onRetry = onRetry
        self.onContinue = onContinue

        topPaddingConstraint.constant = model.topPadding

        providerBadge.configure(
            kind: model.message.providerKind,
            relayKind: model.relayKind,
            relayAvatar: model.relayAvatar,
            size: 28
        )

        let modelName = model.resolvedModelName ?? model.message.modelName
        modelNameLabel.text = modelName

        statusPillContainer.isHidden = !isGenerating

        let isAwaitingCellStreamingOwner = isGenerating
            && model.displayText != nil
            && streamingController.isSubscribed
        if !isStreamingReconfigure && !shouldDeferFinalBody && !isAwaitingCellStreamingOwner {
            configureBody(
                text: effectiveText,
                isStreaming: isGenerating,
                renderHint: model.renderHint,
                messageID: messageID,
                parentViewController: parentViewController
            )
        }

        if !isStreamingReconfigure {
            reasoningBlock.configure(
                text: model.message.reasoningText ?? "",
                durationMs: model.message.reasoningDurationMs,
                isStreaming: isGenerating,
                hasMainText: !effectiveText.isEmpty
            )
        }

        configureToolSteps(message: model.message, isGenerating: isGenerating)
        unhandledToolCallView.configure(calls: model.message.unhandledToolCalls ?? [])

        let attachments = model.message.attachments ?? []
        if !attachments.isEmpty {
            configureAttachments(attachments.filter { $0.kind == .image }, parentViewController: parentViewController)
        } else {
            tearDownAttachmentViews()
        }

        // Citations appear only once the body has finished rendering on screen. The gate looks at the
        // rendered state, not at whether the data layer has text: the pacer reveals text at its own
        // pace, while citations can be attached as soon as they are written to message.citations.
        // The data itself is kept so retry / edit can still map citations back to documents.
        boundCitations = model.message.citations ?? []
        boundSearchHeader = ExternalSearchChatPresentation.sourcesHeader(model.message)
        refreshCitationsBlock(parentViewController: parentViewController)
        configureSearchErrorCard(
            isGenerating
                ? nil
                : ExternalSearchChatPresentation.errorCard(
                    model.message, isLastAssistant: model.message.role == .assistant && model.isLastInConversation,
                    serviceExists: { WebSearchLocalServices.contains($0) }
                )
        )
        configureReplyNotice(isGenerating ? nil : model.replyNotice)

        if model.showMetadata {
            let providerName = model.resolvedProviderName ?? model.message.providerName
            metadataView.configure(
                model: model,
                providerName: providerName,
                modelName: modelName,
                leadingInset: Self.assistantBodyLeadingInset,
                onRetry: onRetry,
                onContinue: onContinue,
                onRegenerateWithSearch: ExternalSearchChatPresentation.offersRegenerateWithSearch(model.message)
                    && onSearchAction != nil
                    ? { [weak self] in self?.onSearchAction?(.regenerateWithSearch) }
                    : nil,
                onSaveNote: onSaveNote,
                onOpenNoteReferences: onOpenNoteReferences,
                onCrosscheck: onCrosscheck,
                onOpenMemoryUsed: onOpenMemoryUsed,
                isVisualRenderPending: shouldDeferFinalBody
            )
        } else {
            metadataView.resetForReuse()
        }
        memorySuggestionView.onSave = onSaveMemorySuggestion
        memorySuggestionView.onEdit = onEditMemorySuggestion
        memorySuggestionView.onIgnore = onIgnoreMemorySuggestion
        applyMemorySuggestion(isGenerating ? nil : model.memorySuggestion)

        if isGenerating || ((wasStreaming || didExitGenerating) && !shouldDeferFinalBody) {
            notifyContentDidChange()
        }
        refreshStreamActivityPresentation()
    }
}
