import Foundation
import Testing
@testable import Oriveo

@Suite("CatalogModelBuilder", .serialized)
struct CatalogModelBuilderTests {

    // MARK: - buildCatalogModel

    @Test("Build With Metadata")
    func buildWithMetadata() async throws {
        let client = try await makeLoadedClient()

        let model = await CatalogModelBuilder.buildCatalogModel(
            providerKind: .openAI,
            runtimeModelId: "gpt-4o",
            fallbackName: "gpt-4o-fallback",
            metadataClient: client
        )

        #expect(model.id == "gpt-4o")
        #expect(model.name == "GPT-4o")
        #expect(model.canonicalModelId == "gpt-4o")
        #expect(model.capabilities.contains(.image))
        #expect(model.capabilities.contains(.reasoning))
        #expect(model.isRecommended == true)
        #expect(model.sortRank == 130)
        #expect(model.groupKey == "gpt-4o")
        #expect(model.groupName == "GPT-4o")
        #expect(model.reasoningProfile == "oai_responses")
        #expect(model.promptPrice == 0.0000025)
        #expect(model.completionPrice == 0.00001)
        #expect(model.isDefault == true)
        #expect(!model.priceTier.isEmpty)
    }

    @Test("Build Without Metadata")
    func buildWithoutMetadata() async throws {
        let client = try await makeLoadedClient()

        let model = await CatalogModelBuilder.buildCatalogModel(
            providerKind: .openAI,
            runtimeModelId: "unknown-model-xyz",
            fallbackName: "Unknown Model",
            fallbackContextLength: 32000,
            fallbackSummary: "A test model",
            createdAt: 1710500000,
            metadataClient: client
        )

        #expect(model.id == "unknown-model-xyz")
        #expect(model.name == "Unknown Model")
        #expect(model.capabilities == [.text])
        #expect(model.isRecommended == false)
        #expect(model.sortRank == nil)
        #expect(model.canonicalModelId == nil)
        #expect(model.reasoningProfile == nil)
        #expect(model.summary == "A test model")
        #expect(model.createdAt == 1710500000)
        #expect(model.priceTier == "")
        #expect(model.isDefault == false)
    }

    @Test("Build With Alias")
    func buildWithAlias() async throws {
        let client = try await makeLoadedClient()

        let model = await CatalogModelBuilder.buildCatalogModel(
            providerKind: .openAI,
            runtimeModelId: "gpt-4o-2024-08-06",
            fallbackName: "gpt-4o-2024-08-06",
            metadataClient: client
        )

        #expect(model.id == "gpt-4o-2024-08-06")
        #expect(model.name == "GPT-4o")
        #expect(model.canonicalModelId == "gpt-4o")
    }

    @Test("Build With Hyphenated Snapshot Alias")
    func buildWithHyphenatedSnapshotAlias() async throws {
        let client = try await makeLoadedClient()

        let model = await CatalogModelBuilder.buildCatalogModel(
            providerKind: .openAI,
            runtimeModelId: "gpt-5.4-nano-2026-03-01",
            fallbackName: "gpt-5.4-nano-2026-03-01",
            metadataClient: client
        )

        #expect(model.id == "gpt-5.4-nano-2026-03-01")
        #expect(model.name == "GPT-5.4 nano")
        #expect(model.canonicalModelId == "gpt-5.4-nano")
        #expect(abs((model.promptPrice ?? 0) - 0.0000002) < 0.000000000001)
        #expect(model.completionPrice == 0.00000125)
        #expect(!model.priceTier.isEmpty)
    }

    @Test("Build With Completion Only Pricing")
    func buildWithCompletionOnlyPricing() async throws {
        let client = MetadataClient()
        try await client.loadForTesting(json: """
        {
          "version": 1,
          "updatedAt": "2026-03-28T00:00:00Z",
          "providers": {
            "openAI": {
              "displayName": "OpenAI",
              "defaultModelId": "completion-only-model",
              "resolveMap": {
                "completion-only-model": "completion-only-model"
              },
              "models": {
                "completion-only-model": {
                  "canonicalModelId": "completion-only-model",
                  "displayName": "Completion Only Model",
                  "pricing": {
                    "promptPerMToken": 0,
                    "completionPerMToken": 1.25
                  },
                  "capabilities": ["text"],
                  "profiles": {}
                }
              }
            }
          }
        }
        """)

        let model = await CatalogModelBuilder.buildCatalogModel(
            providerKind: .openAI,
            runtimeModelId: "completion-only-model",
            fallbackName: "completion-only-model",
            metadataClient: client
        )

        #expect(model.promptPrice == 0)
        #expect(model.completionPrice == 0.00000125)
        #expect(model.priceTier == "$1.25/M")
    }

    @Test("Build With Explicit Free Pricing")
    func buildWithExplicitFreePricing() async throws {
        let client = MetadataClient()
        try await client.loadForTesting(json: """
        {
          "version": 1,
          "updatedAt": "2026-04-12T00:00:00Z",
          "providers": {
            "openRouter": {
              "displayName": "OpenRouter",
              "defaultModelId": "meta-llama/llama-3.3-8b-instruct:free",
              "resolveMap": {
                "meta-llama/llama-3.3-8b-instruct:free": "meta-llama/llama-3.3-8b-instruct:free"
              },
              "models": {
                "meta-llama/llama-3.3-8b-instruct:free": {
                  "canonicalModelId": "meta-llama/llama-3.3-8b-instruct:free",
                  "displayName": "Llama 3.3 8B Instruct",
                  "pricingStatus": "free",
                  "pricing": {
                    "promptPerMToken": 0,
                    "completionPerMToken": 0
                  },
                  "capabilities": ["text"],
                  "profiles": {}
                }
              }
            }
          }
        }
        """)

        let model = await CatalogModelBuilder.buildCatalogModel(
            providerKind: .openRouter,
            runtimeModelId: "meta-llama/llama-3.3-8b-instruct:free",
            fallbackName: "meta-llama/llama-3.3-8b-instruct:free",
            metadataClient: client
        )

        #expect(model.priceTier == L10n.tr("Free"))
        #expect(model.promptPrice == 0)
        #expect(model.completionPrice == 0)
    }

    @Test("Build With Non Token Pricing")
    func buildWithNonTokenPricing() async throws {
        let client = MetadataClient()
        try await client.loadForTesting(json: """
        {
          "version": 1,
          "updatedAt": "2026-04-20T10:00:00Z",
          "providers": {
            "openAI": {
              "displayName": "OpenAI",
              "defaultModelId": "gpt-image-1",
              "resolveMap": {
                "gpt-image-1": "gpt-image-1"
              },
              "models": {
                "gpt-image-1": {
                  "canonicalModelId": "gpt-image-1",
                  "displayName": "GPT Image 1",
                  "billingSku": "gpt-image-1/payg",
                  "pricingUnit": "per_image",
                  "sourceSummary": {
                    "sourceKind": "official_registry",
                    "sourceName": "OpenAI Pricing Registry",
                    "fetchedAt": "2026-04-20T10:00:00Z"
                  },
                  "pricingStatus": "priced",
                  "pricing": {
                    "promptPerMToken": null,
                    "completionPerMToken": null,
                    "costPerUnit": 0.04
                  },
                  "capabilities": ["text", "imageGeneration"],
                  "profiles": {}
                }
              }
            }
          }
        }
        """)

        let model = await CatalogModelBuilder.buildCatalogModel(
            providerKind: .openAI,
            runtimeModelId: "gpt-image-1",
            fallbackName: "gpt-image-1",
            metadataClient: client
        )

        #expect(model.priceTier == L10n.tr("Non-standard billing"))
        #expect(model.promptPrice == nil)
        #expect(model.completionPrice == nil)
        #expect(model.billingSku == "gpt-image-1/payg")
        #expect(model.pricingUnit == "per_image")
        #expect(model.sourceSummary?.sourceName == "OpenAI Pricing Registry")
        #expect(model.costPerUnit == 0.04)
    }

    @Test("Build With Unknown Pricing Status")
    func buildWithUnknownPricingStatus() async throws {
        let client = MetadataClient()
        try await client.loadForTesting(json: """
        {
          "version": 1,
          "updatedAt": "2026-04-20T10:00:00Z",
          "providers": {
            "openAI": {
              "displayName": "OpenAI",
              "defaultModelId": "gpt-unknown",
              "resolveMap": {
                "gpt-unknown": "gpt-unknown"
              },
              "models": {
                "gpt-unknown": {
                  "canonicalModelId": "gpt-unknown",
                  "displayName": "GPT Unknown",
                  "pricingStatus": "unknown",
                  "pricing": null,
                  "capabilities": ["text"],
                  "profiles": {}
                }
              }
            }
          }
        }
        """)

        let model = await CatalogModelBuilder.buildCatalogModel(
            providerKind: .openAI,
            runtimeModelId: "gpt-unknown",
            fallbackName: "gpt-unknown",
            metadataClient: client
        )

        #expect(model.priceTier == L10n.tr("Price unknown"))
        #expect(model.promptPrice == nil)
        #expect(model.completionPrice == nil)
    }

    @Test("Fallback Context Length Summary")
    func fallbackContextLengthSummary() async throws {
        let client = MetadataClient()

        let model = await CatalogModelBuilder.buildCatalogModel(
            providerKind: .groq,
            runtimeModelId: "test-model",
            fallbackName: "Test",
            fallbackContextLength: 128000,
            metadataClient: client
        )

        #expect(model.summary == "128K")
    }


    @Test("Build Propagates Tool Call")
    func buildPropagatesToolCall() async throws {
        let client = try await makeLoadedClient()

        let supported = await CatalogModelBuilder.buildCatalogModel(
            providerKind: .openAI,
            runtimeModelId: "gpt-4o",
            fallbackName: "gpt-4o",
            metadataClient: client
        )
        #expect(supported.toolCall == true)

        let unspecified = await CatalogModelBuilder.buildCatalogModel(
            providerKind: .openAI,
            runtimeModelId: "gpt-5.4-nano",
            fallbackName: "gpt-5.4-nano",
            metadataClient: client
        )
        #expect(unspecified.toolCall == nil)
    }

    @Test("Enrich Propagates Tool Call")
    func enrichPropagatesToolCall() async throws {
        let client = try await makeLoadedClient()

        let stale = makeModel(id: "gpt-4o")
        #expect(stale.toolCall == nil)

        let enriched = CatalogModelBuilder.enrichStoredModel(stale, providerKind: .openAI, metadataClient: client)
        #expect(enriched.toolCall == true)
    }


    @Test("Build Propagates Library Agentic")
    func buildPropagatesLibraryAgentic() async throws {
        let client = try await makeLoadedClient()

        let declared = await CatalogModelBuilder.buildCatalogModel(
            providerKind: .openAI,
            runtimeModelId: "gpt-4o",
            fallbackName: "gpt-4o",
            metadataClient: client
        )
        #expect(declared.libraryAgentic == true)

        let unspecified = await CatalogModelBuilder.buildCatalogModel(
            providerKind: .openAI,
            runtimeModelId: "gpt-5.4-nano",
            fallbackName: "gpt-5.4-nano",
            metadataClient: client
        )
        #expect(unspecified.libraryAgentic == nil)
    }

    @Test("Enrich Propagates Library Agentic")
    func enrichPropagatesLibraryAgentic() async throws {
        let client = try await makeLoadedClient()

        let stale = makeModel(id: "gpt-4o")
        #expect(stale.libraryAgentic == nil)

        let enriched = CatalogModelBuilder.enrichStoredModel(stale, providerKind: .openAI, metadataClient: client)
        #expect(enriched.libraryAgentic == true)
    }

    @Test("Enrich Respects Capability Contract Version")
    func enrichRespectsCapabilityContractVersion() async throws {
        var stale = makeModel(id: "tri-state-model")
        stale.toolCall = true
        stale.libraryAgentic = true

        let v2 = try await makeCapabilityClient(version: 2, explicitNulls: true)
        let cleared = CatalogModelBuilder.enrichStoredModel(
            stale,
            providerKind: .openAI,
            metadataClient: v2
        )
        #expect(cleared.toolCall == nil)
        #expect(cleared.libraryAgentic == nil)

        let v1 = try await makeCapabilityClient(version: 1, explicitNulls: false)
        let compatible = CatalogModelBuilder.enrichStoredModel(
            stale,
            providerKind: .openAI,
            metadataClient: v1
        )
        #expect(compatible.toolCall == true)
        #expect(compatible.libraryAgentic == true)

        let unversioned = try await makeCapabilityClient(version: nil, explicitNulls: false)
        let legacyCompatible = CatalogModelBuilder.enrichStoredModel(
            stale,
            providerKind: .openAI,
            metadataClient: unversioned
        )
        #expect(legacyCompatible.toolCall == true)
        #expect(legacyCompatible.libraryAgentic == true)

        var missing = makeModel(id: "catalog-miss")
        missing.toolCall = true
        missing.libraryAgentic = true
        let miss = CatalogModelBuilder.enrichStoredModel(
            missing,
            providerKind: .openAI,
            metadataClient: v2
        )
        #expect(miss.toolCall == true)
        #expect(miss.libraryAgentic == true)
    }

    // MARK: - enrichStoredModel

    @Test("Enrich Updates Capabilities And Pricing")
    func enrichUpdatesCapabilitiesAndPricing() async throws {
        let client = try await makeLoadedClient()

        let stale = makeModel(id: "gpt-4o")
        let enriched = CatalogModelBuilder.enrichStoredModel(stale, providerKind: .openAI, metadataClient: client)

        #expect(enriched.capabilities.contains(.image))
        #expect(enriched.capabilities.contains(.file))
        #expect(enriched.capabilities.contains(.reasoning))
        #expect(enriched.name == "GPT-4o")
        #expect(enriched.canonicalModelId == "gpt-4o")
        #expect(enriched.promptPrice == 0.0000025)
        #expect(enriched.completionPrice == 0.00001)
        #expect(!enriched.priceTier.isEmpty)
        #expect(enriched.reasoningModeAvailable == true)
        #expect(enriched.reasoningProfile == "oai_responses")
        #expect(enriched.sortRank == 130)
        #expect(enriched.groupKey == "gpt-4o")
        #expect(enriched.groupName == "GPT-4o")
        #expect(enriched.isRecommended == true)
    }

    @Test("Enrich Preserves Original When No Metadata")
    func enrichPreservesOriginalWhenNoMetadata() async throws {
        let client = try await makeLoadedClient()

        let original = AIModel(
            id: "unknown-model-xyz",
            name: "My Custom Model",
            capabilities: [.text, .image],
            reasoningModeAvailable: false,
            isAvailable: true,
            isDefault: true,
            priceTier: "$5/M",
            summary: "Custom summary",
            promptPrice: 0.00001
        )
        let enriched = CatalogModelBuilder.enrichStoredModel(original, providerKind: .openAI, metadataClient: client)

        #expect(enriched.name == "My Custom Model")
        #expect(enriched.capabilities == [.text, .image])
        #expect(enriched.priceTier == "$5/M")
        #expect(enriched.promptPrice == 0.00001)
        #expect(enriched.isDefault == true)
    }

    @Test("Enrich Preserves User Settings")
    func enrichPreservesUserSettings() async throws {
        let client = try await makeLoadedClient()

        var stale = makeModel(id: "gpt-4o")
        stale.isDefault = true
        stale.isAvailable = false

        let enriched = CatalogModelBuilder.enrichStoredModel(stale, providerKind: .openAI, metadataClient: client)

        #expect(enriched.isDefault == true)
        #expect(enriched.isAvailable == false)
        #expect(enriched.capabilities.contains(.file))
    }

    @Test("Enrich Clears Stale Price When Unknown")
    func enrichClearsStalePriceWhenUnknown() async throws {
        let client = MetadataClient()
        try await client.loadForTesting(json: """
        {
          "version": 1,
          "updatedAt": "2026-04-12T00:00:00Z",
          "providers": {
            "openAI": {
              "displayName": "OpenAI",
              "defaultModelId": "gpt-3.5-turbo-0125",
              "resolveMap": {
                "gpt-3.5-turbo-0125": "gpt-3.5-turbo-0125"
              },
              "models": {
                "gpt-3.5-turbo-0125": {
                  "canonicalModelId": "gpt-3.5-turbo-0125",
                  "displayName": "GPT-3.5 Turbo",
                  "pricingStatus": "unknown",
                  "pricing": {
                    "promptPerMToken": 0,
                    "completionPerMToken": 0
                  },
                  "capabilities": ["text"],
                  "profiles": {}
                }
              }
            }
          }
        }
        """)

        let stale = AIModel(
            id: "gpt-3.5-turbo-0125",
            name: "GPT-3.5 Turbo",
            capabilities: [.text],
            reasoningModeAvailable: false,
            isAvailable: true,
            isDefault: false,
            priceTier: L10n.tr("Free"),
            promptPrice: 0,
            completionPrice: 0
        )
        let enriched = CatalogModelBuilder.enrichStoredModel(stale, providerKind: .openAI, metadataClient: client)

        #expect(enriched.priceTier == L10n.tr("Price unknown"))
        #expect(enriched.promptPrice == nil)
        #expect(enriched.completionPrice == nil)
    }

    @Test("Enrich Clears Stale Group Metadata When UIHints Disappear")
    func enrichClearsStaleGroupMetadataWhenUIHintsDisappear() async throws {
        let client = MetadataClient()
        try await client.loadForTesting(json: """
        {
          "version": 1,
          "updatedAt": "2026-04-18T00:00:00Z",
          "providers": {
            "openRouter": {
              "defaultModelId": "openai/gpt-4o",
              "resolveMap": {
                "openai/gpt-4o": "openai/gpt-4o"
              },
              "models": {
                "openai/gpt-4o": {
                  "canonicalModelId": "openai/gpt-4o",
                  "displayName": "GPT-4o",
                  "pricingStatus": "unknown",
                  "capabilities": ["text"],
                  "profiles": {}
                }
              }
            }
          }
        }
        """)

        let stale = AIModel(
            id: "openai/gpt-4o",
            name: "GPT-4o",
            capabilities: [.text],
            reasoningModeAvailable: false,
            isAvailable: true,
            isDefault: false,
            priceTier: "",
            groupKey: "openai",
            groupName: "OpenAI",
            isRecommended: true,
            sortRank: 120,
            badgeOrder: [.reasoning]
        )

        let enriched = CatalogModelBuilder.enrichStoredModel(stale, providerKind: .openRouter, metadataClient: client)

        #expect(enriched.groupKey == nil)
        #expect(enriched.groupName == nil)
        #expect(enriched.sortRank == nil)
        #expect(enriched.badgeOrder == nil)
        #expect(enriched.isRecommended == false)
    }

    @Test("Enrich Clears Stale Profiles When Metadata Removes Them")
    func enrichClearsStaleProfilesWhenMetadataRemovesThem() async throws {
        let client = MetadataClient()
        try await client.loadForTesting(json: """
        {
          "version": 1,
          "updatedAt": "2026-07-04T00:00:00Z",
          "providers": {
            "openAI": {
              "defaultModelId": "gpt-4o",
              "resolveMap": {
                "gpt-4o": "gpt-4o"
              },
              "models": {
                "gpt-4o": {
                  "canonicalModelId": "gpt-4o",
                  "displayName": "GPT-4o",
                  "pricingStatus": "unknown",
                  "capabilities": ["text"],
                  "profiles": {}
                }
              }
            }
          }
        }
        """)

        let stale = AIModel(
            id: "gpt-4o",
            name: "GPT-4o",
            capabilities: [.text, .reasoning],
            reasoningModeAvailable: true,
            isAvailable: true,
            isDefault: false,
            priceTier: "",
            reasoningProfile: "old_reasoning",
            webSearchProfile: "old_web",
            imageGenProfile: "old_image"
        )

        let enriched = CatalogModelBuilder.enrichStoredModel(stale, providerKind: .openAI, metadataClient: client)

        #expect(enriched.reasoningModeAvailable == false)
        #expect(enriched.reasoningProfile == nil)
        #expect(enriched.webSearchProfile == nil)
        #expect(enriched.imageGenProfile == nil)
    }

    @Test("Enrich Provider Updates Models")
    func enrichProviderUpdatesModels() async throws {
        let client = try await makeLoadedClient()

        let staleModel = makeModel(id: "gpt-4o")
        let provider = Provider(
            id: UUID(),
            kind: .openAI,
            status: .connected,
            models: [staleModel],
            catalogModels: [],
            lastCheckedAt: nil,
            apiKey: "test",
            apiKeyPreview: "te***"
        )

        let enriched = CatalogModelBuilder.enrichProvider(provider, metadataClient: client)

        #expect(enriched.models.first?.capabilities.contains(ModelCapability.file) == true)
        #expect(enriched.models.first?.name == "GPT-4o")
    }

    @Test("Enrich Provider Skips Relay")
    func enrichProviderSkipsRelay() async throws {
        let client = try await makeLoadedClient()

        let model = makeModel(id: "custom-model")
        let provider = Provider(
            id: UUID(),
            kind: .relay,
            status: .connected,
            models: [model],
            catalogModels: [],
            lastCheckedAt: nil,
            apiKey: "test",
            apiKeyPreview: "te***"
        )

        let enriched = CatalogModelBuilder.enrichProvider(provider, metadataClient: client)

        #expect(enriched.models.first?.capabilities == [ModelCapability.text])
    }

    @Test("Enrich Manual Prefix Model")
    func enrichManualPrefixModel() async throws {
        let client = try await makeLoadedClient()

        let manual = AIModel(
            id: "openAI-manual-gpt-4o",
            name: "gpt-4o",
            capabilities: [.text],
            reasoningModeAvailable: false,
            isAvailable: true,
            isDefault: false,
            priceTier: ""
        )
        let enriched = CatalogModelBuilder.enrichStoredModel(manual, providerKind: .openAI, metadataClient: client)

        #expect(enriched.capabilities.contains(.image))
        #expect(enriched.capabilities.contains(.file))
        #expect(enriched.groupKey == "gpt-4o")
        #expect(enriched.name == "GPT-4o")
        #expect(enriched.canonicalModelId == "gpt-4o")
    }

    // MARK: - compactContextText

    @Test("Compact Context Text Formatting")
    func compactContextTextFormatting() {
        #expect(CatalogModelBuilder.compactContextText(nil) == nil)
        #expect(CatalogModelBuilder.compactContextText(0) == nil)
        #expect(CatalogModelBuilder.compactContextText(500) == "500")
        #expect(CatalogModelBuilder.compactContextText(8000) == "8K")
        #expect(CatalogModelBuilder.compactContextText(128000) == "128K")
        #expect(CatalogModelBuilder.compactContextText(1000000) == "1M")
        #expect(CatalogModelBuilder.compactContextText(2000000) == "2M")
    }

    // MARK: - Helpers

    private func makeModel(
        id: String,
        isAvailable: Bool = true,
        isRecommended: Bool = false,
        sortRank: Int? = nil,
        createdAt: Double? = nil
    ) -> AIModel {
        AIModel(
            id: id,
            name: id,
            capabilities: [.text],
            reasoningModeAvailable: false,
            isAvailable: isAvailable,
            isDefault: false,
            priceTier: "",
            createdAt: createdAt,
            isRecommended: isRecommended,
            sortRank: sortRank
        )
    }

    private func makeLoadedClient() async throws -> MetadataClient {
        let client = MetadataClient()
        try await loadTestPayload(into: client)
        return client
    }

    private func makeCapabilityClient(version: Int?, explicitNulls: Bool) async throws -> MetadataClient {
        let fields = explicitNulls
            ? "\"toolCall\": null, \"libraryAgentic\": null"
            : ""
        let contract = version.map { "\"capabilityContractVersion\": \($0)," } ?? ""
        let client = MetadataClient()
        try await client.loadForTesting(json: """
        {
          "version": 1,
          \(contract)
          "providers": {
            "openAI": {
              "resolveMap": { "tri-state-model": "tri-state-model" },
              "models": {
                "tri-state-model": { \(fields) }
              }
            }
          }
        }
        """)
        return client
    }

    private func loadTestPayload(into client: MetadataClient) async throws {
        let json = """
        {
          "version": 1,
          "updatedAt": "2026-03-25T00:00:00Z",
          "providers": {
            "openAI": {
              "displayName": "OpenAI",
              "defaultModelId": "gpt-4o",
              "resolveMap": {
                "gpt-4o": "gpt-4o",
                "gpt-4o-2024-08-06": "gpt-4o",
                "gpt-5.4-nano": "gpt-5.4-nano"
              },
              "models": {
                "gpt-4o": {
                  "canonicalModelId": "gpt-4o",
                  "displayName": "GPT-4o",
                  "contextLength": 128000,
                  "pricing": {
                    "promptPerMToken": 2.5,
                    "completionPerMToken": 10.0,
                    "cachedInputPerMToken": 1.25
                  },
                  "capabilities": ["text", "image", "file", "reasoning"],
                  "toolCall": true,
                  "libraryAgentic": true,
                  "profiles": {
                    "reasoning": "oai_responses",
                    "webSearch": null,
                    "imageGen": null
                  },
                  "uiHints": {
                    "groupKey": "gpt-4o",
                    "groupName": "GPT-4o",
                    "rank": 130,
                    "recommended": true,
                    "badgeOrder": ["reasoning", "image", "file"]
                  }
                },
                "gpt-5.4-nano": {
                  "canonicalModelId": "gpt-5.4-nano",
                  "displayName": "GPT-5.4 nano",
                  "contextLength": 400000,
                  "pricing": {
                    "promptPerMToken": 0.2,
                    "completionPerMToken": 1.25,
                    "cachedInputPerMToken": 0.02
                  },
                  "capabilities": ["text", "image", "reasoning"],
                  "profiles": {
                    "reasoning": "oai_responses",
                    "webSearch": null,
                    "imageGen": null
                  },
                  "uiHints": {
                    "groupKey": "gpt-5",
                    "groupName": "GPT-5",
                    "rank": 166,
                    "recommended": false,
                    "badgeOrder": ["reasoning", "image"]
                  }
                }
              }
            }
          }
        }
        """

        try await client.loadForTesting(json: json)
    }
}

// MARK: - SiliconFlow Vendor Name

@Suite("SiliconFlowVendorName")
struct SiliconFlowVendorNameTests {

    @Test("Zai Aliases")
    func zaiAliases() {
        let aliases = ["zai", "z-ai", "zai-org", "thudm"]
        for alias in aliases {
            #expect(SiliconFlowVendorName.displayName(for: alias) == "Z.ai / GLM", "alias \(alias) should map to Z.ai / GLM")
        }
    }

    @Test("Stepfun Aliases")
    func stepfunAliases() {
        #expect(SiliconFlowVendorName.displayName(for: "stepfun") == "StepFun")
        #expect(SiliconFlowVendorName.displayName(for: "stepfun-ai") == "StepFun")
    }
}
