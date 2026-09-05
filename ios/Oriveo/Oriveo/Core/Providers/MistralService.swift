import Foundation
import OriveoProviderKit

final class MistralService: BaseAPIService, ProviderServiceProtocol {
    private let baseURL = "https://api.mistral.ai/v1"

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
        let response: MistralChatCompletionResponse = try await perform(request)
        guard let choice = response.choices.first else {
            throw ProviderServiceError.emptyResponse
        }
        let text = (choice.message.content?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let reasoningText = choice.message.content?.reasoningText.trimmingCharacters(in: .whitespacesAndNewlines)
        let toolCalls = OpenAIService.nonStreamingToolCalls(choice.message.tool_calls)
        guard !text.isEmpty || !toolCalls.isEmpty else {
            throw ProviderServiceError.emptyResponse
        }
        let continuationRecipe = Self.reasoningReplayRecipe(
            modelID: modelID, reasoningMode: reasoningMode
        )
        let replayToolCalls = choice.message.rawToolCalls?.compactMap {
            $0.foundationValue as? [String: Any]
        }
        if replayToolCalls?.count == choice.message.rawToolCalls?.count,
           let replayMessage = CapabilityRecipeExecution.mistralReplayAssistant(
                content: choice.message.rawContent?.foundationValue,
                toolCalls: replayToolCalls
           ), let encoded = RecipeContinuationRuntime.jsonValue([replayMessage]) {
            try RecipeContinuationRuntime.save(
                messageID: requestOptions.localContinuationMessageID,
                recipe: continuationRecipe,
                state: ["assistantMessages": encoded]
            )
        }

        let breakdown = Self.parseUsage(response.usage)
        let (cost, source) = await MetadataClient.shared.calcCost(
            breakdown: breakdown, modelID: modelID, providerKind: .mistral
        )
        return ProviderChatResult(
            text: text,
            reasoningText: reasoningText?.isEmpty == false ? reasoningText : nil,
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
            reasoningMode: .automatic
        )
    }

    func sendMessageStream(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
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
                        stream: true,
                        reasoningMode: reasoningMode,
                        requestOptions: requestOptions
                    )
                    let (bytes, response) = try await self.bytesWithUnsupportedParamSelfHeal(
                        providerKind: .mistral,
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
                    var lastUsage: MistralUsage?
                    var replayAccumulator = MistralAssistantReplayStreamAccumulator()
                    var reachedTerminalFrame = false

                    var toolCallDecoder = OpenAIChatToolCallStreamDecoder()
                    defer {
                        if let flushed = toolCallDecoder.finishEvent() { continuation.yield(flushed) }
                    }
                    for try await line in bytes.utf8Lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" {
                            reachedTerminalFrame = true
                            break
                        }
                        guard let chunkData = payload.data(using: .utf8) else { continue }
                        // Capture provider-owned content/tool-call shapes before the display
                        // decoder folds them. A malformed or future block poisons only replay;
                        // ordinary response rendering can still use every valid later frame.
                        replayAccumulator.ingest(chunkData)

                        let chunk: MistralStreamChunk
                        do {
                            chunk = try self.decoder.decode(MistralStreamChunk.self, from: chunkData)
                        } catch {
                            continue
                        }

                        if let usage = chunk.usage { lastUsage = usage }
                        if chunk.choices?.first?.finish_reason?.isEmpty == false {
                            reachedTerminalFrame = true
                        }
                        if let flushed = toolCallDecoder.ingestEvent(
                            toolCalls: chunk.choices?.first?.delta?.tool_calls,
                            finishReason: chunk.choices?.first?.finish_reason
                        ) { continuation.yield(flushed) }
                        if let content = chunk.choices?.first?.delta?.content {
                            let reasoning = content.reasoningText
                            if !reasoning.isEmpty {
                                accumulatedReasoning += reasoning
                                continuation.yield(.reasoning(reasoning))
                            }
                            let delta = content.text
                            if !delta.isEmpty {
                                accumulatedText += delta
                                continuation.yield(.delta(delta))
                            }
                        }
                    }

                    if let flushed = toolCallDecoder.finishEvent() { continuation.yield(flushed) }
                    try Task.checkCancellation()
                    let continuationRecipe = Self.reasoningReplayRecipe(
                        modelID: modelID, reasoningMode: reasoningMode
                    )
                    if reachedTerminalFrame,
                       let replayMessage = replayAccumulator.completedAssistantMessage(),
                       let encoded = RecipeContinuationRuntime.jsonValue([replayMessage]) {
                        try RecipeContinuationRuntime.save(
                            messageID: requestOptions.localContinuationMessageID,
                            recipe: continuationRecipe,
                            state: ["assistantMessages": encoded]
                        )
                    }
                    let finalText = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let breakdown = Self.parseUsage(lastUsage)
                    let (cost, source) = await MetadataClient.shared.calcCost(
                        breakdown: breakdown, modelID: modelID, providerKind: .mistral
                    )
                    let trimmedReasoning = accumulatedReasoning.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.yield(
                        .done(
                            ProviderChatResult(
                                text: finalText,
                                reasoningText: trimmedReasoning.isEmpty ? nil : trimmedReasoning,
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

    private func buildChatRequest(
        modelID: String,
        messages: [ChatMessage],
        apiKey: String,
        stream: Bool,
        reasoningMode: ReasoningMode,
        requestOptions: ChatRequestOptions = ChatRequestOptions()
    ) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "\(baseURL)/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = stream ? 120 : 60
        applyHeaders(to: &request, apiKey: apiKey)
        let resolved = MetadataClient.shared.syncResolveCatalogModel(modelID: modelID, providerKind: .mistral)
        let replayAssistantMessages = Self.reasoningReplayRecipe(
            modelID: modelID, reasoningMode: reasoningMode
        ).flatMap { _ in
            CapabilityRecipeExecution.mistralReplayAssistantMessages(
                RecipeContinuationRuntime.replayAssistantMessages(
                    explicitMessageID: requestOptions.localExplicitContinuationMessageID
                )
            )
        }
        let requestMessagesInput = replayAssistantMessages == nil ? messages : messages.filter {
            $0.id != requestOptions.localExplicitContinuationMessageID
        }
        let capabilityIntent = CapabilityEvidenceProductionAdapter.finalChatIntent(
            messages: requestMessagesInput, request: request, effectiveTransport: resolved?.transport ?? "",
            model: requestOptions.capabilityEvidenceModel,
            requestedReasoningMode: reasoningMode, webSearchEnabled: requestOptions.webIntentRequested
        )

        var apiMessages: [[String: Any]] = []
        let systemPrompt = requestOptions.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !systemPrompt.isEmpty {
            apiMessages.append(["role": "system", "content": systemPrompt])
        }
        apiMessages.append(contentsOf: capabilityIntent.outboundMessages.map { Self.buildRequestMessage($0) })
        if let replayAssistantMessages {
            let insertAt = apiMessages.lastIndex(where: { $0["role"] as? String == "user" })
                ?? apiMessages.count
            apiMessages.insert(contentsOf: replayAssistantMessages, at: insertAt)
        }
        var payload: [String: Any] = [
            "model": modelID,
            "messages": apiMessages,
        ]
        if stream {
            payload["stream"] = true
        }
        if let allowedReasoningMode = capabilityIntent.reasoningMode,
           let reasoningMerge = ProfileParamsResolver.reasoningMergeParams(
            providerKind: .mistral,
            modelID: modelID,
            reasoningMode: allowedReasoningMode,
            resolved: resolved
        ) {
            ProfileParamsResolver.deepMerge(&payload, reasoningMerge)
        }

        CapabilityRecipeRequestCompiler.apply(to: &payload, providerKind: .mistral, modelID: modelID, transport: resolved?.transport ?? "", webSearchEnabled: requestOptions.webIntentRequested, reasoningMode: reasoningMode, capabilityPreferences: requestOptions.capabilityPreferences)
        request.httpBody = try encodeChatBody(&payload, options: requestOptions, resolved: resolved, finalRequest: request)
        return request
    }

    static func buildRequestMessageForTest(_ msg: ChatMessage, model: AIModel? = nil) -> [String: Any] {
        buildRequestMessage(msg, model: model)
    }

    private static func reasoningReplayRecipe(
        modelID: String, reasoningMode: ReasoningMode
    ) -> MetadataClient.CapabilityRecipe? {
        RecipeContinuationRuntime.selectedRecipe(
            provider: .mistral, modelID: modelID, transport: "openai_chat",
            webSearchEnabled: false, reasoningMode: reasoningMode,
            continuationKind: "replay_reasoning", parser: { $0 == "mistral_reasoning_v1" }
        )
    }

    private static func buildRequestMessage(_ msg: ChatMessage, model: AIModel? = nil) -> [String: Any] {
        let attachments = msg.attachments ?? []
        let imageAttachments = attachments.filter { $0.kind == .image }

        let (combinedText, _) = BaseAPIService.injectFileAttachmentsAsText(
            userText: msg.text,
            attachments: attachments,
            provider: .mistral,
            model: model
        )

        guard !imageAttachments.isEmpty, msg.role == .user else {
            return ["role": msg.role.rawValue, "content": combinedText]
        }

        var contentParts: [[String: Any]] = [["type": "text", "text": combinedText]]
        for image in imageAttachments {
            let dataURL = image.resolvedDataURL
            guard !dataURL.isEmpty else { continue }
            contentParts.append(["type": "image_url", "image_url": ["url": dataURL]])
        }
        return ["role": msg.role.rawValue, "content": contentParts]
    }
}

/// Reconstructs the complete assistant `content` wire from streaming deltas. Once Mistral has
/// emitted a block array, later plain-string deltas become text blocks at their original position;
/// flattening all thinking before all text would change the assistant message the next request sees.
struct MistralAssistantReplayStreamAccumulator {
    private var valid = true
    private var sawContent = false
    private var sawBlocks = false
    private var stringContent = ""
    private var blocks: [[String: Any]] = []
    private var toolCalls = MistralReplayToolCallAccumulator()

    mutating func ingest(_ data: Data) {
        guard valid else { return }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            valid = false
            return
        }
        guard let choices = object["choices"] as? [[String: Any]],
              let choice = choices.first else { return }
        guard choice["delta"] == nil || choice["delta"] is [String: Any] else {
            valid = false
            return
        }
        guard let delta = choice["delta"] as? [String: Any] else { return }

        if let content = delta["content"], !(content is NSNull) {
            ingestContent(content)
        }
        if let rawCalls = delta["tool_calls"], !(rawCalls is NSNull),
           !toolCalls.ingest(rawCalls) {
            valid = false
        }
    }

    func completedAssistantMessage() -> [String: Any]? {
        guard valid, sawContent, let finalToolCalls = toolCalls.completedCalls() else { return nil }
        let content: Any = sawBlocks ? blocks : stringContent
        return CapabilityRecipeExecution.mistralReplayAssistant(
            content: content,
            toolCalls: toolCalls.wasPresent ? finalToolCalls : nil
        )
    }

    private mutating func ingestContent(_ content: Any) {
        if let string = content as? String {
            sawContent = true
            guard !string.isEmpty else { return }
            if sawBlocks {
                blocks.append(["type": "text", "text": string])
            } else {
                stringContent += string
            }
            return
        }
        guard let incoming = content as? [[String: Any]],
              CapabilityRecipeExecution.validMistralContent(incoming) else {
            valid = false
            return
        }
        sawContent = true
        if !sawBlocks, !stringContent.isEmpty {
            blocks.append(["type": "text", "text": stringContent])
            stringContent = ""
        }
        sawBlocks = true
        blocks.append(contentsOf: incoming)
    }
}

/// Streaming tool calls arrive fragmented by `index`. This accumulator keeps the standard Mistral
/// assistant tool-call frame complete for replay while the existing ProviderKit decoder continues
/// to own user-facing `.toolCallDeltas` events.
private struct MistralReplayToolCallAccumulator {
    private struct Partial {
        var id: String?
        var type: String?
        var name = ""
        var arguments = ""
        var sawFunction = false
    }

    private var partials: [Int: Partial] = [:]
    private(set) var wasPresent = false
    private var valid = true

    mutating func ingest(_ raw: Any) -> Bool {
        wasPresent = true
        guard valid, let calls = raw as? [[String: Any]] else {
            valid = false
            return false
        }
        for call in calls {
            guard let index = call["index"] as? Int, index >= 0 else {
                valid = false
                return false
            }
            var partial = partials[index] ?? Partial()
            if let rawID = call["id"] {
                guard let id = rawID as? String, !id.isEmpty,
                      partial.id == nil || partial.id == id else {
                    valid = false
                    return false
                }
                partial.id = id
            }
            if let rawType = call["type"] {
                guard let type = rawType as? String, type == "function",
                      partial.type == nil || partial.type == type else {
                    valid = false
                    return false
                }
                partial.type = type
            }
            if let rawFunction = call["function"] {
                guard let function = rawFunction as? [String: Any] else {
                    valid = false
                    return false
                }
                partial.sawFunction = true
                if let rawName = function["name"] {
                    guard let name = rawName as? String else {
                        valid = false
                        return false
                    }
                    partial.name += name
                }
                if let rawArguments = function["arguments"] {
                    guard let arguments = rawArguments as? String else {
                        valid = false
                        return false
                    }
                    partial.arguments += arguments
                }
            }
            partials[index] = partial
        }
        return true
    }

    func completedCalls() -> [[String: Any]]? {
        guard valid else { return nil }
        var result: [[String: Any]] = []
        for index in partials.keys.sorted() {
            guard let partial = partials[index], let id = partial.id,
                  partial.type == "function", partial.sawFunction,
                  !partial.name.isEmpty else { return nil }
            result.append([
                "id": id,
                "type": "function",
                "function": ["name": partial.name, "arguments": partial.arguments],
            ])
        }
        return result
    }
}

private struct MistralUsage: Decodable {
    let prompt_tokens: Int?
    let completion_tokens: Int?
    let prompt_tokens_details: PromptTokensDetails?

    struct PromptTokensDetails: Decodable {
        let cached_tokens: Int?
    }

    init(
        prompt_tokens: Int? = nil,
        completion_tokens: Int? = nil,
        prompt_tokens_details: PromptTokensDetails? = nil
    ) {
        self.prompt_tokens = prompt_tokens
        self.completion_tokens = completion_tokens
        self.prompt_tokens_details = prompt_tokens_details
    }
}

extension MistralService {
    fileprivate static func parseUsage(_ usage: MistralUsage?) -> UsageBreakdown {
        guard let usage else { return UsageBreakdown() }
        let cached = usage.prompt_tokens_details?.cached_tokens ?? 0
        let total = usage.prompt_tokens ?? 0
        return UsageBreakdown(
            promptTokens: max(0, total - cached),
            cachedInputTokens: cached,
            cacheCreation5mTokens: 0,
            cacheCreation1hTokens: 0,
            completionTokens: usage.completion_tokens ?? 0,
            reasoningTokens: 0,
            upstreamCost: nil,
            cacheReadObserved: usage.prompt_tokens_details?.cached_tokens != nil
        )
    }

    #if DEBUG
    static func parseUsageForTesting(
        promptTokens: Int?,
        completionTokens: Int?,
        cachedTokens: Int?
    ) -> UsageBreakdown {
        let usage = MistralUsage(
            prompt_tokens: promptTokens,
            completion_tokens: completionTokens,
            prompt_tokens_details: cachedTokens.map { MistralUsage.PromptTokensDetails(cached_tokens: $0) }
        )
        return parseUsage(usage)
    }
    #endif
}

private struct MistralChatCompletionResponse: Decodable {
    let choices: [MistralChoice]
    let usage: MistralUsage?
}

private struct MistralChoice: Decodable {
    let message: MistralMessage
}

private struct MistralMessage: Decodable {
    let content: OpenAIChatMessageContent?
    let tool_calls: [ChatCompletionToolCall]?
    let rawContent: MetadataClient.JSONValue?
    let rawToolCalls: [MetadataClient.JSONValue]?

    private enum CodingKeys: String, CodingKey { case content, tool_calls }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try container.decodeIfPresent(OpenAIChatMessageContent.self, forKey: .content)
        tool_calls = try container.decodeIfPresent([ChatCompletionToolCall].self, forKey: .tool_calls)
        rawContent = try container.decodeIfPresent(MetadataClient.JSONValue.self, forKey: .content)
        rawToolCalls = try container.decodeIfPresent([MetadataClient.JSONValue].self, forKey: .tool_calls)
    }
}

private struct MistralStreamChunk: Decodable {
    let choices: [MistralStreamChoice]?
    let usage: MistralUsage?
}

private struct MistralStreamChoice: Decodable {
    let delta: MistralDelta?
    var finish_reason: String?
}

private struct MistralDelta: Decodable {
    var tool_calls: [OpenAICompatibleChunk.Choice.ToolCallDelta]?
    let content: OpenAIChatMessageContent?
}
