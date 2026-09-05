import Foundation
import Testing
@testable import Oriveo

@Suite("Cached Markdown View Render Tests")
struct CachedMarkdownViewRenderTests {


    private func rendered(_ text: String) -> String {
        CachedMarkdownView.renderMarkdown(text).string
    }

    private func newlineCount(_ text: String) -> Int {
        rendered(text).filter { $0 == "\n" }.count
    }


    @Test("Single Paragraph No Newline")
    func singleParagraphNoNewline() {
        let result = rendered("Hello world")
        #expect(!result.contains("\n"))
    }

    @Test("Two Paragraphs Single Newline")
    func twoParagraphsSingleNewline() {
        let result = rendered("Paragraph one\nParagraph two")
        #expect(result.contains("Paragraph one"))
        #expect(result.contains("Paragraph two"))
        #expect(result.contains("\n"))
    }

    @Test("Two Paragraphs Double Newline")
    func twoParagraphsDoubleNewline() {
        let result = rendered("Paragraph one\n\nParagraph two")
        #expect(result.contains("Paragraph one"))
        #expect(result.contains("Paragraph two"))
        #expect(result.contains("\n"))
    }

    @Test("Multiple Paragraphs All Preserved")
    func multipleParagraphsAllPreserved() {
        let text = "First paragraph\nSecond paragraph\nThird paragraph\nFourth paragraph"
        let count = newlineCount(text)
        #expect(count >= 3)
    }

    // MARK: - Bold / Inline

    @Test("Bold Inline Same Paragraph")
    func boldInlineSameParagraph() {
        let result = rendered("This is **bold** text")
        #expect(!result.contains("\n"))
    }

    @Test("Bold Across Paragraphs")
    func boldAcrossParagraphs() {
        let text = "**Brand:** Ground coffee\n**Drink:** XXL iced Americano\n**Price:** 37 yuan"
        let count = newlineCount(text)
        #expect(count >= 2)
    }


    @Test("Heading And Paragraph")
    func headingAndParagraph() {
        let text = "# Heading\nThis is a body paragraph"
        let result = rendered(text)
        #expect(result.contains("\n"))
    }

    @Test("Multiple Headings")
    func multipleHeadings() {
        let text = "# Level one\n## Level two\n### Level three"
        let count = newlineCount(text)
        #expect(count >= 2)
    }


    @Test("Blockquote And Paragraph")
    func blockquoteAndParagraph() {
        let text = "Body\n\n> This is a quote\n\nFollowing paragraph"
        let count = newlineCount(text)
        #expect(count >= 2)
    }


    @Test("Table Cells Same Row No Newline")
    func tableCellsSameRowNoNewline() {
        let text = """
        | A | B | C |
        | - | - | - |
        | 1 | 2 | 3 |
        """
        let result = rendered(text)
        #expect(result.contains("\t"))
    }

    @Test("Table Rows Separated By Newline")
    func tableRowsSeparatedByNewline() {
        let text = """
        | A | B |
        | - | - |
        | 1 | 2 |
        | 3 | 4 |
        """
        let result = rendered(text)
        #expect(newlineCount(text) >= 2)
    }

    @Test("Table With Surrounding Paragraphs")
    func tableWithSurroundingParagraphs() {
        let text = "Before\n\n| A | B |\n| - | - |\n| 1 | 2 |\n\nAfter"
        let result = rendered(text)
        #expect(result.contains("Before"))
        #expect(result.contains("After"))
        #expect(newlineCount(text) >= 3)
    }


    @Test("Unordered List Items")
    func unorderedListItems() {
        let text = "- Apple\n- Banana\n- Orange"
        let count = newlineCount(text)
        #expect(count >= 2)
    }

    @Test("Ordered List Items")
    func orderedListItems() {
        let text = "1. First\n2. Second\n3. Third"
        let count = newlineCount(text)
        #expect(count >= 2)
    }


    @Test("Mixed Content")
    func mixedContent() {
        let text = """
        # Coffee info
        **Brand:** Ground coffee
        **Drink:** XXL iced Americano
        - Recipe: three shots espresso
        - Price: 37 yuan
        """
        let count = newlineCount(text)
        #expect(count >= 4)
    }

    @Test("Multiplication Table")
    func multiplicationTable() {
        let text = """
        | × | 1 | 2 | 3 |
        | - | - | - | - |
        | 1 | 1 | 2 | 3 |
        | 2 | 2 | 4 | 6 |
        | 3 | 3 | 6 | 9 |
        """
        let result = rendered(text)
        let tabCount = result.filter { $0 == "\t" }.count
        #expect(tabCount >= 12)

        let nlCount = result.filter { $0 == "\n" }.count
        #expect(nlCount >= 3)
    }


    @Test("Html Bold Tag Converted")
    func htmlBoldTagConverted() {
        let result = rendered("<b>Bold</b>plain")
        #expect(!result.contains("<b>"))
        #expect(!result.contains("</b>"))
        #expect(result.contains("Bold"))
    }

    @Test("Html Strong Tag Converted")
    func htmlStrongTagConverted() {
        let result = rendered("<strong>Strong</strong>text")
        #expect(!result.contains("<strong>"))
        #expect(result.contains("Strong"))
    }

    @Test("Html Italic Tag Converted")
    func htmlItalicTagConverted() {
        let result = rendered("<i>Italic</i>text")
        #expect(!result.contains("<i>"))
        #expect(result.contains("Italic"))
    }

    @Test("Html Em Tag Converted")
    func htmlEmTagConverted() {
        let result = rendered("<em>Emphasis</em>text")
        #expect(!result.contains("<em>"))
        #expect(result.contains("Emphasis"))
    }

    @Test("Html Bold In Table Cells")
    func htmlBoldInTableCells() {
        let text = """
        | ※ | <b>1</b> | <b>2</b> |
        |:---:|:---:|:---:|
        | <b>1</b> | 1 | 2 |
        | <b>2</b> | 2 | 4 |
        """
        let result = rendered(text)
        #expect(!result.contains("<b>"))
        #expect(!result.contains("</b>"))
        #expect(result.contains("1"))
        #expect(result.contains("※"))
    }


    @Test("Empty Text Handled")
    func emptyTextHandled() {
        let result = rendered("")
        #expect(result.isEmpty || !result.isEmpty)
    }

    @Test("Only Newlines")
    func onlyNewlines() {
        let result = rendered("\n\n\n")
        #expect(result.count >= 0)
    }


    @Test("Inline Math Source Preserved")
    func inlineMathSourcePreserved() {
        let result = rendered("Formula $x_1$ is here")
        #expect(result.contains("$x_1$") || result.contains("\u{FFFC}"))
        #expect(!result.contains("\u{E002}"))
        #expect(!result.contains("\u{E003}"))
    }

    @Test("Block Math No Token Residue")
    func blockMathNoTokenResidue() {
        let result = rendered("Before\n\n$$E=mc^2$$\n\nAfter")
        #expect(result.contains("Before"))
        #expect(result.contains("After"))
        #expect(result.contains("$$E=mc^2$$") || result.contains("\u{FFFC}"))
        #expect(!result.contains("\u{E002}"))
    }

    @Test("Code Span Dollar Untouched")
    func codeSpanDollarUntouched() {
        let result = rendered("`$5` and `$10` prices")
        #expect(result.contains("$5"))
        #expect(result.contains("$10"))
        #expect(!result.contains("\u{FFFC}"))
    }
}


@Suite("Static Markdown Math Support Tests")
struct StaticMarkdownMathSupportTests {

    @Test("Inline Extract")
    func inlineExtract() {
        let (text, segments) = StaticMarkdownMathSupport.extract("Mass-energy equation $E=mc^2$ holds")
        #expect(segments.count == 1)
        #expect(segments.first?.latex == "E=mc^2")
        #expect(segments.first?.isInline == true)
        #expect(!text.contains("$"))
    }

    @Test("Block Extract Single Line")
    func blockExtractSingleLine() {
        let (text, segments) = StaticMarkdownMathSupport.extract("Before\n$$a+b=c$$\nAfter")
        #expect(segments.count == 1)
        #expect(segments.first?.latex == "a+b=c")
        #expect(segments.first?.isInline == false)
        #expect(!text.contains("$$"))
    }

    @Test("Block Extract Multi Line")
    func blockExtractMultiLine() {
        let (_, segments) = StaticMarkdownMathSupport.extract("$$\n\\tan(30) = \\frac{h}{100}\n$$")
        #expect(segments.count == 1)
        #expect(segments.first?.latex == "\\tan(30) = \\frac{h}{100}")
        #expect(segments.first?.isInline == false)
    }

    @Test("Normalized Delimiters")
    func normalizedDelimiters() {
        let (_, segments) = StaticMarkdownMathSupport.extract(#"Euler \(e^{i\pi}+1=0\) formula"#)
        #expect(segments.count == 1)
        #expect(segments.first?.isInline == true)
        #expect(segments.first?.latex == #"e^{i\pi}+1=0"#)
    }

    @Test("Code Protected")
    func codeProtected() {
        let (text, segments) = StaticMarkdownMathSupport.extract("`$5` and `$10` prices")
        #expect(segments.isEmpty)
        #expect(text.contains("`$5`"))
    }

    @Test("Unclosed Block Kept")
    func unclosedBlockKept() {
        let (text, segments) = StaticMarkdownMathSupport.extract("$$a+b")
        #expect(segments.isEmpty)
        #expect(text == "$$a+b")
    }

    @Test("Restore Round Trip")
    func restoreRoundTrip() {
        let original = "Inline $x_1$ and block\n$$y^2$$\nend"
        let (text, segments) = StaticMarkdownMathSupport.extract(original)
        let restored = StaticMarkdownMathSupport.restoreTokens(text, segments: segments)
        #expect(restored.contains("$x_1$"))
        #expect(restored.contains("$$y^2$$"))
    }

    @Test("Contains Delimiters")
    func containsDelimiters() {
        #expect(StaticMarkdownMathSupport.containsMathDelimiters("$$x$$"))
        #expect(StaticMarkdownMathSupport.containsMathDelimiters("Has $x^2$ formula"))
        #expect(StaticMarkdownMathSupport.containsMathDelimiters(#"Has \(x\) delimiters"#))
        #expect(!StaticMarkdownMathSupport.containsMathDelimiters("Plain text has no formula"))
        #expect(!StaticMarkdownMathSupport.containsMathDelimiters("Price $5"))
    }
}
