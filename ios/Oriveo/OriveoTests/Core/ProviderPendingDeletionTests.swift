import Foundation
import Testing
@testable import Oriveo

@Suite("ProviderDeletion", .serialized)
@MainActor
struct ProviderPendingDeletionTests {
    @Test("Custom LLMDeletion Clears Connection Data And Retains Conversations")
    func customLLMDeletionClearsConnectionDataAndRetainsConversations() throws {
        let uid = "pending-provider-del-\(UUID().uuidString)"
        let providerID = UUID()
        let modelID = "delete-contract-model"
        let conversationID = UUID()
        let settings = GenerationParameterSettingsStore.shared
        let presets = GenerationParameterPresetStore.shared
        defer {
            settings.removeScopes(providerID: providerID)
            presets.removeScopes(providerID: providerID)
            ProviderAPIKeyStore.delete(providerID: providerID, uid: uid)
            DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }

        weak var releasedState: AppState?
        do {
            let state = AppState(seedDemoData: true, sessionUID: uid)
            releasedState = state
            let seed = TestFactories.makeProvider(
                id: providerID,
                kind: .relay,
                models: [TestFactories.makeModel(id: modelID, isDefault: true)],
                customName: "Deletion contract relay"
            )
            state.providers = [seed]

            let persistedProvider = try #require(state.provider(for: providerID))
            let persistedModel = try #require(persistedProvider.models.first(where: { $0.id == modelID }))
            ProviderAPIKeyStore.save(apiKey: "delete-contract-key", providerID: persistedProvider.id, uid: uid)
            let overrides = GenerationParameterOverrides(values: [
                "temperature": .init(state: .value, value: .number(0.42)),
            ])
            settings.setConnectionDefaults(overrides, providerID: persistedProvider.id)
            settings.setModelDefaults(overrides, providerID: persistedProvider.id, modelID: persistedModel.id)
            settings.setSessionOverrides(
                overrides,
                providerID: persistedProvider.id,
                modelID: persistedModel.id,
                conversationID: conversationID
            )
            _ = presets.save(
                name: "Delete contract",
                providerID: persistedProvider.id,
                modelID: persistedModel.id,
                profileFingerprint: "relay-delete-contract",
                values: overrides
            )
            state.conversations = [TestFactories.makeConversation(
                id: conversationID,
                providerID: persistedProvider.id,
                providerKind: persistedProvider.kind,
                modelID: persistedModel.id
            )]
            let persistedConversation = try #require(state.conversation(for: conversationID))

            #expect(state.deleteProvider(providerID: persistedProvider.id))

            #expect(state.provider(for: persistedProvider.id) == nil)
            #expect(ProviderAPIKeyStore.load(providerID: persistedProvider.id, uid: uid) == nil)
            #expect(settings.connectionDefaults(providerID: persistedProvider.id) == nil)
            #expect(settings.modelDefaults(providerID: persistedProvider.id, modelID: persistedModel.id) == nil)
            #expect(settings.sessionOverrides(
                providerID: persistedProvider.id,
                modelID: persistedModel.id,
                conversationID: persistedConversation.id
            ) == nil)
            #expect(presets.list(
                providerID: persistedProvider.id,
                modelID: persistedModel.id,
                profileFingerprint: "relay-delete-contract"
            ).isEmpty)
            #expect(state.conversation(for: persistedConversation.id)?.id == persistedConversation.id)
        }
        #expect(releasedState == nil)
    }
}
