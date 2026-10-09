import SwiftUI
import UIKit

/// The source-text length limit for the chat and Home inputs (each passes it to `ComposerTextView`).
enum ChatInputLimit {
    /// A single message holds at most 50,000 UTF-16 code units of source text (display-layer soft breaks do not
    /// count); the value is the same on every platform.
    /// Rationale: the Android input re-lays out the whole text on every change. On an emulator, typing one
    /// character into 50K characters of non-repeating text costs up to 40 ms for the slowest frame, and 100 ms or
    /// more at 500K characters; all platforms share this limit.
    static let maxUTF16 = 50_000

    static func limitReachedMessage(limit: Int = maxUTF16) -> String {
        String(
            format: L10n.tr("chat_input_length_limit_reached", table: .chat),
            locale: AppLocalization.currentLocale,
            Int64(limit)
        )
    }

    /// The over-limit notice shared by both inputs. Deduplication happens in `ComposerTextView.Coordinator`; every
    /// call here shows the toast once.
    @MainActor
    static func showLimitReachedToast() {
        ToastManager.shared.show(limitReachedMessage())
    }
}

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
/// - Geometry queries over a large range (tap hit-testing after Select All, selection rects) are bounded by the
///   viewport as well: the layout manager is a `ComposerTextLayoutManager`;
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
    /// Source-text length limit (UTF-16, soft breaks excluded); nil = unlimited. It only constrains user edits:
    /// a string pushed in from outside is accepted as is and can only be shortened afterwards.
    var maxLength: Int?
    /// Called when a user edit is shortened or blocked by the limit; it fires once per over-limit episode and
    /// re-arms only after the length drops below the limit.
    var onLengthLimitExceeded: (@MainActor () -> Void)?

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
        // The layout manager is our own subclass so selection geometry queries are bounded by the viewport too
        // (see `ComposerTextLayoutManager`).
        let textView = ComposerUITextView.makeBoundedTextKit2()
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
        /// The length user edits may not push the source text past: max(limit, source length at the last settle).
        /// An overlong draft pushed in from outside can therefore only be shortened.
        private var lengthCeiling = 0
        /// Whether the over-limit notice may fire: set to false after it fires, back to true once the source text
        /// drops below the limit.
        private var limitNoticeArmed = true
        /// Where IME composition started (display-string offset): the limit is not enforced while composing, and
        /// after commit the span from here to the caret is what was just committed.
        private var compositionStart: Int?
        /// The display string when a Writing Tools rewrite began: nothing is truncated during the rewrite; afterwards
        /// it is diffed against this to find the rewritten span, which is then truncated if needed.
        private var writingToolsBaseline: String?
        private var isWritingToolsRunning = false
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
            self.lengthCeiling = parent.maxLength ?? 0
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
            // Content pushed in from outside is neither truncated nor announced (truncating would silently destroy
            // what the user already has); if it is overlong its length becomes the ceiling, so it can only be shortened.
            compositionStart = nil
            writingToolsBaseline = nil
            isWritingToolsRunning = false
            limitNoticeArmed = true
            if let limit = parent.maxLength {
                lengthCeiling = max(limit, Self.sourceLength(of: textView.textStorage.string as NSString))
            }
            contentDidChange(in: textView)
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            let length = (text as NSString).length
            // Whole-block insertions that bypass the paste delegate (a third-party keyboard's clipboard, dictation,
            // Live Text, programmatic insertText): UIKit lays the whole block out in the viewport to place the caret
            // right after inserting, 17s on the main thread for a single 200K-character Arabic paragraph, too late for
            // the after-the-fact split. Intercept before the insertion and write the split display string into
            // storage ourselves, so an overlong paragraph never reaches storage.
            // The length limit is also checked here first: the part that does not fit is cut before it reaches storage.
            if let composer = textView as? ComposerUITextView,
               interceptInsertion(text, in: range, of: composer) {
                return false
            }
            // This replacement follows right after the paste delegate handed out its display string; don't compare
            // contents, smart insert may add spaces at either end.
            pendingEdit = (NSRange(location: range.location, length: length), pendingPasteDisplay != nil)
            pendingPasteDisplay = nil
            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplying, let textView = textView as? ComposerUITextView else { return }
            enforceLengthLimitAfterEdit(in: textView)
            normalizeAndSplitEditedRange(in: textView)
            let source = SoftParagraphBreaks.source(fromDisplay: textView.textStorage.string)
            publishedSource = source
            contentDidChange(in: textView)
            if parent.text != source {
                parent.text = source
            }
        }

        // MARK: Length limit

        /// The source-text length (UTF-16) of a range of the display string: soft breaks are excluded. There is only
        /// one soft break per couple of thousand code units, so very few lookups are needed.
        static func sourceLength(of text: NSString, in range: NSRange? = nil) -> Int {
            let range = range ?? NSRange(location: 0, length: text.length)
            var separators = 0
            var search = range
            while search.length > 0 {
                let found = text.range(of: SoftParagraphBreaks.separatorString, options: .literal, range: search)
                guard found.location != NSNotFound else { break }
                separators += 1
                search = NSRange(location: NSMaxRange(found), length: NSMaxRange(range) - NSMaxRange(found))
            }
            return range.length - separators
        }

        private func noteLengthLimitExceeded() {
            guard limitNoticeArmed else { return }
            limitNoticeArmed = false
            parent.onLengthLimitExceeded?()
        }

        private func isLengthLimitSuspended(for textView: UITextView) -> Bool {
            isWritingToolsRunning || textView.isWritingToolsActive
        }

        /// The pre-insertion entry point (shared by shouldChangeTextIn and the insertText override): truncate to the
        /// length limit first, then split overlong paragraphs.
        /// Returns true when this insertion has been handled here (written to storage or blocked outright) and the
        /// caller must drop the original insertion.
        func interceptInsertion(_ text: String, in range: NSRange, of textView: ComposerUITextView) -> Bool {
            guard let kept = lengthLimitedInsertion(text, in: range, of: textView) else {
                return replaceIfOverlong(text, in: range, of: textView)
            }
            if !kept.isEmpty {
                replaceWithSoftBrokenDisplay(SoftParagraphBreaks.display(forSource: kept), in: range, of: textView)
            }
            return true
        }

        /// When this insertion would push the source text past the ceiling, returns the leading part that fits
        /// ("" = not even one grapheme fits); returns nil when it does not overflow.
        /// Composition, display strings the paste delegate already truncated, and Writing Tools rewrites are not
        /// judged here; they are left to textViewDidChange.
        private func lengthLimitedInsertion(_ text: String, in range: NSRange, of textView: ComposerUITextView) -> String? {
            guard parent.maxLength != nil,
                  pendingPasteDisplay == nil,
                  !text.isEmpty,
                  textView.markedTextRange == nil,
                  !isLengthLimitSuspended(for: textView) else { return nil }
            let incoming = text as NSString
            let room = roomForInsertion(replacing: range, in: textView, upperBoundIncoming: incoming.length)
            guard incoming.length > room else { return nil }
            noteLengthLimitExceeded()
            return Self.prefix(of: incoming, fittingUTF16: room)
        }

        /// How many source code units still fit after `range` is replaced. Storage holds the display string with soft
        /// breaks, so both the remainder and the replaced range are measured in source text.
        /// `upperBoundIncoming` is only a shortcut: the display string is never shorter than the source text, so if it
        /// fits when measured on the display string there is no need to count soft breaks.
        private func roomForInsertion(replacing range: NSRange, in textView: UITextView, upperBoundIncoming: Int) -> Int {
            let storage = textView.textStorage
            let location = min(range.location, storage.length)
            let safeRange = NSRange(location: location, length: min(range.length, storage.length - location))
            if storage.length - safeRange.length + upperBoundIncoming <= lengthCeiling {
                return Int.max
            }
            let text = storage.string as NSString
            let remaining = Self.sourceLength(of: text) - Self.sourceLength(of: text, in: safeRange)
            return lengthCeiling - remaining
        }

        /// The longest prefix of at most `room` code units, with the cut moved back to a grapheme boundary (never
        /// splitting a surrogate pair, combining sequence or ZWJ sequence).
        static func prefix(of text: NSString, fittingUTF16 room: Int) -> String {
            guard room > 0 else { return "" }
            guard room < text.length else { return text as String }
            return text.substring(to: text.rangeOfComposedCharacterSequence(at: room).location)
        }

        /// After-the-fact truncation: when a path that skips the pre-insertion entry point (IME commit, Writing Tools,
        /// some system services, spaces added by smart insert) pushes the source text past the ceiling, the tail of
        /// the span just edited is cut. Undo and redo only return to content that was once accepted and are not truncated.
        private func enforceLengthLimitAfterEdit(in textView: ComposerUITextView, rewritten: NSRange? = nil) {
            guard parent.maxLength != nil else { return }
            let storage = textView.textStorage
            if let marked = textView.markedTextRange {
                if compositionStart == nil {
                    compositionStart = textView.offset(from: textView.beginningOfDocument, to: marked.start)
                }
                return
            }
            guard rewritten != nil || !isLengthLimitSuspended(for: textView) else { return }
            let composedFrom = compositionStart
            compositionStart = nil
            defer { settleLength(in: textView) }
            guard storage.length > lengthCeiling else { return }
            let text = storage.string as NSString
            let overflow = Self.sourceLength(of: text) - lengthCeiling
            guard overflow > 0 else { return }
            if let undoManager = textView.undoManager, undoManager.isUndoing || undoManager.isRedoing { return }

            let caret = min(textView.selectedRange.location, text.length)
            // The span just edited, [floor, end): rewritten range > composition range > the range shouldChangeTextIn
            // recorded > inferred from the length delta.
            let fromPasteDelegate = pendingEdit?.fromPasteDelegate ?? (pendingPasteDisplay != nil)
            let floor: Int
            let end: Int
            if let rewritten {
                floor = min(rewritten.location, text.length)
                end = min(NSMaxRange(rewritten), text.length)
            } else if let composedFrom, composedFrom <= caret {
                (floor, end) = (composedFrom, caret)
            } else if let edit = pendingEdit ?? inferredEdit(caret: caret, length: text.length) {
                floor = min(edit.range.location, text.length)
                end = min(NSMaxRange(edit.range), text.length)
            } else {
                (floor, end) = (0, caret)
            }
            // Count overflow source code units back from the end of the span (soft breaks do not count), then back off
            // to a grapheme boundary; never go past the span start, so text before the span is untouched.
            var cut = end
            var remaining = overflow
            while remaining > 0, cut > floor {
                cut -= 1
                if text.character(at: cut) != SoftParagraphBreaks.separator { remaining -= 1 }
            }
            if cut > floor, cut < text.length {
                cut = max(floor, text.rangeOfComposedCharacterSequence(at: cut).location)
            }
            guard cut < end else { return }
            textView.inputDelegate?.textWillChange(textView)
            storage.replaceCharacters(in: NSRange(location: cut, length: end - cut), with: "")
            textView.selectedRange = NSRange(location: cut, length: 0)
            textView.inputDelegate?.textDidChange(textView)
            // Storage edits bypass the undo stack and older steps would point at shifted ranges (the same trade-off as
            // the fallback split).
            textView.undoManager?.removeAllActions()
            if rewritten == nil {
                pendingEdit = (NSRange(location: floor, length: cut - floor), fromPasteDelegate)
            } else {
                // The soft breaks inside the rewritten range were inserted by us and must not be handled below as
                // foreign insertions.
                pendingEdit = nil
                lastDisplayLength = storage.length
            }
            noteLengthLimitExceeded()
        }

        /// After an edit settles: update the ceiling (it only comes down, never below the limit) and re-arm the
        /// notice once the source text is back under the limit.
        private func settleLength(in textView: UITextView) {
            guard let limit = parent.maxLength else { return }
            let storage = textView.textStorage
            // The display string is never shorter than the source text: when it is under the limit, soft breaks need not be counted.
            let length = storage.length < limit ? storage.length : Self.sourceLength(of: storage.string as NSString)
            lengthCeiling = max(limit, length)
            if length < limit { limitNoticeArmed = true }
        }

        // MARK: Writing Tools

        func textViewWritingToolsWillBegin(_ textView: UITextView) {
            isWritingToolsRunning = true
            writingToolsBaseline = textView.textStorage.string
        }

        /// Nothing is truncated during a rewrite (that would interrupt the system's inline animation and its own range
        /// bookkeeping); once it ends, the rewritten span is found by diffing and any overflowing tail is cut here.
        func textViewWritingToolsDidEnd(_ textView: UITextView) {
            isWritingToolsRunning = false
            let baseline = writingToolsBaseline
            writingToolsBaseline = nil
            guard !isApplying, let textView = textView as? ComposerUITextView, textView.markedTextRange == nil else { return }
            let current = textView.textStorage.string as NSString
            let rewritten = baseline.map { Self.changedRange(from: $0 as NSString, to: current) }
                ?? NSRange(location: 0, length: current.length)
            enforceLengthLimitAfterEdit(
                in: textView,
                rewritten: rewritten.length > 0 ? rewritten : NSRange(location: 0, length: current.length)
            )
            textViewDidChange(textView)
        }

        /// The span of the new string that differs from the old one: the common prefix and common suffix are removed.
        static func changedRange(from old: NSString, to new: NSString) -> NSRange {
            let limit = min(old.length, new.length)
            var prefix = 0
            while prefix < limit, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
            var suffix = 0
            while suffix < limit - prefix,
                  old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) {
                suffix += 1
            }
            return NSRange(location: prefix, length: new.length - prefix - suffix)
        }

        /// Rewrites an insertion containing an overlong paragraph into the split display string and returns true
        /// (the caller drops the original insertion). Display strings handed out by the paste delegate and
        /// insertions during IME composition are left alone.
        func replaceIfOverlong(_ text: String, in range: NSRange, of textView: ComposerUITextView) -> Bool {
            guard pendingPasteDisplay == nil,
                  (text as NSString).length > SoftParagraphBreaks.maxParagraphUTF16,
                  textView.markedTextRange == nil else { return false }
            let display = SoftParagraphBreaks.display(forSource: text)
            guard display != text else { return false }
            replaceWithSoftBrokenDisplay(display, in: range, of: textView)
            return true
        }

        /// Writes the split display string on the inserter's behalf. Storage is edited directly and bypasses the undo
        /// stack (the same trade-off as the after-the-fact split: older steps would point at shifted ranges, so the
        /// stack is cleared), and the input system is notified once, as for any programmatic change. The edited range
        /// is marked as our own insertion so the U+2029 in the display string is not taken for foreign text and
        /// turned into \n.
        private func replaceWithSoftBrokenDisplay(_ display: String, in range: NSRange, of textView: ComposerUITextView) {
            let storage = textView.textStorage
            let safeRange = NSRange(
                location: min(range.location, storage.length),
                length: min(range.length, max(0, storage.length - min(range.location, storage.length)))
            )
            let length = (display as NSString).length
            textView.inputDelegate?.textWillChange(textView)
            storage.replaceCharacters(in: safeRange, with: NSAttributedString(string: display, attributes: textAttributes(parent)))
            textView.selectedRange = NSRange(location: safeRange.location + length, length: 0)
            textView.inputDelegate?.textDidChange(textView)
            pendingEdit = (NSRange(location: safeRange.location, length: length), true)
            textViewDidChange(textView)
            textView.undoManager?.removeAllActions()
            textView.scrollRangeToVisible(textView.selectedRange)
        }

        /// Infers, from the length delta, an insertion that never went through shouldChangeTextIn: the inserted
        /// content ends at the caret.
        private func inferredEdit(caret: Int, length: Int) -> (range: NSRange, fromPasteDelegate: Bool)? {
            let delta = length - lastDisplayLength
            guard delta > 0 else { return nil }
            let location = max(0, caret - delta)
            return (NSRange(location: location, length: min(delta, length - location)), pendingPasteDisplay != nil)
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
            let edit = pendingEdit ?? inferredEdit(caret: caret, length: text.length)
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
            var joined = itemStrings.map(\.string).joined(separator: "\n")
            // Length limit: truncate first, then split into paragraphs, still letting the system do the insertion (the
            // undo stack is kept). The part that does not fit never enters storage.
            if parent.maxLength != nil,
               let textView = textPasteConfigurationSupporting as? ComposerUITextView,
               textView.markedTextRange == nil {
                let incoming = joined as NSString
                let range = NSRange(
                    location: textView.offset(from: textView.beginningOfDocument, to: textRange.start),
                    length: textView.offset(from: textRange.start, to: textRange.end)
                )
                let room = roomForInsertion(replacing: range, in: textView, upperBoundIncoming: incoming.length)
                if incoming.length > room {
                    noteLengthLimitExceeded()
                    joined = Self.prefix(of: incoming, fittingUTF16: room)
                }
            }
            let display = SoftParagraphBreaks.display(forSource: joined)
            // An empty string will not trigger shouldChangeTextIn again: leave no marker behind, or the next unrelated
            // insertion would be mistaken for a paste.
            pendingPasteDisplay = display.isEmpty ? nil : display
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
    /// Nothing else holds the content storage strongly (the layout manager references it weakly), so the view
    /// keeps it alive.
    private var ownedContentStorage: NSTextContentStorage?
    private(set) var boundedLayoutManager: ComposerTextLayoutManager?

    /// The production constructor: TextKit 2 with a `ComposerTextLayoutManager`.
    /// Equivalent to `UITextView(usingTextLayoutManager: true)` except for the layout manager subclass.
    static func makeBoundedTextKit2() -> ComposerUITextView {
        let contentStorage = NSTextContentStorage()
        let layoutManager = ComposerTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.textContainer = container
        let textView = ComposerUITextView(frame: .zero, textContainer: container)
        textView.ownedContentStorage = contentStorage
        textView.boundedLayoutManager = layoutManager
        return textView
    }

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

    /// The keyboard (including a third-party keyboard's clipboard), dictation and programmatic insertion all land
    /// here, and some of those paths never ask shouldChangeTextIn first, so intercept at the entry point too
    /// (overlong-paragraph splitting and the length limit share this entry point).
    override func insertText(_ text: String) {
        if let coordinator, coordinator.interceptInsertion(text, in: selectedRange, of: self) { return }
        super.insertText(text)
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

/// The composer's TextKit 2 layout manager: keeps geometry queries over a large range near the viewport.
///
/// A scrollable TextKit 2 view normally lays out only the paragraphs in its viewport, but UIKit does not when it
/// asks "where is this range":
/// - every tap on the text runs the selection interaction's repeated-tap check, which asks whether the point is
///   inside the selection and enumerates the **whole selection** segment by segment to get its bounding rect;
/// - `selectionRects(for:)` and `firstRect(for:)` (selection highlight, edit menu placement) enumerate the whole
///   range the same way.
/// All of them end up in `enumerateTextSegments(in:type:options:using:)`, whose cost grows with the length of
/// the range, and TextKit 2 keeps no layout outside the viewport, so every question lays the whole text out
/// again. After Select All on a long text each tap is a full-document layout: about 420–490 ms per tap for
/// 500K CJK characters on a simulator, and several seconds of main-thread hang on a device.
///
/// What happens here: when the range is longer than `passThroughUTF16`, only three pieces are enumerated — the
/// head of the range, the intersection of the range with the area around the viewport, and the tail of the range.
/// - The selection rects visible in the viewport are unchanged (the viewport piece is enumerated as usual);
/// - The overall bounding rect still spans from the top of the first line to the bottom of the last one (both
///   the head and the tail pieces are there), so "is this tap inside the selection" answers the same;
/// - Highlights that scroll into view are requested again by UIKit with a small range near the viewport, so
///   they are unaffected.
/// Locked by `ComposerSelectionGeometryTests`.
nonisolated final class ComposerTextLayoutManager: NSTextLayoutManager {
    /// Ranges up to this length go to the system untouched (a few display paragraphs at most; already bounded).
    static let passThroughUTF16 = 8_192
    /// The length kept at the head and at the tail, and the padding added on each side of the viewport.
    static let edgeUTF16 = 2_048

    /// Observed by tests: how many queries were bounded, and the total length (UTF-16) handed to the system.
    private(set) var boundedQueryCount = 0
    private(set) var enumeratedUTF16 = 0
    #if DEBUG
    /// Test seam: turns bounding off to measure the system's own cost (the regression tests use it to show that
    /// an unbounded query really covers the whole text).
    var _testDisableBounding = false
    #endif

    override func enumerateTextSegments(
        in textRange: NSTextRange,
        type: NSTextLayoutManager.SegmentType,
        options: NSTextLayoutManager.SegmentOptions = [],
        using block: (NSTextRange?, CGRect, CGFloat, NSTextContainer) -> Bool
    ) {
        guard let pieces = boundedPieces(for: textRange) else {
            enumeratedUTF16 &+= offset(from: textRange.location, to: textRange.endLocation)
            super.enumerateTextSegments(in: textRange, type: type, options: options, using: block)
            return
        }
        boundedQueryCount &+= 1
        var keepGoing = true
        for piece in pieces where keepGoing {
            enumeratedUTF16 &+= offset(from: piece.location, to: piece.endLocation)
            super.enumerateTextSegments(in: piece, type: type, options: options) { range, frame, baseline, container in
                keepGoing = block(range, frame, baseline, container)
                return keepGoing
            }
        }
    }

    /// nil when the range is short enough (no bounding); otherwise non-overlapping pieces in document order.
    func boundedPieces(for textRange: NSTextRange) -> [NSTextRange]? {
        let start = textRange.location
        let end = textRange.endLocation
        guard offset(from: start, to: end) > Self.passThroughUTF16 else { return nil }
        #if DEBUG
        if _testDisableBounding { return nil }
        #endif
        var candidates: [(NSTextLocation, NSTextLocation)] = []
        if let headEnd = location(start, offsetBy: Self.edgeUTF16) {
            candidates.append((start, headEnd))
        }
        if let viewport = textViewportLayoutController.viewportRange {
            let lower = location(viewport.location, offsetBy: -Self.edgeUTF16) ?? documentRange.location
            let upper = location(viewport.endLocation, offsetBy: Self.edgeUTF16) ?? documentRange.endLocation
            let clampedLower = lower.compare(start) == .orderedAscending ? start : lower
            let clampedUpper = upper.compare(end) == .orderedDescending ? end : upper
            if clampedLower.compare(clampedUpper) == .orderedAscending {
                candidates.append((clampedLower, clampedUpper))
            }
        }
        if let tailStart = location(end, offsetBy: -Self.edgeUTF16) {
            candidates.append((tailStart, end))
        }
        candidates.sort { $0.0.compare($1.0) == .orderedAscending }
        var merged: [(NSTextLocation, NSTextLocation)] = []
        for candidate in candidates {
            if let last = merged.last, candidate.0.compare(last.1) != .orderedDescending {
                if candidate.1.compare(last.1) == .orderedDescending {
                    merged[merged.count - 1].1 = candidate.1
                }
            } else {
                merged.append(candidate)
            }
        }
        let pieces = merged.compactMap { NSTextRange(location: $0.0, end: $0.1) }
        return pieces.isEmpty ? nil : pieces
    }
}
