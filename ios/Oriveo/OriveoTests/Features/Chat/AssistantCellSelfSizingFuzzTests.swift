import Foundation
import Testing
import UIKit
@testable import Oriveo

/// Regression matrix for the self-sizing crash: body shape x memory candidate shape x width, measured
/// through the production self-size entry. An engine assertion kills the host outright, so every case prints
/// its index first and the last log line names the culprit when the host dies.
@Suite("Assistant cell self-sizing - shape matrix")
@MainActor
struct AssistantCellSelfSizingFuzzTests {
    // CJK samples are written as unicode escapes so the source stays ASCII; "\u{597D}\u{7684}" is two CJK characters.
    private static let cjkSentence = "\u{597D}\u{7684}\u{FF0C}\u{8FD9}\u{662F}\u{4E00}\u{6BB5}\u{6B63}\u{6587}\u{3002}"

    private static let bodies: [String] = [
        "",
        " ",
        "\n\n\n",
        "Hi",
        String(repeating: "Sure, this is a paragraph of body text. ", count: 400),
        String(repeating: "a", count: 6000),
        "https://example.com/" + String(repeating: "x", count: 3000),
        "```swift\nlet x = 1\n" + String(repeating: "print(x)\n", count: 200) + "```",
        "| a | b |\n|---|---|\n" + String(repeating: "| 1 | 2 |\n", count: 50),
        "| one |\n|---|\n| " + String(repeating: "\u{957F}", count: 2000) + " |",
        "$$\\int_0^1 x^2 dx$$ and $a/b$",
        "> quote\n> " + String(repeating: "nested", count: 300),
        "# Heading\n## Second level\n- list\n  - child\n1. ordered\n\n---\n",
        String(repeating: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}", count: 500),
        "\u{0645}\u{0631}\u{062D}\u{0628}\u{0627} " + String(repeating: "\u{0646}\u{0635} \u{0637}\u{0648}\u{064A}\u{0644} ", count: 300),
        String(repeating: "\n", count: 2000) + "tail",
        "<think>inner</think>body",
        String(repeating: cjkSentence, count: 100),
    ]

    private static let memoryContents: [String?] = [
        nil,
        "",
        " ",
        "\n\n\n",
        "Short",
        String(repeating: "The user prefers replies in Simplified Chinese, ", count: 200),
        String(repeating: "x", count: 5000),
        String(repeating: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}", count: 300),
        String(repeating: "\n", count: 500) + "tail",
        "\u{200B}\u{200B}\u{200B}",
        "\u{FFFC}",
    ]

    private static let widths: [CGFloat] = [440, 120, 1, 0]

    private static func makeCell(body: String, memory: String??, width: CGFloat, window: UIWindow) -> AssistantMessageCell? {
        let message = ChatMessage(
            id: UUID(), role: .assistant, text: body, reasoningText: nil,
            providerKind: .openAI, providerName: "OpenAI", modelName: "GPT-4o",
            estimatedCost: 0.01, state: .delivered, attachments: nil, citations: nil
        )
        let bar = memory.map { MemorySuggestionBar(messageID: message.id, content: $0) }
        let rows = ChatCollectionProjectionBuilder.makeRows(from: [message], metadata: .empty, memorySuggestion: bar)
        let plan = ChatCollectionProjectionBuilder.makeSnapshotPlan(from: rows, providerMetadataVersion: 0)
        guard let model = plan.renderModelsByID[message.id] else { return nil }
        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: max(width, 1), height: 100))
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

    private static func measure(_ cell: AssistantMessageCell, width: CGFloat) -> CGSize {
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
        attributes.frame = CGRect(x: 0, y: 0, width: width, height: 120)
        let preferred = cell.preferredLayoutAttributesFitting(attributes)
        cell.frame = CGRect(origin: .zero, size: preferred.size)
        cell.layoutIfNeeded()
        // Second round: measure again once the real frame has settled (production checkForPreferredAttributes measures repeatedly).
        let again = cell.preferredLayoutAttributesFitting(attributes)
        return again.size
    }

    @Test("body x memory candidate x width: self-size stays finite", arguments: Array(0..<bodies.count))
    func matrix(bodyIndex: Int) {
        let body = Self.bodies[bodyIndex]
        for (memoryIndex, memory) in Self.memoryContents.enumerated() {
            for memoryOn in [true, false] {
                let state: String?? = memoryOn ? .some(memory) : .none
                for width in Self.widths {
                    print("[selfsize-fuzz] body=\(bodyIndex) memory=\(memoryIndex) on=\(memoryOn) width=\(width)")
                    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: max(width, 1), height: 900))
                    window.isHidden = false
                    guard let cell = Self.makeCell(body: body, memory: state, width: width, window: window) else {
                        Issue.record("model missing body=\(bodyIndex)")
                        continue
                    }
                    let size = Self.measure(cell, width: width)
                    #expect(size.width.isFinite && size.height.isFinite && size.height > 0,
                            "body=\(bodyIndex) memory=\(memoryIndex) width=\(width) size=\(size)")
                    window.isHidden = true
                }
            }
        }
    }
}
