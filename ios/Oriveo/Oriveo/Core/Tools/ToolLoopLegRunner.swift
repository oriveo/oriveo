import Foundation
import OriveoProviderKit

/// Rebuilds the assistant message an `openai_chat` leg has to replay when the provider requires
/// its reasoning to be sent back with the tool results. The parser kind comes only from the
/// model's capability recipe; each provider-owned shape reuses the strict accumulator that plain
/// chat uses, while the visible text still goes through the regular decoder.
private enum OpenAIChatReasoningReplayAccumulator {
    case simple(SimpleReasoningReplayAccumulator)
    case openRouter(OpenRouterAssistantReplayStreamAccumulator)
    case miniMax(MiniMaxAssistantReplayStreamAccumulator)
    case mistral(MistralAssistantReplayStreamAccumulator)

    init?(parserKind: String) {
        switch parserKind {
        case "moonshot_reasoning_v1", "deepseek_reasoning_v1":
            self = .simple(SimpleReasoningReplayAccumulator())
        case "openrouter_reasoning_v1":
            self = .openRouter(OpenRouterAssistantReplayStreamAccumulator())
        case "minimax_reasoning_v1":
            self = .miniMax(MiniMaxAssistantReplayStreamAccumulator())
        case "mistral_reasoning_v1":
            self = .mistral(MistralAssistantReplayStreamAccumulator())
        default:
            return nil
        }
    }

    mutating func ingest(_ data: Data) {
        switch self {
        case var .simple(value):
            value.ingest(data)
            self = .simple(value)
        case var .openRouter(value):
            value.ingest(data)
            self = .openRouter(value)
        case var .miniMax(value):
            value.ingest(data)
            self = .miniMax(value)
        case var .mistral(value):
            value.ingest(data)
            self = .mistral(value)
        }
    }

    mutating func completedAssistantMessage(content: String) -> [String: Any]? {
        switch self {
        case var .simple(value):
            let result = value.completedAssistantMessage()
            self = .simple(value)
            return result
        case let .openRouter(value):
            return value.completedAssistantMessage(content: content)
        case let .miniMax(value):
            return value.completedAssistantMessage()
        case let .mistral(value):
            return value.completedAssistantMessage()
        }
    }
}

/// Moonshot and DeepSeek share one replay shape. An explicitly empty `reasoning_content` must be
/// kept: dropping the field makes the second leg fail with a 400.
private struct SimpleReasoningReplayAccumulator {
    private var valid = true
    private var content = ""
    private var reasoning = ""
    private var sawReasoning = false
    private var decoder = OpenAIChatToolCallStreamDecoder(decodesFunctionNames: false)
    private var completedCalls: [ProviderToolCall]?

    mutating func ingest(_ data: Data) {
        guard valid else { return }
        guard let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            valid = false
            return
        }
        guard let choices = frame["choices"] as? [[String: Any]], let choice = choices.first else { return }
        guard choice["delta"] == nil || choice["delta"] is [String: Any] else {
            valid = false
            return
        }
        if let delta = choice["delta"] as? [String: Any] {
            if let rawContent = delta["content"], !(rawContent is NSNull) {
                guard let fragment = rawContent as? String else {
                    valid = false
                    return
                }
                content += fragment
            }
            if delta.keys.contains("reasoning_content") || delta.keys.contains("reasoning") {
                let raw = delta["reasoning_content"] ?? delta["reasoning"]
                guard let fragment = raw as? String else {
                    valid = false
                    return
                }
                sawReasoning = true
                reasoning += fragment
            }
        }
        let calls = decoder.ingest(frame: frame)
        if !calls.isEmpty { completedCalls = calls }
    }

    mutating func completedAssistantMessage() -> [String: Any]? {
        guard valid, sawReasoning else { return nil }
        let calls = completedCalls ?? decoder.finish()
        var wireCalls: [[String: Any]] = []
        for call in calls {
            guard let id = call.providerCallID, !id.isEmpty, !call.name.isEmpty else { return nil }
            wireCalls.append([
                "id": id,
                "type": "function",
                "function": ["name": call.name, "arguments": call.rawArguments],
            ])
        }
        return CapabilityRecipeExecution.deepSeekReplayAssistant(
            content: content,
            reasoningContent: reasoning,
            toolCalls: wireCalls
        )
    }
}

/// Runs one model leg of the tool loop over the `openai_chat` protocol: send the request, decode
/// the stream, emit leg events. It never executes a tool call itself.
nonisolated final class OpenAIChatToolLoopLegRunner: ToolLoopLegRunning, @unchecked Sendable {
    private struct Configuration: Sendable {
        var url: URL
        var apiKey: String
        var modelID: String
        var providerKind: ProviderKind
        var authMode: RelayAuthMode
        var headers: [RelayKeyValue]
        var serviceTier: String?
        var reasoningProfileName: String?
        var reasoningMode: ReasoningMode
        var relayReasoningEffort: String?
        var generationOptions: ChatRequestOptions
        var generationProfile: GenerationProfileRef?
        var effectiveTransport: String
        /// The reasoning-replay decoder selected by the model's capability recipe. Always nil for
        /// relay connections; it is never guessed from a provider or model name.
        var reasoningReplayParserKind: String?
        var capabilityEvidenceModel: AIModel
        var userAgent: String
        /// Headers a subscription link requires verbatim; empty in API-key mode.
        var subscriptionHeaders: [String: String]
        /// Inputs of the outbound tools gate, evaluated for every leg: the catalog snapshot and the
        /// per-connection memory can both change after the runner was created.
        var provider: Provider
        var model: AIModel
        var toolCallMemory: ToolCallMemoryStore
    }

    private let configuration: Configuration
    private let session: URLSession

    /// The wire protocol this connection finally speaks.
    var effectiveTransportForEvidence: String { configuration.effectiveTransport }

    /// - Parameter accessToken: the freshly read access token of a subscription link (the Keychain is
    ///   the source of truth; `provider.apiKey` is only a "connected" marker there). Pass nil in
    ///   API-key mode to use `provider.apiKey`.
    @MainActor
    init(
        provider: Provider,
        model: AIModel,
        modelID: String,
        reasoningMode: ReasoningMode,
        requestOptions: ChatRequestOptions = ChatRequestOptions(),
        accessToken: String? = nil,
        toolCallMemory: ToolCallMemoryStore = .shared,
        session: URLSession = .shared
    ) throws {
        let effectiveKey = accessToken ?? provider.apiKey
        let endpoint = try Self.resolveEndpoint(
            provider: provider, apiKey: effectiveKey, requestOptions: requestOptions
        )
        let authMode = Self.resolvedAuthMode(provider: provider)
        // Profile names are read from the current catalog snapshot first and from the persisted model
        // only as a fallback, the same order plain chat uses. Relay models are not in the catalog.
        let reasoningProfileName: String? = provider.kind == .relay
            ? model.reasoningProfile
            : (MetadataClient.shared.syncResolveCatalogModel(
                modelID: model.id,
                providerKind: provider.kind
               )?.profiles.reasoning ?? model.reasoningProfile)
        let generationProfile: GenerationProfileRef? = provider.kind == .relay
            ? GenerationParameterAvailability.profile(provider: provider, model: model)
            : (MetadataClient.shared.syncResolveCatalogModel(
                modelID: model.id,
                providerKind: provider.kind
            )?.generationProfile ?? model.generationProfile)
        let generationOptions = requestOptions
        // A subscription link fixes its own protocol; everything else reads the catalog.
        let effectiveTransport = provider.kind == .relay
            ? RelayTransport.openaiChatCompletions.rawValue
            : (CapabilityControlResolution.subscriptionFinalTransport(for: provider, model: model)
                ?? MetadataClient.shared.syncResolveCatalogModel(
                    modelID: model.id, providerKind: provider.kind
                )?.transport ?? "")
        let capabilityEvidenceModel = provider.kind == .relay
            ? model
            : MetadataClient.shared.syncCurrentCapabilityEvidenceModel(
                model, providerKind: provider.kind
            )
        configuration = Configuration(
            url: endpoint,
            apiKey: effectiveKey,
            modelID: modelID,
            providerKind: provider.kind,
            authMode: authMode,
            headers: provider.relayRequested?.headers ?? [],
            serviceTier: provider.kind == .relay ? provider.relayRequested?.serviceTier : nil,
            reasoningProfileName: reasoningProfileName,
            reasoningMode: reasoningMode,
            relayReasoningEffort: provider.kind == .relay
                ? provider.relayRequested?.reasoningEffort.flatMap { $0 == .automatic ? nil : $0.rawValue }
                : nil,
            generationOptions: generationOptions,
            generationProfile: generationProfile,
            effectiveTransport: effectiveTransport,
            reasoningReplayParserKind: Self.reasoningReplayParserKind(
                providerKind: provider.kind,
                modelID: modelID,
                transport: effectiveTransport
            ),
            capabilityEvidenceModel: capabilityEvidenceModel,
            userAgent: UserAgentProvider.nativeUserAgent,
            subscriptionHeaders: requestOptions.grokSubscription?.requiredHeaders ?? [:],
            provider: provider,
            model: model,
            toolCallMemory: toolCallMemory
        )
        self.session = session
    }

    func run(request: ToolLoopLegRequest) -> AsyncThrowingStream<ToolLoopLegEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let streamShape = MetadataClient.shared.syncReasoningStreamShape(
                        profileName: self.configuration.reasoningProfileName
                    )
                    let urlRequest = try self.buildURLRequest(request)
                    let (bytes, response) = try await self.session.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else {
                        throw ProviderServiceError.network(detail: "Missing HTTPURLResponse.")
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = Data()
                        for try await byte in bytes { body.append(byte) }
                        // "Tools are not supported" is matched against the raw body first: the mapped
                        // error keeps only a fragment such as `error.message`, which hides shapes
                        // like `detail[].msg`.
                        throw await MainActor.run {
                            ToolUnsupportedErrorMatcher.annotate(
                                BaseAPIService(session: self.session).mapHTTPError(
                                    statusCode: http.statusCode,
                                    data: body,
                                    url: urlRequest.url,
                                    isRelay: self.configuration.providerKind == .relay
                                ),
                                statusCode: http.statusCode, rawBody: body
                            )
                        }
                    }

                    // Fragments are assembled inside the leg and handed over once, so the consumer
                    // sees complete proposals. Function names were sent verbatim and are read back
                    // verbatim.
                    var toolCallDecoder = OpenAIChatToolCallStreamDecoder(decodesFunctionNames: false)
                    var replayAccumulator = self.configuration.reasoningReplayParserKind
                        .flatMap(OpenAIChatReasoningReplayAccumulator.init(parserKind:))
                    var visibleText = ""
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard let payload = Self.ssePayload(from: line) else { continue }
                        if payload == "[DONE]" { break }
                        if let data = payload.data(using: .utf8) {
                            replayAccumulator?.ingest(data)
                        }
                        for event in try Self.events(from: payload, shape: streamShape, toolCalls: &toolCallDecoder) {
                            if case let .textDelta(delta) = event { visibleText += delta }
                            continuation.yield(event)
                        }
                    }
                    if let flushed = Self.toolCallEvent(toolCallDecoder.finish()) {
                        continuation.yield(flushed)
                    }
                    if let replay = replayAccumulator?.completedAssistantMessage(content: visibleText),
                       let value = try? ToolJSONValue.make(replay) {
                        continuation.yield(.providerAssistantReplay(value))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Converts the chat history into loop messages: file attachments are injected as text the same
    /// way plain chat does, and images become `image_url` parts.
    static func messages(
        from chatMessages: [ChatMessage],
        providerKind: ProviderKind,
        model: AIModel
    ) -> [ToolLoopMessage] {
        chatMessages.compactMap { message in
            let attachments = message.attachments ?? []
            let injected = BaseAPIService.injectFileAttachmentsAsText(
                userText: message.text,
                attachments: attachments,
                provider: providerKind,
                model: model,
                imagePlaceholderText: nil
            ).text
            let images = attachments.filter { $0.kind == .image && !$0.resolvedDataURL.isEmpty }
            guard !images.isEmpty else {
                return ToolLoopMessage(role: message.role.rawValue, content: injected)
            }

            var parts: [ToolLoopMessage.ContentPart] = []
            if !injected.isEmpty {
                parts.append(.init(type: "text", text: injected, imageURL: nil))
            }
            parts.append(contentsOf: images.map {
                .init(
                    type: "image_url",
                    text: nil,
                    imageURL: .init(url: $0.resolvedDataURL, detail: "auto")
                )
            })
            return ToolLoopMessage(role: message.role.rawValue, contentParts: parts)
        }
    }

    private func buildURLRequest(
        _ leg: ToolLoopLegRequest
    ) throws -> URLRequest {
        var request = URLRequest(url: configuration.url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        Self.applyAuthentication(
            to: &request,
            mode: configuration.authMode,
            apiKey: configuration.apiKey
        )
        if configuration.providerKind == .openRouter {
            request.setValue("https://github.com/oriveo/oriveo", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("Oriveo", forHTTPHeaderField: "X-Title")
        }
        for header in configuration.headers where !header.key.isEmpty {
            request.setValue(header.value, forHTTPHeaderField: header.key)
        }
        for (key, value) in configuration.subscriptionHeaders where !key.isEmpty {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let currentOfficialInput = configuration.providerKind == .relay
            ? nil
            : MetadataClient.shared.syncCapabilityEvidenceModelInput(
                modelID: configuration.capabilityEvidenceModel.id,
                providerKind: configuration.providerKind
            )
        // The transport has a single source: `effectiveTransport` computed in `init`. Deriving it
        // again from the catalog here would yield an empty string for subscription links, which
        // silently disables reasoning and generation-parameter injection.
        let finalEffectiveTransport = configuration.effectiveTransport
        let finalReasoningProfileName = configuration.providerKind == .relay
            ? configuration.reasoningProfileName
            : currentOfficialInput?.resolved?.profiles.reasoning
        let finalGenerationProfile = configuration.providerKind == .relay
            ? configuration.generationProfile
            : currentOfficialInput?.resolved?.generationProfile

        let hasVisionInput = leg.messages.contains { message in
            message.contentParts?.contains(where: { $0.type == "image_url" }) == true
        }
        let requestsTools = !leg.tools.isEmpty && leg.toolChoice != .none
        let requestedReasoningMode = Self.semanticReasoningMode(
            relayEffort: configuration.relayReasoningEffort,
            fallback: configuration.reasoningMode
        )
        var capabilityKeys: Set<String> = []
        var explicitKeys: Set<String> = []
        if hasVisionInput {
            capabilityKeys.insert("vision_input")
            explicitKeys.insert("vision_input")
        }
        if requestsTools {
            capabilityKeys.insert("tool_call")
            explicitKeys.insert("tool_call")
        }
        let reasoningModes = requestedReasoningMode == .automatic
            ? ReasoningMode.allCases.filter { $0 != .automatic }
            : [requestedReasoningMode]
        capabilityKeys.formUnion(reasoningModes.map { "reasoning_level/\($0.rawValue)" })
        if requestedReasoningMode != .automatic {
            explicitKeys.insert("reasoning_level/\(requestedReasoningMode.rawValue)")
        }
        let capabilityIntent = CapabilityEvidenceProductionAdapter.finalDispatchIntent(
            request: request,
            effectiveTransport: finalEffectiveTransport,
            model: configuration.capabilityEvidenceModel,
            keys: capabilityKeys,
            explicitKeys: explicitKeys
        )
        // The outbound tools gate is the capability policy alone (declared support, a local adapter
        // for the transport, and what this connection is remembered to accept).
        if requestsTools, !ToolCallCapabilityPolicy.permitsToolsOutbound(
            provider: configuration.provider, model: configuration.model, memory: configuration.toolCallMemory
        ) {
            throw ProviderServiceError.invalidConfiguration(
                detail: "Tools are unavailable for this model or connection."
            )
        }
        let outboundMessages = hasVisionInput && !capabilityIntent.permitsOutbound("vision_input")
            ? leg.messages.map(Self.removingVisionInput)
            : leg.messages
        let allowedReasoningMode: ReasoningMode? = {
            let selected = requestedReasoningMode == .automatic
                ? capabilityIntent.declaredReasoningDefaultLevel : requestedReasoningMode
            guard let selected,
                  capabilityIntent.permitsOutbound("reasoning_level/\(selected.rawValue)") else {
                return nil
            }
            return selected
        }()

        var payload: [String: Any] = [
            "model": configuration.modelID,
            "messages": try OpenAIChatToolAdapter().encodeConversation(outboundMessages).messages,
            "stream": true,
            "stream_options": ["include_usage": true],
        ]
        if requestsTools {
            payload["tools"] = try OpenAIChatToolAdapter().encodeTools(leg.tools)
            payload["tool_choice"] = leg.toolChoice.rawValue
        }
        if let serviceTier = configuration.serviceTier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !serviceTier.isEmpty {
            payload["service_tier"] = serviceTier
        }
        if let allowedReasoningMode,
           let reasoningParams = ProfileParamsResolver.reasoningMergeParams(
            providerKind: configuration.providerKind,
            modelID: configuration.modelID,
            reasoningMode: allowedReasoningMode,
            profileName: finalReasoningProfileName
        ) {
            ProfileParamsResolver.deepMerge(&payload, reasoningParams)
        }
        if allowedReasoningMode != nil,
           let relayReasoningEffort = configuration.relayReasoningEffort {
            payload["reasoning_effort"] = relayReasoningEffort
        }
        // Every leg shares the generation-parameter resolver with plain chat, so model defaults and
        // per-conversation overrides apply here too and stay behind the same capability gate.
        ProfileParamsResolver.applyGenerationParameters(
            to: &payload,
            options: configuration.generationOptions,
            profile: finalGenerationProfile,
            finalRequest: request,
            effectiveTransport: finalEffectiveTransport
        )
        // The capability recipe is the only automatic writer of capability fields, applied after the
        // generation parameters and before encoding, as in the chat request builders.
        // - `reasoningMode` is the level that already passed the outbound gate; nil falls back to
        //   `.automatic`, which makes the compiler inject nothing.
        // - `webSearchEnabled` stays false: `payload["tools"]` belongs to the tool loop, and a web
        //   `server_tool` recipe would append to that same array.
        CapabilityRecipeRequestCompiler.apply(
            to: &payload,
            providerKind: configuration.providerKind,
            modelID: configuration.modelID,
            transport: finalEffectiveTransport,
            webSearchEnabled: false,
            reasoningMode: allowedReasoningMode ?? .automatic
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return request
    }

    private static func removingVisionInput(_ message: ToolLoopMessage) -> ToolLoopMessage {
        var copy = message
        if let parts = message.contentParts {
            let filtered = parts.filter { $0.type != "image_url" }
            copy.contentParts = filtered.isEmpty ? nil : filtered
            if filtered.isEmpty, copy.content == nil { copy.content = "" }
        }
        return copy
    }

    private static func semanticReasoningMode(
        relayEffort: String?,
        fallback: ReasoningMode
    ) -> ReasoningMode {
        switch relayEffort {
        case "low": return .fast
        case "medium": return .balanced
        case "high": return .deep
        case "xhigh": return .max
        default: return fallback
        }
    }

    private static func reasoningReplayParserKind(
        providerKind: ProviderKind,
        modelID: String,
        transport: String
    ) -> String? {
        guard providerKind != .relay,
              let recipe = MetadataClient.shared.syncCapabilityRecipe(
                modelID: modelID, providerKind: providerKind, capability: "reasoning"
              ),
              CapabilityRecipeExecution.mayExecute(recipe),
              recipe.continuationKind == RequestContinuationKind.replayReasoning.rawValue,
              CapabilityRecipeRequestCompiler.canonicalTransport(recipe.transport.protocolName)
                == CapabilityRecipeRequestCompiler.canonicalTransport(transport),
              let parser = recipe.responseParserKind,
              [
                "moonshot_reasoning_v1", "deepseek_reasoning_v1", "openrouter_reasoning_v1",
                "minimax_reasoning_v1", "mistral_reasoning_v1",
              ].contains(parser) else { return nil }
        return parser
    }

    @MainActor
    private static func resolveEndpoint(
        provider: Provider,
        apiKey: String,
        requestOptions: ChatRequestOptions
    ) throws -> URL {
        // A Grok subscription leg must go to the subscription's own chat endpoint; the API-key host
        // would answer a subscription token with 401.
        if provider.authMode == .subscription, provider.kind == .grok {
            guard let chatURL = requestOptions.grokSubscription?.chatURL else {
                throw ProviderServiceError.invalidConfiguration(detail: "Missing Grok subscription chat endpoint.")
            }
            return chatURL
        }
        if provider.kind == .relay {
            guard let rawBaseURL = provider.baseURLText,
                  !rawBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProviderServiceError.invalidConfiguration(detail: "Missing Relay base URL.")
            }
            let runtime = MetadataClient.shared.syncRelayRuntimeConfig()
            let rule = runtime.transportRules[MetadataClient.RelayTransportKey.openaiChatCompletions]
                ?? MetadataClient.RelayRuntimeConfig.fallback.transportRules[MetadataClient.RelayTransportKey.openaiChatCompletions]!
            return try relayURL(
                baseURL: rawBaseURL,
                defaultVersion: rule.defaultVersion,
                acceptedVersions: Set(rule.acceptedVersions),
                queryParams: provider.relayRequested?.queryParams ?? [],
                authMode: resolvedAuthMode(provider: provider),
                apiKey: apiKey
            )
        }

        let rawUserBase = provider.baseURLText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let userBase = rawUserBase.flatMap { value in
            value.isEmpty ? nil : (value.hasPrefix("http://") || value.hasPrefix("https://") ? value : "https://\(value)")
        }
        return try EndpointResolver.resolve(
            providerKind: provider.kind,
            userBaseURL: userBase,
            kind: .chat,
            metadataTransport: MetadataClient.shared.syncProviderTransport(providerKind: provider.kind)
        ).url
    }

    private static func relayURL(
        baseURL: String,
        defaultVersion: String,
        acceptedVersions: Set<String>,
        queryParams: [RelayKeyValue],
        authMode: RelayAuthMode,
        apiKey: String
    ) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        let baseString = normalized.hasPrefix("http://") || normalized.hasPrefix("https://")
            ? normalized
            : "https://\(normalized)"
        guard let base = URL(string: baseString),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw ProviderServiceError.invalidConfiguration(detail: "Invalid Relay base URL.")
        }

        let existingSegments = components.path.split(separator: "/").map(String.init)
        let hasVersion = existingSegments.contains(where: acceptedVersions.contains)
        var pathSegments = existingSegments
        if !hasVersion { pathSegments.append(defaultVersion) }
        pathSegments.append(contentsOf: ["chat", "completions"])
        components.path = "/" + pathSegments.joined(separator: "/")
        var items = components.queryItems ?? []
        if authMode == .queryKey {
            items.append(URLQueryItem(name: "key", value: apiKey))
        }
        items.append(contentsOf: queryParams.filter { !$0.key.isEmpty }.map {
            URLQueryItem(name: $0.key, value: $0.value)
        })
        components.queryItems = items.isEmpty ? nil : items
        guard let url = components.url else {
            throw ProviderServiceError.invalidConfiguration(detail: "Invalid Relay endpoint URL.")
        }
        return url
    }

    @MainActor
    private static func resolvedAuthMode(provider: Provider) -> RelayAuthMode {
        guard provider.kind == .relay else { return .bearer }
        if let requested = provider.relayRequested?.authMode, requested != .auto { return requested }
        let rule = MetadataClient.shared.syncRelayRuntimeConfig()
            .transportRules[MetadataClient.RelayTransportKey.openaiChatCompletions]
        return RelayAuthMode(rawValue: rule?.defaultAuthMode ?? "bearer") ?? .bearer
    }

    private static func applyAuthentication(to request: inout URLRequest, mode: RelayAuthMode, apiKey: String) {
        switch mode {
        case .none:
            break
        case .auto, .bearer:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .xApiKey:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        case .xGoogApiKey:
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        case .queryKey:
            break
        }
    }

    private static func ssePayload(from line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        return String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
    }

    /// Assembled proposals become one `.toolCallDeltas`, each entry a complete call.
    private static func toolCallEvent(_ calls: [ProviderToolCall]) -> ToolLoopLegEvent? {
        guard !calls.isEmpty else { return nil }
        return .toolCallDeltas(calls.enumerated().map { offset, call in
            ToolLoopToolCallDelta(
                index: offset, id: call.providerCallID, type: "function",
                name: call.name, arguments: call.rawArguments
            )
        })
    }

    private static func events(
        from payload: String,
        shape: MetadataClient.StreamShape? = nil,
        toolCalls decoder: inout OpenAIChatToolCallStreamDecoder
    ) throws -> [ToolLoopLegEvent] {
        guard let data = payload.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderServiceError.network(detail: "The provider returned an invalid streaming event.")
        }
        if let error = root["error"] as? [String: Any] {
            throw ProviderServiceError.upstream(
                statusCode: 500,
                detail: error["message"] as? String ?? "The provider returned a streaming error."
            )
        }

        var events: [ToolLoopLegEvent] = []
        if let usage = root["usage"] as? [String: Any] {
            events.append(.usage(ToolLoopUsage(
                promptTokens: usage["prompt_tokens"] as? Int,
                completionTokens: usage["completion_tokens"] as? Int,
                totalTokens: usage["total_tokens"] as? Int
            )))
        }
        guard let choice = (root["choices"] as? [[String: Any]])?.first else { return events }
        // `finish_reason` may arrive in a frame of its own with no delta, so flushing cannot depend
        // on a delta being present.
        let finishReason = choice["finish_reason"] as? String
        guard let delta = choice["delta"] as? [String: Any] else {
            if let flushed = toolCallEvent(decoder.ingest(toolCalls: nil, finishReason: finishReason)) {
                events.append(flushed)
            }
            return events
        }

        if let content = delta["content"] as? String, !content.isEmpty {
            events.append(.textDelta(content))
        } else if let blocks = delta["content"] as? [[String: Any]] {
            // The block-array shape carries thinking inside `content`; fold it out with the same
            // helper plain chat uses instead of discarding it.
            if let folded = OpenAIChatContentBlocks.fold(blocks), !folded.reasoning.isEmpty {
                events.append(.reasoningDelta(folded.reasoning))
            }
            let text = blocks.compactMap { block -> String? in
                guard let type = block["type"] as? String,
                      type == "text" || type == "output_text" else { return nil }
                return block["text"] as? String
            }.joined()
            if !text.isEmpty { events.append(.textDelta(text)) }
        }

        // Reasoning deltas follow the same order as the chat strategy: an explicit stream-shape path
        // wins; otherwise both `reasoning_content` and `reasoning` are checked.
        if let overridePath = shape?.reasoningDeltaPath {
            if let reasoning = StreamPathExtractor.extractString(root, path: overridePath),
               !reasoning.isEmpty {
                events.append(.reasoningDelta(reasoning))
            }
        } else {
            let reasoning = (delta["reasoning_content"] as? String)
                ?? (delta["reasoning"] as? String)
            if let reasoning, !reasoning.isEmpty {
                events.append(.reasoningDelta(reasoning))
            }
        }

        let rawToolCalls = delta["tool_calls"] as? [[String: Any]]
        let deltas = rawToolCalls.flatMap { raw -> [OpenAICompatibleChunk.Choice.ToolCallDelta]? in
            guard JSONSerialization.isValidJSONObject(raw),
                  let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
            return try? JSONDecoder().decode([OpenAICompatibleChunk.Choice.ToolCallDelta].self, from: data)
        }
        if let flushed = toolCallEvent(decoder.ingest(toolCalls: deltas, finishReason: finishReason)) {
            events.append(flushed)
        }
        return events
    }
}

/// Leg runner for the protocols other than `openai_chat` (`anthropic_messages`,
/// `openai_responses`, `gemini_generate`).
///
/// It has the same job as `OpenAIChatToolLoopLegRunner`. The protocol differences live in
/// `ToolProtocolAdapter` (conversation, tools and proposal translation) and `ToolLoopLegWire`
/// (endpoint, headers, request skeleton, usage and in-stream errors); text and reasoning deltas reuse
/// the `TransportStrategy` of plain chat.
nonisolated final class ProtocolToolLoopLegRunner: ToolLoopLegRunning, @unchecked Sendable {
    private struct Configuration: Sendable {
        var url: URL
        var apiKey: String
        var modelID: String
        var providerKind: ProviderKind
        var authMode: RelayAuthMode
        var headers: [RelayKeyValue]
        var reasoningProfileName: String?
        var reasoningMode: ReasoningMode
        var generationOptions: ChatRequestOptions
        var generationProfile: GenerationProfileRef?
        /// The wire protocol this connection finally speaks: the relay's requested one, or the
        /// catalog's for an official provider. Request building never derives it a second time.
        var effectiveTransport: String
        var maxOutputTokens: Int?
        var capabilityEvidenceModel: AIModel
        var userAgent: String
        var subscriptionHeaders: [String: String]
        var provider: Provider
        var model: AIModel
        var toolCallMemory: ToolCallMemoryStore
    }

    let adapter: any ToolProtocolAdapter
    private let wire: any ToolLoopLegWire
    private let configuration: Configuration
    private let session: URLSession

    var effectiveTransportForEvidence: String { configuration.effectiveTransport }

    @MainActor
    init(
        adapter: any ToolProtocolAdapter,
        wire: any ToolLoopLegWire,
        provider: Provider,
        model: AIModel,
        modelID: String,
        reasoningMode: ReasoningMode,
        requestOptions: ChatRequestOptions = ChatRequestOptions(),
        accessToken: String? = nil,
        toolCallMemory: ToolCallMemoryStore = .shared,
        session: URLSession = .shared
    ) throws {
        let catalog = provider.kind == .relay
            ? nil
            : MetadataClient.shared.syncResolveCatalogModel(modelID: model.id, providerKind: provider.kind)
        let effectiveTransport = provider.kind == .relay
            ? wire.transportKind.rawValue
            : (CapabilityControlResolution.subscriptionFinalTransport(for: provider, model: model)
                ?? catalog?.transport ?? "")
        let authMode = Self.resolvedAuthMode(provider: provider, wire: wire)
        let effectiveKey = accessToken ?? provider.apiKey
        let url = try Self.resolveEndpoint(
            provider: provider, modelID: modelID, apiKey: effectiveKey, authMode: authMode, wire: wire,
            requestOptions: requestOptions
        )
        configuration = Configuration(
            url: url,
            apiKey: effectiveKey,
            modelID: modelID,
            providerKind: provider.kind,
            authMode: authMode,
            headers: provider.relayRequested?.headers ?? [],
            reasoningProfileName: provider.kind == .relay ? model.reasoningProfile : (catalog?.profiles.reasoning ?? model.reasoningProfile),
            reasoningMode: reasoningMode,
            generationOptions: requestOptions,
            generationProfile: provider.kind == .relay
                ? GenerationParameterAvailability.profile(provider: provider, model: model)
                : (catalog?.generationProfile ?? model.generationProfile),
            effectiveTransport: effectiveTransport,
            maxOutputTokens: catalog?.maxOutputTokens.flatMap { $0 > 0 ? $0 : nil },
            capabilityEvidenceModel: provider.kind == .relay
                ? model
                : MetadataClient.shared.syncCurrentCapabilityEvidenceModel(model, providerKind: provider.kind),
            userAgent: UserAgentProvider.nativeUserAgent,
            subscriptionHeaders: requestOptions.grokSubscription?.requiredHeaders ?? [:],
            provider: provider,
            model: model,
            toolCallMemory: toolCallMemory
        )
        self.adapter = adapter
        self.wire = wire
        self.session = session
    }

    func run(request: ToolLoopLegRequest) -> AsyncThrowingStream<ToolLoopLegEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try self.buildURLRequest(request)
                    let (bytes, response) = try await self.session.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else {
                        throw ProviderServiceError.network(detail: "Missing HTTPURLResponse.")
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = Data()
                        for try await byte in bytes { body.append(byte) }
                        throw await MainActor.run {
                            ToolUnsupportedErrorMatcher.annotate(
                                BaseAPIService(session: self.session).mapHTTPError(
                                    statusCode: http.statusCode, data: body, url: urlRequest.url,
                                    isRelay: self.configuration.providerKind == .relay
                                ),
                                statusCode: http.statusCode, rawBody: body
                            )
                        }
                    }

                    let strategy = TransportRegistry.strategy(for: self.wire.transportKind)
                    let shape = MetadataClient.shared.syncReasoningStreamShape(
                        profileName: self.configuration.reasoningProfileName
                    )
                    var ctx = StreamContext()
                    var decoder = self.adapter.makeStreamDecoder()
                    var usage: ToolLoopUsage?
                    var currentEvent = ""
                    var proposals: [ProviderToolCall] = []
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if line.hasPrefix("event:") {
                            currentEvent = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                            continue
                        }
                        guard let payload = Self.ssePayload(from: line) else { continue }
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              var frame = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            throw ProviderServiceError.network(detail: "The provider returned an invalid streaming event.")
                        }
                        if self.wire.injectsEventType, frame["type"] == nil, !currentEvent.isEmpty {
                            frame["type"] = currentEvent
                        }
                        currentEvent = ""
                        if let error = self.wire.streamError(in: frame) { throw error }
                        if let next = self.wire.usage(from: frame, current: usage) { usage = next }

                        // Text and reasoning go through the chat strategy; tool calls go through the
                        // adapter's decoder.
                        let framePayload = try Self.serialized(frame)
                        for event in strategy.parseStreamLine(framePayload, ctx: &ctx, shape: shape) {
                            switch event {
                            case let .delta(text): continuation.yield(.textDelta(text))
                            case let .reasoning(text): continuation.yield(.reasoningDelta(text))
                            case .toolCallDeltas, .citations, .imagePart, .activity, .done: break
                            }
                        }
                        proposals.append(contentsOf: decoder.ingest(frame: frame))
                    }
                    proposals.append(contentsOf: decoder.finish())
                    if let usage { continuation.yield(.usage(usage)) }
                    if !decoder.replayBlocks.isEmpty {
                        continuation.yield(.providerReplayBlocks(decoder.replayBlocks))
                    }
                    if let event = Self.toolCallEvent(proposals) { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func buildURLRequest(
        _ leg: ToolLoopLegRequest
    ) throws -> URLRequest {
        var request = URLRequest(url: configuration.url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        wire.applyProtocolHeaders(to: &request)
        Self.applyAuthentication(to: &request, mode: configuration.authMode, apiKey: configuration.apiKey)
        for header in configuration.headers where !header.key.isEmpty {
            request.setValue(header.value, forHTTPHeaderField: header.key)
        }
        for (key, value) in configuration.subscriptionHeaders where !key.isEmpty {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let requestsTools = !leg.tools.isEmpty && leg.toolChoice != .none
        let hasVisionInput = leg.messages.contains { message in
            message.contentParts?.contains(where: { $0.type == "image_url" }) == true
        }
        var capabilityKeys: Set<String> = []
        var explicitKeys: Set<String> = []
        if hasVisionInput {
            capabilityKeys.insert("vision_input")
            explicitKeys.insert("vision_input")
        }
        if requestsTools {
            capabilityKeys.insert("tool_call")
            explicitKeys.insert("tool_call")
        }
        let requestedReasoningMode = configuration.reasoningMode
        let reasoningModes = requestedReasoningMode == .automatic
            ? ReasoningMode.allCases.filter { $0 != .automatic }
            : [requestedReasoningMode]
        capabilityKeys.formUnion(reasoningModes.map { "reasoning_level/\($0.rawValue)" })
        if requestedReasoningMode != .automatic {
            explicitKeys.insert("reasoning_level/\(requestedReasoningMode.rawValue)")
        }
        let capabilityIntent = CapabilityEvidenceProductionAdapter.finalDispatchIntent(
            request: request,
            effectiveTransport: configuration.effectiveTransport,
            model: configuration.capabilityEvidenceModel,
            keys: capabilityKeys,
            explicitKeys: explicitKeys
        )
        // The outbound tools gate is the capability policy alone (declared support, a local adapter
        // for the transport, and what this connection is remembered to accept).
        if requestsTools, !ToolCallCapabilityPolicy.permitsToolsOutbound(
            provider: configuration.provider, model: configuration.model, memory: configuration.toolCallMemory
        ) {
            throw ProviderServiceError.invalidConfiguration(
                detail: "Tools are unavailable for this model or connection."
            )
        }
        let outboundMessages = hasVisionInput && !capabilityIntent.permitsOutbound("vision_input")
            ? leg.messages.map(Self.removingVisionInput)
            : leg.messages
        let allowedReasoningMode: ReasoningMode? = {
            let selected = requestedReasoningMode == .automatic
                ? capabilityIntent.declaredReasoningDefaultLevel : requestedReasoningMode
            guard let selected,
                  capabilityIntent.permitsOutbound("reasoning_level/\(selected.rawValue)") else {
                return nil
            }
            return selected
        }()

        let conversation = try adapter.encodeConversation(outboundMessages)
        // The final leg (`toolChoice == .none`) still carries the tool definitions: some upstreams
        // answer 400 when the history holds tool results but the request declares no tools.
        let tools = leg.tools.isEmpty ? nil : try adapter.encodeTools(leg.tools)
        var payload = wire.requestBody(
            modelID: configuration.modelID,
            conversation: conversation,
            tools: tools,
            toolChoice: leg.toolChoice,
            maxOutputTokens: configuration.maxOutputTokens
        )
        if let allowedReasoningMode,
           let reasoningParams = ProfileParamsResolver.reasoningMergeParams(
            providerKind: configuration.providerKind,
            modelID: configuration.modelID,
            reasoningMode: allowedReasoningMode,
            profileName: configuration.reasoningProfileName
        ) {
            ProfileParamsResolver.deepMerge(&payload, reasoningParams)
        }
        ProfileParamsResolver.applyGenerationParameters(
            to: &payload,
            options: configuration.generationOptions,
            profile: configuration.generationProfile,
            finalRequest: request,
            effectiveTransport: configuration.effectiveTransport
        )
        CapabilityRecipeRequestCompiler.apply(
            to: &payload,
            providerKind: configuration.providerKind,
            modelID: configuration.modelID,
            transport: configuration.effectiveTransport,
            webSearchEnabled: false,
            reasoningMode: allowedReasoningMode ?? .automatic
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return request
    }


    @MainActor
    private static func resolveEndpoint(
        provider: Provider,
        modelID: String,
        apiKey: String,
        authMode: RelayAuthMode,
        wire: any ToolLoopLegWire,
        requestOptions: ChatRequestOptions
    ) throws -> URL {
        if provider.authMode == .subscription, provider.kind == .grok {
            // A Grok subscription leg must go to the subscription's own Responses endpoint.
            guard wire.transportKind == .openaiResponses,
                  let responsesURL = requestOptions.grokSubscription?.responsesURL else {
                throw ProviderServiceError.invalidConfiguration(detail: "Missing Grok subscription responses endpoint.")
            }
            return responsesURL
        }
        if provider.kind == .relay {
            guard let rawBaseURL = provider.baseURLText,
                  !rawBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProviderServiceError.invalidConfiguration(detail: "Missing Relay base URL.")
            }
            let rule = relayRule(for: wire)
            let apiBase = try RelayEndpointResolver.runtimeAPIBaseURL(
                rawBaseURL: rawBaseURL,
                relayRequested: provider.relayRequested,
                defaultVersion: rule.defaultVersion,
                acceptedVersions: Set(rule.acceptedVersions)
            )
            let endpoint = try RelayEndpointResolver.endpointURL(
                apiBaseURL: apiBase,
                endpointPath: wire.relayEndpointPath(modelID: modelID),
                securityMode: provider.relayRequested?.securityMode ?? .remoteHTTPS
            )
            guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
                throw ProviderServiceError.invalidConfiguration(detail: "Invalid Relay endpoint URL.")
            }
            var items = (components.queryItems ?? []) + wire.streamQueryItems
            if authMode == .queryKey { items.append(URLQueryItem(name: "key", value: apiKey)) }
            items.append(contentsOf: (provider.relayRequested?.queryParams ?? []).filter { !$0.key.isEmpty }.map {
                URLQueryItem(name: $0.key, value: $0.value)
            })
            components.queryItems = items.isEmpty ? nil : items
            guard let url = components.url else {
                throw ProviderServiceError.invalidConfiguration(detail: "Invalid Relay endpoint URL.")
            }
            return url
        }

        let rawUserBase = provider.baseURLText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let userBase = rawUserBase.flatMap { value in
            value.isEmpty ? nil : (value.hasPrefix("http://") || value.hasPrefix("https://") ? value : "https://\(value)")
        }
        let base = try wire.officialEndpoint(providerKind: provider.kind, userBaseURL: userBase, modelID: modelID)
        guard !wire.streamQueryItems.isEmpty,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base }
        components.queryItems = (components.queryItems ?? []) + wire.streamQueryItems
        return components.url ?? base
    }

    @MainActor
    private static func relayRule(for wire: any ToolLoopLegWire) -> MetadataClient.RelayTransportRule {
        let key = wire.relayTransportKey
        return MetadataClient.shared.syncRelayRuntimeConfig().transportRules[key]
            ?? MetadataClient.RelayRuntimeConfig.fallback.transportRules[key]
            ?? MetadataClient.RelayRuntimeConfig.fallback.transportRules[MetadataClient.RelayTransportKey.openaiChatCompletions]!
    }

    @MainActor
    private static func resolvedAuthMode(provider: Provider, wire: any ToolLoopLegWire) -> RelayAuthMode {
        guard provider.kind == .relay else { return wire.officialAuthMode }
        if let requested = provider.relayRequested?.authMode, requested != .auto { return requested }
        return RelayAuthMode(rawValue: relayRule(for: wire).defaultAuthMode) ?? wire.officialAuthMode
    }

    private static func applyAuthentication(to request: inout URLRequest, mode: RelayAuthMode, apiKey: String) {
        switch mode {
        case .none, .queryKey:
            break
        case .auto, .bearer:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .xApiKey:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        case .xGoogApiKey:
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        }
    }


    private static func removingVisionInput(_ message: ToolLoopMessage) -> ToolLoopMessage {
        var copy = message
        if let parts = message.contentParts {
            let filtered = parts.filter { $0.type != "image_url" }
            copy.contentParts = filtered.isEmpty ? nil : filtered
            if filtered.isEmpty, copy.content == nil { copy.content = "" }
        }
        return copy
    }

    private static func ssePayload(from line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        return String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
    }

    private static func serialized(_ frame: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: frame)
        return String(decoding: data, as: UTF8.self)
    }

    /// Assembled proposals become one `.toolCallDeltas`, each entry a complete call.
    private static func toolCallEvent(_ calls: [ProviderToolCall]) -> ToolLoopLegEvent? {
        guard !calls.isEmpty else { return nil }
        return .toolCallDeltas(calls.enumerated().map { offset, call in
            ToolLoopToolCallDelta(
                index: offset, id: call.providerCallID, type: "function",
                name: call.name, arguments: call.rawArguments, providerSignature: call.providerSignature
            )
        })
    }
}

/// Picks the leg runner and the protocol adapter for a connection's final wire protocol. They come
/// as a pair because the messages the loop feeds back and the request the leg sends must speak the
/// same protocol.
nonisolated enum ToolLoopLegRunnerFactory {
    struct Pair {
        let runner: any ToolLoopLegRunning
        let adapter: any ToolProtocolAdapter
    }

    @MainActor
    static func make(
        provider: Provider,
        model: AIModel,
        modelID: String,
        reasoningMode: ReasoningMode,
        requestOptions: ChatRequestOptions,
        accessToken: String?,
        toolCallMemory: ToolCallMemoryStore,
        session: URLSession = .shared
    ) throws -> Pair {
        let transport = ToolCallCapabilityPolicy.effectiveTransport(provider: provider, model: model)
            ?? TransportKind.openaiChat.rawValue
        guard let adapter = ToolProtocolAdapters.adapter(for: transport) else {
            throw ProviderServiceError.invalidConfiguration(
                detail: "Tools are unavailable for this model or connection."
            )
        }
        if let wire = ToolProtocolAdapters.legWire(for: transport) {
            let runner = try ProtocolToolLoopLegRunner(
                adapter: adapter, wire: wire, provider: provider, model: model, modelID: modelID,
                reasoningMode: reasoningMode, requestOptions: requestOptions, accessToken: accessToken,
                toolCallMemory: toolCallMemory, session: session
            )
            return Pair(runner: runner, adapter: adapter)
        }
        let runner = try OpenAIChatToolLoopLegRunner(
            provider: provider, model: model, modelID: modelID, reasoningMode: reasoningMode,
            requestOptions: requestOptions, accessToken: accessToken,
            toolCallMemory: toolCallMemory, session: session
        )
        return Pair(runner: runner, adapter: adapter)
    }
}
