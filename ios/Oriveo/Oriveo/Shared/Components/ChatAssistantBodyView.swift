import SwiftUI
import UIKit

/// Assistant message body rendered through the same path as the chat assistant cell:
/// while streaming the whole text goes through `MarkdownAttributedStringRenderer.render(_:)`;
/// once finished it is split by `AssistantStaticBodyRenderer.flattenedFinalSegments(forText:)`
/// and laid out vertically as frozen text views, code cards and table cards.
/// Text is never split by paragraph direction here; each paragraph carries its own writing
/// direction from the renderer, so ordered lists stay in one text block.
struct ChatAssistantBodyView: UIViewRepresentable {
    let text: String
    let isStreaming: Bool

    /// Segments shown for `text`: one text segment while streaming, the chat final segments otherwise.
    static func segments(for text: String, isStreaming: Bool) -> [StreamingSegmentParser.Segment] {
        if isStreaming {
            return [StreamingSegmentParser.Segment(kind: .text, content: text)]
        }
        return AssistantStaticBodyRenderer.flattenedFinalSegments(forText: text)
    }

    /// Attributed text for a text segment, identical to the chat frozen text block.
    static func attributedText(for segment: StreamingSegmentParser.Segment) -> NSAttributedString {
        MarkdownAttributedStringRenderer.render(segment.content)
    }

    func makeUIView(context: Context) -> ContainerView {
        let container = ContainerView()
        container.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        container.setContentHuggingPriority(.required, for: .vertical)
        return container
    }

    func updateUIView(_ container: ContainerView, context: Context) {
        container.apply(text: text, isStreaming: isStreaming)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ContainerView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return CGSize(width: width, height: ceil(uiView.measuredHeight(fittingWidth: width)))
    }

    /// Vertical stack of block views; spacing matches the chat cell body stack.
    final class ContainerView: UIView {
        private let stack = UIStackView()
        private var lastText: String?
        private var lastStreaming: Bool?
        /// The single text view reused across streaming updates.
        private var streamingTextView: ChatPassiveTextView?

        /// Block views currently laid out, top to bottom.
        var blockViews: [UIView] { stack.arrangedSubviews }

        override init(frame: CGRect) {
            super.init(frame: frame)
            stack.axis = .vertical
            stack.alignment = .fill
            stack.spacing = OriveoTheme.Spacing.md
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: topAnchor),
                stack.leadingAnchor.constraint(equalTo: leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        /// Applies new content. While streaming the same text view is reused and only its attributed
        /// text changes; final segments are rebuilt only on the streaming-to-final switch or when the
        /// final text changes. Repeating the same input does nothing.
        func apply(text: String, isStreaming: Bool) {
            guard lastText != text || lastStreaming != isStreaming else { return }
            lastText = text
            lastStreaming = isStreaming
            if isStreaming {
                let attributed = MarkdownAttributedStringRenderer.render(text)
                if let textView = streamingTextView {
                    textView.attributedText = attributed
                    textView.invalidateIntrinsicContentSize()
                } else {
                    removeAllBlocks()
                    let textView = AssistantStaticBodyRenderer.makeFrozenTextView(attributed)
                    textView.useStableWidthForIntrinsic = false
                    textView.usesLengthOnlyIntrinsicHeightCache = false
                    stack.addArrangedSubview(textView)
                    streamingTextView = textView
                }
                invalidateIntrinsicContentSize()
                return
            }
            rebuild(with: ChatAssistantBodyView.segments(for: text, isStreaming: false))
        }

        private func removeAllBlocks() {
            streamingTextView = nil
            for view in stack.arrangedSubviews {
                stack.removeArrangedSubview(view)
                view.removeFromSuperview()
                if let card = view as? UIKitTableCard { UIKitTableCard.recycle(card) }
                if let card = view as? UIKitCodeBlockCard { UIKitCodeBlockCard.recycle(card) }
            }
        }

        private func rebuild(with segments: [StreamingSegmentParser.Segment]) {
            removeAllBlocks()
            for segment in segments {
                stack.addArrangedSubview(makeBlockView(segment))
            }
            invalidateIntrinsicContentSize()
        }

        private func makeBlockView(_ segment: StreamingSegmentParser.Segment) -> UIView {
            switch segment.kind {
            case .text:
                return AssistantStaticBodyRenderer.makeFrozenTextView(
                    ChatAssistantBodyView.attributedText(for: segment)
                )
            case .codeBlock(let language):
                let card = UIKitCodeBlockCard.make(
                    language: language,
                    content: segment.content,
                    parentViewController: nil
                )
                card.onIntrinsicHeightDidChange = { [weak self] in self?.invalidateIntrinsicContentSize() }
                return card
            case .table(let lines):
                if let card = UIKitTableCard.make(lines: lines) {
                    card.onIntrinsicHeightDidChange = { [weak self] in self?.invalidateIntrinsicContentSize() }
                    return card
                }
                return AssistantStaticBodyRenderer.makeFrozenTextView(
                    ChatAssistantBodyView.attributedText(for: segment)
                )
            }
        }

        func measuredHeight(fittingWidth width: CGFloat) -> CGFloat {
            let views = stack.arrangedSubviews
            guard !views.isEmpty else { return 0 }
            var total = stack.spacing * CGFloat(views.count - 1)
            for view in views {
                if let textView = view as? ChatPassiveTextView {
                    total += ceil(textView.measuredContentSize(fittingWidth: width).height)
                } else {
                    total += ceil(view.systemLayoutSizeFitting(
                        CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                        withHorizontalFittingPriority: .required,
                        verticalFittingPriority: .fittingSizeLevel
                    ).height)
                }
            }
            return total
        }
    }
}
