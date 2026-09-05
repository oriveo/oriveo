import Testing
@testable import Oriveo

@Suite("Provider Endpoint Options")
struct ProviderEndpointOptionsTests {

    @Test("Mini Max Official Endpoints")
    func miniMaxOfficialEndpoints() {
        let options = ProviderKind.miniMax.setupEndpointOptions

        #expect(options.count == 2)
        #expect(options.map(\.id) == ["global", "cn"])
        #expect(ProviderKind.miniMax.defaultSetupEndpointID == "global")
        #expect(ProviderKind.miniMax.resolvedSetupBaseURLText(for: "cn") == "api.minimaxi.com/v1")
        #expect(ProviderKind.miniMax.usesConfigurableBaseURL)
    }

    @Test("Mini Max Recognizes New APIKey Format")
    func miniMaxRecognizesNewAPIKeyFormat() {
        #expect(ProviderKind.miniMax.apiKeyPlaceholder == "sk-api-...")
        #expect(ProviderKind.inferred(fromAPIKey: "sk-api-demo") == .miniMax)
    }

    @Test("Generic SKPrefix Does Not Infer Open AI")
    func genericSKPrefixDoesNotInferOpenAI() {
        #expect(ProviderKind.inferred(fromAPIKey: "sk-demo") == nil)
        #expect(ProviderKind.inferred(fromAPIKey: "sk-live-123") == nil)
    }

    @Test("Qwen Official Endpoints")
    func qwenOfficialEndpoints() {
        let options = ProviderKind.qwen.setupEndpointOptions

        #expect(options.count == 4)
        #expect(options.first?.id == "sg")
        #expect(options.first?.baseURLText == "dashscope-intl.aliyuncs.com")
        #expect(ProviderKind.qwen.defaultSetupEndpointID == "sg")
        #expect(ProviderKind.qwen.usesConfigurableBaseURL)
    }

    @Test("Other Providers Do Not Expose Endpoint Options")
    func otherProvidersDoNotExposeEndpointOptions() {
        #expect(ProviderKind.openAI.setupEndpointOptions.isEmpty)
        #expect(ProviderKind.openAI.defaultSetupEndpointID == nil)
        #expect(!ProviderKind.openAI.usesConfigurableBaseURL)
    }

    @Test("Direct Providers Exclude Open Router")
    func directProvidersExcludeOpenRouter() {
        #expect(ProviderKind.directProviders == [
            .openAI,
            .anthropic,
            .gemini,
            .deepseek,
            .grok,
            .miniMax,
            .zhipu,
            .qwen,
            .moonshot,
            .mistral
        ])
    }

    @Test("Aggregator Providers Include Open Router First")
    func aggregatorProvidersIncludeOpenRouterFirst() {
        #expect(ProviderKind.aggregatorProviders == [
            .openRouter,
            .groq,
            .together,
            .fireworks,
            .siliconFlow
        ])
    }

    // MARK: - Grok

    @Test("Grok Display Identity")
    func grokDisplayIdentity() {
        #expect(ProviderKind.grok.displayName == "Grok")
        #expect(ProviderKind.grok.defaultBaseURLText == "api.x.ai/v1")
    }

    @Test("Grok Attachment Support")
    func grokAttachmentSupport() {
        let support = ProviderKind.grok.attachmentSupport
        #expect(support.image == true)
        #expect(support.nativeFile == false)
        #expect(support.textFileInline == true)
    }

    @Test("Grok Recognizes APIKey Prefix")
    func grokRecognizesAPIKeyPrefix() {
        #expect(ProviderKind.grok.apiKeyPlaceholder == "xai-...")
        #expect(ProviderKind.inferred(fromAPIKey: "xai-abc") == .grok)
        #expect(ProviderKind.inferred(fromAPIKey: "XAI-UPPER") == .grok)
    }
}
