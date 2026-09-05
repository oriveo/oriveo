import Foundation
import Testing
@testable import Oriveo

@Suite("Relay Official Catalog Resolver Tests", .serialized)
struct RelayOfficialCatalogResolverTests {

    private func loadFixtureJSON() throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = testFileURL
            .deletingLastPathComponent() // OriveoTests/
            .deletingLastPathComponent() // Oriveo/
            .deletingLastPathComponent() // ios/
            .deletingLastPathComponent() // repository root
        let fixtureURL = repoRoot.appendingPathComponent(
            "shared/test-fixtures/relay/metadata-fixture.json"
        )
        return try String(contentsOf: fixtureURL, encoding: .utf8)
    }

    private func makeRelayProvider(
        transport: RelayTransport = .openaiResponses,
        catalogModels: [AIModel] = []
    ) -> Provider {
        Provider(
            id: UUID(),
            kind: .relay,
            status: .connected,
            models: [],
            catalogModels: catalogModels,
            apiKey: "",
            apiKeyPreview: "",
            relayRequested: RelayRequestedConfig(transport: transport)
        )
    }

    private func makeLocalModel(id: String) -> AIModel {
        AIModel(
            id: id,
            name: id,
            capabilities: [.text],
            reasoningModeAvailable: false,
            isAvailable: true,
            isDefault: false,
            priceTier: ""
        )
    }

    @Test("Enriches Known Open AIModel")
    func enrichesKnownOpenAIModel() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: loadFixtureJSON())

        let provider = makeRelayProvider(
            transport: .openaiResponses,
            catalogModels: [makeLocalModel(id: "gpt-5.4")]
        )
        let runtime = MetadataClient.shared.syncRelayRuntimeConfig()
        let enriched = RelayOfficialCatalogResolver.enrich(
            localModel: provider.catalogModels[0],
            provider: provider,
            runtimeConfig: runtime
        )

        #expect(enriched.canonicalModelId == "gpt-5.4")
        #expect(enriched.name == "GPT-5.4")
        #expect(enriched.capabilities.contains(.text))
        #expect(enriched.capabilities.contains(.image))
        #expect(enriched.capabilities.contains(.file))
        #expect(enriched.capabilities.contains(.web))
        #expect(enriched.capabilities.contains(.reasoning))
        #expect(enriched.reasoningProfile == "openaiReasoning")
        #expect(enriched.webSearchProfile == "openaiWebSearch")
    }

    @Test("Intersects Envelope For Chat Completions")
    func intersectsEnvelopeForChatCompletions() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: loadFixtureJSON())

        let provider = makeRelayProvider(
            transport: .openaiChatCompletions,
            catalogModels: [makeLocalModel(id: "gpt-5.4")]
        )
        let runtime = MetadataClient.shared.syncRelayRuntimeConfig()
        let enriched = RelayOfficialCatalogResolver.enrich(
            localModel: provider.catalogModels[0],
            provider: provider,
            runtimeConfig: runtime
        )

        #expect(!enriched.capabilities.contains(.web))
        #expect(enriched.webSearchProfile == nil)

        #expect(enriched.capabilities.contains(.file))

        #expect(enriched.capabilities.contains(.reasoning))
        #expect(enriched.reasoningProfile == "openaiReasoning")
    }

    @Test("Unknown Model Falls Back To Local")
    func unknownModelFallsBackToLocal() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: loadFixtureJSON())

        let local = makeLocalModel(id: "my-internal-model")
        let provider = makeRelayProvider(
            transport: .openaiResponses,
            catalogModels: [local]
        )
        let runtime = MetadataClient.shared.syncRelayRuntimeConfig()
        let enriched = RelayOfficialCatalogResolver.enrich(
            localModel: local,
            provider: provider,
            runtimeConfig: runtime
        )

        #expect(enriched.id == local.id)
        #expect(enriched.name == local.name)
        #expect(enriched.capabilities == local.capabilities)
        #expect(enriched.canonicalModelId == nil)
        #expect(enriched.webSearchProfile == nil)
    }

    @Test("Enriches Entire Catalog Preserving Order")
    func enrichesEntireCatalogPreservingOrder() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: loadFixtureJSON())

        let models = [
            makeLocalModel(id: "my-custom-model"),
            makeLocalModel(id: "gpt-5.4"),
            makeLocalModel(id: "claude-sonnet-4.5"),
        ]
        let provider = makeRelayProvider(
            transport: .openaiResponses,
            catalogModels: models
        )
        let runtime = MetadataClient.shared.syncRelayRuntimeConfig()
        let enriched = RelayOfficialCatalogResolver.enrichCatalog(
            provider: provider,
            runtimeConfig: runtime
        )

        #expect(enriched.count == 3)
        #expect(enriched[0].id == "my-custom-model")
        #expect(enriched[0].canonicalModelId == nil)

        #expect(enriched[1].id == "gpt-5.4")
        #expect(enriched[1].canonicalModelId == "gpt-5.4")
        #expect(enriched[1].name == "GPT-5.4")

        #expect(enriched[2].id == "claude-sonnet-4.5")
        #expect(enriched[2].canonicalModelId == "claude-sonnet-4.5")
        #expect(enriched[2].name == "Claude Sonnet 4.5")
    }

    @Test("Runtime Support Attachment Envelope")
    func runtimeSupportAttachmentEnvelope() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: loadFixtureJSON())

        let provider = makeRelayProvider(transport: .openaiChatCompletions)
        let runtime = MetadataClient.shared.syncRelayRuntimeConfig()
        let support = RelayRuntimeSupport.attachmentSupport(for: provider, runtimeConfig: runtime)

        #expect(support?.image == true)
        #expect(support?.nativeFile == false)
        #expect(support?.textFileInline == true)
    }

    @Test("Runtime Support Auto Transport Resolves To Chat Completions")
    func runtimeSupportAutoTransportResolvesToChatCompletions() async throws {
        let provider = makeRelayProvider(transport: .auto)
        let runtime = MetadataClient.RelayRuntimeConfig.fallback
        let support = RelayRuntimeSupport.attachmentSupport(for: provider, runtimeConfig: runtime)
        #expect(support?.image == true)
        #expect(support?.nativeFile == false)
        #expect(support?.textFileInline == true)
        #expect(RelayRuntimeSupport.supportsWebSearch(for: provider, runtimeConfig: runtime) == false)
    }

    @Test("Manual Image Gen Capability Preserved When Catalog Misses")
    func manualImageGenCapabilityPreservedWhenCatalogMisses() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: loadFixtureJSON())

        let manual = AIModel(
            id: "relay-manual-gpt-image-2",
            name: "gpt-image-2",
            capabilities: [.text, .imageGen],
            reasoningModeAvailable: false,
            isAvailable: true,
            isDefault: true,
            priceTier: "",
            imageGenProfile: "default"
        )
        let provider = makeRelayProvider(
            transport: .openaiChatCompletions,
            catalogModels: [manual]
        )
        let runtime = MetadataClient.shared.syncRelayRuntimeConfig()
        let enriched = RelayOfficialCatalogResolver.enrich(
            localModel: manual,
            provider: provider,
            runtimeConfig: runtime
        )

        #expect(enriched.capabilities.contains(.imageGen))
        #expect(enriched.capabilities.contains(.text))
    }

    @Test("Manual Image Gen Capability Preserved When Envelope Blocks")
    func manualImageGenCapabilityPreservedWhenEnvelopeBlocks() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: loadFixtureJSON())

        let manual = AIModel(
            id: "gpt-5.4",
            name: "gpt-5.4",
            capabilities: [.text, .imageGen],
            reasoningModeAvailable: false,
            isAvailable: true,
            isDefault: true,
            priceTier: ""
        )
        let provider = makeRelayProvider(
            transport: .openaiChatCompletions,
            catalogModels: [manual]
        )
        let runtime = MetadataClient.shared.syncRelayRuntimeConfig()
        let enriched = RelayOfficialCatalogResolver.enrich(
            localModel: manual,
            provider: provider,
            runtimeConfig: runtime
        )

        #expect(enriched.capabilities.contains(.imageGen))
    }

    @Test("Clears Stale Profiles When Official Metadata Removes Them")
    func clearsStaleProfilesWhenOfficialMetadataRemovesThem() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "providers": {
            "openAI": {
              "resolveMap": {
                "gpt-authority": "gpt-authority"
              },
              "models": {
                "gpt-authority": {
                  "canonicalModelId": "gpt-authority",
                  "displayName": "GPT Authority",
                  "capabilities": ["text", "reasoning", "web", "imageGeneration"],
                  "profiles": {}
                }
              }
            }
          }
        }
        """)

        let local = AIModel(
            id: "gpt-authority",
            name: "gpt-authority",
            capabilities: [.text, .reasoning, .web, .imageGen],
            reasoningModeAvailable: true,
            isAvailable: true,
            isDefault: false,
            priceTier: "",
            reasoningProfile: "old_reasoning",
            webSearchProfile: "old_web",
            imageGenProfile: "old_image"
        )
        let provider = makeRelayProvider(
            transport: .openaiResponses,
            catalogModels: [local]
        )
        let runtime = MetadataClient.shared.syncRelayRuntimeConfig()

        let enriched = RelayOfficialCatalogResolver.enrich(
            localModel: local,
            provider: provider,
            runtimeConfig: runtime
        )

        #expect(enriched.capabilities.contains(.reasoning))
        #expect(enriched.capabilities.contains(.web))
        #expect(enriched.capabilities.contains(.imageGen))
        #expect(enriched.reasoningModeAvailable == false)
        #expect(enriched.reasoningProfile == nil)
        #expect(enriched.webSearchProfile == nil)
        #expect(enriched.imageGenProfile == nil)
    }

    @Test("RelayRuntimeSupport.supportsWebSearch: openai_responses=true / anthropic_messages=false")
    func runtimeSupportWebSearchByTransport() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: loadFixtureJSON())

        let runtime = MetadataClient.shared.syncRelayRuntimeConfig()
        #expect(
            RelayRuntimeSupport.supportsWebSearch(
                for: makeRelayProvider(transport: .openaiResponses),
                runtimeConfig: runtime
            ) == true
        )
        #expect(
            RelayRuntimeSupport.supportsWebSearch(
                for: makeRelayProvider(transport: .anthropicMessages),
                runtimeConfig: runtime
            ) == false
        )
        #expect(
            RelayRuntimeSupport.supportsWebSearch(
                for: makeRelayProvider(transport: .geminiGenerateContent),
                runtimeConfig: runtime
            ) == true
        )
    }


    @Test("Manual Model Skips Catalog Enrichment")
    func manualModelSkipsCatalogEnrichment() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: loadFixtureJSON())

        let runtime = MetadataClient.shared.syncRelayRuntimeConfig()
        let manualModel = AIModel(
            id: "gpt-5.4",
            name: "gpt-5.4 (manual)",
            capabilities: [.text, .image],
            reasoningModeAvailable: false,
            isAvailable: true,
            isDefault: false,
            priceTier: "",
            summary: "Manual model",
            isManual: true
        )
        let provider = makeRelayProvider(
            transport: .openaiResponses,
            catalogModels: [manualModel]
        )

        let enriched = RelayOfficialCatalogResolver.enrich(
            localModel: manualModel,
            provider: provider,
            runtimeConfig: runtime
        )

        #expect(enriched.id == "gpt-5.4")
        #expect(enriched.name == "gpt-5.4 (manual)")
        #expect(enriched.capabilities == [.text, .image])
        #expect(enriched.summary == "Manual model")
    }

    @Test("Manual Official Model Keeps User Fields And Merges Pricing")
    func manualOfficialModelKeepsUserFieldsAndMergesPricing() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: loadFixtureJSON())

        let runtime = MetadataClient.shared.syncRelayRuntimeConfig()
        let manualModel = AIModel(
            id: "gpt-5.4",
            name: "gpt-5.4 (manual)",
            capabilities: [.text, .image],
            reasoningModeAvailable: false,
            isAvailable: true,
            isDefault: true,
            priceTier: "",
            summary: "Manual model",
            isManual: true
        )
        let provider = makeRelayProvider(
            transport: .openaiResponses,
            catalogModels: [manualModel]
        )

        let enriched = RelayOfficialCatalogResolver.enrich(
            localModel: manualModel,
            provider: provider,
            runtimeConfig: runtime
        )

        #expect(enriched.id == "gpt-5.4")
        #expect(enriched.name == "gpt-5.4 (manual)")
        #expect(enriched.capabilities == [.text, .image])
        #expect(enriched.summary == "Manual model")
        #expect(enriched.canonicalModelId == "gpt-5.4")
        #expect(enriched.promptPrice == 0.000002)
        #expect(enriched.completionPrice == 0.000008)
        #expect(!enriched.priceTier.isEmpty)
    }

    @Test("Manual Model With Custom Name Skips Enrichment")
    func manualModelWithCustomNameSkipsEnrichment() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: loadFixtureJSON())

        let runtime = MetadataClient.shared.syncRelayRuntimeConfig()

        let manualModel = AIModel(
            id: "my-finetuned-llm-v2",
            name: "My Finetuned LLM v2",
            capabilities: [.text, .reasoning],
            reasoningModeAvailable: true,
            isAvailable: true,
            isDefault: true,
            priceTier: "",
            summary: "Manual model",
            isManual: true
        )
        let provider = makeRelayProvider(
            transport: .openaiResponses,
            catalogModels: [manualModel]
        )

        let enriched = RelayOfficialCatalogResolver.enrich(
            localModel: manualModel,
            provider: provider,
            runtimeConfig: runtime
        )

        #expect(enriched.id == "my-finetuned-llm-v2")
        #expect(enriched.name == "My Finetuned LLM v2")
        #expect(enriched.capabilities == [.text, .reasoning])
        #expect(enriched.isDefault == true)
    }

    @Test("Legacy Prefixed Manual Model Still Skips Catalog Enrichment")
    func legacyPrefixedManualModelStillSkipsCatalogEnrichment() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: loadFixtureJSON())

        let runtime = MetadataClient.shared.syncRelayRuntimeConfig()
        let legacyModel = AIModel(
            id: "relay-manual-gpt-5.4",
            name: "gpt-5.4 (manual legacy)",
            capabilities: [.text, .image],
            reasoningModeAvailable: false,
            isAvailable: true,
            isDefault: false,
            priceTier: "",
            summary: "Legacy manual model"
        )
        let provider = makeRelayProvider(
            transport: .openaiResponses,
            catalogModels: [legacyModel]
        )

        let enriched = RelayOfficialCatalogResolver.enrich(
            localModel: legacyModel,
            provider: provider,
            runtimeConfig: runtime
        )

        #expect(enriched.id == "relay-manual-gpt-5.4")
        #expect(enriched.name == "gpt-5.4 (manual legacy)")
        #expect(enriched.capabilities == [.text, .image])
        #expect(enriched.summary == "Legacy manual model")
    }

    @Test("A Non Manual Model Still Enriches")
    func phaseA_nonManualModelStillEnriches() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: loadFixtureJSON())

        let runtime = MetadataClient.shared.syncRelayRuntimeConfig()

        let catalogModel = makeLocalModel(id: "gpt-5.4")
        let provider = makeRelayProvider(
            transport: .openaiResponses,
            catalogModels: [catalogModel]
        )

        let enriched = RelayOfficialCatalogResolver.enrich(
            localModel: catalogModel,
            provider: provider,
            runtimeConfig: runtime
        )

        #expect(enriched.id == "gpt-5.4")
        #expect(enriched.capabilities.contains(.text))
    }
}
