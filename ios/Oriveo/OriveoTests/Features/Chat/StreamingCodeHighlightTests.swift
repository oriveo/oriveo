import Testing
import UIKit
@testable import Oriveo

/// Per-line highlighting while code streams, and handing the on-screen result over when the fence
/// closes.
///
/// This is what stops "streamed code stays white and then the whole block flashes from white to
/// coloured the moment the fence closes":
/// 1. a line is coloured in the same tick its trailing newline arrives, and the per-line result is
///    identical to highlighting the finished block in one pass, because both share the same rules;
/// 2. when the fence closes, the already-coloured on-screen result is harvested so the frozen card's
///    first frame is never white;
/// 3. the card's asynchronous path has a synchronous fast path on a cache hit, so scrolling back
///    through history no longer shows plain text that snaps to colour.
@MainActor
@Suite("Streaming Code Highlight Tests")
struct StreamingCodeHighlightTests {

    private var keywordColor: UIColor { MarkdownCodeBlockPalette.keywordUIColor }
    private var commentColor: UIColor { MarkdownCodeBlockPalette.commentUIColor }
    private var baseColor: UIColor { MarkdownCodeBlockPalette.foregroundUIColor }

    private func fgColor(_ attr: NSAttributedString, at location: Int) -> UIColor? {
        guard location < attr.length else { return nil }
        return attr.attribute(.foregroundColor, at: location, effectiveRange: nil) as? UIColor
    }


    @Test("Line Highlight Matches Full Highlight")
    func lineHighlightMatchesFullHighlight() {
        let code = """
        let total = 42
        // sum the values
        func add(a: Int, b: Int) -> Int {
            return a + b
        }
        print("done")
        """
        let full = SyntaxHighlighter.highlightUncached(code, language: "swift", baseColor: baseColor)
        let ns = code as NSString
        var open = false
        var lineStart = 0
        for line in code.components(separatedBy: "\n") {
            let lineRange = NSRange(location: lineStart, length: (line as NSString).length)
            let perLine = AssistantStreamingCodeRenderer.highlightLine(
                line, language: "swift", blockCommentOpen: &open
            )
            let fullSlice = full.attributedSubstring(from: lineRange)
            #expect(perLine.isEqual(to: fullSlice), "line \(ns.substring(with: lineRange)) differs from the full-pass highlight")
            lineStart = lineRange.location + lineRange.length + 1
        }
        #expect(open == false)
    }


    @Test("Completed Lines Colorize Immediately")
    func completedLinesColorizeImmediately() {
        let renderer = AssistantStreamingCodeRenderer()
        renderer.update(language: "swift", code: "let x = 1\nprint(x")

        let rendered = renderer._testAttributedCode
        #expect(fgColor(rendered, at: 0) == keywordColor)
        let tailStart = ("let x = 1\n" as NSString).length
        #expect(fgColor(rendered, at: tailStart) == baseColor)
    }


    @Test("Block Comment Spans Lines")
    func blockCommentSpansLines() {
        let renderer = AssistantStreamingCodeRenderer()
        renderer.update(language: "swift", code: "/* start\nmiddle line\nend */\nlet x = 1\n")

        let rendered = renderer._testAttributedCode
        let ns = rendered.string as NSString
        let middleLoc = ns.range(of: "middle").location
        #expect(fgColor(rendered, at: middleLoc) == commentColor)
        let letLoc = ns.range(of: "let").location
        #expect(fgColor(rendered, at: letLoc) == keywordColor)
    }


    @Test("Harvest Matches Final Highlight")
    func harvestMatchesFinalHighlight() {
        let code = """
        func greet(name: String) -> String {
            let message = "hello"
            return message
        }
        """
        let renderer = AssistantStreamingCodeRenderer()
        renderer.update(language: "swift", code: code)

        let harvested = renderer.harvestAttributedCodeForHandoff(fullContent: code)
        let final = SyntaxHighlighter.highlightUncached(code, language: "swift", baseColor: baseColor)
        #expect(harvested != nil)
        #expect(harvested?.isEqual(to: final) == true,
                "the handed-over result differs from the final full highlight, so the handoff still changes colours")
        if let harvested {
            let ns = harvested.string as NSString
            let returnLoc = ns.range(of: "return").location
            #expect(fgColor(harvested, at: returnLoc) == keywordColor)
        }
    }

    @Test("Harvest Completes Unrevealed Tail On Big Step Close")
    func harvestCompletesUnrevealedTailOnBigStepClose() {
        let fullCode = """
        func greet(name: String) -> String {
            let message = "hello"
            return message
        }
        """
        let shown = String(fullCode.prefix(48))
        let renderer = AssistantStreamingCodeRenderer()
        renderer.update(language: "swift", code: shown)
        #expect(renderer.lastRenderedCode == shown)

        let harvested = renderer.harvestAttributedCodeForHandoff(fullContent: fullCode)
        let final = SyntaxHighlighter.highlightUncached(fullCode, language: "swift", baseColor: baseColor)
        #expect(harvested != nil)
        #expect(harvested?.string == fullCode, "after catching up, the handed-over result must be the complete content")
        #expect(harvested?.isEqual(to: final) == true,
                "the highlight produced while catching up must match the final full pass, so the handoff changes no colours")

        let renderer2 = AssistantStreamingCodeRenderer()
        renderer2.update(language: "swift", code: "totally different content")
        #expect(renderer2.harvestAttributedCodeForHandoff(fullContent: fullCode) == nil)
    }


    @Test("Card Uses Cached Highlight Synchronously")
    func cardUsesCachedHighlightSynchronously() {
        let unique = UUID().uuidString
        let code = (0 ..< 25).map { "let value\($0) = \($0) // \(unique)" }.joined(separator: "\n")
        _ = SyntaxHighlighter.highlight(code, language: "swift", baseColor: baseColor)

        let card = UIKitCodeBlockCard(
            language: "swift",
            content: code,
            parentViewController: nil,
            highlightTransition: false
        )
        let rendered = card._testCodeAttributedText
        #expect(rendered != nil)
        #expect(fgColor(rendered!, at: 0) == keywordColor, "a cache hit must render synchronously; the first frame must not be plain")
    }


    @Test("Card Handoff Shows Colored First Frame")
    func cardHandoffShowsColoredFirstFrame() {
        let unique = UUID().uuidString
        let code = (0 ..< 25).map { "let item\($0) = \($0) // \(unique)" }.joined(separator: "\n")
        let renderer = AssistantStreamingCodeRenderer()
        renderer.update(language: "swift", code: code)
        let harvested = renderer.harvestAttributedCodeForHandoff(fullContent: code)
        #expect(harvested != nil)

        let card = UIKitCodeBlockCard(
            language: "swift",
            content: code,
            parentViewController: nil,
            highlightTransition: false,
            initialAttributedText: harvested
        )
        let rendered = card._testCodeAttributedText
        #expect(rendered != nil)
        #expect(fgColor(rendered!, at: 0) == keywordColor, "the handed-over result must be the first frame instead of falling back to plain")
    }


    @Test("Title Plus Code Commit Enters Instantly")
    func titlePlusCodeCommitEntersInstantly() {
        let bodyStack = UIStackView()
        let anchor = UIView()
        bodyStack.addArrangedSubview(anchor)
        let cellTextView = UIView()
        let parentVC = UIViewController()
        let renderer = AssistantStaticBodyRenderer(
            bodyStack: bodyStack,
            textView: cellTextView
        )
        renderer.setParentViewController(parentVC)

        let code = "let x = 1"
        let titleHarvest = MarkdownAttributedStringRenderer.render("### Title")
        let codeHarvest = SyntaxHighlighter.highlightUncached(code, language: "swift", baseColor: baseColor)
        renderer.appendFrozenViews(
            newSegments: [
                StreamingSegmentParser.Segment(kind: .text, content: "### Title"),
                StreamingSegmentParser.Segment(kind: .codeBlock(language: "swift"), content: code),
            ],
            harvestedFirstText: titleHarvest,
            harvestedCode: (content: code, attributed: codeHarvest)
        )

        let frozen = bodyStack.arrangedSubviews.filter { $0 !== anchor }
        #expect(frozen.count == 2)
        for view in frozen {
            #expect(view.alpha == 1, "a segment already on screen must appear at its final state; fading from alpha 0 shows the background first and then the content")
            #expect(view.transform == .identity)
            #expect(view.layer.animationKeys() == nil, "an instant entrance must leave no animation running")
            #expect(renderer._testInstantViews.contains(ObjectIdentifier(view)),
                    "a segment that consumed a harvest must be accounted as an instant entrance")
        }
        let card = frozen.compactMap { $0 as? UIKitCodeBlockCard }.first
        #expect(card != nil)
        if let rendered = card?._testCodeAttributedText {
            #expect(fgColor(rendered, at: 0) == keywordColor, "the handed-over result must be the card's first frame instead of falling back to plain")
        }
    }

    @Test("Unseen Segments Still Enter With Spring")
    func unseenSegmentsStillEnterWithSpring() {
        let bodyStack = UIStackView()
        let anchor = UIView()
        bodyStack.addArrangedSubview(anchor)
        let cellTextView = UIView()
        let parentVC = UIViewController()
        let renderer = AssistantStaticBodyRenderer(
            bodyStack: bodyStack,
            textView: cellTextView
        )
        renderer.setParentViewController(parentVC)

        renderer.appendFrozenViews(newSegments: [
            StreamingSegmentParser.Segment(kind: .text, content: "new paragraph"),
        ])

        let view = bodyStack.arrangedSubviews.first { $0 !== anchor }
        #expect(view != nil)
        #expect(view.map { renderer._testInstantViews.contains(ObjectIdentifier($0)) } == false,
                "a segment that was not on screen must not be accounted as instant; it fades in")
    }

    @Test("Streaming Container Shadow Matches Frozen Card")
    func streamingContainerShadowMatchesFrozenCard() {
        let renderer = AssistantStreamingCodeRenderer()
        let card = UIKitCodeBlockCard(
            language: "swift",
            content: "let x = 1",
            parentViewController: nil
        )
        #expect(renderer.view.layer.shadowOpacity == card.layer.shadowOpacity)
        #expect(renderer.view.layer.shadowRadius == card.layer.shadowRadius)
        #expect(renderer.view.layer.shadowOffset == card.layer.shadowOffset)
        #expect(renderer.view.clipsToBounds == false, "clipping on the outer view would cut off the shadow")
    }


    @Test("Card Falls Back To Plain On Handoff Mismatch")
    func cardFallsBackToPlainOnHandoffMismatch() {
        let unique = UUID().uuidString
        let code = (0 ..< 25).map { "let mis\($0) = \($0) // \(unique)" }.joined(separator: "\n")
        let bogus = NSAttributedString(string: "totally unrelated content")

        let card = UIKitCodeBlockCard(
            language: "swift",
            content: code,
            parentViewController: nil,
            highlightTransition: false,
            initialAttributedText: bogus
        )
        let rendered = card._testCodeAttributedText
        #expect(rendered?.string.hasPrefix("let mis0") == true, "on a mismatch the real code must be shown, unhighlighted")
        #expect(fgColor(rendered!, at: 0) == baseColor)
    }
}
