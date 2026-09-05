import Foundation
import Testing
@testable import Oriveo

@Suite("ConversationRuntimeBridge", .serialized)
struct ConversationRuntimeBridgeTests {

    @Test("Upsert Conversation Returns Derived Projection")
    func upsertConversationReturnsDerivedProjection() throws {
        let uid = "bridge-upsert-\(UUID().uuidString)"
        let bridge = ConversationRuntimeBridge()

        defer {
            DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }

        DatabaseManager.shared.close()

        let providerID = UUID()
        let untouched = TestFactories.makeConversation(
            title: "Untouched",
            providerID: providerID,
            messages: [TestFactories.makeMessage(text: "keep me", estimatedCost: 0.2)]
        )
        let target = TestFactories.makeConversation(
            title: "Original",
            providerID: providerID,
            messages: [TestFactories.makeMessage(role: .user, text: "first prompt", estimatedCost: 0.15)]
        )

        try bridge.persistLegacyProjection([untouched, target], for: uid)

        var updatedTarget = target
        updatedTarget.title = "Stale Title"
        updatedTarget.previewText = "Stale Preview"
        updatedTarget.estimatedCost = 999
        updatedTarget.messages.append(
            TestFactories.makeMessage(role: .assistant, text: "assistant reply", estimatedCost: 0.35)
        )

        let refreshed = try bridge.upsertConversation(updatedTarget, uid: uid)
        let projection = try bridge.loadLegacyProjection(uid: uid)

        #expect(refreshed.title == "first prompt")
        #expect(refreshed.previewText == "assistant reply")
        #expect(abs(refreshed.estimatedCost - 0.5) < 0.000_001)
        #expect(projection.count == 2)
        #expect(projection.first(where: { $0.id == untouched.id })?.title == "Untouched")
        #expect(projection.first(where: { $0.id == target.id })?.title == "first prompt")
    }

    @Test("Delete Conversation Removes Only Target Projection")
    func deleteConversationRemovesOnlyTargetProjection() throws {
        let uid = "bridge-delete-\(UUID().uuidString)"
        let bridge = ConversationRuntimeBridge()

        defer {
            DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }

        DatabaseManager.shared.close()

        let first = TestFactories.makeConversation(title: "First")
        let second = TestFactories.makeConversation(title: "Second")

        try bridge.persistLegacyProjection([first, second], for: uid)
        try bridge.deleteConversation(id: first.id, uid: uid)

        let projection = try bridge.loadLegacyProjection(uid: uid)
        #expect(projection.map(\.id) == [second.id])
        #expect(projection.first?.title == "Second")
    }

    @Test("Update Conversation Models Only Touches Targets")
    func updateConversationModelsOnlyTouchesTargets() throws {
        let uid = "bridge-model-update-\(UUID().uuidString)"
        let bridge = ConversationRuntimeBridge()

        defer {
            DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }

        DatabaseManager.shared.close()

        let originalProviderID = UUID()
        let newProviderID = UUID()
        let untouched = TestFactories.makeConversation(
            title: "Untouched",
            providerID: originalProviderID,
            modelID: "model-a",
            messages: [TestFactories.makeMessage(text: "keep me")]
        )
        let target = TestFactories.makeConversation(
            title: "Target",
            providerID: originalProviderID,
            modelID: "legacy-model",
            messages: [TestFactories.makeMessage(text: "target body")]
        )

        try bridge.persistLegacyProjection([untouched, target], for: uid)

        let refreshed = try bridge.updateConversationModels(
            [
                ConversationModelUpdate(
                    conversationID: target.id,
                    providerID: newProviderID,
                    providerKind: .openAI,
                    modelID: "canonical-model"
                )
            ],
            uid: uid
        )

        #expect(refreshed.count == 1)
        let refreshedTarget = try #require(refreshed.first(where: { $0.id == target.id }))

        #expect(refreshedTarget.providerID == newProviderID)
        #expect(refreshedTarget.modelID == "canonical-model")
        #expect(refreshedTarget.messages.map(\.id) == target.messages.map(\.id))
        #expect(refreshedTarget.previewText == target.previewText)

        let allConversations = try bridge.fetchConversationProjection(uid: uid)
        let dbUntouched = try #require(allConversations.first(where: { $0.id == untouched.id }))
        #expect(dbUntouched.providerID == originalProviderID)
        #expect(dbUntouched.modelID == "model-a")
        #expect(dbUntouched.messages.map(\.id) == untouched.messages.map(\.id))
    }
}
