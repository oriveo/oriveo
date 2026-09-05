import Foundation
import Testing
@testable import Oriveo

@Suite("ConversationManagerPinnedProjection", .serialized)
struct ConversationManagerPinnedProjectionTests {

    @Test("pinned list uses a summary projection: no messages, no attachment hydrate")
    @MainActor
    func pinnedProjectionSkipsMessagesAndAttachments() throws {
        let previousUID = AppSessionStore.activeUID
        let uid = "pinned-projection-\(UUID().uuidString)"
        defer {
            DatabaseManager.shared.close()
            AppSessionStore.switchToUser(previousUID)
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }
        DatabaseManager.shared.close()

        let attachment = TestFactories.makeFileAttachment(
            base64Data: Data("pinned-sidecar-payload".utf8).base64EncodedString()
        )
        let pinned = TestFactories.makeConversation(
            title: "Pinned",
            previewText: "pinned preview",
            messages: [TestFactories.makeMessage(role: .assistant, text: "body", attachments: [attachment])]
        )
        let other = TestFactories.makeConversation(
            title: "Other",
            messages: [TestFactories.makeMessage(role: .assistant, text: "other")]
        )

        let state = AppState(sessionUID: uid)
        _ = try state.conversationRuntimeBridge.replaceAllConversations([pinned, other], uid: uid)
        state.preferences.pinnedConversationIDs = [pinned.id]

        let result = state.conversationManager.pinnedConversations
        #expect(result.count == 1)
        #expect(result.first?.id == pinned.id)
        #expect(result.first?.title == "Pinned")
        #expect(result.first?.previewText == "pinned preview")
        #expect(result.first?.displayMessageCount == 1)
        #expect(result.first?.messages.isEmpty == true)
    }

    @Test("pinned list returns in pinnedConversationIDs order and filters invisible conversations")
    @MainActor
    func pinnedProjectionKeepsOrderAndVisibility() throws {
        let previousUID = AppSessionStore.activeUID
        let uid = "pinned-order-\(UUID().uuidString)"
        defer {
            DatabaseManager.shared.close()
            AppSessionStore.switchToUser(previousUID)
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }
        DatabaseManager.shared.close()

        let first = TestFactories.makeConversation(
            title: "First",
            messages: [TestFactories.makeMessage(text: "a")]
        )
        let second = TestFactories.makeConversation(
            title: "Second",
            messages: [TestFactories.makeMessage(text: "b")]
        )
        let emptyDraft = TestFactories.makeConversation(title: "Draft", isDraft: true, messages: [])

        let state = AppState(sessionUID: uid)
        _ = try state.conversationRuntimeBridge.replaceAllConversations(
            [first, second, emptyDraft],
            uid: uid
        )
        state.preferences.pinnedConversationIDs = [second.id, emptyDraft.id, first.id, UUID()]

        let result = state.conversationManager.pinnedConversations
        #expect(result.map(\.id) == [second.id, first.id])
    }

    @Test("the same conversationsVersion reuses the cache and does not query again")
    @MainActor
    func pinnedProjectionCachesUntilVersionChanges() throws {
        let previousUID = AppSessionStore.activeUID
        let uid = "pinned-cache-\(UUID().uuidString)"
        defer {
            DatabaseManager.shared.close()
            AppSessionStore.switchToUser(previousUID)
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }
        DatabaseManager.shared.close()

        let pinned = TestFactories.makeConversation(
            title: "Pinned",
            messages: [TestFactories.makeMessage(text: "a")]
        )
        let state = AppState(sessionUID: uid)
        _ = try state.conversationRuntimeBridge.replaceAllConversations([pinned], uid: uid)
        state.preferences.pinnedConversationIDs = [pinned.id]

        #expect(state.conversationManager.pinnedConversations.count == 1)

        try state.conversationRuntimeBridge.deleteConversations(ids: [pinned.id], uid: uid)
        #expect(state.conversationManager.pinnedConversations.count == 1)

        state.conversations = []
        #expect(state.conversationManager.pinnedConversations.isEmpty)
    }
}
