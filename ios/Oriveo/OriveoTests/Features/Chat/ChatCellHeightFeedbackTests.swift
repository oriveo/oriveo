import Testing
import UIKit
@testable import Oriveo

/// A cell must never report its height back because of a layout or frame change.
///
/// The feedback loop this breaks: `cell.layoutSubviews` called `notifyHeightChangeIfNeeded`, which
/// read `contentStack.bounds.height`. That value depends on the cell's current frame (`.fill`
/// distribution plus a low-priority bottom constraint), so the callback wrote a new height into the
/// controller's cache, the cache invalidated the layout, the new layout changed the frame, the cell
/// laid out again and reported a different value - oscillating between two heights forever, which
/// reads as flicker.
///
/// Heights are now produced only by the controller's deterministic geometry pass, triggered by
/// content and independent of frames. This suite feeds the cell different frames and asserts that
/// no height callback fires.
@Suite("Cell height feedback")
@MainActor
struct ChatCellHeightFeedbackTests {
    private static let width: CGFloat = 390

    private func makeAssistantModel(text: String) -> ChatCollectionProjectionBuilder.MessageRenderModel {
        let message = ChatMessage(
            id: UUID(), role: .assistant, text: text, reasoningText: nil,
            providerKind: .openAI, providerName: "OpenAI", modelName: "GPT-4o",
            estimatedCost: 0, state: .delivered, attachments: nil, citations: nil
        )
        return ChatCollectionProjectionBuilder.MessageRenderModel(
            messageID: message.id, message: message, presentationKind: .assistant,
            showMetadata: false, resolvedProviderName: "OpenAI", resolvedModelName: "GPT-4o",
            relayKind: nil, renderHint: nil, topPadding: 16,
            displayText: nil, textHash: text.hashValue, isStreaming: false, providerMetadataVersion: 0
        )
    }

    private func makeStreamingModel(id: UUID, text: String) -> ChatCollectionProjectionBuilder.MessageRenderModel {
        let message = ChatMessage(
            id: id, role: .assistant, text: text, reasoningText: nil,
            providerKind: .openAI, providerName: "OpenAI", modelName: "GPT-4o",
            estimatedCost: 0, state: .generating, attachments: nil, citations: nil
        )
        return ChatCollectionProjectionBuilder.MessageRenderModel(
            messageID: id, message: message, presentationKind: .assistant,
            showMetadata: false, resolvedProviderName: "OpenAI", resolvedModelName: "GPT-4o",
            relayKind: nil, renderHint: nil, topPadding: 16,
            displayText: text, textHash: text.hashValue, isStreaming: true, providerMetadataVersion: 0
        )
    }

    @Test("Streaming Update Fires Content Did Change")
    func streamingUpdateFiresContentDidChange() {
        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: Self.width, height: 100))
        let parent = UIViewController()
        let id = UUID()
        cell.configure(
            model: makeStreamingModel(id: id, text: ""),
            parentViewController: parent,
            onContentHeightDidChange: nil, onRetry: nil, onContinue: nil
        )
        let before = cell._testContentDidChangeCount
        cell.updateStreamingText("Hello streaming token text on screen")
        #expect(cell._testContentDidChangeCount > before,
                "updateStreamingText did not raise a content signal, so streaming self-size invalidation is missing")
        #expect(cell._testLastContentDidChangeID == id,
                "content signal carried the wrong message id: \(String(describing: cell._testLastContentDidChangeID))")
    }

    @Test("Assistant Does Not Report On Frame Change")
    func assistantDoesNotReportOnFrameChange() {
        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: Self.width, height: 100))
        let parent = UIViewController()
        var reports: [CGFloat] = []
        cell.configure(
            model: makeAssistantModel(
                text: "Hello world. This is a finalized assistant message that wraps onto more than one line of text."
            ),
            parentViewController: parent,
            onContentHeightDidChange: { reports.append($0) },
            onRetry: nil, onContinue: nil
        )
        cell.setNeedsLayout(); cell.layoutIfNeeded()
        reports.removeAll()

        for h in [50.0, 320.0, 88.0, 600.0, 165.0, 186.0] {
            cell.frame = CGRect(x: 0, y: 0, width: Self.width, height: h)
            cell.setNeedsLayout(); cell.layoutIfNeeded()
        }
        #expect(reports.isEmpty, "the cell reported a height on a frame change, so the feedback loop is still closed: \(reports)")
    }
}
