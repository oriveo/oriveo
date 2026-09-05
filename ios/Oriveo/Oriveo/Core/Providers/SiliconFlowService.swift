import Foundation
import OriveoProviderKit

final class SiliconFlowService: BaseAPIService, ProviderServiceProtocol, CustomBaseURLProvider, BalanceQueryable {
    private let defaultBaseURL = "https://api.siliconflow.cn/v1"


    func syncProvider(apiKey: String, preferredModelID: String?) async throws -> ProviderSyncResult {
        try await syncProvider(apiKey: apiKey, preferredModelID: preferredModelID, baseURL: nil)
    }

    func syncProvider(apiKey: String, preferredModelID: String?, baseURL: String) async throws -> ProviderSyncResult {
        try await syncProvider(apiKey: apiKey, preferredModelID: preferredModelID, baseURL: Optional(baseURL))
    }

    private func syncProvider(apiKey: String, preferredModelID: String?, baseURL: String?) async throws -> ProviderSyncResult {
        _ = baseURL
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
            baseURL: nil,
            reasoningMode: .automatic,
            requestOptions: ChatRequestOptions()
        )
    }

    func sendMessage(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        baseURL: String
    ) async throws -> ProviderChatResult {
        try await sendMessage(
            apiKey: apiKey,
            modelID: modelID,
            messages: messages,
            baseURL: Optional(baseURL),
            reasoningMode: .automatic,
            requestOptions: ChatRequestOptions()
        )
    }

    func sendMessage(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        baseURL: String? = nil,
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
            baseURL: baseURL,
            stream: false,
            reasoningMode: reasoningMode,
            requestOptions: requestOptions
        )
        let response: SiliconFlowChatCompletionResponse = try await perform(request)
        guard let choice = response.choices.first else {
            throw ProviderServiceError.emptyResponse
        }

        let text = (choice.message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let toolCalls = OpenAIService.nonStreamingToolCalls(choice.message.tool_calls)
        guard !text.isEmpty || !toolCalls.isEmpty else {
            throw ProviderServiceError.emptyResponse
        }

        let breakdown = Self.parseUsage(response.usage)
        let (cost, source) = await MetadataClient.shared.calcCost(
            breakdown: breakdown, modelID: modelID, providerKind: .siliconFlow
        )
        return ProviderChatResult(
            text: text,
            promptTokens: breakdown.totalInputTokens,
            completionTokens: breakdown.completionTokens,
            estimatedCost: cost,
            usageBreakdown: breakdown,
            costSource: source,
            toolCalls: toolCalls.isEmpty ? nil : toolCalls
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
            baseURL: nil,
            reasoningMode: .automatic,
            requestOptions: ChatRequestOptions()
        )
    }

    func sendMessageStream(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        baseURL: String
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        sendMessageStream(
            apiKey: apiKey,
            modelID: modelID,
            messages: messages,
            baseURL: Optional(baseURL),
            reasoningMode: .automatic,
            requestOptions: ChatRequestOptions()
        )
    }

    func sendMessageStream(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        baseURL: String? = nil,
        reasoningMode: ReasoningMode = .automatic,
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
                        baseURL: baseURL,
                        stream: true,
                        reasoningMode: reasoningMode,
                        requestOptions: requestOptions
                    )
                    let (bytes, response) = try await self.bytesWithUnsupportedParamSelfHeal(
                        providerKind: .siliconFlow,
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
                    var lastUsage: SiliconFlowUsage?

                    var toolCallDecoder = OpenAIChatToolCallStreamDecoder()
                    defer {
                        if let flushed = toolCallDecoder.finishEvent() { continuation.yield(flushed) }
                    }
                    for try await line in bytes.utf8Lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" { break }
                        guard let chunkData = payload.data(using: .utf8) else { continue }

                        let chunk: SiliconFlowStreamChunk
                        do {
                            chunk = try self.decoder.decode(SiliconFlowStreamChunk.self, from: chunkData)
                        } catch {
                            continue
                        }

                        if let usage = chunk.usage { lastUsage = usage }
                        if let flushed = toolCallDecoder.ingestEvent(
                            toolCalls: chunk.choices?.first?.delta?.tool_calls,
                            finishReason: chunk.choices?.first?.finish_reason
                        ) { continuation.yield(flushed) }
                        if let reasoning = chunk.choices?.first?.delta?.reasoning_content, !reasoning.isEmpty {
                            continuation.yield(.reasoning(reasoning))
                        }
                        if let delta = chunk.choices?.first?.delta?.content, !delta.isEmpty {
                            accumulatedText += delta
                            continuation.yield(.delta(delta))
                        }
                    }

                    if let flushed = toolCallDecoder.finishEvent() { continuation.yield(flushed) }
                    let finalText = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let breakdown = Self.parseUsage(lastUsage)
                    let (cost, source) = await MetadataClient.shared.calcCost(
                        breakdown: breakdown, modelID: modelID, providerKind: .siliconFlow
                    )

                    continuation.yield(
                        .done(
                            ProviderChatResult(
                                text: finalText,
                                promptTokens: breakdown.totalInputTokens,
                                completionTokens: breakdown.completionTokens,
                                estimatedCost: cost,
                                usageBreakdown: breakdown,
                                costSource: source
                            )
                        )
                    )
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

    // MARK: - Balance

    func fetchBalance(apiKey: String, baseURL: String?) async throws -> ProviderBalance {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BalanceQueryError.keyInvalid(detail: "Missing API key.")
        }
        let origin = balanceOriginFrom(baseURL, fallback: "https://api.siliconflow.cn")
        guard let url = URL(string: "\(origin)/v1/user/info") else {
            throw BalanceQueryError.network(detail: "Invalid SiliconFlow user/info URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        applyHeaders(to: &request, apiKey: apiKey)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BalanceQueryError.network(detail: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw BalanceQueryError.network(detail: "Missing HTTPURLResponse.")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw BalanceQueryError.keyInvalid(detail: "SiliconFlow rejected API key (\(http.statusCode)).")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw BalanceQueryError.network(detail: "SiliconFlow /user/info HTTP \(http.statusCode).")
        }
        struct UserInfoResponse: Decodable {
            struct DataField: Decodable {
                let balance: String?
                let chargeBalance: String?
                let totalBalance: String?
            }
            let data: DataField?
        }
        let decoded: UserInfoResponse
        do {
            decoded = try decoder.decode(UserInfoResponse.self, from: data)
        } catch {
            throw BalanceQueryError.decoding(detail: error.localizedDescription)
        }
        let total = Double(decoded.data?.totalBalance ?? "") ?? 0
        let granted = Double(decoded.data?.balance ?? "")
        let topUp = Double(decoded.data?.chargeBalance ?? "")
        let currency = URL(string: origin)?.host?.lowercased().hasSuffix("siliconflow.com") == true ? "USD" : "CNY"
        return ProviderBalance(
            currency: currency,
            total: total,
            granted: granted,
            topUp: topUp,
            fetchedAt: Date()
        )
    }


    private func buildChatRequest(
        modelID: String,
        messages: [ChatMessage],
        apiKey: String,
        baseURL: String?,
        stream: Bool,
        reasoningMode: ReasoningMode,
        requestOptions: ChatRequestOptions = ChatRequestOptions()
    ) throws -> URLRequest {
        let effectiveBaseURL = normalizedBaseURL(baseURL, default: defaultBaseURL)
        var request = URLRequest(url: URL(string: "\(effectiveBaseURL)/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = stream ? 120 : 60
        applyHeaders(to: &request, apiKey: apiKey)
        let resolved = MetadataClient.shared.syncResolveCatalogModel(
            modelID: modelID, providerKind: .siliconFlow
        )
        let capabilityIntent = CapabilityEvidenceProductionAdapter.finalChatIntent(
            messages: messages, request: request, effectiveTransport: resolved?.transport ?? "",
            model: requestOptions.capabilityEvidenceModel,
            requestedReasoningMode: reasoningMode, webSearchEnabled: requestOptions.webIntentRequested
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
           let merge = ProfileParamsResolver.reasoningMergeParams(
            providerKind: .siliconFlow,
            modelID: modelID,
            reasoningMode: allowedReasoningMode,
            resolved: resolved
        ) {
            ProfileParamsResolver.deepMerge(&payload, merge)
        }

        CapabilityRecipeRequestCompiler.apply(to: &payload, providerKind: .siliconFlow, modelID: modelID, transport: resolved?.transport ?? "", webSearchEnabled: requestOptions.webIntentRequested, reasoningMode: reasoningMode, capabilityPreferences: requestOptions.capabilityPreferences)
        request.httpBody = try encodeChatBody(&payload, options: requestOptions, resolved: resolved, finalRequest: request)
        return request
    }

    private static func buildRequestMessage(_ msg: ChatMessage, model: AIModel? = nil) -> [String: Any] {
        let atts = msg.attachments ?? []
        let imageAtts = atts.filter { $0.kind == .image }

        let (combinedText, _) = BaseAPIService.injectFileAttachmentsAsText(
            userText: msg.text,
            attachments: atts,
            provider: .siliconFlow,
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



    private func buildModels(from remoteModels: [SiliconFlowMetadataModel], preferredModelID: String?) async -> [AIModel] {
        let normalizedPreferredID = preferredModelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        var models: [AIModel] = []
        models.reserveCapacity(remoteModels.count)

        for remote in remoteModels {
            var model = await CatalogModelBuilder.buildCatalogModel(
                providerKind: .siliconFlow,
                runtimeModelId: remote.id,
                fallbackName: remote.id.split(separator: "/").last.map(String.init) ?? remote.id,
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

private struct SiliconFlowMetadataModel {
    let id: String
}

private struct SiliconFlowChatCompletionResponse: Decodable {
    let choices: [Choice]
    let usage: SiliconFlowUsage?

    struct Choice: Decodable {
        let message: Message

        struct Message: Decodable {
            let content: String?
            let reasoning_content: String?
            let tool_calls: [ChatCompletionToolCall]?
        }
    }
}

private struct SiliconFlowStreamChunk: Decodable {
    let choices: [Choice]?
    let usage: SiliconFlowUsage?

    struct Choice: Decodable {
        let delta: Delta?
    var finish_reason: String?
    }

    struct Delta: Decodable {
        let content: String?
        let reasoning_content: String?
    var tool_calls: [OpenAICompatibleChunk.Choice.ToolCallDelta]?
    }
}

private struct SiliconFlowUsage: Decodable {
    let prompt_tokens: Int?
    let completion_tokens: Int?
    let input_tokens: Int?
    let output_tokens: Int?
    let prompt_tokens_details: PromptTokensDetails?

    struct PromptTokensDetails: Decodable {
        let cached_tokens: Int?
    }
}

extension SiliconFlowService {
    fileprivate static func parseUsage(_ usage: SiliconFlowUsage?) -> UsageBreakdown {
        guard let usage else { return UsageBreakdown() }
        let cached = usage.prompt_tokens_details?.cached_tokens ?? 0
        let total = usage.prompt_tokens ?? usage.input_tokens ?? 0
        let completion = usage.completion_tokens ?? usage.output_tokens ?? 0
        return UsageBreakdown(
            promptTokens: max(0, total - cached),
            cachedInputTokens: cached,
            cacheCreation5mTokens: 0,
            cacheCreation1hTokens: 0,
            completionTokens: completion,
            reasoningTokens: 0,
            upstreamCost: nil,
            cacheReadObserved: usage.prompt_tokens_details?.cached_tokens != nil
        )
    }
}
