import SwiftUI
import UIKit

/// The multi-line input shared by the chat composer and the Home hero (height grows with the text from one to
/// `maxLines` lines, then the text scrolls inside the field).
///
/// Replaces SwiftUI `TextField(axis: .vertical)`. That control is a TextKit 2 UITextView underneath, and every
/// SwiftUI layout asks its `_intrinsicSizeWithinSize:` once per size proposal; each question sets the size,
/// invalidates all layout and lays the text out cold, and focus, keyboard and sheet changes start another round.
/// With one very long paragraph every question pays for bidi and shaping of the whole paragraph: on a simulator,
/// pasting 8K of Arabic blocked the main thread for 4.0 s, typing one more character 7.8 s and dismissing and
/// showing the keyboard again 15.9 s; at 32K it was close to a minute.
///
/// What this view does instead:
/// - It stays on TextKit 2 (the same editing engine as the old TextField: input methods, selection and inline
///   Writing Tools rewrites are only complete on TextKit 2), and a scrollable TextKit 2 view only lays out the
///   paragraphs in its viewport;
/// - Overlong paragraphs are split in the display string with U+2029 (`SoftParagraphBreaks`), so every paragraph
///   in the viewport is bounded, while the binding always holds the source text. Once split, TextKit 2 is faster
///   than TextKit 1: 32K of Arabic loads in 19 vs 56 ms and inserting one character takes 5.4 vs 13.6 ms;
/// - Height comes from a separate TextKit 2 measuring stack that only lays out the first few lines and is cached
///   by (content version, width), without touching the live view's geometry. Never touch the live view's
///   `layoutManager`: that drops it into TextKit 1 compatibility mode;
/// - Focus is bridged by hand through a plain `Binding<Bool>`: first responder changes are always deferred out of
///   SwiftUI's update stack (resigning inside a graph update walks the responder chain up to the hosting view and
///   re-enters the same graph update).
struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    /// Empty = draw no placeholder (the caller layers its own, like the Home hero's decorative cursor).
    var placeholder: String = ""
    var font: UIFont
    var textColor: UIColor
    var placeholderColor: UIColor = .placeholderText
    /// nil = inherit the host's tint.
    var tintColor: UIColor?
    var isEnabled: Bool = true
    var maxLines: Int = 5
    /// nil = use the placeholder as the VoiceOver label.
    var accessibilityLabel: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> ComposerContainerView {
        let container = Self.makeContainer(coordinator: context.coordinator)
        context.coordinator.applyStyle(self, to: container, force: true)
        context.coordinator.apply(text, to: container.textView)
        return container
    }

    /// The single source of the production configuration, shared by makeUIView and the tests.
    static func makeContainer(coordinator: Coordinator) -> ComposerContainerView {
        // Ask for TextKit 2 explicitly: it lays out by viewport while scrolling, and it is the old TextField's engine.
        let textView = ComposerUITextView(usingTextLayoutManager: true)
        textView.backgroundColor = .clear
        textView.isScrollEnabled = true
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.delegate = coordinator
        textView.pasteDelegate = coordinator
        textView.textDragDelegate = coordinator
        textView.coordinator = coordinator
        let container = ComposerContainerView(textView: textView)
        container.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return container
    }

    func updateUIView(_ container: ComposerContainerView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.applyStyle(self, to: container, force: false)
        // While typing, the binding holds the very String that was just published, so this comparison is cheap;
        // it only differs when the text is pushed from outside (cleared after sending, draft or edit restored).
        if text != coordinator.publishedSource {
            coordinator.apply(text, to: container.textView)
        }
        coordinator.scheduleFocusSync(for: container.textView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerContainerView, context: Context) -> CGSize? {
        let height = context.coordinator.measuredHeight(width: proposal.width, textView: uiView.textView)
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? uiView.bounds.width
        return CGSize(width: width, height: height)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, UITextPasteDelegate, UITextDragDelegate {
        var parent: ComposerTextView
        /// The source text (without soft breaks) last loaded into the view or published from it.
        private(set) var publishedSource = ""
        /// Display content version: bumped on every content change, invalidates the measurement cache.
        private(set) var contentVersion = 0

        private var appliedStyle: StyleKey?
        private var focusSyncScheduled = false
        /// True while text pushed from outside replaces the whole string: `unmarkText()` may call
        /// textViewDidChange synchronously, and the old text must not be published back to the binding then.
        private var isApplying = false
        /// The edit behind the next textViewDidChange: its range in the new text, and whether it came from the paste
        /// delegate (in which case the soft breaks in it are ours).
        private var pendingEdit: (range: NSRange, fromPasteDelegate: Bool)?
        /// The display string the paste delegate just handed out: a following shouldChangeTextIn replacing text with
        /// it is our own insert.
        private var pendingPasteDisplay: String?
        /// Display length after the last change was processed: some insert paths skip shouldChangeTextIn, and the
        /// inserted range is then inferred from the length delta and the caret.
        private var lastDisplayLength = 0
        private var lastMeasuredHeight: CGFloat?
        private var measureCache: [MeasureKey: CGFloat] = [:]
        /// For tests: how many times the measuring stack actually laid text out (cache hits not counted).
        private(set) var measurePasses = 0

        /// Inserts that bypass the paste delegate (typing, dictation, Writing Tools) only trigger a split once the
        /// paragraph grows past this length, so a keystroke does not rescan and resplit.
        static let fallbackParagraphUTF16 = 4_096

        // A separate TextKit 2 measuring stack: the same layout engine as the live view (so line heights round the
        // same way). It only lays out the start of the display string and never touches the live text container.
        private let measureContentStorage = NSTextContentStorage()
        private let measureLayoutManager = NSTextLayoutManager()
        private let measureContainer = NSTextContainer(size: CGSize(width: 100, height: 0))

        init(parent: ComposerTextView) {
            self.parent = parent
            super.init()
            measureContainer.lineFragmentPadding = 0
            measureLayoutManager.textContainer = measureContainer
            measureContentStorage.addTextLayoutManager(measureLayoutManager)
        }

        // MARK: Content

        /// Source text pushed from outside: replace the whole string, move the caret to the end and clear the undo
        /// stack (its steps point into content that no longer exists).
        func apply(_ source: String, to textView: ComposerUITextView) {
            isApplying = true
            defer { isApplying = false }
            if textView.markedTextRange != nil {
                textView.unmarkText()
            }
            let display = SoftParagraphBreaks.display(forSource: source)
            textView.attributedText = NSAttributedString(string: display, attributes: textAttributes(parent))
            textView.typingAttributes = textAttributes(parent)
            textView.selectedRange = NSRange(location: (display as NSString).length, length: 0)
            textView.undoManager?.removeAllActions()
            pendingEdit = nil
            pendingPasteDisplay = nil
            lastDisplayLength = textView.textStorage.length
            publishedSource = source
            contentDidChange(in: textView)
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            let length = (text as NSString).length
            // This replacement follows right after the paste delegate handed out its display string; don't compare
            // contents, smart insert may add spaces at either end.
            pendingEdit = (NSRange(location: range.location, length: length), pendingPasteDisplay != nil)
            pendingPasteDisplay = nil
            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplying, let textView = textView as? ComposerUITextView else { return }
            normalizeAndSplitEditedRange(in: textView)
            let source = SoftParagraphBreaks.source(fromDisplay: textView.textStorage.string)
            publishedSource = source
            contentDidChange(in: textView)
            if parent.text != source {
                parent.text = source
            }
        }

        private func contentDidChange(in textView: ComposerUITextView) {
            contentVersion &+= 1
            let container = textView.superview as? ComposerContainerView
            container?.updatePlaceholderVisibility()
            // Only ask SwiftUI for a new layout when the height at the current width actually changed, so ordinary
            // typing does not relayout the whole bar. Invalidate the container (the representable's root view):
            // SwiftUI only watches the root, an invalidation on the inner text view never reaches it.
            let height = measuredHeight(width: textView.bounds.width > 0 ? textView.bounds.width : nil, textView: textView)
            if lastMeasuredHeight != height {
                lastMeasuredHeight = height
                container?.invalidateIntrinsicContentSize()
            }
        }

        /// Fallback for inserts that bypass the paste delegate (third-party keyboard clipboards, dictation, Writing
        /// Tools, text scanning), which can bring in several long paragraphs at once.
        /// 1. A U+2029 in such an insert is the user's own text; left in place it would be removed as a soft break
        ///    when restoring the source and glue two paragraphs together, so it is replaced with "\n" (same length).
        /// 2. Every overlong paragraph touched by the edited range is split, not only the caret's paragraph (the
        ///    caret paragraph is empty when the insert ends with a newline).
        /// These storage changes are not on the undo stack, so older undo steps would point at shifted ranges;
        /// the stack is cleared whenever anything was changed.
        private func normalizeAndSplitEditedRange(in textView: UITextView) {
            guard textView.markedTextRange == nil else { return }
            let storage = textView.textStorage
            defer { lastDisplayLength = storage.length }
            let text = storage.string as NSString
            let caret = min(textView.selectedRange.location, text.length)
            // Some insert paths (programmatic insertText, some system services) skip shouldChangeTextIn:
            // infer the insert from the length delta, ending at the caret.
            let inferred: (range: NSRange, fromPasteDelegate: Bool)? = {
                let delta = text.length - lastDisplayLength
                guard delta > 0 else { return nil }
                let location = max(0, caret - delta)
                return (NSRange(location: location, length: min(delta, text.length - location)), pendingPasteDisplay != nil)
            }()
            let edit = pendingEdit ?? inferred
            pendingEdit = nil
            pendingPasteDisplay = nil
            // A deletion has a zero-length replacement, so the edited range is the caret; don't use
            // NSIntersectionRange (its location is undefined for zero-length results).
            let edited: NSRange = {
                guard let edit else { return NSRange(location: caret, length: 0) }
                let location = min(edit.range.location, text.length)
                return NSRange(location: location, length: min(edit.range.length, text.length - location))
            }()
            // Short text cannot hold an overlong paragraph; nothing to scan unless a foreign insert carries U+2029.
            let foreignInsert = edit.map { !$0.fromPasteDelegate } ?? false
            guard text.length > Coordinator.fallbackParagraphUTF16
                || (foreignInsert && edited.length > 0 && text.substring(with: edited).utf16.contains(SoftParagraphBreaks.separator))
            else { return }
            var modified = false
            storage.beginEditing()
            if foreignInsert, edited.length > 0 {
                let separator = SoftParagraphBreaks.separatorString
                var search = edited
                while search.length > 0 {
                    let found = (storage.string as NSString).range(of: separator, options: [], range: search)
                    guard found.location != NSNotFound else { break }
                    storage.replaceCharacters(in: found, with: "\n")
                    modified = true
                    search = NSRange(location: NSMaxRange(found), length: NSMaxRange(search) - NSMaxRange(found))
                }
            }
            // Walk the paragraphs from the end of the edited range backwards, so earlier inserts never shift the
            // offsets still to be processed.
            let current = storage.string as NSString
            var cursor = min(NSMaxRange(edited), current.length)
            var inserted = 0
            var insertedBeforeCaret = 0
            while true {
                let paragraph = current.paragraphRange(for: NSRange(location: min(cursor, current.length), length: 0))
                if paragraph.length > Coordinator.fallbackParagraphUTF16 {
                    let local = NoteSoftParagraphBreaks.breakOffsets(
                        in: current.substring(with: paragraph) as NSString,
                        maxParagraphUTF16: SoftParagraphBreaks.maxParagraphUTF16
                    )
                    for offset in local.reversed() {
                        let location = paragraph.location + offset
                        let attributes = storage.attributes(at: max(0, location - 1), effectiveRange: nil)
                        storage.replaceCharacters(
                            in: NSRange(location: location, length: 0),
                            with: NSAttributedString(string: SoftParagraphBreaks.separatorString, attributes: attributes)
                        )
                        inserted += 1
                        if location <= caret { insertedBeforeCaret += 1 }
                    }
                }
                guard paragraph.location > edited.location, paragraph.location > 0 else { break }
                cursor = paragraph.location - 1
            }
            storage.endEditing()
            if inserted > 0 {
                let selection = textView.selectedRange
                textView.selectedRange = NSRange(location: selection.location + insertedBeforeCaret, length: 0)
            }
            if modified || inserted > 0 {
                textView.undoManager?.removeAllActions()
            }
        }

        // MARK: Paste / drag and drop

        /// Menu paste, ⌘V and drops all come through here: text is split before it is inserted, so an overlong
        /// paragraph never reaches the storage in one piece.
        func textPasteConfigurationSupporting(
            _ textPasteConfigurationSupporting: any UITextPasteConfigurationSupporting,
            combineItemAttributedStrings itemStrings: [NSAttributedString],
            for textRange: UITextRange
        ) -> NSAttributedString {
            let joined = itemStrings.map(\.string).joined(separator: "\n")
            let display = SoftParagraphBreaks.display(forSource: joined)
            pendingPasteDisplay = display
            return NSAttributedString(string: display, attributes: textAttributes(parent))
        }

        /// A dragged selection carries the source text: dropped back into the field with its soft breaks,
        /// `normalized` would turn them into real newlines and silently change the text.
        func textDraggableView(
            _ textDraggableView: UIView & UITextDraggable,
            itemsForDrag dragRequest: UITextDragRequest
        ) -> [UIDragItem] {
            guard let textView = textDraggableView as? UITextView,
                  let selected = textView.text(in: dragRequest.dragRange),
                  selected.utf16.contains(SoftParagraphBreaks.separator) else {
                return dragRequest.suggestedItems
            }
            let source = SoftParagraphBreaks.source(fromDisplay: selected)
            return [UIDragItem(itemProvider: NSItemProvider(object: source as NSString))]
        }

        // MARK: Focus

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.isFocused {
                parent.isFocused = true
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFocused {
                parent.isFocused = false
            }
        }

        /// Focus is reconciled on the next run loop turn: updateUIView runs inside the host's graph update, and
        /// becoming or resigning there walks the responder chain up to the SwiftUI host and re-enters that update.
        func scheduleFocusSync(for textView: ComposerUITextView) {
            guard parent.isFocused != textView.isFirstResponder, !focusSyncScheduled else { return }
            focusSyncScheduled = true
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.focusSyncScheduled = false
                self.syncFocus(textView)
            }
        }

        /// Only call this from UIKit callbacks or asynchronously, never from updateUIView's synchronous stack (it
        /// re-enters the SwiftUI host through the responder chain). When focus is wanted but cannot be taken
        /// (disabled, or becoming first responder fails) the binding goes back to false, as FocusState did in
        /// both cases; left at true it would keep the focus ring lit, hold up draft reconciliation and pop the
        /// keyboard out of nowhere once the field is enabled again.
        func syncFocus(_ textView: ComposerUITextView) {
            if parent.isFocused {
                guard !textView.isFirstResponder, textView.window != nil else { return }
                if !parent.isEnabled || !textView.becomeFirstResponder() {
                    parent.isFocused = false
                }
            } else if textView.isFirstResponder {
                textView.resignFirstResponder()
            }
        }

        // MARK: Style

        private struct StyleKey: Equatable {
            let font: UIFont
            let textColor: UIColor
            let placeholder: String
            let placeholderColor: UIColor
            let tintColor: UIColor?
            let isEnabled: Bool
            let accessibilityLabel: String?
        }

        func applyStyle(_ parent: ComposerTextView, to container: ComposerContainerView, force: Bool) {
            let textView = container.textView
            let key = StyleKey(
                font: parent.font,
                textColor: parent.textColor,
                placeholder: parent.placeholder,
                placeholderColor: parent.placeholderColor,
                tintColor: parent.tintColor,
                isEnabled: parent.isEnabled,
                accessibilityLabel: parent.accessibilityLabel
            )
            guard force || key != appliedStyle else { return }
            let fontChanged = appliedStyle?.font != key.font
            let colorChanged = appliedStyle?.textColor != key.textColor
            appliedStyle = key
            if force || fontChanged || colorChanged {
                // font / textColor rewrite attributes across the whole storage; only touch them when they changed.
                textView.font = key.font
                textView.textColor = key.textColor
                textView.typingAttributes = textAttributes(parent)
            }
            if fontChanged {
                measureCache.removeAll()
                lastMeasuredHeight = nil
                container.invalidateIntrinsicContentSize()
            }
            textView.tintColor = key.tintColor
            if key.isEnabled || !textView.isFirstResponder {
                textView.isEditable = key.isEnabled
                textView.isSelectable = key.isEnabled
            } else {
                // This runs inside updateUIView's graph update: disabling the first responder synchronously makes
                // UIKit resign it right away, which re-enters the SwiftUI host through the responder chain.
                // Resign asynchronously first, then disable.
                DispatchQueue.main.async { [weak self, weak textView] in
                    guard let self, let textView, !self.parent.isEnabled else { return }
                    textView.resignFirstResponder()
                    textView.isEditable = false
                    textView.isSelectable = false
                }
            }
            container.configurePlaceholder(text: key.placeholder, font: key.font, color: key.placeholderColor)
            textView.accessibilityLabel = key.accessibilityLabel ?? (key.placeholder.isEmpty ? nil : key.placeholder)
        }

        private func textAttributes(_ parent: ComposerTextView) -> [NSAttributedString.Key: Any] {
            [.font: parent.font, .foregroundColor: parent.textColor]
        }

        // MARK: Measurement

        private struct MeasureKey: Hashable {
            let version: Int
            let width: Int
            let maxLines: Int
        }

        /// Height = the first `maxLines` lines (fewer if the text is shorter, one line for empty text).
        /// A missing, zero or infinite width gets one line straight away: SwiftUI is probing for an ideal size
        /// there, and laying text out would be meaningless.
        ///
        /// Rounding matches what `TextField(axis: .vertical).lineLimit(1...maxLines)` measured: below the limit the
        /// content height is rounded up to a whole point (one 16 pt line is 20, two are 39), at the limit it is
        /// rounded up to a pixel (five 16 pt lines are 95.667). A single line off by those 0.67 pt moves the text
        /// down a pixel once the field is centered in its 44 pt minimum height.
        func measuredHeight(width: CGFloat?, textView: ComposerUITextView) -> CGFloat {
            let oneLine = parent.font.lineHeight.rounded(.up)
            guard let width, width.isFinite, width >= 20 else { return oneLine }
            let key = MeasureKey(version: contentVersion, width: Int((width * 2).rounded()), maxLines: parent.maxLines)
            if let cached = measureCache[key] { return cached }
            let height = max(oneLine, measure(textView.textStorage, width: width, maxLines: parent.maxLines))
            if measureCache.count > 8 { measureCache.removeAll() }
            measureCache[key] = height
            return height
        }

        /// Only moves the start of the display string into the measuring stack; when that yields fewer than
        /// `maxLines` lines before reaching the end, the prefix grows geometrically and is laid out again.
        private func measure(_ storage: NSTextStorage, width: CGFloat, maxLines: Int) -> CGFloat {
            let total = storage.length
            guard total > 0 else { return 0 }
            let text = storage.string as NSString
            measureContainer.size = CGSize(width: width, height: 0)
            var prefix = min(total, 1_024)
            while true {
                if prefix < total {
                    // Cut on a grapheme boundary, never inside a surrogate pair or combining sequence. If the
                    // cluster starts at 0 (the first grapheme alone is longer than the cut, say one letter followed
                    // by a thousand combining marks), take the cluster's end instead; otherwise prefix stays 0 and
                    // the growth below never terminates.
                    let cluster = text.rangeOfComposedCharacterSequence(at: prefix)
                    prefix = cluster.location > 0 ? cluster.location : min(total, NSMaxRange(cluster))
                }
                measurePasses += 1
                measureContentStorage.attributedString = storage.attributedSubstring(from: NSRange(location: 0, length: prefix))
                var lines = 0
                var bottom: CGFloat = 0
                // A trailing newline puts the caret on a new line: the extra line fragment counts that line too.
                measureLayoutManager.enumerateTextLayoutFragments(
                    from: measureLayoutManager.documentRange.location,
                    options: [.ensuresLayout, .ensuresExtraLineFragment]
                ) { fragment in
                    let origin = fragment.layoutFragmentFrame.minY
                    for line in fragment.textLineFragments {
                        lines += 1
                        bottom = origin + line.typographicBounds.maxY
                        if lines >= maxLines { return false }
                    }
                    return true
                }
                if lines >= maxLines { return ceilToPixel(bottom) }
                if prefix >= total { return bottom.rounded(.up) }
                prefix = min(total, max(prefix * 4, prefix + 1))
            }
        }

        private func ceilToPixel(_ value: CGFloat) -> CGFloat {
            let scale = UITraitCollection.current.displayScale > 0 ? UITraitCollection.current.displayScale : 3
            return (value * scale).rounded(.up) / scale
        }
    }
}

/// The UIKit root view of `ComposerTextView`: the UITextView and the placeholder are siblings.
/// The placeholder cannot live inside the UITextView: a TextKit 2 UITextView rearranges its own subviews, and a
/// label added there was measured to be missing from the view tree.
final class ComposerContainerView: UIView {
    let textView: ComposerUITextView
    private let placeholderLabel = UILabel()

    init(textView: ComposerUITextView) {
        self.textView = textView
        super.init(frame: .zero)
        addSubview(textView)
        placeholderLabel.numberOfLines = 1
        placeholderLabel.lineBreakMode = .byTruncatingTail
        placeholderLabel.textAlignment = .natural
        placeholderLabel.isAccessibilityElement = false
        placeholderLabel.isUserInteractionEnabled = false
        addSubview(placeholderLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configurePlaceholder(text: String, font: UIFont, color: UIColor) {
        placeholderLabel.text = text
        placeholderLabel.font = font
        placeholderLabel.textColor = color
        updatePlaceholderVisibility()
        setNeedsLayout()
    }

    func updatePlaceholderVisibility() {
        placeholderLabel.isHidden = textView.hasText || (placeholderLabel.text ?? "").isEmpty
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if textView.frame != bounds {
            textView.frame = bounds
        }
        // Same origin as the first line of text: textContainerInset and lineFragmentPadding are always 0.
        placeholderLabel.frame = CGRect(
            x: 0,
            y: 0,
            width: bounds.width,
            height: (placeholderLabel.font ?? textView.font)?.lineHeight ?? 0
        )
    }
}

/// The UITextView behind `ComposerTextView`: copy and cut restore the source text, growing clears any leftover
/// scroll offset, and the paragraph direction always stays natural.
final class ComposerUITextView: UITextView {
    weak var coordinator: ComposerTextView.Coordinator?
    /// Injected by tests; always the system pasteboard in production.
    var sourcePasteboard: UIPasteboard = .general

    override func layoutSubviews() {
        super.layoutSubviews()
        // Content that fits the field should have no scroll offset: when the text grows from N to N+1 lines, the
        // field first scrolls the caret into view at its old height, then SwiftUI makes it taller, and the
        // leftover offset would clip the top of the first line.
        if contentSize.height <= bounds.height + 0.5, contentOffset.y != 0 {
            contentOffset = .zero
        }
    }

    /// When the view becomes first responder or the keyboard changes, UIKit pins the paragraph direction to the
    /// keyboard language (English keyboard → LTR), and Arabic pasted or typed afterwards is laid out LTR (the final
    /// punctuation lands on the wrong side). The old TextField always resolved direction from the first strong
    /// character (natural); keep doing that.
    override func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

    override var typingAttributes: [NSAttributedString.Key: Any] {
        get { Self.naturalized(super.typingAttributes) }
        set { super.typingAttributes = Self.naturalized(newValue) }
    }

    private static func naturalized(_ attributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        guard let style = attributes[.paragraphStyle] as? NSParagraphStyle,
              style.baseWritingDirection != .natural,
              let mutable = style.mutableCopy() as? NSMutableParagraphStyle else {
            return attributes
        }
        mutable.baseWritingDirection = .natural
        var copy = attributes
        copy[.paragraphStyle] = mutable
        return copy
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Joining the window can happen in the middle of a SwiftUI render: reconcile focus asynchronously as well,
        // never become first responder synchronously here.
        guard window != nil, let coordinator else { return }
        coordinator.scheduleFocusSync(for: self)
    }

    override func copy(_ sender: Any?) {
        let source = selectedSourceTextIfSoftBroken()
        super.copy(sender)
        if let source { sourcePasteboard.string = source }
    }

    override func cut(_ sender: Any?) {
        // Cut deletes the selection, so the source text has to be read before super.
        let source = selectedSourceTextIfSoftBroken()
        super.cut(sender)
        if let source { sourcePasteboard.string = source }
    }

    /// The selection's source text without soft breaks when it contains any; nil otherwise, which keeps whatever
    /// the system wrote to the pasteboard.
    func selectedSourceTextIfSoftBroken() -> String? {
        let range = selectedRange
        guard range.length > 0, NSMaxRange(range) <= textStorage.length else { return nil }
        let selected = (textStorage.string as NSString).substring(with: range)
        guard selected.utf16.contains(SoftParagraphBreaks.separator) else { return nil }
        return SoftParagraphBreaks.source(fromDisplay: selected)
    }
}
