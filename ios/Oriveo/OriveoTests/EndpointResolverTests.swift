import Foundation
import Testing
@testable import Oriveo

@Suite("Endpoint Resolver Tests")
struct EndpointResolverTests {

    // MARK: - Helpers

    private func makeProvider(kind: ProviderKind, baseURLText: String? = nil) -> Provider {
        TestFactories.makeProvider(
            kind: kind,
            baseURLText: baseURLText ?? ""
        )
    }


    @Test("User Base URLOverrides All")
    func userBaseURLOverridesAll() throws {
        let provider = makeProvider(kind: .openAI, baseURLText: "https://my-proxy.com/v1")
        let metadata = MetadataClient.ProviderTransportDefinition(
            baseUrl: "https://api.openai.com/v1",
            endpoints: MetadataClient.TransportEndpoints(
                chat: "/chat/completions",
                responses: nil,
                images: nil,
                embeddings: nil,
                files: nil
            )
        )
        let resolved = try EndpointResolver.resolve(
            provider: provider,
            kind: .chat,
            metadataTransport: metadata
        )
        #expect(resolved.baseURL == "https://my-proxy.com/v1")
        #expect(resolved.url.absoluteString == "https://my-proxy.com/v1/chat/completions")
    }


    @Test("Metadata Base URL")
    func metadataBaseURL() throws {
        let provider = makeProvider(kind: .anthropic)
        let metadata = MetadataClient.ProviderTransportDefinition(
            baseUrl: "https://api.anthropic.com/v1",
            endpoints: MetadataClient.TransportEndpoints(
                chat: "/messages",
                responses: nil,
                images: nil,
                embeddings: nil,
                files: "/files"
            )
        )
        let chat = try EndpointResolver.resolve(provider: provider, kind: .chat, metadataTransport: metadata)
        #expect(chat.url.absoluteString == "https://api.anthropic.com/v1/messages")

        let files = try EndpointResolver.resolve(provider: provider, kind: .files, metadataTransport: metadata)
        #expect(files.url.absoluteString == "https://api.anthropic.com/v1/files")
    }


    @Test("Fallback Table")
    func fallbackTable() throws {
        let provider = makeProvider(kind: .anthropic)
        let resolved = try EndpointResolver.resolve(
            provider: provider,
            kind: .chat,
            metadataTransport: nil
        )
        #expect(resolved.baseURL == "https://api.anthropic.com/v1")
        #expect(resolved.url.absoluteString == "https://api.anthropic.com/v1/messages")
    }

    @Test("Qwen Fallback Vs Metadata")
    func qwenFallbackVsMetadata() throws {
        let provider = makeProvider(kind: .qwen)

        let fallback = try EndpointResolver.resolve(provider: provider, kind: .chat, metadataTransport: nil)
        #expect(fallback.baseURL.contains("compatible-mode"))

        let metadata = MetadataClient.ProviderTransportDefinition(
            baseUrl: "https://dashscope-intl.aliyuncs.com",
            endpoints: MetadataClient.TransportEndpoints(
                chat: "/api/v1/services/aigc/text-generation/generation",
                responses: nil, images: nil, embeddings: nil, files: nil
            )
        )
        let native = try EndpointResolver.resolve(
            provider: provider,
            kind: .chat,
            metadataTransport: metadata
        )
        #expect(native.url.absoluteString == "https://dashscope-intl.aliyuncs.com/api/v1/services/aigc/text-generation/generation")
    }


    @Test("Moonshot CNBase URLAllowed")
    func moonshotCNBaseURLAllowed() throws {
        let provider = makeProvider(kind: .moonshot)
        let metadata = MetadataClient.ProviderTransportDefinition(
            baseUrl: "https://api.moonshot.cn/v1",
            endpoints: MetadataClient.TransportEndpoints(
                chat: "/chat/completions",
                responses: nil, images: nil, embeddings: nil, files: nil
            )
        )
        let resolved = try EndpointResolver.resolve(
            provider: provider,
            kind: .chat,
            metadataTransport: metadata
        )
        #expect(resolved.baseURL == "https://api.moonshot.cn/v1")
        #expect(resolved.url.absoluteString == "https://api.moonshot.cn/v1/chat/completions")
    }

    @Test("Silicon Flow International Base URLAllowed")
    func siliconFlowInternationalBaseURLAllowed() throws {
        let provider = makeProvider(kind: .siliconFlow)
        let metadata = MetadataClient.ProviderTransportDefinition(
            baseUrl: "https://api.siliconflow.com/v1",
            endpoints: MetadataClient.TransportEndpoints(
                chat: "/chat/completions",
                responses: nil, images: nil, embeddings: nil, files: nil
            )
        )
        let resolved = try EndpointResolver.resolve(
            provider: provider,
            kind: .chat,
            metadataTransport: metadata
        )
        #expect(resolved.baseURL == "https://api.siliconflow.com/v1")
        #expect(resolved.url.absoluteString == "https://api.siliconflow.com/v1/chat/completions")
    }


    @Test("User Base With Metadata Path")
    func userBaseWithMetadataPath() throws {
        let provider = makeProvider(kind: .openAI, baseURLText: "https://relay.example.com/v1")
        let metadata = MetadataClient.ProviderTransportDefinition(
            baseUrl: "https://api.openai.com/v1",
            endpoints: MetadataClient.TransportEndpoints(
                chat: "/chat/completions",
                responses: "/responses",
                images: "/images/generations",
                embeddings: nil, files: nil
            )
        )
        let responses = try EndpointResolver.resolve(
            provider: provider,
            kind: .responses,
            metadataTransport: metadata
        )
        #expect(responses.url.absoluteString == "https://relay.example.com/v1/responses")
    }


    @Test("Join URLNormalization")
    func joinURLNormalization() {
        let url1 = EndpointResolver.joinURL(base: "https://a.com/v1/", path: "/chat")
        #expect(url1?.absoluteString == "https://a.com/v1/chat")
        let url2 = EndpointResolver.joinURL(base: "https://a.com/v1", path: "chat")
        #expect(url2?.absoluteString == "https://a.com/v1/chat")
        let url3 = EndpointResolver.joinURL(base: "https://a.com/v1", path: "/chat")
        #expect(url3?.absoluteString == "https://a.com/v1/chat")
    }


    @Test("Resolve Base URLPriority")
    func resolveBaseURLPriority() {
        let p1 = makeProvider(kind: .openAI, baseURLText: "https://user.com/v1")
        #expect(EndpointResolver.resolveBaseURL(provider: p1, metadataTransport: nil) == "https://user.com/v1")

        let p2 = makeProvider(kind: .openAI)
        let meta = MetadataClient.ProviderTransportDefinition(
            baseUrl: "https://eu.api.openai.com/v1",
            endpoints: nil
        )
        #expect(EndpointResolver.resolveBaseURL(provider: p2, metadataTransport: meta) == "https://eu.api.openai.com/v1")

        #expect(EndpointResolver.resolveBaseURL(provider: p2, metadataTransport: nil) == "https://api.openai.com/v1")
    }


    private func chatMetadata(baseUrl: String?, chat: String?) -> MetadataClient.ProviderTransportDefinition {
        MetadataClient.ProviderTransportDefinition(
            baseUrl: baseUrl,
            endpoints: MetadataClient.TransportEndpoints(
                chat: chat, responses: nil, images: nil, embeddings: nil, files: nil
            )
        )
    }

    @Test("Deepseek Duplicate Version Segment")
    func deepseekDuplicateVersionSegment() throws {
        let resolved = try EndpointResolver.resolve(
            providerKind: .deepseek,
            userBaseURL: "https://api.deepseek.com/v1",
            kind: .chat,
            metadataTransport: chatMetadata(baseUrl: "https://api.deepseek.com", chat: "/v1/chat/completions")
        )
        #expect(resolved.url.absoluteString == "https://api.deepseek.com/v1/chat/completions")
    }

    @Test("Groq Duplicate Prefix")
    func groqDuplicatePrefix() throws {
        let resolved = try EndpointResolver.resolve(
            providerKind: .groq,
            userBaseURL: "https://api.groq.com/openai/v1",
            kind: .chat,
            metadataTransport: chatMetadata(baseUrl: "https://api.groq.com", chat: "/openai/v1/chat/completions")
        )
        #expect(resolved.url.absoluteString == "https://api.groq.com/openai/v1/chat/completions")
    }

    @Test("Qwen Compatible Mode Base Stripped")
    func qwenCompatibleModeBaseStripped() throws {
        let resolved = try EndpointResolver.resolve(
            providerKind: .qwen,
            userBaseURL: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
            kind: .chat,
            metadataTransport: chatMetadata(
                baseUrl: "https://dashscope-intl.aliyuncs.com",
                chat: "/api/v1/services/aigc/text-generation/generation"
            )
        )
        #expect(resolved.url.absoluteString
            == "https://dashscope-intl.aliyuncs.com/api/v1/services/aigc/text-generation/generation")
    }

    @Test("Qwen Compatible Mode Path Deduped")
    func qwenCompatibleModePathDeduped() throws {
        let resolved = try EndpointResolver.resolve(
            providerKind: .qwen,
            userBaseURL: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
            kind: .chat,
            metadataTransport: chatMetadata(
                baseUrl: "https://dashscope-intl.aliyuncs.com",
                chat: "/compatible-mode/v1/chat/completions"
            )
        )
        #expect(resolved.url.absoluteString
            == "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions")
    }

    @Test("Bare Origin Base Untouched")
    func bareOriginBaseUntouched() throws {
        let resolved = try EndpointResolver.resolve(
            providerKind: .deepseek,
            userBaseURL: "https://api.deepseek.com",
            kind: .chat,
            metadataTransport: chatMetadata(baseUrl: "https://api.deepseek.com", chat: "/v1/chat/completions")
        )
        #expect(resolved.url.absoluteString == "https://api.deepseek.com/v1/chat/completions")
    }

    @Test("Non Matching Prefix Keeps Base Path")
    func nonMatchingPrefixKeepsBasePath() throws {
        let resolved = try EndpointResolver.resolve(
            providerKind: .deepseek,
            userBaseURL: "https://proxy.example.com/upstream",
            kind: .chat,
            metadataTransport: chatMetadata(baseUrl: "https://api.deepseek.com", chat: "/v1/chat/completions")
        )
        #expect(resolved.url.absoluteString == "https://proxy.example.com/upstream/v1/chat/completions")
    }

    @Test("Metadata Base Also Normalized")
    func metadataBaseAlsoNormalized() throws {
        let resolved = try EndpointResolver.resolve(
            providerKind: .deepseek,
            kind: .chat,
            metadataTransport: chatMetadata(baseUrl: "https://api.deepseek.com/v1", chat: "/v1/chat/completions")
        )
        #expect(resolved.url.absoluteString == "https://api.deepseek.com/v1/chat/completions")
    }

    @Test("Trailing Slash Base Normalized")
    func trailingSlashBaseNormalized() throws {
        let resolved = try EndpointResolver.resolve(
            providerKind: .deepseek,
            userBaseURL: "https://api.deepseek.com/v1/",
            kind: .chat,
            metadataTransport: chatMetadata(baseUrl: "https://api.deepseek.com", chat: "/v1/chat/completions")
        )
        #expect(resolved.url.absoluteString == "https://api.deepseek.com/v1/chat/completions")
    }

    @Test("Fallback Short Path Keeps Base")
    func fallbackShortPathKeepsBase() throws {
        let deepseek = try EndpointResolver.resolve(
            providerKind: .deepseek,
            userBaseURL: "https://api.deepseek.com/v1",
            kind: .chat,
            metadataTransport: nil
        )
        #expect(deepseek.url.absoluteString == "https://api.deepseek.com/v1/chat/completions")

        let qwen = try EndpointResolver.resolve(
            providerKind: .qwen,
            userBaseURL: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
            kind: .chat,
            metadataTransport: nil
        )
        #expect(qwen.url.absoluteString
            == "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions")
    }


    @Test("Fallback Chat URLs Match Server Contract")
    func fallbackChatURLsMatchServerContract() throws {
        let golden: [(ProviderKind, String)] = [
            (.deepseek, "https://api.deepseek.com/v1/chat/completions"),
            (.groq, "https://api.groq.com/openai/v1/chat/completions"),
            (.fireworks, "https://api.fireworks.ai/inference/v1/chat/completions"),
            (.zhipu, "https://open.bigmodel.cn/api/paas/v4/chat/completions"),
            (.qwen, "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions"),
        ]
        for (kind, expected) in golden {
            let resolved = try EndpointResolver.resolve(
                providerKind: kind,
                userBaseURL: nil,
                kind: .chat,
                metadataTransport: nil
            )
            #expect(resolved.url.absoluteString == expected)
        }
    }

    @Test("Qwen Images Fallback Uses Native Origin")
    func qwenImagesFallbackUsesNativeOrigin() throws {
        let expected = "https://dashscope-intl.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation"

        let fromFallback = try EndpointResolver.resolve(
            providerKind: .qwen,
            userBaseURL: nil,
            kind: .images,
            metadataTransport: nil
        )
        #expect(fromFallback.url.absoluteString == expected)
        #expect(!fromFallback.url.absoluteString.contains("/images/generations"))
        #expect(!fromFallback.url.absoluteString.contains("compatible-mode/v1/api"))

        let fromUserBase = try EndpointResolver.resolve(
            providerKind: .qwen,
            userBaseURL: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
            kind: .images,
            metadataTransport: nil
        )
        #expect(fromUserBase.url.absoluteString == expected)

        let chat = try EndpointResolver.resolve(
            providerKind: .qwen,
            userBaseURL: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
            kind: .chat,
            metadataTransport: nil
        )
        #expect(chat.url.absoluteString
            == "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions")
    }

    @Test("Mini Max Images Fallback Matches Server Contract")
    func miniMaxImagesFallbackMatchesServerContract() throws {
        let resolved = try EndpointResolver.resolve(
            providerKind: .miniMax,
            userBaseURL: nil,
            kind: .images,
            metadataTransport: nil
        )
        #expect(resolved.url.absoluteString == "https://api.minimax.io/v1/image_generation")
        #expect(!resolved.url.absoluteString.contains("/images/generations"))

        let chat = try EndpointResolver.resolve(
            providerKind: .miniMax,
            userBaseURL: nil,
            kind: .chat,
            metadataTransport: nil
        )
        #expect(chat.url.absoluteString == "https://api.minimax.io/v1/chat/completions")
    }
}
