import Foundation
import Testing
import UIKit
@testable import Oriveo

@MainActor
@Suite("Chat Passive Text View Source Text Tests")
struct ChatPassiveTextViewSourceTextTests {

    private func inlineMath(_ latex: String) -> NSAttributedString {
        NSAttributedString(
            attachment: LatexAttachment(image: UIImage(), font: .systemFont(ofSize: 17), isInline: true, latex: latex)
        )
    }

    @Test("Plain Text Unchanged")
    func plainTextUnchanged() {
        let attr = NSAttributedString(string: "hello world")
        let result = ChatPassiveTextView.sourceText(in: attr, range: NSRange(location: 0, length: attr.length))
        #expect(result == "hello world")
    }

    @Test("Inline Math Restored")
    func inlineMathRestored() {
        let attr = NSMutableAttributedString(string: "Mass-energy equation ")
        attr.append(inlineMath("E=mc^2"))
        attr.append(NSAttributedString(string: " holds"))
        let result = ChatPassiveTextView.sourceText(in: attr, range: NSRange(location: 0, length: attr.length))
        #expect(result == "Mass-energy equation $E=mc^2$ holds")
    }

    @Test("Block Math Restored")
    func blockMathRestored() {
        let attr = NSMutableAttributedString(string: "Before\n")
        attr.append(NSAttributedString(
            attachment: LatexAttachment(image: UIImage(), font: .systemFont(ofSize: 18), isInline: false, latex: "a+b=c")
        ))
        attr.append(NSAttributedString(string: "\nAfter"))
        let result = ChatPassiveTextView.sourceText(in: attr, range: NSRange(location: 0, length: attr.length))
        #expect(result == "Before\n$$a+b=c$$\nAfter")
    }

    @Test("Placeholder Restored")
    func placeholderRestored() {
        let attr = NSAttributedString(attachment: BlockMathPlaceholderAttachment(height: 40, latex: "x^2"))
        let result = ChatPassiveTextView.sourceText(in: attr, range: NSRange(location: 0, length: attr.length))
        #expect(result == "$$x^2$$")
    }

    @Test("Unknown Attachment Dropped")
    func unknownAttachmentDropped() {
        let attr = NSMutableAttributedString(string: "Above")
        attr.append(NSAttributedString(attachment: NSTextAttachment()))
        attr.append(NSAttributedString(string: "Below"))
        let result = ChatPassiveTextView.sourceText(in: attr, range: NSRange(location: 0, length: attr.length))
        #expect(result == "AboveBelow")
    }

    @Test("Partial Range")
    func partialRange() {
        let attr = NSMutableAttributedString(string: "AB")
        attr.append(inlineMath("x"))
        attr.append(NSAttributedString(string: "CD"))
        let result = ChatPassiveTextView.sourceText(in: attr, range: NSRange(location: 1, length: 3))
        #expect(result == "B$x$C")
    }

    @Test("Invalid Range")
    func invalidRange() {
        let attr = NSAttributedString(string: "abc")
        #expect(ChatPassiveTextView.sourceText(in: attr, range: NSRange(location: 0, length: 0)).isEmpty)
        #expect(ChatPassiveTextView.sourceText(in: attr, range: NSRange(location: 2, length: 5)).isEmpty)
    }
}
