import Foundation
import OriveoProviderKit
import Testing
@testable import Oriveo

/// Replays responses by request path and records (path, request body) in order. Used by the review-blocker cases.
final class ReviewURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        let status: Int
        let body: String
        /// Non-nil: send the body without finishing, then send this part later and finish ("" = close silently). Simulates how the stream ends after the user stops it.
        var deferredTail: String? = nil
    }

    nonisolated(unsafe) static var handler: (@Sendable (URLRequest, Int) -> Reply?)?
    nonisolated(unsafe) static var captured: [(path: String, body: [String: Any])] = []
    private static let lock = NSLock()

    static func reset(_ handler: (@Sendable (URLRequest, Int) -> Reply?)?) {
        lock.withLock {
            Self.handler = handler
            captured = []
        }
    }

    static func bodies(pathSuffix: String) -> [[String: Any]] {
        lock.withLock { captured.filter { $0.path.hasSuffix(pathSuffix) }.map(\.body) }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReviewURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let reply: Reply? = Self.lock.withLock {
            let body = Self.bodyObject(of: request) ?? [:]
            let index = Self.captured.filter { $0.path == path }.count
            Self.captured.append((path, body))
            return Self.handler?(request, index)
        }
        let resolved = reply ?? Reply(status: 404, body: "{}")
        let url = request.url ?? URL(string: "https://invalid.test")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: resolved.status,
            httpVersion: nil,
            headerFields: ["Content-Type": resolved.status == 200 && resolved.body.hasPrefix("{") == false
                ? "text/event-stream" : "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(resolved.body.utf8))
        guard let tail = resolved.deferredTail else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, !self.stopLock.withLock({ self.stopped }) else { return }
            if !tail.isEmpty {
                self.client?.urlProtocol(self, didLoad: Data(tail.utf8))
            }
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    private let stopLock = NSLock()
    private var stopped = false

    override func stopLoading() {
        stopLock.withLock { stopped = true }
    }

    private static func bodyObject(of request: URLRequest) -> [String: Any]? {
        let data: Data
        if let body = request.httpBody {
            data = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = Data()
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
            defer { pointer.deallocate() }
            while stream.hasBytesAvailable {
                let count = stream.read(pointer, maxLength: 4_096)
                if count <= 0 { break }
                buffer.append(pointer, count: count)
            }
            data = buffer
        } else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// Review blockers: rho samples are only recorded on a single-leg chat, not on an overflow finish;
/// the user output cap is bounded by oWire, relay image generation uses the user's original prompt, and a rejected send clears the edit-resend marker.
extension ContextPipelineTests {

    // MARK: ρ

    @Test func rho_skipped_for_tool_or_library_legs() async throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let store = database.store
        let state = AppState(
            seedDemoData: true,
            providerSession: ReviewURLProtocol.session(),
            toolCallMemory: try makeToolLoopMemoryStore(),
            mcpServerDirectory: McpServerDirectory(
                credentialStore: McpCredentialStore(storage: InMemoryMcpCredentialStorage()),
                openStore: { _ in store }
            )
        )
        var (relay, model) = makeToolLoopRelayProvider(transport: .openaiChatCompletions)
        model.contextLength = 40_000
        model.maxOutputTokens = 4_000
        relay.models = [model]
        let serverID = UUID()
        let conversationID = UUID()
        let schema = JSONValue.object(JSONObject([
            ("type", .string("object")),
            ("properties", .object(JSONObject([("city", .object(JSONObject([("type", .string("string"))])))]))),
        ]))
        try store.addServer(
            McpServerAddition(
                id: serverID, name: "Weather", url: "https://mcp.example.com/mcp", authKind: .auto,
                localOnly: false, iconURL: nil, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                snapshots: [McpToolSnapshot(
                    serverId: serverID, toolName: "get_weather", title: "Get weather",
                    description: "Weather lookup", inputSchema: schema,
                    annotations: .object(JSONObject([("readOnlyHint", .bool(true))])),
                    contentHash: sha256Hex("context-review:get_weather"), readOnly: true,
                    pendingReview: false, oversized: false
                )],
                permissions: [:],
                connectionState: McpConnectionState(serverId: serverID, status: .connected, generation: .stateless)
            ),
            maxServers: 20
        )
        try store.setServerEnabled(true, conversationId: conversationID, serverId: serverID)
        state.providers = [relay]
        state.conversations = [TestFactories.makeConversation(
            id: conversationID, providerID: relay.id, modelID: model.id, messages: []
        )]
        let rhoKey = RhoCalibrationKey(transportInstanceId: relay.id.uuidString, modelId: model.id)
        let sidecar = try SidecarContextLedger()
        sidecar.inject(into: state)
        let ledger = sidecar.store

        // A tool-loop leg that finishes successfully with usage: no rho sample is recorded.
        ReviewURLProtocol.reset { request, _ in
            guard request.url?.path.hasSuffix("/chat/completions") == true else { return nil }
            return .init(status: 200, body: Self.sse([Self.contentFrame("It is warm."), Self.stopFrame(promptTokens: 40)]))
        }
        defer { ReviewURLProtocol.reset(nil) }
        _ = await state.chatManager.sendMessage("Weather?", in: conversationID, capabilitySelection: ChatCapabilitySelection())
        let delivered = try await settledAssistant(state, conversationID)
        #expect(delivered.state == .delivered)
        #expect(!ReviewURLProtocol.bodies(pathSuffix: "/chat/completions").isEmpty)
        #expect(try ledger.loadRhoTable().calibration(for: rhoKey).n == 0)

        // A tool-loop leg that overflows: "predicted no overflow but overflowed" is not recorded.
        let seeded = RhoCalibration(n: 3, rho: 0.4, seeds: [0.4, 0.4, 0.4])
        try ledger.saveRho(rhoKey, seeded)
        ReviewURLProtocol.reset { request, _ in
            guard request.url?.path.hasSuffix("/chat/completions") == true else { return nil }
            return .init(status: 400, body: Self.overflowBody)
        }
        _ = await state.chatManager.sendMessage("Weather again?", in: conversationID, capabilitySelection: ChatCapabilitySelection())
        _ = try await settledAssistant(state, conversationID)
        #expect(try ledger.loadRhoTable().calibration(for: rhoKey) == seeded)
    }

    @Test func rho_skipped_on_context_window_exceeded() async throws {
        let fixture = makeOverflowFixture(
            relayTransport: .anthropicMessages,
            messages: [
                TestFactories.makeMessage(role: .user, text: "First question"),
                TestFactories.makeMessage(role: .assistant, text: "First answer"),
            ]
        )
        let bodies = try await sendAndSettle(fixture, text: "Next", replies: [
            .init(status: 200, body: Self.anthropicSSE(
                text: "Partial", stopReason: "model_context_window_exceeded", inputTokens: 40
            )),
        ])
        let assistant = try await settledAssistant(fixture.state, fixture.conversationID)

        #expect(bodies.count == 1)
        #expect(assistant.stopReason == .contextWindowExceeded)
        let manifests = try ledger(fixture).manifests(conversationId: fixture.conversationID.uuidString)
        #expect(manifests.last?.stopReason == .contextWindowExceeded)
        #expect(manifests.last?.observedInput == 40)
        #expect(try ledger(fixture).loadRhoTable().calibration(for: fixture.rhoKey).n == 0)
    }

    /// The text of the first non-system message in the request body (content is a string or text parts).
    static func firstConversationText(_ body: [String: Any]?) -> String? {
        let raw = body?["messages"] as? [[String: Any]] ?? []
        guard let message = raw.first(where: { $0["role"] as? String != "system" }) else { return nil }
        if let string = message["content"] as? String { return string }
        let parts = message["content"] as? [[String: Any]] ?? []
        return parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n")
    }

    // MARK: Output cap

    @Test func user_max_output_capped_by_o_wire() async throws {
        // User sets 12000, model 8192, W=16000: O=12000, oWire = min(O, W/2) = 8000, and the sent value is min(user value, oWire).
        let fixture = makeOverflowFixture(
            contextLength: 16_000, maxOutputTokens: 8_192, relayTransport: .anthropicMessages, messages: []
        )
        let providerID = try #require(fixture.state.providers.first?.id)
        GenerationParameterSettingsStore.shared.setConnectionDefaults(
            GenerationParameterOverrides(values: ["max_output_tokens": .init(state: .value, value: .number(12_000))]),
            providerID: providerID
        )
        defer { GenerationParameterSettingsStore.shared.setConnectionDefaults(nil, providerID: providerID) }
        let bodies = try await sendAndSettle(fixture, text: "Hello", replies: [
            .init(status: 200, body: Self.anthropicSSE(text: "Hi", stopReason: "end_turn", inputTokens: 10)),
        ])

        let body = try #require(bodies.first)
        #expect((body["max_tokens"] as? NSNumber)?.intValue == 8_000)
        #expect(fixture.state.chatManager.debugLastContextBudgetForTesting?.oWire == 8_000)
    }

    // MARK: Relay image generation

    /// iOS relay image generation (chat_completions protocol) goes through /images/generations, not chat completions;
    /// assert that it sends no chat request and that the image prompt is the user's original text without [D] (attachment note) or checkpoint.
    @Test func relay_image_prompt_has_no_dynamic_block() async throws {
        let history = [
            TestFactories.makeMessage(
                role: .user, text: "Here is a file",
                attachments: [TestFactories.makeFileAttachment(fileName: "notes.txt", mimeType: "text/plain", base64Data: "aGVsbG8=")]
            ),
            TestFactories.makeMessage(role: .assistant, text: "Got it"),
        ]
        let fixture = makeOverflowFixture(messages: history)
        var providers = fixture.state.providers
        providers[0].models[0].capabilities = [.text, .imageGen]
        fixture.state.providers = providers
        let bodies = try await sendAndSettle(fixture, text: "Draw a cat", replies: [
            .init(status: 200, body: #"{"created":1,"data":[{"b64_json":"iVBORw0KGgo="}]}"#),
        ])

        // Only one request was sent, and it is the image endpoint body (it has a prompt and no chat messages).
        #expect(bodies.count == 1)
        let body = try #require(bodies.first)
        #expect(body["messages"] == nil)
        #expect(body["prompt"] as? String == "Draw a cat")
    }

    // MARK: Edit and resend

    @Test func edit_resend_reject_clears_pending() async throws {
        let editedID = UUID()
        let fixture = makeOverflowFixture(
            contextLength: 2_000,
            maxOutputTokens: 200,
            messages: [
                TestFactories.makeMessage(id: editedID, role: .user, text: "Short question"),
                TestFactories.makeMessage(role: .assistant, text: "Short answer"),
            ]
        )
        OverflowURLProtocol.reset([])
        defer { OverflowURLProtocol.reset([]) }
        let draft = fixture.state.beginEditingUserMessage(messageID: editedID, in: fixture.conversationID)
        #expect(draft != nil)
        #expect(fixture.state.chatManager.debugHasPendingEditResendForTesting(fixture.conversationID))

        let longText = String(repeating: "A very long paragraph. ", count: 1_000)
        let sent = await fixture.state.sendMessage(longText, in: fixture.conversationID)

        #expect(sent == nil)
        #expect(OverflowURLProtocol.bodies.isEmpty)
        #expect(!fixture.state.chatManager.debugHasPendingEditResendForTesting(fixture.conversationID))
    }

    // MARK: Fixtures

    static func anthropicSSE(text: String, stopReason: String, inputTokens: Int) -> String {
        [
            #"event: message_start"# + "\n" + #"data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"relay-overflow","content":[],"usage":{"input_tokens":\#(inputTokens),"output_tokens":1}}}"#,
            #"event: content_block_start"# + "\n" + #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"event: content_block_delta"# + "\n" + #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(text)"}}"#,
            #"event: content_block_stop"# + "\n" + #"data: {"type":"content_block_stop","index":0}"#,
            #"event: message_delta"# + "\n" + #"data: {"type":"message_delta","delta":{"stop_reason":"\#(stopReason)"},"usage":{"output_tokens":3}}"#,
            #"event: message_stop"# + "\n" + #"data: {"type":"message_stop"}"#,
        ].map { $0 + "\n\n" }.joined()
    }

    static func serialized(_ body: [String: Any]?) -> String {
        guard let body, let data = try? JSONSerialization.data(withJSONObject: body) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Waits for the last assistant message to leave generating, then leaves some time for the final write-back.
    func settledAssistant(_ state: AppState, _ conversationID: UUID) async throws -> ChatMessage {
        try? await Task.sleep(nanoseconds: 100_000_000)
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            let last = state.conversation(for: conversationID)?.messages.last
            if last?.role == .assistant, last?.state != .generating,
               !state.chatManager.isBusyStreaming(in: conversationID) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        return try #require(state.conversation(for: conversationID)?.messages.last { $0.role == .assistant })
    }
}
