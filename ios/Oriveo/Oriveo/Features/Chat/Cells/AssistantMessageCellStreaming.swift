import Combine
import UIKit

extension AssistantMessageCell {
    func setTypingIndicatorVisible(_ visible: Bool) {
        if UIAccessibility.isReduceMotionEnabled {
            typingContainer.isHidden = !visible
            typingContainer.alpha = 1
            textView.isHidden = visible
            textView.alpha = 1
            if visible {
                typingIndicator.startAnimating()
            } else {
                typingIndicator.stopAnimating()
            }
            return
        }
        let duration: TimeInterval = 0.10
        if visible {
            textView.isHidden = true
            textView.alpha = 1
            typingContainer.isHidden = false
            typingContainer.alpha = 0
            typingIndicator.startAnimating()
            UIView.animate(
                withDuration: duration,
                delay: 0,
                options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]
            ) {
                self.typingContainer.alpha = 1
            }
        } else {
            textView.isHidden = false
            textView.alpha = 1
            UIView.animate(
                withDuration: duration,
                delay: 0,
                options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]
            ) {
                self.typingContainer.alpha = 0
            } completion: { _ in
                self.typingContainer.isHidden = true
                self.typingContainer.alpha = 1
                self.typingIndicator.stopAnimating()
            }
        }
    }

    func updateStreamingText(_ text: String) {
        guard boundMessageID != nil else { return }

        if text.isEmpty {
            if !lastStreamingText.isEmpty { return }
            setTypingIndicatorVisible(streamingController.isReasoningEmpty())
            lastStreamingText = ""
        } else {
            let wasShowingTyping = !typingContainer.isHidden && typingContainer.alpha > 0
            if wasShowingTyping {
                textView.isHidden = false
                textView.alpha = 1
            }

            let parsed = incrementalParser.parse(text)

            let tailText: String
            let unclosedCode: (language: String?, code: String)?
            if let fence = parsed.unclosedFence {
                tailText = fence.textBefore
                unclosedCode = (fence.language, fence.code)
            } else {
                tailText = parsed.tail
                unclosedCode = nil
            }

            let willCommitNewSegments = parsed.committed.count > staticBodyRenderer.committedSegmentCount
            var harvestedText: NSAttributedString?
            if willCommitNewSegments,
               bodyStack.arrangedSubviews.contains(textView) {
                if textView.textStorage.length > 0 {
                    harvestedText = blockWriter.harvestForFreeze()
                }
                bodyStack.removeArrangedSubview(textView)
                lastStreamingText = ""
            }

            if willCommitNewSegments {
                let newSegments = Array(parsed.committed[staticBodyRenderer.committedSegmentCount...])

                if let first = newSegments.first,
                   case .codeBlock(let lang) = first.kind,
                   !streamingCodeRenderer.isHidden,
                   !streamingCodeRenderer.lastRenderedCode.isEmpty,
                   first.content.hasPrefix(streamingCodeRenderer.lastRenderedCode) {
                    upgradeStreamingCodeContainerToFrozenView(language: lang, content: first.content)
                    let remainder = Array(newSegments.dropFirst())
                    if !remainder.isEmpty {
                        appendFrozenViews(newSegments: remainder, harvestedFirstText: harvestedText)
                    }
                } else {
                    appendFrozenViews(newSegments: newSegments, harvestedFirstText: harvestedText)
                }
                staticBodyRenderer.markCommittedSegmentCount(parsed.committed.count)
            }

            textView.isHidden = false
            if tailText.isEmpty {
                if textView.textStorage.length > 0 {
                    textView.textStorage.setAttributedString(NSAttributedString())
                    blockWriter.reset()
                }
                lastStreamingText = ""
                if bodyStack.arrangedSubviews.contains(textView),
                   staticBodyRenderer.committedSegmentCount > 0 {
                    bodyStack.removeArrangedSubview(textView)
                }
            } else {
                if !bodyStack.arrangedSubviews.contains(textView) {
                    let anchorIdx = bodyStack.arrangedSubviews.firstIndex(of: streamingCodeRenderer.view) ?? bodyStack.arrangedSubviews.count
                    bodyStack.insertArrangedSubview(textView, at: anchorIdx)
                }

                if tailText != lastStreamingText {
                    blockWriter.applyTail(tailText)
                }
                lastStreamingText = tailText
            }

            if let (lang, code) = unclosedCode {
                updateStreamingCodeBlock(language: lang, code: code)
            } else {
                hideStreamingCodeBlock()
            }

            if let tableLines = parsed.streamingTable {
                updateStreamingTableCard(lines: tableLines)
            } else {
                hideStreamingTableCard()
            }

            if wasShowingTyping {
                setTypingIndicatorVisible(false)
            }
            requestStreamingSelfSizeInvalidate()
        }
    }

    func appendFrozenViews(
        newSegments: [StreamingSegmentParser.Segment],
        harvestedFirstText: NSAttributedString? = nil
    ) {
        var harvestedCode: (content: String, attributed: NSAttributedString)?
        if !streamingCodeRenderer.isHidden, !streamingCodeRenderer.lastRenderedCode.isEmpty {
            let shown = streamingCodeRenderer.lastRenderedCode
            let matching = newSegments.first { segment in
                if case .codeBlock = segment.kind { return segment.content.hasPrefix(shown) }
                return false
            }
            if let matching,
               let attributed = streamingCodeRenderer.harvestAttributedCodeForHandoff(fullContent: matching.content) {
                harvestedCode = (matching.content, attributed)
            }
        }
        staticBodyRenderer.appendFrozenViews(
            newSegments: newSegments,
            harvestedFirstText: harvestedFirstText,
            harvestedCode: harvestedCode
        )
        reconcileResolvedLatexInFrozenViews()
    }

    /// "text before\n```swift\ncode here" → ("text before", ("swift", "code here"))
    /// "just text" → ("just text", nil)

    func clearFrozenViews() {
        staticBodyRenderer.clear()
    }


    func startStreamingSubscription(
        publisher: AnyPublisher<Void, Never>,
        reasoningPublisher: AnyPublisher<ReasoningStreamDelta, Never> =
            Empty<ReasoningStreamDelta, Never>().eraseToAnyPublisher(),
        textProvider: @escaping () -> String,
        reasoningSnapshotProvider: @escaping () -> ReasoningStreamSnapshot? = { nil }
    ) {
        streamingController.start(
            publisher: publisher,
            reasoningPublisher: reasoningPublisher,
            textProvider: textProvider,
            reasoningSnapshotProvider: reasoningSnapshotProvider,
            isBound: { [weak self] in self?.boundMessageID != nil },
            enqueueText: { [weak self] text in
                self?.pacer.enqueue(text)
            },
            applyInitialText: { [weak self] initialText in
                guard let self else { return }
                self.pacer.cancel()
                self.chunkFader.cancel()
                self.pendingFinalStreamingRender = nil
                self.bodyStackMinHeightConstraint?.isActive = true
                self.pacer.snapToInitial(initialText)
                self.updateStreamingText(initialText)
            },
            applyInitialReasoning: { [weak self] snapshot in
                self?.reasoningBlock.applyStreamingSnapshot(snapshot)
            },
            hideTypingIfNeeded: { [weak self] in
                guard let self, self.pacer.visibleText.isEmpty else { return }
                self.setTypingIndicatorVisible(false)
            },
            applyReasoning: { [weak self] delta in
                self?.reasoningBlock.appendStreamingDelta(delta)
            }
        )
    }


    func shouldDeferFinalStreamingRender(
        previousMessageID: UUID?,
        nextMessageID: UUID,
        isGenerating: Bool,
        targetText: String,
        hadStreamingPacer: Bool
    ) -> Bool {
        guard hadStreamingPacer else { return false }
        guard !isGenerating else { return false }
        guard previousMessageID == nextMessageID else { return false }
        guard !UIAccessibility.isReduceMotionEnabled else { return false }
        guard !targetText.isEmpty else { return false }
        guard targetText.hasPrefix(pacer.visibleText) else { return false }
        return pacer.visibleText != targetText
    }

    func prepareFinalStreamingRender(text: String, renderHint: MarkdownRenderHint?, messageID: UUID) {
        pendingFinalStreamingRender = PendingFinalStreamingRender(
            messageID: messageID,
            text: text,
            renderHint: renderHint
        )
        pacer.enqueue(text)
    }



}

// MARK: - StreamingPacerDelegate

extension AssistantMessageCell: StreamingPacerDelegate {
    var isPacerEnabled: Bool { boundMessageID != nil }

    var pacerHasPendingFinalRender: Bool { pendingFinalStreamingRender != nil }

    func pacer(_ pacer: StreamingPacer, didAdvanceTo visibleText: String) {
        updateStreamingText(visibleText)
    }

    func pacerDidReachTarget(_ pacer: StreamingPacer) {
        finishPendingFinalStreamingRenderIfNeeded()
    }
}
