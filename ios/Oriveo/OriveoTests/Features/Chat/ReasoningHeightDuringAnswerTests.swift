import Combine
import Testing
import UIKit
@testable import Oriveo

/// Reproduces the reasoning block (the indicator bar) growing and shrinking while the answer is
/// still streaming.
///
/// Scenario: the reasoning text is complete and collapsed to a single line while the answer arrives
/// token by token, so every answer token makes the cell self-size again. The test measures the real
/// laid-out frame height of the reasoning block inside the cell and asserts it does not oscillate
/// as the answer grows.
@Suite("Reasoning block height stays stable while the answer streams")
@MainActor
struct ReasoningHeightDuringAnswerTests {
    private static let width: CGFloat = 390

    private func makeStreamingMessage(id: UUID, text: String, reasoning: String) -> ChatMessage {
        ChatMessage(id: id, role: .assistant, text: text, reasoningText: reasoning,
                    providerKind: .openAI, providerName: "OpenAI", modelName: "GPT-4o",
                    estimatedCost: 0, state: .generating, attachments: nil, citations: nil)
    }

    private func model(_ msg: ChatMessage) -> ChatCollectionProjectionBuilder.MessageRenderModel {
        ChatCollectionProjectionBuilder.MessageRenderModel(
            messageID: msg.id, message: msg, presentationKind: .assistant, showMetadata: true,
            resolvedProviderName: "OpenAI", resolvedModelName: "GPT-4o", relayKind: nil,
            renderHint: nil, topPadding: 16, displayText: nil, textHash: msg.text.hashValue,
            isStreaming: true, providerMetadataVersion: 1)
    }

    private func relayout(_ cell: AssistantMessageCell) -> (cell: CGFloat, reasoning: CGFloat) {
        let fit = cell.contentView.systemLayoutSizeFitting(
            CGSize(width: Self.width, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel)
        cell.frame = CGRect(x: 0, y: 0, width: Self.width, height: fit.height)
        cell.contentView.frame = cell.bounds
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
        return (fit.height, cell.reasoningBlock.frame.height)
    }

    @Test("Reasoning Height Stable While Answer Streams")
    func reasoningHeightStableWhileAnswerStreams() {
        let id = UUID()
        let reasoning = "あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみ"
        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: Self.width, height: 200))
        let vc = UIViewController()
        cell.configure(model: model(makeStreamingMessage(id: id, text: "", reasoning: reasoning)),
                       parentViewController: vc, onContentHeightDidChange: nil, onRetry: nil, onContinue: nil)

        var reasoningHeights: [CGFloat] = []
        var cellHeights: [CGFloat] = []
        let answer = "Sure, here is the answer. This body grows one character at a time to simulate the cell self-sizing continuously while the text streams in."
        let chars = Array(answer)
        for n in 1...chars.count {
            cell.updateStreamingText(String(chars.prefix(n)))
            let (cellH, reasoningH) = relayout(cell)
            cellHeights.append(cellH)
            reasoningHeights.append(reasoningH)
        }

        let distinctReasoning = Set(reasoningHeights.map { ($0 * 2).rounded() / 2 })
        #expect(distinctReasoning.count == 1,
                Comment(rawValue: "the reasoning block height oscillates: distinct=\(distinctReasoning.sorted()) reasoning=\(reasoningHeights.map { Int($0) })"))

        var nonMonotonic = 0
        for i in 1..<cellHeights.count where cellHeights[i] + 0.5 < cellHeights[i - 1] {
            nonMonotonic += 1
        }
        #expect(nonMonotonic == 0,
                Comment(rawValue: "the cell height is not monotonic (it jumps): occurrences=\(nonMonotonic) cellHeights=\(cellHeights.map { Int($0) })"))
    }
}
