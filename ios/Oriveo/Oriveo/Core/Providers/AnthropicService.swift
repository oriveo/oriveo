import Foundation
import OriveoProviderKit

final class AnthropicService: BaseAPIService, ProviderServiceProtocol {
    private let baseURL = "https://api.anthropic.com/v1"


    override func applyHeaders(to request: inout URLRequest, apiKey: String) {
        applyJSONHeaders(to: &request)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
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
            reasoningMode: .automatic
        )
    }

    func sendMessage(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        reasoningMode: ReasoningMode = .automatic,
        webSearchEnabled: Bool = false,
        requestOptions: ChatRequestOptions = ChatRequestOptions()
    ) async throws -> ProviderChatResult {
        try validateAPIKey(apiKey)
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderServiceError.invalidConfiguration(detail: "Missing model identifier.")
        }

        let (data, _) = try await performRawWithUnsupportedParamSelfHeal(
            providerKind: .anthropic,
            modelID: modelID
        ) { droppedParams in
            try buildMessagesRequest(
                modelID: modelID,
                messages: messages,
                apiKey: apiKey,
                stream: false,
                reasoningMode: reasoningMode,
                webSearchEnabled: webSearchEnabled,
                requestOptions: requestOptions,
                droppedParams: droppedParams
            )
        }

        let anthropicResponse: AnthropicChatResponse
        do {
            anthropicResponse = try decoder.decode(AnthropicChatResponse.self, from: data)
        } catch {
            throw ProviderServiceError.network(detail: "Decoding failed: \(error.localizedDescription)")
        }

        // A completed Anthropic response may legally contain only thinking/tool blocks (for
        // example pause_turn). Persist those opaque blocks before deciding whether there is UI text:
        // an explicit continue must still be able to replay the completed protocol leg.
        let continuationRecipe = RecipeContinuationRuntime.selectedRecipe(
            provider: .anthropic, modelID: modelID, transport: "anthropic_messages",
            webSearchEnabled: webSearchEnabled, reasoningMode: reasoningMode,
            continuationKind: "replay_blocks", parser: { $0 == "anthropic_web_search_v1" || $0 == "anthropic_thinking_v1" }
        )
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let blocks = object["content"] as? [[String: Any]],
           let encoded = RecipeContinuationRuntime.jsonValue(blocks) {
            try RecipeContinuationRuntime.save(
                messageID: requestOptions.localContinuationMessageID,
                recipe: continuationRecipe,
                state: ["blocks": encoded]
            )
        }

        let text = anthropicResponse.resolvedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ProviderServiceError.emptyResponse
        }

        let breakdown = Self.parseUsage(anthropicResponse.usage)
        let (cost, source) = await MetadataClient.shared.calcCost(
            breakdown: breakdown, modelID: modelID, providerKind: .anthropic, at: Date()
        )
        return ProviderChatResult(
            text: text,
            promptTokens: breakdown.totalInputTokens,
            completionTokens: breakdown.completionTokens,
            estimatedCost: cost,
            usageBreakdown: breakdown,
            usageReported: anthropicResponse.usage != nil,
            costSource: source
        )
    }

    func sendMessage(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        baseURL: String,
        reasoningMode: ReasoningMode = .automatic,
        requestOptions: ChatRequestOptions = ChatRequestOptions(),
        relayRequested: RelayRequestedConfig? = nil
    ) async throws -> ProviderChatResult {
        try validateAPIKey(apiKey)
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderServiceError.invalidConfiguration(detail: "Missing model identifier.")
        }

        // When a relay rejects a native file block, resend once with the files injected as text (NativeFileFallback).
        let (data, _) = try await NativeFileFallback.run(
            .relayScope(.anthropicMessages, connectionID: requestOptions.attachmentConnectionID, modelID: requestOptions.capabilityEvidenceModel?.id, fileOverride: requestOptions.capabilityEvidenceModel?.relayCapabilityOverrides?.file)
        ) { try await performRawWithUnsupportedParamSelfHeal(
            providerKind: .relay,
            modelID: modelID,
            effectiveTransport: RelayTransport.anthropicMessages.rawValue,
            relayEngineProfile: relayRequested?.engineProfile,
            relayDeclaredProfile: requestOptions.generationProfile
        ) { droppedParams in
            try buildRelayMessagesRequest(
                modelID: modelID,
                messages: messages,
                apiKey: apiKey,
                baseURL: baseURL,
                stream: false,
                reasoningMode: reasoningMode,
                requestOptions: requestOptions,
                relayRequested: relayRequested,
                droppedParams: droppedParams
            )
        } }

        let anthropicResponse: AnthropicChatResponse
        do {
            anthropicResponse = try decoder.decode(AnthropicChatResponse.self, from: data)
        } catch {
            throw ProviderServiceError.network(detail: "Decoding failed: \(error.localizedDescription)")
        }

        let text = anthropicResponse.resolvedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ProviderServiceError.emptyResponse
        }

        let breakdown = Self.parseUsage(anthropicResponse.usage)
        return ProviderChatResult(
            text: text,
            promptTokens: breakdown.totalInputTokens,
            completionTokens: breakdown.completionTokens,
            estimatedCost: 0,
            usageBreakdown: breakdown,
            usageReported: anthropicResponse.usage != nil,
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
            reasoningMode: .automatic
        )
    }

    func sendMessageStream(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
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

                    let request = try self.buildMessagesRequest(
                        modelID: modelID,
                        messages: messages,
                        apiKey: apiKey,
                        stream: true,
                        reasoningMode: reasoningMode,
                        webSearchEnabled: webSearchEnabled,
                        requestOptions: requestOptions
                    )
                    let (bytes, response) = try await self.bytesWithUnsupportedParamSelfHeal(
                        providerKind: .anthropic,
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
                    var startUsage: AnthropicUsage?
                    // The upstream counts as having reported usage only when message_start or message_delta carried a usage object.
                    var sawUsage = false
                    var outputTokens = 0
                    var currentEvent = ""
                    let antStrategy = TransportRegistry.strategy(for: .anthropicMessages)
                    let resolvedWebProfile = MetadataClient.shared.syncResolveCatalogModel(
                            modelID: modelID,
                            providerKind: .anthropic
                        )?.profiles.webSearch
                    let antShape = webSearchEnabled
                        ? MetadataClient.shared.syncWebSearchStreamShape(profileName: resolvedWebProfile)
                        : nil
                    var antCtx = StreamContext()
                    var antLastCitationsCount = 0
                    var replayBlocks: [Int: [String: Any]] = [:]
                    var replayBlockOrder: [Int] = []
                    var replayInputJSON: [Int: String] = [:]
                    var sawMessageStop = false

                    var finishTracker = StreamFinishTracker(family: .anthropic)
                    for try await line in bytes.utf8Lines {
                        if Task.isCancelled { break }

                        if line.hasPrefix("event: ") {
                            currentEvent = String(line.dropFirst(7))
                            continue
                        }

                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        guard let jsonData = payload.data(using: .utf8) else { continue }
                        // Anthropic reports in-stream errors as `event: error` + `{"type":"error",...}`.
                        try Self.throwIfStreamErrorFrame(jsonData, beforeAnyContent: accumulatedText.isEmpty, redacting: [apiKey])
                        finishTracker.observeFrame(jsonData, eventType: currentEvent.isEmpty ? nil : currentEvent)

                        for ev in antStrategy.parseStreamLine(payload, ctx: &antCtx, shape: antShape) {
                            switch ev {
                            case .reasoning, .toolCallDeltas, .activity: continuation.yield(ev)
                            default: break
                            }
                        }
                        let citationsSnapshot = antCtx.citationsAccumulator.citations
                        if citationsSnapshot.count > antLastCitationsCount {
                            antLastCitationsCount = citationsSnapshot.count
                            continuation.yield(.citations(citationsSnapshot))
                        }

                        switch currentEvent {
                        case "content_block_start":
                            if let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                               let index = object["index"] as? Int,
                               let block = object["content_block"] as? [String: Any] {
                                replayBlocks[index] = block
                                replayBlockOrder.append(index)
                            }
                        case "message_start":
                            if let msg = try? self.decoder.decode(AnthropicMessageStart.self, from: jsonData) {
                                startUsage = msg.message?.usage
                                if startUsage != nil { sawUsage = true }
                                outputTokens = msg.message?.usage?.output_tokens ?? 0
                            }
                        case "content_block_delta":
                            if let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                               let index = object["index"] as? Int,
                               let delta = object["delta"] as? [String: Any] {
                                Self.mergeReplayDelta(delta, into: &replayBlocks[index], inputJSON: &replayInputJSON[index])
                            }
                            if let delta = try? self.decoder.decode(AnthropicContentBlockDelta.self, from: jsonData),
                               let text = delta.delta?.text, !text.isEmpty {
                                accumulatedText += text
                                continuation.yield(.delta(text))
                            }
                        case "message_delta":
                            if let delta = try? self.decoder.decode(AnthropicMessageDelta.self, from: jsonData) {
                                if delta.usage != nil { sawUsage = true }
                                outputTokens = delta.usage?.output_tokens ?? outputTokens
                            }
                        case "message_stop":
                            sawMessageStop = true
                        default:
                            break
                        }

                        currentEvent = ""
                    }
                    for ev in AnthropicMessagesStrategy.flushToolCalls(ctx: &antCtx) { continuation.yield(ev) }

                    let finalText = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let continuationRecipe = RecipeContinuationRuntime.selectedRecipe(
                        provider: .anthropic, modelID: modelID, transport: "anthropic_messages",
                        webSearchEnabled: webSearchEnabled, reasoningMode: reasoningMode,
                        continuationKind: "replay_blocks", parser: { $0 == "anthropic_web_search_v1" || $0 == "anthropic_thinking_v1" }
                    )
                    if !Task.isCancelled, sawMessageStop,
                       let blocks = Self.completeReplayBlocks(
                            blocks: replayBlocks, order: replayBlockOrder, inputJSON: replayInputJSON
                       ), let encoded = RecipeContinuationRuntime.jsonValue(blocks) {
                        try RecipeContinuationRuntime.save(
                            messageID: requestOptions.localContinuationMessageID,
                            recipe: continuationRecipe,
                            state: ["blocks": encoded]
                        )
                    }
                    var finalUsage = startUsage ?? AnthropicUsage(input_tokens: 0, output_tokens: 0)
                    finalUsage.output_tokens = outputTokens
                    let breakdown = Self.parseUsage(finalUsage)
                    let (cost, source) = await MetadataClient.shared.calcCost(
                        breakdown: breakdown, modelID: modelID, providerKind: .anthropic, at: Date()
                    )
                    let result = ProviderChatResult(
                        text: finalText,
                        promptTokens: breakdown.totalInputTokens,
                        completionTokens: breakdown.completionTokens,
                        estimatedCost: cost,
                        usageBreakdown: breakdown,
                        usageReported: sawUsage,
                        costSource: source,
                        finish: finishTracker.finish()
                    )
                    try Self.throwIfContextWindowExceededBeforeAnswer(
                        result.finish, answer: finalText, continuation: continuation
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
                        .relayScope(.anthropicMessages, connectionID: requestOptions.attachmentConnectionID, modelID: requestOptions.capabilityEvidenceModel?.id, fileOverride: requestOptions.capabilityEvidenceModel?.relayCapabilityOverrides?.file)
                    ) {
                        let request = try self.buildRelayMessagesRequest(
                            modelID: modelID,
                            messages: messages,
                            apiKey: apiKey,
                            baseURL: baseURL,
                            stream: true,
                            reasoningMode: reasoningMode,
                            requestOptions: requestOptions,
                            relayRequested: relayRequested
                        )
                        let (bytes, response) = try await self.bytesWithUnsupportedParamSelfHeal(
                            providerKind: .relay,
                            modelID: modelID,
                            request: request,
                            effectiveTransport: RelayTransport.anthropicMessages.rawValue,
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
                    var startUsage: AnthropicUsage?
                    // The upstream counts as having reported usage only when message_start or message_delta carried a usage object.
                    var sawUsage = false
                    var outputTokens = 0
                    var currentEvent = ""
                    let relayStrategy = TransportRegistry.strategy(for: .anthropicMessages)
                    // The citation profile is derived from the web fragment merged into this turn; with no fragment the strategy's built-in parsing is used.
                    let relayShape = MetadataClient.shared.syncWebSearchStreamShape(
                        profileName: requestOptions.officialForeignRoute
                            // An official provider's foreign-protocol route behaves as before: citations are parsed by the profile the catalog matches.
                            ? MetadataClient.shared.syncResolveCatalogModel(modelID: modelID, providerKind: .anthropic)?.profiles.webSearch
                            : RelayWebFragments.citationProfile(
                                transport: .anthropicMessages,
                                fragment: requestOptions.relayWebFragments?.object(for: .anthropicMessages)
                            )
                    )
                    var relayCtx = StreamContext()
                    var relayLastCitationsCount = 0
                    var bodyStartChecked = false

                    var finishTracker = StreamFinishTracker(family: .anthropic)
                    for try await line in bytes.utf8Lines {
                        if Task.isCancelled { break }
                        // A fallback web page's Content-Type is not always html: recognize it once more on the first body line, before any output.
                        try self.rejectRelayWebPageStreamStart(httpResponse, line: line, settled: &bodyStartChecked)

                        if line.hasPrefix("event: ") {
                            currentEvent = String(line.dropFirst(7))
                            continue
                        }

                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        guard let jsonData = payload.data(using: .utf8) else { continue }
                        // Anthropic reports in-stream errors as `event: error` + `{"type":"error",...}`.
                        try Self.throwIfStreamErrorFrame(jsonData, beforeAnyContent: accumulatedText.isEmpty, redacting: [apiKey])
                        finishTracker.observeFrame(jsonData, eventType: currentEvent.isEmpty ? nil : currentEvent)

                        for ev in relayStrategy.parseStreamLine(payload, ctx: &relayCtx, shape: relayShape) {
                            switch ev {
                            case .reasoning, .toolCallDeltas, .activity: continuation.yield(ev)
                            default: break
                            }
                        }
                        let citationsSnapshot = relayCtx.citationsAccumulator.citations
                        if citationsSnapshot.count > relayLastCitationsCount {
                            relayLastCitationsCount = citationsSnapshot.count
                            continuation.yield(.citations(citationsSnapshot))
                        }

                        switch currentEvent {
                        case "message_start":
                            if let msg = try? self.decoder.decode(AnthropicMessageStart.self, from: jsonData) {
                                startUsage = msg.message?.usage
                                if startUsage != nil { sawUsage = true }
                                outputTokens = msg.message?.usage?.output_tokens ?? 0
                            }
                        case "content_block_delta":
                            if let delta = try? self.decoder.decode(AnthropicContentBlockDelta.self, from: jsonData),
                               let text = delta.delta?.text, !text.isEmpty {
                                accumulatedText += text
                                continuation.yield(.delta(text))
                            }
                        case "message_delta":
                            if let delta = try? self.decoder.decode(AnthropicMessageDelta.self, from: jsonData) {
                                if delta.usage != nil { sawUsage = true }
                                outputTokens = delta.usage?.output_tokens ?? outputTokens
                            }
                        case "message_stop":
                            break
                        default:
                            break
                        }

                        currentEvent = ""
                    }
                    for ev in AnthropicMessagesStrategy.flushToolCalls(ctx: &relayCtx) { continuation.yield(ev) }

                    let finalText = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    var finalUsage = startUsage ?? AnthropicUsage(input_tokens: 0, output_tokens: 0)
                    finalUsage.output_tokens = outputTokens
                    let breakdown = Self.parseUsage(finalUsage)
                    let (cost, source) = await MetadataClient.shared.calcCost(
                        breakdown: breakdown, modelID: modelID, providerKind: .anthropic, at: Date()
                    )
                    let result = ProviderChatResult(
                        text: finalText,
                        promptTokens: breakdown.totalInputTokens,
                        completionTokens: breakdown.completionTokens,
                        estimatedCost: cost,
                        usageBreakdown: breakdown,
                        usageReported: sawUsage,
                        costSource: source,
                        finish: finishTracker.finish()
                    )
                    try Self.throwIfContextWindowExceededBeforeAnswer(
                        result.finish, answer: finalText, continuation: continuation
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

    private func buildMessagesRequest(
        modelID: String,
        messages: [ChatMessage],
        apiKey: String,
        stream: Bool,
        reasoningMode: ReasoningMode,
        webSearchEnabled: Bool,
        requestOptions: ChatRequestOptions = ChatRequestOptions(),
        droppedParams: Set<String> = []
    ) throws -> URLRequest {
        let metadataTransport = MetadataClient.shared.syncProviderTransport(providerKind: .anthropic)
        let metadataBase = EndpointResolver.officialMetadataBaseURL(
            providerKind: .anthropic,
            metadataTransport: metadataTransport
        )
        let endpointBase = metadataBase ?? EndpointResolver.fallbackBaseURL(for: .anthropic)
        let endpointPath = metadataTransport?.endpoints?.chat
            ?? EndpointResolver.fallbackEndpointPath(.anthropic, kind: .chat)
        guard let endpointURL = EndpointResolver.joinURL(base: endpointBase, path: endpointPath) else {
            throw ProviderServiceError.invalidConfiguration(detail: "Invalid Anthropic endpoint.")
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = stream ? 120 : 60
        applyHeaders(to: &request, apiKey: apiKey)

        let systemPrompt = requestOptions.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = MetadataClient.shared.syncResolveCatalogModel(modelID: modelID, providerKind: .anthropic)
        let recipeLegacyInput = CapabilityRecipeRequestCompiler.legacyInput(
            providerKind: .anthropic, modelID: modelID,
            webSearchEnabled: webSearchEnabled, reasoningMode: reasoningMode
        )
        let continuationRecipe = RecipeContinuationRuntime.selectedRecipe(
            provider: .anthropic, modelID: modelID, transport: resolved?.transport ?? "",
            webSearchEnabled: webSearchEnabled, reasoningMode: reasoningMode,
            continuationKind: "replay_blocks", parser: { $0 == "anthropic_web_search_v1" || $0 == "anthropic_thinking_v1" }
        )
        let replayBlocks = continuationRecipe.flatMap { _ in
            RecipeContinuationRuntime.replayBlocks(
                explicitMessageID: requestOptions.localExplicitContinuationMessageID
            )
        }
        // ChatRequestBuilder includes the partial target assistant before its final continue user.
        // A complete opaque replay replaces that partial leg; absence/corruption leaves the normal
        // clean-restart history untouched.
        let requestMessagesInput = replayBlocks == nil ? messages : messages.filter {
            $0.id != requestOptions.localExplicitContinuationMessageID
        }
        let capabilityIntent = CapabilityEvidenceProductionAdapter.finalChatIntent(
            messages: requestMessagesInput, request: request,
            effectiveTransport: resolved?.transport ?? "",
            model: requestOptions.capabilityEvidenceModel,
            requestedReasoningMode: recipeLegacyInput.reasoningMode,
            webSearchEnabled: recipeLegacyInput.webSearchEnabled
        )
        // The output budget comes from the catalog; 8192 is only the fallback when the snapshot is missing.
        //
        // Hardcoding 8192 used to be safe because the legacy `ant_budget` profile sent budget and max_tokens as a
        // pair (fast 2048/8192, balanced 8192/12288, deep 16384/20480) and deepMerge let the paired max_tokens
        // override it. Once the recipe became the only writer, `anthropic.messages.reasoning.v1` kept only the
        // `/thinking` op and the paired max_tokens was lost, so the deep level became budget_tokens=16384 with
        // max_tokens=8192: upstream truncates thinking back to 8192, deep becomes indistinguishable from balanced,
        // and the UI still shows deep thinking.
        //
        // Why not add a max_tokens op back to the recipe: `max_tokens` is already the generation owner's wire target
        // (`max_output_tokens -> max_tokens` in the `anthropic_messages` template), so the reasoning recipe writing
        // `/max_tokens` too would be rejected as `ownerConflict` by `RequestPreferenceResolver.validateAssignments`.
        // Why not lift the relay `max(8192, budget+4096)` formula up here: that would create a formula only iOS has
        // and would need an extra ruling on who wins when the user explicitly sets max_output_tokens.
        //
        // A user-set output budget does not live at this layer: it goes through the generation parameter
        // (canonical id `max_output_tokens`), and `ProfileParamsResolver.applyGenerationParameters` below writes it into
        // the same `max_tokens` key after this payload, overriding this default. So the priority chain
        // "explicit value > catalog maxOutputTokens > 8192" holds, and only the last two levels are decided here.
        // On the main chat path the base value is plan.budget.oWire (already capped by the model limit and the window);
        // non-chat paths keep the original fallback.
        let defaultMaxTokens = requestOptions.maxOutputTokens
            ?? resolved?.maxOutputTokens.flatMap { $0 > 0 ? $0 : nil }
            ?? CapabilityEvidenceFacade.anthropicDefaultMaxOutputTokens
        let payload = AnthropicChatRequest(
            model: modelID,
            max_tokens: defaultMaxTokens,
            system: systemPrompt.isEmpty ? nil : systemPrompt,
            stream: stream ? true : nil,
            cache_control: nil,
            thinking: nil,
            output_config: nil,
            messages: try AttachmentDelivery.mapTurns(capabilityIntent.outboundMessages, isChatSend: requestOptions.capabilityEvidenceModel != nil, dynamicText: requestOptions.dynamicText) { try Self.buildRequestMessage($0, transport: .anthropicMessages, model: requestOptions.capabilityEvidenceModel, isOutgoingTurn: $1) }
        )
        var body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any] ?? [:]
        // The official route places a breakpoint only when the catalog declares promptCache.policyRef == anthropic.explicit; with no catalog it places none.
        Self.applyCacheBreakpoint(
            to: &body, dynamicText: requestOptions.dynamicText,
            placeBreakpoint: CapabilityEvidenceFacade.placesOfficialAnthropicCacheBreakpoint(
                policyRef: resolved?.promptCachePolicyRef
            )
        )
        if capabilityIntent.webSearchEnabled,
           let webMerge = ProfileParamsResolver.webSearchMergeParams(
            providerKind: .anthropic,
            modelID: modelID,
            profileName: resolved?.profiles.webSearch,
            droppedParams: droppedParams
           ) {
            ProfileParamsResolver.deepMerge(&body, webMerge)
        }
        if recipeLegacyInput.usesLegacyMapping,
           let allowedReasoningMode = capabilityIntent.reasoningMode,
           let reasoningMerge = ProfileParamsResolver.reasoningMergeParams(
            providerKind: .anthropic,
            modelID: modelID,
            reasoningMode: allowedReasoningMode,
            resolved: resolved,
            droppedParams: droppedParams
        ) {
            ProfileParamsResolver.deepMerge(&body, reasoningMerge)
        }
        try ClientToolsInjector.apply(to: &body, protocol: .anthropicMessages, options: requestOptions)
        ProfileParamsResolver.applyTemperatureGate(to: &body, resolved: resolved)
        let generationApplication = ProfileParamsResolver.applyGenerationParameters(
            to: &body,
            options: requestOptions,
            profile: resolved?.generationProfile,
            finalRequest: request,
            effectiveTransport: resolved?.transport
        )
        CapabilityRecipeRequestCompiler.apply(
            to: &body, providerKind: .anthropic, modelID: modelID,
            transport: resolved?.transport ?? "", webSearchEnabled: webSearchEnabled,
            reasoningMode: reasoningMode, capabilityPreferences: requestOptions.capabilityPreferences
        )
        // The thinking fields are only complete at this point, so the guard has to run after the
        // capability writer.
        ProfileParamsResolver.applyAnthropicThinkingGuard(
            to: &body, application: generationApplication, builderDefaultMaxTokens: defaultMaxTokens
        )
        if let blocks = replayBlocks {
            var requestMessages = body["messages"] as? [[String: Any]] ?? []
            // The continuation instruction is the final user turn. The replay must precede it;
            // appending after it produces an invalid Anthropic conversation order.
            let instruction = requestMessages.last
            if instruction?["role"] as? String == "user" { requestMessages.removeLast() }
            requestMessages.append(["role": "assistant", "content": blocks])
            if let instruction { requestMessages.append(instruction) }
            body["messages"] = requestMessages
        }
        try CapabilityRecipeExecution.applySafeCustomFragments(
            requestOptions.localSafeCustomBodyFragments, to: &body,
            providerKind: .anthropic, modelID: modelID,
            transport: resolved?.transport ?? "anthropic_messages"
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
        return try buildRelayMessagesRequest(
            modelID: modelID, messages: messages, apiKey: apiKey, baseURL: baseURL, stream: true,
            reasoningMode: .automatic, requestOptions: requestOptions, relayRequested: relayRequested,
            maxOutputTokens: maxOutputTokens, functionTools: functionTools, keepImageAttachments: true
        )
    }

    /// The two "Test capabilities" inputs; chat passes neither and its output is unchanged: `maxOutputTokens` is used directly as `max_tokens`
    /// (without the thinking-budget floor), and `functionTools` is `tools` in this protocol's shape.
    func buildRelayMessagesRequest(
        modelID: String,
        messages: [ChatMessage],
        apiKey: String,
        baseURL: String,
        stream: Bool,
        reasoningMode: ReasoningMode,
        requestOptions: ChatRequestOptions = ChatRequestOptions(),
        relayRequested: RelayRequestedConfig? = nil,
        droppedParams: Set<String> = [],
        maxOutputTokens: Int? = nil,
        functionTools: [Any]? = nil,
        keepImageAttachments: Bool = false
    ) throws -> URLRequest {
        let baseString = try RelayEndpointResolver.runtimeAPIBaseURL(
            rawBaseURL: baseURL,
            relayRequested: relayRequested,
            defaultVersion: "v1",
            acceptedVersions: ["v1"]
        )
        // Pass the connection's security mode: it defaults to remoteHTTPS, under which a local http connection would be blocked as plaintext.
        let base = try RelayEndpointResolver.endpointURL(
            apiBaseURL: baseString, endpointPath: "/messages",
            securityMode: relayRequested?.securityMode ?? .remoteHTTPS
        )

        let finalURL: URL
        if let relayRequested,
           let queryParams = relayRequested.effectiveQueryParams,
           !queryParams.isEmpty,
           var components = URLComponents(url: base, resolvingAgainstBaseURL: false) {
            let items = queryParams.map { URLQueryItem(name: $0.key, value: $0.value) }
            components.queryItems = (components.queryItems ?? []) + items
            finalURL = components.url ?? base
        } else {
            finalURL = base
        }

        var request = URLRequest(url: finalURL)
        request.httpMethod = "POST"
        request.timeoutInterval = stream ? 120 : 60
        applyRelayHeaders(to: &request, apiKey: apiKey, relayRequested: relayRequested)
        for header in relayRequested?.effectiveHeaders ?? [] {
            request.setValue(header.value, forHTTPHeaderField: header.key)
        }
        let capabilityIntent = CapabilityEvidenceProductionAdapter.finalChatIntent(
            messages: messages, request: request,
            effectiveTransport: RelayTransport.anthropicMessages.rawValue,
            model: requestOptions.capabilityEvidenceModel,
            requestedReasoningMode: reasoningMode,
            webSearchEnabled: false,
            keepImageAttachments: keepImageAttachments
        )

        let shouldDropThinking = droppedParams.contains("thinking")
        let shouldDropOutputConfig = droppedParams.contains("output_config")
        let plan = shouldDropThinking
            ? RelayThinkingPlan(thinking: nil, adaptiveEffort: nil)
            : Self.relayThinkingPlan(modelID: modelID, reasoningMode: capabilityIntent.reasoningMode)
        let thinking = plan.thinking
        let outputConfig = shouldDropOutputConfig ? nil : plan.adaptiveEffort.map { AnthropicChatRequest.OutputConfig(effort: $0) }

        let systemPrompt = requestOptions.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        // Anthropic API constraint: budget_tokens is clamped to max_tokens, so a hardcoded 8192 would cap Deep/Max
        // thinking at 8192. The formula matches the Web client.
        // The main chat path uses plan.budget.oWire; when the thinking budget is >= that, applyAnthropicThinkingGuard below raises it to budget + 4096.
        let resolvedMaxTokens = maxOutputTokens ?? requestOptions.maxOutputTokens ?? max(
            CapabilityEvidenceFacade.anthropicDefaultMaxOutputTokens,
            (capabilityIntent.reasoningMode.flatMap(Self.relayAnthropicBudgetTokens) ?? 0) + 4096
        )
        let payload = AnthropicChatRequest(
            model: modelID,
            max_tokens: resolvedMaxTokens,
            system: systemPrompt.isEmpty ? nil : systemPrompt,
            stream: stream ? true : nil,
            cache_control: nil,
            thinking: thinking,
            output_config: outputConfig,
            messages: try AttachmentDelivery.mapTurns(capabilityIntent.outboundMessages, isChatSend: requestOptions.capabilityEvidenceModel != nil, dynamicText: requestOptions.dynamicText) { try Self.buildRequestMessage($0, transport: .relayAnthropicMessages, model: requestOptions.capabilityEvidenceModel, isOutgoingTurn: $1) }
        )
        var body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any] ?? [:]
        Self.applyCacheBreakpoint(to: &body, dynamicText: requestOptions.dynamicText)
        if let functionTools {
            body["tools"] = functionTools
        }
        try ClientToolsInjector.apply(to: &body, protocol: .anthropicMessages, options: requestOptions)
        let generationApplication = ProfileParamsResolver.applyGenerationParameters(
            to: &body,
            options: requestOptions,
            finalRequest: request,
            effectiveTransport: RelayTransport.anthropicMessages.rawValue
        )
        ProfileParamsResolver.applyAnthropicThinkingGuard(
            to: &body, application: generationApplication, builderDefaultMaxTokens: resolvedMaxTokens
        )
        // Relay web fragment: applied after the builder's output and before the additional request body.
        RelayWebFragments.apply(requestOptions.relayWebFragments, transport: .anthropicMessages, to: &body)
        ClientToolsInjector.moveHostMemoryToolsLast(in: &body)
        try AdditionalRequestBody.apply(requestOptions.localAdditionalRequestBody, to: &body)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        CapabilityExecutionRuntime.confirmFinalWireEncoded()
        return request
    }

    fileprivate struct RelayThinkingPlan {
        let thinking: AnthropicChatRequest.Thinking?
        /// The adaptive thinking level, written to `output_config.effort`.
        let adaptiveEffort: String?
    }

    /// In-stream model_context_window_exceeded: when no answer text was produced, deliver finish first and then throw, so the
    /// caller takes the same recovery as an HTTP overflow; when text was already produced it finishes as usual and
    /// finish records stopReason as context_window_exceeded.
    static func throwIfContextWindowExceededBeforeAnswer(
        _ finish: StreamFinish?,
        answer: String,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) throws {
        guard let finish, answer.isEmpty,
              StopReasonResolver.resolve(
                  family: finish.family, ended: finish.ended, finishRaw: finish.finishRaw, hadContent: false
              ) == .contextWindowExceeded
        else { return }
        continuation.yield(.finish(finish))
        throw ProviderServiceError.upstream(
            statusCode: 200,
            detail: "The model stopped because the context window was exceeded (stop_reason: model_context_window_exceeded)."
        )
    }

    /// What `thinking` a Relay Anthropic-compatible endpoint receives at this level. The send path and the
    /// advanced-settings linkage prediction both read this, so the prediction never disagrees with what is
    /// actually sent. `reasoningMode` is the level already allowed by capability evidence; nil means thinking is off.
    fileprivate static func relayThinkingPlan(modelID: String, reasoningMode: ReasoningMode?) -> RelayThinkingPlan {
        guard let reasoningMode else { return .init(thinking: nil, adaptiveEffort: nil) }
        let lowered = modelID.lowercased()
        let usesAdaptiveThinking =
            lowered.contains("sonnet-4-6") || lowered.contains("sonnet-4.6") // heuristic-allow: Relay Anthropic-compatible fallback only; official Anthropic uses metadata profiles.
            || lowered.contains("opus-4-6") || lowered.contains("opus-4.6") // heuristic-allow: Relay Anthropic-compatible fallback only; official Anthropic uses metadata profiles.
        if usesAdaptiveThinking, let effort = relayAnthropicAdaptiveEffort(reasoningMode, for: modelID) {
            return .init(thinking: .init(type: "adaptive"), adaptiveEffort: effort)
        }
        if let budgetTokens = relayAnthropicBudgetTokens(reasoningMode) {
            return .init(thinking: .init(type: "enabled", budget_tokens: budgetTokens), adaptiveEffort: nil)
        }
        return .init(thinking: nil, adaptiveEffort: nil)
    }

    /// The request body shape of the same decision (`{"thinking": {...}}`), for predictions that do not build
    /// a whole request.
    static func relayThinkingRequestFields(modelID: String, reasoningMode: ReasoningMode?) -> [String: Any] {
        guard let thinking = relayThinkingPlan(modelID: modelID, reasoningMode: reasoningMode).thinking else { return [:] }
        var fields: [String: Any] = ["type": thinking.type]
        if let budget = thinking.budget_tokens { fields["budget_tokens"] = budget }
        return ["thinking": fields]
    }

    private static func relayAnthropicBudgetTokens(_ mode: ReasoningMode) -> Int? {
        switch mode {
        case .automatic: return nil
        case .fast: return 2_048
        case .balanced: return 8_192
        case .deep: return 16_384
        case .max: return 24_576
        }
    }

    private static func relayAnthropicAdaptiveEffort(_ mode: ReasoningMode, for modelID: String) -> String? {
        guard mode != .automatic else { return nil }
        switch mode {
        case .fast: return "low"
        case .balanced: return "medium"
        case .deep: return "high"
        case .max: return modelID.lowercased().contains("opus") ? "max" : "high" // heuristic-allow: Relay Anthropic-compatible fallback only; official Anthropic uses metadata profiles.
        case .automatic: return nil
        }
    }

    private func applyRelayHeaders(
        to request: inout URLRequest,
        apiKey: String,
        relayRequested: RelayRequestedConfig?
    ) {
        request.applyRelaySecurityMode(relayRequested)
        applyJSONHeaders(to: &request)
        let resolvedAuth = resolveRelayAuthMode(relayRequested)
        switch resolvedAuth {
        case .none:
            break
        case .xApiKey, .auto:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        case .bearer:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .queryKey, .xGoogApiKey:
            break
        }
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        guard resolvedAuth != .none else { return }
        if let ua = relayRequested?.effectiveCustomUserAgent?.trimmingCharacters(in: .whitespacesAndNewlines),
           !ua.isEmpty {
            request.setValue(ua, forHTTPHeaderField: "User-Agent")
        }
    }

    private func resolveRelayAuthMode(_ relayRequested: RelayRequestedConfig?) -> RelayAuthMode {
        guard let relayRequested else { return .xApiKey }
        if relayRequested.authMode != .auto {
            return relayRequested.authMode
        }
        return .xApiKey
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

    /// The same rule for the official route, Relay and tool legs: no top-level `cache_control`, and at most one
    /// ephemeral breakpoint in the whole request (Anthropic allows at most 4).
    /// - [D]: on the "current user message" (the last user message without a tool_result), when its last text block
    ///   == dynamicText or ends with "\n\n"+dynamicText, D is split off as that message's last standalone text block
    ///   (after the image / document blocks). Every tool-loop leg splits it the same way, so the prefix stays stable
    ///   leg to leg. If it is not recognized the message is sent unchanged.
    /// - Breakpoint: the last non-[D] block of the last user message in the whole request (on a tool leg that is the
    ///   tool_result turn, landing on the notice if there is one); when that message has only the [D] block, it goes there.
    /// Plain-text content is first expanded into a single text block.
    /// `placeBreakpoint == false` (the official catalog does not declare anthropic.explicit): [D] is still split off, but no breakpoint is placed and content is not rewritten.
    static func applyCacheBreakpoint(to body: inout [String: Any], dynamicText: String?, placeBreakpoint: Bool = true) {
        guard var messages = body["messages"] as? [[String: Any]],
              let lastUserIndex = messages.lastIndex(where: { $0["role"] as? String == "user" })
        else { return }

        func blocks(of message: [String: Any]) -> [[String: Any]]? {
            if let text = message["content"] as? String {
                return text.isEmpty ? nil : [["type": "text", "text": text]]
            }
            if let existing = message["content"] as? [[String: Any]], !existing.isEmpty { return existing }
            return nil
        }

        var dynamicSplitIndex: Int?
        if let dynamicText, !dynamicText.isEmpty,
           let currentIndex = messages.lastIndex(where: { message in
               guard message["role"] as? String == "user" else { return false }
               let content = message["content"] as? [[String: Any]] ?? []
               return !content.contains { $0["type"] as? String == "tool_result" }
           }),
           var current = blocks(of: messages[currentIndex]),
           let textIndex = current.lastIndex(where: { $0["type"] as? String == "text" }),
           let text = current[textIndex]["text"] as? String {
            let (head, dynamic) = AttachmentInjector.splitDynamic(text, dynamicText: dynamicText)
            if let dynamic {
                // Empty body (text == D): leave no empty text block
                if head.isEmpty {
                    current.remove(at: textIndex)
                } else {
                    current[textIndex]["text"] = head
                }
                current.append(["type": "text", "text": dynamic])
                messages[currentIndex]["content"] = current
                dynamicSplitIndex = currentIndex
            }
        }

        guard placeBreakpoint, var lastBlocks = blocks(of: messages[lastUserIndex]) else {
            body["messages"] = messages
            return
        }
        var breakpointIndex = lastBlocks.count - 1
        if dynamicSplitIndex == lastUserIndex, lastBlocks.count > 1 {
            breakpointIndex = lastBlocks.count - 2
        }
        lastBlocks[breakpointIndex]["cache_control"] = ["type": "ephemeral"] as [String: Any]
        messages[lastUserIndex]["content"] = lastBlocks
        body["messages"] = messages
    }

    /// Wire shape of the message blocks (without the capability-evidence projection), produced by the same
    /// encoder as the request body's `messages`. Lets tests check block-level fields: the official route's
    /// vision evidence is unavailable in tests, so images sent through sendMessageStream become placeholders.
    static func encodedWireMessages(_ messages: [ChatMessage], transport: AttachmentTransport, model: AIModel?) throws -> Data {
        try JSONEncoder().encode(
            AttachmentDelivery.mapTurns(messages, isChatSend: model != nil) {
                try buildRequestMessage($0, transport: transport, model: model, isOutgoingTurn: $1)
            }
        )
    }

    private static func buildRequestMessage(_ msg: ChatMessage, transport: AttachmentTransport, model: AIModel?, isOutgoingTurn: Bool) throws -> AnthropicChatRequest.Message {
        let role = msg.role == .assistant ? "assistant" : "user"

        guard let atts = msg.attachments, !atts.isEmpty else {
            return .init(role: role, content: .text(msg.text))
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

        guard !imageAtts.isEmpty || !nativeAtts.isEmpty else {
            return .init(role: role, content: .text(combinedText))
        }

        // Cache breakpoints are not set at block level: Anthropic allows at most 4 per request, so a breakpoint
        // per image / document would 400 with 4+ attachments. Both the official route and Relay set a single breakpoint
        // on the last user message at request-body level; [D] is also split off there as a standalone last block
        // (see applyCacheBreakpoint).
        var contentBlocks: [AnthropicChatRequest.ContentBlock] = [
            .init(type: "text", text: combinedText)
        ]
        for a in imageAtts {
            let b64 = a.resolvedBase64Data
            guard !b64.isEmpty else { continue }
            contentBlocks.append(.init(
                type: "image",
                source: .init(type: "base64", media_type: ImageMediaType.resolve(base64: b64, declared: a.mimeType), data: b64)
            ))
        }
        for f in nativeAtts {
            if let base64 = f.originalBase64Data, !base64.isEmpty {
                contentBlocks.append(.init(
                    type: "document",
                    source: .init(type: "base64", media_type: f.mimeType, data: base64)
                ))
            }
        }
        return .init(role: role, content: .blocks(contentBlocks))
    }


    private static let knownTextModelIDs = [
        "claude-sonnet-4-20250514",
        "claude-3-5-haiku-20241022",
    ]

    private func buildModels(from remoteModels: [AnthropicMetadataModel], preferredModelID: String?) async -> [AIModel] {
        let normalizedPreferredID = preferredModelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        var models: [AIModel] = []
        models.reserveCapacity(remoteModels.count)

        for remote in remoteModels {
            var model = await CatalogModelBuilder.buildCatalogModel(
                providerKind: .anthropic,
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

    /// Keeps the opaque server blocks byte-for-byte at field level while the SSE
    /// response is assembled. Unknown delta shapes deliberately make the replay
    /// unavailable instead of manufacturing a block the next request cannot use.
    private static func mergeReplayDelta(
        _ delta: [String: Any], into replayBlock: inout [String: Any]?, inputJSON: inout String?
    ) {
        guard var block = replayBlock else { return }
        if let text = delta["text"] as? String {
            block["text"] = (block["text"] as? String ?? "") + text
        } else if let thinking = delta["thinking"] as? String {
            block["thinking"] = (block["thinking"] as? String ?? "") + thinking
        } else if let signature = delta["signature"] as? String {
            block["signature"] = (block["signature"] as? String ?? "") + signature
        } else if let partialJSON = delta["partial_json"] as? String {
            inputJSON = (inputJSON ?? "") + partialJSON
        } else {
            // Preserve an explicit invalid marker; completeReplayBlocks rejects it.
            block["__oriveo_invalid_replay_delta"] = true
        }
        replayBlock = block
    }

    private static func completeReplayBlocks(
        blocks: [Int: [String: Any]], order: [Int], inputJSON: [Int: String]
    ) -> [[String: Any]]? {
        guard order.count == Set(order).count else { return nil }
        var completed: [[String: Any]] = []
        for index in order {
            guard var block = blocks[index], block["__oriveo_invalid_replay_delta"] == nil,
                  let type = block["type"] as? String, !type.isEmpty else { return nil }
            if let rawInput = inputJSON[index] {
                guard let inputData = rawInput.data(using: .utf8),
                      let input = try? JSONSerialization.jsonObject(with: inputData) else { return nil }
                block["input"] = input
            }
            completed.append(block)
        }
        return completed.isEmpty ? nil : completed
    }
}


private struct AnthropicMetadataModel {
    var id: String
}


private struct AnthropicChatRequest: Encodable {
    var model: String
    var max_tokens: Int
    var system: String?
    var stream: Bool?
    var cache_control: CacheControl?
    var thinking: Thinking?
    var output_config: OutputConfig?
    var messages: [Message]

    struct Message: Encodable {
        var role: String
        var content: MessageContent
    }

    struct Thinking: Encodable {
        var type: String
        var budget_tokens: Int? = nil
    }

    struct OutputConfig: Encodable {
        var effort: String
    }

    struct CacheControl: Encodable {
        var type: String
    }

    enum MessageContent: Encodable {
        case text(String)
        case blocks([ContentBlock])

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let s): try container.encode(s)
            case .blocks(let b): try container.encode(b)
            }
        }
    }

    struct ContentBlock: Encodable {
        var type: String
        var text: String?
        var source: Source?
        var cache_control: CacheControl?

        struct Source: Encodable {
            var type: String       // "base64"
            var media_type: String // "image/png", "application/pdf"
            var data: String
        }

        struct CacheControl: Encodable {
            var type: String
        }

        private enum CodingKeys: String, CodingKey {
            case type, text, source, cache_control
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(type, forKey: .type)
            if let text { try container.encode(text, forKey: .text) }
            if let source { try container.encode(source, forKey: .source) }
            if let cache_control { try container.encode(cache_control, forKey: .cache_control) }
        }
    }
}

private struct AnthropicChatResponse: Decodable {
    var content: [ContentBlock]?
    var usage: AnthropicUsage?

    struct ContentBlock: Decodable {
        var type: String?
        var text: String?
    }

    var resolvedText: String {
        content?
            .filter { $0.type == "text" }
            .compactMap { $0.text }
            .joined() ?? ""
    }
}

nonisolated private struct AnthropicUsage: Decodable {
    var input_tokens: Int?
    var output_tokens: Int?
    var cache_read_input_tokens: Int?
    var cache_creation_input_tokens: Int?
    var cache_creation: CacheCreation?

    struct CacheCreation: Decodable {
        var ephemeral_5m_input_tokens: Int?
        var ephemeral_1h_input_tokens: Int?

        init(ephemeral_5m_input_tokens: Int? = nil, ephemeral_1h_input_tokens: Int? = nil) {
            self.ephemeral_5m_input_tokens = ephemeral_5m_input_tokens
            self.ephemeral_1h_input_tokens = ephemeral_1h_input_tokens
        }
    }

    init(
        input_tokens: Int? = nil,
        output_tokens: Int? = nil,
        cache_read_input_tokens: Int? = nil,
        cache_creation_input_tokens: Int? = nil,
        cache_creation: CacheCreation? = nil
    ) {
        self.input_tokens = input_tokens
        self.output_tokens = output_tokens
        self.cache_read_input_tokens = cache_read_input_tokens
        self.cache_creation_input_tokens = cache_creation_input_tokens
        self.cache_creation = cache_creation
    }
}

private struct AnthropicMessageStart: Decodable {
    var message: MessageInfo?

    struct MessageInfo: Decodable {
        var usage: AnthropicUsage?
    }
}

private struct AnthropicContentBlockDelta: Decodable {
    var delta: Delta?

    struct Delta: Decodable {
        var type: String?
        var text: String?
    }
}

private struct AnthropicMessageDelta: Decodable {
    var delta: Delta?
    var usage: AnthropicUsage?

    struct Delta: Decodable {
        var stop_reason: String?
    }
}

extension AnthropicService {
    /// Tool legs reuse the same usage parser as ordinary chat: what a leg gets is the usage object of an SSE frame.
    nonisolated static func legUsageBreakdown(usageJSON: [String: Any]) -> UsageBreakdown? {
        guard let data = try? JSONSerialization.data(withJSONObject: usageJSON),
              let usage = try? JSONDecoder().decode(AnthropicUsage.self, from: data) else { return nil }
        return parseUsage(usage)
    }

    nonisolated fileprivate static func parseUsage(_ usage: AnthropicUsage?) -> UsageBreakdown {
        guard let usage else { return UsageBreakdown() }
        let cc = usage.cache_creation
        let write5m = cc?.ephemeral_5m_input_tokens
            ?? usage.cache_creation_input_tokens
            ?? 0
        let write1h = cc?.ephemeral_1h_input_tokens ?? 0
        return UsageBreakdown(
            promptTokens: usage.input_tokens ?? 0,
            cachedInputTokens: usage.cache_read_input_tokens ?? 0,
            cacheCreation5mTokens: write5m,
            cacheCreation1hTokens: write1h,
            completionTokens: usage.output_tokens ?? 0,
            reasoningTokens: 0,
            upstreamCost: nil,
            cacheReadObserved: usage.cache_read_input_tokens != nil,
            cacheWriteObserved: usage.cache_creation_input_tokens != nil
                || usage.cache_creation?.ephemeral_5m_input_tokens != nil
                || usage.cache_creation?.ephemeral_1h_input_tokens != nil
        )
    }

    #if DEBUG
    static func parseUsageForTesting(
        inputTokens: Int?,
        outputTokens: Int?,
        cacheRead: Int?,
        ephemeral5m: Int?,
        ephemeral1h: Int?,
        legacyCacheCreation: Int?
    ) -> UsageBreakdown {
        let cc: AnthropicUsage.CacheCreation?
        if ephemeral5m != nil || ephemeral1h != nil {
            cc = AnthropicUsage.CacheCreation(
                ephemeral_5m_input_tokens: ephemeral5m,
                ephemeral_1h_input_tokens: ephemeral1h
            )
        } else {
            cc = nil
        }
        let usage = AnthropicUsage(
            input_tokens: inputTokens,
            output_tokens: outputTokens,
            cache_read_input_tokens: cacheRead,
            cache_creation_input_tokens: legacyCacheCreation,
            cache_creation: cc
        )
        return parseUsage(usage)
    }
    #endif
}

// MARK: - Protocol entry points with request options: one-line forwards to this service's existing options overloads

extension AnthropicService {
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
