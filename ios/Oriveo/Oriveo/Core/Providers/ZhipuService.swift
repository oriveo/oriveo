import Foundation

final class ZhipuService: BaseAPIService, ProviderServiceProtocol {
    private let baseURL = "https://open.bigmodel.cn/api/paas/v4"


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
            requestOptions: ChatRequestOptions()
        )
    }

    func sendMessage(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        reasoningMode: ReasoningMode = .automatic,
        requestOptions: ChatRequestOptions = ChatRequestOptions()
    ) async throws -> ProviderChatResult {
        try validateAPIKey(apiKey)
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderServiceError.invalidConfiguration(detail: "Missing model identifier.")
        }

        let request = try buildChatRequest(
            modelID: modelID,
            messages: messages,
            apiKey: apiKey,
            stream: false,
            reasoningMode: reasoningMode,
            requestOptions: requestOptions
        )
        let response: ZhipuChatCompletionResponse = try await perform(request)
        guard let choice = response.choices.first else {
            throw ProviderServiceError.emptyResponse
        }
        let text = choice.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ProviderServiceError.emptyResponse
        }
        let breakdown = Self.parseUsage(response.usage)
        let (cost, source) = await MetadataClient.shared.calcCost(
            breakdown: breakdown, modelID: modelID, providerKind: .zhipu
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

                    let request = try self.buildChatRequest(
                        modelID: modelID,
                        messages: messages,
                        apiKey: apiKey,
                        stream: true,
                        reasoningMode: reasoningMode,
                        webSearchEnabled: webSearchEnabled,
                        requestOptions: requestOptions
                    )
                    let (bytes, response) = try await self.bytesWithUnsupportedParamSelfHeal(
                        providerKind: .zhipu,
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
                    var lastUsage: ZhipuUsage?
                    // Zhipu nests web search results inside the tool call delta
                    // (`choices.0.delta.tool_calls.0.web_search.search_result`). The exact path
                    // comes from the model's web search profile rather than being hard-coded here,
                    // so a change upstream is a metadata update instead of a client release.
                    let zhipuStrategy = TransportRegistry.strategy(for: .openaiChat)
                    let zhipuShape = MetadataClient.shared.syncWebSearchStreamShape(
                        profileName: MetadataClient.shared.syncResolveCatalogModel(
                            modelID: modelID,
                            providerKind: .zhipu
                        )?.profiles.webSearch
                    )
                    var zhipuCtx = StreamContext()
                    defer {
                        for ev in OpenAIChatStrategy.flushToolCalls(ctx: &zhipuCtx) { continuation.yield(ev) }
                    }
                    var zhipuLastCitationsCount = 0

                    for try await line in bytes.utf8Lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" { break }
                        guard let chunkData = payload.data(using: .utf8) else { continue }
                        let chunk: ZhipuStreamChunk
                        do {
                            chunk = try self.decoder.decode(ZhipuStreamChunk.self, from: chunkData)
                        } catch {
                            continue
                        }
                        if let usage = chunk.usage { lastUsage = usage }
                        if let delta = chunk.choices?.first?.delta,
                           let content = delta.content, !content.isEmpty {
                            accumulatedText += content
                            continuation.yield(.delta(content))
                        }
                        for ev in zhipuStrategy.parseStreamLine(payload, ctx: &zhipuCtx, shape: zhipuShape) {
                            switch ev {
                            case let .reasoning(text): continuation.yield(.reasoning(text))
                            case .toolCallDeltas: continuation.yield(ev)
                            default: break
                            }
                        }
                        let snapshot = zhipuCtx.citationsAccumulator.citations
                        if snapshot.count > zhipuLastCitationsCount {
                            zhipuLastCitationsCount = snapshot.count
                            continuation.yield(.citations(snapshot))
                        }
                    }
                    for ev in OpenAIChatStrategy.flushToolCalls(ctx: &zhipuCtx) {
                        continuation.yield(ev)
                    }

                    let finalText = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let breakdown = Self.parseUsage(lastUsage)
                    let (cost, source) = await MetadataClient.shared.calcCost(
                        breakdown: breakdown, modelID: modelID, providerKind: .zhipu
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



    private func buildChatRequest(
        modelID: String,
        messages: [ChatMessage],
        apiKey: String,
        stream: Bool,
        reasoningMode: ReasoningMode,
        webSearchEnabled: Bool = false,
        requestOptions: ChatRequestOptions = ChatRequestOptions()
    ) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "\(baseURL)/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = stream ? 120 : 60
        applyHeaders(to: &request, apiKey: apiKey)
        let resolved = MetadataClient.shared.syncResolveCatalogModel(modelID: modelID, providerKind: .zhipu)
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
           let reasoningMerge = ProfileParamsResolver.reasoningMergeParams(
            providerKind: .zhipu,
            modelID: modelID,
            reasoningMode: allowedReasoningMode,
            resolved: resolved
        ) {
            ProfileParamsResolver.deepMerge(&payload, reasoningMerge)
        }

        if capabilityIntent.webSearchEnabled,
           let profileName = resolved?.profiles.webSearch,
           let webMerge = ProfileParamsResolver.webSearchMergeParams(
            providerKind: .zhipu,
            modelID: modelID,
            profileName: profileName
           ) {
            ProfileParamsResolver.deepMerge(&payload, webMerge)
        }

        CapabilityRecipeRequestCompiler.apply(to: &payload, providerKind: .zhipu, modelID: modelID, transport: resolved?.transport ?? "", webSearchEnabled: webSearchEnabled, reasoningMode: reasoningMode, capabilityPreferences: requestOptions.capabilityPreferences)
        request.httpBody = try encodeChatBody(&payload, options: requestOptions, resolved: resolved, finalRequest: request)
        return request
    }

    private static func buildRequestMessage(_ msg: ChatMessage, model: AIModel? = nil) -> [String: Any] {
        let atts = msg.attachments ?? []
        let imageAtts = atts.filter { $0.kind == .image }

        let (combinedText, _) = BaseAPIService.injectFileAttachmentsAsText(
            userText: msg.text,
            attachments: atts,
            provider: .zhipu,
            model: model
        )

        guard !imageAtts.isEmpty else {
            return ["role": msg.role.rawValue, "content": combinedText]
        }

        var contentParts: [[String: Any]] = [["type": "text", "text": combinedText]]
        for img in imageAtts {
            let b64 = img.resolvedBase64Data
            guard !b64.isEmpty else { continue }
            let mime = img.mimeType ?? "image/jpeg"
            contentParts.append([
                "type": "image_url",
                "image_url": ["url": "data:\(mime);base64,\(b64)"]
            ])
        }
        return ["role": msg.role.rawValue, "content": contentParts]
    }


    private static let knownTextModelIDs = ["glm-4-plus", "glm-4-flash", "glm-4-air"]

    private func buildModels(from remoteModels: [ZhipuRemoteModel], preferredModelID: String?) async -> [AIModel] {
        let normalizedPreferredID = preferredModelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        var models: [AIModel] = []
        models.reserveCapacity(remoteModels.count)

        for remote in remoteModels {
            var model = await CatalogModelBuilder.buildCatalogModel(
                providerKind: .zhipu,
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
}


private struct ZhipuRemoteModel {
    var id: String
}

private struct ZhipuChatCompletionResponse: Decodable {
    var choices: [Choice]
    var usage: ZhipuUsage?

    struct Choice: Decodable {
        var message: Message

        struct Message: Decodable {
            var content: String
        }
    }
}

private struct ZhipuStreamChunk: Decodable {
    var choices: [ZhipuStreamChoice]?
    var usage: ZhipuUsage?
}

private struct ZhipuStreamChoice: Decodable {
    var delta: ZhipuStreamDelta?
}

private struct ZhipuStreamDelta: Decodable {
    var content: String?
}

private struct ZhipuUsage: Decodable {
    var prompt_tokens: Int?
    var completion_tokens: Int?
    var total_tokens: Int?
    var prompt_tokens_details: PromptTokensDetails?
    var completion_tokens_details: CompletionTokensDetails?

    struct PromptTokensDetails: Decodable {
        var cached_tokens: Int?
        init(cached_tokens: Int? = nil) { self.cached_tokens = cached_tokens }
    }

    struct CompletionTokensDetails: Decodable {
        var reasoning_tokens: Int?
        init(reasoning_tokens: Int? = nil) { self.reasoning_tokens = reasoning_tokens }
    }

    init(
        prompt_tokens: Int? = nil,
        completion_tokens: Int? = nil,
        total_tokens: Int? = nil,
        prompt_tokens_details: PromptTokensDetails? = nil,
        completion_tokens_details: CompletionTokensDetails? = nil
    ) {
        self.prompt_tokens = prompt_tokens
        self.completion_tokens = completion_tokens
        self.total_tokens = total_tokens
        self.prompt_tokens_details = prompt_tokens_details
        self.completion_tokens_details = completion_tokens_details
    }
}

extension ZhipuService {
    fileprivate static func parseUsage(_ usage: ZhipuUsage?) -> UsageBreakdown {
        guard let usage else { return UsageBreakdown() }
        let cached = usage.prompt_tokens_details?.cached_tokens ?? 0
        let total = usage.prompt_tokens ?? 0
        return UsageBreakdown(
            promptTokens: max(0, total - cached),
            cachedInputTokens: cached,
            cacheCreation5mTokens: 0,
            cacheCreation1hTokens: 0,
            completionTokens: usage.completion_tokens ?? 0,
            reasoningTokens: usage.completion_tokens_details?.reasoning_tokens ?? 0,
            upstreamCost: nil,
            cacheReadObserved: usage.prompt_tokens_details?.cached_tokens != nil
        )
    }

    #if DEBUG
    static func parseUsageForTesting(
        promptTokens: Int?,
        completionTokens: Int?,
        cachedTokens: Int?,
        reasoningTokens: Int?
    ) -> UsageBreakdown {
        let usage = ZhipuUsage(
            prompt_tokens: promptTokens,
            completion_tokens: completionTokens,
            total_tokens: nil,
            prompt_tokens_details: cachedTokens.map { ZhipuUsage.PromptTokensDetails(cached_tokens: $0) },
            completion_tokens_details: reasoningTokens.map { ZhipuUsage.CompletionTokensDetails(reasoning_tokens: $0) }
        )
        return parseUsage(usage)
    }
    #endif
}
