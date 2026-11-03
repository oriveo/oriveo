import Foundation
import OriveoProviderKit
import Testing
@testable import Oriveo

// Live body coalescing buffer: a stalled stream flushes its buffered tail on its own, and a user stop folds
// the tail into the interrupted text and the stop usage.
// Streams go through the production `sendMessage` path over `StopReasonURLProtocol`.

nonisolated private func streamingDeltaFlushFrames(_ chunks: [String]) -> String {
    chunks.map { "data: {\"choices\":[{\"delta\":{\"content\":\"\($0)\"}}]}\n\n" }.joined()
}

@Suite("StreamingDeltaFlushTests", .serialized, .sharedProcessState)
@MainActor
struct StreamingDeltaFlushTests {

    private func waitUntil(
        _ label: String,
        iterations: Int = 150,
        condition: @MainActor () -> Bool
    ) async throws {
        for _ in 0..<iterations {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("Timed out waiting for \(label)")
    }

    private func lastAssistant(_ state: AppState, _ conversationID: UUID) -> ChatMessage? {
        state.conversation(for: conversationID)?.messages.last { $0.role == .assistant }
    }

    /// Sends one OpenRouter turn whose stream delivers `"Head\n"` then `"tail"` in one chunk and then hangs.
    private func sendHangingHeadAndTail(
        prefix: String,
        configure: (AppState) -> Void = { _ in }
    ) async throws -> (AppState, UUID) {
        StopReasonURLProtocol.reset()
        StopReasonURLProtocol.reply = { request in
            guard request.url?.path.hasSuffix("/chat/completions") == true else { return nil }
            return .hang(text: streamingDeltaFlushFrames(["Head\\n", "tail"]))
        }
        let state = AppState(
            seedDemoData: false,
            sessionUID: "delta-flush-\(prefix)-\(UUID().uuidString)",
            providerSession: StopReasonURLProtocol.session()
        )
        let modelID = "openai/gpt-4o-mini"
        let provider = TestFactories.makeProvider(
            kind: .openRouter,
            models: [TestFactories.makeModel(
                id: modelID, name: modelID, isDefault: true, promptPrice: 0.000002, completionPrice: 0.000008
            )]
        )
        let conversation = TestFactories.makeConversation(
            providerID: provider.id, providerKind: .openRouter, modelID: modelID
        )
        state.providers = [provider]
        state.upsertConversationProjection(conversation)
        configure(state)
        _ = await state.sendMessage("Hello", in: conversation.id)
        return (state, conversation.id)
    }

    @Test func stalled_stream_flushes_buffered_tail_within_window() async throws {
        defer { StopReasonURLProtocol.reset() }
        let (state, conversationID) = try await sendHangingHeadAndTail(prefix: "stalled")
        try await waitUntil("head flushed by its newline") {
            state.chatManager.streamingText(in: conversationID).hasPrefix("Head\n")
        }
        // No further events arrive; the tail must surface once the 40ms window ends (polled for at most 200ms).
        try await waitUntil("buffered tail flushed after the window", iterations: 10) {
            state.chatManager.streamingText(in: conversationID) == "Head\ntail"
        }
        #expect(state.chatManager.streamingText(in: conversationID) == "Head\ntail")
        #expect(state.chatManager._testingBufferedStreamingDelta(in: conversationID)?.isEmpty != false)
        state.chatManager.cancelGeneration(in: conversationID, userInitiated: false)
    }

    @Test func user_stop_includes_buffered_tail_in_text_and_usage() async throws {
        defer { StopReasonURLProtocol.reset() }
        // A wide window keeps the tail buffered until the stop, so the stop path itself must flush it.
        let (state, conversationID) = try await sendHangingHeadAndTail(prefix: "stop") {
            $0.chatManager._testingSetStreamingDeltaFlushWindow(30)
        }
        try await waitUntil("tail held in the coalescing buffer") {
            state.chatManager.streamingText(in: conversationID) == "Head\n"
                && state.chatManager._testingBufferedStreamingDelta(in: conversationID) == "tail"
        }

        state.chatManager.cancelGeneration(in: conversationID)

        try await waitUntil("stopped usage written") { lastAssistant(state, conversationID)?.outputTokens != nil }
        let message = try #require(lastAssistant(state, conversationID))
        #expect(message.state == .interrupted)
        #expect(message.text == "Head\ntail")
        let expectedOutput = Int((Double("Head\ntail".utf8.count) * RhoCalibration().rhoHi).rounded(.up))
        #expect(message.outputTokens == expectedOutput)
        #expect(state.chatManager._testingBufferedStreamingDelta(in: conversationID) == nil)
    }
}
