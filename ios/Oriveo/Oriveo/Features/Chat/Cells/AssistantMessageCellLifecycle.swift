import SwiftUI
import UIKit

extension AssistantMessageCell {
    func handleLatexImageDidRender(_ note: Notification) {
        guard let latex = note.userInfo?[LatexImageCache.userInfoLatexKey] as? String,
              !latex.isEmpty else { return }

        let didRerenderFrozen = staticBodyRenderer.rerenderFrozenLabels(containing: latex)
        let isStreaming = streamingController.isSubscribed || pendingFinalStreamingRender != nil

        if isStreaming {
            var didUpgradeTail = false
            traitCollection.performAsCurrent {
                didUpgradeTail = MarkdownAttributedStringRenderer.upgradeBlockMathPlaceholders(
                    in: textView.textStorage,
                    latex: latex
                )
            }
            if didUpgradeTail { textView.invalidateIntrinsicContentSize() }
            if didRerenderFrozen || didUpgradeTail || lastStreamingText.contains(latex) {
                resolvedLatexAwaitingReconcile.insert(latex)
            }
            if didRerenderFrozen || didUpgradeTail { notifyContentDidChange() }
            return
        }

        var didRerenderMainText = false

        if !textView.isHidden,
           currentRenderMode != .plainText,
           currentMessageText.contains(latex) {
            MarkdownAttributedStringRenderer.invalidateCache(for: currentMessageText)
            var rendered = NSAttributedString()
            traitCollection.performAsCurrent {
                rendered = MarkdownAttributedStringRenderer.render(currentMessageText)
            }
            textView.attributedText = rendered
            textView.linkTextAttributes = [
                .foregroundColor: UIColor(OriveoTheme.Palette.primary)
            ]
            textView.invalidateIntrinsicContentSize()
            didRerenderMainText = true
        }

        if didRerenderFrozen || didRerenderMainText {
            notifyContentDidChange()
        }
    }

    func reconcileResolvedLatexInFrozenViews() {
        guard !resolvedLatexAwaitingReconcile.isEmpty else { return }
        var didRerender = false
        for latex in resolvedLatexAwaitingReconcile {
            if staticBodyRenderer.rerenderFrozenLabels(containing: latex) {
                didRerender = true
            }
        }
        if didRerender { notifyContentDidChange() }
    }

    func reconcileResolvedLatexBeforeFinalRender(text: String) {
        guard resolvedLatexAwaitingReconcile.contains(where: { text.contains($0) }) else { return }
        MarkdownAttributedStringRenderer.invalidateCache(for: text)
        resolvedLatexAwaitingReconcile.removeAll()
    }

    func resetStreamingIncrementalState() {
        lastStreamingText = ""
        blockWriter.reset()
        incrementalParser.reset()
        resolvedLatexAwaitingReconcile.removeAll()
        textView.text = nil
        textView.attributedText = nil
        textView.invalidateIntrinsicContentSize()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        streamingController.cancel()
        pacer.reset()
        chunkFader.cancel()
        clearFrozenViews()
        hideStreamingCodeBlock()
        hideStreamingTableCard()
        boundMessageID = nil
        pendingRenderGeneration &+= 1
        textView.isHidden = false
        textView.alpha = 1
        typingIndicator.stopAnimating()
        typingContainer.isHidden = true
        typingContainer.alpha = 1
        statusPillContainer.isHidden = true
        metadataView.isHidden = true
        unhandledToolCallView.resetForReuse()
        tearDownAttachmentViews()
        tearDownCitationsBlock()
        tearDownRecoveryCard()
        reasoningBlock.resetForReuse()
        providerBadge.resetForReuse()
        currentMessageState = nil
        onContentHeightDidChange = nil
        onFinalStreamingRenderCompleted = nil
        onRetry = nil
        onContinue = nil
        resetStreamingIncrementalState()
        streamingHeightFloor = 0
        cancelPendingStreamingHeightFlush(resetTimestamp: true)
        pendingFinalStreamingRender = nil
        bodyStackMinHeightConstraint?.isActive = false
        streamingController.resetReasoning()
        metadataView.resetForReuse()
    }

    func finishPendingFinalStreamingRenderIfNeeded() {
        guard let pending = pendingFinalStreamingRender else { return }
        if chunkFader.displayClock != nil, !chunkFader.pendingChunks.isEmpty {
            chunkFader.onQueueDidDrain = { [weak self] in
                self?.finishPendingFinalStreamingRenderIfNeeded()
            }
            return
        }
        pendingFinalStreamingRender = nil
        pacer.cancel()
        cancelPendingStreamingHeightFlush(resetTimestamp: true)

        guard boundMessageID == pending.messageID,
              let parentViewController else { return }

        hideStreamingCodeBlock()
        hideStreamingTableCard()
        textView.invalidateIntrinsicContentSize()
        configureBody(
            text: pending.text,
            isStreaming: false,
            renderHint: pending.renderHint,
            messageID: pending.messageID,
            parentViewController: parentViewController
        )
        metadataView.markVisualRenderCompleted()
        notifyContentDidChange()
        onFinalStreamingRenderCompleted?()
        OriveoHaptic.tap()
    }

    static func parseStreamingSegmentsForTesting(_ text: String) -> (
        committedCount: Int,
        tail: String,
        streamingTable: [String]?
    ) {
        let parsed = StreamingSegmentParser.parse(text)
        return (parsed.committed.count, parsed.tail, parsed.streamingTable)
    }

    enum SegmentKindForTesting: Equatable {
        case text
        case codeBlock
        case table
    }

    static func parseStreamingSegmentsDetailedForTesting(_ text: String) -> (
        committedKinds: [SegmentKindForTesting],
        committedContents: [String],
        tail: String,
        streamingTable: [String]?
    ) {
        let parsed = StreamingSegmentParser.parse(text)
        let kinds: [SegmentKindForTesting] = parsed.committed.map { seg in
            switch seg.kind {
            case .text: return .text
            case .codeBlock: return .codeBlock
            case .table: return .table
            }
        }
        let contents = parsed.committed.map(\.content)
        return (kinds, contents, parsed.tail, parsed.streamingTable)
    }

    // MARK: - Height

    func notifyContentDidChange() {
        guard boundMessageID != nil else { return }
        invalidateIntrinsicContentSize()
        #if DEBUG
        _testContentDidChangeCount += 1
        _testLastContentDidChangeID = boundMessageID
        #endif
    }

    nonisolated static func shouldDeferStreamingInvalidate(
        isStreamingActive: Bool,
        isScrolling: Bool,
        isNearBottom: Bool
    ) -> Bool {
        return isStreamingActive && isScrolling && !isNearBottom
    }

    nonisolated static func shouldThrottleStreamingInvalidate(
        isStreamingActive: Bool,
        now: CFTimeInterval,
        lastInvalidate: CFTimeInterval
    ) -> Bool {
        guard isStreamingActive else { return false }
        guard lastInvalidate > 0 else { return false }
        return (now - lastInvalidate) < AssistantMessageCell.minStreamingInvalidateInterval
    }

    func requestStreamingSelfSizeInvalidate() {
        if AssistantMessageCell.shouldDeferStreamingInvalidate(
            isStreamingActive: isStreamingActive,
            isScrolling: chunkFader.isScrollingProvider(),
            isNearBottom: isNearBottomProvider()
        ) {
            pendingStreamingHeightFlush = true
            return
        }
        let now = CACurrentMediaTime()
        if AssistantMessageCell.shouldThrottleStreamingInvalidate(
            isStreamingActive: isStreamingActive,
            now: now,
            lastInvalidate: lastStreamingInvalidateTimestamp
        ) {
            pendingStreamingHeightFlush = true
            scheduleTrailingStreamingHeightFlush(after: max(
                0,
                AssistantMessageCell.minStreamingInvalidateInterval
                    - (now - lastStreamingInvalidateTimestamp)
            ))
            return
        }
        cancelPendingStreamingHeightFlush(resetTimestamp: false)
        lastStreamingInvalidateTimestamp = now
        notifyContentDidChange()
    }

    private func scheduleTrailingStreamingHeightFlush(after delay: CFTimeInterval) {
        guard pendingStreamingHeightWorkItem == nil,
              let messageID = boundMessageID else { return }
        let expectedGeneration = streamingHeightFlushGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.streamingHeightFlushGeneration == expectedGeneration,
                  self.boundMessageID == messageID else { return }
            self.pendingStreamingHeightWorkItem = nil
            guard self.pendingStreamingHeightFlush else { return }
            guard !AssistantMessageCell.shouldDeferStreamingInvalidate(
                isStreamingActive: self.isStreamingActive,
                isScrolling: self.chunkFader.isScrollingProvider(),
                isNearBottom: self.isNearBottomProvider()
            ) else { return }
            self.pendingStreamingHeightFlush = false
            self.lastStreamingInvalidateTimestamp = CACurrentMediaTime()
            self.notifyContentDidChange()
        }
        pendingStreamingHeightWorkItem = work
        #if DEBUG
        _testScheduledStreamingHeightFlushCount += 1
        #endif
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func cancelPendingStreamingHeightFlush(resetTimestamp: Bool) {
        streamingHeightFlushGeneration &+= 1
        pendingStreamingHeightWorkItem?.cancel()
        pendingStreamingHeightWorkItem = nil
        pendingStreamingHeightFlush = false
        if resetTimestamp {
            lastStreamingInvalidateTimestamp = 0
        }
    }

    func flushStreamingHeightIfPending() {
        guard pendingStreamingHeightFlush, boundMessageID != nil else { return }
        cancelPendingStreamingHeightFlush(resetTimestamp: false)
        lastStreamingInvalidateTimestamp = CACurrentMediaTime()
        notifyContentDidChange()
    }

    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        let preferred = layoutAttributes.copy() as! UICollectionViewLayoutAttributes
        let targetWidth = layoutAttributes.size.width > 0
            ? layoutAttributes.size.width
            : max(contentView.bounds.width, bounds.width, 1)
        let fittedSize = contentView.systemLayoutSizeFitting(
            CGSize(width: targetWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        let naturalHeight = max(ceil(fittedSize.height), 1)
        preferred.size.width = targetWidth
        preferred.size.height = naturalHeight
        streamingHeightFloor = AssistantMessageCell.nextStreamingHeightFloor(
            natural: naturalHeight,
            current: streamingHeightFloor,
            streaming: isStreamingActive
        )
        if isStreamingActive {
            preferred.size.height = streamingHeightFloor
        }
        ChatRenderDiagnostics.recordCellPrefer(
            id: String(boundMessageID?.uuidString.prefix(4) ?? "_"),
            minY: layoutAttributes.frame.minY,
            oldH: layoutAttributes.size.height,
            newH: preferred.size.height,
            isStream: isStreamingActive
        )
        return preferred
    }
}
