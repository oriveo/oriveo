import Testing
import UIKit
@testable import Oriveo

/// Two symptoms with one cause:
/// 1. large empty gaps appear between blocks while an answer streams, and close up once it finishes;
/// 2. the moment streaming ends, the layout flashes and the content slides down.
///
/// Cause: the streaming layout and the finished layout disagree about how blocks are separated. A
/// text segment frozen while streaming keeps the blank-line character between it and the next block,
/// which occupies about 25pt in the text storage, so the visual gap is that blank line plus the 12pt
/// stack spacing - roughly 37pt. The finished render produces segment content with no leading or
/// trailing blank line, so the gap is only the 12pt spacing. Every block boundary therefore differs
/// by 25 to 50pt and the error accumulates with the number of blocks, which is why answers with many
/// code blocks show the largest gaps. It has nothing to do with reasoning; this suite reproduces it
/// with none.
///
/// At finalize the frozen views are cleared and the body re-rendered in the tighter form, so the cell
/// height drops by the accumulated gap, the content height drops with it, and the scroll offset is
/// clamped back - the flash and slide.
///
/// The fix is to make the two paths agree by trimming the blank-line characters at the commit and
/// harvest boundaries.
@Suite("Streaming height floor gap")
@MainActor
struct StreamingFloorGapDiagnosticTests {
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

    /// Dumps the height of each subview of the body stack so the difference between the streaming
    /// and finished layouts can be attributed to a specific view.
    private func dumpBodyStack(_ cell: AssistantMessageCell, label: String) {
        let items = cell.bodyStack.arrangedSubviews.map { view -> String in
            let name = String(describing: type(of: view))
            let text = ((view as? UITextView)?.text?.prefix(12) ?? "")
                .replacingOccurrences(of: "\n", with: "⏎")
            return "\(name)(w=\(Int(view.frame.width)) h=\(Int(view.frame.height))\(view.isHidden ? " hidden" : ""))\(text.isEmpty ? "" : " \"\(text)…\"")"
        }
        print("[FLOORGAP] \(label) bodyStack: \(items.joined(separator: " | "))")
    }

    /// Simulates one collection view self-sizing pass: measure, apply the frame, lay out.
    private func relayout(_ cell: AssistantMessageCell) -> CGFloat {
        let fit = cell.contentView.systemLayoutSizeFitting(
            CGSize(width: Self.width, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel)
        cell.frame = CGRect(x: 0, y: 0, width: Self.width, height: fit.height)
        cell.contentView.frame = cell.bounds
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
        return fit.height
    }

    @Test("large chunks: the peak streaming measurement against the finished natural height is the visible gap")
    func floorGapUnderLargeChunks() {
        let id = UUID()
        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: Self.width, height: 200))
        let vc = UIViewController()
        cell.configure(model: model(makeMessage(id: id, text: "", generating: true), isStreaming: true),
                       parentViewController: vc, onContentHeightDidChange: nil, onRetry: nil, onContinue: nil)

        // A realistic shape: a heading, a subheading, two long code blocks and paragraphs, delivered
        // in large chunks.
        let codeA = "```php\nfunction yangHuiTriangle(int $n): array {\n"
            + String(repeating: "    $row[] = $result[$i - 1][$j - 1] + $result[$i - 1][$j];\n", count: 18)
            + "    return $result;\n}\n```"
        let codeB = "```php\nfunction fib(int $n): int {\n"
            + String(repeating: "    $memo[$i] = $memo[$i - 1] + $memo[$i - 2];\n", count: 14)
            + "    return $memo[$n];\n}\n```"
        let steps: [String] = {
            var acc: [String] = []
            var t = "## More PHP interview algorithm questions\n\n"
            acc.append(t)
            t += "**11. Pascal triangle**\n\n"
            acc.append(t)
            // While the fence is open the streaming code renderer draws it; the leading newline is
            // kept because the closing fence has to be on its own line.
            t += String(codeA.dropLast(3))
            acc.append(t)
            // The fence closes and the card is handed over to a frozen view.
            t += "```"
            acc.append(t)
            t += "\n\nThe time complexity is O(n²), the space complexity is also O(n²), and a rolling array brings it down to O(n).\n\n"
            acc.append(t)
            t += "**12. Fibonacci sequence (memoised)**\n\n"
            acc.append(t)
            t += String(codeB.dropLast(3))
            acc.append(t)
            t += "```"
            acc.append(t)
            t += "\n\nThat covers more of the common PHP interview algorithm questions, spanning arrays, dynamic programming and recursion."
            acc.append(t)
            return acc
        }()

        var floor: CGFloat = 0
        var trace: [String] = []
        for (i, s) in steps.enumerated() {
            cell.updateStreamingText(s)
            let natural = relayout(cell)
            let prevFloor = floor
            floor = max(floor, natural)
            trace.append("step\(i): natural=\(Int(natural)) floor=\(Int(floor))\(floor > prevFloor ? " ↑" : "")")
        }
        dumpBodyStack(cell, label: "last streaming step")

        // The finished layout, matching what re-entering the conversation produces: clear and render
        // the whole body statically.
        let full = steps.last!
        cell.configure(model: model(makeMessage(id: id, text: full, generating: false), isStreaming: false),
                       parentViewController: vc, onContentHeightDidChange: nil, onRetry: nil, onContinue: nil)
        let finalH = relayout(cell)
        let gap = floor - finalH
        dumpBodyStack(cell, label: "finished")

        print("[FLOORGAP] \(trace.joined(separator: "\n[FLOORGAP] "))")
        print("[FLOORGAP] final=\(Int(finalH)) peak=\(Int(floor)) gap=\(Int(gap))")
        let parsed = AssistantMessageCell.parseStreamingSegmentsDetailedForTesting(full)
        print("[FLOORGAP] parser committed=\(parsed.committedKinds) tailLen=\(parsed.tail.count) tailPrefix=\"\(parsed.tail.prefix(30))…\"")

        // Parity: the streaming layout must match the finished layout. Once the two agree about
        // blank lines the gap goes to zero; the tolerance is one line height. Anything larger is
        // visible to the user as gaps while streaming and a flash at finalize.
        #expect(gap < 24,
                Comment(rawValue: "the peak streaming measurement is \(Int(gap))pt taller than the finished layout, which is empty space while streaming and a flash at finalize"))
    }
}
