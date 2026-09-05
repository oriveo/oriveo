import Foundation

final class GrokService: BaseAPIService, ProviderServiceProtocol {
    private let baseURL = "https://api.x.ai/v1"

    static let grokTicksPerUSD: Double = 10_000_000_000

    func syncProvider(apiKey: String, preferredModelID: String?) async throws -> ProviderSyncResult {
        try validateAPIKey(apiKey)
        await MetadataClient.shared.ensureInitialized()
        return ProviderSyncResult(models: [])
    }

    func sendMessage(apiKey: String, modelID: String, messages: [ChatMessage]) async throws -> ProviderChatResult {
        try await sendMessage(apiKey: apiKey, modelID: modelID, messages: messages, reasoningMode: .automatic)
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
        await MetadataClient.shared.ensureInitialized()
        let resolved = MetadataClient.shared.syncResolveCatalogModel(modelID: modelID, providerKind: .grok)

        if let subscription = requestOptions.grokSubscription, subscription.usesResponses {
            let request = try buildSubscriptionResponsesRequest(
                modelID: modelID, messages: messages, apiKey: apiKey, subscription: subscription,
                stream: false, reasoningMode: reasoningMode, webSearchEnabled: webSearchEnabled,
                requestOptions: requestOptions
            )
            let data: Data
            do {
                CapabilityExecutionRuntime.confirmRequestDispatched()
                let (raw, response) = try await session.relayData(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw ProviderServiceError.network(detail: "Missing HTTPURLResponse.")
                }
                guard (200 ..< 300).contains(http.statusCode) else {
                    throw mapHTTPError(
                        statusCode: http.statusCode, data: raw,
                        url: request.url, request: request, subscriptionLane: .grok
                    )
                }
                data = raw
            } catch let error as ProviderServiceError {
                throw error
            } catch {
                throw ProviderServiceError.network(detail: error.localizedDescription)
            }
            let response = try decoder.decode(GrokResponsesResponse.self, from: data)
            let text = response.resolvedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw ProviderServiceError.emptyResponse }
            let breakdown = Self.parseResponsesUsage(response.usage)
            return ProviderChatResult(
                text: text,
                promptTokens: breakdown.totalInputTokens,
                completionTokens: breakdown.completionTokens,
                estimatedCost: 0,
                usageBreakdown: breakdown,
                costSource: .subscription
            )
        }

        if requestOptions.grokSubscription == nil,
           Self.transportKind(for: resolved) == .openaiResponses {
            let (data, _) = try await performRawWithUnsupportedParamSelfHeal(
                providerKind: .grok,
                modelID: modelID
            ) { droppedParams in
                try buildResponsesRequest(
                    modelID: modelID,
                    messages: messages,
                    apiKey: apiKey,
                    stream: false,
                    reasoningMode: reasoningMode,
                    webSearchEnabled: webSearchEnabled,
                    requestOptions: requestOptions,
                    droppedParams: droppedParams,
                    resolved: resolved
                )
            }
            let response = try decoder.decode(GrokResponsesResponse.self, from: data)
            let text = response.resolvedText.trimmingCharacters(in: .whitespacesAndNewlines)
            try RecipeContinuationRuntime.save(
                messageID: requestOptions.localContinuationMessageID,
                recipe: Self.responsesPreviousIDRecipe(
                    modelID: modelID, reasoningMode: reasoningMode,
                    webSearchEnabled: webSearchEnabled
                ),
                state: response.id.map { ["previousResponseId": .string($0)] } ?? [:]
            )
            // A completed Responses turn may legitimately be tool/reasoning-only. Persist its
            // opaque response id before the UI-facing empty-text decision so explicit continuation
            guard !text.isEmpty else { throw ProviderServiceError.emptyResponse }
            let breakdown = Self.parseResponsesUsage(response.usage)
            let (cost, source) = await resolveGrokCost(
                breakdown: breakdown, modelID: modelID,
                subscription: requestOptions.grokSubscription
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

        let (data, _) = try await performRawWithUnsupportedParamSelfHeal(
            providerKind: .grok,
            modelID: modelID
        ) { droppedParams in
            try buildChatRequest(
                modelID: modelID,
                messages: messages,
                apiKey: apiKey,
                stream: false,
                reasoningMode: reasoningMode,
                webSearchEnabled: webSearchEnabled,
                requestOptions: requestOptions,
                droppedParams: droppedParams,
                resolved: resolved
            )
        }
        let response = try decoder.decode(GrokChatCompletionResponse.self, from: data)
        guard let choice = response.choices.first else { throw ProviderServiceError.emptyResponse }
        let text = (choice.message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ProviderServiceError.emptyResponse }

        let breakdown = Self.parseUsage(response.usage)
        let (cost, source) = await resolveGrokCost(
            breakdown: breakdown, modelID: modelID,
            subscription: requestOptions.grokSubscription
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

    func sendMessageStream(apiKey: String, modelID: String, messages: [ChatMessage]) -> AsyncThrowingStream<StreamEvent, Error> {
        sendMessageStream(apiKey: apiKey, modelID: modelID, messages: messages, reasoningMode: .automatic)
    }

    func sendMessageStream(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        reasoningMode: ReasoningMode = .automatic,
        webSearchEnabled: Bool = false,
        requestOptions: ChatRequestOptions = ChatRequestOptions()
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        grokStreamCore(
            apiKey: apiKey, modelID: modelID, messages: messages,
            reasoningMode: reasoningMode, requestOptions: requestOptions,
            webSearchEnabled: webSearchEnabled
        )
    }

    private func grokStreamCore(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        reasoningMode: ReasoningMode,
        requestOptions: ChatRequestOptions,
        webSearchEnabled: Bool
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try self.validateAPIKey(apiKey)
                    guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw ProviderServiceError.invalidConfiguration(detail: "Missing model identifier.")
                    }
                    await MetadataClient.shared.ensureInitialized()
                    let resolved = MetadataClient.shared.syncResolveCatalogModel(modelID: modelID, providerKind: .grok)
                    if let subscription = requestOptions.grokSubscription, subscription.usesResponses {
                        let request = try self.buildSubscriptionResponsesRequest(
                            modelID: modelID, messages: messages, apiKey: apiKey, subscription: subscription,
                            stream: true, reasoningMode: reasoningMode, webSearchEnabled: webSearchEnabled,
                            requestOptions: requestOptions
                        )
                        try await self.consumeResponsesStream(
                            request: request,
                            modelID: modelID,
                            resolved: nil,
                            reasoningMode: reasoningMode,
                            webSearchEnabled: webSearchEnabled,
                            requestOptions: requestOptions,
                            subscriptionLane: .grok,
                            continuation: continuation
                        )
                        continuation.finish()
                        return
                    }
                    if requestOptions.grokSubscription == nil,
                       Self.transportKind(for: resolved) == .openaiResponses {
                        let request = try self.buildResponsesRequest(
                            modelID: modelID,
                            messages: messages,
                            apiKey: apiKey,
                            stream: true,
                            reasoningMode: reasoningMode,
                            webSearchEnabled: webSearchEnabled,
                            requestOptions: requestOptions,
                            resolved: resolved
                        )
                        try await self.consumeResponsesStream(
                            request: request,
                            modelID: modelID,
                            resolved: resolved,
                            reasoningMode: reasoningMode,
                            webSearchEnabled: webSearchEnabled,
                            requestOptions: requestOptions,
                            continuation: continuation
                        )
                        continuation.finish()
                        return
                    }
                    let request = try self.buildChatRequest(
                        modelID: modelID, messages: messages, apiKey: apiKey, stream: true,
                        reasoningMode: reasoningMode, webSearchEnabled: webSearchEnabled,
                        requestOptions: requestOptions,
                        resolved: resolved
                    )
                    let (bytes, _) = try await self.bytesWithUnsupportedParamSelfHeal(
                        providerKind: .grok,
                        modelID: modelID,
                        request: request,
                        effectiveTransport: TransportKind.openaiChat.rawValue,
                        subscriptionLane: requestOptions.grokSubscription == nil ? nil : .grok
                    )

                    var accumulatedText = ""
                    var lastUsage: GrokUsage?
                    let grokStrategy = TransportRegistry.strategy(for: .openaiChat)
                    let grokShape = MetadataClient.shared.syncWebSearchStreamShape(
                        profileName: MetadataClient.shared.syncResolveCatalogModel(
                            modelID: modelID,
                            providerKind: .grok
                        )?.profiles.webSearch
                    )
                    var grokCtx = StreamContext()
                    defer {
                        for ev in OpenAIChatStrategy.flushToolCalls(ctx: &grokCtx) { continuation.yield(ev) }
                    }
                    var grokLastCitationsCount = 0
                    var frameLog = GrokSSEFrameLog(
                        lane: requestOptions.grokSubscription == nil ? "key" : "subscription"
                    )
                    for try await line in bytes.utf8Lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" {
                            frameLog.recordDone()
                            break
                        }
                        guard let chunkData = payload.data(using: .utf8) else { continue }
                        let chunk: GrokStreamChunk
                        do {
                            chunk = try self.decoder.decode(GrokStreamChunk.self, from: chunkData)
                        } catch {
                            frameLog.recordUndecodable(payloadLength: payload.utf8.count)
                            continue
                        }
                        frameLog.record(chunk, payloadLength: payload.utf8.count)
                        if let usage = chunk.usage { lastUsage = usage }
                        if let delta = chunk.choices?.first?.delta?.content, !delta.isEmpty {
                            accumulatedText += delta
                            continuation.yield(.delta(delta))
                        }
                        for ev in grokStrategy.parseStreamLine(payload, ctx: &grokCtx, shape: grokShape) {
                            switch ev {
                            case let .reasoning(text):
                                continuation.yield(.reasoning(text))
                            case .toolCallDeltas:
                                continuation.yield(ev)
                            default:
                                break
                            }
                        }
                        let snapshot = grokCtx.citationsAccumulator.citations
                        if snapshot.count > grokLastCitationsCount {
                            grokLastCitationsCount = snapshot.count
                            continuation.yield(.citations(snapshot))
                        }
                    }
                    for ev in OpenAIChatStrategy.flushToolCalls(ctx: &grokCtx) {
                        continuation.yield(ev)
                    }
                    frameLog.flushSummary()
                    let finalText = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let breakdown = Self.parseUsage(lastUsage)
                    let (cost, source) = await self.resolveGrokCost(
                        breakdown: breakdown, modelID: modelID,
                        subscription: requestOptions.grokSubscription
                    )
                    continuation.yield(.done(ProviderChatResult(
                        text: finalText,
                        promptTokens: breakdown.totalInputTokens,
                        completionTokens: breakdown.completionTokens,
                        estimatedCost: cost,
                        usageBreakdown: breakdown,
                        costSource: source
                    )))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func buildResponsesRequest(
        modelID: String,
        messages: [ChatMessage],
        apiKey: String,
        stream: Bool,
        reasoningMode: ReasoningMode,
        webSearchEnabled: Bool,
        requestOptions: ChatRequestOptions = ChatRequestOptions(),
        droppedParams: Set<String> = [],
        resolved: MetadataClient.ResolvedModelMetadata?
    ) throws -> URLRequest {
        var request = URLRequest(url: try resolveGrokEndpoint(
            kind: .responses, subscription: requestOptions.grokSubscription
        ))
        request.httpMethod = "POST"
        request.timeoutInterval = stream ? 120 : 60
        applyGrokHeaders(to: &request, apiKey: apiKey, subscription: requestOptions.grokSubscription)
        let capabilityIntent = CapabilityEvidenceProductionAdapter.finalChatIntent(
            messages: messages, request: request, effectiveTransport: resolved?.transport ?? "",
            model: requestOptions.capabilityEvidenceModel,
            requestedReasoningMode: reasoningMode, webSearchEnabled: webSearchEnabled
        )

        let systemPrompt = requestOptions.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = GrokResponsesRequest(
            model: modelID,
            input: capabilityIntent.outboundMessages.map { Self.buildResponsesInputMessage($0) },
            instructions: systemPrompt.isEmpty ? nil : systemPrompt,
            stream: stream ? true : nil
        )
        var body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any] ?? [:]
        if capabilityIntent.webSearchEnabled,
           let profileName = resolved?.profiles.webSearch,
           let merge = ProfileParamsResolver.webSearchMergeParams(
                providerKind: .grok, modelID: modelID, profileName: profileName
           ) {
            Self.deepMerge(&body, merge)
        }
        if let allowedReasoningMode = capabilityIntent.reasoningMode,
           let reasoningMerge = Self.reasoningMergeParamsForRequest(
            modelID: modelID,
            reasoningMode: allowedReasoningMode,
            droppedParams: droppedParams,
            resolved: resolved
        ) {
            Self.deepMerge(&body, reasoningMerge)
        }
        CapabilityRecipeRequestCompiler.apply(
            to: &body, providerKind: .grok, modelID: modelID,
            transport: TransportKind.openaiResponses.rawValue,
            webSearchEnabled: webSearchEnabled, reasoningMode: reasoningMode,
            capabilityPreferences: requestOptions.capabilityPreferences
        )
        if Self.responsesPreviousIDRecipe(
            modelID: modelID, reasoningMode: reasoningMode, webSearchEnabled: webSearchEnabled
        ) != nil {
            body.merge(CapabilityRecipeExecution.openAIResponsesPreviousID(
                RecipeContinuationRuntime.previousResponseID(
                    explicitMessageID: requestOptions.localExplicitContinuationMessageID
                )
            )) { _, latest in latest }
        }
        request.httpBody = try encodeChatBody(&body, options: requestOptions, resolved: resolved, finalRequest: request)
        return request
    }

    private static func responsesPreviousIDRecipe(
        modelID: String, reasoningMode: ReasoningMode, webSearchEnabled: Bool
    ) -> MetadataClient.CapabilityRecipe? {
        RecipeContinuationRuntime.selectedRecipe(
            provider: .grok, modelID: modelID,
            transport: TransportKind.openaiResponses.rawValue,
            webSearchEnabled: webSearchEnabled, reasoningMode: reasoningMode,
            continuationKind: "previous_id", parser: {
                $0 == "grok_reasoning_v1" || $0 == "grok_web_search_v1"
            }
        )
    }

    private func consumeResponsesStream(
        request: URLRequest,
        modelID: String,
        resolved: MetadataClient.ResolvedModelMetadata?,
        reasoningMode: ReasoningMode,
        webSearchEnabled: Bool,
        requestOptions: ChatRequestOptions,
        subscriptionLane: SubscriptionLane? = nil,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        let (bytes, _) = try await bytesWithUnsupportedParamSelfHeal(
            providerKind: .grok,
            modelID: modelID,
            request: request,
            effectiveTransport: TransportKind.openaiResponses.rawValue,
            subscriptionLane: subscriptionLane
        )

        var accumulatedText = ""
        var accumulatedReasoning = ""
        var lastUsage: GrokResponsesUsage?
        let strategy = TransportRegistry.strategy(for: .openaiResponses)
        let shape = MetadataClient.shared.syncWebSearchStreamShape(profileName: resolved?.profiles.webSearch)
        var ctx = StreamContext()
        var lastCitationsCount = 0
        var currentEvent = ""
        var completedResponseID: String?
        var frameLog = GrokResponsesSSEFrameLog(lane: subscriptionLane == nil ? "key" : "subscription")
        defer {
            for ev in OpenAIResponsesStrategy.flushToolCalls(ctx: &ctx) { continuation.yield(ev) }
            frameLog.flushSummary()
        }

        for try await line in bytes.utf8Lines {
            if Task.isCancelled { break }
            if line.hasPrefix("event:") {
                currentEvent = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if payload == "[DONE]" {
                frameLog.recordDone()
                currentEvent = ""
                break
            }
            guard !payload.isEmpty else {
                currentEvent = ""
                continue
            }

            let eventType = Self.responsesEventType(payload: payload, fallback: currentEvent)
            frameLog.record(eventType: eventType, payloadLength: payload.utf8.count)
            let strategyPayload = Self.injectResponsesEventType(payload: payload, type: eventType)
            for ev in strategy.parseStreamLine(strategyPayload, ctx: &ctx, shape: shape) {
                if case .toolCallDeltas = ev { continuation.yield(ev) }
            }
            let citations = ctx.citationsAccumulator.citations
            if citations.count > lastCitationsCount {
                lastCitationsCount = citations.count
                continuation.yield(.citations(citations))
            }

            guard let data = payload.data(using: .utf8) else {
                currentEvent = ""
                continue
            }
            switch eventType {
            case "response.output_text.delta":
                if let raw = try? decoder.decode(GrokResponsesStreamDelta.self, from: data).delta,
                   case let delta = Self.stripLeakedControlTokens(raw),
                   !delta.isEmpty {
                    accumulatedText += delta
                    continuation.yield(.delta(delta))
                }
            case "response.reasoning.delta", "response.reasoning_summary_text.delta", "response.reasoning_summary.delta":
                if let delta = try? decoder.decode(GrokResponsesStreamDelta.self, from: data).delta,
                   !delta.isEmpty {
                    accumulatedReasoning += delta
                    continuation.yield(.reasoning(delta))
                }
            case "response.completed":
                let completed = try? decoder.decode(GrokResponsesStreamCompleted.self, from: data)
                lastUsage = completed?.resolvedUsage
                completedResponseID = completed?.resolvedID ?? completedResponseID
            case "response.failed", "error":
                let parsed = try? decoder.decode(GrokResponsesStreamErrorEnvelope.self, from: data)
                throw ProviderServiceError.upstream(
                    statusCode: 200,
                    detail: parsed?.resolvedMessage ?? "Responses stream failed."
                )
            default:
                break
            }
            currentEvent = ""
        }

        for ev in OpenAIResponsesStrategy.flushToolCalls(ctx: &ctx) { continuation.yield(ev) }
        let breakdown = Self.parseResponsesUsage(lastUsage)
        try RecipeContinuationRuntime.save(
            messageID: requestOptions.localContinuationMessageID,
            recipe: Self.responsesPreviousIDRecipe(
                modelID: modelID, reasoningMode: reasoningMode,
                webSearchEnabled: webSearchEnabled
            ),
            state: completedResponseID.map { ["previousResponseId": .string($0)] } ?? [:]
        )
        let (cost, source) = await resolveGrokCost(
            breakdown: breakdown, modelID: modelID,
            subscription: requestOptions.grokSubscription
        )
        continuation.yield(.done(ProviderChatResult(
            text: accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines),
            reasoningText: {
                let trimmed = accumulatedReasoning.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }(),
            promptTokens: breakdown.totalInputTokens,
            completionTokens: breakdown.completionTokens,
            estimatedCost: cost,
            usageBreakdown: breakdown,
            costSource: source
        )))
    }

    private func buildSubscriptionResponsesRequest(
        modelID: String,
        messages: [ChatMessage],
        apiKey: String,
        subscription: GrokSubscriptionRequestContext,
        stream: Bool,
        reasoningMode: ReasoningMode,
        webSearchEnabled: Bool,
        requestOptions: ChatRequestOptions
    ) throws -> URLRequest {
        guard let url = subscription.responsesURL else {
            throw ProviderServiceError.invalidConfiguration(detail: "Missing Grok subscription responses endpoint.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = stream ? 120 : 60
        applyGrokHeaders(to: &request, apiKey: apiKey, subscription: subscription)
        if stream {
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }

        let systemPrompt = requestOptions.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = requestOptions.capabilityEvidenceModel
        var body: [String: Any] = [
            "model": modelID,
            "input": messages.map { Self.buildSubscriptionResponsesInputItem($0) },
            "store": false,
        ]
        if stream { body["stream"] = true }
        if !systemPrompt.isEmpty { body["instructions"] = systemPrompt }
        let supportsWeb = model?.capabilities.contains(.web) ?? false
        if supportsWeb {
            body["tools"] = [["type": "web_search"]]
        }
        let declaredLevels = CapabilityControlResolution.subscriptionDeclaredReasoningLevels(
            providerKind: .grok, model: model
        )
        let effort: String? = reasoningMode == .automatic
            ? CapabilityControlResolution.subscriptionDefaultReasoningLevel(providerKind: .grok, model: model)
            : OpenAIService.codexReasoningEffort(for: reasoningMode, declaredLevels: declaredLevels)
        if let effort {
            body["reasoning"] = ["effort": effort, "summary": "auto"]
        }
        request.httpBody = try encodeChatBody(&body, options: requestOptions, resolved: nil, finalRequest: request)
        return request
    }

    static func buildSubscriptionResponsesInputItem(_ msg: ChatMessage) -> [String: Any] {
        let role = msg.role.rawValue
        guard msg.role == .user else {
            let type = msg.role == .assistant ? "output_text" : "input_text"
            return ["role": role, "content": [["type": type, "text": msg.text]]]
        }
        let attachments = msg.attachments ?? []
        let imageAttachments = attachments.filter { $0.kind == .image }
        let fileAttachments = attachments.filter { $0.kind == .file }
        let (combinedText, _) = BaseAPIService.injectFileAttachmentsAsText(
            userText: msg.text,
            attachments: fileAttachments,
            provider: .grok,
            model: nil
        )
        var parts: [[String: Any]] = []
        if !combinedText.isEmpty || imageAttachments.isEmpty {
            parts.append(["type": "input_text", "text": combinedText])
        }
        for image in imageAttachments {
            let dataURL = image.resolvedDataURL
            guard !dataURL.isEmpty else { continue }
            parts.append(["type": "input_image", "image_url": dataURL, "detail": "auto"])
        }
        return ["role": role, "content": parts]
    }

    private static func buildResponsesInputMessage(_ msg: ChatMessage) -> GrokResponsesRequest.InputMessage {
        guard let attachments = msg.attachments, !attachments.isEmpty else {
            return .init(role: msg.role.rawValue, content: .text(msg.text))
        }

        guard msg.role == .user else {
            return .init(role: msg.role.rawValue, content: .text(msg.text))
        }

        let imageAttachments = attachments.filter { $0.kind == .image }
        let fileAttachments = attachments.filter { $0.kind == .file }
        let (combinedText, _) = BaseAPIService.injectFileAttachmentsAsText(
            userText: msg.text,
            attachments: fileAttachments,
            provider: .grok,
            model: nil
        )
        guard !imageAttachments.isEmpty else {
            return .init(role: msg.role.rawValue, content: .text(combinedText))
        }

        var parts: [GrokResponsesRequest.ContentPart] = []
        if !combinedText.isEmpty {
            parts.append(.init(type: "input_text", text: combinedText))
        }
        for image in imageAttachments {
            let dataURL = image.resolvedDataURL
            guard !dataURL.isEmpty else { continue }
            parts.append(.init(type: "input_image", image_url: dataURL, detail: "auto"))
        }
        return parts.isEmpty
            ? .init(role: msg.role.rawValue, content: .text(combinedText))
            : .init(role: msg.role.rawValue, content: .parts(parts))
    }

    private static func transportKind(for resolved: MetadataClient.ResolvedModelMetadata?) -> TransportKind {
        guard let raw = resolved?.transport,
              let kind = TransportKind(rawValue: raw) else {
            return .openaiChat
        }
        return kind
    }

    private func applyGrokHeaders(
        to request: inout URLRequest,
        apiKey: String,
        subscription: GrokSubscriptionRequestContext?
    ) {
        applyHeaders(to: &request, apiKey: apiKey)
        guard let subscription else { return }
        for (name, value) in subscription.requiredHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    private func resolveGrokCost(
        breakdown: UsageBreakdown,
        modelID: String,
        subscription: GrokSubscriptionRequestContext?
    ) async -> (Double, CostSource) {
        if subscription != nil { return (0, .subscription) }
        return await MetadataClient.shared.calcCost(
            breakdown: breakdown, modelID: modelID, providerKind: .grok
        )
    }

    private func resolveGrokEndpoint(
        kind: EndpointKind,
        subscription: GrokSubscriptionRequestContext?
    ) throws -> URL {
        if let subscription, kind == .chat {
            return subscription.chatURL
        }
        let metadataTransport = MetadataClient.shared.syncProviderTransport(providerKind: .grok)
        let base = metadataTransport?.baseUrl
            ?? EndpointResolver.fallbackBaseURL(for: .grok)
        let path = Self.endpointPath(in: metadataTransport?.endpoints, kind: kind)
            ?? EndpointResolver.fallbackEndpointPath(.grok, kind: kind)
        guard let url = EndpointResolver.joinURL(base: base, path: path) else {
            throw ProviderServiceError.invalidConfiguration(detail: "Invalid Grok endpoint.")
        }
        return url
    }

    private static func endpointPath(in endpoints: MetadataClient.TransportEndpoints?, kind: EndpointKind) -> String? {
        switch kind {
        case .chat: return endpoints?.chat
        case .responses: return endpoints?.responses
        case .images: return endpoints?.images
        case .embeddings: return endpoints?.embeddings
        case .files: return endpoints?.files
        }
    }

    nonisolated static func stripLeakedControlTokens(_ delta: String) -> String {
        guard delta.contains("<|eos|>") else { return delta }
        return delta.replacingOccurrences(of: "<|eos|>", with: "")
    }

    private static func responsesEventType(payload: String, fallback: String) -> String {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String,
              !type.isEmpty else {
            return fallback
        }
        return type
    }

    private static func injectResponsesEventType(payload: String, type: String) -> String {
        guard !type.isEmpty,
              let data = payload.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return payload
        }
        if object["type"] == nil {
            object["type"] = type
        }
        guard let merged = try? JSONSerialization.data(withJSONObject: object),
              let mergedString = String(data: merged, encoding: .utf8) else {
            return payload
        }
        return mergedString
    }

    private static func deepMerge(_ target: inout [String: Any], _ source: [String: Any]) {
        for (key, value) in source {
            if var existing = target[key] as? [String: Any],
               let nested = value as? [String: Any] {
                deepMerge(&existing, nested)
                target[key] = existing
            } else {
                target[key] = value
            }
        }
    }

    private static func reasoningMergeParamsForRequest(
        modelID: String,
        reasoningMode: ReasoningMode,
        droppedParams: Set<String>,
        resolved: MetadataClient.ResolvedModelMetadata?
    ) -> [String: Any]? {
        guard !droppedParams.contains("reasoning") else { return nil }
        return ProfileParamsResolver.reasoningMergeParams(
            providerKind: .grok,
            modelID: modelID,
            reasoningMode: reasoningMode,
            resolved: resolved,
            droppedParams: droppedParams
        )
    }

    private func buildChatRequest(
        modelID: String,
        messages: [ChatMessage],
        apiKey: String,
        stream: Bool,
        reasoningMode: ReasoningMode,
        webSearchEnabled: Bool,
        requestOptions: ChatRequestOptions = ChatRequestOptions(),
        droppedParams: Set<String> = [],
        resolved: MetadataClient.ResolvedModelMetadata? = nil
    ) throws -> URLRequest {
        var request = URLRequest(url: try resolveGrokEndpoint(
            kind: .chat, subscription: requestOptions.grokSubscription
        ))
        request.httpMethod = "POST"
        request.timeoutInterval = stream ? 120 : 60
        applyGrokHeaders(to: &request, apiKey: apiKey, subscription: requestOptions.grokSubscription)
        let capabilityIntent = CapabilityEvidenceProductionAdapter.finalChatIntent(
            messages: messages, request: request, effectiveTransport: resolved?.transport ?? "",
            model: requestOptions.capabilityEvidenceModel,
            requestedReasoningMode: reasoningMode, webSearchEnabled: webSearchEnabled
        )

        var apiMessages: [[String: Any]] = []
        let systemPrompt = requestOptions.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !systemPrompt.isEmpty {
            apiMessages.append(["role": "system", "content": systemPrompt])
        }
        apiMessages.append(contentsOf: capabilityIntent.outboundMessages.map { Self.buildRequestMessage($0) })

        var payload: [String: Any] = [
            "model": modelID,
            "messages": apiMessages,
        ]
        if stream {
            payload["stream"] = true
            payload["stream_options"] = ["include_usage": true]
        }
        if let allowedReasoningMode = capabilityIntent.reasoningMode,
           let reasoningMerge = Self.reasoningMergeParamsForRequest(
            modelID: modelID,
            reasoningMode: allowedReasoningMode,
            droppedParams: droppedParams,
            resolved: resolved
        ) {
            Self.deepMerge(&payload, reasoningMerge)
        }
        CapabilityRecipeRequestCompiler.apply(
            to: &payload, providerKind: .grok, modelID: modelID,
            transport: TransportKind.openaiChat.rawValue,
            webSearchEnabled: webSearchEnabled, reasoningMode: reasoningMode,
            capabilityPreferences: requestOptions.capabilityPreferences
        )
        if requestOptions.grokSubscription != nil,
           let effort = OpenAIService.codexReasoningEffort(
            for: reasoningMode,
            declaredLevels: CapabilityControlResolution.subscriptionDeclaredReasoningLevels(
                providerKind: .grok, model: requestOptions.capabilityEvidenceModel
            )
           ) {
            payload["reasoning_effort"] = effort
        }
        request.httpBody = try encodeChatBody(&payload, options: requestOptions, resolved: resolved, finalRequest: request)
        return request
    }

    private static func buildRequestMessage(_ msg: ChatMessage, model: AIModel? = nil) -> [String: Any] {
        let attachments = msg.attachments ?? []
        let imageAttachments = attachments.filter { $0.kind == .image }
        let fileAttachments = attachments.filter { $0.kind == .file }

        if !imageAttachments.isEmpty {
            let (injectedText, _) = BaseAPIService.injectFileAttachmentsAsText(
                userText: msg.text,
                attachments: fileAttachments,
                provider: .grok,
                model: model
            )
            var parts: [[String: Any]] = []
            if !injectedText.isEmpty {
                parts.append(["type": "text", "text": injectedText])
            }
            for img in imageAttachments {
                let b64 = img.resolvedBase64Data
                guard !b64.isEmpty else { continue }
                let mime = img.mimeType ?? "image/png"
                let dataURL = "data:\(mime);base64,\(b64)"
                parts.append(["type": "image_url", "image_url": ["url": dataURL]])
            }
            if parts.isEmpty {
                parts.append(["type": "text", "text": injectedText])
            }
            return ["role": msg.role.rawValue, "content": parts]
        }

        let (text, _) = BaseAPIService.injectFileAttachmentsAsText(
            userText: msg.text,
            attachments: attachments,
            provider: .grok,
            model: model
        )
        return ["role": msg.role.rawValue, "content": text]
    }

    private func buildModels(from remoteModels: [GrokMetadataModel], preferredModelID: String?) async -> [AIModel] {
        let normalizedPreferredID = preferredModelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        var models: [AIModel] = []
        models.reserveCapacity(remoteModels.count)
        for remote in remoteModels {
            var model = await CatalogModelBuilder.buildCatalogModel(
                providerKind: .grok,
                runtimeModelId: remote.id,
                fallbackName: remote.id,
                fallbackContextLength: nil,
                createdAt: nil
            )
            if normalizedPreferredID == remote.id { model.isDefault = true }
            models.append(model)
        }
        models.sort(by: catalogModelSort)
        if let normalizedPreferredID, models.contains(where: { $0.id == normalizedPreferredID }) { return models }
        return selectDefaultBySortRank(models)
    }
}

private struct GrokMetadataModel { let id: String }

private struct GrokResponsesRequest: Encodable {
    var model: String
    var input: [InputMessage]
    var instructions: String?
    var stream: Bool?

    struct InputMessage: Encodable {
        var role: String
        var content: InputContent
    }

    enum InputContent: Encodable {
        case text(String)
        case parts([ContentPart])

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let text):
                try container.encode(text)
            case .parts(let parts):
                try container.encode(parts)
            }
        }
    }

    struct ContentPart: Encodable {
        var type: String
        var text: String?
        var image_url: String?
        var detail: String?
    }
}

private struct GrokResponsesResponse: Decodable {
    var id: String?
    var output_text: String?
    var output: [OutputItem]?
    var usage: GrokResponsesUsage?

    struct OutputItem: Decodable {
        var content: [ContentPart]?
    }

    struct ContentPart: Decodable {
        var type: String?
        var text: String?
    }

    var resolvedText: String {
        if let output_text, !output_text.isEmpty { return output_text }
        return output?
            .flatMap { $0.content ?? [] }
            .compactMap { $0.type == "output_text" ? $0.text : nil }
            .joined() ?? ""
    }
}

private struct GrokResponsesUsage: Decodable {
    var input_tokens: Int?
    var output_tokens: Int?
    var cost_in_usd_ticks: Int64?
    var input_tokens_details: InputTokensDetails?
    var output_tokens_details: OutputTokensDetails?

    struct InputTokensDetails: Decodable {
        var cached_tokens: Int?
    }

    struct OutputTokensDetails: Decodable {
        var reasoning_tokens: Int?
    }
}

private struct GrokResponsesStreamDelta: Decodable {
    var delta: String?
}

private struct GrokResponsesStreamCompleted: Decodable {
    var id: String?
    var usage: GrokResponsesUsage?
    var response: CompletedResponse?

    var resolvedUsage: GrokResponsesUsage? {
        usage ?? response?.usage
    }

    var resolvedID: String? { id ?? response?.id }

    struct CompletedResponse: Decodable {
        var id: String?
        var usage: GrokResponsesUsage?
    }
}

private struct GrokResponsesStreamErrorEnvelope: Decodable {
    var error: ErrorPayload?
    var response: ResponseWrapper?

    var resolvedMessage: String? {
        error?.message ?? response?.error?.message
    }

    struct ErrorPayload: Decodable {
        var message: String?
    }

    struct ResponseWrapper: Decodable {
        var error: ErrorPayload?
    }
}

private struct GrokUsage: Decodable {
    let prompt_tokens: Int?
    let completion_tokens: Int?
    let cost_in_usd_ticks: Int64?
    let prompt_tokens_details: PromptTokensDetails?
    let completion_tokens_details: CompletionTokensDetails?

    struct PromptTokensDetails: Decodable {
        let cached_tokens: Int?
        init(cached_tokens: Int? = nil) { self.cached_tokens = cached_tokens }
    }

    struct CompletionTokensDetails: Decodable {
        let reasoning_tokens: Int?
        init(reasoning_tokens: Int? = nil) { self.reasoning_tokens = reasoning_tokens }
    }

    init(
        prompt_tokens: Int? = nil,
        completion_tokens: Int? = nil,
        cost_in_usd_ticks: Int64? = nil,
        prompt_tokens_details: PromptTokensDetails? = nil,
        completion_tokens_details: CompletionTokensDetails? = nil
    ) {
        self.prompt_tokens = prompt_tokens
        self.completion_tokens = completion_tokens
        self.cost_in_usd_ticks = cost_in_usd_ticks
        self.prompt_tokens_details = prompt_tokens_details
        self.completion_tokens_details = completion_tokens_details
    }
}
private struct GrokChatCompletionResponse: Decodable { let choices: [GrokChoice]; let usage: GrokUsage? }
private struct GrokChoice: Decodable { let message: GrokMessage }
private struct GrokMessage: Decodable { let content: String? }
private struct GrokStreamChunk: Decodable { let choices: [GrokStreamChoice]?; let usage: GrokUsage? }
private struct GrokStreamChoice: Decodable { let delta: GrokDelta?; let finish_reason: String? }
private struct GrokDelta: Decodable {
    let content: String?
    let reasoning_content: String?
    let tool_calls: [GrokToolCallDelta]?
}
private struct GrokToolCallDelta: Decodable { let index: Int?; let id: String? }

private struct GrokSSEFrameLog {
    let lane: String
    private var frames = 0
    private var contentFrames = 0
    private var reasoningFrames = 0
    private var toolCallFrames = 0
    private var usageFrames = 0
    private var undecodable = 0
    private var finishReason: String?
    private var sawDone = false

    init(lane: String) { self.lane = lane }

    mutating func record(_ chunk: GrokStreamChunk, payloadLength: Int) {
        frames += 1
        let choice = chunk.choices?.first
        var kinds: [String] = []
        if let content = choice?.delta?.content, !content.isEmpty { contentFrames += 1; kinds.append("content") }
        if let reasoning = choice?.delta?.reasoning_content, !reasoning.isEmpty { reasoningFrames += 1; kinds.append("reasoning") }
        if let calls = choice?.delta?.tool_calls, !calls.isEmpty { toolCallFrames += 1; kinds.append("tool_calls×\(calls.count)") }
        if chunk.usage != nil { usageFrames += 1; kinds.append("usage") }
        if let reason = choice?.finish_reason, !reason.isEmpty { finishReason = reason }
        #if DEBUG
        print("[Grok][SSE][\(lane)] #\(frames) kinds=\(kinds.isEmpty ? "empty" : kinds.joined(separator: "+")) len=\(payloadLength) finish_reason=\(choice?.finish_reason ?? "-")")
        #endif
    }

    mutating func recordUndecodable(payloadLength: Int) {
        frames += 1
        undecodable += 1
        #if DEBUG
        print("[Grok][SSE][\(lane)] #\(frames) undecodable len=\(payloadLength)")
        #endif
    }

    mutating func recordDone() { sawDone = true }

    func flushSummary() {
        NSLog("[Grok][SSE][%@] frames=%d content=%d reasoning=%d tool_calls=%d usage=%d undecodable=%d finish_reason=%@ done=%d",
              lane, frames, contentFrames, reasoningFrames, toolCallFrames, usageFrames, undecodable,
              finishReason ?? "-", sawDone ? 1 : 0)
    }
}

struct GrokResponsesSSEFrameLog {
    let lane: String
    private(set) var frames = 0
    private(set) var counts: [String: Int] = [:]
    private(set) var sawDone = false

    init(lane: String) { self.lane = lane }

    mutating func record(eventType: String, payloadLength: Int) {
        frames += 1
        let key = eventType.isEmpty ? "untyped" : eventType
        counts[key, default: 0] += 1
        #if DEBUG
        print("[Grok][Responses][\(lane)] #\(frames) type=\(key) len=\(payloadLength)")
        #endif
    }

    mutating func recordDone() { sawDone = true }

    var summary: String {
        counts.keys.sorted().map { "\($0)=\(counts[$0] ?? 0)" }.joined(separator: " ")
    }

    func flushSummary() {
        NSLog("[Grok][Responses][%@] frames=%d done=%d %@", lane, frames, sawDone ? 1 : 0, summary)
    }
}

extension GrokService {
    fileprivate static func parseUsage(_ usage: GrokUsage?) -> UsageBreakdown {
        guard let usage else { return UsageBreakdown() }
        let cached = usage.prompt_tokens_details?.cached_tokens ?? 0
        let total = usage.prompt_tokens ?? 0
        let upstream = usage.cost_in_usd_ticks.map { Double($0) / grokTicksPerUSD }
        return UsageBreakdown(
            promptTokens: max(0, total - cached),
            cachedInputTokens: cached,
            cacheCreation5mTokens: 0,
            cacheCreation1hTokens: 0,
            completionTokens: usage.completion_tokens ?? 0,
            reasoningTokens: usage.completion_tokens_details?.reasoning_tokens ?? 0,
            upstreamCost: upstream,
            cacheReadObserved: usage.prompt_tokens_details?.cached_tokens != nil
        )
    }

    fileprivate static func parseResponsesUsage(_ usage: GrokResponsesUsage?) -> UsageBreakdown {
        guard let usage else { return UsageBreakdown() }
        let cached = usage.input_tokens_details?.cached_tokens ?? 0
        let total = usage.input_tokens ?? 0
        let upstream = usage.cost_in_usd_ticks.map { Double($0) / grokTicksPerUSD }
        return UsageBreakdown(
            promptTokens: max(0, total - cached),
            cachedInputTokens: cached,
            cacheCreation5mTokens: 0,
            cacheCreation1hTokens: 0,
            completionTokens: usage.output_tokens ?? 0,
            reasoningTokens: usage.output_tokens_details?.reasoning_tokens ?? 0,
            upstreamCost: upstream,
            cacheReadObserved: usage.input_tokens_details?.cached_tokens != nil
        )
    }

    #if DEBUG
    static func parseUsageForTesting(
        promptTokens: Int?,
        completionTokens: Int?,
        costInUsdTicks: Int64?,
        cachedTokens: Int?,
        reasoningTokens: Int?
    ) -> UsageBreakdown {
        let usage = GrokUsage(
            prompt_tokens: promptTokens,
            completion_tokens: completionTokens,
            cost_in_usd_ticks: costInUsdTicks,
            prompt_tokens_details: cachedTokens.map { GrokUsage.PromptTokensDetails(cached_tokens: $0) },
            completion_tokens_details: reasoningTokens.map { GrokUsage.CompletionTokensDetails(reasoning_tokens: $0) }
        )
        return parseUsage(usage)
    }
    #endif
}
