import QuartzCore
import SwiftUI
import Testing
import UIKit
@testable import Oriveo

/// Main-thread cost of typing in the home hero: mount the real AppRootView with the conversations in the real database, insertText into the hero text view one character at a time,
/// and measure the whole-page recomputation each character triggers. Wall-clock numbers are only printed.
@MainActor
@Suite("Home typing hang cost", .serialized, .sharedProcessState)
struct HomeHeroTypingHangCostTests {
    private func yieldMainActor(for seconds: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func firstEditableTextView(in view: UIView) -> UITextView? {
        if let textView = view as? UITextView, textView.isEditable, !textView.isHidden { return textView }
        for subview in view.subviews {
            if let found = firstEditableTextView(in: subview) { return found }
        }
        return nil
    }

    @Test("typing 23 characters into the home hero with 300 conversations (6 folders)")
    func typingInHeroComposer() async throws {
        let previousUID = AppSessionStore.activeUID
        let uid = "home-typing-\(UUID().uuidString)"
        defer {
            DatabaseManager.shared.close()
            AppSessionStore.switchToUser(previousUID)
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }
        DatabaseManager.shared.close()

        let provider = TestFactories.makeProvider(kind: .openAI)
        let folders = (0..<6).map { TestFactories.makeFolder(name: "Folder \($0)") }
        let now = Date()
        let conversations = (0..<300).map { index in
            var conversation = TestFactories.makeConversation(
                title: "Conversation \(index) about a fairly long topic title",
                providerID: provider.id,
                providerKind: .openAI,
                modelID: "gpt-4o",
                previewText: "Preview text for conversation \(index)",
                estimatedCost: 0.003,
                messages: (0..<6).map { messageIndex in
                    TestFactories.makeMessage(
                        role: messageIndex.isMultiple(of: 2) ? .user : .assistant,
                        text: "Message \(messageIndex) in conversation \(index)",
                        providerID: provider.id,
                        modelID: "gpt-4o"
                    )
                },
                updatedAt: now.addingTimeInterval(-TimeInterval(index) * 3_600),
                folderID: index.isMultiple(of: 5) ? folders[index % folders.count].id : nil
            )
            conversation.messageCountOverride = 6
            return conversation
        }
        _ = try ConversationRuntimeBridge().replaceAllConversations(conversations, uid: uid)
        DatabaseManager.shared.close()

        let state = AppState(sessionUID: uid)
        defer { state.flushConversationPersistQueue() }
        AppSessionStore.switchToUser(uid)
        state.providers = [provider]
        state.folders = folders
        state.hasCompletedOnboarding = true
        state.selectedTab = .home

        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: AppRootView(appState: state))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: scene.screen.bounds.size)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.endEditing(true)
            window.isHidden = true
            window.rootViewController = nil
        }
        try await yieldMainActor(for: 2.0)

        let input = try #require(firstEditableTextView(in: host.view), "the home hero text view was not found")
        input.becomeFirstResponder()
        try await yieldMainActor(for: 0.6)

        let typed = "hello, this is a typing"
        let probe = MainThreadStallProbe()
        var perKeystroke: [CFTimeInterval] = []
        probe.start()
        for character in typed {
            let start = CACurrentMediaTime()
            input.insertText(String(character))
            try await Task.sleep(for: .milliseconds(1))
            perKeystroke.append(CACurrentMediaTime() - start)
            try await yieldMainActor(for: 0.08)
        }
        probe.stop()

        let sorted = perKeystroke.sorted()
        print("""
        [HANG-COST] home hero typing (300 conversations / 6 folders, \(typed.count) characters)
          longest main-thread stall \(String(format: "%.0f", probe.maxStall * 1000))ms, >16ms total \(String(format: "%.0f", probe.jankTotal * 1000))ms
          per-keystroke median \(String(format: "%.1f", sorted[sorted.count / 2] * 1000))ms, slowest \(String(format: "%.1f", (sorted.last ?? 0) * 1000))ms
        """)
        #expect(input.text.hasSuffix(typed))

        // For profiling: when ORIVEO_SAMPLE_READY is set, write a ready file and keep typing while an external sampler attaches.
        if let ready = ProcessInfo.processInfo.environment["ORIVEO_SAMPLE_READY"] {
            FileManager.default.createFile(atPath: ready, contents: Data("\(getpid())".utf8))
            try await yieldMainActor(for: 1.5)
            for index in 0..<250 {
                input.insertText(index.isMultiple(of: 10) ? " " : "x")
                try await yieldMainActor(for: 0.04)
            }
        }
    }
}
