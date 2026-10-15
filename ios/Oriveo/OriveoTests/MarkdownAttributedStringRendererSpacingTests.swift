import Foundation
import Testing
import UIKit
@testable import Oriveo

@Suite("Markdown Attributed String Renderer Spacing Tests")
struct MarkdownAttributedStringRendererSpacingTests {
    private func attachmentCount(in attributedString: NSAttributedString) -> Int {
        var count = 0
        attributedString.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: attributedString.length)
        ) { value, _, _ in
            if value != nil {
                count += 1
            }
        }
        return count
    }

    private func links(in attributedString: NSAttributedString) -> [URL] {
        var links: [URL] = []
        attributedString.enumerateAttribute(
            .link,
            in: NSRange(location: 0, length: attributedString.length)
        ) { value, _, _ in
            if let url = value as? URL { links.append(url) }
        }
        return links
    }

    /// On an iPad (screen 1032pt) with a chat column of about 632pt, the rule used to stretch to 960pt
    /// via `max(lineFrag, screenWidth - 72)` and run out of the column; its width must follow only
    /// the line fragment width the text container gives it.
    @Test("horizontal rule width follows the line fragment, not the screen")
    func horizontalRuleWidthFollowsLineFragment() throws {
        let rendered = MarkdownAttributedStringRenderer.render("above\n\n---\n\nbelow")
        var rule: NSTextAttachment?
        rendered.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: rendered.length)
        ) { value, _, stop in
            if let attachment = value as? NSTextAttachment {
                rule = attachment
                stop.pointee = true
            }
        }
        let attachment = try #require(rule)
        let bounds = attachment.attachmentBounds(
            for: nil,
            proposedLineFragment: CGRect(x: 0, y: 0, width: 300, height: 20),
            glyphPosition: .zero,
            characterIndex: 0
        )
        #expect(bounds.width == 300)
    }

    @Test("only HTTPS markdown links are interactive in UIKit and cached renderers")
    func unsafeMarkdownLinksArePlainText() {
        let markdown = "[safe](https://example.com) [plain](http://example.com) [script](javascript:alert)"
        let main = MarkdownAttributedStringRenderer.render(markdown)
        let cached = CachedMarkdownView.renderMarkdown(markdown)

        #expect(links(in: main).map(\.absoluteString) == ["https://example.com"])
        #expect(links(in: cached).map(\.absoluteString) == ["https://example.com"])
        #expect(main.string == "safe plain script")
        #expect(cached.string == "safe plain script")
    }

    @Test("raw HTML script remains inert text")
    func rawHTMLScriptIsInert() {
        let rendered = MarkdownAttributedStringRenderer.render("<script>alert('x')</script>")

        #expect(rendered.string == "<script>alert('x')</script>")
        #expect(links(in: rendered).isEmpty)
    }

    @Test("Horizontal Rule Between List And Paragraph")
    func horizontalRuleBetweenListAndParagraph() {
        let text = """
        🎓 Study tips:
        1. Understand the principle before writing code
        2. Manually simulate the execution a few times
        3. Add debug output and watch variables change
        ---
        Want a detailed walkthrough of an algorithm?
        """

        let result = MarkdownAttributedStringRenderer.render(text)

        #expect(
            !result.string.contains("\n\n")
        )
        #expect(attachmentCount(in: result) == 1)
    }



    @Test("Preserve Leading Newline")
    func preserveLeadingNewline() {
        let result = MarkdownAttributedStringRenderer.renderPreservingBoundaries("\npara2")
        #expect(result.string.hasPrefix("\n"))
        #expect(result.string == "\npara2")
    }

    @Test("Preserve Trailing Newline")
    func preserveTrailingNewline() {
        let result = MarkdownAttributedStringRenderer.renderPreservingBoundaries("para1\n")
        #expect(result.string.hasSuffix("\n"))
        #expect(result.string == "para1\n")
    }

    @Test("Preserve Double Newline Paragraph Break")
    func preserveDoubleNewlineParagraphBreak() {
        let result = MarkdownAttributedStringRenderer.renderPreservingBoundaries("\npara2\n")
        #expect(result.string == "\npara2\n")
    }

    @Test("Preserve Bare Newline Suffix")
    func preserveBareNewlineSuffix() {
        let result = MarkdownAttributedStringRenderer.renderPreservingBoundaries("\n\n")
        #expect(result.string == "\n\n")
    }

    @Test("Render Still Trims For Full Text Path")
    func renderStillTrimsForFullTextPath() {
        let result = MarkdownAttributedStringRenderer.render("\n\npara1\n\n")
        #expect(!result.string.hasPrefix("\n"))
        #expect(!result.string.hasSuffix("\n"))
        #expect(result.string == "para1")
    }

    @Test("Render Preserves Middle Double Newline")
    func renderPreservesMiddleDoubleNewline() {
        let result = MarkdownAttributedStringRenderer.render("para1\n\npara2")
        #expect(result.string.contains("\n\n"))
    }
}
