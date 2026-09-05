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
    let citationsHost = UIView()

    let unhandledToolCallView = UIKitUnhandledToolCallView()

    var recoveryCard: UIKitRecoveryCard?
    let recoveryCardHost = UIView()

    let metadataView = AssistantMetadataView()
    var bodyStackMinHeightConstraint: NSLayoutConstraint?
    var topPaddingConstraint: NSLayoutConstraint!

    var boundMessageID: UUID?
    var currentMessageState: ChatMessageState?
    var currentRenderMode: MarkdownStaticRenderingMode = .plainText
    var currentMessageText: String = ""
    var pendingRenderGeneration: UInt = 0
    var onContentHeightDidChange: ((CGFloat) -> Void)?
    var onRetry: (() -> Void)?
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

    let streamingCodeRenderer = AssistantStreamingCodeRenderer()

    var streamingTableRenderer: AssistantStreamingTableRenderer?

    var latexRenderObserver: NSObjectProtocol?
    var resolvedLatexAwaitingReconcile: Set<String> = []
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
        pacer.delegate = self
        chunkFader.textStorageProvider = { [weak self] in self?.textView.textStorage }
        blockWriter.textViewProvider = { [weak self] in self?.textView }
        blockWriter.chunkFader = chunkFader
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
        onSaveSelection: ((String) -> Void)? = nil,
        onAskSelection: ((QuoteSelectionContent) -> Void)? = nil,
        onReplaceSelection: ((String) -> Void)? = nil,
        onSaveCodeBlock: ((String, String?) -> Void)? = nil
    ) {
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

        // / pacer.visibleText / lastRendered* / streamingHeightFloor / streamingController).
        // upsertConversationProjection → messageRevision &+= 1 → isStreamingOnlyChange fast path
        let isStreamingReconfigure = previousMessageID == model.messageID
            && isGenerating
            && hadStreamingPacer
            && !shouldDeferFinalBody

        if !isStreamingReconfigure {
            cancelPendingStreamingHeightFlush(resetTimestamp: true)
            streamingController.cancel()
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

        unhandledToolCallView.configure(calls: model.message.unhandledToolCalls ?? [])

        let attachments = model.message.attachments ?? []
        if !attachments.isEmpty {
            configureAttachments(attachments.filter { $0.kind == .image }, parentViewController: parentViewController)
        } else {
            tearDownAttachmentViews()
        }

        let bodyHasStarted = !isGenerating || !effectiveText.isEmpty
        if let citations = model.message.citations, !citations.isEmpty, bodyHasStarted {
            configureCitations(citations, parentViewController: parentViewController)
        } else {
            tearDownCitationsBlock()
        }

        if model.showMetadata {
            let providerName = model.resolvedProviderName ?? model.message.providerName
            metadataView.configure(
                model: model,
                providerName: providerName,
                modelName: modelName,
                leadingInset: Self.assistantBodyLeadingInset,
                onRetry: onRetry,
                onContinue: onContinue,
                onSaveNote: onSaveNote,
                onOpenNoteReferences: onOpenNoteReferences,
                isVisualRenderPending: shouldDeferFinalBody
            )
        } else {
            metadataView.resetForReuse()
        }

        if isGenerating || ((wasStreaming || didExitGenerating) && !shouldDeferFinalBody) {
            notifyContentDidChange()
        }
    }
}
