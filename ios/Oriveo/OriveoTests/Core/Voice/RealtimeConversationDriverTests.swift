import Foundation
import OriveoProviderKit
import Testing
@testable import Oriveo

/// RealtimeConversationDriver wiring a real GARealtimeTransport (fake socket) to a fake RealtimeAudioIO.
@Suite("RealtimeConversationDriver", .timeLimit(.minutes(1)))
struct RealtimeConversationDriverTests {

    typealias SocketBox = GARealtimeTransportTests.SocketBox

    /// Fake audio IO: records the call order; isPlaying = something is queued and playback has not been stopped.
    final class FakeAudio: RealtimeAudioIO {
        var log: [String] = []
        var enqueued: [(Data, String)] = []
        var played = 0
        var onFrame: ((Data) -> Void)?
        var onInterruption: (() -> Void)?
        private var playbackStopped = false
        private var stopWaiters: [CheckedContinuation<Void, Never>] = []
        var stopCount: Int { log.filter { $0 == "stopRealtime" }.count }
        var startCount: Int { log.filter { $0 == "startRealtime" }.count }

        /// Like the real audio: startRealtime after stopRealtime throws (single-use semantics).
        struct StartAfterStop: Error {}

        func startRealtime(
            uplinkSampleRate: Double,
            onFrame: @escaping (Data) -> Void,
            onInterruption: @escaping () -> Void
        ) throws {
            log.append("startRealtime")
            if stopCount > 0 { throw StartAfterStop() }
            self.onFrame = onFrame
            self.onInterruption = onInterruption
        }
        func enqueue(pcm16: Data, itemId: String) {
            log.append("enqueue:\(itemId)")
            enqueued.append((pcm16, itemId))
            playbackStopped = false
        }
        func playedMs(itemId: String) -> Int {
            log.append("playedMs:\(itemId)")
            return played
        }
        var isPlaying: Bool { !enqueued.isEmpty && !playbackStopped }
        var onPlaybackDrained: (() -> Void)?
        func stopRealtimePlayback() {
            log.append("stopPlayback")
            playbackStopped = true
        }
        func stopRealtime() {
            log.append("stopRealtime")
            playbackStopped = true
            let waiters = stopWaiters
            stopWaiters = []
            waiters.forEach { $0.resume() }
        }
        func playEarcon(_ earcon: VoiceConversationLogic.Earcon) {
            log.append("earcon")
        }
        func waitStopped() async {
            if stopCount > 0 { return }
            await withCheckedContinuation { stopWaiters.append($0) }
        }
    }

    /// Fake connection: emits unified events directly (simulates a transport without itemId such as Gemini) and records truncate.
    final class FakeConnection: RealtimeTransport, RealtimeSessionControl, @unchecked Sendable {
        let kind: RealtimeTransportKind = .geminiLive
        let uplinkSampleRate = 16_000.0
        let (events, continuation) = AsyncThrowingStream<RealtimeSessionEvent, Error>.makeStream()
        var truncates: [(String?, Double)] = []
        func openRealtimeSession(transport: RealtimeTransportInput) -> AsyncThrowingStream<RealtimeSessionEvent, Error> {
            events
        }
        func sendAudio(_ pcm16: Data) {}
        func truncate(itemId: String?, contentIndex: Int, playedMs: Double) {
            truncates.append((itemId, playedMs))
        }
        func close() { continuation.finish() }
    }

    private static let endpoint = RealtimeEndpoint(
        host: "api.openai.com", apiKey: "sk-test-secret", model: "gpt-realtime",
        path: "/v1/realtime", voice: "marin", inputTranscriptionModel: "gpt-4o-transcribe"
    )

    /// Plan as the production path produces it: ChatMessage → realtimeSessionInput → assembleRealtimeSession → PlannedRealtimeSession.
    private static func plan() throws -> PlannedRealtimeSession {
        let snapshot = ChatRequestSnapshot(
            conversation: ChatRequestConversationSnapshot(id: UUID(), useMemory: false, skillID: nil, instructions: "Be brief."),
            messages: [TestFactories.makeMessage(role: .user, text: "Typed question")],
            preferences: ChatRequestPreferencesSnapshot(),
            skill: nil,
            sendPath: .send(excludingMessageID: nil)
        )
        let sessionInput = ChatRequestBuilder.realtimeSessionInput(
            snapshot, contextWindow: 128_000, currentSessionId: "rt-1", sessionMessageIds: [], checkpoint: nil
        )
        return try #require(PlannedRealtimeSession.from(ContextAssembler.assembleRealtimeSession(sessionInput)))
    }

    private static func make(
        _ kind: RealtimeTransportKind = .openaiRealtime
    ) throws -> (RealtimeConversationDriver, GARealtimeTransport, SocketBox, FakeAudio) {
        let box = SocketBox()
        let connection = try #require(GARealtimeTransport(kind: kind, endpoint: endpoint, makeSocket: box.make))
        let audio = FakeAudio()
        return (RealtimeConversationDriver(connection: connection, audio: audio), connection, box, audio)
    }

    private static func fixtureMessages(_ id: String) throws -> [[String: Any]] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent("shared/voice-contracts/realtime-events.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: candidate)) as? [String: Any])
                let cases = try #require(root["mapCases"] as? [[String: Any]])
                let found = try #require(cases.first { $0["id"] as? String == id })
                let input = try #require(found["input"] as? [String: Any])
                return try #require(input["messages"] as? [[String: Any]])
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    @Test func mic_sent_after_ready_at_24k() async throws {
        let (driver, connection, box, audio) = try Self.make()
        var iterator = driver.run(plan: try Self.plan()).makeAsyncIterator()
        #expect(box.requests.count == 1)
        #expect(audio.onFrame == nil)

        try box.socket.push(["type": "session.created"])
        #expect(try await iterator.next() == .ready)
        #expect(audio.log == ["startRealtime"])

        // 10 ms @ 48 kHz is resampled by production code to 24 kHz PCM16 → about 240 samples.
        let samples = (0..<480).map { Float(sin(Double($0) * 0.05)) * 0.5 }
        let frame = try #require(RealtimePCM.pcm16LE24k(from: samples, sampleRate: 48_000))
        #expect((200...280).contains(frame.count / 2))
        let before = box.socket.sent.count
        let onFrame = try #require(audio.onFrame)
        onFrame(frame)
        let after = Array(box.socket.sent.dropFirst(before))
        #expect(after.count == 1)
        #expect(after.first?["type"] as? String == "input_audio_buffer.append")
        #expect(after.first?["audio"] as? String == frame.base64EncodedString())

        connection.close()
        #expect(try await iterator.next() == nil)
        #expect(audio.stopCount >= 1)
    }

    @Test func assistant_audio_played() async throws {
        let (driver, connection, box, audio) = try Self.make()
        var iterator = driver.run(plan: try Self.plan()).makeAsyncIterator()
        try box.socket.push(["type": "session.created"])
        try box.socket.push([
            "type": "response.output_audio.delta", "response_id": "resp_1", "item_id": "msg_1",
            "output_index": 0, "content_index": 0, "delta": "AQIDBA==",
        ])
        #expect(try await iterator.next() == .ready)
        let event = try await iterator.next()
        guard case let .assistantAudio(itemId, _, base64, _) = event else {
            Issue.record("expected assistantAudio, got \(String(describing: event))")
            return
        }
        #expect(itemId == "msg_1")
        #expect(base64 == "AQIDBA==")
        #expect(audio.enqueued.map(\.0) == [Data([1, 2, 3, 4])])
        #expect(audio.enqueued.map(\.1) == ["msg_1"])
        #expect(audio.isPlaying)

        connection.close()
        #expect(try await iterator.next() == nil)
        #expect(audio.stopCount >= 1)
    }

    @Test func barge_in_stops_and_truncates_played_ms() async throws {
        let (driver, connection, box, audio) = try Self.make()
        audio.played = 1500
        var iterator = driver.run(plan: try Self.plan()).makeAsyncIterator()
        try box.socket.push(["type": "session.created"])
        for message in try Self.fixtureMessages("openai_turn_detected_cancel_is_interrupted") {
            try box.socket.push(message)
        }

        var events: [RealtimeSessionEvent] = []
        while let event = try await iterator.next() {
            events.append(event)
            if case .userSpeechStarted = event { break }
        }
        connection.close()
        while let event = try await iterator.next() { events.append(event) }

        #expect(events.first == .ready)
        #expect(events.contains(.userSpeechStarted(itemId: "msg_011")))
        // Read the played milliseconds first, then stop playback; only then stopRealtime.
        let bargeIn = audio.log.filter { $0.hasPrefix("playedMs") || $0 == "stopPlayback" }
        #expect(Array(bargeIn.prefix(2)) == ["playedMs:msg_010", "stopPlayback"])
        let truncates = box.socket.sent.filter { $0["type"] as? String == "conversation.item.truncate" }
        #expect(truncates.count == 1)
        #expect(truncates.first?["item_id"] as? String == "msg_010")
        #expect((truncates.first?["content_index"] as? NSNumber)?.intValue == 0)
        #expect((truncates.first?["audio_end_ms"] as? NSNumber)?.intValue == 1500)
        #expect(audio.stopCount >= 1)
    }

    @Test func barge_in_drops_late_audio_of_truncated_item() async throws {
        let (driver, connection, box, audio) = try Self.make()
        audio.played = 1500
        var iterator = driver.run(plan: try Self.plan()).makeAsyncIterator()
        try box.socket.push(["type": "session.created"])
        for message in try Self.fixtureMessages("openai_turn_detected_cancel_is_interrupted").prefix(3) {
            try box.socket.push(message)
        }
        let late: [String: Any] = [
            "type": "response.output_audio.delta", "response_id": "resp_002", "item_id": "msg_010",
            "output_index": 0, "content_index": 0, "delta": "CCCC",
        ]
        try box.socket.push(late)
        // A late chunk would count as playing again if enqueued, and another speech_started would then send one more truncate.
        try box.socket.push(["type": "input_audio_buffer.speech_started", "item_id": "msg_012"])

        var events: [RealtimeSessionEvent] = []
        while let event = try await iterator.next() {
            events.append(event)
            if case .userSpeechStarted(itemId: "msg_012") = event { break }
        }
        connection.close()
        while let event = try await iterator.next() { events.append(event) }

        // Events are forwarded as-is, late chunk included.
        #expect(events.contains(.assistantAudio(itemId: "msg_010", contentIndex: 0, base64: "CCCC", sampleRateHz: 24_000)))
        #expect(audio.enqueued.map(\.0) == [try #require(Data(base64Encoded: "BBBB"))])
        #expect(audio.enqueued.map(\.1) == ["msg_010"])
        let truncates = box.socket.sent.filter { $0["type"] as? String == "conversation.item.truncate" }
        #expect(truncates.count == 1)
        #expect(truncates.first?["item_id"] as? String == "msg_010")
    }

    @Test func ready_twice_starts_audio_once() async throws {
        let (driver, connection, box, audio) = try Self.make()
        var iterator = driver.run(plan: try Self.plan()).makeAsyncIterator()
        try box.socket.push(["type": "session.created"])
        try box.socket.push(["type": "session.created"])
        #expect(try await iterator.next() == .ready)
        #expect(try await iterator.next() == .ready)
        #expect(audio.log.filter { $0 == "startRealtime" }.count == 1)
        connection.close()
        #expect(try await iterator.next() == nil)
    }

    @Test func system_interruption_closes() async throws {
        let (driver, _, box, audio) = try Self.make()
        var iterator = driver.run(plan: try Self.plan()).makeAsyncIterator()
        try box.socket.push(["type": "session.created"])
        #expect(try await iterator.next() == .ready)

        let onInterruption = try #require(audio.onInterruption)
        onInterruption()
        #expect(box.socket.closed)
        #expect(audio.stopCount >= 1)
        #expect(try await iterator.next() == nil)
    }

    @Test func session_ended_stops_audio() async throws {
        let (driver, _, box, audio) = try Self.make(.xaiRealtime)
        var iterator = driver.run(plan: try Self.plan()).makeAsyncIterator()
        try box.socket.push(["type": "session.created"])
        try box.socket.push(["type": "error", "error": ["type": "max_duration", "message": "limit"]])
        #expect(try await iterator.next() == .ready)
        #expect(try await iterator.next() == .sessionEnded(reason: "max_duration"))
        #expect(audio.stopCount >= 1)
        #expect(try await iterator.next() == nil)

        // A stream error also stops the audio.
        let (failing, _, failingBox, failingAudio) = try Self.make()
        var failingIterator = failing.run(plan: try Self.plan()).makeAsyncIterator()
        try failingBox.socket.push(["type": "session.created"])
        #expect(try await failingIterator.next() == .ready)
        failingBox.socket.peerFail(URLError(.networkConnectionLost))
        await #expect(throws: URLError.self) { _ = try await failingIterator.next() }
        #expect(failingAudio.stopCount >= 1)

        // Consumer cancellation also stops the audio and closes the socket.
        let (cancelled, _, cancelledBox, cancelledAudio) = try Self.make()
        let plan = try Self.plan()
        let consumer = Task {
            for try await _ in cancelled.run(plan: plan) {}
        }
        try cancelledBox.socket.push(["type": "session.created"])
        consumer.cancel()
        await cancelledAudio.waitStopped()
        await cancelledBox.socket.waitClosed()
        #expect(cancelledAudio.stopCount >= 1)
    }

    @Test func barge_in_null_item_drops_until_interrupted() async throws {
        let connection = FakeConnection()
        let audio = FakeAudio()
        audio.played = 700
        let driver = RealtimeConversationDriver(connection: connection, audio: audio)
        var iterator = driver.run(plan: try Self.plan()).makeAsyncIterator()
        let sequence: [RealtimeSessionEvent] = [
            .ready,
            .assistantAudio(itemId: nil, contentIndex: 0, base64: "AQID", sampleRateHz: 24_000),
            .userSpeechStarted(itemId: nil),
            .assistantAudio(itemId: nil, contentIndex: 0, base64: "BBBB", sampleRateHz: 24_000),
            .interrupted,
            .assistantAudio(itemId: nil, contentIndex: 0, base64: "CCCC", sampleRateHz: 24_000),
        ]
        for event in sequence { connection.continuation.yield(event) }
        var events: [RealtimeSessionEvent] = []
        for _ in sequence { if let event = try await iterator.next() { events.append(event) } }
        connection.close()
        while let event = try await iterator.next() { events.append(event) }

        // Events are forwarded as-is, the dropped late chunk included.
        #expect(events == sequence)
        // Read the played milliseconds first, then stop playback; without an itemId there is no truncate.
        let bargeIn = audio.log.filter { $0.hasPrefix("playedMs") || $0 == "stopPlayback" }
        #expect(Array(bargeIn.prefix(2)) == ["playedMs:", "stopPlayback"])
        #expect(connection.truncates.isEmpty)
        // Chunks between the interruption and interrupted are dropped; enqueueing resumes afterwards.
        #expect(audio.enqueued.map(\.0) == [
            try #require(Data(base64Encoded: "AQID")), try #require(Data(base64Encoded: "CCCC")),
        ])
    }

    @Test func barge_in_null_item_resumes_after_turn_done() async throws {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let driver = RealtimeConversationDriver(connection: connection, audio: audio)
        var iterator = driver.run(plan: try Self.plan()).makeAsyncIterator()
        let sequence: [RealtimeSessionEvent] = [
            .ready,
            .assistantAudio(itemId: nil, contentIndex: 0, base64: "AQID", sampleRateHz: 24_000),
            .userSpeechStarted(itemId: nil),
            .assistantAudio(itemId: nil, contentIndex: 0, base64: "BBBB", sampleRateHz: 24_000),
            .assistantTurnDone(itemId: nil, status: .completed, text: ""),
            .assistantAudio(itemId: nil, contentIndex: 0, base64: "CCCC", sampleRateHz: 24_000),
        ]
        for event in sequence { connection.continuation.yield(event) }
        for _ in sequence { _ = try await iterator.next() }
        connection.close()
        while try await iterator.next() != nil {}

        #expect(audio.enqueued.map(\.0) == [
            try #require(Data(base64Encoded: "AQID")), try #require(Data(base64Encoded: "CCCC")),
        ])
        #expect(connection.truncates.isEmpty)
    }

    @Test func interrupt_playback_stops_and_truncates() async throws {
        let (driver, connection, box, audio) = try Self.make()
        var iterator = driver.run(plan: try Self.plan()).makeAsyncIterator()
        try box.socket.push(["type": "session.created"])
        try box.socket.push([
            "type": "response.output_audio.delta", "response_id": "resp_1", "item_id": "msg_1",
            "output_index": 0, "content_index": 0, "delta": "AQIDBA==",
        ])
        #expect(try await iterator.next() == .ready)
        _ = try await iterator.next()
        #expect(audio.isPlaying)

        audio.played = 800
        driver.interruptPlayback()
        #expect(Array(audio.log.suffix(2)) == ["playedMs:msg_1", "stopPlayback"])
        let truncates = box.socket.sent.filter { $0["type"] as? String == "conversation.item.truncate" }
        #expect(truncates.count == 1)
        #expect(truncates.first?["item_id"] as? String == "msg_1")
        #expect((truncates.first?["audio_end_ms"] as? NSNumber)?.intValue == 800)

        // Late chunks of the interrupted item are dropped; the events are still forwarded.
        try box.socket.push([
            "type": "response.output_audio.delta", "response_id": "resp_1", "item_id": "msg_1",
            "output_index": 0, "content_index": 0, "delta": "CCCC",
        ])
        #expect(try await iterator.next() == .assistantAudio(itemId: "msg_1", contentIndex: 0, base64: "CCCC", sampleRateHz: 24_000))
        #expect(audio.enqueued.count == 1)

        connection.close()
        while try await iterator.next() != nil {}
    }

    @Test func interrupt_playback_when_idle_noop() async throws {
        let (driver, connection, box, audio) = try Self.make()
        var iterator = driver.run(plan: try Self.plan()).makeAsyncIterator()
        try box.socket.push(["type": "session.created"])
        #expect(try await iterator.next() == .ready)

        driver.interruptPlayback()
        #expect(audio.log == ["startRealtime"])
        #expect(!box.socket.sent.contains { $0["type"] as? String == "conversation.item.truncate" })

        connection.close()
        #expect(try await iterator.next() == nil)
    }

    // MARK: - A session ended by expiry does not stop the audio

    /// Pushes ready, then finishes the fake connection's stream with `error`, and returns the error thrown by the driver.
    private static func endAfterReady(with error: Error) async throws -> (FakeAudio, Error?) {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let driver = RealtimeConversationDriver(connection: connection, audio: audio)
        var iterator = driver.run(plan: try Self.plan()).makeAsyncIterator()
        connection.continuation.yield(.ready)
        #expect(try await iterator.next() == .ready)
        connection.continuation.finish(throwing: error)
        var thrown: Error?
        do {
            while try await iterator.next() != nil {}
        } catch {
            thrown = error
        }
        return (audio, thrown)
    }

    @Test func session_expired_end_keeps_audio_running() async throws {
        let (audio, thrown) = try await Self.endAfterReady(with: GeminiLiveTransportError.sessionExpired(reason: "session expired"))
        #expect(thrown as? GeminiLiveTransportError == .sessionExpired(reason: "session expired"))
        #expect(audio.startCount == 1)
        #expect(audio.stopCount == 0)
    }

    @Test func other_error_end_still_stops_audio() async throws {
        let (audio, thrown) = try await Self.endAfterReady(with: GeminiLiveTransportError.connectionClosed)
        #expect(thrown as? GeminiLiveTransportError == .connectionClosed)
        #expect(audio.stopCount == 1)
    }
}
