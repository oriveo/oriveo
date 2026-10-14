import Foundation

/// The single entry point that picks the outbound service by (provider, model).
///
/// Two routes:
/// - `.native`: use this provider's own service (when the `apiProtocol` delivered for an official provider equals the native family, or is missing or unrecognized; hosted / free / subscription).
///   The request body stays byte-for-byte unchanged, guarded by the migration golden test.
/// - `.byProtocol`: the builder that dispatches by protocol (the Relay set: Chat / Responses -> OpenAIService, Messages -> AnthropicService,
///   Gemini -> GeminiService). Relay connections always take this route; an official provider takes it only when a different protocol is delivered, and providerKind only decides the authentication method.
enum ProviderServiceRouter {

    struct ProtocolRoute: Equatable, Sendable {
        /// Protocol used for dispatch (`auto` takes the same branch as Chat).
        let transport: RelayTransport
        /// Connection address handed to the service (for Relay, the address the user entered; for official providers, the delivered base URL that passed the trusted table).
        let baseURL: String
        /// A copy of the configuration for this request: protocol and root address already resolved per model, and the service only reads it.
        let requested: RelayRequestedConfig
        /// Official provider cross-protocol route: web search still mounts tools automatically by chat preference / recipe (the web-search change applies only to the relay path).
        var isOfficialForeign = false
    }

    enum Route: Equatable, Sendable {
        case native(ProviderKind)
        case byProtocol(ProtocolRoute)
    }

    // MARK: - Routing

    static func route(provider: Provider, model: AIModel) -> Route {
        if provider.kind == .relay {
            guard let baseURL = provider.baseURLText else { return .native(.relay) }
            return .byProtocol(.init(
                transport: RelayEndpointResolver.effectiveTransport(provider: provider, model: model),
                baseURL: baseURL,
                requested: RelayEndpointResolver.routedRequested(provider: provider, model: model)
                    ?? RelayRequestedConfig()
            ))
        }
        return officialProtocolRoute(provider: provider).map(Route.byProtocol) ?? .native(provider.kind)
    }

    /// Official provider: dispatch by protocol only when the delivered `apiProtocol` is not this provider's native family. Hosted / free / subscription do not take part.
    static func officialProtocolRoute(
        provider: Provider,
        config: MetadataClient.PublicProviderConfig? = nil
    ) -> ProtocolRoute? {
        guard ProviderForm.of(provider) == .official,
              let config = config ?? MetadataClient.shared.syncPublicProviderConfig(providerKind: provider.kind),
              let transport = foreignTransport(apiProtocol: config.apiProtocol, providerKind: provider.kind),
              OfficialTrustedHosts.isTrustedURL(
                  config.defaultBaseURL, providerKind: provider.kind, delivered: config.trustedHosts?.hosts
              ) else { return nil }
        let baseURL = config.defaultBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return ProtocolRoute(
            transport: transport,
            baseURL: baseURL,
            requested: RelayRequestedConfig(
                transport: transport,
                authMode: officialAuthMode(for: provider.kind),
                resolvedAPIBaseURL: RelayEndpointResolver.versionCompletedAPIRoot(baseURL, transport: transport)
            ),
            isOfficialForeign: true
        )
    }

    /// Returns the protocol only if the delivered value differs from the native family; if equal to the native family, missing or unrecognized, returns nil (take the original path).
    static func foreignTransport(apiProtocol: String?, providerKind: ProviderKind) -> RelayTransport? {
        let raw = apiProtocol?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let declared: RelayTransport
        switch raw {
        case "openai", "openai_compatible", "openai_chat_completions":
            declared = .openaiChatCompletions
        case "openai_responses":
            declared = .openaiResponses
        case "anthropic", "anthropic_messages":
            declared = .anthropicMessages
        case "gemini", "gemini_generate_content":
            declared = .geminiGenerateContent
        default:
            return nil
        }
        return declared == nativeFamily(of: providerKind) ? nil : declared
    }

    /// Native protocol family: anthropic and gemini are one family each, and all other official providers are the openai-compatible family.
    static func nativeFamily(of kind: ProviderKind) -> RelayTransport {
        switch kind {
        case .anthropic: return .anthropicMessages
        case .gemini: return .geminiGenerateContent
        default: return .openaiChatCompletions
        }
    }

    /// providerKind only decides the authentication method: keep this provider's native service auth header and do not follow the protocol.
    static func officialAuthMode(for kind: ProviderKind) -> RelayAuthMode {
        switch kind {
        case .anthropic: return .xApiKey
        case .gemini: return .xGoogApiKey
        default: return .bearer
        }
    }

    // MARK: - Service table

    /// The service instances used for one send, built on the same session. The single table that picks a service by kind.
    struct Services {
        let openRouter: OpenRouterService
        let openAI: OpenAIService
        let deepSeek: DeepSeekService
        let grok: GrokService
        let gemini: GeminiService
        let anthropic: AnthropicService
        let groq: GroqService
        let together: TogetherService
        let fireworks: FireworksService
        let miniMax: MiniMaxService
        let zhipu: ZhipuService
        let qwen: QwenService
        let moonshot: MoonshotService
        let mistral: MistralService
        let siliconFlow: SiliconFlowService

        init(session: URLSession = .shared) {
            openRouter = OpenRouterService(session: session)
            openAI = OpenAIService(session: session)
            deepSeek = DeepSeekService(session: session)
            grok = GrokService(session: session)
            gemini = GeminiService(session: session)
            anthropic = AnthropicService(session: session)
            groq = GroqService(session: session)
            together = TogetherService(session: session)
            fireworks = FireworksService(session: session)
            miniMax = MiniMaxService(session: session)
            zhipu = ZhipuService(session: session)
            qwen = QwenService(session: session)
            moonshot = MoonshotService(session: session)
            mistral = MistralService(session: session)
            siliconFlow = SiliconFlowService(session: session)
        }

        /// Get the native service by kind. Relay catalog sync and probing go through OpenAIService; hosted has no BYOK service.
        func native(for kind: ProviderKind) -> (any ProviderServiceProtocol)? {
            switch kind {
            case .openRouter: return openRouter
            case .openAI: return openAI
            case .deepseek: return deepSeek
            case .grok: return grok
            case .anthropic: return anthropic
            case .gemini: return gemini
            case .groq: return groq
            case .together: return together
            case .fireworks: return fireworks
            case .miniMax: return miniMax
            case .zhipu: return zhipu
            case .qwen: return qwen
            case .moonshot: return moonshot
            case .mistral: return mistral
            case .siliconFlow: return siliconFlow
            case .relay: return openAI
            }
        }

        // MARK: By-protocol dispatch (shared by Relay and official cross-protocol)

        func protocolStream(
            _ route: ProtocolRoute,
            apiKey: String,
            modelID: String,
            messages: [ChatMessage],
            reasoningMode: ReasoningMode,
            webSearchEnabled: Bool,
            supportsImageGen: Bool,
            requestOptions: ChatRequestOptions
        ) -> AsyncThrowingStream<StreamEvent, Error> {
            var options = requestOptions
            options.relayRequested = route.requested
            options.officialForeignRoute = route.isOfficialForeign
            switch route.transport {
            case .anthropicMessages:
                return anthropic.sendMessageStream(
                    apiKey: apiKey, modelID: modelID, messages: messages, baseURL: route.baseURL,
                    reasoningMode: reasoningMode, requestOptions: options, relayRequested: route.requested
                )
            case .geminiGenerateContent:
                return gemini.sendMessageStream(
                    apiKey: apiKey, modelID: modelID, messages: messages, baseURL: route.baseURL,
                    reasoningMode: reasoningMode, webSearchEnabled: webSearchEnabled,
                    // Gemini Relay: imageGen goes through native responseModalities (RelayImageRoute.geminiModality)
                    supportsImageGen: supportsImageGen,
                    requestOptions: options, relayRequested: route.requested
                )
            case .openaiResponses, .openaiChatCompletions, .llamacppNative, .auto:
                return openAI.sendMessageStream(
                    apiKey: apiKey, modelID: modelID, messages: messages, baseURL: route.baseURL,
                    reasoningMode: reasoningMode, requestOptions: options,
                    relayRequested: route.requested, webSearchEnabled: webSearchEnabled
                )
            }
        }

        func protocolSend(
            _ route: ProtocolRoute,
            apiKey: String,
            modelID: String,
            messages: [ChatMessage],
            reasoningMode: ReasoningMode,
            webSearchEnabled: Bool,
            supportsImageGen: Bool,
            requestOptions: ChatRequestOptions
        ) async throws -> ProviderChatResult {
            var options = requestOptions
            options.relayRequested = route.requested
            options.officialForeignRoute = route.isOfficialForeign
            switch route.transport {
            case .anthropicMessages:
                return try await anthropic.sendMessage(
                    apiKey: apiKey, modelID: modelID, messages: messages, baseURL: route.baseURL,
                    reasoningMode: reasoningMode, requestOptions: options, relayRequested: route.requested
                )
            case .geminiGenerateContent:
                return try await gemini.sendMessage(
                    apiKey: apiKey, modelID: modelID, messages: messages, baseURL: route.baseURL,
                    reasoningMode: reasoningMode, webSearchEnabled: webSearchEnabled,
                    supportsImageGen: supportsImageGen,
                    requestOptions: options, relayRequested: route.requested
                )
            case .openaiResponses, .openaiChatCompletions, .llamacppNative, .auto:
                return try await openAI.sendMessage(
                    apiKey: apiKey, modelID: modelID, messages: messages, baseURL: route.baseURL,
                    reasoningMode: reasoningMode, requestOptions: options,
                    relayRequested: route.requested, webSearchEnabled: webSearchEnabled
                )
            }
        }

        /// One-off non-streaming send that bypasses the main chat path (memory drafts etc.): route by (provider, model).
        func sendMessage(
            provider: Provider,
            model: AIModel,
            messages: [ChatMessage]
        ) async throws -> ProviderChatResult? {
            let modelID = model.id
            switch ProviderServiceRouter.route(provider: provider, model: model) {
            case .byProtocol(let route):
                return try await protocolSend(
                    route, apiKey: ProviderCredentialResolver.apiKey(provider: provider, modelID: modelID), modelID: modelID, messages: messages,
                    reasoningMode: .automatic, webSearchEnabled: false, supportsImageGen: false,
                    requestOptions: ChatRequestOptions()
                )
            case .native(let kind):
                guard let service = native(for: kind) else { return nil }
                return try await service.sendMessage(
                    apiKey: ProviderCredentialResolver.apiKey(provider: provider, modelID: modelID),
                    modelID: modelID,
                    messages: messages,
                    // The base URL always comes from the endpoint source resolver. The OpenAI official provider is the exception and passes nil:
                    // `OpenAIService.sendMessage(baseURL:)` has Relay semantics, and passing one would divert into the Relay path.
                    baseURL: kind == .openAI ? nil : provider.requestBaseURLText()
                )
            }
        }
    }
}
