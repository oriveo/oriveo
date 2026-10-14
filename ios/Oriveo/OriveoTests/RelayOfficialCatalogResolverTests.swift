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
        let support = RelayRuntimeSupport.attachmentSupport(for: provider, model: nil, runtimeConfig: runtime)

        #expect(support?.image == true)
        #expect(support?.nativeFile == false)
        #expect(support?.textFileInline == true)
    }

    @Test("Runtime Support Auto Transport Resolves To Chat Completions")
    func runtimeSupportAutoTransportResolvesToChatCompletions() async throws {
        let provider = makeRelayProvider(transport: .auto)
        let runtime = MetadataClient.RelayRuntimeConfig.fallback
        let support = RelayRuntimeSupport.attachmentSupport(for: provider, model: nil, runtimeConfig: runtime)
        #expect(support?.image == true)
        #expect(support?.nativeFile == false)
        #expect(support?.textFileInline == true)
        #expect(RelayRuntimeSupport.supportsWebSearch(for: provider, model: nil, runtimeConfig: runtime) == false)
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

    @Test("A manual exact match with no official profile is treated like a catalog model: stale local profiles are cleared")
    func manualExactMatchClearsStaleProfilesLikeCatalogModel() async throws {
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
            name: "gpt-authority (manual)",
            capabilities: [.text, .reasoning, .web, .imageGen],
            reasoningModeAvailable: true,
            isAvailable: true,
            isDefault: false,
            priceTier: "",
            reasoningProfile: "old_reasoning",
            webSearchProfile: "old_web",
            imageGenProfile: "old_image",
            isManual: true
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

        #expect(enriched.name == "gpt-authority (manual)")
        #expect(enriched.capabilities.contains(.reasoning))
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
                model: nil,
                runtimeConfig: runtime
            ) == true
        )
        #expect(
            RelayRuntimeSupport.supportsWebSearch(
                for: makeRelayProvider(transport: .anthropicMessages),
                model: nil,
                runtimeConfig: runtime
            ) == false
        )
        #expect(
            RelayRuntimeSupport.supportsWebSearch(
                for: makeRelayProvider(transport: .geminiGenerateContent),
                model: nil,
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
        // An exact match inherits capabilities as a union, the same way catalog models do; the user's own capabilities are kept.
        #expect(enriched.capabilities == [.text, .image, .file, .web, .reasoning])
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
        // A manual exact match inherits capabilities as a union (previously the user's [.text, .image] was kept as is).
        #expect(enriched.capabilities == [.text, .image, .file, .web, .reasoning])
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
        // A legacy-prefixed manual model also matches exactly on the prefix-stripped id and inherits capabilities as a union.
        #expect(enriched.capabilities == [.text, .image, .file, .web, .reasoning])
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

    // MARK: - Native file allowlist inheritance

    /// Models in the shared fixture carry no native-file fields; they are injected in memory for anthropic claude-sonnet-4.5,
    /// optionally overriding nativeFile on the anthropic_messages envelope. The fixture file itself is left untouched.
    private func loadFixtureJSONWithNativeFileWhitelist(
        anthropicMessagesNativeFile: Bool? = nil,
        pdfNativeDefault: Bool = false,
        withPricing: Bool = false
    ) throws -> String {
        let data = Data(try loadFixtureJSON().utf8)
        var root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var providers = try #require(root["providers"] as? [String: Any])
        var anthropic = try #require(providers["anthropic"] as? [String: Any])
        var models = try #require(anthropic["models"] as? [String: Any])
        var sonnet = try #require(models["claude-sonnet-4.5"] as? [String: Any])
        sonnet["nativeFileMimes"] = ["application/pdf"]
        sonnet["pdfNativeDefault"] = pdfNativeDefault
        sonnet["attachmentExtraction"] = ["maxLines": 1234]
        if withPricing {
            sonnet["pricing"] = ["promptPerMToken": 3.0, "completionPerMToken": 15.0]
            sonnet["pricingStatus"] = "priced"
        }
        models["claude-sonnet-4.5"] = sonnet
        anthropic["models"] = models
        providers["anthropic"] = anthropic
        root["providers"] = providers
        if let anthropicMessagesNativeFile {
            var runtime = try #require(root["relayRuntimeConfig"] as? [String: Any])
            var envelopes = try #require(runtime["transportEnvelopes"] as? [String: Any])
            var envelope = try #require(envelopes["anthropic_messages"] as? [String: Any])
            envelope["nativeFile"] = anthropicMessagesNativeFile
            envelopes["anthropic_messages"] = envelope
            runtime["transportEnvelopes"] = envelopes
            root["relayRuntimeConfig"] = runtime
        }
        let out = try JSONSerialization.data(withJSONObject: root)
        return String(decoding: out, as: UTF8.self)
    }

    private func enrichSonnet(
        transport: RelayTransport,
        id: String = "claude-sonnet-4.5",
        isManual: Bool = false
    ) -> AIModel {
        let local = AIModel(
            id: id,
            name: id,
            capabilities: [.text],
            reasoningModeAvailable: false,
            isAvailable: true,
            isDefault: false,
            priceTier: "",
            isManual: isManual
        )
        let provider = makeRelayProvider(transport: transport, catalogModels: [local])
        return RelayOfficialCatalogResolver.enrich(
            localModel: local,
            provider: provider,
            runtimeConfig: MetadataClient.shared.syncRelayRuntimeConfig()
        )
    }

    @Test("A same-provider match (anthropic_messages) inherits the three native-file fields")
    func inheritsNativeFileWhitelistOnTransportFirstMatch() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: loadFixtureJSONWithNativeFileWhitelist())

        let enriched = enrichSonnet(transport: .anthropicMessages)

        #expect(enriched.canonicalModelId == "claude-sonnet-4.5")
        #expect(enriched.nativeFileMimes == ["application/pdf"])
        #expect(enriched.pdfNativeDefault == false)
        #expect(enriched.attachmentExtraction?.maxLines == 1234)
    }

    @Test("An envelope with nativeFile=false inherits nothing and leaves the three fields empty")
    func dropsNativeFileWhitelistWhenEnvelopeDisablesNativeFile() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(
            json: loadFixtureJSONWithNativeFileWhitelist(anthropicMessagesNativeFile: false)
        )

        let enriched = enrichSonnet(transport: .anthropicMessages)

        #expect(enriched.canonicalModelId == "claude-sonnet-4.5")
        #expect(enriched.nativeFileMimes.isEmpty)
        #expect(enriched.pdfNativeDefault == false)
        #expect(enriched.attachmentExtraction == nil)
    }

    @Test("A cross-provider match (anthropic model over openai_responses) inherits nothing but still resolves the canonical id")
    func dropsNativeFileWhitelistOnCrossProviderMatch() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: loadFixtureJSONWithNativeFileWhitelist())

        let enriched = enrichSonnet(transport: .openaiResponses)

        #expect(enriched.canonicalModelId == "claude-sonnet-4.5")
        #expect(enriched.nativeFileMimes.isEmpty)
        #expect(enriched.pdfNativeDefault == false)
        #expect(enriched.attachmentExtraction == nil)
    }

    @Test("A manual model inherits on a same-provider match and stays empty without a match")
    func manualModelInheritsNativeFileWhitelistOnlyWhenMatched() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: loadFixtureJSONWithNativeFileWhitelist())

        let matched = enrichSonnet(transport: .anthropicMessages, isManual: true)
        #expect(matched.canonicalModelId == "claude-sonnet-4.5")
        #expect(matched.nativeFileMimes == ["application/pdf"])
        #expect(matched.pdfNativeDefault == false)
        #expect(matched.attachmentExtraction?.maxLines == 1234)

        let missed = enrichSonnet(transport: .anthropicMessages, id: "my-finetuned-llm-v2", isManual: true)
        #expect(missed.canonicalModelId == nil)
        #expect(missed.nativeFileMimes.isEmpty)
        #expect(missed.pdfNativeDefault == false)
        #expect(missed.attachmentExtraction == nil)
    }

    @Test("A manual model with a stale allowlist has it cleared on a cross-provider match")
    func manualModelStockWhitelistIsClearedOnCrossProviderMatch() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: loadFixtureJSONWithNativeFileWhitelist())

        var stock = AIModel(
            id: "claude-sonnet-4.5", name: "mine", capabilities: [.text],
            reasoningModeAvailable: false, isAvailable: true, isDefault: false, priceTier: "",
            isManual: true
        )
        stock.nativeFileMimes = ["application/pdf"]
        stock.pdfNativeDefault = true
        let provider = makeRelayProvider(transport: .openaiResponses, catalogModels: [stock])
        let enriched = RelayOfficialCatalogResolver.enrich(
            localModel: stock,
            provider: provider,
            runtimeConfig: MetadataClient.shared.syncRelayRuntimeConfig()
        )

        #expect(enriched.canonicalModelId == "claude-sonnet-4.5")
        #expect(enriched.name == "mine")
        #expect(enriched.nativeFileMimes.isEmpty)
        #expect(enriched.pdfNativeDefault == false)
    }

    @Test("RL2-PROBE-04 reachable_does_not_authorize_the_native_file_whitelist: a probed protocol does not inherit the whitelist; observed / user sources behave as in S0")
    func rl2Probe04ReachableDoesNotAuthorizeNativeFileWhitelist() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(
            json: loadFixtureJSONWithNativeFileWhitelist(pdfNativeDefault: true)
        )
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var fixtureURL: URL?
        while cursor.path != "/", fixtureURL == nil {
            let candidate = cursor.appendingPathComponent("shared/test-fixtures/relay/probe-orchestration.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) { fixtureURL = candidate }
            cursor.deleteLastPathComponent()
        }
        let fixture = try #require(fixtureURL)
        let rawRoot = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture))
        let root = try #require(rawRoot as? [String: Any])
        let scenario = try #require((root["scenarios"] as? [[String: Any]])?.first {
            $0["caseId"] as? String == "reachable_does_not_authorize_the_native_file_whitelist"
        })
        let sources = try #require(scenario["sources"] as? [String: String])
        #expect(Set(sources.keys) == Set(RelayTransportSource.allCases.map(\.rawValue)))

        // S0 baseline: the connection is anthropic_messages directly and the model follows the connection.
        let baseline = enrichSonnet(transport: .anthropicMessages)
        #expect(baseline.nativeFileMimes == ["application/pdf"])
        #expect(baseline.pdfNativeDefault == true)

        for (rawSource, verdict) in sources {
            let source = try #require(RelayTransportSource(rawValue: rawSource))
            var local = AIModel(
                id: "claude-sonnet-4.5", name: "claude-sonnet-4.5", capabilities: [.text],
                reasoningModeAvailable: false, isAvailable: true, isDefault: false, priceTier: ""
            )
            local.relayTransport = .anthropicMessages
            local.relayTransportSource = source
            // The connection defaults to Chat: the protocol comes only from the model itself.
            let provider = makeRelayProvider(transport: .openaiChatCompletions, catalogModels: [local])
            let enriched = RelayOfficialCatalogResolver.enrich(
                localModel: local,
                provider: provider,
                runtimeConfig: MetadataClient.shared.syncRelayRuntimeConfig()
            )
            #expect(enriched.canonicalModelId == "claude-sonnet-4.5", "\(rawSource)")
            #expect(enriched.capabilities == baseline.capabilities, "\(rawSource): the remaining capabilities are carried over")
            #expect(enriched.promptPrice == baseline.promptPrice, "\(rawSource): pricing is carried over")
            #expect(enriched.attachmentExtraction == baseline.attachmentExtraction, "\(rawSource)")
            if verdict == "not_inherited" {
                #expect(enriched.nativeFileMimes.isEmpty, "\(rawSource)")
                #expect(enriched.pdfNativeDefault == false, "\(rawSource)")
            } else {
                #expect(verdict == "inherited")
                #expect(enriched.nativeFileMimes == baseline.nativeFileMimes, "\(rawSource)")
                #expect(enriched.pdfNativeDefault == baseline.pdfNativeDefault, "\(rawSource)")
            }
        }
    }

    // MARK: - RL2-INHERIT

    private func enrichSonnetModel(
        _ local: AIModel,
        transport: RelayTransport
    ) -> AIModel {
        let provider = makeRelayProvider(transport: transport, catalogModels: [local])
        return RelayOfficialCatalogResolver.enrich(
            localModel: local,
            provider: provider,
            runtimeConfig: MetadataClient.shared.syncRelayRuntimeConfig()
        )
    }

    private func sonnetLocal(id: String = "claude-sonnet-4.5", isManual: Bool) -> AIModel {
        AIModel(
            id: id, name: "mine-\(id)", capabilities: [.text],
            reasoningModeAvailable: false, isAvailable: true, isDefault: false, priceTier: "",
            summary: "Mine", isManual: isManual
        )
    }

    @Test("RL2-INHERIT-01 a match in the corresponding provider carries capabilities / profile / pricing / all three whitelists (catalog and manual models follow the same rule); with envelope nativeFile=false the three whitelists are empty")
    func rl2Inherit01SameFamilyInheritsEverything() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: loadFixtureJSONWithNativeFileWhitelist(withPricing: true))

        for isManual in [false, true] {
            let enriched = enrichSonnetModel(sonnetLocal(isManual: isManual), transport: .anthropicMessages)
            let label = isManual ? "manual" : "catalog"
            #expect(enriched.canonicalModelId == "claude-sonnet-4.5", "\(label)")
            #expect(Set(enriched.capabilities) == [.text, .image, .file, .reasoning], "\(label)")
            #expect(enriched.reasoningProfile == "anthropicReasoning", "\(label)")
            #expect(enriched.reasoningModeAvailable, "\(label)")
            #expect(enriched.generationProfile != nil, "\(label)")
            #expect(enriched.promptPrice == 0.000003, "\(label)")
            #expect(enriched.completionPrice == 0.000015, "\(label)")
            #expect(enriched.nativeFileMimes == ["application/pdf"], "\(label)")
            #expect(enriched.attachmentExtraction?.maxLines == 1234, "\(label)")
            if isManual {
                #expect(enriched.name == "mine-claude-sonnet-4.5")
                #expect(enriched.summary == "Mine")
            }
        }

        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(
            json: loadFixtureJSONWithNativeFileWhitelist(anthropicMessagesNativeFile: false, withPricing: true)
        )
        for isManual in [false, true] {
            let enriched = enrichSonnetModel(sonnetLocal(isManual: isManual), transport: .anthropicMessages)
            let label = isManual ? "manual" : "catalog"
            #expect(enriched.reasoningProfile == "anthropicReasoning", "\(label)")
            #expect(enriched.promptPrice == 0.000003, "\(label)")
            #expect(enriched.nativeFileMimes.isEmpty, "\(label)")
            #expect(enriched.pdfNativeDefault == false, "\(label)")
            #expect(enriched.attachmentExtraction == nil, "\(label)")
        }
    }

    @Test("RL2-INHERIT-02 a cross-provider match carries capabilities / profile / pricing and leaves the three whitelists empty; a manual exact match (including the date-suffix-stripped alias) inherits the same way")
    func rl2Inherit02CrossFamilyInheritsAllButWhitelist() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: loadFixtureJSONWithNativeFileWhitelist(withPricing: true))

        let subjects: [(label: String, model: AIModel)] = [
            ("catalog", sonnetLocal(isManual: false)),
            ("manual", sonnetLocal(isManual: true)),
            ("manual-dated", sonnetLocal(id: "claude-sonnet-4-5-2026-04-01", isManual: true)),
        ]
        for (label, local) in subjects {
            let enriched = enrichSonnetModel(local, transport: .openaiResponses)
            #expect(enriched.canonicalModelId == "claude-sonnet-4.5", "\(label)")
            #expect(Set(enriched.capabilities).isSuperset(of: [.text, .image, .file, .reasoning]), "\(label)")
            #expect(enriched.reasoningProfile == "anthropicReasoning", "\(label)")
            #expect(enriched.promptPrice == 0.000003, "\(label)")
            #expect(enriched.nativeFileMimes.isEmpty, "\(label)")
            #expect(enriched.pdfNativeDefault == false, "\(label)")
            #expect(enriched.attachmentExtraction == nil, "\(label)")
        }

        // A manual model with no match is kept as is; no capabilities are invented.
        let missed = enrichSonnetModel(sonnetLocal(id: "my-finetuned-llm-v2", isManual: true), transport: .openaiResponses)
        #expect(missed.capabilities == [.text])
        #expect(missed.reasoningProfile == nil)
    }
}
