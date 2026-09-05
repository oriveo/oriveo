import Foundation
import Testing
@testable import Oriveo

@Suite("Metadata Fixture Tests", .serialized)
struct MetadataFixtureTests {

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

    @Test("Fixture Model Resolution")
    func fixtureModelResolution() async throws {
        await MetadataClient.shared.resetForTesting()
        let json = try loadFixtureJSON()
        try await MetadataClient.shared.loadForTesting(json: json)

        let gpt = MetadataClient.shared.syncResolveCatalogModelAcrossProvidersWithProvider(modelID: "gpt-5.4")
        #expect(gpt?.matchedProviderKind == .openAI)
        #expect(gpt?.canonicalModelId == "gpt-5.4")

        let gptDated = MetadataClient.shared.syncResolveCatalogModelAcrossProvidersWithProvider(modelID: "gpt-5.4-2026-04-01")
        #expect(gptDated?.canonicalModelId == "gpt-5.4")

        let gptImage = MetadataClient.shared.syncResolveCatalogModelAcrossProvidersWithProvider(modelID: "gpt-image-2")
        #expect(gptImage?.matchedProviderKind == .openAI)
        #expect(gptImage?.canonicalModelId == "gpt-image-2")

        let claude = MetadataClient.shared.syncResolveCatalogModelAcrossProvidersWithProvider(modelID: "claude-sonnet-4.5")
        #expect(claude?.matchedProviderKind == .anthropic)

        let claudeDated = MetadataClient.shared.syncResolveCatalogModelAcrossProvidersWithProvider(modelID: "claude-sonnet-4-5-2026-04-01")
        #expect(claudeDated?.canonicalModelId == "claude-sonnet-4.5")

        let gemini = MetadataClient.shared.syncResolveCatalogModelAcrossProvidersWithProvider(modelID: "gemini-2.5-pro")
        #expect(gemini?.matchedProviderKind == .gemini)

        #expect(MetadataClient.shared.syncResolveCatalogModelAcrossProvidersWithProvider(modelID: "my-custom-model") == nil)

        await MetadataClient.shared.resetForTesting()
    }

    @Test("Fixture Generation Parameter Expansion Consistency")
    func fixtureGenerationParameterExpansionConsistency() async throws {
        await MetadataClient.shared.resetForTesting()
        let json = try loadFixtureJSON()
        try await MetadataClient.shared.loadForTesting(json: json)

        let gpt = MetadataClient.shared.resolveCatalogModel(modelID: "gpt-5.4", providerKind: .openAI)
        let gptEnum = gpt?.generationProfile?.parameters?.first(where: { $0.id == "reasoning_effort" })?.enumValues
        #expect(gptEnum == [.string("low"), .string("high")])

        let claude = MetadataClient.shared.resolveCatalogModel(modelID: "claude-sonnet-4.5", providerKind: .anthropic)
        let claudeEnum = claude?.generationProfile?.parameters?.first(where: { $0.id == "reasoning_effort" })?.enumValues
        #expect(claudeEnum == [.string("low"), .string("medium"), .string("high"), .string("xhigh")])

        await MetadataClient.shared.resetForTesting()
    }

    @Test("Fixture Runtime Config Alignment")
    func fixtureRuntimeConfigAlignment() async throws {
        await MetadataClient.shared.resetForTesting()
        let json = try loadFixtureJSON()
        try await MetadataClient.shared.loadForTesting(json: json)

        let runtime = MetadataClient.shared.syncRelayRuntimeConfig()
        #expect(runtime.version == "2026-04-23-1")
        #expect(runtime.officialProviderWhitelist == ["openAI", "anthropic", "gemini", "deepseek", "miniMax", "zhipu", "qwen"])

        let openaiResponses = runtime.transportEnvelopes["openai_responses"]
        #expect(openaiResponses?.image == true)
        #expect(openaiResponses?.nativeFile == true)
        #expect(openaiResponses?.webSearch == true)
        #expect(openaiResponses?.imageGeneration == true)
        #expect(runtime.transportRules["openai_responses"]?.providerPriority == "openAI")
        #expect(runtime.transportRules["openai_responses"]?.defaultAuthMode == "bearer")
        #expect(runtime.transportRules["openai_responses"]?.defaultVersion == "v1")
        #expect(runtime.transportRules["openai_responses"]?.acceptedVersions == ["v1"])
        #expect(runtime.transportRules["openai_responses"]?.codexIdentityDefault == true)
        #expect(runtime.transportRules["openai_responses"]?.webSearchToolName == "web_search")
        #expect(runtime.transportRules["openai_responses"]?.imageRoute == "inline_responses_tool")
        #expect(runtime.transportRules["openai_responses"]?.forceStreamForImageGeneration == true)

        let chat = runtime.transportEnvelopes["openai_chat_completions"]
        #expect(chat?.nativeFile == false)
        #expect(chat?.webSearch == false)
        #expect(chat?.imageGeneration == false)
        #expect(runtime.transportRules["openai_chat_completions"]?.defaultAuthMode == "bearer")
        #expect(runtime.transportRules["openai_chat_completions"]?.imageRoute == "images_endpoint")

        let anthropic = runtime.transportEnvelopes["anthropic_messages"]
        #expect(anthropic?.webSearch == false)
        #expect(anthropic?.imageGeneration == false)
        #expect(runtime.transportRules["anthropic_messages"]?.providerPriority == "anthropic")
        #expect(runtime.transportRules["anthropic_messages"]?.defaultAuthMode == "x_api_key")

        let gemini = runtime.transportEnvelopes["gemini_generate_content"]
        #expect(gemini?.webSearch == true)
        #expect(gemini?.imageGeneration == true)
        #expect(runtime.transportRules["gemini_generate_content"]?.defaultAuthMode == "x_goog_api_key")
        #expect(runtime.transportRules["gemini_generate_content"]?.defaultVersion == "v1beta")

        #expect(runtime.verificationPolicy.hardFailedExpiryDays == 7)
        #expect(runtime.verificationPolicy.softFailedRetryAfterSeconds == 60)
        #expect(runtime.verificationPolicy.verifiedCacheDays == 30)
        #expect(runtime.featureGatingPolicy.showActualModelIdHint == true)
        #expect(runtime.featureGatingPolicy.showSoftFailHint == true)

        await MetadataClient.shared.resetForTesting()
    }

    @Test("Empty Whitelist Falls Back To Defaults")
    func emptyWhitelistFallsBackToDefaults() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "contractVersion": 1,
          "providers": {},
          "relayRuntimeConfig": {
            "version": "2026-04-23-x",
            "officialProviderWhitelist": [],
            "transportEnvelopes": {},
            "verificationPolicy": {
              "hardFailedExpiryDays": 7,
              "softFailedRetryAfterSeconds": 60,
              "verifiedCacheDays": 30
            },
            "featureGatingPolicy": {
              "showActualModelIdHint": true,
              "showSoftFailHint": true
            }
          }
        }
        """)

        let runtime = MetadataClient.shared.syncRelayRuntimeConfig()
        #expect(runtime.officialProviderWhitelist.count == 8)
        #expect(runtime.officialProviderWhitelist.contains("openAI"))
        #expect(runtime.officialProviderWhitelist.contains("anthropic"))

        await MetadataClient.shared.resetForTesting()
    }

    @Test("Empty Transport Envelopes Falls Back To Defaults")
    func emptyTransportEnvelopesFallsBackToDefaults() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "contractVersion": 1,
          "providers": {},
          "relayRuntimeConfig": {
            "version": "2026-04-23-x",
            "officialProviderWhitelist": ["openAI"],
            "transportEnvelopes": {},
            "verificationPolicy": {
              "hardFailedExpiryDays": 7,
              "softFailedRetryAfterSeconds": 60,
              "verifiedCacheDays": 30
            },
            "featureGatingPolicy": {
              "showActualModelIdHint": true,
              "showSoftFailHint": true
            }
          }
        }
        """)

        let runtime = MetadataClient.shared.syncRelayRuntimeConfig()
        #expect(runtime.transportEnvelopes["openai_responses"]?.webSearch == true)
        #expect(runtime.transportEnvelopes["openai_chat_completions"]?.webSearch == false)
        #expect(runtime.transportEnvelopes["anthropic_messages"]?.imageGeneration == false)
        #expect(runtime.transportEnvelopes["gemini_generate_content"]?.webSearch == true)

        await MetadataClient.shared.resetForTesting()
    }
}
