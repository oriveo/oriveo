import QuartzCore
import SwiftUI
import Testing
import UIKit
@testable import Oriveo

/// Regression lock for the composer freezing on a very long paste.
///
/// The old input was a SwiftUI `TextField(axis: .vertical)`: TextKit 2 lays text out paragraph by paragraph, SwiftUI
/// measures every layout under several size proposals and each measurement throws all layout away, so one unbroken
/// pasted Arabic paragraph was laid out in full on every layout pass. Before the fix, on a simulator, an 8K Arabic
/// paragraph blocked the main thread for 4.0 s on paste, 7.8 s on the next keystroke and 15.9 s when the keyboard
/// was dismissed and shown again. This suite pins machine-independent structure: display paragraphs are bounded, the
/// binding holds the source text, and measurement only lays out a cached prefix. Wall-clock numbers are only printed.
@MainActor
@Suite("Composer text view - long paste stays bounded", .serialized)
struct ComposerTextViewTests {
    static let arabicSentence = "هذا نص تجريبي طويل باللغة العربية لاختبار أداء التخطيط في مربع الإدخال، ويحتوي على كلمات متعددة وعلامات ترقيم مختلفة. "

    static func arabic(utf16: Int) -> String {
        var out = ""
        while out.utf16.count < utf16 { out += arabicSentence }
        return out
    }

    static func longestParagraphUTF16(_ text: String) -> Int {
        let ns = text as NSString
        var longest = 0
        var location = 0
        while location < ns.length {
            let range = ns.paragraphRange(for: NSRange(location: location, length: 0))
            longest = max(longest, range.length)
            location = max(NSMaxRange(range), location + 1)
        }
        return longest
    }

    // MARK: - Display-only soft breaks (pure functions)

    @Test("short text passes through without soft breaks")
    func shortTextUnchanged() {
        let text = "Hello\nمرحبا\nこんにちは 👋🏽"
        #expect(SoftParagraphBreaks.display(forSource: text) == text)
        #expect(SoftParagraphBreaks.source(fromDisplay: text) == text)
    }

    @Test("a long single paragraph splits into bounded display paragraphs and restores to the exact source")
    func longParagraphRoundTrip() {
        for source in [
            Self.arabic(utf16: 64_000),
            String(repeating: "にほんごのながいぶんしょうで、かいぎょうがありません。", count: 2_000),
            String(repeating: "emoji 👩‍👩‍👧‍👦 and combining e\u{301} ", count: 3_000),
            String(repeating: "x", count: 30_000),
        ] {
            let display = SoftParagraphBreaks.display(forSource: source)
            #expect(display.utf16.contains(SoftParagraphBreaks.separator), "an overlong paragraph should be split")
            #expect(Self.longestParagraphUTF16(display) <= SoftParagraphBreaks.maxParagraphUTF16 + 1)
            #expect(SoftParagraphBreaks.source(fromDisplay: display) == source, "restoring must give back the exact source")
        }
    }

    @Test("a U+2029 in the source becomes a newline so it is never removed as a soft break")
    func sourceParagraphSeparatorNormalized() {
        let source = "first\u{2029}second"
        let display = SoftParagraphBreaks.display(forSource: source)
        #expect(display == "first\nsecond")
        #expect(SoftParagraphBreaks.source(fromDisplay: display) == "first\nsecond")
    }

    // MARK: - UIKit view

    private final class Box {
        var text = ""
        var focused = false
    }

    private func representable(
        _ box: Box,
        isEnabled: Bool = true,
        font: UIFont = .systemFont(ofSize: 16),
        maxLength: Int? = nil,
        onLengthLimitExceeded: (@MainActor () -> Void)? = nil
    ) -> ComposerTextView {
        ComposerTextView(
            text: Binding(get: { box.text }, set: { box.text = $0 }),
            isFocused: Binding(get: { box.focused }, set: { box.focused = $0 }),
            placeholder: "Type a message...",
            font: font,
            textColor: .label,
            isEnabled: isEnabled,
            maxLength: maxLength,
            onLengthLimitExceeded: onLengthLimitExceeded
        )
    }

    private func makeView(
        box: Box,
        width: CGFloat = 320,
        font: UIFont = .systemFont(ofSize: 16),
        maxLength: Int? = nil,
        onLengthLimitExceeded: (@MainActor () -> Void)? = nil
    ) -> (ComposerUITextView, ComposerTextView.Coordinator, UIWindow) {
        let representable = representable(box, font: font, maxLength: maxLength, onLengthLimitExceeded: onLengthLimitExceeded)
        let coordinator = representable.makeCoordinator()
        let container = ComposerTextView.makeContainer(coordinator: coordinator)
        coordinator.applyStyle(representable, to: container, force: true)
        coordinator.apply(box.text, to: container.textView)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width + 40, height: 600))
        container.frame = CGRect(x: 20, y: 100, width: width, height: 110)
        window.addSubview(container)
        window.isHidden = false
        container.layoutIfNeeded()
        return (container.textView, coordinator, window)
    }

    private func placeholderLabel(of textView: UITextView) -> UILabel? {
        textView.superview?.subviews.compactMap { $0 as? UILabel }.first
    }

    @Test("placeholder: visible when empty, hidden with text, back after clearing")
    func placeholderFollowsContent() throws {
        let box = Box()
        let (textView, coordinator, window) = makeView(box: box)
        defer { window.isHidden = true }
        let label = try #require(placeholderLabel(of: textView), "the placeholder label must sit in the container next to the text view")
        #expect(label.text == "Type a message...")
        #expect(!label.isHidden, "empty text should show the placeholder")
        #expect(label.frame.width > 0 && label.frame.height > 0, "placeholder frame is empty: \(label.frame)")
        coordinator.apply("hello", to: textView)
        #expect(label.isHidden, "text should hide the placeholder")
        coordinator.apply("", to: textView)
        #expect(!label.isHidden, "clearing should show the placeholder again")
    }

    @Test("keyboard-driven writing direction is suppressed: Arabic inserted under an English keyboard stays natural (first strong character)")
    func typedRightToLeftTextStaysNatural() async throws {
        let box = Box()
        let (textView, _, window) = makeView(box: box)
        defer { window.isHidden = true }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let keyWindow = UIWindow(windowScene: scene)
        keyWindow.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        keyWindow.rootViewController = UIViewController()
        keyWindow.makeKeyAndVisible()
        defer { keyWindow.isHidden = true }
        let container = try #require(textView.superview)
        keyWindow.rootViewController?.view.addSubview(container)
        textView.becomeFirstResponder()
        try await Task.sleep(for: .milliseconds(300))
        let typing = textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle
        #expect((typing?.baseWritingDirection ?? .natural) == .natural, "typingAttributes carry a pinned direction: \(String(describing: typing?.baseWritingDirection.rawValue))")
        textView.insertText("مرحبا، كيف حالك اليوم؟")
        let style = textView.textStorage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect((style?.baseWritingDirection ?? .natural) == .natural, "the inserted Arabic paragraph got a pinned direction: \(String(describing: style?.baseWritingDirection.rawValue))")
    }

    @Test("the paste delegate splits before inserting, so pasted text never reaches the storage in one piece")
    func pasteDelegateSplitsBeforeInsert() throws {
        let box = Box()
        let (textView, coordinator, window) = makeView(box: box)
        defer { window.isHidden = true }
        let source = Self.arabic(utf16: 32_000)
        let range = try #require(textView.textRange(from: textView.endOfDocument, to: textView.endOfDocument))
        let combined = coordinator.textPasteConfigurationSupporting(
            textView,
            combineItemAttributedStrings: [NSAttributedString(string: source)],
            for: range
        )
        #expect(Self.longestParagraphUTF16(combined.string) <= SoftParagraphBreaks.maxParagraphUTF16 + 1)
        #expect(SoftParagraphBreaks.source(fromDisplay: combined.string) == source)
        let font = combined.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        #expect(font == UIFont.systemFont(ofSize: 16), "pasted text takes the field's font, not rich text styles from the pasteboard")
    }

    @Test("a whole-paragraph insert that bypasses the paste delegate is split as a fallback and the binding keeps the source")
    func fallbackSplitKeepsSourceInBinding() {
        let box = Box()
        let (textView, coordinator, window) = makeView(box: box)
        defer { window.isHidden = true }
        let source = Self.arabic(utf16: 32_000)
        textView.insertText(source)
        coordinator.textViewDidChange(textView)
        #expect(Self.longestParagraphUTF16(textView.textStorage.string) <= SoftParagraphBreaks.maxParagraphUTF16 + 1)
        #expect(box.text == source, "the binding (draft / send) must hold the source text without soft breaks")
        #expect(textView.selectedRange.location == textView.textStorage.length, "the caret should still be at the end after splitting")

        textView.insertText("x")
        coordinator.textViewDidChange(textView)
        #expect(box.text == source + "x")
    }

    @Test("a long source pushed from outside is split for display and the published source is unchanged")
    func externalApplyKeepsSource() {
        let box = Box()
        box.text = Self.arabic(utf16: 20_000)
        let (textView, coordinator, window) = makeView(box: box)
        defer { window.isHidden = true }
        #expect(Self.longestParagraphUTF16(textView.textStorage.string) <= SoftParagraphBreaks.maxParagraphUTF16 + 1)
        #expect(coordinator.publishedSource == box.text)
        // Never read `layoutManager` in tests: that drops the view into TextKit 1 compatibility mode.
        #expect(textView.textLayoutManager != nil, "must be TextKit 2: the old TextField's editing engine, laid out by viewport while scrolling")
    }

    @Test("copying or cutting a selection with soft breaks puts the source text on the pasteboard")
    func copyAndCutRestoreSource() throws {
        let box = Box()
        box.text = Self.arabic(utf16: 10_000)
        let (textView, _, window) = makeView(box: box)
        defer { window.isHidden = true }
        let pasteboard = try #require(UIPasteboard(name: UIPasteboard.Name("composer-test-\(UUID().uuidString)"), create: true))
        textView.sourcePasteboard = pasteboard
        textView.selectedRange = NSRange(location: 0, length: textView.textStorage.length)
        textView.copy(nil)
        #expect(pasteboard.string == box.text)
        textView.cut(nil)
        #expect(pasteboard.string == Self.arabic(utf16: 10_000))
        UIPasteboard.remove(withName: pasteboard.name)
    }

    @Test("height: one line when empty, real line count below the limit, clamped at 5 lines")
    func measuredHeightFollowsLines() {
        let box = Box()
        let (textView, coordinator, window) = makeView(box: box)
        defer { window.isHidden = true }
        let font = UIFont.systemFont(ofSize: 16)
        let oneLine = coordinator.measuredHeight(width: 320, textView: textView)
        #expect(abs(oneLine - font.lineHeight) < 1, "empty text should be one line tall, got \(oneLine)")

        coordinator.apply("one\ntwo\nthree", to: textView)
        let three = coordinator.measuredHeight(width: 320, textView: textView)
        #expect(three > oneLine * 2.5 && three < oneLine * 3.5, "three lines should be about three line heights, got \(three)")

        coordinator.apply((1...9).map { "line \($0)" }.joined(separator: "\n"), to: textView)
        let clamped = coordinator.measuredHeight(width: 320, textView: textView)
        #expect(clamped > oneLine * 4.5 && clamped < oneLine * 5.5, "more than 5 lines should clamp at 5, got \(clamped)")

        coordinator.apply("trailing newline\n", to: textView)
        let trailing = coordinator.measuredHeight(width: 320, textView: textView)
        #expect(trailing > oneLine * 1.5, "after a trailing newline the caret is on a new line and the height includes it, got \(trailing)")
    }

    @Test("measurement is bounded and cached: long text lays out only a prefix, repeated layout does not, probing proposals never do")
    func measurementIsBoundedAndCached() {
        let box = Box()
        box.text = Self.arabic(utf16: 64_000)
        let (textView, coordinator, window) = makeView(box: box)
        defer { window.isHidden = true }
        let before = coordinator.measurePasses
        let height = coordinator.measuredHeight(width: 300, textView: textView)
        #expect(coordinator.measurePasses - before == 1, "the first prefix already fills 5 lines, so one pass is enough")
        _ = coordinator.measuredHeight(width: 300, textView: textView)
        _ = coordinator.measuredHeight(width: nil, textView: textView)
        _ = coordinator.measuredHeight(width: 0, textView: textView)
        _ = coordinator.measuredHeight(width: .infinity, textView: textView)
        #expect(coordinator.measurePasses - before == 1, "repeated measurement at the same width and probing proposals must not lay out again")
        #expect(height > UIFont.systemFont(ofSize: 16).lineHeight * 4.5)
    }

    @Test("measurement returns when the first grapheme cluster is longer than the prefix (a text bomb) instead of looping forever")
    func measurementTerminatesOnHugeGraphemeCluster() {
        let box = Box()
        box.text = "e" + String(repeating: "\u{0301}", count: 1_500) + " tail"
        let (textView, coordinator, window) = makeView(box: box)
        defer { window.isHidden = true }
        let height = coordinator.measuredHeight(width: 300, textView: textView)
        #expect(height > 0)
    }

    @Test("several long paragraphs inserted at once and ending in a newline: every paragraph in the edited range is split and the binding keeps the source")
    func multiParagraphInsertIsSplitEverywhere() {
        let box = Box()
        let (textView, coordinator, window) = makeView(box: box)
        defer { window.isHidden = true }
        let paragraph = Self.arabic(utf16: 12_000)
        let source = paragraph + "\n" + paragraph + "\n"
        textView.insertText(source)
        coordinator.textViewDidChange(textView)
        #expect(Self.longestParagraphUTF16(textView.textStorage.string) <= SoftParagraphBreaks.maxParagraphUTF16 + 1,
                "every overlong paragraph in the edited range must be split (not only the empty caret paragraph)")
        #expect(box.text == source)
    }

    @Test("a U+2029 in a foreign insert becomes a newline, so restoring the source never removes it as a soft break")
    func foreignParagraphSeparatorBecomesNewline() {
        let box = Box()
        let (textView, coordinator, window) = makeView(box: box)
        defer { window.isHidden = true }
        textView.insertText("first\u{2029}second")
        coordinator.textViewDidChange(textView)
        #expect(box.text == "first\nsecond", "the two paragraphs must not be glued into firstsecond: \(box.text)")
    }

    @Test("splitting with the caret mid-document keeps the caret right after the inserted text")
    func caretStaysAfterInsertedTextWhenSplittingMidDocument() {
        let box = Box()
        box.text = "tail"
        let (textView, coordinator, window) = makeView(box: box)
        defer { window.isHidden = true }
        textView.selectedRange = NSRange(location: 0, length: 0)
        let paragraph = Self.arabic(utf16: 10_000)
        textView.insertText(paragraph)
        coordinator.textViewDidChange(textView)
        let display = textView.textStorage.string as NSString
        let caret = textView.selectedRange.location
        #expect(display.substring(from: caret) == "tail", "the caret should sit right before the original tail, but is followed by \(display.substring(from: min(caret, display.length)).prefix(20))")
        #expect(box.text == paragraph + "tail")
    }

    @Test("a focus request while disabled snaps the binding back to false instead of popping the keyboard once enabled")
    func focusRequestWhileDisabledSnapsBack() async throws {
        let box = Box()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let disabled = representable(box, isEnabled: false)
        let coordinator = disabled.makeCoordinator()
        let container = ComposerTextView.makeContainer(coordinator: coordinator)
        coordinator.applyStyle(disabled, to: container, force: true)
        coordinator.apply("", to: container.textView)
        container.frame = CGRect(x: 20, y: 200, width: 300, height: 40)
        window.rootViewController?.view.addSubview(container)
        box.focused = true
        coordinator.scheduleFocusSync(for: container.textView)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!container.textView.isFirstResponder)
        #expect(box.focused == false, "a disabled field cannot take focus, so the binding should snap back to false")
    }

    @Test("disabling while focused resigns first responder asynchronously and the binding follows to false")
    func disablingWhileFocusedResignsAsynchronously() async throws {
        let box = Box()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let enabled = representable(box)
        let coordinator = enabled.makeCoordinator()
        let container = ComposerTextView.makeContainer(coordinator: coordinator)
        coordinator.applyStyle(enabled, to: container, force: true)
        coordinator.apply("draft", to: container.textView)
        container.frame = CGRect(x: 20, y: 200, width: 300, height: 40)
        window.rootViewController?.view.addSubview(container)
        box.focused = true
        coordinator.scheduleFocusSync(for: container.textView)
        try await Task.sleep(for: .milliseconds(200))
        #expect(container.textView.isFirstResponder)

        let disabled = representable(box, isEnabled: false)
        coordinator.parent = disabled
        coordinator.applyStyle(disabled, to: container, force: false)
        #expect(container.textView.isFirstResponder, "disabling must not resign synchronously inside the update stack")
        try await Task.sleep(for: .milliseconds(200))
        #expect(!container.textView.isFirstResponder)
        #expect(!container.textView.isEditable)
        #expect(box.focused == false)
    }

    private struct GrowthHost: View {
        @State var text = ""
        @State var focused = false
        var body: some View {
            VStack {
                Spacer()
                ComposerTextView(text: $text, isFocused: $focused, placeholder: "Type", font: .systemFont(ofSize: 16), textColor: .label)
                    .frame(width: 300)
            }
        }
    }

    @Test("typing line by line inside SwiftUI grows the field and caps it at 5 lines (height changes must reach SwiftUI)")
    func growsWithTypedLinesInsideSwiftUI() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        let host = UIHostingController(rootView: GrowthHost())
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await yieldMainActor(for: 0.5)
        let input = try #require(firstEditableTextView(in: host.view))
        let lineHeight = UIFont.systemFont(ofSize: 16).lineHeight
        #expect(abs(input.bounds.height - lineHeight.rounded(.up)) < 0.5, "should start one line tall, got \(input.bounds.height)")
        var heights: [CGFloat] = []
        for line in 1...7 {
            input.insertText(line == 1 ? "line 1" : "\nline \(line)")
            try await yieldMainActor(for: 0.2)
            heights.append(input.bounds.height)
        }
        #expect(heights[1] > heights[0] + lineHeight * 0.8, "line 2 did not grow the field: \(heights)")
        #expect(heights[2] > heights[1] + lineHeight * 0.8, "line 3 did not grow the field: \(heights)")
        #expect(heights[4] > lineHeight * 4.5 && heights[4] < lineHeight * 5.5, "unexpected height at 5 lines: \(heights)")
        #expect(abs(heights[6] - heights[4]) < 0.5, "more than 5 lines should be capped: \(heights)")
    }

    // MARK: - Production shape: the real ChatView

    private func yieldMainActor(for seconds: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func firstEditableTextView(in view: UIView) -> UITextView? {
        if let textView = view as? UITextView, textView.isEditable { return textView }
        for subview in view.subviews {
            if let found = firstEditableTextView(in: subview) { return found }
        }
        return nil
    }

    // MARK: - Length limit

    private final class LimitProbe {
        var notices = 0
    }

    private static let limit = ChatInputLimit.maxUTF16

    private func makeLimitedView(
        box: Box,
        probe: LimitProbe
    ) -> (ComposerUITextView, ComposerTextView.Coordinator, UIWindow) {
        makeView(box: box, maxLength: Self.limit, onLengthLimitExceeded: { probe.notices += 1 })
    }

    /// The production paste chain: paste delegate (truncate + split) -> shouldChangeTextIn -> the system writes the returned string into the selection -> textViewDidChange.
    private func paste(_ source: String, into textView: ComposerUITextView, _ coordinator: ComposerTextView.Coordinator) throws {
        let selection = try #require(textView.selectedTextRange)
        let combined = coordinator.textPasteConfigurationSupporting(
            textView,
            combineItemAttributedStrings: [NSAttributedString(string: source)],
            for: selection
        )
        let range = textView.selectedRange
        guard !combined.string.isEmpty || range.length > 0 else { return }
        guard coordinator.textView(textView, shouldChangeTextIn: range, replacementText: combined.string) else { return }
        textView.textStorage.replaceCharacters(in: range, with: combined)
        textView.selectedRange = NSRange(location: range.location + combined.length, length: 0)
        coordinator.textViewDidChange(textView)
    }

    private func type(_ text: String, into textView: ComposerUITextView, _ coordinator: ComposerTextView.Coordinator) {
        textView.insertText(text)
        coordinator.textViewDidChange(textView)
    }

    private func deleteBackward(in textView: ComposerUITextView, _ coordinator: ComposerTextView.Coordinator) {
        textView.deleteBackward()
        coordinator.textViewDidChange(textView)
    }

    private func count(of character: Character, in text: String) -> Int {
        text.reduce(0) { $0 + ($1 == character ? 1 : 0) }
    }

    @Test("a paste within the limit passes through unchanged without a notice")
    func limit_pasteWithinLimit_passesThrough() throws {
        let box = Box()
        let probe = LimitProbe()
        let (textView, coordinator, window) = makeLimitedView(box: box, probe: probe)
        defer { window.isHidden = true }
        try paste("hello \u{4F60}\u{597D} 👋🏽", into: textView, coordinator)
        #expect(box.text == "hello \u{4F60}\u{597D} 👋🏽")
        textView.selectedRange = NSRange(location: 0, length: textView.textStorage.length)
        let exact = String(repeating: "a", count: Self.limit)
        try paste(exact, into: textView, coordinator)
        #expect(box.text == exact, "a paste exactly at the limit is kept whole")
        #expect(probe.notices == 0)
    }

    @Test("a paste over the limit keeps the part that fits and shows one notice")
    func limit_pasteOverflow_keepsPrefixAndToastsOnce() throws {
        let box = Box()
        let probe = LimitProbe()
        let (textView, coordinator, window) = makeLimitedView(box: box, probe: probe)
        defer { window.isHidden = true }
        try paste(String(repeating: "a", count: 60_000), into: textView, coordinator)
        #expect(box.text == String(repeating: "a", count: Self.limit), "pasting 60,000 a's into an empty field leaves 50,000")
        #expect(probe.notices == 1)
        #expect(textView.textStorage.string.utf16.contains(SoftParagraphBreaks.separator), "the truncated text is still split into paragraphs")
        #expect(Self.longestParagraphUTF16(textView.textStorage.string) <= SoftParagraphBreaks.maxParagraphUTF16 + 1)
        #expect(textView.selectedRange.location == textView.textStorage.length)

        try paste("more", into: textView, coordinator)
        #expect(box.text.utf16.count == Self.limit)
        #expect(probe.notices == 1, "no repeat notice while the length has not dropped below the limit")
    }

    @Test("an overflowing paste in the middle leaves the text around it alone and puts the caret after the kept part")
    func limit_pasteInMiddle_keepsSurroundingTextAndCaret() throws {
        let head = String(repeating: "h", count: 30_000)
        let tail = String(repeating: "t", count: 19_990)
        let box = Box()
        box.text = head + tail
        let probe = LimitProbe()
        let (textView, coordinator, window) = makeLimitedView(box: box, probe: probe)
        defer { window.isHidden = true }
        let insertion = (textView.textStorage.string as NSString).range(of: "t").location
        textView.selectedRange = NSRange(location: insertion, length: 0)
        try paste("0123456789ABCDEFGHIJ", into: textView, coordinator)
        #expect(box.text == head + "0123456789" + tail, "only the tail of this insertion is cut")
        let display = textView.textStorage.string as NSString
        let caret = textView.selectedRange.location
        #expect(textView.selectedRange.length == 0)
        #expect(SoftParagraphBreaks.source(fromDisplay: display.substring(from: caret)) == tail, "what follows the caret should be exactly the original second half")
        #expect(display.substring(to: caret).hasSuffix("0123456789"))
        #expect(probe.notices == 1)
    }

    @Test("replacing a selection counts the removed source length as room (soft breaks excluded)")
    func limit_replaceSelection_countsRemovedRange() throws {
        let box = Box()
        box.text = String(repeating: "a", count: Self.limit)
        let probe = LimitProbe()
        let (textView, coordinator, window) = makeLimitedView(box: box, probe: probe)
        defer { window.isHidden = true }

        // Paste path: 100 display code units selected, one of them a soft break -> 99 source code units are freed.
        let first = NSRange(location: 2_000, length: 100)
        #expect((textView.textStorage.string as NSString).substring(with: first).utf16.contains(SoftParagraphBreaks.separator))
        textView.selectedRange = first
        try paste(String(repeating: "b", count: 150), into: textView, coordinator)
        #expect(count(of: "b", in: box.text) == 99)
        #expect(box.text.utf16.count == Self.limit)
        #expect(probe.notices == 1)

        // Keyboard, dictation and other whole-string insertion paths use the same rule.
        let second = NSRange(location: 6_100, length: 100)
        let removed = SoftParagraphBreaks.source(fromDisplay: (textView.textStorage.string as NSString).substring(with: second))
        #expect(removed.utf16.count == 99, "the selection should contain one soft break; actual source length \(removed.utf16.count)")
        textView.selectedRange = second
        type(String(repeating: "c", count: 150), into: textView, coordinator)
        #expect(count(of: "c", in: box.text) == 99)
        #expect(box.text.utf16.count == Self.limit)

        // Replacing with shorter content is not limited.
        textView.selectedRange = NSRange(location: 10, length: 5)
        type("dd", into: textView, coordinator)
        #expect(count(of: "d", in: box.text) == 2)
        #expect(box.text.utf16.count == Self.limit - 3)
    }

    @Test("typing at the limit is blocked with one notice, and re-arms only after dropping below the limit")
    func limit_typingAtLimit_blockedToastOnceUntilRearmed() {
        let box = Box()
        let full = String(repeating: "a", count: Self.limit)
        box.text = full
        let probe = LimitProbe()
        let (textView, coordinator, window) = makeLimitedView(box: box, probe: probe)
        defer { window.isHidden = true }
        for _ in 0..<3 { type("b", into: textView, coordinator) }
        #expect(box.text == full)
        #expect(coordinator.publishedSource == full)
        #expect(probe.notices == 1, "repeated typing shows only one notice")

        deleteBackward(in: textView, coordinator)
        #expect(box.text.utf16.count == Self.limit - 1)
        type("b", into: textView, coordinator)
        #expect(box.text.hasSuffix("ab") && box.text.utf16.count == Self.limit, "after dropping back, the field can be filled up to the limit again")
        #expect(probe.notices == 1)
        type("c", into: textView, coordinator)
        #expect(!box.text.contains("c"))
        #expect(probe.notices == 2, "re-armed after dropping below the limit")
    }

    @Test("IME composition is not truncated; the overflow is cut after commit")
    func limit_imeComposition_notCutWhileComposing_cutOnCommit() {
        let box = Box()
        let base = String(repeating: "a", count: Self.limit - 2)
        box.text = base
        let probe = LimitProbe()
        let (textView, coordinator, window) = makeLimitedView(box: box, probe: probe)
        defer { window.isHidden = true }
        textView.setMarkedText("nihaoma", selectedRange: NSRange(location: 7, length: 0))
        coordinator.textViewDidChange(textView)
        #expect(textView.markedTextRange != nil, "precondition: composition is in progress")
        #expect(box.text == base + "nihaoma", "the limit is not judged during composition")
        #expect(probe.notices == 0)

        textView.insertText("\u{4F60}\u{597D}\u{5417}")
        coordinator.textViewDidChange(textView)
        #expect(textView.markedTextRange == nil)
        #expect(box.text == base + "\u{4F60}\u{597D}", "the tail that does not fit is cut after commit")
        #expect(textView.selectedRange.location == textView.textStorage.length)
        #expect(probe.notices == 1)
    }

    @Test("the cut backs off to a grapheme boundary: no split surrogate pairs or ZWJ sequences, so the result may fall slightly under the limit")
    func limit_cutPoint_neverSplitsSurrogateOrGraphemeCluster() throws {
        let prefix = String(repeating: "a", count: Self.limit - 1)
        let family = "👨‍👩‍👧"
        // Paste
        do {
            let box = Box()
            let probe = LimitProbe()
            let (textView, coordinator, window) = makeLimitedView(box: box, probe: probe)
            defer { window.isHidden = true }
            try paste(prefix + family, into: textView, coordinator)
            #expect(box.text == prefix, "a grapheme crossing the limit is dropped whole, leaving 49,999")
            #expect(probe.notices == 1)
        }
        // Whole-string insertion (keyboard clipboard / dictation)
        do {
            let box = Box()
            let probe = LimitProbe()
            let (textView, coordinator, window) = makeLimitedView(box: box, probe: probe)
            defer { window.isHidden = true }
            type(prefix + "😀", into: textView, coordinator)
            #expect(box.text == prefix, "a surrogate pair must not keep only its first half")
            #expect(probe.notices == 1)
        }
        // After-the-fact truncation (IME commit)
        do {
            let box = Box()
            box.text = prefix
            let probe = LimitProbe()
            let (textView, coordinator, window) = makeLimitedView(box: box, probe: probe)
            defer { window.isHidden = true }
            textView.setMarkedText("x", selectedRange: NSRange(location: 1, length: 0))
            coordinator.textViewDidChange(textView)
            textView.insertText(family)
            coordinator.textViewDidChange(textView)
            #expect(box.text == prefix)
            #expect(probe.notices == 1)
        }
    }

    @Test("deletion is always allowed at or above the limit, without a notice")
    func limit_deleteAtOrAboveLimit_alwaysAllowed() {
        for length in [Self.limit, 60_000] {
            let box = Box()
            box.text = String(repeating: "a", count: length)
            let probe = LimitProbe()
            let (textView, coordinator, window) = makeLimitedView(box: box, probe: probe)
            defer { window.isHidden = true }
            deleteBackward(in: textView, coordinator)
            #expect(box.text.utf16.count == length - 1)
            textView.selectedRange = NSRange(location: 0, length: 10)
            deleteBackward(in: textView, coordinator)
            #expect(box.text.utf16.count == length - 11)
            #expect(probe.notices == 0)
        }
    }

    @Test("an overlong legacy draft is restored as is without truncation or notice, and can only be shortened afterwards")
    func limit_legacyOverlongDraft_restoredIntact_onlyShrinkAllowed() throws {
        let legacy = Self.arabic(utf16: 60_000)
        let length = legacy.utf16.count
        let box = Box()
        box.text = legacy
        let probe = LimitProbe()
        let (textView, coordinator, window) = makeLimitedView(box: box, probe: probe)
        defer { window.isHidden = true }
        #expect(coordinator.publishedSource == legacy, "programmatic writes are accepted as is")
        #expect(SoftParagraphBreaks.source(fromDisplay: textView.textStorage.string) == legacy)
        #expect(probe.notices == 0)

        type("x", into: textView, coordinator)
        #expect(box.text == legacy, "an overlong draft must not grow")
        #expect(probe.notices == 1)

        // Replacements of equal or shorter length still work: select 5 source code units, paste 8, keep only 5.
        let storageLength = textView.textStorage.length
        let selected = NSRange(location: storageLength - 5, length: 5)
        #expect(!(textView.textStorage.string as NSString).substring(with: selected).utf16.contains(SoftParagraphBreaks.separator))
        textView.selectedRange = selected
        try paste("12345678", into: textView, coordinator)
        #expect(box.text.utf16.count == length)
        #expect(box.text.hasSuffix("12345"))

        // After shortening, the new length is the ceiling.
        textView.selectedRange = NSRange(location: textView.textStorage.length - 10, length: 10)
        deleteBackward(in: textView, coordinator)
        #expect(box.text.utf16.count == length - 10)
        type("yyyyyyyyyyyy", into: textView, coordinator)
        #expect(!box.text.contains("y"), "still above the limit: freed room cannot be filled back in")
        #expect(box.text.utf16.count == length - 10)
    }

    @Test("Home input: same component, same limit, same notice")
    func limit_homeComposer_sameRule() throws {
        #expect(ChatInputLimit.maxUTF16 == 50_000)
        // Both hosts pass the shared constant and the shared notice to ComposerTextView.
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Oriveo/Features")
        for path in ["Home/HomeView.swift", "Chat/ChatComposerBar.swift"] {
            let source = try String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8)
            let call = try #require(source.range(of: "ComposerTextView("), "\(path) should use ComposerTextView")
            let arguments = source[call.upperBound...].prefix(900)
            #expect(arguments.contains("maxLength: ChatInputLimit.maxUTF16"), "\(path) does not pass the length limit")
            #expect(arguments.contains("onLengthLimitExceeded: ChatInputLimit.showLimitReachedToast"), "\(path) does not wire the over-limit notice")
        }

        // Built with the Home configuration (no placeholder, explicit accessibility name): the same rule applies and the notice goes through the single-slot toast.
        let box = Box()
        let home = ComposerTextView(
            text: Binding(get: { box.text }, set: { box.text = $0 }),
            isFocused: Binding(get: { box.focused }, set: { box.focused = $0 }),
            font: .systemFont(ofSize: 17),
            textColor: .label,
            accessibilityLabel: "Ask anything",
            maxLength: ChatInputLimit.maxUTF16,
            onLengthLimitExceeded: ChatInputLimit.showLimitReachedToast
        )
        let coordinator = home.makeCoordinator()
        let container = ComposerTextView.makeContainer(coordinator: coordinator)
        coordinator.applyStyle(home, to: container, force: true)
        coordinator.apply(box.text, to: container.textView)
        let message = ChatInputLimit.limitReachedMessage()
        #expect(!message.contains("%") && !message.contains("chat_input_length_limit_reached"), "the text is missing or the placeholder was not filled: \(message)")
        #expect(message.filter(\.isNumber).count == 5, "the number should be written out in full: \(message)")
        try paste(String(repeating: "a", count: 49_999) + "👨‍👩‍👧", into: container.textView, coordinator)
        #expect(box.text == String(repeating: "a", count: 49_999))
        #expect(ToastManager.shared.current?.message == message)
    }

    @Test("Writing Tools rewrites are not truncated while running; the tail of the rewritten span is cut at the end")
    func limit_writingTools_notCutWhileRewriting_cutOnEnd() {
        let box = Box()
        let head = String(repeating: "h", count: 10)
        let tail = String(repeating: "t", count: Self.limit - 40)
        box.text = head + "0123456789" + tail
        let probe = LimitProbe()
        let (textView, coordinator, window) = makeLimitedView(box: box, probe: probe)
        defer { window.isHidden = true }
        coordinator.textViewWritingToolsWillBegin(textView)
        textView.textStorage.replaceCharacters(in: NSRange(location: 10, length: 10), with: String(repeating: "W", count: 100))
        textView.selectedRange = NSRange(location: 110, length: 0)
        coordinator.textViewDidChange(textView)
        #expect(box.text.utf16.count == Self.limit + 70, "no truncation while the rewrite is running")
        #expect(probe.notices == 0)

        coordinator.textViewWritingToolsDidEnd(textView)
        #expect(box.text == head + String(repeating: "W", count: 30) + tail, "only the tail of the rewritten span is cut; the text before and after is untouched")
        #expect(probe.notices == 1)
    }

    @Test("real chat screen: after pasting a 32K single Arabic paragraph, typing and refocusing stay bounded and the draft is the source")
    func productionChatViewLongPaste() async throws {
        let previousUID = AppSessionStore.activeUID
        let uid = "composer-long-paste-\(UUID().uuidString)"
        defer {
            DatabaseManager.shared.close()
            AppSessionStore.switchToUser(previousUID)
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }
        DatabaseManager.shared.close()
        let provider = TestFactories.makeProvider(kind: .openAI)
        let conversation = TestFactories.makeConversation(
            title: "Long paste", providerID: provider.id, providerKind: .openAI, modelID: "gpt-4o",
            messages: (0..<4).map { index in
                TestFactories.makeMessage(
                    role: index.isMultiple(of: 2) ? .user : .assistant,
                    text: "Message \(index)", providerID: provider.id, modelID: "gpt-4o"
                )
            }
        )
        _ = try ConversationRuntimeBridge().replaceAllConversations([conversation], uid: uid)
        DatabaseManager.shared.close()
        let state = AppState(sessionUID: uid)
        defer { state.flushConversationPersistQueue() }
        // Switch after creating AppState: in a clean container the first AppState runs the partition migration and
        // switches back to the guest user.
        AppSessionStore.switchToUser(uid)
        state.providers = [provider]
        let host = UIHostingController(
            rootView: NavigationStack { ChatView(conversationID: conversation.id) }.environment(state)
        )
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 430, height: 932)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await yieldMainActor(for: 2.0)
        let input = try #require(firstEditableTextView(in: host.view) as? ComposerUITextView, "the chat input should be a ComposerUITextView")
        let coordinator = try #require(input.coordinator)
        #expect(coordinator.parent.maxLength == ChatInputLimit.maxUTF16, "the chat input must carry the length limit")
        #expect(input.textLayoutManager != nil, "the input must stay on TextKit 2 (touching layoutManager downgrades it)")
        input.becomeFirstResponder()
        try await yieldMainActor(for: 0.6)

        let paste = Self.arabic(utf16: 32_000)
        let probe = MainThreadStallProbe()
        probe.start()
        input.insertText(paste)
        try await yieldMainActor(for: 1.0)
        probe.stop()
        let pasteStall = probe.maxStall
        #expect(Self.longestParagraphUTF16(input.textStorage.string) <= SoftParagraphBreaks.maxParagraphUTF16 + 1)

        probe.start()
        input.insertText("x")
        try await yieldMainActor(for: 0.6)
        probe.stop()
        let keyStall = probe.maxStall

        let passesBeforeFocus = coordinator.measurePasses
        probe.start()
        input.resignFirstResponder()
        try await yieldMainActor(for: 0.8)
        input.becomeFirstResponder()
        try await yieldMainActor(for: 0.8)
        probe.stop()
        let focusStall = probe.maxStall
        #expect(coordinator.measurePasses == passesBeforeFocus, "relayout caused by focus / keyboard must not measure again (the content did not change)")
        #expect(coordinator.publishedSource == paste + "x", "the composer must receive the source text")

        print(String(
            format: "[HANG-COST] composer long paste (single Arabic paragraph, %d UTF-16) longest main-thread stall: paste %.0fms, one keystroke %.0fms, keyboard dismissed and shown %.0fms (before the fix, at 8K: 3954 / 7762 / 15942ms)",
            paste.utf16.count, pasteStall * 1000, keyStall * 1000, focusStall * 1000
        ))
    }
}
