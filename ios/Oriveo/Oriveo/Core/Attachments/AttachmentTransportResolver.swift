import Foundation

/// Which outbound route a chat send will take, from the connection settings, the model and this turn's
/// request options alone; it reads no credentials and makes no network calls.
///
/// The composer uses it at the moment of sending to work out the route ahead of time, then uses the same
/// `AttachmentDelivery.plan` to decide whether this turn's attachments fit. Branches for multi-protocol
/// providers read the same decision functions each Service uses when sending. Anything that cannot be
/// determined (the catalog is not loaded, the protocol is only known once credentials return, image
/// generation routes) returns nil and is left to the failure card at send time, with no guessing.
enum AttachmentTransportResolver {

    struct Request: Equatable {
        /// The web search switch passed to the Service this turn.
        var webSearchEnabled = false
        /// Whether this turn's web preference is automatic (MiniMax picks its web route by it).
        var webPreferenceIsAutomatic = false
        /// This turn goes out through the tool loop (MCP tools or a library agent leg).
        var usesToolLoop = false
    }

    static func resolve(provider: Provider, model: AIModel, request: Request) -> AttachmentTransport? {
        // Image generation has its own dispatch (a separate image endpoint and driver model) and is not predicted here.
        guard !model.capabilities.contains(.imageGen) else { return nil }
        if request.usesToolLoop { return .toolLoop(provider.kind) }

        let modelID = ModelResolver.resolvedProviderModelIdentifier(model.id, providerKind: provider.kind)
        switch provider.kind {
        case .relay:
            return relay(provider.relayRequested?.transport ?? .openaiChatCompletions)

        case .openAI:
            if provider.authMode == .subscription { return .codexSubscription }
            guard catalogReady(.openAI) else { return nil }
            switch OpenAIService.officialTransport(modelID: modelID) {
            case .openaiChat: return .openAIChat
            case .openaiResponses: return .openAIResponses
            default: return nil
            }
        case .grok:
            if provider.authMode == .subscription {
                // The protocol is decided by the model-level source of truth; if it cannot be decided it waits for the context returned when the token is fetched, and is not guessed here.
                guard let transport = CapabilityControlResolution.subscriptionFinalTransport(for: provider, model: model) else {
                    return nil
                }
                return transport == TransportKind.openaiResponses.rawValue ? .grokSubscription : .grokChat
            }
            guard catalogReady(.grok) else { return nil }
            let resolved = MetadataClient.shared.syncResolveCatalogModel(modelID: modelID, providerKind: .grok)
            return GrokService.transportKind(for: resolved) == .openaiResponses ? .grokResponses : .grokChat
        case .gemini:
            guard catalogReady(.gemini) else { return nil }
            return GeminiService.interactionsRecipe(modelID: modelID, webSearchEnabled: request.webSearchEnabled) != nil
                ? .geminiInteractions
                : .geminiGenerateContent
        case .miniMax:
            guard catalogReady(.miniMax) else { return nil }
            return MiniMaxService.exactAnthropicWebRecipe(
                modelID: modelID, requested: request.webPreferenceIsAutomatic
            ) != nil ? .miniMaxAnthropicWeb : .miniMaxChat

        case .anthropic: return .anthropicMessages
        case .openRouter: return .openRouterChat
        case .deepseek: return .deepSeekChat
        case .qwen: return .qwenChat
        case .moonshot: return .moonshotChat
        case .zhipu: return .zhipuChat
        case .siliconFlow: return .siliconFlowChat
        case .mistral: return .mistralChat
        case .groq: return .groqChat
        case .together: return .togetherChat
        case .fireworks: return .fireworksChat
        }
    }

    /// A relay's route is decided only by the protocol configured on the connection; "auto" sends Chat Completions.
    static func relay(_ transport: RelayTransport) -> AttachmentTransport {
        switch transport {
        case .openaiChatCompletions, .auto: return .relayOpenAIChat
        case .openaiResponses: return .relayOpenAIResponses
        case .llamacppNative: return .relayLlamaCppNative
        case .anthropicMessages: return .relayAnthropicMessages
        case .geminiGenerateContent: return .relayGeminiGenerateContent
        }
    }

    /// The model used to resolve text limits and the native allow-list: the same one written into the request
    /// options and handed to `deliver` when sending. Tool-loop legs use the conversation model directly.
    static func deliveryModel(provider: Provider, model: AIModel, transport: AttachmentTransport) -> AIModel {
        if case .toolLoop = transport { return model }
        return evidenceModel(provider: provider, model: model)
    }

    static func evidenceModel(provider: Provider, model: AIModel) -> AIModel {
        provider.kind == .relay
            ? model
            : MetadataClient.shared.syncCurrentCapabilityEvidenceModel(model, providerKind: provider.kind)
    }

    /// While the snapshot or this provider's catalog has not arrived, a route computed now for a provider that picks its protocol from the catalog cannot be trusted.
    private static func catalogReady(_ kind: ProviderKind) -> Bool {
        MetadataClient.shared.syncHasSnapshot() && !MetadataClient.shared.syncIsCatalogPending(providerKind: kind)
    }
}
