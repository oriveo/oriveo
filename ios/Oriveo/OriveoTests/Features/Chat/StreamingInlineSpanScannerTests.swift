import Foundation
import Testing
@testable import Oriveo

/// Inline safety-boundary scanner used by the block-commit renderer.
///
/// Contract: `safeBoundary(in:)` returns the largest UTF-16 offset in a line such that the prefix
/// before it contains no unclosed inline opener. Committing the prefix first and the remainder
/// later must therefore produce the same result as rendering the whole line at once
/// (`CanonicalSpanRenderTests` pins that concatenation equivalence; this suite pins the boundary
/// position itself).
///
/// Input contract: `line` is the line content *after* the block-level leading marker has been
/// stripped (`## `, `> `, `- ` are removed by the chunker when it classifies the line) and never
/// contains a newline.
///
/// The scanner is deliberately conservative: a trailing character that could still become a marker
/// (`*`, `~`, `$` and friends, with the next character unknown) counts as a potential opener and
/// the boundary stops before it. Holding one beat longer is cheaper than committing text that then
/// has to be rewritten.
@Suite("Streaming Inline Span Scanner Tests")
struct StreamingInlineSpanScannerTests {

    private func boundary(_ line: String) -> Int {
        StreamingInlineSpanScanner.safeBoundary(in: line)
    }

    private func utf16Len(_ s: String) -> Int { (s as NSString).length }


    @Test("Plain Text Fully Safe")
    func plainTextFullySafe() {
        for line in ["hello world", "あいうえ English おか", "", "あい 123 うえお，。！"] {
            #expect(boundary(line) == utf16Len(line))
        }
    }

    @Test("Closed Spans Fully Safe")
    func closedSpansFullySafe() {
        for line in [
            "a **bold** c",
            "a *italic* b",
            "use `let x = 1` here",
            "a ~~strike~~ b",
            "see [title](https://e.co) end",
            "inline $x^2$ done",
            "あい**うえ**おか",
            "mix **b** and *i* and `c` ok",
        ] {
            #expect(boundary(line) == utf16Len(line), "line: \(line)")
        }
    }


    @Test("Unclosed Bold Holds At Opener")
    func unclosedBoldHoldsAtOpener() {
        #expect(boundary("a **b") == 2)          // "a " is committable
        #expect(boundary("あい**うえ") == 2)      // the two CJK characters are 2 UTF-16 units
        #expect(boundary("**あいうえお") == 0)
    }

    @Test("Unclosed Italic Holds At Star")
    func unclosedItalicHoldsAtStar() {
        #expect(boundary("mul 3 * 4") == 6)
        #expect(boundary("あいう*") == 3)
    }

    @Test("Unclosed Code Holds At Backtick")
    func unclosedCodeHoldsAtBacktick() {
        #expect(boundary("start `let x") == 6)
    }

    @Test("Strike Semantics")
    func strikeSemantics() {
        #expect(boundary("a ~~s") == 2)
        #expect(boundary("a ~ b") == utf16Len("a ~ b"))
        #expect(boundary("ab~") == 2)
    }

    @Test("Link Semantics")
    func linkSemantics() {
        #expect(boundary("see [titl") == 4)
        #expect(boundary("[t](ur") == 0)
        #expect(boundary("[a]b](u) z") == utf16Len("[a]b](u) z"))
    }

    @Test("Math Semantics")
    func mathSemantics() {
        #expect(boundary("cost $5 million") == 5)
        #expect(boundary("price $$5") == utf16Len("price $$5"))
    }


    @Test("Markers Inside Closed Code Are Literal")
    func markersInsideClosedCodeAreLiteral() {
        for line in ["`a*b` c", "`x ~~y` z", "`$var` ok"] {
            #expect(boundary(line) == utf16Len(line), "line: \(line)")
        }
    }


    @Test("Boundary Follows Latest Opener")
    func boundaryFollowsLatestOpener() {
        let line = "a **b** then `code"
        #expect(boundary(line) == utf16Len("a **b** then "))
    }


    @Test("Italic Closer Needs Non Star Follower")
    func italicCloserNeedsNonStarFollower() {
        #expect(boundary("*a**") == 0)
        #expect(boundary("**a*** tail") == 5)
    }
}
