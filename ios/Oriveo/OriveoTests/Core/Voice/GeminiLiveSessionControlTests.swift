import Foundation
import OriveoProviderKit
import Testing
@testable import Oriveo

/// Gemini Live adapter: declares 16 kHz uplink, hands audio to the transport verbatim and in order, truncate is a no-op, close is forwarded.
@Suite("GeminiLiveSessionControl", .timeLimit(.minutes(1)))
struct GeminiLiveSessionControlTests {

    private static let endpoint = RealtimeEndpoint(
        host: "generativelanguage.googleapis.com",
        apiKey: "k+y/=",
        model: "gemini-3.8-live",
        path: "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent",
        voice: "Kore",
        inputTranscriptionModel: "unused"
    )

    private static let setupComplete = #"{"setupComplete":{}}"#

    /// Builds the input through the production plan projection: session instructions "Be brief.", no history.
    private static func input() throws -> RealtimeTransportInput {
        let snapshot = ChatRequestSnapshot(
            conversation: ChatRequestConversationSnapshot(
                id: UUID(), useMemory: false, skillID: nil, instructions: "Be brief."
            ),
            messages: [],
            preferences: ChatRequestPreferencesSnapshot(),
            skill: nil,
            sendPath: .send(excludingMessageID: nil)
        )
        let sessionInput = ChatRequestBuilder.realtimeSessionInput(
            snapshot, contextWindow: 131_072, currentSessionId: nil, sessionMessageIds: [], checkpoint: nil
        )
        let plan = ContextAssembler.assembleRealtimeSession(sessionInput)
        return try #require(PlannedRealtimeSession.from(plan)).transportInput()
    }

    private static func pcm(_ samples: [Int16]) -> Data {
        var data = Data()
        for sample in samples {
            let bits = UInt16(bitPattern: sample)
            data.append(UInt8(bits & 0xFF))
            data.append(UInt8(bits >> 8))
        }
        return data
    }

    /// Adapter plus fake socket: production config(for:) maps the endpoint, the socket comes from the fake factory.
    private static func make() -> (GeminiLiveSessionControl, AsyncStream<FakeLiveSocket>) {
        let (sockets, sink) = AsyncStream<FakeLiveSocket>.makeStream()
        let transport = GeminiLiveTransport(
            config: GeminiLiveSessionControl.config(for: endpoint),
            socketFactory: { url in
                let socket = FakeLiveSocket(url: url)
                sink.yield(socket)
                return socket
            }
        )
        return (GeminiLiveSessionControl(transport: transport), sockets)
    }

    /// Waits until `count` audio frames have accumulated on the socket and returns their base64 in send order.
    private static func audioFrames(_ socket: FakeLiveSocket, count: Int) async throws -> [String] {
        var found: [String] = []
        var index = 0
        while found.count < count {
            let frame = await socket.frame(index)
            index += 1
            let object = try #require(try JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
            if let input = object["realtimeInput"] as? [String: Any],
               let audio = input["audio"] as? [String: Any],
               let data = audio["data"] as? String {
                found.append(data)
            }
        }
        return found
    }

    /// Uplink is resampled once to 16 kHz at the capture side (the transport's declared rate); sendAudio base64-encodes verbatim and emits in order, with no further downsampling.
    @Test func gemini_uplink_16k_passthrough() async throws {
        let (control, sockets) = Self.make()
        #expect(control.uplinkSampleRate == 16_000)
        var events = control.openRealtimeSession(transport: try Self.input()).makeAsyncIterator()
        var iterator = sockets.makeAsyncIterator()
        let socket = try #require(await iterator.next())
        #expect(socket.url.absoluteString.contains("generativelanguage.googleapis.com"))
        socket.push(Self.setupComplete)
        #expect(try await events.next() == .ready)

        // Three 10 ms frames @ 16 kHz.
        let chunks = (0..<3).map { chunk in Self.pcm((0..<160).map { Int16(chunk * 1_000 + $0 * 2) }) }
        chunks.forEach(control.sendAudio)

        #expect(try await Self.audioFrames(socket, count: 3) == chunks.map { $0.base64EncodedString() })
        control.close()
    }

    /// Cases in the fixture's truncateCases with transport == gemini_live (expected is always null: nothing is sent).
    private static func geminiTruncateCases() throws -> [[String: Any]] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent("shared/voice-contracts/realtime-events.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: candidate)) as? [String: Any])
                let all = try #require(root["truncateCases"] as? [[String: Any]])
                return all.filter { (($0["input"] as? [String: Any])?["transport"] as? String) == "gemini_live" }
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    @Test func never_sends_truncate() async throws {
        let cases = try Self.geminiTruncateCases()
        #expect(cases.count == 1)
        let (control, sockets) = Self.make()
        var events = control.openRealtimeSession(transport: try Self.input()).makeAsyncIterator()
        var iterator = sockets.makeAsyncIterator()
        let socket = try #require(await iterator.next())
        socket.push(Self.setupComplete)
        #expect(try await events.next() == .ready)

        for item in cases {
            let input = try #require(item["input"] as? [String: Any])
            #expect(item["expected"] is NSNull)
            let playedMs = try #require(input["playedMs"] as? Double)
            control.truncate(itemId: input["itemId"] as? String, contentIndex: 0, playedMs: playedMs)
        }
        control.truncate(itemId: "item-1", contentIndex: 0, playedMs: 420)
        control.sendAudio(Self.pcm([1, 2, 3]))
        _ = try await Self.audioFrames(socket, count: 1)
        // Audio frames go out in order after truncate; the whole run only has setup / clientContent / realtimeInput, and no frame carries truncate or its itemId.
        #expect(socket.sent.last?.contains("realtimeInput") == true)
        for frame in socket.sent {
            let object = try #require(try JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
            #expect(Set(object.keys).isSubset(of: ["setup", "clientContent", "realtimeInput"]), "\(frame)")
        }
        #expect(!socket.sent.contains { $0.contains("item-1") || $0.lowercased().contains("truncate") })
        control.close()
    }

    @Test func close_forwards() async throws {
        let (control, sockets) = Self.make()
        var events = control.openRealtimeSession(transport: try Self.input()).makeAsyncIterator()
        var iterator = sockets.makeAsyncIterator()
        let socket = try #require(await iterator.next())
        socket.push(Self.setupComplete)
        #expect(try await events.next() == .ready)

        control.close()
        await socket.waitClosed()
        #expect(socket.closed)
        #expect(try await events.next() == nil)
        #expect(control.kind == .geminiLive)
    }
}

// MARK: - Fake socket (replay style as in GeminiLiveTransportTests)

private nonisolated final class FakeLiveSocket: GeminiLiveSocket, @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var inbox: [String] = []
    private var ended = false
    private var waiter: CheckedContinuation<String?, Never>?
    private var _sent: [String] = []
    private var _closed = false
    private var frameWaiters: [(Int, CheckedContinuation<String, Never>)] = []
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    init(url: URL) { self.url = url }

    var sent: [String] { lock.withLock { _sent } }
    var closed: Bool { lock.withLock { _closed } }

    /// Returns once the frame at `index` has been sent.
    func frame(_ index: Int) async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            let ready: String? = lock.withLock {
                if _sent.count > index { return _sent[index] }
                frameWaiters.append((index, continuation))
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    func push(_ text: String) { deliver(text) }

    private func deliver(_ text: String?) {
        let resume: CheckedContinuation<String?, Never>? = lock.withLock {
            guard !ended else { return nil }
            if text == nil { ended = true }
            if let waiter {
                self.waiter = nil
                return waiter
            }
            if let text { inbox.append(text) }
            return nil
        }
        resume?.resume(returning: text)
    }

    func send(_ text: String) async throws {
        let due: [(CheckedContinuation<String, Never>, String)] = lock.withLock {
            _sent.append(text)
            let sent = _sent
            let due = frameWaiters.filter { $0.0 < sent.count }.map { ($0.1, sent[$0.0]) }
            frameWaiters.removeAll { $0.0 < sent.count }
            return due
        }
        due.forEach { $0.0.resume(returning: $0.1) }
    }

    func receive() async throws -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let immediate: String?? = lock.withLock {
                if !inbox.isEmpty { return .some(inbox.removeFirst()) }
                if ended { return .some(nil) }
                waiter = continuation
                return nil
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
    }

    func close() {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            _closed = true
            defer { closeWaiters = [] }
            return closeWaiters
        }
        waiters.forEach { $0.resume() }
        deliver(nil)
    }

    func waitClosed() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let done: Bool = lock.withLock {
                if _closed { return true }
                closeWaiters.append(continuation)
                return false
            }
            if done { continuation.resume() }
        }
    }
}
