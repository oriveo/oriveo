import Foundation
import Testing
@testable import Oriveo

// Truth table for how `ProviderCatalogResolver` classifies a provider's models: which of them are
// manual (present locally but absent from the catalog), which stay enabled, and what an alias of a
// catalog model resolves to.

@Suite("Manual Retained Truth Table Tests", .serialized)
struct ManualRetainedTruthTableTests {

    private let metadataJSON = """
    {
      "version": 1,
      "contractVersion": 1,
      "providers": {
        "openAI": {
          "defaultModelId": "gpt-5.4",
          "resolveMap": {
            "gpt-5.4": "gpt-5.4",
            "gpt-5.4-2026-03-05": "gpt-5.4"
          },
          "models": {
            "gpt-5.4": {
              "canonicalModelId": "gpt-5.4",
              "displayName": "GPT-5.4",
              "capabilities": ["text", "reasoning"],
              "pricing": { "promptPerMToken": 2.0, "completionPerMToken": 8.0 },
              "profiles": {},
              "uiHints": { "rank": 200 }
            }
          }
        }
      }
    }
    """

    private func loadMetadata() async throws -> MetadataClient {
        let client = MetadataClient()
        await client.resetForTesting()
        try await client.loadForTesting(json: metadataJSON)
        return client
    }

    private func makeProvider(enabledModels: [AIModel]) -> Provider {
        Provider(
            id: UUID(),
            kind: .openAI,
            status: .connected,
            models: enabledModels,
            catalogModels: [],
            lastCheckedAt: Date(),
            apiKey: "sk-test",
            apiKeyPreview: "sk-...st",
            lastError: nil,
            baseURLText: nil
        )
    }

    private func model(id: String, isDefault: Bool = false, canonical: String? = nil) -> AIModel {
        AIModel(
            id: id,
            name: id,
            capabilities: [.text],
            reasoningModeAvailable: false,
            isAvailable: true,
            isDefault: isDefault,
            priceTier: "",
            canonicalModelId: canonical
        )
    }

    @Test("Case1")
    func case1() async throws {
        let metadata = try await loadMetadata()
        let provider = makeProvider(enabledModels: [model(id: "gpt-5.4", isDefault: true)])

        let catalog = ProviderCatalogResolver.resolve(provider: provider, metadata: metadata)

        let target = try #require(catalog.enabledModels.first(where: { $0.model.id == "gpt-5.4" }))
        #expect(!target.isManual)
        #expect(target.model.name == "GPT-5.4")
    }

    @Test("Case3")
    func case3() async throws {
        let metadata = try await loadMetadata()
        let provider = makeProvider(enabledModels: [])

        let catalog = ProviderCatalogResolver.resolve(provider: provider, metadata: metadata)

        let target = try #require(catalog.catalog.first(where: { $0.model.id == "gpt-5.4" }))
        #expect(!target.isEnabled)
        #expect(!target.isManual)
    }

    @Test("Case4")
    func case4() async throws {
        let metadata = try await loadMetadata()
        let unknownModel = model(id: "gpt-legacy-mystery")
        let provider = makeProvider(enabledModels: [unknownModel])

        let catalog = ProviderCatalogResolver.resolve(provider: provider, metadata: metadata)

        let target = try #require(catalog.enabledModels.first(where: { $0.model.id == "gpt-legacy-mystery" }))
        #expect(target.isManual)
        #expect(catalog.hasManualModels)
    }

    @Test("Case6")
    func case6() async throws {
        let metadata = try await loadMetadata()
        let provider = makeProvider(enabledModels: [])

        let catalog = ProviderCatalogResolver.resolve(provider: provider, metadata: metadata)

        #expect(catalog.catalog.contains(where: { $0.model.id == "gpt-legacy-mystery" }) == false)
    }

    @Test("Case8")
    func case8() async throws {
        let metadata = try await loadMetadata()
        let aliasModel = AIModel(
            id: "gpt-5.4-2026-03-05",
            name: "Old Snapshot",
            capabilities: [.text],
            reasoningModeAvailable: false,
            isAvailable: true,
            isDefault: true,
            priceTier: "",
            canonicalModelId: "gpt-5.4"
        )
        let provider = makeProvider(enabledModels: [aliasModel])

        let catalog = ProviderCatalogResolver.resolve(provider: provider, metadata: metadata)

        let target = try #require(catalog.enabledModels.first)
        #expect(!target.isManual)
        #expect(target.model.id == "gpt-5.4" || target.model.canonicalModelId == "gpt-5.4")
    }

    @Test("Case2")
    func case2() async throws {
        let metadata = try await loadMetadata()
        ManualRetainedPruningPolicy.flagOverrideForTesting = true
        defer { ManualRetainedPruningPolicy.flagOverrideForTesting = nil }

        let provider = makeProvider(enabledModels: [model(id: "gpt-5.4", isDefault: true)])
        let catalog = ProviderCatalogResolver.resolve(provider: provider, metadata: metadata)

        let target = try #require(catalog.enabledModels.first(where: { $0.model.id == "gpt-5.4" }))
        #expect(!target.isManual)
        #expect(target.model.name == "GPT-5.4")

        let pruned = ManualRetainedPruningPolicy.apply(
            provider: provider,
            resolvedCatalog: catalog,
            metadata: metadata
        )
        #expect(pruned.count == 1)
        #expect(pruned.first?.id == "gpt-5.4")
    }

    @Test("Case5")
    func case5() async throws {
        let metadata = try await loadMetadata()
        ManualRetainedPruningPolicy.flagOverrideForTesting = true
        defer { ManualRetainedPruningPolicy.flagOverrideForTesting = nil }

        let provider = makeProvider(enabledModels: [
            model(id: "gpt-5.4"),
            model(id: "gpt-legacy-mystery", isDefault: true),
        ])
        let catalog = ProviderCatalogResolver.resolve(provider: provider, metadata: metadata)

        #expect(catalog.enabledModels.contains(where: { $0.isManual && $0.model.id == "gpt-legacy-mystery" }))

        let pruned = ManualRetainedPruningPolicy.apply(
            provider: provider,
            resolvedCatalog: catalog,
            metadata: metadata
        )
        #expect(pruned.contains(where: { $0.id == "gpt-legacy-mystery" }) == false)
        let newDefault = pruned.first(where: { $0.isDefault })
        #expect(newDefault?.id == "gpt-5.4")
    }

    @Test("Case5 Fallback Without Metadata Default")
    func case5FallbackWithoutMetadataDefault() async throws {
        let metadata = try await loadMetadata()
        ManualRetainedPruningPolicy.flagOverrideForTesting = true
        defer { ManualRetainedPruningPolicy.flagOverrideForTesting = nil }

        let provider = makeProvider(enabledModels: [
            model(id: "gpt-legacy-mystery", isDefault: true),
        ])
        let catalog = ProviderCatalogResolver.resolve(provider: provider, metadata: metadata)

        let pruned = ManualRetainedPruningPolicy.apply(
            provider: provider,
            resolvedCatalog: catalog,
            metadata: metadata
        )

        #expect(pruned.isEmpty)
    }
}
