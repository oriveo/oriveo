import ChatLayout
import Combine
import os
import UIKit

/// Reading anchor: the message id of the cell under the viewport's top edge plus where that edge falls inside the cell (0–1).
///
/// A width change (folding or half-folding a Duo, rotating an iPhone, resizing an iPad window) relays out
/// every cell at a new height, so a pixel offset goes stale; recording "which message and how far into it"
/// lets a long answer land back in the same place after relayout. `nil` means at the bottom.
struct ChatReadingAnchor: Equatable {
    let messageID: UUID
    let progress: CGFloat
}

@MainActor
final class ChatListViewController: UIViewController {
    static let bottomBreathingRoom: CGFloat = OriveoTheme.Spacing.xl

    nonisolated static let userBubbleMaxWidth: CGFloat = 320

    private let dataSource = ChatListDataSource()
    private lazy var chatLayout: ChatScrollChatLayout = {
        let layout = ChatScrollChatLayout()
        layout.supportSelfSizingInvalidation = true
        layout.keepContentAtBottomOfVisibleArea = false
        layout.keepContentOffsetAtBottomOnBatchUpdates = false
        layout.settings.additionalInsets = UIEdgeInsets(top: 16, left: 0, bottom: 0, right: 0)
        layout.settings.interItemSpacing = 0
        layout.settings.interSectionSpacing = 0
        // The estimate is only a first-screen placeholder; each cell's systemLayoutSizeFitting replaces
        // it with the real height. The width follows this view's actual width (an iPad split layout or an
        // unfolded Duo differs from the screen width); before the first layout a common phone width is
        // used, and viewDidLayoutSubviews rewrites it once the collection view has its real width.
        let initialWidth = viewIfLoaded?.bounds.width ?? 0
        layout.settings.estimatedItemSize = CGSize(
            width: initialWidth > 0 ? initialWidth : Self.fallbackEstimatedItemWidth,
            height: Self.estimatedItemHeight
        )
        layout.delegate = self
        return layout
    }()
    private lazy var collectionView: UICollectionView = {
        let cv = ChatListCollectionView(frame: .zero, collectionViewLayout: chatLayout)
        cv.backgroundColor = .clear
        cv.contentInsetAdjustmentBehavior = .never
        cv.contentInset.bottom = Self.bottomBreathingRoom
        cv.alwaysBounceVertical = true
        cv.keyboardDismissMode = .interactive
        return cv
    }()

    private lazy var stickController = ChatStickToBottomController(
        geometry: self,
        minBottomPadding: Self.bottomBreathingRoom,
        displayScale: traitCollection.displayScale > 0 ? traitCollection.displayScale : 3,
        hasStreamingContent: { [weak self] in
            guard let self else { return false }
            for case let cell as AssistantMessageCell in self.collectionView.visibleCells
            where cell.hasVisibleStreamingContent {
                return true
            }
            return false
        },
        writeBottomInset: { [weak self] inset in
            self?.collectionView.contentInset.bottom = inset
        },
        writeOffset: { [weak self] y, animated in
            self?.collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: animated)
        }
    )
    private var anchorUserMessageID: UUID?
    private var reconcileTickToken: StreamingDisplayClock.SubscriberToken?
    private enum ReconcileTickKind { case streaming, settle }
    private var reconcileTickKind: ReconcileTickKind?
    private var pendingContentSizeReconcile = false
    private var needsSettleInsetReconcile = false
    private var contentSizeObservation: NSKeyValueObservation?

    private let keyboardCoordinator = ChatKeyboardCoordinator()
    private lazy var gestureObserver = ChatScrollGestureObserver(
        onUserGrabbed: { [weak self] in
            guard let self else { return }
            self.stickController.userDidGrab()
            self.reportFollowingChangeIfNeeded()
        },
        onSettle: { [weak self] in
            guard let self else { return }
            self.stickController.settle()
            self.flushStreamingCellHeightIfNeeded()
            if self.needsSettleInsetReconcile {
                self.needsSettleInsetReconcile = false
                if self.reconcileTickToken == nil, !self.stickController.isStreamingMode {
                    self.stickController.reconcileInsetOnly()
                }
            }
            self.reportFollowingChangeIfNeeded()
        },
        hasMoreAbove: { [weak self] in self?.hasMoreAbove ?? false },
        onRequestExtendUpward: { [weak self] in self?.onRequestExtendUpward() },
        onDidScroll: { [weak self] in
            self?.reportVisibleTopUserMessageIfNeeded()
            self?.updateUserBubbleGradientAnchors()
        },
        onWillDisplay: { [weak self] cell in
            guard let self, let user = cell as? UserMessageCell else { return }
            self.updateUserBubbleGradientAnchor(user)
        })

    private var pendingViewModel: ChatCollectionViewModel?
    private var pendingProviderMetadataVersion: UInt = 0
    private var onRetry: (ChatMessage) -> Void = { _ in }
    private var onContinue: (ChatMessage) -> Void = { _ in }
    private var onSaveNote: (ChatMessage) -> Void = { _ in }
    private var onOpenNoteReferences: ([NoteSummary]) -> Void = { _ in }
    private var onCrosscheck: (ChatMessage) -> Void = { _ in }
    private var onMcpStepAction: (ChatMessage, McpToolStepAction) -> Void = { _, _ in }
    private var onSearchAction: (ChatMessage, ExternalSearchCardAction) -> Void = { _, _ in }
    private var onOpenMemoryUsed: (ChatMessage) -> Void = { _ in }
    private var onSaveSelection: (ChatMessage, String) -> Void = { _, _ in }
    private var onAskSelection: (ChatMessage, QuoteSelectionContent) -> Void = { _, _ in }
    private var canReplaceCurrentNoteSelection = false
    private var onReplaceSelection: (ChatMessage, String) -> Void = { _, _ in }
    private var onSaveCodeBlock: (ChatMessage, String, String?) -> Void = { _, _, _ in }
    private var onOpenCompactionDetail: () -> Void = {}
    private var onAcceptDirectiveSuggestion: () -> Void = {}
    private var onIgnoreDirectiveSuggestion: () -> Void = {}
    private var onSaveMemorySuggestion: () -> Void = {}
    private var onEditMemorySuggestion: () -> Void = {}
    private var onIgnoreMemorySuggestion: () -> Void = {}
    private var onRegenerate: (ChatMessage) -> Void = { _ in }
    private var onEditMessage: (ChatMessage) -> Void = { _ in }
    private var onSwitchModel: () -> Void = {}
    private var offersSwitchKey: (ChatMessage) -> Bool = { _ in false }
    private var onSwitchKey: (ChatMessage) -> Void = { _ in }
    private var isSendingMessage = false
    private var pendingAnchorUserMessageID: UUID?
    private var onAnchorUserMessageConsumed: (UUID) -> Void = { _ in }
    private var lastHandledAnchorID: UUID?
    private var onIsAtBottomChanged: (Bool) -> Void = { _ in }
    private var onAutoScrollEnabledChanged: (Bool) -> Void = { _ in }
    private var lastScrollToBottomRequest: UInt = 0
    private var hasMoreAbove = false
    private var hasMoreBelow = false
    private var onRequestExtendUpward: () -> Void = {}
    private var onPendingSearchTargetHandled: () -> Void = {}
    private var lastReportedIsFollowing: Bool?
    private var onVisibleTopUserMessageChanged: (UUID?) -> Void = { _ in }
    private var lastReportedTopUserMessageID: UUID?
    private var hasReportedTopUserMessage = false
    private var outlineFirstUserMessageID: UUID?
    private var outlineLastUserMessageID: UUID?
    private var lastHandledOutlineScrollRequest: UInt = 0
    private var pendingFlashMessageID: UUID?
    private struct PendingOutlineScroll {
        let messageID: UUID
        let shouldFlash: Bool
        let conversationID: UUID?
    }
    private var pendingOutlineScroll: PendingOutlineScroll?
    private var outlineScrollSeq: UInt = 0
    private static let outlineScrollTopPadding: CGFloat = 16
    /// A reading anchor injected from outside (for example by the layer above when the conversation changes
    /// carrier or the scene is rebuilt): consumed on the first build or a conversation switch, after search
    /// targeting and note jumps and before the bottom fallback. An anchor whose message is not in the window
    /// counts as none (the list lands at the bottom as usual).
    var pendingReadingAnchor: ChatReadingAnchor?
    /// The reading anchor captured before a width change of this same controller: taken in
    /// `viewDidLayoutSubviews` **before** collectionView.frame changes (afterwards ChatLayout relays out at the
    /// new width and the old geometry is gone), then consumed by the width-change branch of the same `rebuildIfReady` pass.
    private var widthChangeReadingAnchor: ChatReadingAnchor?
    /// Signpost interval around the width-change reload + layout (see `chat.widthRelayout` in Instruments).
    private static let relayoutSignposter = OSSignposter(subsystem: Bundle.main.bundleIdentifier ?? "Oriveo", category: "chat")
    #if DEBUG
    /// Duration of the latest width-change reload + layout in milliseconds; tests read it to guard against regressions.
    private(set) var _testLastWidthRelayoutMs: Double?
    #endif
    private var dismissedErrorIDs: Set<UUID> = []
    private var expandedRecoveryDetailIDs: Set<UUID> = []
    private var prependGeometryRecoveryCount = 0
    private var lastLargeJump: (at: CFTimeInterval, distance: CGFloat, source: String)?
    private static let largeJumpViewportMultiple: CGFloat = 2
    #if DEBUG
    var _testForceInconsistentPostBatchGeometry = false
    #endif

    private let displayClock = StreamingDisplayClock()
    private lazy var streamingCoordinator = ChatStreamingCoordinator(displayClock: displayClock)
    private let markdownCacheActor = MarkdownCacheActor()

    private var lastConversationID: UUID?
    private var lastMessageRevision: UInt = .max
    private var lastProviderMetadataVersion: UInt = .max
    /// Adding or removing the compaction separator does not change the message revision, so keep a separate copy to trigger a rebuild (reconfigures the cell that hosts the row).
    private var lastCompactionSeparator: ContextCompactionSeparator?
    /// The suggestion bar appearing or disappearing does not change the message revision either, so keep a separate copy to trigger a rebuild.
    private var lastDirectiveSuggestionMessageID: UUID?
    private var lastCurrentVisionInput: CapabilityEvidenceFacade.InputCapabilityProjection?
    private var lastMemorySuggestion: MemorySuggestionBar?
    private var lastMeasuredWidth: CGFloat = 0
    private var contentDirty = false
    private var bottomSettleGeneration: UInt = 0
    private var bottomSettleLastContentH: CGFloat = .nan
    private var bottomSettleStableFrames: Int = 0
    private var isAwaitingReveal = false
    private var isDeferringInitialRebuildForTransition = true
    private var deferralFlushScheduled = false
    private var deferralFallbackTimer: Timer?
    private let skeletonOverlay = ChatListSkeletonOverlay()
    private var prewarmProgress: ChatPrewarmProgress?

    nonisolated static func shouldDeferInitialRebuild(
        rows: [ChatCollectionProjectionBuilder.MessageRow],
        viewportHeight: CGFloat = 844
    ) -> Bool {
        let coverageBudget = max(viewportHeight, 600) * 1.25
        var score = 0
        var tailRowCount = 0
        var covered: CGFloat = 0
        for row in rows.reversed() {
            score += Self.weightedRowCost(row)
            if score > Self.deferInitialRebuildCostThreshold { return true }
            tailRowCount += 1
            covered += Self.estimatedRowHeight(row)
            if covered >= coverageBudget { break }
        }
        covered = 0
        for row in rows.prefix(rows.count - tailRowCount) {
            score += Self.weightedRowCost(row)
            if score > Self.deferInitialRebuildCostThreshold { return true }
            covered += Self.estimatedRowHeight(row)
            if covered >= coverageBudget { break }
        }
        return score > Self.deferInitialRebuildCostThreshold
    }

    nonisolated private static func weightedRowCost(
        _ row: ChatCollectionProjectionBuilder.MessageRow
    ) -> Int {
        let text = row.message.text
        // A folded long user message only measures its prefix (`UserMessageFold`). Scoring it by its full length
        // would push a conversation that should render synchronously onto the skeleton path.
        if row.message.role == .user, UserMessageFold.shouldFold(text) {
            return UserMessageFold.previewUTF16 + (row.message.attachments?.isEmpty == false ? 1500 : 0)
        }
        var cost = text.count
        if text.contains("```") { cost += 3000 }
        if text.contains("\n|") { cost += 2000 }
        if !(row.message.attachments ?? []).isEmpty { cost += 1500 }
        return cost
    }

    nonisolated private static func estimatedRowHeight(
        _ row: ChatCollectionProjectionBuilder.MessageRow
    ) -> CGFloat {
        if row.message.role == .user, UserMessageFold.shouldFold(row.message.text) {
            return UserMessageFold.collapsedTextHeight + userFullTextButtonRowHeight + 36
        }
        let lines = max(1, (row.message.text.count + 29) / 30)
        return CGFloat(lines) * 22 + 36
    }

    nonisolated static let deferInitialRebuildCostThreshold = 8000

    private func endInitialRebuildTransitionDeferralAndFlush(source: String = "test") {
        guard isDeferringInitialRebuildForTransition, !deferralFlushScheduled else { return }
        deferralFlushScheduled = true
        deferralFallbackTimer?.invalidate()
        deferralFallbackTimer = nil
        #if DEBUG
        AppLog.info("deferred rebuild flush triggered by \(source)", module: "ChatOpen")
        #endif
        waitForPrewarmThenRebuild(start: CACurrentMediaTime())
    }

    private func waitForPrewarmThenRebuild(start: CFTimeInterval) {
        let waitedMs = (CACurrentMediaTime() - start) * 1000
        let prewarmDone = prewarmProgress?.isDone ?? true
        if prewarmDone || waitedMs >= 800 {
            #if DEBUG
            AppLog.info(
                "initial rebuild released after \(Int(waitedMs))ms, prewarm done=\(prewarmDone)",
                module: "ChatOpen"
            )
            #endif
            isDeferringInitialRebuildForTransition = false
            rebuildIfReady()
            return
        }
        let timer = Timer(timeInterval: 0.05, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.waitForPrewarmThenRebuild(start: start)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        #if DEBUG
        AppLog.info(
            "viewWillAppear animated=\(animated) coordinator=\(transitionCoordinator != nil) "
            + "deferring=\(isDeferringInitialRebuildForTransition)",
            module: "ChatOpen"
        )
        #endif
        guard isDeferringInitialRebuildForTransition, !deferralFlushScheduled,
              animated, let coordinator = transitionCoordinator else { return }
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.endInitialRebuildTransitionDeferralAndFlush(source: "coordinator")
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        endInitialRebuildTransitionDeferralAndFlush(source: "didAppear")
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Stop reading only when leaving the chat screen, not when a sheet covers it
        if view.window == nil {
            ReadAloudController.shared.stop(.navigated)
        }
    }

    private func showSkeletonOverlay() {
        skeletonOverlay.isHidden = false
    }

    private func hideSkeletonOverlay() {
        skeletonOverlay.isHidden = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        ChatRenderDiagnostics.resetSession()
        view.backgroundColor = .clear
        view.addSubview(collectionView)
        view.addSubview(skeletonOverlay)
        ChatListDataSource.register(on: collectionView)
        collectionView.dataSource = dataSource
        keyboardCoordinator.onViewportSettled = { [weak self] in
            self?.reconcileViewportChangeEnsuringFullLayout(animated: false)
            self?.updateUserBubbleGradientAnchors()
        }
        collectionView.delegate = gestureObserver
        chatLayout.isFollowingProvider = { [weak self] in self?.stickController.isFollowing ?? true }
        chatLayout.isStreamingProvider = { [weak self] in self?.stickController.isStreamingMode ?? false }
        contentSizeObservation = collectionView.observe(\.contentSize) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.scheduleQuiescentInsetReconcile()
                // A row height change moves the bubbles below it within the visible area, and does not necessarily come with a scroll callback
                self?.updateUserBubbleGradientAnchors()
            }
        }
        // Switching between light and dark: pooled rich cards built in the old appearance are not worth
        // keeping (they would correct their colors when taken back, but formulas and markdown re-render).
        registerForTraitChanges(OriveoDarkPaletteTrait.colorAppearanceTraits) { (_: ChatListViewController, _: UITraitCollection) in
            ChatRichCardRecycling.purgeAll()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if collectionView.frame != view.bounds {
            // The width is about to change and the list is built: capture the reading anchor from the old geometry before changing the frame (nil at the bottom, which lands at the bottom again).
            if collectionView.frame.width > 0,
               view.bounds.width != collectionView.frame.width,
               lastConversationID != nil {
                widthChangeReadingAnchor = captureReadingAnchor()
            }
            collectionView.frame = view.bounds
            syncEstimatedItemWidth()
            reconcileViewportChangeEnsuringFullLayout(animated: false)
        }
        skeletonOverlay.frame = view.bounds
        rebuildIfReady()
        // Rotation / keyboard / SwiftUI frame change: the visible-area height changed, so the visible bubbles re-anchor
        updateUserBubbleGradientAnchors()
    }

    // MARK: - Viewport-anchored gradient of user bubbles

    /// Each visible user bubble takes the segment of the gradient matching its position in the visible area. Only the gradient layer geometry changes: no layout, no cell rebuild.
    private func updateUserBubbleGradientAnchors() {
        for case let cell as UserMessageCell in collectionView.visibleCells {
            updateUserBubbleGradientAnchor(cell)
        }
    }

    private func updateUserBubbleGradientAnchor(_ cell: UserMessageCell) {
        cell.updateBubbleGradientAnchor(
            viewportHeight: viewportHeight,
            bubbleTopInViewport: cell.bubbleTopY(in: collectionView) - collectionView.bounds.minY
        )
    }

    /// The estimated width follows the collection view's actual width; it is only written when it
    /// changes (changing the settings invalidates the whole layout).
    private func syncEstimatedItemWidth() {
        let width = collectionView.bounds.width
        guard width > 0, chatLayout.settings.estimatedItemSize?.width != width else { return }
        chatLayout.settings.estimatedItemSize = CGSize(width: width, height: Self.estimatedItemHeight)
    }

    private static let estimatedItemHeight: CGFloat = 80
    /// Placeholder width before the first layout (the iPhone baseline of 402pt), replaced as soon as
    /// the real width arrives.
    private static let fallbackEstimatedItemWidth: CGFloat = 402


    func update(
        viewModel: ChatCollectionViewModel,
        providerMetadataVersion: UInt,
        streamingPublisher: AnyPublisher<Void, Never>,
        streamingReasoningPublisher: AnyPublisher<ReasoningStreamDelta, Never>,
        streamingTextProvider: @escaping () -> String,
        streamingReasoningSnapshotProvider: @escaping () -> ReasoningStreamSnapshot?,
        streamingActivityPublisher: AnyPublisher<StreamActivityState, Never> =
            Empty<StreamActivityState, Never>().eraseToAnyPublisher(),
        streamingActivityProvider: @escaping () -> StreamActivityState? = { nil },
        onRetry: @escaping (ChatMessage) -> Void,
        onContinue: @escaping (ChatMessage) -> Void,
        onSaveNote: @escaping (ChatMessage) -> Void = { _ in },
        onOpenNoteReferences: @escaping ([NoteSummary]) -> Void = { _ in },
        onCrosscheck: @escaping (ChatMessage) -> Void = { _ in },
        onMcpStepAction: @escaping (ChatMessage, McpToolStepAction) -> Void = { _, _ in },
        onSearchAction: @escaping (ChatMessage, ExternalSearchCardAction) -> Void = { _, _ in },
        onOpenMemoryUsed: @escaping (ChatMessage) -> Void = { _ in },
        onSaveSelection: @escaping (ChatMessage, String) -> Void = { _, _ in },
        onAskSelection: @escaping (ChatMessage, QuoteSelectionContent) -> Void = { _, _ in },
        canReplaceCurrentNoteSelection: Bool = false,
        onReplaceSelection: @escaping (ChatMessage, String) -> Void = { _, _ in },
        onSaveCodeBlock: @escaping (ChatMessage, String, String?) -> Void = { _, _, _ in },
        onOpenCompactionDetail: @escaping () -> Void = {},
        onAcceptDirectiveSuggestion: @escaping () -> Void = {},
        onIgnoreDirectiveSuggestion: @escaping () -> Void = {},
        onSaveMemorySuggestion: @escaping () -> Void = {},
        onEditMemorySuggestion: @escaping () -> Void = {},
        onIgnoreMemorySuggestion: @escaping () -> Void = {},
        onRegenerate: @escaping (ChatMessage) -> Void,
        onEditMessage: @escaping (ChatMessage) -> Void,
        onSwitchModel: @escaping () -> Void,
        offersSwitchKey: @escaping (ChatMessage) -> Bool = { _ in false },
        onSwitchKey: @escaping (ChatMessage) -> Void = { _ in },
        pendingAnchorUserMessageID: UUID? = nil,
        onAnchorUserMessageConsumed: @escaping (UUID) -> Void = { _ in },
        scrollToBottomRequest: UInt = 0,
        onIsAtBottomChanged: @escaping (Bool) -> Void = { _ in },
        onAutoScrollEnabledChanged: @escaping (Bool) -> Void = { _ in },
        hasMoreAbove: Bool = false,
        hasMoreBelow: Bool = false,
        onRequestExtendUpward: @escaping () -> Void = {},
        onPendingSearchTargetHandled: @escaping () -> Void = {},
        outlineScrollRequest: UInt = 0,
        outlineScrollMessageID: UUID? = nil,
        outlineScrollShouldFlash: Bool = false,
        onVisibleTopUserMessageChanged: @escaping (UUID?) -> Void = { _ in }
    ) {
        let outlinePaginationChanged = hasMoreAbove != self.hasMoreAbove
            || hasMoreBelow != self.hasMoreBelow
        pendingViewModel = viewModel
        pendingProviderMetadataVersion = providerMetadataVersion
        self.onRetry = onRetry
        self.onContinue = onContinue
        self.onSaveNote = onSaveNote
        self.onOpenNoteReferences = onOpenNoteReferences
        self.onCrosscheck = onCrosscheck
        self.onMcpStepAction = onMcpStepAction
        self.onSearchAction = onSearchAction
        self.onOpenMemoryUsed = onOpenMemoryUsed
        self.onSaveSelection = onSaveSelection
        self.onAskSelection = onAskSelection
        self.canReplaceCurrentNoteSelection = canReplaceCurrentNoteSelection
        self.onReplaceSelection = onReplaceSelection
        self.onSaveCodeBlock = onSaveCodeBlock
        self.onOpenCompactionDetail = onOpenCompactionDetail
        self.onAcceptDirectiveSuggestion = onAcceptDirectiveSuggestion
        self.onIgnoreDirectiveSuggestion = onIgnoreDirectiveSuggestion
        self.onSaveMemorySuggestion = onSaveMemorySuggestion
        self.onEditMemorySuggestion = onEditMemorySuggestion
        self.onIgnoreMemorySuggestion = onIgnoreMemorySuggestion
        self.onRegenerate = onRegenerate
        self.onEditMessage = onEditMessage
        self.onSwitchModel = onSwitchModel
        self.offersSwitchKey = offersSwitchKey
        self.onSwitchKey = onSwitchKey
        self.pendingAnchorUserMessageID = pendingAnchorUserMessageID
        self.onAnchorUserMessageConsumed = onAnchorUserMessageConsumed
        self.onIsAtBottomChanged = onIsAtBottomChanged
        self.onAutoScrollEnabledChanged = onAutoScrollEnabledChanged
        self.hasMoreAbove = hasMoreAbove
        self.hasMoreBelow = hasMoreBelow
        self.onRequestExtendUpward = onRequestExtendUpward
        self.onPendingSearchTargetHandled = onPendingSearchTargetHandled
        self.onVisibleTopUserMessageChanged = onVisibleTopUserMessageChanged
        self.isSendingMessage = viewModel.isSendingMessage
        ReadAloudController.shared.observeChat(
            conversationID: viewModel.conversationID,
            streamingMessageID: viewModel.streamingMessageID
        )
        streamingCoordinator.bind(
            publisher: streamingPublisher,
            reasoningPublisher: streamingReasoningPublisher,
            textProvider: streamingTextProvider,
            reasoningSnapshotProvider: streamingReasoningSnapshotProvider,
            activityPublisher: streamingActivityPublisher,
            activityProvider: streamingActivityProvider
        )
        let nowStreaming = viewModel.streamingMessageID != nil
        if stickController.isStreamingMode != nowStreaming {
            stickController.setStreamingMode(nowStreaming)
            if nowStreaming {
                startStreamingReconcileTick()
            } else {
                startSettleReconcileTick()
            }
            reportFollowingChangeIfNeeded()
        }
        let outlineContentChanged = viewModel.conversationID != lastConversationID
            || viewModel.messageRevision != lastMessageRevision
        if viewModel.conversationID != lastConversationID
            || viewModel.messageRevision != lastMessageRevision
            || providerMetadataVersion != lastProviderMetadataVersion
            || viewModel.compactionSeparator != lastCompactionSeparator
            || viewModel.directiveSuggestionMessageID != lastDirectiveSuggestionMessageID
            || viewModel.memorySuggestion != lastMemorySuggestion
            || viewModel.currentVisionInput != lastCurrentVisionInput {
            contentDirty = true
            prewarmMarkdown(rows: viewModel.rows)
        }
        rebuildIfReady()
        handleScrollToBottomRequest(scrollToBottomRequest)
        handleOutlineScrollRequest(outlineScrollRequest, messageID: outlineScrollMessageID, shouldFlash: outlineScrollShouldFlash)
        if outlineContentChanged || outlinePaginationChanged {
            RunLoop.main.perform { [weak self] in
                self?.reportVisibleTopUserMessageIfNeeded()
            }
        }
    }

    private func handleScrollToBottomRequest(_ request: UInt) {
        guard request != lastScrollToBottomRequest else { return }
        lastScrollToBottomRequest = request
        guard lastConversationID != nil else { return }
        outlineScrollSeq &+= 1
        if stickController.isStreamingMode {
            stickController.pinToAnchor(animated: true)
        } else {
            stickController.resumeFollowing(animated: true)
            scrollToBottomEnsuringFullLayout()
            stickController.invalidateOffsetBaseline()
        }
        reportFollowingChangeIfNeeded()
    }


    private func handleOutlineScrollRequest(_ request: UInt, messageID: UUID?, shouldFlash: Bool = false) {
        guard request != lastHandledOutlineScrollRequest else { return }
        lastHandledOutlineScrollRequest = request
        guard let messageID else { return }
        if isDeferringInitialRebuildForTransition
            || !dataSource.rows.contains(where: { $0.id == messageID }) {
            pendingOutlineScroll = PendingOutlineScroll(
                messageID: messageID,
                shouldFlash: shouldFlash,
                conversationID: pendingViewModel?.conversationID
            )
            return
        }
        pendingOutlineScroll = nil
        pendingFlashMessageID = shouldFlash ? messageID : nil
        scrollToUserMessage(id: messageID, animated: false)
    }

    @discardableResult
    private func consumePendingOutlineScroll(conversationID: UUID?) -> Bool {
        guard let pending = pendingOutlineScroll else { return false }
        if let pendingConv = pending.conversationID, pendingConv != conversationID {
            pendingOutlineScroll = nil
            return false
        }
        guard dataSource.rows.contains(where: { $0.id == pending.messageID }) else { return false }
        pendingOutlineScroll = nil
        pendingFlashMessageID = pending.shouldFlash ? pending.messageID : nil
        scrollToUserMessage(id: pending.messageID, animated: false)
        revealCollectionViewIfAwaiting()
        return true
    }

    func scrollToUserMessage(id: UUID, animated: Bool) {
        scrollToMessage(id: id, progress: nil, animated: animated, source: "outline")
    }

    /// Scrolls to a message by id and converges (shared by outline jumps and reading anchors). `progress == nil` puts the message top 16pt below the viewport top;
    /// otherwise the viewport top lands at `progress` of the message's height. Returns false when the target is not in the window and no offset was written.
    @discardableResult
    private func scrollToMessage(id: UUID, progress: CGFloat?, animated: Bool, source: String) -> Bool {
        collectionView.layoutIfNeeded()
        guard let targetOffset = outlineTargetOffset(for: id, progress: progress) else { return false }
        bottomSettleGeneration &+= 1
        revealCollectionViewIfAwaiting()
        stickController.userDidGrab()
        recordProgrammaticJump(to: targetOffset, source: source)
        collectionView.setContentOffset(CGPoint(x: 0, y: targetOffset), animated: animated)
        stickController.invalidateOffsetBaseline()
        reportFollowingChangeIfNeeded()
        if !animated { reportVisibleTopUserMessageIfNeeded() }

        outlineScrollSeq &+= 1
        let seq = outlineScrollSeq
        RunLoop.main.perform { [weak self] in
            self?.runOutlineCorrectionPass(
                id: id,
                progress: progress,
                seq: seq,
                remainingPasses: Self.outlineCorrectionFrameBudget,
                lastCorrected: .nan,
                stableFrames: 0
            )
        }
        return true
    }

    /// Captures the current reading anchor. Returns nil (= at the bottom) when not streaming and within `atBottomThreshold` of the bottom (the same measure as `settle`);
    /// otherwise (including the pinned-to-top streaming state) the message id of the cell under the viewport top and where the top falls inside it.
    func captureReadingAnchor() -> ChatReadingAnchor? {
        let rows = dataSource.rows
        guard !rows.isEmpty else { return nil }
        if !stickController.isStreamingMode,
           distanceFromBottom < ChatStickToBottomController.atBottomThreshold {
            return nil
        }
        let topY = collectionView.contentOffset.y
        let visible = collectionView.indexPathsForVisibleItems.sorted(by: { $0.item < $1.item })
        for indexPath in visible where indexPath.item < rows.count {
            guard let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame,
                  frame.maxY > topY else { continue }
            // When the viewport top falls in a gap between cells or in the top padding, take the first cell below it with progress 0.
            let progress = frame.height > 0 ? (topY - frame.minY) / frame.height : 0
            return ChatReadingAnchor(messageID: rows[indexPath.item].id, progress: min(1, max(0, progress)))
        }
        return nil
    }

    /// Lands on a reading anchor (reusing the outline jump's converge-by-id loop, so no new offset writer).
    /// Returns false when the anchor's message is not in the window. The inset is recomputed from the current
    /// geometry first: reset() puts it back to minPad, and the pinned-top padding and streaming runway must be
    /// restored or the target would be clamped by a too-small maxOffset.
    private func restoreReadingAnchor(_ anchor: ChatReadingAnchor) -> Bool {
        guard dataSource.rows.contains(where: { $0.id == anchor.messageID }) else { return false }
        stickController.reconcileInsetOnly()
        return scrollToMessage(id: anchor.messageID, progress: anchor.progress,
                               animated: false, source: "reading_anchor")
    }

    private static let outlineCorrectionFrameBudget = 30
    private static let outlineCorrectionStableThreshold = 3

    private func runOutlineCorrectionPass(
        id: UUID,
        progress: CGFloat? = nil,
        seq: UInt,
        remainingPasses: Int,
        lastCorrected: CGFloat,
        stableFrames: Int
    ) {
        guard outlineScrollSeq == seq else { return }
        guard !collectionView.isTracking, !collectionView.isDragging, !collectionView.isDecelerating else { return }
        collectionView.layoutIfNeeded()
        guard let corrected = outlineTargetOffset(for: id, progress: progress) else { return }
        if abs(collectionView.contentOffset.y - corrected) > 0.5 {
            collectionView.setContentOffset(CGPoint(x: 0, y: corrected), animated: false)
            stickController.invalidateOffsetBaseline()
        }
        reportVisibleTopUserMessageIfNeeded()

        if remainingPasses == Self.outlineCorrectionFrameBudget,
           let flashID = pendingFlashMessageID, flashID == id {
            pendingFlashMessageID = nil
            if let rowIndex = dataSource.rows.firstIndex(where: { $0.id == id }),
               let cell = collectionView.cellForItem(at: IndexPath(item: rowIndex, section: 0)) {
                NoteMessageHighlighter.flash(cell.contentView)
            }
        }

        let nextStable = (corrected == lastCorrected) ? stableFrames + 1 : 0
        guard remainingPasses > 0, nextStable < Self.outlineCorrectionStableThreshold else { return }
        let timer = Timer(timeInterval: Self.bottomSettleFrameInterval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.runOutlineCorrectionPass(
                    id: id,
                    progress: progress,
                    seq: seq,
                    remainingPasses: remainingPasses - 1,
                    lastCorrected: corrected,
                    stableFrames: nextStable
                )
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// With a non-nil `progress` (a reading anchor) the 16pt top padding is replaced by "the viewport top lands at `progress` of the message's height".
    private func outlineTargetOffset(for id: UUID, progress: CGFloat? = nil) -> CGFloat? {
        guard let rowIndex = dataSource.rows.firstIndex(where: { $0.id == id }),
              let attributes = collectionView.layoutAttributesForItem(at: IndexPath(item: rowIndex, section: 0))
        else { return nil }
        let maxOffset = max(
            0,
            collectionView.collectionViewLayout.collectionViewContentSize.height
                + collectionView.contentInset.bottom
                - stickController.streamingRunway()
                - collectionView.bounds.height
        )
        let desiredTop = progress.map { attributes.frame.minY + $0 * attributes.frame.height }
            ?? attributes.frame.minY - Self.outlineScrollTopPadding
        return min(maxOffset, max(0, desiredTop))
    }

    private func reportVisibleTopUserMessageIfNeeded() {
        let id = computeTopVisibleUserMessageID()
        if hasReportedTopUserMessage && id == lastReportedTopUserMessageID { return }
        hasReportedTopUserMessage = true
        lastReportedTopUserMessageID = id
        onVisibleTopUserMessageChanged(id)
    }

    private func computeTopVisibleUserMessageID() -> UUID? {
        let rows = dataSource.rows
        guard !rows.isEmpty else { return nil }
        let firstUserID = outlineFirstUserMessageID
        let lastUserID = outlineLastUserMessageID
        let visible = collectionView.indexPathsForVisibleItems.sorted(by: { $0.item < $1.item })
        guard !visible.isEmpty else { return firstUserID }
        let activationY = collectionView.contentOffset.y + collectionView.bounds.height * 0.33
        var activationItem = visible.first!.item
        for indexPath in visible {
            guard indexPath.item < rows.count,
                  let attributes = collectionView.layoutAttributesForItem(at: indexPath)
            else { continue }
            if attributes.frame.minY <= activationY {
                activationItem = indexPath.item
            }
        }
        var idx = min(max(activationItem, 0), rows.count - 1)
        while idx >= 0 && rows[idx].message.role != .user { idx -= 1 }
        let focusID = idx >= 0 ? rows[idx].id : firstUserID
        let edgeEpsilon: CGFloat = 1
        return ChatOutline.resolvedActiveID(
            firstID: firstUserID,
            lastID: lastUserID,
            focusID: focusID,
            atConversationStart: !hasMoreAbove && collectionView.contentOffset.y <= edgeEpsilon,
            atConversationEnd: !hasMoreBelow && distanceFromBottom <= edgeEpsilon
        )
    }

    private func reconcileViewportChangeEnsuringFullLayout(animated: Bool) {
        collectionView.layoutIfNeeded()
        stickController.reconcileForViewportChange(animated: animated)
        if stickController.isFollowing && !stickController.isStreamingMode {
            scrollToBottomEnsuringFullLayout()
            stickController.invalidateOffsetBaseline()
        }
        reportFollowingChangeIfNeeded()
    }

    private func startStreamingReconcileTick() {
        if reconcileTickToken != nil, reconcileTickKind == .streaming { return }
        stopStreamingReconcileTick()
        reconcileTickKind = .streaming
        reconcileTickToken = displayClock.addSubscriber { [weak self] _ in
            guard let self else { return }
            guard Self.shouldRunReconcileTick(
                isDragging: self.collectionView.isDragging,
                isDecelerating: self.collectionView.isDecelerating
            ) else { return }
            self.stickController.reconcile(animated: false)
        }
        displayClock.resume()
    }

    nonisolated static func shouldRunReconcileTick(isDragging: Bool, isDecelerating: Bool) -> Bool {
        return !isDragging && !isDecelerating
    }

    private func scheduleQuiescentInsetReconcile() {
        guard reconcileTickToken == nil, !pendingContentSizeReconcile else { return }
        pendingContentSizeReconcile = true
        RunLoop.main.perform { [weak self] in
            guard let self else { return }
            self.pendingContentSizeReconcile = false
            guard self.reconcileTickToken == nil, !self.stickController.isStreamingMode else { return }
            guard Self.shouldRunReconcileTick(
                isDragging: self.collectionView.isDragging,
                isDecelerating: self.collectionView.isDecelerating
            ) else {
                self.needsSettleInsetReconcile = true
                return
            }
            self.stickController.reconcileInsetOnly()
        }
    }

    private func stopStreamingReconcileTick() {
        guard let token = reconcileTickToken else { return }
        displayClock.removeSubscriber(token)
        reconcileTickToken = nil
        reconcileTickKind = nil
    }

    private func startSettleReconcileTick() {
        stopStreamingReconcileTick()
        reconcileTickKind = .settle
        var startTS: CFTimeInterval = -1
        var didReconcile = false
        reconcileTickToken = displayClock.addSubscriber { [weak self] ts in
            guard let self else { return }
            if startTS < 0 { startTS = ts }
            if Self.shouldRunReconcileTick(
                isDragging: self.collectionView.isDragging,
                isDecelerating: self.collectionView.isDecelerating
            ) {
                self.stickController.reconcile(animated: false)
                didReconcile = true
            }
            if ts - startTS >= 0.7, didReconcile {
                self.stopStreamingReconcileTick()
            }
        }
        displayClock.resume()
    }

    private func prewarmMarkdown(rows: [ChatCollectionProjectionBuilder.MessageRow]) {
        let isDark = traitCollection.userInterfaceStyle == .dark
        let texts: [String] = rows.reversed().compactMap { row in
            guard row.message.role == .assistant,
                  row.message.state != .generating,
                  !row.message.text.isEmpty else { return nil }
            return row.message.text
        }
        guard !texts.isEmpty else { return }
        let progress = ChatPrewarmProgress()
        prewarmProgress = progress
        Task { [markdownCacheActor] in
            for text in texts {
                await markdownCacheActor.prepareRendered(text: text, isDark: isDark)
            }
            progress.markDone()
        }
    }


    private func rebuildIfReady() {
        guard let viewModel = pendingViewModel else { return }
        let width = collectionView.bounds.width
        guard width > 0 else { return }
        let widthChanged = width != lastMeasuredWidth
        guard contentDirty || widthChanged else { return }

        if isDeferringInitialRebuildForTransition,
           lastConversationID == nil || viewModel.conversationID != lastConversationID,
           viewModel.streamingMessageID == nil,
           Self.shouldDeferInitialRebuild(rows: viewModel.rows,
                                          viewportHeight: collectionView.bounds.height) {
            showSkeletonOverlay()
            if deferralFallbackTimer == nil, !deferralFlushScheduled {
                #if DEBUG
                AppLog.info(
                    "initial rebuild deferred for \(viewModel.rows.count) rows; skeleton shown "
                    + "with a 0.8s fallback timer",
                    module: "ChatOpen"
                )
                #endif
                let timer = Timer(timeInterval: 0.8, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.endInitialRebuildTransitionDeferralAndFlush(source: "fallback-timer")
                    }
                }
                deferralFallbackTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
            return
        }

        let plan = ChatCollectionProjectionBuilder.makeSnapshotPlan(
            from: viewModel.rows,
            streamingMessageID: viewModel.streamingMessageID,
            streamingText: viewModel.streamingText,
            providerMetadataVersion: pendingProviderMetadataVersion
        )
        let context = ChatListDataSource.RenderContext(
            parentViewController: self,
            // The bubble limit also loses the avatar and both side margins: on a 393 pt wide phone the bubble is at
            // most 301, and measuring at 320 counts too few lines and clips the last one.
            maxBubbleWidth: min(Self.userBubbleMaxWidth, max(120, width - UserMessageCell.horizontalChrome)),
            onRetry: onRetry,
            onContinue: onContinue,
            onSaveNote: onSaveNote,
            onOpenNoteReferences: onOpenNoteReferences,
            onCrosscheck: onCrosscheck,
            onMcpStepAction: onMcpStepAction,
            onSearchAction: onSearchAction,
            onOpenMemoryUsed: onOpenMemoryUsed,
            onSaveSelection: onSaveSelection,
            onAskSelection: onAskSelection,
            canReplaceCurrentNoteSelection: canReplaceCurrentNoteSelection,
            onReplaceSelection: onReplaceSelection,
            onSaveCodeBlock: onSaveCodeBlock,
            onOpenCompactionDetail: onOpenCompactionDetail,
            onAcceptDirectiveSuggestion: onAcceptDirectiveSuggestion,
            onIgnoreDirectiveSuggestion: onIgnoreDirectiveSuggestion,
            onSaveMemorySuggestion: onSaveMemorySuggestion,
            onEditMemorySuggestion: onEditMemorySuggestion,
            onIgnoreMemorySuggestion: onIgnoreMemorySuggestion,
            onRegenerate: onRegenerate,
            onEditMessage: onEditMessage,
            onSwitchModel: onSwitchModel,
            offersSwitchKey: offersSwitchKey,
            onSwitchKey: onSwitchKey,
            isSendingMessage: isSendingMessage,
            isErrorDismissed: { [weak self] id in self?.dismissedErrorIDs.contains(id) ?? false },
            isRecoveryDetailExpanded: { [weak self] id in self?.expandedRecoveryDetailIDs.contains(id) ?? false },
            onDismissError: { [weak self] id in self?.dismissedErrorIDs.insert(id) },
            onToggleRecoveryDetail: { [weak self] id, expanded in
                if expanded { self?.expandedRecoveryDetailIDs.insert(id) }
                else { self?.expandedRecoveryDetailIDs.remove(id) }
            },
            streamingMessageID: viewModel.streamingMessageID,
            onConfigureStreamingCell: { [weak self] cell in
                guard let self else { return }
                self.streamingCoordinator.attachStreaming(to: cell)
                cell.chunkFader.isScrollingProvider = { [weak collectionView = self.collectionView] in
                    guard let cv = collectionView else { return false }
                    return cv.isDragging || cv.isDecelerating
                }
                cell.isNearBottomProvider = { [weak self] in
                    guard let self else { return false }
                    return self.distanceFromBottom < self.collectionView.bounds.height
                }
            }
        )

        let isConversationSwitch = viewModel.conversationID != lastConversationID
        if isConversationSwitch {
            dismissedErrorIDs.removeAll()
            expandedRecoveryDetailIDs.removeAll()
            lastHandledAnchorID = nil
            anchorUserMessageID = nil
            stopStreamingReconcileTick()
            // A different conversation: the previous conversation's table and code cards will not be taken back.
            ChatRichCardRecycling.purgeAll()
        }
        let isInitialOrReset = lastConversationID == nil || isConversationSwitch || widthChanged
        lastMeasuredWidth = width
        // Width change of the same controller (not the first build, not a conversation switch): use the anchor captured before the frame changed; a conversation switch discards it.
        let isWidthOnlyChange = widthChanged && lastConversationID != nil && !isConversationSwitch
        let widthAnchor = isWidthOnlyChange ? widthChangeReadingAnchor : nil
        widthChangeReadingAnchor = nil

        let diff = dataSource.computeDiff(newRows: viewModel.rows, newRenderModels: plan.renderModelsByID)
        let commit: () -> Void = { [weak self] in
            guard let self else { return }
            self.dataSource.commit(rows: viewModel.rows, renderModels: plan.renderModelsByID, context: context)
            self.outlineFirstUserMessageID = viewModel.rows.first(where: { $0.message.role == .user })?.id
            self.outlineLastUserMessageID = viewModel.rows.last(where: { $0.message.role == .user })?.id
        }
        if isInitialOrReset {
            if isDeferringInitialRebuildForTransition {
                isDeferringInitialRebuildForTransition = false
                deferralFallbackTimer?.invalidate()
                deferralFallbackTimer = nil
            }
            commit()
            let hideUntilBottomSettled = lastConversationID == nil || isConversationSwitch
            if hideUntilBottomSettled {
                isAwaitingReveal = true
                collectionView.alpha = 0
                if viewModel.streamingMessageID == nil,
                   Self.shouldDeferInitialRebuild(rows: viewModel.rows,
                                                  viewportHeight: collectionView.bounds.height) {
                    showSkeletonOverlay()
                }
            }
            let reloadStart = CACurrentMediaTime()
            let relayoutInterval = isWidthOnlyChange
                ? Self.relayoutSignposter.beginInterval("chat.widthRelayout",
                                                        id: Self.relayoutSignposter.makeSignpostID())
                : nil
            collectionView.reloadData()
            collectionView.layoutIfNeeded()
            if let relayoutInterval {
                Self.relayoutSignposter.endInterval("chat.widthRelayout", relayoutInterval)
                #if DEBUG
                _testLastWidthRelayoutMs = (CACurrentMediaTime() - reloadStart) * 1000
                #endif
            }
            #if DEBUG
            AppLog.info(
                "initial reload and layout took \(Int((CACurrentMediaTime() - reloadStart) * 1000))ms "
                + "for \(viewModel.rows.count) rows",
                module: "ChatOpen"
            )
            #endif
            stickController.reset()
            if viewModel.streamingMessageID != nil {
                stickController.setStreamingMode(true)
                startStreamingReconcileTick()
            }
            // Both jump handlers scroll on their own, and so does a reading anchor (the reader was
            // in the history before a width change, or one was injected from outside: it lands back
            // by message id and ratio). Only fall back to the bottom when none of them claimed this
            // first layout.
            if !handlePendingSearchTargetIfNeeded(viewModel),
               !consumePendingOutlineScroll(conversationID: viewModel.conversationID),
               !((isWidthOnlyChange ? widthAnchor : takePendingReadingAnchor()).map { restoreReadingAnchor($0) } ?? false) {
                scrollToBottomEnsuringFullLayout()
            }
        } else if diff.requiresFullReload {
            commit()
            collectionView.reloadData()
        } else if !diff.isEmpty {
            let isPrepend = diff.inserts.contains(0)
            applyIncrementalUpdate(diff, commit: commit, isPrepend: isPrepend)
        } else {
            commit()
        }
        handlePendingAnchorIfNeeded()

        lastConversationID = viewModel.conversationID
        lastMessageRevision = viewModel.messageRevision
        lastProviderMetadataVersion = pendingProviderMetadataVersion
        lastCompactionSeparator = viewModel.compactionSeparator
        lastDirectiveSuggestionMessageID = viewModel.directiveSuggestionMessageID
        lastMemorySuggestion = viewModel.memorySuggestion
        lastCurrentVisionInput = viewModel.currentVisionInput
        contentDirty = false
    }

    /// Takes the injected reading anchor (once; when its message is not in the window `restoreReadingAnchor` fails and the list lands at the bottom).
    private func takePendingReadingAnchor() -> ChatReadingAnchor? {
        defer { pendingReadingAnchor = nil }
        return pendingReadingAnchor
    }

    ///
    ///
    private func applyIncrementalUpdate(
        _ diff: ChatListDiff.Result,
        commit: @escaping () -> Void,
        isPrepend: Bool = false
    ) {
        let batch = { [weak self] in
            guard let self else { return }
            commit()
            self.applyCollectionMutations(diff)
        }

        if isPrepend {
            applyPrependUpdate(diff: diff, commit: commit)
            return
        }

        UIView.performWithoutAnimation {
            collectionView.performBatchUpdates(batch, completion: nil)
            applyShiftedReconfigures(diff)
        }
    }

    private struct PrependViewportAnchor {
        let messageID: UUID
        let snapshot: ChatLayoutPositionSnapshot
    }

    private func applyPrependUpdate(diff: ChatListDiff.Result, commit: @escaping () -> Void) {
        releaseFirstResponderHeldOutsideViewport()
        collectionView.setNeedsLayout()
        collectionView.layoutIfNeeded()

        var verdict = prependGeometryVerdict(stage: .preBatch)
        if !verdict.isConsistent { verdict = reconvergeGeometry(stage: .preBatch) }
        guard verdict.isConsistent else {
            recoverPrependFromInconsistentGeometry(commit: commit, stage: .preBatch, verdict: verdict)
            return
        }

        let anchor = capturePrependViewportAnchor()
        UIView.performWithoutAnimation {
            collectionView.performBatchUpdates({
                commit()
                applyCollectionMutations(diff)
            }, completion: nil)
            applyShiftedReconfigures(diff)
            collectionView.setNeedsLayout()
            collectionView.layoutIfNeeded()
        }
        var committed = prependGeometryVerdict(stage: .postBatch)
        if !committed.isConsistent { committed = reconvergeGeometry(stage: .postBatch) }
        guard committed.isConsistent else {
            recoverCommittedPrependFromInconsistentGeometry(anchor: anchor, stage: .postBatch, verdict: committed)
            return
        }
        if let anchor {
            restorePrependViewportAnchor(anchor)
        }
        stickController.invalidateOffsetBaseline()
    }

    /// Makes a cell that is far outside the viewport but still holds the first responder give it up, so UIKit
    /// can reuse the cell.
    ///
    /// UICollectionView never reuses a cell that holds the first responder. Message text is a selectable
    /// UITextView, so long-pressing to select text makes it first responder; scrolling back to the top to load
    /// history afterwards leaves that cell in `visibleCells`, tens of thousands of points away from the
    /// viewport, with a frame that matches its layout attributes. The geometry barrier then reports
    /// `stale_viewport` and the whole list is reloaded, and because no anchor can be trusted before the batch,
    /// the prepended rows push the reading position away.
    ///
    /// The barrier is right to reject that cell (carrying it into `restoreContentOffset` is exactly what the
    /// barrier exists to prevent), so the criteria stay as they are and the cause is removed first instead: a
    /// selection inside a cell nobody can see means nothing to the user, and once it resigns the next layout
    /// pass reuses the cell normally, so the prepend takes the regular path and the reading position holds.
    /// The responder chain stops at `ChatListCollectionView` (`canBecomeFirstResponder == true`), which makes
    /// resigning here safe even inside a SwiftUI graph update.
    private func releaseFirstResponderHeldOutsideViewport() {
        let bounds = collectionView.bounds
        let tolerance = max(bounds.height, 1)
        for cell in collectionView.visibleCells {
            guard let overflow = Self.viewportOverflow(cellFrame: cell.frame, viewport: bounds, tolerance: tolerance),
                  overflow > 0,
                  Self.containsFirstResponder(cell) else { continue }
            cell.endEditing(true)
        }
    }

    private static func containsFirstResponder(_ view: UIView) -> Bool {
        view.isFirstResponder || view.subviews.contains { containsFirstResponder($0) }
    }

    private func reconvergeGeometry(stage: PrependGeometryStage) -> PrependGeometryVerdict {
        chatLayout.invalidateLayout()
        collectionView.setNeedsLayout()
        collectionView.layoutIfNeeded()
        return prependGeometryVerdict(stage: stage)
    }

    private func applyCollectionMutations(_ diff: ChatListDiff.Result) {
        if !diff.deletes.isEmpty {
            collectionView.deleteItems(at: diff.deletes.map { IndexPath(item: $0, section: 0) })
        }
        if !diff.inserts.isEmpty {
            collectionView.insertItems(at: diff.inserts.map { IndexPath(item: $0, section: 0) })
        }
        if !diff.reconfigures.isEmpty, !diff.reconfiguresShiftedByStructure {
            collectionView.reconfigureItems(at: diff.reconfigures.map { IndexPath(item: $0, section: 0) })
        }
    }

    /// Reconfigures shifted by an insert or delete in the same update run after the structural change is
    /// committed, with new indexes. Inside the batch, the same number would both pick the existing cell from
    /// the pre-update table and query the already-committed dataSource, so a shifted row gets mismatched;
    /// see `ChatListDiff.Result.reconfigures`.
    private func applyShiftedReconfigures(_ diff: ChatListDiff.Result) {
        guard diff.reconfiguresShiftedByStructure, !diff.reconfigures.isEmpty else { return }
        collectionView.performBatchUpdates({
            collectionView.reconfigureItems(at: diff.reconfigures.map { IndexPath(item: $0, section: 0) })
        }, completion: nil)
    }

    struct PrependGeometryVerdict {
        enum Reason: String {
            case cellWithoutIndexPath = "no_index_path"
            case rowOutOfRange = "row_out_of_range"
            case nonFiniteFrame = "non_finite_frame"
            case staleViewport = "stale_viewport"
        }
        let reason: Reason?
        let visibleCount: Int
        let rowCount: Int
        let worstOverflow: CGFloat
        let viewportTop: CGFloat
        let viewportHeight: CGFloat
        let offendingCount: Int
        let worstItem: Int?
        let worstCellMinY: CGFloat
        let worstAttributeMinY: CGFloat?
        /// Whether the worst cell still contains the first responder. Expected to stay false now that
        /// `releaseFirstResponderHeldOutsideViewport` runs first; if a recovery with matching cell and attribute
        /// positions shows up again, this tells "focus was not released" from "UIKit kept the cell for another reason".
        let worstCellHoldsFirstResponder: Bool
        var isConsistent: Bool { reason == nil }
    }

    private func prependGeometryVerdict(stage: PrependGeometryStage) -> PrependGeometryVerdict {
        let bounds = collectionView.bounds
        let tolerance = max(bounds.height, 1)
        let visibleCells = collectionView.visibleCells
        var reason: PrependGeometryVerdict.Reason?
        var worstOverflow: CGFloat = 0
        var offendingCount = 0
        var worstItem: Int?
        var worstCellMinY: CGFloat = 0
        var worstCellHoldsFirstResponder = false
        for cell in visibleCells {
            guard let indexPath = collectionView.indexPath(for: cell) else {
                reason = reason ?? .cellWithoutIndexPath
                continue
            }
            guard indexPath.section == 0, dataSource.rows.indices.contains(indexPath.item) else {
                reason = reason ?? .rowOutOfRange
                continue
            }
            let overflow = Self.viewportOverflow(
                cellFrame: cell.frame,
                viewport: bounds,
                tolerance: tolerance
            )
            guard let overflow else {
                reason = reason ?? .nonFiniteFrame
                continue
            }
            if overflow > 0 {
                reason = reason ?? .staleViewport
                offendingCount += 1
                if overflow > worstOverflow {
                    worstOverflow = overflow
                    worstItem = indexPath.item
                    worstCellMinY = cell.frame.minY
                    worstCellHoldsFirstResponder = Self.containsFirstResponder(cell)
                }
            }
        }
        let worstAttributeMinY: CGFloat? = worstItem.flatMap { item in
            chatLayout.layoutAttributesForItem(at: IndexPath(item: item, section: 0))?.frame.minY
        }
        #if DEBUG
        if stage == .postBatch, _testForceInconsistentPostBatchGeometry {
            return PrependGeometryVerdict(
                reason: .staleViewport,
                visibleCount: visibleCells.count,
                rowCount: dataSource.rows.count,
                worstOverflow: 99_999,
                viewportTop: bounds.origin.y,
                viewportHeight: bounds.height,
                offendingCount: max(offendingCount, 1),
                worstItem: worstItem,
                worstCellMinY: worstCellMinY,
                worstAttributeMinY: worstAttributeMinY,
                worstCellHoldsFirstResponder: worstCellHoldsFirstResponder
            )
        }
        #endif
        return PrependGeometryVerdict(
            reason: reason,
            visibleCount: visibleCells.count,
            rowCount: dataSource.rows.count,
            worstOverflow: worstOverflow,
            viewportTop: bounds.origin.y,
            viewportHeight: bounds.height,
            offendingCount: offendingCount,
            worstItem: worstItem,
            worstCellMinY: worstCellMinY,
            worstAttributeMinY: worstAttributeMinY,
            worstCellHoldsFirstResponder: worstCellHoldsFirstResponder
        )
    }

    nonisolated static func viewportOverflow(
        cellFrame: CGRect,
        viewport: CGRect,
        tolerance: CGFloat
    ) -> CGFloat? {
        guard cellFrame.minY.isFinite, cellFrame.maxY.isFinite,
              viewport.minY.isFinite, viewport.maxY.isFinite else { return nil }
        let toleratedTop = viewport.minY - tolerance
        let toleratedBottom = viewport.maxY + tolerance
        return max(0, max(toleratedTop - cellFrame.maxY, cellFrame.minY - toleratedBottom))
    }

    private func capturePrependViewportAnchor() -> PrependViewportAnchor? {
        guard let snapshot = chatLayout.getContentOffsetSnapshot(from: .top),
              snapshot.indexPath.section == 0,
              dataSource.rows.indices.contains(snapshot.indexPath.item) else { return nil }
        return PrependViewportAnchor(
            messageID: dataSource.rows[snapshot.indexPath.item].id,
            snapshot: snapshot
        )
    }

    private func restorePrependViewportAnchor(_ anchor: PrependViewportAnchor) {
        guard let item = dataSource.rows.firstIndex(where: { $0.id == anchor.messageID }) else { return }
        var snapshot = anchor.snapshot
        snapshot.indexPath = IndexPath(item: item, section: 0)
        chatLayout.restoreContentOffset(with: snapshot)
    }

    private enum PrependGeometryStage: String {
        case preBatch = "pre_batch"
        case postBatch = "post_batch"
    }

    private func recoverPrependFromInconsistentGeometry(
        commit: () -> Void,
        stage: PrependGeometryStage,
        verdict: PrependGeometryVerdict
    ) {
        commit()
        recoverCommittedPrependFromInconsistentGeometry(anchor: nil, stage: stage, verdict: verdict)
    }

    private func recoverCommittedPrependFromInconsistentGeometry(
        anchor: PrependViewportAnchor?,
        stage: PrependGeometryStage,
        verdict: PrependGeometryVerdict
    ) {
        UIView.performWithoutAnimation {
            collectionView.reloadData()
            collectionView.setNeedsLayout()
            collectionView.layoutIfNeeded()
        }
        if let anchor {
            restorePrependViewportAnchor(anchor)
        }
        stickController.invalidateOffsetBaseline()
        prependGeometryRecoveryCount &+= 1
        guard Self.shouldReportGeometryRecovery(count: prependGeometryRecoveryCount) else { return }
        AppLog.warning(
            "chat_prepend_inconsistent_geometry_recovered",
            module: "chat",
            context: [
                "recovery": "reload_data",
                "stage": stage.rawValue,
                "reason": verdict.reason?.rawValue ?? "none",
                "visible_cells": String(verdict.visibleCount),
                "offending_cells": String(verdict.offendingCount),
                "row_count": String(verdict.rowCount),
                "worst_overflow_pt": Self.metric(verdict.worstOverflow),
                "verdict_offset_y": Self.metric(verdict.viewportTop),
                "verdict_viewport_h": Self.metric(verdict.viewportHeight),
                "worst_item": verdict.worstItem.map(String.init) ?? "none",
                "worst_cell_min_y": Self.metric(verdict.worstCellMinY),
                "worst_attr_min_y": verdict.worstAttributeMinY.map(Self.metric) ?? "no_attributes",
                "worst_cell_first_responder": verdict.worstCellHoldsFirstResponder ? "1" : "0",
                "recovery_count": String(prependGeometryRecoveryCount),
                "last_jump_source": lastLargeJump?.source ?? "none",
                "last_jump_age_ms": lastLargeJump.map {
                    Self.metric(CGFloat((CACurrentMediaTime() - $0.at) * 1000))
                } ?? "none",
                "last_jump_distance_pt": lastLargeJump.map { Self.metric($0.distance) } ?? "none",
                "viewport_height": Self.metric(collectionView.bounds.height),
                "content_offset_y": Self.metric(collectionView.contentOffset.y),
                "content_height": Self.metric(chatLayout.collectionViewContentSize.height),
                "bottom_inset": Self.metric(collectionView.contentInset.bottom),
                "restored_anchor": anchor == nil ? "0" : "1",
                "is_streaming": stickController.isStreamingMode ? "1" : "0",
                "is_dragging": collectionView.isDragging ? "1" : "0",
                "is_decelerating": collectionView.isDecelerating ? "1" : "0"
            ]
        )
    }

    nonisolated static func shouldReportGeometryRecovery(count: Int) -> Bool {
        count > 0 && (count & (count - 1)) == 0
    }

    private func recordProgrammaticJump(to targetOffset: CGFloat, source: String) {
        let currentOffset = collectionView.contentOffset.y
        let distance = abs(targetOffset - currentOffset)
        let viewport = max(collectionView.bounds.height, 1)
        guard distance >= viewport * Self.largeJumpViewportMultiple else { return }
        lastLargeJump = (CACurrentMediaTime(), distance, source)
        AppLog.info(
            "large_programmatic_jump",
            module: "chat.scroll",
            context: [
                "source": source,
                "distance_pt": Self.metric(distance),
                "from_y": Self.metric(currentOffset),
                "to_y": Self.metric(targetOffset)
            ]
        )
    }

    private static func metric(_ value: CGFloat) -> String {
        guard value.isFinite else { return "non_finite" }
        return String(Int(min(max(value.rounded(), -1e9), 1e9)))
    }

    private func scrollToBottomEnsuringFullLayout() {
        bottomSettleGeneration &+= 1
        bottomSettleLastContentH = .nan
        bottomSettleStableFrames = 0
        scrollToBottomEnsuringFullLayout(
            generation: bottomSettleGeneration,
            remainingPasses: Self.bottomSettleFrameBudget
        )
    }

    private func revealCollectionViewIfAwaiting() {
        guard isAwaitingReveal else { return }
        isAwaitingReveal = false
        collectionView.alpha = 1
        hideSkeletonOverlay()
        #if DEBUG
        AppLog.info("settle finished, skeleton hidden", module: "ChatOpen")
        #endif
    }

    private static let bottomSettleFrameBudget = 30
    private static let bottomSettleStableThreshold = 3
    private static let bottomSettleFrameInterval: TimeInterval = 1.0 / 60.0
    private static let searchTargetTopPadding: CGFloat = 16.0

    @discardableResult
    private func handlePendingSearchTargetIfNeeded(_ viewModel: ChatCollectionViewModel) -> Bool {
        guard let target = viewModel.pendingSearchScrollTarget,
              target.conversationID == viewModel.conversationID else {
            return false
        }

        collectionView.layoutIfNeeded()
        if let rowIndex = viewModel.rows.firstIndex(where: {
            $0.message.text.localizedCaseInsensitiveContains(target.query)
        }), let attributes = collectionView.layoutAttributesForItem(at: IndexPath(item: rowIndex, section: 0)) {
            let maxOffset = max(
                0,
                collectionView.collectionViewLayout.collectionViewContentSize.height
                    + collectionView.contentInset.bottom
                    - stickController.streamingRunway()
                    - collectionView.bounds.height
            )
            let targetOffset = min(
                maxOffset,
                max(0, attributes.frame.minY - Self.searchTargetTopPadding)
            )
            recordProgrammaticJump(to: targetOffset, source: "search")
            collectionView.setContentOffset(CGPoint(x: 0, y: targetOffset), animated: false)
            stickController.invalidateOffsetBaseline()

            let targetID = viewModel.rows[rowIndex].message.id
            bottomSettleGeneration &+= 1
            outlineScrollSeq &+= 1
            let seq = outlineScrollSeq
            RunLoop.main.perform { [weak self] in
                self?.runOutlineCorrectionPass(
                    id: targetID,
                    seq: seq,
                    remainingPasses: Self.outlineCorrectionFrameBudget,
                    lastCorrected: .nan,
                    stableFrames: 0
                )
            }
        }

        revealCollectionViewIfAwaiting()
        reportFollowingChangeIfNeeded()
        onPendingSearchTargetHandled()
        return true
    }

    private func scrollToBottomEnsuringFullLayout(
        generation: UInt,
        remainingPasses: Int
    ) {
        guard generation == bottomSettleGeneration else { return }
        guard !collectionView.isDragging && !collectionView.isDecelerating else {
            revealCollectionViewIfAwaiting()
            return
        }
        let count = collectionView.numberOfItems(inSection: 0)
        guard count > 0 else {
            revealCollectionViewIfAwaiting()
            return
        }
        collectionView.layoutIfNeeded()
        let contentH = collectionView.collectionViewLayout.collectionViewContentSize.height
        let maxOffset = max(
            0,
            contentH + collectionView.contentInset.bottom - stickController.streamingRunway()
                - collectionView.bounds.height
        )
        if abs(collectionView.contentOffset.y - maxOffset) > 0.5 {
            recordProgrammaticJump(to: maxOffset, source: "bottom_settle")
            collectionView.setContentOffset(CGPoint(x: 0, y: maxOffset), animated: false)
        }
        stickController.invalidateOffsetBaseline()

        if contentH == bottomSettleLastContentH {
            bottomSettleStableFrames += 1
        } else {
            bottomSettleStableFrames = 0
            bottomSettleLastContentH = contentH
        }
        let stable = bottomSettleStableFrames >= Self.bottomSettleStableThreshold

        guard remainingPasses > 0 && !stable else {
            revealCollectionViewIfAwaiting()
            return
        }
        let timer = Timer(timeInterval: Self.bottomSettleFrameInterval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scrollToBottomEnsuringFullLayout(
                    generation: generation,
                    remainingPasses: remainingPasses - 1
                )
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func handlePendingAnchorIfNeeded() {
        guard let id = pendingAnchorUserMessageID, id != lastHandledAnchorID,
              dataSource.rows.contains(where: { $0.id == id }) else { return }
        lastHandledAnchorID = id
        anchorUserMessageID = id
        outlineScrollSeq &+= 1
        collectionView.layoutIfNeeded()
        stickController.pinToAnchor(animated: true)
        reportFollowingChangeIfNeeded()
        onAnchorUserMessageConsumed(id)
    }

    /// "Modifying state during view update, this will cause undefined behavior"runtime
    func reportFollowingChangeIfNeeded() {
        let current = stickController.isFollowing
        guard current != lastReportedIsFollowing else { return }
        lastReportedIsFollowing = current
        RunLoop.main.perform { [weak self] in
            guard let self else { return }
            self.onIsAtBottomChanged(current)
            self.onAutoScrollEnabledChanged(current)
        }
    }

    private func flushStreamingCellHeightIfNeeded() {
        for case let cell as AssistantMessageCell in collectionView.visibleCells {
            cell.flushStreamingHeightIfPending()
        }
    }

    /// Called by the list bridge when the list is rebuilt for a carrier change (two columns ↔ one): there is no push transition to protect, so the first build runs synchronously
    /// and folding does not flash the skeleton. Must be called before the first `update`.
    func skipInitialTransitionDeferral() {
        isDeferringInitialRebuildForTransition = false
        deferralFallbackTimer?.invalidate()
        deferralFallbackTimer = nil
    }

    #if DEBUG
    func _testEndTransitionDeferral() { endInitialRebuildTransitionDeferralAndFlush() }
    func _testCompleteInitialAppearance() {
        isDeferringInitialRebuildForTransition = false
        deferralFallbackTimer?.invalidate()
        deferralFallbackTimer = nil
    }
    func _testSkeletonVisible() -> Bool { !skeletonOverlay.isHidden }
    func _testNumberOfItems() -> Int {
        collectionView.numberOfItems(inSection: 0)
    }
    func _testContentOffsetY() -> CGFloat { collectionView.contentOffset.y }
    func _testCollectionViewAlpha() -> CGFloat { collectionView.alpha }
    func _testIsStreamingMode() -> Bool { stickController.isStreamingMode }
    func _testTriggerCompetingScrollSettle() { scrollToBottomEnsuringFullLayout() }
    func _testContentHeight() -> CGFloat { collectionView.collectionViewLayout.collectionViewContentSize.height }
    func _testSetContentOffset(_ y: CGFloat) { collectionView.contentOffset = CGPoint(x: 0, y: y) }
    func _testTopVisibleMessageID() -> UUID? {
        guard let topIdx = collectionView.indexPathsForVisibleItems.min()?.item,
              topIdx < dataSource.rows.count else { return nil }
        return dataSource.rows[topIdx].id
    }
    func _testVisualPosition(of id: UUID) -> CGFloat? {
        guard let idx = dataSource.rows.firstIndex(where: { $0.id == id }),
              let attr = collectionView.layoutAttributesForItem(at: IndexPath(item: idx, section: 0)) else { return nil }
        return attr.frame.minY - collectionView.contentOffset.y
    }
    func _testVisualMaxY(of id: UUID) -> CGFloat? {
        guard let idx = dataSource.rows.firstIndex(where: { $0.id == id }),
              let attr = collectionView.layoutAttributesForItem(at: IndexPath(item: idx, section: 0)) else { return nil }
        return attr.frame.maxY - collectionView.contentOffset.y
    }
    func _testCollectionBoundsHeight() -> CGFloat { collectionView.bounds.height }
    func _testBottomInset() -> CGFloat { collectionView.contentInset.bottom }
    func _testAssistantMetadataView(for id: UUID) -> AssistantMetadataView? {
        guard let idx = dataSource.rows.firstIndex(where: { $0.id == id }),
              let cell = collectionView.cellForItem(at: IndexPath(item: idx, section: 0)) as? AssistantMessageCell
        else { return nil }
        return cell.metadataView
    }
    func _testCellForMessage(_ id: UUID) -> UICollectionViewCell? {
        guard let idx = dataSource.rows.firstIndex(where: { $0.id == id }) else { return nil }
        return collectionView.cellForItem(at: IndexPath(item: idx, section: 0))
    }
    func _testPrependGeometryRecoveryCount() -> Int { prependGeometryRecoveryCount }
    #endif
}

final class ChatPrewarmProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func markDone() {
        lock.lock()
        done = true
        lock.unlock()
    }

    var isDone: Bool {
        lock.lock()
        defer { lock.unlock() }
        return done
    }
}

// MARK: - ChatLayoutDelegate

extension ChatListViewController: ChatLayoutDelegate {
    func sizeForItem(_ chatLayout: CollectionViewChatLayout, at indexPath: IndexPath) -> ItemSize {
        let width = collectionView.bounds.width
        guard indexPath.item < dataSource.rows.count else {
            return .estimated(CGSize(width: width, height: 80))
        }
        let height = Self.estimatedRowHeight(for: dataSource.rows[indexPath.item], width: width)
        return .estimated(CGSize(width: width, height: height))
    }

    nonisolated static func estimatedRowHeight(
        for row: ChatCollectionProjectionBuilder.MessageRow,
        width: CGFloat
    ) -> CGFloat {
        let message = row.message
        let isUser = message.role == .user
        let contentWidth = isUser ? userContentWidth(for: width) : assistantContentWidth(for: width)

        var height = row.topPadding
        height += isUser
            ? userBubbleChromeHeight
            : assistantChromeHeight(showMetadata: row.showMetadata)

        // A folded long user message (`UserMessageFold`) shows only the capped part plus the "Show full message"
        // pill row, independent of the full length.
        if isUser, UserMessageFold.shouldFold(message.text) {
            let preview = estimatedMarkdownHeight(
                for: UserMessageFold.preview(of: message.text),
                contentWidth: contentWidth,
                metrics: .userBubble
            )
            height += min(preview, UserMessageFold.collapsedTextHeight) + userFullTextButtonRowHeight
        } else {
            height += estimatedMarkdownHeight(
                for: message.text,
                contentWidth: contentWidth,
                metrics: isUser ? .userBubble : .assistantBody
            )
        }
        if message.text.contains("\n|") { height *= 1.1 }

        if !isUser, let reasoning = message.reasoningText, !reasoning.isEmpty {
            height += reasoningCollapsedHeight
        }

        let imageAttachments = (message.attachments ?? []).filter { $0.kind == .image }
        if !imageAttachments.isEmpty {
            let imageWidth: CGFloat = isUser
                ? max(120, min(userBubbleMaxWidth, width * 0.82)) - 8
                : assistantContentWidth(for: width)
            let ratios = imageAttachments.map {
                CachedAttachmentImage.cachedPreferredAspectRatio(
                    for: $0,
                    partitionUID: AppSessionStore.activeUID
                ) ?? CachedAttachmentImage.fallbackAspectRatio
            }
            height += estimatedImagesHeight(imageWidth: imageWidth, ratios: ratios, userGrid: isUser)
        }
        // User file attachments: `UserAttachmentsGroup` lays out one row of file chips; below images there is one more stack spacing.
        if isUser, (message.attachments ?? []).contains(where: { $0.kind != .image }) {
            height += UserFileAttachmentLayout.chipHeight
            if !imageAttachments.isEmpty { height += UserFileAttachmentLayout.rowSpacing }
        }

        // Before the body: the MCP step block. Only its collapsed height counts (it collapses once the
        // answer is complete).
        if !isUser, let steps = message.toolSteps, !steps.isEmpty {
            height += toolStepsCollapsedHeight
        }

        // The external search sources card is collapsed to its title row by default; without one, estimate the citations block as before.
        if !isUser, message.capabilityExecution?.externalSearch?.sourcesLine != nil {
            height += searchSourcesCollapsedHeight
            // Library / MCP sources still go in the ordinary citations block (below the sources card).
            let others = CitationsBlock.splitSearchSources(message.citations ?? []).others
            if !others.isEmpty { height += estimatedCitationsHeight(count: others.count) }
        } else if !isUser, let citations = message.citations, !citations.isEmpty {
            height += estimatedCitationsHeight(count: citations.count)
        }
        // External search error card (`UIKitSearchErrorCard`): title + subtitle + one row of buttons.
        if !isUser, message.capabilityExecution?.externalSearch?.errorCard != nil {
            height += searchErrorCardHeight
        }

        // After the citations: the reply notice line (relay web search was not used; footnote, wraps to two lines at common widths).
        if !isUser, row.replyNotice != nil {
            height += replyNoticeHeight
        }

        // Top of the cell: the compaction separator row (can be attached to both user and assistant).
        if row.compactionSeparator != nil {
            height += compactionSeparatorHeight
        }

        // Below the bubble: the "Set as instruction" suggestion bar (user only).
        if isUser, row.showsDirectiveSuggestion {
            height += directiveSuggestionHeight
        }
        // Below the attachments inside the bubble: the "not sent to this model" caption (attached only to user messages with images whose current vision projection is a placeholder).
        if isUser, UserMessageCell.showsNotSentToModel(attachments: message.attachments ?? [], visionInput: row.visionInput) {
            height += notSentCaptionHeight
        }
        // After the metadata action row: the "Save to memory?" bar (non-streaming assistant only); its height follows the candidate text line count.
        if !isUser, let memorySuggestion = row.memorySuggestion {
            height += memorySuggestionHeight(memorySuggestion, width: width)
        }

        // Recovery card (last failed assistant message, embedded by ChatListDataSource via
        // `AssistantMessageRecoveryBuilder.makeConfig`): a failed message's `message.text` is often empty,
        // so a text-length estimate only gives a lower bound, while the card itself measures 190-260pt
        // (title + body + 48pt primary button + technical details entry).
        // The estimate cannot see runtime state such as isDismissed / isSendingMessage, so assuming it is shown is the safe direction.
        if !isUser, message.state == .failed, row.isLastInConversation {
            height += estimatedRecoveryCardHeight(
                charsPerLine: max(1, contentWidth / proseFullCharWidth)
            )
        }
        return max(44, height.rounded())
    }

    nonisolated static func assistantContentWidth(for width: CGFloat) -> CGFloat {
        max(160, width - ChatCardStableWidth.contentChrome)
    }

    /// Clamped by the cell width the same way the cell measures (`UserMessageCell.horizontalChrome`):
    /// a 393 pt wide phone only has 301, not 320.
    nonisolated static func userContentWidth(for width: CGFloat) -> CGFloat {
        max(120, min(userBubbleMaxWidth, width * 0.82, width - UserMessageCell.horizontalChrome))
    }

    nonisolated static func estimatedRecoveryCardHeight(charsPerLine: CGFloat) -> CGFloat {
        let chrome: CGFloat = 20 + 20 + 6 + 12 + 48 + 12 + 25 + 20
        let bodyLines = max(1, (40 / max(charsPerLine, 1)).rounded(.up))
        return chrome + bodyLines * proseLineHeight + 8
    }

    /// `userGrid`: several images in a user bubble are not stacked one per row but laid out by `UserAttachmentsGroup` in a fixed grid:
    /// 2 images in one row of 128 squares, 3 in one row of 96 squares, 4+ in a 2x2 of 128 squares (the 4th cell carries +N), independent of aspect ratio.
    /// A single image stays a hero at width / ratio.
    nonisolated static func estimatedImagesHeight(
        imageWidth: CGFloat,
        ratios: [CGFloat],
        userGrid: Bool = false
    ) -> CGFloat {
        if userGrid, ratios.count >= 2 {
            let grid: CGFloat
            switch ratios.count {
            case 2:
                grid = UserImageAttachmentLayout.gridSide
            case 3:
                grid = UserImageAttachmentLayout.compactSide
            default:
                grid = UserImageAttachmentLayout.gridSide * 2 + UserImageAttachmentLayout.imageSpacing
            }
            return grid + 12
        }
        return ratios.reduce(0) { $0 + imageWidth / max($1, 0.1) + 12 }
    }

    nonisolated static func estimatedCitationsHeight(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let shown = min(count, CitationsBlock.collapsedLimit)
        let toggle: CGFloat = count > CitationsBlock.collapsedLimit ? citationsToggleHeight : 0
        return citationsHeaderHeight + CGFloat(shown) * citationsRowHeight + toggle
    }



    nonisolated struct TypographyMetrics: Sendable {
        let lineHeight: CGFloat
        let fullCharWidth: CGFloat
        let halfCharWidth: CGFloat

        static let assistantBody = TypographyMetrics(
            lineHeight: 26, fullCharWidth: 16, halfCharWidth: 8.2
        )
        static let userBubble = TypographyMetrics(
            lineHeight: 27, fullCharWidth: 16, halfCharWidth: 6.74
        )
    }

    nonisolated static var proseLineHeight: CGFloat { TypographyMetrics.assistantBody.lineHeight }
    nonisolated static var proseFullCharWidth: CGFloat { TypographyMetrics.assistantBody.fullCharWidth }
    nonisolated static let codeCharWidth: CGFloat = 8.4
    /// A code card adds no paragraph spacing, so this is the bare monospaced line height.
    /// Wrapping is already accounted for by `estimatedWrappedLines` at the given width; adding
    /// a second factor here would count it twice and overestimate every code block that stays
    /// under the preview cap.
    nonisolated static let codeLineHeight: CGFloat = 16.7
    nonisolated static let codeCardChromeHeight: CGFloat = 44
    nonisolated static let codeTextInset: CGFloat = 24

    nonisolated static func assistantChromeHeight(showMetadata: Bool) -> CGFloat {
        showMetadata ? 104 : 76
    }
    nonisolated static let userBubbleChromeHeight: CGFloat = 28

    /// The "Show full message" pill row of a folded user bubble (bubbleStack spacing 8 + the pill's footnote line
    /// height + 12 of vertical padding).
    nonisolated static let userFullTextButtonRowHeight: CGFloat = 36

    nonisolated static let reasoningCollapsedHeight: CGFloat = 58

    /// Collapsed height of the MCP step block (`UIKitToolStepsView`: a 46pt header plus the 8pt stack spacing
    /// to the body), whatever the number of steps.
    nonisolated static let toolStepsCollapsedHeight: CGFloat = 54
    /// Reply notice line (two footnote lines plus the slot spacing).
    nonisolated static let replyNoticeHeight: CGFloat = 44
    /// Estimates for the collapsed external search sources card (title row only) and the error card; the real height comes from cell self-sizing.
    nonisolated static let searchSourcesCollapsedHeight: CGFloat = 34
    nonisolated static let searchErrorCardHeight: CGFloat = 118
    /// Compaction separator row (`ContextCompactionSeparatorView`: top 8 + two 12pt lines + line spacing 2 + bottom 12).
    nonisolated static let compactionSeparatorHeight: CGFloat = 52
    /// "Set as instruction" suggestion bar (`DirectiveSuggestionBarView`: top gap 8 + padding 10x2 + one footnote line + gap 6 + button 28).
    nonisolated static let directiveSuggestionHeight: CGFloat = 80
    /// The "not sent to this model" caption (`UserMessageCell.notSentRow`: one caption2 line + bubbleStack spacing 8).
    nonisolated static let notSentCaptionHeight: CGFloat = 22

    /// "Save to memory?" bar (`MemorySuggestionBarView`): top gap 8 + padding 10x2 + one prompt line; with a candidate,
    /// add gap 6 + body (footnote, up to 2 lines) + gap 6 + button 28. With memory off there is only the prompt text, counted as two lines.
    nonisolated static func memorySuggestionHeight(_ bar: MemorySuggestionBar, width: CGFloat) -> CGFloat {
        let chrome = MemorySuggestionBarView.topGap + MemorySuggestionBarView.padding * 2
        guard let content = bar.content else {
            return chrome + memorySuggestionLineHeight * 2
        }
        let textWidth = userContentWidth(for: width) - MemorySuggestionBarView.padding * 2 - 2
        let lines = min(
            MemorySuggestionBarView.contentMaxLines,
            max(1, estimatedWrappedLines(
                in: content,
                contentWidth: textWidth,
                fullCharWidth: memorySuggestionFullCharWidth,
                halfCharWidth: memorySuggestionHalfCharWidth
            ))
        )
        return chrome
            + memorySuggestionLineHeight
            + MemorySuggestionBarView.spacing + lines * memorySuggestionLineHeight
            + MemorySuggestionBarView.spacing + MemorySuggestionBarView.buttonHeight
    }

    /// Footnote text metrics for the memory bar (13pt).
    nonisolated static let memorySuggestionLineHeight: CGFloat = 18
    nonisolated static let memorySuggestionFullCharWidth: CGFloat = 13
    nonisolated static let memorySuggestionHalfCharWidth: CGFloat = 6.6

    nonisolated static let citationsHeaderHeight: CGFloat = 25
    nonisolated static let citationsRowHeight: CGFloat = 53
    nonisolated static let citationsToggleHeight: CGFloat = 36

    nonisolated static let maxEstimateScanCharacters = 8192

    nonisolated static func estimatedMarkdownHeight(
        for text: String,
        contentWidth: CGFloat,
        metrics: TypographyMetrics = .assistantBody
    ) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        var height: CGFloat = 0
        var isCodeSegment = false
        for segment in text.components(separatedBy: "```") {
            if isCodeSegment {
                height += estimatedCodeBlockHeight(for: segment, contentWidth: contentWidth)
            } else {
                height += estimatedWrappedLines(
                    in: segment,
                    contentWidth: contentWidth,
                    fullCharWidth: metrics.fullCharWidth,
                    halfCharWidth: metrics.halfCharWidth
                ) * metrics.lineHeight
            }
            isCodeSegment.toggle()
        }
        return height
    }

    nonisolated static func estimatedCodeBlockHeight(for segment: String, contentWidth: CGFloat) -> CGFloat {
        let body: Substring
        if let newlineIndex = segment.firstIndex(of: "\n") {
            body = segment[segment.index(after: newlineIndex)...]
        } else {
            body = segment[...]
        }
        let trimmed = body.hasSuffix("\n") ? body.dropLast() : body
        let codeWidth = max(60, contentWidth - codeTextInset)
        let lines = estimatedWrappedLines(
            in: trimmed,
            contentWidth: codeWidth,
            fullCharWidth: codeCharWidth * 2,
            halfCharWidth: codeCharWidth
        )
        let natural = lines * codeLineHeight + codeTextInset
        return min(natural, UIKitCodeBlockCard.maxPreviewHeight) + codeCardChromeHeight
    }

    nonisolated static func estimatedWrappedLines(
        in segment: some StringProtocol,
        contentWidth: CGFloat,
        fullCharWidth: CGFloat,
        halfCharWidth: CGFloat
    ) -> CGFloat {
        guard !segment.isEmpty else { return 0 }
        let usableWidth = max(contentWidth, 1)
        var lines: CGFloat = 0
        var lineWidth: CGFloat = 0
        var scanned = 0
        var truncated = false
        for character in segment {
            if scanned >= maxEstimateScanCharacters {
                truncated = true
                break
            }
            scanned += 1
            if character == "\n" {
                lines += max(1, (lineWidth / usableWidth).rounded(.up))
                lineWidth = 0
                continue
            }
            lineWidth += isFullWidth(character) ? fullCharWidth : halfCharWidth
        }
        lines += max(1, (lineWidth / usableWidth).rounded(.up))
        if truncated {
            let total = segment.count
            if total > scanned {
                lines *= CGFloat(total) / CGFloat(scanned)
            }
        }
        return lines
    }

    nonisolated static func isFullWidth(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x1100...0x115F,
             0x2E80...0x303E,
             0x3041...0x33FF,
             0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xA000...0xA4CF,
             0xAC00...0xD7A3,
             0xF900...0xFAFF,
             0xFE10...0xFE19,
             0xFE30...0xFE6F,
             0xFF00...0xFF60,
             0xFFE0...0xFFE6,
             0x1F300...0x1F9FF,
             0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }

    func alignmentForItem(_ chatLayout: CollectionViewChatLayout, at indexPath: IndexPath) -> ChatItemAlignment {
        return .fullWidth
    }
}

// MARK: - ChatStickToBottomGeometry

extension ChatListViewController: ChatStickToBottomGeometry {
    var contentHeight: CGFloat {
        collectionView.collectionViewLayout.collectionViewContentSize.height
    }

    var viewportHeight: CGFloat {
        keyboardCoordinator.effectiveViewport(for: view)
    }

    var distanceFromBottom: CGFloat {
        let maxOffset = max(0, contentHeight + collectionView.contentInset.bottom - collectionView.bounds.height)
        return max(0, maxOffset - collectionView.contentOffset.y)
    }

    var anchorTopY: CGFloat? {
        guard let id = anchorUserMessageID,
              let idx = dataSource.rows.firstIndex(where: { $0.id == id }),
              let attr = collectionView.layoutAttributesForItem(at: IndexPath(item: idx, section: 0))
        else { return nil }
        return attr.frame.minY
    }

    var bottomObstruction: CGFloat {
        max(0, collectionView.bounds.height - viewportHeight)
    }
}


/// The chat list's collection view. Its only job is to stop the first responder chain here.
///
/// `updateUIViewController` runs inside the SwiftUI host's AttributeGraph update pass by
/// definition. The batch update we perform there makes UIKit relocate the first responder, and
/// if a cell currently holds one, `resignFirstResponder` walks the responder chain *upwards*
/// looking for something willing to take over.
///
/// That does not require an editable field: message bodies are `isEditable = false` but
/// `isSelectable = true` text views, and a text view holding a selection is a first responder
/// all the same. With every link in the chain declining, the walk leaves the collection view
/// and eventually asks the `_UIHostingView` that owns the representable, whose
/// `canBecomeFirstResponder` getter has to evaluate `responderNode` — re-entering the very
/// same host's graph update. The same attribute lands on the update stack twice,
/// AttributeGraph reports a cycle, and printing that diagnostic blocks the main thread on a
/// synchronous write until the watchdog kills the app.
///
/// `nextFirstResponder` stops at the first responder that answers true, so answering true here
/// removes the edge itself rather than the moment it fires: it holds regardless of when the
/// batch update starts or why the resign happens (batch update, cell reuse, scrolling away,
/// VoiceOver focus changes, interactive keyboard dismissal).
///
/// Letting the list hold focus is also the more accurate semantic for VoiceOver and hardware
/// keyboards — it is an interactive scrolling container, and the composer takes focus back with
/// its own `becomeFirstResponder` when the user starts typing.
final class ChatListCollectionView: UICollectionView {
    override var canBecomeFirstResponder: Bool { true }
}
