import Foundation
import OriveoProviderKit

final class GeminiService: BaseAPIService, ProviderServiceProtocol {
    private let baseURL = "https://generativelanguage.googleapis.com/v1beta"

    // A subclass with stored properties still synthesizes its own isolated deinit; keep it nonisolated like BaseAPIService (swift#85663).
    nonisolated deinit {}

    override func applyHeaders(to request: inout URLRequest, apiKey: String) {
        applyJSONHeaders(to: &request, includeAccept: false)
    }

    /// endpoint_route builder. Selection is exclusively the versioned catalog recipe; there is
    /// no model-name inference or beta fallback. The endpoint_route recipe is itself the web recipe:
    /// it supplies the route and the google_search tool op.
    func buildInteractionsRequest(
        modelID: String,
        messages: [ChatMessage],
        apiKey: String,
        stream: Bool,
        recipe: MetadataClient.CapabilityRecipe,
        reasoningRecipe: MetadataClient.CapabilityRecipe? = nil,
        reasoningIntent: String? = nil,
        reasoningAvailableIntents: [String]? = nil,
        systemPrompt: String = "",
        safeCustomBodyFragments: [SafeCustomBodyFragment] = [],
        additionalRequestBody: AdditionalRequestBodyPayload? = nil,
        capabilityEvidenceModel: AIModel? = nil,
        dynamicText: String? = nil
    ) throws -> URLRequest {
        guard recipe.executionKind == "endpoint_route",
              recipe.providerKind == "gemini",
              recipe.transport.protocolName == "gemini_interactions",
              let route = recipe.route else {
            throw ProviderServiceError.invalidConfiguration(detail: "Invalid Gemini Interactions recipe.")
        }
        return try buildInteractionsRequest(
            modelID: modelID, messages: messages, apiKey: apiKey, stream: stream,
            route: route, webRecipe: recipe,
            reasoningRecipe: reasoningRecipe, reasoningIntent: reasoningIntent,
            reasoningAvailableIntents: reasoningAvailableIntents,
            systemPrompt: systemPrompt, safeCustomBodyFragments: safeCustomBodyFragments,
            additionalRequestBody: additionalRequestBody, capabilityEvidenceModel: capabilityEvidenceModel,
            dynamicText: dynamicText
        )
    }

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
        try validateAPIKey(apiKey)
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderServiceError.invalidConfiguration(detail: "Missing model identifier.")
        }

        if let recipe = Self.interactionsRecipe(
            modelID: modelID, webSearchEnabled: webSearchEnabled, historyHasVideo: Self.historyHasVideo(messages)
        ) {
            return try await sendInteractions(
                apiKey: apiKey, modelID: modelID, messages: messages, stream: false, recipe: recipe,
                reasoningMode: reasoningMode, systemPrompt: requestOptions.systemPrompt,
                safeCustomBodyFragments: requestOptions.localSafeCustomBodyFragments,
                additionalRequestBody: requestOptions.localAdditionalRequestBody,
                capabilityEvidenceModel: requestOptions.capabilityEvidenceModel,
                dynamicText: requestOptions.dynamicText
            )
        }

        let (data, _) = try await performRawWithUnsupportedParamSelfHeal(
            providerKind: .gemini,
            modelID: modelID
        ) { droppedParams in
            try buildGenerateContentRequest(
                modelID: modelID, messages: messages, apiKey: apiKey, stream: false,
                reasoningMode: reasoningMode, webSearchEnabled: webSearchEnabled,
                supportsImageGen: supportsImageGen, requestOptions: requestOptions,
                droppedParams: droppedParams
            )
        }



        let geminiResponse: GeminiGenerateContentResponse
        do {
            geminiResponse = try decoder.decode(GeminiGenerateContentResponse.self, from: data)
        } catch {
            throw ProviderServiceError.network(detail: "Decoding failed: \(error.localizedDescription)")
        }
        let continuationRecipe = RecipeContinuationRuntime.selectedRecipe(
            provider: .gemini, modelID: modelID, transport: "gemini_generate_content",
            webSearchEnabled: webSearchEnabled, reasoningMode: reasoningMode,
            continuationKind: "replay_blocks", parser: { ["gemini_google_search_v1", "gemini_thinking_v1"].contains($0) }
        )
        if let blocks = Self.geminiReplayBlocks(from: data), let encoded = RecipeContinuationRuntime.jsonValue(blocks) {
            try RecipeContinuationRuntime.save(
                messageID: requestOptions.localContinuationMessageID, recipe: continuationRecipe,
                state: ["blocks": encoded]
            )
        }

        try Self.throwIfBlockedChunk(geminiResponse)

        let text = geminiResponse.resolvedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageAttachments = geminiResponse.resolvedAttachments
        guard !text.isEmpty || !imageAttachments.isEmpty else {
            throw ProviderServiceError.emptyResponse
        }

        let breakdown = Self.parseUsage(geminiResponse.usageMetadata)
        let (cost, source) = await MetadataClient.shared.calcCost(
            breakdown: breakdown, modelID: modelID, providerKind: .gemini
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

    func sendMessage(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        baseURL: String,
        reasoningMode: ReasoningMode = .automatic,
        webSearchEnabled: Bool = false,
        supportsImageGen: Bool = false,
        requestOptions: ChatRequestOptions = ChatRequestOptions(),
        relayRequested: RelayRequestedConfig? = nil
    ) async throws -> ProviderChatResult {
        try validateAPIKey(apiKey)
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderServiceError.invalidConfiguration(detail: "Missing model identifier.")
        }

        // When a relay rejects a native file block, resend once with the files injected as text (NativeFileFallback).
        let (data, _) = try await NativeFileFallback.run(
            .relayScope(.geminiGenerateContent, connectionID: requestOptions.attachmentConnectionID, modelID: requestOptions.capabilityEvidenceModel?.id, fileOverride: requestOptions.capabilityEvidenceModel?.relayCapabilityOverrides?.file)
        ) { try await performRawWithUnsupportedParamSelfHeal(
            providerKind: .relay,
            modelID: modelID,
            effectiveTransport: RelayTransport.geminiGenerateContent.rawValue,
            relayEngineProfile: relayRequested?.engineProfile,
            relayDeclaredProfile: requestOptions.generationProfile
        ) { droppedParams in
            try buildRelayGenerateContentRequest(
                modelID: modelID,
                messages: messages,
                apiKey: apiKey,
                baseURL: baseURL,
                stream: false,
                reasoningMode: reasoningMode,
                webSearchEnabled: webSearchEnabled,
                supportsImageGen: supportsImageGen,
                requestOptions: requestOptions,
                relayRequested: relayRequested,
                droppedParams: droppedParams
            )
        } }

        let geminiResponse: GeminiGenerateContentResponse
        do {
            geminiResponse = try decoder.decode(GeminiGenerateContentResponse.self, from: data)
        } catch {
            throw ProviderServiceError.network(detail: "Decoding failed: \(error.localizedDescription)")
        }

        try Self.throwIfBlockedChunk(geminiResponse)

        let text = geminiResponse.resolvedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = geminiResponse.resolvedAttachments
        guard !text.isEmpty || !attachments.isEmpty else {
            throw ProviderServiceError.emptyResponse
        }

        let breakdown = Self.parseUsage(geminiResponse.usageMetadata)
        return ProviderChatResult(
            text: text,
            promptTokens: breakdown.totalInputTokens,
            completionTokens: breakdown.completionTokens,
            estimatedCost: 0,
            attachments: attachments.isEmpty ? nil : attachments,
            usageBreakdown: breakdown,
            costSource: nil
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
                do {
                    try self.validateAPIKey(apiKey)
                    guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw ProviderServiceError.invalidConfiguration(detail: "Missing model identifier.")
                    }

                    if let recipe = Self.interactionsRecipe(
                        modelID: modelID, webSearchEnabled: webSearchEnabled,
                        historyHasVideo: Self.historyHasVideo(messages)
                    ) {
                        try await self.streamInteractions(
                            apiKey: apiKey, modelID: modelID, messages: messages, recipe: recipe,
                            reasoningMode: reasoningMode, systemPrompt: requestOptions.systemPrompt,
                            safeCustomBodyFragments: requestOptions.localSafeCustomBodyFragments,
                            additionalRequestBody: requestOptions.localAdditionalRequestBody,
                            capabilityEvidenceModel: requestOptions.capabilityEvidenceModel,
                            dynamicText: requestOptions.dynamicText,
                            continuation: continuation
                        )
                        continuation.finish()
                        return
                    }

                    let request = try self.buildGenerateContentRequest(
                        modelID: modelID, messages: messages, apiKey: apiKey, stream: true,
                        reasoningMode: reasoningMode, webSearchEnabled: webSearchEnabled,
                        supportsImageGen: supportsImageGen, requestOptions: requestOptions
                    )
                    let (bytes, response) = try await self.bytesWithUnsupportedParamSelfHeal(
                        providerKind: .gemini,
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
                    var lastUsage: GeminiUsageMetadata?
                    var latestReplayBlocks: [[String: Any]]?
                    // groundingMetadata.groundingChunks[].web.{uri,title}.
                    let gemStrategy = TransportRegistry.strategy(for: .geminiGenerate)
                    let gemShape = MetadataClient.shared.syncWebSearchStreamShape(
                        profileName: MetadataClient.shared.syncResolveCatalogModel(
                            modelID: modelID,
                            providerKind: .gemini
                        )?.profiles.webSearch
                    )
                    var gemCtx = StreamContext()
                    var gemLastCitationsCount = 0
                    var finishTracker = StreamFinishTracker(family: .gemini)

                    for try await line in bytes.utf8Lines {
                        if Task.isCancelled { break }

                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        guard let jsonData = payload.data(using: .utf8) else { continue }

                        let chunk: GeminiGenerateContentResponse
                        do {
                            chunk = try self.decoder.decode(
                                GeminiGenerateContentResponse.self, from: jsonData
                            )
                        } catch {
                            continue
                        }
                        latestReplayBlocks = Self.geminiReplayBlocks(from: jsonData) ?? latestReplayBlocks

                        finishTracker.observeFrame(jsonData)
                        // A blocked finishReason / promptFeedback.blockReason throws on the next line: hand out the finish first.
                        if Self.isBlockedFinishChunk(chunk) || Self.isBlockedPromptChunk(chunk) {
                            continuation.yield(.finish(finishTracker.finish()))
                        }
                        // A blocked termination must throw so the error card is shown; the partial text already emitted is kept by the upper Failed path
                        try Self.throwIfBlockedChunk(chunk)

                        if let usage = chunk.usageMetadata {
                            lastUsage = usage
                        }

                        let chunkText = chunk.resolvedText
                        if !chunkText.isEmpty {
                            accumulatedText += chunkText
                            continuation.yield(.delta(chunkText))
                        }

                        for att in chunk.resolvedAttachments {
                            continuation.yield(.imagePart(att))
                        }

                        for ev in gemStrategy.parseStreamLine(payload, ctx: &gemCtx, shape: gemShape) {
                            switch ev {
                            case .reasoning, .toolCallDeltas: continuation.yield(ev)
                            default: break
                            }
                        }
                        let citationsSnapshot = gemCtx.citationsAccumulator.citations
                        if citationsSnapshot.count > gemLastCitationsCount {
                            gemLastCitationsCount = citationsSnapshot.count
                            continuation.yield(.citations(citationsSnapshot))
                        }
                    }

                    for ev in GeminiGenerateStrategy.flushToolCalls(ctx: &gemCtx) { continuation.yield(ev) }

                    let finalText = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let continuationRecipe = RecipeContinuationRuntime.selectedRecipe(
                        provider: .gemini, modelID: modelID, transport: "gemini_generate_content",
                        webSearchEnabled: webSearchEnabled, reasoningMode: reasoningMode,
                        continuationKind: "replay_blocks", parser: { ["gemini_google_search_v1", "gemini_thinking_v1"].contains($0) }
                    )
                    if let blocks = latestReplayBlocks, let encoded = RecipeContinuationRuntime.jsonValue(blocks) {
                        try RecipeContinuationRuntime.save(
                            messageID: requestOptions.localContinuationMessageID, recipe: continuationRecipe,
                            state: ["blocks": encoded]
                        )
                    }
                    let breakdown = Self.parseUsage(lastUsage)
                    let (cost, source) = await MetadataClient.shared.calcCost(
                        breakdown: breakdown, modelID: modelID, providerKind: .gemini
                    )
                    let result = ProviderChatResult(
                        text: finalText,
                        promptTokens: breakdown.totalInputTokens,
                        completionTokens: breakdown.completionTokens,
                        estimatedCost: cost,
                        usageBreakdown: breakdown,
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

    func sendMessageStream(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        baseURL: String,
        reasoningMode: ReasoningMode = .automatic,
        webSearchEnabled: Bool = false,
        supportsImageGen: Bool = false,
        requestOptions: ChatRequestOptions = ChatRequestOptions(),
        relayRequested: RelayRequestedConfig? = nil
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try self.validateAPIKey(apiKey)
                    guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw ProviderServiceError.invalidConfiguration(detail: "Missing model identifier.")
                    }

                    // When a relay rejects a native file block before the first event, resend once with the files injected as text (NativeFileFallback).
                    let (request, bytes, response) = try await NativeFileFallback.run(
                        .relayScope(.geminiGenerateContent, connectionID: requestOptions.attachmentConnectionID, modelID: requestOptions.capabilityEvidenceModel?.id, fileOverride: requestOptions.capabilityEvidenceModel?.relayCapabilityOverrides?.file)
                    ) {
                        let request = try self.buildRelayGenerateContentRequest(
                            modelID: modelID,
                            messages: messages,
                            apiKey: apiKey,
                            baseURL: baseURL,
                            stream: true,
                            reasoningMode: reasoningMode,
                            webSearchEnabled: webSearchEnabled,
                            supportsImageGen: supportsImageGen,
                            requestOptions: requestOptions,
                            relayRequested: relayRequested
                        )
                        let (bytes, response) = try await self.bytesWithUnsupportedParamSelfHeal(
                            providerKind: .relay,
                            modelID: modelID,
                            request: request,
                            effectiveTransport: RelayTransport.geminiGenerateContent.rawValue,
                            relayEngineProfile: relayRequested?.engineProfile,
                            relayDeclaredProfile: requestOptions.generationProfile
                        )
                        return (request, bytes, response)
                    }

                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw ProviderServiceError.network(detail: "Missing HTTPURLResponse.")
                    }

                    guard (200 ..< 300).contains(httpResponse.statusCode) else {
                        var errorData = Data()
                        for try await byte in bytes { errorData.append(byte) }
                        throw self.mapHTTPError(statusCode: httpResponse.statusCode, data: errorData)
                    }

                    var accumulatedText = ""
                    var lastUsage: GeminiUsageMetadata?
                    // The citation profile is derived from the web fragment merged into this turn.
                    let relayStrategy = TransportRegistry.strategy(for: .geminiGenerate)
                    let relayShape = MetadataClient.shared.syncWebSearchStreamShape(
                        profileName: requestOptions.officialForeignRoute
                            // An official provider's foreign-protocol route behaves as before: citations are parsed by the profile the catalog matches.
                            ? MetadataClient.shared.syncResolveCatalogModel(modelID: modelID, providerKind: .gemini)?.profiles.webSearch
                            : RelayWebFragments.citationProfile(
                                transport: .geminiGenerateContent,
                                fragment: requestOptions.relayWebFragments?.object(for: .geminiGenerateContent)
                            )
                    )
                    var relayCtx = StreamContext()
                    var relayLastCitationsCount = 0
                    var bodyStartChecked = false
                    var finishTracker = StreamFinishTracker(family: .gemini)

                    for try await line in bytes.utf8Lines {
                        if Task.isCancelled { break }
                        // A fallback web page's Content-Type is not always html: recognize it once more on the first body line, before any output.
                        try self.rejectRelayWebPageStreamStart(httpResponse, line: line, settled: &bodyStartChecked)

                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        guard let jsonData = payload.data(using: .utf8) else { continue }

                        let chunk: GeminiGenerateContentResponse
                        do {
                            chunk = try self.decoder.decode(
                                GeminiGenerateContentResponse.self, from: jsonData
                            )
                        } catch {
                            continue
                        }

                        finishTracker.observeFrame(jsonData)
                        // A blocked finishReason / promptFeedback.blockReason throws on the next line: hand out the finish first.
                        if Self.isBlockedFinishChunk(chunk) || Self.isBlockedPromptChunk(chunk) {
                            continuation.yield(.finish(finishTracker.finish()))
                        }
                        // A blocked termination must throw so the error card is shown; the partial text already emitted is kept by the upper Failed path
                        try Self.throwIfBlockedChunk(chunk)

                        if let usage = chunk.usageMetadata {
                            lastUsage = usage
                        }

                        let chunkText = chunk.resolvedText
                        if !chunkText.isEmpty {
                            accumulatedText += chunkText
                            continuation.yield(.delta(chunkText))
                        }

                        for att in chunk.resolvedAttachments {
                            continuation.yield(.imagePart(att))
                        }

                        for ev in relayStrategy.parseStreamLine(payload, ctx: &relayCtx, shape: relayShape) {
                            switch ev {
                            case .reasoning, .toolCallDeltas: continuation.yield(ev)
                            default: break
                            }
                        }
                        let citationsSnapshot = relayCtx.citationsAccumulator.citations
                        if citationsSnapshot.count > relayLastCitationsCount {
                            relayLastCitationsCount = citationsSnapshot.count
                            continuation.yield(.citations(citationsSnapshot))
                        }
                    }
                    for ev in GeminiGenerateStrategy.flushToolCalls(ctx: &relayCtx) { continuation.yield(ev) }

                    let finalText = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let breakdown = Self.parseUsage(lastUsage)
                    let (cost, source) = await MetadataClient.shared.calcCost(
                        breakdown: breakdown, modelID: modelID, providerKind: .gemini
                    )
                    let result = ProviderChatResult(
                        text: finalText,
                        promptTokens: breakdown.totalInputTokens,
                        completionTokens: breakdown.completionTokens,
                        estimatedCost: cost,
                        usageBreakdown: breakdown,
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

    // MARK: - Gemini Interactions (`/interactions`, path from recipe)

    /// Attachment tier: preActivation = what the route currently declares (images become a placeholder, files arrive as text), always used in production;
    /// activated = typed image / document tiers promoted only after a real provider verification, passed in by tests only for now.
    enum InteractionsAttachmentProfile { case preActivation, activated }

    /// The recipe's route.path accepts only these two; anything else is a configuration error and is not built and tried.
    private static let interactionsPaths: Set<String> = ["/v1/interactions", "/v1beta/interactions"]

    /// Split-parameter builder: the route comes from the endpoint_route recipe; when web search is off no web recipe is passed;
    /// the reasoning recipe goes through the generic compiler (last-specific-wins), and the automatic level also compiles with selectedIntent=nil,
    /// landing only the base op that has no intent. Every turn sends the full Step[], never previous_interaction_id, and store is always false.
    func buildInteractionsRequest(
        modelID: String, messages: [ChatMessage], apiKey: String, stream: Bool,
        route: MetadataClient.CapabilityRecipeRoute,
        webRecipe: MetadataClient.CapabilityRecipe?,
        reasoningRecipe: MetadataClient.CapabilityRecipe? = nil,
        reasoningIntent: String? = nil,
        reasoningAvailableIntents: [String]? = nil,
        attachmentProfile: InteractionsAttachmentProfile = .preActivation,
        systemPrompt: String = "",
        safeCustomBodyFragments: [SafeCustomBodyFragment] = [],
        additionalRequestBody: AdditionalRequestBodyPayload? = nil,
        capabilityEvidenceModel: AIModel? = nil,
        dynamicText: String? = nil
    ) throws -> URLRequest {
        try validateAPIKey(apiKey)
        guard route.protocolName == "gemini_interactions",
              route.endpointClass == "interactions",
              route.requestMapper == "gemini_interactions_v1",
              Self.interactionsPaths.contains(route.path) else {
            throw ProviderServiceError.invalidConfiguration(detail: "Invalid Gemini Interactions route.")
        }
        guard var endpoint = URLComponents(string: baseURL) else {
            throw ProviderServiceError.invalidConfiguration(detail: "Invalid Gemini Interactions endpoint.")
        }
        // The generateContent base ends in `/v1beta`; the Interactions path carries its own version segment, so the base's version segment is removed first.
        var basePath = endpoint.path
        for suffix in ["/v1beta", "/v1"] where basePath.hasSuffix(suffix) {
            basePath.removeLast(suffix.count)
            break
        }
        endpoint.path = basePath + route.path
        endpoint.query = nil
        endpoint.fragment = nil
        guard let url = endpoint.url else {
            throw ProviderServiceError.invalidConfiguration(detail: "Invalid Gemini Interactions endpoint.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = stream ? 120 : 60
        applyHeaders(to: &request, apiKey: apiKey)
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        var body: [String: Any] = [
            "model": modelID,
            "stream": stream,
            "store": false,
            // An assistant turn whose body is empty after trimming (failed or interrupted before any text was written) does not replay an empty model_output; the user turns before and after it each become their own step.
            "input": try AttachmentDelivery.mapTurns(
                messages.filter { $0.role == .user || !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                isChatSend: capabilityEvidenceModel != nil,
                dynamicText: dynamicText
            ) { message, isOutgoingTurn in
                // The assistant replays only the body text, never thoughts or signatures.
                guard message.role == .user else {
                    return ["type": "model_output", "content": [["type": "text", "text": message.text]]]
                }
                return [
                    "type": "user_input",
                    "content": try Self.interactionsUserContent(
                        message, isOutgoingTurn: isOutgoingTurn, profile: attachmentProfile, model: capabilityEvidenceModel
                    ),
                ]
            },
        ]
        let trimmedSystem = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSystem.isEmpty {
            body["system_instruction"] = trimmedSystem
        }
        for (recipe, capability, intent, intents) in [
            (webRecipe, "web", nil as String?, nil as [String]?),
            (reasoningRecipe, "reasoning", reasoningIntent, reasoningAvailableIntents),
        ] {
            guard let recipe else { continue }
            let compilation = CapabilityRecipeRequestCompiler.compile(
                recipe: recipe, to: &body, providerKind: "gemini", transport: "gemini_interactions",
                capability: capability, selectedIntent: intent, availableIntents: intents
            )
            guard compilation.applied else {
                throw ProviderServiceError.invalidConfiguration(
                    detail: "Gemini Interactions \(capability) recipe rejected: \(compilation.reason ?? "unknown")"
                )
            }
            CapabilityRecipeRequestCompiler.recordBuilderOwnedDelta(
                recipe: recipe, providerKind: .gemini, modelID: modelID, transport: "gemini_interactions",
                deltaRootKeys: Set(compilation.redactedPreview.keys)
            )
        }
        // `redactedPreview` is audit-only. The inout body above is the sole production wire.
        try CapabilityRecipeExecution.applySafeCustomFragments(
            safeCustomBodyFragments, to: &body,
            providerKind: .gemini, modelID: modelID, transport: "gemini_interactions"
        )
        try AdditionalRequestBody.apply(additionalRequestBody, to: &body)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        // This is the final wire boundary of this chat request; a builder that does not go through
        // BaseAPIService.encodeChatBody must confirm it itself, otherwise the "requested" fact is never
        // established (`requested` is recorded by confirmRequestDispatched only after finalWireEncoded).
        CapabilityExecutionRuntime.confirmFinalWireEncoded()
        return request
    }

    /// The content of one user turn: within the turn, text comes first and media after.
    /// preActivation uses the route's existing delivery (images become a placeholder, files become xml-v1 text), and no media bytes enter the body.
    private static func interactionsUserContent(
        _ message: ChatMessage, isOutgoingTurn: Bool, profile: InteractionsAttachmentProfile, model: AIModel?
    ) throws -> [[String: Any]] {
        let attachments = message.attachments ?? []
        switch profile {
        case .preActivation:
            let text = try AttachmentDelivery.deliver(
                isOutgoingTurn: isOutgoingTurn, userText: message.text, attachments: attachments,
                transport: .geminiInteractions, model: model
            ).injectedText
            return [["type": "text", "text": text]]
        case .activated:
            var content: [[String: Any]] = message.text.isEmpty ? [] : [["type": "text", "text": message.text]]
            for attachment in attachments {
                switch attachment.kind {
                case .image:
                    let b64 = attachment.resolvedBase64Data
                    content.append(["type": "image", "data": b64, "mime_type": ImageMediaType.resolve(base64: b64, declared: attachment.mimeType)])
                case .file:
                    content.append([
                        "type": "document",
                        "data": attachment.originalBase64Data ?? attachment.resolvedBase64Data,
                        "mime_type": attachment.mimeType,
                    ])
                case .video:
                    continue
                }
            }
            return content
        }
    }

    /// Whether this turn goes through Interactions: only when web search is on, the catalog recipe points this model's web search at that endpoint,
    /// and the whole request history (including this turn) has no video attachment (video is delivered as generateContent inlineData).
    /// Streaming and non-streaming dispatch and the pre-send attachment route resolution read the same function.
    static func interactionsRecipe(
        modelID: String, webSearchEnabled: Bool, historyHasVideo: Bool
    ) -> MetadataClient.CapabilityRecipe? {
        guard webSearchEnabled, !historyHasVideo,
              let recipe = MetadataClient.shared.syncCapabilityRecipe(
                  modelID: modelID, providerKind: .gemini, capability: "web"
              ), recipe.executionKind == "endpoint_route",
              recipe.transport.protocolName == "gemini_interactions" else { return nil }
        return recipe
    }

    static func historyHasVideo(_ messages: [ChatMessage]) -> Bool {
        messages.contains { $0.attachments?.contains { $0.kind == .video } == true }
    }

    /// The production-side reasoning input: only a reasoning recipe issued by the server whose transport is gemini_interactions is accepted
    /// (generateContent's reasoning recipe is not borrowed); without one, no generation_config is sent.
    private static func interactionsReasoning(
        modelID: String, reasoningMode: ReasoningMode
    ) -> (recipe: MetadataClient.CapabilityRecipe, intent: String?, intents: [String]?)? {
        guard let recipe = MetadataClient.shared.syncCapabilityRecipe(
            modelID: modelID, providerKind: .gemini, capability: "reasoning"
        ), recipe.executionKind == "request_overlay",
              recipe.transport.protocolName == "gemini_interactions" else { return nil }
        let intents = MetadataClient.shared.syncCapabilityRecipeRuntime(
            modelID: modelID, providerKind: .gemini
        ).controls?["reasoning"]?.availableIntents
        return (recipe, reasoningMode.intentToken, intents)
    }

    private func buildProductionInteractionsRequest(
        modelID: String, messages: [ChatMessage], apiKey: String, stream: Bool,
        recipe: MetadataClient.CapabilityRecipe, reasoningMode: ReasoningMode, systemPrompt: String,
        safeCustomBodyFragments: [SafeCustomBodyFragment], additionalRequestBody: AdditionalRequestBodyPayload?,
        capabilityEvidenceModel: AIModel?, dynamicText: String?
    ) throws -> URLRequest {
        let reasoning = Self.interactionsReasoning(modelID: modelID, reasoningMode: reasoningMode)
        return try buildInteractionsRequest(
            modelID: modelID, messages: messages, apiKey: apiKey, stream: stream, recipe: recipe,
            reasoningRecipe: reasoning?.recipe, reasoningIntent: reasoning?.intent,
            reasoningAvailableIntents: reasoning?.intents,
            systemPrompt: systemPrompt, safeCustomBodyFragments: safeCustomBodyFragments,
            additionalRequestBody: additionalRequestBody, capabilityEvidenceModel: capabilityEvidenceModel,
            dynamicText: dynamicText
        )
    }

    private func sendInteractions(
        apiKey: String, modelID: String, messages: [ChatMessage], stream: Bool,
        recipe: MetadataClient.CapabilityRecipe, reasoningMode: ReasoningMode, systemPrompt: String,
        safeCustomBodyFragments: [SafeCustomBodyFragment], additionalRequestBody: AdditionalRequestBodyPayload?,
        capabilityEvidenceModel: AIModel?, dynamicText: String?
    ) async throws -> ProviderChatResult {
        let request = try buildProductionInteractionsRequest(
            modelID: modelID, messages: messages, apiKey: apiKey, stream: stream, recipe: recipe,
            reasoningMode: reasoningMode, systemPrompt: systemPrompt, safeCustomBodyFragments: safeCustomBodyFragments,
            additionalRequestBody: additionalRequestBody, capabilityEvidenceModel: capabilityEvidenceModel,
            dynamicText: dynamicText
        )
        // This route uses the session directly, bypassing BaseAPIService's send wrapper, so it records the requested fact itself.
        CapabilityExecutionRuntime.confirmRequestDispatched()
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderServiceError.network(detail: "Missing HTTPURLResponse.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw mapHTTPError(statusCode: http.statusCode, data: data)
        }
        let text = Self.interactionsText(from: data).trimmingCharacters(in: .whitespacesAndNewlines)
        let webEvidence = Self.interactionsWebEvidence(from: data)
        if webEvidence.searchExecuted {
            CapabilityExecutionRuntime.recordParserEvent(.toolResult, nonEmpty: true)
        }
        // The root of a non-streaming response is the Interaction resource itself: it gets the same terminal-state judgment and usage as the streaming interaction.completed.
        var terminal = InteractionsStreamParser(redacting: [apiKey], receivedText: text)
        try terminal.consumeInteraction((try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
        try terminal.finish()
        guard !text.isEmpty else { throw ProviderServiceError.emptyResponse }
        let breakdown = terminal.usage?.breakdown ?? UsageBreakdown()
        let (cost, source) = await MetadataClient.shared.calcCost(
            breakdown: breakdown, modelID: modelID, providerKind: .gemini
        )
        return ProviderChatResult(text: text, promptTokens: breakdown.totalInputTokens,
                                  completionTokens: breakdown.completionTokens,
                                  estimatedCost: cost, usageBreakdown: breakdown, costSource: source,
                                  citations: webEvidence.citations.isEmpty ? nil : webEvidence.citations)
    }

    private func streamInteractions(
        apiKey: String, modelID: String, messages: [ChatMessage], recipe: MetadataClient.CapabilityRecipe,
        reasoningMode: ReasoningMode, systemPrompt: String, safeCustomBodyFragments: [SafeCustomBodyFragment],
        additionalRequestBody: AdditionalRequestBodyPayload?,
        capabilityEvidenceModel: AIModel?, dynamicText: String?,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        let request = try buildProductionInteractionsRequest(
            modelID: modelID, messages: messages, apiKey: apiKey, stream: true, recipe: recipe,
            reasoningMode: reasoningMode, systemPrompt: systemPrompt, safeCustomBodyFragments: safeCustomBodyFragments,
            additionalRequestBody: additionalRequestBody, capabilityEvidenceModel: capabilityEvidenceModel,
            dynamicText: dynamicText
        )
        // Same as above: this route confirms the dispatch itself because it uses the session directly.
        CapabilityExecutionRuntime.confirmRequestDispatched()
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderServiceError.network(detail: "Missing HTTPURLResponse.")
        }
        guard (200..<300).contains(http.statusCode) else {
            var data = Data(); for try await byte in bytes { data.append(byte) }
            throw mapHTTPError(statusCode: http.statusCode, data: data)
        }
        var parser = InteractionsStreamParser(redacting: [apiKey])
        guard let finish = try await Self.pumpInteractions(
            lines: bytes.utf8Lines, parser: &parser, continuation: continuation
        ) else { return }
        let breakdown = parser.usage?.breakdown ?? UsageBreakdown()
        let (cost, source) = await MetadataClient.shared.calcCost(
            breakdown: breakdown, modelID: modelID, providerKind: .gemini
        )
        continuation.yield(.done(ProviderChatResult(
            text: parser.text.trimmingCharacters(in: .whitespacesAndNewlines),
            promptTokens: breakdown.totalInputTokens, completionTokens: breakdown.completionTokens,
            estimatedCost: cost, usageBreakdown: breakdown, costSource: source,
            // Reaching here means an interaction terminal state was seen (otherwise finish() has already thrown for the cut stream).
            finish: finish
        )))
    }

    /// Feed the Interactions parser line by line and hand out the finish (family gemini_interactions, finishRaw = terminal status).
    /// failed / requires_action / cancelled still throw from the parser as before, and (clean, status) is handed out before throwing;
    /// a stream cut without a terminal state hands out an eof-type finish first and then throws. Returns the finish that done carries on a normal ending; returns nil when the user cancels.
    static func pumpInteractions<Lines: AsyncSequence>(
        lines: Lines, parser: inout InteractionsStreamParser,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws -> StreamFinish? where Lines.Element == String {
        var finishTracker = StreamFinishTracker(family: .geminiInteractions)
        for try await line in lines {
            // A user cancellation goes through the existing cancel wrap-up in ChatManager and skips the terminal-state judgment.
            guard !Task.isCancelled else { return nil }
            if let data = BaseAPIService.sseDataPayload(line) { finishTracker.observeFrame(data) }
            let events: [StreamEvent]
            do {
                events = try parser.consume(line: line)
            } catch {
                // Terminal states failed / requires_action / cancelled throw here: hand out the finish first (the error frame does not carry one).
                if finishTracker.sawMarker { continuation.yield(.finish(finishTracker.finish())) }
                throw error
            }
            for event in events { continuation.yield(event) }
        }
        guard !Task.isCancelled else { return nil }
        let finish = finishTracker.finish()
        // The stream was cut without an interaction terminal state: parser.finish() will throw, so hand out an eof-type finish first.
        if !finishTracker.sawMarker { continuation.yield(.finish(finish)) }
        try parser.finish()
        return finish
    }

    /// The three totals of `interaction.usage` (official Interactions API reference).
    struct InteractionsUsage: Equatable {
        var inputTokens: Int
        var cachedTokens: Int
        var outputTokens: Int
        var thoughtTokens: Int

        init?(_ raw: Any?) {
            guard let usage = raw as? [String: Any] else { return nil }
            inputTokens = usage["total_input_tokens"] as? Int ?? 0
            cachedTokens = usage["total_cached_tokens"] as? Int ?? 0
            outputTokens = usage["total_output_tokens"] as? Int ?? 0
            thoughtTokens = usage["total_thought_tokens"] as? Int ?? 0
        }

        /// The same criterion as generateContent's parseUsage: output and thought are two independent items, and completion is their sum.
        var breakdown: UsageBreakdown {
            UsageBreakdown(
                promptTokens: max(0, inputTokens - cachedTokens),
                cachedInputTokens: cachedTokens,
                completionTokens: outputTokens + thoughtTokens,
                reasoningTokens: thoughtTokens,
                cacheReadObserved: cachedTokens > 0
            )
        }
    }

    /// The production parser of the Interactions SSE stream. Lines are fed in one at a time and dispatched on `data.event_type`;
    /// `event:` lines and `[DONE]` are not parsed. Terminal states: completed / incomplete finish normally (incomplete is handled like
    /// generateContent's MAX_TOKENS); an error frame, status=failed / requires_action / cancelled, or a stream that ends without
    /// interaction.completed all throw an upstream error. When text or thinking has already arrived, the caller marks the message failed and keeps what was received.
    struct InteractionsStreamParser {
        private(set) var text = ""
        private(set) var thinking = ""
        private(set) var searchEvidenceCount = 0
        private(set) var usage: InteractionsUsage?
        private var citations = CitationAccumulator()
        private var completed = false
        /// The raw Interaction terminal state received (completed / incomplete), used as the finishRaw of StreamFinish.
        private(set) var terminalStatus: String?
        private let credentials: [String]

        init(redacting credentials: [String] = [], receivedText: String = "") {
            self.credentials = credentials
            self.text = receivedText
        }

        private var beforeAnyContent: Bool { text.isEmpty && thinking.isEmpty }

        mutating func consume(line: String) throws -> [StreamEvent] {
            guard let data = BaseAPIService.sseDataPayload(line),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
            switch object["event_type"] as? String {
            case "step.delta":
                return consumeDelta(object["delta"] as? [String: Any] ?? [:])
            case "interaction.completed":
                try consumeInteraction(object["interaction"] as? [String: Any] ?? [:])
                return []
            case "error":
                let error = object["error"] as? [String: Any] ?? [:]
                throw streamError(
                    code: (error["code"] as? String) ?? "interaction_error",
                    message: error["message"] as? String
                )
            case "interaction.created", "interaction.status_update", "step.start", "step.stop":
                return []
            default:
                #if DEBUG
                print("[GeminiInteractions] ignoring unknown event_type: \(object["event_type"] ?? "nil")")
                #endif
                return []
            }
        }

        /// The terminal state of an Interaction resource (shared by streaming interaction.completed and the non-streaming root object).
        mutating func consumeInteraction(_ interaction: [String: Any]) throws {
            let status = interaction["status"] as? String
            switch status {
            case "completed", "incomplete":
                completed = true
                terminalStatus = status
                usage = InteractionsUsage(interaction["usage"])
            case "failed":
                throw streamError(code: "interaction_failed", message: nil)
            case "requires_action":
                throw streamError(code: "interaction_requires_action", message: nil)
            case "cancelled":
                throw streamError(code: "interaction_cancelled", message: nil)
            default:
                // A status with no terminal meaning does not count as completion; at wrap-up it is handled as interaction_stream_closed.
                break
            }
        }

        /// Called when the connection closes: a stream with neither interaction.completed nor an error is treated as interrupted (an upstream error).
        mutating func finish() throws {
            guard completed else { throw streamError(code: "interaction_stream_closed", message: nil) }
        }

        private mutating func consumeDelta(_ delta: [String: Any]) -> [StreamEvent] {
            switch delta["type"] as? String {
            case "text":
                guard let chunk = delta["text"] as? String, !chunk.isEmpty else { return [] }
                text += chunk
                return [.delta(chunk)]
            case "thought_summary":
                guard let chunk = (delta["content"] as? [String: Any])?["text"] as? String, !chunk.isEmpty else { return [] }
                thinking += chunk
                return [.reasoning(chunk)]
            case "text_annotation_delta":
                let incoming = GeminiService.interactionsURLCitations(delta["annotations"])
                guard !incoming.isEmpty else { return [] }
                let before = citations.citations
                citations.ingest(incoming)
                return citations.citations == before ? [] : [.citations(citations.citations)]
            case "google_search_result":
                // The official stream samples carry no result: anything whose is_error is not true counts as one piece of evidence.
                guard delta["is_error"] as? Bool != true else { return [] }
                searchEvidenceCount += 1
                CapabilityExecutionRuntime.recordParserEvent(.toolResult, nonEmpty: true)
                return []
            case "thought_signature", "google_search_call":
                return []
            default:
                #if DEBUG
                print("[GeminiInteractions] ignoring unknown delta.type: \(delta["type"] ?? "nil")")
                #endif
                return []
            }
        }

        /// The code is a string (an official URI-style identifier or an interaction_* synthesized by this client) and is also written into the technical details.
        private func streamError(code: String, message: String?) -> ProviderServiceError {
            let upstream = message.flatMap { $0.isEmpty ? nil : $0 }
                .map { RelayErrorSnippet.truncate(RelayRequestSecurity.redactingCredentials($0, credentials: credentials), maxBytes: 2048) }
            let detail = upstream.map { "\(code): \($0)" } ?? "Gemini Interactions stream ended with \(code)."
            let error = BaseAPIService.mapStreamError(type: code, message: detail)
            if beforeAnyContent, case .upstream = error {
                CapabilityExecutionRuntime.recordStreamRejectionBeforeEvents()
            }
            return error
        }
    }

    /// Interactions keeps text under completed `steps` for non-streaming responses. Keep the parser
    /// structurally narrow: only semantic `text` fields under model_output steps are surfaced,
    /// never IDs, signatures, or arbitrary metadata.
    private static func interactionsText(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        func texts(_ value: Any) -> [String] {
            if let string = value as? String { return [string] }
            if let array = value as? [Any] { return array.flatMap(texts) }
            guard let dictionary = value as? [String: Any] else { return [] }
            var result: [String] = []
            if let text = dictionary["text"] as? String { result.append(text) }
            for key in ["content", "parts", "delta", "output"] {
                if let nested = dictionary[key] { result.append(contentsOf: texts(nested)) }
            }
            return result
        }
        if let steps = object["steps"] as? [[String: Any]] {
            return steps.compactMap { step -> String? in
                guard step["type"] as? String == "model_output" else { return nil }
                if let content = step["content"] { return texts(content).joined() }
                if let output = step["output"] { return texts(output).joined() }
                return nil
            }.joined()
        }
        return ""
    }

    struct InteractionsWebEvidence {
        var citations: [Citation] = []
        var searchExecuted = false
    }

    /// An annotation of `type: "url_citation"` with `{url, title, start_index, end_index}`;
    /// other annotation types (file / place) are not web sources. The indexes are passed through as they are, and the client does not slice by them.
    static func interactionsURLCitations(_ value: Any?) -> [Citation] {
        ((value as? [[String: Any]]) ?? []).compactMap { annotation in
            guard annotation["type"] as? String == "url_citation",
                  let url = annotation["url"] as? String,
                  !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return Citation(
                url: url, title: annotation["title"] as? String, snippet: nil, faviconUrl: nil, index: nil,
                startIndex: annotation["start_index"] as? Int, endIndex: annotation["end_index"] as? Int
            )
        }
    }

    /// Web evidence of a non-streaming Interaction (official Interactions API reference), found in the completed `steps`:
    /// - a `google_search_result` whose `is_error` is not true means the search ran (`result` may be absent);
    /// - a url_citation in the annotations of a model_output body is a source.
    static func interactionsWebEvidence(from data: Data) -> InteractionsWebEvidence {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .init() }
        var evidence = InteractionsWebEvidence()
        func collectURLCitations(_ value: Any) {
            if let array = value as? [Any] { array.forEach(collectURLCitations); return }
            guard let dictionary = value as? [String: Any] else { return }
            evidence.citations.append(contentsOf: interactionsURLCitations(dictionary["annotations"]))
            for key in ["content", "parts", "output"] {
                if let nested = dictionary[key] { collectURLCitations(nested) }
            }
        }
        for step in (object["steps"] as? [[String: Any]]) ?? [] {
            if step["type"] as? String == "google_search_result", step["is_error"] as? Bool != true {
                evidence.searchExecuted = true
            }
            if step["type"] as? String == "model_output" { collectURLCitations(step) }
        }
        return evidence
    }

    /// Preserve the exact model content block supplied by Gemini, including a part's opaque
    /// thoughtSignature. Re-encoding through the app's text DTO would silently discard it and
    /// make an explicit follow-up invalid for models that require the signature.
    private static func geminiReplayBlocks(from data: Data) -> [[String: Any]]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = object["candidates"] as? [[String: Any]] else { return nil }
        let blocks = candidates.compactMap { candidate -> [String: Any]? in
            guard var content = candidate["content"] as? [String: Any] else { return nil }
            content["role"] = (content["role"] as? String) ?? "model"
            return content
        }
        return blocks.isEmpty ? nil : blocks
    }


    private static let blockedFinishReasons: Set<String> = [
        "SAFETY", "RECITATION", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII",
    ]

    /// Gemini reports content blocking in fields inside an HTTP 200 stream rather than as an HTTP error:
    ///   - top-level `error`: an error in the middle of the stream (quota exhausted midway, etc.); the protocol cuts the stream right after it is sent;
    ///   - `promptFeedback.blockReason`: the prompt is rejected as a whole, usually with no candidates and zero output throughout;
    ///   - `candidates[].finishReason ∈ blockedFinishReasons`: generation is cut off midway by the content policy.
    /// If none of them throws, the user only sees an empty response or a truncated reply with no error card or retry entry (while still being billed).
    /// The type is upstream(200): the stream already returned 2xx and no finer HTTP status is available, consistent with Android Upstream(200).
    /// Keeping the partial text already emitted in the upper Failed path is expected.
    /// This frame throws because of a blocked finishReason (frames where a top-level error / blockReason throws first do not count).
    private static func isBlockedFinishChunk(_ chunk: GeminiGenerateContentResponse) -> Bool {
        let errorMessage = chunk.error?.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errorStatus = chunk.error?.status?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let blockReason = chunk.promptFeedback?.blockReason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard errorMessage.isEmpty, errorStatus.isEmpty, blockReason.isEmpty,
              let finishReason = chunk.candidates?.first?.finishReason else { return false }
        return blockedFinishReasons.contains(finishReason)
    }

    /// This frame throws because of promptFeedback.blockReason (frames where a top-level error throws first do not count).
    private static func isBlockedPromptChunk(_ chunk: GeminiGenerateContentResponse) -> Bool {
        let errorMessage = chunk.error?.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errorStatus = chunk.error?.status?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let blockReason = chunk.promptFeedback?.blockReason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return errorMessage.isEmpty && errorStatus.isEmpty && !blockReason.isEmpty
    }

    private static func throwIfBlockedChunk(_ chunk: GeminiGenerateContentResponse) throws {
        if let error = chunk.error {
            let message = error.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let status = error.status?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !message.isEmpty || !status.isEmpty {
                let detail: String
                if !status.isEmpty, !message.isEmpty {
                    detail = "[\(status)] \(message)"
                } else {
                    detail = message.isEmpty ? status : message
                }
                throw ProviderServiceError.upstream(
                    statusCode: 200,
                    detail: "Gemini stream error: \(detail)"
                )
            }
        }
        if let blockReason = chunk.promptFeedback?.blockReason?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !blockReason.isEmpty {
            throw ProviderServiceError.upstream(
                statusCode: 200,
                detail: "Gemini blocked the prompt (blockReason=\(blockReason))."
            )
        }
        if let finishReason = chunk.candidates?.first?.finishReason,
           blockedFinishReasons.contains(finishReason) {
            throw ProviderServiceError.upstream(
                statusCode: 200,
                detail: "Gemini stopped the response (finishReason=\(finishReason))."
            )
        }
    }


    override func mapHTTPError(
        statusCode: Int,
        data: Data,
        url: URL? = nil,
        request: URLRequest? = nil,
        subscriptionLane: SubscriptionLane? = nil,
        isRelay: Bool = false,
        relayTransport: RelayTransport? = nil
    ) -> ProviderServiceError {
        let detail = decodeErrorMessage(from: data, request: request)
            ?? HTTPURLResponse.localizedString(forStatusCode: statusCode)
        if statusCode == 400, detail.lowercased().contains("api key") {
            // Early return skips the base class: record the status and body here (overflow recognition reads it).
            ChatFailureDiagnostics.recordHTTPFailure(statusCode: statusCode, body: data)
            return .invalidAPIKey(detail: detail)
        }
        return super.mapHTTPError(
            statusCode: statusCode, data: data, url: url, request: request,
            isRelay: isRelay, relayTransport: relayTransport
        )
    }


    private func buildGenerateContentRequest(
        modelID: String, messages: [ChatMessage], apiKey: String, stream: Bool,
        reasoningMode: ReasoningMode, webSearchEnabled: Bool,
        supportsImageGen: Bool,
        requestOptions: ChatRequestOptions = ChatRequestOptions(),
        droppedParams: Set<String> = []
    ) throws -> URLRequest {
        let endpoint = stream ? "streamGenerateContent" : "generateContent"
        let metadataTransport = MetadataClient.shared.syncProviderTransport(providerKind: .gemini)
        let metadataBase = EndpointResolver.officialMetadataBaseURL(
            providerKind: .gemini,
            metadataTransport: metadataTransport
        )
        let endpointBase = metadataBase ?? EndpointResolver.fallbackBaseURL(for: .gemini)
        let modelsPath = metadataTransport?.endpoints?.chat
            ?? EndpointResolver.fallbackEndpointPath(.gemini, kind: .chat)
        guard let modelsURL = EndpointResolver.joinURL(base: endpointBase, path: modelsPath) else {
            throw ProviderServiceError.invalidConfiguration(detail: "Invalid Gemini endpoint.")
        }
        var urlString = "\(modelsURL.absoluteString)/\(modelID):\(endpoint)"
        if stream {
            urlString += "?alt=sse"
        }

        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "POST"
        request.timeoutInterval = stream ? 120 : 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        let resolved = MetadataClient.shared.syncResolveCatalogModel(modelID: modelID, providerKind: .gemini)
        // Decide by the route actually used this turn: when the model's transport is judged gemini_interactions but this turn did not
        // select Interactions, what goes out is still generateContent, so a recipe whose protocol is gemini_interactions does not enter the body
        // and is not recorded as requested, because the route does not match.
        let wireTransport = resolved?.transport == "gemini_interactions"
            ? "gemini_generate_content" : resolved?.transport
        let recipeLegacyInput = CapabilityRecipeRequestCompiler.legacyInput(
            providerKind: .gemini, modelID: modelID,
            webSearchEnabled: webSearchEnabled, reasoningMode: reasoningMode
        )
        let capabilityIntent = CapabilityEvidenceProductionAdapter.finalChatIntent(
            messages: messages, request: request,
            effectiveTransport: wireTransport ?? "",
            model: requestOptions.capabilityEvidenceModel,
            // Image-generation requests remain on their separate legacy image contract until
            // that contract is versioned; only makes text-chat model controls runtime-owned.
            requestedReasoningMode: supportsImageGen ? reasoningMode : recipeLegacyInput.reasoningMode,
            webSearchEnabled: supportsImageGen ? webSearchEnabled : recipeLegacyInput.webSearchEnabled
        )
        let contents = try AttachmentDelivery.mapTurns(capabilityIntent.outboundMessages, isChatSend: requestOptions.capabilityEvidenceModel != nil, dynamicText: requestOptions.dynamicText) { try Self.buildContent($0, transport: .geminiGenerateContent, model: requestOptions.capabilityEvidenceModel, isOutgoingTurn: $1) }
        // Only image models send responseModalities (TEXT+IMAGE, with the same value as a fallback in the imageGen profile below);
        // non-image models do not send it and are driven by the metadata profile (aligned with web: text models carry no responseModalities).
        let modalities: [String]? = supportsImageGen ? ["TEXT", "IMAGE"] : nil
        let config = GeminiGenerateContentRequest.GenerationConfig(
            responseModalities: modalities,
            thinkingConfig: nil
        )
        let systemPrompt = requestOptions.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let systemInstruction: GeminiGenerateContentRequest.SystemInstruction? = systemPrompt.isEmpty ? nil : .init(parts: [.init(text: systemPrompt)])
        let payload = GeminiGenerateContentRequest(
            contents: contents,
            systemInstruction: systemInstruction,
            tools: nil,
            generationConfig: config
        )
        var body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any] ?? [:]
        let continuationRecipe = RecipeContinuationRuntime.selectedRecipe(
            provider: .gemini, modelID: modelID, transport: "gemini_generate_content",
            webSearchEnabled: webSearchEnabled, reasoningMode: reasoningMode,
            continuationKind: "replay_blocks", parser: { ["gemini_google_search_v1", "gemini_thinking_v1"].contains($0) }
        )
        if continuationRecipe != nil,
           let blocks = RecipeContinuationRuntime.replayBlocks(
                explicitMessageID: requestOptions.localExplicitContinuationMessageID
           ) {
            var contents = body["contents"] as? [[String: Any]] ?? []
            let insertAt: Int
            if let lastUser = contents.lastIndex(where: { $0["role"] as? String == "user" }) {
                var target = lastUser
                if target > 0, contents[target - 1]["role"] as? String == "model" {
                    contents.remove(at: target - 1)
                    target -= 1
                }
                insertAt = target
            } else {
                insertAt = contents.count
            }
            contents.insert(contentsOf: blocks, at: insertAt)
            body["contents"] = contents
        }
        if (supportsImageGen ? webSearchEnabled : capabilityIntent.webSearchEnabled),
           let webMerge = ProfileParamsResolver.webSearchMergeParams(
            providerKind: .gemini,
            modelID: modelID,
            profileName: resolved?.profiles.webSearch,
            droppedParams: droppedParams,
            allowLegacyProfile: supportsImageGen
           ) {
            ProfileParamsResolver.deepMerge(&body, webMerge)
        }
        if supportsImageGen,
           let imageMerge = ProfileParamsResolver.imageGenMergeParams(
            providerKind: .gemini,
            modelID: modelID,
            profileName: resolved?.profiles.imageGen,
            droppedParams: droppedParams
           ) {
            ProfileParamsResolver.deepMerge(&body, imageMerge)
        }
        if (recipeLegacyInput.usesLegacyMapping || supportsImageGen),
           let allowedReasoningMode = supportsImageGen ? reasoningMode : capabilityIntent.reasoningMode,
           let reasoningMerge = ProfileParamsResolver.reasoningMergeParams(
            providerKind: .gemini,
            modelID: modelID,
            reasoningMode: allowedReasoningMode,
            resolved: resolved,
            droppedParams: droppedParams,
            allowLegacyProfile: supportsImageGen
        ) {
            ProfileParamsResolver.deepMerge(&body, reasoningMerge)
        }
        try ClientToolsInjector.apply(to: &body, protocol: .geminiGenerate, options: requestOptions)
        ProfileParamsResolver.applyTemperatureGate(to: &body, resolved: resolved)
        ProfileParamsResolver.applyGenerationParameters(
            to: &body,
            options: requestOptions,
            profile: resolved?.generationProfile,
            finalRequest: request,
            effectiveTransport: wireTransport
        )
        CapabilityRecipeRequestCompiler.apply(
            to: &body, providerKind: .gemini, modelID: modelID,
            transport: wireTransport ?? "", webSearchEnabled: webSearchEnabled,
            reasoningMode: reasoningMode, capabilityPreferences: requestOptions.capabilityPreferences
        )
        try CapabilityRecipeExecution.applySafeCustomFragments(
            requestOptions.localSafeCustomBodyFragments, to: &body,
            providerKind: .gemini, modelID: modelID,
            transport: wireTransport ?? "gemini_generate_content"
        )
        try AdditionalRequestBody.apply(requestOptions.localAdditionalRequestBody, to: &body)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        CapabilityExecutionRuntime.confirmFinalWireEncoded()
        return request
    }

    /// The request for "Test capabilities": the same validation and builder as relay streaming chat (`stream: true`),
    /// with just two extra inputs, the output cap and function tools. It only builds the request and never sends it.
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
        try validateAPIKey(apiKey)
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderServiceError.invalidConfiguration(detail: "Missing model identifier.")
        }
        return try buildRelayGenerateContentRequest(
            modelID: modelID, messages: messages, apiKey: apiKey, baseURL: baseURL, stream: true,
            reasoningMode: .automatic, supportsImageGen: false, requestOptions: requestOptions, relayRequested: relayRequested,
            maxOutputTokens: maxOutputTokens, functionTools: functionTools, keepImageAttachments: true
        )
    }

    /// The two "Test capabilities" inputs; chat passes neither and its output is unchanged: `maxOutputTokens` is written to `generationConfig.maxOutputTokens`;
    /// when `functionTools` is passed, this request's `tools` contains only that one.
    func buildRelayGenerateContentRequest(
        modelID: String,
        messages: [ChatMessage],
        apiKey: String,
        baseURL: String,
        stream: Bool,
        reasoningMode: ReasoningMode,
        webSearchEnabled: Bool = false,
        supportsImageGen: Bool,
        requestOptions: ChatRequestOptions = ChatRequestOptions(),
        relayRequested: RelayRequestedConfig? = nil,
        droppedParams: Set<String> = [],
        maxOutputTokens: Int? = nil,
        functionTools: [Any]? = nil,
        keepImageAttachments: Bool = false
    ) throws -> URLRequest {
        let normalizedBase = try RelayEndpointResolver.runtimeAPIBaseURL(
            rawBaseURL: baseURL,
            relayRequested: relayRequested,
            defaultVersion: "v1beta",
            acceptedVersions: ["v1", "v1beta"]
        )
        let endpoint = stream ? "streamGenerateContent" : "generateContent"
        let path = "/models/\(modelID):\(endpoint)"
        // Pass the connection's security mode: it defaults to remoteHTTPS, under which a local http connection would be blocked as plaintext.
        let endpointURL = try RelayEndpointResolver.endpointURL(
            apiBaseURL: normalizedBase, endpointPath: path,
            securityMode: relayRequested?.securityMode ?? .remoteHTTPS
        )
        guard var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false) else {
            throw ProviderServiceError.invalidConfiguration(detail: "Invalid base URL: \(baseURL)")
        }

        var items = components.queryItems ?? []
        if stream {
            items.append(URLQueryItem(name: "alt", value: "sse"))
        }
        if resolveRelayAuthMode(relayRequested) == .queryKey {
            items.append(URLQueryItem(name: "key", value: apiKey))
        }
        for queryParam in relayRequested?.effectiveQueryParams ?? [] {
            items.append(URLQueryItem(name: queryParam.key, value: queryParam.value))
        }
        components.queryItems = items.isEmpty ? nil : items

        guard let url = components.url else {
            throw ProviderServiceError.invalidConfiguration(detail: "Invalid base URL: \(baseURL)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = stream ? 120 : 60
        applyRelayHeaders(to: &request, apiKey: apiKey, relayRequested: relayRequested)
        for header in relayRequested?.effectiveHeaders ?? [] {
            request.setValue(header.value, forHTTPHeaderField: header.key)
        }

        let capabilityIntent = CapabilityEvidenceProductionAdapter.finalChatIntent(
            messages: messages, request: request,
            effectiveTransport: RelayTransport.geminiGenerateContent.rawValue,
            model: requestOptions.capabilityEvidenceModel,
            requestedReasoningMode: reasoningMode,
            // Only an official provider's foreign-protocol route still expresses a web search intent; a relay's web search looks only at the connection-level fragment.
            webSearchEnabled: requestOptions.officialForeignRoute && webSearchEnabled,
            keepImageAttachments: keepImageAttachments
        )
        let contents = try AttachmentDelivery.mapTurns(capabilityIntent.outboundMessages, isChatSend: requestOptions.capabilityEvidenceModel != nil, dynamicText: requestOptions.dynamicText) { try Self.buildContent($0, transport: .relayGeminiGenerateContent, model: requestOptions.capabilityEvidenceModel, isOutgoingTurn: $1) }
        let modalities = supportsImageGen ? ["TEXT", "IMAGE"] : ["TEXT"]
        let shouldDropThinkingConfig = droppedParams.contains("thinking_config")
        let thinkingBudget = shouldDropThinkingConfig
            ? nil : capabilityIntent.reasoningMode.flatMap {
                Self.relayGeminiThinkingBudget($0, for: modelID)
            }
        let thinkingLevel = shouldDropThinkingConfig
            ? nil : capabilityIntent.reasoningMode.flatMap {
                Self.relayGeminiThinkingLevel($0, for: modelID)
            }
        let thinkingConfig = (thinkingBudget != nil || thinkingLevel != nil)
            ? GeminiGenerateContentRequest.GenerationConfig.ThinkingConfig(
                thinkingBudget: thinkingBudget,
                thinkingLevel: thinkingLevel
            )
            : nil
        let config = GeminiGenerateContentRequest.GenerationConfig(
            responseModalities: modalities,
            thinkingConfig: thinkingConfig,
            maxOutputTokens: maxOutputTokens
        )
        let systemPrompt = requestOptions.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let systemInstruction: GeminiGenerateContentRequest.SystemInstruction? = systemPrompt.isEmpty ? nil : .init(parts: [.init(text: systemPrompt)])
        let payload = GeminiGenerateContentRequest(
            contents: contents,
            systemInstruction: systemInstruction,
            // A relay no longer adds googleSearch automatically from the chat preference; it is merged below only when the connection stores a Gemini web fragment.
            // An official provider's foreign-protocol route keeps the original behavior.
            tools: Self.officialForeignGoogleSearch(requestOptions: requestOptions, webSearchEnabled: capabilityIntent.webSearchEnabled),
            generationConfig: config
        )
        var body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any] ?? [:]
        if let functionTools {
            body["tools"] = functionTools
        }
        try ClientToolsInjector.apply(to: &body, protocol: .geminiGenerate, options: requestOptions)
        ProfileParamsResolver.applyGenerationParameters(
            to: &body,
            options: requestOptions,
            finalRequest: request,
            effectiveTransport: RelayTransport.geminiGenerateContent.rawValue
        )
        // Relay web fragment: applied after the builder's output and before the additional request body.
        RelayWebFragments.apply(requestOptions.relayWebFragments, transport: .geminiGenerateContent, to: &body)
        ClientToolsInjector.moveHostMemoryToolsLast(in: &body)
        try AdditionalRequestBody.apply(requestOptions.localAdditionalRequestBody, to: &body)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        CapabilityExecutionRuntime.confirmFinalWireEncoded()
        return request
    }

    /// The googleSearch of an official provider's foreign-protocol route (the original relay builder behavior, kept only for official providers).
    private static func officialForeignGoogleSearch(
        requestOptions: ChatRequestOptions, webSearchEnabled: Bool
    ) -> [GeminiGenerateContentRequest.Tool]? {
        requestOptions.officialForeignRoute && webSearchEnabled ? [.init(googleSearch: .init())] : nil
    }

    private static func relayGeminiThinkingBudget(_ mode: ReasoningMode, for modelID: String) -> Int? {
        guard mode != .automatic, !relayUsesGeminiThinkingLevel(modelID) else { return nil }
        switch mode {
        case .automatic: return nil
        case .fast: return 1_024
        case .balanced: return 4_096
        case .deep: return 16_384
        case .max: return 24_576
        }
    }

    private static func relayGeminiThinkingLevel(_ mode: ReasoningMode, for modelID: String) -> String? {
        guard mode != .automatic, relayUsesGeminiThinkingLevel(modelID) else { return nil }
        switch mode {
        case .automatic: return nil
        case .fast: return "LOW"
        case .balanced: return "MEDIUM"
        case .deep, .max: return "HIGH"
        }
    }

    private static func relayUsesGeminiThinkingLevel(_ modelID: String) -> Bool {
        let lowered = modelID.lowercased()
        return lowered.contains("3.1") || lowered.contains("gemini-3") // heuristic-allow: Relay Gemini-compatible fallback only; official Gemini uses metadata profiles.
    }

    private func applyRelayHeaders(
        to request: inout URLRequest,
        apiKey: String,
        relayRequested: RelayRequestedConfig?
    ) {
        request.applyRelaySecurityMode(relayRequested)
        applyJSONHeaders(to: &request, includeAccept: false)
        switch resolveRelayAuthMode(relayRequested) {
        case .none:
            return
        case .xGoogApiKey, .auto:
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        case .xApiKey:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        case .bearer:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .queryKey:
            break
        }
        if let ua = relayRequested?.effectiveCustomUserAgent?.trimmingCharacters(in: .whitespacesAndNewlines),
           !ua.isEmpty {
            request.setValue(ua, forHTTPHeaderField: "User-Agent")
        }
    }

    private func resolveRelayAuthMode(_ relayRequested: RelayRequestedConfig?) -> RelayAuthMode {
        guard let relayRequested else { return .xGoogApiKey }
        if relayRequested.authMode != .auto {
            return relayRequested.authMode
        }
        return .xGoogApiKey
    }

    private static func versionedRelayBaseURL(
        _ rawBaseURL: String,
        defaultVersion: String,
        acceptedVersions: Set<String>
    ) -> String {
        let trimmed = rawBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        let baseString = normalized.hasPrefix("http") ? normalized : "https://\(normalized)"
        guard let url = URL(string: baseString) else { return baseString }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let segments = path.split(separator: "/").map(String.init)
        if segments.contains(where: acceptedVersions.contains) {
            return baseString
        }
        let versionedPath = path.isEmpty ? defaultVersion : "\(path)/\(defaultVersion)"
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path = "/" + versionedPath
        components?.query = nil
        components?.fragment = nil
        return components?.url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? "\(baseString)/\(defaultVersion)"
    }

    private static func buildContent(_ msg: ChatMessage, transport: AttachmentTransport, model: AIModel?, isOutgoingTurn: Bool) throws -> GeminiGenerateContentRequest.Content {
        let role = msg.role == .assistant ? "model" : "user"

        guard let atts = msg.attachments, !atts.isEmpty else {
            return .init(role: role, parts: [.init(text: msg.text)])
        }

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
        let injectedText = delivery.injectedText

        var parts: [GeminiGenerateContentRequest.Part] = [.init(text: injectedText)]
        for a in atts {
            switch a.kind {
            case .image:
                let b64 = a.resolvedBase64Data
                guard !b64.isEmpty else { continue }
                parts.append(.init(inlineData: .init(mimeType: ImageMediaType.resolve(base64: b64, declared: a.mimeType), data: b64)))
            case .video:
                let b64 = a.resolvedBase64Data
                guard !b64.isEmpty else { continue }
                parts.append(.init(inlineData: .init(mimeType: a.mimeType, data: b64)))
            case .file:
                break  // Files are already handled by AttachmentDelivery
            }
        }
        for f in nativeAtts {
            if let base64 = f.originalBase64Data, !base64.isEmpty {
                parts.append(.init(inlineData: .init(mimeType: f.mimeType, data: base64)))
            }
        }
        return .init(role: role, parts: parts)
    }


    private static let knownTextModelIDs = [
        "gemini-2.5-flash",
        "gemini-2.5-pro",
        "gemini-2.0-flash",
    ]

    private func buildModels(from remoteModels: [GeminiMetadataModel], preferredModelID: String?) async -> [AIModel] {
        let normalizedPreferredID = preferredModelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        var models: [AIModel] = []
        models.reserveCapacity(remoteModels.count)

        for remote in remoteModels {
            var model = await CatalogModelBuilder.buildCatalogModel(
                providerKind: .gemini,
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


private struct GeminiMetadataModel {
    var id: String
}


private struct GeminiGenerateContentRequest: Encodable {
    var contents: [Content]
    var systemInstruction: SystemInstruction?
    var tools: [Tool]?
    var generationConfig: GenerationConfig?

    private enum CodingKeys: String, CodingKey {
        case contents
        case systemInstruction
        case tools
        case generationConfig
    }

    struct SystemInstruction: Encodable {
        var parts: [TextPart]

        struct TextPart: Encodable {
            var text: String
        }
    }

    struct GenerationConfig: Encodable {
        var responseModalities: [String]?
        var thinkingConfig: ThinkingConfig?
        /// Passed only by "Test capabilities"; nil is not encoded, so chat output is unchanged.
        var maxOutputTokens: Int? = nil

        struct ThinkingConfig: Encodable {
            var thinkingBudget: Int?
            var thinkingLevel: String?

            private enum CodingKeys: String, CodingKey {
                case thinkingBudget
                case thinkingLevel
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                if let thinkingBudget { try container.encode(thinkingBudget, forKey: .thinkingBudget) }
                if let thinkingLevel { try container.encode(thinkingLevel, forKey: .thinkingLevel) }
            }
        }
    }

    struct Tool: Encodable {
        var googleSearch: EmptyObject?
    }

    struct EmptyObject: Encodable {}

    struct Content: Encodable {
        var role: String
        var parts: [Part]
    }

    struct Part: Encodable {
        var text: String?
        var inlineData: InlineData?

        struct InlineData: Encodable {
            var mimeType: String
            var data: String
        }

        private enum CodingKeys: String, CodingKey {
            case text
            case inlineData
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            if let text { try container.encode(text, forKey: .text) }
            if let inlineData { try container.encode(inlineData, forKey: .inlineData) }
        }
    }
}

private struct GeminiGenerateContentResponse: Decodable {
    var candidates: [Candidate]?
    var usageMetadata: GeminiUsageMetadata?
    var promptFeedback: PromptFeedback?
    var error: APIError?

    struct PromptFeedback: Decodable {
        var blockReason: String?
    }

    struct APIError: Decodable {
        var code: Int?
        var message: String?
        var status: String?

        private enum CodingKeys: String, CodingKey {
            case code, message, status
        }

        init(from decoder: Decoder) throws {
            if let keyed = try? decoder.container(keyedBy: CodingKeys.self) {
                code = (try? keyed.decodeIfPresent(Int.self, forKey: .code)) ?? nil
                message = (try? keyed.decodeIfPresent(String.self, forKey: .message)) ?? nil
                status = (try? keyed.decodeIfPresent(String.self, forKey: .status)) ?? nil
                return
            }
            if let single = try? decoder.singleValueContainer(),
               let text = try? single.decode(String.self) {
                message = text
            }
        }
    }

    struct Candidate: Decodable {
        var content: CandidateContent?
        var finishReason: String?
    }

    struct CandidateContent: Decodable {
        var parts: [ContentPart]?
    }

    struct ContentPart: Decodable {
        var text: String?
        var inlineData: InlineData?
        var thought: Bool?
    }

    struct InlineData: Decodable {
        var mimeType: String
        var data: String
    }

    var resolvedText: String {
        candidates?
            .compactMap { $0.content?.parts }
            .flatMap { $0 }
            .filter { $0.thought != true }
            .compactMap { $0.text }
            .joined() ?? ""
    }

    var resolvedAttachments: [Attachment] {
        let parts = candidates?
            .compactMap { $0.content?.parts }
            .flatMap { $0 } ?? []
        return parts.compactMap { part in
            guard let inline = part.inlineData,
                  inline.mimeType.hasPrefix("image/") else { return nil }
            return Attachment(
                id: UUID(),
                kind: .image,
                fileName: "generated_image.\(inline.mimeType.replacingOccurrences(of: "image/", with: ""))",
                mimeType: inline.mimeType,
                base64Data: inline.data
            )
        }
    }
}

private struct GeminiUsageMetadata: Decodable {
    var promptTokenCount: Int?
    var candidatesTokenCount: Int?
    var totalTokenCount: Int?
    var cachedContentTokenCount: Int?
    var thoughtsTokenCount: Int?

    init(
        promptTokenCount: Int? = nil,
        candidatesTokenCount: Int? = nil,
        totalTokenCount: Int? = nil,
        cachedContentTokenCount: Int? = nil,
        thoughtsTokenCount: Int? = nil
    ) {
        self.promptTokenCount = promptTokenCount
        self.candidatesTokenCount = candidatesTokenCount
        self.totalTokenCount = totalTokenCount
        self.cachedContentTokenCount = cachedContentTokenCount
        self.thoughtsTokenCount = thoughtsTokenCount
    }
}

extension GeminiService {
    fileprivate static func parseUsage(_ usage: GeminiUsageMetadata?) -> UsageBreakdown {
        guard let usage else { return UsageBreakdown() }
        let prompt = usage.promptTokenCount ?? 0
        let cached = usage.cachedContentTokenCount ?? 0
        let candidates = usage.candidatesTokenCount ?? 0
        let thoughts = usage.thoughtsTokenCount ?? 0
        return UsageBreakdown(
            promptTokens: max(0, prompt - cached),
            cachedInputTokens: cached,
            cacheCreation5mTokens: 0,
            cacheCreation1hTokens: 0,
            completionTokens: candidates + thoughts,
            reasoningTokens: thoughts,
            upstreamCost: nil,
            cacheReadObserved: usage.cachedContentTokenCount != nil
        )
    }

    #if DEBUG
    static func parseUsageForTesting(
        promptTokenCount: Int?,
        candidatesTokenCount: Int?,
        thoughtsTokenCount: Int?,
        cachedContentTokenCount: Int?
    ) -> UsageBreakdown {
        let usage = GeminiUsageMetadata(
            promptTokenCount: promptTokenCount,
            candidatesTokenCount: candidatesTokenCount,
            totalTokenCount: nil,
            cachedContentTokenCount: cachedContentTokenCount,
            thoughtsTokenCount: thoughtsTokenCount
        )
        return parseUsage(usage)
    }
    #endif
}

// MARK: - Protocol entry with request options: a one-line forward to the options overload this service already has

extension GeminiService {
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
}
