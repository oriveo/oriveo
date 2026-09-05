import Testing
@testable import Oriveo

@Suite("ProviderSelectionSnapshot", .serialized)
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
}
