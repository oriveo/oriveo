import XCTest
@testable import Oriveo

/// Routes that do not depend on the metadata catalog: one case each. The ones that pick their protocol from the catalog (OpenAI / Grok direct, Gemini, MiniMax)
/// are compared one by one against the real outbound path in `ProviderProductionBuilderMatrixTests`.
@MainActor
final class AttachmentTransportResolverTests: XCTestCase {

    private func model(_ id: String = "model-x", capabilities: [ModelCapability] = [.text, .file]) -> AIModel {
        TestFactories.makeModel(id: id, capabilities: capabilities, isDefault: true)
    }

    private func provider(_ kind: ProviderKind, relay: RelayTransport? = nil, subscription: Bool = false) -> Provider {
        var provider = TestFactories.makeProvider(kind: kind, models: [model()])
        if let relay { provider.relayRequested = RelayRequestedConfig(transport: relay) }
        if subscription { provider.authMode = .subscription }
        return provider
    }

    private func resolve(
        _ provider: Provider, _ model: AIModel? = nil, _ request: AttachmentTransportResolver.Request = .init()
    ) -> AttachmentTransport? {
        AttachmentTransportResolver.resolve(provider: provider, model: model ?? self.model(), request: request)
    }

    func testRelayFollowsTheConfiguredProtocolAndAutoMeansChatCompletions() {
        XCTAssertEqual(resolve(provider(.relay, relay: .openaiChatCompletions)), .relayOpenAIChat)
        XCTAssertEqual(resolve(provider(.relay, relay: .auto)), .relayOpenAIChat)
        XCTAssertEqual(resolve(provider(.relay, relay: .openaiResponses)), .relayOpenAIResponses)
        XCTAssertEqual(resolve(provider(.relay, relay: .llamacppNative)), .relayLlamaCppNative)
        XCTAssertEqual(resolve(provider(.relay, relay: .anthropicMessages)), .relayAnthropicMessages)
        XCTAssertEqual(resolve(provider(.relay, relay: .geminiGenerateContent)), .relayGeminiGenerateContent)
        // The connection has no protocol configured yet: Chat Completions, as on the outbound side.
        XCTAssertEqual(resolve(provider(.relay)), .relayOpenAIChat)
        XCTAssertEqual(Set(RelayTransport.allCases.map(AttachmentTransportResolver.relay)).count, 5)
    }

    func testSubscriptionRoutesAreKnownWithoutFetchingAToken() {
        XCTAssertEqual(resolve(provider(.openAI, subscription: true)), .codexSubscription)
        // A Grok subscription's protocol is decided by the model-level source of truth; the fallback is Responses.
        let grok = provider(.grok, subscription: true)
        let expected: AttachmentTransport =
            CapabilityControlResolution.subscriptionFinalTransport(for: grok, model: model())
                == TransportKind.openaiResponses.rawValue ? .grokSubscription : .grokChat
        XCTAssertEqual(resolve(grok), expected)
    }

    func testSingleRouteProviders() {
        let expected: [ProviderKind: AttachmentTransport] = [
            .anthropic: .anthropicMessages, .openRouter: .openRouterChat, .deepseek: .deepSeekChat,
            .qwen: .qwenChat, .moonshot: .moonshotChat, .zhipu: .zhipuChat, .siliconFlow: .siliconFlowChat,
            .mistral: .mistralChat, .groq: .groqChat, .together: .togetherChat, .fireworks: .fireworksChat,
        ]
        for (kind, transport) in expected {
            XCTAssertEqual(resolve(provider(kind)), transport, "\(kind)")
            // The web search switch does not change these providers' routes.
            XCTAssertEqual(resolve(provider(kind), nil, .init(webSearchEnabled: true, webPreferenceIsAutomatic: true)), transport, "\(kind)")
        }
    }

    func testToolLoopWinsOverTheProviderRouteAndKeepsTheProviderForTheWrapper() {
        for kind in [ProviderKind.openAI, .anthropic, .deepseek, .relay, .gemini] {
            XCTAssertEqual(resolve(provider(kind), nil, .init(usesToolLoop: true)), .toolLoop(kind), "\(kind)")
        }
    }

    func testImageGenerationModelsAreNotPredicted() {
        let imageModel = model(capabilities: [.text, .imageGen])
        for kind in [ProviderKind.openAI, .relay, .openRouter, .gemini] {
            XCTAssertNil(resolve(provider(kind), imageModel), "\(kind)")
            XCTAssertNil(resolve(provider(kind), imageModel, .init(usesToolLoop: true)), "\(kind)")
        }
    }

    func testDeliveryModelIsTheSessionModelOnToolLoopAndRelay() {
        let relay = provider(.relay, relay: .openaiResponses)
        let sessionModel = model("relay-model")
        XCTAssertEqual(
            AttachmentTransportResolver.deliveryModel(provider: relay, model: sessionModel, transport: .relayOpenAIResponses),
            sessionModel
        )
        XCTAssertEqual(
            AttachmentTransportResolver.deliveryModel(provider: provider(.anthropic), model: sessionModel, transport: .toolLoop(.anthropic)),
            sessionModel
        )
    }
}
