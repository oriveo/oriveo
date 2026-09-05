import Foundation
import OriveoProviderKit

final class MoonshotService: BaseAPIService, ProviderServiceProtocol, CustomBaseURLProvider, BalanceQueryable {
    private let defaultBaseURL = "https://api.moonshot.ai/v1"

    func syncProvider(apiKey: String, preferredModelID: String?) async throws -> ProviderSyncResult {
        try await syncProvider(apiKey: apiKey, preferredModelID: preferredModelID, baseURL: nil)
    }

    func syncProvider(apiKey: String, preferredModelID: String?, baseURL: String) async throws -> ProviderSyncResult {
        try await syncProvider(apiKey: apiKey, preferredModelID: preferredModelID, baseURL: Optional(baseURL))
    }

    func syncProvider(apiKey: String, preferredModelID: String?, baseURL: String?) async throws -> ProviderSyncResult {
        try validateAPIKey(apiKey)
        await MetadataClient.shared.ensureInitialized()
        return ProviderSyncResult(models: [])
    }

    func sendMessage(apiKey: String, modelID: String, messages: [ChatMessage]) async throws -> ProviderChatResult {
        try await sendMessage(
            apiKey: apiKey,
            modelID: modelID,
            messages: messages,
            baseURL: nil,
            reasoningMode: .automatic,
            webSearchEnabled: false,
            requestOptions: ChatRequestOptions()
        )
    }

    func sendMessage(apiKey: String, modelID: String, messages: [ChatMessage], baseURL: String) async throws -> ProviderChatResult {
        try await sendMessage(
            apiKey: apiKey,
            modelID: modelID,
            messages: messages,
            baseURL: Optional(baseURL),
            reasoningMode: .automatic,
            webSearchEnabled: false,
            requestOptions: ChatRequestOptions()
        )
    }

    func sendMessage(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        baseURL: String? = nil,
        reasoningMode: ReasoningMode = .automatic,
        webSearchEnabled: Bool = false,
        requestOptions: ChatRequestOptions = ChatRequestOptions()
    ) async throws -> ProviderChatResult {
        let request = try buildChatRequest(
            modelID: modelID,
            messages: messages,
            apiKey: apiKey,
            baseURL: baseURL,
            stream: false,
            reasoningMode: reasoningMode,
            webSearchEnabled: webSearchEnabled,
            requestOptions: requestOptions
        )
        let response: MoonshotChatCompletionResponse = try await perform(request)
        guard let choice = response.choices.first else { throw ProviderServiceError.emptyResponse }
        let continuationRecipe = RecipeContinuationRuntime.selectedRecipe(
            provider: .moonshot, modelID: modelID, transport: "openai_chat",
            webSearchEnabled: webSearchEnabled, reasoningMode: reasoningMode,
            continuationKind: "replay_reasoning", parser: { $0 == "moonshot_reasoning_v1" }
        )
        if let encoded = RecipeContinuationRuntime.jsonValue([Self.assistantReplayMessage(choice.message)]) {
            try RecipeContinuationRuntime.save(
                messageID: requestOptions.localContinuationMessageID, recipe: continuationRecipe,
                state: ["assistantMessages": encoded]
            )
        }
        let text = (choice.message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let reasoningText = choice.message.reasoning_content?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ProviderServiceError.emptyResponse }
        let breakdown = Self.parseUsage(response.usage)
        let (cost, source) = await MetadataClient.shared.calcCost(
            breakdown: breakdown, modelID: modelID, providerKind: .moonshot
        )
        return ProviderChatResult(
            text: text,
            reasoningText: reasoningText?.isEmpty == false ? reasoningText : nil,
            promptTokens: breakdown.totalInputTokens,
            completionTokens: breakdown.completionTokens,
            estimatedCost: cost,
            usageBreakdown: breakdown,
            costSource: source
        )
    }

    func sendMessageStream(apiKey: String, modelID: String, messages: [ChatMessage]) -> AsyncThrowingStream<StreamEvent, Error> {
        sendMessageStream(
            apiKey: apiKey,
            modelID: modelID,
            messages: messages,
            baseURL: nil,
            reasoningMode: .automatic,
            webSearchEnabled: false,
            requestOptions: ChatRequestOptions()
        )
    }

    func sendMessageStream(apiKey: String, modelID: String, messages: [ChatMessage], baseURL: String) -> AsyncThrowingStream<StreamEvent, Error> {
        sendMessageStream(
            apiKey: apiKey,
            modelID: modelID,
            messages: messages,
            baseURL: Optional(baseURL),
            reasoningMode: .automatic,
            webSearchEnabled: false,
            requestOptions: ChatRequestOptions()
        )
    }

    func sendMessageStream(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        baseURL: String? = nil,
        reasoningMode: ReasoningMode = .automatic,
        webSearchEnabled: Bool = false,
        requestOptions: ChatRequestOptions = ChatRequestOptions()
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var initialRequest: URLRequest
                    if let continuationID = requestOptions.localExplicitContinuationMessageID,
                       let replayRequest = try? self.buildExplicitToolLoopContinuationRequest(
                           messageID: continuationID, apiKey: apiKey, modelID: modelID,
                           messages: messages, baseURL: baseURL, requestOptions: requestOptions
                       ) {
                        // Explicit continue/retry may use a same-process, complete sidecar. Missing,
                        // interrupted, corrupt, or previous-launch state is a clean restart, never a
                        // failed ordinary chat and never an automatic replay.
                        initialRequest = replayRequest
                    } else {
                        initialRequest = try self.buildChatRequest(
                            modelID: modelID, messages: messages, apiKey: apiKey, baseURL: baseURL,
                            stream: true, reasoningMode: reasoningMode, webSearchEnabled: webSearchEnabled,
                            requestOptions: requestOptions
                        )
                    }
                    // Formula is a web capability, not a model default.  A published recipe must
                    // never cause tools/GETs/tool-loop execution when the caller did not request web.
                    let activeRecipe: MetadataClient.CapabilityRecipe? = {
                        guard webSearchEnabled,
                              let candidate = MetadataClient.shared.syncCapabilityRecipe(
                                modelID: modelID, providerKind: .moonshot, capability: "web"
                              ),
                              CapabilityRecipeExecution.mayExecute(candidate),
                              candidate.executionKind == "client_tool_loop",
                              candidate.transport.protocolName == "openai_chat",
                              candidate.continuationKind == "tool_loop" else { return nil }
                        let isFormula = candidate.responseParserKind == "moonshot_formula_web_v1"
                            && candidate.continuationVariant == "fiber"
                            && candidate.formula != nil
                        let isBuiltin = candidate.responseParserKind == "moonshot_builtin_web_v1"
                            && candidate.continuationVariant == "default"
                            && candidate.formula == nil
                        guard isFormula || isBuiltin else { return nil }
                        return candidate
                    }()
                    var formulaToolRegistrations: [FormulaToolRegistration] = []
                    if let formula = activeRecipe?.formula,
                       activeRecipe?.executionKind == "client_tool_loop",
                       activeRecipe?.continuationVariant == "fiber" {
                        let prepared = try await self.addFormulaTools(
                            to: initialRequest, apiKey: apiKey, baseURL: baseURL, formula: formula
                        )
                        initialRequest = prepared.request
                        formulaToolRegistrations = prepared.registrations
                    }

                    let resolved = MetadataClient.shared.syncResolveCatalogModel(
                        modelID: modelID,
                        providerKind: .moonshot
                    )
                    let kimiShape = MetadataClient.shared.syncWebSearchStreamShape(
                        profileName: resolved?.profiles.webSearch
                    )
                    let recipe = activeRecipe
                    let serverLoops = recipe?.maxToolLoops ?? MetadataClient.shared.syncWebSearchMaxToolLoops(
                        profileName: recipe == nil ? resolved?.profiles.webSearch : nil
                    )
                    let maxToolLoops = ToolCallLoop.Limits.effectiveMaxSteps(serverValue: serverLoops)

                    let legRunner = MoonshotToolLoopLegRunner(
                        initialRequest: initialRequest,
                        kimiShape: kimiShape,
                        perform: { [self] request in
                            try await self.bytesWithUnsupportedParamSelfHeal(
                                providerKind: .moonshot, modelID: modelID, request: request
                            )
                        },
                        citationsSink: { citations in continuation.yield(.citations(citations)) }
                    )
                    let registry: ToolRegistry
                    if !webSearchEnabled {
                        registry = .empty
                    } else if let formula = recipe?.formula, recipe?.continuationVariant == "fiber" {
                        registry = ToolRegistry(entries: formulaToolRegistrations.map { registration in
                            MoonshotWebSearchTool(
                                name: registration.name,
                                wireType: registration.wireType,
                                executeCall: { [self] call in
                                    try await self.runFormulaFiber(
                                        call: ProviderToolCall(
                                            providerCallID: call.id, name: call.function.name,
                                            rawArguments: call.function.arguments
                                        ),
                                        apiKey: apiKey, baseURL: baseURL, formula: formula
                                    )
                                }
                            )
                        })
                    } else {
                        registry = ToolRegistry(entries: [MoonshotWebSearchTool(executeCall: { call in
                            MoonshotWebSearchTool.builtinResultContent(for: call)
                        })])
                    }
                    let persistence = MoonshotContinuationPersistence(
                        messageID: requestOptions.localContinuationMessageID, recipe: recipe
                    )
                    let loop = ToolCallLoop(
                        registry: registry,
                        legRunner: legRunner,
                        adapter: OpenAIChatToolAdapter(includesToolNameInResult: true),
                        limits: ToolCallLoop.Limits(maxSteps: maxToolLoops),
                        includesReasoningInAssistantMessage: true,
                        onUnhandledToolCalls: { calls in continuation.yield(.toolCallDeltas(calls)) },
                        onLegCompleted: { record in try await MainActor.run { try persistence.save(record) } }
                    )
                    let progress = MoonshotLoopProgress()
                    let onProgress: ToolCallLoop.ProgressHandler = { event in
                        switch event {
                        case .legStarted:
                            await progress.beginLeg()
                        case let .textDelta(text):
                            await progress.appendText(text)
                            continuation.yield(.delta(text))
                        case let .reasoningDelta(reasoning):
                            if await progress.appendReasoning(reasoning) {
                                continuation.yield(.reasoning("\n\n"))
                            }
                            continuation.yield(.reasoning(reasoning))
                        case .usage, .toolCallsAccepted:
                            break
                        }
                    }
                    var usageSources = [legRunner]
                    let result: ToolCallLoop.Result
                    do {
                        result = try await loop.run(messages: [], onProgress: onProgress)
                    } catch let error where webSearchEnabled && ToolUnsupportedErrorMatcher.matches(error) {
                        guard await progress.text.isEmpty, await progress.reasoning.isEmpty else { throw error }
                        let bareRunner = MoonshotToolLoopLegRunner(
                            initialRequest: try Self.strippingTools(from: initialRequest),
                            kimiShape: kimiShape,
                            perform: { [self] request in
                                try await self.bytesWithUnsupportedParamSelfHeal(
                                    providerKind: .moonshot, modelID: modelID, request: request
                                )
                            },
                            citationsSink: { citations in continuation.yield(.citations(citations)) }
                        )
                        let bareLoop = ToolCallLoop(
                            registry: .empty, legRunner: bareRunner,
                            limits: ToolCallLoop.Limits(maxSteps: 1),
                            onUnhandledToolCalls: { calls in continuation.yield(.toolCallDeltas(calls)) }
                        )
                        result = try await bareLoop.run(messages: [], onProgress: onProgress)
                        usageSources = [bareRunner]
                        CapabilityExecutionRuntime.recordToolsRecovered(owner: "web")
                    }
                    let accumulatedText = await progress.text
                    let accumulatedReasoning = await progress.reasoning
                    var totalUsage = ProviderTokenUsageAccumulator()
                    for source in usageSources {
                        for usage in source.collectedLegUsages { totalUsage.add(usage) }
                    }

                    let trimmedText = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmedText.isEmpty, !result.receivedStructuredToolCalls, !Task.isCancelled {
                        throw ProviderServiceError.emptyResponse
                    }
                    let reasoningReplayRecipe = RecipeContinuationRuntime.selectedRecipe(
                        provider: .moonshot, modelID: modelID, transport: "openai_chat",
                        webSearchEnabled: webSearchEnabled, reasoningMode: reasoningMode,
                        continuationKind: "replay_reasoning", parser: { $0 == "moonshot_reasoning_v1" }
                    )
                    if let encoded = RecipeContinuationRuntime.jsonValue([[
                        "role": "assistant",
                        "content": accumulatedText,
                        "reasoning_content": accumulatedReasoning,
                    ]]) {
                        try RecipeContinuationRuntime.save(
                            messageID: requestOptions.localContinuationMessageID,
                            recipe: reasoningReplayRecipe, state: ["assistantMessages": encoded]
                        )
                    }
                    let breakdown = OpenAICompatibleStreamState.usageBreakdown(from: totalUsage.combined)
                    let (cost, source) = await MetadataClient.shared.calcCost(
                        breakdown: breakdown, modelID: modelID, providerKind: .moonshot
                    )
                    let trimmedReasoning = accumulatedReasoning.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.yield(.done(ProviderChatResult(
                        text: trimmedText,
                        reasoningText: trimmedReasoning.isEmpty ? nil : trimmedReasoning,
                        promptTokens: breakdown.totalInputTokens,
                        completionTokens: breakdown.completionTokens,
                        estimatedCost: cost,
                        usageBreakdown: breakdown,
                        costSource: source
                    )))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Explicit continue/retry entry only. Normal new sends never call this path. It replays a
    /// structurally validated, complete assistant tool-call + tool-result block from local GRDB.
    func buildExplicitToolLoopContinuationRequest(
        messageID: UUID,
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        baseURL: String? = nil,
        requestOptions: ChatRequestOptions = ChatRequestOptions()
    ) throws -> URLRequest {
        guard let snapshot = RecipeContinuationRuntime.load(messageID: messageID),
              snapshot.interrupted == false, snapshot.kind == "tool_loop" else {
            throw ProviderServiceError.invalidConfiguration(detail: "Missing local continuation state.")
        }
        let decision = RequestPreferenceResolver.validateContinuation(.init(
            kind: snapshot.kind, variant: nil, step: 1,
            state: snapshot.state.mapValues(Self.requestPreferenceValue)
        ))
        guard decision.accepted,
              case let .array(completed)? = snapshot.state["completedMessages"] else {
            throw ProviderServiceError.invalidConfiguration(detail: "Invalid local continuation state.")
        }
        var request = try buildChatRequest(
            modelID: modelID, messages: messages, apiKey: apiKey, baseURL: baseURL, stream: true,
            reasoningMode: .automatic, webSearchEnabled: false, requestOptions: requestOptions
        )
        var body = try requestJSON(from: request)
        var replay = body["messages"] as? [[String: Any]] ?? []
        let completedMessages: [[String: Any]] = completed.compactMap { value -> [String: Any]? in
            guard case let .object(object) = value else { return nil }
            return object.mapValues { $0.foundationValue }
        }
        // ChatRequestBuilder's explicit continue snapshot ends with a partial target assistant
        // followed by a synthetic user continue instruction. Replace that partial frame with the
        // opaque complete assistant/tool block and insert it *before* the new user turn.
        let insertAt: Int
        if let lastUser = replay.lastIndex(where: { $0["role"] as? String == "user" }) {
            var target = lastUser
            if target > 0, replay[target - 1]["role"] as? String == "assistant" {
                replay.remove(at: target - 1)
                target -= 1
            }
            insertAt = target
        } else {
            insertAt = replay.count
        }
        replay.insert(contentsOf: completedMessages, at: insertAt)
        body["messages"] = replay
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - Balance

    func fetchBalance(apiKey: String, baseURL: String?) async throws -> ProviderBalance {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BalanceQueryError.keyInvalid(detail: "Missing API key.")
        }
        let origin = balanceOriginFrom(baseURL, fallback: "https://api.moonshot.ai")
        guard let url = URL(string: "\(origin)/v1/users/me/balance") else {
            throw BalanceQueryError.network(detail: "Invalid Moonshot balance URL.")
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
            throw BalanceQueryError.keyInvalid(detail: "Moonshot rejected API key (\(http.statusCode)).")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw BalanceQueryError.network(detail: "Moonshot /balance HTTP \(http.statusCode).")
        }
        struct BalanceResponse: Decodable {
            struct DataField: Decodable {
                let available_balance: Double?
                let voucher_balance: Double?
                let cash_balance: Double?
            }
            let data: DataField?
        }
        let decoded: BalanceResponse
        do {
            decoded = try decoder.decode(BalanceResponse.self, from: data)
        } catch {
            throw BalanceQueryError.decoding(detail: error.localizedDescription)
        }
        let host = URL(string: origin)?.host?.lowercased() ?? ""
        let currency = host.hasSuffix("moonshot.cn") ? "CNY" : "USD"
        return ProviderBalance(
            currency: currency,
            total: decoded.data?.available_balance ?? 0,
            granted: decoded.data?.voucher_balance,
            topUp: decoded.data?.cash_balance,
            fetchedAt: Date()
        )
    }

    private func requestJSON(from request: URLRequest) throws -> [String: Any] {
        guard let body = request.httpBody,
              let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw ProviderServiceError.invalidConfiguration(detail: "Invalid Kimi request payload.")
        }
        return json
    }

    private struct FormulaToolRegistration {
        let name: String
        let wireType: String
    }

    private func addFormulaTools(
        to request: URLRequest, apiKey: String, baseURL: String?, formula: MetadataClient.CapabilityRecipeFormula
    ) async throws -> (request: URLRequest, registrations: [FormulaToolRegistration]) {
        var toolsRequest = URLRequest(url: try formulaURL(baseURL: baseURL, path: formula.toolsPath))
        toolsRequest.httpMethod = "GET"; toolsRequest.timeoutInterval = 30; applyHeaders(to: &toolsRequest, apiKey: apiKey)
        let (data, response) = try await session.data(for: toolsRequest)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let formulaTools = object["tools"] as? [Any], !formulaTools.isEmpty else {
            throw ProviderServiceError.invalidConfiguration(detail: "Moonshot Formula tools unavailable.")
        }
        var body = try requestJSON(from: request)
        let builderTools = body["tools"] as? [Any] ?? []
        var identities = Set(builderTools.compactMap(Self.toolIdentity))
        var registrations: [FormulaToolRegistration] = []
        for tool in formulaTools {
            guard let object = tool as? [String: Any],
                  let identity = Self.toolIdentity(tool),
                  let wireType = object["type"] as? String,
                  !wireType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  identities.insert(identity).inserted else {
                throw ProviderServiceError.invalidConfiguration(detail: "Moonshot Formula tool name conflict.")
            }
            registrations.append(FormulaToolRegistration(name: identity, wireType: wireType))
        }
        // Builder-owned tools always stay first; Formula is an additive, dynamically fetched contribution.
        body["tools"] = builderTools + formulaTools
        var updated = request
        updated.httpBody = try JSONSerialization.data(withJSONObject: body)
        return (updated, registrations)
    }

    private func runFormulaFiber(
        call: ProviderToolCall, apiKey: String, baseURL: String?, formula: MetadataClient.CapabilityRecipeFormula
    ) async throws -> String {
        var request = URLRequest(url: try formulaURL(baseURL: baseURL, path: formula.fibersPath))
        request.httpMethod = "POST"; request.timeoutInterval = 60; applyHeaders(to: &request, apiKey: apiKey)
        // arguments must remain the provider-returned JSON string: parsing/re-serializing changes bytes.
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": call.name, "arguments": call.rawArguments
        ])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let context = object["context"] as? [String: Any],
              let output = (context["output"] as? String) ?? (context["encrypted_output"] as? String) else {
            throw ProviderServiceError.invalidConfiguration(detail: "Moonshot Formula fiber output unavailable.")
        }
        return output
    }

    private func formulaURL(baseURL: String?, path: String) throws -> URL {
        guard path.hasPrefix("/v1/formulas/"), !path.contains(".."), !path.contains("://"),
              !path.contains("?") && !path.contains("#"),
              var components = URLComponents(string: normalizedBaseURL(baseURL, default: defaultBaseURL)) else {
            throw ProviderServiceError.invalidConfiguration(detail: "Invalid Moonshot Formula endpoint.")
        }
        // Start with the actual chat API root instead of resetting to origin. A proxy such as
        // https://proxy.example/custom/v1 must retain `/custom/v1`; recipe's `/v1` prefix is a
        // protocol marker, not permission to escape that configured root.
        let basePath = components.path.hasSuffix("/chat/completions")
            ? String(components.path.dropLast("/chat/completions".count))
            : components.path
        let normalizedRoot = basePath.hasSuffix("/v1") ? String(basePath.dropLast(3)) : basePath
        components.path = normalizedRoot + path
        components.query = nil; components.fragment = nil
        guard let url = components.url else { throw ProviderServiceError.invalidConfiguration(detail: "Invalid Moonshot Formula endpoint.") }
        return url
    }

    private static func strippingTools(from request: URLRequest) throws -> URLRequest {
        guard let body = request.httpBody,
              var json = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw ProviderServiceError.invalidConfiguration(detail: "Invalid Kimi request payload.")
        }
        json.removeValue(forKey: "tools")
        json.removeValue(forKey: "tool_choice")
        var stripped = request
        stripped.httpBody = try JSONSerialization.data(withJSONObject: json)
        return stripped
    }

    private func buildChatRequest(
        modelID: String,
        messages: [ChatMessage],
        apiKey: String,
        baseURL: String?,
        stream: Bool,
        reasoningMode: ReasoningMode,
        webSearchEnabled: Bool,
        requestOptions: ChatRequestOptions
    ) throws -> URLRequest {
        try validateAPIKey(apiKey)
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderServiceError.invalidConfiguration(detail: "Missing model identifier.")
        }

        var request = URLRequest(url: URL(string: "\(normalizedBaseURL(baseURL, default: defaultBaseURL))/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = stream ? 120 : 60
        applyHeaders(to: &request, apiKey: apiKey)
        let resolved = MetadataClient.shared.syncResolveCatalogModel(modelID: modelID, providerKind: .moonshot)
        let recipeLegacyInput = CapabilityRecipeRequestCompiler.legacyInput(
            providerKind: .moonshot, modelID: modelID,
            webSearchEnabled: webSearchEnabled, reasoningMode: reasoningMode
        )
        let capabilityIntent = CapabilityEvidenceProductionAdapter.finalChatIntent(
            messages: messages, request: request, effectiveTransport: resolved?.transport ?? "",
            model: requestOptions.capabilityEvidenceModel,
            requestedReasoningMode: recipeLegacyInput.reasoningMode, webSearchEnabled: recipeLegacyInput.webSearchEnabled
        )

        var apiMessages: [[String: Any]] = []
        let systemPrompt = requestOptions.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !systemPrompt.isEmpty {
            apiMessages.append(["role": "system", "content": systemPrompt])
        }
        apiMessages.append(contentsOf: capabilityIntent.outboundMessages.map { Self.buildRequestMessage($0) })
        let reasoningReplayRecipe = RecipeContinuationRuntime.selectedRecipe(
            provider: .moonshot, modelID: modelID, transport: resolved?.transport ?? "openai_chat",
            webSearchEnabled: webSearchEnabled, reasoningMode: reasoningMode,
            continuationKind: "replay_reasoning", parser: { $0 == "moonshot_reasoning_v1" }
        )
        if reasoningReplayRecipe != nil,
           let assistantMessages = RecipeContinuationRuntime.replayAssistantMessages(
                explicitMessageID: requestOptions.localExplicitContinuationMessageID
           ) {
            apiMessages.append(contentsOf: assistantMessages)
        }

        var payload: [String: Any] = [
            "model": modelID,
            "stream": stream,
            "messages": apiMessages,
        ]
        if stream {
            payload["stream_options"] = ["include_usage": true]
        }
        if recipeLegacyInput.usesLegacyMapping, capabilityIntent.webSearchEnabled,
           let webSearchMerge = ProfileParamsResolver.webSearchMergeParams(
            providerKind: .moonshot,
            modelID: modelID,
            profileName: resolved?.profiles.webSearch
           ) {
            ProfileParamsResolver.deepMerge(&payload, webSearchMerge)
        }
        if recipeLegacyInput.usesLegacyMapping, let allowedReasoningMode = capabilityIntent.reasoningMode,
           let reasoningMerge = ProfileParamsResolver.reasoningMergeParams(
            providerKind: .moonshot,
            modelID: modelID,
            reasoningMode: allowedReasoningMode,
            resolved: resolved
        ) {
            ProfileParamsResolver.deepMerge(&payload, reasoningMerge)
        }
        CapabilityRecipeRequestCompiler.apply(
            to: &payload, providerKind: .moonshot, modelID: modelID,
            transport: resolved?.transport ?? "", webSearchEnabled: webSearchEnabled,
            reasoningMode: reasoningMode, capabilityPreferences: requestOptions.capabilityPreferences
        )
        request.httpBody = try encodeChatBody(&payload, options: requestOptions, resolved: resolved, finalRequest: request)
        return request
    }

    private static func buildRequestMessage(_ msg: ChatMessage, model: AIModel? = nil) -> [String: Any] {
        let attachments = msg.attachments ?? []
        let imageAttachments = attachments.filter { $0.kind == .image }
        let videoAttachments = attachments.filter { $0.kind == .video }

        let (combinedText, _) = BaseAPIService.injectFileAttachmentsAsText(
            userText: msg.text,
            attachments: attachments,
            provider: .moonshot,
            model: model
        )

        guard !imageAttachments.isEmpty || !videoAttachments.isEmpty else {
            return ["role": msg.role.rawValue, "content": combinedText]
        }

        var contentParts: [[String: Any]] = [["type": "text", "text": combinedText]]
        for image in imageAttachments {
            let dataURL = image.resolvedDataURL
            guard !dataURL.isEmpty else { continue }
            contentParts.append(["type": "image_url", "image_url": ["url": dataURL]])
        }
        for video in videoAttachments {
            let dataURL = video.resolvedDataURL
            guard !dataURL.isEmpty else { continue }
            contentParts.append(["type": "video_url", "video_url": ["url": dataURL]])
        }
        return ["role": msg.role.rawValue, "content": contentParts]
    }

    private func buildModels(from modelIDs: [String], preferredModelID: String?) async -> [AIModel] {
        let normalizedPreferredID = preferredModelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        var models: [AIModel] = []
        models.reserveCapacity(modelIDs.count)
        for modelID in modelIDs {
            var model = await CatalogModelBuilder.buildCatalogModel(
                providerKind: .moonshot,
                runtimeModelId: modelID,
                fallbackName: modelID,
                fallbackContextLength: nil,
                createdAt: nil
            )
            if normalizedPreferredID == modelID {
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

    private static let knownTextModelIDs = [
        "kimi-k2.6",
        "kimi-k2.5",
        "moonshot-v1-128k",
    ]
}

private struct MoonshotUsage: Decodable {
    let prompt_tokens: Int?
    let completion_tokens: Int?
    let cached_tokens: Int?

    init(
        prompt_tokens: Int? = nil,
        completion_tokens: Int? = nil,
        cached_tokens: Int? = nil
    ) {
        self.prompt_tokens = prompt_tokens
        self.completion_tokens = completion_tokens
        self.cached_tokens = cached_tokens
    }
}

extension MoonshotService {
    fileprivate static func parseUsage(_ usage: MoonshotUsage?) -> UsageBreakdown {
        guard let usage else { return UsageBreakdown() }
        let cached = usage.cached_tokens ?? 0
        let total = usage.prompt_tokens ?? 0
        return UsageBreakdown(
            promptTokens: max(0, total - cached),
            cachedInputTokens: cached,
            cacheCreation5mTokens: 0,
            cacheCreation1hTokens: 0,
            completionTokens: usage.completion_tokens ?? 0,
            reasoningTokens: 0,
            upstreamCost: nil,
            cacheReadObserved: usage.cached_tokens != nil
        )
    }

    #if DEBUG
    static func parseUsageForTesting(
        promptTokens: Int?,
        completionTokens: Int?,
        cachedTokensTopLevel: Int?
    ) -> UsageBreakdown {
        let usage = MoonshotUsage(
            prompt_tokens: promptTokens,
            completion_tokens: completionTokens,
            cached_tokens: cachedTokensTopLevel
        )
        return parseUsage(usage)
    }
    #endif
}

private struct MoonshotChatCompletionResponse: Decodable {
    let choices: [MoonshotChoice]
    let usage: MoonshotUsage?
}

private struct MoonshotChoice: Decodable {
    let message: MoonshotMessage
}

private struct MoonshotMessage: Decodable {
    let content: String?
    let reasoning_content: String?
    let tool_calls: [MoonshotToolCall]?
}

private struct MoonshotToolCall: Decodable {
    let id: String?
    let type: String?
    let function: MoonshotToolFunction?

    func asRequestObject() -> [String: Any] {
        var object: [String: Any] = [:]
        if let id { object["id"] = id }
        if let type { object["type"] = type }
        if let function { object["function"] = function.asRequestObject() }
        return object
    }
}

private struct MoonshotToolFunction: Decodable {
    let name: String?
    let arguments: String?

    func asRequestObject() -> [String: Any] {
        var object: [String: Any] = [:]
        if let name { object["name"] = name }
        if let arguments { object["arguments"] = arguments }
        return object
    }
}

private extension MoonshotService {
    static func assistantReplayMessage(_ message: MoonshotMessage) -> [String: Any] {
        var result: [String: Any] = [
            "role": "assistant",
            "content": message.content ?? "",
            "reasoning_content": message.reasoning_content ?? "",
        ]
        if let calls = message.tool_calls, !calls.isEmpty {
            result["tool_calls"] = calls.map { $0.asRequestObject() }
        }
        return result
    }

    static func jsonValue(_ value: Any) -> MetadataClient.JSONValue {
        if let value = value as? String { return .string(value) }
        if let value = value as? Bool { return .bool(value) }
        if let value = value as? NSNumber { return .number(value.doubleValue) }
        if let value = value as? [String: Any] { return .object(value.mapValues(jsonValue)) }
        if let value = value as? [Any] { return .array(value.map(jsonValue)) }
        return .null
    }

    static func requestPreferenceValue(_ value: MetadataClient.JSONValue) -> RequestPreferenceJSONValue {
        switch value {
        case .null: return .null
        case let .bool(value): return .bool(value)
        case let .number(value): return .double(value)
        case let .string(value): return .string(value)
        case let .array(value): return .array(value.map(requestPreferenceValue))
        case let .object(value): return .object(value.mapValues(requestPreferenceValue))
        }
    }

    static func toolIdentity(_ value: Any) -> String? {
        guard let object = value as? [String: Any] else { return nil }
        if let function = object["function"] as? [String: Any], let name = function["name"] as? String { return name }
        return object["name"] as? String
    }
}
