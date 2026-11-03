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
        /// Played ms set per item; an item without one reports played (under idealPlayback it reports the samples received).
        var playedByItem: [String: Int] = [:]
        /// Ideal player: each item reports ⌊received samples × 1000 ÷ 24 kHz⌋ ms (replayed as voice-contracts-check does).
        var idealPlayback = false
        var earcons: [VoiceConversationLogic.Earcon] = []
        var onFrame: ((Data) -> Void)?
        /// Uplink sample rate received by the latest startRealtime (the transport's declared value).
        var uplinkSampleRate: Double?
        var onInterruption: (() -> Void)?
        var onPlaybackDrained: (() -> Void)?
        /// In production this is the per-buffer dBFS of mainMixer output (main actor); tests call it directly to feed the playback level.
        var onOutputLevel: ((Double) -> Void)?
        /// Current output route (production reads engine.route); defaults to loudspeaker.
        var route: VoiceConversationLogic.Route = .speaker
        /// In production this is the routeChange notification (main actor); cases trigger it via changeRoute.
        var onRouteChanged: ((VoiceConversationLogic.Route) -> Void)?
        /// Switches the output route mid-session: changes the current route first, then calls back, same as the production engine.
        func changeRoute(_ newRoute: VoiceConversationLogic.Route) {
            route = newRoute
            onRouteChanged?(newRoute)
        }
        /// Downlink reference level (production reads the downlink block dB at the playhead); the uplink gate reads it on the thread that feeds frames, and cases set it before feeding frames.
        nonisolated(unsafe) var ref: Double?
        private var playbackStopped = false
        var stopCount: Int { log.filter { $0 == "stopRealtime" }.count }
        var startCount: Int { log.filter { $0 == "startRealtime" }.count }

        /// Number of times prepareSession was called (not logged, so existing order assertions are not changed).
        private(set) var prepareCount = 0

        /// Matches real audio: startRealtime after stopRealtime throws (one-shot semantics).
        struct StartAfterStop: Error {}

        func prepareSession() async throws {
            prepareCount += 1
        }

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
        /// Injection for capture-start failure when re-opening capture: if set, startRealtimeCapture throws it.
        var captureError: Error?
        /// playback-only start: does not create capture (onFrame not set); logged but not counted in startCount.
        func startRealtimePlayback(onInterruption: @escaping () -> Void) throws {
            log.append("startRealtimePlayback")
            if stopCount > 0 { throw StartAfterStop() }
            self.onInterruption = onInterruption
        }
        func startRealtimeCapture(uplinkSampleRate: Double, onFrame: @escaping (Data) -> Void) throws {
            self.uplinkSampleRate = uplinkSampleRate
            log.append("startRealtimeCapture")
            if let captureError { throw captureError }
            self.onFrame = onFrame
        }
        func enqueue(pcm16: Data, itemId: String) {
            log.append("enqueue:\(itemId)")
            enqueued.append((pcm16, itemId))
            if !pcm16.isEmpty { playbackStopped = false }
        }
        func playedMs(itemId: String) -> Int {
            log.append("playedMs:\(itemId)")
            if let ms = playedByItem[itemId] { return ms }
            guard idealPlayback else { return played }
            let samples = enqueued.filter { $0.1 == itemId }.reduce(0) { $0 + $1.0.count / 2 }
            return samples * 1000 / Int(RealtimePCM.sampleRate)
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
        nonisolated func playbackReferenceDb(behindSamples: [Int]) -> [Double?] { behindSamples.map { _ in ref } }
        /// The downlink queue finishes playing naturally (not via stopping): calls back once when done, same as the real player.
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
        var texts: [String] = []
        /// Order of truncate / sendText.
        var controlOrder: [String] = []
        func sendText(_ text: String) {
            texts.append(text)
            controlOrder.append("text:\(text)")
        }
        func truncate(itemId: String?, contentIndex: Int, playedMs: Double) {
            truncates.append((itemId, playedMs))
            controlOrder.append("truncate:\(itemId ?? "nil")")
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
        connection: FakeConnection? = nil,
        speechModel: FakeSpeechModel? = nil,
        speechModelLoader: RealtimeSpeechProbLoading.Loader? = nil,
        failureContext: RealtimeFailureContext = RealtimeFailureContext(),
        catalogCheck: RealtimeVoiceConversationController.CatalogCheck? = nil,
        autoStart: Bool = true
    ) throws -> RealtimeVoiceConversationController {
        let ended = ended
        let box = speechModel.map(RealtimeSpeechProbBox.init(model:))
        let controller = RealtimeVoiceConversationController(
            connection: connection ?? self.connection, audio: audio, plan: try plan ?? Self.plan(), sink: sink, clock: clock,
            reopener: reopener,
            replanner: replanner,
            catalogCheck: catalogCheck,
            // By default no voice-activity model (energy gate); model-mode cases inject a fake model
            speechModel: speechModelLoader ?? box.map { box in { box.model } },
            failureContext: failureContext,
            onError: { ended.errors.append($0) },
            onEnded: { reason, draft in ended.record(reason, draft) }
        )
        if autoStart { controller.start() }
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
        // : max_duration / timeout ends are wrapped up as errors (showError(max_duration))
        #expect(ended.value?.0 == .error)
        #expect(ended.errors == ["max_duration"])
        #expect(connection.closeCount >= 1)
        #expect(controller.statusKey == .error)
    }

    /// : the session ends while ready has arrived but not yet been handled (connection already closed); a late ready does not prepare a session or start the engine.
    @Test func late_ready_after_close_skips_prepare_and_start() async throws {
        let controller = try start()
        send(.ready)
        // Ends synchronously on the main actor: the driver has not yet handled the queued ready.
        controller.end()
        await ended.wait()
        await controller.streamTask?.value
        #expect(connection.closeCount >= 1)
        #expect(audio.prepareCount == 0)
        #expect(audio.startCount == 0)
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

    /// Card iL: within one uplink level window (7 frames × 10 ms) only the first frame is loud; the published value is that frame's dB (relative to −50 noise floor), not the window's average energy.
    @Test func uplink_window_publishes_loudest_frame() async throws {
        let controller = try start()
        send(.ready)
        await waitStatus(controller, .listening)
        let onFrame = try #require(audio.onFrame)
        let loud = Self.frame(amplitude: 0.05)
        onFrame(loud)
        for _ in 1..<Self.framesPerLevel { onFrame(Self.frame(amplitude: 0.005)) }

        let samples = (0..<240).map { Float(sin(Double($0) * 0.2)) * 0.05 }
        let expected = ConversationAudioMath.level(db: ConversationAudioMath.dbfs(samples), floorDb: ConversationAudioMath.aiFloorDb)
        #expect(expected > 0.4 && expected < 0.6)
        #expect(abs(controller.level - expected) < 1e-3)
    }

    /// Card iL: the speaking level takes the peak within the window of the real downlink playback output: silent output is 0, at most about 15 times per second; while listening the output level does not drive the orb.
    @Test func speaking_level_follows_played_output() async throws {
        let controller = try start()
        send(.ready)
        await waitStatus(controller, .listening)
        let output = try #require(audio.onOutputLevel)
        output(-26)
        #expect(controller.level == 0)

        clock.nowMs += 100
        send(.assistantAudio(itemId: "msg_1", contentIndex: 0, base64: "AQIDBA==", sampleRateHz: 24_000))
        await waitStatus(controller, .speaking)
        output(ConversationAudioMath.silenceDb)
        #expect(controller.level == 0)

        var published: [Double] = []
        let subscription = controller.$level.dropFirst().sink { published.append($0) }
        // 1 s of output, one block every 20 ms; only one block per 80 ms window is loud, and loudness increases window by window.
        for index in 0..<50 {
            clock.nowMs += 20
            output(index % 4 == 1 ? -40 + Double(index) / 2 : ConversationAudioMath.silenceDb)
        }
        subscription.cancel()
        #expect(!published.isEmpty)
        #expect(published.count <= Int(DictationLevelMeter.maxUpdatesPerSecond))
        #expect(published == published.sorted())
        // The peak of the last full window is block 45: −40 + 22.5 = −17.5 dBFS.
        #expect(abs(controller.level - ConversationAudioMath.level(db: -17.5, floorDb: ConversationAudioMath.aiFloorDb)) < 1e-9)
    }

    @Test func tap_orb_calls_interrupt_playback() async throws {
        let controller = try start()
        audio.played = 900
        send(.ready, .assistantAudio(itemId: "msg_1", contentIndex: 0, base64: "AQIDBA==", sampleRateHz: 24_000))
        await waitStatus(controller, .speaking)
        // The speaking level comes from the real playback output: −26 dBFS relative to the −50 floor → (24 − 6) / 30.
        let output = try #require(audio.onOutputLevel)
        output(-26)
        #expect(abs(controller.level - 0.6) < 1e-9)
        #expect(audio.isPlaying)

        controller.tapOrb()
        #expect(Array(audio.log.suffix(2)) == ["playedMs:msg_1", "stopPlayback"])
        #expect(connection.truncates.count == 1)
        #expect(connection.truncates.first?.0 == "msg_1")
        #expect(connection.truncates.first?.1 == 900)
        #expect(controller.statusKey == .listening)
    }

    @Test func typed_text_cold_starts_playback_only_and_sends_after_ready() async throws {
        let controller = try start(autoStart: false)
        #expect(connection.openCount == 0)
        controller.sendTypedText(" Hello ")
        // Not connected: opens the session playback-only; text is only queued and not sent before ready (GA would drop it) nor persisted
        #expect(connection.openCount == 1)
        #expect(sink.log.isEmpty)
        #expect(connection.texts.isEmpty)

        send(.ready, .assistantAudio(itemId: "a1", contentIndex: 0, base64: "AQIDBA==", sampleRateHz: 24_000))
        await waitStatus(controller, .speaking)
        #expect(connection.texts == ["Hello"])
        #expect(audio.prepareCount == 1)
        #expect(audio.log.filter { $0 == "startRealtimePlayback" }.count == 1)
        #expect(audio.startCount == 0)
        #expect(!audio.log.contains("startRealtimeCapture"))
        #expect(audio.onFrame == nil)
        #expect(sink.log == ["user:Hello"])
    }

    @Test func typed_text_when_connected_sends_immediately() async throws {
        let controller = try start()
        send(.ready)
        await waitStatus(controller, .listening)
        controller.sendTypedText("Hi there")
        #expect(connection.texts == ["Hi there"])
        #expect(sink.log == ["user:Hi there"])
        #expect(controller.statusKey == .thinking)
        // Already in a voice session: does not open another connection or restart audio
        #expect(connection.openCount == 1)
        #expect(audio.startCount == 1)
        #expect(!audio.log.contains("startRealtimePlayback"))
        // Blank: not sent, not persisted
        controller.sendTypedText("   ")
        #expect(connection.texts == ["Hi there"])
        #expect(sink.log == ["user:Hi there"])
    }

    @Test func typed_text_while_speaking_truncates_then_sends() async throws {
        let controller = try start()
        audio.played = 900
        send(.ready, .assistantAudio(itemId: "msg_1", contentIndex: 0, base64: "AQIDBA==", sampleRateHz: 24_000))
        await waitStatus(controller, .speaking)
        #expect(audio.isPlaying)

        controller.sendTypedText("Stop")
        #expect(Array(audio.log.suffix(2)) == ["playedMs:msg_1", "stopPlayback"])
        #expect(connection.truncates.count == 1)
        #expect(connection.truncates.first?.0 == "msg_1")
        #expect(connection.truncates.first?.1 == 900)
        #expect(connection.controlOrder == ["truncate:msg_1", "text:Stop"])
        #expect(sink.log.filter { $0.hasPrefix("user:") } == ["user:Stop"])
        #expect(controller.statusKey == .thinking)
    }

    @Test func typed_text_persists_once_via_sink() async throws {
        let controller = try start()
        send(.ready)
        await waitStatus(controller, .listening)
        controller.sendTypedText("Once")
        // Already ready: persisted at the same moment it is sent
        #expect(sink.log == ["user:Once"])
        #expect(connection.texts == ["Once"])
        send(
            .assistantTranscript(itemId: "a1", text: "Sure", final: false),
            .assistantTurnDone(itemId: "a1", status: .completed, text: "Sure")
        )
        await sink.waitCount(2)
        await waitStatus(controller, .listening)
        #expect(sink.log == ["user:Once", "assistant:Sure"])
        #expect(connection.texts == ["Once"])
    }

    @Test func playback_only_session_idle_ends_after_120s() async throws {
        let controller = try start(autoStart: false)
        controller.sendTypedText("Hello")
        send(
            .ready,
            .assistantTranscript(itemId: "a1", text: "Hi", final: false),
            .assistantTurnDone(itemId: "a1", status: .completed, text: "Hi")
        )
        await sink.waitCount(2)
        await waitStatus(controller, .listening)
        let idle = RealtimeConversationLogic.Constants.idleEndMs
        clock.advance(idle - 1)
        #expect(ended.value == nil)
        clock.advance(1)
        #expect(ended.value?.0 == .idle)
        #expect(audio.startCount == 0)
        #expect(audio.stopCount == 1)
    }

    @Test func reopen_keeps_playback_only_mode() async throws {
        let second = FakeConnection()
        let reopens = Reopens(.success(second))
        let controller = try start(reopener: try reopener(reopens), autoStart: false)
        controller.sendTypedText("Hello")
        send(
            .ready,
            .assistantTranscript(itemId: "a1", text: "Hi", final: false),
            .assistantTurnDone(itemId: "a1", status: .completed, text: "Hi")
        )
        await sink.waitCount(2)
        await waitStatus(controller, .listening)
        // Closed with 1008 while speaking: the call does not end, a new connection is opened with history through the current reopener path
        send(.userSpeechStarted(itemId: "u1"))
        let firstStream = controller.streamTask
        connection.continuation.finish(throwing: Self.expired)
        await firstStream?.value
        #expect(controller.statusKey == .thinking)

        second.continuation.yield(.ready)
        await waitStatus(controller, .listening)
        #expect(reopens.calls == 1)
        #expect(second.openCount == 1)
        // The new driver keeps playback-only: does not open the mic and does not start capture again; audio is not restarted
        #expect(audio.log.filter { $0 == "startRealtimePlayback" }.count == 1)
        #expect(audio.startCount == 0)
        #expect(!audio.log.contains("startRealtimeCapture"))
        #expect(audio.stopCount == 0)
        controller.sendTypedText("Again")
        #expect(second.texts == ["Again"])
        #expect(connection.texts == ["Hello"])
    }

    /// Typed during re-open: while the reopener projects history this sentence has not been persisted yet; sent once after the new connection is ready and persisted once, so the model does not receive it twice.
    @Test func reopen_queued_typed_text_persists_after_ready_once() async throws {
        let second = FakeConnection()
        let gate = ReopenGate()
        let plan = try Self.plan()
        let sink = sink
        let reopener: RealtimeVoiceConversationController.Reopener = { @MainActor in
            await gate.wait()
            gate.logAtReopen = sink.log
            return (connection: second, plan: plan)
        }
        let controller = try start(reopener: reopener)
        send(.ready)
        await waitStatus(controller, .listening)
        let firstStream = controller.streamTask
        connection.continuation.finish(throwing: Self.expired)
        await firstStream?.value
        #expect(controller.statusKey == .thinking)

        controller.sendTypedText("Queued")
        #expect(connection.texts.isEmpty)
        #expect(sink.log.isEmpty)
        gate.open()
        second.continuation.yield(.ready)
        await sink.waitCount(1)
        #expect(gate.logAtReopen == [])
        #expect(second.texts == ["Queued"])
        #expect(connection.texts.isEmpty)
        #expect(sink.log == ["user:Queued"])
    }

    /// Reopener gate: the reopener does not return until the test releases it.
    @MainActor final class ReopenGate {
        private var opened = false
        private var waiter: CheckedContinuation<Void, Never>?
        /// The moment the reopener returns (projecting history) and the sink has already received.
        var logAtReopen: [String]?
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func open() {
            opened = true
            waiter?.resume()
            waiter = nil
        }
    }

    // MARK: -  resume capture when switching back to voice

    struct CaptureFailed: Error {}

    /// The playback-only session opened by typing enters listening (the Hello turn has finished).
    private func playbackOnlyListening() async throws -> RealtimeVoiceConversationController {
        let controller = try start(autoStart: false)
        controller.sendTypedText("Hello")
        send(
            .ready,
            .assistantTranscript(itemId: "a1", text: "Hi", final: false),
            .assistantTurnDone(itemId: "a1", status: .completed, text: "Hi")
        )
        await sink.waitCount(2)
        await waitStatus(controller, .listening)
        return controller
    }

    @Test func resume_voice_capture_starts_capture_on_same_connection() async throws {
        let controller = try await playbackOnlyListening()
        #expect(audio.onFrame == nil)
        controller.resumeVoiceCapture()
        // Capture is started on the same connection: no reconnection, no audio restart
        #expect(audio.log.filter { $0 == "startRealtimeCapture" }.count == 1)
        #expect(connection.openCount == 1)
        #expect(connection.closeCount == 0)
        #expect(audio.startCount == 0)
        #expect(audio.stopCount == 0)
        #expect(controller.statusKey == .listening)
        // Uplink is attached to the current connection
        let onFrame = try #require(audio.onFrame)
        onFrame(Self.frame)
        #expect(!connection.sent.isEmpty)
        #expect(ended.value == nil)
        // Already started: calling again does nothing
        controller.resumeVoiceCapture()
        #expect(audio.log.filter { $0 == "startRealtimeCapture" }.count == 1)
    }

    @Test func resume_voice_capture_while_speaking_truncates_first() async throws {
        let controller = try start(autoStart: false)
        audio.played = 900
        controller.sendTypedText("Hello")
        send(.ready, .assistantAudio(itemId: "msg_1", contentIndex: 0, base64: "AQIDBA==", sampleRateHz: 24_000))
        await waitStatus(controller, .speaking)
        #expect(audio.isPlaying)

        controller.resumeVoiceCapture()
        // Same conventions as the tap-ball interruption: first read the played ms, stop playback, truncate, then start capture
        #expect(Array(audio.log.suffix(3)) == ["playedMs:msg_1", "stopPlayback", "startRealtimeCapture"])
        #expect(connection.truncates.count == 1)
        #expect(connection.truncates.first?.0 == "msg_1")
        #expect(connection.truncates.first?.1 == 900)
        #expect(controller.statusKey == .listening)
        #expect(connection.openCount == 1)
    }

    /// Fixture backToStage while_speaking_interrupts: returning to the voice dock while the AI is playing interrupts it: stop playback, by played ms
    /// truncate, back to listening; capture is started on the same connection; late-arriving audio from the interrupted reply is no longer queued for playback.
    @Test func back_to_stage_while_speaking_interrupts() async throws {
        let controller = try start(autoStart: false)
        audio.played = 600
        controller.sendTypedText("Hello")
        send(.ready, .assistantAudio(itemId: "msg_1", contentIndex: 0, base64: "AQIDBA==", sampleRateHz: 24_000))
        await waitStatus(controller, .speaking)
        #expect(audio.isPlaying)
        #expect(connection.truncates.isEmpty)

        controller.resumeVoiceCapture()
        #expect(!audio.isPlaying)
        #expect(connection.truncates.count == 1)
        #expect(connection.truncates.first?.0 == "msg_1")
        #expect(connection.truncates.first?.1 == 600)
        #expect(controller.statusKey == .listening)
        #expect(connection.openCount == 1)
        #expect(connection.closeCount == 0)
        #expect(ended.value == nil)

        // The late audio chunk from the interrupted reply: no longer played.
        let enqueued = audio.log.filter { $0 == "enqueue:msg_1" }.count
        send(.assistantAudio(itemId: "msg_1", contentIndex: 0, base64: "AQIDBA==", sampleRateHz: 24_000))
        await Task.yield()
        #expect(audio.log.filter { $0 == "enqueue:msg_1" }.count == enqueued)
        #expect(controller.statusKey == .listening)
    }

    @Test func resume_voice_capture_failure_ends_session() async throws {
        let controller = try await playbackOnlyListening()
        audio.captureError = CaptureFailed()
        controller.resumeVoiceCapture()
        // If resuming capture fails the session ends
        await ended.wait()
        #expect(ended.value?.0 == .system)
        #expect(connection.closeCount >= 1)
        #expect(audio.stopCount >= 1)
        #expect(controller.statusKey == nil)
    }

    @Test func resume_voice_capture_noop_when_capturing() async throws {
        // The voice-opened session is already capturing
        let voice = try start()
        send(.ready)
        await waitStatus(voice, .listening)
        voice.resumeVoiceCapture()
        #expect(!audio.log.contains("startRealtimeCapture"))
        #expect(audio.startCount == 1)
        #expect(connection.closeCount == 0)
        #expect(voice.statusKey == .listening)
    }

    /// 1 s of 24 kHz downlink and an eight-word reply: the revealed prefix follows the played ratio.
    private static let secondOfAudio = Data(count: 48_000).base64EncodedString()
    private static let countReply = "one two three four five six seven eight"

    private static func prefix(playedMs: Int) -> String {
        RealtimeConversationLogic.revealPrefix(text: countReply, playedMs: playedMs, audioSamples: 24_000, sampleRateHz: 24_000)
    }

    /// The user finishes speaking this turn; the assistant reply starts playing (transcription arrives first).
    private func startReply(_ controller: RealtimeVoiceConversationController) async {
        send(
            .ready, .userSpeechStarted(itemId: "u1"), .userSpeechStopped(itemId: "u1"),
            .userTranscript(itemId: "u1", text: "Count please", final: true),
            .assistantTranscript(itemId: "msg_1", text: Self.countReply, final: false),
            .assistantAudio(itemId: "msg_1", contentIndex: 0, base64: Self.secondOfAudio, sampleRateHz: 24_000)
        )
        await waitStatus(controller, .speaking)
    }

    /// Speaking: once every 100 ms a one-shot beat reads the player and sends progress; leaving speaking leaves no beat.
    @Test func speaking_reports_progress_on_beat() async throws {
        let controller = try start()
        await startReply(controller)
        let beat = RealtimeVoiceConversationController.progressBeatMs
        let start = clock.nowMs
        #expect(clock.pendingDeadlines.contains(start + beat))
        let reads = { self.audio.log.filter { $0 == "playedMs:msg_1" }.count }
        let before = reads()
        audio.playedByItem["msg_1"] = 600
        clock.advance(beat)
        #expect(reads() == before + 1)
        #expect(clock.pendingDeadlines.contains(start + 2 * beat))

        // The 600 sent by the beat only increases and never decreases: on interruption it freezes at 600 even if the player reports less.
        audio.playedByItem["msg_1"] = 300
        controller.tapOrb()
        #expect(controller.statusKey == .listening)
        #expect(!clock.pendingDeadlines.contains(start + 2 * beat))
        send(.assistantTurnDone(itemId: "msg_1", status: .completed, text: Self.countReply))
        await sink.waitCount(2)
        let expected = Self.prefix(playedMs: 600)
        #expect(!expected.isEmpty && expected != Self.countReply && expected != Self.prefix(playedMs: 300))
        #expect(sink.log == ["user:Count please", "assistant:\(expected)"])
    }

    /// Before a tap-to-interrupt, one extra progress is sent first; what freezes is the real played amount now (not the previous beat).
    @Test func tap_orb_reports_progress_before_freeze() async throws {
        let controller = try start()
        await startReply(controller)
        audio.playedByItem["msg_1"] = 500
        controller.tapOrb()
        send(.assistantTurnDone(itemId: "msg_1", status: .completed, text: Self.countReply))
        await sink.waitCount(2)
        let expected = Self.prefix(playedMs: 500)
        #expect(!expected.isEmpty && expected != Self.countReply)
        #expect(sink.log == ["user:Count please", "assistant:\(expected)"])
    }

    /// Before ending, one extra progress is sent first; the reply finishing playback is persisted by the real played amount; no beat is left after ending.
    @Test func end_reports_progress_before_flush() async throws {
        let controller = try start()
        await startReply(controller)
        send(.assistantTurnDone(itemId: "msg_1", status: .completed, text: Self.countReply))
        while controller.eventsReceivedForTesting < 7 { await Task.yield() }
        audio.playedByItem["msg_1"] = 400
        controller.end()
        await ended.wait()
        let expected = Self.prefix(playedMs: 400)
        #expect(!expected.isEmpty && expected != Self.countReply)
        #expect(sink.log == ["user:Count please", "assistant:\(expected)"])
        #expect(clock.pendingDeadlines.isEmpty)
    }

    private func waitCaption(_ controller: RealtimeVoiceConversationController, _ caption: String?) async {
        for await value in controller.$caption.values where value == caption { return }
    }

    ///  · : no text while speaking takes no space, and text appears only when it exists; while the AI speaks the subtitle reveals by played ratio, and after interruption returns to the user's subtitle.
    @Test func caption_follows_user_transcript_then_assistant_reveal() async throws {
        let controller = try start()
        send(.ready, .userSpeechStarted(itemId: "u1"))
        while controller.eventsReceivedForTesting < 2 { await Task.yield() }
        #expect(controller.caption == nil)
        #expect(controller.drafts.user == nil)

        send(.userTranscript(itemId: "u1", text: " Count ", final: false))
        await waitCaption(controller, "Count")
        #expect(controller.drafts.user == "Count")

        send(
            .userSpeechStopped(itemId: "u1"),
            .userTranscript(itemId: "u1", text: "Count please", final: true),
            .assistantTranscript(itemId: "msg_1", text: Self.countReply, final: false),
            .assistantAudio(itemId: "msg_1", contentIndex: 0, base64: Self.secondOfAudio, sampleRateHz: 24_000)
        )
        await waitStatus(controller, .speaking)
        // Not yet played out loud: the AI subtitle is empty and the voice dock shows the status line.
        #expect(controller.caption == nil)
        #expect(controller.drafts.user == nil)
        #expect(controller.drafts.assistant == nil)

        audio.playedByItem["msg_1"] = 500
        clock.advance(RealtimeVoiceConversationController.progressBeatMs)
        let revealed = Self.prefix(playedMs: 500)
        #expect(!revealed.isEmpty && revealed != Self.countReply)
        #expect(controller.caption == revealed)
        #expect(controller.drafts.assistant == revealed)

        // : before interruption, read the played amount once more and freeze it; back to listening, the subtitle is no longer the AI's text, the bubble keeps the frozen segment and no longer reveals afterwards.
        audio.playedByItem["msg_1"] = 700
        controller.tapOrb()
        let frozen = Self.prefix(playedMs: 700)
        #expect(frozen != revealed && frozen != Self.countReply)
        #expect(controller.statusKey == .listening)
        #expect(controller.caption == nil)
        #expect(controller.drafts.assistant == frozen)
        audio.playedByItem["msg_1"] = 1000
        clock.advance(RealtimeVoiceConversationController.progressBeatMs)
        #expect(controller.drafts.assistant == frozen)
    }

    ///  · : the stage line uses stageLine — user subtitle → status line (AI speaking, no text yet) → revealed text → interruption returns to the status line; empty when ended.
    @Test func stage_line_shows_user_caption_reveal_or_status() async throws {
        let controller = try start()
        send(.ready, .userSpeechStarted(itemId: "u1"), .userTranscript(itemId: "u1", text: " Count ", final: false))
        await waitCaption(controller, "Count")
        #expect(controller.stageLine == .user("Count"))

        send(
            .userSpeechStopped(itemId: "u1"),
            .userTranscript(itemId: "u1", text: "Count please", final: true),
            .assistantTranscript(itemId: "msg_1", text: Self.countReply, final: false),
            .assistantAudio(itemId: "msg_1", contentIndex: 0, base64: Self.secondOfAudio, sampleRateHz: 24_000)
        )
        await waitStatus(controller, .speaking)
        #expect(controller.stageLine == .status(key: "speaking"))
        #expect(controller.caption == nil)

        audio.playedByItem["msg_1"] = 500
        clock.advance(RealtimeVoiceConversationController.progressBeatMs)
        let revealed = Self.prefix(playedMs: 500)
        #expect(!revealed.isEmpty)
        #expect(controller.stageLine == .assistant(revealed))
        #expect(controller.caption == revealed)

        controller.tapOrb()
        #expect(controller.stageLine == .status(key: "listening"))
        #expect(controller.caption == nil)

        controller.end()
        await ended.wait()
        #expect(controller.stageLine == nil)
        #expect(controller.caption == nil)
    }

    /// : in the reduce that emits persist, the bubble on that side is cleared; the persisted count and text are carried out with the same value; both sides are empty after ending.
    @Test func drafts_clear_after_persist() async throws {
        let controller = try start()
        await startReply(controller)
        #expect(controller.drafts.user == nil)
        #expect(controller.drafts.userPersisted == 1)
        #expect(controller.drafts.userPersistedText == "Count please")
        #expect(controller.drafts.assistantPersisted == 0)

        audio.playedByItem["msg_1"] = 500
        controller.tapOrb()
        let expected = Self.prefix(playedMs: 500)
        #expect(controller.drafts.assistant == expected)
        send(.assistantTurnDone(itemId: "msg_1", status: .completed, text: Self.countReply))
        await sink.waitCount(2)
        #expect(sink.log == ["user:Count please", "assistant:\(expected)"])
        #expect(controller.drafts == RealtimeDrafts(
            userPersisted: 1, assistantPersisted: 1, userPersistedText: "Count please", assistantPersistedText: expected
        ))

        controller.end()
        await ended.wait()
        #expect(controller.caption == nil)
        #expect(controller.drafts.user == nil && controller.drafts.assistant == nil)
        #expect(controller.drafts.assistantPersisted == 1)
    }

    /// : recomputed on every reduce, but not re-emitted when the value is unchanged (a beat sending the same played ms does not trigger a refresh).
    @Test func caption_not_republished_when_unchanged() async throws {
        let controller = try start()
        await startReply(controller)
        var captions: [String?] = []
        var drafts: [RealtimeDrafts] = []
        let captionSubscription = controller.$caption.dropFirst().sink { captions.append($0) }
        let draftsSubscription = controller.$drafts.dropFirst().sink { drafts.append($0) }
        let beat = RealtimeVoiceConversationController.progressBeatMs
        clock.advance(beat)
        audio.playedByItem["msg_1"] = 500
        clock.advance(beat)
        clock.advance(beat)
        clock.advance(beat)
        captionSubscription.cancel()
        draftsSubscription.cancel()
        let revealed = Self.prefix(playedMs: 500)
        #expect(captions == [revealed])
        #expect(drafts.map(\.assistant) == [revealed])
    }

    @Test func playback_drained_from_audio_idle() async throws {
        let controller = try start()
        send(
            .ready,
            .assistantAudio(itemId: "msg_1", contentIndex: 0, base64: "AQIDBA==", sampleRateHz: 24_000),
            .assistantTurnDone(itemId: "msg_1", status: .completed, text: "Done")
        )
        await waitStatus(controller, .speaking)
        clock.advance(250)
        #expect(controller.statusKey == .speaking)
        // : the reply completes during playback and is persisted only after playback finishes.
        #expect(sink.log.isEmpty)

        // The playhead has never moved (the player has not started) is not counted as a stall: after playback only the player's callback is awaited.
        audio.finishPlayback()
        await sink.waitCount(1)
        #expect(sink.log == ["assistant:Done"])
        #expect(controller.statusKey == .listening)
        #expect(controller.displayState == .listening)
    }

    /// ⑩ (same as Android A16): the reply completed, the playhead moved then stopped, and the finished callback never comes; a stall lasting drainStallMs counts as finished playing, and the full text is persisted.
    @Test func stalled_tail_after_turn_done_persists_full_text() async throws {
        let controller = try start()
        audio.played = 80
        send(
            .ready,
            .assistantAudio(itemId: "msg_1", contentIndex: 0, base64: "AQIDBA==", sampleRateHz: 24_000),
            .assistantTurnDone(itemId: "msg_1", status: .completed, text: "all of it")
        )
        // Advance the clock only after all three events have entered the controller (reply completed); otherwise the stall timer has not started.
        while controller.eventsReceivedForTesting < 3 { await Task.yield() }
        #expect(controller.statusKey == .speaking)
        clock.advance(RealtimeVoiceConversationController.progressBeatMs)
        clock.advance(RealtimeVoiceConversationController.drainStallMs - 100)
        #expect(sink.log.isEmpty)
        #expect(controller.statusKey == .speaking)

        clock.advance(RealtimeVoiceConversationController.progressBeatMs)
        await sink.waitCount(1)
        // Not truncated by played ratio; the stuck tail is stopped and the next turn does not inherit "playing".
        #expect(sink.log == ["assistant:all of it"])
        #expect(audio.log.contains("stopPlayback"))
        #expect(controller.statusKey == .listening)
    }

    /// During the reply only empty PCM is queued: the player never started, so it will not call back on finish; at replyDone the played amount is read as empty, and playbackDrained is dispatched on the spot.
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

    /// After a stop-playback on interruption, the old reply's late finished callback: the new reply still has audio queued, so do not wrap up by it.
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
        await waitStatus(controller, .speaking)
        // : msg_2 is still playing and is persisted only after playback finishes.
        #expect(sink.log.isEmpty)
        #expect(audio.isPlaying)

        // Late callback for the segment before stop-playback (the player is still playing msg_2).
        audio.onPlaybackDrained?()
        #expect(controller.statusKey == .speaking)

        audio.finishPlayback()
        await sink.waitCount(1)
        #expect(sink.log == ["assistant:Second"])
        #expect(controller.statusKey == .listening)
    }

    // MARK: -  typing after ending realtime: the assistant reply is persisted when playback finishes

    /// A single turn of audio-carrying reply in a playback-only session: after the finished callback, the assistant is persisted.
    private func typedReplyDrains(
        _ controller: RealtimeVoiceConversationController,
        connection: FakeConnection, audio: FakeAudio, sink: FakeSink, base: Int
    ) async {
        controller.sendTypedText("Hello")
        for event: RealtimeSessionEvent in [
            .ready,
            .assistantAudio(itemId: "a1", contentIndex: 0, base64: "AQIDBA==", sampleRateHz: 24_000),
            .assistantTranscript(itemId: "a1", text: "Hi", final: false),
            .assistantTurnDone(itemId: "a1", status: .completed, text: "Hi"),
        ] { connection.continuation.yield(event) }
        await waitStatus(controller, .speaking)
        await sink.waitCount(base + 1)
        #expect(audio.isPlaying)
        audio.finishPlayback()
        await sink.waitCount(base + 2)
        #expect(Array(sink.log.suffix(2)) == ["user:Hello", "assistant:Hi"])
        #expect(controller.statusKey == .listening)
    }

    @Test func typed_only_reply_with_audio_persists_after_drain() async throws {
        let controller = try start(autoStart: false)
        await typedReplyDrains(controller, connection: connection, audio: audio, sink: sink, base: 0)
        #expect(sink.log == ["user:Hello", "assistant:Hi"])
    }

    /// One voice turn, then end realtime; then typing starts a new session from the host (new connection, new audio, same as production makeAudio); the reply is still persisted when playback finishes.
    @Test func typed_after_stop_reopens_and_persists_reply() async throws {
        let first = try start()
        send(
            .ready,
            .assistantTranscript(itemId: "v1", text: "Voice", final: false),
            .assistantTurnDone(itemId: "v1", status: .completed, text: "Voice")
        )
        await sink.waitCount(1)
        first.end()
        await ended.wait()
        #expect(audio.stopCount == 1)

        let secondConnection = FakeConnection()
        let secondAudio = FakeAudio()
        let second = RealtimeVoiceConversationController(
            connection: secondConnection, audio: secondAudio, plan: try Self.plan(), sink: sink, clock: clock,
            speechModel: nil, onError: { _ in }, onEnded: { _, _ in }
        )
        await typedReplyDrains(second, connection: secondConnection, audio: secondAudio, sink: sink, base: 1)
        #expect(sink.log == ["assistant:Voice", "user:Hello", "assistant:Hi"])
        #expect(secondAudio.startCount == 0)
        #expect(secondAudio.log.contains("startRealtimePlayback"))
    }

    /// V-AD contract card item 4: during a screen-reader announcement the uplink pauses but is not counted as silence; silence takes priority; cancelling silence during an announcement only clears silence, and the uplink resumes only when the announcement ends.
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
        // Disconnected after connecting with no other signal: classified as unknown
        #expect(ended.errors == ["unknown"])
        #expect(controller.statusKey == .error)
    }

    @Test func failed_stream_shows_error_and_ends() async throws {
        let controller = try start()
        send(.ready)
        await waitStatus(controller, .listening)
        connection.continuation.finish(throwing: URLError(.networkConnectionLost))
        await ended.wait()
        #expect(ended.errors == ["unknown"])
        #expect(controller.failure?.classification.category == .unknown)
        #expect(ended.value?.0 == .error)
        #expect(ended.value?.1 == nil)
        #expect(controller.displayState == .error)
        #expect(controller.statusKey == .error)
        #expect(connection.closeCount >= 1)
    }

    // MARK: -  failures classified into 6 categories

    private static let failureContext = RealtimeFailureContext(providerName: "OpenAI", model: "gpt-realtime", maxSessionSec: 2)

    /// Handshake rejected (not ready): classified by HTTP status; the failure object carries the copy key, placeholder values, and the recovery path.
    private func handshakeRejected(_ status: Int) async throws -> RealtimeVoiceConversationController {
        let controller = try start(failureContext: Self.failureContext)
        connection.continuation.finish(throwing: RealtimeHandshakeError(httpStatus: status))
        await ended.wait()
        #expect(ended.value?.0 == .error)
        #expect(controller.statusKey == .error)
        return controller
    }

    @Test func handshake_401_is_auth() async throws {
        let controller = try await handshakeRejected(401)
        #expect(ended.errors == ["auth"])
        let failure = try #require(controller.failure)
        #expect(failure.classification.copyKey == "voice_realtime_failure_auth")
        #expect(failure.classification.actions == [.openConnection])
        #expect(failure.copyArgValue == "OpenAI")
    }

    @Test func handshake_429_is_quota() async throws {
        let controller = try await handshakeRejected(429)
        #expect(ended.errors == ["quota"])
        #expect(controller.failure?.classification.actions == [.retry, .switchModel])
        #expect(controller.failure?.copyArgValue == "OpenAI")
    }

    @Test func handshake_404_is_model_gone() async throws {
        let controller = try await handshakeRejected(404)
        #expect(ended.errors == ["model_gone"])
        #expect(controller.failure?.classification.actions == [.switchModel])
        #expect(controller.failure?.copyArgValue == "gpt-realtime")
    }

    @Test func gemini_socket_close_carries_http_status() async throws {
        let controller = try start(failureContext: Self.failureContext)
        connection.continuation.finish(throwing: GeminiLiveSocketClosed(code: 0, reason: nil, httpStatus: 403))
        await ended.wait()
        #expect(ended.errors == ["auth"])
        #expect(controller.failure?.classification.category == .auth)
    }

    @Test func connect_failure_before_ready_is_network() async throws {
        let controller = try start(failureContext: Self.failureContext)
        connection.continuation.finish(throwing: URLError(.cannotConnectToHost))
        await ended.wait()
        #expect(ended.errors == ["network"])
        #expect(controller.failure?.copyArgValue == "gpt-realtime")
    }

    // MARK: -  re-fetch the catalog after a failure

    /// Catalog re-fetch stand-in: records the number of calls, returns the preset result or throws.
    nonisolated final class CatalogChecks: @unchecked Sendable {
        struct FetchFailed: Error {}
        private let lock = NSLock()
        private var count = 0
        private let result: Result<Bool?, Error>
        init(_ result: Result<Bool?, Error>) { self.result = result }
        var calls: Int { lock.withLock { count } }
        var check: RealtimeVoiceConversationController.CatalogCheck {
            { [self] in
                lock.withLock { count += 1 }
                return try result.get()
            }
        }
    }

    @Test func handshake_failure_with_model_removed_from_catalog_is_model_gone() async throws {
        let checks = CatalogChecks(.success(false))
        let controller = try start(failureContext: Self.failureContext, catalogCheck: checks.check)
        connection.continuation.finish(throwing: URLError(.cannotConnectToHost))
        await ended.wait()
        // This connection was never ready: re-fetch the catalog; if the model has been delisted → model_gone (takes precedence over connectError's network)
        #expect(checks.calls == 1)
        #expect(ended.errors == ["model_gone"])
        #expect(controller.failure?.classification.category == .modelGone)
        #expect(controller.failure?.copyArgValue == "gpt-realtime")
    }

    @Test func failure_after_ready_does_not_refetch_catalog() async throws {
        let checks = CatalogChecks(.success(false))
        let controller = try start(failureContext: Self.failureContext, catalogCheck: checks.check)
        send(.ready)
        await waitStatus(controller, .listening)
        connection.continuation.finish(throwing: URLError(.networkConnectionLost))
        await ended.wait()
        // It was ready: does not re-fetch the catalog; classification is not affected by the catalog (no reopener, no handshake signal → unknown)
        #expect(checks.calls == 0)
        #expect(ended.errors == ["unknown"])
        #expect(controller.failure?.classification.category == .unknown)
    }

    @Test func catalog_refetch_error_leaves_signal_nil() async throws {
        let checks = CatalogChecks(.failure(CatalogChecks.FetchFailed()))
        let controller = try start(failureContext: Self.failureContext, catalogCheck: checks.check)
        connection.continuation.finish(throwing: URLError(.cannotConnectToHost))
        await ended.wait()
        // Re-fetch throws → catalogHasModel is nil, classified as a handshake failure → network
        #expect(checks.calls == 1)
        #expect(ended.errors == ["network"])
        #expect(controller.failure?.classification.category == .network)
    }

    @Test func error_event_code_classifies_next_close() async throws {
        let controller = try start(failureContext: Self.failureContext)
        send(.ready)
        await waitStatus(controller, .listening)
        // The unified error event itself is not fatal
        await sendAndWait(controller, .error(code: "insufficient_quota", message: "quota"))
        #expect(ended.value == nil)
        #expect(controller.statusKey == .listening)
        connection.continuation.finish(throwing: URLError(.networkConnectionLost))
        await ended.wait()
        #expect(ended.errors == ["quota"])
    }

    @Test func connected_past_max_session_sec_is_max_duration() async throws {
        let controller = try start(failureContext: Self.failureContext)
        send(.ready)
        await waitStatus(controller, .listening)
        clock.advance(2_000)
        connection.continuation.finish(throwing: URLError(.networkConnectionLost))
        await ended.wait()
        #expect(ended.errors == ["max_duration"])
        let failure = try #require(controller.failure)
        #expect(failure.classification.actions == [.continueWithHistory])
        #expect(failure.copyArgValue == nil)
    }

    @Test func connected_under_max_session_sec_is_not_max_duration() async throws {
        let controller = try start(failureContext: Self.failureContext)
        send(.ready)
        await waitStatus(controller, .listening)
        clock.advance(1_999)
        connection.continuation.finish(throwing: URLError(.networkConnectionLost))
        await ended.wait()
        #expect(ended.errors == ["unknown"])
        #expect(controller.failure?.classification.category == .unknown)
    }

    // MARK: - Closeout AK · contract card B item 2 session expired

    /// Reopener stand-in: records the number of calls, returns a new connection or throws as needed.
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

    /// While muted, the first connection ends with sessionExpired, and waits for the controller to dispatch the stream's last input (entering dormancy).
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
        // No reopening during dormancy
        #expect(reopens.calls == 0)

        // Unmute: the reducer emits reopen + starts uplink; state returns to thinking until the new connection is ready
        controller.toggleMute()
        #expect(controller.statusKey == .thinking)
        #expect(ended.value == nil)
    }

    /// : while dormant, typing only queues and is not persisted, and wakes the reopen; after the new connection is ready it is persisted once and sent, and mute stays on.
    @Test func dormant_typed_text_wakes_reopen_and_persists_after_ready_once() async throws {
        let second = FakeConnection()
        let reopens = Reopens(.success(second))
        let controller = try start(reopener: try reopener(reopens))
        await expireWhileMuted(controller)
        #expect(reopens.calls == 0)

        controller.sendTypedText("Wake up")
        #expect(connection.texts.isEmpty)
        #expect(sink.log.isEmpty)

        second.continuation.yield(.ready)
        await sink.waitCount(1)
        #expect(reopens.calls == 1)
        #expect(second.openCount == 1)
        #expect(second.texts == ["Wake up"])
        #expect(connection.texts.isEmpty)
        #expect(sink.log == ["user:Wake up"])
        #expect(ended.value == nil)
        // Waking does not change mute: the new connection's uplink stays closed; frames are only released after unmute
        let onFrame = try #require(audio.onFrame)
        onFrame(Self.frame)
        #expect(second.sent.isEmpty)
        controller.toggleMute()
        onFrame(Self.frame)
        #expect(second.sent == [Self.frame])
        #expect(reopens.calls == 1)
    }

    // MARK: - Closeout AK · contract card F items 3–4 automatic re-open on expiry when not muted

    @Test func unmuted_session_expired_reopens_and_continues() async throws {
        let second = FakeConnection()
        let reopens = Reopens(.success(second))
        let controller = try start(reopener: try reopener(reopens))
        send(.ready)
        await waitStatus(controller, .listening)
        // Closed with 1008 while speaking: the call does not end; a new connection is opened with history via the current reopener path
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
        // Closeout AK · contract card C: audio does not stop during reopening
        #expect(audio.startCount == 1)
        #expect(audio.stopCount == 0)
        let onFrame = try #require(audio.onFrame)
        onFrame(Self.frame)
        #expect(second.sent == [Self.frame])

        // The same sink continues to receive the conversation on the new connection
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
        #expect(ended.errors == ["unknown"])
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

    // MARK: - Closeout AK · contract card C items 2–6 audio does not stop during reopening

    @Test func reopen_keeps_audio_running_and_rebinds_uplink() async throws {
        let second = FakeConnection()
        let reopens = Reopens(.success(second))
        let controller = try start(reopener: try reopener(reopens))
        await expireWhileMuted(controller)
        // Dormant: audio does not stop, the uplink gate is closed, mic frames reach no connection
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
        // The new driver's Ready only swaps the callback, and does not start audio again
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

    // Closeout AK · contract card D item 2: after session expiry, unbind the uplink callback until the reopened new driver is Ready, then rebind
    @Test func expired_unbinds_uplink_until_reopened_ready() async throws {
        let second = FakeConnection()
        let reopens = Reopens(.success(second))
        let controller = try start(reopener: try reopener(reopens))
        await expireWhileMuted(controller)
        let firstSent = connection.sent.count
        let onFrame = try #require(audio.onFrame)

        // Unmute: the uplink gate opens, but frames before the new connection is Ready do not enter either the old or new connection
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
        // Reopen failure classified as network
        #expect(ended.errors == ["network"])
        #expect(ended.value?.0 == .error)
        #expect(controller.statusKey == .error)
    }

    @Test func reopen_without_reopener_fails() async throws {
        let controller = try start()
        await expireWhileMuted(controller)

        controller.toggleMute()
        // No reopener: no reopen-failure signal, classified as unknown
        #expect(ended.errors == ["unknown"])
        #expect(ended.value?.0 == .error)
        #expect(controller.statusKey == .error)
    }

    // MARK: -  handshake timeout and unexpected drop automatic re-open

    @Test func handshake_not_done_in_10s_is_network() async throws {
        let controller = try start(failureContext: Self.failureContext)
        clock.advance(RealtimeModelPolicy.Constants.connectTimeoutMs - 1)
        #expect(ended.value == nil)
        #expect(controller.statusKey == .thinking)
        clock.advance(1)
        await ended.wait()
        // Handshake timeout (connectTimedOut) is classified as network, and the connection is closed
        #expect(ended.errors == ["network"])
        #expect(controller.failure?.classification.category == .network)
        #expect(controller.failure?.copyArgValue == "gpt-realtime")
        #expect(ended.value?.0 == .error)
        #expect(connection.closeCount >= 1)
        await controller.streamTask?.value
        #expect(controller.statusKey == .error)
    }

    @Test func ready_within_10s_cancels_handshake_timeout() async throws {
        let controller = try start(failureContext: RealtimeFailureContext(model: "gpt-realtime"))
        clock.advance(RealtimeModelPolicy.Constants.connectTimeoutMs - 1)
        send(.ready)
        await waitStatus(controller, .listening)
        clock.advance(RealtimeModelPolicy.Constants.connectTimeoutMs)
        #expect(ended.value == nil)
        #expect(ended.errors.isEmpty)
        #expect(controller.statusKey == .listening)
    }

    @Test func drop_after_ready_reopen_fails_is_network() async throws {
        let reopens = Reopens(.failure(URLError(.notConnectedToInternet)))
        let controller = try start(reopener: try reopener(reopens), failureContext: Self.failureContext)
        send(.ready)
        await waitStatus(controller, .listening)
        connection.continuation.finish(throwing: URLError(.networkConnectionLost))
        await ended.wait()
        // Unexpected drop re-opens once with history; still failing → reopenFailed → network
        #expect(reopens.calls == 1)
        #expect(ended.errors == ["network"])
        #expect(controller.failure?.classification.category == .network)
        #expect(ended.value?.0 == .error)
        #expect(audio.stopCount == 1)
    }

    @Test func reopened_connection_handshake_timeout_is_network() async throws {
        let second = FakeConnection()
        let reopens = Reopens(.success(second))
        let controller = try start(reopener: try reopener(reopens), failureContext: Self.failureContext)
        send(.ready)
        await waitStatus(controller, .listening)
        connection.continuation.finish(throwing: URLError(.networkConnectionLost))
        while second.openCount == 0 { await Task.yield() }
        #expect(ended.value == nil)
        clock.advance(RealtimeModelPolicy.Constants.connectTimeoutMs)
        await ended.wait()
        #expect(reopens.calls == 1)
        #expect(ended.errors == ["network"])
        #expect(second.closeCount >= 1)
        #expect(controller.statusKey == .error)
    }

    @Test func reopened_connection_failing_before_ready_is_network() async throws {
        let second = FakeConnection()
        let reopens = Reopens(.success(second))
        let controller = try start(reopener: try reopener(reopens), failureContext: Self.failureContext)
        send(.ready)
        await waitStatus(controller, .listening)
        connection.continuation.finish(throwing: URLError(.networkConnectionLost))
        while second.openCount == 0 { await Task.yield() }
        second.continuation.finish(throwing: URLError(.networkConnectionLost))
        await ended.wait()
        // Re-open only constants.autoReopenAttempts times
        #expect(reopens.calls == RealtimeModelPolicy.Constants.autoReopenAttempts)
        #expect(ended.errors == ["network"])
        #expect(controller.failure?.classification.category == .network)
    }

    @Test func drop_reopens_once_without_show_error() async throws {
        let second = FakeConnection()
        let reopens = Reopens(.success(second))
        let controller = try start(reopener: try reopener(reopens))
        send(.ready)
        await waitStatus(controller, .listening)
        let firstStream = controller.streamTask
        // After Gemini handle reconnection is exhausted (resumeFailed), it also re-opens once with history
        connection.continuation.finish(throwing: GeminiLiveTransportError.resumeFailed)
        await firstStream?.value
        #expect(ended.errors.isEmpty)
        #expect(ended.value == nil)
        #expect(controller.failure == nil)
        // During re-open the orb stays in listening with no level, and does not switch to thinking
        #expect(controller.displayState == .listening)
        #expect(controller.statusKey == .listening)
        let onFrame = try #require(audio.onFrame)
        for _ in 0..<Self.framesPerLevel { onFrame(Self.frame) }
        #expect(controller.level == 0)
        #expect(connection.sent.isEmpty)

        while second.openCount == 0 { await Task.yield() }
        second.continuation.yield(.ready)
        second.continuation.yield(.userSpeechStarted(itemId: "u2"))
        second.continuation.yield(.userSpeechStopped(itemId: "u2"))
        second.continuation.yield(.userTranscript(itemId: "u2", text: "Still there?", final: true))
        second.continuation.yield(.assistantTurnDone(itemId: "a2", status: .completed, text: "Yes."))
        await sink.waitCount(2)
        #expect(sink.log == ["user:Still there?", "assistant:Yes."])
        #expect(reopens.calls == 1)
        #expect(ended.errors.isEmpty)
        #expect(ended.value == nil)
        // Re-open does not stop audio; the new driver only swaps the uplink callback
        #expect(audio.startCount == 1)
        #expect(audio.stopCount == 0)
        let rebound = try #require(audio.onFrame)
        rebound(Self.frame)
        #expect(second.sent.last == Self.frame)
        #expect(connection.sent.isEmpty)

        controller.end()
        #expect(audio.stopCount == 1)
        #expect(ended.value?.0 == .user)
    }

    @Test func muted_drop_after_reopen_without_progress_ends_unknown_not_dormant() async throws {
        let second = FakeConnection()
        let reopens = Reopens(.success(second))
        let controller = try start(reopener: try reopener(reopens), failureContext: Self.failureContext)
        send(.ready)
        await waitStatus(controller, .listening)
        connection.continuation.finish(throwing: URLError(.networkConnectionLost))
        while second.openCount == 0 { await Task.yield() }
        second.continuation.yield(.ready)
        // During re-open the orb already stays in listening; wait until the new connection's ready is fully dispatched
        while controller.eventsReceivedForTesting < 2 { await Task.yield() }
        controller.toggleMute()
        #expect(controller.statusKey == .muted)

        // After re-open no progress, dropped again while muted: afterDrop first judges no progress → ends as unknown, no dormancy, no further re-open
        second.continuation.finish(throwing: URLError(.networkConnectionLost))
        await ended.wait()
        #expect(reopens.calls == 1)
        #expect(ended.errors == ["unknown"])
        #expect(ended.value?.0 == .error)
        #expect(controller.failure?.classification.category == .unknown)
        #expect(controller.statusKey == .error)
    }

    @Test func gemini_expired_while_muted_after_reopen_without_progress_ends_unknown_not_dormant() async throws {
        let second = FakeConnection()
        let reopens = Reopens(.success(second))
        let controller = try start(reopener: try reopener(reopens))
        send(.ready)
        await waitStatus(controller, .listening)
        // Closed with 1008 while not muted: re-opens once with history
        connection.continuation.finish(throwing: Self.expired)
        while second.openCount == 0 { await Task.yield() }
        second.continuation.yield(.ready)
        while controller.eventsReceivedForTesting < 2 { await Task.yield() }
        controller.toggleMute()
        #expect(controller.statusKey == .muted)

        // After re-open no progress, closed by 1008 again while muted: goes directly into the reducer, which first judges no progress → ends as unknown, no dormancy
        second.continuation.finish(throwing: Self.expired)
        await ended.wait()
        #expect(reopens.calls == 1)
        #expect(ended.errors == ["unknown"])
        #expect(ended.value?.0 == .error)
        #expect(controller.statusKey == .error)
    }

    @Test func reopened_handshake_404_is_network_without_catalog_refetch() async throws {
        let second = FakeConnection()
        let reopens = Reopens(.success(second))
        let checks = CatalogChecks(.success(false))
        let controller = try start(
            reopener: try reopener(reopens), failureContext: Self.failureContext, catalogCheck: checks.check
        )
        send(.ready)
        await waitStatus(controller, .listening)
        connection.continuation.finish(throwing: URLError(.networkConnectionLost))
        while second.openCount == 0 { await Task.yield() }
        // Re-open handshake 404: classified as network (not a delisted model), does not re-fetch the catalog
        second.continuation.finish(throwing: RealtimeHandshakeError(httpStatus: 404))
        await ended.wait()
        #expect(reopens.calls == 1)
        #expect(checks.calls == 0)
        #expect(ended.errors == ["network"])
        #expect(controller.failure?.classification.category == .network)
    }

    @Test func drop_with_quota_code_does_not_reopen() async throws {
        let reopens = Reopens(.success(FakeConnection()))
        let controller = try start(reopener: try reopener(reopens), failureContext: Self.failureContext)
        send(.ready)
        await waitStatus(controller, .listening)
        await sendAndWait(controller, .error(code: "insufficient_quota", message: "quota"))
        connection.continuation.finish(throwing: URLError(.networkConnectionLost))
        await ended.wait()
        // Failures re-open cannot fix (quota) are classified and end directly
        #expect(reopens.calls == 0)
        #expect(ended.errors == ["quota"])
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
        // Before ready there is only one one-shot handshake timeout (), removed on ready
        #expect(clock.pendingDeadlines == [RealtimeModelPolicy.Constants.connectTimeoutMs])
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

    // MARK: Uplink gate for loudspeaker playback (F2 card i2)

    /// Pushes a group of events and waits for the controller to dispatch them all.
    private func sendAndWait(_ controller: RealtimeVoiceConversationController, _ events: RealtimeSessionEvent...) async {
        let target = controller.eventsReceivedForTesting + events.count
        for event in events { connection.continuation.yield(event) }
        while controller.eventsReceivedForTesting < target { await Task.yield() }
    }

    /// One reply = 2 s of downlink audio (200 10 ms segments).
    private static let replyChunks = 200
    private static let replySamples: [Float] = (0..<(240 * replyChunks)).map { Float(sin(Double($0) * 0.07)) * 0.5 }
    private static let replyBase64 = RealtimePCM.encodePCM16LE(replySamples).base64EncodedString()
    private static let replyText = "The weather today is sunny with a light breeze and clear skies"
    /// The reply fragment returned when the server hears loudspeaker echo as user speech.
    private static let replySnippet = "sunny with a light breeze and clear skies"
    /// Start-of-speech threshold of the server VAD stand-in.
    private static let serverVadDb = -50.0
    /// Room noise floor (microphone input before and after playback).
    private static let roomDb = -55.0

    /// A copy of the downlink PCM's index-th 10 ms segment attenuated to db dBFS (the residual echo after AEC).
    private static func echo(_ index: Int, db: Double) -> Data {
        let slice = Array(replySamples[(index * 240)..<((index + 1) * 240)])
        let gain = Float(pow(10, (db - ConversationAudioMath.dbfs(slice)) / 20))
        return RealtimePCM.encodePCM16LE(slice.map { $0 * gain })
    }

    /// 10 ms sine at db dBFS (RMS = amplitude / √2).
    private static func tone(db: Double) -> Data {
        frame(amplitude: Float(2.0.squareRoot() * pow(10, db / 20)))
    }

    private static func pcmDb(_ data: Data) -> Double {
        let bytes = [UInt8](data)
        let samples = stride(from: 0, to: bytes.count - 1, by: 2).map { offset in
            Float(Int16(bitPattern: UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8)) / 32_768
        }
        return ConversationAudioMath.dbfs(samples)
    }

    private var interruptCount: Int { audio.log.filter { $0 == "stopPlayback" }.count }

    private struct EchoCycle {
        /// The server VAD stand-in heard uplink during playback (interrupts on that basis).
        var heard = false
        /// Number of uplink frames sent to the server during playback.
        var playbackSent = 0
        /// Status word after the reply starts playing.
        var status: Status?
    }

    /// Loudspeaker self-oscillation reproduction: the fake connection is wrapped with a "server VAD" stand-in. When an uplink frame above −50 dB arrives during playback, it is treated as user speech, and the reply
    /// userSpeechStarted / userSpeechStopped / final userTranscript (the reply fragment); an interrupted reply is followed by the next reply after it wraps up;
    /// if nothing is heard, the reply finishes and after 1 s of room noise (past the echo window) the user asks once more. Echo frames = attenuated copies of downlink PCM, fed every 10 ms.
    private func echoCycle(_ controller: RealtimeVoiceConversationController, index: Int, echoDb: Double) async throws -> EchoCycle {
        let onFrame = try #require(audio.onFrame)
        let id = "a\(index)"
        let user = "u\(index)"
        await sendAndWait(
            controller,
            .assistantAudio(itemId: id, contentIndex: 0, base64: Self.replyBase64, sampleRateHz: 24_000),
            .assistantTranscript(itemId: id, text: Self.replyText, final: false)
        )
        var cycle = EchoCycle(status: controller.statusKey)
        for chunk in 0..<Self.replyChunks {
            guard audio.isPlaying else { break }
            let before = connection.sent.count
            onFrame(Self.echo(chunk, db: echoDb))
            let fresh = connection.sent[before...]
            cycle.playbackSent += fresh.count
            if fresh.contains(where: { Self.pcmDb($0) > Self.serverVadDb }) {
                cycle.heard = true
                break
            }
        }
        if cycle.heard {
            await sendAndWait(
                controller,
                .userSpeechStarted(itemId: user),
                .userSpeechStopped(itemId: user),
                .userTranscript(itemId: user, text: Self.replySnippet, final: true),
                .assistantTurnDone(itemId: id, status: .interrupted, text: "")
            )
        } else {
            await sendAndWait(controller, .assistantTurnDone(itemId: id, status: .completed, text: Self.replyText))
            audio.finishPlayback()
            for _ in 0..<100 { onFrame(Self.tone(db: Self.roomDb)) }
            await sendAndWait(
                controller,
                .userSpeechStarted(itemId: user),
                .userSpeechStopped(itemId: user),
                .userTranscript(itemId: user, text: "Tell me more", final: true)
            )
        }
        return cycle
    }

    /// Starts a session and feeds 0.5 s of room noise (25 gate frames of 20 ms; the next reply starts playing at a gate-frame boundary).
    private func startListeningInRoom(
        speechModel: FakeSpeechModel? = nil,
        speechModelLoader: RealtimeSpeechProbLoading.Loader? = nil
    ) async throws -> RealtimeVoiceConversationController {
        let controller = try start(speechModel: speechModel, speechModelLoader: speechModelLoader)
        send(.ready)
        await waitStatus(controller, .listening)
        let onFrame = try #require(audio.onFrame)
        for _ in 0..<50 { onFrame(Self.tone(db: Self.roomDb)) }
        return controller
    }

    /// −45 dBFS echo residual (below the local speech-start threshold): over 5 reply cycles not a single frame is uplinked during playback; the server never interrupts.
    @Test func speaker_echo_never_reaches_server() async throws {
        let controller = try await startListeningInRoom()
        var cycles: [EchoCycle] = []
        for index in 0..<5 {
            cycles.append(try await echoCycle(controller, index: index, echoDb: -45))
        }
        #expect(cycles.map(\.playbackSent) == Array(repeating: 0, count: 5))
        #expect(cycles.allSatisfy { !$0.heard })
        #expect(interruptCount == 0)
        // Past the echo window after playback, room noise uplinks as usual.
        #expect(connection.sent.count > 50)
        #expect(sink.log.filter { $0.hasPrefix("assistant:") }.count == 5)
    }

    /// −30 dBFS echo residual (the local VAD lets it through as speech): the server hears the echo as interruptions at most twice,
    /// after which echo transcripts are all counted as false interruptions and voice interruption is turned off; the speaking state changes to "tap to interrupt".
    @Test func speaker_loud_echo_loop_bounded_by_false_barge_ins() async throws {
        let controller = try await startListeningInRoom()
        var cycles: [EchoCycle] = []
        for index in 0..<4 {
            cycles.append(try await echoCycle(controller, index: index, echoDb: -30))
        }
        #expect(cycles.map(\.heard) == [true, true, false, false])
        #expect(interruptCount <= 2)
        #expect(cycles[2].status == .speakingTapToInterrupt)
        #expect(cycles[3].status == .speakingTapToInterrupt)
        #expect(cycles[2].playbackSent == 0)
        #expect(cycles[3].playbackSent == 0)
    }

    /// The user really speaks during loudspeaker playback: speech must reach bargeInMinSpeechMs to be let through, the catch-up starts vadPrerollMs before the speech onset, and it is passed through thereafter.
    @Test func speaker_barge_in_opens_with_preroll() async throws {
        let controller = try await startListeningInRoom()
        let onFrame = try #require(audio.onFrame)
        await sendAndWait(
            controller,
            .assistantAudio(itemId: "a0", contentIndex: 0, base64: Self.replyBase64, sampleRateHz: 24_000),
            .assistantTranscript(itemId: "a0", text: Self.replyText, final: false)
        )
        let voiceAt = 120
        let voice = Self.tone(db: -20)
        let before = connection.sent.count
        var fed: [Data] = []
        var openedAt: Int?
        for chunk in 0..<Self.replyChunks {
            let data = chunk < voiceAt ? Self.echo(chunk, db: -45) : voice
            fed.append(data)
            onFrame(data)
            if connection.sent.count > before {
                openedAt = chunk
                break
            }
        }
        let opened = try #require(openedAt)
        let constants = VoiceConversationLogic.Constants.self
        #expect(opened == voiceAt + constants.bargeInMinSpeechMs / 10 - 1)
        let prerollChunks = constants.vadPrerollMs / 10
        #expect(Data(connection.sent[before...].joined()) == Data(fed.dropFirst(voiceAt - prerollChunks).joined()))
        #expect(audio.isPlaying)
        onFrame(voice)
        #expect(connection.sent.last == voice)
    }

    /// F2b fake speech model: probabilities are set per frame by the case; after fail every feed throws. Records the number of 16 kHz samples fed.
    nonisolated final class FakeSpeechModel: RealtimeSpeechProb {
        struct InferenceFailed: Error {}
        var prob = 0.0
        var fail = false
        private(set) var fedSamples = 0

        func feed(_ samples: UnsafeBufferPointer<Float>) throws -> Double {
            if fail { throw InferenceFailed() }
            fedSamples += samples.count
            return prob
        }
    }

    /// F2b: AEC degraded, the loudspeaker echo residual −30 dBFS (energy mode would let it through) but the model prob is 0.1: over 3 reply cycles not a single frame is uplinked during playback.
    @Test func speaker_degraded_echo_low_prob_never_reaches_server() async throws {
        let model = FakeSpeechModel()
        model.prob = 0.1
        let controller = try await startListeningInRoom(speechModel: model)
        var cycles: [EchoCycle] = []
        for index in 0..<3 {
            cycles.append(try await echoCycle(controller, index: index, echoDb: -30))
        }
        #expect(cycles.map(\.playbackSent) == [0, 0, 0])
        #expect(cycles.allSatisfy { !$0.heard })
        #expect(interruptCount == 0)
        // The model consumes 16 kHz continuously from capture start: the 24 kHz uplink converts to about 2/3 of the sample count
        let uplinkSamples = connection.sent.reduce(0) { $0 + $1.count / 2 }
        #expect(model.fedSamples > uplinkSamples / 2)
    }

    /// F2b: on a −30 dBFS prob 0.1 echo, the user speaks at −18 dBFS (prob 0.95): let through once bargeInMinSpeechMs is met, the catch-up carries the pre-roll.
    @Test func speaker_barge_in_high_prob_opens_over_echo() async throws {
        let model = FakeSpeechModel()
        model.prob = 0.1
        let controller = try await startListeningInRoom(speechModel: model)
        let onFrame = try #require(audio.onFrame)
        await sendAndWait(
            controller,
            .assistantAudio(itemId: "a0", contentIndex: 0, base64: Self.replyBase64, sampleRateHz: 24_000),
            .assistantTranscript(itemId: "a0", text: Self.replyText, final: false)
        )
        let voiceAt = 120
        let voice = Self.tone(db: -18)
        let before = connection.sent.count
        var fed: [Data] = []
        var openedAt: Int?
        for chunk in 0..<Self.replyChunks {
            let isVoice = chunk >= voiceAt
            model.prob = isVoice ? 0.95 : 0.1
            let data = isVoice ? voice : Self.echo(chunk, db: -30)
            fed.append(data)
            onFrame(data)
            if connection.sent.count > before {
                openedAt = chunk
                break
            }
        }
        let opened = try #require(openedAt)
        let constants = VoiceConversationLogic.Constants.self
        #expect(opened == voiceAt + constants.bargeInMinSpeechMs / 10 - 1)
        let prerollChunks = constants.vadPrerollMs / 10
        #expect(Data(connection.sent[before...].joined()) == Data(fed.dropFirst(voiceAt - prerollChunks).joined()))
        #expect(audio.isPlaying)
    }

    /// F2c fixture frames: (db, prob, ref), expanded from the frame segments of the shared fixture uplinkGateCases; the start / finish frames of opts.
    private struct GateFixtureCase {
        var frames: [(db: Double, prob: Double, ref: Double?)]
        var playbackStart: Int
        var playbackEnded: Int
        var expected: [String: Any]
    }

    private static func gateFixture(_ id: String) throws -> GateFixtureCase {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var root: [String: Any]?
        while cursor.path != "/", root == nil {
            let candidate = cursor.appendingPathComponent("shared/voice-contracts/realtime-conversation.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                root = try JSONSerialization.jsonObject(with: Data(contentsOf: candidate)) as? [String: Any]
            }
            cursor.deleteLastPathComponent()
        }
        let cases = try #require(root?["uplinkGateCases"] as? [[String: Any]])
        let item = try #require(cases.first { $0["id"] as? String == id }, "\(id)")
        let input = try #require(item["input"] as? [String: Any])
        let runs = try #require(input["frames"] as? [[Any]])
        let frames = try runs.flatMap { run -> [(db: Double, prob: Double, ref: Double?)] in
            let db = try #require(run[0] as? NSNumber).doubleValue
            let count = try #require(run[1] as? NSNumber).intValue
            let prob = try #require(run[2] as? NSNumber).doubleValue
            let ref = (run[3] as? NSNumber)?.doubleValue
            return Array(repeating: (db, prob, ref), count: count)
        }
        let opts = try #require(input["opts"] as? [String: Any])
        return GateFixtureCase(
            frames: frames,
            playbackStart: try #require(opts["playbackStartFrame"] as? Int),
            playbackEnded: try #require(opts["playbackEndedFrame"] as? Int),
            expected: try #require(item["expected"] as? [String: Any])
        )
    }

    /// One 20 ms gate frame (24 kHz, 480 samples) of a db dBFS sine; the phase varies with the frame number (each frame's bytes differ).
    private static func gateFrame(db: Double, index: Int) -> Data {
        let raw = (0..<480).map { Float(sin(Double($0) * 0.2 + Double(index) * 0.37)) }
        let gain = Float(pow(10, (db - ConversationAudioMath.dbfs(raw)) / 20))
        return RealtimePCM.encodePCM16LE(raw.map { $0 * gain })
    }

    /// Feeds fixture frames [from, until] one by one through the fake audio into the controller: issues the reply before the start frame, ends and finishes playing before the finish frame;
    /// each frame first sets the model prob and the downlink reference, then goes uplink. Returns the injected frames.
    private func feedGateFixture(
        _ controller: RealtimeVoiceConversationController, model: FakeSpeechModel, _ fixture: GateFixtureCase,
        from: Int, through until: Int
    ) async throws -> [Data] {
        let onFrame = try #require(audio.onFrame)
        var injected: [Data] = []
        for index in from...until {
            let frame = fixture.frames[index]
            if index == fixture.playbackStart {
                await sendAndWait(
                    controller,
                    .assistantAudio(itemId: "a0", contentIndex: 0, base64: Self.replyBase64, sampleRateHz: 24_000)
                )
                #expect(audio.isPlaying)
            }
            if index == fixture.playbackEnded {
                await sendAndWait(controller, .assistantTurnDone(itemId: "a0", status: .completed, text: Self.replyText))
                audio.finishPlayback()
            }
            model.prob = frame.prob
            audio.ref = frame.ref
            let data = Self.gateFrame(db: frame.db, index: index)
            injected.append(data)
            onFrame(data)
        }
        return injected
    }

    /// F2c: loudspeaker AEC degraded, the echo rises and falls with the downlink reference, and the model judges speech (0.9). Reference-correlated echo frames are fed to the VAD with prob 0:
    /// not one frame uplinks during playback or the echo window, and only after the echo window ends are the held tail segments released and sent.
    @Test func speaker_echo_reference_correlated_echo_never_reaches_server() async throws {
        let fixture = try Self.gateFixture("rt_gate_echo_ref_correlated_echo_held")
        let model = FakeSpeechModel()
        model.prob = 0.02
        let controller = try start(speechModel: model)
        send(.ready)
        await waitStatus(controller, .listening)
        let pb = fixture.playbackStart
        let openAt = try #require(fixture.expected["openAtFrame"] as? Int)
        let flushFrom = try #require(fixture.expected["flushFromFrame"] as? Int)
        let held = try await feedGateFixture(controller, model: model, fixture, from: 0, through: openAt - 1)
        #expect(connection.sent.count == pb)
        let rest = try await feedGateFixture(controller, model: model, fixture, from: openAt, through: fixture.frames.count - 1)
        let all = held + rest
        #expect(connection.sent == Array(all[0..<pb]) + Array(all[flushFrom...]))
        #expect(interruptCount == 0)
    }

    /// F2c: the user interrupts during playback, with the near end well above the reference (not following): the echo is not judged; speech reaching bargeInMinSpeechMs passes the frame, and the pre-roll is sent in order.
    @Test func speaker_echo_reference_barge_in_opens() async throws {
        let fixture = try Self.gateFixture("rt_gate_echo_ref_barge_in_louder_opens")
        #expect(fixture.expected["openReason"] as? String == "speech")
        let model = FakeSpeechModel()
        model.prob = 0.02
        let controller = try start(speechModel: model)
        send(.ready)
        await waitStatus(controller, .listening)
        let pb = fixture.playbackStart
        let openAt = try #require(fixture.expected["openAtFrame"] as? Int)
        let flushFrom = try #require(fixture.expected["flushFromFrame"] as? Int)
        let injected = try await feedGateFixture(controller, model: model, fixture, from: 0, through: openAt)
        #expect(audio.isPlaying)
        #expect(connection.sent == Array(injected[0..<pb]) + Array(injected[flushFrom...openAt]))
    }

    /// F2b: the model throws mid-inference → this session switches to the energy judgement and no longer returns to the model: −30 dBFS echo is let through after the start grace (same as with no model).
    @Test func speaker_model_inference_failed_falls_back_energy() async throws {
        let model = FakeSpeechModel()
        model.prob = 0.1
        let controller = try await startListeningInRoom(speechModel: model)
        let onFrame = try #require(audio.onFrame)
        await sendAndWait(
            controller,
            .assistantAudio(itemId: "a0", contentIndex: 0, base64: Self.replyBase64, sampleRateHz: 24_000),
            .assistantTranscript(itemId: "a0", text: Self.replyText, final: false)
        )
        model.fail = true
        let before = connection.sent.count
        var openedAt: Int?
        for chunk in 0..<Self.replyChunks {
            onFrame(Self.echo(chunk, db: -30))
            if connection.sent.count > before {
                openedAt = chunk
                break
            }
        }
        let opened = try #require(openedAt)
        let constants = VoiceConversationLogic.Constants.self
        #expect(opened >= constants.bargeInGraceMs / 10)
        // No longer returns to the model after failure: recovery probabilities are no longer fed either
        model.fail = false
        let fedAfter = model.fedSamples
        onFrame(Self.echo(opened + 1, db: -30))
        onFrame(Self.echo(opened + 2, db: -30))
        #expect(model.fedSamples == fedAfter)
    }

    /// F2b slow loader: blocks until released (on the loading thread); records the model it built (weak reference) to judge whether it was dropped.
    nonisolated final class SlowLoader: @unchecked Sendable {
        private let gate = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var _loaded = false
        private weak var _model: FakeSpeechModel?
        var loaded: Bool { lock.withLock { _loaded } }
        var model: FakeSpeechModel? { lock.withLock { _model } }

        var loader: RealtimeSpeechProbLoading.Loader {
            { [self] in
                gate.wait()
                let model = FakeSpeechModel()
                model.prob = 0.95
                lock.withLock {
                    _model = model
                    _loaded = true
                }
                return model
            }
        }

        func release() { gate.signal() }
    }

    /// F2b: the model is not ready within 500 ms → the whole session uses the energy basis: loudspeaker −30 dBFS echo is let through after the start grace.
    @Test func speaker_model_not_ready_energy_whole_session() async throws {
        let slow = SlowLoader()
        defer { slow.release() }
        let controller = try await startListeningInRoom(speechModelLoader: slow.loader)
        let onFrame = try #require(audio.onFrame)
        #expect(!slow.loaded)
        await sendAndWait(
            controller,
            .assistantAudio(itemId: "a0", contentIndex: 0, base64: Self.replyBase64, sampleRateHz: 24_000),
            .assistantTranscript(itemId: "a0", text: Self.replyText, final: false)
        )
        let before = connection.sent.count
        var openedAt: Int?
        for chunk in 0..<Self.replyChunks {
            onFrame(Self.echo(chunk, db: -30))
            if connection.sent.count > before {
                openedAt = chunk
                break
            }
        }
        let opened = try #require(openedAt)
        let constants = VoiceConversationLogic.Constants.self
        #expect(opened == (constants.bargeInGraceMs + constants.bargeInMinSpeechMs) / 10 - 1)
    }

    /// F2b: the session ends while waiting for the model → the late model is dropped (not installed for uplink, not fed, released), and the engine does not start.
    @Test func ended_while_loading_closes_model() async throws {
        let slow = SlowLoader()
        let controller = try start(speechModelLoader: slow.loader)
        send(.ready)
        while audio.prepareCount == 0 { await Task.yield() }
        controller.end()
        await ended.wait()
        slow.release()
        while !slow.loaded { await Task.yield() }
        while slow.model != nil { await Task.yield() }
        #expect(audio.startCount == 0)
        #expect(audio.onFrame == nil)
    }

    /// Earphone route is not armed: uplink passes through unchanged during playback.
    /// F2 review: the held queue has a cap — it does not grow without bound when the reply is long or the real end signal is lost
    @Test func held_uplink_frames_are_capped() {
        let uplink = RealtimeUplink(minLevelInterval: 1)
        var sent = 0
        uplink.bind { _ in sent += 1 }
        uplink.playbackStarted(route: .speaker)
        let frame = Data(count: Int(RealtimePCM.sampleRate) / 50 * 2) // 20 ms of silence; the gate holds it the whole time
        for _ in 0..<300 { uplink.deliver(frame) }
        #expect(sent == 0)
        #expect(uplink.heldFrameCount == RealtimeUplink.maxHeldFrames)
    }

    /// F2c: when one uplink callback yields multiple gate frames, each frame takes a different chunk in capture order: frame k looks back (m − 1 − k) × 480 samples from the playhead.
    /// Records the "samples looked back" passed when the uplink gate takes its reference (called on the audio thread).
    nonisolated final class ReferenceProbe: @unchecked Sendable {
        let lock = NSLock()
        var behind: [Int] = []
        var calls = 0
    }

    @Test func speaker_echo_reference_batch_frames_use_offset_head() {
        let probe = ReferenceProbe()
        let uplink = RealtimeUplink(minLevelInterval: 1) { behind in
            probe.lock.withLock {
                probe.behind.append(contentsOf: behind)
                probe.calls += 1
            }
            return behind.map { -20 - Double($0 / 480) }
        }
        uplink.bind { _ in }
        uplink.playbackStarted(route: .speaker)
        let gateBytes = Int(RealtimePCM.sampleRate) / 50 * 2
        // Three whole frames delivered at once: the earliest frame is two chunks back
        uplink.deliver(Data(count: gateBytes * 3))
        #expect(probe.lock.withLock { probe.behind } == [960, 480, 0])
        // Half a frame: not enough to fill a frame, no reference taken
        uplink.deliver(Data(count: gateBytes / 2))
        #expect(probe.lock.withLock { probe.behind }.count == 3)
        // Another 1.5 frames: fills the previous frame + one whole frame = 2 frames
        uplink.deliver(Data(count: gateBytes * 3 / 2))
        #expect(probe.lock.withLock { probe.behind } == [960, 480, 0, 480, 0])
        // Each callback that yields frames takes only one read (the same batch shares one playhead reading)
        #expect(probe.lock.withLock { probe.calls } == 2)
    }

    @Test func headphones_uplink_not_gated() async throws {
        audio.route = .headphones
        let controller = try await startListeningInRoom()
        let onFrame = try #require(audio.onFrame)
        await sendAndWait(
            controller,
            .assistantAudio(itemId: "a0", contentIndex: 0, base64: Self.replyBase64, sampleRateHz: 24_000),
            .assistantTranscript(itemId: "a0", text: Self.replyText, final: false)
        )
        #expect(audio.isPlaying)
        let before = connection.sent.count
        let echoes = (0..<20).map { Self.echo($0, db: -30) }
        for echo in echoes { onFrame(echo) }
        #expect(Array(connection.sent[before...]) == echoes)
    }

    /// : during playback the loudspeaker is switched to earphones → the gate is disarmed on the spot; afterward uplink passes through unchanged (the held loudspeaker echo is discarded), without waiting for the next connection.
    @Test func route_change_to_headphones_disarms_gate_at_once() async throws {
        let controller = try await startListeningInRoom()
        let onFrame = try #require(audio.onFrame)
        await sendAndWait(
            controller,
            .assistantAudio(itemId: "a0", contentIndex: 0, base64: Self.replyBase64, sampleRateHz: 24_000),
            .assistantTranscript(itemId: "a0", text: Self.replyText, final: false)
        )
        #expect(audio.isPlaying)
        let before = connection.sent.count
        for chunk in 0..<5 { onFrame(Self.echo(chunk, db: -30)) }
        #expect(connection.sent.count == before)
        audio.changeRoute(.headphones)
        let echoes = (5..<20).map { Self.echo($0, db: -30) }
        for echo in echoes { onFrame(echo) }
        #expect(Array(connection.sent[before...]) == echoes)
    }

    /// : during playback the earphones are switched to loudspeaker → the gate is armed on the spot; afterward echo is held back.
    @Test func route_change_to_speaker_arms_gate_at_once() async throws {
        audio.route = .headphones
        let controller = try await startListeningInRoom()
        let onFrame = try #require(audio.onFrame)
        await sendAndWait(
            controller,
            .assistantAudio(itemId: "a0", contentIndex: 0, base64: Self.replyBase64, sampleRateHz: 24_000),
            .assistantTranscript(itemId: "a0", text: Self.replyText, final: false)
        )
        #expect(audio.isPlaying)
        let before = connection.sent.count
        let passed = (0..<5).map { Self.echo($0, db: -30) }
        for echo in passed { onFrame(echo) }
        #expect(Array(connection.sent[before...]) == passed)
        audio.changeRoute(.speaker)
        for chunk in 5..<10 { onFrame(Self.echo(chunk, db: -30)) }
        #expect(connection.sent.count == before + passed.count)
    }
}
