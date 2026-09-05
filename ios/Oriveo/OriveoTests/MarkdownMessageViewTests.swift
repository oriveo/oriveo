import Foundation
import Testing
import CoreGraphics
@testable import Oriveo

@Suite("Markdown Message View Tests")
struct MarkdownMessageViewTests {
    @Test("Plain Text Uses Plain Renderer")
    func plainTextUsesPlainRenderer() {
        let text = "Hello, Oriveo."

        #expect(MarkdownMessageView.staticRenderingMode(for: text) == .plainText)
    }

    @Test("Inline Markdown Uses Attributed Renderer")
    func inlineMarkdownUsesAttributedRenderer() {
        let text = "Use **bold** and `code` inline."

        #expect(MarkdownMessageView.staticRenderingMode(for: text) == .inlineMarkdown)
    }

    @Test("Streaming Tail Reuses Chat Text Storage Writer")
    func streamingTailReusesChatTextStorageWriter() throws {
        let source = try String(contentsOfFile: markdownMessageViewSourcePath(), encoding: .utf8)
        guard let segmentRange = source.range(of: "private struct StreamingTextSegmentView") else {
            Issue.record("StreamingTextSegmentView not found")
            return
        }
        let segmentSource = String(source[segmentRange.lowerBound...])

        #expect(segmentSource.contains("StreamingMarkdownTailTextView"))
        #expect(source.contains("BlockCommitTextWriter"))
        #expect(!segmentSource.contains("NativeTextLabel"))
        #expect(!segmentSource.contains("HStack(spacing: 0)"))
    }

    @Test("Finished Streaming Layout Commits Final Markdown Paragraph")
    func finishedStreamingLayoutCommitsFinalMarkdownParagraph() {
        let text = "Intro paragraph.\n\nUse **bold** and `code`."

        let activeSplit = MarkdownMessageView.streamingLayoutSplit(for: text, keepsCurrentTail: true)
        #expect(activeSplit.committed == "Intro paragraph.\n\n")
        #expect(activeSplit.tail == "Use **bold** and `code`.")

        let finishedSplit = MarkdownMessageView.streamingLayoutSplit(for: text, keepsCurrentTail: false)
        #expect(finishedSplit.committed == text)
        #expect(finishedSplit.tail.isEmpty)
    }

    @Test("Hiding Cursor Does Not Commit Streaming Tail")
    func hidingCursorDoesNotCommitStreamingTail() throws {
        let source = try String(contentsOfFile: markdownMessageViewSourcePath(), encoding: .utf8)

        #expect(!source.contains("keepsCurrentTail: isStreaming && showsCursor"))
        #expect(source.contains("keepsCurrentTail: isStreaming)"))
    }

    @Test("Streaming Tail Measurement Does Not Use Compressed Width Fallback")
    func streamingTailMeasurementDoesNotUseCompressedWidthFallback() throws {
        let source = try String(contentsOfFile: markdownMessageViewSourcePath(), encoding: .utf8)
        guard let viewRange = source.range(of: "private struct StreamingMarkdownTailTextView") else {
            Issue.record("StreamingMarkdownTailTextView not found")
            return
        }
        let viewSource = String(source[viewRange.lowerBound...])

        #expect(viewSource.contains("guard let width = proposal.width, width.isFinite, width > 0 else { return nil }"))
        #expect(!viewSource.contains("UIView.layoutFittingCompressedSize.width"))
    }

    @Test("Streaming Tail Measurement Does Not Mutate UIView Bounds")
    func streamingTailMeasurementDoesNotMutateUIViewBounds() throws {
        let source = try String(contentsOfFile: markdownMessageViewSourcePath(), encoding: .utf8)
        guard let viewRange = source.range(of: "private struct StreamingMarkdownTailTextView") else {
            Issue.record("StreamingMarkdownTailTextView not found")
            return
        }
        let viewSource = String(source[viewRange.lowerBound...])

        #expect(viewSource.contains("width.isFinite"))
        #expect(!viewSource.contains("uiView.bounds.size.width"))
        #expect(!viewSource.contains("uiView.bounds ="))
    }

    @Test("Streaming Tail Measurement Uses Chat Passive Cached Measurement")
    func streamingTailMeasurementUsesChatPassiveCachedMeasurement() throws {
        let source = try String(contentsOfFile: markdownMessageViewSourcePath(), encoding: .utf8)
        guard let viewRange = source.range(of: "private struct StreamingMarkdownTailTextView") else {
            Issue.record("StreamingMarkdownTailTextView not found")
            return
        }
        let viewSource = String(source[viewRange.lowerBound...])

        #expect(viewSource.contains("measuredContentSize(fittingWidth: width)"))
        #expect(!viewSource.contains("uiView.sizeThatFits"))
    }

    @Test("Code Fence Only Uses Segmented Renderer")
    func codeFenceOnlyUsesSegmentedRenderer() {
        let text = """
        ```swift
        print("hello")
        ```
        """

        #expect(MarkdownMessageView.staticRenderingMode(for: text) == .segmentedCodeMarkdown)
    }

    @Test("Table Markdown Uses Block Renderer")
    func tableMarkdownUsesBlockRenderer() {
        let text = """
        ## 

        |  |  |
        | --- | --- |
        |  | O(log n) |
        |  | O(log n) |
        """

        #expect(MarkdownMessageView.staticRenderingMode(for: text) == .blockMarkdown)
    }

    @Test("Code Fence And Table Use Segmented Renderer")
    func codeFenceAndTableUseSegmentedRenderer() {
        let text = """
        ## 

        ```text
         10 -> : true
        ```

        ## 

        |  |  |
        | --- | --- |
        | - | , |
        """

        #expect(MarkdownMessageView.staticRenderingMode(for: text) == .segmentedCodeMarkdown)
    }

    @Test("Warmed Hint Matches Static Detection")
    func warmedHintMatchesStaticDetection() async {
        let actor = MarkdownCacheActor()
        let text = "Use **bold** and `code` inline."

        let hint = await actor.prepareHint(messageID: UUID(), text: text)

        #expect(hint.mode == .inlineMarkdown)
        #expect(hint.contentHash == MarkdownRenderHint.hash(for: text))
        #expect(MarkdownMessageView.resolvedRenderingMode(for: text, renderHint: hint) == .inlineMarkdown)
    }

    @Test("Stale Hint Falls Back To Static Detection")
    func staleHintFallsBackToStaticDetection() {
        let staleHint = MarkdownRenderHint(
            messageID: UUID(),
            contentHash: 1,
            mode: .plainText
        )
        let text = """
        ## Heading

        | A | B |
        | - | - |
        | 1 | 2 |
        """

        #expect(MarkdownMessageView.resolvedRenderingMode(for: text, renderHint: staleHint) == .blockMarkdown)
    }

    @Test("Height Change Filter Ignores Tiny Jitter")
    func heightChangeFilterIgnoresTinyJitter() {
        #expect(MarkdownMessageView.shouldNotifyHeightChange(from: 120, to: 120.6) == false)
    }

    @Test("Height Change Filter Reports Meaningful Delta")
    func heightChangeFilterReportsMeaningfulDelta() {
        #expect(MarkdownMessageView.shouldNotifyHeightChange(from: 120, to: 123.5) == true)
    }

    private func markdownMessageViewSourcePath() -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        return testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Oriveo/Shared/Components/MarkdownMessageView.swift")
            .path
    }
}
