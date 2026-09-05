import Combine
import Testing
import UIKit
@testable import Oriveo

@Suite("Streaming Incremental Append")
struct StreamingIncrementalAppendTests {

    @Test("Assistant Cell Incremental Append Produces Correct Text")
    @MainActor
    func assistantCellIncrementalAppendProducesCorrectText() {
        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        let model = makeRenderModel(text: "Hello", isGenerating: true)
        let vc = UIViewController()
        cell.configure(
            model: model,
            parentViewController: vc,
            onContentHeightDidChange: nil,
            onRetry: nil,
            onContinue: nil
        )

        cell.updateStreamingText("Hello world")
        cell.updateStreamingText("Hello world, how are you?")

        let textView = extractTextView(from: cell)
        #expect(textView?.text == "Hello world, how are you?")
    }

    @Test("Assistant Cell Empty Text Shows Typing Indicator")
    @MainActor
    func assistantCellEmptyTextShowsTypingIndicator() {
        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        let model = makeRenderModel(text: "", isGenerating: true)
        let vc = UIViewController()
        cell.configure(
            model: model,
            parentViewController: vc,
            onContentHeightDidChange: nil,
            onRetry: nil,
            onContinue: nil
        )

        cell.updateStreamingText("")

        let textView = extractTextView(from: cell)
        #expect(textView?.isHidden == true)
    }

    @Test("First Token Does Not Apply Whole Text View Fade")
    @MainActor
    func firstTokenDoesNotApplyWholeTextViewFade() {
        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        let model = makeRenderModel(text: "", isGenerating: true)
        let vc = UIViewController()
        cell.configure(
            model: model,
            parentViewController: vc,
            onContentHeightDidChange: nil,
            onRetry: nil,
            onContinue: nil
        )

        cell.updateStreamingText("")
        cell.updateStreamingText("H")

        let textView = extractTextView(from: cell)
        #expect(textView?.isHidden == false)
        #expect(textView?.alpha == 1)
    }

    @Test("Text View Not Compressed When Cell Frame Lags Behind Natural Height")
    @MainActor
    func textViewNotCompressedWhenCellFrameLagsBehindNaturalHeight() {
        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let model = makeRenderModel(text: "The first paragraph of the body.", isGenerating: true)
        let vc = UIViewController()
        cell.configure(
            model: model,
            parentViewController: vc,
            onContentHeightDidChange: nil,
            onRetry: nil,
            onContinue: nil
        )
        cell.updateStreamingText("The first paragraph of the body.\n```swift\nlet a = 1\nlet b = 2\nlet c = 3\n")
        cell.layoutIfNeeded()

        guard let textView = extractTextView(from: cell) else {
            Issue.record("could not find the body textView")
            return
        }
        let intrinsicHeight = textView.intrinsicContentSize.height
        #expect(intrinsicHeight > 0)

        cell.frame = CGRect(x: 0, y: 0, width: 390, height: 60)
        cell.setNeedsLayout()
        cell.layoutIfNeeded()

        #expect(textView.bounds.height >= intrinsicHeight - 1.0)
    }

    @Test("Assistant Cell Empty Generating Metadata Aligns Left")
    @MainActor
    func assistantCellEmptyGeneratingMetadataAlignsLeft() {
        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        let model = makeRenderModelWithMetadata(text: "", state: .generating)
        let vc = UIViewController()
        cell.configure(
            model: model,
            parentViewController: vc,
            onContentHeightDidChange: nil,
            onRetry: nil,
            onContinue: nil
        )

        cell.updateStreamingText("")

        let metadataStack = extractMetadataStack(from: cell)
        #expect(metadataStack?.directionalLayoutMargins.leading == AssistantMessageCell.assistantBodyLeadingInset)
    }

    @Test("Assistant Cell Delivered Metadata Aligns Left")
    @MainActor
    func assistantCellDeliveredMetadataAlignsLeft() {
        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        let model = makeRenderModelWithMetadata(text: "Hello", state: .delivered)
        let vc = UIViewController()
        cell.configure(
            model: model,
            parentViewController: vc,
            onContentHeightDidChange: nil,
            onRetry: nil,
            onContinue: nil
        )

        let metadataStack = extractMetadataStack(from: cell)
        #expect(metadataStack?.directionalLayoutMargins.leading == AssistantMessageCell.assistantBodyLeadingInset)
    }

    @Test("Assistant Cell Non Prefix Change Does Full Replace")
    @MainActor
    func assistantCellNonPrefixChangeDoesFullReplace() {
        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        let model = makeRenderModel(text: "abc", isGenerating: true)
        let vc = UIViewController()
        cell.configure(
            model: model,
            parentViewController: vc,
            onContentHeightDidChange: nil,
            onRetry: nil,
            onContinue: nil
        )

        cell.updateStreamingText("abc")
        cell.updateStreamingText("abX")

        let textView = extractTextView(from: cell)
        #expect(textView?.text == "abX")
    }

    @Test("Assistant Cell Long Text Incremental Append Integrity")
    @MainActor
    func assistantCellLongTextIncrementalAppendIntegrity() {
        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        let model = makeRenderModel(text: "The quick brown fox ", isGenerating: true)
        let vc = UIViewController()
        cell.configure(
            model: model,
            parentViewController: vc,
            onContentHeightDidChange: nil,
            onRetry: nil,
            onContinue: nil
        )

        var accumulated = "The quick brown fox "
        cell.updateStreamingText(accumulated)

        let tokens = ["jumps ", "over ", "the ", "lazy ", "dog. ",
                       "Pack ", "my ", "box ", "with ", "five ",
                       "dozen ", "liquor ", "jugs."]
        for token in tokens {
            accumulated += token
            cell.updateStreamingText(accumulated)
        }

        let textView = extractTextView(from: cell)
        #expect(textView?.text == accumulated)
    }

    @Test("Assistant Cell Reuse Clears Streaming State")
    @MainActor
    func assistantCellReuseClearsStreamingState() {
        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        let model = makeRenderModel(text: "Hello", isGenerating: true)
        let vc = UIViewController()
        cell.configure(
            model: model,
            parentViewController: vc,
            onContentHeightDidChange: nil,
            onRetry: nil,
            onContinue: nil
        )
        cell.updateStreamingText("Hello world")

        cell.prepareForReuse()

        let model2 = makeRenderModel(text: "New", isGenerating: true)
        cell.configure(
            model: model2,
            parentViewController: vc,
            onContentHeightDidChange: nil,
            onRetry: nil,
            onContinue: nil
        )
        cell.updateStreamingText("New message")

        let textView = extractTextView(from: cell)
        #expect(textView?.text == "New message")
    }

    @Test("Assistant Cell Configure Tears Down Existing Recovery Card")
    @MainActor
    func assistantCellConfigureTearsDownExistingRecoveryCard() {
        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        let vc = UIViewController()
        let interruptedModel = makeRenderModel(text: "partial", isGenerating: false)

        cell.configure(
            model: interruptedModel,
            parentViewController: vc,
            onContentHeightDidChange: nil,
            onRetry: nil,
            onContinue: nil
        )
        cell.embedRecoveryCard(
            .init(
                title: "Interrupted",
                message: "partial",
                primaryTitle: "Continue",
                secondaryTitle: "Regenerate",
                tertiaryTitle: nil,
                tone: .warning,
                technicalDetail: nil,
                actionsEnabled: true,
                primaryAction: {},
                secondaryAction: {},
                tertiaryAction: nil,
                onDismiss: {}
            )
        )

        #expect(extractRecoveryCard(from: cell) != nil)

        let generatingModel = makeRenderModel(text: "partial", isGenerating: true)
        cell.configure(
            model: generatingModel,
            parentViewController: vc,
            onContentHeightDidChange: nil,
            onRetry: nil,
            onContinue: nil
        )

        #expect(extractRecoveryCard(from: cell) == nil)
    }

    @Test("Assistant Cell Configure Renders Existing Streaming Code Block")
    @MainActor
    func assistantCellConfigureRendersExistingStreamingCodeBlock() {
        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 240))
        let vc = UIViewController()
        let model = makeRenderModel(
            text: """
            ```go
            func bubbleSort(arr []int) []int {
            """,
            isGenerating: true
        )

        cell.configure(
            model: model,
            parentViewController: vc,
            onContentHeightDidChange: nil,
            onRetry: nil,
            onContinue: nil
        )

        let streamingCodeContainer = extractStreamingCodeContainer(from: cell)
        let streamingCodeTextView = extractStreamingCodeTextView(from: cell)
        let textView = extractTextView(from: cell)

        #expect(streamingCodeContainer?.isHidden == false)
        #expect(streamingCodeTextView?.text == "func bubbleSort(arr []int) []int {")
        #expect(textView?.isHidden == false)
        #expect(textView?.text.isEmpty == true)
    }

    @Test("Assistant Cell Interrupted Shows Continue Button")
    @MainActor
    func assistantCellInterruptedShowsContinueButton() {
        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        let vc = UIViewController()
        let model = makeRenderModelWithMetadata(text: "Partial reply", state: .interrupted)

        cell.configure(
            model: model,
            parentViewController: vc,
            onContentHeightDidChange: nil,
            onRetry: nil,
            onContinue: { /* no-op */ }
        )

        #expect(extractContinueButton(from: cell)?.isHidden == false)
        #expect(extractRecoveryCard(from: cell) == nil)
    }

    @Test("Assistant Cell Interrupted Without Callback Hides Continue Button")
    @MainActor
    func assistantCellInterruptedWithoutCallbackHidesContinueButton() {
        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        let vc = UIViewController()
        let model = makeRenderModelWithMetadata(text: "Partial reply", state: .interrupted)

        cell.configure(
            model: model,
            parentViewController: vc,
            onContentHeightDidChange: nil,
            onRetry: nil,
            onContinue: nil
        )

        #expect(extractContinueButton(from: cell)?.isHidden == true)
    }

    @Test("Assistant Cell Delivered Hides Continue Button")
    @MainActor
    func assistantCellDeliveredHidesContinueButton() {
        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        let vc = UIViewController()
        let model = makeRenderModelWithMetadata(text: "Final reply", state: .delivered)

        cell.configure(
            model: model,
            parentViewController: vc,
            onContentHeightDidChange: nil,
            onRetry: nil,
            onContinue: { /* no-op */ }
        )

        #expect(extractContinueButton(from: cell)?.isHidden == true)
    }

    @Test("Assistant Cell Meta Copy Button Is Icon Only")
    @MainActor
    func assistantCellMetaCopyButtonIsIconOnly() {
        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        let vc = UIViewController()
        let model = makeRenderModelWithMetadata(text: "Final reply", state: .delivered)

        cell.configure(
            model: model,
            parentViewController: vc,
            onContentHeightDidChange: nil,
            onRetry: nil,
            onContinue: nil
        )

        let button = extractMetaCopyButton(from: cell)
        #expect(button?.isHidden == false)
        #expect(button?.configuration?.attributedTitle == nil)
        #expect(button?.configuration?.title == nil)
    }

    @Test("Assistant Cell Defers Final Static Render Until Pacer Catches Up")
    @MainActor
    func assistantCellDefersFinalStaticRenderUntilPacerCatchesUp() async throws {
        let messageID = UUID()
        let visible = "First line arrives.\nSec"
        let target = [
            "First line arrives.",
            "Second line arrives.",
            "Third line arrives.",
            "Fourth line arrives."
        ].joined(separator: "\n")
        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 400))
        let vc = UIViewController()
        let publisher = PassthroughSubject<Void, Never>()
        var streamingText = visible

        cell.configure(
            model: makeRenderModel(id: messageID, text: visible, isGenerating: true),
            parentViewController: vc,
            onContentHeightDidChange: nil,
            onRetry: nil,
            onContinue: nil
        )
        cell.startStreamingSubscription(
            publisher: publisher.eraseToAnyPublisher(),
            textProvider: { streamingText }
        )

        streamingText = target
        publisher.send()
        try await Task.sleep(nanoseconds: 90_000_000)

        cell.configure(
            model: makeRenderModel(id: messageID, text: target, isGenerating: false),
            parentViewController: vc,
            onContentHeightDidChange: nil,
            onRetry: nil,
            onContinue: nil
        )

        let textDuringFinalTransition = extractTextView(from: cell)?.text ?? ""
        #expect(textDuringFinalTransition.count < target.count)

        var converged = ""
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            converged = extractTextView(from: cell)?.text ?? ""
            if converged.count >= target.count { break }
        }
        #expect(converged.count >= target.count)
    }

    @Test("Final Static Render Completion Callback Fires After Pacer Catches Up")
    @MainActor
    func finalStaticRenderCompletionCallbackFiresAfterPacerCatchesUp() async throws {
        let messageID = UUID()
        let visible = "First line arrives.\nSec"
        let target = [
            "First line arrives.",
            "Second line arrives.",
            "Third line arrives."
        ].joined(separator: "\n")
        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 400))
        let vc = UIViewController()
        let publisher = PassthroughSubject<Void, Never>()
        var streamingText = visible
        var completionCount = 0

        cell.configure(
            model: makeRenderModel(id: messageID, text: visible, isGenerating: true),
            parentViewController: vc,
            onContentHeightDidChange: nil,
            onRetry: nil,
            onContinue: nil
        )
        cell.startStreamingSubscription(
            publisher: publisher.eraseToAnyPublisher(),
            textProvider: { streamingText }
        )

        streamingText = target
        publisher.send()
        try await Task.sleep(nanoseconds: 90_000_000)

        cell.onFinalStreamingRenderCompleted = {
            completionCount += 1
        }
        cell.configure(
            model: makeRenderModel(id: messageID, text: target, isGenerating: false),
            parentViewController: vc,
            onContentHeightDidChange: nil,
            onRetry: nil,
            onContinue: nil
        )

        #expect(completionCount == 0)
        #expect(cell.hasPendingFinalStreamingRenderForCurrentMessage)

        await waitUntil(timeoutNanoseconds: 5_000_000_000) {
            completionCount == 1
        }
        #expect(completionCount == 1)
        #expect(!cell.hasPendingFinalStreamingRenderForCurrentMessage)
        #expect(extractTextView(from: cell)?.text == target)
    }

    @Test("Repeated Streaming Attach Keeps Pacer Scheduled")
    @MainActor
    func repeatedStreamingAttachKeepsPacerScheduled() async throws {
        let messageID = UUID()
        let target = "Hi! How can I help you today? 😊 Here is a second sentence so the streaming display still has something left to play."
        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        let vc = UIViewController()
        let publisher = PassthroughSubject<Void, Never>()
        var streamingText = ""

        cell.configure(
            model: makeRenderModel(id: messageID, text: "", isGenerating: true),
            parentViewController: vc,
            onContentHeightDidChange: nil,
            onRetry: nil,
            onContinue: nil
        )
        cell.startStreamingSubscription(
            publisher: publisher.eraseToAnyPublisher(),
            textProvider: { streamingText }
        )

        streamingText = target
        publisher.send()
        #expect(cell.pacer.visibleText != target)
        #expect(cell.pacer.isScheduled)

        cell.startStreamingSubscription(
            publisher: publisher.eraseToAnyPublisher(),
            textProvider: { streamingText }
        )
        #expect(cell.pacer.isScheduled)

        cell.configure(
            model: makeRenderModel(id: messageID, text: target, isGenerating: false),
            parentViewController: vc,
            onContentHeightDidChange: nil,
            onRetry: nil,
            onContinue: nil
        )
        await waitUntil(timeoutNanoseconds: 5_000_000_000) {
            !cell.hasPendingFinalStreamingRenderForCurrentMessage
        }
        #expect(extractTextView(from: cell)?.text == target)
    }

    @Test("Final Render Restarts Cancelled Pacer For Unchanged Target")
    @MainActor
    func finalRenderRestartsCancelledPacerForUnchangedTarget() async throws {
        let messageID = UUID()
        let target = "Hi! How can I help you today? 😊 Here is a second sentence so the streaming display still has something left to play."
        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        let vc = UIViewController()
        let publisher = PassthroughSubject<Void, Never>()
        var streamingText = ""

        cell.configure(
            model: makeRenderModel(id: messageID, text: "", isGenerating: true),
            parentViewController: vc,
            onContentHeightDidChange: nil,
            onRetry: nil,
            onContinue: nil
        )
        cell.startStreamingSubscription(
            publisher: publisher.eraseToAnyPublisher(),
            textProvider: { streamingText }
        )

        streamingText = target
        publisher.send()
        #expect(cell.pacer.visibleText != target)
        cell.pacer.cancel()
        #expect(!cell.pacer.isScheduled)

        cell.configure(
            model: makeRenderModel(id: messageID, text: target, isGenerating: false),
            parentViewController: vc,
            onContentHeightDidChange: nil,
            onRetry: nil,
            onContinue: nil
        )
        #expect(cell.pacer.isScheduled)

        await waitUntil(timeoutNanoseconds: 5_000_000_000) {
            !cell.hasPendingFinalStreamingRenderForCurrentMessage
        }
        #expect(extractTextView(from: cell)?.text == target)
    }

    // MARK: - Helpers

    @MainActor
    private func extractTextView(from cell: AssistantMessageCell) -> UITextView? {
        let mirror = Mirror(reflecting: cell)
        return mirror.children.first(where: { $0.label == "textView" })?.value as? UITextView
    }

    @MainActor
    private func waitUntil(
        timeoutNanoseconds: UInt64,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @MainActor
    private func extractRecoveryCard(from cell: AssistantMessageCell) -> UIView? {
        cell.recoveryCard
    }

    @MainActor
    private func extractContinueButton(from cell: AssistantMessageCell) -> UIButton? {
        let mirror = Mirror(reflecting: cell.metadataView)
        return mirror.children.first(where: { $0.label == "continueButton" })?.value as? UIButton
    }

    @MainActor
    private func extractMetaCopyButton(from cell: AssistantMessageCell) -> UIButton? {
        let mirror = Mirror(reflecting: cell.metadataView)
        return mirror.children.first(where: { $0.label == "copyButton" })?.value as? UIButton
    }

    @MainActor
    private func extractMetadataStack(from cell: AssistantMessageCell) -> UIStackView? {
        cell.metadataView
    }

    private func makeRenderModelWithMetadata(
        text: String,
        state: ChatMessageState
    ) -> ChatCollectionProjectionBuilder.MessageRenderModel {
        let message = TestFactories.makeMessage(role: .assistant, text: text, state: state)
        return ChatCollectionProjectionBuilder.MessageRenderModel(
            messageID: message.id,
            message: message,
            presentationKind: .assistant,
            showMetadata: true,
            resolvedProviderName: "OpenAI",
            resolvedModelName: "GPT-4o",
            relayKind: nil,
            renderHint: nil,
            topPadding: 16,
            displayText: nil,
            textHash: text.hashValue,
            isStreaming: state == .generating,
            providerMetadataVersion: 1
        )
    }

    @MainActor
    private func extractStreamingCodeContainer(from cell: AssistantMessageCell) -> UIView? {
        cell.streamingCodeRenderer.view
    }

    @MainActor
    private func extractStreamingCodeTextView(from cell: AssistantMessageCell) -> UITextView? {
        let mirror = Mirror(reflecting: cell.streamingCodeRenderer)
        return mirror.children.first(where: { $0.label == "textView" })?.value as? UITextView
    }

    private func makeRenderModel(
        id: UUID = UUID(),
        text: String,
        isGenerating: Bool
    ) -> ChatCollectionProjectionBuilder.MessageRenderModel {
        let message = TestFactories.makeMessage(
            id: id,
            role: .assistant,
            text: text,
            state: isGenerating ? .generating : .delivered
        )
        return ChatCollectionProjectionBuilder.MessageRenderModel(
            messageID: message.id,
            message: message,
            presentationKind: .assistant,
            showMetadata: false,
            resolvedProviderName: "OpenAI",
            resolvedModelName: "GPT-4o",
            relayKind: nil,
            renderHint: nil,
            topPadding: 16,
            displayText: nil,
            textHash: text.hashValue,
            isStreaming: isGenerating,
            providerMetadataVersion: 1
        )
    }
}
