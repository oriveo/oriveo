import GRDB
import QuartzCore
import SwiftUI
import Testing
import UIKit
@testable import Oriveo

/// Streaming checkpoints: production ChatView plus a store write of the generating row.
/// After WindowSnapshot ignores the generating cursor, a checkpoint must not punch through the list body.
@MainActor
@Suite("Chat streaming checkpoint hang cost", .serialized, .sharedProcessState)
struct ChatStreamingCheckpointHangCostTests {
    private func yieldMainActor(for seconds: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Under a fully loaded concurrent run, the async settling after mount (conversation projection, sync state, note
    /// summaries and so on) can arrive later than a fixed 1.5s, and a late body evaluation would be charged to the
    /// checkpoints. Before measuring, wait until both body layers evaluate zero times for one full checkpoint window
    /// (8 x 0.12s), up to 10s; the assertions stay as they were.
    private func waitForRenderQuiescence(conversationID: UUID) async throws {
        let deadline = Date().addingTimeInterval(10)
        while true {
            ChatView.resetBodyEvaluationCount(countingOnly: conversationID)
            ChatMessageList.resetBodyEvaluationCount(countingOnly: conversationID)
            try await yieldMainActor(for: 0.96)
            if ChatView.bodyEvaluationCount == 0, ChatMessageList.bodyEvaluationCount == 0 { return }
            if Date() >= deadline {
                Issue.record("Still evaluating bodies 10s after mount (ChatView \(ChatView.bodyEvaluationCount), list \(ChatMessageList.bodyEvaluationCount)); the page never settled")
                return
            }
        }
    }

    @Test("Checkpoints on a 60-message window do not rerender the list or grow with completed length")
    func checkpointDoesNotRerenderChatViewOrGrowWithCompletedLength() async throws {
        let previousUID = AppSessionStore.activeUID
        let uid = "checkpoint-hang-\(UUID().uuidString)"
        defer {
            DatabaseManager.shared.close()
            AppSessionStore.switchToUser(previousUID)
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }
        DatabaseManager.shared.close()

        let provider = TestFactories.makeProvider(kind: .openAI)
        let conversationID = UUID()
        let generatingID = UUID()
        let completed = (0..<60).map { index -> ChatMessage in
            TestFactories.makeMessage(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                text: String(repeating: "completed-\(index) ", count: 40),
                providerID: provider.id,
                modelID: "gpt-4o",
                state: .delivered
            )
        }
        var generating = TestFactories.makeMessage(
            id: generatingID,
            role: .assistant,
            text: "start",
            providerID: provider.id,
            modelID: "gpt-4o",
            state: .generating
        )
        let conversation = TestFactories.makeConversation(
            id: conversationID,
            title: "Checkpoint hang",
            providerID: provider.id,
            providerKind: .openAI,
            modelID: "gpt-4o",
            messages: completed + [generating]
        )
        _ = try ConversationRuntimeBridge().replaceAllConversations([conversation], uid: uid)

        let state = AppState(sessionUID: uid)
        AppSessionStore.switchToUser(uid)
        state.providers = [provider]
        // loadSession turns leftover `.generating` into `.interrupted`. Rewrite a live
        // generating row before mounting ChatView; that is the checkpoint path.
        _ = try ConversationRuntimeBridge().replaceAllConversations([conversation], uid: uid)

        let host = UIHostingController(
            rootView: NavigationStack { ChatView(conversationID: conversationID) }.environment(state)
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
        try await yieldMainActor(for: 1.5)
        try await waitForRenderQuiescence(conversationID: conversationID)

        ChatView.resetBodyEvaluationCount(countingOnly: conversationID)
        ChatMessageList.resetBodyEvaluationCount(countingOnly: conversationID)
        MessageWindowLoader.resetContentChangeCount()
        let pool = try DatabaseManager.shared.openIfNeeded(for: uid)
        let probe = MainThreadStallProbe()
        var perCheckpoint: [CFTimeInterval] = []
        probe.start()
        for step in 0..<8 {
            generating.text += String(repeating: "token\(step) ", count: 20)
            let nextText = generating.text
            let start = CACurrentMediaTime()
            // Community edition has no managed checkpoint API. A single-row
            // generating text UPDATE is the observation path the window loader sees.
            try await pool.write { db in
                try db.execute(
                    sql: "UPDATE message SET text = ? WHERE id = ?",
                    arguments: [nextText, generatingID.uuidString]
                )
            }
            perCheckpoint.append(CACurrentMediaTime() - start)
            try await yieldMainActor(for: 0.12)
        }
        probe.stop()

        let sorted = perCheckpoint.sorted()
        let firstHalf = perCheckpoint.prefix(4).reduce(0, +) / 4
        let secondHalf = perCheckpoint.suffix(4).reduce(0, +) / 4
        print("""
        [HANG-COST] streaming checkpoint (60 completed + generating, 8 writes)
          longest main-thread stall \(String(format: "%.0f", probe.maxStall * 1000))ms
          median \(String(format: "%.1f", sorted[sorted.count / 2] * 1000))ms
          first 4 mean \(String(format: "%.1f", firstHalf * 1000))ms, last 4 mean \(String(format: "%.1f", secondHalf * 1000))ms
          ChatView.body \(ChatView.bodyEvaluationCount), ChatMessageList.body \(ChatMessageList.bodyEvaluationCount)
          window content changes \(MessageWindowLoader.contentChangeCount)
        """)
        #expect(MessageWindowLoader.contentChangeCount == 0, "A checkpoint must not bump window revision, got \(MessageWindowLoader.contentChangeCount)")
        #expect(ChatView.bodyEvaluationCount == 0, "A checkpoint must not recompute ChatView.body, got \(ChatView.bodyEvaluationCount)")
        #expect(ChatMessageList.bodyEvaluationCount == 0, "A checkpoint must not recompute the list body, got \(ChatMessageList.bodyEvaluationCount)")
        #expect(secondHalf < firstHalf * 3 + 0.05, "Later checkpoints must not grow linearly with completed length")
    }
}
