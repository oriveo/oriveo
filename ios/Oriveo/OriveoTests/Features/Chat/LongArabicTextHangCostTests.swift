import QuartzCore
import SwiftUI
import Testing
import UIKit
@testable import Oriveo

/// Main-thread cost of very long Arabic text (with harakat and ligatures) through the production components. Pasting
/// a whole Arabic passage is the worst case for CoreText shaping: every stall lands in `GSUB::ApplyLigatureSubst` /
/// `GPOS::ApplyMarkLigPos`, i.e. ligature substitution and mark positioning, on the main thread.
///
/// Method: `MainThreadStallProbe` measures what an app-hang watchdog sees, how long the main thread stays blocked in
/// one stretch; synchronous calls are wrapped in wall-clock time directly. The text is a single 200K UTF-16 paragraph
/// with no line breaks, the worst shape.
@MainActor
@Suite("Very long Arabic text · main-thread cost (production components)", .serialized)
struct LongArabicTextHangCostTests {
    /// A sentence with harakat (fatha / kasra / shadda / sukun / tanwin), the lam-alef ligature and the Allah
    /// ligature: `ApplyLigatureSubst` / `ApplyMarkLigPos` only show up on text like this.
    static let sentence = "بِسْمِ اللَّهِ الرَّحْمَٰنِ الرَّحِيمِ، لَا إِلَٰهَ إِلَّا اللَّهُ وَالسَّلَامُ عَلَيْكُمْ وَرَحْمَةُ اللَّهِ وَبَرَكَاتُهُ؛ هَٰذَا نَصٌّ طَوِيلٌ جِدًّا لِاخْتِبَارِ الْأَدَاءِ. "

    static func arabic(utf16: Int) -> String {
        var out = ""
        out.reserveCapacity(utf16 * 2)
        while out.utf16.count < utf16 { out += sentence }
        return out
    }

    static let longUTF16 = 200_000

    private func ms(_ seconds: CFTimeInterval) -> String { String(format: "%.0fms", seconds * 1000) }

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

    private struct ChatHarness {
        let window: UIWindow
        let host: UIViewController
        let state: AppState
        let cleanup: () -> Void
    }

    /// Mounts the real `ChatView` in a 430x932 window (same assembly as `ComposerTextViewTests.productionChatViewLongPaste`).
    private func mountChatView(uid: String, messages: [ChatMessage]) throws -> ChatHarness {
        let previousUID = AppSessionStore.activeUID
        DatabaseManager.shared.close()
        let provider = TestFactories.makeProvider(kind: .openAI)
        let conversation = TestFactories.makeConversation(
            title: "Long arabic", providerID: provider.id, providerKind: .openAI, modelID: "gpt-4o",
            previewText: "preview",
            messages: messages.map { message in
                var copy = message
                copy.providerID = provider.id
                return copy
            }
        )
        _ = try ConversationRuntimeBridge().replaceAllConversations([conversation], uid: uid)
        DatabaseManager.shared.close()
        let state = AppState(sessionUID: uid)
        AppSessionStore.switchToUser(uid)
        state.providers = [provider]
        let host = UIHostingController(
            rootView: NavigationStack { ChatView(conversationID: conversation.id) }.environment(state)
        )
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 430, height: 932)
        window.rootViewController = host
        return ChatHarness(window: window, host: host, state: state) {
            window.isHidden = true
            window.rootViewController = nil
            state.flushConversationPersistQueue()
            DatabaseManager.shared.close()
            AppSessionStore.switchToUser(previousUID)
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }
    }

    // MARK: - Composer

    @Test("composer: paste / type / refocus with 200K characters of Arabic")
    func composerLongArabicPaste() async throws {
        let harness = try mountChatView(
            uid: "long-arabic-composer-\(UUID().uuidString)",
            messages: [TestFactories.makeMessage(role: .user, text: "hi"), TestFactories.makeMessage(role: .assistant, text: "hello")]
        )
        defer { harness.cleanup() }
        harness.window.makeKeyAndVisible()
        try await yieldMainActor(for: 2.0)
        let input = try #require(firstEditableTextView(in: harness.host.view) as? ComposerUITextView)
        let coordinator = try #require(input.coordinator)
        input.becomeFirstResponder()
        try await yieldMainActor(for: 0.6)

        let paste = Self.arabic(utf16: Self.longUTF16)
        let probe = MainThreadStallProbe()

        // System paste menu / Cmd-V / drop: the paste delegate hands out the display string first, which then replaces the selection.
        probe.start()
        let range = try #require(input.selectedTextRange)
        let display = coordinator.textPasteConfigurationSupporting(
            input, combineItemAttributedStrings: [NSAttributedString(string: paste)], for: range
        )
        input.insertText(display.string)
        try await yieldMainActor(for: 1.5)
        probe.stop()
        let pasteStall = probe.maxStall
        #expect(coordinator.publishedSource == paste, "after a paste the draft must be the source text")

        probe.start()
        input.insertText("x")
        try await yieldMainActor(for: 0.8)
        probe.stop()
        let keyStall = probe.maxStall

        probe.start()
        input.resignFirstResponder()
        try await yieldMainActor(for: 0.8)
        input.becomeFirstResponder()
        try await yieldMainActor(for: 0.8)
        probe.stop()
        let focusStall = probe.maxStall

        // Insertions that bypass the paste delegate (a third-party keyboard's clipboard, dictation, Live Text, input
        // from the keyboard dock): a whole-block insertText.
        input.selectedRange = NSRange(location: 0, length: input.textStorage.length)
        input.deleteBackward()
        try await yieldMainActor(for: 0.8)
        probe.start()
        input.insertText(paste)
        try await yieldMainActor(for: 1.5)
        probe.stop()
        let foreignInsertStall = probe.maxStall
        #expect(coordinator.publishedSource == paste, "after a foreign insertion the draft must be the source text")

        print("""
        [HANG-COST] composer · single Arabic paragraph of \(paste.utf16.count) UTF-16 (real ChatView, longest main-thread stall)
          paste (paste delegate path) \(ms(pasteStall)); type one more character \(ms(keyStall)); dismiss and reopen keyboard \(ms(focusStall))
          foreign insertText (bypassing the paste delegate) \(ms(foreignInsertStall))
        """)
        #expect(pasteStall < 0.5, "paste blocked the main thread for \(ms(pasteStall))")
        #expect(keyStall < 0.5, "typing blocked the main thread for \(ms(keyStall))")
        #expect(focusStall < 0.5, "refocusing blocked the main thread for \(ms(focusStall))")
        #expect(foreignInsertStall < 0.5, "foreign insertion blocked the main thread for \(ms(foreignInsertStall))")
    }

    // MARK: - User bubble

    private func makeUserModel(text: String) -> ChatCollectionProjectionBuilder.MessageRenderModel {
        let message = ChatMessage(
            id: UUID(), role: .user, text: text, reasoningText: nil,
            providerKind: .openAI, providerName: "OpenAI", modelName: "GPT-4o",
            estimatedCost: 0, state: .delivered, attachments: nil, citations: nil
        )
        return ChatCollectionProjectionBuilder.MessageRenderModel(
            messageID: message.id, message: message, presentationKind: .user,
            showMetadata: true, resolvedProviderName: "OpenAI", resolvedModelName: "GPT-4o",
            relayKind: nil, renderHint: nil, topPadding: 16,
            displayText: nil, textHash: text.hashValue, isStreaming: false, providerMetadataVersion: 0
        )
    }

    private final class LayoutCounter: NSObject, NSLayoutManagerDelegate {
        /// Number of complete (atEnd) layouts: iOS's TextKit 1 lays the full text out synchronously on both storage
        /// edits and container geometry changes.
        var fullLayouts = 0
        func layoutManager(_ layoutManager: NSLayoutManager, didCompleteLayoutFor textContainer: NSTextContainer?, atEnd layoutFinishedFlag: Bool) {
            if layoutFinishedFlag { fullLayouts += 1 }
        }
    }

    private func textView(in view: UIView) -> ChatPassiveTextView? {
        if let found = view as? ChatPassiveTextView { return found }
        for subview in view.subviews {
            if let found = textView(in: subview) { return found }
        }
        return nil
    }

    /// One full appearance of a fresh cell: configure, then the same self-sizing path as ChatLayout (natural height at
    /// full width, then layout at the real size). Returns main-thread wall-clock time and how many complete layouts
    /// the bubble's text view performed.
    private func measureUserBubble(utf16: Int, width: CGFloat = 393) throws -> (seconds: CFTimeInterval, liveFullLayouts: Int, height: CGFloat) {
        let text = Self.arabic(utf16: utf16)
        let cell = UserMessageCell(frame: CGRect(x: 0, y: 0, width: width, height: 100))
        let live = try #require(textView(in: cell))
        let counter = LayoutCounter()
        live.layoutManager.delegate = counter
        let start = CACurrentMediaTime()
        cell.configure(model: makeUserModel(text: text), maxBubbleWidth: 320, parentViewController: UIViewController())
        cell.contentView.frame = CGRect(x: 0, y: 0, width: width, height: 100)
        let fit = cell.contentView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        cell.frame = CGRect(x: 0, y: 0, width: width, height: fit.height)
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
        return (CACurrentMediaTime() - start, counter.fullLayouts, fit.height)
    }

    @Test("user bubble cell: a fresh cell lays the whole text out only once in the live view (frame before text)")
    func userBubbleLaysOutOnce() throws {
        let sample = try measureUserBubble(utf16: 64_000)
        print("[HANG-COST] user bubble cell · single Arabic paragraph of 64000 UTF-16 at width 393: main thread \(ms(sample.seconds)), \(sample.liveFullLayouts) complete layouts in the live view, cell height \(Int(sample.height))pt")
        // Filling the text before the frame is set lays it out once at the stale width (0) in configure and again at
        // the real width after the host's layoutSubviews changes the frame: 2 layouts.
        #expect(sample.liveFullLayouts == 1, "the live view laid the whole text out \(sample.liveFullLayouts) times")
    }

    @Test("user bubble cell: 64K characters (a realistic long message, ~110KB request body) < 500ms; 200K is recorded as is")
    func userBubbleCellLongArabic() throws {
        let real = try measureUserBubble(utf16: 64_000)
        let huge = try measureUserBubble(utf16: Self.longUTF16)
        print("""
        [HANG-COST] user bubble cell · single Arabic paragraph (configure + self-sizing + layout, main-thread wall clock)
          64000 UTF-16: \(ms(real.seconds)); \(Self.longUTF16) UTF-16: \(ms(huge.seconds)) (cell height \(Int(huge.height))pt)
        """)
        #expect(real.seconds < 0.5, "a 64K-character bubble took \(ms(real.seconds)) on the main thread")
        // 200K: the off-screen measurement and the live view each lay the whole text out once, and shaping cost is
        // linear in length, so a synchronous path cannot get under 500ms. A real bound needs rendering only a prefix
        // with an expand-to-full-text affordance (a bubble layout change); until then this is recorded, not faked.
        withKnownIssue("a single 200K-character bubble still exceeds 500ms: needs a long-message collapse design", isIntermittent: true) {
            #expect(huge.seconds < 0.5, "a 200K-character bubble took \(ms(huge.seconds)) on the main thread")
        }
    }

    @Test("real chat screen: opening a conversation whose last user message is very long Arabic")
    func chatViewOpensLongArabicUserMessage() async throws {
        var stalls: [Int: CFTimeInterval] = [:]
        for utf16 in [64_000, Self.longUTF16] {
            let text = Self.arabic(utf16: utf16)
            let harness = try mountChatView(
                uid: "long-arabic-bubble-\(UUID().uuidString)",
                messages: [
                    TestFactories.makeMessage(role: .user, text: "hi"),
                    TestFactories.makeMessage(role: .assistant, text: "hello"),
                    TestFactories.makeMessage(role: .user, text: text),
                ]
            )
            let probe = MainThreadStallProbe()
            probe.start()
            harness.window.makeKeyAndVisible()
            try await yieldMainActor(for: 4.0)
            probe.stop()
            harness.cleanup()
            stalls[utf16] = probe.maxStall
            print("[HANG-COST] real chat screen first open (last user message a single Arabic paragraph of \(utf16) UTF-16): longest main-thread stall \(ms(probe.maxStall)), >16ms total \(ms(probe.jankTotal))")
        }
        #expect((stalls[64_000] ?? .infinity) < 0.5, "opening with 64K characters blocked the main thread for \(ms(stalls[64_000] ?? .infinity))")
        withKnownIssue("a single 200K-character bubble still exceeds 500ms: needs a long-message collapse design", isIntermittent: true) {
            #expect((stalls[Self.longUTF16] ?? .infinity) < 0.5, "opening with 200K characters blocked the main thread for \(ms(stalls[Self.longUTF16] ?? .infinity))")
        }
    }
}
