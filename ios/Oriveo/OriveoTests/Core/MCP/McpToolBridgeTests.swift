import Foundation
import GRDB
import OriveoProviderKit
import Testing
@testable import Oriveo

// MARK: - MCP tools wired into the shared tool loop
//
// The model side runs the production leg runner (`ToolLoopLegRunnerFactory`, four wire protocols) with
// `ScriptedModelURLProtocol` replaying the shared `provider-toolcall/` corpus (only `get_weather` is swapped for the name
// sent in this request; the corpus files stay as they are). The MCP server side runs the production `McpClient` with
// `McpScriptedURLProtocol` replaying the `mcp/protocol/` fixtures. Assembly reads from a real GRDB store; the confirmation gate is a test double.

// MARK: - Model-side test support (shared with the other MCP chat tests)

/// Loader for the shared tool-call corpus in `shared/test-fixtures/provider-toolcall/`.
enum ToolCallCorpus {
    /// Walks up from this test file until it finds `shared/test-fixtures/provider-toolcall/<name>`.
    static func text(_ name: String) throws -> String {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor
                .appendingPathComponent("shared")
                .appendingPathComponent("test-fixtures")
                .appendingPathComponent("provider-toolcall")
                .appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return String(decoding: try Data(contentsOf: candidate), as: UTF8.self)
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}

/// A scripted model endpoint: replays `(status, body)` pairs in order and records every request it receives.
final class ScriptedModelURLProtocol: URLProtocol, @unchecked Sendable {
    struct Recorded: @unchecked Sendable {
        let url: URL?
        let headers: [String: String]
        let body: [String: Any]
    }

    nonisolated(unsafe) private static var script: [(status: Int, body: Data)] = []
    nonisolated(unsafe) private static var recorded: [Recorded] = []
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
        config.protocolClasses = [ScriptedModelURLProtocol.self]
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

/// A custom-endpoint provider with one model, speaking the given wire protocol.
@MainActor
func makeToolLoopRelayProvider(transport: RelayTransport, toolCall: Bool? = true) -> (Provider, AIModel) {
    var model = AIModel(
        id: "relay-agent-model", name: "Relay Agent", capabilities: [.text],
        reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: "standard"
    )
    model.toolCall = toolCall
    let provider = Provider(
        id: UUID(), kind: .relay, status: .connected, models: [model], catalogModels: [],
        apiKey: "relay-key", apiKeyPreview: "...key", baseURLText: "https://relay.test",
        relayRequested: RelayRequestedConfig(transport: transport)
    )
    return (provider, model)
}

/// A tool-call memory store on its own temporary database (full migrator), away from the app's database pool.
func makeToolLoopMemoryStore() throws -> ToolCallMemoryStore {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("toolcall-memory-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let pool = try DatabasePool(
        path: directory.appendingPathComponent(DatabaseSchema.fileName).path,
        configuration: DatabaseSchema.makeConfiguration()
    )
    let files = AttachmentFileStore(rootDirectory: directory.appendingPathComponent("Files", isDirectory: true))
    try DatabaseSchema.makeMigrator(attachmentFileStore: files).migrate(pool)
    return ToolCallMemoryStore(poolProvider: { pool })
}

// MARK: - Fixtures for this file

private let weatherServerID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
private let conversationA = UUID(uuidString: "CCCCCCCC-0000-0000-0000-00000000000A")!
private let conversationB = UUID(uuidString: "CCCCCCCC-0000-0000-0000-00000000000B")!
private let weatherOutbound = "mcp_weather_get_weather"

private func schema(_ properties: [String], required: [String] = []) -> JSONValue {
    .object(JSONObject([
        ("type", .string("object")),
        ("properties", .object(JSONObject(properties.map { ($0, .object(JSONObject([("type", .string("string"))]))) }))),
        ("required", .array(required.map { .string($0) })),
    ]))
}

private func snapshot(
    _ toolName: String,
    serverId: UUID = weatherServerID,
    readOnly: Bool = true,
    pendingReview: Bool = false,
    oversized: Bool = false,
    inputSchema: JSONValue = schema(["city", "unit"])
) -> McpToolSnapshot {
    McpToolSnapshot(
        serverId: serverId,
        toolName: toolName,
        title: toolName,
        // An oversized tool: the description really exceeds the limit (assembly re-evaluates against the current runtime config instead of trusting the stored flag).
        description: oversized
            ? String(repeating: "x", count: McpRuntimeConfig.fallback.maxToolDefinitionBytes + 1)
            : "Tool \(toolName)",
        inputSchema: inputSchema,
        annotations: .object(JSONObject([("readOnlyHint", .bool(readOnly))])),
        contentHash: sha256Hex("\(serverId.uuidString):\(toolName)"),
        readOnly: readOnly,
        pendingReview: pendingReview,
        oversized: oversized
    )
}

private func weatherRecord(id: UUID = weatherServerID, slug: String = "weather", localOnly: Bool = false) -> McpServerRecord {
    McpTestRecords.record(id: id, slug: slug, name: "Weather", url: "https://mcp.example.com/mcp", localOnly: localOnly)
}

private func input(
    _ record: McpServerRecord = weatherRecord(),
    endpoint: McpServerEndpointResolution = .ready(URL(string: "https://mcp.example.com/mcp")!),
    status: McpConnectionStatus? = .connected,
    snapshots: [McpToolSnapshot],
    permissions: [String: McpToolPermission] = [:]
) -> McpBridgeServerInput {
    McpBridgeServerInput(record: record, endpoint: endpoint, connectionStatus: status, snapshots: snapshots, permissions: permissions)
}

/// Stores a server in the real store and enables it for the conversation; its snapshots are confirmed (not quarantined).
private func seedServer(
    _ database: McpTestDatabase,
    snapshots: [McpToolSnapshot],
    permissions: [String: McpToolPermission] = [:],
    enabledIn conversations: [UUID] = [conversationA],
    status: McpConnectionStatus = .connected
) throws {
    try database.store.addServer(
        McpServerAddition(
            id: weatherServerID, name: "Weather", url: "https://mcp.example.com/mcp", authKind: .auto,
            localOnly: false, iconURL: nil, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            snapshots: snapshots, permissions: permissions,
            connectionState: McpConnectionState(serverId: weatherServerID, status: status, generation: .stateless)
        ),
        maxServers: 20
    )
    for conversation in conversations {
        try database.store.setServerEnabled(true, conversationId: conversation, serverId: weatherServerID)
    }
}

/// A fake confirmation gate that answers from a script and records everything it was asked.
private actor ScriptedGate: McpConfirmationGate {
    private var answers: [McpConfirmationChoice]
    private(set) var asked: [McpConfirmationRequest] = []

    init(_ answers: [McpConfirmationChoice]) { self.answers = answers }

    func requestConfirmation(_ request: McpConfirmationRequest) async throws -> McpConfirmationChoice {
        asked.append(request)
        return answers.isEmpty ? .deny : answers.removeFirst()
    }
}

private actor UnhandledRecorder {
    private(set) var names: [String] = []
    func record(_ calls: [ProviderToolCall]) { names.append(contentsOf: calls.map(\.name)) }
}

private func toolsListStub() throws -> McpScriptedURLProtocol.Stub {
    try McpClientFixture.stub("protocol/stateless/tools-list.response.json")
}

private func toolsCallStub() throws -> McpScriptedURLProtocol.Stub {
    try McpClientFixture.stub("protocol/stateless/tools-call.response.json")
}

private func executor(
    conversation: UUID = conversationA,
    gate: any McpConfirmationGate = ScriptedGate([]),
    grants: McpConversationGrants = McpConversationGrants()
) -> McpToolExecutor {
    McpToolExecutor(
        conversationId: conversation,
        gate: gate,
        grants: grants,
        tokenProvider: { _ in nil },
        // These cases cover assembly and loop wiring and have no store to re-read, so the local state is the one seen at assembly time.
        // Re-reading local state is covered in `McpToolStepTests`, starting from `sendMessage` against a real store.
        liveState: { .usable(permission: $0.permission, endpoint: $0.endpoint) },
        makeClient: { McpClient(endpoint: $0, session: McpScriptedURLProtocol.session()) }
    )
}

private func bodyText(_ body: [String: Any]) -> String {
    (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
        .map { String(decoding: $0, as: UTF8.self) } ?? ""
}

private func toolNames(in body: [String: Any]) -> [String] {
    guard let tools = body["tools"] as? [[String: Any]] else { return [] }
    return tools.compactMap { tool in
        (tool["function"] as? [String: Any])?["name"] as? String  // openai_chat
            ?? tool["name"] as? String  // responses / anthropic
    } + tools.flatMap { ($0["functionDeclarations"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String } }
}

/// Swaps `get_weather` in a corpus SSE body for the name sent in this request (the corpus file itself is untouched).
private func corpusLeg(_ file: String) throws -> String {
    try ToolCallCorpus.text(file).replacingOccurrences(of: "\"get_weather\"", with: "\"\(weatherOutbound)\"")
}

private func textLeg(_ transport: RelayTransport, _ text: String) -> String {
    switch transport {
    case .anthropicMessages:
        return [
            ("message_start", #"{"type":"message_start","message":{"id":"m2","type":"message","role":"assistant","model":"claude","content":[],"stop_reason":null,"usage":{"input_tokens":200,"output_tokens":1}}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(text)"}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":9}}"#),
            ("message_stop", #"{"type":"message_stop"}"#),
        ].map { "event: \($0.0)\ndata: \($0.1)\n\n" }.joined()
    case .openaiResponses:
        return [
            ("response.created", #"{"type":"response.created","response":{"id":"r2","status":"in_progress","output":[]}}"#),
            ("response.output_item.added", #"{"type":"response.output_item.added","output_index":0,"item":{"id":"m2","type":"message","status":"in_progress","role":"assistant","content":[]}}"#),
            ("response.output_text.delta", #"{"type":"response.output_text.delta","item_id":"m2","output_index":0,"content_index":0,"delta":"\#(text)"}"#),
            ("response.completed", #"{"type":"response.completed","response":{"id":"r2","status":"completed","output":[],"usage":{"input_tokens":200,"output_tokens":9,"total_tokens":209}}}"#),
        ].map { "event: \($0.0)\ndata: \($0.1)\n\n" }.joined()
    case .geminiGenerateContent:
        return "data: " + #"{"candidates":[{"content":{"parts":[{"text":"\#(text)"}],"role":"model"},"finishReason":"STOP","index":0}]}"# + "\n\n"
    default:
        return [
            #"{"choices":[{"delta":{"content":"\#(text)"}}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#,
        ].map { "data: \($0)\n\n" }.joined() + "data: [DONE]\n\n"
    }
}

private func openAIToolLeg(_ calls: [(id: String, name: String, arguments: String)]) -> String {
    let deltas: [[String: Any]] = calls.enumerated().map { index, call in
        ["index": index, "id": call.id, "type": "function", "function": ["name": call.name, "arguments": call.arguments]]
    }
    let frames: [[String: Any]] = [
        ["choices": [["delta": ["tool_calls": deltas]]]],
        ["choices": [["delta": [String: Any](), "finish_reason": "tool_calls"]]],
    ]
    return frames.map { frame in
        let data = (try? JSONSerialization.data(withJSONObject: frame)) ?? Data()
        return "data: \(String(decoding: data, as: UTF8.self))\n\n"
    }.joined() + "data: [DONE]\n\n"
}

/// The production leg runner plus the production loop construction (the same `McpToolBridge.makeLoop` as `ChatManager.runMcpToolLoop`).
@MainActor
private func runLoop(
    transport: RelayTransport,
    plan: McpToolPlan,
    executor: McpToolExecutor,
    unhandled: UnhandledRecorder = UnhandledRecorder()
) async throws -> ToolCallLoop.Result {
    let (relay, model) = makeToolLoopRelayProvider(transport: transport)
    let pair = try ToolLoopLegRunnerFactory.make(
        provider: relay, model: model, modelID: model.id, reasoningMode: .automatic,
        requestOptions: ChatRequestOptions(), accessToken: nil,
        toolCallMemory: try makeToolLoopMemoryStore(), session: ScriptedModelURLProtocol.session()
    )
    let loop = McpToolBridge.makeLoop(
        plan: plan, executor: executor, legRunner: pair.runner, adapter: pair.adapter,
        runtimeConfig: .fallback, onUnhandledToolCalls: { await unhandled.record($0) }
    )
    return try await loop.run(messages: McpToolBridge.initialMessages(
        history: [ToolLoopMessage(role: "user", content: "Weather in Melbourne?")],
        systemPrompt: "Be brief."
    ))
}

private let weatherPlan = McpToolBridge.plan(servers: [input(snapshots: [snapshot("get_weather")])], runtimeConfig: .fallback)

@Suite("MCP tool bridge and loop wiring", .serialized)
struct McpToolBridgeTests {

    @Test("a large catalog does not use up the limit before later servers get a turn, and a server with no usable tools takes no turn")
    func distributesToolBudgetAcrossServers() {
        let other = UUID(uuidString: "BBBBBBBB-0000-4000-8000-000000000002")!
        let large = input(snapshots: (0..<45).map { snapshot("tool_\($0)") })
        let later = input(weatherRecord(id: other, slug: "notion"), snapshots: [snapshot("search", serverId: other), snapshot("fetch", serverId: other)])
        let empty = input(snapshots: [snapshot("off")], permissions: ["off": .off])
        let plan = McpToolBridge.plan(servers: [large, empty, later], runtimeConfig: McpRuntimeConfig(maxToolsPerRequest: 4))
        #expect(plan.tools.map(\.binding.toolName) == ["tool_0", "search", "tool_1", "fetch"])
        #expect(plan.truncated)
        let full = McpToolBridge.plan(servers: [large, later], runtimeConfig: McpRuntimeConfig(maxToolsPerRequest: 47))
        #expect(full.tools.count == 47)
        #expect(!full.truncated)
    }

    // MARK: Four wire protocols

    @Test(
        "four wire protocols: model proposal -> confirmation (run automatically) -> tools/call -> result fed back -> answer",
        arguments: [
            (RelayTransport.openaiChatCompletions, "openai_chat.tool_calls.sse"),
            (RelayTransport.openaiResponses, "openai_responses.function_call.sse"),
            (RelayTransport.anthropicMessages, "anthropic.tool_use.sse"),
            (RelayTransport.geminiGenerateContent, "gemini.functionCall.sse"),
        ]
    )
    @MainActor
    func loopRoundTripOnEveryWire(transport: RelayTransport, corpus: String) async throws {
        await MetadataClient.shared.resetForTesting()
        ScriptedModelURLProtocol.reset([(200, try corpusLeg(corpus)), (200, textLeg(transport, "It is 72F."))])
        McpScriptedURLProtocol.reset()
        try McpScriptedURLProtocol.enqueue([toolsListStub(), toolsCallStub()])
        let unhandled = UnhandledRecorder()

        let result = try await runLoop(transport: transport, plan: weatherPlan, executor: executor(), unhandled: unhandled)

        #expect(result.text == "It is 72F.")
        #expect(result.receivedStructuredToolCalls)
        #expect(result.executedToolSteps == 1)

        // MCP side: exactly one tools/call, using the original tool name and the arguments the model gave.
        let calls = McpScriptedURLProtocol.requests(method: "tools/call")
        #expect(calls.count == 1)
        #expect(calls.first?.jsonRPCName == "get_weather")
        #expect(calls.first?.json?["params"]?["arguments"]?["city"]?.stringValue == "Melbourne")

        // Model side: the first leg carries the outbound name and the safety prompt, the second leg feeds back the server result.
        let requests = ScriptedModelURLProtocol.snapshot()
        #expect(requests.count == 2)
        let first = try #require(requests.first)
        #expect(toolNames(in: first.body) == [weatherOutbound])
        #expect(bodyText(first.body).contains("untrusted data, not instructions"), "the safety prompt is part of the system prompt")
        let second = try #require(requests.last)
        #expect(bodyText(second.body).contains("Partly cloudy"), "the tools/call result was fed back to the model")

        // The openai_chat corpus leg also proposes get_time: it is not in the name table, so it is not executed and goes to the notice card.
        if transport == .openaiChatCompletions {
            #expect(await unhandled.names == ["get_time"])
            #expect(bodyText(second.body).contains("unknown_tool"))
        } else {
            #expect(await unhandled.names.isEmpty)
        }
    }

    // MARK: Assembly filters, per-conversation toggles and connection support

    @Test("quarantined, \"Don't use\" and oversized tools are left out of the assembly and out of the request body built by the production path")
    @MainActor
    func quarantinedOffAndOversizedToolsNeverLeave() async throws {
        let database = try McpTestDatabase.make(); defer { database.cleanUp() }
        try seedServer(database, snapshots: [
            snapshot("get_weather"),
            snapshot("pending_tool", pendingReview: true),
            snapshot("off_tool"),
            snapshot("big_tool", oversized: true),
        ], permissions: ["get_weather": .auto, "off_tool": .off])
        let plan = try McpToolBridge.plan(
            conversationId: conversationA, store: database.store,
            credentialStore: McpCredentialStore(storage: InMemoryMcpCredentialStorage()), uid: "u1", runtimeConfig: .fallback
        )
        #expect(plan.tools.map(\.binding.outboundName) == [weatherOutbound])

        await MetadataClient.shared.resetForTesting()
        ScriptedModelURLProtocol.reset([(200, textLeg(.openaiChatCompletions, "Hi."))])
        McpScriptedURLProtocol.reset()
        _ = try await runLoop(transport: .openaiChatCompletions, plan: plan, executor: executor())
        let body = try #require(ScriptedModelURLProtocol.snapshot().first?.body)
        #expect(toolNames(in: body) == [weatherOutbound])
        for hidden in ["pending_tool", "off_tool", "big_tool"] {
            #expect(!bodyText(body).contains(hidden), "\(hidden) must not appear in the request body")
        }
    }

    @Test("\"oversized\" is re-evaluated at assembly against the current runtime config: after lowering the limit a tool that fit in the old snapshot is no longer sent, and after raising it a flagged tool is not stuck forever")
    func oversizedIsRejudgedAgainstTheCurrentConfig() throws {
        let database = try McpTestDatabase.make(); defer { database.cleanUp() }
        let credentials = McpCredentialStore(storage: InMemoryMcpCredentialStorage())
        // When stored (limit 16384): get_weather fits; big_tool exceeds the limit and is flagged oversized.
        try seedServer(database, snapshots: [snapshot("get_weather"), snapshot("big_tool", oversized: true)])
        func names(maxBytes: Int) throws -> [String] {
            var config = McpRuntimeConfig.fallback
            config.maxToolDefinitionBytes = maxBytes
            return try McpToolBridge.plan(
                conversationId: conversationA, store: database.store, credentialStore: credentials, uid: "u1", runtimeConfig: config
            ).tools.map(\.snapshot.toolName)
        }
        #expect(try names(maxBytes: McpRuntimeConfig.fallback.maxToolDefinitionBytes) == ["get_weather"])
        #expect(try names(maxBytes: 16).isEmpty, "limit lowered: a tool that fit when stored is now over the limit")
        #expect(Set(try names(maxBytes: 200_000)) == ["get_weather", "big_tool"], "limit raised: a tool flagged oversized when stored now fits")
    }

    @Test("local state is re-read before execution: a missing record, a quarantined tool, \"Don't use\", a changed definition or title, an oversized tool and a URL missing on this device are all unavailable; the permission is the current one")
    func liveStateReflectsTheStoreAtCallTime() throws {
        let database = try McpTestDatabase.make(); defer { database.cleanUp() }
        let credentials = McpCredentialStore(storage: InMemoryMcpCredentialStorage())
        try seedServer(database, snapshots: [snapshot("get_weather")])
        let tool = try #require(try McpToolBridge.plan(
            conversationId: conversationA, store: database.store, credentialStore: credentials, uid: "u1", runtimeConfig: .fallback
        ).tools.first)
        func live(_ config: McpRuntimeConfig = .fallback) -> McpLiveToolState {
            McpToolBridge.liveState(of: tool, store: database.store, credentialStore: credentials, uid: "u1", runtimeConfig: config)
        }
        func rewrite(_ change: (inout McpToolSnapshot) -> Void) throws {
            var current = snapshot("get_weather")
            change(&current)
            try database.store.replaceToolSnapshots(serverId: weatherServerID, snapshots: [current])
        }
        let endpoint = try #require(URL(string: "https://mcp.example.com/mcp"))
        #expect(live() == .usable(permission: .auto, endpoint: endpoint))

        try database.store.setToolPermission(.ask, serverId: weatherServerID, toolName: "get_weather")
        #expect(live() == .usable(permission: .ask, endpoint: endpoint), "tightened to ask every time: still usable, but it must pass the gate again")
        try database.store.setToolPermission(.off, serverId: weatherServerID, toolName: "get_weather")
        #expect(live() == .unavailable)
        try database.store.setToolPermission(.auto, serverId: weatherServerID, toolName: "get_weather")

        try rewrite { $0.pendingReview = true }
        #expect(live() == .unavailable, "quarantined")
        try rewrite { $0.contentHash = sha256Hex("changed") }
        #expect(live() == .unavailable, "the definition changed, and even if the user confirmed the new one the model still holds the old one")
        try rewrite { $0.title = "Delete everything" }
        #expect(live() == .unavailable, "the title changed")
        try rewrite { _ in }
        #expect(live() == .usable(permission: .auto, endpoint: endpoint))

        var tiny = McpRuntimeConfig.fallback
        tiny.maxToolDefinitionBytes = 16
        #expect(live(tiny) == .unavailable, "oversized under the current config")
        #expect(live(McpRuntimeConfig(enabled: false)) == .unavailable, "the master switch is off")

        try database.store.deleteServer(id: weatherServerID)
        #expect(live() == .unavailable, "the record is gone")
    }

    @Test("a conversation with no server enabled assembles nothing; the toggle is per conversation and does not leak from another one")
    func nothingEnabledMeansNoTools() throws {
        let database = try McpTestDatabase.make(); defer { database.cleanUp() }
        let credentials = McpCredentialStore(storage: InMemoryMcpCredentialStorage())
        try seedServer(database, snapshots: [snapshot("get_weather")], enabledIn: [conversationA])

        let other = try McpToolBridge.plan(
            conversationId: conversationB, store: database.store, credentialStore: credentials, uid: "u1", runtimeConfig: .fallback
        )
        #expect(other.isEmpty)
        let enabled = try McpToolBridge.plan(
            conversationId: conversationA, store: database.store, credentialStore: credentials, uid: "u1", runtimeConfig: .fallback
        )
        #expect(enabled.tools.map(\.binding.outboundName) == [weatherOutbound])

        // After turning it off the same conversation carries nothing either.
        try database.store.setServerEnabled(false, conversationId: conversationA, serverId: weatherServerID)
        #expect(try McpToolBridge.plan(
            conversationId: conversationA, store: database.store, credentialStore: credentials, uid: "u1", runtimeConfig: .fallback
        ).isEmpty)
        // Nor with the master switch off.
        try database.store.setServerEnabled(true, conversationId: conversationA, serverId: weatherServerID)
        #expect(try McpToolBridge.plan(
            conversationId: conversationA, store: database.store, credentialStore: credentials, uid: "u1",
            runtimeConfig: McpRuntimeConfig(enabled: false)
        ).isEmpty)
    }

    @Test("the connection gate follows the model: tool-call support carries MCP tools, a model without it does not")
    @MainActor
    func connectionGateFollowsToolCallSupport() throws {
        let memory = try makeToolLoopMemoryStore()
        let (supported, supportedModel) = makeToolLoopRelayProvider(transport: .openaiChatCompletions, toolCall: true)
        #expect(McpToolBridge.connectionSupportsTools(provider: supported, model: supportedModel, memory: memory))
        let (unsupported, unsupportedModel) = makeToolLoopRelayProvider(transport: .openaiChatCompletions, toolCall: false)
        #expect(!McpToolBridge.connectionSupportsTools(provider: unsupported, model: unsupportedModel, memory: memory))
    }

    @Test("assembly: a server that needs a new sign-in or lacks its full URL is left out entirely; above the limit the servers take turns")
    func planExcludesUnusableServersAndCaps() {
        let second = UUID()
        let plan = McpToolBridge.plan(servers: [
            input(snapshots: [snapshot("get_weather"), snapshot("get_time")]),
            input(weatherRecord(id: second, slug: "second"), snapshots: [snapshot("ping", serverId: second)]),
        ], runtimeConfig: McpRuntimeConfig(maxToolsPerRequest: 2))
        #expect(plan.tools.map(\.binding.outboundName) == ["mcp_weather_get_weather", "mcp_second_ping"])
        #expect(plan.truncated)

        #expect(McpToolBridge.plan(servers: [input(status: .needsAuth, snapshots: [snapshot("get_weather")])], runtimeConfig: .fallback).isEmpty)
        #expect(McpToolBridge.plan(
            servers: [input(weatherRecord(localOnly: true), endpoint: .needsAddress, snapshots: [snapshot("get_weather")])],
            runtimeConfig: .fallback
        ).isEmpty, "a localOnly server without its full URL must not send requests to the display URL")

        // Name table: outbound name -> server + original tool name.
        #expect(plan.nameTable[weatherOutbound] == McpToolBinding(outboundName: weatherOutbound, serverId: weatherServerID, toolName: "get_weather"))
        #expect(plan.nameTable["get_weather"] == nil, "the original name is not in the name table, so a model that answers with it is not executed")
    }

    // MARK: The three confirmation choices

    @Test("\"Ask every time\" denied: no tools/call (the server is not even contacted), user_denied is fed back and the answer continues")
    @MainActor
    func deniedAskToolNeverCallsServer() async throws {
        let plan = McpToolBridge.plan(
            servers: [input(snapshots: [snapshot("get_weather", readOnly: false)])], runtimeConfig: .fallback
        )
        #expect(plan.tools.first?.permission == .ask)
        await MetadataClient.shared.resetForTesting()
        ScriptedModelURLProtocol.reset([
            (200, try corpusLeg("openai_chat.tool_calls.sse")), (200, textLeg(.openaiChatCompletions, "Skipped.")),
        ])
        McpScriptedURLProtocol.reset()
        let gate = ScriptedGate([.deny])

        let result = try await runLoop(transport: .openaiChatCompletions, plan: plan, executor: executor(gate: gate))

        #expect(result.text == "Skipped.")
        #expect(await gate.asked.map(\.toolName) == ["get_weather"])
        #expect(await gate.asked.first?.arguments["city"]?.stringValue == "Melbourne")
        #expect(McpScriptedURLProtocol.requests().isEmpty, "the server received no request after the denial")
        let second = try #require(ScriptedModelURLProtocol.snapshot().last)
        #expect(bodyText(second.body).contains("user_denied"))
    }

    @Test("three confirmation choices: allow once asks again next time; allow for the conversation applies to the same server, tool and conversation only; deny does not call")
    func confirmationChoices() async throws {
        let tools = McpToolBridge.plan(servers: [input(snapshots: [
            snapshot("get_weather", readOnly: false), snapshot("create_issue", readOnly: false),
        ])], runtimeConfig: .fallback).tools
        let weather = try #require(tools.first { $0.snapshot.toolName == "get_weather" })
        let issue = try #require(tools.first { $0.snapshot.toolName == "create_issue" })
        let call = ToolLoopToolCall(id: "c1", function: .init(name: weatherOutbound, arguments: #"{"city":"Melbourne"}"#))
        let context = ToolExecutionContext(callID: "c1", stepNumber: 1, legIndex: 0)
        McpScriptedURLProtocol.reset()
        McpScriptedURLProtocol.setFallback(try toolsCallStub())
        McpScriptedURLProtocol.enqueue(try toolsListStub())
        let grants = McpConversationGrants()

        // Allow once: the call is made, and the next one (a new answer turn) asks again.
        let onceGate = ScriptedGate([.once, .conversation])
        _ = try await executor(gate: onceGate, grants: grants).execute(weather, call: call, context: context)
        #expect(McpScriptedURLProtocol.requests(method: "tools/call").count == 1)
        McpScriptedURLProtocol.enqueue(try toolsListStub())
        _ = try await executor(gate: onceGate, grants: grants).execute(weather, call: call, context: context)
        #expect(await onceGate.asked.count == 2, "allow once leaves no record")

        // Allow for the conversation: the same tool in the same conversation is not asked again; another tool or another conversation is.
        let quietGate = ScriptedGate([])
        McpScriptedURLProtocol.enqueue(try toolsListStub())
        _ = try await executor(gate: quietGate, grants: grants).execute(weather, call: call, context: context)
        #expect(await quietGate.asked.isEmpty)
        let issueCall = ToolLoopToolCall(id: "c2", function: .init(name: "mcp_weather_create_issue", arguments: "{}"))
        let denied = try await executor(gate: quietGate, grants: grants).execute(issue, call: issueCall, context: context)
        #expect(await quietGate.asked.map(\.toolName) == ["create_issue"], "another tool of the same server still asks")
        #expect(denied.content.contains("user_denied"))
        _ = try await executor(conversation: conversationB, gate: quietGate, grants: grants).execute(weather, call: call, context: context)
        #expect(await quietGate.asked.count == 2, "it does not carry over to another conversation")
        #expect(McpScriptedURLProtocol.requests(method: "tools/call").count == 3, "neither denial sent a tools/call")
    }

    @Test("arguments that are not an object or miss a required field throw ToolCallRejection so the model can correct itself; the user is not asked and nothing is called")
    func invalidArgumentsAreRejectedBeforeConfirmation() async throws {
        let plan = McpToolBridge.plan(servers: [input(snapshots: [
            snapshot("get_weather", readOnly: false, inputSchema: schema(["city"], required: ["city"])),
        ])], runtimeConfig: .fallback)
        let tool = try #require(plan.tools.first)
        let gate = ScriptedGate([.once])
        McpScriptedURLProtocol.reset()
        for arguments in ["[1]", "{\"unit\":\"c\"}", "not json"] {
            let call = ToolLoopToolCall(id: "c", function: .init(name: weatherOutbound, arguments: arguments))
            await #expect(throws: ToolCallRejection.self) {
                _ = try await executor(gate: gate).execute(tool, call: call, context: ToolExecutionContext(callID: "c", stepNumber: 1, legIndex: 0))
            }
        }
        #expect(await gate.asked.isEmpty)
        #expect(McpScriptedURLProtocol.requests().isEmpty)
    }

    // MARK: Failure degradation

    @Test("repeated server errors: each one is fed back as ok:false and the answer still completes; consecutive failures do not abort the turn")
    @MainActor
    func repeatedServerFailuresDegradeWithoutAbortingTheTurn() async throws {
        await MetadataClient.shared.resetForTesting()
        let leg = openAIToolLeg([(id: "c1", name: weatherOutbound, arguments: #"{"city":"A"}"#)])
        ScriptedModelURLProtocol.reset([
            (200, leg), (200, leg.replacingOccurrences(of: "\"c1\"", with: "\"c2\"")),
            (200, leg.replacingOccurrences(of: "\"c1\"", with: "\"c3\"")), (200, textLeg(.openaiChatCompletions, "Unavailable.")),
        ])
        McpScriptedURLProtocol.reset()
        McpScriptedURLProtocol.enqueue(try toolsListStub())
        McpScriptedURLProtocol.setFallback(McpScriptedURLProtocol.Stub(status: 500))

        let result = try await runLoop(transport: .openaiChatCompletions, plan: weatherPlan, executor: executor())

        #expect(result.text == "Unavailable.")
        #expect(McpScriptedURLProtocol.requests(method: "tools/call").count == 3, "a failed tools/call is not retried automatically, so there is one per proposal")
        let last = try #require(ScriptedModelURLProtocol.snapshot().last)
        let toolContents = (last.body["messages"] as? [[String: Any]] ?? [])
            .filter { $0["role"] as? String == "tool" }.compactMap { $0["content"] as? String }
        #expect(toolContents.count == 3)
        #expect(toolContents.allSatisfy { $0.contains("\"ok\":false") && !$0.contains("Internal") }, "only the closed-set code is fed back, never the server's own text")
    }
}
