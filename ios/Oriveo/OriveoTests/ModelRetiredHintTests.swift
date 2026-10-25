import Foundation
import Testing
@testable import Oriveo

/// When the preferred model of a new chat is retired: automatic fallback + the hint shows only once per connection x model + the three new strings are complete in all 16 languages.
@Suite("Model retired hint", .serialized, .sharedProcessState)
struct ModelRetiredHintTests {

    private static let locales = [
        "ar", "de", "en", "es", "fr", "hi", "id", "ja", "ko",
        "pt-BR", "ru", "th", "tr", "vi", "zh-Hans", "zh-Hant",
    ]

    private static let newKeys = [
        ChatModelRemovedBanner.retiredMessageKey,
        ChatModelRemovedBanner.switchToKey,
        ModelRetiredHintHistory.lastUsedRetiredHintKey,
    ]

    @Test("The same connection x retired model hints only once; another model or another connection hints again")
    func hintShownOncePerProviderAndModel() throws {
        let suite = "model-retired-hint-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = ModelRetiredHintHistory(defaults: defaults)
        let providerID = UUID()

        let hint = NewChatRetiredFallbackHint(providerID: providerID, retiredModelID: "gpt-4-legacy", fallbackModelName: "GPT-5.4")
        #expect(hint.consumeMessage(history: history)
            == String(format: L10n.tr("Your last model was retired. Now using %@.", table: .chat), "GPT-5.4"))
        #expect(hint.consumeMessage(history: history) == nil)
        #expect(history.hasShownHint(providerID: providerID, modelID: "gpt-4-legacy"))
        #expect(defaults.stringArray(forKey: "model_retired_hint_seen.v1") == ["\(providerID.uuidString)|gpt-4-legacy"])

        #expect(history.consumeFirstHint(providerID: providerID, modelID: "gpt-4-other"))
        #expect(history.consumeFirstHint(providerID: UUID(), modelID: "gpt-4-legacy"))
    }

    @Test("lastUsed retired: the new-chat model is the fallback result of newChatModel, with a one-time hint")
    func lastUsedRetiredFallsBackForNewChat() async throws {
        let retired = TestFactories.makeModel(id: "gpt-4-legacy", name: "GPT-4 Legacy", canonicalModelId: "gpt-4-legacy")
        let fallback = TestFactories.makeModel(id: "gpt-5.4", name: "GPT-5.4", canonicalModelId: "gpt-5.4")
        let provider = TestFactories.makeProvider(kind: .openAI, models: [retired, fallback], catalogModels: [retired, fallback])
        let ref = LastUsedModelRef(providerID: provider.id, modelID: "gpt-4-legacy")

        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: ChatScreenProjectionTests.retiredMetadataJSON)

        let expected = ConversationModelRetirement.newChatModel(
            catalog: MetadataClient.shared.syncConversationRetirementRead(
                providerKind: .openAI,
                modelIDs: ["gpt-4-legacy", "gpt-5.4"]
            ).catalog,
            userModels: ["gpt-4-legacy", "gpt-5.4"],
            preferredModelId: "gpt-4-legacy",
            now: Date()
        )
        #expect(expected == .init(modelId: "gpt-5.4", hint: .lastUsedRetired))

        let active = try #require(ProviderSelectionSnapshot.activeModel(in: [provider], lastUsedModelRef: ref))
        #expect(active.provider.id == provider.id)
        #expect(active.model.id == expected.modelId)

        let hint = try #require(NewChatRetiredFallbackHint.resolve(
            requestedProviderID: nil,
            providers: [provider],
            lastUsedModelRef: ref
        ))
        #expect(hint == NewChatRetiredFallbackHint(providerID: provider.id, retiredModelID: "gpt-4-legacy", fallbackModelName: "GPT-5.4"))
        // An existing conversation (requestedProviderID non-nil) shows no new-chat hint
        #expect(NewChatRetiredFallbackHint.resolve(requestedProviderID: provider.id, providers: [provider], lastUsedModelRef: ref) == nil)

        // lastUsed still available -> no fallback, no hint
        let liveRef = LastUsedModelRef(providerID: provider.id, modelID: "gpt-5.4")
        #expect(ProviderSelectionSnapshot.newChatRetiredFallback(in: [provider], lastUsedModelRef: liveRef) == nil)
        await MetadataClient.shared.resetForTesting()
    }

    @Test("Every model of the lastUsed connection is retired: a cross-connection fallback hints once too, keyed by the connection holding the retired model, with the name of the model it fell back to")
    func lastUsedRetiredCrossConnectionFallbackStillHints() async throws {
        let retired = TestFactories.makeModel(id: "gpt-4-legacy", name: "GPT-4 Legacy", canonicalModelId: "gpt-4-legacy")
        let dead = TestFactories.makeProvider(kind: .openAI, models: [retired], catalogModels: [retired])
        let relayModel = TestFactories.makeModel(id: "relay-chat", name: "Relay Chat")
        let next = TestFactories.makeProvider(kind: .relay, models: [relayModel])
        let ref = LastUsedModelRef(providerID: dead.id, modelID: "gpt-4-legacy")

        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: ChatScreenProjectionTests.retiredMetadataJSON)

        let active = try #require(ProviderSelectionSnapshot.activeModel(in: [dead, next], lastUsedModelRef: ref))
        #expect(active.provider.id == next.id)
        #expect(active.model.id == "relay-chat")
        let hint = try #require(NewChatRetiredFallbackHint.resolve(
            requestedProviderID: nil,
            providers: [dead, next],
            lastUsedModelRef: ref
        ))
        #expect(hint == NewChatRetiredFallbackHint(providerID: dead.id, retiredModelID: "gpt-4-legacy", fallbackModelName: "Relay Chat"))
        await MetadataClient.shared.resetForTesting()
    }

    @Test("lastUsed retired: the connection isDefault is not read; falls back to the catalog defaultModelId")
    func lastUsedRetiredIgnoresConnectionDefault() async throws {
        let retired = TestFactories.makeModel(id: "gpt-4-legacy", name: "GPT-4 Legacy", canonicalModelId: "gpt-4-legacy")
        let catalogDefault = TestFactories.makeModel(id: "gpt-5.4", name: "GPT-5.4", canonicalModelId: "gpt-5.4")
        let userDefault = TestFactories.makeModel(id: "gpt-5.5", name: "GPT-5.5", isDefault: true, canonicalModelId: "gpt-5.5")
        let models = [retired, catalogDefault, userDefault]
        let provider = TestFactories.makeProvider(kind: .openAI, models: models, catalogModels: models)
        let ref = LastUsedModelRef(providerID: provider.id, modelID: "gpt-4-legacy")

        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: ChatScreenProjectionTests.retiredMetadataJSON)

        let fallback = try #require(ProviderSelectionSnapshot.newChatRetiredFallback(in: [provider], lastUsedModelRef: ref))
        #expect(fallback.model.id == "gpt-5.4")
        #expect(fallback.retiredModelID == "gpt-4-legacy")
        await MetadataClient.shared.resetForTesting()
    }

    @Test("lastUsed retired: when the enabled model is a dated snapshot and defaultModelId is its canonical, fall back to that snapshot")
    func lastUsedRetiredFallsBackToDatedSnapshotOfCatalogDefault() async throws {
        let other = TestFactories.makeModel(id: "gpt-5.5", name: "GPT-5.5", canonicalModelId: "gpt-5.5")
        let dated = TestFactories.makeModel(id: "gpt-5.4-2026-03-05", name: "GPT-5.4 (2026-03-05)", canonicalModelId: "gpt-5.4")
        let provider = TestFactories.makeProvider(kind: .openAI, models: [other, dated], catalogModels: [other, dated])
        let ref = LastUsedModelRef(providerID: provider.id, modelID: "gpt-4-legacy")

        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: ChatScreenProjectionTests.retiredMetadataJSON)

        let fallback = try #require(ProviderSelectionSnapshot.newChatRetiredFallback(in: [provider], lastUsedModelRef: ref))
        #expect(fallback.model.id == "gpt-5.4-2026-03-05")
        await MetadataClient.shared.resetForTesting()
    }

    @Test("The three new strings are complete in all 16 languages, and non-English locales differ from the English source")
    func newCopyLocalizedInEveryLocale() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Oriveo/Chat.xcstrings")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let strings = root?["strings"] as? [String: Any] ?? [:]
        #expect(Self.newKeys == ["%@ has been retired.", "Switch to %@", "Your last model was retired. Now using %@."])
        for key in Self.newKeys {
            let entry = try #require(strings[key] as? [String: Any], "Chat.xcstrings is missing \(key)")
            let localizations = entry["localizations"] as? [String: Any] ?? [:]
            #expect(Set(localizations.keys) == Set(Self.locales), "\(key) locales are incomplete")
            for locale in Self.locales {
                let unit = (localizations[locale] as? [String: Any])?["stringUnit"] as? [String: Any]
                let value = unit?["value"] as? String ?? ""
                #expect(unit?["state"] as? String == "translated", "\(locale) · \(key)")
                #expect(value.contains("%@"), "\(locale) · \(key) lost the placeholder")
                if locale == "en" {
                    #expect(value == key)
                } else {
                    #expect(!value.isEmpty && value != key, "\(locale) · \(key) is still English or empty: \(value)")
                }
            }
        }
    }
}
