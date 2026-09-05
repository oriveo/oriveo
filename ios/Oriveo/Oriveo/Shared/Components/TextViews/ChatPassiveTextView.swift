import SwiftUI
import UIKit

final class ChatPassiveTextView: UITextView {

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        configureForChat()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer {
            return false
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    var useStableWidthForIntrinsic: Bool = false {
        didSet { invalidateIntrinsicContentSize() }
    }

    var usesLengthOnlyIntrinsicHeightCache: Bool = true {
        didSet { invalidateIntrinsicContentSize() }
    }

    var hugsContentWidth: Bool = false {
        didSet { if hugsContentWidth != oldValue { invalidateIntrinsicContentSize() } }
    }

    var maxContentWidth: CGFloat = .greatestFiniteMagnitude {
        didSet { if hugsContentWidth, maxContentWidth != oldValue { invalidateIntrinsicContentSize() } }
    }

    var onSaveSelection: ((String) -> Void)?
    var onReplaceSelection: ((String) -> Void)?
    var onAskSelection: ((QuoteSelectionContent) -> Void)?
    var quoteContentKind: QuoteContentKind = .prose

    override var intrinsicContentSize: CGSize {
        if hugsContentWidth {
            return hugIntrinsicContentSize()
        }
        let width: CGFloat = {
            if useStableWidthForIntrinsic, let stable = computeStableWidth(), stable > 0 {
                return stable
            }
            return bounds.width
        }()
        guard width > 0 else { return super.intrinsicContentSize }
        return measuredContentSize(fittingWidth: width)
    }

    func measuredContentSize(fittingWidth width: CGFloat) -> CGSize {
        guard width.isFinite, width > 0 else { return super.intrinsicContentSize }
        let length = textStorage.length

        if let cached = cachedIntrinsic,
           cached.length == length,
           usesLengthOnlyIntrinsicHeightCache || abs(cached.width - width) < 0.5 {
            return CGSize(width: width, height: cached.height)
        }

        let attr = attributedText ?? NSAttributedString(string: text ?? "", attributes: [.font: font ?? UIFont.systemFont(ofSize: 17)])
        guard attr.length > 0 else {
            let h = textContainerInset.top + textContainerInset.bottom
            cachedIntrinsic = (width, h, 0)
            return CGSize(width: width, height: h)
        }
        let innerWidth = width - textContainerInset.left - textContainerInset.right - textContainer.lineFragmentPadding * 2
        let rect = attr.boundingRect(
            with: CGSize(width: innerWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        let height = ceil(rect.height) + textContainerInset.top + textContainerInset.bottom
        cachedIntrinsic = (width, height, length)
        return CGSize(width: width, height: height)
    }

    private var cachedIntrinsic: (width: CGFloat, height: CGFloat, length: Int)?

    private var cachedHugIntrinsic: (cap: CGFloat, length: Int, size: CGSize)?

    private func hugIntrinsicContentSize() -> CGSize {
        let cap = maxContentWidth
        guard cap > 0, cap < .greatestFiniteMagnitude else { return super.intrinsicContentSize }
        let length = textStorage.length
        if let cached = cachedHugIntrinsic, cached.length == length, abs(cached.cap - cap) < 0.5 {
            return cached.size
        }
        let insetsH = textContainerInset.left + textContainerInset.right + textContainer.lineFragmentPadding * 2
        let insetsV = textContainerInset.top + textContainerInset.bottom
        let attr = attributedText ?? NSAttributedString(
            string: text ?? "", attributes: [.font: font ?? UIFont.systemFont(ofSize: 17)])
        guard attr.length > 0 else {
            let size = CGSize(width: 0, height: insetsV)
            cachedHugIntrinsic = (cap, 0, size)
            return size
        }
        let innerCap = max(1, cap - insetsH)
        let rect = attr.boundingRect(
            with: CGSize(width: innerCap, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        let width = min(ceil(rect.width) + insetsH, cap)
        let height = ceil(rect.height) + insetsV
        let size = CGSize(width: width, height: height)
        cachedHugIntrinsic = (cap, length, size)
        return size
    }

    private func computeStableWidth() -> CGFloat? {
        var view: UIView? = superview
        while let v = view {
            if let cv = v as? UICollectionView {
                return cv.bounds.width - ChatCardStableWidth.contentChrome
            }
            view = v.superview
        }
        return nil
    }

    static func sourceText(in attributed: NSAttributedString, range: NSRange) -> String {
        guard range.location != NSNotFound,
              range.length > 0,
              range.location + range.length <= attributed.length else { return "" }
        var result = ""
        let ns = attributed.string as NSString
        attributed.enumerateAttribute(.attachment, in: range, options: []) { value, subRange, _ in
            if let latex = value as? LatexAttachment {
                result += latex.isInline ? "$\(latex.latexSource)$" : "$$\(latex.latexSource)$$"
            } else if let placeholder = value as? BlockMathPlaceholderAttachment {
                result += "$$\(placeholder.latex)$$"
            } else if value == nil {
                result += ns.substring(with: subRange)
            }
        }
        return result
    }

    static func quoteSelectionContent(
        in attributed: NSAttributedString,
        range: NSRange,
        contentKind: QuoteContentKind
    ) -> QuoteSelectionContent? {
        guard range.location != NSNotFound,
              range.length > 0,
              range.location + range.length <= attributed.length else { return nil }
        let beforeRange = NSRange(location: 0, length: range.location)
        let afterLocation = range.location + range.length
        let afterRange = NSRange(location: afterLocation, length: attributed.length - afterLocation)
        let selected = sourceText(in: attributed, range: range)
        guard !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var leading = sourceText(in: attributed, range: beforeRange)
        var trailing = sourceText(in: attributed, range: afterRange)
        if contentKind == .prose {
            leading = proseLeadingContext(leading)
            trailing = proseTrailingContext(trailing)
        }
        return QuoteSelectionContent(
            contentKind: contentKind,
            leadingText: leading,
            selectedText: selected,
            trailingText: trailing
        )
    }

    private static func proseLeadingContext(_ text: String) -> String {
        guard let currentBlockStart = text.lastIndex(of: "\n").map({ text.index(after: $0) }) else {
            return text
        }

        var cursor = currentBlockStart
        while cursor > text.startIndex {
            let separator = text.index(before: cursor)
            let precedingText = text[..<separator]
            let blockStart = precedingText.lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
            let block = text[blockStart..<separator]
            if !block.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return String(text[blockStart...])
            }
            cursor = blockStart
        }
        return text
    }

    private static func proseTrailingContext(_ text: String) -> String {
        guard var cursor = text.firstIndex(of: "\n") else { return text }

        while cursor < text.endIndex {
            let blockStart = text.index(after: cursor)
            let remainingText = text[blockStart...]
            let blockEnd = remainingText.firstIndex(of: "\n") ?? text.endIndex
            let block = text[blockStart..<blockEnd]
            if !block.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return String(text[..<blockEnd])
            }
            guard blockEnd < text.endIndex else { break }
            cursor = blockEnd
        }
        return text
    }

    private func selectionContainsMathAttachment(in range: NSRange) -> Bool {
        guard let attributed = attributedText,
              range.length > 0,
              range.location + range.length <= attributed.length else { return false }
        var found = false
        attributed.enumerateAttribute(.attachment, in: range, options: []) { value, _, stop in
            if value is LatexAttachment || value is BlockMathPlaceholderAttachment {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    override func copy(_ sender: Any?) {
        let range = selectedRange
        if range.length > 0, let attributed = attributedText, selectionContainsMathAttachment(in: range) {
            UIPasteboard.general.string = Self.sourceText(in: attributed, range: range)
            return
        }
        super.copy(sender)
    }

    private func configureForChat() {
        delegate = self
        delaysContentTouches = false
        canCancelContentTouches = true
        panGestureRecognizer.isEnabled = false
        textDragInteraction?.isEnabled = false
        layoutManager.allowsNonContiguousLayout = false
        contentMode = .topLeft
    }
}

extension ChatPassiveTextView: UITextViewDelegate {
    func textView(
        _ textView: UITextView,
        editMenuForTextIn range: NSRange,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        guard (onAskSelection != nil || onSaveSelection != nil || onReplaceSelection != nil),
              range.length > 0,
              let attributed = textView.attributedText else {
            return UIMenu(children: suggestedActions)
        }
        let selected = Self.sourceText(in: attributed, range: range)
        guard !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return UIMenu(children: suggestedActions)
        }
        var customActions: [UIMenuElement] = []
        if let onAskSelection,
           let content = Self.quoteSelectionContent(
               in: attributed,
               range: range,
               contentKind: quoteContentKind
           ) {
            customActions.append(UIAction(
                title: L10n.tr("Ask", table: .chat),
                image: UIImage(systemName: "quote.bubble")
            ) { [weak textView] _ in
                onAskSelection(content)
                textView?.selectedRange = NSRange(location: 0, length: 0)
                textView?.resignFirstResponder()
            })
        }
        if let onReplaceSelection {
            customActions.append(UIAction(
                title: L10n.tr("Replace Current Note", table: .notes),
                image: UIImage(systemName: "note.text")
            ) { _ in
                onReplaceSelection(selected)
            })
        }
        if let onSaveSelection {
            customActions.append(UIAction(
                title: L10n.tr("Save as Note", table: .notes),
                image: UIImage(systemName: "note.text.badge.plus")
            ) { _ in
                onSaveSelection(selected)
            })
        }
        return UIMenu(children: customActions + suggestedActions)
    }
}
