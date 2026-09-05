import Foundation
import Testing
@testable import Oriveo

@Suite("ModelDisplayLookup", .serialized)
struct ModelDisplayLookupTests {
    @Test("Official Provider Lookup Avoids Catalog Projection")
    func officialProviderLookupAvoidsCatalogProjection() async throws {
        let metadata = MetadataClient()
        await metadata.resetForTesting()
        try await metadata.loadForTesting(json: """
        {
          "version": 1,
          "providers": {
            "openAI": {
              "defaultModelId": "gpt-4o",
              "resolveMap": {
                "gpt-4o-2024-08-06": "gpt-4o",
                "gpt-4o": "gpt-4o"
              },
              "models": {
                "gpt-4o": {
                  "canonicalModelId": "gpt-4o",
                  "displayName": "GPT-4o Latest"
                }
              }
            }
          }
        }
        """)

        let provider = TestFactories.makeProvider(
            kind: .openAI,
            models: [TestFactories.makeModel(id: "gpt-4o", name: "GPT-4o Local")]
        )

        ProviderCatalogResolver.debugResolveCallCount = 0
        let lookup = await MainActor.run {
            ModelDisplayLookup(providers: [provider], metadata: metadata)
        }
        let providerName = lookup.providerDisplayName(providerID: provider.id)
        let modelName = lookup.modelDisplayName(
            providerID: provider.id,
            modelID: "gpt-4o-2024-08-06",
            fallback: "Legacy Snapshot"
        )

        #expect(providerName == ProviderKind.openAI.displayName)
        #expect(modelName == "GPT-4o Latest")
        #expect(ProviderCatalogResolver.debugResolveCallCount == 0)
    }

    @Test("Metadata Only Historical Model Still Resolves Display Name")
    func metadataOnlyHistoricalModelStillResolvesDisplayName() async throws {
        let metadata = MetadataClient()
        await metadata.resetForTesting()
        try await metadata.loadForTesting(json: """
        {
          "version": 1,
          "providers": {
            "openAI": {
              "defaultModelId": "gpt-4o",
              "resolveMap": {
                "o4-mini-2026-04-10": "o4-mini",
                "o4-mini": "o4-mini"
              },
              "models": {
                "o4-mini": {
                  "canonicalModelId": "o4-mini",
                  "displayName": "o4-mini"
                }
              }
            }
          }
        }
        """)

        let provider = TestFactories.makeProvider(
            kind: .openAI,
            models: [TestFactories.makeModel(id: "gpt-4o", name: "GPT-4o Local")]
        )

        ProviderCatalogResolver.debugResolveCallCount = 0
        let lookup = await MainActor.run {
            ModelDisplayLookup(providers: [provider], metadata: metadata)
        }
        let modelName = lookup.modelDisplayName(
            providerID: provider.id,
            modelID: "o4-mini-2026-04-10",
            fallback: "Legacy Snapshot"
        )

        #expect(modelName == "o4-mini")
        #expect(ProviderCatalogResolver.debugResolveCallCount == 0)
    }

    @Test("Relay Lookup Uses Local State")
    func relayLookupUsesLocalState() async {
        let provider = TestFactories.makeProvider(
            kind: .relay,
            models: [TestFactories.makeModel(id: "custom-model", name: "Custom Relay Model", isDefault: true)],
            catalogModels: [TestFactories.makeModel(id: "custom-model", name: "Custom Relay Model")],
            customName: "My Relay"
        )

        ProviderCatalogResolver.debugResolveCallCount = 0
        let lookup = await MainActor.run {
            ModelDisplayLookup(providers: [provider])
        }
        let providerName = lookup.providerDisplayName(providerID: provider.id)
        let modelName = lookup.modelDisplayName(
            providerID: provider.id,
            modelID: "custom-model",
            fallback: "Fallback"
        )

        #expect(providerName == "My Relay")
        #expect(modelName == "Custom Relay Model")
        #expect(ProviderCatalogResolver.debugResolveCallCount == 0)
    }


    @Test("Context Length Prefers Metadata")
    func contextLengthPrefersMetadata() async throws {
        let metadata = MetadataClient()
        await metadata.resetForTesting()
        try await metadata.loadForTesting(json: """
        {
          "version": 1,
          "providers": {
            "openAI": {
              "defaultModelId": "gpt-4o",
              "resolveMap": {
                "gpt-4o-2024-08-06": "gpt-4o",
                "gpt-4o": "gpt-4o"
              },
              "models": {
                "gpt-4o": {
                  "canonicalModelId": "gpt-4o",
                  "displayName": "GPT-4o Latest",
                  "contextLength": 128000
                }
              }
            }
          }
        }
        """)

        var localModel = TestFactories.makeModel(id: "gpt-4o", name: "GPT-4o Local")
        localModel.contextLength = 8_000
        let provider = TestFactories.makeProvider(kind: .openAI, models: [localModel])

        let lookup = await MainActor.run {
            ModelDisplayLookup(providers: [provider], metadata: metadata)
        }
        #expect(lookup.contextLength(providerID: provider.id, modelID: "gpt-4o") == 128_000)
        #expect(lookup.contextLength(providerID: provider.id, modelID: "gpt-4o-2024-08-06") == 128_000)
    }

    @Test("Context Length Falls Back To Local Then Nil")
    func contextLengthFallsBackToLocalThenNil() async {
        var withWindow = TestFactories.makeModel(id: "custom-model", name: "Custom")
        withWindow.contextLength = 32_000
        let withoutWindow = TestFactories.makeModel(id: "bare-model", name: "Bare")

        let provider = TestFactories.makeProvider(
            kind: .relay,
            models: [withWindow, withoutWindow],
            customName: "My Relay"
        )

        let lookup = await MainActor.run { ModelDisplayLookup(providers: [provider]) }
        #expect(lookup.contextLength(providerID: provider.id, modelID: "custom-model") == 32_000)
        #expect(lookup.contextLength(providerID: provider.id, modelID: "bare-model") == nil)
        #expect(lookup.contextLength(providerID: provider.id, modelID: "removed-model") == nil)
        #expect(lookup.contextLength(providerID: UUID(), modelID: "custom-model") == nil)
    }

    @Test("Fingerprint Tracks Context Length")
    func fingerprintTracksContextLength() async {
        let providerID = UUID()
        var model = TestFactories.makeModel(id: "gpt-4o", name: "GPT-4o")
        model.contextLength = 8_000
        let before = TestFactories.makeProvider(id: providerID, kind: .openAI, models: [model])

        model.contextLength = 128_000
        let after = TestFactories.makeProvider(id: providerID, kind: .openAI, models: [model])

        let lhs = await MainActor.run { ModelDisplayLookup.fingerprint(providers: [before]) }
        let rhs = await MainActor.run { ModelDisplayLookup.fingerprint(providers: [after]) }
        #expect(lhs != rhs)
    }
}
