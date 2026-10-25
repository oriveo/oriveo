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
        /// The request history (including this turn) has a video attachment; the Gemini Interactions route is excluded by it.
        var historyHasVideo = false
    }

    static func resolve(provider: Provider, model: AIModel, request: Request) -> AttachmentTransport? {
        // Image generation has its own dispatch (a separate image endpoint and driver model) and is not predicted here.
        // A relay uses the same check as the image dispatch (including the image generation override).
        let dispatchesImageGeneration = provider.kind == .relay
            ? RelayRuntimeSupport.dispatchesImageGeneration(model: model)
            : model.capabilities.contains(.imageGen)
        guard !dispatchesImageGeneration else { return nil }
        if request.usesToolLoop { return .toolLoop(provider.kind) }

        let modelID = ModelResolver.resolvedProviderModelIdentifier(model.id, providerKind: provider.kind)
        switch provider.kind {
        case .relay:
            return relay(RelayEndpointResolver.effectiveTransport(provider: provider, model: model))

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
            return GeminiService.interactionsRecipe(
                modelID: modelID, webSearchEnabled: request.webSearchEnabled, historyHasVideo: request.historyHasVideo
            ) != nil
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

    /// A relay's route is decided by the protocol this model actually uses (the model's own protocol first, otherwise the connection's); "auto" sends Chat Completions.
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
            ? RelayFileOverride.applied(to: model, provider: provider)
            : MetadataClient.shared.syncCurrentCapabilityEvidenceModel(model, providerKind: provider.kind)
    }

    /// While the snapshot or this provider's catalog has not arrived, a route computed now for a provider that picks its protocol from the catalog cannot be trusted.
    private static func catalogReady(_ kind: ProviderKind) -> Bool {
        MetadataClient.shared.syncHasSnapshot() && !MetadataClient.shared.syncIsCatalogPending(providerKind: kind)
    }
}

/// Applies a relay model-level file override onto the native-file allowlist. The pre-send check, the outbound
/// delivery and the model options panel all read this one copy through `evidenceModel`, so the three places
/// see the same allowlist.
/// - On: adds `application/pdf` and sets `pdfNativeDefault = true` (the original allowlist is kept as a union);
///   when the facade entry result says native files are closed (the envelope does not accept native files) the file stays text,
///   because the protocol cannot carry a file block.
/// - Off: the allowlist is treated as empty and every file is injected as text.
/// - No override: unchanged.
/// When On and the upstream rejects the file, the send falls back to text as the attachment spec requires and the
/// override itself is not rewritten; an override takes precedence over the `file` negative cache (see
/// `NativeFileFallback.Scope.fileOverride`).
enum RelayFileOverride {
    static let pdfMime = "application/pdf"

    static func applied(to model: AIModel, provider: Provider) -> AIModel {
        guard let value = model.relayCapabilityOverrides?.file else { return model }
        var out = model
        // Whether native files are open only reads the facade entry result (the file_input projection: closed when the envelope does not accept it).
        let projection = CapabilityEvidenceProductionAdapter.capabilityProjection(
            provider: provider, model: model, identity: nil,
            keys: [CapabilityEvidenceFacade.fileInputKey]
        )
        let nativeFileOpen = CapabilityEvidenceFacade.attachmentImportEntry(
            provider: provider, model: model, projection: projection,
            relayInputEnvelope: {
                RelayRuntimeSupport.inputEnvelope(
                    transport: $0, runtimeConfig: MetadataClient.shared.syncRelayRuntimeConfig()
                )
            }
        ).nativeFile
        if value, nativeFileOpen {
            if !out.nativeFileMimes.contains(pdfMime) { out.nativeFileMimes.append(pdfMime) }
            out.pdfNativeDefault = true
        } else {
            out.nativeFileMimes = []
            out.pdfNativeDefault = false
        }
        return out
    }
}
