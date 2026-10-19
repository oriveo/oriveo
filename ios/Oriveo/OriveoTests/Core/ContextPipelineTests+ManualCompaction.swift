import Foundation
import OriveoProviderKit
import Testing
@testable import Oriveo

/// Records the request bodies emitted by manual compaction; when summaryReply is non-nil the summary request is answered with this text as OpenAI SSE.
private final class ManualCompactionURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var capturedBodies: [[String: Any]] = []
    nonisolated(unsafe) static var summaryReply: String?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.bodyObject(of: request)
        if let body {
            Self.capturedBodies.append(body)
        }
        var payload = "data: [DONE]\n\n"
        if let reply = Self.summaryReply {
            let chunk: [String: Any] = [
                "id": "chatcmpl-manual-summary",
                "object": "chat.completion.chunk",
                "choices": [["index": 0, "delta": ["content": reply]]],
            ]
            let data = (try? JSONSerialization.data(withJSONObject: chunk)) ?? Data()
            payload = "data: " + String(decoding: data, as: UTF8.self) + "\n\n" + payload
        }
        let url = request.url ?? URL(string: "https://relay.invalid")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func bodyObjectForTesting(of request: URLRequest) -> [String: Any]? {
        bodyObject(of: request)
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

/// For concurrent compaction: each request suspends first, the test releases it by index with a chosen response, and request bodies are recorded in arrival order.
private final class ConcurrentCompactionURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var held: [ConcurrentCompactionURLProtocol] = []
    nonisolated(unsafe) private static var bodies: [[String: Any]] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        held = []
        bodies = []
    }

    static var heldCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return held.count
    }

    static var capturedBodies: [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return bodies
    }

    /// Releases the suspended request at `index` and answers it with `reply` as OpenAI SSE.
    static func release(_ index: Int, reply: String) {
        lock.lock()
        let target = index < held.count ? held[index] : nil
        lock.unlock()
        target?.respond(reply)
    }

    override func startLoading() {
        let body = ManualCompactionURLProtocol.bodyObjectForTesting(of: request) ?? [:]
        Self.lock.lock()
        Self.bodies.append(body)
        Self.held.append(self)
        Self.lock.unlock()
    }

    override func stopLoading() {}

    private func respond(_ reply: String) {
        let chunk: [String: Any] = [
            "id": "chatcmpl-concurrent-summary",
            "object": "chat.completion.chunk",
            "choices": [["index": 0, "delta": ["content": reply]]],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: chunk)) ?? Data()
        let payload = "data: " + String(decoding: data, as: UTF8.self) + "\n\n" + "data: [DONE]\n\n"
        let url = request.url ?? URL(string: "https://relay.invalid")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Manual compaction always uses the AI summary (ignoring the preference and the circuit breaker) and only falls back when the remote switch is off.
extension ContextPipelineTests {

    @Test func manual_compaction_request_body_from_production() async throws {
        let previous = AppPreferencesStore.savedContextAISummaryEnabled
        AppPreferencesStore.savedContextAISummaryEnabled = false
        ManualCompactionURLProtocol.summaryReply = ContextCheckpoint.headings
            .map { "## \($0)\n(none)" }
            .joined(separator: "\n")
        ManualCompactionURLProtocol.capturedBodies = []
        defer {
            AppPreferencesStore.savedContextAISummaryEnabled = previous
            ManualCompactionURLProtocol.summaryReply = nil
            ManualCompactionURLProtocol.capturedBodies = []
        }
        let fixture = makeManualFixture(messages: Self.manualHistory(bytes: 3_500))
        let chatManager = fixture.state.chatManager
        let conversationId = fixture.conversationID.uuidString
        let coordinator = try #require(
            chatManager.debugCompactionCoordinatorForTesting(uid: fixture.state.sessionPartitionUID)
        )
        coordinator.debugSetBreakerForTesting(
            ContextCompactionBreaker(
                failures: ContextCompactionBreaker.failuresToTrip,
                turnsLeft: ContextCompactionBreaker.fallbackTurns
            ),
            conversationId: conversationId
        )
        #expect(coordinator.breakerState(conversationId: conversationId).mode == .fallbackOnly)

        let result = await chatManager.compactConversationNow(conversationId: fixture.conversationID)

        #expect(result.outcome == .summary)
        let bodies = ManualCompactionURLProtocol.capturedBodies
        #expect(bodies.count == 1, "manual compaction sends only the summary request, no chat request")
        let body = try #require(bodies.first)
        #expect(body["tools"] == nil)
        let messages = body["messages"] as? [[String: Any]] ?? []
        let last = try #require(messages.last)
        #expect(last["role"] as? String == "user")
        #expect(Self.manualText(of: last).contains("CONTEXT CHECKPOINT"))
        // The last message in the conversation (Answer 9) is the current message and is not part of the summary span.
        #expect(!Self.manualText(of: last).contains("Answer 9:"))
        let rows = try fixture.store().list(conversationId: conversationId)
        #expect(rows.map(\.kind) == [.summary])
        #expect(result.row?.checkpointId == rows.first?.checkpointId)
    }

    @Test func manual_compaction_flag_off_uses_fallback() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "providers": {},
          "runtimeConfig": { "featureFlags": { "\(ContextCompactionCoordinator.remoteFlagKey)": false } }
        }
        """)
        ManualCompactionURLProtocol.summaryReply = ContextCheckpoint.headings
            .map { "## \($0)\n(none)" }
            .joined(separator: "\n")
        ManualCompactionURLProtocol.capturedBodies = []
        defer {
            ManualCompactionURLProtocol.summaryReply = nil
            ManualCompactionURLProtocol.capturedBodies = []
        }
        let fixture = makeManualFixture(messages: Self.manualHistory(bytes: 8_000))

        let result = await fixture.state.chatManager.compactConversationNow(conversationId: fixture.conversationID)
        await MetadataClient.shared.resetForTesting()

        #expect(result.outcome == .fallback)
        #expect(ManualCompactionURLProtocol.capturedBodies.isEmpty)
        let rows = try fixture.store().list(conversationId: fixture.conversationID.uuidString)
        #expect(rows.map(\.kind) == [.fallback])
    }

    @Test func manual_compaction_without_conversation_is_noop() async throws {
        ManualCompactionURLProtocol.capturedBodies = []
        defer { ManualCompactionURLProtocol.capturedBodies = [] }
        let fixture = makeManualFixture(messages: [])

        let missing = await fixture.state.chatManager.compactConversationNow(conversationId: UUID())
        #expect(missing.outcome == .noop)
        #expect(missing.row == nil)

        let empty = await fixture.state.chatManager.compactConversationNow(conversationId: fixture.conversationID)
        #expect(empty.outcome == .noop)
        #expect(empty.row == nil)
        #expect(ManualCompactionURLProtocol.capturedBodies.isEmpty)
        let rows = try fixture.store().list(conversationId: fixture.conversationID.uuidString)
        #expect(rows.isEmpty)
    }

    /// Single-flight: a second compaction in the same conversation waits for the first (including retries) to finish and then re-evaluates against latestValid;
    /// summaries are not sent concurrently, the first uses the system it started with, and the first's discarded-draft retry is not charged to the second.
    @Test func concurrent_compactions_keep_own_snapshot() async throws {
        ConcurrentCompactionURLProtocol.reset()
        defer { ConcurrentCompactionURLProtocol.reset() }
        let validReply = ContextCheckpoint.headings
            .map { "## \($0)\n(none)" }
            .joined(separator: "\n")
        let fixture = makeManualFixture(
            messages: Self.manualHistory(bytes: 3_500),
            useMemory: true,
            protocolClass: ConcurrentCompactionURLProtocol.self
        )
        let state = fixture.state
        let chatManager = state.chatManager
        let conversationID = fixture.conversationID
        try await Self.seedMemory(state, [
            Self.memoryItem("mem-marker", .fact, "Memory marker alpha", createdAt: "2026-01-01T00:00:00Z"),
        ])

        // While A's first summary request is suspended, start B after changing system: B queues and no second concurrent summary is sent.
        let first = Task { await chatManager.compactConversationNow(conversationId: conversationID) }
        try await Self.waitForHeld(1)
        try await Self.seedMemory(state, [
            Self.memoryItem("mem-marker", .fact, "Memory marker beta", createdAt: "2026-01-01T00:00:00Z"),
        ])
        let second = Task { await chatManager.compactConversationNow(conversationId: conversationID) }
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(ConcurrentCompactionURLProtocol.heldCount == 1)

        // A's first reply is a discarded draft -> A's second summary still carries its own system; after release, A persists its row.
        ConcurrentCompactionURLProtocol.release(0, reply: "not a checkpoint")
        try await Self.waitForHeld(2)
        ConcurrentCompactionURLProtocol.release(1, reply: validReply)
        let firstResult = await first.value

        // B re-evaluates against the row A persisted: there is no new span, so noop and no further summary.
        let secondResult = await second.value

        #expect(firstResult.outcome == .summary)
        #expect(firstResult.failures.isEmpty)
        #expect(secondResult.outcome == .noop)
        #expect(secondResult.row == nil)
        #expect(ConcurrentCompactionURLProtocol.heldCount == 2)
        let systems = ConcurrentCompactionURLProtocol.capturedBodies.map { body -> String in
            let messages = body["messages"] as? [[String: Any]] ?? []
            return messages.first { $0["role"] as? String == "system" }.map(Self.manualText(of:)) ?? ""
        }
        let markers = systems.map { system -> String in
            if system.contains("Memory marker alpha") { return "alpha" }
            if system.contains("Memory marker beta") { return "beta" }
            return "none"
        }
        #expect(markers == ["alpha", "alpha"])
        let coordinator = try #require(chatManager.debugCompactionCoordinatorForTesting(uid: state.sessionPartitionUID))
        #expect(coordinator.breakerState(conversationId: conversationID.uuidString).failures == 0)
    }

    // MARK: Fixtures

    private static func waitForHeld(_ count: Int) async throws {
        let deadline = Date().addingTimeInterval(5)
        while ConcurrentCompactionURLProtocol.heldCount < count {
            guard Date() < deadline else {
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private struct ManualFixture {
        let state: AppState
        let conversationID: UUID

        func store() throws -> ContextCompactionStore {
            try #require(ContextCompactionStore.forPartition(state.sessionPartitionUID))
        }
    }

    private static func manualHistory(bytes: Int) -> [ChatMessage] {
        var history: [ChatMessage] = []
        for turn in 0..<10 {
            history.append(TestFactories.makeMessage(
                role: .user, text: "Question \(turn): " + String(repeating: "q", count: bytes)
            ))
            history.append(TestFactories.makeMessage(
                role: .assistant, text: "Answer \(turn): " + String(repeating: "a", count: bytes)
            ))
        }
        return history
    }

    private static func manualText(of message: [String: Any]) -> String {
        if let string = message["content"] as? String { return string }
        let parts = message["content"] as? [[String: Any]] ?? []
        return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    /// W=40000, O=4000 -> B=36000.
    private func makeManualFixture(
        messages: [ChatMessage],
        useMemory: Bool = false,
        protocolClass: AnyClass = ManualCompactionURLProtocol.self
    ) -> ManualFixture {
        let providerID = UUID()
        let modelID = "relay-window"
        var model = TestFactories.makeModel(id: modelID, capabilities: [.text], isDefault: true)
        model.contextLength = 40_000
        model.maxOutputTokens = 4_000
        let provider = Provider(
            id: providerID,
            kind: .relay,
            status: .connected,
            models: [model],
            catalogModels: [],
            apiKey: "relay-key",
            apiKeyPreview: "...key",
            baseURLText: "https://relay.test/v1",
            relayRequested: RelayRequestedConfig(transport: .openaiChatCompletions)
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolClass]
        let state = AppState(
            seedDemoData: false,
            sessionUID: "context-pipeline-manual-\(UUID().uuidString)",
            providerSession: URLSession(configuration: configuration)
        )
        let stamped = messages.map { message -> ChatMessage in
            var message = message
            message.providerID = providerID
            message.providerKind = .relay
            message.modelID = modelID
            return message
        }
        var conversation = TestFactories.makeConversation(
            providerID: providerID,
            providerKind: .relay,
            modelID: modelID,
            messages: stamped
        )
        conversation.useMemory = useMemory
        state.providers = [provider]
        state.upsertConversationProjection(conversation)
        state.flushConversationPersistQueue()
        return ManualFixture(state: state, conversationID: conversation.id)
    }
}
