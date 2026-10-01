import Combine
import UIKit

extension AssistantMessageCell {
    func setTypingIndicatorVisible(_ visible: Bool) {
        // Whether the typing indicator is on screen decides who carries the waiting label, the
        // indicator or the status line, so re-evaluate whenever its visibility changes.
        defer { refreshStreamActivityPresentation() }
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
        reasoningSnapshotProvider: @escaping () -> ReasoningStreamSnapshot? = { nil },
        activityPublisher: AnyPublisher<StreamActivityState, Never> =
            Empty<StreamActivityState, Never>().eraseToAnyPublisher(),
        activityProvider: @escaping () -> StreamActivityState? = { nil }
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
                // Setting up the subscription starts the pause clock. From here on only changes
                // to visible content push it back.
                self.streamSessionEnded = false
                self.streamQuietTimer.noteVisibleChange()
                self.refreshStreamActivityPresentation()
            },
            applyInitialReasoning: { [weak self] snapshot in
                self?.reasoningBlock.applyStreamingSnapshot(snapshot)
            },
            hideTypingIfNeeded: { [weak self] in
                guard let self, self.pacer.visibleText.isEmpty else { return }
                self.setTypingIndicatorVisible(false)
            },
            applyReasoning: { [weak self] delta in
                guard let self else { return }
                self.reasoningBlock.appendStreamingDelta(delta)
                // Only non-empty reasoning text is a visible change. An empty heartbeat changes
                // nothing on screen and does not push the pause clock back.
                if !delta.delta.isEmpty, self.isAwaitingStreamOutput {
                    self.streamQuietTimer.noteVisibleChange()
                }
            },
            activityPublisher: activityPublisher,
            activityProvider: activityProvider,
            applyActivity: { [weak self] state in
                self?.applyStreamActivityState(state)
            }
        )
    }

    // MARK: - Stream activity status line

    /// Whether body text is already on screen. This reads what is actually displayed (frozen
    /// segments, the tail, the streaming code card, the streaming table card), the same way the
    /// empty-text guard in `configureBody` does: when the text ends in a code block or a table the
    /// tail happens to be empty, so the tail alone is not enough.
    var hasStreamedBodyOnScreen: Bool {
        !lastStreamingText.isEmpty
            || staticBodyRenderer.committedSegmentCount > 0
            || textView.textStorage.length > 0
            || !streamingCodeRenderer.isHidden
            || streamingTableRenderer?.card != nil
    }

    var isTypingIndicatorOnScreen: Bool {
        !typingContainer.isHidden && typingContainer.alpha > 0
    }

    /// The message is still waiting for output: it is bound, its state is generating, and the
    /// session has not been removed yet.
    var isAwaitingStreamOutput: Bool {
        boundMessageID != nil && currentMessageState == .generating && !streamSessionEnded
    }

    /// Entry point of the activity channel: the snapshot read at binding, then every set, clear
    /// and session removal. Only a state for the bound message counts; `nil` (the conversation has
    /// no session right now) and a state for another message both mean "no activity".
    func applyStreamActivityState(_ state: StreamActivityState?) {
        let own = state?.messageID == boundMessageID ? state : nil
        if own?.isStreaming == false {
            // The stream is over: stop the timer and hide all waiting feedback without waiting
            // for the message state to be reconfigured.
            streamSessionEnded = true
            streamQuietTimer.cancel()
        }
        streamActivity = own?.activity
        refreshStreamActivityPresentation()
    }

    /// Re-evaluates the waiting feedback and applies it to the views. The decision itself is the
    /// pure function `StreamActivityPresentation.resolve`. Call this whenever any input changes;
    /// the views are left alone when the result is the same.
    func refreshStreamActivityPresentation() {
        let presentation = StreamActivityPresentation.resolve(
            isGenerating: isAwaitingStreamOutput,
            hasBodyText: hasStreamedBodyOnScreen,
            typingIndicatorVisible: isTypingIndicatorOnScreen,
            activity: streamActivity,
            quiet: streamQuietTimer.isQuiet
        )
        guard presentation != streamActivityPresentation else { return }
        streamActivityPresentation = presentation
        switch presentation {
        case .hidden:
            typingIndicator.setCaption(nil)
            setStreamActivityLineText(nil)
        case let .typingCaption(activity):
            typingIndicator.setCaption(StreamActivityCaption.activity(activity).localizedText)
            setStreamActivityLineText(nil)
        case let .statusLine(caption):
            typingIndicator.setCaption(nil)
            setStreamActivityLineText(caption.localizedText)
        }
    }

    private func setStreamActivityLineText(_ text: String?) {
        let wasHidden = streamActivityLineHost.isHidden
        if let text {
            streamActivityLine.present(text: text)
            guard wasHidden else { return }
        } else {
            streamActivityLine.dismiss()
            guard !wasHidden else { return }
        }
        setStreamActivityLineHostHidden(text == nil)
        // Showing or hiding the status line changes the natural height of the cell, so it goes
        // through the single gate for self-sizing while streaming (throttled to 15 Hz and yielding
        // to scrolling); outside streaming the gate applies the height directly. When the line
        // hides, the streaming height floor absorbs the drop, so the content height does not
        // jitter downwards.
        requestStreamingSelfSizeInvalidate()
    }

    private func setStreamActivityLineHostHidden(_ hidden: Bool) {
        // No animation: inside the batch animation context of a reconfigure, toggling `isHidden`
        // on an arranged subview is implicitly animated by UIStackView. The only entrance
        // animation allowed is the status line's own alpha fade.
        UIView.performWithoutAnimation {
            // bodyStack has a 4 pt bottom margin of its own; subtracting it leaves exactly 8 pt
            // between the body text and the status line. Hiding restores the default spacing, so
            // the layout between bodyStack and the blocks after it (tool-call card, citations,
            // metadata) is unchanged.
            contentStack.setCustomSpacing(
                hidden
                    ? UIStackView.spacingUseDefault
                    : Self.streamActivityLineTopSpacing - bodyStack.directionalLayoutMargins.bottom,
                after: bodyStack
            )
            streamActivityLineHost.isHidden = hidden
        }
    }

    /// Cell reuse: stops the timer, clears the activity, hides the status line and restores the
    /// typing indicator label. No height signal is sent, since no message is bound at this point.
    func resetStreamActivityForReuse() {
        streamQuietTimer.cancel()
        streamActivity = nil
        streamSessionEnded = false
        streamActivityPresentation = .hidden
        streamActivityLine.dismiss()
        setStreamActivityLineHostHidden(true)
        typingIndicator.setCaption(nil)
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
        // The pause is measured from the last change to the visible body text: every step until
        // the pacer has caught up pushes the clock back, so the status line never shares the
        // screen with text that is still appearing. The closing drain after generation has ended
        // does not count, since nothing is waiting by then.
        if isAwaitingStreamOutput {
            streamQuietTimer.noteVisibleChange()
        }
        refreshStreamActivityPresentation()
    }

    func pacerDidReachTarget(_ pacer: StreamingPacer) {
        finishPendingFinalStreamingRenderIfNeeded()
    }
}
