import Combine
import Foundation
import OriveoProviderKit
import Testing
@testable import Oriveo

/// RealtimeVoiceConversationController sends a fake connection's events through the real driver into the reducer and executes the effects.
@Suite("RealtimeVoiceConversationController", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct RealtimeVoiceConversationControllerTests {

    typealias Status = VoiceConversationLogic.StatusKey

    /// Fake audio IO: records the call order; isPlaying = something non-empty is queued and playback has not been stopped / has not finished (like the real player, empty PCM is not scheduled);
    /// finishPlayback goes through the playback-finished callback.
    final class FakeAudio: RealtimeAudioIO {
        var log: [String] = []
        var enqueued: [(Data, String)] = []
        var played = 0
        var earcons: [VoiceConversationLogic.Earcon] = []
        var onFrame: ((Data) -> Void)?
        /// Uplink sample rate received by the latest startRealtime (the transport's declared value).
        var uplinkSampleRate: Double?
        var onInterruption: (() -> Void)?
        var onPlaybackDrained: (() -> Void)?
        private var playbackStopped = false
        var stopCount: Int { log.filter { $0 == "stopRealtime" }.count }
        var startCount: Int { log.filter { $0 == "startRealtime" }.count }

        /// Like the real audio: startRealtime after stopRealtime throws (single-use semantics).
        struct StartAfterStop: Error {}

        func startRealtime(
            uplinkSampleRate: Double,
            onFrame: @escaping (Data) -> Void,
            onInterruption: @escaping () -> Void
        ) throws {
            self.uplinkSampleRate = uplinkSampleRate
            log.append("startRealtime")
            if stopCount > 0 { throw StartAfterStop() }
            self.onFrame = onFrame
            self.onInterruption = onInterruption
        }
        func enqueue(pcm16: Data, itemId: String) {
            log.append("enqueue:\(itemId)")
            enqueued.append((pcm16, itemId))
            if !pcm16.isEmpty { playbackStopped = false }
        }
        func playedMs(itemId: String) -> Int {
            log.append("playedMs:\(itemId)")
            return played
        }
        var isPlaying: Bool { enqueued.contains { !$0.0.isEmpty } && !playbackStopped }
        func stopRealtimePlayback() {
            log.append("stopPlayback")
            playbackStopped = true
        }
        func stopRealtime() {
            log.append("stopRealtime")
            playbackStopped = true
        }
        func playEarcon(_ earcon: VoiceConversationLogic.Earcon) {
            earcons.append(earcon)
        }
        /// The downlink queue finishes naturally (without a stop): like the real player, invokes the playback-finished callback once.
        func finishPlayback() {
            playbackStopped = true
            onPlaybackDrained?()
        }
    }

    /// Fake connection: emits unified events directly, records uplink audio, truncate and close.
    /// nonisolated: uplink may call sendAudio on a background thread (see realtime_uplink_not_hopped_through_main).
    nonisolated final class FakeConnection: RealtimeTransport, RealtimeSessionControl, @unchecked Sendable {
        let kind: RealtimeTransportKind = .openaiRealtime
        let uplinkSampleRate: Double
        let (events, continuation) = AsyncThrowingStream<RealtimeSessionEvent, Error>.makeStream()
        var sent: [Data] = []
        /// Whether each sendAudio call happened on the main thread.
        var sentOnMain: [Bool] = []
        var truncates: [(String?, Double)] = []
        var closeCount = 0
        var openCount = 0
        init(uplinkSampleRate: Double = RealtimePCM.sampleRate) { self.uplinkSampleRate = uplinkSampleRate }
        func openRealtimeSession(transport: RealtimeTransportInput) -> AsyncThrowingStream<RealtimeSessionEvent, Error> {
            openCount += 1
            return events
        }
        func sendAudio(_ pcm16: Data) {
            sent.append(pcm16)
            sentOnMain.append(Thread.isMainThread)
        }
        func truncate(itemId: String?, contentIndex: Int, playedMs: Double) {
            truncates.append((itemId, playedMs))
        }
        func close() {
            closeCount += 1
            continuation.finish()
        }
    }

    final class FakeSink: RealtimeConversationSink {
        var log: [String] = []
        private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
        func appendUser(_ text: String) { record("user:\(text)") }
        func appendAssistant(_ text: String) { record("assistant:\(text)") }
        private func record(_ entry: String) {
            log.append(entry)
            let ready = waiters.filter { $0.0 <= log.count }
            waiters.removeAll { $0.0 <= log.count }
            ready.forEach { $0.1.resume() }
        }
        func waitCount(_ count: Int) async {
            if log.count >= count { return }
            await withCheckedContinuation { waiters.append((count, $0)) }
        }
    }

    /// End callback record: reason + draft, awaitable.
    final class Ended {
        var value: (RealtimeConversationLogic.EndReason, String?)?
        var errors: [String] = []
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func record(_ reason: RealtimeConversationLogic.EndReason, _ draft: String?) {
            value = (reason, draft)
            let ready = waiters
            waiters = []
            ready.forEach { $0.resume() }
        }
        func wait() async {
            if value != nil { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    /// Manual clock: one-shot timers only; advance fires them in due order, and a fired timer is no longer valid.
    final class ManualClock: VoiceConversationClock {
        private final class Entry: VoiceConversationTimer {
            let at: Int
            let handler: () -> Void
            var done = false
            init(at: Int, handler: @escaping () -> Void) {
                self.at = at
                self.handler = handler
            }
            func cancel() { done = true }
        }

        var nowMs = 0
        private var entries: [Entry] = []
        /// Number of timers already fired.
        private(set) var fired = 0

        /// Due times of the pending one-shot timers.
        var pendingDeadlines: [Int] { entries.filter { !$0.done }.map(\.at) }

        func after(ms: Int, _ handler: @escaping () -> Void) -> VoiceConversationTimer {
            let entry = Entry(at: nowMs + max(0, ms), handler: handler)
            entries.append(entry)
            return entry
        }

        func advance(_ ms: Int) {
            let end = nowMs + ms
            while let entry = entries.filter({ !$0.done && $0.at <= end }).min(by: { $0.at < $1.at }) {
                nowMs = max(nowMs, entry.at)
                entry.done = true
                fired += 1
                entry.handler()
            }
            entries.removeAll { $0.done }
            nowMs = end
        }
    }

    private let connection = FakeConnection()
    private let audio = FakeAudio()
    private let sink = FakeSink()
    private let clock = ManualClock()
    private let ended = Ended()

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

    private func start(
        reopener: RealtimeVoiceConversationController.Reopener? = nil,
        replanner: RealtimeVoiceConversationController.Replanner? = nil,
        plan: PlannedRealtimeSession? = nil,
        connection: FakeConnection? = nil
    ) throws -> RealtimeVoiceConversationController {
        let ended = ended
        let controller = RealtimeVoiceConversationController(
            connection: connection ?? self.connection, audio: audio, plan: try plan ?? Self.plan(), sink: sink, clock: clock,
            reopener: reopener,
            replanner: replanner,
            onError: { ended.errors.append($0) },
            onEnded: { reason, draft in ended.record(reason, draft) }
        )
        controller.start()
        return controller
    }

    private func send(_ events: RealtimeSessionEvent...) {
        for event in events { connection.continuation.yield(event) }
    }

    private func waitStatus(_ controller: RealtimeVoiceConversationController, _ key: Status) async {
        for await value in controller.$statusKey.values where value == key { return }
    }

    private static let expired = GeminiLiveTransportError.sessionExpired(reason: "session expired")

    private static let frame: Data = RealtimePCM.encodePCM16LE((0..<240).map { Float(sin(Double($0) * 0.2)) * 0.5 })
    /// Frames of 10 ms needed to fill one level window (1 / 15 s): 7 frames = 70 ms.
    private static let framesPerLevel = Int((RealtimePCM.sampleRate / DictationLevelMeter.maxUpdatesPerSecond / 240).rounded(.up))

    private static func frame(amplitude: Float) -> Data {
        RealtimePCM.encodePCM16LE((0..<240).map { Float(sin(Double($0) * 0.2)) * amplitude })
    }

    @Test func persist_calls_sink_in_order() async throws {
        let controller = try start()
        send(.ready)
        await waitStatus(controller, .listening)
        send(
            .userSpeechStarted(itemId: "u1"),
            .userSpeechStopped(itemId: "u1"),
            .userTranscript(itemId: "u1", text: " Hello there ", final: true),
            .assistantTranscript(itemId: "a1", text: "Hi!", final: false),
            .assistantTurnDone(itemId: "a1", status: .completed, text: "Hi!"),
            .sessionEnded(reason: "max_duration")
        )
        await ended.wait()
        #expect(sink.log == ["user:Hello there", "assistant:Hi!"])
        #expect(ended.value?.0 == .system)
        #expect(connection.closeCount >= 1)
        #expect(controller.statusKey == nil)
    }

    @Test func mute_gates_uplink_and_sends_silence() async throws {
        let controller = try start()
        // connecting also shows thinking: wait for listening first, then advance.
        send(.ready)
        await waitStatus(controller, .listening)
        send(.userSpeechStarted(itemId: "u1"), .userSpeechStopped(itemId: "u1"))
        await waitStatus(controller, .thinking)
        send(.userSpeechStarted(itemId: "u2"))
        await waitStatus(controller, .listening)

        let onFrame = try #require(audio.onFrame)
        // The level is throttled by audio duration: it is published only once a window fills, while frames still go up one by one.
        for _ in 0..<(Self.framesPerLevel - 1) { onFrame(Self.frame) }
        #expect(controller.level == 0)
        onFrame(Self.frame)
        #expect(connection.sent == Array(repeating: Self.frame, count: Self.framesPerLevel))
        #expect(controller.level > 0)
        let sentBeforeMute = connection.sent.count

        controller.toggleMute()
        #expect(controller.statusKey == .muted)
        #expect(controller.displayState == .muted)
        #expect(controller.level == 0)
        // Mute while speaking: first pad 1000 ms of zero PCM16, sized by the uplink sample rate the transport declares (fake connection 24 kHz).
        #expect(audio.uplinkSampleRate == connection.uplinkSampleRate)
        #expect(connection.sent.count == sentBeforeMute + 1)
        #expect(connection.sent.last == Data(count: Int(connection.uplinkSampleRate) * 2))
        onFrame(Self.frame)
        #expect(connection.sent.count == sentBeforeMute + 1)

        controller.toggleMute()
        #expect(controller.statusKey == .listening)
        onFrame(Self.frame)
        #expect(connection.sent.count == sentBeforeMute + 2)
        #expect(connection.sent.last == Self.frame)
    }

    /// When the connection declares 16 kHz (Gemini Live): the 1000 ms of zeros padded on mute while speaking is counted at 16k: 16000 samples × 2 bytes.
    @Test func silence_frames_sized_by_declared_16k_rate() async throws {
        let gemini = FakeConnection(uplinkSampleRate: 16_000)
        let controller = try start(connection: gemini)
        gemini.continuation.yield(.ready)
        await waitStatus(controller, .listening)
        gemini.continuation.yield(.userSpeechStarted(itemId: "u1"))
        gemini.continuation.yield(.userSpeechStopped(itemId: "u1"))
        await waitStatus(controller, .thinking)
        gemini.continuation.yield(.userSpeechStarted(itemId: "u2"))
        await waitStatus(controller, .listening)
        #expect(audio.uplinkSampleRate == 16_000)

        controller.toggleMute()
        #expect(controller.statusKey == .muted)
        #expect(gemini.sent == [Data(count: 32_000)])
        #expect(connection.sent.isEmpty)
    }

    /// 100 frames × 10 ms = 1 s of audio: level publishes ≤ 1 s × 15 times; amplitude increases frame by frame, so every window's level differs.
    @Test func uplink_level_publishes_at_most_15hz() async throws {
        let controller = try start()
        send(.ready)
        await waitStatus(controller, .listening)
        let onFrame = try #require(audio.onFrame)

        var published: [Double] = []
        let subscription = controller.$level.dropFirst().sink { published.append($0) }
        let frames = (0..<100).map { Self.frame(amplitude: 0.05 + 0.009 * Float($0)) }
        for frame in frames { onFrame(frame) }
        subscription.cancel()

        let seconds = Double(frames.reduce(0) { $0 + $1.count / 2 }) / RealtimePCM.sampleRate
        #expect(connection.sent == frames)
        #expect(!published.isEmpty)
        #expect(published.count <= Int(seconds * DictationLevelMeter.maxUpdatesPerSecond))
        #expect(published == published.sorted())
        #expect(controller.level == published.last)
    }

    /// Uplink frames handed over by the audio thread go to the transport on the same thread without hopping through the main thread; the level is published back on the main thread afterwards.
    @Test func realtime_uplink_not_hopped_through_main() async throws {
        let controller = try start()
        send(.ready)
        await waitStatus(controller, .listening)
        let onFrame = try #require(audio.onFrame)
        let connection = connection
        let frames = Array(repeating: Self.frame, count: Self.framesPerLevel)

        let sentOnMain: [Bool] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                for frame in frames { onFrame(frame) }
                // The frame is handed to the transport synchronously on this thread: all are recorded before returning.
                continuation.resume(returning: connection.sentOnMain)
            }
        }
        #expect(sentOnMain == Array(repeating: false, count: frames.count))
        #expect(connection.sent == frames)
        for await value in controller.$level.values where value > 0 { break }
        #expect(controller.level > 0)
    }

    @Test func tap_orb_calls_interrupt_playback() async throws {
        let controller = try start()
        audio.played = 900
        send(.ready, .assistantAudio(itemId: "msg_1", contentIndex: 0, base64: "AQIDBA==", sampleRateHz: 24_000))
        await waitStatus(controller, .speaking)
        #expect(controller.level == 0.5)
        #expect(audio.isPlaying)

        controller.tapOrb()
        #expect(Array(audio.log.suffix(2)) == ["playedMs:msg_1", "stopPlayback"])
        #expect(connection.truncates.count == 1)
        #expect(connection.truncates.first?.0 == "msg_1")
        #expect(connection.truncates.first?.1 == 900)
        #expect(controller.statusKey == .listening)
    }

    @Test func playback_drained_from_audio_idle() async throws {
        let controller = try start()
        send(
            .ready,
            .assistantAudio(itemId: "msg_1", contentIndex: 0, base64: "AQIDBA==", sampleRateHz: 24_000),
            .assistantTurnDone(itemId: "msg_1", status: .completed, text: "Done")
        )
        await sink.waitCount(1)
        #expect(sink.log == ["assistant:Done"])
        #expect(controller.statusKey == .speaking)

        clock.advance(250)
        #expect(controller.statusKey == .speaking)

        // Playback end is driven only by the player callback, not by the clock.
        audio.finishPlayback()
        #expect(controller.statusKey == .listening)
        #expect(controller.displayState == .listening)
    }

    /// Only empty PCM is enqueued during the reply: the player never starts and never calls back playback-finished; at the moment replyDone is read, playback is already drained, so playbackDrained is dispatched on the spot.
    @Test func empty_pcm_then_turn_done_still_drains() async throws {
        let controller = try start()
        send(
            .ready,
            .assistantAudio(itemId: "msg_1", contentIndex: 0, base64: "", sampleRateHz: 24_000),
            .assistantTurnDone(itemId: "msg_1", status: .completed, text: "Done")
        )
        await sink.waitCount(1)
        #expect(sink.log == ["assistant:Done"])
        #expect(!audio.isPlaying)
        #expect(controller.statusKey == .listening)
        #expect(controller.displayState == .listening)
    }

    /// After an interruption stops playback, the old reply's late playback-finished callback: the new reply still has audio to play, so it must not wrap up on it.
    @Test func stale_drained_callback_after_stop_ignored() async throws {
        let controller = try start()
        send(.ready, .assistantAudio(itemId: "msg_1", contentIndex: 0, base64: "AQIDBA==", sampleRateHz: 24_000))
        await waitStatus(controller, .speaking)
        controller.tapOrb()
        #expect(controller.statusKey == .listening)

        send(
            .assistantAudio(itemId: "msg_2", contentIndex: 0, base64: "AQIDBA==", sampleRateHz: 24_000),
            .assistantTurnDone(itemId: "msg_2", status: .completed, text: "Second")
        )
        await sink.waitCount(1)
        #expect(controller.statusKey == .speaking)
        #expect(audio.isPlaying)

        // Late callback for the segment before the stop (the player is still playing msg_2).
        audio.onPlaybackDrained?()
        #expect(controller.statusKey == .speaking)

        audio.finishPlayback()
        #expect(controller.statusKey == .listening)
    }

    /// While a screen reader announcement is speaking the uplink pauses but does not count as muted; mute takes priority, and unmuting during the announcement only clears mute, the uplink opens once the announcement ends.
    @Test func screenReaderSpeakingGatesUplinkWithoutMute() async throws {
        let controller = try start()
        send(.ready)
        await waitStatus(controller, .listening)
        let onFrame = try #require(audio.onFrame)
        onFrame(Self.frame)
        #expect(connection.sent.count == 1)

        controller.setScreenReaderSpeaking(true)
        #expect(controller.statusKey == .listening)
        onFrame(Self.frame)
        #expect(connection.sent.count == 1)

        controller.setScreenReaderSpeaking(false)
        onFrame(Self.frame)
        #expect(connection.sent.count == 2)

        controller.setScreenReaderSpeaking(true)
        controller.toggleMute()
        #expect(controller.statusKey == .muted)
        controller.toggleMute()
        #expect(controller.statusKey == .listening)
        onFrame(Self.frame)
        #expect(connection.sent.count == 2)

        controller.setScreenReaderSpeaking(false)
        onFrame(Self.frame)
        #expect(connection.sent.count == 3)

        controller.toggleMute()
        controller.setScreenReaderSpeaking(true)
        controller.setScreenReaderSpeaking(false)
        onFrame(Self.frame)
        #expect(connection.sent.count == 3)
        #expect(controller.statusKey == .muted)
    }

    @Test func showErrorInvokesOnErrorOnce() async throws {
        let controller = try start()
        send(.ready)
        await waitStatus(controller, .listening)
        connection.continuation.finish(throwing: URLError(.networkConnectionLost))
        await ended.wait()
        controller.end()
        controller.setScreenReaderSpeaking(true)
        #expect(ended.errors == ["URLError"])
        #expect(controller.statusKey == .error)
    }

    @Test func failed_stream_shows_error_and_ends() async throws {
        let controller = try start()
        send(.ready)
        await waitStatus(controller, .listening)
        connection.continuation.finish(throwing: URLError(.networkConnectionLost))
        await ended.wait()
        #expect(ended.errors == ["URLError"])
        #expect(ended.value?.0 == .error)
        #expect(ended.value?.1 == nil)
        #expect(controller.displayState == .error)
        #expect(controller.statusKey == .error)
        #expect(connection.closeCount >= 1)
    }

    // MARK: - Session expiry

    /// Reopener stand-in: records the call count and returns a new connection or throws as needed.
    final class Reopens {
        var calls = 0
        var result: Result<FakeConnection, Error>
        init(_ result: Result<FakeConnection, Error>) { self.result = result }
    }

    private func reopener(_ reopens: Reopens) throws -> RealtimeVoiceConversationController.Reopener {
        let plan = try Self.plan()
        return { @MainActor in
            reopens.calls += 1
            return (connection: try reopens.result.get(), plan: plan)
        }
    }

    /// While muted, ends the first connection with sessionExpired and waits until the controller has dispatched the stream's last input (entering dormancy).
    private func expireWhileMuted(_ controller: RealtimeVoiceConversationController) async {
        send(.ready)
        await waitStatus(controller, .listening)
        controller.toggleMute()
        #expect(controller.statusKey == .muted)
        let firstStream = controller.streamTask
        connection.continuation.finish(throwing: Self.expired)
        await firstStream?.value
    }

    @Test func session_expired_while_muted_stays_dormant_without_ended() async throws {
        let reopens = Reopens(.success(FakeConnection()))
        let controller = try start(reopener: try reopener(reopens))
        await expireWhileMuted(controller)
        clock.advance(250)
        #expect(ended.value == nil)
        #expect(ended.errors.isEmpty)
        #expect(controller.statusKey == .muted)
        // No reopen while dormant
        #expect(reopens.calls == 0)

        // Unmute: the reducer emits reopen + uplink on, state returns to thinking until the new connection is ready
        controller.toggleMute()
        #expect(controller.statusKey == .thinking)
        #expect(ended.value == nil)
    }

    // MARK: - Automatic reopen on expiry while not muted

    @Test func unmuted_session_expired_reopens_and_continues() async throws {
        let second = FakeConnection()
        let reopens = Reopens(.success(second))
        let controller = try start(reopener: try reopener(reopens))
        send(.ready)
        await waitStatus(controller, .listening)
        // Closed with 1008 while speaking: the call does not end, a new connection is opened with history through the current reopener path
        send(.userSpeechStarted(itemId: "u1"))
        let firstStream = controller.streamTask
        connection.continuation.finish(throwing: Self.expired)
        await firstStream?.value
        #expect(ended.value == nil)
        #expect(ended.errors.isEmpty)
        #expect(controller.statusKey == .thinking)

        second.continuation.yield(.ready)
        await waitStatus(controller, .listening)
        #expect(reopens.calls == 1)
        #expect(second.openCount == 1)
        #expect(connection.openCount == 1)
        // Audio keeps running during the reopen
        #expect(audio.startCount == 1)
        #expect(audio.stopCount == 0)
        let onFrame = try #require(audio.onFrame)
        onFrame(Self.frame)
        #expect(second.sent == [Self.frame])

        // The same sink keeps receiving the new connection's conversation
        second.continuation.yield(.userSpeechStarted(itemId: "u2"))
        second.continuation.yield(.userSpeechStopped(itemId: "u2"))
        second.continuation.yield(.userTranscript(itemId: "u2", text: "Still there?", final: true))
        second.continuation.yield(.assistantTurnDone(itemId: "a2", status: .completed, text: "Yes."))
        await sink.waitCount(2)
        #expect(sink.log == ["user:Still there?", "assistant:Yes."])
        #expect(ended.value == nil)

        controller.end()
        #expect(second.closeCount >= 1)
        #expect(reopens.calls == 1)
    }

    @Test func reopen_expired_again_without_progress_ends_error() async throws {
        let second = FakeConnection()
        let reopens = Reopens(.success(second))
        let controller = try start(reopener: try reopener(reopens))
        send(.ready)
        await waitStatus(controller, .listening)
        let firstStream = controller.streamTask
        connection.continuation.finish(throwing: Self.expired)
        await firstStream?.value
        second.continuation.yield(.ready)
        await waitStatus(controller, .listening)
        #expect(ended.value == nil)

        // ready is not progress: the new connection expires again → end with an error, no further reopen
        second.continuation.finish(throwing: Self.expired)
        await ended.wait()
        #expect(reopens.calls == 1)
        #expect(ended.errors == ["sessionExpired"])
        #expect(ended.value?.0 == .error)
        #expect(controller.statusKey == .error)
        #expect(audio.startCount == 1)
        #expect(audio.stopCount == 1)
    }

    // MARK: - Controller executes reopen

    @Test func unmute_after_expiry_reopens_on_new_connection() async throws {
        let second = FakeConnection()
        let reopens = Reopens(.success(second))
        let controller = try start(reopener: try reopener(reopens))
        await expireWhileMuted(controller)
        let firstSent = connection.sent.count

        controller.toggleMute()
        #expect(controller.statusKey == .thinking)
        // ready is delivered by the new connection's events
        second.continuation.yield(.ready)
        await waitStatus(controller, .listening)
        #expect(reopens.calls == 1)
        #expect(second.openCount == 1)
        #expect(connection.openCount == 1)

        let onFrame = try #require(audio.onFrame)
        onFrame(Self.frame)
        #expect(second.sent == [Self.frame])
        #expect(connection.sent.count == firstSent)

        // The same sink keeps receiving the new connection's transcripts; the host does not receive ended
        second.continuation.yield(.userSpeechStarted(itemId: "u9"))
        second.continuation.yield(.userSpeechStopped(itemId: "u9"))
        second.continuation.yield(.userTranscript(itemId: "u9", text: "Back again", final: true))
        await sink.waitCount(1)
        #expect(sink.log == ["user:Back again"])
        #expect(ended.value == nil)

        controller.end()
        #expect(second.closeCount >= 1)
        #expect(reopens.calls == 1)
    }

    // MARK: - Audio keeps running during a reopen

    @Test func reopen_keeps_audio_running_and_rebinds_uplink() async throws {
        let second = FakeConnection()
        let reopens = Reopens(.success(second))
        let controller = try start(reopener: try reopener(reopens))
        await expireWhileMuted(controller)
        // Dormant: audio keeps running, the uplink gate is closed, and microphone frames reach no connection
        #expect(audio.startCount == 1)
        #expect(audio.stopCount == 0)
        let firstSent = connection.sent.count
        let dormantFrame = try #require(audio.onFrame)
        dormantFrame(Self.frame)
        #expect(connection.sent.count == firstSent)
        #expect(second.sent.isEmpty)

        controller.toggleMute()
        second.continuation.yield(.ready)
        await waitStatus(controller, .listening)
        // The new driver's Ready only swaps the callback and does not start audio again
        #expect(audio.startCount == 1)
        #expect(audio.stopCount == 0)
        #expect(ended.errors.isEmpty)
        #expect(ended.value == nil)

        let onFrame = try #require(audio.onFrame)
        onFrame(Self.frame)
        #expect(second.sent == [Self.frame])
        #expect(connection.sent.count == firstSent)

        controller.end()
        #expect(audio.stopCount == 1)
        await controller.streamTask?.value
        #expect(audio.stopCount == 1)
        #expect(audio.startCount == 1)
    }

    // After session expiry the uplink callback is unbound until the reopened new driver is Ready, then bound again
    @Test func expired_unbinds_uplink_until_reopened_ready() async throws {
        let second = FakeConnection()
        let reopens = Reopens(.success(second))
        let controller = try start(reopener: try reopener(reopens))
        await expireWhileMuted(controller)
        let firstSent = connection.sent.count
        let onFrame = try #require(audio.onFrame)

        // Unmute: the uplink gate opens, but frames before the new connection is Ready reach neither the old nor the new connection
        controller.toggleMute()
        onFrame(Self.frame)
        while second.openCount == 0 { await Task.yield() }
        onFrame(Self.frame)
        #expect(connection.sent.count == firstSent)
        #expect(second.sent.isEmpty)

        second.continuation.yield(.ready)
        await waitStatus(controller, .listening)
        let rebound = try #require(audio.onFrame)
        rebound(Self.frame)
        #expect(second.sent == [Self.frame])
        #expect(connection.sent.count == firstSent)

        controller.end()
        await controller.streamTask?.value
    }

    @Test func reopen_failure_shows_error_and_ends() async throws {
        let reopens = Reopens(.failure(URLError(.notConnectedToInternet)))
        let controller = try start(reopener: try reopener(reopens))
        await expireWhileMuted(controller)

        controller.toggleMute()
        await ended.wait()
        #expect(reopens.calls == 1)
        #expect(ended.errors == ["URLError"])
        #expect(ended.value?.0 == .error)
        #expect(controller.statusKey == .error)
    }

    @Test func reopen_without_reopener_fails() async throws {
        let controller = try start()
        await expireWhileMuted(controller)

        controller.toggleMute()
        #expect(ended.errors == ["RealtimeReopenError"])
        #expect(ended.value?.0 == .error)
        #expect(controller.statusKey == .error)
    }

    @Test func end_user_writes_draft() async throws {
        let controller = try start()
        send(.ready)
        await waitStatus(controller, .listening)
        send(
            .userSpeechStarted(itemId: "u1"),
            .userTranscript(itemId: "u1", text: "Draft text ", final: false),
            .userSpeechStopped(itemId: "u1")
        )
        await waitStatus(controller, .thinking)
        controller.end()
        #expect(ended.value?.0 == .user)
        #expect(ended.value?.1 == "Draft text")
        #expect(sink.log.isEmpty)
        #expect(connection.closeCount >= 1)
        #expect(controller.statusKey == nil)
    }

    @Test func system_interruption_closes() async throws {
        let controller = try start()
        send(.ready)
        await waitStatus(controller, .listening)
        let onInterruption = try #require(audio.onInterruption)
        onInterruption()
        #expect(ended.value?.0 == .system)
        #expect(ended.value?.1 == nil)
        #expect(connection.closeCount >= 1)
        #expect(audio.stopCount >= 1)
        #expect(controller.statusKey == nil)
    }

    @Test func stream_finished_without_session_ended_is_system_interruption() async throws {
        let controller = try start()
        send(.ready)
        await waitStatus(controller, .listening)
        connection.continuation.finish()
        await ended.wait()
        #expect(ended.value?.0 == .system)
        #expect(ended.value?.1 == nil)
        #expect(ended.errors.isEmpty)
        #expect(connection.closeCount >= 1)
        #expect(controller.statusKey == nil)
    }

    /// No periodic tick: while idle only one one-shot timer up to idleEndMs is scheduled, and it ends the call once when it fires.
    @Test func no_periodic_tick_idle_ends_once_at_deadline() async throws {
        let controller = try start()
        #expect(clock.pendingDeadlines.isEmpty)
        send(.ready)
        await waitStatus(controller, .listening)
        let idle = RealtimeConversationLogic.Constants.idleEndMs
        #expect(clock.pendingDeadlines == [idle])
        clock.advance(idle - 1)
        #expect(clock.fired == 0)
        #expect(ended.value == nil)
        clock.advance(1)
        #expect(clock.fired == 1)
        #expect(ended.value?.0 == .idle)
        #expect(clock.pendingDeadlines.isEmpty)
        #expect(controller.statusKey == nil)
    }

    @Test func idle_tick_ends() async throws {
        let controller = try start()
        send(.ready)
        await waitStatus(controller, .listening)
        clock.advance(RealtimeConversationLogic.Constants.idleEndMs - 250)
        #expect(ended.value == nil)
        clock.advance(250)
        #expect(ended.value?.0 == .idle)
        #expect(connection.closeCount >= 1)
        #expect(controller.statusKey == nil)
        #expect(controller.level == 0)
    }

    // MARK: - Reopen on turn-boundary fingerprint change

    /// Replanner stand-in: records the call count and whether it was called on the main thread, returns a preset fingerprint.
    nonisolated final class Replans: @unchecked Sendable {
        private let lock = NSLock()
        private var next: RealtimeSessionFingerprint?
        private var count = 0
        private var main: [Bool] = []
        init(_ next: RealtimeSessionFingerprint?) { self.next = next }
        var calls: Int { lock.withLock { count } }
        var onMain: [Bool] { lock.withLock { main } }
        func callAsFunction() -> RealtimeSessionFingerprint? {
            let isMain = Thread.isMainThread
            return lock.withLock {
                count += 1
                main.append(isMain)
                return next
            }
        }
    }

    private static func replanner(_ replans: Replans) -> RealtimeVoiceConversationController.Replanner {
        { replans() }
    }

    /// One full exchange (no audio, the reply ends and goes straight back to listening): once the transcript is persisted the turn boundary is reached.
    private func completeTurn(_ controller: RealtimeVoiceConversationController) async {
        send(.ready)
        await waitStatus(controller, .listening)
        send(
            .userSpeechStarted(itemId: "u1"),
            .userSpeechStopped(itemId: "u1"),
            .userTranscript(itemId: "u1", text: "What changed?", final: true),
            .assistantTurnDone(itemId: "a1", status: .completed, text: "Nothing yet.")
        )
        await sink.waitCount(2)
    }

    @Test func turn_boundary_fingerprint_change_reopens_once() async throws {
        let second = FakeConnection()
        let reopens = Reopens(.success(second))
        let replans = Replans(RealtimeSessionFingerprint(instructionsSha256: "changed", lastHistoryId: nil))
        let controller = try start(reopener: try reopener(reopens), replanner: Self.replanner(replans))
        await completeTurn(controller)
        await controller.replanTask?.value
        // Fingerprint changed: close the old connection, reopen with the new plan; state is thinking until the new connection is ready
        #expect(replans.calls == 1)
        #expect(controller.statusKey == .thinking)
        #expect(connection.closeCount == 1)
        second.continuation.yield(.ready)
        await waitStatus(controller, .listening)
        #expect(reopens.calls == 1)
        #expect(second.openCount == 1)
        #expect(ended.value == nil)
        #expect(ended.errors.isEmpty)
        // The old connection's stream finishing neither ends the call nor stops the audio; uplink switches to the new connection
        #expect(audio.startCount == 1)
        #expect(audio.stopCount == 0)
        let onFrame = try #require(audio.onFrame)
        onFrame(Self.frame)
        #expect(second.sent == [Self.frame])
        #expect(connection.sent.isEmpty)
        // The new connection's ready is not a turn boundary: no further replan or reopen
        #expect(replans.calls == 1)
        #expect(reopens.calls == 1)
    }

    @Test func same_fingerprint_no_reopen() async throws {
        let plan = try Self.plan()
        let reopens = Reopens(.success(FakeConnection()))
        let replans = Replans(try #require(plan.plan.fingerprint))
        let controller = try start(reopener: try reopener(reopens), replanner: Self.replanner(replans), plan: plan)
        await completeTurn(controller)
        await controller.replanTask?.value
        #expect(replans.calls == 1)
        #expect(controller.statusKey == .listening)
        #expect(reopens.calls == 0)
        #expect(connection.closeCount == 0)
        #expect(ended.value == nil)
    }

    @Test func replan_runs_off_main() async throws {
        let replans = Replans(nil)
        let controller = try start(replanner: Self.replanner(replans))
        await completeTurn(controller)
        await controller.replanTask?.value
        #expect(replans.onMain == [false])
        // Planning failed (nil): no reopen
        #expect(controller.statusKey == .listening)
    }
}
