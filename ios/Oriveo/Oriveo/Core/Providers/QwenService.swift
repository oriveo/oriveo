import Foundation
import OriveoProviderKit

final class QwenService: BaseAPIService, ProviderServiceProtocol, CustomBaseURLProvider {
    private let defaultBaseURL = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"


    func syncProvider(apiKey: String, preferredModelID: String?) async throws -> ProviderSyncResult {
        try await syncProvider(
            apiKey: apiKey,
            preferredModelID: preferredModelID,
            baseURL: nil
        )
    }

    func syncProvider(apiKey: String, preferredModelID: String?, baseURL: String) async throws -> ProviderSyncResult {
        try await syncProvider(
            apiKey: apiKey,
            preferredModelID: preferredModelID,
            baseURL: Optional(baseURL)
        )
    }

    func syncProvider(apiKey: String, preferredModelID: String?, baseURL: String?) async throws -> ProviderSyncResult {
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

        let resolved = MetadataClient.shared.syncResolveCatalogModel(
            modelID: modelID,
            providerKind: .qwen
        )

        if let attachments = try await qwenImageAttachmentsIfImageModel(
            apiKey: apiKey, modelID: modelID, messages: messages, baseURL: baseURL, resolved: resolved
        ) {
            return ProviderChatResult(
                text: "", promptTokens: 0, completionTokens: 0, estimatedCost: 0, attachments: attachments
            )
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

        let response: QwenChatCompletionResponse = try await perform(request)
        guard let choice = response.choices.first else {
            throw ProviderServiceError.emptyResponse
        }
        let trimmed = (choice.message.content?.textValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let toolCalls = OpenAIService.nonStreamingToolCalls(choice.message.tool_calls)
        guard !trimmed.isEmpty || !toolCalls.isEmpty else {
            throw ProviderServiceError.emptyResponse
        }
        let text = trimmed
        let breakdown = Self.parseUsage(response.usage)
        let (cost, source) = await MetadataClient.shared.calcCost(
            breakdown: breakdown, modelID: modelID, providerKind: .qwen
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
            reasoningMode: .automatic
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
            reasoningMode: .automatic
        )
    }

    func sendMessageStream(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        baseURL: String? = nil,
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
                        baseURL: baseURL,
                        stream: true,
                        reasoningMode: reasoningMode,
                        webSearchEnabled: webSearchEnabled,
                        requestOptions: requestOptions
                    )
                    let (bytes, response) = try await self.bytesWithUnsupportedParamSelfHeal(
                        providerKind: .qwen,
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
                    var accumulatedReasoning = ""
                    var lastUsage: QwenUsage?

                    var toolCallDecoder = OpenAIChatToolCallStreamDecoder()
                    var sawToolCalls = false
                    defer {
                        if let flushed = toolCallDecoder.finishEvent() { continuation.yield(flushed) }
                    }
                    for try await line in bytes.utf8Lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
                        if payload.isEmpty { continue }
                        if payload == "[DONE]" { break }
                        guard let chunkData = payload.data(using: .utf8) else { continue }

                        if let errorMessage = Self.streamErrorMessage(from: chunkData) {
                            throw ProviderServiceError.upstream(
                                statusCode: httpResponse.statusCode,
                                detail: errorMessage
                            )
                        }

                        let chunk: QwenStreamChunk
                        do {
                            chunk = try self.decoder.decode(QwenStreamChunk.self, from: chunkData)
                        } catch {
                            continue
                        }
                        if let usage = chunk.usage { lastUsage = usage }
                        if let flushed = toolCallDecoder.ingestEvent(
                            toolCalls: chunk.choices?.first?.delta?.tool_calls,
                            finishReason: chunk.choices?.first?.finish_reason
                        ) {
                            sawToolCalls = true
                            continuation.yield(flushed)
                        }
                        let choice = chunk.choices?.first
                        if let content = choice?.streamContent, !content.isEmpty {
                            accumulatedText += content
                            continuation.yield(.delta(content))
                        }
                        if let reasoning = choice?.streamReasoningContent, !reasoning.isEmpty {
                            accumulatedReasoning += reasoning
                            continuation.yield(.reasoning(reasoning))
                        }
                    }

                    if let flushed = toolCallDecoder.finishEvent() {
                        sawToolCalls = true
                        continuation.yield(flushed)
                    }
                    var finalText = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if finalText.isEmpty, !sawToolCalls {
                        let reasoningFallback = accumulatedReasoning.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !reasoningFallback.isEmpty else {
                            throw ProviderServiceError.emptyResponse
                        }
                        finalText = reasoningFallback
                        continuation.yield(.delta(reasoningFallback))
                    }
                    let breakdown = Self.parseUsage(lastUsage)
                    let (cost, source) = await MetadataClient.shared.calcCost(
                        breakdown: breakdown, modelID: modelID, providerKind: .qwen
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


    private func qwenImageAttachmentsIfImageModel(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        baseURL: String?,
        resolved: MetadataClient.ResolvedModelMetadata?
    ) async throws -> [Attachment]? {
        guard try imageRouteOrThrow(resolved: resolved) == .dashscopeMultimodal else { return nil }

        let prompt = messages.last?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !prompt.isEmpty else { throw ProviderServiceError.emptyResponse }

        let requestBaseURL = normalizedBaseURL(baseURL, default: defaultBaseURL)
        let nativeBase = requestBaseURL.replacingOccurrences(of: "/compatible-mode/v1", with: "")
        guard let url = URL(string: "\(nativeBase)/api/v1/services/aigc/multimodal-generation/generation") else {
            throw ProviderServiceError.invalidConfiguration(detail: "Invalid Qwen image endpoint.")
        }
        let requestDefaults = MetadataClient.shared.syncImageGenRequestDefaults(profileName: resolved?.profiles.imageGen)
        return try await generateImageViaDashscopeMultimodal(
            apiKey: apiKey, modelID: modelID, prompt: prompt, url: url, requestDefaults: requestDefaults
        )
    }


    private func resolveChatEndpoint(baseURL userBase: String?) -> URL {
        let trimmedUserBase = userBase?.trimmingCharacters(in: .whitespacesAndNewlines)
        let userBaseValid = trimmedUserBase.map { !$0.isEmpty } ?? false

        if userBaseValid {
            return Self.composeCompatibleChatURL(base: normalizedBaseURL(userBase, default: defaultBaseURL))
        }
        let metadataTransport = MetadataClient.shared.syncProviderTransport(providerKind: .qwen)
        let endpointBase = EndpointResolver.officialMetadataBaseURL(
            providerKind: .qwen,
            metadataTransport: metadataTransport
        ) ?? EndpointResolver.fallbackBaseURL(for: .qwen)
        let endpointPath = metadataTransport?.endpoints?.chat
            ?? EndpointResolver.fallbackEndpointPath(.qwen, kind: .chat)
        return EndpointResolver.joinURL(base: endpointBase, path: endpointPath)
            ?? URL(string: Self.defaultCompatChatURL)!
    }

    private static let defaultCompatChatURL =
        "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions"

    static func composeCompatibleChatURL(base: String) -> URL {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }

        if trimmed.hasSuffix("/chat/completions") {
            return URL(string: trimmed) ?? URL(string: defaultCompatChatURL)!
        }

        if let nativeRange = trimmed.range(of: "/api/v1/services/aigc/text-generation/generation") {
            trimmed = String(trimmed[..<nativeRange.lowerBound])
        }
        if trimmed.hasSuffix("/compatible-mode/v1") {
            trimmed = String(trimmed.dropLast("/compatible-mode/v1".count))
        }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }

        let lowered = trimmed.lowercased()
        if lowered.contains("dashscope") || lowered.contains("aliyuncs") {
            return URL(string: "\(trimmed)/compatible-mode/v1/chat/completions")
                ?? URL(string: defaultCompatChatURL)!
        }
        return URL(string: "\(trimmed)/chat/completions") ?? URL(string: defaultCompatChatURL)!
    }

    private func buildChatRequest(
        modelID: String,
        messages: [ChatMessage],
        apiKey: String,
        baseURL: String? = nil,
        stream: Bool,
        reasoningMode: ReasoningMode,
        webSearchEnabled: Bool = false,
        requestOptions: ChatRequestOptions = ChatRequestOptions()
    ) throws -> URLRequest {
        let url = resolveChatEndpoint(baseURL: baseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = stream ? 120 : 60
        applyHeaders(to: &request, apiKey: apiKey)
        let resolved = MetadataClient.shared.syncResolveCatalogModel(modelID: modelID, providerKind: .qwen)
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
            providerKind: .qwen,
            modelID: modelID,
            reasoningMode: allowedReasoningMode,
            resolved: resolved
        ) {
            ProfileParamsResolver.deepMerge(&payload, reasoningMerge)
        }

        if capabilityIntent.webSearchEnabled,
           let profileName = resolved?.profiles.webSearch,
           let merge = ProfileParamsResolver.webSearchMergeParams(
            providerKind: .qwen,
            modelID: modelID,
            profileName: profileName
           ) {
            for (key, value) in merge {
                if key == "parameters", let nested = value as? [String: Any] {
                    for (k, v) in nested { payload[k] = v }
                } else {
                    payload[key] = value
                }
            }
        }
        CapabilityRecipeRequestCompiler.apply(to: &payload, providerKind: .qwen, modelID: modelID, transport: resolved?.transport ?? "", webSearchEnabled: webSearchEnabled, reasoningMode: reasoningMode, capabilityPreferences: requestOptions.capabilityPreferences)
        request.httpBody = try encodeChatBody(&payload, options: requestOptions, resolved: resolved, finalRequest: request)
        return request
    }

    func chatEndpointURL(baseURL: String?) -> URL {
        resolveChatEndpoint(baseURL: baseURL)
    }

    static func streamErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let errObj = json["error"] as? [String: Any],
           let msg = errObj["message"] as? String, !msg.isEmpty {
            return msg
        }
        if let errString = json["error"] as? String, !errString.isEmpty {
            return errString
        }
        if json["choices"] == nil, json["code"] != nil,
           let msg = json["message"] as? String, !msg.isEmpty {
            return msg
        }
        return nil
    }

    func chatRequestForTesting(
        modelID: String,
        messages: [ChatMessage],
        apiKey: String,
        baseURL: String?,
        stream: Bool,
        reasoningMode: ReasoningMode = .automatic
    ) throws -> URLRequest {
        try buildChatRequest(
            modelID: modelID,
            messages: messages,
            apiKey: apiKey,
            baseURL: baseURL,
            stream: stream,
            reasoningMode: reasoningMode
        )
    }

    private static func buildRequestMessage(_ msg: ChatMessage, model: AIModel? = nil) -> [String: Any] {
        let atts = msg.attachments ?? []
        let imageAtts = atts.filter { $0.kind == .image }

        let (combinedText, _) = BaseAPIService.injectFileAttachmentsAsText(
            userText: msg.text,
            attachments: atts,
            provider: .qwen,
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


    private func buildModels(from remoteModels: [QwenRemoteModel], preferredModelID: String?) async -> [AIModel] {
        let normalizedPreferredID = preferredModelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        var models: [AIModel] = []
        models.reserveCapacity(remoteModels.count)

        for remote in remoteModels {
            var model = await CatalogModelBuilder.buildCatalogModel(
                providerKind: .qwen,
                runtimeModelId: remote.id,
                fallbackName: remote.id,
                fallbackContextLength: nil,
                createdAt: remote.created
            )
            if normalizedPreferredID == remote.id {
                model.isDefault = true
            }
            models.append(model)
        }

        models.sort(by: catalogModelSort)

        let resolvedDefaultID = resolveDefaultModelID(
            from: models,
            preferredModelID: normalizedPreferredID
        )
        guard let resolvedDefaultID else {
            return models
        }

        return models.map { model in
            var updatedModel = model
            updatedModel.isDefault = model.id == resolvedDefaultID
            return updatedModel
        }
    }

    private static let knownTextModelIDs = ["qwen3-max", "qwen3.5-plus", "qwen-plus", "qwen-turbo"]

    private func resolveDefaultModelID(from models: [AIModel], preferredModelID: String?) -> String? {
        if let preferredModelID,
           models.contains(where: { $0.id == preferredModelID }) {
            return preferredModelID
        }

        if let metadataDefaultID = models.first(where: { $0.isDefault && !$0.supportsImageGenerationRoute })?.id {
            return metadataDefaultID
        }

        if let knownFallbackID = Self.knownTextModelIDs.first(where: { knownID in
            models.contains(where: { $0.id == knownID })
        }) {
            return knownFallbackID
        }

        if let firstTextModelID = models.first(where: { !$0.supportsImageGenerationRoute })?.id {
            return firstTextModelID
        }

        if let metadataDefaultID = models.first(where: \.isDefault)?.id {
            return metadataDefaultID
        }

        return models.first?.id
    }
}


private struct QwenModelsResponse: Decodable {
    var data: [QwenRemoteModel]
}

private struct QwenRemoteModel: Decodable {
    var id: String
    var created: TimeInterval?
    var owned_by: String?
}

private struct QwenChatCompletionResponse: Decodable {
    var choices: [Choice]
    var usage: QwenUsage?

    struct Choice: Decodable {
        var message: Message

        struct Message: Decodable {
            var content: QwenContentValue?
            var tool_calls: [ChatCompletionToolCall]?
        }
    }
}

private struct QwenStreamChunk: Decodable {
    var choices: [QwenStreamChoice]?
    var usage: QwenUsage?
}

private struct QwenStreamChoice: Decodable {
    var delta: QwenStreamDelta?
    var finish_reason: String?
    var message: QwenStreamMessage?

    var streamContent: String? {
        if let text = delta?.content?.textValue, !text.isEmpty {
            return text
        }
        if let text = message?.content?.textValue, !text.isEmpty {
            return text
        }
        return nil
    }

    var streamReasoningContent: String? {
        if let text = delta?.reasoning_content, !text.isEmpty {
            return text
        }
        if let text = message?.reasoning_content, !text.isEmpty {
            return text
        }
        return nil
    }
}

private struct QwenStreamDelta: Decodable {
    var tool_calls: [OpenAICompatibleChunk.Choice.ToolCallDelta]?
    var content: QwenContentValue?
    var reasoning_content: String?
}

private struct QwenStreamMessage: Decodable {
    var content: QwenContentValue?
    var reasoning_content: String?
}

private enum QwenContentValue: Decodable {
    case text(String)
    case parts([Part])

    var textValue: String {
        switch self {
        case let .text(text):
            return text
        case let .parts(parts):
            return parts
                .compactMap(\.text)
                .joined(separator: "\n")
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let text = try? container.decode(String.self) {
            self = .text(text)
            return
        }

        if let parts = try? container.decode([Part].self) {
            self = .parts(parts)
            return
        }

        self = .text("")
    }

    struct Part: Decodable {
        var type: String?
        var text: String?
    }
}

private struct QwenUsage: Decodable {
    var prompt_tokens: Int?
    var completion_tokens: Int?
    var total_tokens: Int?
    var prompt_tokens_details: PromptTokensDetails?
    var cached_tokens: Int?
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
        cached_tokens: Int? = nil,
        completion_tokens_details: CompletionTokensDetails? = nil
    ) {
        self.prompt_tokens = prompt_tokens
        self.completion_tokens = completion_tokens
        self.total_tokens = total_tokens
        self.prompt_tokens_details = prompt_tokens_details
        self.cached_tokens = cached_tokens
        self.completion_tokens_details = completion_tokens_details
    }
}

extension QwenService {
    fileprivate static func parseUsage(_ usage: QwenUsage?) -> UsageBreakdown {
        guard let usage else { return UsageBreakdown() }
        let cached = usage.prompt_tokens_details?.cached_tokens ?? usage.cached_tokens ?? 0
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
                || usage.cached_tokens != nil
        )
    }

    #if DEBUG
    static func parseUsageForTesting(
        promptTokens: Int?,
        completionTokens: Int?,
        cachedInDetails: Int?,
        cachedAtTopLevel: Int?
    ) -> UsageBreakdown {
        let details: QwenUsage.PromptTokensDetails?
        if let cachedInDetails {
            details = QwenUsage.PromptTokensDetails(cached_tokens: cachedInDetails)
        } else {
            details = nil
        }
        let usage = QwenUsage(
            prompt_tokens: promptTokens,
            completion_tokens: completionTokens,
            total_tokens: nil,
            prompt_tokens_details: details,
            cached_tokens: cachedAtTopLevel,
            completion_tokens_details: nil
        )
        return parseUsage(usage)
    }
    #endif
}
