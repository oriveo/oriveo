import Testing
import UIKit
@testable import Oriveo

/// Self-sizing an assistant cell with a memory bar once tripped the NSISEngine assertion
/// "reciprocal (inf) ... not finite", with the pivot row naming `memory_suggestion_edit.Width`. This measures
/// each bar state at each width in a real window, through the production self-size entry.
@Suite("Memory bar - assistant cell self-sizing")
@MainActor
struct MemorySuggestionCellLayoutTests {
    private static let states: [MemorySuggestionBar?] = [
        nil,
        MemorySuggestionBar(messageID: UUID(), content: nil),
        MemorySuggestionBar(messageID: UUID(), content: "The user prefers replies in Simplified Chinese, technical terms kept in English, and answers short and direct."),
        MemorySuggestionBar(messageID: UUID(), content: nil),
        nil,
        MemorySuggestionBar(messageID: UUID(), content: "Short"),
    ]

    private static func makeCell(width: CGFloat, window: UIWindow) -> AssistantMessageCell? {
        let message = ChatMessage(
            id: UUID(), role: .assistant,
            text: String(repeating: "Sure, here is an answer long enough to make the cell wrap over several lines and take a second measuring round. ", count: 4),
            reasoningText: nil,
            providerKind: .openAI, providerName: "OpenAI", modelName: "GPT-4o",
            estimatedCost: 0.01, state: .delivered, attachments: nil, citations: nil
        )
        let rows = ChatCollectionProjectionBuilder.makeRows(from: [message], metadata: .empty)
        let plan = ChatCollectionProjectionBuilder.makeSnapshotPlan(from: rows, providerMetadataVersion: 0)
        guard let model = plan.renderModelsByID[message.id] else { return nil }
        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: width, height: 100))
        cell.configure(
            model: model,
            parentViewController: UIViewController(),
            onContentHeightDidChange: nil,
            onRetry: nil,
            onContinue: nil
        )
        window.addSubview(cell)
        return cell
    }

    @Test("self-size height stays finite and does not trip the engine assertion across states and widths", arguments: [440, 402, 393, 320, 1] as [CGFloat])
    func selfSizingAcrossStates(width: CGFloat) throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: max(width, 1), height: 900))
        window.isHidden = false
        let cell = try #require(Self.makeCell(width: width, window: window))
        for state in Self.states {
            cell.applyMemorySuggestion(state)
            let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
            attributes.frame = CGRect(x: 0, y: 0, width: width, height: 120)
            let preferred = cell.preferredLayoutAttributesFitting(attributes)
            #expect(preferred.size.height.isFinite)
            #expect(preferred.size.height > 0)
            cell.frame = CGRect(origin: .zero, size: preferred.size)
            cell.layoutIfNeeded()
        }
        window.isHidden = true
    }
}
