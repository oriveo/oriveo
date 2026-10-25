import Foundation
import OriveoProviderKit
import Testing
@testable import Oriveo

/// Connection, opening, frame mapping and end-of-stream semantics of GARealtimeTransport (fake socket).
@Suite("GARealtimeTransport", .timeLimit(.minutes(1)))
struct GARealtimeTransportTests {

    /// Fake socket: records the frames sent, inbound frames are pushed by the test; after close, a pending and any later receive throw.
    final class FakeSocket: RealtimeSocket, @unchecked Sendable {
        private let lock = NSLock()
        private var inbox: [Result<String?, Error>] = []
        private var waiter: CheckedContinuation<String?, Error>?
        private var closeWaiters: [CheckedContinuation<Void, Never>] = []
        private var _sent: [String] = []
        private var _closed = false
        var failSends: Error?

        var sent: [[String: Any]] {
            lock.withLock { _sent }.compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
            }
        }
        var sentTypes: [String] { sent.map { $0["type"] as? String ?? "?" } }
        var closed: Bool { lock.withLock { _closed } }

        func send(_ text: String, completion: @escaping @Sendable (Error?) -> Void) {
            let failure = lock.withLock { () -> Error? in
                _sent.append(text)
                return failSends
            }
            completion(failure)
        }

        func receive() async throws -> String? {
            try await withCheckedThrowingContinuation { continuation in
                let next = lock.withLock { () -> Result<String?, Error>? in
                    if _closed { return .failure(URLError(.cancelled)) }
                    if !inbox.isEmpty { return inbox.removeFirst() }
                    waiter = continuation
                    return nil
                }
                if let next { continuation.resume(with: next) }
            }
        }

        func close() {
            let (waiting, closers) = lock.withLock { () -> (CheckedContinuation<String?, Error>?, [CheckedContinuation<Void, Never>]) in
                _closed = true
                defer { waiter = nil; closeWaiters = [] }
                return (waiter, closeWaiters)
            }
            waiting?.resume(throwing: URLError(.cancelled))
            closers.forEach { $0.resume() }
        }

        func waitClosed() async {
            await withCheckedContinuation { continuation in
                let done = lock.withLock { () -> Bool in
                    if _closed { return true }
                    closeWaiters.append(continuation)
                    return false
                }
                if done { continuation.resume() }
            }
        }

        private func deliver(_ result: Result<String?, Error>) {
            let waiting = lock.withLock { () -> CheckedContinuation<String?, Error>? in
                if let waiter {
                    self.waiter = nil
                    return waiter
                }
                inbox.append(result)
                return nil
            }
            waiting?.resume(with: result)
        }

        func push(_ object: [String: Any]) throws {
            deliver(.success(String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)))
        }
        func pushRaw(_ text: String) { deliver(.success(text)) }
        func peerFail(_ error: Error) { deliver(.failure(error)) }
        /// Peer closes: receive returns nil.
        func peerFailNil() { deliver(.success(nil)) }
    }

    final class SocketBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [URLRequest] = []
        let socket = FakeSocket()
        var requests: [URLRequest] { lock.withLock { _requests } }
        func make(_ request: URLRequest) -> any RealtimeSocket {
            lock.withLock { _requests.append(request) }
            return socket
        }
    }

    private static let endpoint = RealtimeEndpoint(
        host: "api.openai.com", apiKey: "sk-test-secret", model: "gpt-realtime 1",
        path: "/v1/realtime", voice: "marin", inputTranscriptionModel: "gpt-4o-transcribe"
    )

    /// Opening input as the production path produces it: ChatMessage → realtimeSessionInput → assembleRealtimeSession → transportInput.
    private static func input(history: [(ChatRole, String)] = []) throws -> RealtimeTransportInput {
        let messages = history.map { TestFactories.makeMessage(role: $0.0, text: $0.1) }
        let snapshot = ChatRequestSnapshot(
            conversation: ChatRequestConversationSnapshot(id: UUID(), useMemory: false, skillID: nil, instructions: "Be brief."),
            messages: messages,
            preferences: ChatRequestPreferencesSnapshot(),
            skill: nil,
            sendPath: .send(excludingMessageID: nil)
        )
        let sessionInput = ChatRequestBuilder.realtimeSessionInput(
            snapshot, contextWindow: 128_000, currentSessionId: "rt-1", sessionMessageIds: [], checkpoint: nil
        )
        let planned = try #require(PlannedRealtimeSession.from(ContextAssembler.assembleRealtimeSession(sessionInput)))
        return planned.transportInput()
    }

    private static func make(_ kind: RealtimeTransportKind = .openaiRealtime) throws -> (GARealtimeTransport, SocketBox) {
        let box = SocketBox()
        let transport = try #require(GARealtimeTransport(kind: kind, endpoint: endpoint, makeSocket: box.make))
        return (transport, box)
    }

    @Test func connects_with_bearer_and_url() throws {
        let (transport, box) = try Self.make()
        let stream = transport.openRealtimeSession(transport: try Self.input())
        let request = try #require(box.requests.first)
        #expect(box.requests.count == 1)
        #expect(request.url?.absoluteString == "wss://api.openai.com/v1/realtime?model=gpt-realtime%201")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-secret")
        #expect(!String(describing: Self.endpoint).contains("sk-test-secret"))
        #expect(!String(reflecting: Self.endpoint).contains("sk-test-secret"))
        var dumped = ""
        dump(Self.endpoint, to: &dumped)
        #expect(!dumped.contains("sk-test-secret"))
        transport.close()
        _ = stream
    }

    @Test func opening_sent_before_ready_audio_after_ready() async throws {
        let (transport, box) = try Self.make()
        let input = try Self.input(history: [(.user, "Typed question"), (.assistant, "Typed answer")])
        let stream = transport.openRealtimeSession(transport: input)
        let codec = try #require(GARealtimeCodec(transport: .openaiRealtime))
        let expected = codec.openingMessages(input: input, voice: "marin", inputTranscriptionModel: "gpt-4o-transcribe").beforeReady
        #expect(box.socket.sentTypes == ["session.update", "conversation.item.create", "conversation.item.create"])
        #expect(box.socket.sent.map { NSDictionary(dictionary: $0) } == expected.map { NSDictionary(dictionary: $0) })

        transport.sendAudio(Data([1, 2, 3, 4]))
        #expect(box.socket.sent.count == 3)

        var iterator = stream.makeAsyncIterator()
        try box.socket.push(["type": "session.created"])
        #expect(try await iterator.next() == .ready)

        transport.sendAudio(Data([1, 2, 3, 4]))
        transport.truncate(itemId: "item_1", contentIndex: 0, playedMs: 1234.9)
        transport.truncate(itemId: nil, contentIndex: 0, playedMs: 500)
        let after = Array(box.socket.sent.dropFirst(3))
        #expect(after.count == 2)
        #expect(after.first?["type"] as? String == "input_audio_buffer.append")
        #expect(after.first?["audio"] as? String == "AQIDBA==")
        #expect(after.last?["type"] as? String == "conversation.item.truncate")
        #expect(after.last?["item_id"] as? String == "item_1")
        #expect((after.last?["audio_end_ms"] as? NSNumber)?.intValue == 1234)
        transport.close()
    }

    @Test func server_frames_mapped_in_order() async throws {
        let (transport, box) = try Self.make(.xaiRealtime)
        let stream = transport.openRealtimeSession(transport: try Self.input())
        try box.socket.push(["type": "session.created"])
        box.socket.pushRaw("not json")
        box.socket.pushRaw("[1, 2]")
        try box.socket.push(["type": "input_audio_buffer.speech_started", "item_id": "u1"])
        try box.socket.push(["type": "response.output_audio_transcript.delta", "item_id": "a1", "delta": "Hel"])
        try box.socket.push(["type": "response.output_audio_transcript.delta", "item_id": "a1", "delta": "lo"])
        try box.socket.push(["type": "response.done", "response": ["status": "completed"]])
        try box.socket.push(["type": "error", "error": ["type": "max_duration", "message": "limit"]])
        try box.socket.push(["type": "session.created"])

        var events: [RealtimeSessionEvent] = []
        for try await event in stream { events.append(event) }
        #expect(events == [
            .ready,
            .userSpeechStarted(itemId: "u1"),
            .assistantTranscript(itemId: "a1", text: "Hel", final: false),
            .assistantTranscript(itemId: "a1", text: "Hello", final: false),
            .assistantTurnDone(itemId: "a1", status: .completed, text: "Hello"),
            .sessionEnded(reason: "max_duration"),
        ])
        #expect(box.socket.closed)
    }

    @Test func error_event_does_not_end_stream() async throws {
        let (transport, box) = try Self.make()
        let stream = transport.openRealtimeSession(transport: try Self.input())
        var iterator = stream.makeAsyncIterator()
        try box.socket.push(["type": "error", "error": ["type": "invalid_request_error", "code": "bad_item", "message": "nope"]])
        try box.socket.push(["type": "session.created"])
        #expect(try await iterator.next() == .error(code: "bad_item", message: "nope"))
        #expect(try await iterator.next() == .ready)
        #expect(!box.socket.closed)
        transport.close()
        #expect(try await iterator.next() == nil)
    }

    @Test func unexpected_close_fails_stream() async throws {
        let (transport, box) = try Self.make()
        let stream = transport.openRealtimeSession(transport: try Self.input())
        var iterator = stream.makeAsyncIterator()
        try box.socket.push(["type": "session.created"])
        #expect(try await iterator.next() == .ready)
        box.socket.peerFail(URLError(.networkConnectionLost))
        await #expect(throws: URLError.self) { _ = try await iterator.next() }
        #expect(box.socket.closed)

        // A normal close frame from the peer (receive returns nil) also counts as an unexpected close.
        let (peerClosing, closingBox) = try Self.make()
        var closingIterator = peerClosing.openRealtimeSession(transport: try Self.input()).makeAsyncIterator()
        closingBox.socket.pushRaw("{}")
        closingBox.socket.peerFailNil()
        await #expect(throws: GARealtimeTransportError.closedByPeer) { _ = try await closingIterator.next() }

        // A send failure likewise ends the stream with an error.
        let (sending, sendingBox) = try Self.make()
        sendingBox.socket.failSends = URLError(.notConnectedToInternet)
        var sendingIterator = sending.openRealtimeSession(transport: try Self.input()).makeAsyncIterator()
        await #expect(throws: URLError.self) { _ = try await sendingIterator.next() }
        #expect(sendingBox.socket.closed)
    }

    @Test func close_ends_stream() async throws {
        let (transport, box) = try Self.make()
        let stream = transport.openRealtimeSession(transport: try Self.input())
        var iterator = stream.makeAsyncIterator()
        try box.socket.push(["type": "session.created"])
        #expect(try await iterator.next() == .ready)
        transport.close()
        #expect(try await iterator.next() == nil)
        #expect(box.socket.closed)
        transport.sendAudio(Data([0, 0]))
        #expect(box.socket.sentTypes == ["session.update"])

        // The socket is closed when the consumer cancels.
        let (cancelled, cancelledBox) = try Self.make()
        let consumer = Task {
            for try await _ in cancelled.openRealtimeSession(transport: try Self.input()) {}
        }
        consumer.cancel()
        await cancelledBox.socket.waitClosed()
        #expect(cancelledBox.socket.closed)
    }

    @Test func binary_frame_ignored() {
        #expect(URLSessionRealtimeSocket.text(of: .data(Data(#"{"type":"session.created"}"#.utf8))) == nil)
        #expect(URLSessionRealtimeSocket.text(of: .string(#"{"type":"session.created"}"#)) == #"{"type":"session.created"}"#)
    }

    @Test func factory_gemini_returns_session_control() async throws {
        let gemini = try #require(RealtimeTransportFactory.make(kind: .geminiLive, endpoint: Self.endpoint, resumeHandle: "h-1"))
        #expect(gemini.kind == .geminiLive)
        let control = try #require(gemini as? GeminiLiveSessionControl)
        #expect(await control.lastResumeHandle == "h-1")
        let fresh = try #require(RealtimeTransportFactory.make(kind: .geminiLive, endpoint: Self.endpoint) as? GeminiLiveSessionControl)
        #expect(await fresh.lastResumeHandle == nil)
        #expect(GARealtimeTransport(kind: .geminiLive, endpoint: Self.endpoint) == nil)
        #expect(RealtimeTransportFactory.make(kind: .openaiRealtime, endpoint: Self.endpoint)?.kind == .openaiRealtime)
        #expect(RealtimeTransportFactory.make(kind: .xaiRealtime, endpoint: Self.endpoint)?.kind == .xaiRealtime)
    }
}
