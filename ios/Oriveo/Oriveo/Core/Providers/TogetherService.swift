import Foundation
import OriveoProviderKit

final class TogetherService: BaseAPIService, ProviderServiceProtocol, CustomBaseURLProvider {
    /// Used only when the caller gave no base address; official request entry points pass the result of the endpoint-source resolver.
    private let defaultBaseURL = "https://api.together.xyz/v1"


    func syncProvider(apiKey: String, preferredModelID: String?) async throws -> ProviderSyncResult {
        try validateAPIKey(apiKey)
        await MetadataClient.shared.ensureInitialized()
        return ProviderSyncResult(models: [])
    }


    func syncProvider(apiKey: String, preferredModelID: String?, baseURL: String) async throws -> ProviderSyncResult {
        try await syncProvider(apiKey: apiKey, preferredModelID: preferredModelID)
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
        let response: TogetherChatCompletionResponse = try await perform(request)
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
            breakdown: breakdown, modelID: modelID, providerKind: .together, at: Date()
        )
        return ProviderChatResult(
            text: text,
            promptTokens: breakdown.totalInputTokens,
            completionTokens: breakdown.completionTokens,
            estimatedCost: cost,
            usageBreakdown: breakdown,
            usageReported: response.usage != nil,
            costSource: source,
            toolCalls: toolCalls.isEmpty ? nil : toolCalls
        )
    }


    func sendMessage(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        baseURL: String
    ) async throws -> ProviderChatResult {
        try await sendMessage(
            apiKey: apiKey, modelID: modelID, messages: messages, baseURL: Optional(baseURL),
            reasoningMode: .automatic, requestOptions: ChatRequestOptions()
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
        baseURL: String
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        sendMessageStream(
            apiKey: apiKey, modelID: modelID, messages: messages, baseURL: Optional(baseURL),
            reasoningMode: .automatic, requestOptions: ChatRequestOptions()
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
                        providerKind: .together,
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
                    var lastUsage: TogetherUsage?

                    var toolCallDecoder = OpenAIChatToolCallStreamDecoder()
                    defer {
                        if let flushed = toolCallDecoder.finishEvent() { continuation.yield(flushed) }
                    }
                    var finishTracker = StreamFinishTracker(family: .openaiChat)
                    for try await line in bytes.utf8Lines {
                        if Task.isCancelled { break }
                        finishTracker.observeSSELine(line)
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" { break }
                        guard let chunkData = payload.data(using: .utf8) else { continue }
                        try Self.throwIfStreamErrorFrame(chunkData, beforeAnyContent: accumulatedText.isEmpty, redacting: [apiKey])
                        let chunk: TogetherStreamChunk
                        do {
                            chunk = try self.decoder.decode(TogetherStreamChunk.self, from: chunkData)
                        } catch {
                            continue
                        }
                        if let usage = chunk.usage { lastUsage = usage }
                        if let flushed = toolCallDecoder.ingestEvent(
                            toolCalls: chunk.choices?.first?.delta?.tool_calls,
                            finishReason: chunk.choices?.first?.finish_reason
                        ) { continuation.yield(flushed) }
                        if let reasoning = chunk.choices?.first?.delta?.reasoning_content
                            ?? chunk.choices?.first?.delta?.reasoning, !reasoning.isEmpty {
                            continuation.yield(.reasoning(reasoning))
                        }
                        if let delta = chunk.choices?.first?.delta,
                           let content = delta.content, !content.isEmpty {
                            accumulatedText += content
                            continuation.yield(.delta(content))
                        }
                    }

                    if let flushed = toolCallDecoder.finishEvent() { continuation.yield(flushed) }
                    let finalText = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let breakdown = Self.parseUsage(lastUsage)
                    let (cost, source) = await MetadataClient.shared.calcCost(
                        breakdown: breakdown, modelID: modelID, providerKind: .together, at: Date()
                    )
                    let result = ProviderChatResult(
                        text: finalText,
                        promptTokens: breakdown.totalInputTokens,
                        completionTokens: breakdown.completionTokens,
                        estimatedCost: cost,
                        usageBreakdown: breakdown,
                        usageReported: lastUsage != nil,
                        costSource: source,
                        finish: finishTracker.finish()
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
        baseURL: String?,
        stream: Bool,
        reasoningMode: ReasoningMode,
        requestOptions: ChatRequestOptions = ChatRequestOptions()
    ) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "\(normalizedBaseURL(baseURL, default: defaultBaseURL))/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = stream ? 120 : 60
        applyHeaders(to: &request, apiKey: apiKey)
        let resolved = MetadataClient.shared.syncResolveCatalogModel(modelID: modelID, providerKind: .together)
        let capabilityIntent = CapabilityEvidenceProductionAdapter.finalChatIntent(
            messages: messages, request: request, effectiveTransport: resolved?.transport ?? "",
            model: requestOptions.capabilityEvidenceModel,
            requestedReasoningMode: reasoningMode, webSearchEnabled: requestOptions.webIntentRequested
        )

        var apiMessages: [TogetherChatRequest.Message] = []
        let systemPrompt = requestOptions.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !systemPrompt.isEmpty {
            apiMessages.append(.init(role: "system", content: .text(systemPrompt)))
        }
        apiMessages.append(contentsOf: try AttachmentDelivery.mapTurns(capabilityIntent.outboundMessages, isChatSend: requestOptions.capabilityEvidenceModel != nil, dynamicText: requestOptions.dynamicText) { try Self.buildRequestMessage($0, model: requestOptions.capabilityEvidenceModel, isOutgoingTurn: $1) })

        let reasoningEffort = capabilityIntent.reasoningMode.flatMap { allowedMode in
            ProfileParamsResolver.reasoningMergeParams(
                providerKind: .together, modelID: modelID,
                reasoningMode: allowedMode, resolved: resolved
            )?["reasoning_effort"] as? String
        }

        let payload = TogetherChatRequest(
            model: modelID,
            stream: stream ? true : nil,
            stream_options: stream ? TogetherChatRequest.StreamOptions() : nil,
            reasoning_effort: reasoningEffort,
            messages: apiMessages
        )
        var body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any] ?? [:]
        CapabilityRecipeRequestCompiler.apply(to: &body, providerKind: .together, modelID: modelID, transport: resolved?.transport ?? "", webSearchEnabled: requestOptions.webIntentRequested, reasoningMode: reasoningMode, capabilityPreferences: requestOptions.capabilityPreferences)
        request.httpBody = try encodeChatBody(&body, options: requestOptions, resolved: resolved, finalRequest: request)
        return request
    }

    private static func buildRequestMessage(_ msg: ChatMessage, model: AIModel?, isOutgoingTurn: Bool) throws -> TogetherChatRequest.Message {
        let atts = msg.attachments ?? []
        let imageAtts = atts.filter { $0.kind == .image }

        let combinedText = try AttachmentDelivery.deliver(
            isOutgoingTurn: isOutgoingTurn,
            userText: msg.text,
            attachments: atts,
            transport: .togetherChat,
            model: model
        ).injectedText

        guard !imageAtts.isEmpty else {
            return .init(role: msg.role.rawValue, content: .text(combinedText))
        }

        var parts: [TogetherChatRequest.ContentPart] = [.init(type: "text", text: combinedText)]
        for a in imageAtts {
            let dataURL = a.resolvedDataURL
            guard !dataURL.isEmpty else { continue }
            parts.append(.init(type: "image_url", image_url: .init(url: dataURL)))
        }
        return .init(role: msg.role.rawValue, content: .parts(parts))
    }


    private static let knownTextModelIDs = [
        "meta-llama/Llama-3.3-70B-Instruct-Turbo",
        "Qwen/Qwen2.5-72B-Instruct-Turbo",
        "deepseek-ai/DeepSeek-R1",
    ]

    private func buildModels(from remoteModels: [TogetherMetadataModel], preferredModelID: String?) async -> [AIModel] {
        let normalizedPreferredID = preferredModelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        var models: [AIModel] = []
        models.reserveCapacity(remoteModels.count)

        for remote in remoteModels {
            var model = await CatalogModelBuilder.buildCatalogModel(
                providerKind: .together,
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


private struct TogetherMetadataModel {
    var id: String
}

private struct TogetherChatRequest: Encodable {
    var model: String
    var stream: Bool?
    var stream_options: StreamOptions?
    var reasoning_effort: String?
    var messages: [Message]
    var max_tokens: Int?

    struct StreamOptions: Encodable {
        var include_usage: Bool = true
    }

    struct Message: Encodable {
        var role: String
        var content: MessageContent
    }

    enum MessageContent: Encodable {
        case text(String)
        case parts([ContentPart])

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let s): try container.encode(s)
            case .parts(let p): try container.encode(p)
            }
        }
    }

    struct ContentPart: Encodable {
        var type: String
        var text: String?
        var image_url: ImageURL?

        struct ImageURL: Encodable { var url: String }
    }
}

private struct TogetherChatCompletionResponse: Decodable {
    var choices: [Choice]
    var usage: TogetherUsage?

    struct Choice: Decodable {
        var message: Message

        struct Message: Decodable {
            var content: String?
            var tool_calls: [ChatCompletionToolCall]?
        }
    }
}

private struct TogetherStreamChunk: Decodable {
    var choices: [TogetherStreamChoice]?
    var usage: TogetherUsage?
}

private struct TogetherStreamChoice: Decodable {
    var delta: TogetherStreamDelta?
    var finish_reason: String?
}

private struct TogetherStreamDelta: Decodable {
    var tool_calls: [OpenAICompatibleChunk.Choice.ToolCallDelta]?
    var content: String?
    var reasoning_content: String?
    var reasoning: String?
}

private struct TogetherUsage: Decodable {
    var prompt_tokens: Int?
    var completion_tokens: Int?
    var total_tokens: Int?
    /// Two usage shapes (docs.together.ai openai-compatibility "Response shape differences", 2026-10-27):
    /// reasoning models nest fields OpenAI-style under `prompt_tokens_details` / `completion_tokens_details`;
    /// some non-reasoning models put `cached_tokens` flat at the top level of usage with no *_details objects.
    var cached_tokens: Int?
    var prompt_tokens_details: PromptTokensDetails?
    var completion_tokens_details: CompletionTokensDetails?

    struct PromptTokensDetails: Decodable {
        var cached_tokens: Int?
    }

    struct CompletionTokensDetails: Decodable {
        var reasoning_tokens: Int?
    }
}

extension TogetherService {
    /// Tool-loop openai_chat legs reuse the same usage parser as plain chat: a leg receives the usage object from an SSE frame.
    nonisolated static func legUsageBreakdown(usageJSON: [String: Any]) -> UsageBreakdown? {
        guard let data = try? JSONSerialization.data(withJSONObject: usageJSON),
              let usage = try? JSONDecoder().decode(TogetherUsage.self, from: data) else { return nil }
        return parseUsage(usage)
    }

    nonisolated fileprivate static func parseUsage(_ usage: TogetherUsage?) -> UsageBreakdown {
        guard let usage else { return UsageBreakdown() }
        // Nested wins, top level is the fallback; either one present (including 0) counts as an observed cache read
        let reportedCached = usage.prompt_tokens_details?.cached_tokens ?? usage.cached_tokens
        let cached = reportedCached ?? 0
        let total = usage.prompt_tokens ?? 0
        return UsageBreakdown(
            promptTokens: max(0, total - cached),
            cachedInputTokens: cached,
            cacheCreation5mTokens: 0,
            cacheCreation1hTokens: 0,
            completionTokens: usage.completion_tokens ?? 0,
            reasoningTokens: usage.completion_tokens_details?.reasoning_tokens ?? 0,
            upstreamCost: nil,
            cacheReadObserved: reportedCached != nil
        )
    }
}

// MARK: - Protocol entry with request options: a one-line forward to the options overload this service already has

extension TogetherService {
    func sendMessage(
        apiKey: String, modelID: String, messages: [ChatMessage], requestOptions: ChatRequestOptions
    ) async throws -> ProviderChatResult {
        try await sendMessage(apiKey: apiKey, modelID: modelID, messages: messages, baseURL: nil, reasoningMode: .automatic, requestOptions: requestOptions)
    }

    func sendMessageStream(
        apiKey: String, modelID: String, messages: [ChatMessage], requestOptions: ChatRequestOptions
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        sendMessageStream(apiKey: apiKey, modelID: modelID, messages: messages, baseURL: nil, reasoningMode: .automatic, requestOptions: requestOptions)
    }

    func sendMessage(
        apiKey: String, modelID: String, messages: [ChatMessage], baseURL: String, requestOptions: ChatRequestOptions
    ) async throws -> ProviderChatResult {
        try await sendMessage(apiKey: apiKey, modelID: modelID, messages: messages, baseURL: Optional(baseURL), reasoningMode: .automatic, requestOptions: requestOptions)
    }

    func sendMessageStream(
        apiKey: String, modelID: String, messages: [ChatMessage], baseURL: String, requestOptions: ChatRequestOptions
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        sendMessageStream(apiKey: apiKey, modelID: modelID, messages: messages, baseURL: Optional(baseURL), reasoningMode: .automatic, requestOptions: requestOptions)
    }
}
