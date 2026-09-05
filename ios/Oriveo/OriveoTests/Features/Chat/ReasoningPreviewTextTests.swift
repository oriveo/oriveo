import Foundation
import Testing
@testable import Oriveo

/// Behaviour of the single-line preview shown on a collapsed reasoning block.
///
/// Two requirements:
/// - the preview must strip markdown markers, otherwise raw `**` and `###` end up on screen;
/// - producing the preview must be bounded and must not grow with the length of the reasoning. The
///   earlier implementation copied the whole string on every tick and scanned back for the last
///   newline, which is linear in the reasoning length for a stream with few newlines.
@Suite("Collapsed reasoning preview line")
struct ReasoningPreviewTextTests {

    // MARK: - Markdown marker stripping

    @Test("bold markers never reach the screen")
    func stripsBoldMarkers() {
        #expect(ReasoningPreviewText.previewLine(of: "I need to **carefully** check this") == "I need to carefully check this")
    }

    @Test("an unclosed bold marker is stripped too, which is the usual shape of a streaming tail")
    func stripsUnbalancedBoldMarker() {
        // Half-streamed: the opening `**` has arrived and the closing one has not. A regex that
        // requires a matching pair would leave it visible.
        #expect(ReasoningPreviewText.previewLine(of: "next analyze **constraint") == "next analyze constraint")
    }

    @Test("inline code, strikethrough and italic markers are stripped as well")
    func stripsOtherInlineMarkers() {
        #expect(ReasoningPreviewText.previewLine(of: "call `flush()` after") == "call flush() after")
        #expect(ReasoningPreviewText.previewLine(of: "this plan ~~fails~~ retry") == "this plan fails retry")
        #expect(ReasoningPreviewText.previewLine(of: "*note*, then the boundary") == "note, then the boundary")
    }

    @Test("a link keeps only its readable text")
    func keepsLinkTextOnly() {
        #expect(ReasoningPreviewText.previewLine(of: "see [docs](https://example.com/a) here")
                == "see docs here")
    }

    @Test("block-level markers at the start of a line are stripped")
    func stripsBlockMarkers() {
        #expect(ReasoningPreviewText.previewLine(of: "## Step two: verify") == "Step two: verify")
        #expect(ReasoningPreviewText.previewLine(of: "> note the premise") == "note the premise")
        #expect(ReasoningPreviewText.previewLine(of: "- handle the edge case") == "handle the edge case")
        #expect(ReasoningPreviewText.previewLine(of: "3. then merge results") == "then merge results")
    }

    // MARK: - Conservative stripping: leave alone what is not a marker

    @Test("a multiplication sign and snake_case are not mistaken for markers")
    func doesNotTouchNonMarkerSymbols() {
        // Whitespace on both sides means this `*` is not an emphasis marker.
        #expect(ReasoningPreviewText.previewLine(of: "complexity is n * log n") == "complexity is n * log n")
        // Underscores are always kept: snake_case is far more common in reasoning text than
        // underscore emphasis.
        #expect(ReasoningPreviewText.previewLine(of: "field is last_sse_sequence") == "field is last_sse_sequence")
        // A single `~` is a tilde, not a strikethrough.
        #expect(ReasoningPreviewText.previewLine(of: "about~100ms") == "about~100ms")
        #expect(ReasoningPreviewText.previewLine(of: "2*3") == "2*3")
        #expect(ReasoningPreviewText.previewLine(of: "char*") == "char*")
        #expect(ReasoningPreviewText.previewLine(of: "keep \\* escaped") == "keep \\* escaped")
        #expect(ReasoningPreviewText.previewLine(of: ">file") == ">file")
    }

    // MARK: - Line selection and truncation

    @Test("only the last line is used")
    func takesLastLineOnly() {
        #expect(ReasoningPreviewText.previewLine(of: "first\nsecond\nthird") == "third")
    }

    @Test("trailing newlines and whitespace do not change which line is picked")
    func ignoresTrailingWhitespace() {
        #expect(ReasoningPreviewText.previewLine(of: "first\nsecond\n\n  ") == "second")
    }

    @Test("an over-long line is truncated to its tail and prefixed with an ellipsis")
    func truncatesLongLine() {
        let line = String(repeating: "あ", count: 200)
        let preview = ReasoningPreviewText.previewLine(of: line)
        #expect(preview.hasPrefix("…"))
        #expect(preview.dropFirst().count == ReasoningPreviewText.defaultMaxCharacters)
    }

    @Test("a line exactly at the limit gets no ellipsis")
    func doesNotTruncateAtExactLimit() {
        let line = String(repeating: "あ", count: ReasoningPreviewText.defaultMaxCharacters)
        #expect(ReasoningPreviewText.previewLine(of: line) == line)
    }

    @Test("whitespace-only or empty text returns an empty string")
    func emptyForBlankInput() {
        #expect(ReasoningPreviewText.previewLine(of: "") == "")
        #expect(ReasoningPreviewText.previewLine(of: "\n\n   \n") == "")
    }

    /// A shape that slipped through: after a newline the model emits the block or emphasis marker
    /// first and the text only in the next chunk. The marker then owns the whole line, and the rule
    /// "a marker must sit next to non-whitespace" fails on both sides, so without a special case the
    /// raw `**` or `###` would be displayed - exactly the symptom this is meant to cure. Returning an
    /// empty string lets the caller keep the previous frame.
    @Test("a line containing only markdown scaffolding returns an empty string")
    func emptyWhenLineHasOnlyMarkers() {
        #expect(ReasoningPreviewText.previewLine(of: "note:\n**") == "")
        #expect(ReasoningPreviewText.previewLine(of: "note:\n###") == "")
        #expect(ReasoningPreviewText.previewLine(of: "note:\n```") == "")
        #expect(ReasoningPreviewText.previewLine(of: "header\n|---|---|") == "")
        #expect(ReasoningPreviewText.previewLine(of: "summary\n---") == "")
    }

    @Test("a marker already followed by text still renders and is not caught by the marker-only rule")
    func showsContentOnceItArrivesAfterMarkers() {
        #expect(ReasoningPreviewText.previewLine(of: "note:\n**ok" ) == "ok")
        #expect(ReasoningPreviewText.previewLine(of: "note:\n### step three") == "step three")
    }

    // MARK: - Boundedness (performance invariant)

    /// The cost of producing the preview must not depend on the total length of the reasoning. The
    /// check: put the same line at the end of a hundred thousand characters of reasoning and the
    /// result must be identical to taking that line on its own. Together with the bounded backward
    /// scan in the implementation, that pins it against degrading into a full scan.
    @Test("the preview reads only a tail window, independent of how much precedes it")
    func previewIsBoundedRegardlessOfHistoryLength() {
        let tail = "check this **step** now"
        let expected = "check this step now"

        let short = "history\n" + tail
        let huge = String(repeating: "history. ", count: 20_000) + "\n" + tail

        #expect(ReasoningPreviewText.previewLine(of: short) == expected)
        #expect(ReasoningPreviewText.previewLine(of: huge) == expected)
    }

    /// For a very long single line - a long reasoning stream with no newlines - the window cut has
    /// to carry an ellipsis so the reader knows more precedes it.
    @Test("a very long reasoning stream with no newlines still gets an ellipsis at the window cut")
    func markstruncationForUnbrokenLongLine() {
        let preview = ReasoningPreviewText.previewLine(of: String(repeating: "あいうえお", count: 5_000))
        #expect(preview.hasPrefix("…"))
        #expect(preview.dropFirst().count <= ReasoningPreviewText.defaultMaxCharacters)
    }

    @Test("a huge run of trailing whitespace still only scans the fixed tail window")
    func hugeTrailingWhitespaceStaysBounded() {
        let text = "あいうえ" + String(repeating: " ", count: 100_000)
        #expect(ReasoningPreviewText.previewLine(of: text).isEmpty)
    }

    @Test("the rolling preview source stays within its UTF-8 byte budget")
    func rollingPreviewSourceStaysByteBounded() {
        var source = ""
        for _ in 0..<1_000 {
            source = ReasoningPreviewText.appendingToBoundedSuffix(source, delta: "あい😀")
            #expect(source.utf8.count <= ReasoningPreviewText.defaultSourceByteLimit)
        }
        #expect(!source.contains("�"))
    }

    @Test("a huge single chunk keeps the multi-byte tail window valid and bounded")
    func hugeMultibyteChunkStaysValidAndBounded() {
        let combining = "e\u{301}"
        let delta = String(repeating: combining + "😀", count: 20_000)
        let source = ReasoningPreviewText.appendingToBoundedSuffix("", delta: delta)

        #expect(source.utf8.count <= ReasoningPreviewText.defaultSourceByteLimit)
        #expect(!source.contains("�"))
        #expect(source.hasSuffix("😀"))
    }
}
