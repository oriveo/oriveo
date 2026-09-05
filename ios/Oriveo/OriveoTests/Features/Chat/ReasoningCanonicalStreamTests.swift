import Foundation
import Testing
@testable import Oriveo

/// Safe boundaries and incremental canonical commits for an expanded reasoning stream.
///
/// Two invariants:
/// - **raw markers never reach the screen**: an unclosed `**`, backtick, `##` or table skeleton is
///   held until it closes, and then appears in its final rendered form;
/// - **the buffer is bounded**: the pending length must not grow with the total reasoning length. If
///   the buffer grew with the input, every boundary scan would cover everything accumulated so far
///   and the whole path would be quadratic again. Lowering the frequency of the scan is not a fix.
@Suite("Expanded reasoning stream canonical commits")
struct ReasoningCanonicalStreamTests {

    /// Feeds the text in fixed-size chunks and returns what reached the screen, which is how real
    /// deltas arrive.
    private func feed(_ text: String, chunkSize: Int = 3, drain: Bool = true) -> String {
        var stream = ReasoningCanonicalStream()
        let result = NSMutableAttributedString()
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
            if let piece = stream.consume(String(text[index..<end])) { result.append(piece) }
            index = end
        }
        if drain, let tail = stream.drain() { result.append(tail) }
        return result.string
    }

    // MARK: - Raw markers never reach the screen

    @Test("an unclosed bold marker is held and appears in its final form once it closes")
    func holdsUnclosedBoldUntilClosed() {
        var stream = ReasoningCanonicalStream()
        // The `**` is unclosed, so only the text before it is shown.
        #expect(stream.consume("analyze**key")?.string == "analyze")
        // The closing marker arrives, the remainder is committed at once and the marker is gone.
        #expect(stream.consume("point**, continue")?.string == "keypoint, continue")
    }

    @Test("no frame of the stream ever shows a raw marker")
    func neverEmitsRawMarkers() {
        let source = "I need to **carefully** check: call `flush()` first, then see [the docs](https://e.com)."
        for chunkSize in [1, 2, 3, 7, 13] {
            let shown = feed(source, chunkSize: chunkSize)
            #expect(!shown.contains("**"), "chunk=\(chunkSize) leaked a raw **")
            #expect(!shown.contains("`"), "chunk=\(chunkSize) leaked a raw backtick")
            #expect(!shown.contains("]("), "chunk=\(chunkSize) leaked raw link syntax")
            // Nothing is lost: the readable text left after stripping the markers must be complete.
            #expect(shown.contains("carefully"))
            #expect(shown.contains("flush()"))
            #expect(shown.contains("the docs"))
            #expect(!shown.contains("https://e.com"), "a link URL must not be shown as body text")
        }
    }

    @Test("an ambiguous line start: `##` is not shown as body text and then promoted to a heading")
    func holdsHeadingMarkerUntilShaped() {
        var stream = ReasoningCanonicalStream()
        // With only `##` and no space yet the shape is undecided, so nothing is committed.
        // Otherwise it would appear at body size and jump to heading size once the space arrives.
        #expect(stream.consume("##") == nil)
        // Once the space and the text arrive it commits as a heading with the marker stripped.
        #expect(stream.consume(" Second")?.string == "Second")
    }

    @Test("list and quote markers also appear only in their final form")
    func rendersBlockMarkersCanonically() {
        #expect(feed("- Handle the edge cases first\n") == "• Handle the edge cases first\n")
        #expect(feed("> Note the precondition here\n") == "Note the precondition here\n")
    }

    // MARK: - Multi-line regions are held (tables, block formulas, horizontal rules)

    @Test("a table skeleton does not leak line by line; the block commits once it closes")
    func holdsTableUntilRegionComplete() {
        var stream = ReasoningCanonicalStream()
        // The header line arrived; whether this is a table depends on the next line, so hold.
        #expect(stream.consume("| Col A | Col B |\n") == nil)
        // The separator arrived, but the table may continue, so keep holding and never leak `|---|`.
        #expect(stream.consume("|---|---|\n") == nil)
        #expect(stream.consume("| 1 | 2 |\n") == nil)
        // A line without a pipe closes the region and the whole block commits at once.
        let shown = stream.consume("Table done\n")?.string
        #expect(shown != nil)
        #expect(shown?.contains("|---|") == false, "the table separator skeleton leaked onto the screen")
        #expect(shown?.contains("Col A") == true)
        #expect(shown?.contains("Table done") == true)
    }

    @Test("a multi-line block formula is held until it closes")
    func holdsBlockMathUntilClosed() {
        var stream = ReasoningCanonicalStream()
        #expect(stream.consume("$$\n") == nil)
        #expect(stream.consume("x = 1\n") == nil)
        // The closing line arrives and the block commits; the `$$` delimiters are not shown.
        let shown = stream.consume("$$\n")?.string
        #expect(shown != nil)
        #expect(shown?.contains("$$") == false, "the block formula delimiters leaked onto the screen")
    }

    @Test("a horizontal-rule candidate is held until the line ends and is never shown literally")
    func holdsHorizontalRuleCandidate() {
        var stream = ReasoningCanonicalStream()
        #expect(stream.consume("--") == nil)
        #expect(stream.consume("-") == nil)
        // Once the line closes, region detection renders it as a rule rather than three hyphens.
        let shown = stream.consume("\n")?.string
        #expect(shown?.contains("---") == false, "the horizontal rule was shown as literal hyphens")
    }

    // MARK: - Nothing is swallowed

    @Test("draining releases every hold and loses no tail")
    func drainReleasesEverything() {
        var stream = ReasoningCanonicalStream()
        _ = stream.consume("the conclusion is **important")  // this `**` never closes
        let tail = stream.drain()?.string ?? ""
        #expect(!stream.hasPending)
        // An unclosed marker settles literally, matching a full render of the finished text.
        #expect(tail.contains("important"))
    }

    @Test("line breaks and paragraph structure are preserved")
    func preservesLineStructure() {
        let shown = feed("first line\nsecond line\n\nnew paragraph\n")
        #expect(shown.contains("first line"))
        #expect(shown.contains("second line"))
        #expect(shown.contains("new paragraph"))
    }

    // MARK: - Performance invariant: linear in the total input

    /// The buffer has to stay bounded. The check: feed two hundred thousand characters of ordinary
    /// reasoning text and the pending length must stay on the order of a single line. If it grew
    /// with the total, every boundary scan would cover the whole text.
    @Test("the buffer does not grow with the total reasoning length")
    func bufferStaysBoundedAcrossHugeInput() {
        var stream = ReasoningCanonicalStream()
        var peak = 0
        for i in 0..<8_000 {
            _ = stream.consume("reasoning paragraph \(i), with **emphasis** and `code`.\n")
            peak = max(peak, stream.pendingUTF16Length)
        }
        #expect(peak < 256, "a peak buffer of \(peak) means content is accumulating and the cost has become quadratic")
    }

    /// The extreme case: a line that never ends, a long reasoning stream with no newlines. The
    /// buffer is capped by the maximum hold length, which force-releases the content.
    @Test("a very long line with no newlines is still capped by the hold limit")
    func unbrokenLongLineStaysBounded() {
        var stream = ReasoningCanonicalStream(maxHoldUTF16: 512)
        var peak = 0
        for _ in 0..<2_000 {
            _ = stream.consume("reasoning without a newline ")
            peak = max(peak, stream.pendingUTF16Length)
        }
        #expect(peak <= 512 + 64, "the hold limit is not working; the buffer grew to \(peak)")
    }

    /// A pathological case: text keeps arriving after a `**` that never closes. The content must not
    /// be withheld forever.
    @Test("a marker that never closes is released literally once the limit is reached")
    func unclosedMarkerReleasedAtHoldLimit() {
        var stream = ReasoningCanonicalStream(maxHoldUTF16: 128)
        var shown = ""
        _ = stream.consume("opening**")
        for _ in 0..<40 {
            if let piece = stream.consume("more text ") { shown += piece.string }
        }
        #expect(!shown.isEmpty, "nothing was released after the limit, so the content is stuck in the buffer forever")
        #expect(stream.pendingUTF16Length <= 128 + 64)
    }
}
