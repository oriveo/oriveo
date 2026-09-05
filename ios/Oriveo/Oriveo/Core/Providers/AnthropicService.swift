import Foundation

final class AnthropicService: BaseAPIService, ProviderServiceProtocol {
    private let baseURL = "https://api.anthropic.com/v1"


    override func applyHeaders(to request: inout URLRequest, apiKey: String) {
        applyJSONHeaders(to: &request)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    }


    func syncProvider(apiKey: String, preferredModelID: String?) async throws -> ProviderSyncResult {
        try validateAPIKey(apiKey)
        await MetadataClient.shared.ensureInitialized()
        return ProviderSyncResult(models: [])
    }


    func sendMessage(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage]
    ) async throws -> ProviderChatResult {
        try await sendMessage(
            apiKey: apiKey,
            modelID: modelID,
            messages: messages,
            reasoningMode: .automatic
        )
    }

    func sendMessage(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        reasoningMode: ReasoningMode = .automatic,
        webSearchEnabled: Bool = false,
        requestOptions: ChatRequestOptions = ChatRequestOptions()
    ) async throws -> ProviderChatResult {
        try validateAPIKey(apiKey)
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderServiceError.invalidConfiguration(detail: "Missing model identifier.")
        }

        let (data, _) = try await performRawWithUnsupportedParamSelfHeal(
            providerKind: .anthropic,
            modelID: modelID
        ) { droppedParams in
            try buildMessagesRequest(
                modelID: modelID,
                messages: messages,
                apiKey: apiKey,
                stream: false,
                reasoningMode: reasoningMode,
                webSearchEnabled: webSearchEnabled,
                requestOptions: requestOptions,
                droppedParams: droppedParams
            )
        }

        let anthropicResponse: AnthropicChatResponse
        do {
            anthropicResponse = try decoder.decode(AnthropicChatResponse.self, from: data)
        } catch {
            throw ProviderServiceError.network(detail: "Decoding failed: \(error.localizedDescription)")
        }

        // A completed Anthropic response may legally contain only thinking/tool blocks (for
        // example pause_turn). Persist those opaque blocks before deciding whether there is UI text:
        // an explicit continue must still be able to replay the completed protocol leg.
        let continuationRecipe = RecipeContinuationRuntime.selectedRecipe(
            provider: .anthropic, modelID: modelID, transport: "anthropic_messages",
            webSearchEnabled: webSearchEnabled, reasoningMode: reasoningMode,
            continuationKind: "replay_blocks", parser: { $0 == "anthropic_web_search_v1" || $0 == "anthropic_thinking_v1" }
        )
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let blocks = object["content"] as? [[String: Any]],
           let encoded = RecipeContinuationRuntime.jsonValue(blocks) {
            try RecipeContinuationRuntime.save(
                messageID: requestOptions.localContinuationMessageID,
                recipe: continuationRecipe,
                state: ["blocks": encoded]
            )
        }

        let text = anthropicResponse.resolvedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ProviderServiceError.emptyResponse
        }

        let breakdown = Self.parseUsage(anthropicResponse.usage)
        let (cost, source) = await MetadataClient.shared.calcCost(
            breakdown: breakdown, modelID: modelID, providerKind: .anthropic
        )
        return ProviderChatResult(
            text: text,
            promptTokens: breakdown.totalInputTokens,
            completionTokens: breakdown.completionTokens,
            estimatedCost: cost,
            usageBreakdown: breakdown,
            costSource: source
        )
    }

    func sendMessage(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        baseURL: String,
        reasoningMode: ReasoningMode = .automatic,
        requestOptions: ChatRequestOptions = ChatRequestOptions(),
        relayRequested: RelayRequestedConfig? = nil
    ) async throws -> ProviderChatResult {
        try validateAPIKey(apiKey)
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderServiceError.invalidConfiguration(detail: "Missing model identifier.")
        }

        let (data, _) = try await performRawWithUnsupportedParamSelfHeal(
            providerKind: .relay,
            modelID: modelID,
            effectiveTransport: RelayTransport.anthropicMessages.rawValue,
            relayEngineProfile: relayRequested?.engineProfile,
            relayDeclaredProfile: requestOptions.generationProfile
        ) { droppedParams in
            try buildRelayMessagesRequest(
                modelID: modelID,
                messages: messages,
                apiKey: apiKey,
                baseURL: baseURL,
                stream: false,
                reasoningMode: reasoningMode,
                requestOptions: requestOptions,
                relayRequested: relayRequested,
                droppedParams: droppedParams
            )
        }

        let anthropicResponse: AnthropicChatResponse
        do {
            anthropicResponse = try decoder.decode(AnthropicChatResponse.self, from: data)
        } catch {
            throw ProviderServiceError.network(detail: "Decoding failed: \(error.localizedDescription)")
        }

        let text = anthropicResponse.resolvedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ProviderServiceError.emptyResponse
        }

        let breakdown = Self.parseUsage(anthropicResponse.usage)
        return ProviderChatResult(
            text: text,
            promptTokens: breakdown.totalInputTokens,
            completionTokens: breakdown.completionTokens,
            estimatedCost: 0,
            usageBreakdown: breakdown,
            costSource: nil
        )
    }


    func sendMessageStream(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage]
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        sendMessageStream(
            apiKey: apiKey,
            modelID: modelID,
            messages: messages,
            reasoningMode: .automatic
        )
    }

    func sendMessageStream(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        reasoningMode: ReasoningMode = .automatic,
        webSearchEnabled: Bool = false,
        requestOptions: ChatRequestOptions = ChatRequestOptions()
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try self.validateAPIKey(apiKey)
                    guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw ProviderServiceError.invalidConfiguration(detail: "Missing model identifier.")
                    }

                    let request = try self.buildMessagesRequest(
                        modelID: modelID,
                        messages: messages,
                        apiKey: apiKey,
                        stream: true,
                        reasoningMode: reasoningMode,
                        webSearchEnabled: webSearchEnabled,
                        requestOptions: requestOptions
                    )
                    let (bytes, response) = try await self.bytesWithUnsupportedParamSelfHeal(
                        providerKind: .anthropic,
                        modelID: modelID,
                        request: request
                    )

                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw ProviderServiceError.network(detail: "Missing HTTPURLResponse.")
                    }

                    guard (200 ..< 300).contains(httpResponse.statusCode) else {
                        var errorData = Data()
                        for try await byte in bytes { errorData.append(byte) }
                        throw self.mapHTTPError(statusCode: httpResponse.statusCode, data: errorData)
                    }

                    var accumulatedText = ""
                    var startUsage: AnthropicUsage?
                    var outputTokens = 0
                    var currentEvent = ""
                    let antStrategy = TransportRegistry.strategy(for: .anthropicMessages)
                    let resolvedWebProfile = MetadataClient.shared.syncResolveCatalogModel(
                            modelID: modelID,
                            providerKind: .anthropic
                        )?.profiles.webSearch
                    let antShape = webSearchEnabled
                        ? MetadataClient.shared.syncWebSearchStreamShape(profileName: resolvedWebProfile)
                        : nil
                    var antCtx = StreamContext()
                    var antLastCitationsCount = 0
                    var replayBlocks: [Int: [String: Any]] = [:]
                    var replayBlockOrder: [Int] = []
                    var replayInputJSON: [Int: String] = [:]
                    var sawMessageStop = false

                    for try await line in bytes.utf8Lines {
                        if Task.isCancelled { break }

                        if line.hasPrefix("event: ") {
                            currentEvent = String(line.dropFirst(7))
                            continue
                        }

                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        guard let jsonData = payload.data(using: .utf8) else { continue }

                        for ev in antStrategy.parseStreamLine(payload, ctx: &antCtx, shape: antShape) {
                            switch ev {
                            case .reasoning, .toolCallDeltas: continuation.yield(ev)
                            default: break
                            }
                        }
                        let citationsSnapshot = antCtx.citationsAccumulator.citations
                        if citationsSnapshot.count > antLastCitationsCount {
                            antLastCitationsCount = citationsSnapshot.count
                            continuation.yield(.citations(citationsSnapshot))
                        }

                        switch currentEvent {
                        case "content_block_start":
                            if let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                               let index = object["index"] as? Int,
                               let block = object["content_block"] as? [String: Any] {
                                replayBlocks[index] = block
                                replayBlockOrder.append(index)
                            }
                        case "message_start":
                            if let msg = try? self.decoder.decode(AnthropicMessageStart.self, from: jsonData) {
                                startUsage = msg.message?.usage
                                outputTokens = msg.message?.usage?.output_tokens ?? 0
                            }
                        case "content_block_delta":
                            if let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                               let index = object["index"] as? Int,
                               let delta = object["delta"] as? [String: Any] {
                                Self.mergeReplayDelta(delta, into: &replayBlocks[index], inputJSON: &replayInputJSON[index])
                            }
                            if let delta = try? self.decoder.decode(AnthropicContentBlockDelta.self, from: jsonData),
                               let text = delta.delta?.text, !text.isEmpty {
                                accumulatedText += text
                                continuation.yield(.delta(text))
                            }
                        case "message_delta":
                            if let delta = try? self.decoder.decode(AnthropicMessageDelta.self, from: jsonData) {
                                outputTokens = delta.usage?.output_tokens ?? outputTokens
                            }
                        case "message_stop":
                            sawMessageStop = true
                        default:
                            break
                        }

                        currentEvent = ""
                    }
                    for ev in AnthropicMessagesStrategy.flushToolCalls(ctx: &antCtx) { continuation.yield(ev) }

                    let finalText = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let continuationRecipe = RecipeContinuationRuntime.selectedRecipe(
                        provider: .anthropic, modelID: modelID, transport: "anthropic_messages",
                        webSearchEnabled: webSearchEnabled, reasoningMode: reasoningMode,
                        continuationKind: "replay_blocks", parser: { $0 == "anthropic_web_search_v1" || $0 == "anthropic_thinking_v1" }
                    )
                    if !Task.isCancelled, sawMessageStop,
                       let blocks = Self.completeReplayBlocks(
                            blocks: replayBlocks, order: replayBlockOrder, inputJSON: replayInputJSON
                       ), let encoded = RecipeContinuationRuntime.jsonValue(blocks) {
                        try RecipeContinuationRuntime.save(
                            messageID: requestOptions.localContinuationMessageID,
                            recipe: continuationRecipe,
                            state: ["blocks": encoded]
                        )
                    }
                    var finalUsage = startUsage ?? AnthropicUsage(input_tokens: 0, output_tokens: 0)
                    finalUsage.output_tokens = outputTokens
                    let breakdown = Self.parseUsage(finalUsage)
                    let (cost, source) = await MetadataClient.shared.calcCost(
                        breakdown: breakdown, modelID: modelID, providerKind: .anthropic
                    )
                    let result = ProviderChatResult(
                        text: finalText,
                        promptTokens: breakdown.totalInputTokens,
                        completionTokens: breakdown.completionTokens,
                        estimatedCost: cost,
                        usageBreakdown: breakdown,
                        costSource: source
                    )
                    continuation.yield(.done(result))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func sendMessageStream(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        baseURL: String,
        reasoningMode: ReasoningMode = .automatic,
        requestOptions: ChatRequestOptions = ChatRequestOptions(),
        relayRequested: RelayRequestedConfig? = nil
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try self.validateAPIKey(apiKey)
                    guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw ProviderServiceError.invalidConfiguration(detail: "Missing model identifier.")
                    }

                    let request = try self.buildRelayMessagesRequest(
                        modelID: modelID,
                        messages: messages,
                        apiKey: apiKey,
                        baseURL: baseURL,
                        stream: true,
                        reasoningMode: reasoningMode,
                        requestOptions: requestOptions,
                        relayRequested: relayRequested
                    )
                    let (bytes, response) = try await self.bytesWithUnsupportedParamSelfHeal(
                        providerKind: .relay,
                        modelID: modelID,
                        request: request,
                        effectiveTransport: RelayTransport.anthropicMessages.rawValue,
                        relayEngineProfile: relayRequested?.engineProfile,
                        relayDeclaredProfile: requestOptions.generationProfile
                    )

                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw ProviderServiceError.network(detail: "Missing HTTPURLResponse.")
                    }

                    guard (200 ..< 300).contains(httpResponse.statusCode) else {
                        var errorData = Data()
                        for try await byte in bytes { errorData.append(byte) }
                        throw self.mapHTTPError(statusCode: httpResponse.statusCode, data: errorData)
                    }

                    var accumulatedText = ""
                    var startUsage: AnthropicUsage?
                    var outputTokens = 0
                    var currentEvent = ""
                    let relayStrategy = TransportRegistry.strategy(for: .anthropicMessages)
                    let relayShape = self.resolveRelayWebSearchShape(
                        modelID: modelID,
                        relayRequested: relayRequested
                    )
                    var relayCtx = StreamContext()
                    var relayLastCitationsCount = 0

                    for try await line in bytes.utf8Lines {
                        if Task.isCancelled { break }

                        if line.hasPrefix("event: ") {
                            currentEvent = String(line.dropFirst(7))
                            continue
                        }

                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        guard let jsonData = payload.data(using: .utf8) else { continue }

                        for ev in relayStrategy.parseStreamLine(payload, ctx: &relayCtx, shape: relayShape) {
                            switch ev {
                            case .reasoning, .toolCallDeltas: continuation.yield(ev)
                            default: break
                            }
                        }
                        let citationsSnapshot = relayCtx.citationsAccumulator.citations
                        if citationsSnapshot.count > relayLastCitationsCount {
                            relayLastCitationsCount = citationsSnapshot.count
                            continuation.yield(.citations(citationsSnapshot))
                        }

                        switch currentEvent {
                        case "message_start":
                            if let msg = try? self.decoder.decode(AnthropicMessageStart.self, from: jsonData) {
                                startUsage = msg.message?.usage
                                outputTokens = msg.message?.usage?.output_tokens ?? 0
                            }
                        case "content_block_delta":
                            if let delta = try? self.decoder.decode(AnthropicContentBlockDelta.self, from: jsonData),
                               let text = delta.delta?.text, !text.isEmpty {
                                accumulatedText += text
                                continuation.yield(.delta(text))
                            }
                        case "message_delta":
                            if let delta = try? self.decoder.decode(AnthropicMessageDelta.self, from: jsonData) {
                                outputTokens = delta.usage?.output_tokens ?? outputTokens
                            }
                        case "message_stop":
                            break
                        default:
                            break
                        }

                        currentEvent = ""
                    }
                    for ev in AnthropicMessagesStrategy.flushToolCalls(ctx: &relayCtx) { continuation.yield(ev) }

                    let finalText = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    var finalUsage = startUsage ?? AnthropicUsage(input_tokens: 0, output_tokens: 0)
                    finalUsage.output_tokens = outputTokens
                    let breakdown = Self.parseUsage(finalUsage)
                    let (cost, source) = await MetadataClient.shared.calcCost(
                        breakdown: breakdown, modelID: modelID, providerKind: .anthropic
                    )
                    let result = ProviderChatResult(
                        text: finalText,
                        promptTokens: breakdown.totalInputTokens,
                        completionTokens: breakdown.completionTokens,
                        estimatedCost: cost,
                        usageBreakdown: breakdown,
                        costSource: source
                    )
                    continuation.yield(.done(result))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func resolveRelayWebSearchShape(
        modelID: String,
        relayRequested: RelayRequestedConfig?
    ) -> MetadataClient.StreamShape? {
        if let explicit = relayRequested?.webSearchProfile?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty,
           let shape = MetadataClient.shared.syncWebSearchStreamShape(profileName: explicit) {
            return shape
        }
        let fallback = MetadataClient.shared.syncResolveCatalogModel(
            modelID: modelID,
            providerKind: .anthropic
        )?.profiles.webSearch
        return MetadataClient.shared.syncWebSearchStreamShape(profileName: fallback)
    }


    private func buildMessagesRequest(
        modelID: String,
        messages: [ChatMessage],
        apiKey: String,
        stream: Bool,
        reasoningMode: ReasoningMode,
        webSearchEnabled: Bool,
        requestOptions: ChatRequestOptions = ChatRequestOptions(),
        droppedParams: Set<String> = []
    ) throws -> URLRequest {
        let metadataTransport = MetadataClient.shared.syncProviderTransport(providerKind: .anthropic)
        let metadataBase = EndpointResolver.officialMetadataBaseURL(
            providerKind: .anthropic,
            metadataTransport: metadataTransport
        )
        let endpointBase = metadataBase ?? EndpointResolver.fallbackBaseURL(for: .anthropic)
        let endpointPath = metadataTransport?.endpoints?.chat
            ?? EndpointResolver.fallbackEndpointPath(.anthropic, kind: .chat)
        guard let endpointURL = EndpointResolver.joinURL(base: endpointBase, path: endpointPath) else {
            throw ProviderServiceError.invalidConfiguration(detail: "Invalid Anthropic endpoint.")
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = stream ? 120 : 60
        applyHeaders(to: &request, apiKey: apiKey)

        let systemPrompt = requestOptions.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = MetadataClient.shared.syncResolveCatalogModel(modelID: modelID, providerKind: .anthropic)
        let recipeLegacyInput = CapabilityRecipeRequestCompiler.legacyInput(
            providerKind: .anthropic, modelID: modelID,
            webSearchEnabled: webSearchEnabled, reasoningMode: reasoningMode
        )
        let continuationRecipe = RecipeContinuationRuntime.selectedRecipe(
            provider: .anthropic, modelID: modelID, transport: resolved?.transport ?? "",
            webSearchEnabled: webSearchEnabled, reasoningMode: reasoningMode,
            continuationKind: "replay_blocks", parser: { $0 == "anthropic_web_search_v1" || $0 == "anthropic_thinking_v1" }
        )
        let replayBlocks = continuationRecipe.flatMap { _ in
            RecipeContinuationRuntime.replayBlocks(
                explicitMessageID: requestOptions.localExplicitContinuationMessageID
            )
        }
        // ChatRequestBuilder includes the partial target assistant before its final continue user.
        // A complete opaque replay replaces that partial leg; absence/corruption leaves the normal
        // clean-restart history untouched.
        let requestMessagesInput = replayBlocks == nil ? messages : messages.filter {
            $0.id != requestOptions.localExplicitContinuationMessageID
        }
        let capabilityIntent = CapabilityEvidenceProductionAdapter.finalChatIntent(
            messages: requestMessagesInput, request: request,
            effectiveTransport: resolved?.transport ?? "",
            model: requestOptions.capabilityEvidenceModel,
            requestedReasoningMode: recipeLegacyInput.reasoningMode,
            webSearchEnabled: recipeLegacyInput.webSearchEnabled
        )
        let defaultMaxTokens = resolved?.maxOutputTokens.flatMap { $0 > 0 ? $0 : nil } ?? 8192
        let payload = AnthropicChatRequest(
            model: modelID,
            max_tokens: defaultMaxTokens,
            system: systemPrompt.isEmpty ? nil : systemPrompt,
            stream: stream ? true : nil,
            cache_control: .init(type: "ephemeral"),
            thinking: nil,
            output_config: nil,
            messages: capabilityIntent.outboundMessages.map { Self.buildRequestMessage($0) }
        )
        var body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any] ?? [:]
        if capabilityIntent.webSearchEnabled,
           let webMerge = ProfileParamsResolver.webSearchMergeParams(
            providerKind: .anthropic,
            modelID: modelID,
            profileName: resolved?.profiles.webSearch,
            droppedParams: droppedParams
           ) {
            ProfileParamsResolver.deepMerge(&body, webMerge)
        }
        if recipeLegacyInput.usesLegacyMapping,
           let allowedReasoningMode = capabilityIntent.reasoningMode,
           let reasoningMerge = ProfileParamsResolver.reasoningMergeParams(
            providerKind: .anthropic,
            modelID: modelID,
            reasoningMode: allowedReasoningMode,
            resolved: resolved,
            droppedParams: droppedParams
        ) {
            ProfileParamsResolver.deepMerge(&body, reasoningMerge)
        }
        ProfileParamsResolver.applyTemperatureGate(to: &body, resolved: resolved)
        ProfileParamsResolver.applyGenerationParameters(
            to: &body,
            options: requestOptions,
            profile: resolved?.generationProfile,
            finalRequest: request,
            effectiveTransport: resolved?.transport
        )
        CapabilityRecipeRequestCompiler.apply(
            to: &body, providerKind: .anthropic, modelID: modelID,
            transport: resolved?.transport ?? "", webSearchEnabled: webSearchEnabled,
            reasoningMode: reasoningMode, capabilityPreferences: requestOptions.capabilityPreferences
        )
        if let blocks = replayBlocks {
            var requestMessages = body["messages"] as? [[String: Any]] ?? []
            // The continuation instruction is the final user turn. The replay must precede it;
            // appending after it produces an invalid Anthropic conversation order.
            let instruction = requestMessages.last
            if instruction?["role"] as? String == "user" { requestMessages.removeLast() }
            requestMessages.append(["role": "assistant", "content": blocks])
            if let instruction { requestMessages.append(instruction) }
            body["messages"] = requestMessages
        }
        try CapabilityRecipeExecution.applySafeCustomFragments(
            requestOptions.localSafeCustomBodyFragments, to: &body,
            providerKind: .anthropic, modelID: modelID,
            transport: resolved?.transport ?? "anthropic_messages"
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        CapabilityExecutionRuntime.confirmFinalWireEncoded()
        return request
    }

    private func buildRelayMessagesRequest(
        modelID: String,
        messages: [ChatMessage],
        apiKey: String,
        baseURL: String,
        stream: Bool,
        reasoningMode: ReasoningMode,
        requestOptions: ChatRequestOptions = ChatRequestOptions(),
        relayRequested: RelayRequestedConfig? = nil,
        droppedParams: Set<String> = []
    ) throws -> URLRequest {
        let baseString = try RelayEndpointResolver.runtimeAPIBaseURL(
            rawBaseURL: baseURL,
            relayRequested: relayRequested,
            defaultVersion: "v1",
            acceptedVersions: ["v1"]
        )
        let base = try RelayEndpointResolver.endpointURL(apiBaseURL: baseString, endpointPath: "/messages")

        let finalURL: URL
        if let relayRequested,
           let queryParams = relayRequested.effectiveQueryParams,
           !queryParams.isEmpty,
           var components = URLComponents(url: base, resolvingAgainstBaseURL: false) {
            let items = queryParams.map { URLQueryItem(name: $0.key, value: $0.value) }
            components.queryItems = (components.queryItems ?? []) + items
            finalURL = components.url ?? base
        } else {
            finalURL = base
        }

        var request = URLRequest(url: finalURL)
        request.httpMethod = "POST"
        request.timeoutInterval = stream ? 120 : 60
        applyRelayHeaders(to: &request, apiKey: apiKey, relayRequested: relayRequested)
        for header in relayRequested?.effectiveHeaders ?? [] {
            request.setValue(header.value, forHTTPHeaderField: header.key)
        }
        let capabilityIntent = CapabilityEvidenceProductionAdapter.finalChatIntent(
            messages: messages, request: request,
            effectiveTransport: RelayTransport.anthropicMessages.rawValue,
            model: requestOptions.capabilityEvidenceModel,
            requestedReasoningMode: reasoningMode,
            webSearchEnabled: false
        )

        let lowered = modelID.lowercased()
        let usesAdaptiveThinking =
            lowered.contains("sonnet-4-6") || lowered.contains("sonnet-4.6") // heuristic-allow: Relay Anthropic-compatible fallback only; official Anthropic uses metadata profiles.
            || lowered.contains("opus-4-6") || lowered.contains("opus-4.6") // heuristic-allow: Relay Anthropic-compatible fallback only; official Anthropic uses metadata profiles.
        let shouldDropThinking = droppedParams.contains("thinking")
        let shouldDropOutputConfig = droppedParams.contains("output_config")
        let thinking: AnthropicChatRequest.Thinking?
        let outputConfig: AnthropicChatRequest.OutputConfig?
        if shouldDropThinking {
            thinking = nil
            outputConfig = nil
        } else if let allowedReasoningMode = capabilityIntent.reasoningMode,
                  usesAdaptiveThinking,
                  let effort = Self.relayAnthropicAdaptiveEffort(allowedReasoningMode, for: modelID) {
            thinking = .init(type: "adaptive")
            outputConfig = shouldDropOutputConfig ? nil : .init(effort: effort)
        } else if let allowedReasoningMode = capabilityIntent.reasoningMode,
                  let budgetTokens = Self.relayAnthropicBudgetTokens(allowedReasoningMode) {
            thinking = .init(type: "enabled", budget_tokens: budgetTokens)
            outputConfig = nil
        } else {
            thinking = nil
            outputConfig = nil
        }

        let systemPrompt = requestOptions.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedMaxTokens = max(
            8192,
            (capabilityIntent.reasoningMode.flatMap(Self.relayAnthropicBudgetTokens) ?? 0) + 4096
        )
        let payload = AnthropicChatRequest(
            model: modelID,
            max_tokens: resolvedMaxTokens,
            system: systemPrompt.isEmpty ? nil : systemPrompt,
            stream: stream ? true : nil,
            cache_control: nil,
            thinking: thinking,
            output_config: outputConfig,
            messages: capabilityIntent.outboundMessages.map { Self.buildRequestMessage($0) }
        )
        var body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any] ?? [:]
        ProfileParamsResolver.applyGenerationParameters(
            to: &body,
            options: requestOptions,
            finalRequest: request,
            effectiveTransport: RelayTransport.anthropicMessages.rawValue
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        CapabilityExecutionRuntime.confirmFinalWireEncoded()
        return request
    }

    private static func relayAnthropicBudgetTokens(_ mode: ReasoningMode) -> Int? {
        switch mode {
        case .automatic: return nil
        case .fast: return 2_048
        case .balanced: return 8_192
        case .deep: return 16_384
        case .max: return 24_576
        }
    }

    private static func relayAnthropicAdaptiveEffort(_ mode: ReasoningMode, for modelID: String) -> String? {
        guard mode != .automatic else { return nil }
        switch mode {
        case .fast: return "low"
        case .balanced: return "medium"
        case .deep: return "high"
        case .max: return modelID.lowercased().contains("opus") ? "max" : "high" // heuristic-allow: Relay Anthropic-compatible fallback only; official Anthropic uses metadata profiles.
        case .automatic: return nil
        }
    }

    private func applyRelayHeaders(
        to request: inout URLRequest,
        apiKey: String,
        relayRequested: RelayRequestedConfig?
    ) {
        request.applyRelaySecurityMode(relayRequested)
        applyJSONHeaders(to: &request)
        let resolvedAuth = resolveRelayAuthMode(relayRequested)
        switch resolvedAuth {
        case .none:
            break
        case .xApiKey, .auto:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        case .bearer:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .queryKey, .xGoogApiKey:
            break
        }
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        guard resolvedAuth != .none else { return }
        if let ua = relayRequested?.effectiveCustomUserAgent?.trimmingCharacters(in: .whitespacesAndNewlines),
           !ua.isEmpty {
            request.setValue(ua, forHTTPHeaderField: "User-Agent")
        }
    }

    private func resolveRelayAuthMode(_ relayRequested: RelayRequestedConfig?) -> RelayAuthMode {
        guard let relayRequested else { return .xApiKey }
        if relayRequested.authMode != .auto {
            return relayRequested.authMode
        }
        return .xApiKey
    }

    private static func versionedRelayBaseURL(
        _ rawBaseURL: String,
        defaultVersion: String,
        acceptedVersions: Set<String>
    ) -> String {
        let trimmed = rawBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        let baseString = normalized.hasPrefix("http") ? normalized : "https://\(normalized)"
        guard let url = URL(string: baseString) else { return baseString }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let segments = path.split(separator: "/").map(String.init)
        if segments.contains(where: acceptedVersions.contains) {
            return baseString
        }
        let versionedPath = path.isEmpty ? defaultVersion : "\(path)/\(defaultVersion)"
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path = "/" + versionedPath
        components?.query = nil
        components?.fragment = nil
        return components?.url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? "\(baseString)/\(defaultVersion)"
    }

    private static func buildRequestMessage(_ msg: ChatMessage, model: AIModel? = nil) -> AnthropicChatRequest.Message {
        let role = msg.role == .assistant ? "assistant" : "user"

        guard let atts = msg.attachments, !atts.isEmpty else {
            return .init(role: role, content: .text(msg.text))
        }

        let imageAtts = atts.filter { $0.kind == .image }
        let fileAtts = atts.filter { $0.kind == .file }

        let (nativeAtts, textFileAtts) = BaseAPIService.partitionAttachmentsByRoute(
            fileAtts, provider: .anthropic, model: model
        )

        let (combinedText, _) = BaseAPIService.injectFileAttachmentsAsText(
            userText: msg.text,
            attachments: textFileAtts,
            provider: .anthropic,
            model: model
        )

        guard !imageAtts.isEmpty || !nativeAtts.isEmpty else {
            return .init(role: role, content: .text(combinedText))
        }

        let cache = AnthropicChatRequest.ContentBlock.CacheControl(type: "ephemeral")
        var contentBlocks: [AnthropicChatRequest.ContentBlock] = [
            .init(type: "text", text: combinedText)
        ]
        for a in imageAtts {
            let b64 = a.resolvedBase64Data
            guard !b64.isEmpty else { continue }
            contentBlocks.append(.init(
                type: "image",
                source: .init(type: "base64", media_type: a.mimeType, data: b64),
                cache_control: cache
            ))
        }
        for f in nativeAtts {
            if let base64 = f.originalBase64Data, !base64.isEmpty {
                contentBlocks.append(.init(
                    type: "document",
                    source: .init(type: "base64", media_type: f.mimeType, data: base64),
                    cache_control: cache
                ))
            }
        }
        return .init(role: role, content: .blocks(contentBlocks))
    }


    private static let knownTextModelIDs = [
        "claude-sonnet-4-20250514",
        "claude-3-5-haiku-20241022",
    ]

    private func buildModels(from remoteModels: [AnthropicMetadataModel], preferredModelID: String?) async -> [AIModel] {
        let normalizedPreferredID = preferredModelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        var models: [AIModel] = []
        models.reserveCapacity(remoteModels.count)

        for remote in remoteModels {
            var model = await CatalogModelBuilder.buildCatalogModel(
                providerKind: .anthropic,
                runtimeModelId: remote.id,
                fallbackName: remote.id,
                fallbackContextLength: nil,
                createdAt: nil
            )
            if normalizedPreferredID == remote.id {
                model.isDefault = true
            }
            models.append(model)
        }

        models.sort(by: catalogModelSort)

        if let normalizedPreferredID, models.contains(where: { $0.id == normalizedPreferredID }) {
            return models
        }

        return selectDefaultBySortRank(models)
    }

    /// Keeps the opaque server blocks byte-for-byte at field level while the SSE
    /// response is assembled. Unknown delta shapes deliberately make the replay
    /// unavailable instead of manufacturing a block the next request cannot use.
    private static func mergeReplayDelta(
        _ delta: [String: Any], into replayBlock: inout [String: Any]?, inputJSON: inout String?
    ) {
        guard var block = replayBlock else { return }
        if let text = delta["text"] as? String {
            block["text"] = (block["text"] as? String ?? "") + text
        } else if let thinking = delta["thinking"] as? String {
            block["thinking"] = (block["thinking"] as? String ?? "") + thinking
        } else if let signature = delta["signature"] as? String {
            block["signature"] = (block["signature"] as? String ?? "") + signature
        } else if let partialJSON = delta["partial_json"] as? String {
            inputJSON = (inputJSON ?? "") + partialJSON
        } else {
            // Preserve an explicit invalid marker; completeReplayBlocks rejects it.
            block["__oriveo_invalid_replay_delta"] = true
        }
        replayBlock = block
    }

    private static func completeReplayBlocks(
        blocks: [Int: [String: Any]], order: [Int], inputJSON: [Int: String]
    ) -> [[String: Any]]? {
        guard order.count == Set(order).count else { return nil }
        var completed: [[String: Any]] = []
        for index in order {
            guard var block = blocks[index], block["__oriveo_invalid_replay_delta"] == nil,
                  let type = block["type"] as? String, !type.isEmpty else { return nil }
            if let rawInput = inputJSON[index] {
                guard let inputData = rawInput.data(using: .utf8),
                      let input = try? JSONSerialization.jsonObject(with: inputData) else { return nil }
                block["input"] = input
            }
            completed.append(block)
        }
        return completed.isEmpty ? nil : completed
    }
}


private struct AnthropicMetadataModel {
    var id: String
}


private struct AnthropicChatRequest: Encodable {
    var model: String
    var max_tokens: Int
    var system: String?
    var stream: Bool?
    var cache_control: CacheControl?
    var thinking: Thinking?
    var output_config: OutputConfig?
    var messages: [Message]

    struct Message: Encodable {
        var role: String
        var content: MessageContent
    }

    struct Thinking: Encodable {
        var type: String
        var budget_tokens: Int? = nil
    }

    struct OutputConfig: Encodable {
        var effort: String
    }

    struct CacheControl: Encodable {
        var type: String
    }

    enum MessageContent: Encodable {
        case text(String)
        case blocks([ContentBlock])

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let s): try container.encode(s)
            case .blocks(let b): try container.encode(b)
            }
        }
    }

    struct ContentBlock: Encodable {
        var type: String
        var text: String?
        var source: Source?
        var cache_control: CacheControl?

        struct Source: Encodable {
            var type: String       // "base64"
            var media_type: String // "image/png", "application/pdf"
            var data: String
        }

        struct CacheControl: Encodable {
            var type: String
        }

        private enum CodingKeys: String, CodingKey {
            case type, text, source, cache_control
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(type, forKey: .type)
            if let text { try container.encode(text, forKey: .text) }
            if let source { try container.encode(source, forKey: .source) }
            if let cache_control { try container.encode(cache_control, forKey: .cache_control) }
        }
    }
}

private struct AnthropicChatResponse: Decodable {
    var content: [ContentBlock]?
    var usage: AnthropicUsage?

    struct ContentBlock: Decodable {
        var type: String?
        var text: String?
    }

    var resolvedText: String {
        content?
            .filter { $0.type == "text" }
            .compactMap { $0.text }
            .joined() ?? ""
    }
}

private struct AnthropicUsage: Decodable {
    var input_tokens: Int?
    var output_tokens: Int?
    var cache_read_input_tokens: Int?
    var cache_creation_input_tokens: Int?
    var cache_creation: CacheCreation?

    struct CacheCreation: Decodable {
        var ephemeral_5m_input_tokens: Int?
        var ephemeral_1h_input_tokens: Int?

        init(ephemeral_5m_input_tokens: Int? = nil, ephemeral_1h_input_tokens: Int? = nil) {
            self.ephemeral_5m_input_tokens = ephemeral_5m_input_tokens
            self.ephemeral_1h_input_tokens = ephemeral_1h_input_tokens
        }
    }

    init(
        input_tokens: Int? = nil,
        output_tokens: Int? = nil,
        cache_read_input_tokens: Int? = nil,
        cache_creation_input_tokens: Int? = nil,
        cache_creation: CacheCreation? = nil
    ) {
        self.input_tokens = input_tokens
        self.output_tokens = output_tokens
        self.cache_read_input_tokens = cache_read_input_tokens
        self.cache_creation_input_tokens = cache_creation_input_tokens
        self.cache_creation = cache_creation
    }
}

private struct AnthropicMessageStart: Decodable {
    var message: MessageInfo?

    struct MessageInfo: Decodable {
        var usage: AnthropicUsage?
    }
}

private struct AnthropicContentBlockDelta: Decodable {
    var delta: Delta?

    struct Delta: Decodable {
        var type: String?
        var text: String?
    }
}

private struct AnthropicMessageDelta: Decodable {
    var delta: Delta?
    var usage: AnthropicUsage?

    struct Delta: Decodable {
        var stop_reason: String?
    }
}

extension AnthropicService {
    fileprivate static func parseUsage(_ usage: AnthropicUsage?) -> UsageBreakdown {
        guard let usage else { return UsageBreakdown() }
        let cc = usage.cache_creation
        let write5m = cc?.ephemeral_5m_input_tokens
            ?? usage.cache_creation_input_tokens
            ?? 0
        let write1h = cc?.ephemeral_1h_input_tokens ?? 0
        return UsageBreakdown(
            promptTokens: usage.input_tokens ?? 0,
            cachedInputTokens: usage.cache_read_input_tokens ?? 0,
            cacheCreation5mTokens: write5m,
            cacheCreation1hTokens: write1h,
            completionTokens: usage.output_tokens ?? 0,
            reasoningTokens: 0,
            upstreamCost: nil,
            cacheReadObserved: usage.cache_read_input_tokens != nil,
            cacheWriteObserved: usage.cache_creation_input_tokens != nil
                || usage.cache_creation?.ephemeral_5m_input_tokens != nil
                || usage.cache_creation?.ephemeral_1h_input_tokens != nil
        )
    }

    #if DEBUG
    static func parseUsageForTesting(
        inputTokens: Int?,
        outputTokens: Int?,
        cacheRead: Int?,
        ephemeral5m: Int?,
        ephemeral1h: Int?,
        legacyCacheCreation: Int?
    ) -> UsageBreakdown {
        let cc: AnthropicUsage.CacheCreation?
        if ephemeral5m != nil || ephemeral1h != nil {
            cc = AnthropicUsage.CacheCreation(
                ephemeral_5m_input_tokens: ephemeral5m,
                ephemeral_1h_input_tokens: ephemeral1h
            )
        } else {
            cc = nil
        }
        let usage = AnthropicUsage(
            input_tokens: inputTokens,
            output_tokens: outputTokens,
            cache_read_input_tokens: cacheRead,
            cache_creation_input_tokens: legacyCacheCreation,
            cache_creation: cc
        )
        return parseUsage(usage)
    }
    #endif
}
