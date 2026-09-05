import Testing
import UIKit
@testable import Oriveo

/// Finalizing an answer must reuse the frozen views built while it was streaming.
///
/// The common prefix of segments keeps its view instances, only the newly appended tail creates new
/// views, and views beyond the new segment list are removed. Rebuilding a code card at finalize
/// would re-run the asynchronous highlight and flash the block from plain back to coloured.
@Suite("AssistantStaticBodyRenderer - finalize reuse frozen views (fix 3A)")
@MainActor
struct AssistantStaticBodyRendererReuseFrozenViewsTests {


    @Test("Flattened Final Segments Collects All")
    func flattenedFinalSegmentsCollectsAll() {
        let text = "leading paragraph\n\n```swift\nlet x = 1\n```\n\ntrailing paragraph"
        let segments = AssistantStaticBodyRenderer.flattenedFinalSegments(forText: text)
        #expect(segments.count >= 2)
        #expect(segments.contains { seg in
            if case .codeBlock = seg.kind { return seg.content == "let x = 1" }
            return false
        })
    }

    @Test("Flattened Final Segments Unclosed Fence Stays Code")
    func flattenedFinalSegmentsUnclosedFenceStaysCode() {
        let text = "intro\n```sql\nSELECT 1;\n| a | b |\n|---|---|\n"
        let segments = AssistantStaticBodyRenderer.flattenedFinalSegments(forText: text)
        #expect(segments.count == 2)
        guard segments.count == 2,
              case .text = segments[0].kind,
              case .codeBlock(let lang) = segments[1].kind else {
            Issue.record("expected segments [text, codeBlock]")
            return
        }
        #expect(segments[0].content == "intro")
        #expect(lang == "sql")
        #expect(segments[1].content == "SELECT 1;\n| a | b |\n|---|---|")
    }


    @Test("Longest Common Prefix Full Match")
    func longestCommonPrefixFullMatch() {
        let a = [
            StreamingSegmentParser.Segment(kind: .text, content: "A"),
            StreamingSegmentParser.Segment(kind: .codeBlock(language: "swift"), content: "let x = 1"),
        ]
        let b = a
        #expect(AssistantStaticBodyRenderer.longestCommonPrefixCount(a, b) == 2)
    }

    @Test("Longest Common Prefix Partial")
    func longestCommonPrefixPartial() {
        let a = [
            StreamingSegmentParser.Segment(kind: .text, content: "A"),
            StreamingSegmentParser.Segment(kind: .codeBlock(language: "swift"), content: "let x = 1"),
            StreamingSegmentParser.Segment(kind: .text, content: "C"),
        ]
        let b = [
            StreamingSegmentParser.Segment(kind: .text, content: "A"),
            StreamingSegmentParser.Segment(kind: .codeBlock(language: "swift"), content: "let x = 1"),
            StreamingSegmentParser.Segment(kind: .text, content: "C-extended"),
        ]
        #expect(AssistantStaticBodyRenderer.longestCommonPrefixCount(a, b) == 2)
    }

    @Test("Longest Common Prefix Mismatch First")
    func longestCommonPrefixMismatchFirst() {
        let a = [StreamingSegmentParser.Segment(kind: .text, content: "X")]
        let b = [StreamingSegmentParser.Segment(kind: .text, content: "Y")]
        #expect(AssistantStaticBodyRenderer.longestCommonPrefixCount(a, b) == 0)
    }

    @Test("Longest Common Prefix Empty")
    func longestCommonPrefixEmpty() {
        let empty: [StreamingSegmentParser.Segment] = []
        let one = [StreamingSegmentParser.Segment(kind: .text, content: "A")]
        #expect(AssistantStaticBodyRenderer.longestCommonPrefixCount(empty, one) == 0)
        #expect(AssistantStaticBodyRenderer.longestCommonPrefixCount(one, empty) == 0)
        #expect(AssistantStaticBodyRenderer.longestCommonPrefixCount(empty, empty) == 0)
    }


    @Test("Finalize Reuses In Place Upgraded Code Card")
    func finalizeReusesInPlaceUpgradedCodeCard() {
        let bodyStack = UIStackView()
        let textView = UIView()
        bodyStack.addArrangedSubview(textView)
        let renderer = AssistantStaticBodyRenderer(bodyStack: bodyStack, textView: textView)
        let placeholderVC = UIViewController()
        renderer.setParentViewController(placeholderVC)

        let codeSegment = StreamingSegmentParser.Segment(
            kind: .codeBlock(language: "swift"),
            content: "let x = 1"
        )
        renderer.appendFrozenViews(newSegments: [codeSegment])
        guard let cardBefore = bodyStack.arrangedSubviews.compactMap({ $0 as? UIKitCodeBlockCard }).first else {
            Issue.record("appendFrozenViews should already have created a UIKitCodeBlockCard while streaming")
            return
        }
        let cardBeforeID = ObjectIdentifier(cardBefore)

        renderer.renderBlockMarkdown(
            text: "```swift\nlet x = 1\n```",
            renderHint: nil,
            parentViewController: placeholderVC
        )

        let cardsAfter = bodyStack.arrangedSubviews.compactMap { $0 as? UIKitCodeBlockCard }
        #expect(cardsAfter.count == 1, "on the reuse path, finalize must not rebuild the code card")
        #expect(cardsAfter.first.map { ObjectIdentifier($0) } == cardBeforeID,
                "the same code block segment must reuse the card instance upgraded in place while streaming, not destroy and rebuild it")
    }

    @Test("Finalize Appends New Tail Segments After Reuse")
    func finalizeAppendsNewTailSegmentsAfterReuse() {
        let bodyStack = UIStackView()
        let textView = UIView()
        bodyStack.addArrangedSubview(textView)
        let renderer = AssistantStaticBodyRenderer(bodyStack: bodyStack, textView: textView)
        let placeholderVC = UIViewController()
        renderer.setParentViewController(placeholderVC)

        let codeContent = "let x = 1"
        renderer.appendFrozenViews(newSegments: [
            StreamingSegmentParser.Segment(kind: .codeBlock(language: "swift"), content: codeContent),
        ])
        let upgradedIDs = bodyStack.arrangedSubviews
            .filter { $0 !== textView }
            .map(ObjectIdentifier.init)
        #expect(upgradedIDs.count == 1)

        let finalizeText = "```swift\n\(codeContent)\n```\n\nxxxxxx"
        renderer.renderBlockMarkdown(
            text: finalizeText,
            renderHint: nil,
            parentViewController: placeholderVC
        )

        let afterFrozen = bodyStack.arrangedSubviews.filter { $0 !== textView }
        let afterIDs = afterFrozen.map(ObjectIdentifier.init)
        for id in upgradedIDs {
            #expect(afterIDs.contains(id), "code block views in the common prefix must be reused")
        }
        #expect(afterFrozen.count > upgradedIDs.count, "the newly appended tail text segment must add at least one view")
    }

    @Test("Finalize Mismatch Falls Back To Clear Rebuild")
    func finalizeMismatchFallsBackToClearRebuild() {
        let bodyStack = UIStackView()
        let textView = UIView()
        bodyStack.addArrangedSubview(textView)
        let renderer = AssistantStaticBodyRenderer(bodyStack: bodyStack, textView: textView)
        let placeholderVC = UIViewController()
        renderer.setParentViewController(placeholderVC)

        renderer.appendFrozenViews(newSegments: [
            StreamingSegmentParser.Segment(kind: .text, content: "old content"),
        ])
        let oldLabelID = bodyStack.arrangedSubviews
            .filter { $0 !== textView }
            .first.map(ObjectIdentifier.init)
        #expect(oldLabelID != nil)

        renderer.renderBlockMarkdown(
            text: "completely different new content",
            renderHint: nil,
            parentViewController: placeholderVC
        )

        let newLabels = bodyStack.arrangedSubviews.filter { $0 !== textView }
        #expect(newLabels.count == 1, "after a rebuild on a mismatch only one new view remains")
        if let newID = newLabels.first.map(ObjectIdentifier.init) {
            #expect(newID != oldLabelID, "a mismatch must rebuild rather than reuse the old view")
        }
    }

    @Test("Finalize First Render Appends")
    func finalizeFirstRenderAppends() {
        let bodyStack = UIStackView()
        let textView = UIView()
        bodyStack.addArrangedSubview(textView)
        let renderer = AssistantStaticBodyRenderer(bodyStack: bodyStack, textView: textView)
        let placeholderVC = UIViewController()
        renderer.setParentViewController(placeholderVC)

        renderer.renderBlockMarkdown(
            text: "plain text content",
            renderHint: nil,
            parentViewController: placeholderVC
        )
        let frozen = bodyStack.arrangedSubviews.filter { $0 !== textView }
        #expect(frozen.count == 1, "rendering a single text segment for the first time produces one view")
    }

    @Test("Finalize Drops Extra Frozen Tail")
    func finalizeDropsExtraFrozenTail() {
        let bodyStack = UIStackView()
        let textView = UIView()
        bodyStack.addArrangedSubview(textView)
        let renderer = AssistantStaticBodyRenderer(bodyStack: bodyStack, textView: textView)
        let placeholderVC = UIViewController()
        renderer.setParentViewController(placeholderVC)

        renderer.appendFrozenViews(newSegments: [
            StreamingSegmentParser.Segment(kind: .text, content: "A"),
            StreamingSegmentParser.Segment(kind: .text, content: "B"),
            StreamingSegmentParser.Segment(kind: .text, content: "C"),
        ])
        #expect(bodyStack.arrangedSubviews.filter { $0 !== textView }.count == 3)

        renderer.renderBlockMarkdown(
            text: "A",
            renderHint: nil,
            parentViewController: placeholderVC
        )
        let after = bodyStack.arrangedSubviews.filter { $0 !== textView }
        #expect(after.count == 1, "views beyond the new segment list must be removed")
    }

    @Test("Resolved Latex Rerenders Only Matching Frozen Text")
    func resolvedLatexRerendersOnlyMatchingFrozenText() {
        let bodyStack = UIStackView()
        let textView = UIView()
        bodyStack.addArrangedSubview(textView)
        let renderer = AssistantStaticBodyRenderer(bodyStack: bodyStack, textView: textView)
        let placeholderVC = UIViewController()
        renderer.setParentViewController(placeholderVC)

        renderer.appendFrozenViews(newSegments: [
            StreamingSegmentParser.Segment(kind: .text, content: "before $$x^2$$ after"),
            StreamingSegmentParser.Segment(kind: .text, content: "unrelated text"),
        ])

        #expect(renderer.rerenderFrozenLabels(containing: "x^2"))
        #expect(!renderer.rerenderFrozenLabels(containing: "missing"))
    }

    @Test("Apply Attributed Text Replaces Attachment Only Diff")
    func applyAttributedTextReplacesAttachmentOnlyDiff() {
        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        cell.textView.attributedText = NSAttributedString(attachment: NSTextAttachment())

        let resolved = NSTextAttachment()
        cell.applyAttributedText(NSAttributedString(attachment: resolved))

        var found: NSTextAttachment?
        let applied = cell.textView.attributedText ?? NSAttributedString()
        applied.enumerateAttribute(.attachment, in: NSRange(location: 0, length: applied.length)) { value, _, _ in
            if let attachment = value as? NSTextAttachment { found = attachment }
        }
        #expect(found === resolved, "a formula that settles during a deferred finalize must land as a new attachment")
    }

    @Test("Attachment Runs Identical Semantics")
    func attachmentRunsIdenticalSemantics() {
        let shared = NSTextAttachment()
        let a = NSAttributedString(attachment: shared)
        let b = NSAttributedString(attachment: shared)
        #expect(AssistantMessageCell.attachmentRunsIdentical(a, b))

        let c = NSAttributedString(attachment: NSTextAttachment())
        #expect(!AssistantMessageCell.attachmentRunsIdentical(a, c))

        let p1 = NSAttributedString(string: "plain text")
        let p2 = NSAttributedString(string: "plain text")
        #expect(AssistantMessageCell.attachmentRunsIdentical(p1, p2))
    }

    @Test("Finalize Replaces Literal Latex With Attachment")
    func finalizeReplacesLiteralLatexWithAttachment() {
        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        let placeholderVC = UIViewController()
        cell.parentViewController = placeholderVC
        let raw = "the general form is:\n\\[\nax_t^2+bx_t+c=0\n\\]"
        cell.textView.attributedText = NSAttributedString(string: raw)

        cell.configureBody(
            text: raw,
            isStreaming: false,
            renderHint: nil,
            messageID: UUID(),
            parentViewController: placeholderVC
        )

        let shown = cell.textView.attributedText?.string ?? ""
        #expect(!shown.contains("\\["), "the finished state must not keep literal LaTeX delimiters")
        #expect(shown.contains("\u{FFFC}"), "a block formula must render as an attachment, either a placeholder or the formula image")
    }

    @Test("Resolved Latex Pending State Is Consumed After Freeze")
    func resolvedLatexPendingStateIsConsumedAfterFreeze() {
        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        let placeholderVC = UIViewController()
        cell.parentViewController = placeholderVC
        cell.staticBodyRenderer.setParentViewController(placeholderVC)
        cell.resolvedLatexAwaitingReconcile.insert("x^2")

        cell.appendFrozenViews(newSegments: [
            StreamingSegmentParser.Segment(kind: .text, content: "$$x^2$$"),
        ])

        #expect(cell.resolvedLatexAwaitingReconcile == ["x^2"],
                "it has to survive the freeze until finalize, otherwise re-reading the whole segment from cache brings the placeholder back")
        cell.reconcileResolvedLatexBeforeFinalRender(text: "$$x^2$$")
        #expect(cell.resolvedLatexAwaitingReconcile.isEmpty)
    }
}
