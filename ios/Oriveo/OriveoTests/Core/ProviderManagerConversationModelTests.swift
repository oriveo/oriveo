import Foundation
import Testing
@testable import Oriveo

/// Contract "model catalog and capability truth": neither a catalog refresh nor a provider change rewrites the modelID of an existing conversation.
/// Each case reads back from the database: both the in-memory projection and the persisted conversations keep the original modelID.
@Suite("ProviderManager does not rewrite conversation models", .serialized)
@MainActor
struct ProviderManagerConversationModelTests {
    private static var retainedStates: [AppState] = []

    private func makeState() -> (state: AppState, uid: String) {
        let uid = "provider-manager-conversation-model-\(UUID().uuidString)"
        let state = AppState(seedDemoData: false, sessionUID: uid)
        state.providers = []
        Self.retainedStates.append(state)
        return (state, uid)
    }

    private func seed(_ state: AppState, _ conversations: [Conversation]) {
        for conversation in conversations {
            state.upsertConversationProjection(conversation)
        }
        state.flushConversationPersistQueue()
    }

    /// The modelIDs read back from memory and from the database (by conversation id).
    private func storedModelIDs(_ state: AppState, uid: String, _ ids: [UUID]) throws -> (memory: [String?], database: [String?]) {
        state.flushConversationPersistQueue()
        let rows = try state.conversationRuntimeBridge.fetchConversationProjection(ids: ids, uid: uid)
        return (
            ids.map { state.conversation(for: $0)?.modelID },
            ids.map { id in rows.first { $0.id == id }?.modelID }
        )
    }

    private func officialFixture(kind: ProviderKind = .openAI) -> (provider: Provider, missing: Conversation, alias: Conversation) {
        let providerID = UUID()
        let canonical = TestFactories.makeModel(id: "gpt-5.4", name: "GPT-5.4", isDefault: true, canonicalModelId: "gpt-5.4")
        let provider = TestFactories.makeProvider(id: providerID, kind: kind, models: [canonical], catalogModels: [canonical])
        let missing = TestFactories.makeConversation(providerID: providerID, providerKind: kind, modelID: "removed-model")
        let alias = TestFactories.makeConversation(providerID: providerID, providerKind: kind, modelID: "gpt-5.4-2026-03-05")
        return (provider, missing, alias)
    }

    @Test("After updateProvider the modelIDs of conversations with a missing model and with a dated alias are unchanged")
    func updateProviderKeepsConversationModelIDs() throws {
        let (state, uid) = makeState()
        let fixture = officialFixture()
        state.providers = [fixture.provider]
        seed(state, [fixture.missing, fixture.alias])

        var updated = fixture.provider
        updated.catalogModels = []
        state.providerManager.updateProvider(updated)

        let ids = [fixture.missing.id, fixture.alias.id]
        let read = try storedModelIDs(state, uid: uid, ids)
        #expect(read.memory == ["removed-model", "gpt-5.4-2026-03-05"])
        #expect(read.database == ["removed-model", "gpt-5.4-2026-03-05"])
    }

    @Test("After upsertProvider the modelIDs of conversations with a missing model and with a dated alias are unchanged")
    func upsertProviderKeepsConversationModelIDs() throws {
        let (state, uid) = makeState()
        let fixture = officialFixture()
        seed(state, [fixture.missing, fixture.alias])

        #expect(state.providerManager.upsertProvider(fixture.provider))

        let ids = [fixture.missing.id, fixture.alias.id]
        let read = try storedModelIDs(state, uid: uid, ids)
        #expect(read.memory == ["removed-model", "gpt-5.4-2026-03-05"])
        #expect(read.database == ["removed-model", "gpt-5.4-2026-03-05"])
    }
}
