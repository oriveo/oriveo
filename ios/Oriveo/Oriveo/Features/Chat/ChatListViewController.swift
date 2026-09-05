import ChatLayout
import Combine
import UIKit

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
        layout.settings.estimatedItemSize = CGSize(width: UIScreen.main.bounds.width, height: 80)
        layout.delegate = self
        return layout
    }()
    private lazy var collectionView: UICollectionView = {
        let cv = UICollectionView(frame: .zero, collectionViewLayout: chatLayout)
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
        displayScale: traitCollection.displayScale > 0 ? traitCollection.displayScale : UIScreen.main.scale,
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
        onDidScroll: { [weak self] in self?.reportVisibleTopUserMessageIfNeeded() })

    private var pendingViewModel: ChatCollectionViewModel?
    private var pendingProviderMetadataVersion: UInt = 0
    private var onRetry: (ChatMessage) -> Void = { _ in }
    private var onContinue: (ChatMessage) -> Void = { _ in }
    private var onSaveNote: (ChatMessage) -> Void = { _ in }
    private var onOpenNoteReferences: ([NoteSummary]) -> Void = { _ in }
    private var onSaveSelection: (ChatMessage, String) -> Void = { _, _ in }
    private var onAskSelection: (ChatMessage, QuoteSelectionContent) -> Void = { _, _ in }
    private var canReplaceCurrentNoteSelection = false
    private var onReplaceSelection: (ChatMessage, String) -> Void = { _, _ in }
    private var onSaveCodeBlock: (ChatMessage, String, String?) -> Void = { _, _, _ in }
    private var onRegenerate: (ChatMessage) -> Void = { _ in }
    private var onEditMessage: (ChatMessage) -> Void = { _ in }
    private var onSwitchModel: () -> Void = {}
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
        var cost = text.count
        if text.contains("```") { cost += 3000 }
        if text.contains("\n|") { cost += 2000 }
        if !(row.message.attachments ?? []).isEmpty { cost += 1500 }
        return cost
    }

    nonisolated private static func estimatedRowHeight(
        _ row: ChatCollectionProjectionBuilder.MessageRow
    ) -> CGFloat {
        let lines = max(1, (row.message.text.count + 29) / 30)
        return CGFloat(lines) * 22 + 36
    }

    nonisolated static let deferInitialRebuildCostThreshold = 8000

    private func endInitialRebuildTransitionDeferralAndFlush(source: String = "test") {
        guard isDeferringInitialRebuildForTransition, !deferralFlushScheduled else { return }
        deferralFlushScheduled = true
        deferralFallbackTimer?.invalidate()
        deferralFallbackTimer = nil
        NSLog("[OPEN-TRACE] flush triggered source=%@", source)
        waitForPrewarmThenRebuild(start: CACurrentMediaTime())
    }

    private func waitForPrewarmThenRebuild(start: CFTimeInterval) {
        let waitedMs = (CACurrentMediaTime() - start) * 1000
        let prewarmDone = prewarmProgress?.isDone ?? true
        if prewarmDone || waitedMs >= 800 {
            NSLog("[OPEN-TRACE] initial rebuild released prewarmWait=%.0fms done=%d", waitedMs, prewarmDone ? 1 : 0)
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
        NSLog("[OPEN-TRACE] viewWillAppear animated=%d coordinator=%d deferring=%d",
              animated ? 1 : 0, transitionCoordinator != nil ? 1 : 0,
              isDeferringInitialRebuildForTransition ? 1 : 0)
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
        }
        collectionView.delegate = gestureObserver
        chatLayout.isFollowingProvider = { [weak self] in self?.stickController.isFollowing ?? true }
        chatLayout.isStreamingProvider = { [weak self] in self?.stickController.isStreamingMode ?? false }
        contentSizeObservation = collectionView.observe(\.contentSize) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.scheduleQuiescentInsetReconcile()
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if collectionView.frame != view.bounds {
            collectionView.frame = view.bounds
            reconcileViewportChangeEnsuringFullLayout(animated: false)
        }
        skeletonOverlay.frame = view.bounds
        rebuildIfReady()
    }


    func update(
        viewModel: ChatCollectionViewModel,
        providerMetadataVersion: UInt,
        streamingPublisher: AnyPublisher<Void, Never>,
        streamingReasoningPublisher: AnyPublisher<ReasoningStreamDelta, Never>,
        streamingTextProvider: @escaping () -> String,
        streamingReasoningSnapshotProvider: @escaping () -> ReasoningStreamSnapshot?,
        onRetry: @escaping (ChatMessage) -> Void,
        onContinue: @escaping (ChatMessage) -> Void,
        onSaveNote: @escaping (ChatMessage) -> Void = { _ in },
        onOpenNoteReferences: @escaping ([NoteSummary]) -> Void = { _ in },
        onSaveSelection: @escaping (ChatMessage, String) -> Void = { _, _ in },
        onAskSelection: @escaping (ChatMessage, QuoteSelectionContent) -> Void = { _, _ in },
        canReplaceCurrentNoteSelection: Bool = false,
        onReplaceSelection: @escaping (ChatMessage, String) -> Void = { _, _ in },
        onSaveCodeBlock: @escaping (ChatMessage, String, String?) -> Void = { _, _, _ in },
        onRegenerate: @escaping (ChatMessage) -> Void,
        onEditMessage: @escaping (ChatMessage) -> Void,
        onSwitchModel: @escaping () -> Void,
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
        self.onSaveSelection = onSaveSelection
        self.onAskSelection = onAskSelection
        self.canReplaceCurrentNoteSelection = canReplaceCurrentNoteSelection
        self.onReplaceSelection = onReplaceSelection
        self.onSaveCodeBlock = onSaveCodeBlock
        self.onRegenerate = onRegenerate
        self.onEditMessage = onEditMessage
        self.onSwitchModel = onSwitchModel
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
        streamingCoordinator.bind(
            publisher: streamingPublisher,
            reasoningPublisher: streamingReasoningPublisher,
            textProvider: streamingTextProvider,
            reasoningSnapshotProvider: streamingReasoningSnapshotProvider
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
            || providerMetadataVersion != lastProviderMetadataVersion {
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
        collectionView.layoutIfNeeded()
        guard let targetOffset = outlineTargetOffset(for: id) else { return }
        bottomSettleGeneration &+= 1
        revealCollectionViewIfAwaiting()
        stickController.userDidGrab()
        recordProgrammaticJump(to: targetOffset, source: "outline")
        collectionView.setContentOffset(CGPoint(x: 0, y: targetOffset), animated: animated)
        stickController.invalidateOffsetBaseline()
        reportFollowingChangeIfNeeded()
        if !animated { reportVisibleTopUserMessageIfNeeded() }

        outlineScrollSeq &+= 1
        let seq = outlineScrollSeq
        RunLoop.main.perform { [weak self] in
            self?.runOutlineCorrectionPass(
                id: id,
                seq: seq,
                remainingPasses: Self.outlineCorrectionFrameBudget,
                lastCorrected: .nan,
                stableFrames: 0
            )
        }
    }

    private static let outlineCorrectionFrameBudget = 30
    private static let outlineCorrectionStableThreshold = 3

    private func runOutlineCorrectionPass(
        id: UUID,
        seq: UInt,
        remainingPasses: Int,
        lastCorrected: CGFloat,
        stableFrames: Int
    ) {
        guard outlineScrollSeq == seq else { return }
        guard !collectionView.isTracking, !collectionView.isDragging, !collectionView.isDecelerating else { return }
        collectionView.layoutIfNeeded()
        guard let corrected = outlineTargetOffset(for: id) else { return }
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
                    seq: seq,
                    remainingPasses: remainingPasses - 1,
                    lastCorrected: corrected,
                    stableFrames: nextStable
                )
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func outlineTargetOffset(for id: UUID) -> CGFloat? {
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
        return min(maxOffset, max(0, attributes.frame.minY - Self.outlineScrollTopPadding))
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
                NSLog("[OPEN-TRACE] initial rebuild deferred rows=%d (heavy conversation, skeleton shown, 0.8s fallback timer armed)", viewModel.rows.count)
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
            maxBubbleWidth: Self.userBubbleMaxWidth,
            onRetry: onRetry,
            onContinue: onContinue,
            onSaveNote: onSaveNote,
            onOpenNoteReferences: onOpenNoteReferences,
            onSaveSelection: onSaveSelection,
            onAskSelection: onAskSelection,
            canReplaceCurrentNoteSelection: canReplaceCurrentNoteSelection,
            onReplaceSelection: onReplaceSelection,
            onSaveCodeBlock: onSaveCodeBlock,
            onRegenerate: onRegenerate,
            onEditMessage: onEditMessage,
            onSwitchModel: onSwitchModel,
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
        }
        let isInitialOrReset = lastConversationID == nil || isConversationSwitch || widthChanged
        lastMeasuredWidth = width

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
            collectionView.reloadData()
            collectionView.layoutIfNeeded()
            NSLog("[OPEN-TRACE] initial reload+layout %.0fms rows=%d",
                  (CACurrentMediaTime() - reloadStart) * 1000, viewModel.rows.count)
            stickController.reset()
            if viewModel.streamingMessageID != nil {
                stickController.setStreamingMode(true)
                startStreamingReconcileTick()
            }
            if handlePendingSearchTargetIfNeeded(viewModel) {
            } else if consumePendingOutlineScroll(conversationID: viewModel.conversationID) {
            } else {
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
        contentDirty = false
    }

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
        }
    }

    private struct PrependViewportAnchor {
        let messageID: UUID
        let snapshot: ChatLayoutPositionSnapshot
    }

    private func applyPrependUpdate(diff: ChatListDiff.Result, commit: @escaping () -> Void) {
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
        if !diff.reconfigures.isEmpty {
            collectionView.reconfigureItems(at: diff.reconfigures.map { IndexPath(item: $0, section: 0) })
        }
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
                worstAttributeMinY: worstAttributeMinY
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
            worstAttributeMinY: worstAttributeMinY
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
        NSLog("[OPEN-TRACE] reveal (settle finished, skeleton hidden)")
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

        height += estimatedMarkdownHeight(
            for: message.text,
            contentWidth: contentWidth,
            metrics: isUser ? .userBubble : .assistantBody
        )
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
                UIKitAssistantImageView.preferredAspectRatio(
                    for: $0,
                    partitionUID: AppSessionStore.activeUID
                )
            }
            height += estimatedImagesHeight(imageWidth: imageWidth, ratios: ratios)
        }

        if !isUser, let citations = message.citations, !citations.isEmpty {
            height += estimatedCitationsHeight(count: citations.count)
        }

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

    nonisolated static func userContentWidth(for width: CGFloat) -> CGFloat {
        max(120, min(userBubbleMaxWidth, width * 0.82))
    }

    nonisolated static func estimatedRecoveryCardHeight(charsPerLine: CGFloat) -> CGFloat {
        let chrome: CGFloat = 20 + 20 + 6 + 12 + 48 + 12 + 25 + 20
        let bodyLines = max(1, (40 / max(charsPerLine, 1)).rounded(.up))
        return chrome + bodyLines * proseLineHeight + 8
    }

    nonisolated static func estimatedImagesHeight(imageWidth: CGFloat, ratios: [CGFloat]) -> CGFloat {
        ratios.reduce(0) { $0 + imageWidth / max($1, 0.1) + 12 }
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

    nonisolated static let reasoningCollapsedHeight: CGFloat = 58

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
