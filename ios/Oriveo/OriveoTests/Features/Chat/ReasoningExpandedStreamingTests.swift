import Testing
import UIKit
@testable import Oriveo

/// Pins the three fixes for "100% CPU while streaming with the reasoning block expanded":
///
/// 1. **A dead height signal.** The old `layoutSubviews` detected changes through
///    `intrinsicContentSize.height`, but `UIKitReasoningBlock` is a plain `UIView` that does not
///    override it, so the value was always -1 and `onHeightDidChange` never fired again after the
///    first layout - the cell height stopped following the expanded block as it grew.
/// 2. **A full replace on every tick, which is O(n²).** While expanded and streaming, every tick
///    rebuilt the whole accumulated reasoning into a new `NSAttributedString` and handed it to the
///    label, so TextKit relaid out the entire text each time. It now appends into the text storage
///    instead, which costs only the delta.
/// 3. **Double rendering.** `configure` called `updateContent` for the changed text and
///    `applyExpansionState` then unconditionally rendered a second time. The second render is now
///    skipped when the expansion state has not changed.
@Suite("Expanded reasoning block streaming")
@MainActor
struct ReasoningExpandedStreamingTests {
    private static let width: CGFloat = 332

    private final class StreamHarness {
        let block: UIKitReasoningBlock
        let messageID = UUID()
        let sendTaskID = UUID()
        var text = ""
        var revision: UInt64 = 0

        init(block: UIKitReasoningBlock) {
            self.block = block
            block.onRequestStreamingSnapshot = { [weak self] in self?.applySnapshot() }
        }

        func start(_ text: String) {
            self.text = text
            revision = 1
            applySnapshot()
        }

        func append(_ delta: String) {
            text.append(delta)
            revision &+= 1
            block.appendStreamingDelta(ReasoningStreamDelta(
                messageID: messageID,
                sendTaskID: sendTaskID,
                revision: revision,
                delta: delta
            ))
        }

        func applySnapshot() {
            block.applyStreamingSnapshot(ReasoningStreamSnapshot(
                messageID: messageID,
                sendTaskID: sendTaskID,
                revision: revision,
                text: text
            ))
        }
    }

    private func makeHostedBlock() -> (UIKitReasoningBlock, UIView) {
        let block = UIKitReasoningBlock()
        block.translatesAutoresizingMaskIntoConstraints = false
        let host = UIView(frame: CGRect(x: 0, y: 0, width: Self.width, height: 800))
        host.addSubview(block)
        NSLayoutConstraint.activate([
            block.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            block.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            block.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        return (block, host)
    }

    private func layout(_ host: UIView) {
        host.setNeedsLayout()
        host.layoutIfNeeded()
    }

    private static let streamSteps: [String] = {
        let lines = [
            "First understand what the user actually needs",
            "Then break the problem into sub-problems and analyze each one",
            "Next combine the context and the known facts into a conclusion",
            "Then check the reasoning chain for missed edge cases",
            "Finally write an accurate and complete answer",
        ]
        var acc = ""
        return lines.map { line in
            acc += line + "\n"
            return acc
        }
    }()

    @Test("Expanded Streaming Growth Fires Height Signal")
    func expandedStreamingGrowthFiresHeightSignal() {
        let (block, host) = makeHostedBlock()
        let stream = StreamHarness(block: block)
        stream.start(Self.streamSteps[0])
        layout(host)
        block._testTapHeader()
        layout(host)

        var fired = 0
        block.onHeightDidChange = { fired += 1 }
        var previous = Self.streamSteps[0]
        for step in Self.streamSteps.dropFirst() {
            stream.append(String(step.dropFirst(previous.count)))
            previous = step
            layout(host)
        }
        #expect(fired > 0,
                Comment(rawValue: "growing while expanded never reported a height change, so the cell never remeasures - the content overflows and the CPU work is wasted"))
    }

    @Test("Configure Renders Content Exactly Once")
    func configureRendersContentExactlyOnce() {
        let (block, host) = makeHostedBlock()
        let stream = StreamHarness(block: block)
        stream.start("Analyze the question the user asked")
        layout(host)
        #expect(block._testContentRenderCount == 1,
                Comment(rawValue: "the first configure rendered \(block._testContentRenderCount) times (expected 1)"))

        block.appendStreamingDelta(ReasoningStreamDelta(
            messageID: stream.messageID,
            sendTaskID: stream.sendTaskID,
            revision: stream.revision,
            delta: "duplicate"
        ))
        layout(host)
        #expect(block._testContentRenderCount == 1,
                Comment(rawValue: "configuring again with the same text rendered \(block._testContentRenderCount) times (expected to stay at 1)"))
    }

    @Test("Expanded Streaming Appends Only")
    func expandedStreamingAppendsOnly() {
        let (block, host) = makeHostedBlock()
        let stream = StreamHarness(block: block)
        stream.start(Self.streamSteps[0])
        layout(host)
        block._testTapHeader()
        layout(host)

        var previous = Self.streamSteps[0]
        for step in Self.streamSteps.dropFirst() {
            stream.append(String(step.dropFirst(previous.count)))
            previous = step
        }
        layout(host)

        #expect(block._testStreamFullReplaceCount == 1,
                Comment(rawValue: "the expanded stream replaced its whole content \(block._testStreamFullReplaceCount) times (expected exactly once, at the moment it expanded)"))
        #expect(block._testStreamAppendCount == Self.streamSteps.count - 1,
                Comment(rawValue: "incremental appends: \(block._testStreamAppendCount) (expected \(Self.streamSteps.count - 1))"))
        #expect(block._testContentPlainText == Self.streamSteps.last!,
                Comment(rawValue: "after append-only updates the content no longer matches the full text"))
    }

    @Test("Collapsed Preview Holds When Tail Is Marker Only")
    func collapsedPreviewHoldsWhenTailIsMarkerOnly() {
        let (block, host) = makeHostedBlock()
        let stream = StreamHarness(block: block)
        stream.start("Confirm the input bounds\n")
        layout(host)
        #expect(block._testContentPlainText == "Confirm the input bounds")

        stream.append("**")
        layout(host)
        #expect(block._testContentPlainText == "Confirm the input bounds",
                Comment(rawValue: "the preview became \"\(block._testContentPlainText)\" - either raw markup reached the screen or it flashed empty"))

        stream.append("key constraint")
        layout(host)
        #expect(block._testContentPlainText == "key constraint")
    }

    @Test("Toggle During Stream Keeps Content Correct")
    func toggleDuringStreamKeepsContentCorrect() {
        let (block, host) = makeHostedBlock()
        let stream = StreamHarness(block: block)
        stream.start(Self.streamSteps[0])
        layout(host)
        block._testTapHeader()
        layout(host)
        stream.append(String(Self.streamSteps[1].dropFirst(Self.streamSteps[0].count)))
        block._testTapHeader()
        layout(host)
        stream.append(String(Self.streamSteps[2].dropFirst(Self.streamSteps[1].count)))
        block._testTapHeader()
        layout(host)
        stream.append(String(Self.streamSteps[3].dropFirst(Self.streamSteps[2].count)))
        layout(host)

        #expect(block._testContentPlainText == Self.streamSteps[3],
                Comment(rawValue: "after collapsing and expanding again the content no longer matches the accumulated text:\n\(block._testContentPlainText)"))
    }

    @Test("Streaming Expansion Keeps Toggle Layout Callback")
    func streamingExpansionKeepsToggleLayoutCallback() {
        let (block, host) = makeHostedBlock()
        let stream = StreamHarness(block: block)
        stream.start(Self.streamSteps[1])
        layout(host)

        var layoutChangeCount = 0
        block.onLayoutChange = { layoutChangeCount += 1 }
        block._testTapHeader()
        layout(host)

        #expect(layoutChangeCount == 1)
        #expect(block._testIsExpanded)
        #expect(block._testContentPlainText == Self.streamSteps[1])
        #expect(block._testStreamFullReplaceCount == 1)
    }

    @Test("Empty Retry Task Resets Expansion Preference")
    func emptyRetryTaskResetsExpansionPreference() {
        let (block, host) = makeHostedBlock()
        let messageID = UUID()
        let firstTaskID = UUID()
        block.applyStreamingSnapshot(ReasoningStreamSnapshot(
            messageID: messageID,
            sendTaskID: firstTaskID,
            revision: 1,
            text: Self.streamSteps[0]
        ))
        layout(host)
        block._testTapHeader()
        #expect(block._testIsExpanded)

        let retryTaskID = UUID()
        block.applyStreamingSnapshot(ReasoningStreamSnapshot(
            messageID: messageID,
            sendTaskID: retryTaskID,
            revision: 0,
            text: " \n"
        ))

        #expect(!block._testIsExpanded)
    }

    @Test("Continuation Task Preserves Expansion Preference")
    func continuationTaskPreservesExpansionPreference() {
        let (block, host) = makeHostedBlock()
        let messageID = UUID()
        block.applyStreamingSnapshot(ReasoningStreamSnapshot(
            messageID: messageID,
            sendTaskID: UUID(),
            revision: 1,
            text: Self.streamSteps[0]
        ))
        layout(host)
        block._testTapHeader()
        #expect(block._testIsExpanded)

        block.applyStreamingSnapshot(ReasoningStreamSnapshot(
            messageID: messageID,
            sendTaskID: UUID(),
            revision: 1,
            text: Self.streamSteps[1]
        ))

        #expect(block._testIsExpanded)
        #expect(block._testContentPlainText == Self.streamSteps[1])
    }
}
