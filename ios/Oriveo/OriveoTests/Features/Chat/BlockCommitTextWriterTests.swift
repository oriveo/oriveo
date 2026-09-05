import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Oriveo

/// `BlockCommitTextWriter` appends canonically rendered blocks into the live text view.
///
/// Every step must leave the storage byte-for-byte identical to rendering the whole text in one
/// pass, and it may only ever append, so a committed prefix is never rewritten.
@Suite("Block commit text writer")
@MainActor
struct BlockCommitTextWriterTests {

    private func makeWriter() -> (BlockCommitTextWriter, UITextView) {
        let textView = UITextView()
        let writer = BlockCommitTextWriter()
        writer.textViewProvider = { textView }
        return (writer, textView)
    }

    private func assertStructurallyEqual(
        _ rawActual: NSAttributedString, _ rawExpected: NSAttributedString,
        _ context: String
    ) {
        let actual = fixed(rawActual)
        let expected = fixed(rawExpected)
        #expect(actual.string == expected.string, "strings differ at \(context): \(actual.string) vs \(expected.string)")
        guard actual.string == expected.string else { return }
        for i in 0..<actual.length {
            let a = normalized(actual.attributes(at: i, effectiveRange: nil))
            let b = normalized(expected.attributes(at: i, effectiveRange: nil))
            if !NSDictionary(dictionary: a).isEqual(to: b) {
                Issue.record("attributes differ at \(context) index \(i) (char: \((actual.string as NSString).substring(with: NSRange(location: i, length: 1))))")
                return
            }
        }
    }

    private func normalized(_ attrs: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var copy = attrs
        if let attachment = copy[.attachment] {
            let typeName = String(describing: type(of: attachment))
            copy[.attachment] = (typeName == "LatexAttachment" || typeName == "BlockMathPlaceholderAttachment")
                ? "BlockMath" : typeName
        }
        return copy
    }

    private func fixed(_ attr: NSAttributedString) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: attr)
        mutable.fixAttributes(in: NSRange(location: 0, length: mutable.length))
        return mutable
    }

    private func runSequence(_ tails: [String], context: String) {
        let (writer, textView) = makeWriter()
        for (step, tail) in tails.enumerated() {
            writer.applyTail(tail)
            let normalized = BlockCommitTextWriter.normalizedTailForRendering(tail)
            let expected = normalized.isEmpty
                ? NSAttributedString()
                : MarkdownAttributedStringRenderer.renderPreservingBoundaries(normalized)
            assertStructurallyEqual(
                NSAttributedString(attributedString: textView.textStorage),
                expected,
                "\(context) step\(step)"
            )
        }
    }


    @Test("Heading And Inline Increment")
    func headingAndInlineIncrement() {
        runSequence([
            "## Tit",
            "## Title",
            "## Title\n",
            "## Title\nBody ",
            "## Title\nBody **bold** ca",
            "## Title\nBody **bold** calm ending",
        ], context: "heading")
    }

    @Test("Blank Lines And Groups")
    func blankLinesAndGroups() {
        runSequence([
            "Para one",
            "Para one\n",
            "Para one\n\n",
            "Para one\n\nPara two begins",
            "Para one\n\nPara two begins and continues\nThird line\nFourth line unfinis",
        ], context: "blank")
    }

    @Test("Horizontal Rule Line")
    func horizontalRuleLine() {
        runSequence([
            "---\n",
            "---\nFollowing text",
        ], context: "hr")
    }

    @Test("Single Line Block Math Commits As Attachment")
    func singleLineBlockMathCommitsAsAttachment() {
        runSequence([
            "Formula:\n$$a_1 + a_2 = b$$\n",
            "Formula:\n$$a_1 + a_2 = b$$\nFollowing text",
        ], context: "blockmath-singleline")

        let (writer, textView) = makeWriter()
        writer.applyTail("$$x_9^2 + y_9^2$$\n")
        #expect(!textView.textStorage.string.contains("$$"), "a single-line block formula must not reach the screen literally")

        let (writer2, textView2) = makeWriter()
        writer2.applyTail("Change of base corollary:\n$$\\log_{a^m} b^n = \\frac{n}{m}\\log_a b$$")
        #expect(!textView2.textStorage.string.contains("$$"), "a closed single-line formula with no trailing newline must not reach the screen literally either")
        #expect(textView2.textStorage.string.contains("\u{FFFC}"), "it must render as an attachment")
    }

    @Test("Normalized Tail Single Line Block Math")
    func normalizedTailSingleLineBlockMath() {
        #expect(BlockCommitTextWriter.normalizedTailForRendering("$$x^2$$\n") == "$$x^2$$\n")
        #expect(BlockCommitTextWriter.normalizedTailForRendering("$$\n") == "$$\n")
        #expect(BlockCommitTextWriter.normalizedTailForRendering("Body $$\n") == "Body $$")
        #expect(BlockCommitTextWriter.normalizedTailForRendering("$$x^2$$") == "$$x^2$$\n")
        #expect(BlockCommitTextWriter.normalizedTailForRendering("Corollary:\n$$x^2$$") == "Corollary:\n$$x^2$$\n")
        #expect(BlockCommitTextWriter.normalizedTailForRendering("---") == "---\n")
    }

    @Test("Latex Bracket Block Commits As Attachment")
    func latexBracketBlockCommitsAsAttachment() {
        runSequence([
            "The general form is:\n\\[\nax_7^2+bx_7+c=0\n\\]\n",
            "The general form is:\n\\[\nax_7^2+bx_7+c=0\n\\]\nwhere",
        ], context: "blockmath-bracket")

        let (writer, textView) = makeWriter()
        writer.applyTail("\\[\na_8\\neq 0\n\\]\n")
        let shown = textView.textStorage.string
        #expect(!shown.contains("\\["), "a \\[ block must not reach the screen literally")
        #expect(shown.contains("\u{FFFC}"), "a \\[ block must render as an attachment, either a placeholder or the formula image")

        #expect(BlockCommitTextWriter.normalizedTailForRendering("\\[\nx\n\\]\n") == "\\[\nx\n\\]\n")
        #expect(BlockCommitTextWriter.normalizedTailForRendering("\\[x_a\\]\n") == "\\[x_a\\]\n")
    }

    @Test("Upgrade Block Math Placeholder In Place")
    func upgradeBlockMathPlaceholderInPlace() async throws {
        let latex = "u_{ip}^2 + v_{ip}^2 = 1"
        let (writer, textView) = makeWriter()
        writer.applyTail("Derivation:\n$$\(latex)$$\n")
        let before = textView.textStorage.string
        let color = UIColor(OriveoTheme.Palette.textPrimary)
        var tries = 0
        while LatexImageCache.cachedImage(latex: latex, fontSize: 20, textColor: color, inline: false) == nil,
              tries < 150 {
            try await Task.sleep(nanoseconds: 20_000_000)
            tries += 1
        }
        #expect(
            LatexImageCache.cachedImage(latex: latex, fontSize: 20, textColor: color, inline: false) != nil,
            "the background render should finish within the grace period"
        )

        let upgraded = MarkdownAttributedStringRenderer.upgradeBlockMathPlaceholders(
            in: textView.textStorage, latex: latex
        )
        #expect(upgraded, "on a cache hit the placeholder must be upgraded in place")
        #expect(textView.textStorage.string == before, "the upgrade may only change attributes, never characters")
        var hasLatexAttachment = false
        textView.textStorage.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: textView.textStorage.length)
        ) { value, _, _ in
            if value is LatexAttachment { hasLatexAttachment = true }
        }
        #expect(hasLatexAttachment, "after the upgrade the attachment must be the rendered formula")
    }

    @Test("Bullet Lines")
    func bulletLines() {
        runSequence([
            "- Item one ",
            "- Item one continued\n",
            "- Item one continued\n- Item two\n",
        ], context: "bullet")
    }

    @Test("Quote Lines")
    func quoteLines() {
        runSequence([
            "> Quote ",
            "> Quote body\nPlain line",
        ], context: "quote")
    }


    @Test("Non Prefix Rebuilds")
    func nonPrefixRebuilds() {
        let (writer, textView) = makeWriter()
        writer.applyTail("First paragraph")
        writer.applyTail("Completely different content")
        assertStructurallyEqual(
            NSAttributedString(attributedString: textView.textStorage),
            MarkdownAttributedStringRenderer.renderPreservingBoundaries("Completely different content"),
            "rebuild"
        )
        #expect(writer.lastCommittedTail == "Completely different content")
    }

    @Test("Harvest For Freeze")
    func harvestForFreeze() {
        let (writer, textView) = makeWriter()
        writer.applyTail("## Title\nBody text")
        let before = NSAttributedString(attributedString: textView.textStorage)
        let harvested = writer.harvestForFreeze()
        #expect(harvested.isEqual(to: before))
        #expect(textView.textStorage.length == 0)
        #expect(writer.lastCommittedTail == "")
        writer.applyTail("New tail")
        assertStructurallyEqual(
            NSAttributedString(attributedString: textView.textStorage),
            MarkdownAttributedStringRenderer.renderPreservingBoundaries("New tail"),
            "after-harvest"
        )
    }


    @Test("Fader Integration")
    func faderIntegration() {
        let (writer, textView) = makeWriter()
        let fader = ChunkFadeAnimator()
        fader.textStorageProvider = { textView.textStorage }
        fader.nowProvider = { 1000 }
        fader.isScrollingProvider = { false }
        fader.reduceMotionProvider = { false }
        writer.chunkFader = fader

        writer.applyTail("Hello world")
        #expect(fader.pendingChunks.count == 1)
        let color0 = textView.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        var alpha0: CGFloat = -1
        color0?.getRed(nil, green: nil, blue: nil, alpha: &alpha0)
        #expect(alpha0 == 0)

        writer.applyTail("Hello world, more")
        #expect(fader.pendingChunks.count == 2)
        let harvested = writer.harvestForFreeze()
        #expect(fader.pendingChunks.isEmpty)
        var alphaH: CGFloat = -1
        (harvested.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor)?
            .getRed(nil, green: nil, blue: nil, alpha: &alphaH)
        #expect(alphaH == 1)
    }
}
