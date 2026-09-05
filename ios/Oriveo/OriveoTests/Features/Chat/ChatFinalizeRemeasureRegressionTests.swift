import Combine
import Testing
import UIKit
@testable import Oriveo

/// After a send completes, a long previous message containing a code block used to overlap the
/// next user bubble.
///
/// Cause: the cached height was never corrected at the moment a message went from generating to
/// delivered. `ChatRowHeightCoordinator.measureHeights` only measures rows missing from the cache,
/// and the message was already cached from streaming; and `AssistantMessageCell.configure` only
/// called `notifyContentDidChange()` while `isGenerating`, so a delivered reconfigure on the
/// non-deferred finalize path raised no content signal. The cache therefore kept the streaming
/// height - the streaming code card and paced plain text are shorter than the final
/// `UIKitCodeBlockCard` plus fully rendered markdown - and the content overflowed the cell frame
/// onto the bubble below. Re-entering the conversation built a fresh controller with an empty
/// cache and measured everything, which is why only the freshly rendered send looked wrong.
///
/// Fix: the finalize transition raises `notifyContentDidChange` so the controller remeasures and
/// corrects the cache to the final height, matching what a re-entry would produce.
@Suite("Finalize transition triggers a remeasure")
@MainActor
struct ChatFinalizeRemeasureRegressionTests {
    private func makeModel(
        id: UUID,
        text: String,
        displayText: String?,
        state: ChatMessageState
    ) -> ChatCollectionProjectionBuilder.MessageRenderModel {
        let message = ChatMessage(
            id: id, role: .assistant, text: text, reasoningText: nil,
            providerKind: .openAI, providerName: "OpenAI", modelName: "GPT-4o",
            estimatedCost: 0, state: state, attachments: nil, citations: nil
        )
        return ChatCollectionProjectionBuilder.MessageRenderModel(
            messageID: id, message: message, presentationKind: .assistant,
            showMetadata: true, resolvedProviderName: "OpenAI", resolvedModelName: "GPT-4o",
            relayKind: nil, renderHint: nil, topPadding: 16,
            displayText: displayText, textHash: (displayText ?? text).hashValue,
            isStreaming: state == .generating, providerMetadataVersion: 0
        )
    }

    @Test("Finalize Transition Fires Remeasure")
    func finalizeTransitionFiresRemeasure() {
        let id = UUID()
        let text = """
        An upper-bounded wildcard lets a `List<Integer>` be assigned to a list of numbers:
        ```java
        List<Integer> li = new ArrayList<>();
        List<? extends Number> l1 = li;
        ```
        Without the wildcard the second line does not compile, because generics are invariant.
        """
        let parent = UIViewController()
        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 300))

        cell.configure(
            model: makeModel(id: id, text: text, displayText: text, state: .generating),
            parentViewController: parent, onContentHeightDidChange: nil, onRetry: nil, onContinue: nil
        )
        cell.startStreamingSubscription(
            publisher: Empty<Void, Never>().eraseToAnyPublisher(),
            textProvider: { text }
        )

        let before = cell._testContentDidChangeCount

        cell.configure(
            model: makeModel(id: id, text: text, displayText: nil, state: .delivered),
            parentViewController: parent, onContentHeightDidChange: nil, onRetry: nil, onContinue: nil
        )

        #expect(cell._testContentDidChangeCount > before,
                "the finalize transition raised no content signal, so nothing remeasured and the rows overlap")
    }

    @Test("Fast Finalize Without Streaming Subscription Fires Remeasure For Footer Actions")
    func fastFinalizeWithoutStreamingSubscriptionFiresRemeasureForFooterActions() {
        let id = UUID()
        let text = "A fast answer that finishes before the visible cell attaches to streaming."
        let parent = UIViewController()
        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 220))

        cell.configure(
            model: makeModel(id: id, text: text, displayText: text, state: .generating),
            parentViewController: parent,
            onContentHeightDidChange: nil,
            onRetry: {},
            onContinue: nil,
            onSaveNote: {}
        )

        let before = cell._testContentDidChangeCount

        cell.configure(
            model: makeModel(id: id, text: text, displayText: nil, state: .delivered),
            parentViewController: parent,
            onContentHeightDidChange: nil,
            onRetry: {},
            onContinue: nil,
            onSaveNote: {}
        )

        #expect(cell._testContentDidChangeCount > before,
                "a fast completion showed the footer action row without a content signal, so the action row can keep a stale layout until the conversation is reopened")
    }
}
