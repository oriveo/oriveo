import Foundation
import GRDB
import OriveoProviderKit
import Testing

@testable import Oriveo

// MARK: - Shared fixtures (shared/test-fixtures/provider-toolcall, one directory for all platforms)

private enum LoopFixtures {
    static let directory = ["shared", "test-fixtures", "provider-toolcall"]

    static func url(_ name: String) throws -> URL {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = (directory + [name]).reduce(cursor) { $0.appendingPathComponent($1) }
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    static func data(_ name: String) throws -> Data { try Data(contentsOf: url(name)) }

    struct UnsupportedContract: Decodable {
        struct Rules: Decodable {
            let status_range: [Int]
            let status_excluded: [Int]
            let subject_patterns: [String]
            let verdict_patterns: [String]
        }
        struct Case: Decodable {
            let id: String
            let status: Int
            let body: String
            let expect: Bool
        }
        let rules: Rules
        let cases: [Case]
    }
}

/// A per-request scripted mock: replays (status, body) in order and records every request (URL / headers / body).
private final class ScriptedURLProtocol: URLProtocol, @unchecked Sendable {
    struct Recorded: @unchecked Sendable {
        let url: URL?
        let headers: [String: String]
        let body: [String: Any]
    }

    nonisolated(unsafe) static var script: [(status: Int, body: Data)] = []
    nonisolated(unsafe) static var recorded: [Recorded] = []
    private static let lock = NSLock()

    static func reset(_ responses: [(Int, String)]) {
        lock.withLock {
            script = responses.map { ($0.0, Data($0.1.utf8)) }
            recorded = []
        }
    }

    static func snapshot() -> [Recorded] { lock.withLock { recorded } }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptedURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let bodyData: Data = {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return Data() }
            stream.open(); defer { stream.close() }
            var data = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let count = stream.read(buffer, maxLength: 4096)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            return data
        }()
        let body = (try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]) ?? [:]
        let next: (status: Int, body: Data) = Self.lock.withLock {
            Self.recorded.append(Recorded(url: request.url, headers: request.allHTTPHeaderFields ?? [:], body: body))
            return Self.script.isEmpty ? (200, Data("data: [DONE]\n\n".utf8)) : Self.script.removeFirst()
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: next.status, httpVersion: nil,
            headerFields: ["Content-Type": next.status == 200 ? "text/event-stream" : "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: next.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func sse(_ frames: [String]) -> String {
    frames.map { "data: \($0)\n\n" }.joined() + "data: [DONE]\n\n"
}

private func textLeg(_ text: String) -> String {
    sse([
        #"{"choices":[{"delta":{"content":"\#(text)"}}]}"#,
        #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#,
    ])
}

private let toolsUnsupported400 = #"{"error":{"message":"This model does not support tools.","type":"invalid_request_error"}}"#

/// One tool definition for the legs that only need a non-empty tools list.
private func weatherTools() throws -> [ToolLoopToolDefinition] {
    [ToolLoopToolDefinition(function: .init(
        name: "get_weather",
        description: "Get the weather for a city.",
        parameters: try ToolJSONValue.make([
            "type": "object",
            "properties": ["city": ["type": "string"]],
            "required": ["city"],
        ])
    ))]
}

@MainActor
private func makeRelayProvider(toolCall: Bool? = nil, baseURL: String = "https://relay.test/v1") -> (Provider, AIModel) {
    var model = AIModel(
        id: "relay-agent-model", name: "Relay Agent", capabilities: [.text],
        reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: "standard"
    )
    model.toolCall = toolCall
    let provider = Provider(
        id: UUID(), kind: .relay, status: .connected, models: [model], catalogModels: [],
        apiKey: "relay-key", apiKeyPreview: "...key", baseURLText: baseURL,
        relayRequested: RelayRequestedConfig(transport: .openaiChatCompletions)
    )
    return (provider, model)
}

private func moonshotReasoningMetadataJSON(modelID: String) throws -> String {
    let runtime = try CapabilityRuntimeFixtures.runtimeEnvelopeJSON()
    let controls = try CapabilityRuntimeFixtures.controlsJSON(
        .init(
            capability: "reasoning",
            recipeRef: "moonshot.chat.reasoning.v1",
            availableIntents: try CapabilityRuntimeFixtures.reasoningIntents(
                ofRecipe: "moonshot.chat.reasoning.v1"
            )
        )
    )
    return """
    {
      "version": 1,
      "updatedAt": "2026-08-24T00:00:00Z",
      "capabilityRuntime": \(runtime),
      "providers": {
        "moonshot": {
          "displayName": "Moonshot",
          "transport": {
            "baseUrl": "https://api.moonshot.ai/v1",
            "endpoints": { "chat": "/chat/completions" }
          },
          "resolveMap": { "\(modelID)": "\(modelID)" },
          "models": {
            "\(modelID)": {
              "canonicalModelId": "\(modelID)",
              "displayName": "Kimi fixture",
              "transport": "openai_chat",
              "capabilities": ["text", "reasoning"],
              "capabilityControls": \(controls),
              "toolCall": true
            }
          }
        }
      }
    }
    """
}

/// A standalone GRDB database (runs the full migrator) that leaves the DatabaseManager's current user pool alone.
private func makeMemoryStore() throws -> ToolCallMemoryStore {
    let uid = "toolcall-memory-\(UUID().uuidString)"
    try FileManager.default.createDirectory(at: AppSessionStore.userDir(for: uid), withIntermediateDirectories: true)
    let pool = try DatabasePool(
        path: AppSessionStore.databasePath(for: uid).path,
        configuration: DatabaseSchema.makeConfiguration()
    )
    let files = AttachmentFileStore(rootDirectory: AppSessionStore.filesDir(for: uid))
    try DatabaseSchema.makeMigrator(attachmentFileStore: files).migrate(pool)
    return ToolCallMemoryStore(poolProvider: { pool })
}

// MARK: - 4xx contract and registry shape

@Suite("Tools-unsupported 4xx contract (shared fixture)", .sharedProcessState)
struct ToolUnsupportedErrorMatcherContractTests {
    @Test("The pattern lists match the shared contract file verbatim, and every case is judged as its expect says")
    func patternsMatchSharedContract() throws {
        let contract = try JSONDecoder().decode(LoopFixtures.UnsupportedContract.self, from: LoopFixtures.data("tool-unsupported-4xx.json"))
        #expect(contract.rules.subject_patterns == ToolUnsupportedErrorMatcher.subjectPatterns)
        #expect(contract.rules.verdict_patterns == ToolUnsupportedErrorMatcher.verdictPatterns)
        #expect(contract.rules.status_range == [ToolUnsupportedErrorMatcher.statusRange.lowerBound, ToolUnsupportedErrorMatcher.statusRange.upperBound])
        #expect(Set(contract.rules.status_excluded) == ToolUnsupportedErrorMatcher.excludedStatuses)
        #expect(contract.cases.count >= 10)
        for item in contract.cases {
            #expect(
                ToolUnsupportedErrorMatcher.matches(statusCode: item.status, body: item.body) == item.expect,
                "case \(item.id) is judged differently from the contract"
            )
        }
    }

    @Test("The mapped-error entry only accepts ProviderServiceError.upstream with a status outside the excluded set")
    func mappedErrorEntry() {
        #expect(ToolUnsupportedErrorMatcher.matches(ProviderServiceError.upstream(statusCode: 400, detail: "Unrecognized request argument supplied: tools")))
        #expect(!ToolUnsupportedErrorMatcher.matches(ProviderServiceError.rateLimited(detail: "tools unsupported")))
        #expect(!ToolUnsupportedErrorMatcher.matches(ProviderServiceError.invalidAPIKey(detail: "tools unsupported")))
        #expect(!ToolUnsupportedErrorMatcher.matches(ProviderServiceError.upstream(statusCode: 500, detail: "tools unsupported")))
    }

    @Test("Registry shape: names are a unique whitelist, registration order is the tools order, and unknown names are not found")
    func registryShape() {
        let web = ToolRegistry(entries: [MoonshotWebSearchTool(executeCall: { _ in "{}" })])
        #expect(web.entry(named: "$web_search")?.wireType == "builtin_function")
        #expect(web.entry(named: "get_weather") == nil)
        #expect(web.definitions.isEmpty, "the definitions of server-side built-in tools are injected into the request body by the recipe, not sent from the registry")
        #expect(ToolCallCapabilityPolicy.localAdapterTransports == Set(ToolProtocolAdapters.available.keys), "the local adapter set comes only from ToolProtocolAdapters.available")
        #expect(ToolCallCapabilityPolicy.localAdapterTransports.contains(TransportKind.openaiChat.rawValue))
    }
}

// MARK: - Connection-level memory

@Suite("Connection-level tool memory", .serialized, .sharedProcessState)
struct ToolCallMemoryStoreTests {
    @Test("GRDB round trip: write true/false, read back, clear a whole connection")
    func roundTrip() throws {
        let store = try makeMemoryStore()
        let connection = UUID()
        #expect(store.lookup(connectionID: connection, modelID: "m") == nil)
        #expect(store.record(connectionID: connection, modelID: "m", toolCall: false, reason: .toolsRejected4xx))
        let first = try #require(store.lookup(connectionID: connection, modelID: "m"))
        #expect(first.toolCall == false)
        #expect(first.reason == ToolCallMemoryReason.toolsRejected4xx.rawValue)
        #expect(store.record(connectionID: connection, modelID: "m", toolCall: true, reason: .structuredToolCalls))
        #expect(store.lookup(connectionID: connection, modelID: "m")?.toolCall == true)
        #expect(store.record(connectionID: connection, modelID: "other", toolCall: false, reason: .toolsRejected4xx))
        #expect(store.count() == 2)
        store.clear(connectionID: connection)
        #expect(store.lookup(connectionID: connection, modelID: "m") == nil)
        #expect(store.count() == 0)
    }

    @Test("A revision change voids only the rejection memory (false); an observed support (true) is kept")
    func factsRevisionVoidsOnlyRejection() throws {
        let store = try makeMemoryStore()
        let connection = UUID()
        #expect(store.record(connectionID: connection, modelID: "yes", toolCall: true, reason: .structuredToolCalls, factsRevision: "r0"))
        #expect(store.record(connectionID: connection, modelID: "no", toolCall: false, reason: .toolsRejected4xx, factsRevision: "r0"))
        #expect(store.lookup(connectionID: connection, modelID: "yes", currentFactsRevision: "r1")?.toolCall == true)
        #expect(store.lookup(connectionID: connection, modelID: "no", currentFactsRevision: "r1") == nil)
        #expect(store.lookup(connectionID: connection, modelID: "no", currentFactsRevision: "r0")?.toolCall == false)
    }

    @Test("Decision priority: first-party / Relay declaration > memory > unknown (fail open); memory only applies to Relay / subscription / manual models")
    @MainActor
    func decisionPriority() throws {
        let store = try makeMemoryStore()
        let (relay, model) = makeRelayProvider(toolCall: nil)
        // unknown + no memory => fail open
        let open = ToolCallCapabilityPolicy.decide(provider: relay, model: model, memory: store)
        #expect(open.verdict == nil && open.source == .unknown && open.allowed && open.decided)
        // Memory false => tools are not sent. A Relay false is recorded by the production write entry as a toolCall negative cache and no longer writes the old tool memory.
        defer { RelayNegativeCache.shared.clearConnection(relay.id.uuidString) }
        RelayRejectionRecording.rememberToolCall(
            provider: relay, model: model, toolCall: false, reason: .toolsRejected4xx, statusCode: 422, sentTransport: .openaiChatCompletions, memory: store
        )
        let remembered = ToolCallCapabilityPolicy.decide(provider: relay, model: model, memory: store)
        #expect(remembered.verdict == false && remembered.source == .memory && !remembered.allowed)
        // A Relay's local declaration beats memory
        let (declaredRelay, declaredModel) = makeRelayProvider(toolCall: true)
        store.record(connectionID: declaredRelay.id, modelID: declaredModel.id, toolCall: false, reason: .toolsRejected4xx)
        let declared = ToolCallCapabilityPolicy.decide(provider: declaredRelay, model: declaredModel, memory: store)
        #expect(declared.verdict == true && declared.source == .relayDeclaration && declared.allowed)
        // Relay auto => the first-send protocol is taken as the final transport => decided
        var autoRelay = relay
        autoRelay.relayRequested = RelayRequestedConfig(transport: .auto)
        let autoDecision = ToolCallCapabilityPolicy.decide(provider: autoRelay, model: model, memory: store)
        #expect(autoDecision.decided)
        #expect(autoDecision.transport == ToolCallCapabilityPolicy.transportKindName(
            for: RelayFirstSendTransport.current(provider: autoRelay, model: model)
        ))
        // Scope: an official catalog connection does not use memory
        let official = Provider(
            id: UUID(), kind: .openAI, status: .connected, models: [model], catalogModels: [],
            apiKey: "k", apiKeyPreview: "k", baseURLText: nil
        )
        #expect(!ToolCallCapabilityPolicy.memoryEligible(provider: official, model: model))
        var manual = model
        manual.isManual = true
        #expect(ToolCallCapabilityPolicy.memoryEligible(provider: official, model: manual))
        var subscription = official
        subscription.authMode = .subscription
        #expect(ToolCallCapabilityPolicy.memoryEligible(provider: subscription, model: model))
    }
}

// MARK: - Generic loop production path

@Suite("Generic tool loop production path", .serialized, .sharedProcessState)
struct ToolCallLoopProductionTests {
    @Test("An official model with no tool_call evidence but a top-level toolCall=true is unknown (not judged supported, and the top-level field is not a fallback)")
    @MainActor
    func officialToolCallWithoutEvidenceIsUnknown() async throws {
        let modelID = "kimi-tool-evidence-fixture"
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: try moonshotReasoningMetadataJSON(modelID: modelID))
        let resolved = try #require(MetadataClient.shared.syncResolveCatalogModel(modelID: modelID, providerKind: .moonshot))
        #expect(resolved.toolCall == true, "precondition: the catalog's top-level toolCall=true")
        let model = AIModel(
            id: modelID, name: "Kimi fixture", capabilities: [.text],
            reasoningModeAvailable: false, isAvailable: true, isDefault: true,
            priceTier: "standard", toolCall: true
        )
        let provider = Provider(
            id: UUID(), kind: .moonshot, status: .connected, models: [model], catalogModels: [],
            apiKey: "sk-kimi", apiKeyPreview: "...kimi", baseURLText: nil
        )
        let verdict = ToolCallCapabilityPolicy.catalogVerdict(provider: provider, model: model)
        #expect(verdict.verdict == nil)
        #expect(verdict.source == .unknown)
        let decision = ToolCallCapabilityPolicy.decide(provider: provider, model: model, memory: try makeMemoryStore())
        #expect(decision.verdict == nil)
        #expect(decision.source == .unknown)
    }

    @Test("openai_chat fails closed when the tool_calls of the raw replay differ from this leg's")
    func mismatchedAssistantReplayFallsBackToNeutralMessage() throws {
        let adapter = OpenAIChatToolAdapter()
        let call = ToolLoopToolCall(
            id: "call-current",
            function: .init(name: "get_weather", arguments: #"{"city":"Melbourne"}"#)
        )
        let stale = try ToolJSONValue.make([
            "role": "assistant",
            "content": "",
            "reasoning_content": "must-not-cross",
            "tool_calls": [[
                "id": "call-stale",
                "type": "function",
                "function": ["name": "get_weather", "arguments": #"{"city":"Melbourne"}"#],
            ]],
        ])
        let message = adapter.encodeAssistantToolCalls(
            text: "", reasoning: nil, toolCalls: [call], replayBlocks: [],
            assistantReplay: stale
        )

        let conversation = try adapter.encodeConversation([message])
        let messages = try #require(conversation.messages as? [[String: Any]])
        let assistant = try #require(messages.first)
        #expect(assistant["reasoning_content"] == nil)
        let calls = try #require(assistant["tool_calls"] as? [[String: Any]])
        #expect(calls.first?["id"] as? String == "call-current")
    }

    @Test("openai_chat degrades a corrupt raw replay to a neutral message without throwing")
    func malformedAssistantReplayFallsBackWithoutThrowing() throws {
        let adapter = OpenAIChatToolAdapter()
        let call = ToolLoopToolCall(
            id: "call-current",
            function: .init(name: "get_weather", arguments: #"{"city":"Melbourne"}"#)
        )
        let malformed = ToolJSONValue.object([
            "role": .string("assistant"),
            "content": .number(.nan),
            "reasoning_content": .string("must-not-cross"),
            "tool_calls": .array([]),
        ])
        let message = adapter.encodeAssistantToolCalls(
            text: "", reasoning: nil, toolCalls: [call], replayBlocks: [],
            assistantReplay: malformed
        )

        let conversation = try adapter.encodeConversation([message])
        let messages = try #require(conversation.messages as? [[String: Any]])
        let assistant = try #require(messages.first)
        #expect(assistant["reasoning_content"] == nil)
        #expect((assistant["tool_calls"] as? [[String: Any]])?.first?["id"] as? String == "call-current")
    }

    @Test("Tools-unsupported 400 -> memory false -> resend without tools -> third time no tools at all; 429/401 write no memory")
    @MainActor
    func memoryNegativePath() async throws {
        await MetadataClient.shared.resetForTesting()
        let store = try makeMemoryStore()
        let (relay, model) = makeRelayProvider(toolCall: nil)
        let tools = try weatherTools()
        let userMessage = ToolLoopMessage(role: "user", content: "plan")

        // First time: unknown fails open, the request body carries tools, and the upstream answers 400 "tools not supported"
        #expect(ToolCallCapabilityPolicy.decide(provider: relay, model: model, memory: store).allowed)
        ScriptedURLProtocol.reset([(400, toolsUnsupported400), (200, textLeg("Plain answer"))])
        let runner = try OpenAIChatToolLoopLegRunner(
            provider: relay, model: model, modelID: model.id, reasoningMode: .automatic,
            toolCallMemory: store, session: ScriptedURLProtocol.session()
        )
        var matched = false
        do {
            for try await _ in runner.run(request: ToolLoopLegRequest(messages: [userMessage], tools: tools, toolChoice: .auto)) {}
        } catch {
            matched = ToolUnsupportedErrorMatcher.matches(error)
            #expect(matched, "the 400 mapped by the production leg runner must match the shared contract patterns: \(error)")
        }
        #expect(matched)
        #expect((ScriptedURLProtocol.snapshot().first?.body["tools"] as? [Any])?.isEmpty == false)
        // ChatManager writes memory false in the same branch (rememberToolCallCapability -> RelayRejectionRecording), through the same production entry;
        // a Relay is recorded as a toolCall negative cache.
        defer { RelayNegativeCache.shared.clearConnection(relay.id.uuidString) }
        RelayRejectionRecording.rememberToolCall(
            provider: relay, model: model, toolCall: false, reason: .toolsRejected4xx, statusCode: 400, sentTransport: .openaiChatCompletions, memory: store
        )

        // Second time: the fallback leg, same leg runner, without tools
        var text = ""
        for try await event in runner.run(request: ToolLoopLegRequest(messages: [userMessage], tools: [], toolChoice: .none)) {
            if case let .textDelta(delta) = event { text += delta }
        }
        #expect(text == "Plain answer")
        let second = try #require(ScriptedURLProtocol.snapshot().last)
        #expect(second.body["tools"] == nil)
        #expect(second.body["tool_choice"] == nil)

        // Third time: with memory false the leg runner's outbound gate also rejects a leg that carries tools (no request is sent)
        #expect(ToolCallCapabilityPolicy.decide(provider: relay, model: model, memory: store).allowed == false)
        let before = ScriptedURLProtocol.snapshot().count
        let rememberedRunner = try OpenAIChatToolLoopLegRunner(
            provider: relay, model: model, modelID: model.id, reasoningMode: .automatic,
            toolCallMemory: store, session: ScriptedURLProtocol.session()
        )
        await #expect(throws: ProviderServiceError.self) {
            for try await _ in rememberedRunner.run(request: ToolLoopLegRequest(
                messages: [userMessage], tools: tools, toolChoice: .auto
            )) {}
        }
        #expect(ScriptedURLProtocol.snapshot().count == before, "once memory is false a leg with tools is rejected before the outbound gate and never reaches the upstream")

        // 429 / 401: not evidence that tools are unsupported, so no memory is written
        for (status, body) in [(429, #"{"error":{"message":"Rate limit exceeded for tools"}}"#), (401, #"{"error":{"message":"Invalid API key; tools unsupported"}}"#)] {
            let (fresh, freshModel) = makeRelayProvider(toolCall: nil)
            ScriptedURLProtocol.reset([(status, body)])
            let freshRunner = try OpenAIChatToolLoopLegRunner(
                provider: fresh, model: freshModel, modelID: freshModel.id, reasoningMode: .automatic,
                toolCallMemory: store, session: ScriptedURLProtocol.session()
            )
            do {
                for try await _ in freshRunner.run(request: ToolLoopLegRequest(
                    messages: [userMessage], tools: tools, toolChoice: .auto
                )) {}
                Issue.record("\(status) must throw")
            } catch {
                #expect(!ToolUnsupportedErrorMatcher.matches(error), "\(status) must not be judged as tools unsupported")
            }
            #expect(store.lookup(connectionID: fresh.id, modelID: freshModel.id) == nil)
        }
    }

    @Test("Grok subscription chat leg hits subscription.chatUrl with the subscription token and the required headers")
    @MainActor
    func grokSubscriptionChatLeg() async throws {
        await MetadataClient.shared.resetForTesting()
        var model = AIModel(id: "grok-4.6", name: "Grok 4.6", capabilities: [.text], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: "standard")
        // This case tests the chat leg for an upstream that explicitly declares the chat backend; without a declaration a Grok subscription
        // defaults to Responses, so marking chat explicitly is the real premise of this chat leg.
        model.upstreamAPIBackend = "chat"
        var provider = Provider(id: UUID(), kind: .grok, status: .connected, models: [model], catalogModels: [], apiKey: "connected-marker", apiKeyPreview: "…", baseURLText: nil)
        provider.authMode = .subscription
        var options = ChatRequestOptions()
        options.grokSubscription = GrokSubscriptionRequestContext(
            chatURL: URL(string: "https://cli-chat-proxy.grok.com/rest/app-chat/v1/chat/completions")!,
            requiredHeaders: ["x-grok-client-version": "2.7.1"]
        )
        let decision = ToolCallCapabilityPolicy.decide(provider: provider, model: model, memory: try makeMemoryStore())
        #expect(decision.transport == TransportKind.openaiChat.rawValue, "the subscription transport reads subscriptionFinalTransport")
        #expect(decision.allowed && decision.decided)

        ScriptedURLProtocol.reset([(200, textLeg("hi"))])
        let runner = try OpenAIChatToolLoopLegRunner(
            provider: provider, model: model, modelID: model.id, reasoningMode: .automatic,
            requestOptions: options, accessToken: "subscription-access-token",
            toolCallMemory: try makeMemoryStore(), session: ScriptedURLProtocol.session()
        )
        for try await _ in runner.run(request: ToolLoopLegRequest(
            messages: [ToolLoopMessage(role: "user", content: "plan")],
            tools: try weatherTools(),
            toolChoice: .auto
        )) {}
        let request = try #require(ScriptedURLProtocol.snapshot().first)
        #expect(request.url?.absoluteString == "https://cli-chat-proxy.grok.com/rest/app-chat/v1/chat/completions")
        #expect(request.headers["Authorization"] == "Bearer subscription-access-token")
        #expect(request.headers["x-grok-client-version"] == "2.7.1")
        #expect((request.body["tools"] as? [[String: Any]])?.count == 1)
        #expect(request.body["model"] as? String == "grok-4.6")
        // The subscription leg's transport must come from subscriptionFinalTransport and never be an empty string (otherwise reasoning / generation injection silently fails).
        #expect(runner.effectiveTransportForEvidence == TransportKind.openaiChat.rawValue)
    }

    @Test("Grok subscription declaring api_backend=responses: the leg goes through ProtocolToolLoopLegRunner to subscription.responsesURL, with tools in the flat Responses shape")
    @MainActor
    func grokSubscriptionResponsesLeg() async throws {
        await MetadataClient.shared.resetForTesting()
        var model = AIModel(id: "grok-4.6", name: "Grok 4.6", capabilities: [.text, .web], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: "standard")
        model.upstreamAPIBackend = "responses"
        var provider = Provider(id: UUID(), kind: .grok, status: .connected, models: [model], catalogModels: [], apiKey: "connected-marker", apiKeyPreview: "…", baseURLText: nil)
        provider.authMode = .subscription
        var options = ChatRequestOptions()
        options.grokSubscription = GrokSubscriptionRequestContext(
            chatURL: URL(string: "https://cli-chat-proxy.grok.com/v1/chat/completions")!,
            responsesURL: URL(string: "https://cli-chat-proxy.grok.com/v1/responses")!,
            requiredHeaders: ["x-grok-client-version": "1.0.4"],
            transport: TransportKind.openaiResponses.rawValue
        )
        let decision = ToolCallCapabilityPolicy.decide(provider: provider, model: model, memory: try makeMemoryStore())
        #expect(decision.transport == TransportKind.openaiResponses.rawValue, "the subscription transport reads the new source of truth (/models api_backend)")
        #expect(decision.allowed && decision.decided, "openai_responses is already in the local adapter set")

        let stream = "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"hi\"}\n\nevent: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"r1\",\"usage\":{\"input_tokens\":2,\"output_tokens\":1}}}\n\n"
        ScriptedURLProtocol.reset([(200, stream)])
        let pair = try ToolLoopLegRunnerFactory.make(
            provider: provider, model: model, modelID: model.id, reasoningMode: .automatic,
            requestOptions: options, accessToken: "subscription-access-token",
            toolCallMemory: try makeMemoryStore(), session: ScriptedURLProtocol.session()
        )
        let runner = try #require(pair.runner as? ProtocolToolLoopLegRunner)
        #expect(pair.adapter.transport == TransportKind.openaiResponses.rawValue)
        for try await _ in runner.run(request: ToolLoopLegRequest(
            messages: [ToolLoopMessage(role: "user", content: "plan")],
            tools: try weatherTools(),
            toolChoice: .auto
        )) {}
        let request = try #require(ScriptedURLProtocol.snapshot().first)
        #expect(request.url?.absoluteString == "https://cli-chat-proxy.grok.com/v1/responses")
        #expect(request.headers["Authorization"] == "Bearer subscription-access-token")
        #expect(request.headers["x-grok-client-version"] == "1.0.4")
        // The Responses leg of an official provider carries no Codex identity material.
        #expect(request.headers["Originator"] == nil)
        #expect(request.headers["session_id"] == nil)
        #expect(request.headers["User-Agent"]?.hasPrefix("codex_cli_rs/") != true)
        #expect(request.body["prompt_cache_key"] == nil)
        let tools = try #require(request.body["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools.first?["type"] as? String == "function")
        #expect(tools.first?["name"] as? String != nil, "flat Responses tools, no function wrapper")
        #expect(request.body["input"] != nil)
        #expect(request.body["messages"] == nil)
        #expect(request.body["model"] as? String == "grok-4.6")
        #expect(runner.effectiveTransportForEvidence == TransportKind.openaiResponses.rawValue)
    }

    /// Sends one Relay leg and returns the outbound request that was recorded.
    @MainActor
    private func recordedRelayLeg(_ requested: RelayRequestedConfig) async throws -> ScriptedURLProtocol.Recorded {
        await MetadataClient.shared.resetForTesting()
        var (provider, model) = makeRelayProvider(baseURL: "https://relay.test")
        provider.relayRequested = requested
        let stream = "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"hi\"}\n\nevent: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"r1\",\"usage\":{\"input_tokens\":2,\"output_tokens\":1}}}\n\n"
        ScriptedURLProtocol.reset([(200, stream)])
        let pair = try ToolLoopLegRunnerFactory.make(
            provider: provider, model: model, modelID: "golden-relay-model", reasoningMode: .automatic,
            requestOptions: ChatRequestOptions(), accessToken: nil, toolCallMemory: try makeMemoryStore(),
            session: ScriptedURLProtocol.session()
        )
        do {
            for try await _ in pair.runner.run(request: ToolLoopLegRequest(
                messages: [
                    ToolLoopMessage(role: "system", content: "You are a golden fixture."),
                    ToolLoopMessage(role: "user", content: "Hello"),
                    ToolLoopMessage(role: "assistant", content: "Hi there."),
                    ToolLoopMessage(role: "user", content: "Summarize in one word."),
                ],
                tools: [], toolChoice: .none
            )) {}
        } catch {
            // Only the outbound request matters; a Responses stream fed to another protocol cannot be decoded, which does not matter here.
        }
        return try #require(ScriptedURLProtocol.snapshot().first)
    }

    @Test("The outbound request of a Relay Responses leg carries the Codex identity headers and prompt_cache_key")
    @MainActor
    func relayResponsesLegCarriesCodexIdentity() async throws {
        let request = try await recordedRelayLeg(RelayRequestedConfig(transport: .openaiResponses, authMode: .bearer))
        #expect(request.url?.path.hasSuffix("/responses") == true)
        #expect(request.headers["User-Agent"]?.hasPrefix("codex_cli_rs/") == true)
        #expect(request.headers["Originator"] == "codex_cli_rs")
        #expect(request.headers["OpenAI-Beta"] == "responses=experimental")
        #expect(request.headers["session_id"]?.count == 36)
        #expect(request.headers["Authorization"] == "Bearer relay-key")
        // The same pure function and the same inputs as chat (the expected value of the golden fixture case).
        #expect(request.body["instructions"] as? String == "You are a golden fixture.")
        #expect(request.body["prompt_cache_key"] as? String == "2290bbc6e2bae08a11ede516e419f3c6")
    }

    @Test("With codexCompatIdentity=false the leg carries neither; legs on non-Responses protocols are unchanged")
    @MainActor
    func relayLegWithoutCodexIdentity() async throws {
        let off = try await recordedRelayLeg(
            RelayRequestedConfig(transport: .openaiResponses, authMode: .bearer, codexCompatIdentity: false)
        )
        #expect(off.url?.path.hasSuffix("/responses") == true)
        #expect(off.headers["Originator"] == nil)
        #expect(off.headers["session_id"] == nil)
        #expect(off.headers["OpenAI-Beta"] == nil)
        #expect(off.headers["User-Agent"]?.hasPrefix("codex_cli_rs/") != true)
        #expect(off.body["prompt_cache_key"] == nil)

        let anthropic = try await recordedRelayLeg(
            RelayRequestedConfig(transport: .anthropicMessages, authMode: .xApiKey)
        )
        #expect(anthropic.url?.path.hasSuffix("/messages") == true)
        #expect(anthropic.headers["Originator"] == nil)
        #expect(anthropic.body["prompt_cache_key"] == nil)
    }

    @Test("Non-streaming Chat Completions tool_calls reach ProviderChatResult, and an empty body does not throw emptyResponse")
    @MainActor
    func nonStreamingToolCallsSurvive() async throws {
        await MetadataClient.shared.resetForTesting()
        ScriptedURLProtocol.reset([(200, #"{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_ns","type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Melbourne\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":3,"completion_tokens":2}}"#)])
        let service = OpenAIService(session: ScriptedURLProtocol.session())
        let result = try await service.sendMessage(
            apiKey: "sk-test", modelID: "gpt-4.1",
            messages: [ChatMessage(id: UUID(), role: .user, text: "weather", providerKind: .openAI, providerName: "OpenAI", modelName: "gpt-4.1", state: .delivered)],
            baseURL: "https://relay.test/v1", reasoningMode: .automatic,
            requestOptions: ChatRequestOptions(),
            relayRequested: RelayRequestedConfig(transport: .openaiChatCompletions, stream: false)
        )
        #expect(result.text.isEmpty)
        #expect(result.toolCalls?.map(\.name) == ["get_weather"])
        #expect(result.toolCalls?.first?.providerCallID == "call_ns")
        #expect(result.toolCalls?.first?.rawArguments == #"{"city":"Melbourne"}"#)
    }

    @Test("Function names are not encoded on the request side nor restored on the response side: names that look like escape sequences enter the proposal as sent (non-streaming and streaming decoder defaults)")
    @MainActor
    func toolNamesThatLookEscapedAreKeptAsSent() async throws {
        // `_fe`, `_ca`, `_de` are valid hex escapes and `__` is the short form of `.`; restoring would corrupt names that were never encoded.
        let names = ["web_fetch", "tool_call", "mcp_notes_delete_page", "mcp_a__b"]
        for name in names {
            await MetadataClient.shared.resetForTesting()
            ScriptedURLProtocol.reset([(200, #"{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_ns","type":"function","function":{"name":"\#(name)","arguments":"{}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":3,"completion_tokens":2}}"#)])
            let service = OpenAIService(session: ScriptedURLProtocol.session())
            let result = try await service.sendMessage(
                apiKey: "sk-test", modelID: "gpt-4.1",
                messages: [ChatMessage(id: UUID(), role: .user, text: "go", providerKind: .openAI, providerName: "OpenAI", modelName: "gpt-4.1", state: .delivered)],
                baseURL: "https://relay.test/v1", reasoningMode: .automatic,
                requestOptions: ChatRequestOptions(),
                relayRequested: RelayRequestedConfig(transport: .openaiChatCompletions, stream: false)
            )
            #expect(result.toolCalls?.map(\.name) == [name])

            let delta = try JSONDecoder().decode(
                [OpenAICompatibleChunk.Choice.ToolCallDelta].self,
                from: Data(#"[{"index":0,"id":"call_1","type":"function","function":{"name":"\#(name)","arguments":"{}"}}]"#.utf8)
            )
            var decoder = OpenAIChatToolCallStreamDecoder()
            let flushed = decoder.ingest(toolCalls: delta, finishReason: "tool_calls")
            #expect(flushed.map(\.name) == [name])
        }
    }
}

// MARK: - Private chunk decoders

@Suite("Private chunk decoders handle tool_calls", .serialized, .sharedProcessState)
struct PrivateChunkDecoderToolCallTests {
    private static func fixtureSSE() throws -> String {
        String(decoding: try LoopFixtures.data("openai_chat.tool_calls.sse"), as: UTF8.self)
    }

    private static func collect(_ stream: AsyncThrowingStream<StreamEvent, Error>) async throws -> [[ProviderToolCall]] {
        var batches: [[ProviderToolCall]] = []
        for try await event in stream {
            if case let .toolCallDeltas(calls) = event { batches.append(calls) }
        }
        return batches
    }

    private static func expectFixtureCalls(_ batches: [[ProviderToolCall]], provider: String) {
        #expect(batches.count == 1, "\(provider): the proposals of one leg should merge into one event")
        let calls = batches.flatMap { $0 }
        #expect(calls.map(\.name) == ["get_weather", "get_time"], Comment(rawValue: provider))
        #expect(calls.map(\.providerCallID) == ["call_r2_weather", "call_r2_time"], Comment(rawValue: provider))
        #expect(calls.first?.rawArguments == #"{"city":"Melbourne","unit":"celsius"}"#, Comment(rawValue: provider))
    }

    private static func user(_ kind: ProviderKind) -> ChatMessage {
        ChatMessage(id: UUID(), role: .user, text: "the weather in Melbourne today", providerKind: kind, providerName: kind.displayName, modelName: "m", state: .delivered)
    }

    @Test("Groq / Together / Fireworks / SiliconFlow / Qwen / MiniMax / Mistral consume the shared corpus -> .toolCallDeltas", arguments: [
        "groq", "together", "fireworks", "siliconflow", "qwen", "minimax", "mistral",
    ])
    @MainActor
    func privateDecodersEmitToolCalls(provider: String) async throws {
        await MetadataClient.shared.resetForTesting()
        ScriptedURLProtocol.reset([(200, try Self.fixtureSSE())])
        let session = ScriptedURLProtocol.session()
        let stream: AsyncThrowingStream<StreamEvent, Error>
        switch provider {
        case "groq": stream = GroqService(session: session).sendMessageStream(apiKey: "k", modelID: "llama", messages: [Self.user(.groq)])
        case "together": stream = TogetherService(session: session).sendMessageStream(apiKey: "k", modelID: "llama", messages: [Self.user(.together)])
        case "fireworks": stream = FireworksService(session: session).sendMessageStream(apiKey: "k", modelID: "llama", messages: [Self.user(.fireworks)])
        case "siliconflow": stream = SiliconFlowService(session: session).sendMessageStream(apiKey: "k", modelID: "qwen", messages: [Self.user(.siliconFlow)])
        case "qwen": stream = QwenService(session: session).sendMessageStream(apiKey: "k", modelID: "qwen-plus", messages: [Self.user(.qwen)])
        case "minimax": stream = MiniMaxService(session: session).sendMessageStream(apiKey: "k", modelID: "MiniMax-M2", messages: [Self.user(.miniMax)])
        default: stream = MistralService(session: session).sendMessageStream(apiKey: "k", modelID: "mistral-large", messages: [Self.user(.mistral)])
        }
        Self.expectFixtureCalls(try await Self.collect(stream), provider: provider)
    }
}
