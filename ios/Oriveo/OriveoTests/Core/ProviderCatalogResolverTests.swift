import Foundation
import Testing
@testable import Oriveo

@Suite("ProviderCatalogResolver", .serialized)
struct ProviderCatalogResolverTests {


    private func makeProvider(
        kind: ProviderKind = .openAI,
        models: [AIModel] = [],
        catalogModels: [AIModel] = []
    ) -> Provider {
        Provider(
            id: .init(),
            kind: kind,
            status: .connected,
            models: models,
            catalogModels: catalogModels,
            lastCheckedAt: nil,
            apiKey: "sk-test",
            apiKeyPreview: "sk-...test",
            lastError: nil,
            baseURLText: nil
        )
    }

    private func makeModel(
        id: String,
        name: String? = nil,
        isAvailable: Bool = true,
        isDefault: Bool = false,
        canonicalModelId: String? = nil,
        isRecommended: Bool = false,
        sortRank: Int? = nil,
        capabilities: [ModelCapability] = [.text]
    ) -> AIModel {
        AIModel(
            id: id,
            name: name ?? id,
            capabilities: capabilities,
            reasoningModeAvailable: false,
            isAvailable: isAvailable,
            isDefault: isDefault,
            priceTier: "",
            canonicalModelId: canonicalModelId,
            isRecommended: isRecommended,
            sortRank: sortRank
        )
    }

    private let metadataJSON = """
    {
        "version": 1,
        "providers": {
            "openAI": {
                "defaultModelId": "gpt-4o",
                "resolveMap": {
                    "gpt-4o-2024-08-06": "gpt-4o",
                    "gpt-4o-mini": "gpt-4o-mini"
                },
                "models": {
                    "gpt-4o": {
                        "canonicalModelId": "gpt-4o",
                        "aliases": ["gpt-4o-2024-08-06"],
                        "displayName": "GPT-4o",
                        "contextLength": 128000,
                        "capabilities": ["text", "image", "file"],
                        "pricing": { "promptPerMToken": 2.5, "completionPerMToken": 10.0 },
                        "profiles": { "reasoning": null, "webSearch": null, "imageGen": null },
                        "uiHints": { "groupKey": null, "groupName": null, "rank": 100, "recommended": true, "badgeOrder": null }
                    },
                    "gpt-4o-mini": {
                        "canonicalModelId": "gpt-4o-mini",
                        "displayName": "GPT-4o Mini",
                        "contextLength": 128000,
                        "capabilities": ["text", "image"],
                        "pricing": { "promptPerMToken": 0.15, "completionPerMToken": 0.6 },
                        "profiles": { "reasoning": null, "webSearch": null, "imageGen": null },
                        "uiHints": { "groupKey": null, "groupName": null, "rank": 80, "recommended": true, "badgeOrder": null }
                    },
                    "o3-mini": {
                        "canonicalModelId": "o3-mini",
                        "displayName": "o3 Mini",
                        "contextLength": 200000,
                        "capabilities": ["reasoning", "text"],
                        "pricing": { "promptPerMToken": 1.1, "completionPerMToken": 4.4 },
                        "profiles": { "reasoning": "o3-mini", "webSearch": null, "imageGen": null },
                        "uiHints": { "groupKey": null, "groupName": null, "rank": 90, "recommended": false, "badgeOrder": null }
                    }
                }
            }
        }
    }
    """

    private func loadedMetadata() async throws -> MetadataClient {
        let client = MetadataClient()
        await client.resetForTesting()
        try await client.loadForTesting(json: metadataJSON)
        return client
    }


    @Test("Official Provider With Metadata")
    func officialProviderWithMetadata() async throws {
        let metadata = try await loadedMetadata()
        let provider = makeProvider(
            kind: .openAI,
            models: [makeModel(id: "gpt-4o", isDefault: true)]
        )

        let catalog = ProviderCatalogResolver.resolve(provider: provider, metadata: metadata)

        #expect(catalog.catalog.count == 3)
        #expect(catalog.enabledModels.count == 1)
        #expect(catalog.enabledModels.first?.model.id == "gpt-4o")
        #expect(catalog.enabledModels.first?.isEnabled == true)
        #expect(catalog.enabledModels.first?.isManual == false)
    }


    @Test("Relay Uses Local Catalog")
    func relayUsesLocalCatalog() async throws {
        let metadata = try await loadedMetadata()
        let relayModels = [
            makeModel(id: "my-model-1", isDefault: true),
            makeModel(id: "my-model-2"),
        ]
        let provider = makeProvider(
            kind: .relay,
            models: [relayModels[0]],
            catalogModels: relayModels
        )

        let catalog = ProviderCatalogResolver.resolve(provider: provider, metadata: metadata)

        #expect(catalog.catalog.count == 2)
        #expect(catalog.enabledModels.count == 1)
        #expect(catalog.enabledModels.first?.model.id == "my-model-1")
        #expect(catalog.recommendedModels.isEmpty)
    }


    @Test("Manual Models Detected")
    func manualModelsDetected() async throws {
        let metadata = try await loadedMetadata()
        let manualModel = makeModel(id: "openAI-manual-custom-model", name: "custom-model")
        let provider = makeProvider(
            kind: .openAI,
            models: [
                makeModel(id: "gpt-4o", isDefault: true),
                manualModel,
            ]
        )

        let catalog = ProviderCatalogResolver.resolve(provider: provider, metadata: metadata)

        #expect(catalog.hasManualModels == true)
        let manual = catalog.enabledModels.first(where: { $0.isManual })
        #expect(manual != nil)
        #expect(manual?.model.id == manualModel.id)
    }


    @Test("Alias Matching")
    func aliasMatching() async throws {
        let metadata = try await loadedMetadata()
        let provider = makeProvider(
            kind: .openAI,
            models: [makeModel(id: "gpt-4o-2024-08-06", isDefault: true)]
        )

        let catalog = ProviderCatalogResolver.resolve(provider: provider, metadata: metadata)

        let enabled = catalog.enabledModels.filter { !$0.isManual }
        #expect(enabled.count >= 1)
        #expect(catalog.hasManualModels == false)
    }


    @Test("Metadata Empty Degradation")
    func metadataEmptyDegradation() async throws {
        let metadata = MetadataClient()
        await metadata.resetForTesting()

        let provider = makeProvider(
            kind: .openAI,
            models: [
                makeModel(id: "gpt-4o", isDefault: true),
                makeModel(id: "gpt-3.5-turbo"),
            ]
        )

        let catalog = ProviderCatalogResolver.resolve(provider: provider, metadata: metadata)

        #expect(catalog.enabledModels.count == 2)
        #expect(catalog.enabledModels.allSatisfy { $0.isManual })
        #expect(catalog.hasManualModels == true)
        #expect(catalog.recommendedModels.isEmpty)
    }


    @Test("Zero Enabled Models")
    func zeroEnabledModels() async throws {
        let metadata = try await loadedMetadata()
        let provider = makeProvider(kind: .openAI, models: [])

        let catalog = ProviderCatalogResolver.resolve(provider: provider, metadata: metadata)

        #expect(catalog.enabledModels.isEmpty)
        #expect(catalog.catalog.count == 3)
        #expect(catalog.defaultModel == nil)
        #expect(catalog.hasManualModels == false)
    }


    @Test("Default Model Resolution")
    func defaultModelResolution() async throws {
        let metadata = try await loadedMetadata()

        let providerA = makeProvider(
            kind: .openAI,
            models: [
                makeModel(id: "gpt-4o-mini", isDefault: true),
                makeModel(id: "gpt-4o"),
            ]
        )
        let catalogA = ProviderCatalogResolver.resolve(provider: providerA, metadata: metadata)
        #expect(catalogA.defaultModel?.model.id == "gpt-4o-mini")

        let providerB = makeProvider(
            kind: .openAI,
            models: [
                makeModel(id: "gpt-4o-mini"),
                makeModel(id: "gpt-4o"),
            ]
        )
        let catalogB = ProviderCatalogResolver.resolve(provider: providerB, metadata: metadata)
        #expect(catalogB.defaultModel?.model.id == "gpt-4o")

        let providerC = makeProvider(
            kind: .openAI,
            models: [makeModel(id: "o3-mini")]
        )
        let catalogC = ProviderCatalogResolver.resolve(provider: providerC, metadata: metadata)
        #expect(catalogC.defaultModel?.model.id == "o3-mini")
    }


    @Test("Recommended Models Derivation")
    func recommendedModelsDerivation() async throws {
        let metadata = try await loadedMetadata()
        let provider = makeProvider(
            kind: .openAI,
            models: [makeModel(id: "o3-mini", isDefault: true)]
        )

        let catalog = ProviderCatalogResolver.resolve(provider: provider, metadata: metadata)

        let recommendedIds = catalog.recommendedModels.map(\.model.id)
        #expect(recommendedIds.contains("gpt-4o"))
        #expect(recommendedIds.contains("gpt-4o-mini"))
        #expect(!recommendedIds.contains("o3-mini"))
        if catalog.recommendedModels.count >= 2 {
            let ranks = catalog.recommendedModels.compactMap(\.model.sortRank)
            #expect(ranks == ranks.sorted(by: >))
        }
    }


    private let aggregatorMetadataJSON = """
    {
        "version": 1,
        "contractVersion": 1,
        "providers": {
            "openRouter": {
                "defaultModelId": "anthropic/claude-sonnet-4",
                "resolveMap": {
                    "anthropic/claude-sonnet-4": "anthropic/claude-sonnet-4",
                    "meta-llama/llama-3-8b": "meta-llama/llama-3-8b"
                },
                "models": {
                    "anthropic/claude-sonnet-4": {
                        "canonicalModelId": "anthropic/claude-sonnet-4",
                        "displayName": "Claude Sonnet 4",
                        "vendorKey": "anthropic",
                        "vendorName": "Anthropic",
                        "capabilities": ["text", "reasoning"],
                        "pricing": { "promptPerMToken": 3.0, "completionPerMToken": 15.0 },
                        "profiles": {},
                        "uiHints": { "groupKey": "anthropic", "groupName": "Anthropic", "rank": 150, "recommended": true }
                    },
                    "meta-llama/llama-3-8b": {
                        "canonicalModelId": "meta-llama/llama-3-8b",
                        "displayName": "Llama 3 8B",
                        "capabilities": ["text"],
                        "pricing": { "promptPerMToken": 0.1, "completionPerMToken": 0.1 },
                        "profiles": {},
                        "uiHints": { "rank": 50 }
                    }
                }
            }
        }
    }
    """

    @Test("Open Router Group Key From Metadata")
    func openRouterGroupKeyFromMetadata() async throws {
        let metadata = MetadataClient()
        await metadata.resetForTesting()
        try await metadata.loadForTesting(json: aggregatorMetadataJSON)

        let provider = makeProvider(
            kind: .openRouter,
            models: [makeModel(id: "anthropic/claude-sonnet-4", isDefault: true)]
        )
        let catalog = ProviderCatalogResolver.resolve(provider: provider, metadata: metadata)

        let claude = try #require(catalog.catalog.first(where: { $0.model.id == "anthropic/claude-sonnet-4" }))
        #expect(claude.model.groupKey == "anthropic")
        #expect(claude.model.groupName == "Anthropic")
    }

    @Test("Open Router Group Key Not Fallback To Slug")
    func openRouterGroupKeyNotFallbackToSlug() async throws {
        let metadata = MetadataClient()
        await metadata.resetForTesting()
        try await metadata.loadForTesting(json: aggregatorMetadataJSON)

        let provider = makeProvider(
            kind: .openRouter,
            models: [makeModel(id: "meta-llama/llama-3-8b")]
        )
        let catalog = ProviderCatalogResolver.resolve(provider: provider, metadata: metadata)

        let llama = try #require(catalog.catalog.first(where: { $0.model.id == "meta-llama/llama-3-8b" }))
        #expect(llama.model.groupKey == nil)
        #expect(llama.model.groupName == nil)
    }

    @Test("Silicon Flow Group Key From Metadata")
    func siliconFlowGroupKeyFromMetadata() async throws {
        let metadata = MetadataClient()
        await metadata.resetForTesting()
        try await metadata.loadForTesting(json: """
        {
            "version": 1,
            "contractVersion": 1,
            "providers": {
                "siliconFlow": {
                    "defaultModelId": "deepseek-ai/DeepSeek-V3",
                    "resolveMap": {
                        "deepseek-ai/DeepSeek-V3": "deepseek-ai/DeepSeek-V3",
                        "Qwen/Qwen3-235B": "Qwen/Qwen3-235B"
                    },
                    "models": {
                        "deepseek-ai/DeepSeek-V3": {
                            "canonicalModelId": "deepseek-ai/DeepSeek-V3",
                            "displayName": "DeepSeek V3",
                            "vendorKey": "deepseek-ai",
                            "vendorName": "DeepSeek",
                            "capabilities": ["text"],
                            "profiles": {},
                            "uiHints": { "groupKey": "deepseek-ai", "groupName": "DeepSeek" }
                        },
                        "Qwen/Qwen3-235B": {
                            "canonicalModelId": "Qwen/Qwen3-235B",
                            "displayName": "Qwen3 235B",
                            "capabilities": ["text"],
                            "profiles": {},
                            "uiHints": {}
                        }
                    }
                }
            }
        }
        """)

        let provider = makeProvider(
            kind: .siliconFlow,
            models: [
                makeModel(id: "deepseek-ai/DeepSeek-V3", isDefault: true),
                makeModel(id: "Qwen/Qwen3-235B"),
            ]
        )
        let catalog = ProviderCatalogResolver.resolve(provider: provider, metadata: metadata)

        let deepSeek = try #require(catalog.catalog.first(where: { $0.model.id == "deepseek-ai/DeepSeek-V3" }))
        #expect(deepSeek.model.groupKey == "deepseek-ai")
        #expect(deepSeek.model.groupName == "DeepSeek")

        let qwen = try #require(catalog.catalog.first(where: { $0.model.id == "Qwen/Qwen3-235B" }))
        #expect(qwen.model.groupKey == nil)
    }


    @Test("Safe Degrade Does Not Expand Catalog")
    func safeDegradeDoesNotExpandCatalog() async throws {
        let tooNewJSON = """
        {
          "version": 99,
          "contractVersion": 99,
          "providers": {
            "openAI": {
              "defaultModelId": "gpt-future",
              "resolveMap": { "gpt-future": "gpt-future" },
              "models": {
                "gpt-future": {
                  "canonicalModelId": "gpt-future",
                  "displayName": "GPT Future",
                  "capabilities": ["text"],
                  "profiles": {}
                }
              }
            }
          }
        }
        """
        let metadata = MetadataClient()
        await metadata.resetForTesting()
        try await metadata.loadForTesting(json: tooNewJSON)

        let userEnabled = makeModel(id: "gpt-4o", isDefault: true)
        let provider = makeProvider(kind: .openAI, models: [userEnabled])

        let catalog = ProviderCatalogResolver.resolve(provider: provider, metadata: metadata)

        #expect(catalog.catalog.contains(where: { $0.model.id == "gpt-future" }) == false)
        let retained = try #require(catalog.enabledModels.first)
        #expect(retained.model.id == "gpt-4o")
        #expect(retained.isManual)
        #expect(catalog.hasManualModels)
        #expect(catalog.recommendedModels.isEmpty)
    }

    @Test("In Compatible Window Does Expand Catalog")
    func inCompatibleWindowDoesExpandCatalog() async throws {
        let compatibleJSON = """
        {
          "version": 42,
          "contractVersion": 2,
          "providers": {
            "openAI": {
              "defaultModelId": "gpt-next",
              "resolveMap": { "gpt-next": "gpt-next" },
              "models": {
                "gpt-next": {
                  "canonicalModelId": "gpt-next",
                  "displayName": "GPT Next",
                  "capabilities": ["text"],
                  "profiles": {}
                }
              }
            }
          }
        }
        """
        let metadata = MetadataClient()
        await metadata.resetForTesting()
        try await metadata.loadForTesting(json: compatibleJSON)

        let provider = makeProvider(kind: .openAI, models: [])
        let catalog = ProviderCatalogResolver.resolve(provider: provider, metadata: metadata)

        #expect(catalog.catalog.contains(where: { $0.model.id == "gpt-next" }))
    }

    // MARK: - availableModelCount

    @Test("Available Model Count")
    func availableModelCount() async throws {
        let metadata = try await loadedMetadata()
        let provider = makeProvider(
            kind: .openAI,
            models: [makeModel(id: "gpt-4o", isDefault: true)]
        )

        let catalog = ProviderCatalogResolver.resolve(provider: provider, metadata: metadata)

        #expect(catalog.availableModelCount == 3)
    }


    @Test("Resolve Memoizes On Both Axes")
    func resolveMemoizesOnBothAxes() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: metadataJSON)
        ProviderCatalogResolver.resetMemoForTesting()
        ProviderCatalogResolver.debugResolveComputationCount = 0

        let provider = makeProvider(
            kind: .openAI,
            models: [makeModel(id: "gpt-4o", isDefault: true)]
        )

        let first = ProviderCatalogResolver.resolve(provider: provider)
        let second = ProviderCatalogResolver.resolve(provider: provider)
        #expect(ProviderCatalogResolver.debugResolveComputationCount == 1)
        #expect(first.catalog.map(\.model.id) == second.catalog.map(\.model.id))

        var renamed = provider
        renamed.models = [makeModel(id: "gpt-4o", name: "GPT-4o renamed", isDefault: true)]
        _ = ProviderCatalogResolver.resolve(provider: renamed)
        #expect(ProviderCatalogResolver.debugResolveComputationCount == 2)

        try await MetadataClient.shared.loadForTesting(json: metadataJSON)
        _ = ProviderCatalogResolver.resolve(provider: provider)
        #expect(ProviderCatalogResolver.debugResolveComputationCount == 3)

        ProviderCatalogResolver.resetMemoForTesting()
        await MetadataClient.shared.resetForTesting()
    }
}
