import Foundation
import CoreFoundation
import OriveoProviderKit

struct ProviderSyncResult {
    var models: [AIModel]
}

struct ProviderChatResult {
    var text: String
    var reasoningText: String? = nil
    var promptTokens: Int
    var completionTokens: Int
    var estimatedCost: Double
    var attachments: [Attachment]? = nil
    var servedModelID: String? = nil
    var usageBreakdown: UsageBreakdown? = nil
    var costSource: CostSource? = nil
    var toolCalls: [ProviderToolCall]? = nil
    var citations: [Citation]? = nil
}

/// Every failure a provider request can surface to the user.
enum ProviderServiceError: Error {
    case invalidAPIKey(detail: String)
    case quotaExceeded(detail: String)
    case modelUnavailable(detail: String)
    case rateLimited(detail: String)
    case emptyModelCatalog
    case emptyResponse
    case invalidConfiguration(detail: String)
    case network(detail: String)
    case upstream(statusCode: Int, detail: String)
    /// The user signed in with their own provider subscription (Codex, Grok) and that lane failed.
    case subscriptionFailure(
        lane: SubscriptionLane,
        kind: SubscriptionFailureKind,
        messageKey: String,
        detail: String
    )

    enum SubscriptionLane: String {
        case grok
        case openAI

        var titleKey: String {
            switch self {
            case .grok: return "Grok subscription"
            case .openAI: return "ChatGPT subscription"
            }
        }
    }

    enum SubscriptionFailureKind: String {
        case unavailable
        case ineligible
        case expired
        case quotaExhausted
    }


    /// Localized headline for the error banner.
    var title: String {
        if case .subscriptionFailure = self { return L10n.tr(titleKey, table: .providers) }
        return L10n.tr(titleKey)
    }

    var titleKey: String {
        switch self {
        case .invalidAPIKey:
            return "Invalid API Key"
        case .quotaExceeded:
            return "Provider Quota Reached"
        case .modelUnavailable:
            return "Model Unavailable"
        case .rateLimited:
            return "Provider Rate Limited"
        case .emptyModelCatalog:
            return "No Models Found"
        case .emptyResponse:
            return "Empty Provider Response"
        case .invalidConfiguration:
            return "Provider Configuration Error"
        case .network, .upstream:
            return "Provider Request Failed"
        case let .subscriptionFailure(lane, _, _, _):
            return lane.titleKey
        }
    }

    var message: String {
        if case .subscriptionFailure = self { return L10n.tr(messageKey, table: .providers) }
        return L10n.tr(messageKey)
    }

    var messageKey: String {
        switch self {
        case .invalidAPIKey:
            return "The API key could not be validated. Check the value or generate a new key."
        case .quotaExceeded:
            return "The provider reports that the quota or credit for this API key is used up. Check your billing with the provider, or switch models."
        case .modelUnavailable:
            return "This model is currently unavailable from the provider. Switch models or try again later."
        case .rateLimited:
            return "The provider is temporarily rate limiting this request. Please wait a moment and try again."
        case .emptyModelCatalog:
            return "The provider returned an empty model catalog, so we could not finish setup."
        case .emptyResponse:
            return "The provider returned no assistant content for this message."
        case .invalidConfiguration:
            return "The selected provider configuration is incomplete, so the request could not be sent."
        case .network:
            return "The request did not complete successfully. Please check your network and try again."
        case .upstream:
            return "The provider returned an error for this request. Please retry or switch models."
        case let .subscriptionFailure(_, _, messageKey, _):
            return messageKey
        }
    }

    /// Stable, non-localized slug used for local diagnostics and the retry card.
    var diagnosticCode: String {
        switch self {
        case .invalidAPIKey: return "invalid_api_key"
        case .quotaExceeded: return "quota_exceeded"
        case .modelUnavailable: return "model_unavailable"
        case .rateLimited: return "rate_limited"
        case .emptyModelCatalog: return "empty_model_catalog"
        case .emptyResponse: return "empty_response"
        case .invalidConfiguration: return "invalid_configuration"
        case .network: return "network"
        case let .upstream(statusCode, _): return "upstream_\(statusCode)"
        case let .subscriptionFailure(lane, kind, _, _): return "\(lane.rawValue)_subscription_\(kind.rawValue)"
        }
    }

    var technicalDetail: String {
        switch self {
        case let .invalidAPIKey(detail),
             let .quotaExceeded(detail),
             let .modelUnavailable(detail),
             let .rateLimited(detail),
             let .invalidConfiguration(detail),
             let .network(detail):
            return detail
        case .emptyModelCatalog:
            return "The provider model catalog returned zero models."
        case .emptyResponse:
            return "The provider chat completion finished without any text content."
        case let .upstream(statusCode, detail):
            return "Upstream HTTP \(statusCode): \(detail)"
        case let .subscriptionFailure(lane, kind, _, detail):
            return "\(lane.titleKey) \(kind.rawValue): \(detail)"
        }
    }
}

enum StreamEvent {
    case delta(String)
    case reasoning(String)
    case imagePart(Attachment)
    case citations([Citation])
    case toolCallDeltas([ProviderToolCall])
    case done(ProviderChatResult)
}

final class OpenRouterService: BaseAPIService, ProviderServiceProtocol, BalanceQueryable {

    // MARK: - Headers

    override func applyHeaders(to request: inout URLRequest, apiKey: String) {
        super.applyHeaders(to: &request, apiKey: apiKey)
        request.setValue("https://github.com/oriveo/oriveo", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Oriveo", forHTTPHeaderField: "X-Title")
    }

    // MARK: - Sync

    private let pricingCache = OpenRouterPricingCache()

    func syncProvider(apiKey: String, preferredModelID: String?) async throws -> ProviderSyncResult {
        try validateAPIKey(apiKey)

        await MetadataClient.shared.ensureInitialized()
        return ProviderSyncResult(models: [])
    }

    // MARK: - Balance

    func fetchBalance(apiKey: String, baseURL: String?) async throws -> ProviderBalance {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BalanceQueryError.keyInvalid(detail: "Missing API key.")
        }
        let origin = balanceOriginFrom(baseURL, fallback: "https://openrouter.ai")
        guard let url = URL(string: "\(origin)/api/v1/credits") else {
            throw BalanceQueryError.network(detail: "Invalid OpenRouter credits URL.")
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
        if http.statusCode == 401 {
            throw BalanceQueryError.silentHidden(detail: "OpenRouter /credits requires management key.")
        }
        if http.statusCode == 403 {
            throw BalanceQueryError.keyInvalid(detail: "OpenRouter rejected API key (403).")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw BalanceQueryError.network(detail: "OpenRouter /credits HTTP \(http.statusCode).")
        }
        struct CreditsResponse: Decodable {
            struct DataField: Decodable {
                let total_credits: Double?
                let total_usage: Double?
            }
            let data: DataField?
        }
        let decoded: CreditsResponse
        do {
            decoded = try decoder.decode(CreditsResponse.self, from: data)
        } catch {
            throw BalanceQueryError.decoding(detail: error.localizedDescription)
        }
        let total = (decoded.data?.total_credits ?? 0) - (decoded.data?.total_usage ?? 0)
        return ProviderBalance(
            currency: "USD",
            total: total,
            granted: nil,
            topUp: decoded.data?.total_credits,
            fetchedAt: Date(),
            totalUsage: decoded.data?.total_usage
        )
    }

    // MARK: - Chat (non-streaming)

    // ProviderServiceProtocol conformance
    func sendMessage(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage]
    ) async throws -> ProviderChatResult {
        try await sendMessage(
            apiKey: apiKey,
            modelID: modelID,
            messages: messages,
            reasoningMode: .automatic,
            webSearchEnabled: false,
            supportsImageGen: false
        )
    }

    func sendMessage(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        reasoningMode: ReasoningMode = .automatic,
        webSearchEnabled: Bool = false,
        supportsImageGen: Bool = false,
        requestOptions: ChatRequestOptions = ChatRequestOptions()
    ) async throws -> ProviderChatResult {
        try await sendMessage(
            apiKey: apiKey,
            modelID: modelID,
            messages: messages,
            reasoningMode: reasoningMode,
            webSearchEnabled: webSearchEnabled,
            supportsImageGen: supportsImageGen,
            requestOptions: requestOptions,
            allowShortRateLimitRetry: true
        )
    }

    private func sendMessage(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        reasoningMode: ReasoningMode,
        webSearchEnabled: Bool,
        supportsImageGen: Bool,
        requestOptions: ChatRequestOptions,
        allowShortRateLimitRetry: Bool
    ) async throws -> ProviderChatResult {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderServiceError.invalidConfiguration(detail: "Missing API key.")
        }

        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderServiceError.invalidConfiguration(detail: "Missing model identifier.")
        }

        let resolved = MetadataClient.shared.syncResolveCatalogModel(modelID: modelID, providerKind: .openRouter)
        var request = URLRequest(url: try resolveChatEndpoint())
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        applyHeaders(to: &request, apiKey: apiKey)
        let capabilityIntent = CapabilityEvidenceProductionAdapter.finalChatIntent(
            messages: messages, request: request, effectiveTransport: resolved?.transport ?? "",
            model: requestOptions.capabilityEvidenceModel,
            requestedReasoningMode: reasoningMode, webSearchEnabled: webSearchEnabled
        )

        var apiMessages: [OpenRouterChatRequest.Message] = []
        let systemPrompt = requestOptions.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !systemPrompt.isEmpty {
            apiMessages.append(.init(role: "system", content: .text(systemPrompt)))
        }
        apiMessages.append(contentsOf: capabilityIntent.outboundMessages.map { Self.buildRequestMessage($0) })

        let payload = OpenRouterChatRequest(
            model: modelID,
            max_tokens: resolved?.maxOutputTokens,
            modalities: nil,
            reasoning: nil,
            tools: nil,
            messages: apiMessages
        )

        #if DEBUG
        if supportsImageGen {
            AppLog.info(
                "Image generation request: model=\(payload.model), modalities=\(payload.modalities ?? []), "
                + "maxTokens=\(payload.max_tokens.map(String.init) ?? "unset"), messages=\(payload.messages.count)",
                module: "ImageGen"
            )
        }
        #endif

        var body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any] ?? [:]
        if let allowedReasoningMode = capabilityIntent.reasoningMode,
           let reasoningMerge = ProfileParamsResolver.reasoningMergeParams(
            providerKind: .openRouter,
            modelID: modelID,
            reasoningMode: allowedReasoningMode,
            resolved: resolved
        ) {
            ProfileParamsResolver.deepMerge(&body, reasoningMerge)
        }
        if capabilityIntent.webSearchEnabled,
           let webSearchMerge = ProfileParamsResolver.webSearchMergeParams(
            providerKind: .openRouter,
            modelID: modelID,
            profileName: resolved?.profiles.webSearch
           ) {
            ProfileParamsResolver.deepMerge(&body, webSearchMerge)
        }
        if supportsImageGen,
           let imageGenMerge = ProfileParamsResolver.imageGenMergeParams(
            providerKind: .openRouter,
            modelID: modelID,
            profileName: resolved?.profiles.imageGen
        ) {
            ProfileParamsResolver.deepMerge(&body, imageGenMerge)
        }
        Self.appendExplicitReasoningReplay(
            to: &body, modelID: modelID, reasoningMode: reasoningMode,
            explicitMessageID: requestOptions.localExplicitContinuationMessageID
        )
        CapabilityRecipeRequestCompiler.apply(to: &body, providerKind: .openRouter, modelID: modelID, transport: resolved?.transport ?? "", webSearchEnabled: webSearchEnabled, reasoningMode: reasoningMode, capabilityPreferences: requestOptions.capabilityPreferences)
        request.httpBody = try encodeChatBody(&body, options: requestOptions, resolved: resolved, finalRequest: request)

        let (data, rawResponse) = try await performRaw(request)

        if let mappedError = mapSuccessStatusErrorEnvelope(
            from: data,
            httpStatusCode: rawResponse.statusCode
        ) {
            if allowShortRateLimitRetry,
               let retryDelayMs = mappedError.retryDelayMilliseconds,
               retryDelayMs <= 1_000 {
                #if DEBUG
                AppLog.info(
                    "Upstream returned 429, retrying in \(retryDelayMs)ms: \(mappedError.error.technicalDetail)",
                    module: "ImageGen"
                )
                #endif
                try await Task.sleep(nanoseconds: UInt64(max(retryDelayMs, 50)) * 1_000_000)
                return try await sendMessage(
                    apiKey: apiKey,
                    modelID: modelID,
                    messages: messages,
                    reasoningMode: reasoningMode,
                    webSearchEnabled: webSearchEnabled,
                    supportsImageGen: supportsImageGen,
                    requestOptions: requestOptions,
                    allowShortRateLimitRetry: false
                )
            }
            throw mappedError.error
        }

        let response: OpenRouterChatResponse
        do {
            response = try decoder.decode(OpenRouterChatResponse.self, from: data)
        } catch {
            #if DEBUG
            let statusCode = rawResponse.statusCode
            AppLog.warning(
                "Could not decode the response: model=\(modelID) status=\(statusCode) "
                + "bytes=\(data.count) error=\(error)",
                module: "ImageGen"
            )
            #endif
            throw ProviderServiceError.network(detail: "Decoding failed: \(error.localizedDescription)")
        }

        guard let choice = response.choices.first else {
            throw ProviderServiceError.emptyResponse
        }


        #if DEBUG
        switch choice.message.content {
        case .text(let t):
            AppLog.info("Response content is text, \(t.count) characters", module: "ImageGen")
        case .parts(let p):
            AppLog.info(
                "Response content has \(p.count) parts: \(p.map { $0.type ?? "untyped" })",
                module: "ImageGen"
            )
        }
        #endif
        let rawText = choice.message.content.textValue
        var imageAttachments = response.resolvedImageAttachments
        if imageAttachments.isEmpty {
            imageAttachments = choice.message.content.imageAttachments
        }
        let text = ContentValue.stripInlineImages(from: rawText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #if DEBUG
        AppLog.info(
            "Parsed response: raw \(rawText.count) characters, cleaned \(text.count) characters, "
            + "\(imageAttachments.count) images",
            module: "ImageGen"
        )
        #endif
        guard !text.isEmpty || !imageAttachments.isEmpty else {
            throw ProviderServiceError.emptyResponse
        }

        let continuationRecipe = Self.reasoningReplayRecipe(
            modelID: modelID, reasoningMode: reasoningMode
        )
        let replayReasoningDetails = choice.message.reasoning_details?.compactMap {
            $0.foundationValue as? [String: Any]
        }
        let replayToolCalls = choice.message.tool_calls?.compactMap {
            $0.foundationValue as? [String: Any]
        }
        if choice.message.continuationFieldsValid,
           replayReasoningDetails?.count == choice.message.reasoning_details?.count,
           replayToolCalls?.count == choice.message.tool_calls?.count,
           let replayMessage = CapabilityRecipeExecution.openRouterReplayAssistant(
                content: rawText,
                reasoningDetails: replayReasoningDetails,
                toolCalls: replayToolCalls
           ), let encoded = RecipeContinuationRuntime.jsonValue([replayMessage]) {
            try RecipeContinuationRuntime.save(
                messageID: requestOptions.localContinuationMessageID,
                recipe: continuationRecipe,
                state: ["assistantMessages": encoded]
            )
        }

        let breakdown = Self.parseUsage(response.usage)
        let resolvedModelID = response.model ?? modelID
        let (cost, source) = await MetadataClient.shared.calcCost(
            breakdown: breakdown, modelID: resolvedModelID, providerKind: .openRouter
        )

        return ProviderChatResult(
            text: text,
            promptTokens: breakdown.totalInputTokens,
            completionTokens: breakdown.completionTokens,
            estimatedCost: cost,
            attachments: imageAttachments.isEmpty ? nil : imageAttachments,
            servedModelID: response.model,
            usageBreakdown: breakdown,
            costSource: source
        )
    }

    // MARK: - Chat (streaming)

    // ProviderServiceProtocol conformance
    func sendMessageStream(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage]
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        sendMessageStream(
            apiKey: apiKey,
            modelID: modelID,
            messages: messages,
            reasoningMode: .automatic,
            webSearchEnabled: false,
            supportsImageGen: false
        )
    }

    func sendMessageStream(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        reasoningMode: ReasoningMode = .automatic,
        webSearchEnabled: Bool = false,
        supportsImageGen: Bool = false,
        requestOptions: ChatRequestOptions = ChatRequestOptions()
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var orCtx = StreamContext()
                do {
                    guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw ProviderServiceError.invalidConfiguration(detail: "Missing API key.")
                    }
                    guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw ProviderServiceError.invalidConfiguration(detail: "Missing model identifier.")
                    }

                    let resolved = MetadataClient.shared.syncResolveCatalogModel(modelID: modelID, providerKind: .openRouter)
                    var request = URLRequest(url: try self.resolveChatEndpoint())
                    request.httpMethod = "POST"
                    request.timeoutInterval = 120
                    self.applyHeaders(to: &request, apiKey: apiKey)
                    let capabilityIntent = CapabilityEvidenceProductionAdapter.finalChatIntent(
                        messages: messages, request: request, effectiveTransport: resolved?.transport ?? "",
                        model: requestOptions.capabilityEvidenceModel,
                        requestedReasoningMode: reasoningMode, webSearchEnabled: webSearchEnabled
                    )

                    var apiMessages: [OpenRouterChatRequest.Message] = []
                    let systemPrompt = requestOptions.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !systemPrompt.isEmpty {
                        apiMessages.append(.init(role: "system", content: .text(systemPrompt)))
                    }
                    apiMessages.append(contentsOf: capabilityIntent.outboundMessages.map { Self.buildRequestMessage($0) })

                    let payload = OpenRouterChatRequest(
                        model: modelID,
                        stream: true,
                        stream_options: OpenRouterChatRequest.StreamOptions(),
                        max_tokens: resolved?.maxOutputTokens,
                        modalities: nil,
                        reasoning: nil,
                        tools: nil,
                        messages: apiMessages
                    )
                    #if DEBUG
                    if supportsImageGen {
                        AppLog.info(
                            "Image generation stream request: model=\(payload.model), "
                            + "modalities=\(payload.modalities ?? []), "
                            + "maxTokens=\(payload.max_tokens.map(String.init) ?? "unset"), "
                            + "messages=\(payload.messages.count)",
                            module: "ImageGen"
                        )
                    }
                    #endif
                    var body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any] ?? [:]
                    if let allowedReasoningMode = capabilityIntent.reasoningMode,
                       let reasoningMerge = ProfileParamsResolver.reasoningMergeParams(
                        providerKind: .openRouter,
                        modelID: modelID,
                        reasoningMode: allowedReasoningMode,
                        resolved: resolved
                    ) {
                        ProfileParamsResolver.deepMerge(&body, reasoningMerge)
                    }
                    if capabilityIntent.webSearchEnabled,
                       let webSearchMerge = ProfileParamsResolver.webSearchMergeParams(
                        providerKind: .openRouter,
                        modelID: modelID,
                        profileName: resolved?.profiles.webSearch
                       ) {
                        ProfileParamsResolver.deepMerge(&body, webSearchMerge)
                    }
                    if supportsImageGen,
                       let imageGenMerge = ProfileParamsResolver.imageGenMergeParams(
                        providerKind: .openRouter,
                        modelID: modelID,
                        profileName: resolved?.profiles.imageGen
                       ) {
                        ProfileParamsResolver.deepMerge(&body, imageGenMerge)
                    }
                    Self.appendExplicitReasoningReplay(
                        to: &body, modelID: modelID, reasoningMode: reasoningMode,
                        explicitMessageID: requestOptions.localExplicitContinuationMessageID
                    )
                    CapabilityRecipeRequestCompiler.apply(
                        to: &body, providerKind: .openRouter, modelID: modelID,
                        transport: resolved?.transport ?? "", webSearchEnabled: webSearchEnabled,
                        reasoningMode: reasoningMode,
                        capabilityPreferences: requestOptions.capabilityPreferences
                    )
                    request.httpBody = try self.encodeChatBody(
                        &body,
                        options: requestOptions,
                        resolved: resolved,
                        finalRequest: request
                    )

                    let (bytes, response) = try await self.bytesWithUnsupportedParamSelfHeal(
                        providerKind: .openRouter,
                        modelID: modelID,
                        request: request
                    )

                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw ProviderServiceError.network(detail: "Missing HTTPURLResponse.")
                    }

                    guard (200 ..< 300).contains(httpResponse.statusCode) else {
                        var errorData = Data()
                        for try await byte in bytes {
                            errorData.append(byte)
                        }
                        throw self.mapHTTPError(statusCode: httpResponse.statusCode, data: errorData)
                    }

                    var accumulatedText = ""
                    var lastModel: String?
                    var lastUsage: OpenRouterUsage?
                    var replayAccumulator = OpenRouterAssistantReplayStreamAccumulator()
                    var reachedTerminalFrame = false
                    let orStrategy = TransportRegistry.strategy(for: .openaiChat)
                    let orShape = MetadataClient.shared.syncWebSearchStreamShape(
                        profileName: MetadataClient.shared.syncResolveCatalogModel(
                            modelID: modelID,
                            providerKind: .openRouter
                        )?.profiles.webSearch
                    )
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
                        let chunk: OpenRouterStreamChunk
                        do {
                            chunk = try self.decoder.decode(OpenRouterStreamChunk.self, from: chunkData)
                        } catch {
                            continue
                        }

                        lastModel = chunk.model ?? lastModel
                        if let usage = chunk.usage {
                            lastUsage = usage
                        }
                        if chunk.choices?.first?.finish_reason?.isEmpty == false {
                            reachedTerminalFrame = true
                        }

                        if let delta = chunk.choices?.first?.delta,
                           let content = delta.content {
                            let text = content.textValue
                            if !text.isEmpty {
                                accumulatedText += text
                                continuation.yield(.delta(text))
                            }
                            for att in content.imageAttachments {
                                continuation.yield(.imagePart(att))
                            }
                        }
                        for ev in orStrategy.parseStreamLine(payload, ctx: &orCtx, shape: orShape) {
                            switch ev {
                            case let .reasoning(text): continuation.yield(.reasoning(text))
                            case .toolCallDeltas: continuation.yield(ev)
                            default: break
                            }
                        }
                    }
                    for ev in OpenAIChatStrategy.flushToolCalls(ctx: &orCtx) {
                        continuation.yield(ev)
                    }

                    let finalCitations = orCtx.citationsAccumulator.citations
                    if !finalCitations.isEmpty {
                        continuation.yield(.citations(finalCitations))
                    }

                    let finalText = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let continuationRecipe = Self.reasoningReplayRecipe(
                        modelID: modelID, reasoningMode: reasoningMode
                    )
                    try Task.checkCancellation()
                    if reachedTerminalFrame,
                       let replayMessage = replayAccumulator.completedAssistantMessage(
                            content: accumulatedText
                       ), let encoded = RecipeContinuationRuntime.jsonValue([replayMessage]) {
                        try RecipeContinuationRuntime.save(
                            messageID: requestOptions.localContinuationMessageID,
                            recipe: continuationRecipe,
                            state: ["assistantMessages": encoded]
                        )
                    }
                    let breakdown = Self.parseUsage(lastUsage)
                    let resolvedModelID = lastModel ?? modelID
                    let (cost, source) = await MetadataClient.shared.calcCost(
                        breakdown: breakdown, modelID: resolvedModelID, providerKind: .openRouter
                    )

                    let result = ProviderChatResult(
                        text: finalText,
                        promptTokens: breakdown.totalInputTokens,
                        completionTokens: breakdown.completionTokens,
                        estimatedCost: cost,
                        servedModelID: lastModel,
                        usageBreakdown: breakdown,
                        costSource: source
                    )
                    continuation.yield(.done(result))
                    continuation.finish()
                } catch {
                    for ev in OpenAIChatStrategy.flushToolCalls(ctx: &orCtx) { continuation.yield(ev) }
                    let citations = orCtx.citationsAccumulator.citations
                    if !citations.isEmpty {
                        continuation.yield(.citations(citations))
                    }
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Request Message Building

    private static func buildRequestMessage(_ msg: ChatMessage, model: AIModel? = nil) -> OpenRouterChatRequest.Message {
        let atts = msg.attachments ?? []
        let imageAtts = atts.filter { $0.kind == .image }

        let (combinedText, _) = BaseAPIService.injectFileAttachmentsAsText(
            userText: msg.text,
            attachments: atts,
            provider: .openRouter,
            model: model
        )

        guard !imageAtts.isEmpty else {
            return .init(role: msg.role.rawValue, content: .text(combinedText))
        }

        var parts: [OpenRouterChatRequest.ContentPart] = [.init(type: "text", text: combinedText)]
        for a in imageAtts {
            let dataURL = a.resolvedDataURL
            guard !dataURL.isEmpty else { continue }
            parts.append(.init(type: "image_url", image_url: .init(url: dataURL, detail: "auto")))
        }
        return .init(role: msg.role.rawValue, content: .parts(parts))
    }

    private static func reasoningReplayRecipe(
        modelID: String, reasoningMode: ReasoningMode
    ) -> MetadataClient.CapabilityRecipe? {
        RecipeContinuationRuntime.selectedRecipe(
            provider: .openRouter, modelID: modelID, transport: "openai_chat",
            webSearchEnabled: false, reasoningMode: reasoningMode,
            continuationKind: "replay_reasoning", parser: { $0 == "openrouter_reasoning_v1" }
        )
    }

    private static func appendExplicitReasoningReplay(
        to body: inout [String: Any], modelID: String, reasoningMode: ReasoningMode,
        explicitMessageID: UUID?
    ) {
        guard reasoningReplayRecipe(modelID: modelID, reasoningMode: reasoningMode) != nil,
              let assistantMessages = CapabilityRecipeExecution.openRouterReplayAssistantMessages(
                RecipeContinuationRuntime.replayAssistantMessages(
                    explicitMessageID: explicitMessageID
                )
              ), var messages = body["messages"] as? [[String: Any]] else { return }
        // Replace ChatRequestBuilder's partial target assistant, then keep its final continue user
        // as the last turn. Appending opaque replay after that user is invalid protocol order.
        let insertAt: Int
        if let lastUser = messages.lastIndex(where: { $0["role"] as? String == "user" }) {
            var target = lastUser
            if target > 0, messages[target - 1]["role"] as? String == "assistant" {
                messages.remove(at: target - 1)
                target -= 1
            }
            insertAt = target
        } else {
            insertAt = messages.count
        }
        messages.insert(contentsOf: assistantMessages, at: insertAt)
        body["messages"] = messages
    }

    // MARK: - Metadata-backed Model Building

    private func buildModelsFromMetadata(_ metadataModelIDs: [String], preferredModelID: String?) async -> [AIModel] {
        let normalizedPreferredID = preferredModelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceIDs = metadataModelIDs

        var models: [AIModel] = []
        models.reserveCapacity(sourceIDs.count)

        for modelID in sourceIDs {
            let fallbackName = modelID.split(separator: "/", maxSplits: 1).last.map(String.init) ?? modelID
            var model = await CatalogModelBuilder.buildCatalogModel(
                providerKind: .openRouter,
                runtimeModelId: modelID,
                fallbackName: fallbackName
            )
            if normalizedPreferredID == modelID {
                model.isDefault = true
            }
            models.append(model)
        }

        models = CatalogModelBuilder.deduplicateByCanonical(models)
        models.sort(by: catalogModelSort)

        if let normalizedPreferredID, models.contains(where: { $0.id == normalizedPreferredID }) {
            return models
        }

        return selectDefaultBySortRank(models)
    }


    private func mapSuccessStatusErrorEnvelope(
        from data: Data,
        httpStatusCode: Int
    ) -> (error: ProviderServiceError, retryDelayMilliseconds: Int?)? {
        guard let envelope = try? decoder.decode(OpenRouterErrorEnvelope.self, from: data),
              let error = envelope.error else {
            return nil
        }

        let effectiveStatus: Int
        if httpStatusCode != 200 {
            effectiveStatus = httpStatusCode
        } else if let nestedStatus = error.code?.statusCode {
            effectiveStatus = nestedStatus
        } else {
            effectiveStatus = 502
        }

        let mappedError = mapHTTPError(statusCode: effectiveStatus, data: data)
        let retryDelayMilliseconds = effectiveStatus == 429
            ? Self.parseRetryDelayMilliseconds(from: error.message)
            : nil

        #if DEBUG
        AppLog.info(
            "Mapped the error envelope: httpStatus=\(httpStatusCode), effectiveStatus=\(effectiveStatus), "
            + "retryAfterMs=\(retryDelayMilliseconds.map(String.init) ?? "none"), detail=\(mappedError.technicalDetail)",
            module: "ImageGen"
        )
        #endif

        return (mappedError, retryDelayMilliseconds)
    }

    private func resolveChatEndpoint() throws -> URL {
        let metadataTransport = MetadataClient.shared.syncProviderTransport(providerKind: .openRouter)
        let endpointBase = EndpointResolver.officialMetadataBaseURL(
            providerKind: .openRouter,
            metadataTransport: metadataTransport
        ) ?? EndpointResolver.fallbackBaseURL(for: .openRouter)
        let endpointPath = metadataTransport?.endpoints?.chat
            ?? EndpointResolver.fallbackEndpointPath(.openRouter, kind: .chat)
        guard let url = EndpointResolver.joinURL(base: endpointBase, path: endpointPath) else {
            throw ProviderServiceError.invalidConfiguration(detail: "Invalid OpenRouter endpoint.")
        }
        return url
    }

    private static func parseRetryDelayMilliseconds(from message: String?) -> Int? {
        guard let message,
              let regex = try? NSRegularExpression(pattern: #"try again in (\d+)ms"#, options: [.caseInsensitive]),
              let match = regex.firstMatch(
                  in: message,
                  options: [],
                  range: NSRange(message.startIndex..., in: message)
              ),
              let range = Range(match.range(at: 1), in: message) else {
            return nil
        }

        return Int(message[range])
    }
}

/// Captures the provider-owned OpenRouter assistant frame before the display parser folds it.
/// `reasoning_details` without an index are distinct ordered records; indexed records keep their
/// first global position while later chunks merge only protocol fragment fields.
struct OpenRouterAssistantReplayStreamAccumulator {
    private var isValid = true
    private var reasoningDetails = OpenRouterReasoningDetailsAccumulator()
    private var toolCalls = OpenRouterReplayToolCallAccumulator()

    mutating func ingest(_ data: Data) {
        guard isValid else { return }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            isValid = false
            return
        }
        guard let rawChoices = object["choices"] else { return }
        guard let choices = rawChoices as? [Any] else {
            isValid = false
            return
        }
        guard let first = choices.first else { return }
        guard let choice = first as? [String: Any] else {
            isValid = false
            return
        }
        guard choice["delta"] == nil || choice["delta"] is [String: Any] else {
            isValid = false
            return
        }
        guard let delta = choice["delta"] as? [String: Any] else { return }
        if let rawDetails = delta["reasoning_details"], !(rawDetails is NSNull),
           !reasoningDetails.ingest(rawDetails) {
            isValid = false
        }
        if let rawCalls = delta["tool_calls"], !(rawCalls is NSNull),
           !toolCalls.ingest(rawCalls) {
            isValid = false
        }
    }

    func completedAssistantMessage(content: String) -> [String: Any]? {
        guard isValid,
              let details = reasoningDetails.completedDetails(),
              let calls = toolCalls.completedCalls() else { return nil }
        return CapabilityRecipeExecution.openRouterReplayAssistant(
            content: content,
            reasoningDetails: details,
            toolCalls: toolCalls.wasPresent ? calls : nil
        )
    }
}

private struct OpenRouterReasoningDetailsAccumulator {
    private var ordered: [[String: Any]] = []
    private var indexedPositions: [Int: Int] = [:]
    private var isValid = true

    mutating func ingest(_ raw: Any) -> Bool {
        guard isValid, let fragments = raw as? [Any] else {
            isValid = false
            return false
        }
        for fragment in fragments {
            guard let detail = fragment as? [String: Any],
                  !detail.isEmpty,
                  JSONSerialization.isValidJSONObject(detail) else {
                isValid = false
                return false
            }
            if let rawIndex = detail["index"] {
                guard let index = openRouterNonnegativeInteger(rawIndex) else {
                    isValid = false
                    return false
                }
                if let position = indexedPositions[index] {
                    guard mergeOpenRouterReasoningDetail(
                        detail, into: &ordered[position]
                    ) else {
                        isValid = false
                        return false
                    }
                } else {
                    indexedPositions[index] = ordered.count
                    ordered.append(detail)
                }
            } else {
                // No-index details are complete opaque records, not fallback index zero. Every
                // occurrence remains distinct even when it is the first item of another chunk.
                ordered.append(detail)
            }
        }
        return true
    }

    func completedDetails() -> [[String: Any]]? {
        guard isValid,
              CapabilityRecipeExecution.validOpenRouterReasoningDetails(ordered) else { return nil }
        return ordered
    }
}

private struct OpenRouterReplayToolCallAccumulator {
    private struct Partial {
        var id: String?
        var type: String?
        var name = ""
        var arguments = ""
        var sawFunction = false
    }

    private var partials: [Int: Partial] = [:]
    private var lastIndex = 0
    private var isValid = true
    private(set) var wasPresent = false

    mutating func ingest(_ raw: Any) -> Bool {
        wasPresent = true
        guard isValid, let fragments = raw as? [Any] else {
            isValid = false
            return false
        }
        let callKeys: Set<String> = ["index", "id", "type", "function"]
        let functionKeys: Set<String> = ["name", "arguments"]
        for fragment in fragments {
            guard let call = fragment as? [String: Any],
                  Set(call.keys).isSubset(of: callKeys) else {
                isValid = false
                return false
            }
            let index: Int
            if let rawIndex = call["index"] {
                guard let parsed = openRouterNonnegativeInteger(rawIndex) else {
                    isValid = false
                    return false
                }
                index = parsed
                lastIndex = parsed
            } else {
                index = lastIndex
            }
            var partial = partials[index] ?? Partial()
            if let rawID = call["id"] {
                guard let id = rawID as? String, !id.isEmpty,
                      partial.id == nil || partial.id == id else {
                    isValid = false
                    return false
                }
                partial.id = id
            }
            if let rawType = call["type"] {
                guard let type = rawType as? String, type == "function",
                      partial.type == nil || partial.type == type else {
                    isValid = false
                    return false
                }
                partial.type = type
            }
            if let rawFunction = call["function"] {
                guard let function = rawFunction as? [String: Any],
                      Set(function.keys).isSubset(of: functionKeys) else {
                    isValid = false
                    return false
                }
                partial.sawFunction = true
                if let rawName = function["name"] {
                    guard let name = rawName as? String else {
                        isValid = false
                        return false
                    }
                    partial.name += name
                }
                if let rawArguments = function["arguments"] {
                    guard let arguments = rawArguments as? String else {
                        isValid = false
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
        guard isValid else { return nil }
        if !wasPresent { return [] }
        guard !partials.isEmpty else { return nil }
        var complete: [[String: Any]] = []
        for index in partials.keys.sorted() {
            guard let partial = partials[index], let id = partial.id,
                  partial.type == "function", partial.sawFunction,
                  !partial.name.isEmpty else { return nil }
            complete.append([
                "id": id,
                "type": "function",
                "function": ["name": partial.name, "arguments": partial.arguments],
            ])
        }
        return complete
    }
}

private func mergeOpenRouterReasoningDetail(
    _ fragment: [String: Any], into current: inout [String: Any]
) -> Bool {
    for (key, value) in fragment {
        if ["text", "summary", "data"].contains(key),
           let next = value as? String,
           let existing = current[key] as? String {
            current[key] = existing + next
        } else if let existing = current[key] {
            guard openRouterJSONValuesEqual(existing, value) else { return false }
        } else {
            current[key] = value
        }
    }
    return true
}

private func openRouterJSONValuesEqual(_ lhs: Any, _ rhs: Any) -> Bool {
    let left = ["value": lhs]
    let right = ["value": rhs]
    guard JSONSerialization.isValidJSONObject(left),
          JSONSerialization.isValidJSONObject(right),
          let leftData = try? JSONSerialization.data(withJSONObject: left, options: [.sortedKeys]),
          let rightData = try? JSONSerialization.data(withJSONObject: right, options: [.sortedKeys])
    else { return false }
    return leftData == rightData
}

private func openRouterNonnegativeInteger(_ value: Any) -> Int? {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let raw = number.doubleValue
    guard raw.isFinite, raw >= 0, raw.rounded(.towardZero) == raw,
          raw <= Double(Int.max) else { return nil }
    return Int(raw)
}

private struct OpenRouterErrorEnvelope: Decodable {
    var error: ErrorDetail?

    struct ErrorDetail: Decodable {
        var message: String?
        var code: ErrorCode?
    }

    enum ErrorCode: Decodable {
        case int(Int)
        case string(String)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let intValue = try? container.decode(Int.self) {
                self = .int(intValue)
                return
            }
            self = .string(try container.decode(String.self))
        }

        var statusCode: Int? {
            switch self {
            case .int(let value):
                return value
            case .string(let value):
                return Int(value)
            }
        }
    }
}


private struct OpenRouterChatRequest: Encodable {
    var model: String
    var stream: Bool?
    var stream_options: StreamOptions?
    var max_tokens: Int?
    var modalities: [String]?
    var reasoning: Reasoning?
    var tools: [Tool]?
    var messages: [Message]

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
        var file: FileRef?

        struct ImageURL: Encodable {
            var url: String
            var detail: String?
        }
        struct FileRef: Encodable { var filename: String; var file_data: String }
    }

    struct StreamOptions: Encodable {
        var include_usage: Bool = true
    }

    struct Reasoning: Encodable {
        var effort: String
    }

    struct Tool: Encodable {
        var type: String
    }
}

private struct OpenRouterStreamChunk: Decodable {
    var model: String?
    var choices: [StreamChoice]?
    var usage: OpenRouterUsage?
}

private struct StreamChoice: Decodable {
    var delta: StreamDelta?
    var finish_reason: String?
}

private struct StreamDelta: Decodable {
    var content: ContentValue?
    /// Opaque continuation material. This must not be converted to rendered
    /// reasoning text before it is replayed to OpenRouter.
    var reasoning_details: [MetadataClient.JSONValue]?
    var tool_calls: [MetadataClient.JSONValue]?
}

private struct OpenRouterChatResponse: Decodable {
    var model: String?
    var choices: [Choice]
    var usage: OpenRouterUsage?
    var images: [ImageItem]?

    struct Choice: Decodable {
        var message: Message
        var images: [ImageItem]?

        struct Message: Decodable {
            var content: ContentValue
            var reasoning_details: [MetadataClient.JSONValue]?
            var tool_calls: [MetadataClient.JSONValue]?
            var continuationFieldsValid: Bool
            var images: [ImageItem]?

            private enum CodingKeys: String, CodingKey {
                case content
                case reasoning_details
                case tool_calls
                case images
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                content = (try? container.decode(ContentValue.self, forKey: .content)) ?? .text("")
                var fieldsValid = true
                if container.contains(.reasoning_details),
                   (try? container.decodeNil(forKey: .reasoning_details)) != true {
                    do {
                        reasoning_details = try container.decode(
                            [MetadataClient.JSONValue].self, forKey: .reasoning_details
                        )
                    } catch {
                        reasoning_details = nil
                        fieldsValid = false
                    }
                } else {
                    reasoning_details = nil
                }
                if container.contains(.tool_calls),
                   (try? container.decodeNil(forKey: .tool_calls)) != true {
                    do {
                        tool_calls = try container.decode(
                            [MetadataClient.JSONValue].self, forKey: .tool_calls
                        )
                    } catch {
                        tool_calls = nil
                        fieldsValid = false
                    }
                } else {
                    tool_calls = nil
                }
                continuationFieldsValid = fieldsValid
                images = try? container.decode([ImageItem].self, forKey: .images)
            }
        }
    }

    struct ImageItem: Decodable {
        var type: String?
        var image_url: ImageURLRef?

        struct ImageURLRef: Decodable {
            var url: String?
        }
    }

    var resolvedImageAttachments: [Attachment] {
        let allItems = (choices.first?.message.images ?? [])
            + (choices.first?.images ?? [])
            + (images ?? [])
        var seenHashes = Set<Int>()
        return allItems.compactMap { item in
            guard let urlStr = item.image_url?.url, !urlStr.isEmpty else { return nil }
            guard seenHashes.insert(urlStr.hashValue).inserted else { return nil }
            if urlStr.hasPrefix("data:image/") {
                let components = urlStr.components(separatedBy: ",")
                guard components.count >= 2 else { return nil }
                let meta = components[0] // data:image/jpeg;base64
                let base64 = components.dropFirst().joined(separator: ",")
                let mimeType = meta
                    .replacingOccurrences(of: "data:", with: "")
                    .replacingOccurrences(of: ";base64", with: "")
                return Attachment(
                    id: UUID(),
                    kind: .image,
                    fileName: "generated_image.\(mimeType.replacingOccurrences(of: "image/", with: ""))",
                    mimeType: mimeType,
                    base64Data: base64
                )
            } else {
                return Attachment(
                    id: UUID(),
                    kind: .image,
                    fileName: "generated_image.png",
                    mimeType: "image/png",
                    base64Data: urlStr
                )
            }
        }
    }
}

private struct OpenRouterUsage: Decodable {
    var prompt_tokens: Int?
    var completion_tokens: Int?
    var total_tokens: Int?
    var cost: Double?
    var prompt_tokens_details: PromptTokensDetails?

    struct PromptTokensDetails: Decodable {
        var cached_tokens: Int?
        var cache_write_tokens: Int?

        init(cached_tokens: Int? = nil, cache_write_tokens: Int? = nil) {
            self.cached_tokens = cached_tokens
            self.cache_write_tokens = cache_write_tokens
        }
    }

    init(
        prompt_tokens: Int? = nil,
        completion_tokens: Int? = nil,
        total_tokens: Int? = nil,
        cost: Double? = nil,
        prompt_tokens_details: PromptTokensDetails? = nil
    ) {
        self.prompt_tokens = prompt_tokens
        self.completion_tokens = completion_tokens
        self.total_tokens = total_tokens
        self.cost = cost
        self.prompt_tokens_details = prompt_tokens_details
    }
}

private enum ContentValue: Decodable {
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
        var image_url: ImageURL?

        struct ImageURL: Decodable {
            var url: String?
        }
    }

    var imageAttachments: [Attachment] {
        switch self {
        case .text(let text):
            return Self.extractInlineImageAttachments(from: text)
        case .parts(let parts):
            let structured = Self.extractFromParts(parts)
            if !structured.isEmpty { return structured }
            let joined = parts.compactMap(\.text).joined(separator: "\n")
            return Self.extractInlineImageAttachments(from: joined)
        }
    }


    private static let inlineImageRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"!\[[^\]]*\]\(data:image/([^;]+);base64,([^)]+)\)"#)
    }()

    static func stripInlineImages(from text: String) -> String {
        guard let regex = inlineImageRegex else { return text }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        guard regex.firstMatch(in: text, range: range) != nil else { return text }
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractInlineImageAttachments(from text: String) -> [Attachment] {
        guard let regex = inlineImageRegex else { return [] }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, range: range)
        return matches.compactMap { match in
            guard match.numberOfRanges >= 3 else { return nil }
            let format = nsText.substring(with: match.range(at: 1))
            let base64 = nsText.substring(with: match.range(at: 2))
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: " ", with: "")
            guard !base64.isEmpty else { return nil }
            return Attachment(
                id: UUID(),
                kind: .image,
                fileName: "generated_image.\(format)",
                mimeType: "image/\(format)",
                base64Data: base64
            )
        }
    }

    private static func extractFromParts(_ parts: [Part]) -> [Attachment] {
        return parts.compactMap { part in
            guard part.type == "image_url",
                  let urlStr = part.image_url?.url, !urlStr.isEmpty else { return nil }
            if urlStr.hasPrefix("data:image/") {
                let components = urlStr.components(separatedBy: ",")
                guard components.count == 2 else { return nil }
                let meta = components[0] // data:image/png;base64
                let base64 = components[1]
                let mimeType = meta
                    .replacingOccurrences(of: "data:", with: "")
                    .replacingOccurrences(of: ";base64", with: "")
                return Attachment(
                    id: UUID(),
                    kind: .image,
                    fileName: "generated_image.\(mimeType.replacingOccurrences(of: "image/", with: ""))",
                    mimeType: mimeType,
                    base64Data: base64
                )
            } else {
                return Attachment(
                    id: UUID(),
                    kind: .image,
                    fileName: "generated_image.png",
                    mimeType: "image/png",
                    base64Data: urlStr
                )
            }
        }
    }
}

extension OpenRouterService {
    fileprivate static func parseUsage(_ usage: OpenRouterUsage?) -> UsageBreakdown {
        guard let usage else { return UsageBreakdown() }
        let cached = usage.prompt_tokens_details?.cached_tokens ?? 0
        let writeTokens = usage.prompt_tokens_details?.cache_write_tokens ?? 0
        let totalPrompt = usage.prompt_tokens ?? 0
        return UsageBreakdown(
            promptTokens: max(0, totalPrompt - cached - writeTokens),
            cachedInputTokens: cached,
            cacheCreation5mTokens: 0,
            cacheCreation1hTokens: writeTokens,
            completionTokens: usage.completion_tokens ?? 0,
            reasoningTokens: 0,
            upstreamCost: usage.cost,
            cacheReadObserved: usage.prompt_tokens_details?.cached_tokens != nil,
            cacheWriteObserved: usage.prompt_tokens_details?.cache_write_tokens != nil
        )
    }

    #if DEBUG
    static func parseUsageForTesting(
        promptTokens: Int?,
        completionTokens: Int?,
        cost: Double?,
        cachedTokens: Int?,
        cacheWriteTokens: Int?
    ) -> UsageBreakdown {
        let details: OpenRouterUsage.PromptTokensDetails?
        if cachedTokens != nil || cacheWriteTokens != nil {
            details = OpenRouterUsage.PromptTokensDetails(
                cached_tokens: cachedTokens,
                cache_write_tokens: cacheWriteTokens
            )
        } else {
            details = nil
        }
        let usage = OpenRouterUsage(
            prompt_tokens: promptTokens,
            completion_tokens: completionTokens,
            total_tokens: nil,
            cost: cost,
            prompt_tokens_details: details
        )
        return parseUsage(usage)
    }
    #endif
}

private final class OpenRouterPricingCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: (prompt: Double, completion: Double)] = [:]

    func store(_ models: [AIModel]) {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll(keepingCapacity: true)
        for model in models {
            let prompt = model.promptPrice ?? 0
            let completion = model.completionPrice ?? 0
            if prompt > 0 || completion > 0 {
                cache[model.id] = (prompt, completion)
            }
        }
    }

    func pricing(for modelID: String) -> (prompt: Double, completion: Double)? {
        lock.lock()
        defer { lock.unlock() }
        return cache[modelID]
    }
}


extension URLSession.AsyncBytes {
    var utf8Lines: AsyncThrowingStream<String, Error> {
        let source = self
        return AsyncThrowingStream { continuation in
            let task = Task {
                var buffer = Data()
                do {
                    for try await byte in source {
                        if byte == UInt8(ascii: "\n") {
                            if !buffer.isEmpty,
                               let line = String(data: buffer, encoding: .utf8) {
                                continuation.yield(line)
                            }
                            buffer.removeAll(keepingCapacity: true)
                        } else if byte != UInt8(ascii: "\r") {
                            buffer.append(byte)
                        }
                    }
                    if !buffer.isEmpty,
                       let line = String(data: buffer, encoding: .utf8) {
                        continuation.yield(line)
                    }
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
}
