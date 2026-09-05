import Foundation
import Testing
import UIKit
@testable import Oriveo

/// The canonical rendering entry point used by block-level commits.
///
/// Three properties are pinned:
/// 1. rendering a single canonical line is identical to rendering that line as finished text;
/// 2. line classification (heading level, quote, plain) is shared by the chunker and the writer;
/// 3. **concatenation equivalence**: splitting a line into spans at the scanner's safe boundaries
///    and rendering the spans one by one produces exactly the same string and attribute runs as
///    rendering the whole line at once. That is what guarantees text appears in its final form while
///    streaming and that finalizing changes nothing visually.
@Suite("Canonical span rendering equivalence")
@MainActor
struct CanonicalSpanRenderTests {

    // MARK: - Property 1: a canonical line equals the finished render

    @Test("renderCanonicalLine matches the finished render for a single line")
    func canonicalLineMatchesFinalRender() {
        for line in [
            "# Heading level one",
            "## Level two **bold** heading",
            "### Heading level three",
            "> Quoted text with `code`",
            "- List item",
            "* Star bullet item",
            "Plain text **bold** and *italic* and `code` and ~~strikethrough~~",
            "[link](https://example.com) text",
            "A plain paragraph with no markers at all",
        ] {
            let canonical = MarkdownAttributedStringRenderer.renderCanonicalLine(line)
            let final = MarkdownAttributedStringRenderer.render(line)
            #expect(canonical.isEqual(to: final), "line: \(line)")
        }
    }

    @Test("a horizontal rule renders as an attachment; attachments are not comparable, so the structure is compared")
    func horizontalRuleCanonical() {
        let canonical = MarkdownAttributedStringRenderer.renderCanonicalLine("---")
        let final = MarkdownAttributedStringRenderer.render("---")
        // Both are a single attachment character (U+FFFC) with the same paragraph style.
        #expect(canonical.string == final.string)
        #expect(canonical.string == "\u{FFFC}")
        let cAttach = canonical.attribute(.attachment, at: 0, effectiveRange: nil)
        let fAttach = final.attribute(.attachment, at: 0, effectiveRange: nil)
        #expect(cAttach != nil && fAttach != nil)
        #expect(type(of: cAttach!) == type(of: fAttach!))
    }

    // MARK: - Property 1b: heading line heights are fixed and pixel-aligned

    @Test("heading line heights have equal minimum and maximum and are pixel-aligned, so baselines do not drift")
    func headingLineHeightPixelLock() {
        let scale = UIScreen.main.scale > 0 ? UIScreen.main.scale : 2.0
        let cases: [(String, Int, CGFloat)] = [
            ("# Heading One", 1, 16),   // (source line, level, expected paragraphSpacingBefore)
            ("## Heading Two", 2, 12),
            ("### Heading Three", 3, 8),
        ]
        var lineHeights: [CGFloat] = []
        for (line, level, spacingBefore) in cases {
            let rendered = MarkdownAttributedStringRenderer.renderCanonicalLine(line)
            let style = rendered.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            #expect(style != nil, "level \(level)")
            guard let style else { continue }
            #expect(style.minimumLineHeight > 0)
            #expect(style.minimumLineHeight == style.maximumLineHeight, "level \(level) min==max")
            let px = style.minimumLineHeight * scale
            #expect(abs(px - px.rounded()) < 0.001, "level \(level) lineHeight × scale must be a whole pixel count")
            #expect(style.paragraphSpacingBefore == spacingBefore, "level \(level) paragraph spacing before")
            lineHeights.append(style.minimumLineHeight)
        }
        // H1 > H2 >= H3, matching the font sizes.
        #expect(lineHeights.count == 3)
        if lineHeights.count == 3 {
            #expect(lineHeights[0] > lineHeights[1])
            #expect(lineHeights[1] >= lineHeights[2])
        }
    }

    // MARK: - Property 2: line classification

    @Test("canonicalLineKind classifies lines, including a marker-only prefix arriving early")
    func lineKindDetection() {
        #expect(MarkdownAttributedStringRenderer.canonicalLineKind("# Heading") == .heading(level: 1))
        #expect(MarkdownAttributedStringRenderer.canonicalLineKind("## ") == .heading(level: 2))
        #expect(MarkdownAttributedStringRenderer.canonicalLineKind("###### x") == .heading(level: 6))
        #expect(MarkdownAttributedStringRenderer.canonicalLineKind("####### x") == .plain)   // seven hashes is not a heading
        #expect(MarkdownAttributedStringRenderer.canonicalLineKind("#NoSpace") == .plain)
        #expect(MarkdownAttributedStringRenderer.canonicalLineKind("> Quote") == .quote)
        #expect(MarkdownAttributedStringRenderer.canonicalLineKind(">NoSpace") == .plain)
        #expect(MarkdownAttributedStringRenderer.canonicalLineKind("- List") == .plain)      // lists stay plain; bullets are preprocessed
        #expect(MarkdownAttributedStringRenderer.canonicalLineKind("Body text") == .plain)
    }

    // MARK: - Property 3: concatenation equivalence

    /// Splits the line into two spans at the given UTF-16 boundary, renders each span, concatenates
    /// them and compares the result with rendering the whole line at once.
    private func assertConcatEquivalence(_ line: String, splitAt utf16Boundary: Int) {
        let ns = line as NSString
        let span1 = ns.substring(to: utf16Boundary)
        let span2 = ns.substring(from: utf16Boundary)
        let kind = MarkdownAttributedStringRenderer.canonicalLineKind(line)

        let concat = NSMutableAttributedString()
        concat.append(MarkdownAttributedStringRenderer.renderCommittedSpan(kind: kind, span: span1, isLineStart: true))
        concat.append(MarkdownAttributedStringRenderer.renderCommittedSpan(kind: kind, span: span2, isLineStart: false))

        let whole = MarkdownAttributedStringRenderer.renderCanonicalLine(line)
        #expect(
            concat.isEqual(to: whole),
            "line: \(line) | split: \(utf16Boundary) | concat: \(concat.string) | whole: \(whole.string)"
        )
    }

    @Test("plain line: splitting at the safe boundary before a closed bold span is equivalent")
    func plainSpanConcat() {
        let line = "Prefix text **bold content** suffix"
        assertConcatEquivalence(line, splitAt: ("Prefix text " as NSString).length)
    }

    @Test("heading line: the leading marker is stripped and later spans keep the same style")
    func headingSpanConcat() {
        let line = "## Heading start **emphasis** end"
        assertConcatEquivalence(line, splitAt: ("## Heading start " as NSString).length)
    }

    @Test("quote line: the leading marker is stripped and later spans continue")
    func quoteSpanConcat() {
        let line = "> First quoted part then the second part"
        assertConcatEquivalence(line, splitAt: ("> First quoted part " as NSString).length)
    }

    @Test("bullet line: the hyphen becomes a bullet only in the first span")
    func bulletSpanConcat() {
        let line = "- Item content then more content"
        assertConcatEquivalence(line, splitAt: ("- Item content " as NSString).length)
    }

    @Test("plain CJK text is equivalent when split at any position")
    func cjkArbitrarySplit() {
        let line = "これはただのにほんごのぶんです"
        for boundary in [1, 3, 7, ( line as NSString).length - 1] {
            assertConcatEquivalence(line, splitAt: boundary)
        }
    }

    @Test("splitting at any scanner boundary is always equivalent")
    func scannerBoundarySplitsAreEquivalent() {
        // No `$` here: inline math renders asynchronously through the image cache, so two calls in
        // one test can hit different cache states and the comparison would be flaky.
        for line in [
            "Text `code span` then **bold** end",
            "Body text [link](https://e.co) and ~~strikethrough~~ end",
            "## Heading with `code` and *italic*",
        ] {
            let ns = line as NSString
            // Chunker contract: a span at the start of a line always contains the complete
            // block-level marker, so split points inside the marker are skipped. A split exactly at
            // the marker length is valid: the first span is only the marker and renders to nothing.
            let markerLen = blockMarkerUTF16Length(line)
            for candidate in stride(from: max(1, markerLen), to: ns.length, by: 1) {
                let prefix = ns.substring(to: candidate)
                // Only split points that are themselves safe boundaries are exercised, because those
                // are the only points the chunker commits at. The scanner works on the line content
                // after the block-level marker has been stripped.
                let scannerInput = (prefix as NSString).substring(from: min(markerLen, candidate))
                guard StreamingInlineSpanScanner.safeBoundary(in: scannerInput) == (scannerInput as NSString).length
                else { continue }
                assertConcatEquivalence(line, splitAt: candidate)
            }
        }
    }

    /// UTF-16 length of the leading block-level marker: heading hashes plus a space, a quote marker
    /// plus a space, or zero for a plain line.
    private func blockMarkerUTF16Length(_ line: String) -> Int {
        switch MarkdownAttributedStringRenderer.canonicalLineKind(line) {
        case .heading:
            let ns = line as NSString
            var i = 0
            while i < ns.length, ns.character(at: i) == 0x23 { i += 1 }   // #
            while i < ns.length, ns.character(at: i) == 0x20 || ns.character(at: i) == 0x09 { i += 1 }
            return i
        case .quote:
            return 2
        case .plain:
            return 0
        }
    }
}
