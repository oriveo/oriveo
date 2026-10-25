import Foundation
import GRDB
import OriveoProviderKit
import Testing

@testable import Oriveo

// MARK: - Shared fixtures (shared/test-fixtures/provider-toolcall, one directory for all platforms)

private enum AdapterFixtures {
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

    static func text(_ name: String) throws -> String { String(decoding: try data(name), as: UTF8.self) }
}

/// A per-request scripted mock: replays (status, body) in order and records every request (URL / headers / body).
private final class AdapterScriptedURLProtocol: URLProtocol, @unchecked Sendable {
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
        config.protocolClasses = [AdapterScriptedURLProtocol.self]
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
            return Self.script.isEmpty ? (200, Data()) : Self.script.removeFirst()
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

@MainActor
private func makeRelayProvider(transport: RelayTransport, toolCall: Bool? = true, baseURL: String = "https://relay.test") -> (Provider, AIModel) {
    var model = AIModel(
        id: "relay-agent-model", name: "Relay Agent", capabilities: [.text],
        reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: "standard"
    )
    model.toolCall = toolCall
    let provider = Provider(
        id: UUID(), kind: .relay, status: .connected, models: [model], catalogModels: [],
        apiKey: "relay-key", apiKeyPreview: "...key", baseURLText: baseURL,
        relayRequested: RelayRequestedConfig(transport: transport)
    )
    return (provider, model)
}

/// A standalone GRDB database (runs the full migrator) that leaves the DatabaseManager's current user pool alone.
private func makeMemoryStore() throws -> ToolCallMemoryStore {
    let uid = "toolcall-memory-adapter-\(UUID().uuidString)"
    try FileManager.default.createDirectory(at: AppSessionStore.userDir(for: uid), withIntermediateDirectories: true)
    let pool = try DatabasePool(
        path: AppSessionStore.databasePath(for: uid).path,
        configuration: DatabaseSchema.makeConfiguration()
    )
    let files = AttachmentFileStore(rootDirectory: AppSessionStore.filesDir(for: uid))
    try DatabaseSchema.makeMigrator(attachmentFileStore: files).migrate(pool)
    return ToolCallMemoryStore(poolProvider: { pool })
}

private func userMessage(kind: ProviderKind) -> ChatMessage {
    ChatMessage(id: UUID(), role: .user, text: "the weather in Melbourne today", providerKind: kind, providerName: kind.displayName, modelName: "m", state: .delivered)
}

private struct Collected {
    var text = ""
    var toolCallEvents: [[ProviderToolCall]] = []
    var done: ProviderChatResult?
    var toolCalls: [ProviderToolCall] { toolCallEvents.flatMap { $0 } }
}

private func collect(_ stream: AsyncThrowingStream<StreamEvent, Error>) async throws -> Collected {
    var collected = Collected()
    for try await event in stream {
        switch event {
        case let .delta(chunk): collected.text += chunk
        case let .toolCallDeltas(calls): collected.toolCallEvents.append(calls)
        case let .done(result): collected.done = result
        case .reasoning, .citations, .imagePart, .activity, .finish: break
        }
    }
    return collected
}

private func normalizedJSON(_ raw: String) -> String {
    guard let data = raw.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data),
          let canonical = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    else { return raw }
    return String(decoding: canonical, as: UTF8.self)
}

/// Two tool definitions that exercise the schema shaping: a plain object schema with `additionalProperties`, and a nullable string property.
private func sampleTools() throws -> [ToolLoopToolDefinition] {
    [
        ToolLoopToolDefinition(function: .init(
            name: "get_weather",
            description: "Get the weather for a city.",
            parameters: try ToolJSONValue.make([
                "type": "object",
                "properties": ["city": ["type": "string"]],
                "required": ["city"],
                "additionalProperties": false,
            ])
        )),
        ToolLoopToolDefinition(function: .init(
            name: "list_places",
            description: "List places, optionally inside a container.",
            parameters: try ToolJSONValue.make([
                "type": "object",
                "properties": [
                    "source": ["type": "string"],
                    "containerId": ["type": ["string", "null"]],
                ],
                "required": ["source"],
                "additionalProperties": false,
            ])
        )),
    ]
}

// MARK: - anthropic_messages

@Suite("anthropic_messages tool adapter", .serialized, .sharedProcessState)
struct AnthropicToolAdapterTests {
    @Test("Shared corpus: AnthropicMessagesStrategy decodes tool_use (five input_json_delta slices including an empty one), keeps the body text, one event")
    func fixtureThroughStrategy() throws {
        let manifest = try JSONSerialization.jsonObject(with: AdapterFixtures.data("expected.json")) as? [String: Any]
        let entry = try #require((manifest?["fixtures"] as? [[String: Any]])?.first { $0["file"] as? String == "anthropic.tool_use.sse" })
        let expected = try #require(entry["expected"] as? [String: Any])
        let strategy = AnthropicMessagesStrategy()
        var ctx = StreamContext()
        var text = ""
        var events: [[ProviderToolCall]] = []
        for line in try AdapterFixtures.text("anthropic.tool_use.sse").components(separatedBy: "\n") where line.hasPrefix("data: ") {
            for event in strategy.parseStreamLine(String(line.dropFirst(6)), ctx: &ctx, shape: nil) {
                if case let .delta(chunk) = event { text += chunk }
                if case let .toolCallDeltas(calls) = event { events.append(calls) }
            }
        }
        #expect(AnthropicMessagesStrategy.flushToolCalls(ctx: &ctx).isEmpty, "stop_reason already flushed; the trailing flush must not hand them out twice")
        #expect(text == expected["text"] as? String)
        #expect(events.count == 1)
        let call = try #require(events.first?.first)
        let want = try #require((expected["tool_calls"] as? [[String: Any]])?.first)
        #expect(call.name == want["name"] as? String)
        #expect(call.providerCallID == want["id"] as? String)
        #expect(normalizedJSON(call.rawArguments) == normalizedJSON(want["arguments"] as? String ?? ""))
    }

    @Test("The real AnthropicService (official and Relay streams) consumes the shared corpus: .toolCallDeltas arrive and .done does not throw", arguments: ["official", "relay"])
    @MainActor
    func serviceEmitsToolCallDeltas(lane: String) async throws {
        await MetadataClient.shared.resetForTesting()
        AdapterScriptedURLProtocol.reset([(200, try AdapterFixtures.text("anthropic.tool_use.sse"))])
        let service = AnthropicService(session: AdapterScriptedURLProtocol.session())
        let stream = lane == "official"
            ? service.sendMessageStream(apiKey: "sk-ant-test", modelID: "claude-sonnet-4-5", messages: [userMessage(kind: .anthropic)])
            : service.sendMessageStream(
                apiKey: "relay-key", modelID: "claude-sonnet-4-5", messages: [userMessage(kind: .relay)],
                baseURL: "https://relay.test", relayRequested: RelayRequestedConfig(transport: .anthropicMessages)
            )
        let collected = try await collect(stream)
        #expect(collected.text == "Let me check the weather.")
        #expect(collected.toolCallEvents.count == 1, "\(lane): the proposals of one leg merge into one event")
        #expect(collected.toolCalls.map(\.name) == ["get_weather"])
        #expect(collected.toolCalls.first?.providerCallID == "toolu_r2weather")
        #expect(collected.done != nil)
    }

    @Test("A stream cut without a stop_reason: the Service's trailing flush still hands out the proposals")
    func flushCoversMissingStopReason() throws {
        let strategy = AnthropicMessagesStrategy()
        var ctx = StreamContext()
        var sawEvent = false
        for line in try AdapterFixtures.text("anthropic.tool_use.sse").components(separatedBy: "\n")
        where line.hasPrefix("data: ") && !line.contains("message_delta") {
            for event in strategy.parseStreamLine(String(line.dropFirst(6)), ctx: &ctx, shape: nil) {
                if case .toolCallDeltas = event { sawEvent = true }
            }
        }
        #expect(!sawEvent)
        guard case let .toolCallDeltas(calls)? = AnthropicMessagesStrategy.flushToolCalls(ctx: &ctx).first else {
            Issue.record("the trailing flush handed out no proposals"); return
        }
        #expect(calls.map(\.name) == ["get_weather"])
    }

    @Test("encodeTools / encodeConversation wire shape: input_schema, system split to the top level, tool_result in a user turn, thinking blocks replayed verbatim up front")
    func wireShapes() throws {
        let adapter = AnthropicToolAdapter()
        let tools = try adapter.encodeTools(try sampleTools())
        let first = try #require(tools.first as? [String: Any])
        #expect(first["name"] as? String == "get_weather")
        #expect(first["input_schema"] is [String: Any])
        #expect(first["type"] == nil, "an Anthropic tools entry has no type=function wrapper")

        let history: [ToolLoopMessage] = [
            ToolLoopMessage(role: "system", content: "Safety."),
            ToolLoopMessage(role: "user", content: "weather?"),
            adapter.encodeAssistantToolCalls(
                text: "Let me look.", reasoning: nil,
                toolCalls: [ToolLoopToolCall(id: "toolu_1", function: .init(name: "get_weather", arguments: #"{"city":"Melbourne"}"#))],
                replayBlocks: [.object(["type": .string("thinking"), "thinking": .string("t"), "signature": .string("sig")])]
            ),
            adapter.encodeToolResult(callID: "toolu_1", toolName: "get_weather", content: #"{"ok":true}"#),
            ToolCallLoop.loopNotice("Step limit reached."),
        ]
        let conversation = try adapter.encodeConversation(history)
        #expect(conversation.system == "Safety.")
        let messages = try #require(conversation.messages as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["user", "assistant", "user"])
        let assistantBlocks = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(assistantBlocks.map { $0["type"] as? String } == ["thinking", "text", "tool_use"])
        #expect((assistantBlocks[2]["input"] as? [String: Any])?["city"] as? String == "Melbourne")
        let resultBlocks = try #require(messages[2]["content"] as? [[String: Any]])
        #expect(resultBlocks.map { $0["type"] as? String } == ["tool_result", "text"], "the host loop notice (user) joins the same user turn as a text block next to the tool_result")
        #expect(resultBlocks[0]["tool_use_id"] as? String == "toolu_1")
    }

    @Test("Official endpoint and auth: AnthropicLegWire lands on /v1/messages with x-api-key")
    func officialWire() throws {
        let wire = AnthropicLegWire()
        #expect(try wire.officialEndpoint(providerKind: .anthropic, userBaseURL: nil, modelID: "claude").absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(wire.officialAuthMode == .xApiKey)
        var request = URLRequest(url: URL(string: "https://x")!)
        wire.applyProtocolHeaders(to: &request)
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let body = wire.requestBody(modelID: "m", conversation: ToolProtocolConversation(system: nil, messages: []), tools: [], toolChoice: .none, maxOutputTokens: 4096)
        #expect((body["tool_choice"] as? [String: Any])?["type"] as? String == "none")
        #expect(body["max_tokens"] as? Int == 4096)
        #expect(body["system"] == nil)
    }
}

// MARK: - Adapter availability

@Suite("Tool adapter availability", .sharedProcessState)
struct ToolAdapterAvailabilityTests {
    @Test("The local adapter set has a single declaration site; a client missing the adapter judges a toolCall=true anthropic connection as not executable")
    @MainActor
    func oldClientWithoutAdapterIsNotExecutable() throws {
        #expect(ToolCallCapabilityPolicy.localAdapterTransports == Set(ToolProtocolAdapters.available.keys))
        #expect(ToolCallCapabilityPolicy.localAdapterTransports.contains(TransportKind.anthropicMessages.rawValue))

        let (relay, model) = makeRelayProvider(transport: .anthropicMessages, toolCall: true)
        let store = try makeMemoryStore()
        let current = ToolCallCapabilityPolicy.decide(provider: relay, model: model, memory: store)
        #expect(current.transport == TransportKind.anthropicMessages.rawValue)
        #expect(current.verdict == true && current.allowed && current.decided)

        // Simulate an older client: the set shrinks back to {openai_chat}
        let old = ToolCallCapabilityPolicy.decide(
            provider: relay, model: model, memory: store,
            adapterTransports: [TransportKind.openaiChat.rawValue]
        )
        #expect(old.verdict == true, "the declared toolCall truth from the server / locally is unchanged")
        #expect(old.decided, "the transport is known, so it is not pending")
        #expect(!old.allowed, "without an adapter for the protocol it is not executable")
    }
}

// MARK: - openai_responses

private func responsesSSE(_ frames: [(event: String, data: String)]) -> String {
    frames.map { "event: \($0.event)\ndata: \($0.data)\n\n" }.joined()
}

private let responsesTextLeg = responsesSSE([
    ("response.created", #"{"type":"response.created","response":{"id":"resp_r4b","status":"in_progress","output":[]}}"#),
    ("response.output_item.added", #"{"type":"response.output_item.added","output_index":0,"item":{"id":"msg_r4b","type":"message","status":"in_progress","role":"assistant","content":[]}}"#),
    ("response.output_text.delta", #"{"type":"response.output_text.delta","item_id":"msg_r4b","output_index":0,"content_index":0,"delta":"Plan found [1]."}"#),
    ("response.completed", #"{"type":"response.completed","response":{"id":"resp_r4b","status":"completed","output":[],"usage":{"input_tokens":200,"output_tokens":9,"total_tokens":209}}}"#),
])

/// An official OpenAI catalog snapshot: one openai_responses model with toolCall=true.
/// The model entry comes from the shared recording production-shapes (including the tool_call evidence candidate); only the model id changes, and no evidence view is written by hand.
private func officialResponsesSnapshot() throws -> String {
    let model = try recordedOfficialModelJSON(modelID: "gpt-adapter-fixture")
    return """
    {
      "version": 1,
      "updatedAt": "2026-08-22T00:00:00Z",
      "providers": {
        "openAI": {
          "transport": {
            "baseUrl": "https://api.openai.com/v1",
            "endpoints": { "chat": "/chat/completions", "responses": "/responses" }
          },
          "resolveMap": { "gpt-adapter-fixture": "gpt-adapter-fixture" },
          "models": { "gpt-adapter-fixture": \(model) }
        }
      }
    }
    """
}

/// The official openai_responses model that the server sent in the shared recording `production-shapes.v1.json`, rewritten to `modelID`:
/// only the tool_call evidence candidate is kept and its modelId rewritten, and the validity window is re-anchored to now by the recorded duration (the recorded window has passed).
private func recordedOfficialModelJSON(modelID: String) throws -> String {
    var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let relative = ["shared", "test-fixtures", "provider-capability-evidence", "production-shapes.v1.json"]
    var fixture: URL?
    while cursor.path != "/" {
        let candidate = relative.reduce(cursor) { $0.appendingPathComponent($1) }
        if FileManager.default.fileExists(atPath: candidate.path) { fixture = candidate; break }
        cursor.deleteLastPathComponent()
    }
    let root = try JSONSerialization.jsonObject(with: Data(contentsOf: try #require(fixture))) as? [String: Any]
    let sources = try #require(root?["sources"] as? [String: Any])
    let payload = try #require((sources["serverMetadata"] as? [String: Any])?["payload"] as? [String: Any])
    let models = try #require(((payload["providers"] as? [String: Any])?["openAI"] as? [String: Any])?["models"] as? [String: Any])
    var model = try #require(models.values.first as? [String: Any])
    model["canonicalModelId"] = modelID
    model["capabilities"] = ["text"]
    model.removeValue(forKey: "profiles")
    func rewrite(_ node: Any) -> Any {
        if let array = node as? [Any] {
            return array.filter { item in
                guard let key = (item as? [String: Any])?["key"] as? String else { return true }
                return key == "tool_call"
            }.map(rewrite)
        }
        guard var object = node as? [String: Any] else { return node }
        if object["key"] as? String == "tool_call" {
            object["modelId"] = modelID
            // server_typed must carry a validity window; the recorded window has passed, so re-anchor it to now by the recorded duration.
            if let observed = object["observedAt"] as? Int64, let expires = object["expiresAt"] as? Int64 {
                let now = Int64(Date().timeIntervalSince1970 * 1000)
                object["observedAt"] = now
                object["expiresAt"] = now + (expires - observed)
            }
            return object
        }
        return object.mapValues(rewrite)
    }
    let data = try JSONSerialization.data(withJSONObject: rewrite(model), options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

@Suite("openai_responses tool adapter", .serialized, .sharedProcessState)
struct OpenAIResponsesToolAdapterTests {
    @Test("Shared corpus: OpenAIResponsesStrategy decodes function_call (arguments in three slices plus done), keeps the body text, one event")
    func fixtureThroughStrategy() throws {
        let manifest = try JSONSerialization.jsonObject(with: AdapterFixtures.data("expected.json")) as? [String: Any]
        let entry = try #require((manifest?["fixtures"] as? [[String: Any]])?.first { $0["file"] as? String == "openai_responses.function_call.sse" })
        let expected = try #require(entry["expected"] as? [String: Any])
        let strategy = OpenAIResponsesStrategy()
        var ctx = StreamContext()
        var text = ""
        var events: [[ProviderToolCall]] = []
        for line in try AdapterFixtures.text("openai_responses.function_call.sse").components(separatedBy: "\n") where line.hasPrefix("data: ") {
            for event in strategy.parseStreamLine(String(line.dropFirst(6)), ctx: &ctx, shape: nil) {
                if case let .delta(chunk) = event { text += chunk }
                if case let .toolCallDeltas(calls) = event { events.append(calls) }
            }
        }
        #expect(OpenAIResponsesStrategy.flushToolCalls(ctx: &ctx).isEmpty, "response.completed already flushed; the trailing flush must not hand them out twice")
        #expect(text == expected["text"] as? String)
        #expect(events.count == 1)
        let call = try #require(events.first?.first)
        let want = try #require((expected["tool_calls"] as? [[String: Any]])?.first)
        #expect(call.name == want["name"] as? String)
        #expect(call.providerCallID == want["id"] as? String)
        #expect(normalizedJSON(call.rawArguments) == normalizedJSON(want["arguments"] as? String ?? ""))
    }

    @Test("The real OpenAIService (official Responses and Relay Responses streams) consumes the shared corpus: .toolCallDeltas arrive and .done does not throw", arguments: ["official", "relay"])
    @MainActor
    func serviceEmitsToolCallDeltas(lane: String) async throws {
        await MetadataClient.shared.resetForTesting()
        if lane == "official" { try await MetadataClient.shared.loadForTesting(json: officialResponsesSnapshot()) }
        AdapterScriptedURLProtocol.reset([(200, try AdapterFixtures.text("openai_responses.function_call.sse"))])
        let service = OpenAIService(session: AdapterScriptedURLProtocol.session())
        let stream = lane == "official"
            ? service.sendMessageStream(apiKey: "sk-test", modelID: "gpt-adapter-fixture", messages: [userMessage(kind: .openAI)])
            : service.sendMessageStream(
                apiKey: "relay-key", modelID: "gpt-4.1-mini", messages: [userMessage(kind: .relay)],
                baseURL: "https://relay.test", reasoningMode: .automatic, requestOptions: ChatRequestOptions(),
                relayRequested: RelayRequestedConfig(transport: .openaiResponses)
            )
        let collected = try await collect(stream)
        #expect(AdapterScriptedURLProtocol.snapshot().first?.url?.path.hasSuffix("/responses") == true, "\(lane): must hit the Responses endpoint")
        #expect(collected.text == "Let me check the weather.")
        #expect(collected.toolCallEvents.count == 1, "\(lane): the proposals of one leg merge into one event")
        #expect(collected.toolCalls.map(\.providerCallID) == ["call_r2_weather"])
        #expect(collected.done != nil)
    }

    @Test("encodeTools / encodeConversation wire shape: flat function, instructions, assistant uses output_text, the reasoning item is replayed before the function_call, function_call_output")
    func wireShapes() throws {
        let adapter = OpenAIResponsesToolAdapter()
        let tools = try adapter.encodeTools(try sampleTools())
        let first = try #require(tools.first as? [String: Any])
        #expect(first["type"] as? String == "function")
        #expect(first["name"] as? String == "get_weather")
        #expect(first["parameters"] is [String: Any])
        #expect(first["function"] == nil, "a Responses function tool is flat")

        let history: [ToolLoopMessage] = [
            ToolLoopMessage(role: "system", content: "Safety."),
            ToolLoopMessage(role: "user", content: "weather?"),
            ToolLoopMessage(role: "assistant", content: "earlier answer"),
            adapter.encodeAssistantToolCalls(
                text: "Let me look.", reasoning: nil,
                toolCalls: [ToolLoopToolCall(id: "call_1", function: .init(name: "get_weather", arguments: #"{"city":"Melbourne"}"#))],
                replayBlocks: [.object(["type": .string("reasoning"), "id": .string("rs_1"), "summary": .array([])])]
            ),
            adapter.encodeToolResult(callID: "call_1", toolName: "get_weather", content: #"{"ok":true}"#),
            ToolCallLoop.loopNotice("Step limit reached."),
        ]
        let conversation = try adapter.encodeConversation(history)
        #expect(conversation.system == "Safety.")
        let input = try #require(conversation.messages as? [[String: Any]])
        #expect(input.map { ($0["role"] as? String) ?? ($0["type"] as? String) } == ["user", "assistant", "reasoning", "assistant", "function_call", "function_call_output", "user"])
        let assistant = try #require(input[1]["content"] as? [[String: Any]])
        #expect(assistant.first?["type"] as? String == "output_text", "assistant history must be output_text (input_text belongs to the user side only)")
        #expect(input[2]["id"] as? String == "rs_1")
        #expect(input[4]["call_id"] as? String == "call_1")
        #expect(input[5]["output"] as? String == #"{"ok":true}"#)
        #expect((input[6]["content"] as? [[String: Any]])?.first?["type"] as? String == "input_text")
        #expect((input[6]["content"] as? [[String: Any]])?.first?["text"] as? String == "Step limit reached.")
    }

    @Test("Official OpenAI (catalog openai_responses + toolCall=true): the policy judges it executable, and the production leg runner hits /v1/responses with a Bearer token")
    @MainActor
    func officialOpenAILeg() async throws {
        await MetadataClient.shared.resetForTesting()
        // Official tool_call only trusts catalog evidence; an evidence candidate needs a metadata revision to authorize.
        try await MetadataClient.shared.loadForTesting(json: officialResponsesSnapshot(), metadataETag: "adapter-official-responses")
        let model = AIModel(id: "gpt-adapter-fixture", name: "GPT Adapter", capabilities: [.text], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: "standard")
        let provider = Provider(id: UUID(), kind: .openAI, status: .connected, models: [model], catalogModels: [], apiKey: "sk-official", apiKeyPreview: "…", baseURLText: nil)
        let store = try makeMemoryStore()
        let decision = ToolCallCapabilityPolicy.decide(provider: provider, model: model, memory: store)
        #expect(decision.transport == TransportKind.openaiResponses.rawValue)
        #expect(decision.verdict == true && decision.source == .catalog && decision.allowed)

        AdapterScriptedURLProtocol.reset([(200, responsesTextLeg)])
        let pair = try ToolLoopLegRunnerFactory.make(
            provider: provider, model: model, modelID: model.id, reasoningMode: .automatic,
            requestOptions: ChatRequestOptions(), accessToken: nil, toolCallMemory: store,
            session: AdapterScriptedURLProtocol.session()
        )
        var text = ""
        for try await event in pair.runner.run(request: ToolLoopLegRequest(
            messages: [ToolLoopMessage(role: "user", content: "weather")],
            tools: try sampleTools(),
            toolChoice: .auto
        )) {
            if case let .textDelta(delta) = event { text += delta }
        }
        #expect(text == "Plan found [1].")
        let request = try #require(AdapterScriptedURLProtocol.snapshot().first)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(request.headers["Authorization"] == "Bearer sk-official")
        #expect((request.body["tools"] as? [[String: Any]])?.count == 2)
        #expect(request.body["model"] as? String == "gpt-adapter-fixture")
    }
}

// MARK: - gemini_generate

@Suite("gemini_generate tool adapter", .serialized, .sharedProcessState)
struct GeminiToolAdapterTests {
    @Test("Shared corpus: GeminiGenerateStrategy decodes functionCall (args structured, id null), keeps the body text, one event")
    func fixtureThroughStrategy() throws {
        let manifest = try JSONSerialization.jsonObject(with: AdapterFixtures.data("expected.json")) as? [String: Any]
        let entry = try #require((manifest?["fixtures"] as? [[String: Any]])?.first { $0["file"] as? String == "gemini.functionCall.sse" })
        let expected = try #require(entry["expected"] as? [String: Any])
        let strategy = GeminiGenerateStrategy()
        var ctx = StreamContext()
        var text = ""
        var events: [[ProviderToolCall]] = []
        for line in try AdapterFixtures.text("gemini.functionCall.sse").components(separatedBy: "\n") where line.hasPrefix("data: ") {
            for event in strategy.parseStreamLine(String(line.dropFirst(6)), ctx: &ctx, shape: nil) {
                if case let .delta(chunk) = event { text += chunk }
                if case let .toolCallDeltas(calls) = event { events.append(calls) }
            }
        }
        #expect(GeminiGenerateStrategy.flushToolCalls(ctx: &ctx).isEmpty, "finishReason already flushed; the trailing flush must not hand them out twice")
        #expect(text == expected["text"] as? String)
        #expect(events.count == 1)
        let call = try #require(events.first?.first)
        let want = try #require((expected["tool_calls"] as? [[String: Any]])?.first)
        #expect(call.name == want["name"] as? String)
        #expect(call.providerCallID == nil, "the corpus id is null")
        #expect(normalizedJSON(call.rawArguments) == normalizedJSON(want["arguments"] as? String ?? ""))
    }

    @Test("The real GeminiService (official and Relay streams) consumes the shared corpus: .toolCallDeltas arrive and .done does not throw", arguments: ["official", "relay"])
    @MainActor
    func serviceEmitsToolCallDeltas(lane: String) async throws {
        await MetadataClient.shared.resetForTesting()
        AdapterScriptedURLProtocol.reset([(200, try AdapterFixtures.text("gemini.functionCall.sse"))])
        let service = GeminiService(session: AdapterScriptedURLProtocol.session())
        let stream = lane == "official"
            ? service.sendMessageStream(apiKey: "AIza-test", modelID: "gemini-2.5-flash", messages: [userMessage(kind: .gemini)])
            : service.sendMessageStream(
                apiKey: "relay-key", modelID: "gemini-2.5-flash", messages: [userMessage(kind: .relay)],
                baseURL: "https://relay.test", relayRequested: RelayRequestedConfig(transport: .geminiGenerateContent)
            )
        let collected = try await collect(stream)
        #expect(AdapterScriptedURLProtocol.snapshot().first?.url?.absoluteString.contains(":streamGenerateContent") == true)
        #expect(collected.text == "Let me check the weather.")
        #expect(collected.toolCallEvents.count == 1, "\(lane): the proposals of one leg merge into one event")
        #expect(collected.toolCalls.map(\.name) == ["get_weather"])
        #expect(collected.done != nil)
    }

    @Test("encodeTools / encodeConversation wire shape: functionDeclarations with schema shaping, systemInstruction, functionCall/functionResponse parts, thoughtSignature replay, fallback ids are not sent back")
    func wireShapes() throws {
        let adapter = GeminiToolAdapter()
        let tools = try adapter.encodeTools(try sampleTools())
        let envelope = try #require(tools.first as? [String: Any])
        let declarations = try #require(envelope["functionDeclarations"] as? [[String: Any]])
        #expect(declarations.map { $0["name"] as? String } == ["get_weather", "list_places"])
        let weatherSchema = try #require(declarations[0]["parameters"] as? [String: Any])
        #expect(weatherSchema["additionalProperties"] == nil, "a Gemini Schema does not know additionalProperties; sending it gives a 400")
        let listSchema = try #require(declarations[1]["parameters"] as? [String: Any])
        let container = try #require((listSchema["properties"] as? [String: Any])?["containerId"] as? [String: Any])
        #expect(container["type"] as? String == "string" && container["nullable"] as? Bool == true, "type:[string,null] -> type:string + nullable")

        let history: [ToolLoopMessage] = [
            ToolLoopMessage(role: "system", content: "Safety."),
            ToolLoopMessage(role: "user", content: "weather?"),
            adapter.encodeAssistantToolCalls(
                text: "Let me look.", reasoning: nil,
                toolCalls: [
                    ToolLoopToolCall(id: "tool_call_1_1", function: .init(name: "get_weather", arguments: #"{"city":"Melbourne"}"#), providerSignature: "sig"),
                    ToolLoopToolCall(id: "fc-provided", function: .init(name: "list_places", arguments: #"{"source":"maps"}"#)),
                ],
                replayBlocks: []
            ),
            adapter.encodeToolResult(callID: "tool_call_1_1", toolName: "get_weather", content: #"{"ok":true}"#),
            adapter.encodeToolResult(callID: "fc-provided", toolName: "list_places", content: "plain text"),
            ToolCallLoop.loopNotice("Step limit reached."),
        ]
        let conversation = try adapter.encodeConversation(history)
        #expect(conversation.system == "Safety.")
        let contents = try #require(conversation.messages as? [[String: Any]])
        #expect(contents.map { $0["role"] as? String } == ["user", "model", "user"])
        let modelParts = try #require(contents[1]["parts"] as? [[String: Any]])
        #expect(modelParts.count == 3)
        #expect(modelParts[0]["text"] as? String == "Let me look.")
        #expect(modelParts[1]["thoughtSignature"] as? String == "sig")
        let firstCall = try #require(modelParts[1]["functionCall"] as? [String: Any])
        #expect(firstCall["id"] == nil, "the fallback id added by the loop is not sent back")
        #expect((firstCall["args"] as? [String: Any])?["city"] as? String == "Melbourne")
        #expect((modelParts[2]["functionCall"] as? [String: Any])?["id"] as? String == "fc-provided")
        let userParts = try #require(contents[2]["parts"] as? [[String: Any]])
        #expect(userParts.count == 3, "two functionResponses merge into one user content, and the host loop notice follows as a text part")
        let firstResponse = try #require(userParts[0]["functionResponse"] as? [String: Any])
        #expect(firstResponse["name"] as? String == "get_weather")
        #expect((firstResponse["response"] as? [String: Any])?["ok"] as? Bool == true)
        let secondResponse = try #require(userParts[1]["functionResponse"] as? [String: Any])
        #expect((secondResponse["response"] as? [String: Any])?["result"] as? String == "plain text", "a non-object result is wrapped in result")
        #expect(secondResponse["id"] as? String == "fc-provided")
        #expect(userParts[2]["text"] as? String == "Step limit reached.")
    }

    @Test("Official endpoint and auth: GeminiLegWire lands on /v1beta/models/{id}:streamGenerateContent?alt=sse with x-goog-api-key; the blocking set and in-stream errors throw")
    func officialWire() throws {
        let wire = GeminiLegWire()
        #expect(try wire.officialEndpoint(providerKind: .gemini, userBaseURL: nil, modelID: "gemini-2.5-flash").absoluteString
            == "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:streamGenerateContent")
        #expect(wire.streamQueryItems == [URLQueryItem(name: "alt", value: "sse")])
        #expect(wire.officialAuthMode == .xGoogApiKey)
        #expect(wire.streamError(in: ["candidates": [["finishReason": "SAFETY"]]]) != nil)
        #expect(wire.streamError(in: ["candidates": [["finishReason": "STOP"]]]) == nil)
        #expect(wire.streamError(in: ["candidates": [["finishReason": "MAX_TOKENS"]]]) == nil)
        #expect(wire.streamError(in: ["error": ["status": "RESOURCE_EXHAUSTED", "message": "quota"]]) != nil)
        let body = wire.requestBody(modelID: "m", conversation: ToolProtocolConversation(system: nil, messages: []), tools: [], toolChoice: .none, maxOutputTokens: nil)
        #expect((((body["toolConfig"] as? [String: Any])?["functionCallingConfig"] as? [String: Any])?["mode"]) as? String == "NONE")
        #expect(body["generationConfig"] == nil)
    }
}

// MARK: - openai_chat leg usage

@Suite("openai_chat leg usage", .serialized, .sharedProcessState)
struct ToolProtocolAdapterUsageTests {
    /// Kimi puts usage in `choices[0].usage` (not at the top level): the recorded stream goes frame by frame through the production leg, and the leg usage uses the same parser as plain chat.
    @Test("Moonshot recorded stream: the tool leg usage falls back to choices[0].usage", arguments: [
        ("recorded/moonshot.leg1.sse", 67, 88),
        ("recorded/moonshot_web_search.leg1.sse", 20, 1),
    ])
    func moonshotLegUsageFallsBackToChoiceUsage(fixture: String, prompt: Int, completion: Int) throws {
        var decoder = OpenAIChatToolCallStreamDecoder()
        var usages: [ToolLoopUsage] = []
        for line in try AdapterFixtures.text(fixture).split(separator: "\n") where line.hasPrefix("data: ") {
            let payload = String(line.dropFirst("data: ".count))
            guard payload != "[DONE]" else { continue }
            for case let .usage(usage) in try OpenAIChatToolLoopLegRunner.events(
                from: payload, providerKind: .moonshot, toolCalls: &decoder
            ) {
                usages.append(usage)
            }
        }
        #expect(usages.count == 1, "\(fixture)")
        #expect(usages.first?.promptTokens == prompt && usages.first?.completionTokens == completion, "\(fixture)")
        #expect(usages.first?.breakdown != nil, "\(fixture): the breakdown comes from the Moonshot plain-chat parser")
    }
}
