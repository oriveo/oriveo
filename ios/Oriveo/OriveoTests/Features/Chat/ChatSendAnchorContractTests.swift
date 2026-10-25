import Foundation
import Testing
@testable import Oriveo

@Suite("Chat send anchor contracts", .sharedProcessState)
struct ChatSendAnchorContractTests {

    @Test("pending anchor is nil before local send")
    @MainActor
    func pendingAnchorIsNilBeforeLocalSend() {
        let state = AppState(seedDemoData: true)
        let conversationID = UUID()

        #expect(state.pendingChatAnchorUserMessageID(in: conversationID) == nil)
    }

    @Test("pending anchor is consumed only by matching user message")
    @MainActor
    func pendingAnchorConsumesOnlyMatchingUserMessage() {
        let state = AppState(seedDemoData: true)
        let conversationID = UUID()
        let userID = UUID()

        state._testingSetPendingChatAnchorUserMessageID(userID, in: conversationID)
        state.consumePendingChatAnchorUserMessageID(UUID(), in: conversationID)
        #expect(state.pendingChatAnchorUserMessageID(in: conversationID) == userID)

        state.consumePendingChatAnchorUserMessageID(userID, in: conversationID)
        #expect(state.pendingChatAnchorUserMessageID(in: conversationID) == nil)
    }

    @Test("local send stages anchor before conversation projection is published")
    @MainActor
    func localSendStagesAnchorBeforeProjectionPublish() async throws {
        let state = AppState(seedDemoData: true)
        let conversationID = try #require(state.conversations.first?.id)
        var observedAnchorAtPublish: UUID?
        var observedUserMessageID: UUID?

        state._testingBeforeConversationProjectionUpsert = { conversation in
            guard conversation.id == conversationID,
                  let userMessage = conversation.messages.last(where: { $0.role == .user }) else {
                return
            }
            observedUserMessageID = userMessage.id
            observedAnchorAtPublish = state.pendingChatAnchorUserMessageID(in: conversationID)
        }
        defer { state._testingBeforeConversationProjectionUpsert = nil }

        _ = await state.sendMessage("Anchor timing", in: conversationID)

        #expect(observedAnchorAtPublish == observedUserMessageID)

        // Wait for the send to settle before releasing the lock: the sendTask must not leak into the next locked case and write shared state.
        try await waitUntil(timeoutNanoseconds: 10_000_000_000) {
            !state.conversations.contains { $0.messages.contains { $0.state == .generating } }
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        await MetadataClient.shared.drainBackgroundWorkForTesting()
    }

    @MainActor
    private func waitUntil(
        timeoutNanoseconds: UInt64 = 3_000_000_000,
        intervalNanoseconds: UInt64 = 20_000_000,
        condition: @MainActor @escaping () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))
        while condition() == false {
            if ContinuousClock.now >= deadline {
                Issue.record("Timed out waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: intervalNanoseconds)
        }
    }
}
