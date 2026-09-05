import Testing
import UIKit
@testable import Oriveo

/// Finalizing an answer must reuse the frozen view instances rather than rebuilding them, so the
/// message does not visibly flash once rendering completes.
@Suite("Finalize reuses frozen instances")
@MainActor
struct FinalizeFrozenReuseTests {
    private static let width: CGFloat = 390

    private func makeMessage(id: UUID, text: String, generating: Bool) -> ChatMessage {
        ChatMessage(id: id, role: .assistant, text: text, reasoningText: nil,
                    providerKind: .miniMax, providerName: "MiniMax", modelName: "MiniMax-M2.7",
                    estimatedCost: 0, state: generating ? .generating : .delivered,
                    attachments: nil, citations: nil)
    }

    private func model(_ msg: ChatMessage, isStreaming: Bool) -> ChatCollectionProjectionBuilder.MessageRenderModel {
        ChatCollectionProjectionBuilder.MessageRenderModel(
            messageID: msg.id, message: msg, presentationKind: .assistant, showMetadata: true,
            resolvedProviderName: "MiniMax", resolvedModelName: "MiniMax-M2.7", relayKind: nil,
            renderHint: nil, topPadding: 16, displayText: nil, textHash: msg.text.hashValue,
            isStreaming: isStreaming, providerMetadataVersion: 1)
    }

    private func relayout(_ cell: AssistantMessageCell) {
        let fit = cell.contentView.systemLayoutSizeFitting(
            CGSize(width: Self.width, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel)
        cell.frame = CGRect(x: 0, y: 0, width: Self.width, height: fit.height)
        cell.contentView.frame = cell.bounds
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
    }

    @Test("Finalize Reuses Frozen View Instances")
    func finalizeReusesFrozenViewInstances() {
        let id = UUID()
        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: Self.width, height: 200))
        let vc = UIViewController()
        cell.configure(model: model(makeMessage(id: id, text: "", generating: true), isStreaming: true),
                       parentViewController: vc, onContentHeightDidChange: nil, onRetry: nil, onContinue: nil)

        let full = "Here is the approach.\n\n```swift\nlet a = 1\nlet b = a + 1\nprint(a + b)\n```\n\nThat is the complete example."
        cell.updateStreamingText(full)
        relayout(cell)

        let cardsBefore = cell.bodyStack.arrangedSubviews.compactMap { $0 as? UIKitCodeBlockCard }
        #expect(cardsBefore.count == 1, Comment(rawValue: "precondition: one code card should already be frozen while streaming"))
        let frozenTextBefore = cell.bodyStack.arrangedSubviews
            .compactMap { $0 as? ChatPassiveTextView }
            .filter { $0 !== cell.textView && !($0.text ?? "").isEmpty }

        cell.configure(model: model(makeMessage(id: id, text: full, generating: false), isStreaming: false),
                       parentViewController: vc, onContentHeightDidChange: nil, onRetry: nil, onContinue: nil)
        relayout(cell)

        let cardsAfter = cell.bodyStack.arrangedSubviews.compactMap { $0 as? UIKitCodeBlockCard }
        #expect(cardsAfter.count == 1)
        #expect(cardsBefore.first === cardsAfter.first,
                Comment(rawValue: "finalize destroyed and rebuilt the code card, so the asynchronous highlight runs again and the block flashes from plain back to coloured"))

        let frozenTextAfter = cell.bodyStack.arrangedSubviews
            .compactMap { $0 as? ChatPassiveTextView }
            .filter { $0 !== cell.textView && !($0.text ?? "").isEmpty }
        let beforeIDs = Set(frozenTextBefore.map { ObjectIdentifier($0) })
        let afterIDs = Set(frozenTextAfter.map { ObjectIdentifier($0) })
        #expect(beforeIDs.isSubset(of: afterIDs),
                Comment(rawValue: "finalize rebuilt an already frozen text segment; the prefix must be reused and only the tail appended"))
    }

    @Test("Retry Same Message Clears Frozen Views")
    func retrySameMessageClearsFrozenViews() {
        let id = UUID()
        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: Self.width, height: 200))
        let vc = UIViewController()
        cell.configure(model: model(makeMessage(id: id, text: "", generating: true), isStreaming: true),
                       parentViewController: vc, onContentHeightDidChange: nil, onRetry: nil, onContinue: nil)

        let full = "Old answer.\n\n```swift\nlet old = true\n```\n\nOld ending."
        cell.updateStreamingText(full)
        cell.configure(model: model(makeMessage(id: id, text: full, generating: false), isStreaming: false),
                       parentViewController: vc, onContentHeightDidChange: nil, onRetry: nil, onContinue: nil)

        cell.configure(model: model(makeMessage(id: id, text: "", generating: true), isStreaming: true),
                       parentViewController: vc, onContentHeightDidChange: nil, onRetry: nil, onContinue: nil)

        let residualCards = cell.bodyStack.arrangedSubviews.compactMap { $0 as? UIKitCodeBlockCard }
        #expect(residualCards.isEmpty,
                Comment(rawValue: "the old code card survived a retry, so the reuse optimisation broke the clear-out condition"))
    }

    /// After stopping generation and tapping retry, the badge and the composer state both came back
    /// but the three typing dots never appeared, and the bubble still carried the previous round's
    /// error text; leaving and re-entering the conversation fixed it.
    ///
    /// Cause: the badge and composer read `state == .generating` from the stored row, while the
    /// typing dots read the cell's private `lastStreamingText`. A retry inside the same conversation
    /// goes through `reconfigureItems`, which deliberately reuses the cell instance to avoid
    /// flicker and therefore never calls `prepareForReuse`, and the clear-out branch in `configure`
    /// only cleared the frozen views. `lastStreamingText` kept the previous tail, so the empty-text
    /// guard returned early and the dots never showed.
    @Test("Retry Same Message Shows Typing Indicator")
    func retrySameMessageShowsTypingIndicator() {
        let id = UUID()
        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: Self.width, height: 200))
        let vc = UIViewController()

        let errorText = "The request did not complete. Check the network and try again."
        cell.configure(model: model(makeMessage(id: id, text: "", generating: true), isStreaming: true),
                       parentViewController: vc, onContentHeightDidChange: nil, onRetry: nil, onContinue: nil)
        cell.updateStreamingText(errorText)
        cell.configure(model: model(makeMessage(id: id, text: errorText, generating: false), isStreaming: false),
                       parentViewController: vc, onContentHeightDidChange: nil, onRetry: nil, onContinue: nil)
        relayout(cell)

        cell.configure(model: model(makeMessage(id: id, text: "", generating: true), isStreaming: true),
                       parentViewController: vc, onContentHeightDidChange: nil, onRetry: nil, onContinue: nil)
        relayout(cell)

        #expect(cell.typingContainer.isHidden == false,
                Comment(rawValue: "the typing dots did not appear after the retry: leftover incremental state made the empty-text branch return early"))
        #expect(cell.textView.isHidden,
                Comment(rawValue: "the textView did not make room for the typing dots after the retry, so setTypingIndicatorVisible(true) was never reached"))
        #expect((cell.textView.text ?? "").isEmpty,
                Comment(rawValue: "the textView still shows the previous round after the retry, which is the old error text left hanging in the bubble"))
    }

    @Test("Finalize Race Frame Keeps Content")
    func finalizeRaceFrameKeepsContent() {
        let id = UUID()
        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: Self.width, height: 200))
        let vc = UIViewController()
        cell.configure(model: model(makeMessage(id: id, text: "", generating: true), isStreaming: true),
                       parentViewController: vc, onContentHeightDidChange: nil, onRetry: nil, onContinue: nil)

        let full = "Look at this code:\n\n```swift\nprint(1)\n```\n"
        cell.updateStreamingText(full)
        relayout(cell)
        let cardBefore = cell.bodyStack.arrangedSubviews.compactMap { $0 as? UIKitCodeBlockCard }.first
        #expect(cardBefore != nil, Comment(rawValue: "precondition: one code card should already be frozen while streaming"))

        cell.configure(model: model(makeMessage(id: id, text: "", generating: true), isStreaming: false),
                       parentViewController: vc, onContentHeightDidChange: nil, onRetry: nil, onContinue: nil)
        relayout(cell)

        let cardAfterRace = cell.bodyStack.arrangedSubviews.compactMap { $0 as? UIKitCodeBlockCard }.first
        #expect(cardAfterRace === cardBefore,
                Comment(rawValue: "the racing frame cleared and rebuilt the whole tree because it was mistaken for a retry"))
        #expect(cell.textView.isHidden == false,
                Comment(rawValue: "the racing frame flashed the typing dots and hid the textView, so the guard that only inspects the tail was bypassed"))

        cell.configure(model: model(makeMessage(id: id, text: full, generating: false), isStreaming: false),
                       parentViewController: vc, onContentHeightDidChange: nil, onRetry: nil, onContinue: nil)
        relayout(cell)
        let cardFinal = cell.bodyStack.arrangedSubviews.compactMap { $0 as? UIKitCodeBlockCard }.first
        #expect(cardFinal === cardBefore,
                Comment(rawValue: "the finalize after a racing frame must still reuse the prefix instead of rebuilding the code card"))
    }

    @Test("Finalize Waits For Fade Drain")
    func finalizeWaitsForFadeDrain() {
        let id = UUID()
        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: Self.width, height: 200))
        let vc = UIViewController()
        cell.configure(model: model(makeMessage(id: id, text: "", generating: true), isStreaming: true),
                       parentViewController: vc, onContentHeightDidChange: nil, onRetry: nil, onContinue: nil)

        let full = "First paragraph.\n\n```swift\nlet a = 1\n```\n\nThe closing paragraph text."
        cell.updateStreamingText("First paragraph.\n\n```swift\nlet a = 1\n```\n\nThe")
        cell.updateStreamingText(full)
        relayout(cell)
        #expect(!cell.chunkFader.pendingChunks.isEmpty,
                Comment(rawValue: "precondition: the tail should contain a block that is still fading, since the final commit always lands inside the fade window"))

        let clock = StreamingDisplayClock()
        cell.chunkFader.displayClock = clock
        cell.pendingFinalStreamingRender = AssistantMessageCell.PendingFinalStreamingRender(
            messageID: id, text: full, renderHint: nil)
        cell.finishPendingFinalStreamingRenderIfNeeded()

        #expect(cell.pendingFinalStreamingRender != nil,
                Comment(rawValue: "the handoff happened before the fade finished, so a half-transparent block snapped to its final colour and the tail flashed"))
        #expect(cell.textView.isHidden == false,
                Comment(rawValue: "while waiting, the tail must still be displayed by the live textView"))

        cell.chunkFader.applyAlphas(now: CACurrentMediaTime() + 10, alreadyInEditingTransaction: true)
        #expect(cell.pendingFinalStreamingRender == nil,
                Comment(rawValue: "finalize must complete on its own once the fade finishes"))
        #expect(cell.textView.isHidden,
                Comment(rawValue: "after finalize the tail has been lifted into a frozen segment, so the textView must be hidden"))
    }
}
