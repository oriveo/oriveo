import Testing
@testable import Oriveo

@Suite("ProviderSelectionSnapshot", .serialized, .sharedProcessState)
struct ProviderSelectionSnapshotTests {
    private func withOpenAIMetadata<Result>(
        _ operation: () async throws -> Result
    ) async throws -> Result {
        await MetadataClient.shared.resetForTesting()

        do {
            try await MetadataClient.shared.loadForTesting(json: """
            {
              "version": 1,
              "updatedAt": "2026-04-10T00:00:00Z",
              "providers": {
                "openAI": {
                  "displayName": "OpenAI",
                  "defaultModelId": "gpt-4o",
                  "resolveMap": {
                    "gpt-4o": "gpt-4o",
                    "o4-mini-2026-04-10": "o4-mini",
                    "o4-mini": "o4-mini"
                  },
                  "models": {
                    "gpt-4o": {
                      "canonicalModelId": "gpt-4o",
                      "displayName": "GPT-4o"
                    },
                    "o4-mini": {
                      "canonicalModelId": "o4-mini",
                      "displayName": "o4-mini",
                      "capabilities": ["text", "reasoning"]
                    }
                  }
                }
              }
            }
            """)

            let result = try await operation()
            await MetadataClient.shared.resetForTesting()
            return result
        } catch {
            await MetadataClient.shared.resetForTesting()
            throw error
        }
    }

    @Test("Current And Default Model Avoid Catalog Projection")
    func currentAndDefaultModelAvoidCatalogProjection() {
        let provider = TestFactories.makeProvider(
            kind: .openAI,
            models: [
                TestFactories.makeModel(id: "gpt-4o", name: "GPT-4o", isDefault: true, canonicalModelId: "gpt-4o"),
                TestFactories.makeModel(id: "gpt-4o-mini", name: "GPT-4o Mini", canonicalModelId: "gpt-4o-mini")
            ]
        )

        ProviderCatalogResolver.debugResolveCallCount = 0
        let currentModel = ProviderSelectionSnapshot.currentModel(
            storedModelID: "gpt-4o-2024-08-06",
            in: provider
        )
        let defaultModel = ProviderSelectionSnapshot.defaultModel(in: provider)

        #expect(currentModel?.id == "gpt-4o")
        #expect(defaultModel?.id == "gpt-4o")
        #expect(ProviderCatalogResolver.debugResolveCallCount == 0)
    }

    @Test("Empty Enabled Models Return Nil Default")
    func emptyEnabledModelsReturnNilDefault() {
        let provider = TestFactories.makeProvider(
            kind: .openAI,
            models: []
        )

        ProviderCatalogResolver.debugResolveCallCount = 0
        let defaultModel = ProviderSelectionSnapshot.defaultModel(in: provider)

        #expect(defaultModel == nil)
        #expect(ProviderCatalogResolver.debugResolveCallCount == 0)
    }

    @Test("Default Model Falls Back To Metadata Default ID")
    func defaultModelFallsBackToMetadataDefaultID() async throws {
        try await withOpenAIMetadata {
            let provider = TestFactories.makeProvider(
                kind: .openAI,
                models: [
                    TestFactories.makeModel(
                        id: "o4-mini",
                        name: "o4-mini",
                        canonicalModelId: "o4-mini"
                    ),
                    TestFactories.makeModel(
                        id: "gpt-4o",
                        name: "GPT-4o",
                        canonicalModelId: "gpt-4o"
                    )
                ]
            )

            ProviderCatalogResolver.debugResolveCallCount = 0
            let defaultModel = ProviderSelectionSnapshot.defaultModel(
                in: provider,
                metadata: MetadataClient.shared
            )

            #expect(defaultModel?.id == "gpt-4o")
            #expect(ProviderCatalogResolver.debugResolveCallCount == 0)
        }
    }

    @Test("Disabled Historical Model Stays Selected Via Metadata")
    func disabledHistoricalModelStaysSelectedViaMetadata() async throws {
        try await withOpenAIMetadata {
            let provider = TestFactories.makeProvider(
                kind: .openAI,
                models: [
                    TestFactories.makeModel(
                        id: "gpt-4o",
                        name: "GPT-4o",
                        isDefault: true,
                        canonicalModelId: "gpt-4o"
                    )
                ]
            )

            ProviderCatalogResolver.debugResolveCallCount = 0
            let currentModel = ProviderSelectionSnapshot.currentModel(
                storedModelID: "o4-mini-2026-04-10",
                in: provider
            )
            let defaultModel = ProviderSelectionSnapshot.defaultModel(in: provider)

            #expect(currentModel?.id == "o4-mini")
            #expect(currentModel?.canonicalModelId == "o4-mini")
            #expect(currentModel?.name == "o4-mini")
            #expect(defaultModel?.id == "gpt-4o")
            #expect(ProviderCatalogResolver.debugResolveCallCount == 0)
        }
    }

    @Test("New chat across connections skips connections without a key; the last used connection is tried first, the rest follow list order")
    func activeModelConnectionOrder() {
        let noKey = TestFactories.makeProvider(
            kind: .anthropic, models: [TestFactories.makeModel(id: "claude-x")], apiKey: "", apiKeyPreview: ""
        )
        let unverified = TestFactories.makeProvider(
            kind: .mistral, status: .issue("Connection has not been verified."),
            models: [TestFactories.makeModel(id: "mistral-small")]
        )
        let empty = TestFactories.makeProvider(kind: .openAI, models: [])
        let connected = TestFactories.makeProvider(kind: .deepseek, models: [TestFactories.makeModel(id: "deepseek-chat")])
        let providers = [noKey, unverified, empty, connected]

        #expect(!ProviderSelectionSnapshot.isUsableForNewChat(noKey))
        #expect(ProviderSelectionSnapshot.isUsableForNewChat(unverified))

        // No last used model: the first usable connection is tried first; connections without a key never appear.
        let none = ProviderSelectionSnapshot.activeModel(in: [noKey, connected, unverified], lastUsedModelRef: nil)
        #expect(none?.provider.id == connected.id)

        // The last used connection has no usable model: the rest follow list order, so unverified wins over connected.
        let ref = LastUsedModelRef(providerID: empty.id, modelID: "gpt-gone")
        let chosen = ProviderSelectionSnapshot.activeModel(in: providers, lastUsedModelRef: ref)
        #expect(chosen?.provider.id == unverified.id)
        #expect(chosen?.model.id == "mistral-small")

        // The last used model points at a connection without a key: that connection is skipped.
        let deadRef = LastUsedModelRef(providerID: noKey.id, modelID: "claude-x")
        #expect(ProviderSelectionSnapshot.activeModel(in: providers, lastUsedModelRef: deadRef)?.provider.id != noKey.id)
    }

    @Test("Unusable means missing credentials only: a subscription connection without login credentials is skipped, an erroring connection is not")
    func newChatSkipsOnlyMissingCredential() {
        var subscription = TestFactories.makeProvider(
            kind: .grok, models: [TestFactories.makeModel(id: "grok-4")], apiKey: "", apiKeyPreview: ""
        )
        subscription.authMode = .subscription
        let erroring = TestFactories.makeProvider(
            kind: .deepseek, status: .issue("Invalid API key."),
            models: [TestFactories.makeModel(id: "deepseek-chat")]
        )
        let providers = [subscription, erroring]

        #expect(!ProviderSelectionSnapshot.isUsableForNewChat(subscription))
        #expect(ProviderSelectionSnapshot.isUsableForNewChat(erroring))

        // The subscription connection lacks login credentials, so resolution falls through to the erroring one that has a key.
        let chosen = ProviderSelectionSnapshot.activeModel(in: providers, lastUsedModelRef: nil)
        #expect(chosen?.provider.id == erroring.id)
        #expect(chosen?.model.id == "deepseek-chat")
    }

    @Test("An empty model id makes currentModel use the new-chat chain and ignore the connection default")
    func currentModelEmptyIDIgnoresConnectionDefault() {
        let provider = TestFactories.makeProvider(
            kind: .openAI,
            models: [
                TestFactories.makeModel(id: "first"),
                TestFactories.makeModel(id: "flagged", isDefault: true)
            ]
        )
        #expect(ProviderSelectionSnapshot.currentModel(storedModelID: "", in: provider)?.id == "first")
        let ref = LastUsedModelRef(providerID: provider.id, modelID: "flagged")
        #expect(ProviderSelectionSnapshot.currentModel(storedModelID: nil, in: provider, lastUsedModelRef: ref)?.id == "flagged")
    }
}
