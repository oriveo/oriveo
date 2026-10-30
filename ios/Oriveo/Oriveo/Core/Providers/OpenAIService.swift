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
                baseURL: RelayEndpointResolver.injectedAPIRoot(relayRequested) ?? baseURL,
                relayRequested: relayRequested
            )
        } else if relayRequested != nil {
            // Connection-level catalog GET (refresh / one request per key): the root address comes only from
            // catalogAPIRoot. Otherwise the user's stored address as typed could miss a /v1 or carry a terminal
            // path into /models. If no root can be derived, report the security error for the original address.
            normalizedBase = try RelayEndpointPolicy.requireSecure(
                RelayEndpointResolver.catalogAPIRoot(baseURL: baseURL, relayRequested: relayRequested) ?? baseURL
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
        let data = try await performData(request, isRelay: true)
        let remoteModels: [OpenAIRemoteModel]
        do {
            remoteModels = try Self.decodeRelayCatalog(data)
        } catch {
            throw ProviderServiceError.network(detail: "Decoding failed: \(error.localizedDescription)")
        }
        // A catalog refresh and "add" discovery parse the same raw body: each model's self-reported endpoint
        // types go into the probe candidate cache.
        if let catalog = RelayDiscoveryService.parseCatalog(data: data, transport: .openaiChatCompletions) {
            RelayCatalogEndpointTypesCache.shared.record(
                endpoint: baseURL,
                endpointTypesByModel: catalog.endpointTypesByModel
            )
        }
        let chatModels = remoteModels.filter { isChatModel($0.id) }
        let models = await buildModels(from: chatModels, preferredModelID: preferredModelID)

        return ProviderSyncResult(
            models: models
        )
    }

    /// Decodes a catalog refresh response. The OpenAI list, the new-api `success` wrapper and the Anthropic
    /// paginated shape all carry the models in a `data` array, and only that array is read, in upstream order.
    private static func decodeRelayCatalog(_ data: Data) throws -> [OpenAIRemoteModel] {
        try JSONDecoder().decode(OpenAIModelsResponse.self, from: data).data
    }

    static func relayCatalogModelIDs(from data: Data) throws -> [String] {
        try decodeRelayCatalog(data).map(\.id)
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

                    let transport = RelayEndpointResolver.injectedTransport(relayRequested) ?? .openaiChatCompletions
                    // The citation stream shape is derived from the web-search fragment merged in for this turn;
                    // without a fragment, citation parsing is skipped. Every branch other than Responses sends
                    // through the Chat Completions builder, so it takes the Chat part of the fragment.
                    let fragmentTransport: RelayTransport = transport == .openaiResponses
                        ? .openaiResponses : .openaiChatCompletions
                    let webSearchShape: MetadataClient.StreamShape?
                    if requestOptions.officialForeignRoute {
                        // The official cross-protocol route keeps the original behavior: with web search on,
                        // citations are parsed with the profile the catalog matched.
                        webSearchShape = webSearchEnabled ? self.officialForeignWebSearchShape(modelID: modelID) : nil
                    } else {
                        webSearchShape = MetadataClient.shared.syncWebSearchStreamShape(
                            profileName: RelayWebFragments.citationProfile(
                                transport: fragmentTransport,
                                fragment: requestOptions.relayWebFragments?.object(for: fragmentTransport)
                            )
                        )
                    }
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
                            webSearchShape: webSearchShape,
                            attachmentConnectionID: requestOptions.attachmentConnectionID,
                            attachmentModelID: requestOptions.capabilityEvidenceModel?.id,
                            attachmentFileOverride: requestOptions.capabilityEvidenceModel?.relayCapabilityOverrides?.file
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

        let transport = RelayEndpointResolver.injectedTransport(relayRequested) ?? .openaiChatCompletions
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
            // When a relay rejects a native file block, resend once with the files injected as text (NativeFileFallback).
            let (data, _) = try await NativeFileFallback.run(
                .relayScope(.openaiResponses, connectionID: requestOptions.attachmentConnectionID, modelID: requestOptions.capabilityEvidenceModel?.id, fileOverride: requestOptions.capabilityEvidenceModel?.relayCapabilityOverrides?.file)
            ) { try await performRelayResponsesDataRequestWithFallbacks { hints in
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
            } }

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
                usageReported: response.usage != nil,
                costSource: nil
            )

        case .openaiChatCompletions, .auto, .anthropicMessages, .geminiGenerateContent:
            let (data, _) = try await performRelayChatDataRequest { reasoningEffortOverride in
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
                usageReported: response.usage != nil,
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
            providerKind: resolveCostProviderKind(modelID: modelID, model: requestOptions.capabilityEvidenceModel),
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
        try await RecipeContinuationRuntime.save(
            messageID: requestOptions.localContinuationMessageID,
            recipe: continuationRecipe,
            state: responsesResult.id.map { ["previousResponseId": .string($0)] } ?? [:]
        )
        guard !text.isEmpty || !imageAttachments.isEmpty else {
            throw ProviderServiceError.emptyResponse
        }

        let breakdown = Self.parseResponsesUsage(responsesResult.usage)
        let providerKind = resolveCostProviderKind(modelID: modelID, model: requestOptions.capabilityEvidenceModel)
        let (cost, source) = await MetadataClient.shared.calcCost(
            breakdown: breakdown, modelID: modelID, providerKind: providerKind, at: Date()
        )
        return ProviderChatResult(
            text: text,
            promptTokens: breakdown.totalInputTokens,
            completionTokens: breakdown.completionTokens,
            estimatedCost: cost,
            attachments: imageAttachments.isEmpty ? nil : imageAttachments,
            usageBreakdown: breakdown,
            usageReported: responsesResult.usage != nil,
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
                        // When the subscription backend rejects a native file block before the first event, resend once with the files injected as text (NativeFileFallback).
                        bytes = try await NativeFileFallback.run(
                            .codexSubscriptionScope(connectionID: requestOptions.attachmentConnectionID)
                        ) {
                            let request = try self.buildCodexSubscriptionResponsesRequest(
                                modelID: modelID,
                                messages: messages,
                                apiKey: apiKey,
                                subscription: subscription,
                                reasoningMode: reasoningMode,
                                webSearchEnabled: webSearchEnabled,
                                requestOptions: requestOptions
                            )
                            return try await self.codexSubscriptionResponsesBytes(request: request)
                        }
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
                                providerKind: self.resolveCostProviderKind(modelID: modelID, model: requestOptions.capabilityEvidenceModel),
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
                            providerKind: self.resolveCostProviderKind(modelID: modelID, model: requestOptions.capabilityEvidenceModel)
                        )?.profiles.webSearch
                    )
                    var responsesCtx = StreamContext()
                    var lastCitationsCount = 0
                    var finishTracker = StreamFinishTracker(family: .openaiResponses)

                    for try await line in bytes.utf8Lines {
                        if Task.isCancelled { break }

                        if line.hasPrefix("event: ") {
                            currentEvent = String(line.dropFirst(7))
                            continue
                        }

                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        guard let jsonData = payload.data(using: .utf8) else { continue }
                        // The Responses event name lives in the `event:` header and the data body may carry no
                        // `type`; inject it first so error / response.failed are recognized.
                        let framedData = currentEvent.isEmpty
                            ? jsonData
                            : (self.injectResponsesEventType(payload: payload, type: currentEvent).data(using: .utf8) ?? jsonData)
                        finishTracker.observeFrame(framedData, eventType: currentEvent.isEmpty ? nil : currentEvent)
                        // response.failed throws on the next line: hand out the finish first.
                        if finishTracker.finishRaw == "failed" { continuation.yield(.finish(finishTracker.finish())) }
                        try Self.throwIfStreamErrorFrame(framedData, beforeAnyContent: accumulatedText.isEmpty, redacting: [apiKey])

                        if !currentEvent.isEmpty {
                            let injected = self.injectResponsesEventType(payload: payload, type: currentEvent)
                            for ev in responsesStrategy.parseStreamLine(
                                injected,
                                ctx: &responsesCtx,
                                shape: responsesShape
                            ) {
                                switch ev {
                                case .reasoning, .toolCallDeltas, .activity: continuation.yield(ev)
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
                                // One unreadable frame must not abort a stream that is otherwise fine.
                                #if DEBUG
                                AppLog.error(error, module: "OpenAI", context: ["frame": "output_text.delta"])
                                #endif
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
                                #if DEBUG
                                AppLog.error(error, module: "OpenAI", context: ["frame": "output_image.done"])
                                #endif
                            }
                        case "response.completed", "response.incomplete":
                            // response.incomplete (e.g. max_output_tokens) still goes through done, and usage is taken the same way.
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
                                #if DEBUG
                                AppLog.error(error, module: "OpenAI", context: ["frame": "response.completed"])
                                #endif
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
                        try await RecipeContinuationRuntime.save(
                            messageID: requestOptions.localContinuationMessageID,
                            recipe: continuationRecipe,
                            state: completedResponseID.map { ["previousResponseId": .string($0)] } ?? [:]
                        )
                    }
                    let breakdown = Self.parseResponsesUsage(lastUsage)
                    let providerKind = self.resolveCostProviderKind(modelID: modelID, model: requestOptions.capabilityEvidenceModel)
                    let (cost, source): (Double, CostSource) = subscription != nil
                        ? (0, .subscription)
                        : await MetadataClient.shared.calcCost(
                            breakdown: breakdown, modelID: modelID, providerKind: providerKind, at: Date()
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

    private static func buildRequestMessage(_ msg: ChatMessage, transport: AttachmentTransport, model: AIModel?, isOutgoingTurn: Bool) throws -> ChatCompletionRequest.Message {
        let atts = msg.attachments ?? []
        let imageAtts = atts.filter { $0.kind == .image }

        let combinedText = try AttachmentDelivery.deliver(
            isOutgoingTurn: isOutgoingTurn,
            userText: msg.text,
            attachments: atts,
            transport: transport,
            model: model
        ).injectedText

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
            providerKind: resolveCostProviderKind(modelID: modelID, model: requestOptions.capabilityEvidenceModel),
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
        let (breakdown, usageReported) = Self.parseUsageSignal(response.usage)
        let providerKind = resolveCostProviderKind(modelID: modelID, model: requestOptions.capabilityEvidenceModel)
        let (cost, source) = await MetadataClient.shared.calcCost(
            breakdown: breakdown, modelID: modelID, providerKind: providerKind, at: Date()
        )
        return ProviderChatResult(
            text: text,
            promptTokens: breakdown.totalInputTokens,
            completionTokens: breakdown.completionTokens,
            estimatedCost: cost,
            usageBreakdown: breakdown,
            usageReported: usageReported,
            costSource: source,
            toolCalls: toolCalls.isEmpty ? nil : toolCalls
        )
    }

    static func nonStreamingToolCalls(_ raw: [ChatCompletionToolCall]?) -> [ProviderToolCall] {
        (raw ?? []).compactMap { call in
            guard let function = call.function else { return nil }
            return ProviderToolCall(
                providerCallID: call.id,
                // The request side does not encode function names, so they are not decoded here either: the `_fe` of `web_fetch` would be read as an escaped byte and corrupt the name.
                name: function.name ?? "",
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
            providerKind: resolveCostProviderKind(modelID: modelID, model: requestOptions.capabilityEvidenceModel),
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
                providerKind: resolveCostProviderKind(modelID: modelID, model: requestOptions.capabilityEvidenceModel)
            )?.profiles.webSearch
        )
        var chatCtx = StreamContext()
        var chatLastCitationsCount = 0
        defer {
            for ev in OpenAIChatStrategy.flushToolCalls(ctx: &chatCtx) { continuation.yield(ev) }
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
        let providerKind = resolveCostProviderKind(modelID: modelID, model: requestOptions.capabilityEvidenceModel)
        let (cost, source) = await MetadataClient.shared.calcCost(
            breakdown: breakdown, modelID: modelID, providerKind: providerKind, at: Date()
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
        let continuationDecision = continuationRecipe.map { recipe in
            RecipeContinuationRuntime.continuationDecision(
                explicitMessageID: requestOptions.localExplicitContinuationMessageID,
                statefulLegText: requestOptions.statefulLegText,
                instructionsMode: recipe.instructionsMode,
                fingerprintMatches: requestOptions.continuationFingerprintMatches
            )
        } ?? .fullPlan
        var previousResponseID: String?
        var sendInstructions = true
        if case let .stateful(id, resend) = continuationDecision {
            previousResponseID = id
            sendInstructions = resend
        }
        // `previous_response_id` owns the historical leg server-side. Re-sending it alongside
        // ChatRequestBuilder's partial assistant duplicates context and violates Responses wire.
        // A full plan keeps the whole input.
        let requestMessagesInput: [ChatMessage]
        if previousResponseID != nil,
           var continuationUser = messages.last(where: { $0.role == .user }) {
            if let legText = requestOptions.statefulLegText { continuationUser.text = legText }
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
        let systemPrompt = sendInstructions
            ? requestOptions.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let payload = ResponsesRequest(
            model: modelID,
            input: try AttachmentDelivery.mapTurns(capabilityIntent.outboundMessages, isChatSend: requestOptions.capabilityEvidenceModel != nil, dynamicText: requestOptions.dynamicText) { try Self.buildResponsesInputMessage($0, transport: .openAIResponses, model: requestOptions.capabilityEvidenceModel, isOutgoingTurn: $1) },
            instructions: systemPrompt.isEmpty ? nil : systemPrompt,
            stream: stream ? true : nil,
            reasoning: nil,
            tools: nil,
            service_tier: serviceTier,
            store: requestOptions.relayRequested?.disableResponseStorage == true ? false : nil,
            // The main chat path uses plan.budget.oWire; non-chat paths keep the catalog value.
            max_output_tokens: requestOptions.maxOutputTokens ?? resolved?.maxOutputTokens
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
        try ClientToolsInjector.apply(to: &body, protocol: .openaiResponses, options: requestOptions)
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
        try AdditionalRequestBody.apply(requestOptions.localAdditionalRequestBody, to: &body)
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

    private static func buildResponsesInputMessage(_ msg: ChatMessage, transport: AttachmentTransport, model: AIModel?, isOutgoingTurn: Bool) throws -> ResponsesRequest.InputMessage {
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

        // The transport's per-route switch decides which routes can split out native files; a route with it off always has an empty native set.
        let delivery = try AttachmentDelivery.deliver(
            isOutgoingTurn: isOutgoingTurn,
            userText: msg.text,
            attachments: fileAtts,
            transport: transport,
            model: model
        )
        let nativeAtts = delivery.native
        let combinedText = delivery.injectedText

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
        apiMessages.append(contentsOf: try AttachmentDelivery.mapTurns(capabilityIntent.outboundMessages, isChatSend: requestOptions.capabilityEvidenceModel != nil, dynamicText: requestOptions.dynamicText) { try Self.buildRequestMessage($0, transport: .openAIChat, model: requestOptions.capabilityEvidenceModel, isOutgoingTurn: $1) })
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
        try ClientToolsInjector.apply(to: &body, protocol: .openaiChat, options: requestOptions)
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
        try AdditionalRequestBody.apply(requestOptions.localAdditionalRequestBody, to: &body)
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
        // The native completion endpoint sits at the server root, so strip the chat `/v1` suffix if
        // the connection's API base carries it.
        let root = LlamaCppChannelMigration.nativeRoot(fromBase: baseURL)
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
            "prompt": try llamaCppPrompt(messages: messages, requestOptions: requestOptions),
            "stream": stream,
        ]
        if let nPredictOverride { body["n_predict"] = nPredictOverride }
        ProfileParamsResolver.applyGenerationParameters(
            to: &body,
            options: requestOptions,
            finalRequest: request,
            effectiveTransport: RelayTransport.llamacppNative.rawValue
        )
        try AdditionalRequestBody.apply(requestOptions.localAdditionalRequestBody, to: &body)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        CapabilityExecutionRuntime.confirmFinalWireEncoded()
        return request
    }

    /// File attachments are extracted to text blocks per the route's declaration and joined into their own row; if this turn does not fit it is stopped here like on every other route.
    private func llamaCppPrompt(messages: [ChatMessage], requestOptions: ChatRequestOptions) throws -> String {
        var lines: [String] = []
        let trimmedSystem = requestOptions.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSystem.isEmpty { lines.append("system: \(trimmedSystem)") }
        let turns = try AttachmentDelivery.mapTurns(
            messages, isChatSend: requestOptions.capabilityEvidenceModel != nil, dynamicText: requestOptions.dynamicText
        ) { message, isOutgoingTurn in
            (message.role, try AttachmentDelivery.deliver(
                isOutgoingTurn: isOutgoingTurn,
                userText: message.text,
                attachments: message.attachments ?? [],
                transport: .relayLlamaCppNative,
                model: requestOptions.capabilityEvidenceModel
            ).injectedText)
        }
        for (role, injectedText) in turns {
            let text = injectedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            lines.append("\(role.rawValue): \(text)")
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
            throw mapHTTPError(
                statusCode: error.statusCode, data: error.data, isRelay: true,
                relayTransport: error.effectiveTransport
            )
        }
        let text = try Self.llamaCppContent(from: data).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ProviderServiceError.emptyResponse }
        return ProviderChatResult(text: text, promptTokens: 0, completionTokens: 0, estimatedCost: 0, usageReported: false)
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
                    let (accumulated, finish) = try await Self.pumpLlamaCppNative(
                        lines: bytes.utf8Lines, apiKey: apiKey, continuation: continuation
                    )
                    continuation.yield(.done(ProviderChatResult(
                        text: accumulated.trimmingCharacters(in: .whitespacesAndNewlines),
                        promptTokens: 0, completionTokens: 0, estimatedCost: 0,
                        usageReported: false,
                        finish: finish
                    )))
                    continuation.finish()
                } catch let error as RelayHTTPStatusError {
                    continuation.finish(throwing: self.mapHTTPError(
                        statusCode: error.statusCode, data: error.data, isRelay: true,
                        relayTransport: error.effectiveTransport
                    ))
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
        let prompt = try llamaCppPrompt(messages: messages, requestOptions: requestOptions)
        let result = await LocalEngineRuntimeClient.preflight(
            endpoint: endpoint,
            engine: .llamacpp,
            prompt: prompt,
            contextLimit: nil,
            requested: relayRequested
        )
        if case .supported(_, _, true) = result { throw LocalEngineConnectionError.contextExceeded }
    }

    /// Read the native llama.cpp /completion stream line by line: the body is handed out as deltas, and the last frame (stop: true) records the finish
    /// (family llama_cpp, finishRaw = stop_type, older servers are converted from stopped_*); a cut without receiving stop: true = eof_without_marker.
    static func pumpLlamaCppNative<Lines: AsyncSequence>(
        lines: Lines, apiKey: String,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws -> (text: String, finish: StreamFinish) where Lines.Element == String {
        var accumulated = ""
        var finishTracker = StreamFinishTracker(family: .llamaCpp)
        for try await line in lines {
            if Task.isCancelled { break }
            let payload = line.hasPrefix("data: ") ? String(line.dropFirst(6)) : line
            guard !payload.isEmpty, payload != "[DONE]" else { continue }
            guard let data = payload.data(using: .utf8) else { continue }
            finishTracker.observeFrame(data)
            try throwIfStreamErrorFrame(data, beforeAnyContent: accumulated.isEmpty, redacting: [apiKey])
            let delta = try llamaCppContent(from: data)
            guard !delta.isEmpty else { continue }
            accumulated += delta
            continuation.yield(.delta(delta))
        }
        return (accumulated, finishTracker.finish())
    }

    private static func llamaCppContent(from data: Data) throws -> String {
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
        Self.officialTransport(modelID: modelID)
    }

    /// Which protocol a direct OpenAI model uses. Outbound dispatch and the pre-send attachment route resolution read the same function.
    static func officialTransport(modelID: String) -> TransportKind {
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

    /// Subscription web search follows the subscription-mode verdict: a placeholder subscription connection asks
    /// `subscriptionVerdict(web)`, and the web_search tool is attached only when it is `autoAvailable`.
    static func codexSubscriptionWebAvailable(model: AIModel) -> Bool {
        var link = Provider(
            id: UUID(), kind: .openAI, status: .connected, models: [], catalogModels: [],
            lastCheckedAt: nil, apiKey: "", apiKeyPreview: "", lastError: nil,
            baseURLText: nil, customName: nil, updatedAt: Date()
        )
        link.authMode = .subscription
        return CapabilityControlResolution.subscriptionVerdict(
            provider: link, model: model, capability: "web"
        ).state == .autoAvailable
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
        let supportsWeb = model.map { Self.codexSubscriptionWebAvailable(model: $0) } ?? false
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
            input: try AttachmentDelivery.mapTurns(messages, isChatSend: requestOptions.capabilityEvidenceModel != nil, dynamicText: requestOptions.dynamicText) { try Self.buildResponsesInputMessage($0, transport: .codexSubscription, model: requestOptions.capabilityEvidenceModel, isOutgoingTurn: $1) },
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
        try ClientToolsInjector.apply(to: &body, protocol: .openaiResponses, options: requestOptions)
        try AdditionalRequestBody.apply(requestOptions.localAdditionalRequestBody, to: &body)
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

    /// Chat Completions request for a custom base URL (relays).
    ///
    /// When `relayRequested` is set the cc-switch import contract applies:
    /// - `reasoningEffort` (the connection-level stored level) is void on read and is not sent; the level comes only from this turn's `reasoningMode`
    /// - `serviceTier` takes effect only for OpenAI-style transports (Chat Completions / Responses)
    /// - `headers` / `queryParams` are merged into the request headers / URL
    /// `functionTools`: the capability test's tool entries; when given, this tools array (already in this protocol's shape) is written into the body. Chat does not pass it, so chat output is unchanged.
    /// `omitReasoning`: for probes; `reasoning_effort` is not written. Chat does not pass it, so chat output is unchanged.
    func buildChatCompletionsRequest(
        modelID: String,
        messages: [ChatMessage],
        apiKey: String,
        stream: Bool,
        baseURL: String,
        reasoningMode: ReasoningMode,
        requestOptions: ChatRequestOptions = ChatRequestOptions(),
        relayRequested: RelayRequestedConfig? = nil,
        reasoningEffortOverride: String? = nil,
        validationMaxTokens: Int? = nil,
        functionTools: [Any]? = nil,
        keepImageAttachments: Bool = false,
        omitReasoning: Bool = false
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
        let capabilityIntent = CapabilityEvidenceProductionAdapter.finalChatIntent(
            messages: messages, request: request,
            effectiveTransport: RelayTransport.openaiChatCompletions.rawValue,
            model: requestOptions.capabilityEvidenceModel,
            requestedReasoningMode: reasoningMode,
            webSearchEnabled: false,
            keepImageAttachments: keepImageAttachments
        )
        var apiMessages: [ChatCompletionRequest.Message] = []
        let systemPrompt = requestOptions.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !systemPrompt.isEmpty {
            apiMessages.append(.init(role: "system", content: .text(systemPrompt)))
        }
        apiMessages.append(contentsOf: try AttachmentDelivery.mapTurns(capabilityIntent.outboundMessages, isChatSend: requestOptions.capabilityEvidenceModel != nil, dynamicText: requestOptions.dynamicText) { try Self.buildRequestMessage($0, transport: .relayOpenAIChat, model: requestOptions.capabilityEvidenceModel, isOutgoingTurn: $1) })

        // reasoning_effort follows this turn's reasoningMode only; the stored connection-level level is void on read and is not sent.
        let reasoningEffort = omitReasoning ? nil : capabilityIntent.reasoningMode.flatMap { allowedMode in
            reasoningEffortOverride ?? Self.relayOpenAIReasoningEffort(allowedMode)
        }
        let serviceTier: String? = {
            let transport = RelayEndpointResolver.injectedTransport(relayRequested)
            guard let relayRequested,
                  transport == .openaiChatCompletions || transport == .openaiResponses,
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
        if let functionTools {
            body["tools"] = functionTools
        }
        try ClientToolsInjector.apply(to: &body, protocol: .openaiChat, options: requestOptions)
        ProfileParamsResolver.applyGenerationParameters(
            to: &body,
            options: requestOptions,
            finalRequest: request,
            effectiveTransport: RelayTransport.openaiChatCompletions.rawValue
        )
        // Relay web-search fragment: applied after the builder's output and before the additional request body.
        RelayWebFragments.apply(requestOptions.relayWebFragments, transport: .openaiChatCompletions, to: &body)
        ClientToolsInjector.moveHostMemoryToolsLast(in: &body)
        try AdditionalRequestBody.apply(requestOptions.localAdditionalRequestBody, to: &body)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        CapabilityExecutionRuntime.confirmFinalWireEncoded()
        return request
    }

    /// Responses request for a relay (Codex-style).
    ///
    /// Web search: relays no longer get a tool attached from the chat's web-search preference; a Responses
    /// web-search fragment is merged here only when the connection has stored one. The official cross-protocol
    /// route (`requestOptions.officialForeignRoute`) keeps the original behavior: with `webSearchEnabled` the
    /// web_search tool is attached.
    ///
    /// Whether stream is true is derived by the caller via `RelayRuntimeSupport.shouldForceStream`.
    ///
    /// Two inputs exist for the capability test; chat passes neither and its output is unchanged:
    /// `maxOutputTokens` replaces the default 16384; when `functionTools` is given, this request's `tools`
    /// holds only that array (no image_generation / web_search).
    /// `omitReasoning`: for probes; `reasoning` is not written. Chat does not pass it, so chat output is unchanged.
    func buildRelayResponsesRequest(
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
        removeTools: Bool = false,
        maxOutputTokens: Int? = nil,
        functionTools: [Any]? = nil,
        keepImageAttachments: Bool = false,
        omitReasoning: Bool = false
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

        let capabilityIntent = CapabilityEvidenceProductionAdapter.finalChatIntent(
            messages: messages, request: request,
            effectiveTransport: RelayTransport.openaiResponses.rawValue,
            model: requestOptions.capabilityEvidenceModel,
            requestedReasoningMode: reasoningMode,
            // Only the official cross-protocol route still expresses web-search intent; relay web search comes from the connection-level fragment alone.
            webSearchEnabled: requestOptions.officialForeignRoute && webSearchEnabled,
            keepImageAttachments: keepImageAttachments
        )

        let serviceTier: String? = {
            guard let rawTier = relayRequested?.serviceTier else {
                return nil
            }
            let trimmedTier = rawTier.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedTier.isEmpty ? nil : trimmedTier
        }()
        let reasoningEffort = capabilityIntent.reasoningMode.flatMap { allowedMode in
            reasoningEffortOverride ?? Self.relayOpenAIReasoningEffort(allowedMode)
        }
        let systemPrompt = requestOptions.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var toolsArray: [ResponsesRequest.Tool] = []
        if !removeTools, functionTools == nil {
            toolsArray.append(.init(
                type: "image_generation",
                model: supportsImageGeneration ? imageToolModelID : nil
            ))
            if requestOptions.officialForeignRoute, capabilityIntent.webSearchEnabled,
               let webTool = officialForeignResponsesWebTool(relayRequested: relayRequested) {
                toolsArray.append(webTool)
            }
        }
        let tools: [ResponsesRequest.Tool]? = toolsArray.isEmpty ? nil : toolsArray
        let payload = ResponsesRequest(
            model: modelID,
            input: try AttachmentDelivery.mapTurns(capabilityIntent.outboundMessages, isChatSend: requestOptions.capabilityEvidenceModel != nil, dynamicText: requestOptions.dynamicText) { try Self.buildResponsesInputMessage($0, transport: .relayOpenAIResponses, model: requestOptions.capabilityEvidenceModel, isOutgoingTurn: $1) },
            instructions: systemPrompt.isEmpty ? nil : systemPrompt,
            stream: stream ? true : nil,
            reasoning: omitReasoning || capabilityIntent.reasoningMode == nil
                ? nil : .init(effort: reasoningEffort, summary: "auto"),
            tools: tools,
            service_tier: serviceTier,
            store: relayRequested?.disableResponseStorage == true ? false : nil,
            // A limit passed in by the test capability takes priority; the main chat path uses plan.budget.oWire; everything else keeps the 16384 fallback.
            max_output_tokens: maxOutputTokens ?? requestOptions.maxOutputTokens ?? 16384
        )
        var body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any] ?? [:]
        if let functionTools {
            body["tools"] = functionTools
        }
        try ClientToolsInjector.apply(to: &body, protocol: .openaiResponses, options: requestOptions)
        ProfileParamsResolver.applyGenerationParameters(
            to: &body,
            options: requestOptions,
            finalRequest: request,
            effectiveTransport: RelayTransport.openaiResponses.rawValue
        )
        // Relay web-search fragment: applied after the builder's output and before the additional request body.
        RelayWebFragments.apply(requestOptions.relayWebFragments, transport: .openaiResponses, to: &body)
        ClientToolsInjector.moveHostMemoryToolsLast(in: &body)
        try AdditionalRequestBody.apply(requestOptions.localAdditionalRequestBody, to: &body)
        // Placed after the additional request body so a prompt_cache_key the user wrote themselves is kept.
        // The official cross-protocol route is not a relay, so its body is left alone.
        if !requestOptions.officialForeignRoute, body["prompt_cache_key"] == nil,
           let cacheKey = relayResponsesPromptCacheKey(
            relayRequested: relayRequested,
            model: body["model"] as? String ?? modelID,
            instructions: body["instructions"] as? String ?? "",
            firstUserText: capabilityIntent.outboundMessages.first(where: { $0.role == .user })?.text ?? ""
           ) {
            body["prompt_cache_key"] = cacheKey
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        CapabilityExecutionRuntime.confirmFinalWireEncoded()
        return request
    }


    struct RelayPingResult {
        let modelCount: Int
        let probedEndpoint: String
    }

    /// Lightweight ping: the endpoint is chosen by the transport.
    /// - codex-style / openai_responses → POST `{base}/responses` probe (store=false, no stream, output cap 16)
    ///   Codex-style relays often have no standard /models, so a lightweight /responses ping is used instead
    /// - openai_chat_completions / auto + modelID → POST `{base}/chat/completions` 1-token ping
    /// - openai_chat_completions / auto without modelID → GET `{base}/models` catalog fallback
    /// - anthropic_messages → POST `{base}/v1/messages` 1-token ping(max_tokens=1)
    /// - gemini_generate_content → POST `{base}/v1beta/models/{model}:generateContent` 1-token ping
    /// The probe requests of all four generation endpoints are produced by the chat request builders (`relayProbeRequest`).
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
        let transport = RelayEndpointResolver.injectedTransport(relayRequested) ?? .auto
        switch transport {
        case .llamacppNative:
            let probedEndpoint = try await pingLlamaCppNative(
                apiKey: apiKey,
                baseURL: secureBaseURL,
                relayRequested: relayRequested
            )
            return RelayPingResult(modelCount: 0, probedEndpoint: probedEndpoint)

        case .openaiResponses:
            let probedEndpoint = try await pingRelayProbe(
                transport: .openaiResponses,
                apiKey: apiKey,
                baseURL: secureBaseURL,
                modelID: modelID ?? "gpt-5",
                relayRequested: relayRequested
            )
            return RelayPingResult(modelCount: 0, probedEndpoint: probedEndpoint)
        case .openaiChatCompletions, .auto:
            if let modelID = modelID?.trimmingCharacters(in: .whitespacesAndNewlines),
               !modelID.isEmpty {
                let probedEndpoint = try await pingRelayProbe(
                    transport: .openaiChatCompletions,
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
            let probedEndpoint = try await pingRelayProbe(
                transport: .anthropicMessages,
                apiKey: apiKey,
                baseURL: secureBaseURL,
                modelID: modelID ?? "claude-3-5-haiku-latest",
                relayRequested: relayRequested
            )
            return RelayPingResult(modelCount: 0, probedEndpoint: probedEndpoint)
        case .geminiGenerateContent:
            let probedEndpoint = try await pingRelayProbe(
                transport: .geminiGenerateContent,
                apiKey: apiKey,
                baseURL: secureBaseURL,
                modelID: modelID ?? "gemini-2.0-flash",
                relayRequested: relayRequested
            )
            return RelayPingResult(modelCount: 0, probedEndpoint: probedEndpoint)
        }
    }

    /// A probe request is the chat request with a one-line conversation: all four protocols are produced by the
    /// same request builder that protocol's chat send uses (same headers and the same identity / storage / cache
    /// fields). Only the conversation content, streaming and the output cap differ, and no tool or reasoning
    /// fields are sent (including the connection-level reasoning level). Chat has its own "drop the field and
    /// resend" loop when upstream rejects those fields; a probe has none, so sending them would mix a rejected
    /// field up with the question of whether this route accepts the model at all. It only builds the request and
    /// never sends it; `baseURL` is an address that already passed `requireConfiguredRelayBaseURL`.
    func relayProbeRequest(
        transport: RelayTransport,
        apiKey: String,
        baseURL: String,
        modelID: String,
        relayRequested: RelayRequestedConfig?
    ) throws -> URLRequest {
        let messages = [
            ChatMessage(
                id: UUID(),
                role: .user,
                text: "ping",
                providerKind: .relay,
                providerName: "Relay",
                modelName: modelID,
                state: .delivered
            )
        ]
        switch transport {
        case .openaiResponses:
            return try buildRelayResponsesRequest(
                modelID: modelID, messages: messages, apiKey: apiKey, baseURL: baseURL, stream: false,
                reasoningMode: .automatic, relayRequested: relayRequested,
                removeTools: true, maxOutputTokens: RelayModelProbe.responsesMaxOutputTokens,
                omitReasoning: true
            )
        case .openaiChatCompletions, .auto:
            return try buildChatCompletionsRequest(
                modelID: modelID, messages: messages, apiKey: apiKey, stream: false, baseURL: baseURL,
                reasoningMode: .automatic, relayRequested: relayRequested,
                validationMaxTokens: RelayModelProbe.otherProtocolsMaxTokens,
                omitReasoning: true
            )
        case .anthropicMessages:
            return try AnthropicService(session: session).buildRelayMessagesRequest(
                modelID: modelID, messages: messages, apiKey: apiKey, baseURL: baseURL, stream: false,
                reasoningMode: .automatic, relayRequested: relayRequested,
                droppedParams: ["thinking", "output_config"],
                maxOutputTokens: RelayModelProbe.otherProtocolsMaxTokens
            )
        case .geminiGenerateContent:
            return try GeminiService(session: session).buildRelayGenerateContentRequest(
                modelID: modelID, messages: messages, apiKey: apiKey, baseURL: baseURL, stream: false,
                reasoningMode: .automatic, supportsImageGen: false, relayRequested: relayRequested,
                droppedParams: ["thinking_config"],
                maxOutputTokens: RelayModelProbe.otherProtocolsMaxTokens
            )
        case .llamacppNative:
            throw ProviderServiceError.invalidConfiguration(detail: "Relay probe does not support this transport here.")
        }
    }

    /// Sends one probe request. With a modelID it goes through the real chat path, so a successful `/models`
    /// with an unusable generation endpoint is not mistaken for success.
    private func pingRelayProbe(
        transport: RelayTransport,
        apiKey: String,
        baseURL: String,
        modelID: String,
        relayRequested: RelayRequestedConfig?
    ) async throws -> String {
        let request = try relayProbeRequest(
            transport: transport, apiKey: apiKey, baseURL: baseURL, modelID: modelID, relayRequested: relayRequested
        )
        let (data, response) = try await session.relayData(for: request)
        try requireSuccessfulRelayPing(data: data, response: response, request: request, transport: transport)
        switch transport {
        case .openaiResponses: return "POST /responses"
        case .anthropicMessages: return "POST /v1/messages"
        case .geminiGenerateContent: return "POST :generateContent"
        case .openaiChatCompletions, .auto, .llamacppNative: return "POST /chat/completions"
        }
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
        try requireSuccessfulRelayPing(
            data: data, response: response, request: request, transport: .llamacppNative
        )
        return "POST /completion"
    }

    /// The Chat / Responses request for "Test capabilities": the same validation and builder as relay streaming
    /// chat (the address goes through `requireConfiguredRelayBaseURL`, `stream: true`), with just two extra
    /// inputs, the output cap and function tools. It only builds the request and never sends it.
    func relayCapabilityTestRequest(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        baseURL: String,
        requestOptions: ChatRequestOptions,
        relayRequested: RelayRequestedConfig?,
        maxOutputTokens: Int,
        functionTools: [Any]?
    ) throws -> URLRequest {
        try validateRelayAPIKeyIfRequired(apiKey, relayRequested: relayRequested)
        let secureBaseURL = try requireConfiguredRelayBaseURL(apiKey: apiKey, baseURL: baseURL, relayRequested: relayRequested)
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderServiceError.invalidConfiguration(detail: "Missing model identifier.")
        }
        switch RelayEndpointResolver.injectedTransport(relayRequested) ?? .openaiChatCompletions {
        case .openaiResponses:
            return try buildRelayResponsesRequest(
                modelID: modelID, messages: messages, apiKey: apiKey, baseURL: secureBaseURL, stream: true,
                reasoningMode: .automatic, requestOptions: requestOptions, relayRequested: relayRequested,
                maxOutputTokens: maxOutputTokens, functionTools: functionTools, keepImageAttachments: true
            )
        case .openaiChatCompletions, .auto:
            return try buildChatCompletionsRequest(
                modelID: modelID, messages: messages, apiKey: apiKey, stream: true, baseURL: secureBaseURL,
                reasoningMode: .automatic, requestOptions: requestOptions, relayRequested: relayRequested,
                validationMaxTokens: maxOutputTokens, functionTools: functionTools, keepImageAttachments: true
            )
        case .anthropicMessages, .geminiGenerateContent, .llamacppNative:
            throw ProviderServiceError.invalidConfiguration(detail: "Capability test does not support this transport here.")
        }
    }

    private func requireSuccessfulRelayPing(
        data: Data,
        response: URLResponse,
        request: URLRequest,
        transport: RelayTransport
    ) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ProviderServiceError.network(detail: "No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw mapHTTPError(
                statusCode: http.statusCode, data: data, url: request.url, request: request,
                isRelay: true, relayTransport: transport
            )
        }
        try rejectRelayWebPageSuccess(http, data: data)
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
        let resolvedTransport = transport ?? RelayEndpointResolver.injectedTransport(relayRequested) ?? .auto
        let codexHeaders = RelayRuntimeSupport.codexIdentityHeaders(
            for: resolvedTransport,
            relayRequested: relayRequested,
            resolvedAuthMode: resolvedAuth
        )
        for (name, value) in codexHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let ua = relayRequested?.effectiveCustomUserAgent?.trimmingCharacters(in: .whitespacesAndNewlines),
           !ua.isEmpty {
            request.setValue(ua, forHTTPHeaderField: "User-Agent")
        }
    }

    /// The `prompt_cache_key` of a relay Responses request body. It follows the same condition as injecting the
    /// Codex identity headers in `applyRelayOpenAIHeaders` (auth is not none and `codexIdentityHeaders` is
    /// non-empty): when the identity headers are not injected this returns nil and the body gets no key.
    private func relayResponsesPromptCacheKey(
        relayRequested: RelayRequestedConfig?,
        model: String,
        instructions: String,
        firstUserText: String
    ) -> String? {
        guard !RelayRuntimeSupport.codexIdentityHeaders(
            for: .openaiResponses,
            relayRequested: relayRequested,
            resolvedAuthMode: resolveRelayOpenAIAuthMode(relayRequested)
        ).isEmpty else { return nil }
        return RelayRuntimeSupport.promptCacheKey(
            model: model, instructions: instructions, firstUserText: firstUserText
        )
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
                .transportRules[relayEnvelopeKey(for: RelayEndpointResolver.injectedTransport(relayRequested) ?? .openaiChatCompletions)]?
                .defaultAuthMode
        ) ?? .bearer
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

    /// The Responses web-search tool for the official cross-protocol route (the relay builder's old behavior,
    /// kept for official providers only). Tool name: configured value > value delivered by the runtime config >
    /// default `web_search`; `disabled` attaches nothing.
    private func officialForeignResponsesWebTool(relayRequested: RelayRequestedConfig?) -> ResponsesRequest.Tool? {
        let runtimeName: RelayWebSearchToolName? = {
            switch MetadataClient.shared.syncRelayRuntimeConfig()
                .transportRules[MetadataClient.RelayTransportKey.openaiResponses]?.webSearchToolName {
            case "web_search": return .webSearch
            case "web_search_preview": return .webSearchPreview
            case "disabled": return .disabled
            default: return nil
            }
        }()
        let name = relayRequested?.webSearchToolName ?? runtimeName ?? .webSearch
        return name == .disabled ? nil : .init(type: name.rawValue)
    }

    /// Citation stream shape of the official cross-protocol route when web search is on: the webSearch profile the catalog gives this model (the original behavior).
    private func officialForeignWebSearchShape(modelID: String) -> MetadataClient.StreamShape? {
        let profile = MetadataClient.shared.syncResolveCatalogModel(
            modelID: modelID, providerKind: resolveCostProviderKind(modelID: modelID)
        )?.profiles.webSearch
        return MetadataClient.shared.syncWebSearchStreamShape(profileName: profile)
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
        return try relayEndpointURL(
            apiBaseURL: apiBaseURL,
            endpointPath: endpointPath,
            relayRequested: relayRequested,
            apiKey: apiKey,
            authMode: authMode,
            invalidURLDetail: "Invalid base URL: \(rawBaseURL)"
        )
    }

    /// The endpoint URL once the API root is known: append the path, then add the query key and custom query according to the auth mode.
    private func relayEndpointURL(
        apiBaseURL: String,
        endpointPath: String,
        relayRequested: RelayRequestedConfig?,
        apiKey: String,
        authMode: RelayAuthMode,
        invalidURLDetail: String? = nil
    ) throws -> URL {
        let invalidURLDetail = invalidURLDetail ?? "Invalid base URL: \(apiBaseURL)"
        let endpointURL = try RelayEndpointResolver.endpointURL(
            apiBaseURL: apiBaseURL,
            endpointPath: endpointPath,
            securityMode: relayRequested?.securityMode ?? .remoteHTTPS
        )
        guard var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false) else {
            throw ProviderServiceError.invalidConfiguration(detail: invalidURLDetail)
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
            throw ProviderServiceError.invalidConfiguration(detail: invalidURLDetail)
        }
        return url
    }

    private struct ResponsesStreamPumpResult {
        var accumulatedText: String
        var lastUsage: ResponsesUsage?
        var firstContentEmitted: Bool
        var finishTracker = StreamFinishTracker(family: .openaiResponses)
    }

    private func streamRelayResponses(
        webSearchShape: MetadataClient.StreamShape?,
        attachmentConnectionID: UUID?,
        attachmentModelID: String?,
        attachmentFileOverride: Bool?,
        requestBuilder: @escaping (RelayRetryHints) throws -> URLRequest
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let firstResult = try await self.pumpRelayResponsesStream(
                        hints: RelayRetryHints(),
                        webSearchShape: webSearchShape,
                        attachmentConnectionID: attachmentConnectionID,
                        attachmentModelID: attachmentModelID,
                        attachmentFileOverride: attachmentFileOverride,
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
                        usageReported: firstResult.lastUsage != nil,
                        costSource: nil,
                        finish: firstResult.finishTracker.finish()
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
    /// - webSearchShape: the stream shape the caller derived from the web-search fragment merged in for this
    ///   turn, used by the strategy to parse citations; nil when there is no fragment.
    private func pumpRelayResponsesStream(
        hints: RelayRetryHints,
        webSearchShape: MetadataClient.StreamShape?,
        attachmentConnectionID: UUID?,
        attachmentModelID: String?,
        attachmentFileOverride: Bool?,
        requestBuilder: @escaping (RelayRetryHints) throws -> URLRequest,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws -> ResponsesStreamPumpResult {
        let bytes: URLSession.AsyncBytes
        // When a relay rejects a native file block before the first event, resend once with the files injected as text (NativeFileFallback).
        let pair = try await NativeFileFallback.run(
            .relayScope(
                .openaiResponses, connectionID: attachmentConnectionID, modelID: attachmentModelID,
                fileOverride: attachmentFileOverride
            )
        ) {
            try await self.executeRelayResponsesStreamRequestWithFallbacks(
                requestBuilder: { _ in try requestBuilder(hints) }
            )
        }
        bytes = pair.0
        let http = pair.1

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
        var bodyStartChecked = false

        for try await line in bytes.utf8Lines {
            if Task.isCancelled { break }
            // The fallback web page's Content-Type is not necessarily html: check the first body line once more before any output.
            try self.rejectRelayWebPageStreamStart(http, line: line, settled: &bodyStartChecked)

            if line.hasPrefix("event: ") {
                currentEvent = String(line.dropFirst(7))
                continue
            }

            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" { break }
            guard let jsonData = payload.data(using: .utf8) else { continue }
            result.finishTracker.observeFrame(jsonData, eventType: currentEvent.isEmpty ? nil : currentEvent)
            // response.failed throws in the switch below: hand out the finish first.
            if result.finishTracker.finishRaw == "failed" { continuation.yield(.finish(result.finishTracker.finish())) }

            if !currentEvent.isEmpty {
                let injected = self.injectResponsesEventType(payload: payload, type: currentEvent)
                for ev in respStrategy.parseStreamLine(injected, ctx: &respCtx, shape: webSearchShape) {
                    switch ev {
                    case .reasoning, .toolCallDeltas, .activity: continuation.yield(ev)
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
            case "response.completed", "response.incomplete":
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
        webSearchShape: MetadataClient.StreamShape?,
        requestBuilder: @escaping (String?) throws -> URLRequest
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, http) = try await self.executeRelayChatStreamRequest(
                        requestBuilder: requestBuilder
                    )

                    var accumulatedText = ""
                    var lastUsage: OpenAIUsage?
                    let chatStrategy = TransportRegistry.strategy(for: .openaiChat)
                    var chatCtx = StreamContext()
                    // For relay Chat streaming web search the annotations arrive on the delta (the web tool fragment only writes the message path).
                    chatCtx.readsDeltaCitations = true
                    var chatLastCitationsCount = 0
                    var yieldedAnyEvent = false
                    var bodyStartChecked = false
                    defer {
                        for ev in OpenAIChatStrategy.flushToolCalls(ctx: &chatCtx) { continuation.yield(ev) }
                    }

                    var finishTracker = StreamFinishTracker(family: .openaiChat)
                    for try await line in bytes.utf8Lines {
                        if Task.isCancelled { break }
                        finishTracker.observeSSELine(line)
                        // The Content-Type of a fallback web page is not necessarily html: check the first body line once more before any output.
                        try self.rejectRelayWebPageStreamStart(http, line: line, settled: &bodyStartChecked)
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" { break }
                        guard let chunkData = payload.data(using: .utf8) else { continue }
                        // An error frame inside the stream (the HTTP status is already 200). It
                        // decodes as an ordinary chunk because every field is optional, so unless
                        // it is recognized first it is skipped as an empty frame and the message
                        // ends as "completed, no content".
                        try Self.throwIfStreamErrorFrame(chunkData, beforeAnyContent: !yieldedAnyEvent)
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
                            yieldedAnyEvent = true
                            continuation.yield(.delta(content))
                        }

                        for ev in chatStrategy.parseStreamLine(payload, ctx: &chatCtx, shape: webSearchShape) {
                            switch ev {
                            case let .reasoning(text):
                                yieldedAnyEvent = true
                                continuation.yield(.reasoning(text))
                            case .toolCallDeltas:
                                yieldedAnyEvent = true
                                continuation.yield(ev)
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

                    let (relayBreakdown, relayUsageReported) = Self.parseUsageSignal(lastUsage)
                    continuation.yield(
                        .done(
                            ProviderChatResult(
                                text: accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines),
                                promptTokens: relayBreakdown.totalInputTokens,
                                completionTokens: relayBreakdown.completionTokens,
                                estimatedCost: 0,
                                usageBreakdown: relayBreakdown,
                                usageReported: relayUsageReported,
                                costSource: nil,
                                finish: finishTracker.finish()
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

    private static func relayOpenAIReasoningEffort(_ mode: ReasoningMode) -> String? {
        switch mode {
        case .automatic: return nil
        case .fast: return "low"
        case .balanced: return "medium"
        case .deep: return "high"
        case .max: return "xhigh"
        }
    }

    // A rejected reasoning level is dropped and resent in one place, ChatManager's relay send loop; this only sends once.
    private func performRelayChatDataRequest(
        requestBuilder: (String?) throws -> URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await performRelayRawRequest(
                requestBuilder(nil), effectiveTransport: .openaiChatCompletions
            )
        } catch let error as RelayHTTPStatusError {
            throw mapHTTPError(
                statusCode: error.statusCode, data: error.data, isRelay: true,
                relayTransport: error.effectiveTransport
            )
        }
    }

    private func performRelayResponsesDataRequestWithFallbacks(
        requestBuilder: (RelayRetryHints) throws -> URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        let firstHints = RelayRetryHints()
        do {
            return try await performRelayRawRequest(
                try requestBuilder(firstHints), effectiveTransport: .openaiResponses
            )
        } catch let error as RelayHTTPStatusError {
            throw mapHTTPError(
                statusCode: error.statusCode, data: error.data, isRelay: true,
                relayTransport: error.effectiveTransport
            )
        }
    }

    private func executeRelayChatStreamRequest(
        requestBuilder: (String?) throws -> URLRequest
    ) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        do {
            return try await executeRelayStreamRequest(
                requestBuilder(nil), effectiveTransport: .openaiChatCompletions
            )
        } catch let error as RelayHTTPStatusError {
            throw mapHTTPError(
                statusCode: error.statusCode, data: error.data, isRelay: true,
                relayTransport: error.effectiveTransport
            )
        }
    }

    private func executeRelayResponsesStreamRequestWithFallbacks(
        requestBuilder: (RelayRetryHints) throws -> URLRequest
    ) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        let firstHints = RelayRetryHints()
        do {
            return try await executeRelayStreamRequest(
                try requestBuilder(firstHints), effectiveTransport: .openaiResponses
            )
        } catch let error as RelayHTTPStatusError {
            throw mapHTTPError(
                statusCode: error.statusCode, data: error.data, isRelay: true,
                relayTransport: error.effectiveTransport
            )
        }
    }

    private struct RelayHTTPStatusError: Error {
        let statusCode: Int
        let data: Data
        /// The protocol this request actually used, so error mapping can tell the two Codex identity 403 causes apart.
        let effectiveTransport: RelayTransport
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
                        url: originalRequest.url, request: originalRequest, isRelay: true,
                        relayTransport: effectiveTransport
                    )
                    recordCapabilityUpstreamRejection(
                        mappedError: mapped, errorData: errorData,
                        providerKind: .relay, modelID: scope.modelID,
                        request: originalRequest, effectiveTransport: effectiveTransport.rawValue,
                        relayEngineProfile: nil, relayDeclaredProfile: nil
                    )
                    throw RelayHTTPStatusError(
                        statusCode: http.statusCode, data: errorData, effectiveTransport: effectiveTransport
                    )
                }
                try rejectRelayWebPageSuccess(http, data: nil)
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
                    url: originalRequest.url, request: originalRequest, isRelay: true,
                    relayTransport: effectiveTransport
                )
                recordCapabilityUpstreamRejection(
                    mappedError: mapped, errorData: data,
                    providerKind: .relay, modelID: scope.modelID,
                    request: originalRequest, effectiveTransport: effectiveTransport.rawValue,
                    relayEngineProfile: nil, relayDeclaredProfile: nil
                )
                throw RelayHTTPStatusError(
                    statusCode: http.statusCode, data: data, effectiveTransport: effectiveTransport
                )
            }
            try rejectRelayWebPageSuccess(http, data: data)
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
                breakdown: breakdown, modelID: modelID, providerKind: costProviderKind, at: Date()
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
            usageReported: imagesResult.usage != nil,
            costSource: source
        )
    }


    /// Finds the providerKind of the model family that matches modelID by sweeping the official providers (OpenAI first).
    /// Used on the Relay path: Relay goes through OpenAIService, but the modelID may belong to any family (claude / gemini behind an
    /// OpenAI Chat Completions compatible proxy), so .openAI cannot be hard-coded when looking up pricing.
    /// A real OpenAI model also hits .openAI first in the sweep, so the result equals the hard-coded one.
    /// This is only the Service layer's USD estimate; when Relay hits an official entry, the stored cost is re-estimated by the delivery layer
    /// (`ChatDeliveryAccounting.generationCost` via `RelayOfficialCatalogResolver.officialMatch`) and this amount is ignored.
    /// It uses the same matching function as delivery estimation and capability inheritance (`RelayOfficialCatalogResolver.officialMatch`): canonicalModelId first, otherwise id.
    private func resolveCostProviderKind(modelID: String, model: AIModel? = nil) -> ProviderKind {
        RelayOfficialCatalogResolver.officialMatch(
            modelID: modelID,
            canonicalModelId: model?.canonicalModelId,
            transportPriority: .openAI,
            metadata: .shared
        )?.matchedProviderKind ?? .openAI
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

nonisolated private struct OpenAIUsage: Decodable {
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
    /// Set only for a relay that injects the Codex identity headers; nil is not written to the request body.
    var prompt_cache_key: String? = nil

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

nonisolated private struct ResponsesUsage: Decodable {
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
    /// Tool legs reuse the same usage parser as ordinary chat: what a leg gets is the usage object of an SSE frame.
    nonisolated static func legUsageBreakdown(usageJSON: [String: Any]) -> UsageBreakdown? {
        guard let data = try? JSONSerialization.data(withJSONObject: usageJSON),
              let usage = try? JSONDecoder().decode(OpenAIUsage.self, from: data) else { return nil }
        return parseUsage(usage)
    }

    nonisolated fileprivate static func parseUsage(_ usage: OpenAIUsage?) -> UsageBreakdown {
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

    /// Usage parsing plus an explicit signal for "did the upstream give a usage object": `parseUsage(nil)` also returns an empty breakdown,
    /// so the delivery layer cannot tell from the breakdown whether there was usage.
    fileprivate static func parseUsageSignal(_ usage: OpenAIUsage?) -> (breakdown: UsageBreakdown, reported: Bool) {
        (parseUsage(usage), usage != nil)
    }
    #if DEBUG
    /// Test entry: a non-stream Chat Completions response body goes through production decoding and `parseUsageSignal`.
    static func chatCompletionUsageForTesting(responseBody: Data) throws -> (breakdown: UsageBreakdown, reported: Bool) {
        parseUsageSignal(try JSONDecoder().decode(ChatCompletionResponse.self, from: responseBody).usage)
    }
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

    /// The OpenAI Responses API names usage fields input_tokens / output_tokens (same meaning as chat completions but different fields).
    /// Tool legs of openai_responses reuse the same Responses usage parser as ordinary chat: what a leg gets is the usage object of the `response.completed` frame.
    nonisolated static func responsesLegUsageBreakdown(usageJSON: [String: Any]) -> UsageBreakdown? {
        guard let data = try? JSONSerialization.data(withJSONObject: usageJSON),
              let usage = try? JSONDecoder().decode(ResponsesUsage.self, from: data) else { return nil }
        return parseResponsesUsage(usage)
    }

    nonisolated fileprivate static func parseResponsesUsage(_ usage: ResponsesUsage?) -> UsageBreakdown {
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

// MARK: - Protocol entry with request options: a one-line forward to the options overload this service already has

extension OpenAIService {
    func sendMessage(
        apiKey: String, modelID: String, messages: [ChatMessage], requestOptions: ChatRequestOptions
    ) async throws -> ProviderChatResult {
        try await sendMessage(apiKey: apiKey, modelID: modelID, messages: messages, reasoningMode: .automatic, requestOptions: requestOptions)
    }

    func sendMessageStream(
        apiKey: String, modelID: String, messages: [ChatMessage], requestOptions: ChatRequestOptions
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        sendMessageStream(apiKey: apiKey, modelID: modelID, messages: messages, reasoningMode: .automatic, requestOptions: requestOptions)
    }

    func sendMessage(
        apiKey: String, modelID: String, messages: [ChatMessage], baseURL: String, requestOptions: ChatRequestOptions
    ) async throws -> ProviderChatResult {
        try await sendMessage(apiKey: apiKey, modelID: modelID, messages: messages, baseURL: baseURL, reasoningMode: .automatic, requestOptions: requestOptions, relayRequested: nil)
    }

    func sendMessageStream(
        apiKey: String, modelID: String, messages: [ChatMessage], baseURL: String, requestOptions: ChatRequestOptions
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        sendMessageStream(apiKey: apiKey, modelID: modelID, messages: messages, baseURL: baseURL, reasoningMode: .automatic, requestOptions: requestOptions, relayRequested: nil)
    }
}
