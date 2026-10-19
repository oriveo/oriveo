import Foundation
import GRDB
import OriveoProviderKit
import Testing
@testable import Oriveo

/// A test-only standalone Ledger database (sidecar.sqlite in a temporary directory) injected into `ChatManager.contextLedgerResolver`.
/// It bypasses `DatabaseManager.shared`, so manifest writes are not silently dropped when other suites close it or switch uid in parallel.
final class SidecarContextLedger: @unchecked Sendable {
    let store: ContextLedgerStore
    private let pool: DatabasePool
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oriveo-context-ledger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The standalone database has no conversation table, so the manifest foreign key does not apply; foreign key checks are turned off.
        var configuration = Configuration()
        configuration.foreignKeysEnabled = false
        pool = try DatabasePool(path: directory.appendingPathComponent("sidecar.sqlite").path, configuration: configuration)
        try pool.write { db in try ContextLedgerStore.createTables(in: db) }
        store = ContextLedgerStore(dbPool: pool)
    }

    /// Makes this AppState's ChatManager write only to this standalone database.
    @MainActor
    func inject(into state: AppState) {
        state.chatManager.contextLedgerResolver = { _ in self.store }
    }

    deinit {
        try? pool.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Replays (status code, response body) in request order and records each request body the production send chain emits.
final class OverflowURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        let status: Int
        let body: String
        /// Does not finish after sending the headers and body, simulating a request still streaming (user-cancel cases).
        var hang = false
    }

    nonisolated(unsafe) static var replies: [Reply] = []
    nonisolated(unsafe) static var capturedBodies: [[String: Any]] = []
    private static let lock = NSLock()

    static func reset(_ replies: [Reply]) {
        lock.withLock {
            Self.replies = replies
            capturedBodies = []
        }
    }

    static var bodies: [[String: Any]] { lock.withLock { capturedBodies } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let reply: Reply = Self.lock.withLock {
            if let body = Self.bodyObject(of: request) {
                Self.capturedBodies.append(body)
            }
            return Self.replies.isEmpty ? Reply(status: 200, body: "data: [DONE]\n\n") : Self.replies.removeFirst()
        }
        let url = request.url ?? URL(string: "https://relay.invalid")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: reply.status,
            httpVersion: nil,
            headerFields: ["Content-Type": reply.status == 200 ? "text/event-stream" : "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        if !reply.hang {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

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

/// Overflow recovery, rho write-back, and manifest. Recovery cases assert on the second request body of the production path.
extension ContextPipelineTests {

    static let overflowBody =
        #"{"error":{"code":"context_length_exceeded","message":"This model's maximum context length is 40000 tokens."}}"#

    static func sse(_ frames: [String]) -> String {
        frames.map { "data: \($0)\n\n" }.joined() + "data: [DONE]\n\n"
    }

    static func contentFrame(_ text: String) -> String {
        #"{"choices":[{"index":0,"delta":{"content":"\#(text)"},"finish_reason":null}]}"#
    }

    static func stopFrame(promptTokens: Int?) -> String {
        guard let promptTokens else {
            return #"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#
        }
        return #"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":\#(promptTokens),"completion_tokens":3,"total_tokens":\#(promptTokens + 3)}}"#
    }

    /// A history of 20 messages of about 2400 bytes each: below 0.90*B (no pre-send fallback) but longer than the tail budget (the overflow fallback can fold it).
    static func mediumHistory() -> [ChatMessage] {
        var history: [ChatMessage] = []
        for turn in 0..<10 {
            history.append(TestFactories.makeMessage(
                role: .user, text: "Question \(turn): " + String(repeating: "q", count: 2_400)
            ))
            history.append(TestFactories.makeMessage(
                role: .assistant, text: "Answer \(turn): " + String(repeating: "a", count: 2_400)
            ))
        }
        return history
    }

    // MARK: Cases

    @Test func overflow_recovers_once_with_checkpoint() async throws {
        let history = Self.mediumHistory()
        let fixture = makeOverflowFixture(messages: history)
        let bodies = try await sendAndSettle(fixture, text: "Next", replies: [
            .init(status: 400, body: Self.overflowBody),
            .init(status: 200, body: Self.sse([Self.contentFrame("Recovered"), Self.stopFrame(promptTokens: nil)])),
        ])

        #expect(bodies.count == 2)
        let first = Self.overflowWireMessages(try #require(bodies.first))
        let second = Self.overflowWireMessages(try #require(bodies.dropFirst().first))
        // Second request body: the deterministic checkpoint comes first and the history is folded.
        let head = try #require(second.first)
        #expect(head.role == "user")
        #expect(head.text.hasPrefix("<oriveo-context-checkpoint v=\"1\""))
        #expect(second.count < first.count)
        #expect(second.last?.text == "Next")

        // The same assistant message finishes; the user message is not persisted again.
        let stored = fixture.state.conversation(for: fixture.conversationID)?.messages ?? []
        #expect(stored.count == history.count + 2)
        #expect(stored.filter { $0.role == .user && $0.text == "Next" }.count == 1)
        let assistant = try #require(stored.last)
        #expect(assistant.role == .assistant)
        #expect(assistant.state == .delivered)
        #expect(assistant.text == "Recovered")
        #expect(!stored.contains { $0.text.contains("oriveo-context-checkpoint") })
        // In the default mode the fallback goes through the coordinator and one fallback row is persisted.
        let rows = try #require(ContextCompactionStore.forPartition(fixture.state.sessionPartitionUID))
            .list(conversationId: fixture.conversationID.uuidString)
        #expect(rows.map(\.kind) == [.fallback])
    }

    /// With AI summary on, an overflow first sends a one-shot summary request, persists a summary row, and then resends once using that row.
    @Test func overflow_ai_summary_compacts_then_retries_once() async throws {
        let previous = AppPreferencesStore.savedContextAISummaryEnabled
        AppPreferencesStore.savedContextAISummaryEnabled = true
        defer { AppPreferencesStore.savedContextAISummaryEnabled = previous }
        let summary = ContextCheckpoint.headings.map { "## \($0)\\n(none)" }.joined(separator: "\\n")
        let fixture = makeOverflowFixture(messages: Self.mediumHistory())
        let bodies = try await sendAndSettle(fixture, text: "Next", replies: [
            .init(status: 400, body: Self.overflowBody),
            .init(status: 200, body: Self.sse([Self.contentFrame(summary), Self.stopFrame(promptTokens: nil)])),
            .init(status: 200, body: Self.sse([Self.contentFrame("Recovered"), Self.stopFrame(promptTokens: nil)])),
        ])

        #expect(bodies.count == 3)
        let summaryRequest = Self.overflowWireMessages(try #require(bodies.dropFirst().first))
        #expect(summaryRequest.last?.role == "user")
        #expect(summaryRequest.last?.text.contains("CONTEXT CHECKPOINT") == true)
        let retried = Self.overflowWireMessages(try #require(bodies.dropFirst(2).first))
        let firstUser = try #require(retried.first { $0.role == "user" })
        #expect(firstUser.text.contains("<summary>"))
        #expect(retried.last?.text == "Next")
        let rows = try #require(ContextCompactionStore.forPartition(fixture.state.sessionPartitionUID))
            .list(conversationId: fixture.conversationID.uuidString)
        #expect(rows.map(\.kind) == [.summary])
        let assistant = try #require(fixture.state.conversation(for: fixture.conversationID)?.messages.last)
        #expect(assistant.state == .delivered)
        #expect(assistant.text == "Recovered")
    }

    @Test func overflow_twice_records_context_window_exceeded() async throws {
        let fixture = makeOverflowFixture(messages: Self.mediumHistory())
        let bodies = try await sendAndSettle(fixture, text: "Next", replies: [
            .init(status: 400, body: Self.overflowBody),
            .init(status: 400, body: Self.overflowBody),
            .init(status: 200, body: Self.sse([Self.contentFrame("Never"), Self.stopFrame(promptTokens: nil)])),
        ])

        // Resends automatically only once.
        #expect(bodies.count == 2)
        let second = Self.overflowWireMessages(try #require(bodies.dropFirst().first))
        #expect(second.first?.text.hasPrefix("<oriveo-context-checkpoint v=\"1\"") == true)
        let assistant = try #require(fixture.state.conversation(for: fixture.conversationID)?.messages.last)
        #expect(assistant.state == .failed)
        #expect(assistant.stopReason == .contextWindowExceeded)
    }

    @Test func overflow_after_content_no_retry() async throws {
        let fixture = makeOverflowFixture(messages: Self.mediumHistory())
        let bodies = try await sendAndSettle(fixture, text: "Next", replies: [
            .init(status: 200, body: Self.sse([Self.contentFrame("Partial answer"), Self.overflowBody])),
            .init(status: 200, body: Self.sse([Self.contentFrame("Never"), Self.stopFrame(promptTokens: nil)])),
        ])

        #expect(bodies.count == 1)
        let assistant = try #require(fixture.state.conversation(for: fixture.conversationID)?.messages.last)
        #expect(assistant.state == .failed)
        #expect(assistant.stopReason == .contextWindowExceeded)
        #expect(assistant.text.contains("Partial answer"))
    }

    /// The deterministic fallback carries the old summary of the winning checkpoint. Continuation does not go through the coordinator; after an overflow it resends via the in-memory fallback.
    @Test func overflow_fallback_keeps_latest_checkpoint_summary() async throws {
        let targetID = UUID()
        let history = Self.mediumHistory() + [
            TestFactories.makeMessage(role: .user, text: "Next"),
            TestFactories.makeMessage(id: targetID, role: .assistant, text: "Partial answer", state: .interrupted),
        ]
        let fixture = makeOverflowFixture(messages: history)
        let summary = ContextCheckpoint.headings.enumerated()
            .map { $0.offset == 0 ? "## \($0.element)\nShip the zebra migration." : "## \($0.element)\n(none)" }
            .joined(separator: "\n")
        try saveSummaryCheckpoint(fixture, history: history, summary: summary)
        OverflowURLProtocol.reset([
            .init(status: 400, body: Self.overflowBody),
            .init(status: 200, body: Self.sse([Self.contentFrame(" more"), Self.stopFrame(promptTokens: nil)])),
        ])
        defer { OverflowURLProtocol.reset([]) }
        await fixture.state.chatManager.continueMessage(messageID: targetID, in: fixture.conversationID)
        try await settle(fixture)

        let bodies = OverflowURLProtocol.bodies
        #expect(bodies.count == 2)
        let retried = Self.overflowWireMessages(try #require(bodies.dropFirst().first))
        let head = try #require(retried.first { $0.role == "user" })
        #expect(head.text.hasPrefix("<oriveo-context-checkpoint v=\"1\""))
        #expect(head.text.contains("<summary>## Goal\nShip the zebra migration."))
    }

    /// When a chat send applies a database row, the manifest records the checkpointId applied this time (used to decide cleared_since after compaction is cleared).
    @Test func stored_checkpoint_send_writes_manifest_checkpoint_id() async throws {
        let history = Self.mediumHistory()
        let fixture = makeOverflowFixture(messages: history)
        let conversationId = fixture.conversationID.uuidString
        let summary = ContextCheckpoint.headings.map { "## \($0)\n(none)" }.joined(separator: "\n")
        let checkpointId = try saveSummaryCheckpoint(fixture, history: history, summary: summary)
        let bodies = try await sendAndSettle(fixture, text: "Next", replies: [
            .init(status: 200, body: Self.sse([Self.contentFrame("Answer"), Self.stopFrame(promptTokens: 9_000)])),
        ])

        #expect(bodies.count == 1)
        let sent = Self.overflowWireMessages(try #require(bodies.first))
        #expect(sent.first { $0.role == "user" }?.text.hasPrefix("<oriveo-context-checkpoint v=\"1\"") == true)
        let manifests = try ledger(fixture).manifests(conversationId: conversationId)
        #expect(manifests.count == 1)
        #expect(manifests.last?.checkpointId == checkpointId)
    }

    /// Anthropic in-stream model_context_window_exceeded with no body emitted -> the same recovery as an HTTP overflow, resending only once.
    @Test func anthropic_in_stream_overflow_recovers_once() async throws {
        let fixture = makeOverflowFixture(relayTransport: .anthropicMessages, messages: Self.mediumHistory())
        let bodies = try await sendAndSettle(fixture, text: "Next", replies: [
            .init(status: 200, body: Self.anthropicSSE(text: nil, stopReason: "model_context_window_exceeded")),
            .init(status: 200, body: Self.anthropicSSE(text: nil, stopReason: "model_context_window_exceeded")),
            .init(status: 200, body: Self.anthropicSSE(text: "Never", stopReason: "end_turn")),
        ])

        #expect(bodies.count == 2)
        let first = Self.overflowWireMessages(try #require(bodies.first))
        let second = Self.overflowWireMessages(try #require(bodies.dropFirst().first))
        #expect(second.first?.text.hasPrefix("<oriveo-context-checkpoint v=\"1\"") == true)
        #expect(second.count < first.count)
        let assistant = try #require(fixture.state.conversation(for: fixture.conversationID)?.messages.last)
        #expect(assistant.role == .assistant)
        #expect(assistant.state == .failed)
        #expect(assistant.stopReason == .contextWindowExceeded)
    }

    @Test func anthropic_in_stream_overflow_recovered_reply_delivered() async throws {
        let fixture = makeOverflowFixture(relayTransport: .anthropicMessages, messages: Self.mediumHistory())
        let bodies = try await sendAndSettle(fixture, text: "Next", replies: [
            .init(status: 200, body: Self.anthropicSSE(text: nil, stopReason: "model_context_window_exceeded")),
            .init(status: 200, body: Self.anthropicSSE(text: "Recovered", stopReason: "end_turn")),
        ])

        #expect(bodies.count == 2)
        let assistant = try #require(fixture.state.conversation(for: fixture.conversationID)?.messages.last)
        #expect(assistant.state == .delivered)
        #expect(assistant.text == "Recovered")
    }

    /// Body already emitted: finish as usual without resending, with stopReason recorded as context_window_exceeded.
    @Test func anthropic_in_stream_overflow_after_content_no_retry() async throws {
        let fixture = makeOverflowFixture(relayTransport: .anthropicMessages, messages: Self.mediumHistory())
        let bodies = try await sendAndSettle(fixture, text: "Next", replies: [
            .init(status: 200, body: Self.anthropicSSE(text: "Partial answer", stopReason: "model_context_window_exceeded")),
            .init(status: 200, body: Self.anthropicSSE(text: "Never", stopReason: "end_turn")),
        ])

        #expect(bodies.count == 1)
        let assistant = try #require(fixture.state.conversation(for: fixture.conversationID)?.messages.last)
        #expect(assistant.stopReason == .contextWindowExceeded)
        #expect(assistant.text.contains("Partial answer"))
    }

    @Test func rate_limit_429_not_recovered() async throws {
        let fixture = makeOverflowFixture(messages: Self.mediumHistory())
        let bodies = try await sendAndSettle(fixture, text: "Next", replies: [
            .init(status: 429, body: Self.overflowBody),
            .init(status: 200, body: Self.sse([Self.contentFrame("Never"), Self.stopFrame(promptTokens: nil)])),
        ])

        #expect(bodies.count == 1)
        let assistant = try #require(fixture.state.conversation(for: fixture.conversationID)?.messages.last)
        #expect(assistant.state == .failed)
        #expect(assistant.stopReason == .error)
    }

    @Test func usage_writes_rho_sample() async throws {
        let fixture = makeOverflowFixture(messages: [
            TestFactories.makeMessage(role: .user, text: "First question"),
            TestFactories.makeMessage(role: .assistant, text: "First answer"),
        ])
        let bodies = try await sendAndSettle(fixture, text: "Next", replies: [
            .init(status: 200, body: Self.sse([Self.contentFrame("Done"), Self.stopFrame(promptTokens: 40)])),
        ])

        let body = try #require(bodies.first)
        let textBytes = Self.overflowWireMessages(body).reduce(0) { $0 + $1.text.utf8.count }
        let calibration = try ledger(fixture).loadRhoTable().calibration(for: fixture.rhoKey)
        #expect(calibration.n == 1)
        #expect(calibration.seeds.count == 1)
        let sample = try #require(calibration.seeds.first)
        #expect(abs(sample - Double(40) / Double(textBytes)) < 1e-9)
    }

    @Test func overflow_miss_raises_rho() async throws {
        let fixture = makeOverflowFixture(messages: [
            TestFactories.makeMessage(role: .user, text: "First question"),
            TestFactories.makeMessage(role: .assistant, text: "First answer"),
        ])
        let seeded = RhoCalibration(n: 3, rho: 0.4, seeds: [0.4, 0.4, 0.4])
        try ledger(fixture).saveRho(fixture.rhoKey, seeded)
        _ = try await sendAndSettle(fixture, text: "Next", replies: [
            .init(status: 400, body: Self.overflowBody),
            // No usage: only the write-back of a missed overflow prediction is checked; no success sample is added.
            .init(status: 200, body: Self.sse([Self.contentFrame("Done"), Self.stopFrame(promptTokens: nil)])),
        ])

        let calibration = try ledger(fixture).loadRhoTable().calibration(for: fixture.rhoKey)
        #expect(calibration == seeded.recordingOverflowMiss())
        #expect(abs(calibration.rho - 0.5) < 1e-9)
    }

    @Test func manifest_appended_per_request() async throws {
        let fixture = makeOverflowFixture(messages: Self.mediumHistory())
        _ = try await sendAndSettle(fixture, text: "Next", replies: [
            .init(status: 400, body: Self.overflowBody),
            .init(status: 200, body: Self.sse([Self.contentFrame("Recovered"), Self.stopFrame(promptTokens: 9_000)])),
        ])

        let manifests = try ledger(fixture).manifests(conversationId: fixture.conversationID.uuidString)
        #expect(manifests.count == 2)
        let failed = try #require(manifests.first)
        let recovered = try #require(manifests.last)
        #expect(failed.requestId != recovered.requestId)
        #expect(failed.purpose == .chat)
        #expect(failed.model == Self.overflowModelID)
        #expect(failed.W == 40_000)
        #expect(failed.B == 36_000)
        #expect(failed.estimatedInput > 0)
        #expect(failed.stopReason == .contextWindowExceeded)
        #expect(failed.observedInput == nil)
        // The second request is the post-fallback one: counted from the checkpoint tail, the estimate is smaller, and usage writes back observedInput.
        #expect(recovered.tailFrom != nil)
        #expect(recovered.estimatedInput < failed.estimatedInput)
        #expect(recovered.observedInput == 9_000)
        #expect(recovered.stopReason != nil)
        #expect(recovered.stopReason != .contextWindowExceeded)
    }

    /// rho reads and writes share one source: the rho table injected through the resolver is read, rather than bypassing the resolver to read the global partition database.
    @Test func rho_reads_through_resolver() async throws {
        let fixture = makeOverflowFixture(messages: [
            TestFactories.makeMessage(role: .user, text: "First question"),
            TestFactories.makeMessage(role: .assistant, text: "First answer"),
        ])
        let seeded = RhoCalibration(n: 3, rho: 0.9, seeds: [0.9, 0.9, 0.9])
        #expect(seeded.rhoHi != RhoCalibration().rhoHi)
        try ledger(fixture).saveRho(fixture.rhoKey, seeded)

        let conversation = try #require(fixture.state.conversation(for: fixture.conversationID))
        #expect(fixture.state.chatManager.contextRhoHi(for: conversation) == seeded.rhoHi)

        // When the resolver cannot get a database, fall back to the default calibration.
        fixture.state.chatManager.contextLedgerResolver = { _ in nil }
        #expect(fixture.state.chatManager.contextRhoHi(for: conversation) == RhoCalibration().rhoHi)
    }

    @Test func http_error_carries_status_and_raw_body() throws {
        let service = BaseAPIService(session: URLSession(configuration: .ephemeral))
        let body = #"{"error":{"type":"rate_limit_error","message":"Slow down"}}"#

        // After mapping to dedicated errors (429 -> rateLimited, 401 -> invalidAPIKey) the status code and raw text are still there.
        let rateDiagnostics = ChatFailureDiagnostics()
        let rateError = ChatFailureDiagnostics.$current.withValue(rateDiagnostics) {
            service.mapHTTPError(statusCode: 429, data: Data(body.utf8))
        }
        guard case .rateLimited = rateError else {
            Issue.record("expected rateLimited, got \(rateError)")
            return
        }
        #expect(rateDiagnostics.snapshot.httpStatus == 429)
        #expect(rateDiagnostics.snapshot.rawBody == body)

        let authDiagnostics = ChatFailureDiagnostics()
        let authError = ChatFailureDiagnostics.$current.withValue(authDiagnostics) {
            service.mapHTTPError(statusCode: 401, data: Data(Self.overflowBody.utf8))
        }
        guard case .invalidAPIKey = authError else {
            Issue.record("expected invalidAPIKey, got \(authError)")
            return
        }
        #expect(authDiagnostics.snapshot.httpStatus == 401)
        #expect(authDiagnostics.snapshot.rawBody == Self.overflowBody)

        // The Gemini-overridden 400 plus API-key early-exit branch carries them as well.
        let geminiBody = #"{"error":{"code":400,"message":"API key not valid."}}"#
        let geminiDiagnostics = ChatFailureDiagnostics()
        _ = ChatFailureDiagnostics.$current.withValue(geminiDiagnostics) {
            GeminiService(session: URLSession(configuration: .ephemeral))
                .mapHTTPError(statusCode: 400, data: Data(geminiBody.utf8))
        }
        #expect(geminiDiagnostics.snapshot.httpStatus == 400)
        #expect(geminiDiagnostics.snapshot.rawBody == geminiBody)

        // Only the first 32 KB of the raw text (UTF-8) is kept.
        let huge = String(repeating: "x", count: 40_000)
        let hugeDiagnostics = ChatFailureDiagnostics()
        _ = ChatFailureDiagnostics.$current.withValue(hugeDiagnostics) {
            service.mapHTTPError(statusCode: 400, data: Data(huge.utf8))
        }
        #expect(hugeDiagnostics.snapshot.rawBody?.utf8.count == 32 * 1024)
    }

    @Test func retry_rejected_no_request() async throws {
        let failedID = UUID()
        let longText = String(repeating: "A very long paragraph. ", count: 1_000)
        let fixture = makeOverflowFixture(
            contextLength: 2_000,
            maxOutputTokens: 200,
            messages: [
                TestFactories.makeMessage(role: .user, text: longText),
                TestFactories.makeMessage(id: failedID, role: .assistant, text: "boom", state: .failed),
            ]
        )
        let before = try #require(fixture.state.conversation(for: fixture.conversationID)?.messages.last)
        OverflowURLProtocol.reset([])
        await fixture.state.retryMessage(messageID: failedID, in: fixture.conversationID)
        try await Task.sleep(nanoseconds: 800_000_000)

        #expect(OverflowURLProtocol.bodies.isEmpty)
        let after = try #require(fixture.state.conversation(for: fixture.conversationID)?.messages.last)
        #expect(after.id == failedID)
        #expect(after.state == .failed)
        #expect(after.text == before.text)
        #expect(ToastManager.shared.current?.message == L10n.tr("context_reject_message_too_long", table: .chat))
    }

    // MARK: Fixtures

    /// Anthropic Messages SSE: no body block is emitted when text is nil.
    static func anthropicSSE(text: String?, stopReason: String) -> String {
        var frames: [(String, String)] = [(
            "message_start",
            #"{"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"usage":{"input_tokens":10,"output_tokens":0}}}"#
        )]
        if let text {
            frames.append(("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#))
            frames.append(("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(text)"}}"#))
            frames.append(("content_block_stop", #"{"type":"content_block_stop","index":0}"#))
        }
        frames.append(("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"\#(stopReason)","stop_sequence":null},"usage":{"output_tokens":1}}"#))
        frames.append(("message_stop", #"{"type":"message_stop"}"#))
        return frames.map { "event: \($0.0)\ndata: \($0.1)\n\n" }.joined()
    }

    /// Waits for the last assistant message to leave generating (for entry points other than sendMessage, such as continuation).
    func settle(_ fixture: OverflowFixture) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            let last = fixture.state.conversation(for: fixture.conversationID)?.messages.last
            if last?.role == .assistant, last?.state != .generating, last?.state != .interrupted { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    static let overflowModelID = "relay-overflow"

    struct OverflowFixture {
        let state: AppState
        let conversationID: UUID
        let rhoKey: RhoCalibrationKey
        let ledger: SidecarContextLedger
    }

    func makeOverflowFixture(
        contextLength: Int = 40_000,
        maxOutputTokens: Int = 4_000,
        kind: ProviderKind = .relay,
        relayTransport: RelayTransport = .openaiChatCompletions,
        messages: [ChatMessage]
    ) -> OverflowFixture {
        let providerID = UUID()
        let modelID = Self.overflowModelID
        var model = TestFactories.makeModel(id: modelID, capabilities: [.text], isDefault: true)
        model.contextLength = contextLength
        model.maxOutputTokens = maxOutputTokens
        let provider = Provider(
            id: providerID,
            kind: kind,
            status: .connected,
            models: [model],
            catalogModels: [],
            apiKey: "relay-key",
            apiKeyPreview: "...key",
            baseURLText: kind == .relay ? "https://relay.test/v1" : "",
            relayRequested: kind == .relay ? RelayRequestedConfig(transport: relayTransport) : nil
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OverflowURLProtocol.self]
        let state = AppState(
            seedDemoData: false,
            sessionUID: "context-pipeline-overflow-\(UUID().uuidString)",
            providerSession: URLSession(configuration: configuration)
        )
        let stamped = messages.map { message -> ChatMessage in
            var message = message
            message.providerID = providerID
            message.providerKind = kind
            message.modelID = modelID
            return message
        }
        var conversation = TestFactories.makeConversation(
            providerID: providerID,
            providerKind: kind,
            modelID: modelID,
            messages: stamped
        )
        conversation.useMemory = false
        state.providers = [provider]
        state.upsertConversationProjection(conversation)
        // If the standalone database cannot be created the test environment is broken; crashing outright is easier to diagnose than silently skipping the count.
        let ledger = try! SidecarContextLedger()
        ledger.inject(into: state)
        return OverflowFixture(
            state: state,
            conversationID: conversation.id,
            rhoKey: RhoCalibrationKey(transportInstanceId: providerID.uuidString, modelId: modelID),
            ledger: ledger
        )
    }

    /// Writes a summary row covering the first two history messages and returns the checkpointId. The context_checkpoint foreign key points at the conversation table,
    /// and the conversation is persisted asynchronously by the background queue: drain the queue before writing to avoid flaky "row written before the conversation is persisted -> FOREIGN KEY" failures.
    @discardableResult
    func saveSummaryCheckpoint(_ fixture: OverflowFixture, history: [ChatMessage], summary: String) throws -> String {
        fixture.state.flushConversationPersistQueue()
        let conversationId = fixture.conversationID.uuidString
        let covered = history.prefix(2).map { ContextCheckpoint.CoveredMessage(id: $0.id.uuidString, text: $0.text) }
        let coversTo = history[1].id.uuidString
        let checkpointId = ContextCheckpoint.checkpointId(conversationId: conversationId, coversTo: coversTo)
        try #require(ContextCompactionStore.forPartition(fixture.state.sessionPartitionUID)).save(ContextCheckpointRecord(
            conversationId: conversationId,
            checkpointId: checkpointId,
            kind: .summary,
            coversFrom: history[0].id.uuidString,
            coversTo: coversTo,
            coversDigest: ContextCheckpoint.coversDigest(Array(covered)),
            messagesCovered: 2,
            userMessageIds: [history[0].id.uuidString],
            text: "<oriveo-context-checkpoint v=\"1\">\n<note>\(ContextCheckpoint.note)</note>\n<summary>\(summary)</summary>\n</oriveo-context-checkpoint>",
            summary: summary,
            language: nil,
            model: Self.overflowModelID,
            packerVersion: ContextCheckpoint.packerVersion,
            createdAt: Int64(Date().timeIntervalSince1970 * 1_000),
            cost: nil
        ))
        return checkpointId
    }

    func ledger(_ fixture: OverflowFixture) throws -> ContextLedgerStore {
        fixture.ledger.store
    }

    /// Sends a message, waits for the assistant message to leave generating, and returns the captured request bodies in order.
    func sendAndSettle(
        _ fixture: OverflowFixture,
        text: String,
        replies: [OverflowURLProtocol.Reply]
    ) async throws -> [[String: Any]] {
        OverflowURLProtocol.reset(replies)
        defer { OverflowURLProtocol.reset([]) }
        _ = await fixture.state.sendMessage(text, in: fixture.conversationID)
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            let last = fixture.state.conversation(for: fixture.conversationID)?.messages.last
            if last?.role == .assistant, last?.state != .generating { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        // Let the final write-back finish so it does not interleave with the next case.
        try? await Task.sleep(nanoseconds: 300_000_000)
        return OverflowURLProtocol.bodies
    }

    private struct OverflowWireMessage {
        let role: String
        let text: String
    }

    private static func overflowWireMessages(_ body: [String: Any]) -> [OverflowWireMessage] {
        let raw = body["messages"] as? [[String: Any]] ?? []
        return raw.map { message in
            let role = message["role"] as? String ?? ""
            let text: String
            if let string = message["content"] as? String {
                text = string
            } else if let parts = message["content"] as? [[String: Any]] {
                text = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                    .joined(separator: "\n")
            } else {
                text = ""
            }
            return OverflowWireMessage(role: role, text: text)
        }
    }
}
