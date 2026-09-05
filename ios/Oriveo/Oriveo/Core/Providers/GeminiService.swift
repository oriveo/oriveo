import Foundation

final class GeminiService: BaseAPIService, ProviderServiceProtocol {
    private let baseURL = "https://generativelanguage.googleapis.com/v1beta"

    override func applyHeaders(to request: inout URLRequest, apiKey: String) {
        applyJSONHeaders(to: &request, includeAccept: false)
    }

    /// endpoint_route builder. Selection is exclusively the versioned Server recipe; there is
    /// no model-name inference or beta fallback.
    func buildInteractionsRequest(
        modelID: String,
        messages: [ChatMessage],
        apiKey: String,
        stream: Bool,
        recipe: MetadataClient.CapabilityRecipe,
        previousResponseID: String? = nil,
        systemPrompt: String = "",
        safeCustomBodyFragments: [SafeCustomBodyFragment] = []
    ) throws -> URLRequest {
        try validateAPIKey(apiKey)
        guard recipe.executionKind == "endpoint_route",
              recipe.providerKind == "gemini",
              recipe.transport.protocolName == "gemini_interactions",
              recipe.route?.protocolName == "gemini_interactions",
              recipe.route?.endpointClass == "interactions",
              recipe.route?.requestMapper == "gemini_interactions_v1",
              recipe.route?.path == "/v1/interactions" else {
            throw ProviderServiceError.invalidConfiguration(detail: "Invalid Gemini Interactions recipe.")
        }
        guard var endpoint = URLComponents(string: baseURL) else {
            throw ProviderServiceError.invalidConfiguration(detail: "Invalid Gemini Interactions endpoint.")
        }
        // The historical generateContent base ends at `/v1beta`; GA Interactions is origin-rooted.
        endpoint.path = recipe.route?.path ?? ""
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
            "input": (previousResponseID == nil ? messages : messages.suffix(1)).map {
                ["role": $0.role == .assistant ? "model" : $0.role.rawValue, "parts": [["text": $0.text]]]
            },
        ]
        let trimmedSystem = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSystem.isEmpty {
            body["system_instruction"] = trimmedSystem
        }
        let compilation = CapabilityRecipeRequestCompiler.compile(
            recipe: recipe, to: &body, providerKind: "gemini", transport: "gemini_interactions",
            capability: "web", selectedIntent: nil
        )
        guard compilation.applied else {
            throw ProviderServiceError.invalidConfiguration(detail: "Gemini Interactions recipe rejected: \(compilation.reason ?? "unknown")")
        }
        // `redactedPreview` is audit-only. The inout body above is the sole production wire.
        body.merge(CapabilityRecipeExecution.geminiInteractionsPreviousID(previousResponseID)) { _, latest in latest }
        try CapabilityRecipeExecution.applySafeCustomFragments(
            safeCustomBodyFragments, to: &body,
            providerKind: .gemini, modelID: modelID, transport: "gemini_interactions"
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        CapabilityExecutionRuntime.confirmFinalWireEncoded()
        return request
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

        if webSearchEnabled,
           let recipe = MetadataClient.shared.syncCapabilityRecipe(
               modelID: modelID, providerKind: .gemini, capability: "web"
           ), recipe.executionKind == "endpoint_route",
           recipe.transport.protocolName == "gemini_interactions" {
            return try await sendInteractions(
                apiKey: apiKey, modelID: modelID, messages: messages, stream: false, recipe: recipe,
                systemPrompt: requestOptions.systemPrompt,
                safeCustomBodyFragments: requestOptions.localSafeCustomBodyFragments,
                producerMessageID: requestOptions.localContinuationMessageID,
                explicitMessageID: requestOptions.localExplicitContinuationMessageID
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

        let (data, _) = try await performRawWithUnsupportedParamSelfHeal(
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
        }

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

                    if webSearchEnabled,
                       let recipe = MetadataClient.shared.syncCapabilityRecipe(
                           modelID: modelID, providerKind: .gemini, capability: "web"
                       ), recipe.executionKind == "endpoint_route",
                       recipe.transport.protocolName == "gemini_interactions" {
                        try await self.streamInteractions(
                            apiKey: apiKey, modelID: modelID, messages: messages, recipe: recipe,
                            systemPrompt: requestOptions.systemPrompt,
                            safeCustomBodyFragments: requestOptions.localSafeCustomBodyFragments,
                            producerMessageID: requestOptions.localContinuationMessageID,
                            explicitMessageID: requestOptions.localExplicitContinuationMessageID, continuation: continuation
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
                    let relayStrategy = TransportRegistry.strategy(for: .geminiGenerate)
                    let relayShape = self.resolveRelayWebSearchShape(
                        modelID: modelID,
                        relayRequested: relayRequested
                    )
                    var relayCtx = StreamContext()
                    var relayLastCitationsCount = 0

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
            providerKind: .gemini
        )?.profiles.webSearch
        return MetadataClient.shared.syncWebSearchStreamShape(profileName: fallback)
    }

    // MARK: - Gemini Interactions (GA `/v1/interactions`)

    private func sendInteractions(
        apiKey: String, modelID: String, messages: [ChatMessage], stream: Bool,
        recipe: MetadataClient.CapabilityRecipe, systemPrompt: String,
        safeCustomBodyFragments: [SafeCustomBodyFragment], producerMessageID: UUID?, explicitMessageID: UUID?
    ) async throws -> ProviderChatResult {
        let previousID = try Self.loadExplicitInteractionID(explicitMessageID)
        let request = try buildInteractionsRequest(
            modelID: modelID, messages: messages, apiKey: apiKey, stream: stream, recipe: recipe,
            previousResponseID: previousID, systemPrompt: systemPrompt, safeCustomBodyFragments: safeCustomBodyFragments
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderServiceError.network(detail: "Missing HTTPURLResponse.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw mapHTTPError(statusCode: http.statusCode, data: data)
        }
        let text = Self.interactionsText(from: data).trimmingCharacters(in: .whitespacesAndNewlines)
        // A completed interaction ID is valid opaque continuation state even if this leg contains
        // no displayable text (for example a tool-only completion).
        if let messageID = producerMessageID, let interactionID = Self.completedInteractionID(from: data) {
            try RecipeContinuationRuntime.save(
                messageID: messageID, recipe: recipe, state: ["previousResponseId": .string(interactionID)]
            )
        }
        guard !text.isEmpty else { throw ProviderServiceError.emptyResponse }
        let (cost, source) = await MetadataClient.shared.calcCost(
            breakdown: UsageBreakdown(), modelID: modelID, providerKind: .gemini
        )
        return ProviderChatResult(text: text, promptTokens: 0, completionTokens: 0,
                                  estimatedCost: cost, usageBreakdown: UsageBreakdown(), costSource: source)
    }

    private func streamInteractions(
        apiKey: String, modelID: String, messages: [ChatMessage], recipe: MetadataClient.CapabilityRecipe,
        systemPrompt: String, safeCustomBodyFragments: [SafeCustomBodyFragment],
        producerMessageID: UUID?, explicitMessageID: UUID?,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        let previousID = try Self.loadExplicitInteractionID(explicitMessageID)
        let request = try buildInteractionsRequest(
            modelID: modelID, messages: messages, apiKey: apiKey, stream: true, recipe: recipe,
            previousResponseID: previousID, systemPrompt: systemPrompt, safeCustomBodyFragments: safeCustomBodyFragments
        )
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderServiceError.network(detail: "Missing HTTPURLResponse.")
        }
        guard (200..<300).contains(http.statusCode) else {
            var data = Data(); for try await byte in bytes { data.append(byte) }
            throw mapHTTPError(statusCode: http.statusCode, data: data)
        }
        var text = ""
        var completedInteractionID: String?
        for try await line in bytes.utf8Lines {
            guard !Task.isCancelled else { return }
            let payload = line.hasPrefix("data:")
                ? String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                : line
            guard !payload.isEmpty, payload != "[DONE]", let data = payload.data(using: .utf8) else { continue }
            completedInteractionID = Self.completedInteractionID(from: data) ?? completedInteractionID
            // GA stream events carry nested `step.delta`; do not reuse the legacy
            // generateContent candidates/content parser.
            let delta = Self.interactionsText(from: data)
            guard !delta.isEmpty else { continue }
            text += delta
            continuation.yield(.delta(delta))
        }
        let (cost, source) = await MetadataClient.shared.calcCost(
            breakdown: UsageBreakdown(), modelID: modelID, providerKind: .gemini
        )
        if let messageID = producerMessageID, let completedInteractionID {
            try RecipeContinuationRuntime.save(
                messageID: messageID, recipe: recipe, state: ["previousResponseId": .string(completedInteractionID)]
            )
        }
        continuation.yield(.done(ProviderChatResult(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines), promptTokens: 0,
            completionTokens: 0, estimatedCost: cost, usageBreakdown: UsageBreakdown(), costSource: source
        )))
    }

    /// Interactions keeps text under completed `steps` for non-streaming responses and under
    /// `step.delta` for SSE. Keep the parser structurally narrow: only semantic `text` fields
    /// under those containers are surfaced, never IDs, signatures, or arbitrary metadata.
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
        if object["event_type"] as? String == "step.delta",
           let delta = object["delta"] as? [String: Any],
           delta["type"] as? String == "text" {
            return (delta["text"] as? String) ?? ""
        }
        if object["event_type"] as? String == "step.delta",
           let step = object["step"] as? [String: Any],
           step["type"] as? String == "model_output", let delta = step["delta"] {
            return texts(delta).joined()
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

    private static func completedInteractionID(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let interaction = (object["interaction"] as? [String: Any]) ?? object
        guard interaction["status"] as? String == "completed" else { return nil }
        return interaction["id"] as? String
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

    private static func loadExplicitInteractionID(_ messageID: UUID?) throws -> String? {
        RecipeContinuationRuntime.previousResponseID(explicitMessageID: messageID)
    }


    private static let blockedFinishReasons: Set<String> = [
        "SAFETY", "RECITATION", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII",
    ]

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
        isRelay: Bool = false
    ) -> ProviderServiceError {
        let detail = decodeErrorMessage(from: data, request: request)
            ?? HTTPURLResponse.localizedString(forStatusCode: statusCode)
        if statusCode == 400, detail.lowercased().contains("api key") {
            return .invalidAPIKey(detail: detail)
        }
        return super.mapHTTPError(statusCode: statusCode, data: data, url: url, request: request, isRelay: isRelay)
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
        let recipeLegacyInput = CapabilityRecipeRequestCompiler.legacyInput(
            providerKind: .gemini, modelID: modelID,
            webSearchEnabled: webSearchEnabled, reasoningMode: reasoningMode
        )
        let capabilityIntent = CapabilityEvidenceProductionAdapter.finalChatIntent(
            messages: messages, request: request,
            effectiveTransport: resolved?.transport ?? "",
            model: requestOptions.capabilityEvidenceModel,
            // Image-generation requests remain on their separate legacy image contract until
            // that contract is versioned; only makes text-chat model controls runtime-owned.
            requestedReasoningMode: supportsImageGen ? reasoningMode : recipeLegacyInput.reasoningMode,
            webSearchEnabled: supportsImageGen ? webSearchEnabled : recipeLegacyInput.webSearchEnabled
        )
        let contents = capabilityIntent.outboundMessages.map { Self.buildContent($0) }
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
        ProfileParamsResolver.applyTemperatureGate(to: &body, resolved: resolved)
        ProfileParamsResolver.applyGenerationParameters(
            to: &body,
            options: requestOptions,
            profile: resolved?.generationProfile,
            finalRequest: request,
            effectiveTransport: resolved?.transport
        )
        CapabilityRecipeRequestCompiler.apply(
            to: &body, providerKind: .gemini, modelID: modelID,
            transport: resolved?.transport ?? "", webSearchEnabled: webSearchEnabled,
            reasoningMode: reasoningMode, capabilityPreferences: requestOptions.capabilityPreferences
        )
        try CapabilityRecipeExecution.applySafeCustomFragments(
            requestOptions.localSafeCustomBodyFragments, to: &body,
            providerKind: .gemini, modelID: modelID,
            transport: resolved?.transport ?? "gemini_generate_content"
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        CapabilityExecutionRuntime.confirmFinalWireEncoded()
        return request
    }

    private func buildRelayGenerateContentRequest(
        modelID: String,
        messages: [ChatMessage],
        apiKey: String,
        baseURL: String,
        stream: Bool,
        reasoningMode: ReasoningMode,
        webSearchEnabled: Bool,
        supportsImageGen: Bool,
        requestOptions: ChatRequestOptions = ChatRequestOptions(),
        relayRequested: RelayRequestedConfig? = nil,
        droppedParams: Set<String> = []
    ) throws -> URLRequest {
        let normalizedBase = try RelayEndpointResolver.runtimeAPIBaseURL(
            rawBaseURL: baseURL,
            relayRequested: relayRequested,
            defaultVersion: "v1beta",
            acceptedVersions: ["v1", "v1beta"]
        )
        let endpoint = stream ? "streamGenerateContent" : "generateContent"
        let path = "/models/\(modelID):\(endpoint)"
        let endpointURL = try RelayEndpointResolver.endpointURL(apiBaseURL: normalizedBase, endpointPath: path)
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
            webSearchEnabled: webSearchEnabled
        )
        let contents = capabilityIntent.outboundMessages.map { Self.buildContent($0) }
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
            thinkingConfig: thinkingConfig
        )
        let systemPrompt = requestOptions.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let systemInstruction: GeminiGenerateContentRequest.SystemInstruction? = systemPrompt.isEmpty ? nil : .init(parts: [.init(text: systemPrompt)])
        let payload = GeminiGenerateContentRequest(
            contents: contents,
            systemInstruction: systemInstruction,
            tools: capabilityIntent.webSearchEnabled ? [.init(googleSearch: .init())] : nil,
            generationConfig: config
        )
        var body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any] ?? [:]
        ProfileParamsResolver.applyGenerationParameters(
            to: &body,
            options: requestOptions,
            finalRequest: request,
            effectiveTransport: RelayTransport.geminiGenerateContent.rawValue
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        CapabilityExecutionRuntime.confirmFinalWireEncoded()
        return request
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

    private static func buildContent(_ msg: ChatMessage, model: AIModel? = nil) -> GeminiGenerateContentRequest.Content {
        let role = msg.role == .assistant ? "model" : "user"

        guard let atts = msg.attachments, !atts.isEmpty else {
            return .init(role: role, parts: [.init(text: msg.text)])
        }

        let fileAtts = atts.filter { $0.kind == .file }
        let (nativeAtts, textFileAtts) = BaseAPIService.partitionAttachmentsByRoute(
            fileAtts, provider: .gemini, model: model
        )

        let (injectedText, _) = BaseAPIService.injectFileAttachmentsAsText(
            userText: msg.text,
            attachments: textFileAtts,
            provider: .gemini,
            model: model
        )

        var parts: [GeminiGenerateContentRequest.Part] = [.init(text: injectedText)]
        for a in atts {
            switch a.kind {
            case .image:
                let b64 = a.resolvedBase64Data
                guard !b64.isEmpty else { continue }
                parts.append(.init(inlineData: .init(mimeType: a.mimeType, data: b64)))
            case .video:
                let b64 = a.resolvedBase64Data
                guard !b64.isEmpty else { continue }
                parts.append(.init(inlineData: .init(mimeType: a.mimeType, data: b64)))
            case .file:
                break
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
