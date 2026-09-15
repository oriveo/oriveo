import QuartzCore
import SwiftUI
import Testing
import UIKit
@testable import Oriveo

/// Main-thread cost of typing in the chat composer: mounts the real ChatView over a conversation in a
/// real database, inserts text one character at a time (the same UITextInput path as the keyboard),
/// and counts the page-level recomputation each keystroke triggers. Wall-clock numbers are printed only.
@MainActor
@Suite("Chat composer typing hang cost", .serialized)
struct ChatComposerTypingHangCostTests {
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

    private func countTextViews(in view: UIView) -> Int {
        (view is UITextView ? 1 : 0) + view.subviews.reduce(0) { $0 + countTextViews(in: $1) }
    }

    @Test("Typing 23 characters in a 60-message conversation does not recompute ChatView or the message list")
    func typingInComposer() async throws {
        let previousUID = AppSessionStore.activeUID
        let uid = "composer-typing-\(UUID().uuidString)"
        defer {
            DatabaseManager.shared.close()
            AppSessionStore.switchToUser(previousUID)
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }
        DatabaseManager.shared.close()

        let provider = TestFactories.makeProvider(kind: .openAI)
        let answer = """
        Here is a **detailed** answer with a list:

        - first point with `inline code`
        - second point with a [link](https://example.com)

        And a closing paragraph that is long enough to wrap across several lines in the chat bubble.
        """
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let conversation = TestFactories.makeConversation(
            title: "Typing cost",
            providerID: provider.id,
            providerKind: .openAI,
            modelID: "gpt-4o",
            messages: (0..<60).map { index in
                var message = TestFactories.makeMessage(
                    role: index.isMultiple(of: 2) ? .user : .assistant,
                    text: index.isMultiple(of: 2) ? "Question \(index): how does this work in practice?" : answer,
                    providerID: provider.id,
                    modelID: "gpt-4o"
                )
                message.createdAt = base.addingTimeInterval(TimeInterval(index))
                return message
            },
            updatedAt: base.addingTimeInterval(60)
        )
        _ = try ConversationRuntimeBridge().replaceAllConversations([conversation], uid: uid)
        DatabaseManager.shared.close()

        let state = AppState(sessionUID: uid)
        defer { state.flushConversationPersistQueue() }
        // The message window opens the database of the active partition; without switching, the list
        // stays on its skeleton and the input is read-only. Switch after creating AppState: in a clean
        // container the first AppState runs the partition migration and switches back to the guest partition.
        AppSessionStore.switchToUser(uid)
        state.providers = [provider]

        let host = UIHostingController(
            rootView: NavigationStack { ChatView(conversationID: conversation.id) }.environment(state)
        )
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await yieldMainActor(for: 2.0)

        let rendered = countTextViews(in: host.view)
        #expect(rendered > 10, "The message list rendered no messages (\(rendered) text views), so this is not the real screen")
        let input = try #require(firstEditableTextView(in: host.view), "The chat input was not found")
        input.becomeFirstResponder()
        try await yieldMainActor(for: 0.6)

        let typed = "hello, this is a typing"
        ChatView.resetBodyEvaluationCount()
        ChatMessageList.resetBodyEvaluationCount()
        ChatComposerBar.resetBodyEvaluationCount()
        let probe = MainThreadStallProbe()
        var perKeystroke: [CFTimeInterval] = []
        // Body counters are global statics: in the 80ms gap between keystrokes, unrelated async work
        // (metadata refreshes and similar) can recompute the page. The assertions count only each
        // keystroke's window: pending updates are flushed first, so the window holds only that keystroke's updates.
        var keystrokeChatViewBodies = 0
        var keystrokeMessageListBodies = 0
        var keystrokesWithoutComposerBody = 0
        probe.start()
        for character in typed {
            host.view.layoutIfNeeded()
            let chatViewBefore = ChatView.bodyEvaluationCount
            let messageListBefore = ChatMessageList.bodyEvaluationCount
            let composerBefore = ChatComposerBar.bodyEvaluationCount
            let start = CACurrentMediaTime()
            input.insertText(String(character))
            // Let SwiftUI finish this keystroke's body updates and layout before measuring the next one.
            try await Task.sleep(for: .milliseconds(1))
            host.view.layoutIfNeeded()
            perKeystroke.append(CACurrentMediaTime() - start)
            keystrokeChatViewBodies += ChatView.bodyEvaluationCount - chatViewBefore
            keystrokeMessageListBodies += ChatMessageList.bodyEvaluationCount - messageListBefore
            if ChatComposerBar.bodyEvaluationCount == composerBefore {
                keystrokesWithoutComposerBody += 1
            }
            try await yieldMainActor(for: 0.08)
        }
        probe.stop()

        let sorted = perKeystroke.sorted()
        print("""
        [HANG-COST] chat typing (60-message conversation, \(typed.count) characters)
          longest main-thread stall \(String(format: "%.0f", probe.maxStall * 1000))ms, >16ms total \(String(format: "%.0f", probe.jankTotal * 1000))ms
          per-keystroke median \(String(format: "%.1f", sorted[sorted.count / 2] * 1000))ms, slowest \(String(format: "%.1f", (sorted.last ?? 0) * 1000))ms
          keystroke windows: ChatView.body \(keystrokeChatViewBodies), ChatMessageList.body \(keystrokeMessageListBodies)
          whole run (including gaps): ChatView.body \(ChatView.bodyEvaluationCount), ChatMessageList.body \(ChatMessageList.bodyEvaluationCount), ChatComposerBar.body \(ChatComposerBar.bodyEvaluationCount)
        """)
        #expect(input.text.hasSuffix(typed))
        // Control: each window must really cover its keystroke's recomputation, or the two zeros below prove nothing.
        #expect(keystrokesWithoutComposerBody == 0, "\(keystrokesWithoutComposerBody) keystroke windows saw no composer recomputation, so the window missed the input")
        #expect(keystrokeChatViewBodies == 0, "ChatView body must not run while typing, got \(keystrokeChatViewBodies)")
        #expect(keystrokeMessageListBodies == 0, "The message list body must not run while typing, got \(keystrokeMessageListBodies)")
    }
}
