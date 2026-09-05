import SwiftUI
import UIKit

@MainActor
final class AssistantStaticBodyRenderer {
    private weak var bodyStack: UIStackView?
    private weak var textView: UIView?
    private weak var parentViewController: UIViewController?

    private var frozenViews: [UIView] = []
    private var frozenLabelMarkdown: [ObjectIdentifier: String] = [:]
    private(set) var committedSegmentCount = 0

    private var frozenSegments: [StreamingSegmentParser.Segment] = []

    #if DEBUG
    private(set) var _testInstantViews: Set<ObjectIdentifier> = []
    #endif

    private let hostNotifier: () -> Void

    private let streamingAnchorProvider: () -> UIView?

    var onSaveSelection: ((String) -> Void)?
    var onAskSelection: ((QuoteSelectionContent) -> Void)?
    var onReplaceSelection: ((String) -> Void)?
    var onSaveCodeBlock: ((String, String?) -> Void)?

    init(
        bodyStack: UIStackView,
        textView: UIView,
        streamingAnchorProvider: @escaping () -> UIView? = { nil },
        hostNotifier: @escaping () -> Void = {}
    ) {
        self.bodyStack = bodyStack
        self.textView = textView
        self.streamingAnchorProvider = streamingAnchorProvider
        self.hostNotifier = hostNotifier
    }

    private func anchorIndex(in bodyStack: UIStackView) -> Int {
        if let textView, bodyStack.arrangedSubviews.contains(textView) {
            return bodyStack.arrangedSubviews.firstIndex(of: textView) ?? bodyStack.arrangedSubviews.count
        }
        if let anchor = streamingAnchorProvider(),
           bodyStack.arrangedSubviews.contains(anchor) {
            return bodyStack.arrangedSubviews.firstIndex(of: anchor) ?? bodyStack.arrangedSubviews.count
        }
        return bodyStack.arrangedSubviews.count
    }

    func setParentViewController(_ parentViewController: UIViewController?) {
        self.parentViewController = parentViewController
    }

    func appendFrozenViews(
        newSegments: [StreamingSegmentParser.Segment],
        harvestedFirstText: NSAttributedString? = nil,
        harvestedCode: (content: String, attributed: NSAttributedString)? = nil
    ) {
        guard let parentViewController, let bodyStack, let textView else { return }
        let anchor = anchorIndex(in: bodyStack)

        var springViews: [UIView] = []
        var pendingHarvest = (harvestedFirstText?.length ?? 0) > 0 ? harvestedFirstText : nil
        var pendingCodeHarvest = harvestedCode
        for (i, segment) in newSegments.enumerated() {
            let insertAt = anchor + i
            let view: UIView
            var labelOriginal: String?
            var entersInstantly = false
            switch segment.kind {
            case .text:
                let attributed: NSAttributedString
                if let harvest = pendingHarvest {
                    attributed = harvest
                    pendingHarvest = nil
                    entersInstantly = true
                } else {
                    attributed = MarkdownAttributedStringRenderer.render(segment.content)
                }
                let textBlock = Self.makeFrozenTextView(attributed)
                textBlock.onSaveSelection = onSaveSelection
                textBlock.onAskSelection = onAskSelection
                textBlock.onReplaceSelection = onReplaceSelection
                view = textBlock
                labelOriginal = segment.content

            case .codeBlock(let language):
                let codeHarvest: NSAttributedString?
                if let pending = pendingCodeHarvest, pending.content == segment.content {
                    codeHarvest = pending.attributed
                    pendingCodeHarvest = nil
                    entersInstantly = true
                } else {
                    codeHarvest = nil
                }
                let card = UIKitCodeBlockCard(
                    language: language,
                    content: segment.content,
                    parentViewController: parentViewController,
                    highlightTransition: false,
                    initialAttributedText: codeHarvest
                )
                let notifier = hostNotifier
                card.onIntrinsicHeightDidChange = { notifier() }
                if let onSaveCodeBlock {
                    card.onSaveNote = { onSaveCodeBlock(segment.content, language) }
                }
                card.onAskSelection = onAskSelection
                view = card

            case .table(let lines):
                if let tableData = UIKitTableCard.parseMarkdownLines(lines) {
                    let card = UIKitTableCard(tableData: tableData)
                    card.onAskSelection = onAskSelection
                    let notifier = hostNotifier
                    card.onIntrinsicHeightDidChange = { notifier() }
                    view = card
                } else {
                    view = Self.makeFrozenTextView(
                        MarkdownAttributedStringRenderer.render(segment.content)
                    )
                    labelOriginal = segment.content
                }
            }

            view.alpha = entersInstantly ? 1 : 0
            view.transform = entersInstantly
                ? .identity
                : CGAffineTransform(translationX: 0, y: 8).scaledBy(x: 0.98, y: 0.98)
            bodyStack.insertArrangedSubview(view, at: insertAt)
            frozenViews.append(view)
            frozenSegments.append(segment)
            if !entersInstantly { springViews.append(view) }
            #if DEBUG
            if entersInstantly { _testInstantViews.insert(ObjectIdentifier(view)) }
            #endif
            if let labelOriginal {
                frozenLabelMarkdown[ObjectIdentifier(view)] = labelOriginal
            }
        }

        bodyStack.setNeedsLayout()
        bodyStack.layoutIfNeeded()


        guard !springViews.isEmpty else { return }

        guard !UIAccessibility.isReduceMotionEnabled else {
            for view in springViews {
                view.alpha = 1
                view.transform = .identity
            }
            return
        }

        UIView.animate(
            withDuration: 0.18,
            delay: 0,
            usingSpringWithDamping: 0.92,
            initialSpringVelocity: 0.4,
            options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]
        ) {
            for view in springViews {
                view.alpha = 1
                view.transform = .identity
            }
        }
    }

    func renderBlockMarkdown(
        text: String,
        renderHint: MarkdownRenderHint?,
        parentViewController: UIViewController
    ) {
        _ = renderHint
        setParentViewController(parentViewController)

        let newSegments = Self.flattenedFinalSegments(forText: text)

        let prefix = Self.longestCommonPrefixCount(frozenSegments, newSegments)
        if prefix == 0 && !frozenSegments.isEmpty {
            clear()
            for segment in newSegments {
                appendBlockSegment(segment, parentViewController: parentViewController)
            }
            return
        }

        dropFrozenTail(keepingPrefix: prefix)
        if prefix < newSegments.count {
            for segment in newSegments[prefix...] {
                appendBlockSegment(segment, parentViewController: parentViewController)
            }
        }
        committedSegmentCount = frozenSegments.count
    }

    nonisolated static func flattenedFinalSegments(forText text: String) -> [StreamingSegmentParser.Segment] {
        var segments: [StreamingSegmentParser.Segment] = []
        let parsed = StreamingSegmentParser.parse(text)
        segments.append(contentsOf: parsed.committed)

        if !parsed.tail.isEmpty {
            let (textPart, unclosed) = StreamingSegmentParser.splitTailAtUnclosedFence(parsed.tail)
            if let unclosed {
                if !textPart.isEmpty {
                    let refined = StreamingSegmentParser.splitTextSegmentsForTables([
                        StreamingSegmentParser.Segment(kind: .text, content: textPart)
                    ])
                    segments.append(contentsOf: refined)
                }
                segments.append(StreamingSegmentParser.Segment(
                    kind: .codeBlock(language: unclosed.language),
                    content: unclosed.code
                ))
            } else {
                let tailSegment = StreamingSegmentParser.Segment(kind: .text, content: parsed.tail)
                let refined = StreamingSegmentParser.splitTextSegmentsForTables([tailSegment])
                segments.append(contentsOf: refined)
            }
        }

        if let tableLines = parsed.streamingTable, !tableLines.isEmpty {
            segments.append(StreamingSegmentParser.Segment(
                kind: .table(lines: tableLines),
                content: tableLines.joined(separator: "\n")
            ))
        }
        return segments
    }

    func clear() {
        for view in frozenViews {
            bodyStack?.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        frozenViews.removeAll()
        frozenSegments.removeAll()
        frozenLabelMarkdown.removeAll()
        committedSegmentCount = 0
        #if DEBUG
        _testInstantViews.removeAll()
        #endif
    }

    func markCommittedSegmentCount(_ count: Int) {
        committedSegmentCount = count
    }

    @discardableResult
    func rerenderFrozenLabels(containing latex: String) -> Bool {
        var didRerender = false
        for view in frozenViews {
            guard let frozenText = view as? ChatPassiveTextView,
                  let original = frozenLabelMarkdown[ObjectIdentifier(frozenText)],
                  original.contains(latex) else { continue }
            MarkdownAttributedStringRenderer.invalidateCache(for: original)
            frozenText.traitCollection.performAsCurrent {
                frozenText.attributedText = MarkdownAttributedStringRenderer.render(original)
            }
            frozenText.invalidateIntrinsicContentSize()
            didRerender = true
        }
        return didRerender
    }

    static func makeFrozenTextView(_ attributed: NSAttributedString) -> ChatPassiveTextView {
        let textView = ChatPassiveTextView()
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.linkTextAttributes = [.foregroundColor: UIColor(OriveoTheme.Palette.primary)]
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.required, for: .vertical)
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        textView.useStableWidthForIntrinsic = true
        textView.attributedText = attributed
        return textView
    }

    private func appendBlockSegment(
        _ segment: StreamingSegmentParser.Segment,
        parentViewController: UIViewController
    ) {
        guard let bodyStack, let textView else { return }
        let insertAt = anchorIndex(in: bodyStack)
        let view: UIView
        var labelOriginal: String?

        switch segment.kind {
        case .text:
            let textBlock = Self.makeFrozenTextView(MarkdownAttributedStringRenderer.render(segment.content))
            textBlock.onSaveSelection = onSaveSelection
            textBlock.onAskSelection = onAskSelection
            textBlock.onReplaceSelection = onReplaceSelection
            view = textBlock
            labelOriginal = segment.content

        case .codeBlock(let language):
            let card = UIKitCodeBlockCard(
                language: language,
                content: segment.content,
                parentViewController: parentViewController
            )
            let notifier = hostNotifier
            card.onIntrinsicHeightDidChange = { notifier() }
            if let onSaveCodeBlock {
                card.onSaveNote = { onSaveCodeBlock(segment.content, language) }
            }
            card.onAskSelection = onAskSelection
            view = card

        case .table(let lines):
            if let tableData = UIKitTableCard.parseMarkdownLines(lines) {
                let card = UIKitTableCard(tableData: tableData)
                card.onAskSelection = onAskSelection
                let notifier = hostNotifier
                card.onIntrinsicHeightDidChange = { notifier() }
                view = card
            } else {
                view = Self.makeFrozenTextView(
                    MarkdownAttributedStringRenderer.render(segment.content)
                )
                labelOriginal = segment.content
            }
        }

        bodyStack.insertArrangedSubview(view, at: insertAt)
        frozenViews.append(view)
        frozenSegments.append(segment)
        if let labelOriginal {
            frozenLabelMarkdown[ObjectIdentifier(view)] = labelOriginal
        }
    }

    private func appendBlockSegmentBare(_ segment: StreamingSegmentParser.Segment) {
        guard let parentViewController else { return }
        appendBlockSegment(segment, parentViewController: parentViewController)
    }

    private func dropFrozenTail(keepingPrefix keepPrefixCount: Int) {
        guard keepPrefixCount < frozenViews.count else { return }
        let removedRange = keepPrefixCount..<frozenViews.count
        for view in frozenViews[removedRange] {
            bodyStack?.removeArrangedSubview(view)
            view.removeFromSuperview()
            frozenLabelMarkdown.removeValue(forKey: ObjectIdentifier(view))
        }
        frozenViews.removeSubrange(removedRange)
        frozenSegments.removeSubrange(removedRange)
    }

    static func longestCommonPrefixCount(
        _ frozen: [StreamingSegmentParser.Segment],
        _ incoming: [StreamingSegmentParser.Segment]
    ) -> Int {
        var count = 0
        let bound = min(frozen.count, incoming.count)
        while count < bound, frozen[count] == incoming[count] {
            count += 1
        }
        return count
    }
}
