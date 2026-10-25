import Combine
import Foundation
import OriveoProviderKit
import os

/// Host side of a realtime conversation: writes finished turns into the chat (implemented by the host).
protocol RealtimeConversationSink: AnyObject {
    func appendUser(_ text: String)
    func appendAssistant(_ text: String)
    /// Home entry: create the chat and move to it when there is none yet; a no-op otherwise.
    /// Called once per session on the main thread before the first turn event is reduced.
    /// Returns false when the chat could not be created (the session then ends with an error).
    func ensureConversation() -> Bool
    /// The conversation ended (after its last persist).
    func conversationEnded()
    /// Whether a chat already exists for this session (diagnostic logs only; nil when the sink does not know).
    var hasConversation: Bool? { get }
}

extension RealtimeConversationSink {
    func ensureConversation() -> Bool { true }
    func conversationEnded() {}
    var hasConversation: Bool? { nil }
}

/// Shared os_log helpers for the realtime voice path (subsystem com.kenny.oriveo, category realtime-voice).
nonisolated enum RealtimeVoiceLog {
    static let logger = Logger(subsystem: "com.kenny.oriveo", category: "realtime-voice")

    /// Transcript text for logs: the text itself in Debug builds, only its length in Release.
    static func text(_ value: String) -> String {
        #if DEBUG
        return "\"\(value)\""
        #else
        return "len=\(value.count)"
        #endif
    }

    /// Type, itemId, final flag and (logged) text of one unified event; audio payloads are never logged.
    static func describe(_ event: RealtimeSessionEvent) -> String {
        func item(_ id: String?) -> String { id ?? "nil" }
        switch event {
        case let .userSpeechStarted(itemId), let .userSpeechStopped(itemId):
            return "\(event.typeName) item=\(item(itemId))"
        case let .userTranscript(itemId, text, final), let .assistantTranscript(itemId, text, final):
            return "\(event.typeName) item=\(item(itemId)) final=\(final) text=\(Self.text(text))"
        case let .assistantAudio(itemId, _, base64, _):
            return "\(event.typeName) item=\(item(itemId)) b64len=\(base64.count)"
        case let .assistantTurnDone(itemId, status, text):
            return "\(event.typeName) item=\(item(itemId)) status=\(status) text=\(Self.text(text))"
        case let .goAway(timeLeftMs):
            return "\(event.typeName) timeLeftMs=\(timeLeftMs.map(String.init) ?? "nil")"
        case let .sessionEnded(reason):
            return "\(event.typeName) reason=\(reason)"
        case let .error(code, _):
            return "\(event.typeName) code=\(code)"
        case .ready, .interrupted, .resumable:
            return event.typeName
        }
    }
}

/// Controller: feeds driver events and local input into `RealtimeConversationLogic`
/// and performs the returned effects in order. The UI reads displayState / statusKey / level only.
final class RealtimeVoiceConversationController: ObservableObject {
    typealias Logic = RealtimeConversationLogic
    typealias Connection = any RealtimeTransport & RealtimeSessionControl
    /// the host builds a fresh plan (same projection path, current history) and opens a new connection.
    typealias Reopener = () async throws -> (connection: Connection, plan: PlannedRealtimeSession)
    /// realtime-session.v1 turn boundary: replans with currentSessionId = the open session and returns the
    /// new fingerprint (nil when no plan can be made). Called off the main thread; it must not need the main actor.
    typealias Replanner = @Sendable () async -> RealtimeSessionFingerprint?

    @Published private(set) var displayState: VoiceConversationLogic.DisplayState?
    @Published private(set) var statusKey: VoiceConversationLogic.StatusKey?
    /// 0...1 orb level: latest throttled uplink level while listening, fixed 0.5 while speaking, otherwise 0.
    @Published private(set) var level: Double = 0

    static let speakingLevel = 0.5

    private var connection: Connection
    private let audio: any RealtimeAudioIO
    private let gate: GatedAudio
    /// One driver per session run; a reopen replaces it together with the connection.
    private var driver: RealtimeConversationDriver
    private var plan: PlannedRealtimeSession
    private let reopener: Reopener?
    private let replanner: Replanner?
    private let sink: RealtimeConversationSink
    private let clock: VoiceConversationClock
    private let onError: (String) -> Void
    private let onEnded: (Logic.EndReason, String?) -> Void

    private var state = Logic.initialState
    private var pendingInputs: [Logic.Input] = []
    private var dispatching = false
    private var started = false
    private var showsError = false
    private var draft: String?
    /// The first turn event already asked the sink for a chat (realtime-conversation rules.host: once per session).
    private var conversationEnsured = false
    /// Clock time `start()` ran at: logs report times relative to it.
    private var startedAtMs = 0
    #if DEBUG
    /// Tests only: driver events this controller has dispatched (replay waits on it before advancing).
    private(set) var eventsReceivedForTesting = 0
    #endif
    private var frameLevel: Double = 0
    /// The one armed one-shot timer (at the reducer's next deadline); never a periodic tick.
    private var ticker: VoiceConversationTimer?
    /// Clock time the reducer's counters are current to (last tick, or the first ready); nil before ready.
    private var tickedAtMs: Int?
    /// Consumes the current session stream; finishes once its last input has been dispatched.
    private(set) var streamTask: Task<Void, Never>?
    private var reopenTask: Task<Void, Never>?
    #if DEBUG
    /// Tests only: whether a reopen has been scheduled (nil = never reopened).
    var reopenTaskForTesting: Task<Void, Never>? { reopenTask }
    #endif
    /// Identifies the current session stream; inputs from a replaced stream are dropped.
    private var sessionRun = 0
    /// The input being reduced is planChanged: its reopen replaces a still-live connection.
    private var reducingPlanChange = false
    /// At most one replan per turn boundary; its result is dropped once the token moved on.
    private(set) var replanTask: Task<Void, Never>?
    /// Bumped when a replan starts, when the session leaves idle listening and on every reopen.
    private var replanToken = 0

    init(
        connection: Connection,
        audio: any RealtimeAudioIO,
        plan: PlannedRealtimeSession,
        sink: RealtimeConversationSink,
        clock: VoiceConversationClock = SystemVoiceConversationClock(),
        reopener: Reopener? = nil,
        replanner: Replanner? = nil,
        onError: @escaping (String) -> Void,
        onEnded: @escaping (Logic.EndReason, String?) -> Void
    ) {
        self.connection = connection
        self.audio = audio
        self.plan = plan
        self.sink = sink
        self.clock = clock
        self.reopener = reopener
        self.replanner = replanner
        self.onError = onError
        self.onEnded = onEnded
        let gate = GatedAudio(audio, minLevelInterval: 1 / DictationLevelMeter.maxUpdatesPerSecond)
        self.gate = gate
        driver = RealtimeConversationDriver(connection: connection, audio: gate)
        gate.observeLevel { [weak self] level in self?.uplinkLevel(level) }
        gate.interruptionObserver = { [weak self] in self?.dispatch(.systemInterruption) }
        gate.onPlaybackDrained = { [weak self] in self?.drainIfIdle() }
        publish()
    }

    // MARK: Actions

    /// Opens the session. Calling it again is a no-op.
    func start() {
        guard !started else { return }
        started = true
        startedAtMs = clock.nowMs
        runSession()
    }

    private func runSession() {
        sessionRun += 1
        let run = sessionRun
        let events = driver.run(plan: plan)
        streamTask = Task { [weak self] in
            do {
                for try await event in events {
                    guard let self, self.sessionRun == run else { return }
                    self.dispatch(.event(event))
                    #if DEBUG
                    self.eventsReceivedForTesting += 1
                    #endif
                }
                // Stream finished without sessionEnded or an error: treated as a system interruption
                // (a no-op once the reducer has already ended).
                guard let self, self.sessionRun == run else { return }
                self.dispatch(.systemInterruption)
            } catch let expired as GeminiLiveTransportError where expired.isSessionExpired {
                guard let self, self.sessionRun == run else { return }
                // frames must not reach the dead connection; the reopened driver rebinds on Ready.
                self.gate.unbindUplink()
                self.dispatch(.sessionExpired)
            } catch {
                guard let self, self.sessionRun == run else { return }
                self.dispatch(.failed(code: Self.errorCode(error)))
            }
        }
    }

    /// swap in the reopened connection and run a new driver on it; the same sink
    /// keeps receiving turns and the host gets no ended. A missing or throwing reopener fails the call.
    /// `closingCurrent`: the current connection is still live (planChanged); it is retired and closed first,
    /// and its stream's remaining inputs are dropped, so the shared audio keeps running.
    private func reopen(closingCurrent: Bool) {
        guard let reopener else {
            dispatch(.failed(code: Self.errorCode(RealtimeReopenError.unavailable)))
            return
        }
        if closingCurrent {
            sessionRun += 1
            gate.unbindUplink()
            driver.retire()
            connection.close()
        }
        reopenTask = Task { [weak self] in
            do {
                let reopened = try await reopener()
                guard let self else { return }
                guard self.state.phase != .ended else {
                    reopened.connection.close()
                    return
                }
                self.connection = reopened.connection
                self.plan = reopened.plan
                self.driver = RealtimeConversationDriver(connection: reopened.connection, audio: self.gate)
                self.runSession()
            } catch {
                self?.dispatch(.failed(code: Self.errorCode(error)))
            }
        }
    }

    /// the error type name only, never the URL or key.
    /// Bridged Foundation errors surface as NSError, so URLError is named explicitly.
    /// Same code the cascade uses when the home first send cannot create the chat.
    static let conversationUnavailableCode = "send_failed"

    static func errorCode(_ error: Error) -> String {
        if error is URLError { return "URLError" }
        return String(describing: type(of: error))
    }

    func tapOrb() { dispatch(.tapOrb) }
    func toggleMute() { dispatch(state.muted ? .unmute : .mute) }
    func end() { dispatch(.end) }
    /// The screen reader is announcing the status word: pauses the uplink without muting (mute wins).
    func setScreenReaderSpeaking(_ speaking: Bool) { dispatch(.screenReaderSpeaking(speaking)) }

    // MARK: Event loop

    /// a finished reply drains once the player reported it has nothing left
    /// (player callback only, no polling). A late callback while audio is still queued is stale and ignored.
    private func drainIfIdle() {
        guard state.phase == .speaking, state.drainPending, !gate.isPlaying else { return }
        dispatch(.playbackDrained)
    }

    /// The armed deadline is due: catch the reducer up to now.
    private func deadlineReached() {
        ticker = nil
        run(nil)
    }

    private func dispatch(_ input: Logic.Input) {
        run(input)
    }

    /// Before every input (and when the deadline fires) the reducer first gets one tick of the real
    /// elapsed time; afterwards one one-shot timer is armed at `Logic.nextTickMs`.
    private func run(_ input: Logic.Input?) {
        if let input { pendingInputs.append(input) }
        guard !dispatching else { return }
        dispatching = true
        catchUp()
        while !pendingInputs.isEmpty {
            var next = pendingInputs.removeFirst()
            catchUp()
            let wasDrainPending = state.drainPending
            let wasIdle = Self.isIdleListening(state)
            let wasConnecting = state.phase == .connecting
            // realtime-conversation rules.host: the first turn event creates the chat (home entry)
            // before it is reduced and its status published, so the home bar never shows speaking.
            // Tried once per session; when it cannot be created the session ends with the home cascade
            // first-send error instead of reducing the event.
            if !conversationEnsured, case let .event(event) = next, state.phase != .ended, Self.isTurnEvent(event) {
                conversationEnsured = true
                if !sink.ensureConversation() { next = .failed(code: Self.conversationUnavailableCode) }
            }
            reduce(next)
            let isIdle = Self.isIdleListening(state)
            if wasIdle, !isIdle { replanToken += 1 }
            // Turn boundary: a turn just settled back into idle listening (not the first ready of a session).
            if !wasIdle, isIdle, !wasConnecting { replanAtTurnBoundary() }
            if tickedAtMs == nil, case .event(.ready) = next { tickedAtMs = clock.nowMs }
            // The reply just finished: read the player once. Already idle (nothing or only empty PCM queued)
            // means no further player callback will come, so drain right now.
            if !wasDrainPending, state.drainPending, state.phase == .speaking, !gate.isPlaying {
                pendingInputs.insert(.playbackDrained, at: 0)
            }
        }
        dispatching = false
        armDeadline()
    }

    /// Assistant audio, assistant transcript or user transcript: the events that start a turn's content.
    private static func isTurnEvent(_ event: RealtimeSessionEvent) -> Bool {
        switch event {
        case .assistantAudio, .assistantTranscript, .userTranscript: true
        default: false
        }
    }

    /// Idle listening as the reducer's planChanged requires it: no speech, no turn in progress, not dormant.
    private static func isIdleListening(_ state: Logic.State) -> Bool {
        state.phase == .listening && !state.dormant && !state.userSpeaking
            && !state.turn.userPending && !state.turn.assistantStarted
    }

    /// realtime-session.v1: replan off the main thread and send planChanged only when the fingerprint differs
    /// from the open session's. A result that arrives after the session or the turn changed is dropped.
    private func replanAtTurnBoundary() {
        guard let replanner, let current = plan.plan.fingerprint else { return }
        replanToken += 1
        let token = replanToken
        replanTask = Task { [weak self] in
            let next = await Task.detached(priority: .utility) { await replanner() }.value
            guard let self, self.replanToken == token, let next,
                  ContextAssembler.shouldReopen(current, next) else { return }
            self.dispatch(.planChanged)
        }
    }

    private func catchUp() {
        guard let since = tickedAtMs, state.phase != .ended else { return }
        let now = clock.nowMs
        tickedAtMs = now
        if now > since { reduce(.tick(ms: now - since)) }
    }

    private func reduce(_ input: Logic.Input) {
        reducingPlanChange = input == .planChanged
        defer { reducingPlanChange = false }
        let (newState, effects) = Logic.reduce(state, input)
        log(input, effects: effects)
        state = newState
        publish()
        for effect in effects { perform(effect) }
    }

    private func armDeadline() {
        ticker?.cancel()
        ticker = nil
        // Skip scheduling when nextTickMs <= 0: tick(ms <= 0) has no effect, so it would only spin.
        guard let since = tickedAtMs, let wait = Logic.nextTickMs(state), wait > 0 else { return }
        let delay = max(0, wait - (clock.nowMs - since))
        ticker = clock.after(ms: delay) { [weak self] in self?.deadlineReached() }
    }

    /// One line per input reduced: event type / itemId / final / text, relative ms and whether the chat exists.
    /// Logged before the new state is applied, so phase is the phase the input was reduced in.
    /// Assistant audio chunks with no effect (~30 ms apart) are logged in Debug builds only.
    private func log(_ input: Logic.Input, effects: [Logic.Effect]) {
        let detail: String
        switch input {
        case let .event(event):
            #if !DEBUG
            if case .assistantAudio = event, effects.isEmpty { return }
            #endif
            detail = RealtimeVoiceLog.describe(event)
        case .tick: return
        default: detail = "input \(input)"
        }
        let conversation = sink.hasConversation.map { $0 ? "yes" : "no" } ?? "unknown"
        let elapsed = clock.nowMs - startedAtMs
        RealtimeVoiceLog.logger.info(
            "event \(detail, privacy: .public) t=\(elapsed)ms conversation=\(conversation, privacy: .public) phase=\(String(describing: self.state.phase), privacy: .public)"
        )
    }

    private func logEffect(_ effect: String) {
        let elapsed = clock.nowMs - startedAtMs
        RealtimeVoiceLog.logger.info("effect \(effect, privacy: .public) t=\(elapsed)ms")
    }

    private func perform(_ effect: Logic.Effect) {
        switch effect {
        case let .persist(role, text):
            logEffect("persist role=\(role) text=\(RealtimeVoiceLog.text(text))")
            switch role {
            case .user: sink.appendUser(text)
            case .assistant: sink.appendAssistant(text)
            }
        case .interruptPlayback:
            driver.interruptPlayback()
        case let .sendSilence(ms):
            connection.sendAudio(Self.silence(ms: ms, sampleRate: connection.uplinkSampleRate))
        case let .setUplink(on):
            gate.uplinkOn = on
        case .earcon:
            audio.playEarcon(.thinking)
        case let .showError(code):
            showsError = true
            publish()
            onError(code)
        case let .writeDraft(text):
            draft = text
        case .close:
            ticker?.cancel()
            ticker = nil
            gate.uplinkOn = false
            connection.close()
            gate.stopIfRunning()
        case let .ended(reason):
            logEffect("ended reason=\(reason)")
            gate.stopIfRunning()
            let text = draft
            draft = nil
            sink.conversationEnded()
            onEnded(reason, text)
        case .reopen:
            logEffect("reopen closingCurrent=\(reducingPlanChange)")
            replanToken += 1
            reopen(closingCurrent: reducingPlanChange)
        }
    }

    private func publish() {
        let display = Self.displayState(state, error: showsError)
        if displayState != display { displayState = display }
        let key: VoiceConversationLogic.StatusKey? = showsError
            ? .error
            : Logic.statusKey(state).flatMap(VoiceConversationLogic.StatusKey.init(rawValue:))
        if statusKey != key { statusKey = key }
        let value: Double = switch display {
        case .listening: frameLevel
        case .speaking: Self.speakingLevel
        default: 0
        }
        if level != value { level = value }
    }

    private static func displayState(_ state: Logic.State, error: Bool) -> VoiceConversationLogic.DisplayState? {
        if error { return .error }
        switch state.phase {
        case .ended: return nil
        case .connecting, .thinking: return .thinking
        case .listening: return state.muted ? .muted : .listening
        case .speaking: return .speaking
        }
    }

    // MARK: Uplink

    /// Main actor: a level already throttled on the audio thread (at most maxUpdatesPerSecond per second).
    private func uplinkLevel(_ value: Double) {
        frameLevel = value
        if displayState == .listening, level != frameLevel { level = frameLevel }
    }

    /// `ms` of mono PCM16 zeros at the transport's uplink sample rate.
    static func silence(ms: Int, sampleRate: Double) -> Data {
        Data(count: Int(sampleRate) * max(0, ms) / 1000 * 2)
    }
}

/// Reopen could not run because the host injected no reopener.
enum RealtimeReopenError: Error {
    case unavailable
}

/// Wraps the audio IO handed to the driver: drops uplink frames while the uplink is off
/// and reports uplink levels / system interruptions back to the controller.
/// Uplink frames run through `RealtimeUplink` on the calling (audio) thread straight to the transport.
/// the inner audio is started once per conversation; a later start from a reopened
/// driver only rebinds the current frame / interruption callbacks to that driver.
private final class GatedAudio: RealtimeAudioIO {
    private let inner: any RealtimeAudioIO
    private let uplink: RealtimeUplink
    var uplinkOn: Bool {
        get { uplink.isOn }
        set { uplink.setOn(newValue) }
    }
    var interruptionObserver: (() -> Void)?
    private var currentOnInterruption: (() -> Void)?
    private var innerStarted = false
    private var innerStopped = false
    var onPlaybackDrained: (() -> Void)?

    init(_ inner: any RealtimeAudioIO, minLevelInterval: Double) {
        self.inner = inner
        uplink = RealtimeUplink(minLevelInterval: minLevelInterval)
        inner.onPlaybackDrained = { [weak self] in self?.onPlaybackDrained?() }
    }

    func startRealtime(
        uplinkSampleRate: Double,
        onFrame: @escaping (Data) -> Void,
        onInterruption: @escaping () -> Void
    ) throws {
        uplink.bind(onFrame, sampleRate: uplinkSampleRate)
        currentOnInterruption = onInterruption
        // Running inner audio: rebind only. After a real stop the inner start runs again (and may throw).
        if innerStarted && !innerStopped { return }
        try inner.startRealtime(
            uplinkSampleRate: uplinkSampleRate,
            // @Sendable: nonisolated, runs on the audio thread without a main-actor hop.
            onFrame: { @Sendable [uplink] frame in uplink.deliver(frame) },
            onInterruption: { [weak self] in
                self?.currentOnInterruption?()
                self?.interruptionObserver?()
            }
        )
        innerStarted = true
        innerStopped = false
    }

    /// Drops uplink frames until the next driver binds a new callback via `startRealtime`.
    func unbindUplink() {
        uplink.bind(nil)
    }

    /// Main actor receiver of throttled uplink levels.
    func observeLevel(_ observer: @escaping @MainActor (Double) -> Void) {
        uplink.observeLevel(observer)
    }

    /// conversation end stops the started inner audio exactly once.
    func stopIfRunning() {
        guard innerStarted, !innerStopped else { return }
        stopRealtime()
    }

    func enqueue(pcm16: Data, itemId: String) {
        inner.enqueue(pcm16: pcm16, itemId: itemId)
    }
    func playedMs(itemId: String) -> Int { inner.playedMs(itemId: itemId) }
    var isPlaying: Bool { inner.isPlaying }
    func stopRealtimePlayback() {
        inner.stopRealtimePlayback()
    }
    func stopRealtime() {
        guard !innerStopped else { return }
        innerStopped = true
        inner.stopRealtime()
    }
    func playEarcon(_ earcon: VoiceConversationLogic.Earcon) { inner.playEarcon(earcon) }
}

/// Audio-thread half of the uplink gate: hands each frame to the transport on the calling thread
/// (the transport serializes under its own lock) and throttles the orb level there; only the level
/// hops to the main actor. State is written from the main actor and read on the audio thread under one lock.
nonisolated final class RealtimeUplink: @unchecked Sendable {
    private let lock = NSLock()
    private var on = true
    private var send: ((Data) -> Void)?
    private let minLevelInterval: Double
    private var window: RealtimeUplinkLevelWindow
    private var levelObserver: (@MainActor (Double) -> Void)?

    init(minLevelInterval: Double) {
        self.minLevelInterval = minLevelInterval
        window = RealtimeUplinkLevelWindow(minDuration: minLevelInterval, sampleRate: RealtimePCM.sampleRate)
    }

    var isOn: Bool { lock.withLock { on } }

    /// Turning the uplink off also drops the partially accumulated level window.
    func setOn(_ value: Bool) {
        lock.withLock {
            on = value
            if !value { window.reset() }
        }
    }

    /// sampleRate: the frames' rate (transport uplink rate); a different rate restarts the level window.
    func bind(_ send: ((Data) -> Void)?, sampleRate: Double? = nil) {
        lock.withLock {
            self.send = send
            if let sampleRate, sampleRate != window.sampleRate {
                window = RealtimeUplinkLevelWindow(minDuration: minLevelInterval, sampleRate: sampleRate)
            }
        }
    }

    func observeLevel(_ observer: @escaping @MainActor (Double) -> Void) {
        lock.withLock { levelObserver = observer }
    }

    /// Any thread: sends while on (even unbound frames still feed the level), publishes at most one level per window.
    func deliver(_ frame: Data) {
        let (send, level, observer) = lock.withLock {
            () -> (((Data) -> Void)?, Double?, (@MainActor (Double) -> Void)?) in
            guard on else { return (nil, nil, nil) }
            return (send, window.add(pcm16: frame), levelObserver)
        }
        send?(frame)
        guard let level, let observer else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { observer(level) }
        } else {
            Task { @MainActor in observer(level) }
        }
    }
}

/// Level window over mono PCM16 LE uplink frames at the transport's uplink rate, same throttle as
/// `DictationLevelWindow`: one level per `minDuration` seconds of audio (window frames from the sample rate),
/// squares accumulated by `DbfsWindowAccumulator`. Audio duration, not wall clock: capture is real time and tests stay deterministic.
nonisolated struct RealtimeUplinkLevelWindow {
    let sampleRate: Double
    private var window: DbfsWindowAccumulator

    init(minDuration: Double, sampleRate: Double) {
        self.sampleRate = sampleRate
        window = DbfsWindowAccumulator(windowFrames: max(1, Int((minDuration * sampleRate).rounded())))
    }

    /// nil until the window holds `minDuration` seconds of audio; a frame closing several windows yields the last one.
    mutating func add(pcm16 frame: Data) -> Double? {
        let count = frame.count / 2
        guard count > 0 else { return nil }
        var level: Double?
        frame.withUnsafeBytes { raw in
            for index in 0..<count {
                let value = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))
                guard window.add(Double(value) / 32_768) else { continue }
                level = Self.level(dbfs: window.take())
            }
        }
        return level
    }

    mutating func reset() {
        window.reset()
    }

    /// dBFS → 0…1 on the `DictationLevelMeter.level(rms:)` scale; digital silence (nil) is 0.
    private static func level(dbfs: Double?) -> Double {
        guard let dbfs else { return 0 }
        return Double(DictationLevelMeter.level(rms: Float(pow(10, dbfs / 20))))
    }
}
