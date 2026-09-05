import Foundation
import Testing
@testable import Oriveo

/// `StreamingBlockChunker` is the block-level commit boundary state machine.
///
/// Contract: `nextBoundary(visible:target:...)` advances `visible` - always a prefix of `target` -
/// to the next safe commit boundary. It advances by word blocks (ASCII word boundaries, or a count
/// of CJK characters), commits whole lines at a line end, treats a blank line as a paragraph break,
/// keeps a table header plus separator atomic, holds inside a block-level `$$`, holds on horizontal
/// rules and fence lines, holds on an unclosed inline span at the scanner boundary, and passes
/// characters straight through inside a fence.
///
/// Invariants: `visible` never shrinks; when the result is held `newVisible == visible`; and
/// `isStreamEnd` releases every hold and converges in a finite number of steps.
@Suite("Streaming Block Chunker Tests")
struct StreamingBlockChunkerTests {

    private let cadence = BlockCommitCadence.default

    private func next(
        _ visible: String, _ target: String,
        profile: StreamingPacerLanguageProfile = .cjk,
        streamEnd: Bool = false
    ) -> StreamingBlockChunker.Boundary {
        StreamingBlockChunker.nextBoundary(
            visible: visible, target: target,
            profile: profile, cadence: cadence, isStreamEnd: streamEnd
        )
    }


    @Test("Ascii Word Chunk")
    func asciiWordChunk() {
        let b = next("", "abcd efgh ijkl mnop qrst ", profile: .ascii)
        #expect(b.kind == .wordChunk)
        #expect(b.newVisible == "abcd efgh ijkl ")
    }

    @Test("Ascii Second Chunk Takes Rest")
    func asciiSecondChunkTakesRest() {
        let target = "abcd efgh ijkl mnop qrst "
        let b = next("abcd efgh ijkl ", target, profile: .ascii)
        #expect(b.kind == .wordChunk)
        #expect(b.newVisible == target)
    }

    @Test("Ascii Holds Trailing Partial Word")
    func asciiHoldsTrailingPartialWord() {
        let b = next("abcd efgh ijkl ", "abcd efgh ijkl mnop qrst", profile: .ascii)
        #expect(b.kind == .wordChunk)
        #expect(b.newVisible == "abcd efgh ijkl mnop ")
    }

    @Test("Cjk Chunks")
    func cjkChunks() {
        let b1 = next("", "これはにほんごのぶん")
        #expect(b1.kind == .wordChunk)
        #expect(b1.newVisible == "これはにほん")
        let b2 = next("これはにほん", "これはにほんごのぶん")
        #expect(b2.newVisible == "これはにほんごのぶん")
    }

    @Test("Cjk Chunk Respects Composed Boundary")
    func cjkChunkRespectsComposedBoundary() {
        let b = next("", "a😀😀😀つづきのもじ")
        #expect(b.kind == .wordChunk)
        #expect(b.newVisible == "a😀😀")
    }

    @Test("Cjk Long Marker Line Commits Marker Atomically")
    func cjkLongMarkerLineCommitsMarkerAtomically() {
        let b = next("", "###### もじもじもじ")
        #expect(b.kind == .wordChunk)
        #expect(b.newVisible.hasPrefix("###### "))
    }

    @Test("Cjk Deep Indent Bullet Marker Safe")
    func cjkDeepIndentBulletMarkerSafe() {
        let b = next("", "     - もじもじもじ")
        #expect(b.kind == .wordChunk)
        #expect(b.newVisible.hasPrefix("     - "))
    }


    @Test("First Reveal Exempts Partial Word Hold")
    func firstRevealExemptsPartialWordHold() {
        let b = next("", "Hel", profile: .ascii)
        #expect(b.kind == .wordChunk)
        #expect(b.newVisible == "Hel")
    }

    @Test("Partial Word Hold Resumes After First Reveal")
    func partialWordHoldResumesAfterFirstReveal() {
        let b = next("Hel", "Hello", profile: .ascii)
        #expect(b.kind == .held)
        #expect(b.newVisible == "Hel")
        let b2 = next("Hel", "Hello world", profile: .ascii)
        #expect(b2.newVisible == "Hello ")
    }

    @Test("First Reveal Prefers Word Boundary When Available")
    func firstRevealPrefersWordBoundaryWhenAvailable() {
        let b = next("", "hello world", profile: .ascii)
        #expect(b.newVisible == "hello ")
    }

    // MARK: - inline span hold

    @Test("Hold At Unclosed Bold")
    func holdAtUnclosedBold() {
        let target = "まえ **ふとじ"
        let b1 = next("", target)
        #expect(b1.kind == .wordChunk)
        #expect(b1.newVisible == "まえ ")
        let b2 = next("まえ ", target)
        #expect(b2.kind == .held)
        #expect(b2.newVisible == "まえ ")
    }

    @Test("Chunk Extends Through Closed Span")
    func chunkExtendsThroughClosedSpan() {
        let b = next("", "**ふとじのぶん** つづき")
        #expect(b.kind == .wordChunk)
        #expect(b.newVisible == "**ふとじのぶん**")
        let b2 = next("**ふとじのぶん**", "**ふとじのぶん** つづき")
        #expect(b2.newVisible == "**ふとじのぶん** つづき")
    }

    @Test("Ascii Chunk Extends Through Closed Span")
    func asciiChunkExtendsThroughClosedSpan() {
        let b = next("", "ab **two words here** tail tail", profile: .ascii)
        #expect(b.kind == .wordChunk)
        #expect(b.newVisible.hasSuffix("**") || b.newVisible.hasSuffix(" "))
        let ns = b.newVisible as NSString
        #expect(StreamingInlineSpanScanner.safeBoundary(in: b.newVisible) == ns.length)
    }

    @Test("Line Completion Commits Remainder")
    func lineCompletionCommitsRemainder() {
        let b = next("まえ ", "まえ **ふとじ**\nつぎ")
        #expect(b.kind == .lineEnd)
        #expect(b.newVisible == "まえ **ふとじ**\n")
    }

    @Test("Blank Line Is Paragraph")
    func blankLineIsParagraph() {
        let b = next("いちだん\n", "いちだん\n\nにだんめ")
        #expect(b.kind == .paragraphEnd)
        #expect(b.newVisible == "いちだん\n\n")
    }


    @Test("Heading Early Chunk")
    func headingEarlyChunk() {
        let b = next("", "## みだしぶ")
        #expect(b.kind == .wordChunk)
        #expect(b.newVisible == "## みだしぶ")
    }

    @Test("Ambiguous Line Start Held")
    func ambiguousLineStartHeld() {
        for target in ["#", "--", "> "] {
            let b = next("", target)
            #expect(b.kind == .held, "target: \(target)")
            #expect(b.newVisible == "")
        }
    }

    @Test("Hr Commits At Line End")
    func hrCommitsAtLineEnd() {
        #expect(next("", "---").kind == .held)
        let b = next("", "---\nつづきのもじ")
        #expect(b.kind == .lineEnd)
        #expect(b.newVisible == "---\n")
    }


    @Test("Fence Opener Then Code Chunks")
    func fenceOpenerThenCodeChunks() {
        #expect(next("", "```swift").kind == .held)
        let b1 = next("", "```swift\nlet x = 1")
        #expect(b1.kind == .lineEnd)
        #expect(b1.newVisible == "```swift\n")
        let b2 = next("```swift\n", "```swift\nlet x = 1")
        #expect(b2.kind == .codeChunk)
        #expect(b2.newVisible == "```swift\nlet ")   // codeStepSize(9) == 4
    }

    @Test("Partial Closing Fence Held")
    func partialClosingFenceHeld() {
        let base = "```swift\nlet x = 1\n"
        #expect(next(base, base + "`").kind == .held)
        #expect(next(base, base + "``").kind == .held)
        let grown = next(base, base + "``x")
        #expect(grown.kind == .codeChunk)
        #expect(grown.newVisible == base + "``x")
        let closed = next(base, base + "```")
        #expect(closed.kind == .codeChunk)
        #expect(closed.newVisible == base + "```")
    }

    @Test("Closing Fence Line Atomic Step")
    func closingFenceLineAtomicStep() {
        let base = "```swift\nlet x = 1\n"
        let b = next(base, base + "``` \nつづきのほんぶん")
        #expect(b.kind == .codeChunk)
        #expect(b.newVisible == base + "``` \n")
    }

    @Test("Closing Fence At Line Start Not Overshot")
    func closingFenceAtLineStartNotOvershot() {
        let base = "```c\nint a = 1;\n"
        let target = base + "```\n" + String(repeating: "ほんぶんつづき", count: 20)
        let b = next(base, target)
        #expect(b.kind == .codeChunk)
        #expect(b.newVisible == base + "```\n")
    }

    @Test("Partial Fence Released At Stream End")
    func partialFenceReleasedAtStreamEnd() {
        let base = "```swift\nlet x = 1\n"
        let target = base + "``"
        var visible = base
        var steps = 0
        while visible != target, steps < 50 {
            let b = next(visible, target, streamEnd: true)
            if b.newVisible == visible { break }
            visible = b.newVisible
            steps += 1
        }
        #expect(visible == target)
    }


    @Test("Table Header Separator Atomic")
    func tableHeaderSeparatorAtomic() {
        #expect(next("", "| A | B |").kind == .held)
        #expect(next("", "| A | B |\n|---|---|").kind == .held)
        let b = next("", "| A | B |\n|---|---|\n")
        #expect(b.kind == .tableRows)
        #expect(b.newVisible == "| A | B |\n|---|---|\n")
    }

    @Test("Table Includes Complete Rows")
    func tableIncludesCompleteRows() {
        let b = next("", "| A | B |\n|---|---|\n| 1 | 2 |\n| 3")
        #expect(b.kind == .tableRows)
        #expect(b.newVisible == "| A | B |\n|---|---|\n| 1 | 2 |\n")
        let b2 = next(b.newVisible, "| A | B |\n|---|---|\n| 1 | 2 |\n| 3")
        #expect(b2.kind == .held)
    }

    @Test("Continuing Table Row")
    func continuingTableRow() {
        let visible = "| A | B |\n|---|---|\n"
        let b = next(visible, visible + "| 1 | 2 |\nのこり")
        #expect(b.kind == .tableRows)
        #expect(b.newVisible == visible + "| 1 | 2 |\n")
    }

    @Test("Pipe Line Not Table")
    func pipeLineNotTable() {
        let b = next("", "| A | B |\nふつうのもじ\n")
        #expect(b.kind == .lineEnd)
        #expect(b.newVisible == "| A | B |\n")
    }


    @Test("Block Math Hold Until Closed")
    func blockMathHoldUntilClosed() {
        #expect(next("", "$$\nE=mc^2").kind == .held)
        let b = next("", "$$\nE=mc^2\n$$\nしめ")
        #expect(b.kind == .lineEnd)
        #expect(b.newVisible == "$$\nE=mc^2\n$$\n")
    }

    @Test("Latex Bracket Block Hold Until Closed")
    func latexBracketBlockHoldUntilClosed() {
        #expect(next("", "\\[\nax^2+bx+c=0").kind == .held)
        let b = next("", "\\[\nax^2+bx+c=0\n\\]\nそこで")
        #expect(b.kind == .lineEnd)
        #expect(b.newVisible == "\\[\nax^2+bx+c=0\n\\]\n")
    }

    @Test("Latex Bracket Single Line And Ambiguity")
    func latexBracketSingleLineAndAmbiguity() {
        let b = next("", "\\[a\\neq 0\\]\nつづき")
        #expect(b.kind == .lineEnd)
        #expect(b.newVisible == "\\[a\\neq 0\\]\n")
        #expect(next("", "\\[").kind == .held)
        #expect(next("", "\\").kind == .held)
    }


    @Test("Stream End Releases Holds")
    func streamEndReleasesHolds() {
        #expect(next("", "$$\nE=mc", streamEnd: true).newVisible == "$$\nE=mc")
        #expect(next("", "| A |", streamEnd: true).newVisible == "| A |")
        #expect(next("", "trailing par", profile: .ascii, streamEnd: true).newVisible == "trailing par")
    }


    @Test("Non Prefix Snaps")
    func nonPrefixSnaps() {
        let b = next("xyz", "abc def")
        #expect(b.kind == .snap)
        #expect(b.newVisible == "abc def")
    }

    @Test("Multi Line Catchup")
    func multiLineCatchup() {
        let line = "これはいちれつのぶん\n"   // 11 UTF-16 units
        let target = String(repeating: line, count: 160)   // backlog ~1760 > multiLineBacklog
        let b = next("", target)
        #expect(b.kind == .lineEnd)
        #expect(b.newVisible == String(repeating: line, count: 3))
    }

    @Test("Drain Converges Monotonically")
    func drainConvergesMonotonically() {
        let target = """
        # Title
        A paragraph with **bold** and `code` mixed in, plus a fairly long line of text.

        - Item one
        - Item two

        ```swift
        let x = 1
        let y = 2
        ```

        | A | B |
        |---|---|
        | 1 | 2 |

        > Closing quote
        """
        var visible = ""
        var steps = 0
        while visible != target {
            let b = next(visible, target, streamEnd: true)
            #expect(b.newVisible.count >= visible.count)
            #expect(b.kind != .held, "no hold is allowed at stream end (visible: \(visible.suffix(20)))")
            if b.newVisible == visible {
                Issue.record("no progress: \(visible.suffix(30))")
                break
            }
            visible = b.newVisible
            steps += 1
            if steps > 500 { Issue.record("did not converge within 500 steps"); break }
        }
        #expect(visible == target)
    }
}
