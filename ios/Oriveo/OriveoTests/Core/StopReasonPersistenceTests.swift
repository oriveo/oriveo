import Foundation
import GRDB
import OriveoProviderKit
import Testing
@testable import Oriveo

// Persistence contract: when an assistant message finishes, stopReason is written from the stream-end info and persisted.
// Assertions come from the production path: `sendMessage` -> `ChatManager` finalization -> `upsertConversationProjection` -> GRDB,
// and the database is read through `ConversationRuntimeBridge.fetchConversationProjection`.

/// A replay protocol owned by this suite: it shares no state with the process-level replay protocols of other suites.
final class StopReasonURLProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        /// Ends normally after a complete response.
        case body(status: Int, text: String)
        /// Delivers some body text first, then disconnects with a transport error.
        case partialThenFail(text: String)
        /// Disconnects with a transport error without delivering a single byte.
        case fail
        /// Delivers some body text, then hangs without ending (waiting for the user to stop).
        case hang(text: String)
    }

    nonisolated(unsafe) static var reply: (@Sendable (URLRequest) -> Reply?)?
    nonisolated(unsafe) static var hangDelivered = false

    static func reset() {
        reply = nil
        hangDelivered = false
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StopReasonURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url ?? URL(string: "https://invalid.test")!
        func respond(_ status: Int) {
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": status == 200 ? "text/event-stream" : "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        guard let reply = Self.reply?(request) else {
            respond(404)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        switch reply {
        case let .body(status, text):
            respond(status)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case let .partialThenFail(text):
            respond(200)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            // The body is delivered first and the connection drops a little later: an error right behind it would keep the stream reader from reading even the bytes that already arrived.
            let client = client
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            }
        case .fail:
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        case let .hang(text):
            respond(200)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            Self.hangDelivered = true
        }
    }

    override func stopLoading() {}
}

/// Counts provider requests so a scripted reply can differ per leg.
nonisolated final class StopReasonRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func next() -> Int { lock.withLock { value += 1; return value } }
}

/// Reported usage of the finished legs in the multi-leg stop cases.
private let stopReasonFinishedInput = 5_000
private let stopReasonFinishedOutput = 300
private let stopReasonUsageFrame =
    #"{"choices":[],"usage":{"prompt_tokens":5000,"completion_tokens":300,"total_tokens":5300}}"#
/// Long finished-leg text / reasoning: estimating it again would add far more than the stopped leg's own text.
private let stopReasonLongText = String(repeating: "The user wants a careful answer. ", count: 24)

/// One read-only `get_weather` MCP tool enabled for the conversation.
private func seedStopReasonMcpServer(_ database: McpTestDatabase, conversationID: UUID) throws {
    let store = database.store
    let schema = JSONValue.object(JSONObject([
        ("type", .string("object")),
        ("properties", .object(JSONObject([("city", .object(JSONObject([("type", .string("string"))])))]))),
    ]))
    try store.addServer(
        McpServerAddition(
            id: stopReasonMcpServerID, name: "Weather", url: "https://mcp.example.com/mcp", authKind: .auto,
            localOnly: false, iconURL: nil, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            snapshots: [McpToolSnapshot(
                serverId: stopReasonMcpServerID, toolName: "get_weather", title: "Get weather",
                description: "Weather lookup", inputSchema: schema,
                annotations: .object(JSONObject([("readOnlyHint", .bool(true))])),
                contentHash: sha256Hex("stop-reason:get_weather"), readOnly: true,
                pendingReview: false, oversized: false
            )],
            permissions: [:],
            connectionState: McpConnectionState(serverId: stopReasonMcpServerID, status: .connected, generation: .stateless)
        ),
        maxServers: 20
    )
    try store.setServerEnabled(true, conversationId: conversationID, serverId: stopReasonMcpServerID)
}

nonisolated private func stopReasonChatSSE(_ frames: [String]) -> String {
    frames.map { "data: \($0)\n\n" }.joined() + "data: [DONE]\n\n"
}

private let stopReasonMcpServerID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-0000000005C2")!

@Suite("StopReasonPersistenceTests", .serialized, .sharedProcessState)
@MainActor
struct StopReasonPersistenceTests {

    // MARK: - Fixtures

    private func makeState(prefix: String) -> (AppState, String) {
        let uid = "stop-reason-\(prefix)-\(UUID().uuidString)"
        let state = AppState(seedDemoData: false, sessionUID: uid, providerSession: StopReasonURLProtocol.session())
        return (state, uid)
    }

    private func waitUntil(
        _ label: String,
        iterations: Int = 150,
        condition: @MainActor () -> Bool
    ) async throws {
        for _ in 0..<iterations {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("Timed out waiting for \(label)")
    }

    private func lastAssistant(_ state: AppState, _ conversationID: UUID) -> ChatMessage? {
        state.conversation(for: conversationID)?.messages.last { $0.role == .assistant }
    }

    /// Waits for finalization to settle, then reads this message back from the database.
    private func storedMessage(_ state: AppState, uid: String, conversationID: UUID, messageID: UUID) throws -> ChatMessage? {
        state.flushConversationPersistQueue()
        return try state.conversationRuntimeBridge
            .fetchConversationProjection(id: conversationID, uid: uid)?
            .messages.first { $0.id == messageID }
    }

    /// Sends via OpenRouter (openai_chat family): returns the conversation id.
    private func sendOpenRouter(
        prefix: String,
        kind: ProviderKind = .openRouter,
        modelID: String = "openai/gpt-4o-mini",
        beforeSend: (AppState) async throws -> Void = { _ in },
        reply: @escaping @Sendable (URLRequest) -> StopReasonURLProtocol.Reply?
    ) async throws -> (AppState, String, UUID) {
        StopReasonURLProtocol.reset()
        StopReasonURLProtocol.reply = { request in
            guard request.url?.path.hasSuffix("/chat/completions") == true else { return nil }
            return reply(request)
        }
        let (state, uid) = makeState(prefix: prefix)
        let provider = TestFactories.makeProvider(
            kind: kind,
            models: [TestFactories.makeModel(id: modelID, name: modelID, isDefault: true)]
        )
        let conversation = TestFactories.makeConversation(
            providerID: provider.id, providerKind: kind, modelID: modelID
        )
        state.providers = [provider]
        state.upsertConversationProjection(conversation)
        try await beforeSend(state)
        _ = await state.sendMessage("Hello", in: conversation.id)
        return (state, uid, conversation.id)
    }

    private func waitSettled(_ state: AppState, _ conversationID: UUID) async throws -> ChatMessage {
        try await waitUntil("assistant settled") {
            guard let message = lastAssistant(state, conversationID) else { return false }
            return message.state != .generating && !state.chatManager.isBusyStreaming(in: conversationID)
        }
        return try #require(lastAssistant(state, conversationID))
    }

    // MARK: - BYOK

    @Test func delivered_length() async throws {
        defer { StopReasonURLProtocol.reset() }
        let (state, uid, conversationID) = try await sendOpenRouter(prefix: "length") { _ in
            .body(status: 200, text: stopReasonChatSSE([
                #"{"choices":[{"delta":{"content":"Cut off here"}}]}"#,
                #"{"choices":[{"delta":{},"finish_reason":"length"}]}"#,
            ]))
        }
        let message = try await waitSettled(state, conversationID)
        #expect(message.state == .delivered, "state and UI unchanged")
        #expect(message.stopReason == .length)
        let stored = try #require(try storedMessage(state, uid: uid, conversationID: conversationID, messageID: message.id))
        #expect(stored.stopReason == .length, "length was persisted")
    }

    @Test func user_stop_interrupted() async throws {
        defer { StopReasonURLProtocol.reset() }
        let (state, uid, conversationID) = try await sendOpenRouter(prefix: "user-stop") { _ in
            .hang(text: "data: {\"choices\":[{\"delta\":{\"content\":\"Partial answer\"}}]}\n\n")
        }
        try await waitUntil("stream delivered first chunk") { StopReasonURLProtocol.hangDelivered }
        try await Task.sleep(nanoseconds: 150_000_000)
        state.chatManager.cancelGeneration(in: conversationID)
        let message = try await waitSettled(state, conversationID)
        #expect(message.state == .interrupted)
        #expect(message.stopReason == .interrupted)
        let stored = try #require(try storedMessage(state, uid: uid, conversationID: conversationID, messageID: message.id))
        #expect(stored.stopReason == .interrupted)
    }

    /// Priced model plus one auto skill, so the stopped turn sends a skill manifest and its cost is derivable.
    /// The user-skill cache is keyed by the global active UID; callers must clear it with `clearUserSkills`.
    private func pricedSkillSetup(_ state: AppState) {
        state.providers = state.providers.map { provider in
            var provider = provider
            provider.models = provider.models.map {
                TestFactories.makeModel(
                    id: $0.id, name: $0.name, isDefault: true, promptPrice: 0.000002, completionPrice: 0.000008
                )
            }
            return provider
        }
        state.skillManager.replaceUserSkills([
            Skill(
                id: UUID(), name: "Poet", systemPrompt: "Answer in verse.",
                whenToUse: "The user asks for a poem.", autoInvoke: true, source: .user
            ),
        ])
    }

    private func clearUserSkills(_ state: AppState) {
        state.skillManager.replaceUserSkills([])
    }

    /// A stop after visible text records the estimated usage like a completion and keeps the message interrupted
    ///.
    @Test func user_stop_records_estimated_usage() async throws {
        defer { StopReasonURLProtocol.reset() }
        let ledger = try FixedRhoLedger()
        let (state, uid, conversationID) = try await sendOpenRouter(
            prefix: "user-stop-usage", beforeSend: { state in
                pricedSkillSetup(state)
                try ledger.inject(into: state)
            }
        ) { _ in
            .hang(text: "data: {\"choices\":[{\"delta\":{\"content\":\"Partial answer\"}}]}\n\n")
        }
        defer { clearUserSkills(state) }
        try await waitUntil("stream delivered first chunk") { StopReasonURLProtocol.hangDelivered }
        try await Task.sleep(nanoseconds: 150_000_000)
        state.chatManager.cancelGeneration(in: conversationID)
        _ = try await waitSettled(state, conversationID)
        try await waitUntil("stopped usage written") { lastAssistant(state, conversationID)?.outputTokens != nil }
        let message = try #require(lastAssistant(state, conversationID))
        #expect(message.state == .interrupted)
        #expect(message.stopReason == .interrupted)
        // Input = the request estimate at rhoHi 0.46; output = ceil(14 UTF-8 bytes of "Partial answer" x 0.46) = 7.
        #expect(message.inputTokens == 273, "input is the request estimate, got \(String(describing: message.inputTokens))")
        #expect(message.outputTokens == 7, "output is the visible text estimate, got \(String(describing: message.outputTokens))")
        #expect(message.costSource == .localEstimate)
        // Priced at the catalog rate for openai/gpt-4o-mini ($0.15 / $0.60 per 1M): 273 x 0.15e-6 + 7 x 0.6e-6.
        #expect(abs(message.estimatedCost - 4.515e-05) < 1e-12, "cost got \(message.estimatedCost)")
        #expect(message.skillManifestTokens == 262, "the turn sent a skill manifest, got \(String(describing: message.skillManifestTokens))")
        let stored = try #require(try storedMessage(state, uid: uid, conversationID: conversationID, messageID: message.id))
        #expect(stored.state == .interrupted)
        #expect(stored.outputTokens == message.outputTokens)
        #expect(stored.costSource == .localEstimate)
    }

    /// Nothing visible at the stop: no tokens, cost unknown, no skill manifest tokens
    ///.
    @Test func user_stop_before_output_records_nothing() async throws {
        defer { StopReasonURLProtocol.reset() }
        let (state, uid, conversationID) = try await sendOpenRouter(
            prefix: "user-stop-nothing", beforeSend: { pricedSkillSetup($0) }
        ) { _ in
            .hang(text: "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}\n\n")
        }
        defer { clearUserSkills(state) }
        try await waitUntil("stream delivered first chunk") { StopReasonURLProtocol.hangDelivered }
        try await Task.sleep(nanoseconds: 150_000_000)
        state.chatManager.cancelGeneration(in: conversationID)
        _ = try await waitSettled(state, conversationID)
        try await Task.sleep(nanoseconds: 300_000_000)
        let message = try #require(lastAssistant(state, conversationID))
        #expect(message.state == .interrupted)
        #expect(message.inputTokens == nil)
        #expect(message.outputTokens == nil)
        #expect(message.costSource != .localEstimate)
        #expect(message.skillManifestTokens == nil)
        let stored = try #require(try storedMessage(state, uid: uid, conversationID: conversationID, messageID: message.id))
        #expect(stored.outputTokens == nil)
        #expect(stored.skillManifestTokens == nil)
    }

    /// D-251: a thinking first leg with empty text and a propose_memory call is billed, then the plain resend is
    /// stopped. The resend's single delta arrives inside the 40 ms flush window and no later event follows; the tail
    /// flush still surfaces it, so the stop records the first leg's reported usage plus the resend's visible text
    ///.
    @Test func user_stop_after_propose_leg_keeps_its_usage() async throws {
        defer { StopReasonURLProtocol.reset() }
        StopReasonURLProtocol.reset()
        let firstLeg = stopReasonChatSSE([
            #"{"choices":[{"delta":{"reasoning_content":"The user wants brevity."}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_p1","type":"function","function":{"name":"\#(MemoryPropose.toolName)","arguments":"{\"proposition\":\"Prefers short answers\",\"sourceQuote\":\"I like short answers\",\"kind\":\"preference\",\"scope\":\"global\"}"}}]}}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
            #"{"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":2,"total_tokens":12}}"#,
        ])
        let requests = StopReasonRequestCounter()
        StopReasonURLProtocol.reply = { request in
            guard request.url?.path.hasSuffix("/chat/completions") == true else { return nil }
            return requests.next() == 1
                ? .body(status: 200, text: firstLeg)
                : .hang(text: "data: {\"choices\":[{\"delta\":{\"content\":\"Partial answer\"}}]}\n\n")
        }
        let uid = "stop-reason-propose-\(UUID().uuidString)"
        let state = AppState(
            seedDemoData: false, sessionUID: uid, providerSession: StopReasonURLProtocol.session(),
            toolCallMemory: try makeR4MemoryStore()
        )
        let (provider, model) = makeToolLoopRelayProvider(transport: .openaiChatCompletions)
        state.providers = [provider]
        var conversation = TestFactories.makeConversation(
            hasCustomTitle: true, providerID: provider.id, modelID: model.id, messages: []
        )
        conversation.useMemory = true
        state.upsertConversationProjection(conversation)
        let ledger = try FixedRhoLedger()
        try ledger.inject(into: state, provider: provider, model: model)
        // Same setup as the delivered D-251 case: web on, so the turn makes exactly the first leg and the resend.
        RelayWebSwitch.write(true, provider: provider, model: model, conversationID: conversation.id)
        defer {
            RelayWebFragmentStore.shared.deleteConnection(provider.id)
            RelayWebProbeStore.shared.clearConnection(provider.id.uuidString)
            Task { await TestPartitionCleanup.remove(uid) }
        }
        _ = await state.sendMessage("Remember that I like short answers", in: conversation.id)

        try await waitUntil("resend streaming") { requests.count == 2 && StopReasonURLProtocol.hangDelivered }
        try await waitUntil("stalled resend delta flushed") {
            state.chatManager.streamingText(in: conversation.id) == "Partial answer"
        }
        state.chatManager.cancelGeneration(in: conversation.id)
        _ = try await waitSettled(state, conversation.id)
        try await waitUntil("stopped usage written") { lastAssistant(state, conversation.id)?.outputTokens != nil }
        let message = try #require(lastAssistant(state, conversation.id))
        #expect(requests.count == 2, "first leg and the plain resend, got \(requests.count) requests")
        #expect(message.state == .interrupted)
        #expect(message.text == "Partial answer")
        // First leg reports 10 / 2; the resend adds its request estimate (20) and ceil(14 x 0.46) = 7 output.
        // This case sets no user skill. The earlier 296 (ab1abfe2d3) was recorded while another case's auto skill
        // leaked through the global-UID user-skill cache and added a skill manifest to the resend.
        #expect(message.inputTokens == 30, "the first leg plus the resend's request estimate, got \(String(describing: message.inputTokens))")
        #expect(message.outputTokens == 9, "the first leg plus the resend's visible text estimate, got \(String(describing: message.outputTokens))")
    }

    /// The stopped message carries the finished legs' reported usage plus an estimate for the stopped leg's own
    /// visible text only: the estimate stays far below what the finished legs' long text / reasoning would add.
    private func expectFinishedLegsPlusStoppedEstimate(_ message: ChatMessage) {
        #expect(message.state == .interrupted)
        let addedInput = (message.inputTokens ?? 0) - stopReasonFinishedInput
        let addedOutput = (message.outputTokens ?? 0) - stopReasonFinishedOutput
        #expect(addedInput > 0 && addedInput < stopReasonFinishedInput, "finished input once plus the request estimate, added \(addedInput)")
        #expect(addedOutput > 0 && addedOutput < 40, "finished output plus the stopped leg's visible text only, added \(addedOutput)")
    }

    /// MCP loop: the tool-call leg (long reasoning, reported usage) finished, the answer leg is stopped after text
    ///.
    @Test func user_stop_during_mcp_tool_loop_keeps_finished_leg_usage() async throws {
        defer { StopReasonURLProtocol.reset() }
        let database = try McpTestDatabase.make()
        let mcpDirectory = McpServerDirectory(
            credentialStore: McpCredentialStore(storage: InMemoryMcpCredentialStorage()),
            openStore: { _ in database.store }
        )
        defer { database.cleanUp(after: mcpDirectory) }
        McpScriptedURLProtocol.reset()
        try McpScriptedURLProtocol.enqueue([
            McpClientFixture.stub("protocol/stateless/tools-list.response.json"),
            McpClientFixture.stub("protocol/stateless/tools-call.response.json"),
        ])
        StopReasonURLProtocol.reset()
        let requests = StopReasonRequestCounter()
        let callLeg = stopReasonChatSSE([
            #"{"choices":[{"delta":{"reasoning_content":"\#(stopReasonLongText)"}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_w1","type":"function","function":{"name":"mcp_weather_get_weather","arguments":"{\"city\":\"Melbourne\"}"}}]}}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
            stopReasonUsageFrame,
        ])
        StopReasonURLProtocol.reply = { request in
            guard request.url?.path.hasSuffix("/chat/completions") == true else { return nil }
            return requests.next() == 1
                ? .body(status: 200, text: callLeg)
                : .hang(text: "data: {\"choices\":[{\"delta\":{\"content\":\"Partial answer\"}}]}\n\n")
        }
        let state = AppState(
            seedDemoData: true,
            providerSession: StopReasonURLProtocol.session(),
            toolCallMemory: try makeToolLoopMemoryStore(),
            mcpServerDirectory: mcpDirectory
        )
        let (relay, model) = makeToolLoopRelayProvider(transport: .openaiChatCompletions)
        let conversationID = UUID()
        try seedStopReasonMcpServer(database, conversationID: conversationID)
        state.providers = [relay]
        state.conversations = [TestFactories.makeConversation(id: conversationID, providerID: relay.id, modelID: model.id, messages: [])]
        state.chatManager.debugUseMcpClientFactoryForTesting { McpClient(endpoint: $0, session: McpScriptedURLProtocol.session()) }

        _ = await state.chatManager.sendMessage("Weather?", in: conversationID, capabilitySelection: ChatCapabilitySelection())
        try await waitUntil("answer leg text visible") {
            state.chatManager.streamingText(in: conversationID) == "Partial answer"
        }
        state.chatManager.cancelGeneration(in: conversationID)
        _ = try await waitSettled(state, conversationID)
        try await waitUntil("stopped usage written") { lastAssistant(state, conversationID)?.outputTokens != nil }
        let message = try #require(lastAssistant(state, conversationID))
        #expect(requests.count == 2, "tool-call leg and answer leg, got \(requests.count) requests")
        expectFinishedLegsPlusStoppedEstimate(message)
    }

    /// Memory tail: the first leg (long text plus a propose_memory call, reported usage) is held for its tail; the
    /// tail is stopped after text and only the tail's own text is estimated
    ///.
    @Test func user_stop_after_memory_tail_first_leg_keeps_its_usage() async throws {
        defer { StopReasonURLProtocol.reset() }
        StopReasonURLProtocol.reset()
        let requests = StopReasonRequestCounter()
        let firstLeg = stopReasonChatSSE([
            #"{"choices":[{"delta":{"content":"\#(stopReasonLongText)"}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_p1","type":"function","function":{"name":"\#(MemoryPropose.toolName)","arguments":"{\"proposition\":\"Prefers short answers\",\"sourceQuote\":\"I like short answers\",\"kind\":\"preference\",\"scope\":\"global\"}"}}]}}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
            stopReasonUsageFrame,
        ])
        StopReasonURLProtocol.reply = { request in
            guard request.url?.path.hasSuffix("/chat/completions") == true else { return nil }
            return requests.next() == 1
                ? .body(status: 200, text: firstLeg)
                : .hang(text: "data: {\"choices\":[{\"delta\":{\"content\":\"Partial answer\"}}]}\n\n")
        }
        let uid = "stop-reason-tail-\(UUID().uuidString)"
        let state = AppState(
            seedDemoData: false, sessionUID: uid, providerSession: StopReasonURLProtocol.session(),
            toolCallMemory: try makeR4MemoryStore()
        )
        let (provider, model) = makeToolLoopRelayProvider(transport: .openaiChatCompletions)
        state.providers = [provider]
        var conversation = TestFactories.makeConversation(
            hasCustomTitle: true, providerID: provider.id, modelID: model.id, messages: []
        )
        conversation.useMemory = true
        state.upsertConversationProjection(conversation)
        defer { Task { await TestPartitionCleanup.remove(uid) } }
        _ = await state.sendMessage("Remember that I like short answers", in: conversation.id)

        try await waitUntil("tail text visible") {
            state.chatManager.streamingText(in: conversation.id).hasSuffix("Partial answer")
        }
        state.chatManager.cancelGeneration(in: conversation.id)
        _ = try await waitSettled(state, conversation.id)
        try await waitUntil("stopped usage written") { lastAssistant(state, conversation.id)?.outputTokens != nil }
        let message = try #require(lastAssistant(state, conversation.id))
        #expect(requests.count == 2, "first leg and the tail, got \(requests.count) requests")
        expectFinishedLegsPlusStoppedEstimate(message)
    }

    @Test func system_interrupt_incomplete() async throws {
        defer { StopReasonURLProtocol.reset() }
        let (state, uid, conversationID) = try await sendOpenRouter(prefix: "forced-stop") { _ in
            .hang(text: "data: {\"choices\":[{\"delta\":{\"content\":\"Partial answer long enough to flush now\"}}]}\n\n")
        }
        try await waitUntil("stream delivered first chunk") { StopReasonURLProtocol.hangDelivered }
        // Body text past 32 characters enters the session immediately, without waiting for throttling.
        try await waitUntil("partial text reached session") {
            state.chatManager.streamingText(in: conversationID).contains("Partial answer")
        }
        // A forced stop goes through forceStopStreaming: a system interruption is not a user stop, and with body text it records incomplete.
        state.chatManager.forceStopStreaming()
        let message = try await waitSettled(state, conversationID)
        #expect(message.state == .interrupted, "state is still persisted as interrupted")
        #expect(message.stopReason == .incomplete)
        let stored = try #require(try storedMessage(state, uid: uid, conversationID: conversationID, messageID: message.id))
        #expect(stored.stopReason == .incomplete)
    }

    @Test func transport_error_after_text() async throws {
        defer { StopReasonURLProtocol.reset() }
        let (state, uid, conversationID) = try await sendOpenRouter(prefix: "transport-after") { _ in
            .partialThenFail(text: "data: {\"choices\":[{\"delta\":{\"content\":\"Half an answer\"}}]}\n\n")
        }
        let message = try await waitSettled(state, conversationID)
        #expect(message.text.contains("Half an answer"), "body text before the disconnect was delivered")
        #expect(message.stopReason == .incomplete, "a transport error with body text records incomplete")
        let stored = try #require(try storedMessage(state, uid: uid, conversationID: conversationID, messageID: message.id))
        #expect(stored.stopReason == .incomplete)
    }

    @Test func transport_error_before_text() async throws {
        defer { StopReasonURLProtocol.reset() }
        let (state, uid, conversationID) = try await sendOpenRouter(prefix: "transport-before") { _ in .fail }
        let message = try await waitSettled(state, conversationID)
        #expect(message.state == .failed)
        #expect(message.stopReason == .error, "a transport error without body text records error")
        let stored = try #require(try storedMessage(state, uid: uid, conversationID: conversationID, messageID: message.id))
        #expect(stored.stopReason == .error)
    }

    @Test func deepseek_eof_without_marker_incomplete() async throws {
        defer { StopReasonURLProtocol.reset() }
        // DeepSeek raw SSE: only the role frame, no body, no finish_reason, no [DONE], then the stream is cut.
        let (state, uid, conversationID) = try await sendOpenRouter(
            prefix: "deepseek-eof", kind: .deepseek, modelID: "deepseek-flash"
        ) { _ in
            .body(status: 200, text: "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"},\"finish_reason\":null}]}\n\n")
        }
        let message = try await waitSettled(state, conversationID)
        #expect(message.state == .failed, "a cut stream still ends as failed")
        #expect(message.stopReason == .incomplete, "cut without a terminal marker -> eof_without_marker -> incomplete")
        let stored = try #require(try storedMessage(state, uid: uid, conversationID: conversationID, messageID: message.id))
        #expect(stored.stopReason == .incomplete)
    }

    @Test func retry_does_not_reuse_last_finish() async throws {
        defer { StopReasonURLProtocol.reset() }
        // First: DeepSeek cuts after only the role frame -> delivers an eof-kind finish, records incomplete.
        let (state, uid, conversationID) = try await sendOpenRouter(
            prefix: "retry-stale", kind: .deepseek, modelID: "deepseek-flash"
        ) { _ in
            .body(status: 200, text: "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"},\"finish_reason\":null}]}\n\n")
        }
        let first = try await waitSettled(state, conversationID)
        #expect(first.stopReason == .incomplete)
        // Retry: the connection fails outright, upstream delivered no finish and no body text -> error; the previous eof finish must not be reused.
        StopReasonURLProtocol.reply = { request in
            guard request.url?.path.hasSuffix("/chat/completions") == true else { return nil }
            return .fail
        }
        await state.chatManager.retryMessage(messageID: first.id, in: conversationID)
        let retried = try await waitSettled(state, conversationID)
        #expect(retried.state == .failed)
        #expect(retried.stopReason == .error)
        let stored = try #require(try storedMessage(state, uid: uid, conversationID: conversationID, messageID: retried.id))
        #expect(stored.stopReason == .error)
    }

    // MARK: - MCP

    @Test func mcp_send_delivered_records_stop_reason() async throws {
        defer { StopReasonURLProtocol.reset() }
        let database = try McpTestDatabase.make()
        let mcpDirectory = McpServerDirectory(
            credentialStore: McpCredentialStore(storage: InMemoryMcpCredentialStorage()),
            openStore: { _ in database.store }
        )
        defer { database.cleanUp(after: mcpDirectory) }
        StopReasonURLProtocol.reset()
        StopReasonURLProtocol.reply = { request in
            guard request.url?.path.hasSuffix("/chat/completions") == true else { return nil }
            return .body(status: 200, text: stopReasonChatSSE([
                #"{"choices":[{"delta":{"content":"It is warm."}}]}"#,
                #"{"choices":[{"delta":{},"finish_reason":"length"}]}"#,
            ]))
        }
        let state = AppState(
            seedDemoData: true,
            providerSession: StopReasonURLProtocol.session(),
            toolCallMemory: try makeToolLoopMemoryStore(),
            mcpServerDirectory: mcpDirectory
        )
        let (relay, model) = makeToolLoopRelayProvider(transport: .openaiChatCompletions)
        let conversationID = UUID()
        try seedStopReasonMcpServer(database, conversationID: conversationID)
        state.providers = [relay]
        state.conversations = [TestFactories.makeConversation(id: conversationID, providerID: relay.id, modelID: model.id, messages: [])]

        _ = await state.chatManager.sendMessage("Weather?", in: conversationID, capabilitySelection: ChatCapabilitySelection())
        let message = try await waitSettled(state, conversationID)
        #expect(message.state == .delivered)
        #expect(message.text == "It is warm.")
        #expect(message.stopReason == .length, "the tool loop uses the last round's finish")
    }

    // MARK: - memoryItemIds (stored on this device only)

    /// Written to the database and read back: order is kept; an empty array is stored as NULL and read back as an empty array.
    @Test func memoryItemIdsRoundTrip() async throws {
        let (state, uid) = makeState(prefix: "memory-ids")
        var used = TestFactories.makeMessage(role: .assistant, text: "With memory", state: .delivered)
        used.memoryItemIds = ["mem-b", "mem-a"]
        let plain = TestFactories.makeMessage(role: .assistant, text: "Without memory", state: .delivered)
        let conversation = TestFactories.makeConversation(
            messages: [TestFactories.makeMessage(role: .user, text: "Hi"), used, plain]
        )
        state.upsertConversationProjection(conversation)
        let storedUsed = try #require(try storedMessage(state, uid: uid, conversationID: conversation.id, messageID: used.id))
        let storedPlain = try #require(try storedMessage(state, uid: uid, conversationID: conversation.id, messageID: plain.id))
        #expect(storedUsed.memoryItemIds == ["mem-b", "mem-a"])
        #expect(storedPlain.memoryItemIds.isEmpty)
        #expect(RecordMappers.encodeMemoryItemIds([]) == nil, "an empty array is stored as NULL")
        #expect(RecordMappers.encodeMemoryItemIds(["mem-b", "mem-a"]) == #"["mem-b","mem-a"]"#)
    }

    /// User stops midway: the item ids injected into this request still land on the stopped answer and are persisted.
    @Test func userStopRecordsMemoryItemIds() async throws {
        defer { StopReasonURLProtocol.reset() }
        let item = ContextPipelineTests.memoryItem(
            "mem-a", .fact, "The user prefers green tea.", createdAt: "2026-01-01T00:00:01Z"
        )
        let (state, uid, conversationID) = try await sendOpenRouter(
            prefix: "user-stop-memory",
            beforeSend: { state in try await ContextPipelineTests.seedMemory(state, [item]) }
        ) { _ in
            .hang(text: "data: {\"choices\":[{\"delta\":{\"content\":\"Partial answer\"}}]}\n\n")
        }
        try await waitUntil("stream delivered first chunk") { StopReasonURLProtocol.hangDelivered }
        try await Task.sleep(nanoseconds: 150_000_000)
        state.chatManager.cancelGeneration(in: conversationID)
        let message = try await waitSettled(state, conversationID)
        #expect(message.state == .interrupted)
        #expect(message.memoryItemIds == ["mem-a"])
        let stored = try #require(try storedMessage(state, uid: uid, conversationID: conversationID, messageID: message.id))
        #expect(stored.memoryItemIds == ["mem-a"], "the same set of ids was persisted")
    }

    /// memoryItemIds is not carried by the backup export, and is empty after import.
    @Test func memoryItemIdsNotInBackup() async throws {
        var used = TestFactories.makeMessage(role: .assistant, text: "With memory", state: .delivered)
        used.memoryItemIds = ["mem-a"]
        let conversation = TestFactories.makeConversation(
            messages: [TestFactories.makeMessage(role: .user, text: "Hi"), used]
        )
        let exported = try await BackupService.exportBackup(
            providers: [],
            conversations: [conversation],
            preferences: AppPreference(theme: .system, language: .english),
            lastUsedModelRef: nil,
            includeKeys: false,
            password: nil
        )
        let (parsed, _) = try BackupService.parseBackup(from: exported)
        let restored = try #require(parsed.data.conversations.first { $0.id == conversation.id })
        #expect(restored.messages.first { $0.id == used.id }?.memoryItemIds == [])
        let encoded = try #require(String(data: try JSONEncoder().encode(used), encoding: .utf8))
        #expect(!encoded.contains("memoryItemIds"))
    }

    // MARK: - Backup

    @Test func backup_roundtrip_keeps_stop_reason() async throws {
        var capped = TestFactories.makeMessage(role: .assistant, text: "Cut off", state: .delivered)
        capped.stopReason = .length
        let legacy = TestFactories.makeMessage(role: .assistant, text: "Old", state: .delivered)
        let conversation = TestFactories.makeConversation(
            messages: [TestFactories.makeMessage(role: .user, text: "Hi"), capped, legacy]
        )
        let exported = try await BackupService.exportBackup(
            providers: [],
            conversations: [conversation],
            preferences: AppPreference(theme: .system, language: .english),
            lastUsedModelRef: nil,
            includeKeys: false,
            password: nil
        )
        let (parsed, _) = try BackupService.parseBackup(from: exported)
        let restored = try #require(parsed.data.conversations.first { $0.id == conversation.id })
        #expect(restored.messages.first { $0.id == capped.id }?.stopReason == .length)
        #expect(restored.messages.first { $0.id == legacy.id }?.stopReason == nil, "legacy messages stay nil")
    }
}

/// Context ledger with a fixed calibration for the conversation's provider / model, injected through
/// `ChatManager.contextLedgerResolver`. The injected store is read-only, so a finished leg cannot recalibrate rho
/// and the stopped leg is estimated with exactly `rhoHi`.
final class FixedRhoLedger: @unchecked Sendable {
    static let calibration = RhoCalibration(n: 3, rho: 0.4, seeds: [0.4, 0.4, 0.4])
    /// 0.4 x 1.15 in IEEE double (0.45999999999999996).
    static let rhoHi = calibration.rhoHi

    private let directory: URL
    private let writer: DatabasePool
    private var reader: DatabasePool?

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oriveo-fixed-rho-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = false
        writer = try DatabasePool(path: directory.appendingPathComponent("ledger.sqlite").path, configuration: configuration)
        try writer.write { db in try ContextLedgerStore.createTables(in: db) }
    }

    /// Seeds the calibration for the state's first provider and its default model, then injects the read-only store.
    @MainActor
    func inject(into state: AppState) throws {
        let provider = try #require(state.providers.first)
        let model = try #require(provider.models.first { $0.isDefault } ?? provider.models.first)
        try inject(into: state, provider: provider, model: model)
    }

    @MainActor
    func inject(into state: AppState, provider: Provider, model: AIModel) throws {
        try ContextLedgerStore(dbPool: writer).saveRho(
            RhoCalibrationKey(transportInstanceId: provider.id.uuidString, modelId: model.id), Self.calibration
        )
        var configuration = Configuration()
        configuration.readonly = true
        configuration.foreignKeysEnabled = false
        let reader = try DatabasePool(path: directory.appendingPathComponent("ledger.sqlite").path, configuration: configuration)
        self.reader = reader
        let store = ContextLedgerStore(dbPool: reader)
        #expect(ContextLedgerStore.currentRhoHi(
            for: RhoCalibrationKey(transportInstanceId: provider.id.uuidString, modelId: model.id), in: store
        ) == Self.rhoHi)
        state.chatManager.contextLedgerResolver = { _ in store }
    }

    deinit {
        try? reader?.close()
        try? writer.close()
        try? FileManager.default.removeItem(at: directory)
    }
}
