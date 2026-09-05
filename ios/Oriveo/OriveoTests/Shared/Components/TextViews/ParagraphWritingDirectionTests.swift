import Foundation
import UIKit
import Testing
@testable import Oriveo

@Suite("ParagraphWritingDirection")
struct ParagraphWritingDirectionTests {

    @Test("Latin And CJKResolve Left To Right")
    func latinAndCJKResolveLeftToRight() {
        #expect(ParagraphWritingDirection.firstStrongDirection(in: "Hello world") == .leftToRight)
        #expect(ParagraphWritingDirection.firstStrongDirection(in: "にほんごのぶん L") == .leftToRight)
        #expect(ParagraphWritingDirection.firstStrongDirection(in: "  \"123. \" Hello") == .leftToRight)
    }

    @Test("Persian And Arabic And Hebrew Resolve Right To Left")
    func persianAndArabicAndHebrewResolveRightToLeft() {
        #expect(ParagraphWritingDirection.firstStrongDirection(in: "سلام دنیا") == .rightToLeft)
        #expect(ParagraphWritingDirection.firstStrongDirection(in: "مرحبا بالعالم") == .rightToLeft)
        #expect(ParagraphWritingDirection.firstStrongDirection(in: "שלום עולם") == .rightToLeft)
        #expect(ParagraphWritingDirection.firstStrongDirection(in: "1. سلام") == .rightToLeft)
        #expect(ParagraphWritingDirection.firstStrongDirection(in: "سلام Hello") == .rightToLeft)
    }

    @Test("Neutral Only Paragraph Stays Natural")
    func neutralOnlyParagraphStaysNatural() {
        #expect(ParagraphWritingDirection.firstStrongDirection(in: "12345 -- 67.89") == nil)
        #expect(ParagraphWritingDirection.firstStrongDirection(in: "   ") == nil)
        #expect(ParagraphWritingDirection.firstStrongDirection(in: "") == nil)

        let base = NSParagraphStyle.default
        #expect(ParagraphWritingDirection.style(base, for: "12345") === base)
    }

    @Test("Mixed Document Resolves Per Paragraph")
    func mixedDocumentResolvesPerParagraph() {
        let text = "Hello world\nسلام دنیا\n12345\nשלום עולם"
        let string = NSMutableAttributedString(
            string: text,
            attributes: [.paragraphStyle: NSParagraphStyle.default]
        )
        ParagraphWritingDirection.applyParagraphDirections(to: string)

        let ns = text as NSString
        func direction(ofParagraphStartingWith prefix: String) -> NSWritingDirection? {
            let location = ns.range(of: prefix).location
            guard location != NSNotFound else {
                Issue.record("fixture paragraph not found: \(prefix)")
                return nil
            }
            let style = string.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
            return style?.baseWritingDirection
        }

        #expect(direction(ofParagraphStartingWith: "Hello") == .leftToRight)
        #expect(direction(ofParagraphStartingWith: "سلام") == .rightToLeft)
        #expect(direction(ofParagraphStartingWith: "12345") == .natural)
        #expect(direction(ofParagraphStartingWith: "שלום") == .rightToLeft)
    }

    @Test("All Runs Inside One Paragraph Share Direction")
    func allRunsInsideOneParagraphShareDirection() {
        let text = "سلام bold دنیا"
        let string = NSMutableAttributedString(
            string: text,
            attributes: [.paragraphStyle: NSParagraphStyle.default]
        )
        let ns = text as NSString
        string.addAttributes(
            [.font: UIFont.boldSystemFont(ofSize: 17), .paragraphStyle: NSParagraphStyle.default],
            range: ns.range(of: "bold")
        )
        ParagraphWritingDirection.applyParagraphDirections(to: string)

        var sawNonRTL = false
        string.enumerateAttribute(
            .paragraphStyle,
            in: NSRange(location: 0, length: string.length),
            options: []
        ) { value, _, _ in
            if (value as? NSParagraphStyle)?.baseWritingDirection != .rightToLeft {
                sawNonRTL = true
            }
        }
        #expect(sawNonRTL == false)
    }
}

@Suite("MarkdownRendererWritingDirection")
struct MarkdownRendererWritingDirectionTests {

    private func direction(of rendered: NSAttributedString, at location: Int) -> NSWritingDirection? {
        let style = rendered.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
        return style?.baseWritingDirection
    }

    @Test("Plain Lines Get Explicit Direction")
    func plainLinesGetExplicitDirection() {
        let ltr = MarkdownAttributedStringRenderer.render("Hello **world**")
        #expect(direction(of: ltr, at: 0) == .leftToRight)

        let rtl = MarkdownAttributedStringRenderer.render("سلام **دنیا**")
        #expect(direction(of: rtl, at: 0) == .rightToLeft)
        var sawNonRTL = false
        rtl.enumerateAttribute(
            .paragraphStyle,
            in: NSRange(location: 0, length: rtl.length),
            options: []
        ) { value, _, _ in
            if (value as? NSParagraphStyle)?.baseWritingDirection != .rightToLeft {
                sawNonRTL = true
            }
        }
        #expect(sawNonRTL == false)
    }

    @Test("Heading And Quote Get Explicit Direction")
    func headingAndQuoteGetExplicitDirection() {
        let heading = MarkdownAttributedStringRenderer.render("## سلام دنیا")
        #expect(direction(of: heading, at: 0) == .rightToLeft)

        let quote = MarkdownAttributedStringRenderer.render("> שלום עולם")
        #expect(direction(of: quote, at: 0) == .rightToLeft)

        let ltrHeading = MarkdownAttributedStringRenderer.render("# Release notes")
        #expect(direction(of: ltrHeading, at: 0) == .leftToRight)
    }

    @Test("Mixed Message Resolves Per Paragraph")
    func mixedMessageResolvesPerParagraph() {
        let rendered = MarkdownAttributedStringRenderer.render("Hello world\n\nسلام دنیا")
        let ns = rendered.string as NSString
        let ltrLocation = ns.range(of: "Hello").location
        let rtlLocation = ns.range(of: "سلام").location
        #expect(ltrLocation != NSNotFound)
        #expect(rtlLocation != NSNotFound)
        #expect(direction(of: rendered, at: ltrLocation) == .leftToRight)
        #expect(direction(of: rendered, at: rtlLocation) == .rightToLeft)
    }
}
