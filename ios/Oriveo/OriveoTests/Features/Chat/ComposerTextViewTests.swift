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

    private func representable(_ box: Box, isEnabled: Bool = true, font: UIFont = .systemFont(ofSize: 16)) -> ComposerTextView {
        ComposerTextView(
            text: Binding(get: { box.text }, set: { box.text = $0 }),
            isFocused: Binding(get: { box.focused }, set: { box.focused = $0 }),
            placeholder: "Type a message...",
            font: font,
            textColor: .label,
            isEnabled: isEnabled
        )
    }

    private func makeView(
        box: Box,
        width: CGFloat = 320,
        font: UIFont = .systemFont(ofSize: 16)
    ) -> (ComposerUITextView, ComposerTextView.Coordinator, UIWindow) {
        let representable = representable(box, font: font)
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
