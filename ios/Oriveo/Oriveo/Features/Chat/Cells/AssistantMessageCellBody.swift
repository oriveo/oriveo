import MarkdownUI
import SwiftUI
import UIKit

extension AssistantMessageCell {
    // MARK: - Body

    func configureBody(
        text: String,
        isStreaming: Bool,
        renderHint: MarkdownRenderHint?,
        messageID: UUID,
        parentViewController: UIViewController
    ) {

        if isStreaming {
            if text.isEmpty {
                let hasStreamedContentOnScreen = !lastStreamingText.isEmpty
                    || staticBodyRenderer.committedSegmentCount > 0
                    || textView.textStorage.length > 0
                if hasStreamedContentOnScreen {
                    return
                }
                setTypingIndicatorVisible(true)
            } else {
                updateStreamingText(text)
            }
            return
        }

        setTypingIndicatorVisible(false)

        if text.isEmpty {
            clearFrozenViews()
            textView.text = nil
            textView.isHidden = true
            return
        }
        textView.isHidden = false

        reconcileResolvedLatexBeforeFinalRender(text: text)

        var resolvedMode = MarkdownMessageView.resolvedRenderingMode(for: text, renderHint: renderHint)

        let containsTable = StreamingSegmentParser.textContainsGFMTable(text)
        if resolvedMode == .blockMarkdown && !text.contains("```") && !containsTable {
            resolvedMode = .inlineMarkdown
        }
        if containsTable && resolvedMode == .inlineMarkdown {
            resolvedMode = .blockMarkdown
        }
        currentRenderMode = resolvedMode

        switch resolvedMode {
        case .plainText:
            clearFrozenViews()
            applyAttributedText(
                MarkdownAttributedStringRenderer.plainTextFallback(text),
                animated: false
            )

        case .inlineMarkdown:
            clearFrozenViews()
            let rendered: NSAttributedString
            if let cached = MarkdownAttributedStringRenderer.cachedRender(for: text) {
                rendered = cached
            } else {
                rendered = MarkdownAttributedStringRenderer.render(text)
            }
            applyAttributedText(rendered)

        case .blockMarkdown, .segmentedCodeMarkdown:
            textView.isHidden = true
            textView.text = nil
            textView.attributedText = nil
            staticBodyRenderer.renderBlockMarkdown(
                text: text,
                renderHint: renderHint,
                parentViewController: parentViewController
            )
        }
    }

    func applyAttributedText(_ attrText: NSAttributedString, animated: Bool = false) {
        if let currentAttr = textView.attributedText,
           currentAttr.length == attrText.length,
           currentAttr.string == attrText.string,
           Self.attachmentRunsIdentical(currentAttr, attrText) {
            return
        }
        chunkFader.cancel()
        _ = animated
        textView.attributedText = attrText
        textView.linkTextAttributes = [
            .foregroundColor: UIColor(OriveoTheme.Palette.primary)
        ]
        textView.invalidateIntrinsicContentSize()
    }

    static func attachmentRunsIdentical(_ lhs: NSAttributedString, _ rhs: NSAttributedString) -> Bool {
        guard lhs.string.contains("\u{FFFC}") else { return true }
        var lhsRuns: [(Int, NSTextAttachment)] = []
        lhs.enumerateAttribute(.attachment, in: NSRange(location: 0, length: lhs.length)) { value, range, _ in
            if let attachment = value as? NSTextAttachment { lhsRuns.append((range.location, attachment)) }
        }
        var index = 0
        var identical = true
        rhs.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rhs.length)) { value, range, stop in
            guard let attachment = value as? NSTextAttachment else { return }
            guard index < lhsRuns.count,
                  lhsRuns[index].0 == range.location,
                  lhsRuns[index].1 === attachment else {
                identical = false
                stop.pointee = true
                return
            }
            index += 1
        }
        return identical && index == lhsRuns.count
    }

}

// MARK: - SwiftUI Wrapper

struct StaticMarkdownContentWrapper: View {
    let text: String
    let renderHint: MarkdownRenderHint?

    var body: some View {
        MarkdownMessageView(
            text: text,
            isStreaming: false,
            renderHint: renderHint
        )
    }
}
