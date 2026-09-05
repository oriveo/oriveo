import Foundation
import OriveoProviderKit

final class DeepSeekService: BaseAPIService, ProviderServiceProtocol, BalanceQueryable {
    private let baseURL = "https://api.deepseek.com/v1"

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
        let response: DeepSeekChatCompletionResponse = try await perform(request)
        guard let choice = response.choices.first else {
            throw ProviderServiceError.emptyResponse
        }
        let text = (choice.message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ProviderServiceError.emptyResponse
        }
        let continuationRecipe = Self.reasoningReplayRecipe(
            modelID: modelID, reasoningMode: reasoningMode
        )
        if let encoded = RecipeContinuationRuntime.jsonValue([
            Self.assistantReplayMessage(choice.message)
        ]) {
            try RecipeContinuationRuntime.save(
                messageID: requestOptions.localContinuationMessageID,
                recipe: continuationRecipe,
                state: ["assistantMessages": encoded]
            )
        }

        let breakdown = Self.parseUsage(response.usage)
        let (cost, source) = await MetadataClient.shared.calcCost(
            breakdown: breakdown, modelID: modelID, providerKind: .deepseek
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
                        providerKind: .deepseek,
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

                    var assembler = OpenAICompatibleStreamAssembler(profile: .deepSeek)
                    var streamState = OpenAICompatibleStreamState()

                    for try await line in bytes.utf8Lines {
                        try Task.checkCancellation()
                        for event in streamState.consume(try assembler.ingest(line)) {
                            continuation.yield(event)
                        }
                        if assembler.isDone { break }
                    }
                    try Task.checkCancellation()
                    for event in streamState.consume(try assembler.finish()) {
                        continuation.yield(event)
                    }

                    // DeepSeek requires the previous assistant turn's opaque thinking material on
                    // an explicit continuation.  Save only a fully assembled production response;
                    // partial/cancelled streams deliberately have no replay state.
                    let continuationRecipe = Self.reasoningReplayRecipe(
                        modelID: modelID, reasoningMode: reasoningMode
                    )
                    if let encoded = RecipeContinuationRuntime.jsonValue([Self.assistantReplayMessage(
                        content: streamState.accumulatedText,
                        reasoningContent: streamState.accumulatedReasoning,
                        toolCalls: streamState.toolCalls
                    )]) {
                        try RecipeContinuationRuntime.save(
                            messageID: requestOptions.localContinuationMessageID,
                            recipe: continuationRecipe,
                            state: ["assistantMessages": encoded]
                        )
                    }

                    let finalText = streamState.accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let breakdown = streamState.usageBreakdown
                    let (cost, source) = await MetadataClient.shared.calcCost(
                        breakdown: breakdown, modelID: modelID, providerKind: .deepseek
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
        let origin = balanceOriginFrom(baseURL, fallback: "https://api.deepseek.com")
        guard let url = URL(string: "\(origin)/user/balance") else {
            throw BalanceQueryError.network(detail: "Invalid DeepSeek balance URL.")
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
            throw BalanceQueryError.keyInvalid(detail: "DeepSeek rejected API key (\(http.statusCode)).")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw BalanceQueryError.network(detail: "DeepSeek /user/balance HTTP \(http.statusCode).")
        }
        struct BalanceResponse: Decodable {
            struct Info: Decodable {
                let currency: String?
                let total_balance: String?
                let granted_balance: String?
                let topped_up_balance: String?
            }
            let is_available: Bool?
            let balance_infos: [Info]?
        }
        let decoded: BalanceResponse
        do {
            decoded = try decoder.decode(BalanceResponse.self, from: data)
        } catch {
            throw BalanceQueryError.decoding(detail: error.localizedDescription)
        }
        let infos = decoded.balance_infos ?? []
        let info = infos.first(where: { $0.currency?.uppercased() == "USD" }) ?? infos.first
        let currency = info?.currency ?? "USD"
        let total = Double(info?.total_balance ?? "") ?? 0
        let granted = Double(info?.granted_balance ?? "")
        let topUp = Double(info?.topped_up_balance ?? "")
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
        stream: Bool,
        reasoningMode: ReasoningMode,
        requestOptions: ChatRequestOptions = ChatRequestOptions()
    ) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "\(baseURL)/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = stream ? 120 : 60
        applyHeaders(to: &request, apiKey: apiKey)
        let resolved = MetadataClient.shared.syncResolveCatalogModel(modelID: modelID, providerKind: .deepseek)
        let recipeLegacyInput = CapabilityRecipeRequestCompiler.legacyInput(
            providerKind: .deepseek, modelID: modelID,
            webSearchEnabled: requestOptions.webIntentRequested, reasoningMode: reasoningMode
        )
        let replayAssistantMessages = Self.reasoningReplayRecipe(
            modelID: modelID, reasoningMode: reasoningMode
        ).flatMap { _ in
            RecipeContinuationRuntime.replayAssistantMessages(
                explicitMessageID: requestOptions.localExplicitContinuationMessageID
            )
        }
        let requestMessagesInput = replayAssistantMessages == nil ? messages : messages.filter {
            $0.id != requestOptions.localExplicitContinuationMessageID
        }
        let capabilityIntent = CapabilityEvidenceProductionAdapter.finalChatIntent(
            messages: requestMessagesInput, request: request, effectiveTransport: resolved?.transport ?? "",
            model: requestOptions.capabilityEvidenceModel,
            requestedReasoningMode: recipeLegacyInput.reasoningMode, webSearchEnabled: requestOptions.webIntentRequested
        )

        var apiMessages: [[String: Any]] = []
        let systemPrompt = requestOptions.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !systemPrompt.isEmpty {
            apiMessages.append(["role": "system", "content": systemPrompt])
        }
        apiMessages.append(contentsOf: capabilityIntent.outboundMessages.map { Self.buildRequestMessage($0) })
        // `localExplicitContinuationMessageID` is set only by ChatManager's continue/retry
        // action. A normal new send cannot load sidecar state, even if it shares a model.
        if let replayAssistantMessages {
            let insertAt = apiMessages.lastIndex(where: { $0["role"] as? String == "user" }) ?? apiMessages.count
            apiMessages.insert(contentsOf: replayAssistantMessages, at: insertAt)
        }
        var payload: [String: Any] = [
            "model": modelID,
            "messages": apiMessages,
        ]
        if stream {
            payload["stream"] = true
            payload["stream_options"] = ["include_usage": true]
        }
        if recipeLegacyInput.usesLegacyMapping,
           let allowedReasoningMode = capabilityIntent.reasoningMode,
           let reasoningMerge = ProfileParamsResolver.reasoningMergeParams(
            providerKind: .deepseek,
            modelID: modelID,
            reasoningMode: allowedReasoningMode,
            resolved: resolved
        ) {
            ProfileParamsResolver.deepMerge(&payload, reasoningMerge)
        }

        CapabilityRecipeRequestCompiler.apply(
            to: &payload, providerKind: .deepseek, modelID: modelID,
            transport: resolved?.transport ?? "", webSearchEnabled: requestOptions.webIntentRequested,
            reasoningMode: reasoningMode, capabilityPreferences: requestOptions.capabilityPreferences
        )
        request.httpBody = try encodeChatBody(&payload, options: requestOptions, resolved: resolved, finalRequest: request)
        return request
    }

    static func buildRequestMessageForTest(_ msg: ChatMessage, model: AIModel? = nil) -> [String: Any] {
        buildRequestMessage(msg, model: model)
    }

    private static func buildRequestMessage(_ msg: ChatMessage, model: AIModel? = nil) -> [String: Any] {
        let attachments = msg.attachments ?? []
        let (text, _) = BaseAPIService.injectFileAttachmentsAsText(
            userText: msg.text,
            attachments: attachments,
            provider: .deepseek,
            model: model,
            imagePlaceholderText: "[Image omitted: unsupported by DeepSeek]"
        )
        return [
            "role": msg.role.rawValue,
            "content": text,
        ]
    }

    private static func reasoningReplayRecipe(
        modelID: String, reasoningMode: ReasoningMode
    ) -> MetadataClient.CapabilityRecipe? {
        RecipeContinuationRuntime.selectedRecipe(
            provider: .deepseek, modelID: modelID, transport: "openai_chat",
            webSearchEnabled: false, reasoningMode: reasoningMode,
            continuationKind: "replay_reasoning", parser: { $0 == "deepseek_reasoning_v1" }
        )
    }

    /// Keep DeepSeek's assistant frame in its native form. In particular,
    /// `reasoning_content` is not a UI-only representation and `tool_calls` remains a
    /// complete protocol object with its raw JSON arguments.
    private static func assistantReplayMessage(_ message: DeepSeekMessage) -> [String: Any] {
        assistantReplayMessage(
            content: message.content ?? "",
            reasoningContent: message.reasoning_content ?? "",
            toolCalls: message.tool_calls ?? []
        )
    }

    private static func assistantReplayMessage(
        content: String, reasoningContent: String, toolCalls: [ProviderToolCall]
    ) -> [String: Any] {
        CapabilityRecipeExecution.deepSeekReplayAssistant(
            content: content, reasoningContent: reasoningContent,
            toolCalls: toolCalls.map { call in
                var value: [String: Any] = [
                    "type": "function",
                    "function": ["name": call.name, "arguments": call.rawArguments],
                ]
                if let id = call.providerCallID, !id.isEmpty { value["id"] = id }
                return value
            }
        )
    }

    private static func assistantReplayMessage(
        content: String, reasoningContent: String, toolCalls: [DeepSeekToolCall]
    ) -> [String: Any] {
        CapabilityRecipeExecution.deepSeekReplayAssistant(
            content: content, reasoningContent: reasoningContent,
            toolCalls: toolCalls.map(\.foundationValue)
        )
    }

    private static let knownTextModelIDs = [
        "deepseek-v4-flash",
        "deepseek-v4-pro",
    ]

    private func buildModels(from remoteModels: [DeepSeekMetadataModel], preferredModelID: String?) async -> [AIModel] {
        let normalizedPreferredID = preferredModelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        var models: [AIModel] = []
        models.reserveCapacity(remoteModels.count)

        for remote in remoteModels {
            var model = await CatalogModelBuilder.buildCatalogModel(
                providerKind: .deepseek,
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

private struct DeepSeekMetadataModel {
    let id: String
}

private struct DeepSeekUsage: Decodable {
    let prompt_tokens: Int?
    let completion_tokens: Int?
    let prompt_cache_hit_tokens: Int?
    let prompt_cache_miss_tokens: Int?
    let completion_tokens_details: CompletionTokensDetails?

    struct CompletionTokensDetails: Decodable {
        let reasoning_tokens: Int?
    }

    init(
        prompt_tokens: Int? = nil,
        completion_tokens: Int? = nil,
        prompt_cache_hit_tokens: Int? = nil,
        prompt_cache_miss_tokens: Int? = nil,
        completion_tokens_details: CompletionTokensDetails? = nil
    ) {
        self.prompt_tokens = prompt_tokens
        self.completion_tokens = completion_tokens
        self.prompt_cache_hit_tokens = prompt_cache_hit_tokens
        self.prompt_cache_miss_tokens = prompt_cache_miss_tokens
        self.completion_tokens_details = completion_tokens_details
    }
}

extension DeepSeekService {
    fileprivate static func parseUsage(_ usage: DeepSeekUsage?) -> UsageBreakdown {
        guard let usage else { return UsageBreakdown() }
        let cached = usage.prompt_cache_hit_tokens ?? 0
        let nonCached = usage.prompt_cache_miss_tokens ?? usage.prompt_tokens ?? 0
        return UsageBreakdown(
            promptTokens: nonCached,
            cachedInputTokens: cached,
            cacheCreation5mTokens: 0,
            cacheCreation1hTokens: 0,
            completionTokens: usage.completion_tokens ?? 0,
            reasoningTokens: usage.completion_tokens_details?.reasoning_tokens ?? 0,
            upstreamCost: nil,
            cacheReadObserved: usage.prompt_cache_hit_tokens != nil
        )
    }

    #if DEBUG
    static func parseUsageForTesting(
        promptTokens: Int?,
        completionTokens: Int?,
        cacheHit: Int?,
        cacheMiss: Int?
    ) -> UsageBreakdown {
        let usage = DeepSeekUsage(
            prompt_tokens: promptTokens,
            completion_tokens: completionTokens,
            prompt_cache_hit_tokens: cacheHit,
            prompt_cache_miss_tokens: cacheMiss
        )
        return parseUsage(usage)
    }
    #endif
}

private struct DeepSeekChatCompletionResponse: Decodable {
    let choices: [DeepSeekChoice]
    let usage: DeepSeekUsage?
}

private struct DeepSeekChoice: Decodable {
    let message: DeepSeekMessage
}

private struct DeepSeekMessage: Decodable {
    let content: String?
    let reasoning_content: String?
    let tool_calls: [DeepSeekToolCall]?
}

private struct DeepSeekToolCall: Decodable {
    let id: String?
    let type: String?
    let function: Function

    struct Function: Decodable {
        let name: String
        let arguments: String
    }

    var foundationValue: [String: Any] {
        var value: [String: Any] = [
            "type": type ?? "function",
            "function": ["name": function.name, "arguments": function.arguments],
        ]
        if let id, !id.isEmpty { value["id"] = id }
        return value
    }
}
