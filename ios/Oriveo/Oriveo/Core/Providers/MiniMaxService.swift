import Foundation
import CoreFoundation
import OriveoProviderKit

final class MiniMaxService: BaseAPIService, ProviderServiceProtocol, CustomBaseURLProvider {
    private let defaultBaseURL = "https://api.minimax.io/v1"


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
            providerKind: .miniMax
        )

        if let attachments = try await miniMaxImageAttachmentsIfImageModel(
            apiKey: apiKey, modelID: modelID, messages: messages, baseURL: baseURL, resolved: resolved
        ) {
            return ProviderChatResult(
                text: "", promptTokens: 0, completionTokens: 0, estimatedCost: 0, attachments: attachments
            )
        }

        if let recipe = Self.exactAnthropicWebRecipe(
            modelID: modelID,
            requested: requestOptions.capabilityPreferences?.web == .automatic
        ) {
            return try await sendAnthropicWebMessage(
                recipe: recipe, apiKey: apiKey, modelID: modelID, messages: messages,
                baseURL: baseURL, requestOptions: requestOptions
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
        let response: MiniMaxChatCompletionResponse = try await perform(request)
        guard let choice = response.choices.first else {
            throw ProviderServiceError.emptyResponse
        }
        var tagParser = ThinkingTagParser()
        let parsed = tagParser.parse(choice.message.content ?? "", final: true)
        let text = parsed.compactMap { segment -> String? in
            if case let .text(value) = segment { return value }
            return nil
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let taggedReasoningText = parsed.compactMap { segment -> String? in
            if case let .reasoning(value) = segment { return value }
            return nil
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let splitReasoningText = Self.visibleReasoningText(choice.message.reasoning_details)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let reasoningText = splitReasoningText.isEmpty ? taggedReasoningText : splitReasoningText
        let toolCalls = OpenAIService.nonStreamingToolCalls(choice.message.tool_calls)
        guard !text.isEmpty || !toolCalls.isEmpty else {
            throw ProviderServiceError.emptyResponse
        }
        let continuationRecipe = Self.reasoningReplayRecipe(
            modelID: modelID, reasoningMode: reasoningMode
        )
        let replayDetails = choice.message.reasoning_details?.compactMap {
            $0.foundationValue as? [String: Any]
        }
        let replayToolCalls = choice.message.rawToolCalls?.compactMap {
            $0.foundationValue as? [String: Any]
        }
        if replayDetails?.count == choice.message.reasoning_details?.count,
           replayToolCalls?.count == choice.message.rawToolCalls?.count,
           let replayMessage = CapabilityRecipeExecution.miniMaxReplayAssistant(
                content: choice.message.rawContent?.foundationValue,
                reasoningDetails: replayDetails,
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
            breakdown: breakdown, modelID: modelID, providerKind: .miniMax
        )
        return ProviderChatResult(
            text: text,
            reasoningText: reasoningText.isEmpty ? nil : reasoningText,
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
        requestOptions: ChatRequestOptions = ChatRequestOptions()
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try self.validateAPIKey(apiKey)
                    guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw ProviderServiceError.invalidConfiguration(detail: "Missing model identifier.")
                    }

                    if let recipe = Self.exactAnthropicWebRecipe(
                        modelID: modelID,
                        requested: requestOptions.capabilityPreferences?.web == .automatic
                    ) {
                        for try await event in self.sendAnthropicWebMessageStream(
                            recipe: recipe, apiKey: apiKey, modelID: modelID, messages: messages,
                            baseURL: baseURL, requestOptions: requestOptions
                        ) {
                            continuation.yield(event)
                        }
                        continuation.finish()
                        return
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
                        providerKind: .miniMax,
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
                    var lastUsage: MiniMaxUsage?
                    var tagParser = ThinkingTagParser()
                    var replayAccumulator = MiniMaxAssistantReplayStreamAccumulator()
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
                        replayAccumulator.ingest(chunkData)
                        let chunk: MiniMaxStreamChunk
                        do {
                            chunk = try self.decoder.decode(MiniMaxStreamChunk.self, from: chunkData)
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
                        if let delta = chunk.choices?.first?.delta,
                           let content = delta.content, !content.isEmpty {
                            for segment in tagParser.parse(content) {
                                switch segment {
                                case let .text(text):
                                    accumulatedText += text
                                    continuation.yield(.delta(text))
                                case let .reasoning(reasoning):
                                    accumulatedReasoning += reasoning
                                    continuation.yield(.reasoning(reasoning))
                                }
                            }
                        }
                        if let reasoningDetails = chunk.choices?.first?.delta?.reasoning_details {
                            let reasoning = Self.visibleReasoningText(reasoningDetails)
                            if !reasoning.isEmpty {
                                accumulatedReasoning += reasoning
                                continuation.yield(.reasoning(reasoning))
                            }
                        }
                    }

                    if let flushed = toolCallDecoder.finishEvent() { continuation.yield(flushed) }
                    for segment in tagParser.parse("", final: true) {
                        switch segment {
                        case let .text(text):
                            accumulatedText += text
                            continuation.yield(.delta(text))
                        case let .reasoning(reasoning):
                            accumulatedReasoning += reasoning
                            continuation.yield(.reasoning(reasoning))
                        }
                    }

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
                    let finalReasoning = accumulatedReasoning.trimmingCharacters(in: .whitespacesAndNewlines)
                    let breakdown = Self.parseUsage(lastUsage)
                    let (cost, source) = await MetadataClient.shared.calcCost(
                        breakdown: breakdown, modelID: modelID, providerKind: .miniMax
                    )
                    let result = ProviderChatResult(
                        text: finalText,
                        reasoningText: finalReasoning.isEmpty ? nil : finalReasoning,
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


    private func miniMaxImageAttachmentsIfImageModel(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        baseURL: String?,
        resolved: MetadataClient.ResolvedModelMetadata?
    ) async throws -> [Attachment]? {
        guard try imageRouteOrThrow(resolved: resolved) == .minimaxImageGeneration else { return nil }

        let prompt = messages.last?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !prompt.isEmpty else { throw ProviderServiceError.emptyResponse }

        let requestBaseURL = normalizedBaseURL(baseURL, default: defaultBaseURL)
        guard let url = URL(string: "\(requestBaseURL)/image_generation") else {
            throw ProviderServiceError.invalidConfiguration(detail: "Invalid MiniMax image endpoint.")
        }
        let requestDefaults = MetadataClient.shared.syncImageGenRequestDefaults(profileName: resolved?.profiles.imageGen)
        return try await generateImageViaMiniMaxImageGeneration(
            apiKey: apiKey, modelID: modelID, prompt: prompt, url: url, requestDefaults: requestDefaults
        )
    }


    private static func exactAnthropicWebRecipe(
        modelID: String, requested: Bool
    ) -> MetadataClient.CapabilityRecipe? {
        guard requested,
              let recipe = MetadataClient.shared.syncCapabilityRecipe(
                modelID: modelID, providerKind: .miniMax, capability: "web"
              ),
              recipe.id == "minimax.messages.web.v1",
              recipe.executionKind == "endpoint_route",
              recipe.transport.protocolName == "openai_chat",
              recipe.responseParserKind == "minimax_anthropic_web_v1",
              recipe.continuationKind == "replay_blocks",
              let route = recipe.route,
              route.sourceProtocol == "openai_chat",
              route.protocolName == "anthropic_messages",
              route.endpointClass == "messages",
              route.path == "/anthropic/v1/messages",
              route.method == "POST",
              route.authMode == "x_api_key",
              route.authHeader == "x-api-key",
              route.headers == ["Content-Type": "application/json", "anthropic-version": "2023-06-01"],
              route.requestMapper == "minimax_anthropic_messages_v1"
        else { return nil }
        return recipe
    }

    private func buildAnthropicWebRequest(
        recipe: MetadataClient.CapabilityRecipe,
        modelID: String,
        messages: [ChatMessage],
        apiKey: String,
        baseURL: String?,
        stream: Bool,
        requestOptions: ChatRequestOptions
    ) throws -> URLRequest {
        guard let route = recipe.route,
              let endpoint = Self.alternateRouteURL(
                base: normalizedBaseURL(baseURL, default: defaultBaseURL), path: route.path
              ) else {
            throw ProviderServiceError.invalidConfiguration(detail: "Invalid MiniMax web route.")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = route.method
        request.timeoutInterval = stream ? 120 : 60
        request.setValue(apiKey, forHTTPHeaderField: route.authHeader ?? "")
        route.headers?.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        let resolved = MetadataClient.shared.syncResolveCatalogModel(modelID: modelID, providerKind: .miniMax)
        let replay = RecipeContinuationRuntime.replayBlocks(
            explicitMessageID: requestOptions.localExplicitContinuationMessageID
        )
        let requestMessages = replay == nil ? messages : messages.filter {
            $0.id != requestOptions.localExplicitContinuationMessageID
        }
        var body: [String: Any] = [
            "model": modelID,
            "max_tokens": resolved?.maxOutputTokens ?? 8192,
            "stream": stream,
            "messages": requestMessages.map { Self.buildAnthropicWebMessage($0) },
        ]
        let system = requestOptions.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !system.isEmpty { body["system"] = system }
        CapabilityRecipeRequestCompiler.apply(
            to: &body, providerKind: .miniMax, modelID: modelID, transport: "openai_chat",
            webSearchEnabled: true, reasoningMode: .automatic,
            capabilityPreferences: requestOptions.capabilityPreferences
        )
        guard let tools = body["tools"] as? [[String: Any]], tools.count == 1,
              tools[0]["type"] as? String == "web_search_20250305",
              tools[0]["name"] as? String == "web_search" else {
            throw ProviderServiceError.invalidConfiguration(detail: "Invalid MiniMax web-search recipe.")
        }
        if let replay {
            var wire = body["messages"] as? [[String: Any]] ?? []
            let insertAt = wire.lastIndex { $0["role"] as? String == "user" } ?? wire.count
            wire.insert(["role": "assistant", "content": replay], at: insertAt)
            body["messages"] = wire
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        CapabilityExecutionRuntime.confirmFinalWireEncoded()
        return request
    }

    private static func alternateRouteURL(base: String, path: String) -> URL? {
        guard let baseURL = URL(string: base), var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              path.hasPrefix("/"), !path.contains("..") else { return nil }
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func buildAnthropicWebMessage(_ message: ChatMessage) -> [String: Any] {
        let (text, _) = BaseAPIService.injectFileAttachmentsAsText(
            userText: message.text, attachments: message.attachments ?? [], provider: .miniMax, model: nil
        )
        return ["role": message.role.rawValue, "content": text]
    }

    private func sendAnthropicWebMessage(
        recipe: MetadataClient.CapabilityRecipe,
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        baseURL: String?,
        requestOptions: ChatRequestOptions
    ) async throws -> ProviderChatResult {
        let request = try buildAnthropicWebRequest(
            recipe: recipe, modelID: modelID, messages: messages, apiKey: apiKey,
            baseURL: baseURL, stream: false, requestOptions: requestOptions
        )
        let (data, _) = try await performRaw(request)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = root["content"] as? [[String: Any]],
              let finalizedBlocks = Self.finalizedAnthropicWebBlocks(
                Dictionary(uniqueKeysWithValues: blocks.enumerated().map { ($0.offset, $0.element) }), inputs: [:]
              ) else {
            throw ProviderServiceError.network(detail: "Decoding failed.")
        }
        let text = finalizedBlocks.compactMap { $0["text"] as? String }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let reasoning = finalizedBlocks.compactMap { $0["thinking"] as? String }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var citationAccumulator = CitationAccumulator()
        for block in finalizedBlocks where block["type"] as? String == "web_search_tool_result" {
            for item in block["content"] as? [[String: Any]] ?? [] {
                guard let url = item["url"] as? String else { continue }
                citationAccumulator.ingest(Citation(
                    url: url, title: item["title"] as? String, snippet: item["content"] as? String,
                    faviconUrl: nil, index: nil, startIndex: nil, endIndex: nil
                ))
            }
        }
        if let value = RecipeContinuationRuntime.jsonValue(finalizedBlocks) {
            try RecipeContinuationRuntime.save(
                messageID: requestOptions.localContinuationMessageID,
                recipe: recipe, state: ["blocks": value]
            )
        }
        let usage = root["usage"] as? [String: Any]
        let breakdown = UsageBreakdown(
            promptTokens: usage?["input_tokens"] as? Int ?? 0,
            completionTokens: usage?["output_tokens"] as? Int ?? 0
        )
        let (cost, source) = await MetadataClient.shared.calcCost(
            breakdown: breakdown, modelID: modelID, providerKind: .miniMax
        )
        return ProviderChatResult(
            text: text,
            reasoningText: reasoning.isEmpty ? nil : reasoning,
            promptTokens: breakdown.totalInputTokens,
            completionTokens: breakdown.completionTokens,
            estimatedCost: cost, usageBreakdown: breakdown, costSource: source,
            citations: citationAccumulator.citations.isEmpty ? nil : citationAccumulator.citations
        )
    }

    private func sendAnthropicWebMessageStream(
        recipe: MetadataClient.CapabilityRecipe,
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        baseURL: String?,
        requestOptions: ChatRequestOptions
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try self.buildAnthropicWebRequest(
                        recipe: recipe, modelID: modelID, messages: messages, apiKey: apiKey,
                        baseURL: baseURL, stream: true, requestOptions: requestOptions
                    )
                    CapabilityExecutionRuntime.confirmRequestDispatched()
                    let (bytes, response) = try await self.session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw ProviderServiceError.network(detail: "Missing HTTPURLResponse.")
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var data = Data(); for try await byte in bytes { data.append(byte) }
                        throw self.mapHTTPError(statusCode: http.statusCode, data: data)
                    }
                    let strategy = AnthropicMessagesStrategy()
                    let shape = MetadataClient.StreamShape(
                        reasoningDeltaPath: nil, citationsBlockType: "web_search_tool_result",
                        citationsArrayPath: nil, citationUrlField: "url", citationTitleField: "title",
                        citationSnippetField: "content", imageDataPath: nil
                    )
                    var context = StreamContext()
                    var citationCount = 0
                    var inputTokens = 0
                    var outputTokens = 0
                    var blocks: [Int: [String: Any]] = [:]
                    var inputFragments: [Int: String] = [:]
                    var terminal = false
                    var replayStateValid = true
                    for try await line in bytes.utf8Lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        guard let data = payload.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = object["type"] as? String else { continue }
                        for event in strategy.parseStreamLine(payload, ctx: &context, shape: shape) {
                            switch event {
                            case .delta, .reasoning, .toolCallDeltas: continuation.yield(event)
                            default: break
                            }
                        }
                        if context.citationsAccumulator.citations.count > citationCount {
                            citationCount = context.citationsAccumulator.citations.count
                            continuation.yield(.citations(context.citationsAccumulator.citations))
                        }
                        let index = object["index"] as? Int ?? 0
                        switch type {
                        case "message_start":
                            inputTokens = ((object["message"] as? [String: Any])?["usage"] as? [String: Any])?["input_tokens"] as? Int ?? 0
                        case "content_block_start":
                            if let block = object["content_block"] as? [String: Any],
                               Self.validAnthropicWebBlock(block, partial: true) {
                                blocks[index] = block
                            } else {
                                replayStateValid = false
                            }
                        case "content_block_delta":
                            if let delta = object["delta"] as? [String: Any] {
                                replayStateValid = Self.mergeAnthropicWebDelta(
                                    delta, block: &blocks[index], input: &inputFragments[index]
                                ) && replayStateValid
                            } else { replayStateValid = false }
                        case "message_delta":
                            outputTokens = (object["usage"] as? [String: Any])?["output_tokens"] as? Int ?? outputTokens
                        case "message_stop": terminal = true
                        default: break
                        }
                    }
                    for event in AnthropicMessagesStrategy.flushToolCalls(ctx: &context) { continuation.yield(event) }
                    try Task.checkCancellation()
                    if terminal, replayStateValid,
                       let finalized = Self.finalizedAnthropicWebBlocks(blocks, inputs: inputFragments),
                       let value = RecipeContinuationRuntime.jsonValue(finalized) {
                        try RecipeContinuationRuntime.save(
                            messageID: requestOptions.localContinuationMessageID,
                            recipe: recipe, state: ["blocks": value]
                        )
                    }
                    let finalizedReasoning = context.accumulatedReasoning
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let breakdown = UsageBreakdown(
                        promptTokens: inputTokens, completionTokens: outputTokens
                    )
                    let (cost, source) = await MetadataClient.shared.calcCost(
                        breakdown: breakdown, modelID: modelID, providerKind: .miniMax
                    )
                    continuation.yield(.done(ProviderChatResult(
                        text: context.accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines),
                        reasoningText: finalizedReasoning.isEmpty ? nil : finalizedReasoning,
                        promptTokens: breakdown.totalInputTokens,
                        completionTokens: breakdown.completionTokens,
                        estimatedCost: cost, usageBreakdown: breakdown, costSource: source
                    )))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func mergeAnthropicWebDelta(
        _ delta: [String: Any], block: inout [String: Any]?, input: inout String?
    ) -> Bool {
        guard var current = block, let type = delta["type"] as? String else { block = nil; return false }
        switch type {
        case "text_delta":
            guard let piece = delta["text"] as? String else { block = nil; return false }
            current["text"] = (current["text"] as? String ?? "") + piece
        case "thinking_delta":
            guard let piece = delta["thinking"] as? String else { block = nil; return false }
            current["thinking"] = (current["thinking"] as? String ?? "") + piece
        case "signature_delta":
            guard let piece = delta["signature"] as? String else { block = nil; return false }
            current["signature"] = (current["signature"] as? String ?? "") + piece
        case "input_json_delta":
            guard let piece = delta["partial_json"] as? String else { block = nil; return false }
            input = (input ?? "") + piece
        default: return false
        }
        block = current
        return true
    }

    private static func finalizedAnthropicWebBlocks(
        _ blocks: [Int: [String: Any]], inputs: [Int: String]
    ) -> [[String: Any]]? {
        guard !blocks.isEmpty else { return nil }
        var result: [[String: Any]] = []
        for index in blocks.keys.sorted() {
            guard var block = blocks[index], let type = block["type"] as? String,
                  ["thinking", "redacted_thinking", "text", "server_tool_use", "web_search_tool_result"].contains(type)
            else { return nil }
            if let raw = inputs[index] {
                guard let data = raw.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                block["input"] = object
            }
            guard validAnthropicWebBlock(block, partial: false) else { return nil }
            result.append(block)
        }
        return result
    }

    private static func validAnthropicWebBlock(_ block: [String: Any], partial: Bool) -> Bool {
        guard let type = block["type"] as? String else { return false }
        switch type {
        case "thinking":
            return block["thinking"] is String && (partial || (block["signature"] as? String)?.isEmpty == false)
        case "redacted_thinking":
            return (block["data"] as? String)?.isEmpty == false
        case "text":
            return block["text"] is String
        case "server_tool_use":
            return (block["id"] as? String)?.isEmpty == false
                && block["name"] as? String == "web_search"
                && (partial || block["input"] is [String: Any])
        case "web_search_tool_result":
            guard (block["tool_use_id"] as? String)?.isEmpty == false,
                  let content = block["content"] as? [[String: Any]] else { return false }
            return content.allSatisfy {
                $0["type"] as? String == "web_search_result"
                    && ($0["url"] as? String)?.isEmpty == false
                    && $0["title"] is String && $0["content"] is String
            }
        default:
            return false
        }
    }

    private func buildChatRequest(
        modelID: String,
        messages: [ChatMessage],
        apiKey: String,
        baseURL: String? = nil,
        stream: Bool,
        reasoningMode: ReasoningMode,
        requestOptions: ChatRequestOptions = ChatRequestOptions()
    ) throws -> URLRequest {
        let requestBaseURL = normalizedBaseURL(baseURL, default: defaultBaseURL)
        var request = URLRequest(url: URL(string: "\(requestBaseURL)/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = stream ? 120 : 60
        applyHeaders(to: &request, apiKey: apiKey)
        let resolved = MetadataClient.shared.syncResolveCatalogModel(modelID: modelID, providerKind: .miniMax)
        let replayAssistantMessages = Self.reasoningReplayRecipe(
            modelID: modelID, reasoningMode: reasoningMode
        ).flatMap { _ in
            CapabilityRecipeExecution.miniMaxReplayAssistantMessages(
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

        var body: [String: Any] = ["model": modelID, "messages": apiMessages]
        if stream {
            body["stream"] = true
            body["stream_options"] = ["include_usage": true]
        }
        if let allowedReasoningMode = capabilityIntent.reasoningMode,
           let reasoningMerge = ProfileParamsResolver.reasoningMergeParams(
            providerKind: .miniMax,
            modelID: modelID,
            reasoningMode: allowedReasoningMode,
            resolved: resolved
        ) {
            ProfileParamsResolver.deepMerge(&body, reasoningMerge)
        }
        CapabilityRecipeRequestCompiler.apply(to: &body, providerKind: .miniMax, modelID: modelID, transport: resolved?.transport ?? "", webSearchEnabled: requestOptions.webIntentRequested, reasoningMode: reasoningMode, capabilityPreferences: requestOptions.capabilityPreferences)
        // MiniMax's continuation contract is meaningful only when the provider returns the
        // structured split fields. Force this at the final service-owned layer for every chat leg.
        body["reasoning_split"] = true
        request.httpBody = try encodeChatBody(&body, options: requestOptions, resolved: resolved, finalRequest: request)
        return request
    }

    private static func buildRequestMessage(_ msg: ChatMessage, model: AIModel? = nil) -> [String: Any] {
        let atts = msg.attachments ?? []
        let (text, _) = BaseAPIService.injectFileAttachmentsAsText(
            userText: msg.text,
            attachments: atts,
            provider: .miniMax,
            model: model
        )
        return ["role": msg.role.rawValue, "content": text]
    }

    private static func reasoningReplayRecipe(
        modelID: String, reasoningMode: ReasoningMode
    ) -> MetadataClient.CapabilityRecipe? {
        RecipeContinuationRuntime.selectedRecipe(
            provider: .miniMax, modelID: modelID, transport: "openai_chat",
            webSearchEnabled: false, reasoningMode: reasoningMode,
            continuationKind: "replay_reasoning", parser: { $0 == "minimax_reasoning_v1" }
        )
    }

    private static func visibleReasoningText(
        _ details: [MetadataClient.JSONValue]?
    ) -> String {
        details?.compactMap { detail -> String? in
            guard case let .object(values) = detail else { return nil }
            if case let .string(text)? = values["text"] { return text }
            if case let .string(summary)? = values["summary"] { return summary }
            return nil
        }.joined() ?? ""
    }



    private static let knownTextModelIDs = [
        "MiniMax-M2.5",
        "MiniMax-M2.7",
        "MiniMax-M2.1",
        "MiniMax-M2",
    ]

    private static func metadataBackedRemoteModels(modelIDs: [String]) -> [MiniMaxRemoteModel] {
        let sourceModelIDs = modelIDs.isEmpty ? knownTextModelIDs : modelIDs
        return sourceModelIDs.map { MiniMaxRemoteModel(id: $0) }
    }

    private func buildModels(from remoteModels: [MiniMaxRemoteModel], preferredModelID: String?) async -> [AIModel] {
        let normalizedPreferredID = preferredModelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        var models: [AIModel] = []
        models.reserveCapacity(remoteModels.count)

        for remote in remoteModels {
            var model = await CatalogModelBuilder.buildCatalogModel(
                providerKind: .miniMax,
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

        if let normalizedPreferredID, models.contains(where: { $0.id == normalizedPreferredID }) {
            return models
        }

        return selectDefaultBySortRank(models)
    }
}


private struct MiniMaxModelsResponse: Decodable {
    var data: [MiniMaxRemoteModel]
}

private struct MiniMaxRemoteModel: Decodable {
    var id: String
    var created: TimeInterval?
    var owned_by: String?
}

private struct MiniMaxChatCompletionResponse: Decodable {
    var choices: [Choice]
    var usage: MiniMaxUsage?

    struct Choice: Decodable {
        var message: Message

        struct Message: Decodable {
            let content: String?
            let tool_calls: [ChatCompletionToolCall]?
            let reasoning_details: [MetadataClient.JSONValue]?
            let rawContent: MetadataClient.JSONValue?
            let rawToolCalls: [MetadataClient.JSONValue]?

            private enum CodingKeys: String, CodingKey {
                case content, tool_calls, reasoning_details
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                if container.contains(.content) {
                    rawContent = try container.decodeNil(forKey: .content)
                        ? .null
                        : try container.decode(MetadataClient.JSONValue.self, forKey: .content)
                } else {
                    rawContent = nil
                }
                if case let .string(value)? = rawContent { content = value } else { content = nil }
                tool_calls = try container.decodeIfPresent([ChatCompletionToolCall].self, forKey: .tool_calls)
                rawToolCalls = try container.decodeIfPresent([MetadataClient.JSONValue].self, forKey: .tool_calls)
                reasoning_details = try container.decodeIfPresent(
                    [MetadataClient.JSONValue].self, forKey: .reasoning_details
                )
            }
        }
    }
}

private struct MiniMaxStreamChunk: Decodable {
    var choices: [MiniMaxStreamChoice]?
    var usage: MiniMaxUsage?
}

private struct MiniMaxStreamChoice: Decodable {
    var delta: MiniMaxStreamDelta?
    var finish_reason: String?
}

private struct MiniMaxStreamDelta: Decodable {
    var tool_calls: [OpenAICompatibleChunk.Choice.ToolCallDelta]?
    var content: String?
    var reasoning_details: [MetadataClient.JSONValue]?
}

/// Strictly reconstructs the provider-owned MiniMax assistant wire. Rendering remains independent:
/// a malformed future fragment disables only continuation and never rewrites it into guessed state.
struct MiniMaxAssistantReplayStreamAccumulator {
    private struct PartialCall {
        var id: String?
        var type: String?
        var name: String?
        var arguments = ""
    }

    private var valid = true
    private var sawContent = false
    private var content: Any = NSNull()
    private var details: [Int: [String: Any]] = [:]
    private var calls: [Int: PartialCall] = [:]

    mutating func ingest(_ data: Data) {
        guard valid else { return }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            valid = false
            return
        }
        guard let rawChoices = object["choices"] else { return }
        guard let choices = rawChoices as? [[String: Any]], let choice = choices.first else {
            valid = false
            return
        }
        guard choice["delta"] == nil || choice["delta"] is [String: Any] else {
            valid = false
            return
        }
        guard let delta = choice["delta"] as? [String: Any] else { return }

        if let incoming = delta["content"] {
            if let string = incoming as? String {
                let prefix = content as? String ?? ""
                content = prefix + string
                sawContent = true
            } else if incoming is NSNull {
                if !sawContent {
                    content = NSNull()
                    sawContent = true
                }
            } else {
                valid = false
            }
        }
        if let incoming = delta["reasoning_details"], !mergeDetails(incoming) {
            valid = false
        }
        if let incoming = delta["tool_calls"], !mergeCalls(incoming) {
            valid = false
        }
    }

    func completedAssistantMessage() -> [String: Any]? {
        guard valid, sawContent, !details.isEmpty else { return nil }
        let finalizedDetails = details.keys.sorted().compactMap { details[$0] }
        var finalizedCalls: [[String: Any]]?
        if !calls.isEmpty {
            var result: [[String: Any]] = []
            for index in calls.keys.sorted() {
                guard let call = calls[index], let id = call.id, !id.isEmpty,
                      call.type == "function", let name = call.name, !name.isEmpty else { return nil }
                result.append([
                    "id": id,
                    "type": "function",
                    "function": ["name": name, "arguments": call.arguments],
                ])
            }
            finalizedCalls = result
        }
        return CapabilityRecipeExecution.miniMaxReplayAssistant(
            content: content,
            reasoningDetails: finalizedDetails,
            toolCalls: finalizedCalls
        )
    }

    private mutating func mergeDetails(_ raw: Any) -> Bool {
        guard let incoming = raw as? [[String: Any]], !incoming.isEmpty else { return false }
        for (fallbackIndex, detail) in incoming.enumerated() {
            guard !detail.isEmpty else { return false }
            let index: Int
            if let rawIndex = detail["index"] {
                guard let parsed = miniMaxNonnegativeInteger(rawIndex) else { return false }
                index = parsed
            } else {
                index = fallbackIndex
            }
            var current = details[index] ?? [:]
            for (key, value) in detail {
                if ["text", "summary", "data"].contains(key),
                   let previous = current[key] as? String,
                   let fragment = value as? String {
                    current[key] = previous + fragment
                } else if current[key] == nil {
                    current[key] = value
                } else if !miniMaxJSONEqual(current[key] as Any, value) {
                    return false
                }
            }
            details[index] = current
        }
        return true
    }

    private mutating func mergeCalls(_ raw: Any) -> Bool {
        guard let incoming = raw as? [[String: Any]], !incoming.isEmpty else { return false }
        let allowedKeys: Set<String> = ["index", "id", "type", "function"]
        let functionKeys: Set<String> = ["name", "arguments"]
        for (fallbackIndex, item) in incoming.enumerated() {
            guard Set(item.keys).isSubset(of: allowedKeys) else { return false }
            let index: Int
            if let rawIndex = item["index"] {
                guard let parsed = miniMaxNonnegativeInteger(rawIndex) else { return false }
                index = parsed
            } else {
                index = fallbackIndex
            }
            var call = calls[index] ?? PartialCall()
            if let rawID = item["id"] {
                guard let id = rawID as? String, !id.isEmpty,
                      call.id == nil || call.id == id else { return false }
                call.id = id
            }
            if let rawType = item["type"] {
                guard let type = rawType as? String, type == "function",
                      call.type == nil || call.type == type else { return false }
                call.type = type
            }
            if let rawFunction = item["function"] {
                guard let function = rawFunction as? [String: Any],
                      Set(function.keys).isSubset(of: functionKeys) else { return false }
                if let rawName = function["name"] {
                    guard let name = rawName as? String, !name.isEmpty,
                          call.name == nil || call.name == name else { return false }
                    call.name = name
                }
                if let rawArguments = function["arguments"] {
                    guard let arguments = rawArguments as? String else { return false }
                    call.arguments += arguments
                }
            }
            guard item["id"] != nil || item["type"] != nil || item["function"] != nil else {
                return false
            }
            calls[index] = call
        }
        return true
    }
}

private func miniMaxNonnegativeInteger(_ value: Any) -> Int? {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let raw = number.doubleValue
    guard raw.isFinite, raw >= 0, raw.rounded(.towardZero) == raw,
          raw <= Double(Int.max) else { return nil }
    return Int(raw)
}

private func miniMaxJSONEqual(_ lhs: Any, _ rhs: Any) -> Bool {
    let left = ["value": lhs]
    let right = ["value": rhs]
    guard JSONSerialization.isValidJSONObject(left), JSONSerialization.isValidJSONObject(right),
          let leftData = try? JSONSerialization.data(withJSONObject: left, options: [.sortedKeys]),
          let rightData = try? JSONSerialization.data(withJSONObject: right, options: [.sortedKeys])
    else { return false }
    return leftData == rightData
}

private struct MiniMaxUsage: Decodable {
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

extension MiniMaxService {
    fileprivate static func parseUsage(_ usage: MiniMaxUsage?) -> UsageBreakdown {
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
        let usage = MiniMaxUsage(
            prompt_tokens: promptTokens,
            completion_tokens: completionTokens,
            total_tokens: nil,
            prompt_tokens_details: cachedTokens.map { MiniMaxUsage.PromptTokensDetails(cached_tokens: $0) },
            completion_tokens_details: reasoningTokens.map { MiniMaxUsage.CompletionTokensDetails(reasoning_tokens: $0) }
        )
        return parseUsage(usage)
    }
    #endif
}
