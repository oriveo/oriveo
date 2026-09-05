import Foundation
import CryptoKit
import OriveoProviderKit

final class OpenAIService: BaseAPIService, ProviderServiceProtocol, CustomBaseURLProvider {


    func syncProvider(apiKey: String, preferredModelID: String?) async throws -> ProviderSyncResult {
        try validateAPIKey(apiKey)

        await MetadataClient.shared.ensureInitialized()
        return ProviderSyncResult(models: [])
    }


    func syncProvider(apiKey: String, preferredModelID: String?, baseURL: String) async throws -> ProviderSyncResult {
        try await syncProvider(apiKey: apiKey, preferredModelID: preferredModelID, baseURL: baseURL, relayRequested: nil)
    }

    func syncProvider(
        apiKey: String,
        preferredModelID: String?,
        baseURL: String,
        relayRequested: RelayRequestedConfig?
    ) async throws -> ProviderSyncResult {
        try validateRelayAPIKeyIfRequired(apiKey, relayRequested: relayRequested)

        let normalizedBase: String
        if relayRequested?.engineProfile != nil {
            normalizedBase = try requireConfiguredRelayBaseURL(
                apiKey: apiKey,
                baseURL: relayRequested?.resolvedAPIBaseURL ?? baseURL,
                relayRequested: relayRequested
            )
        } else {
            normalizedBase = try RelayEndpointPolicy.requireSecure(baseURL)
        }
        let urlString = "\(normalizedBase)/models"
        guard let url = URL(string: urlString) else {
            throw ProviderServiceError.invalidConfiguration(detail: "Invalid base URL: \(baseURL)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        applyHeaders(to: &request, apiKey: apiKey)
        request.applyRelaySecurityMode(relayRequested)
        let response: OpenAIModelsResponse = try await perform(request, isRelay: true)
        let chatModels = response.data.filter { isChatModel($0.id) }
        let models = await buildModels(from: chatModels, preferredModelID: preferredModelID)

        return ProviderSyncResult(
            models: models
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
            baseURL: baseURL,
            reasoningMode: .automatic,
            requestOptions: ChatRequestOptions(),
            relayRequested: nil
        )
    }

    func sendMessageStream(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        baseURL: String,
        reasoningMode: ReasoningMode = .automatic,
        requestOptions: ChatRequestOptions = ChatRequestOptions(),
        relayRequested: RelayRequestedConfig? = nil,
        webSearchEnabled: Bool = false,
        supportsImageGeneration: Bool = false,
        imageToolModelID: String? = nil
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try self.validateRelayAPIKeyIfRequired(apiKey, relayRequested: relayRequested)
                    let secureBaseURL = try self.requireConfiguredRelayBaseURL(
                        apiKey: apiKey,
                        baseURL: baseURL,
                        relayRequested: relayRequested
                    )
                    guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw ProviderServiceError.invalidConfiguration(detail: "Missing model identifier.")
                    }

                    let transport = relayRequested?.transport ?? .openaiChatCompletions
                    let webSearchShape: MetadataClient.StreamShape? = webSearchEnabled
                        ? self.resolveRelayWebSearchShape(modelID: modelID, relayRequested: relayRequested)
                        : nil
                    switch transport {
                    case .llamacppNative:
                        let stream = self.streamLlamaCppNative(
                            messages: messages,
                            apiKey: apiKey,
                            baseURL: secureBaseURL,
                            requestOptions: requestOptions,
                            relayRequested: relayRequested
                        )
                        for try await event in stream {
                            continuation.yield(event)
                        }
                        continuation.finish()

                    case .openaiResponses:
                        let stream = self.streamRelayResponses(
                            initialReasoningEffort: self.resolveRelayResponsesReasoningEffort(
                                relayRequested: relayRequested,
                                reasoningMode: reasoningMode
                            ),
                            webSearchShape: webSearchShape
                        ) { hints in
                            try self.buildRelayResponsesRequest(
                                modelID: modelID,
                                messages: messages,
                                apiKey: apiKey,
                                baseURL: secureBaseURL,
                                stream: true,
                                reasoningMode: reasoningMode,
                                requestOptions: requestOptions,
                                relayRequested: relayRequested,
                                reasoningEffortOverride: hints.reasoningEffortOverride,
                                webSearchEnabled: webSearchEnabled,
                                supportsImageGeneration: supportsImageGeneration,
                                imageToolModelID: imageToolModelID,
                                removeTools: hints.removeTools
                            )
                        }
                        for try await event in stream {
                            continuation.yield(event)
                        }
                        continuation.finish()

                    case .openaiChatCompletions, .auto, .anthropicMessages, .geminiGenerateContent:
                        let stream = self.streamRelayChatCompletions(
                            initialReasoningEffort: self.resolveRelayChatCompletionsReasoningEffort(
                                relayRequested: relayRequested,
                                reasoningMode: reasoningMode
                            ),
                            webSearchShape: webSearchShape
                        )
                        { reasoningEffortOverride in
                            try self.buildChatCompletionsRequest(
                                modelID: modelID,
                                messages: messages,
                                apiKey: apiKey,
                                stream: true,
                                baseURL: secureBaseURL,
                                reasoningMode: reasoningMode,
                                requestOptions: requestOptions,
                                relayRequested: relayRequested,
                                reasoningEffortOverride: reasoningEffortOverride
                            )
                        }
                        for try await event in stream {
                            continuation.yield(event)
                        }
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
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
            reasoningMode: .automatic,
            webSearchEnabled: false,
            supportsImageGeneration: false,
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
            baseURL: baseURL,
            reasoningMode: .automatic,
            requestOptions: ChatRequestOptions(),
            relayRequested: nil
        )
    }

    func sendMessage(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        baseURL: String,
        reasoningMode: ReasoningMode = .automatic,
        requestOptions: ChatRequestOptions = ChatRequestOptions(),
        relayRequested: RelayRequestedConfig? = nil,
        webSearchEnabled: Bool = false,
        supportsImageGeneration: Bool = false,
        imageToolModelID: String? = nil
    ) async throws -> ProviderChatResult {
        try validateRelayAPIKeyIfRequired(apiKey, relayRequested: relayRequested)
        let secureBaseURL = try requireConfiguredRelayBaseURL(
            apiKey: apiKey,
            baseURL: baseURL,
            relayRequested: relayRequested
        )
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderServiceError.invalidConfiguration(detail: "Missing model identifier.")
        }

        let transport = relayRequested?.transport ?? .openaiChatCompletions
        switch transport {
        case .llamacppNative:
            return try await sendLlamaCppNative(
                messages: messages,
                apiKey: apiKey,
                baseURL: secureBaseURL,
                requestOptions: requestOptions,
                relayRequested: relayRequested
            )

        case .openaiResponses:
            let (data, _) = try await performRelayResponsesDataRequestWithFallbacks(
                initialReasoningEffort: resolveRelayResponsesReasoningEffort(
                    relayRequested: relayRequested,
                    reasoningMode: reasoningMode
                )
            ) { hints in
                try self.buildRelayResponsesRequest(
                    modelID: modelID,
                    messages: messages,
                    apiKey: apiKey,
                    baseURL: secureBaseURL,
                    stream: false,
                    reasoningMode: reasoningMode,
                    requestOptions: requestOptions,
                    relayRequested: relayRequested,
                    reasoningEffortOverride: hints.reasoningEffortOverride,
                    webSearchEnabled: webSearchEnabled,
                    supportsImageGeneration: supportsImageGeneration,
                    imageToolModelID: imageToolModelID,
                    removeTools: hints.removeTools
                )
            }

            let response: ResponsesResponse
            do {
                response = try decoder.decode(ResponsesResponse.self, from: data)
            } catch {
                throw ProviderServiceError.network(detail: "Decoding failed: \(error.localizedDescription)")
            }

            let text = response.resolvedText.trimmingCharacters(in: .whitespacesAndNewlines)
            let attachments = response.resolvedAttachments
            guard !text.isEmpty || !attachments.isEmpty else {
                throw ProviderServiceError.emptyResponse
            }

            let breakdown = Self.parseResponsesUsage(response.usage)
            return ProviderChatResult(
                text: text,
                promptTokens: breakdown.totalInputTokens,
                completionTokens: breakdown.completionTokens,
                estimatedCost: 0,
                attachments: attachments.isEmpty ? nil : attachments,
                usageBreakdown: breakdown,
                costSource: nil
            )

        case .openaiChatCompletions, .auto, .anthropicMessages, .geminiGenerateContent:
            let (data, _) = try await performRelayDataRequestWithXHighRetry(
                initialReasoningEffort: resolveRelayChatCompletionsReasoningEffort(
                    relayRequested: relayRequested,
                    reasoningMode: reasoningMode
                )
            ) { reasoningEffortOverride in
                try self.buildChatCompletionsRequest(
                    modelID: modelID,
                    messages: messages,
                    apiKey: apiKey,
                    stream: false,
                    baseURL: secureBaseURL,
                    reasoningMode: reasoningMode,
                    requestOptions: requestOptions,
                    relayRequested: relayRequested,
                    reasoningEffortOverride: reasoningEffortOverride
                )
            }

            let response: ChatCompletionResponse
            do {
                response = try decoder.decode(ChatCompletionResponse.self, from: data)
            } catch {
                throw ProviderServiceError.network(detail: "Decoding failed: \(error.localizedDescription)")
            }

            guard let choice = response.choices.first else {
                throw ProviderServiceError.emptyResponse
            }
            let text = choice.message.content.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let toolCalls = Self.nonStreamingToolCalls(choice.message.tool_calls)
            guard !text.isEmpty || !toolCalls.isEmpty else {
                throw ProviderServiceError.emptyResponse
            }

            let breakdown = Self.parseUsage(response.usage)
            return ProviderChatResult(
                text: text,
                promptTokens: breakdown.totalInputTokens,
                completionTokens: breakdown.completionTokens,
                estimatedCost: 0,
                usageBreakdown: breakdown,
                costSource: nil,
                toolCalls: toolCalls.isEmpty ? nil : toolCalls
            )
        }
    }

    func sendMessage(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        reasoningMode: ReasoningMode = .automatic,
        webSearchEnabled: Bool = false,
        supportsImageGeneration: Bool = false,
        requestOptions: ChatRequestOptions = ChatRequestOptions()
    ) async throws -> ProviderChatResult {
        try validateAPIKey(apiKey)
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderServiceError.invalidConfiguration(detail: "Missing model identifier.")
        }

        let transport = resolvedOfficialTransport(modelID: modelID)

        if transport == .openaiChat {
            return try await sendMessageViaChatCompletions(
                apiKey: apiKey,
                modelID: modelID,
                messages: messages,
                reasoningMode: reasoningMode,
                webSearchEnabled: webSearchEnabled,
                supportsImageGeneration: supportsImageGeneration,
                requestOptions: requestOptions
            )
        }

        let (data, httpResponse) = try await performRawWithUnsupportedParamSelfHeal(
            providerKind: resolveCostProviderKind(modelID: modelID),
            modelID: modelID,
            shouldReturnWithoutMapping: { statusCode, data, _ in
                self.isResponsesNotSupported(statusCode, data: data)
            }
        ) { droppedParams in
            try buildResponsesRequest(
                modelID: modelID,
                messages: messages,
                apiKey: apiKey,
                stream: false,
                supportsImageGeneration: supportsImageGeneration,
                reasoningMode: reasoningMode,
                webSearchEnabled: webSearchEnabled,
                requestOptions: requestOptions,
                droppedParams: droppedParams
            )
        }

        if isResponsesNotSupported(httpResponse.statusCode, data: data) {
            return try await sendMessageViaChatCompletions(
                apiKey: apiKey,
                modelID: modelID,
                messages: messages,
                reasoningMode: reasoningMode,
                webSearchEnabled: webSearchEnabled,
                supportsImageGeneration: supportsImageGeneration,
                requestOptions: requestOptions
            )
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw mapHTTPError(statusCode: httpResponse.statusCode, data: data)
        }



        let responsesResult: ResponsesResponse
        do {
            responsesResult = try decoder.decode(ResponsesResponse.self, from: data)
        } catch {
            throw ProviderServiceError.network(detail: "Decoding failed: \(error.localizedDescription)")
        }

        let text = responsesResult.resolvedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageAttachments = responsesResult.resolvedAttachments
        // Responses can finish with a usable opaque response ID but no displayable text (tool or
        // non-text output). Save the completed protocol state before the display-layer empty guard.
        let continuationRecipe = RecipeContinuationRuntime.selectedRecipe(
            provider: .openAI, modelID: modelID, transport: resolvedOfficialTransport(modelID: modelID).rawValue,
            webSearchEnabled: webSearchEnabled, reasoningMode: reasoningMode,
            continuationKind: "previous_id", parser: { $0 == "openai_responses_web_v1" || $0 == "openai_responses_reasoning_v1" }
        )
        try RecipeContinuationRuntime.save(
            messageID: requestOptions.localContinuationMessageID,
            recipe: continuationRecipe,
            state: responsesResult.id.map { ["previousResponseId": .string($0)] } ?? [:]
        )
        guard !text.isEmpty || !imageAttachments.isEmpty else {
            throw ProviderServiceError.emptyResponse
        }

        let breakdown = Self.parseResponsesUsage(responsesResult.usage)
        let providerKind = resolveCostProviderKind(modelID: modelID)
        let (cost, source) = await MetadataClient.shared.calcCost(
            breakdown: breakdown, modelID: modelID, providerKind: providerKind
        )
        return ProviderChatResult(
            text: text,
            promptTokens: breakdown.totalInputTokens,
            completionTokens: breakdown.completionTokens,
            estimatedCost: cost,
            attachments: imageAttachments.isEmpty ? nil : imageAttachments,
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
            reasoningMode: .automatic,
            webSearchEnabled: false,
            supportsImageGeneration: false
        )
    }

    func sendMessageStream(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        reasoningMode: ReasoningMode = .automatic,
        webSearchEnabled: Bool = false,
        supportsImageGeneration: Bool = false,
        requestOptions: ChatRequestOptions = ChatRequestOptions()
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        openAIDirectStreamCore(
            apiKey: apiKey, modelID: modelID, messages: messages,
            reasoningMode: reasoningMode, webSearchEnabled: webSearchEnabled,
            supportsImageGeneration: supportsImageGeneration, requestOptions: requestOptions
        )
    }

    private func openAIDirectStreamCore(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        reasoningMode: ReasoningMode,
        webSearchEnabled: Bool,
        supportsImageGeneration: Bool,
        requestOptions: ChatRequestOptions
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try self.validateAPIKey(apiKey)
                    guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw ProviderServiceError.invalidConfiguration(detail: "Missing model identifier.")
                    }

                    let subscription = requestOptions.openAISubscription

                    let bytes: URLSession.AsyncBytes
                    if let subscription {
                        let request = try self.buildCodexSubscriptionResponsesRequest(
                            modelID: modelID,
                            messages: messages,
                            apiKey: apiKey,
                            subscription: subscription,
                            reasoningMode: reasoningMode,
                            webSearchEnabled: webSearchEnabled,
                            requestOptions: requestOptions
                        )
                        bytes = try await self.codexSubscriptionResponsesBytes(request: request)
                    } else {
                        let transport = self.resolvedOfficialTransport(modelID: modelID)
                        if transport == .openaiChat {
                            try await self.streamViaChatCompletions(
                                apiKey: apiKey,
                                modelID: modelID,
                                messages: messages,
                                reasoningMode: reasoningMode,
                                webSearchEnabled: webSearchEnabled,
                                supportsImageGeneration: supportsImageGeneration,
                                requestOptions: requestOptions,
                                continuation: continuation
                            )
                            return
                        }
                        if transport == .openaiImages {
                            throw ProviderServiceError.invalidConfiguration(
                                detail: "OpenAI image models require the non-streaming Images endpoint."
                            )
                        }

                        let request = try self.buildResponsesRequest(
                            modelID: modelID,
                            messages: messages,
                            apiKey: apiKey,
                            stream: true,
                            supportsImageGeneration: supportsImageGeneration,
                            reasoningMode: reasoningMode,
                            webSearchEnabled: webSearchEnabled,
                            requestOptions: requestOptions
                        )
                        do {
                            (bytes, _) = try await self.bytesWithUnsupportedParamSelfHeal(
                                providerKind: self.resolveCostProviderKind(modelID: modelID),
                                modelID: modelID,
                                request: request,
                                effectiveTransport: TransportKind.openaiResponses.rawValue
                            )
                        } catch let error as ProviderServiceError {
                            guard case let .upstream(statusCode, _) = error, statusCode == 404 else { throw error }
                            try await self.streamViaChatCompletions(
                                apiKey: apiKey,
                                modelID: modelID,
                                messages: messages,
                                reasoningMode: reasoningMode,
                                webSearchEnabled: webSearchEnabled,
                                supportsImageGeneration: supportsImageGeneration,
                                requestOptions: requestOptions,
                                continuation: continuation
                            )
                            return
                        }
                    }

                    var accumulatedText = ""
                    var lastUsage: ResponsesUsage?
                    var completedResponseID: String?
                    var currentEvent = ""
                    var emittedImages = Set<String>()
                    let responsesStrategy = TransportRegistry.strategy(for: .openaiResponses)
                    let responsesShape = MetadataClient.shared.syncWebSearchStreamShape(
                        profileName: MetadataClient.shared.syncResolveCatalogModel(
                            modelID: modelID,
                            providerKind: self.resolveCostProviderKind(modelID: modelID)
                        )?.profiles.webSearch
                    )
                    var responsesCtx = StreamContext()
                    var lastCitationsCount = 0

                    for try await line in bytes.utf8Lines {
                        if Task.isCancelled { break }

                        if line.hasPrefix("event: ") {
                            currentEvent = String(line.dropFirst(7))
                            continue
                        }

                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        guard let jsonData = payload.data(using: .utf8) else { continue }

                        if !currentEvent.isEmpty {
                            let injected = self.injectResponsesEventType(payload: payload, type: currentEvent)
                            for ev in responsesStrategy.parseStreamLine(
                                injected,
                                ctx: &responsesCtx,
                                shape: responsesShape
                            ) {
                                switch ev {
                                case .reasoning, .toolCallDeltas: continuation.yield(ev)
                                default: break
                                }
                            }
                            let snapshot = responsesCtx.citationsAccumulator.citations
                            if snapshot.count > lastCitationsCount {
                                lastCitationsCount = snapshot.count
                                continuation.yield(.citations(snapshot))
                            }
                        }

                        switch currentEvent {
                        case "response.output_text.delta":
                            do {
                                let delta = try self.decoder.decode(ResponsesStreamDelta.self, from: jsonData)
                                if let text = delta.delta, !text.isEmpty {
                                    accumulatedText += text
                                    continuation.yield(.delta(text))
                                }
                            } catch {
                            }
                        case "response.output_image.done",
                             "response.image_generation_call.completed",
                             "response.output_item.done":
                            do {
                                let imageEvent = try self.decoder.decode(ResponsesStreamImageDone.self, from: jsonData)
                                if let base64 = imageEvent.resolvedResult,
                                   emittedImages.insert(imageEvent.resolvedIdentity ?? base64).inserted {
                                    let attachment = Attachment(
                                        id: UUID(),
                                        kind: .image,
                                        fileName: "generated_image.png",
                                        mimeType: "image/png",
                                        base64Data: base64
                                    )
                                    continuation.yield(.imagePart(attachment))
                                }
                            } catch {
                            }
                        case "response.completed":
                            do {
                                let completed = try self.decoder.decode(ResponsesStreamCompleted.self, from: jsonData)
                                lastUsage = completed.resolvedUsage
                                completedResponseID = completed.resolvedID
                                #if DEBUG
                                AppLog.info(
                                    "Responses stream completed, payload \(payload.count) characters",
                                    module: "OpenAI"
                                )
                                #endif
                            } catch {
                            }
                        default:
                            break
                        }

                        currentEvent = ""
                    }

                    for ev in OpenAIResponsesStrategy.flushToolCalls(ctx: &responsesCtx) { continuation.yield(ev) }
                    let finalText = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if subscription == nil {
                        let continuationRecipe = RecipeContinuationRuntime.selectedRecipe(
                            provider: .openAI, modelID: modelID, transport: TransportKind.openaiResponses.rawValue,
                            webSearchEnabled: webSearchEnabled, reasoningMode: reasoningMode,
                            continuationKind: "previous_id", parser: { $0 == "openai_responses_web_v1" || $0 == "openai_responses_reasoning_v1" }
                        )
                        try RecipeContinuationRuntime.save(
                            messageID: requestOptions.localContinuationMessageID,
                            recipe: continuationRecipe,
                            state: completedResponseID.map { ["previousResponseId": .string($0)] } ?? [:]
                        )
                    }
                    let breakdown = Self.parseResponsesUsage(lastUsage)
                    let providerKind = self.resolveCostProviderKind(modelID: modelID)
                    let (cost, source): (Double, CostSource) = subscription != nil
                        ? (0, .subscription)
                        : await MetadataClient.shared.calcCost(
                            breakdown: breakdown, modelID: modelID, providerKind: providerKind
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

    private static func buildRequestMessage(_ msg: ChatMessage, model: AIModel? = nil) -> ChatCompletionRequest.Message {
        let atts = msg.attachments ?? []
        let imageAtts = atts.filter { $0.kind == .image }

        let (combinedText, _) = BaseAPIService.injectFileAttachmentsAsText(
            userText: msg.text,
            attachments: atts,
            provider: .openAI,
            model: model
        )

        guard !imageAtts.isEmpty else {
            return .init(role: msg.role.rawValue, content: .text(combinedText))
        }

        var parts: [ChatCompletionRequest.ContentPart] = [.init(type: "text", text: combinedText)]
        for a in imageAtts {
            let dataURL = a.resolvedDataURL
            guard !dataURL.isEmpty else { continue }
            parts.append(.init(type: "image_url", image_url: .init(url: dataURL, detail: "auto")))
        }
        return .init(role: msg.role.rawValue, content: .parts(parts))
    }


    private func sendMessageViaChatCompletions(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        reasoningMode: ReasoningMode,
        webSearchEnabled: Bool,
        supportsImageGeneration: Bool,
        requestOptions: ChatRequestOptions = ChatRequestOptions()
    ) async throws -> ProviderChatResult {
        let (data, _) = try await performRawWithUnsupportedParamSelfHeal(
            providerKind: resolveCostProviderKind(modelID: modelID),
            modelID: modelID
        ) { droppedParams in
            try buildChatCompletionsRequest(
                modelID: modelID,
                messages: messages,
                apiKey: apiKey,
                stream: false,
                reasoningMode: reasoningMode,
                webSearchEnabled: webSearchEnabled,
                supportsImageGeneration: supportsImageGeneration,
                requestOptions: requestOptions,
                droppedParams: droppedParams
            )
        }
        let response: ChatCompletionResponse
        do {
            response = try decoder.decode(ChatCompletionResponse.self, from: data)
        } catch {
            throw ProviderServiceError.network(detail: "Decoding failed: \(error.localizedDescription)")
        }
        guard let choice = response.choices.first else {
            throw ProviderServiceError.emptyResponse
        }
        let text = choice.message.content.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let toolCalls = Self.nonStreamingToolCalls(choice.message.tool_calls)
        guard !text.isEmpty || !toolCalls.isEmpty else {
            throw ProviderServiceError.emptyResponse
        }
        let breakdown = Self.parseUsage(response.usage)
        let providerKind = resolveCostProviderKind(modelID: modelID)
        let (cost, source) = await MetadataClient.shared.calcCost(
            breakdown: breakdown, modelID: modelID, providerKind: providerKind
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

    static func nonStreamingToolCalls(_ raw: [ChatCompletionToolCall]?) -> [ProviderToolCall] {
        (raw ?? []).compactMap { call in
            guard let function = call.function else { return nil }
            return ProviderToolCall(
                providerCallID: call.id,
                name: ToolFunctionNameCodec.decode(function.name ?? ""),
                rawArguments: function.arguments ?? ""
            )
        }
    }

    private func streamViaChatCompletions(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        reasoningMode: ReasoningMode,
        webSearchEnabled: Bool,
        supportsImageGeneration: Bool,
        requestOptions: ChatRequestOptions = ChatRequestOptions(),
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        let request = try buildChatCompletionsRequest(
            modelID: modelID,
            messages: messages,
            apiKey: apiKey,
            stream: true,
            reasoningMode: reasoningMode,
            webSearchEnabled: webSearchEnabled,
            supportsImageGeneration: supportsImageGeneration,
            requestOptions: requestOptions
        )
        let (bytes, _) = try await bytesWithUnsupportedParamSelfHeal(
            providerKind: resolveCostProviderKind(modelID: modelID),
            modelID: modelID,
            request: request,
            effectiveTransport: TransportKind.openaiChat.rawValue
        )

        var accumulatedText = ""
        var lastUsage: OpenAIUsage?
        let chatStrategy = TransportRegistry.strategy(for: .openaiChat)
        let chatShape = MetadataClient.shared.syncWebSearchStreamShape(
            profileName: MetadataClient.shared.syncResolveCatalogModel(
                modelID: modelID,
                providerKind: resolveCostProviderKind(modelID: modelID)
            )?.profiles.webSearch
        )
        var chatCtx = StreamContext()
        var chatLastCitationsCount = 0
        defer {
            for ev in OpenAIChatStrategy.flushToolCalls(ctx: &chatCtx) { continuation.yield(ev) }
        }

        for try await line in bytes.utf8Lines {
            if Task.isCancelled { break }
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" { break }
            guard let chunkData = payload.data(using: .utf8) else { continue }
            let chunk: OpenAIStreamChunk
            do {
                chunk = try decoder.decode(OpenAIStreamChunk.self, from: chunkData)
            } catch {
                continue
            }
            if let usage = chunk.usage { lastUsage = usage }
            if let delta = chunk.choices?.first?.delta,
               let content = delta.content?.text, !content.isEmpty {
                accumulatedText += content
                continuation.yield(.delta(content))
            }

            for ev in chatStrategy.parseStreamLine(payload, ctx: &chatCtx, shape: chatShape) {
                switch ev {
                case let .reasoning(text): continuation.yield(.reasoning(text))
                case .toolCallDeltas: continuation.yield(ev)
                default: break
                }
            }
            let snapshot = chatCtx.citationsAccumulator.citations
            if snapshot.count > chatLastCitationsCount {
                chatLastCitationsCount = snapshot.count
                continuation.yield(.citations(snapshot))
            }
        }
        for ev in OpenAIChatStrategy.flushToolCalls(ctx: &chatCtx) {
            continuation.yield(ev)
        }

        let finalText = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let breakdown = Self.parseUsage(lastUsage)
        let providerKind = resolveCostProviderKind(modelID: modelID)
        let (cost, source) = await MetadataClient.shared.calcCost(
            breakdown: breakdown, modelID: modelID, providerKind: providerKind
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
    }


    private func buildResponsesRequest(
        modelID: String,
        messages: [ChatMessage],
        apiKey: String,
        stream: Bool,
        supportsImageGeneration: Bool,
        reasoningMode: ReasoningMode,
        webSearchEnabled: Bool,
        requestOptions: ChatRequestOptions = ChatRequestOptions(),
        droppedParams: Set<String> = []
    ) throws -> URLRequest {
        let resolved = MetadataClient.shared.syncResolveCatalogModel(modelID: modelID, providerKind: .openAI)
        var request = URLRequest(url: try resolveOfficialEndpoint(kind: .responses))
        request.httpMethod = "POST"
        request.timeoutInterval = stream ? 120 : 60
        applyHeaders(to: &request, apiKey: apiKey)
        let recipeLegacyInput = CapabilityRecipeRequestCompiler.legacyInput(
            providerKind: .openAI, modelID: modelID,
            webSearchEnabled: webSearchEnabled, reasoningMode: reasoningMode
        )
        let continuationRecipe = RecipeContinuationRuntime.selectedRecipe(
            provider: .openAI, modelID: modelID, transport: resolved?.transport ?? "",
            webSearchEnabled: webSearchEnabled, reasoningMode: reasoningMode,
            continuationKind: "previous_id", parser: { $0 == "openai_responses_web_v1" || $0 == "openai_responses_reasoning_v1" }
        )
        let previousResponseID = continuationRecipe.flatMap { _ in
            RecipeContinuationRuntime.previousResponseID(
                explicitMessageID: requestOptions.localExplicitContinuationMessageID
            )
        }
        // `previous_response_id` owns the historical leg server-side. Re-sending it alongside
        // ChatRequestBuilder's partial assistant duplicates context and violates Responses wire.
        let requestMessagesInput: [ChatMessage]
        if previousResponseID != nil,
           let continuationUser = messages.last(where: { $0.role == .user }) {
            requestMessagesInput = [continuationUser]
        } else {
            requestMessagesInput = messages
        }
        let capabilityIntent = CapabilityEvidenceProductionAdapter.finalChatIntent(
            messages: requestMessagesInput, request: request,
            effectiveTransport: resolved?.transport ?? "",
            model: requestOptions.capabilityEvidenceModel,
            requestedReasoningMode: recipeLegacyInput.reasoningMode,
            webSearchEnabled: recipeLegacyInput.webSearchEnabled
        )
        let serviceTier: String? = {
            guard let rawTier = requestOptions.relayRequested?.serviceTier else {
                return nil
            }
            let trimmedTier = rawTier.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedTier.isEmpty ? nil : trimmedTier
        }()
        let systemPrompt = requestOptions.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = ResponsesRequest(
            model: modelID,
            input: capabilityIntent.outboundMessages.map { Self.buildResponsesInputMessage($0) },
            instructions: systemPrompt.isEmpty ? nil : systemPrompt,
            stream: stream ? true : nil,
            reasoning: nil,
            tools: nil,
            service_tier: serviceTier,
            store: requestOptions.relayRequested?.disableResponseStorage == true ? false : nil,
            max_output_tokens: resolved?.maxOutputTokens
        )
        var body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any] ?? [:]
        if capabilityIntent.webSearchEnabled,
           let webMerge = ProfileParamsResolver.webSearchMergeParams(
            providerKind: .openAI,
            modelID: modelID,
            profileName: resolved?.profiles.webSearch,
            droppedParams: droppedParams
           ) {
            ProfileParamsResolver.deepMerge(&body, webMerge)
        }
        if supportsImageGeneration,
           let imageMerge = ProfileParamsResolver.imageGenMergeParams(
            providerKind: .openAI,
            modelID: modelID,
            profileName: resolved?.profiles.imageGen,
            droppedParams: droppedParams
           ) {
            ProfileParamsResolver.deepMerge(&body, imageMerge)
        }
        //   HTTP 400 "Your organization must be verified to generate reasoning summaries"
        if recipeLegacyInput.usesLegacyMapping,
           let allowedReasoningMode = capabilityIntent.reasoningMode,
           let reasoningMerge = ProfileParamsResolver.reasoningMergeParams(
            providerKind: .openAI,
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
            to: &body, providerKind: .openAI, modelID: modelID,
            transport: resolved?.transport ?? "", webSearchEnabled: webSearchEnabled,
            reasoningMode: reasoningMode, capabilityPreferences: requestOptions.capabilityPreferences
        )
        // Explicit continue/retry is the only consumer of opaque state.  A normal
        // send has no explicit ID and therefore cannot accidentally stitch an old
        // response onto a new user message.
        if let previousResponseID {
            body.merge(CapabilityRecipeExecution.openAIResponsesPreviousID(previousResponseID)) { _, latest in latest }
        }
        try CapabilityRecipeExecution.applySafeCustomFragments(
            requestOptions.localSafeCustomBodyFragments, to: &body,
            providerKind: .openAI, modelID: modelID,
            transport: resolved?.transport ?? "openai_responses"
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        CapabilityExecutionRuntime.confirmFinalWireEncoded()
        return request
    }

    private func buildImagesGenerationRequest(
        modelID: String,
        messages: [ChatMessage],
        apiKey: String,
        baseURL: String? = nil,
        relayRequested: RelayRequestedConfig? = nil
    ) throws -> URLRequest {
        guard let prompt = Self.latestUserPrompt(in: messages) else {
            throw ProviderServiceError.invalidConfiguration(detail: "Image generation requires a text prompt.")
        }

        let baseURL_ = try Self.makeImagesGenerationURL(
            baseURL: baseURL,
            relayRequested: relayRequested
        )
        let finalURL: URL
        if let relayRequested,
           var components = URLComponents(url: baseURL_, resolvingAgainstBaseURL: false) {
            var items = components.queryItems ?? []
            if resolveRelayOpenAIAuthMode(relayRequested) == .queryKey {
                items.append(URLQueryItem(name: "key", value: apiKey))
            }
            items.append(contentsOf: relayRequested.effectiveQueryParams?.map { URLQueryItem(name: $0.key, value: $0.value) } ?? [])
            components.queryItems = items.isEmpty ? nil : items
            finalURL = components.url ?? baseURL_
        } else {
            finalURL = baseURL_
        }

        var request = URLRequest(url: finalURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        if baseURL?.isEmpty == false {
            applyRelayOpenAIHeaders(
                to: &request,
                apiKey: apiKey,
                relayRequested: relayRequested,
                transport: .openaiChatCompletions
            )
            for header in relayRequested?.effectiveHeaders ?? [] {
                request.setValue(header.value, forHTTPHeaderField: header.key)
            }
        } else {
            applyHeaders(to: &request, apiKey: apiKey)
        }
        let responseFormat: String? = baseURL?.isEmpty == false
            ? (Self.isDedicatedImageModel(modelID) ? nil : "b64_json")
            : nil
        let payload = ImagesGenerationRequest(
            model: modelID,
            prompt: prompt,
            n: 1,
            size: "1024x1024",
            response_format: responseFormat
        )
        var body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any] ?? [:]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func makeImagesGenerationURL(
        baseURL: String?,
        relayRequested: RelayRequestedConfig? = nil
    ) throws -> URL {
        guard let raw = baseURL, !raw.isEmpty else {
            let metadataTransport = MetadataClient.shared.syncProviderTransport(providerKind: .openAI)
            let endpointBase = EndpointResolver.officialMetadataBaseURL(
                providerKind: .openAI,
                metadataTransport: metadataTransport
            ) ?? EndpointResolver.fallbackBaseURL(for: .openAI)
            let endpointPath = metadataTransport?.endpoints?.images
                ?? EndpointResolver.fallbackEndpointPath(.openAI, kind: .images)
            return EndpointResolver.joinURL(base: endpointBase, path: endpointPath)
                ?? URL(string: "https://api.openai.com/v1/images/generations")!
        }
        let apiBaseURL = try RelayEndpointResolver.runtimeAPIBaseURL(
            rawBaseURL: raw,
            relayRequested: relayRequested,
            defaultVersion: "v1",
            acceptedVersions: ["v1"]
        )
        return try RelayEndpointResolver.endpointURL(
            apiBaseURL: apiBaseURL,
            endpointPath: "/images/generations"
        )
    }

    private static func buildResponsesInputMessage(_ msg: ChatMessage, model: AIModel? = nil) -> ResponsesRequest.InputMessage {
        let textType = msg.role == .assistant ? "output_text" : "input_text"
        func textOnly(_ text: String) -> ResponsesRequest.InputMessage {
            .init(role: msg.role.rawValue, content: .parts([.init(type: textType, text: text)]))
        }
        guard let atts = msg.attachments, !atts.isEmpty else {
            return textOnly(msg.text)
        }

        guard msg.role == .user else {
            return textOnly(msg.text)
        }

        let imageAtts = atts.filter { $0.kind == .image }
        let fileAtts = atts.filter { $0.kind == .file }

        let (nativeAtts, textFileAtts) = BaseAPIService.partitionAttachmentsByRoute(
            fileAtts, provider: .openAI, model: model
        )

        let (combinedText, _) = BaseAPIService.injectFileAttachmentsAsText(
            userText: msg.text,
            attachments: textFileAtts,
            provider: .openAI,
            model: model
        )

        if imageAtts.isEmpty && nativeAtts.isEmpty {
            return textOnly(combinedText)
        }

        var parts: [ResponsesRequest.ContentPart] = [.init(type: "input_text", text: combinedText)]
        for a in imageAtts {
            let dataURL = a.resolvedDataURL
            guard !dataURL.isEmpty else { continue }
            parts.append(.init(type: "input_image", image_url: dataURL, detail: "auto"))
        }
        for f in nativeAtts {
            if let base64 = f.originalBase64Data, !base64.isEmpty {
                parts.append(.init(type: "input_file", filename: f.fileName,
                                  file_data: "data:\(f.mimeType);base64,\(base64)"))
            }
        }
        return .init(role: msg.role.rawValue, content: .parts(parts))
    }

    private func buildChatCompletionsRequest(
        modelID: String,
        messages: [ChatMessage],
        apiKey: String,
        stream: Bool,
        reasoningMode: ReasoningMode,
        webSearchEnabled: Bool = false,
        supportsImageGeneration: Bool,
        requestOptions: ChatRequestOptions = ChatRequestOptions(),
        droppedParams: Set<String> = []
    ) throws -> URLRequest {
        let resolved = MetadataClient.shared.syncResolveCatalogModel(modelID: modelID, providerKind: .openAI)
        var request = URLRequest(url: try resolveOfficialEndpoint(kind: .chat))
        request.httpMethod = "POST"
        request.timeoutInterval = stream ? 120 : 60
        applyHeaders(to: &request, apiKey: apiKey)
        let recipeLegacyInput = CapabilityRecipeRequestCompiler.legacyInput(
            providerKind: .openAI, modelID: modelID,
            webSearchEnabled: webSearchEnabled, reasoningMode: reasoningMode
        )
        let capabilityIntent = CapabilityEvidenceProductionAdapter.finalChatIntent(
            messages: messages, request: request,
            effectiveTransport: resolved?.transport ?? "",
            model: requestOptions.capabilityEvidenceModel,
            requestedReasoningMode: recipeLegacyInput.reasoningMode,
            webSearchEnabled: recipeLegacyInput.webSearchEnabled
        )
        var apiMessages: [ChatCompletionRequest.Message] = []
        let systemPrompt = requestOptions.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !systemPrompt.isEmpty {
            apiMessages.append(.init(role: "system", content: .text(systemPrompt)))
        }
        apiMessages.append(contentsOf: capabilityIntent.outboundMessages.map { Self.buildRequestMessage($0) })
        let payload = ChatCompletionRequest(
            model: modelID,
            stream: stream ? true : nil,
            stream_options: stream ? ChatCompletionRequest.StreamOptions() : nil,
            reasoning_effort: nil,
            messages: apiMessages
        )
        var body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any] ?? [:]
        if recipeLegacyInput.usesLegacyMapping,
           let allowedReasoningMode = capabilityIntent.reasoningMode,
           let reasoningMerge = ProfileParamsResolver.reasoningMergeParams(
            providerKind: .openAI,
            modelID: modelID,
            reasoningMode: allowedReasoningMode,
            resolved: resolved,
            droppedParams: droppedParams
        ) {
            ProfileParamsResolver.deepMerge(&body, reasoningMerge)
        }
        if capabilityIntent.webSearchEnabled,
           let webMerge = ProfileParamsResolver.webSearchMergeParams(
            providerKind: .openAI,
            modelID: modelID,
            profileName: resolved?.profiles.webSearch,
            droppedParams: droppedParams
           ) {
            ProfileParamsResolver.deepMerge(&body, webMerge)
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
            to: &body, providerKind: .openAI, modelID: modelID,
            transport: resolved?.transport ?? "", webSearchEnabled: webSearchEnabled,
            reasoningMode: reasoningMode, capabilityPreferences: requestOptions.capabilityPreferences
        )
        try CapabilityRecipeExecution.applySafeCustomFragments(
            requestOptions.localSafeCustomBodyFragments, to: &body,
            providerKind: .openAI, modelID: modelID,
            transport: resolved?.transport ?? "openai_chat"
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        CapabilityExecutionRuntime.confirmFinalWireEncoded()
        return request
    }

    // MARK: - llama.cpp native /completion

    private func buildLlamaCppNativeRequest(
        messages: [ChatMessage],
        apiKey: String,
        baseURL: String,
        stream: Bool,
        requestOptions: ChatRequestOptions,
        relayRequested: RelayRequestedConfig?,
        nPredictOverride: Int? = nil
    ) throws -> URLRequest {
        let root = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(root)/completion") else {
            throw ProviderServiceError.invalidConfiguration(detail: "Invalid llama.cpp endpoint.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = stream ? 120 : 60
        applyRelayOpenAIHeaders(
            to: &request,
            apiKey: apiKey,
            relayRequested: relayRequested,
            transport: .llamacppNative
        )
        for header in relayRequested?.effectiveHeaders ?? [] {
            request.setValue(header.value, forHTTPHeaderField: header.key)
        }
        var body: [String: Any] = [
            "prompt": llamaCppPrompt(messages: messages, systemPrompt: requestOptions.systemPrompt),
            "stream": stream,
        ]
        if let nPredictOverride { body["n_predict"] = nPredictOverride }
        ProfileParamsResolver.applyGenerationParameters(
            to: &body,
            options: requestOptions,
            finalRequest: request,
            effectiveTransport: RelayTransport.llamacppNative.rawValue
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        CapabilityExecutionRuntime.confirmFinalWireEncoded()
        return request
    }

    private func llamaCppPrompt(messages: [ChatMessage], systemPrompt: String) -> String {
        var lines: [String] = []
        let trimmedSystem = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSystem.isEmpty { lines.append("system: \(trimmedSystem)") }
        for message in messages {
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            lines.append("\(message.role.rawValue): \(text)")
        }
        lines.append("assistant:")
        return lines.joined(separator: "\n")
    }

    private func sendLlamaCppNative(
        messages: [ChatMessage],
        apiKey: String,
        baseURL: String,
        requestOptions: ChatRequestOptions,
        relayRequested: RelayRequestedConfig?
    ) async throws -> ProviderChatResult {
        try await preflightLlamaCppNative(
            messages: messages, baseURL: baseURL,
            requestOptions: requestOptions, relayRequested: relayRequested
        )
        let request = try buildLlamaCppNativeRequest(
            messages: messages, apiKey: apiKey, baseURL: baseURL, stream: false,
            requestOptions: requestOptions, relayRequested: relayRequested
        )
        let data: Data
        do {
            (data, _) = try await performRelayRawRequest(
                request, effectiveTransport: .llamacppNative
            )
        } catch let error as RelayHTTPStatusError {
            throw mapHTTPError(statusCode: error.statusCode, data: error.data, isRelay: true)
        }
        let text = try llamaCppContent(from: data).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ProviderServiceError.emptyResponse }
        return ProviderChatResult(text: text, promptTokens: 0, completionTokens: 0, estimatedCost: 0)
    }

    private func streamLlamaCppNative(
        messages: [ChatMessage],
        apiKey: String,
        baseURL: String,
        requestOptions: ChatRequestOptions,
        relayRequested: RelayRequestedConfig?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.preflightLlamaCppNative(
                        messages: messages, baseURL: baseURL,
                        requestOptions: requestOptions, relayRequested: relayRequested
                    )
                    let request = try self.buildLlamaCppNativeRequest(
                        messages: messages, apiKey: apiKey, baseURL: baseURL, stream: true,
                        requestOptions: requestOptions, relayRequested: relayRequested
                    )
                    let (bytes, _) = try await self.executeRelayStreamRequest(
                        request, effectiveTransport: .llamacppNative
                    )
                    var accumulated = ""
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        let payload = line.hasPrefix("data: ") ? String(line.dropFirst(6)) : line
                        guard !payload.isEmpty, payload != "[DONE]" else { continue }
                        guard let data = payload.data(using: .utf8) else { continue }
                        let delta = try self.llamaCppContent(from: data)
                        guard !delta.isEmpty else { continue }
                        accumulated += delta
                        continuation.yield(.delta(delta))
                    }
                    continuation.yield(.done(ProviderChatResult(
                        text: accumulated.trimmingCharacters(in: .whitespacesAndNewlines),
                        promptTokens: 0, completionTokens: 0, estimatedCost: 0
                    )))
                    continuation.finish()
                } catch let error as RelayHTTPStatusError {
                    continuation.finish(throwing: self.mapHTTPError(statusCode: error.statusCode, data: error.data, isRelay: true))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func preflightLlamaCppNative(
        messages: [ChatMessage],
        baseURL: String,
        requestOptions: ChatRequestOptions,
        relayRequested: RelayRequestedConfig?
    ) async throws {
        guard let endpoint = URL(string: baseURL) else { return }
        guard let relayRequested else {
            throw ProviderServiceError.invalidConfiguration(detail: "Missing local connection security context.")
        }
        let prompt = llamaCppPrompt(messages: messages, systemPrompt: requestOptions.systemPrompt)
        let result = await LocalEngineRuntimeClient.preflight(
            endpoint: endpoint,
            engine: .llamacpp,
            prompt: prompt,
            contextLimit: nil,
            requested: relayRequested
        )
        if case .supported(_, _, true) = result { throw LocalEngineConnectionError.contextExceeded }
    }

    private func llamaCppContent(from data: Data) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderServiceError.network(detail: "Invalid llama.cpp response.")
        }
        if let content = object["content"] as? String { return content }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            throw ProviderServiceError.network(detail: message)
        }
        return ""
    }

    private func resolvedOfficialTransport(modelID: String) -> TransportKind {
        guard let raw = MetadataClient.shared.syncResolveCatalogModel(
            modelID: modelID,
            providerKind: .openAI
        )?.transport, let transport = TransportKind(rawValue: raw) else {
            return .openaiChat
        }
        switch transport {
        case .openaiChat, .openaiResponses, .openaiImages:
            return transport
        default:
            return .openaiChat
        }
    }

    private func resolveOfficialEndpoint(kind: EndpointKind) throws -> URL {
        let metadataTransport = MetadataClient.shared.syncProviderTransport(providerKind: .openAI)
        let endpointBase = EndpointResolver.officialMetadataBaseURL(
            providerKind: .openAI,
            metadataTransport: metadataTransport
        ) ?? EndpointResolver.fallbackBaseURL(for: .openAI)
        let endpointPath: String? = {
            switch kind {
            case .chat: return metadataTransport?.endpoints?.chat
            case .responses: return metadataTransport?.endpoints?.responses
            case .images: return metadataTransport?.endpoints?.images
            case .embeddings: return metadataTransport?.endpoints?.embeddings
            case .files: return metadataTransport?.endpoints?.files
            }
        }()
        guard let url = EndpointResolver.joinURL(
            base: endpointBase,
            path: endpointPath ?? EndpointResolver.fallbackEndpointPath(.openAI, kind: kind)
        ) else {
            throw ProviderServiceError.invalidConfiguration(detail: "Invalid OpenAI endpoint.")
        }
        return url
    }

    private func buildCodexSubscriptionResponsesRequest(
        modelID: String,
        messages: [ChatMessage],
        apiKey: String,
        subscription: OpenAISubscriptionRequestContext,
        reasoningMode: ReasoningMode,
        webSearchEnabled: Bool,
        requestOptions: ChatRequestOptions
    ) throws -> URLRequest {
        var request = URLRequest(url: subscription.responsesURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(UserAgentProvider.nativeUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(subscription.accountID, forHTTPHeaderField: "chatgpt-account-id")
        for (name, value) in subscription.requiredHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let systemPrompt = requestOptions.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)

        let model = requestOptions.capabilityEvidenceModel
        let supportsWeb = model?.capabilities.contains(.web) ?? false
        let tools: [ResponsesRequest.Tool]? = (webSearchEnabled && supportsWeb)
            ? [ResponsesRequest.Tool(type: "web_search")]
            : nil
        let effort = Self.codexReasoningEffort(
            for: reasoningMode,
            declaredLevels: CapabilityControlResolution.subscriptionDeclaredReasoningLevels(
                providerKind: .openAI, model: model
            )
        )

        let payload = ResponsesRequest(
            model: modelID,
            input: messages.map { Self.buildResponsesInputMessage($0) },
            instructions: systemPrompt.isEmpty ? nil : systemPrompt,
            stream: true,
            reasoning: ResponsesRequest.Reasoning(effort: effort, summary: "auto"),
            tools: tools,
            service_tier: nil,
            store: false,
            max_output_tokens: nil
        )
        var body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any] ?? [:]
        body["include"] = ["reasoning.encrypted_content"]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func codexReasoningEffort(for mode: ReasoningMode, declaredLevels: [String]) -> String? {
        guard !declaredLevels.isEmpty else { return nil }
        let declared = Set(declaredLevels.map { $0.lowercased() })
        let candidates: [String]
        switch mode {
        case .automatic: return nil
        case .fast: candidates = ["low", "minimal", "medium"]
        case .balanced: candidates = ["medium", "low", "high"]
        case .deep: candidates = ["high", "medium"]
        case .max: candidates = ["xhigh", "high", "medium"]
        }
        return candidates.first { declared.contains($0) }
    }

    private func codexSubscriptionResponsesBytes(request: URLRequest) async throws -> URLSession.AsyncBytes {
        let (bytes, response) = try await session.relayBytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderServiceError.network(detail: "Missing HTTPURLResponse.")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            var errorData = Data()
            for try await byte in bytes { errorData.append(byte) }
            throw mapHTTPError(
                statusCode: http.statusCode, data: errorData,
                url: request.url, request: request,
                subscriptionLane: .openAI
            )
        }
        return bytes
    }

    private func buildChatCompletionsRequest(
        modelID: String,
        messages: [ChatMessage],
        apiKey: String,
        stream: Bool,
        baseURL: String,
        reasoningMode: ReasoningMode,
        requestOptions: ChatRequestOptions = ChatRequestOptions(),
        relayRequested: RelayRequestedConfig? = nil,
        reasoningEffortOverride: String? = nil,
        validationMaxTokens: Int? = nil
    ) throws -> URLRequest {
        let finalURL = try buildRelayEndpointURL(
            baseURL: baseURL,
            defaultVersion: "v1",
            acceptedVersions: ["v1"],
            endpointPath: "/chat/completions",
            relayRequested: relayRequested,
            apiKey: apiKey,
            authMode: resolveRelayOpenAIAuthMode(relayRequested)
        )
        var request = URLRequest(url: finalURL)
        request.httpMethod = "POST"
        request.timeoutInterval = stream ? 120 : 60
        applyRelayOpenAIHeaders(
            to: &request,
            apiKey: apiKey,
            relayRequested: relayRequested,
            transport: .openaiChatCompletions
        )
        for header in relayRequested?.effectiveHeaders ?? [] {
            request.setValue(header.value, forHTTPHeaderField: header.key)
        }
        let evidenceReasoningMode = Self.relaySemanticReasoningMode(
            relayRequested?.reasoningEffort, fallback: reasoningMode
        )
        let capabilityIntent = CapabilityEvidenceProductionAdapter.finalChatIntent(
            messages: messages, request: request,
            effectiveTransport: RelayTransport.openaiChatCompletions.rawValue,
            model: requestOptions.capabilityEvidenceModel,
            requestedReasoningMode: evidenceReasoningMode,
            webSearchEnabled: false
        )
        var apiMessages: [ChatCompletionRequest.Message] = []
        let systemPrompt = requestOptions.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !systemPrompt.isEmpty {
            apiMessages.append(.init(role: "system", content: .text(systemPrompt)))
        }
        apiMessages.append(contentsOf: capabilityIntent.outboundMessages.map { Self.buildRequestMessage($0) })

        let reasoningEffort = capabilityIntent.reasoningMode.flatMap { allowedMode in
            reasoningEffortOverride ?? resolveRelayChatCompletionsReasoningEffort(
                relayRequested: relayRequested,
                reasoningMode: allowedMode
            )
        }
        let serviceTier: String? = {
            guard let relayRequested,
                  relayRequested.transport == .openaiChatCompletions || relayRequested.transport == .openaiResponses,
                  let trimmed = relayRequested.serviceTier?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else {
                return nil
            }
            return trimmed
        }()

        let payload = ChatCompletionRequest(
            model: modelID,
            stream: stream ? true : nil,
            stream_options: stream ? ChatCompletionRequest.StreamOptions() : nil,
            reasoning_effort: reasoningEffort,
            service_tier: serviceTier,
            max_tokens: validationMaxTokens,
            messages: apiMessages
        )
        var body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any] ?? [:]
        ProfileParamsResolver.applyGenerationParameters(
            to: &body,
            options: requestOptions,
            finalRequest: request,
            effectiveTransport: RelayTransport.openaiChatCompletions.rawValue
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        CapabilityExecutionRuntime.confirmFinalWireEncoded()
        return request
    }

    private func buildRelayResponsesRequest(
        modelID: String,
        messages: [ChatMessage],
        apiKey: String,
        baseURL: String,
        stream: Bool,
        reasoningMode: ReasoningMode,
        requestOptions: ChatRequestOptions = ChatRequestOptions(),
        relayRequested: RelayRequestedConfig? = nil,
        reasoningEffortOverride: String? = nil,
        webSearchEnabled: Bool = false,
        supportsImageGeneration: Bool = false,
        imageToolModelID: String? = nil,
        removeTools: Bool = false
    ) throws -> URLRequest {
        let finalURL = try buildRelayEndpointURL(
            baseURL: baseURL,
            defaultVersion: "v1",
            acceptedVersions: ["v1"],
            endpointPath: "/responses",
            relayRequested: relayRequested,
            apiKey: apiKey,
            authMode: resolveRelayOpenAIAuthMode(relayRequested)
        )

        var request = URLRequest(url: finalURL)
        request.httpMethod = "POST"
        request.timeoutInterval = stream ? 120 : 60
        applyRelayOpenAIHeaders(
            to: &request,
            apiKey: apiKey,
            relayRequested: relayRequested,
            transport: .openaiResponses
        )
        for header in relayRequested?.effectiveHeaders ?? [] {
            request.setValue(header.value, forHTTPHeaderField: header.key)
        }

        let evidenceReasoningMode = Self.relaySemanticReasoningMode(
            relayRequested?.reasoningEffort, fallback: reasoningMode
        )
        let capabilityIntent = CapabilityEvidenceProductionAdapter.finalChatIntent(
            messages: messages, request: request,
            effectiveTransport: RelayTransport.openaiResponses.rawValue,
            model: requestOptions.capabilityEvidenceModel,
            requestedReasoningMode: evidenceReasoningMode,
            webSearchEnabled: webSearchEnabled
        )

        let serviceTier: String? = {
            guard let rawTier = relayRequested?.serviceTier else {
                return nil
            }
            let trimmedTier = rawTier.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedTier.isEmpty ? nil : trimmedTier
        }()
        let reasoningEffort = capabilityIntent.reasoningMode.flatMap { allowedMode in
            reasoningEffortOverride ?? resolveRelayResponsesReasoningEffort(
                relayRequested: relayRequested,
                reasoningMode: allowedMode
            )
        }
        let systemPrompt = requestOptions.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var toolsArray: [ResponsesRequest.Tool] = []
        if !removeTools {
            toolsArray.append(.init(
                type: "image_generation",
                model: supportsImageGeneration ? imageToolModelID : nil
            ))
            if capabilityIntent.webSearchEnabled {
                let webSearchName = relayRequested?.webSearchToolName
                    ?? relayWebSearchToolNameFromRuntime(
                        MetadataClient.shared.syncRelayRuntimeConfig()
                            .transportRules[MetadataClient.RelayTransportKey.openaiResponses]?
                            .webSearchToolName
                    )
                    ?? .webSearch
                if webSearchName != .disabled {
                    toolsArray.append(.init(type: webSearchName.rawValue))
                }
            }
        }
        let tools: [ResponsesRequest.Tool]? = toolsArray.isEmpty ? nil : toolsArray
        let payload = ResponsesRequest(
            model: modelID,
            input: capabilityIntent.outboundMessages.map { Self.buildResponsesInputMessage($0) },
            instructions: systemPrompt.isEmpty ? nil : systemPrompt,
            stream: stream ? true : nil,
            reasoning: capabilityIntent.reasoningMode == nil
                ? nil : .init(effort: reasoningEffort, summary: "auto"),
            tools: tools,
            service_tier: serviceTier,
            store: relayRequested?.disableResponseStorage == true ? false : nil,
            max_output_tokens: 16384
        )
        var body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any] ?? [:]
        ProfileParamsResolver.applyGenerationParameters(
            to: &body,
            options: requestOptions,
            finalRequest: request,
            effectiveTransport: RelayTransport.openaiResponses.rawValue
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        CapabilityExecutionRuntime.confirmFinalWireEncoded()
        return request
    }


    struct RelayPingResult {
        let modelCount: Int
        let probedEndpoint: String
    }

    /// - openai_chat_completions / auto + modelID → POST `{base}/chat/completions` 1-token ping
    /// - openai_chat_completions / auto without modelID → GET `{base}/models` catalog fallback
    /// - anthropic_messages → POST `{base}/v1/messages` 1-token ping(max_tokens=1)
    /// - gemini_generate_content → POST `{base}/v1beta/models/{model}:generateContent` 1-token ping
    func pingRelay(
        apiKey: String,
        baseURL: String,
        modelID: String?,
        relayRequested: RelayRequestedConfig?
    ) async throws -> RelayPingResult {
        let secureBaseURL = try requireConfiguredRelayBaseURL(
            apiKey: apiKey,
            baseURL: baseURL,
            relayRequested: relayRequested
        )
        let transport = relayRequested?.transport ?? .auto
        switch transport {
        case .llamacppNative:
            let probedEndpoint = try await pingLlamaCppNative(
                apiKey: apiKey,
                baseURL: secureBaseURL,
                relayRequested: relayRequested
            )
            return RelayPingResult(modelCount: 0, probedEndpoint: probedEndpoint)

        case .openaiResponses:
            let probedEndpoint = try await pingRelayResponses(
                apiKey: apiKey,
                baseURL: secureBaseURL,
                modelID: modelID ?? "gpt-5",
                relayRequested: relayRequested
            )
            return RelayPingResult(modelCount: 0, probedEndpoint: probedEndpoint)
        case .openaiChatCompletions, .auto:
            if let modelID = modelID?.trimmingCharacters(in: .whitespacesAndNewlines),
               !modelID.isEmpty {
                let probedEndpoint = try await pingRelayChatCompletions(
                    apiKey: apiKey,
                    baseURL: secureBaseURL,
                    modelID: modelID,
                    relayRequested: relayRequested
                )
                return RelayPingResult(modelCount: 0, probedEndpoint: probedEndpoint)
            } else {
                let result = try await syncProvider(
                    apiKey: apiKey,
                    preferredModelID: modelID,
                    baseURL: secureBaseURL
                )
                return RelayPingResult(modelCount: result.models.count, probedEndpoint: "GET /models")
            }
        case .anthropicMessages:
            let probedEndpoint = try await pingRelayAnthropicMessages(
                apiKey: apiKey,
                baseURL: secureBaseURL,
                modelID: modelID ?? "claude-3-5-haiku-latest",
                relayRequested: relayRequested
            )
            return RelayPingResult(modelCount: 0, probedEndpoint: probedEndpoint)
        case .geminiGenerateContent:
            let probedEndpoint = try await pingRelayGemini(
                apiKey: apiKey,
                baseURL: secureBaseURL,
                modelID: modelID ?? "gemini-2.0-flash",
                relayRequested: relayRequested
            )
            return RelayPingResult(modelCount: 0, probedEndpoint: probedEndpoint)
        }
    }

    private func pingRelayChatCompletions(
        apiKey: String,
        baseURL: String,
        modelID: String,
        relayRequested: RelayRequestedConfig?
    ) async throws -> String {
        let request = try buildChatCompletionsRequest(
            modelID: modelID,
            messages: [
                ChatMessage(
                    id: UUID(),
                    role: .user,
                    text: "ping",
                    providerKind: .relay,
                    providerName: "Relay",
                    modelName: modelID,
                    state: .delivered
                )
            ],
            apiKey: apiKey,
            stream: false,
            baseURL: baseURL,
            reasoningMode: .automatic,
            relayRequested: relayRequested,
            validationMaxTokens: 1
        )

        let (data, response) = try await session.relayData(for: request)
        try requireSuccessfulRelayPing(data: data, response: response, request: request)
        return "POST /chat/completions"
    }

    private func pingLlamaCppNative(
        apiKey: String,
        baseURL: String,
        relayRequested: RelayRequestedConfig?
    ) async throws -> String {
        let request = try buildLlamaCppNativeRequest(
            messages: [
                ChatMessage(
                    id: UUID(), role: .user, text: "ping", providerKind: .relay,
                    providerName: "Relay", modelName: "", state: .delivered
                )
            ],
            apiKey: apiKey,
            baseURL: baseURL,
            stream: false,
            requestOptions: ChatRequestOptions(),
            relayRequested: relayRequested,
            nPredictOverride: 1
        )
        let (data, response) = try await session.relayData(for: request)
        try requireSuccessfulRelayPing(data: data, response: response, request: request)
        return "POST /completion"
    }

    private func pingRelayResponses(
        apiKey: String,
        baseURL: String,
        modelID: String,
        relayRequested: RelayRequestedConfig?
    ) async throws -> String {
        let url = try buildRelayEndpointURL(
            baseURL: baseURL,
            defaultVersion: "v1",
            acceptedVersions: ["v1"],
            endpointPath: "/responses",
            relayRequested: relayRequested,
            apiKey: apiKey,
            authMode: resolveRelayOpenAIAuthMode(relayRequested)
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        applyRelayOpenAIHeaders(
            to: &request,
            apiKey: apiKey,
            relayRequested: relayRequested,
            transport: .openaiResponses
        )
        for header in relayRequested?.effectiveHeaders ?? [] {
            request.setValue(header.value, forHTTPHeaderField: header.key)
        }

        let payload = ResponsesRequest(
            model: modelID,
            input: [
                .init(
                    role: "user",
                    content: .parts([.init(type: "input_text", text: "ping")])
                )
            ],
            instructions: nil,
            stream: nil,
            reasoning: nil,
            tools: nil,
            service_tier: nil,
            store: relayRequested?.disableResponseStorage == true ? false : nil,
            max_output_tokens: 1
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.relayData(for: request)
        try requireSuccessfulRelayPing(data: data, response: response, request: request)
        return "POST /responses"
    }

    private func pingRelayAnthropicMessages(
        apiKey: String,
        baseURL: String,
        modelID: String,
        relayRequested: RelayRequestedConfig?
    ) async throws -> String {
        let resolvedAuth = resolveRelayAnthropicAuthMode(relayRequested)
        let url = try buildRelayEndpointURL(
            baseURL: baseURL,
            defaultVersion: "v1",
            acceptedVersions: ["v1"],
            endpointPath: "/messages",
            relayRequested: relayRequested,
            apiKey: apiKey,
            authMode: resolvedAuth
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        switch resolvedAuth {
        case .none:
            break
        case .bearer:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .auto, .xApiKey:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        case .xGoogApiKey:
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        case .queryKey:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        for header in resolvedAuth == .none ? [] : relayRequested?.effectiveHeaders ?? [] {
            request.setValue(header.value, forHTTPHeaderField: header.key)
        }
        let body: [String: Any] = [
            "model": modelID,
            "max_tokens": 1,
            "messages": [["role": "user", "content": "ping"]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.relayData(for: request)
        try requireSuccessfulRelayPing(data: data, response: response, request: request)
        return "POST /v1/messages"
    }

    private func pingRelayGemini(
        apiKey: String,
        baseURL: String,
        modelID: String,
        relayRequested: RelayRequestedConfig?
    ) async throws -> String {
        let resolvedAuth = resolveRelayGeminiAuthMode(relayRequested)
        let url = try buildRelayEndpointURL(
            baseURL: baseURL,
            defaultVersion: "v1beta",
            acceptedVersions: ["v1", "v1beta"],
            endpointPath: "/models/\(modelID):generateContent",
            relayRequested: relayRequested,
            apiKey: apiKey,
            authMode: resolvedAuth
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        switch resolvedAuth {
        case .none:
            break
        case .bearer:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .xApiKey:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        case .xGoogApiKey:
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        case .auto, .queryKey:
            break
        }
        for header in resolvedAuth == .none ? [] : relayRequested?.effectiveHeaders ?? [] {
            request.setValue(header.value, forHTTPHeaderField: header.key)
        }
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": "ping"]]]],
            "generationConfig": ["maxOutputTokens": 1],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.relayData(for: request)
        try requireSuccessfulRelayPing(data: data, response: response, request: request)
        return "POST :generateContent"
    }

    private func requireSuccessfulRelayPing(
        data: Data,
        response: URLResponse,
        request: URLRequest
    ) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ProviderServiceError.network(detail: "No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw mapHTTPError(statusCode: http.statusCode, data: data, url: request.url, request: request, isRelay: true)
        }
        guard RelaySuccessResponsePolicy.acceptsGenerationResponse(data: data, response: http) else {
            throw ProviderServiceError.upstream(
                statusCode: http.statusCode,
                detail: "The relay returned an HTML page instead of a generation response."
            )
        }
    }

    private func applyRelayOpenAIHeaders(
        to request: inout URLRequest,
        apiKey: String,
        relayRequested: RelayRequestedConfig?,
        transport: RelayTransport? = nil
    ) {
        request.applyRelaySecurityMode(relayRequested)
        applyJSONHeaders(to: &request)
        let resolvedAuth = resolveRelayOpenAIAuthMode(relayRequested)
        switch resolvedAuth {
        case .none:
            break
        case .bearer, .auto:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .xApiKey:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        case .xGoogApiKey:
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        case .queryKey:
            break
        }
        guard resolvedAuth != .none else { return }
        let resolvedTransport = transport ?? relayRequested?.transport ?? .auto
        let codexHeaders = RelayRuntimeSupport.codexIdentityHeaders(
            for: resolvedTransport,
            codexCompatIdentity: relayRequested?.effectiveCodexCompatIdentity
        )
        for (name, value) in codexHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let ua = relayRequested?.effectiveCustomUserAgent?.trimmingCharacters(in: .whitespacesAndNewlines),
           !ua.isEmpty {
            request.setValue(ua, forHTTPHeaderField: "User-Agent")
        }
    }

    func validateRelayAPIKeyIfRequired(_ apiKey: String, relayRequested: RelayRequestedConfig?) throws {
        guard RelayCredentialPolicy.requiresCredential(relayRequested) else { return }
        try validateAPIKey(apiKey)
    }

    private func requireConfiguredRelayBaseURL(
        apiKey: String,
        baseURL: String,
        relayRequested: RelayRequestedConfig?
    ) throws -> String {
        let requiresCredential = RelayCredentialPolicy.requiresCredential(relayRequested)
        return try RelayEndpointPolicy.requireConfigured(
            baseURL,
            securityMode: relayRequested?.securityMode ?? .remoteHTTPS,
            credentials: RelayEndpointPolicy.Credentials(
                authMode: relayRequested?.authMode,
                hasKey: requiresCredential && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        )
    }

    private func resolveRelayOpenAIAuthMode(_ relayRequested: RelayRequestedConfig?) -> RelayAuthMode {
        guard let relayRequested else { return .bearer }
        if relayRequested.authMode != .auto {
            return relayRequested.authMode
        }
        return relayAuthModeFromRuntime(
            MetadataClient.shared.syncRelayRuntimeConfig()
                .transportRules[relayEnvelopeKey(for: relayRequested.transport ?? .openaiChatCompletions)]?
                .defaultAuthMode
        ) ?? .bearer
    }

    private func resolveRelayAnthropicAuthMode(_ relayRequested: RelayRequestedConfig?) -> RelayAuthMode {
        if let relayRequested, relayRequested.authMode != .auto {
            return relayRequested.authMode
        }
        return relayAuthModeFromRuntime(
            MetadataClient.shared.syncRelayRuntimeConfig()
                .transportRules[MetadataClient.RelayTransportKey.anthropicMessages]?
                .defaultAuthMode
        ) ?? .xApiKey
    }

    private func resolveRelayGeminiAuthMode(_ relayRequested: RelayRequestedConfig?) -> RelayAuthMode {
        if let relayRequested, relayRequested.authMode != .auto {
            return relayRequested.authMode
        }
        return relayAuthModeFromRuntime(
            MetadataClient.shared.syncRelayRuntimeConfig()
                .transportRules[MetadataClient.RelayTransportKey.geminiGenerateContent]?
                .defaultAuthMode
        ) ?? .xGoogApiKey
    }

    private func relayEnvelopeKey(for transport: RelayTransport) -> String {
        switch transport {
        case .openaiResponses: return MetadataClient.RelayTransportKey.openaiResponses
        case .openaiChatCompletions, .auto: return MetadataClient.RelayTransportKey.openaiChatCompletions
        case .llamacppNative: return MetadataClient.RelayTransportKey.openaiChatCompletions
        case .anthropicMessages: return MetadataClient.RelayTransportKey.anthropicMessages
        case .geminiGenerateContent: return MetadataClient.RelayTransportKey.geminiGenerateContent
        }
    }

    private func relayAuthModeFromRuntime(_ raw: String?) -> RelayAuthMode? {
        switch raw {
        case "bearer": return .bearer
        case "x_api_key": return .xApiKey
        case "x_goog_api_key": return .xGoogApiKey
        case "query_key": return .queryKey
        default: return nil
        }
    }

    private func relayWebSearchToolNameFromRuntime(_ raw: String?) -> RelayWebSearchToolName? {
        switch raw {
        case "web_search": return .webSearch
        case "web_search_preview": return .webSearchPreview
        case "disabled": return .disabled
        default: return nil
        }
    }

    private func buildRelayEndpointURL(
        baseURL rawBaseURL: String,
        defaultVersion: String,
        acceptedVersions: Set<String>,
        endpointPath: String,
        relayRequested: RelayRequestedConfig?,
        apiKey: String,
        authMode: RelayAuthMode
    ) throws -> URL {
        let apiBaseURL = try RelayEndpointResolver.runtimeAPIBaseURL(
            rawBaseURL: rawBaseURL,
            relayRequested: relayRequested,
            defaultVersion: defaultVersion,
            acceptedVersions: acceptedVersions
        )
        let endpointURL = try RelayEndpointResolver.endpointURL(
            apiBaseURL: apiBaseURL,
            endpointPath: endpointPath,
            securityMode: relayRequested?.securityMode ?? .remoteHTTPS
        )
        guard var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false) else {
            throw ProviderServiceError.invalidConfiguration(detail: "Invalid base URL: \(rawBaseURL)")
        }
        var queryItems = components.queryItems ?? []
        if authMode == .queryKey {
            queryItems.append(URLQueryItem(name: "key", value: apiKey))
        }
        if authMode != .none {
            queryItems.append(contentsOf: relayRequested?.effectiveQueryParams?.map { URLQueryItem(name: $0.key, value: $0.value) } ?? [])
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = components.url else {
            throw ProviderServiceError.invalidConfiguration(detail: "Invalid base URL: \(rawBaseURL)")
        }
        return url
    }

    private struct ResponsesStreamPumpResult {
        var accumulatedText: String
        var lastUsage: ResponsesUsage?
        var firstContentEmitted: Bool
    }

    private func streamRelayResponses(
        initialReasoningEffort: String?,
        webSearchShape: MetadataClient.StreamShape?,
        requestBuilder: @escaping (RelayRetryHints) throws -> URLRequest
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let firstResult = try await self.pumpRelayResponsesStream(
                        initialReasoningEffort: initialReasoningEffort,
                        hints: RelayRetryHints(),
                        webSearchShape: webSearchShape,
                        requestBuilder: requestBuilder,
                        continuation: continuation
                    )

                    let breakdown = Self.parseResponsesUsage(firstResult.lastUsage)
                    continuation.yield(.done(ProviderChatResult(
                        text: firstResult.accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines),
                        promptTokens: breakdown.totalInputTokens,
                        completionTokens: breakdown.completionTokens,
                        estimatedCost: 0,
                        usageBreakdown: breakdown,
                        costSource: nil
                    )))
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

    /// Stream errors always surface. forbids turning a first-event failure into an automatic
    /// retry without a tool/setting.
    private func pumpRelayResponsesStream(
        initialReasoningEffort: String?,
        hints: RelayRetryHints,
        webSearchShape: MetadataClient.StreamShape?,
        requestBuilder: @escaping (RelayRetryHints) throws -> URLRequest,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws -> ResponsesStreamPumpResult {
        let bytes: URLSession.AsyncBytes
        let pair = try await self.executeRelayResponsesStreamRequestWithFallbacks(
            initialReasoningEffort: initialReasoningEffort,
            requestBuilder: { _ in try requestBuilder(hints) }
        )
        bytes = pair.0

        var result = ResponsesStreamPumpResult(
            accumulatedText: "",
            lastUsage: nil,
            firstContentEmitted: false
        )
        var currentEvent = ""
        var emittedImages = Set<String>()
        let respStrategy = TransportRegistry.strategy(for: .openaiResponses)
        var respCtx = StreamContext()
        var respLastCitationsCount = 0

        for try await line in bytes.utf8Lines {
            if Task.isCancelled { break }

            if line.hasPrefix("event: ") {
                currentEvent = String(line.dropFirst(7))
                continue
            }

            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" { break }
            guard let jsonData = payload.data(using: .utf8) else { continue }

            if !currentEvent.isEmpty {
                let injected = self.injectResponsesEventType(payload: payload, type: currentEvent)
                for ev in respStrategy.parseStreamLine(injected, ctx: &respCtx, shape: webSearchShape) {
                    switch ev {
                    case .reasoning, .toolCallDeltas: continuation.yield(ev)
                    default: break
                    }
                }
                let snapshot = respCtx.citationsAccumulator.citations
                if snapshot.count > respLastCitationsCount {
                    respLastCitationsCount = snapshot.count
                    continuation.yield(.citations(snapshot))
                }
            }

            switch currentEvent {
            case "response.output_text.delta":
                if let delta = try? self.decoder.decode(ResponsesStreamDelta.self, from: jsonData),
                   let text = delta.delta, !text.isEmpty {
                    result.accumulatedText += text
                    result.firstContentEmitted = true
                    continuation.yield(.delta(text))
                }
            case "response.output_image.done",
                 "response.image_generation_call.completed",
                 "response.output_item.done":
                if let imageEvent = try? self.decoder.decode(ResponsesStreamImageDone.self, from: jsonData),
                   let base64 = imageEvent.resolvedResult,
                   emittedImages.insert(imageEvent.resolvedIdentity ?? base64).inserted {
                    #if DEBUG
                    AppLog.info(
                        "Relay image event \(currentEvent), base64 payload \(base64.count) characters",
                        module: "ImageGen"
                    )
                    #endif
                    result.firstContentEmitted = true
                    continuation.yield(.imagePart(Attachment(
                        id: UUID(),
                        kind: .image,
                        fileName: "generated_image.png",
                        mimeType: "image/png",
                        base64Data: base64
                    )))
                }
            case "response.completed":
                if let completed = try? self.decoder.decode(ResponsesStreamCompleted.self, from: jsonData) {
                    result.lastUsage = completed.resolvedUsage
                }
            case "error", "response.failed":
                let parsed = try? self.decoder.decode(ResponsesStreamErrorEnvelope.self, from: jsonData)
                let code = parsed?.error?.code ?? parsed?.response?.error?.code
                let message = parsed?.error?.message
                    ?? parsed?.response?.error?.message
                    ?? L10n.tr("The provider returned an error for this request. Please retry or switch models.", table: .providers)
                let param = parsed?.error?.param ?? parsed?.response?.error?.param
                #if DEBUG
                AppLog.warning(
                    "Relay stream error on \(currentEvent): code=\(code ?? "none") message=\(message.prefix(200))",
                    module: "Relay"
                )
                #endif

                _ = param
                throw Self.mapRelayStreamError(code: code, message: message)
            default:
                break
            }

            currentEvent = ""
        }
        for ev in OpenAIResponsesStrategy.flushToolCalls(ctx: &respCtx) { continuation.yield(ev) }
        return result
    }

    private func streamRelayChatCompletions(
        initialReasoningEffort: String?,
        webSearchShape: MetadataClient.StreamShape?,
        requestBuilder: @escaping (String?) throws -> URLRequest
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, _) = try await self.executeRelayStreamRequestWithXHighRetry(
                        initialReasoningEffort: initialReasoningEffort,
                        requestBuilder: requestBuilder
                    )

                    var accumulatedText = ""
                    var lastUsage: OpenAIUsage?
                    let chatStrategy = TransportRegistry.strategy(for: .openaiChat)
                    var chatCtx = StreamContext()
                    var chatLastCitationsCount = 0
                    defer {
                        for ev in OpenAIChatStrategy.flushToolCalls(ctx: &chatCtx) { continuation.yield(ev) }
                    }

                    for try await line in bytes.utf8Lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" { break }
                        guard let chunkData = payload.data(using: .utf8) else { continue }
                        let chunk: OpenAIStreamChunk
                        do {
                            chunk = try self.decoder.decode(OpenAIStreamChunk.self, from: chunkData)
                        } catch {
                            continue
                        }
                        if let usage = chunk.usage { lastUsage = usage }
                        if let delta = chunk.choices?.first?.delta,
                           let content = delta.content?.text, !content.isEmpty {
                            accumulatedText += content
                            continuation.yield(.delta(content))
                        }

                        for ev in chatStrategy.parseStreamLine(payload, ctx: &chatCtx, shape: webSearchShape) {
                            switch ev {
                            case let .reasoning(text): continuation.yield(.reasoning(text))
                            case .toolCallDeltas: continuation.yield(ev)
                            default: break
                            }
                        }
                        let snapshot = chatCtx.citationsAccumulator.citations
                        if snapshot.count > chatLastCitationsCount {
                            chatLastCitationsCount = snapshot.count
                            continuation.yield(.citations(snapshot))
                        }
                    }
                    for ev in OpenAIChatStrategy.flushToolCalls(ctx: &chatCtx) {
                        continuation.yield(ev)
                    }

                    let relayBreakdown = Self.parseUsage(lastUsage)
                    continuation.yield(
                        .done(
                            ProviderChatResult(
                                text: accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines),
                                promptTokens: relayBreakdown.totalInputTokens,
                                completionTokens: relayBreakdown.completionTokens,
                                estimatedCost: 0,
                                usageBreakdown: relayBreakdown,
                                costSource: nil
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

    private func resolveRelayResponsesReasoningEffort(
        relayRequested: RelayRequestedConfig?,
        reasoningMode: ReasoningMode
    ) -> String? {
        relayRequested?.reasoningEffort
            .flatMap { $0 == .automatic ? nil : $0.rawValue }
            ?? Self.relayOpenAIReasoningEffort(reasoningMode)
    }

    private func resolveRelayChatCompletionsReasoningEffort(
        relayRequested: RelayRequestedConfig?,
        reasoningMode: ReasoningMode
    ) -> String? {
        if let explicit = relayRequested?.reasoningEffort, explicit != .automatic {
            return explicit.rawValue
        }
        return Self.relayOpenAIReasoningEffort(reasoningMode)
    }

    private static func relayOpenAIReasoningEffort(_ mode: ReasoningMode) -> String? {
        switch mode {
        case .automatic: return nil
        case .fast: return "low"
        case .balanced: return "medium"
        case .deep: return "high"
        case .max: return "xhigh"
        }
    }

    private static func relaySemanticReasoningMode(
        _ effort: RelayReasoningEffort?,
        fallback: ReasoningMode
    ) -> ReasoningMode {
        switch effort {
        case .low: return .fast
        case .medium: return .balanced
        case .high: return .deep
        case .xhigh: return .max
        case .automatic, nil: return fallback
        }
    }

    private func performRelayDataRequestWithXHighRetry(
        initialReasoningEffort: String?,
        requestBuilder: (String?) throws -> URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        _ = initialReasoningEffort
        do {
            return try await performRelayRawRequest(
                requestBuilder(nil), effectiveTransport: .openaiChatCompletions
            )
        } catch let error as RelayHTTPStatusError {
            throw mapHTTPError(statusCode: error.statusCode, data: error.data, isRelay: true)
        }
    }

    private func performRelayResponsesDataRequestWithFallbacks(
        initialReasoningEffort: String?,
        requestBuilder: (RelayRetryHints) throws -> URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        _ = initialReasoningEffort
        let firstHints = RelayRetryHints()
        do {
            return try await performRelayRawRequest(
                try requestBuilder(firstHints), effectiveTransport: .openaiResponses
            )
        } catch let error as RelayHTTPStatusError {
            throw mapHTTPError(statusCode: error.statusCode, data: error.data, isRelay: true)
        }
    }

    private func executeRelayStreamRequestWithXHighRetry(
        initialReasoningEffort: String?,
        requestBuilder: (String?) throws -> URLRequest
    ) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        _ = initialReasoningEffort
        do {
            return try await executeRelayStreamRequest(
                requestBuilder(nil), effectiveTransport: .openaiChatCompletions
            )
        } catch let error as RelayHTTPStatusError {
            throw mapHTTPError(statusCode: error.statusCode, data: error.data, isRelay: true)
        }
    }

    private func executeRelayResponsesStreamRequestWithFallbacks(
        initialReasoningEffort: String?,
        requestBuilder: (RelayRetryHints) throws -> URLRequest
    ) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        _ = initialReasoningEffort
        let firstHints = RelayRetryHints()
        do {
            return try await executeRelayStreamRequest(
                try requestBuilder(firstHints), effectiveTransport: .openaiResponses
            )
        } catch let error as RelayHTTPStatusError {
            throw mapHTTPError(statusCode: error.statusCode, data: error.data, isRelay: true)
        }
    }

    private struct RelayHTTPStatusError: Error {
        let statusCode: Int
        let data: Data
    }

    private func performRelayRawRequest(
        _ request: URLRequest,
        effectiveTransport: RelayTransport
    ) async throws -> (Data, HTTPURLResponse) {
        let result = try await performRelayRequestWithUnsupportedParamSelfHeal(
            request, streaming: false, effectiveTransport: effectiveTransport
        )
        return try result.dataResult
    }

    private func executeRelayStreamRequest(
        _ request: URLRequest,
        effectiveTransport: RelayTransport
    ) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        let result = try await performRelayRequestWithUnsupportedParamSelfHeal(
            request, streaming: true, effectiveTransport: effectiveTransport
        )
        return try result.streamResult
    }

    private struct RelaySelfHealResult {
        var data: Data?
        var bytes: URLSession.AsyncBytes?
        var response: HTTPURLResponse

        var dataResult: (Data, HTTPURLResponse) {
            get throws {
                guard let data else { throw ProviderServiceError.network(detail: "Missing relay response data.") }
                return (data, response)
            }
        }

        var streamResult: (URLSession.AsyncBytes, HTTPURLResponse) {
            get throws {
                guard let bytes else { throw ProviderServiceError.network(detail: "Missing relay response stream.") }
                return (bytes, response)
            }
        }
    }

    /// Compatibility-named Relay executor. It sends the production body exactly once; never
    /// pre-strips or retries after a 400.
    private func performRelayRequestWithUnsupportedParamSelfHeal(
        _ originalRequest: URLRequest,
        streaming: Bool,
        effectiveTransport: RelayTransport
    ) async throws -> RelaySelfHealResult {
        let scope = relaySelfHealScope(for: originalRequest)
        if streaming {
            do {
                CapabilityExecutionRuntime.confirmRequestDispatched()
                let (bytes, response) = try await session.relayBytes(for: originalRequest)
                guard let http = response as? HTTPURLResponse else {
                    throw ProviderServiceError.network(detail: "Missing HTTPURLResponse.")
                }
                guard (200 ..< 300).contains(http.statusCode) else {
                    var errorData = Data()
                    for try await byte in bytes { errorData.append(byte) }
                    let mapped = mapHTTPError(
                        statusCode: http.statusCode, data: errorData,
                        url: originalRequest.url, request: originalRequest, isRelay: true
                    )
                    recordCapabilityUpstreamRejection(
                        mappedError: mapped, errorData: errorData,
                        providerKind: .relay, modelID: scope.modelID,
                        request: originalRequest, effectiveTransport: effectiveTransport.rawValue,
                        relayEngineProfile: nil, relayDeclaredProfile: nil
                    )
                    throw RelayHTTPStatusError(statusCode: http.statusCode, data: errorData)
                }
                return RelaySelfHealResult(bytes: bytes, response: http)
            } catch let error as ProviderServiceError {
                throw error
            } catch let error as RelayHTTPStatusError {
                throw error
            } catch {
                throw ProviderServiceError.network(detail: error.localizedDescription)
            }
        }
        do {
            CapabilityExecutionRuntime.confirmRequestDispatched()
            let (data, response) = try await session.relayData(for: originalRequest)
            guard let http = response as? HTTPURLResponse else {
                throw ProviderServiceError.network(detail: "Missing HTTPURLResponse.")
            }
            guard (200 ..< 300).contains(http.statusCode) else {
                let mapped = mapHTTPError(
                    statusCode: http.statusCode, data: data,
                    url: originalRequest.url, request: originalRequest, isRelay: true
                )
                recordCapabilityUpstreamRejection(
                    mappedError: mapped, errorData: data,
                    providerKind: .relay, modelID: scope.modelID,
                    request: originalRequest, effectiveTransport: effectiveTransport.rawValue,
                    relayEngineProfile: nil, relayDeclaredProfile: nil
                )
                throw RelayHTTPStatusError(statusCode: http.statusCode, data: data)
            }
            return RelaySelfHealResult(data: data, response: http)
        } catch let error as ProviderServiceError {
            throw error
        } catch let error as RelayHTTPStatusError {
            throw error
        } catch {
            throw ProviderServiceError.network(detail: error.localizedDescription)
        }
    }

    private struct RelaySelfHealScope {
        let modelID: String
    }

    private func relaySelfHealScope(for request: URLRequest) -> RelaySelfHealScope {
        let modelID: String = {
            guard let body = request.httpBody,
                  let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let model = object["model"] as? String,
                  !model.isEmpty else { return "llamacpp_native" }
            return model
        }()
        return RelaySelfHealScope(modelID: modelID)
    }

    private func isResponsesNotSupported(_ statusCode: Int, data: Data) -> Bool {
        statusCode == 404
    }

    static func mapRelayStreamError(code: String?, message: String) -> ProviderServiceError {
        let lower = (code ?? "").lowercased()
        if lower == "moderation_blocked" || message.localizedCaseInsensitiveContains("safety system") {
            return .upstream(
                statusCode: 200,
                detail: L10n.tr("Your prompt was blocked by the upstream safety system (often triggered by copyrighted characters, real people, or sensitive content). Please rephrase the prompt with original descriptions and try again.", table: .providers)
            )
        }
        if lower.contains("image_generation") {
            return .upstream(
                statusCode: 200,
                detail: L10n.tr("The image generation tool failed on the upstream. Please rephrase your prompt or try a different image model ID.", table: .providers)
            )
        }
        return .upstream(statusCode: 200, detail: message)
    }

    func sendMessageViaImagesAPIForRelay(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        baseURL: String,
        relayRequested: RelayRequestedConfig?
    ) async throws -> ProviderChatResult {
        try validateAPIKey(apiKey)
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderServiceError.invalidConfiguration(detail: "Missing model identifier.")
        }
        return try await performImagesGeneration(
            apiKey: apiKey,
            modelID: modelID,
            messages: messages,
            baseURL: baseURL,
            relayRequested: relayRequested,
            costProviderKind: nil
        )
    }

    private func performImagesGeneration(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        baseURL: String?,
        relayRequested: RelayRequestedConfig?,
        costProviderKind: ProviderKind?
    ) async throws -> ProviderChatResult {
        let request = try buildImagesGenerationRequest(
            modelID: modelID,
            messages: messages,
            apiKey: apiKey,
            baseURL: baseURL,
            relayRequested: relayRequested
        )
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.relayData(for: request)
        } catch {
            throw ProviderServiceError.network(detail: error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderServiceError.network(detail: "Missing HTTPURLResponse.")
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw mapHTTPError(statusCode: httpResponse.statusCode, data: data, url: request.url, isRelay: true)
        }

        let imagesResult: ImagesGenerationResponse
        do {
            imagesResult = try decoder.decode(ImagesGenerationResponse.self, from: data)
        } catch {
            throw ProviderServiceError.network(detail: "Decoding failed: \(error.localizedDescription)")
        }

        let attachments = imagesResult.resolvedAttachments
        guard !attachments.isEmpty else {
            throw ProviderServiceError.emptyResponse
        }

        let breakdown = Self.parseResponsesUsage(imagesResult.usage)
        let (cost, source): (Double, CostSource?) = await {
            guard let costProviderKind else { return (0, nil) }
            let result = await MetadataClient.shared.calcCost(
                breakdown: breakdown, modelID: modelID, providerKind: costProviderKind
            )
            return (result.cost, result.source)
        }()
        return ProviderChatResult(
            text: "",
            promptTokens: breakdown.totalInputTokens,
            completionTokens: breakdown.completionTokens,
            estimatedCost: cost,
            attachments: attachments,
            usageBreakdown: breakdown,
            costSource: source
        )
    }


    private func resolveCostProviderKind(modelID: String) -> ProviderKind {
        if let matched = MetadataClient.shared.syncResolveCatalogModelAcrossProvidersWithProvider(
            modelID: modelID,
            transportPriority: .openAI
        ) {
            return matched.matchedProviderKind
        }
        return .openAI
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
            providerKind: resolveCostProviderKind(modelID: modelID)
        )?.profiles.webSearch
        return MetadataClient.shared.syncWebSearchStreamShape(profileName: fallback)
    }


    fileprivate func injectResponsesEventType(payload: String, type: String) -> String {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              var dict = object as? [String: Any] else {
            return payload
        }
        if dict["type"] == nil {
            dict["type"] = type
        }
        guard let merged = try? JSONSerialization.data(withJSONObject: dict),
              let mergedString = String(data: merged, encoding: .utf8) else {
            return payload
        }
        return mergedString
    }


    private static let knownTextModelIDs = [
        "gpt-4o",
        "gpt-4-turbo",
        "gpt-4",
    ]

    private static let excludedPrefixes = [
        "dall-e", "whisper", "tts", "text-embedding",
        "babbage", "davinci", "moderation",
        "omni-moderation", "codex"
    ]

    private func isChatModel(_ id: String) -> Bool {
        let lowered = id.lowercased()
        for prefix in Self.excludedPrefixes {
            // heuristic-allow: Relay/custom OpenAI-compatible catalog filter only; official OpenAI catalog uses metadata.
            if lowered.hasPrefix(prefix) { return false }
        }
        return true
    }

    private static func isDedicatedImageModel(_ modelID: String) -> Bool {
        RelayRuntimeSupport.isDedicatedImageModel(modelID)
    }

    private static func latestUserPrompt(in messages: [ChatMessage]) -> String? {
        guard let prompt = messages.reversed()
            .first(where: { $0.role == .user })?
            .text
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty else {
            return nil
        }
        return prompt
    }

    private static func metadataBackedRemoteModels(modelIDs: [String]) -> [OpenAIMetadataModel] {
        let sourceModelIDs = modelIDs.isEmpty ? knownTextModelIDs : modelIDs
        return sourceModelIDs.map { OpenAIMetadataModel(id: $0) }
    }

    private func buildModels(from remoteModels: [OpenAIMetadataModel], preferredModelID: String?) async -> [AIModel] {
        let normalizedPreferredID = preferredModelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        var models: [AIModel] = []
        models.reserveCapacity(remoteModels.count)

        for remote in remoteModels {
            var model = await CatalogModelBuilder.buildCatalogModel(
                providerKind: .openAI,
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

    private func buildModels(from remoteModels: [OpenAIRemoteModel], preferredModelID: String?) async -> [AIModel] {
        let normalizedPreferredID = preferredModelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        var models: [AIModel] = []
        models.reserveCapacity(remoteModels.count)

        for remote in remoteModels {
            var model = await CatalogModelBuilder.buildCatalogModel(
                providerKind: .openAI,
                runtimeModelId: remote.id,
                fallbackName: remote.id,
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


private struct OpenAIMetadataModel {
    var id: String
}


private struct OpenAIModelsResponse: Decodable {
    var data: [OpenAIRemoteModel]
}

private struct OpenAIRemoteModel: Decodable {
    var id: String
    var created: TimeInterval?
    var owned_by: String?
}

private struct ChatCompletionRequest: Encodable {
    var model: String
    var stream: Bool?
    var stream_options: StreamOptions?
    var reasoning_effort: String?
    var service_tier: String?
    var max_tokens: Int?
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

        struct ImageURL: Encodable {
            var url: String
            var detail: String?
        }
    }

    struct StreamOptions: Encodable {
        var include_usage: Bool = true
    }
}

private struct ChatCompletionResponse: Decodable {
    var choices: [Choice]
    var usage: OpenAIUsage?

    struct Choice: Decodable {
        var message: Message

        struct Message: Decodable {
            var content: OpenAIChatMessageContent
            var tool_calls: [ChatCompletionToolCall]?

            private enum CodingKeys: String, CodingKey { case content, tool_calls }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                content = try container.decodeIfPresent(OpenAIChatMessageContent.self, forKey: .content)
                    ?? .string("")
                tool_calls = try container.decodeIfPresent([ChatCompletionToolCall].self, forKey: .tool_calls)
            }
        }
    }
}

struct ChatCompletionToolCall: Decodable {
    struct Function: Decodable {
        var name: String?
        var arguments: String?
    }

    var id: String?
    var type: String?
    var function: Function?
}

private struct OpenAIStreamChunk: Decodable {
    var choices: [StreamChoice]?
    var usage: OpenAIUsage?
}

private struct StreamChoice: Decodable {
    var delta: StreamDelta?
}

private struct StreamDelta: Decodable {
    var content: OpenAIChatMessageContent?
}

private struct OpenAIUsage: Decodable {
    var prompt_tokens: Int?
    var completion_tokens: Int?
    var total_tokens: Int?
    var prompt_tokens_details: PromptTokensDetails?
    var completion_tokens_details: CompletionTokensDetails?

    struct PromptTokensDetails: Decodable {
        var cached_tokens: Int?

        init(cached_tokens: Int? = nil) {
            self.cached_tokens = cached_tokens
        }
    }

    struct CompletionTokensDetails: Decodable {
        var reasoning_tokens: Int?

        init(reasoning_tokens: Int? = nil) {
            self.reasoning_tokens = reasoning_tokens
        }
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


private struct ResponsesRequest: Encodable {
    var model: String
    var input: [InputMessage]
    var instructions: String?
    var stream: Bool?
    var reasoning: Reasoning?
    var tools: [Tool]?
    var service_tier: String?
    var store: Bool?
    var max_output_tokens: Int?

    struct Tool: Encodable {
        var type: String
        var model: String? = nil
    }

    struct Reasoning: Encodable {
        var effort: String?
        var summary: String?
    }

    struct InputMessage: Encodable {
        var role: String
        var content: InputContent
    }

    enum InputContent: Encodable {
        case parts([ContentPart])

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .parts(let p): try container.encode(p)
            }
        }
    }

    struct ContentPart: Encodable {
        var type: String
        var text: String?
        var image_url: String?
        var detail: String?
        var filename: String?
        var file_data: String?
    }
}

private struct ResponsesResponse: Decodable {
    var id: String?
    var output_text: String?
    var output: [OutputItem]?
    var usage: ResponsesUsage?

    struct OutputItem: Decodable {
        var type: String?
        var content: [ContentPart]?
        var result: String?
    }

    struct ContentPart: Decodable {
        var type: String?
        var text: String?
        var result: String?
    }

    var resolvedText: String {
        if let text = output_text, !text.isEmpty { return text }
        return output?
            .flatMap { $0.content ?? [] }
            .compactMap { $0.type == "output_text" ? $0.text : nil }
            .joined() ?? ""
    }

    var resolvedAttachments: [Attachment] {
        guard let output else { return [] }
        var attachments: [Attachment] = []

        for item in output {
            if item.type == "image_generation_call", let base64 = item.result {
                attachments.append(Attachment(
                    id: UUID(),
                    kind: .image,
                    fileName: "generated_image.png",
                    mimeType: "image/png",
                    base64Data: base64
                ))
            }

            for part in item.content ?? [] {
                if part.type == "output_image", let base64 = part.result {
                    attachments.append(Attachment(
                        id: UUID(),
                        kind: .image,
                        fileName: "generated_image.png",
                        mimeType: "image/png",
                        base64Data: base64
                    ))
                }
            }
        }

        return attachments
    }
}

private struct ResponsesUsage: Decodable {
    var input_tokens: Int?
    var output_tokens: Int?
    var input_tokens_details: InputTokensDetails?
    var output_tokens_details: OutputTokensDetails?

    struct InputTokensDetails: Decodable {
        var cached_tokens: Int?
    }

    struct OutputTokensDetails: Decodable {
        var reasoning_tokens: Int?
    }
}

private struct ResponsesStreamDelta: Decodable {
    var delta: String?
}

private struct ResponsesStreamCompleted: Decodable {
    var usage: ResponsesUsage?
    var response: CompletedResponse?

    var resolvedUsage: ResponsesUsage? {
        usage ?? response?.usage
    }

    var resolvedID: String? { response?.id }

    struct CompletedResponse: Decodable {
        var id: String?
        var usage: ResponsesUsage?
    }
}

private struct ResponsesStreamErrorEnvelope: Decodable {
    var error: ErrorPayload?
    var response: ResponseWrapper?

    struct ErrorPayload: Decodable {
        var code: String?
        var message: String?
        var type: String?
        var param: String?
    }

    struct ResponseWrapper: Decodable {
        var error: ErrorPayload?
    }
}

private struct ResponsesStreamImageDone: Decodable {
    var result: String?
    var item_id: String?
    var item: Item?

    var resolvedResult: String? {
        result ??
            item?.result ??
            item?.content?.first(where: { $0.type == "output_image" })?.result
    }

    var resolvedIdentity: String? {
        item_id ?? item?.id
    }

    struct Item: Decodable {
        var id: String?
        var type: String?
        var result: String?
        var content: [ResponsesResponse.ContentPart]?
    }
}

private struct ImagesGenerationRequest: Encodable {
    var model: String
    var prompt: String
    var n: Int
    var size: String
    var response_format: String?
}

private struct ImagesGenerationResponse: Decodable {
    struct ImageData: Decodable {
        var b64_json: String?
        var url: String?
    }

    var data: [ImageData]
    var usage: ResponsesUsage?

    var resolvedAttachments: [Attachment] {
        data.compactMap { item in
            let payload = item.b64_json ?? item.url
            guard let payload, !payload.isEmpty else { return nil }
            return Attachment(
                id: UUID(),
                kind: .image,
                fileName: "generated_image.png",
                mimeType: "image/png",
                base64Data: payload
            )
        }
    }
}

extension OpenAIService {
    fileprivate static func parseUsage(_ usage: OpenAIUsage?) -> UsageBreakdown {
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
        var usage = OpenAIUsage(
            prompt_tokens: promptTokens,
            completion_tokens: completionTokens,
            total_tokens: nil,
            prompt_tokens_details: cachedTokens.map { OpenAIUsage.PromptTokensDetails(cached_tokens: $0) },
            completion_tokens_details: reasoningTokens.map { OpenAIUsage.CompletionTokensDetails(reasoning_tokens: $0) }
        )
        return parseUsage(usage)
    }
    #endif

    fileprivate static func parseResponsesUsage(_ usage: ResponsesUsage?) -> UsageBreakdown {
        guard let usage else { return UsageBreakdown() }
        let cached = usage.input_tokens_details?.cached_tokens ?? 0
        let total = usage.input_tokens ?? 0
        return UsageBreakdown(
            promptTokens: max(0, total - cached),
            cachedInputTokens: cached,
            cacheCreation5mTokens: 0,
            cacheCreation1hTokens: 0,
            completionTokens: usage.output_tokens ?? 0,
            reasoningTokens: usage.output_tokens_details?.reasoning_tokens ?? 0,
            upstreamCost: nil,
            cacheReadObserved: usage.input_tokens_details?.cached_tokens != nil
        )
    }
}
