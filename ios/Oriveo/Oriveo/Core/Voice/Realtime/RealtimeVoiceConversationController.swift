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

/// Shared os_log helpers for the realtime voice path (subsystem com.oriveo, category realtime-voice).
nonisolated enum RealtimeVoiceLog {
    static let logger = Logger(subsystem: "com.oriveo", category: "realtime-voice")

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

/// What the stage needs besides the signals to classify and word a failure:
/// the copy placeholder values and the catalog's single-session limit.
nonisolated struct RealtimeFailureContext: Sendable, Equatable {
    /// Provider display name (placeholder of auth / quota copy).
    var providerName: String?
    /// Catalog model (placeholder of model_gone / network / unknown copy).
    var model: String?
    /// Catalog single-session limit; nil = no limit, duration is never judged.
    var maxSessionSec: Double?

    init(providerName: String? = nil, model: String? = nil, maxSessionSec: Double? = nil) {
        self.providerName = providerName
        self.model = model
        self.maxSessionSec = maxSessionSec
    }
}

/// The classified failure the session ended with: category, copy key, placeholder value and actions.
struct RealtimeVoiceFailure: Equatable {
    let classification: RealtimeModelPolicy.FailureClassification
    /// Value for the copy placeholder (`classification.copyArg`); nil when the copy has none or it is unknown.
    let copyArgValue: String?
}

/// Controller contract: feeds driver events and local input into `RealtimeConversationLogic`
/// and performs the returned effects in order. The UI reads displayState / statusKey / level only.
final class RealtimeVoiceConversationController: ObservableObject {
    typealias Logic = RealtimeConversationLogic
    typealias Connection = any RealtimeTransport & RealtimeSessionControl
    /// the host builds a fresh plan (same projection path, current history) and opens a new connection.
    typealias Reopener = () async throws -> (connection: Connection, plan: PlannedRealtimeSession)
    /// realtime-session.v1 turn boundary: replans with currentSessionId = the open session and returns the
    /// new fingerprint (nil when no plan can be made). Called off the main thread; it must not need the main actor.
    typealias Replanner = @Sendable () async -> RealtimeSessionFingerprint?
    /// Refetches the catalog and answers whether it still lists this session's model
    /// (nil = catalog unavailable or the fetch failed; cancellation is rethrown). Called off the main thread.
    typealias CatalogCheck = @Sendable () async throws -> Bool?

    @Published private(set) var displayState: VoiceConversationLogic.DisplayState?
    @Published private(set) var statusKey: VoiceConversationLogic.StatusKey?
    /// 0...1 orb level: latest throttled uplink peak while listening, the played output's peak while speaking,
    /// otherwise 0; at most ~15 updates per second either way.
    @Published private(set) var level: Double = 0
    /// The failure the session ended with (set together with `showError`); nil while it has not failed.
    @Published private(set) var failure: RealtimeVoiceFailure?
    /// The stage line, recomputed after every reduce (so it follows playback progress): the user's
    /// not-yet-final transcript, else the assistant text revealed by the played ratio while speaking, else the
    /// status word; error / auto-reopen show the published status key; nil once ended. Only changed values are published.
    @Published private(set) var stageLine: Logic.StageLine?
    /// Stage caption = the text of `stageLine` (user or assistant); nil = the bar shows the status word.
    @Published private(set) var caption: String?
    /// Live chat-list bubbles, recomputed after every reduce; a side goes nil in the reduce that emits its persist
    /// effect (the persist counts of that reduce are already in the same value) and both on end / error.
    /// Only changed values are published.
    @Published private(set) var drafts = RealtimeDrafts()

    private var connection: Connection
    private let audio: any RealtimeAudioIO
    private let gate: GatedAudio
    /// One driver per session run; a reopen replaces it together with the connection.
    private var driver: RealtimeConversationDriver
    private var plan: PlannedRealtimeSession
    private let reopener: Reopener?
    private let replanner: Replanner?
    private let catalogCheck: CatalogCheck?
    /// Some connection of this call reached ready: later failures do not refetch the catalog.
    private var everReady = false
    /// A failure is waiting for its catalog refetch; further failures are dropped until it ends the call.
    private var catalogCheckTask: Task<Void, Never>?
    private let sink: RealtimeConversationSink
    /// Persist effects emitted so far per role and the text of the latest one (see RealtimeDrafts).
    private var userPersisted = 0
    private var assistantPersisted = 0
    private var userPersistedText: String?
    private var assistantPersistedText: String?
    private let clock: VoiceConversationClock
    private let onError: (String) -> Void
    private let onEnded: (Logic.EndReason, String?) -> Void
    private let failureContext: RealtimeFailureContext
    /// Clock time the current connection became ready (nil before its ready): elapsedSec of a failure.
    private var connectedAtMs: Int?
    /// Code of the latest unified error event on the current connection: errorCode of the next close.
    private var lastErrorCode: String?
    /// One-shot handshake deadline of the current connection (connectTimeoutMs); cancelled by its ready.
    private var connectTimer: VoiceConversationTimer?
    /// The current connection was opened by a reopen: failing before its ready is a failed reopen.
    private var runIsReopen = false
    /// Automatic reopens left before the next ready; an unexpected drop after ready uses one.
    private var autoReopensLeft = RealtimeModelPolicy.Constants.autoReopenAttempts
    /// An automatic reopen is in flight (drop until the new connection's ready): the orb stays listening, dimmed.
    private var autoReopening = false

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
    /// Latest published playback output peak (0...1, mapped against `ConversationAudioMath.aiFloorDb`).
    private var outputLevelValue: Double = 0
    /// Output peak accumulated in the current window (nil = nothing yet).
    private var outputPeak: Double?
    private var outputLevelAtMs: Int?
    /// The one armed one-shot timer (at the reducer's next deadline); never a periodic tick.
    private var ticker: VoiceConversationTimer?
    /// One-shot playback progress beat, armed only while speaking; re-armed each time it fires.
    private var progressTimer: VoiceConversationTimer?
    /// The beat fired: the next run reports playback progress before its inputs.
    private var progressDue = false
    /// When the turn's played ms last changed while a completed reply waits for its drain, and its value then.
    private var stalledSince: Int?
    private var stalledPlayed: [String: Int] = [:]
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
    /// False = the session was opened by typed text, so every run starts playback only (mic stays off).
    private var captureOnReady = true
    /// Typed turns waiting for the current connection's ready (the GA transport drops text before it).
    private var pendingTypedTexts: [String] = []
    /// Speaker gate speech model (nil = energy only); loaded in the background when the conversation starts.
    private let speechModelLoader: RealtimeSpeechProbLoading.Loader?

    init(
        connection: Connection,
        audio: any RealtimeAudioIO,
        plan: PlannedRealtimeSession,
        sink: RealtimeConversationSink,
        clock: VoiceConversationClock = SystemVoiceConversationClock(),
        reopener: Reopener? = nil,
        replanner: Replanner? = nil,
        catalogCheck: CatalogCheck? = nil,
        speechModel: RealtimeSpeechProbLoading.Loader? = RealtimeSpeechProbLoading.silero,
        failureContext: RealtimeFailureContext = RealtimeFailureContext(),
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
        self.catalogCheck = catalogCheck
        self.onError = onError
        self.onEnded = onEnded
        self.failureContext = failureContext
        speechModelLoader = speechModel
        let gate = GatedAudio(audio, minLevelInterval: 1 / DictationLevelMeter.maxUpdatesPerSecond)
        self.gate = gate
        driver = RealtimeConversationDriver(connection: connection, audio: gate)
        gate.observeLevel { [weak self] level in self?.uplinkLevel(level) }
        gate.onOutputLevel = { [weak self] db in self?.outputLevel(db) }
        gate.interruptionObserver = { [weak self] in self?.dispatch(.systemInterruption) }
        gate.onPlaybackDrained = { [weak self] in self?.drainIfIdle() }
        // The connection of the moment (a reopen replaces it) updates its route-dependent session settings.
        gate.onRouteChanged = { [weak self] route in self?.connection.updateOutputRoute(route) }
        gate.observeGateOpened { [weak self] in self?.dispatch(.gateOpened) }
        // With a reopener a dropped connection may be reopened: only the conversation end stops the audio.
        gate.keepsAudioOnDriverStop = reopener != nil
        publish()
    }

    // MARK: Actions

    /// Opens the session. Calling it again is a no-op.
    func start() {
        guard !started else { return }
        started = true
        startedAtMs = clock.nowMs
        if let speechModelLoader { gate.loadSpeechModel(speechModelLoader) }
        runSession()
    }

    private func runSession(reopened: Bool = false) {
        sessionRun += 1
        let run = sessionRun
        connectedAtMs = nil
        lastErrorCode = nil
        runIsReopen = reopened
        connectTimer?.cancel()
        connectTimer = clock.after(ms: RealtimeModelPolicy.Constants.connectTimeoutMs) { [weak self] in
            self?.connectTimedOut(run: run)
        }
        let events = driver.run(plan: plan)
        streamTask = Task { [weak self] in
            do {
                for try await event in events {
                    guard let self, self.sessionRun == run else { return }
                    self.noteFailureSignal(event)
                    self.dispatch(.event(event))
                    if case .ready = event { self.flushTypedTexts() }
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
                self.streamFailed(error)
            }
        }
    }

    /// The stream threw. Before ready: the connection (or the reopen) failed. After ready: an unexpected drop
    /// (Gemini has already tried its handle resumes) reopens with history while attempts are left;
    /// failures a reopen cannot fix (auth, quota, model gone, max duration) end right away.
    /// Non-Gemini drops follow RealtimeModelPolicy.afterDrop first: a reopened connection
    /// dropping before any turn progress ends as unknown even while muted; muted and progress come from the reducer.
    private func streamFailed(_ error: Error) {
        connectTimer?.cancel()
        connectTimer = nil
        guard connectedAtMs != nil else {
            fail(error, reopenFailed: runIsReopen)
            return
        }
        let category = RealtimeModelPolicy.classifyFailure(failureSignal(error, reopenFailed: false)).category
        if connection.kind != .geminiLive {
            let outcome = RealtimeModelPolicy.afterDrop(
                provider: Self.policyProvider(connection.kind), category: category,
                muted: state.muted, reopenedWithoutProgress: state.reopenAwaitingProgress
            )
            if outcome.action == .end, let code = outcome.code {
                autoReopening = false
                dispatch(.failed(code: code))
                return
            }
        }
        guard reopener != nil, autoReopensLeft > 0, state.phase != .ended,
              category == .network || category == .unknown else {
            fail(error, reopenFailed: false)
            return
        }
        autoReopensLeft -= 1
        autoReopening = true
        logEffect("autoReopen error=\(String(describing: type(of: error)))")
        // Frames must not reach the dead connection; the reopened driver rebinds on its ready.
        gate.unbindUplink()
        connection.close()
        // Same reducer path as an expiry: flush what was heard, then reopen with text history.
        dispatch(.sessionExpired)
    }

    /// Provider kind names RealtimeModelPolicy.afterDrop takes (same as the realtime-model fixture).
    private static func policyProvider(_ kind: RealtimeTransportKind) -> String {
        switch kind {
        case .openaiRealtime: "openAI"
        case .xaiRealtime: "xai"
        case .geminiLive: "gemini"
        }
    }

    /// The handshake did not complete within connectTimeoutMs: retire the connection and fail.
    private func connectTimedOut(run: Int) {
        connectTimer = nil
        guard sessionRun == run, connectedAtMs == nil, state.phase != .ended else { return }
        sessionRun += 1
        gate.unbindUplink()
        driver.retire()
        connection.close()
        var signal = failureSignal(nil, reopenFailed: runIsReopen)
        signal.connectError = nil
        signal.connectTimedOut = true
        fail(signal)
    }

    /// Ready starts the connection's elapsed time; a unified error event is not fatal, only kept as a signal.
    private func noteFailureSignal(_ event: RealtimeSessionEvent) {
        switch event {
        case .ready where connectedAtMs == nil:
            connectedAtMs = clock.nowMs
            everReady = true
            connectTimer?.cancel()
            connectTimer = nil
            autoReopensLeft = RealtimeModelPolicy.Constants.autoReopenAttempts
            autoReopening = false
        case let .error(code, _): lastErrorCode = code
        default: break
        }
    }

    /// Collects the normalized signals of this failure and ends with its category.
    private func fail(_ error: Error, reopenFailed: Bool) {
        fail(failureSignal(error, reopenFailed: reopenFailed))
    }

    /// Before any ready of this call the catalog is refetched first (async, off the main thread):
    /// A model no longer listed is model_gone.
    private func fail(_ signal: RealtimeModelPolicy.FailureSignal) {
        autoReopening = false
        guard let catalogCheck, !everReady else {
            finishFailure(signal)
            return
        }
        guard catalogCheckTask == nil else { return }
        catalogCheckTask = Task { [weak self] in
            var signal = signal
            do {
                signal.catalogHasModel = try await catalogCheck()
            } catch is CancellationError {
                return
            } catch {
                signal.catalogHasModel = nil
            }
            guard let self else { return }
            self.catalogCheckTask = nil
            guard self.state.phase != .ended else { return }
            self.finishFailure(signal)
        }
    }

    private func finishFailure(_ signal: RealtimeModelPolicy.FailureSignal) {
        let category = RealtimeModelPolicy.classifyFailure(signal).category
        dispatch(.failed(code: category.rawValue))
    }

    /// No ready on the current connection = the connection could not be made (connectError).
    /// The uplink backlog is the connection's own reading (Gemini and GA both report it; nil is not judged).
    private func failureSignal(_ error: Error?, reopenFailed: Bool) -> RealtimeModelPolicy.FailureSignal {
        var signal = RealtimeModelPolicy.FailureSignal(
            httpStatus: (error as? RealtimeHTTPStatusError)?.httpStatus,
            errorCode: lastErrorCode,
            maxSessionSec: failureContext.maxSessionSec,
            uplinkBacklogMs: connection.uplinkBacklogMs
        )
        if let connectedAtMs {
            signal.elapsedSec = Double(clock.nowMs - connectedAtMs) / 1000
        } else if !reopenFailed {
            signal.connectError = true
        }
        if reopenFailed { signal.reopenFailed = true }
        return signal
    }

    /// Swap in the reopened connection and run a new driver on it; the same sink
    /// keeps receiving turns and the host gets no ended. A missing or throwing reopener fails the call.
    /// `closingCurrent`: the current connection is still live (planChanged); it is retired and closed first,
    /// and its stream's remaining inputs are dropped, so the shared audio keeps running.
    private func reopen(closingCurrent: Bool) {
        guard let reopener else {
            fail(RealtimeReopenError.unavailable, reopenFailed: false)
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
                self.driver = RealtimeConversationDriver(
                    connection: reopened.connection, audio: self.gate, captureOnReady: self.captureOnReady
                )
                self.runSession(reopened: true)
            } catch {
                self?.fail(error, reopenFailed: true)
            }
        }
    }

    /// Same code the cascade uses when the home first send cannot create the chat (the reducer files it as unknown).
    static let conversationUnavailableCode = "send_failed"

    /// The stage's view of a failure category: copy key, placeholder value and actions (same tables as classifyFailure).
    static func failure(category: RealtimeModelPolicy.FailureCategory, context: RealtimeFailureContext) -> RealtimeVoiceFailure {
        let actions = RealtimeModelPolicy.actions(for: category)
        let classification = RealtimeModelPolicy.FailureClassification(
            category: category,
            copyKey: RealtimeModelPolicy.copyKey(for: category),
            copyArg: RealtimeModelPolicy.copyArg(for: category),
            actions: actions,
            actionCopyKeys: actions.map { RealtimeModelPolicy.copyKey(for: $0) },
            buttonCopyKeys: RealtimeModelPolicy.buttonCopyKeys(for: actions)
        )
        let value: String? = switch classification.copyArg {
        case .provider: context.providerName
        case .model: context.model
        case .none: nil
        }
        return RealtimeVoiceFailure(classification: classification, copyArgValue: value)
    }

    func tapOrb() { dispatch(.tapOrb) }

    /// One typed user turn to the realtime model. Not started yet: opens the session playback only
    /// (no mic). The text is queued and only goes out on a ready connection (now, or after the next ready);
    /// while queued it is not persisted, so a reopen's projected history does not carry it twice.
    func sendTypedText(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, state.phase != .ended else { return }
        if !started {
            captureOnReady = false
            driver = RealtimeConversationDriver(connection: connection, audio: gate, captureOnReady: false)
            start()
        }
        pendingTypedTexts.append(text)
        // Dormant (expired while muted): the connection is dead; queue and wake a reopen.
        if state.dormant {
            dispatch(.wake)
            return
        }
        if connectedAtMs != nil && state.phase != .connecting { flushTypedTexts() }
    }

    /// The current connection is ready: sends the queued typed turns in order. Each one first goes through the
    /// reducer as a finished user utterance (barge-in truncates a playing reply, the sink persists it once),
    /// then it is sent; if that turn ended the session (the chat could not be created) nothing more is sent.
    private func flushTypedTexts() {
        guard !pendingTypedTexts.isEmpty, state.phase != .ended, !state.dormant else { return }
        let texts = pendingTypedTexts
        pendingTypedTexts = []
        for text in texts {
            dispatch(.event(.userSpeechStarted(itemId: nil)))
            dispatch(.event(.userSpeechStopped(itemId: nil)))
            dispatch(.event(.userTranscript(itemId: nil, text: text, final: true)))
            guard state.phase != .ended else { return }
            logEffect("sendText text=\(RealtimeVoiceLog.text(text))")
            connection.sendText(text)
        }
    }

    /// Typing mode back to voice: a playback-only session adds mic capture and uplink on the same
    /// connection, without reopening. A playing reply is cut first exactly like a tap on the orb (progress
    /// reported, truncated at the played ms). A capture failure closes the connection and ends the session.
    /// Already capturing (or not started / ended): a no-op. Later reopens start with capture.
    func resumeVoiceCapture() {
        guard started, !captureOnReady, state.phase != .ended else { return }
        captureOnReady = true
        logEffect("resumeVoiceCapture phase=\(state.phase)")
        if state.phase == .speaking { dispatch(.tapOrb) }
        driver.startCapture()
    }

    /// Started playback-only by typing and the mic was never added: the user has not spoken in this session.
    var isTypedOnly: Bool { started && !captureOnReady }

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
        if progressDue {
            progressDue = false
            reportProgress()
            drainIfStalled()
        }
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
            // An input that may freeze the reply first gets the player's real played ms.
            if Self.mayFreeze(next) { reportProgress() }
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
        armProgressBeat()
    }

    /// Barge-in, tap, interrupted, end, system interruption and the other inputs that freeze or flush the reply.
    private static func mayFreeze(_ input: Logic.Input) -> Bool {
        switch input {
        case .tapOrb, .end, .systemInterruption, .failed, .sessionExpired, .planChanged:
            true
        case let .event(event):
            switch event {
            case .userSpeechStarted, .userTranscript, .interrupted, .sessionEnded: true
            default: false
            }
        default:
            false
        }
    }

    /// Reports the played ms of every item of this turn's audio; only while speaking and not yet frozen
    /// (the reducer ignores it otherwise, so the player is not read).
    private func reportProgress() {
        guard state.phase == .speaking, state.turn.frozenPlayedMs == nil else { return }
        for key in state.turn.audioItems {
            reduce(.playbackProgress(itemId: key.isEmpty ? nil : key, playedMs: gate.playedMs(itemId: key)))
        }
    }

    /// Backstop for a drained callback that never comes. The reply is
    /// complete, the played ms moved at least once this turn, and then stood still for `drainStallMs`:
    /// the tail is played out. The stuck remainder is stopped (which also ends the uplink's playback
    /// gate, as the natural drain does) and the full text is persisted. A head that never moved is a
    /// player not started yet, not a stuck tail.
    private func drainIfStalled() {
        let played = state.turn.played
        guard state.phase == .speaking, state.drainPending, state.turn.frozenPlayedMs == nil,
              played.values.contains(where: { $0 > 0 })
        else {
            stalledSince = nil
            return
        }
        guard let since = stalledSince, played == stalledPlayed else {
            stalledSince = clock.nowMs
            stalledPlayed = played
            return
        }
        guard clock.nowMs - since >= Self.drainStallMs else { return }
        stalledSince = nil
        RealtimeVoiceLog.logger.info("playback stalled \(self.clock.nowMs - since, privacy: .public)ms after turn done: drained")
        gate.stopRealtimePlayback()
        pendingInputs.append(.playbackDrained)
    }

    /// While speaking one one-shot beat is armed every `progressBeatMs`; leaving speaking cancels it.
    private func armProgressBeat() {
        guard state.phase == .speaking, state.turn.frozenPlayedMs == nil else {
            progressTimer?.cancel()
            progressTimer = nil
            return
        }
        guard progressTimer == nil else { return }
        progressTimer = clock.after(ms: Self.progressBeatMs) { [weak self] in self?.progressBeat() }
    }

    private func progressBeat() {
        progressTimer = nil
        progressDue = true
        run(nil)
    }

    /// The host reports playback progress at most this far apart while speaking.
    static let progressBeatMs = 100

    /// Played ms standing still this long after the reply completed counts as played out.
    static let drainStallMs = 300

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
        for case let .persist(role, text) in effects {
            switch role {
            case .user:
                userPersisted += 1
                userPersistedText = text
            case .assistant:
                assistantPersisted += 1
                assistantPersistedText = text
            }
        }
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
        case .tick, .playbackProgress: return
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
            failure = Self.failure(category: RealtimeModelPolicy.FailureCategory(rawValue: code) ?? .unknown, context: failureContext)
            publish()
            onError(code)
        case let .writeDraft(text):
            draft = text
        case .close:
            ticker?.cancel()
            ticker = nil
            connectTimer?.cancel()
            connectTimer = nil
            progressTimer?.cancel()
            progressTimer = nil
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
        case .disableBargeIn:
            logEffect("disableBargeIn")
            gate.setBargeIn(false)
        }
    }

    /// An automatic reopen is connecting: shown as listening with no level, not as thinking.
    private var listensDimmed: Bool {
        autoReopening && !showsError && state.phase == .connecting
    }

    private func publish() {
        let dimmed = listensDimmed
        let display: VoiceConversationLogic.DisplayState? = dimmed ? .listening : Self.displayState(state, error: showsError)
        if displayState != display { displayState = display }
        let key: VoiceConversationLogic.StatusKey? = if showsError {
            .error
        } else if dimmed {
            .listening
        } else {
            Logic.statusKey(state).flatMap(VoiceConversationLogic.StatusKey.init(rawValue:))
        }
        if statusKey != key { statusKey = key }
        let value: Double = switch display {
        case .listening: dimmed ? 0 : frameLevel
        case .speaking: outputLevelValue
        default: 0
        }
        if level != value { level = value }
        let cleared = showsError || state.phase == .ended
        let nextLine: Logic.StageLine? = if showsError || dimmed {
            key.map { .status(key: $0.rawValue) }
        } else {
            Logic.stageLine(state)
        }
        if stageLine != nextLine { stageLine = nextLine }
        let nextCaption: String? = switch nextLine {
        case let .user(text), let .assistant(text): text
        case .status, .notice, nil: nil
        }
        if caption != nextCaption { caption = nextCaption }
        let assistantText = cleared ? "" : Logic.assistantShown(state)
        let nextDrafts = RealtimeDrafts(
            user: cleared ? nil : Logic.userCaption(state),
            assistant: assistantText.isEmpty ? nil : assistantText,
            userAfterAssistant: cleared ? false : state.turn.userAfterReply,
            userPersisted: userPersisted,
            assistantPersisted: assistantPersisted,
            userPersistedText: userPersistedText,
            assistantPersistedText: assistantPersistedText
        )
        if drafts != nextDrafts { drafts = nextDrafts }
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
        if displayState == .listening, !listensDimmed, level != frameLevel { level = frameLevel }
    }

    /// Main actor: one played-output dBFS block; publishes the window's peak at most once per levelIntervalMs.
    /// Outside speaking the output (earcons, tails) is not the orb's: the window restarts at the next speaking turn.
    private func outputLevel(_ db: Double) {
        guard displayState == .speaking else {
            outputPeak = nil
            outputLevelValue = 0
            return
        }
        let peak = max(outputPeak ?? 0, ConversationAudioMath.level(db: db, floorDb: ConversationAudioMath.aiFloorDb))
        outputPeak = peak
        let now = clock.nowMs
        if let last = outputLevelAtMs, now - last < VoiceConversationController.levelIntervalMs { return }
        outputLevelAtMs = now
        outputPeak = nil
        outputLevelValue = peak
        if level != peak { level = peak }
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
/// Playback cycles drive the speaker uplink gate: a cycle starts when the first block makes the player busy
/// (the route is sampled then) and ends when the player drains or playback is stopped locally.
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
    /// A driver's own stop of running audio (its stream ended or failed) is ignored: the controller may still
    /// reopen and stops the audio itself when the conversation ends (`stopIfRunning`).
    var keepsAudioOnDriverStop = false
    private var currentOnInterruption: (() -> Void)?
    private var innerStarted = false
    private var innerStopped = false
    /// The running inner audio captures the mic (false after a playback-only start).
    private var innerCapturing = false
    /// The conversation ended before the inner audio started: a prepare still in flight must not start it.
    private var closed = false
    /// Speech model load in flight; consumed by the first prepare.
    private var speechModelLoad: Task<RealtimeSpeechProbBox?, Never>?
    var onPlaybackDrained: (() -> Void)?
    /// Route changes after the speaker gate has re-judged them; the controller hands them to the current connection.
    var onRouteChanged: ((VoiceConversationLogic.Route) -> Void)?
    var onOutputLevel: ((Double) -> Void)? {
        get { inner.onOutputLevel }
        set { inner.onOutputLevel = newValue }
    }

    init(_ inner: any RealtimeAudioIO, minLevelInterval: Double) {
        self.inner = inner
        let reference = PlaybackReferenceTap(inner)
        uplink = RealtimeUplink(minLevelInterval: minLevelInterval, reference: { reference.dbs(behindSamples: $0) })
        inner.onPlaybackDrained = { [weak self] in
            self?.uplink.playbackEnded()
            self?.onPlaybackDrained?()
        }
        // A route change mid-conversation re-judges the speaker gate right away (not at the next connection).
        inner.onRouteChanged = { [weak self] route in
            self?.uplink.routeChanged(route: route)
            self?.onRouteChanged?(route)
        }
    }

    /// Running inner audio already holds an active session; otherwise the inner prepares it before its start.
    func prepareSession() async throws {
        if innerStarted && !innerStopped { return }
        // Ended before a late ready: do not activate the session only to deactivate it again.
        if closed { throw CancellationError() }
        try await inner.prepareSession()
        // Capture waits for the speech model at most RealtimeSpeechProbLoading.limit after the conversation
        // started; not ready by then = this conversation's gate runs on energy only.
        if let load = speechModelLoad {
            speechModelLoad = nil
            let loaded = await load.value
            // Ended while waiting: the late model is dropped here (and the uplink refuses it once closed).
            if !closed { uplink.setSpeechModel(loaded?.model) }
        }
        // Ended while preparing: undo the prepared session instead of starting the engine.
        if closed {
            innerStopped = true
            inner.stopRealtime()
            throw CancellationError()
        }
    }

    func startRealtime(
        uplinkSampleRate: Double,
        onFrame: @escaping (Data) -> Void,
        onInterruption: @escaping () -> Void
    ) throws {
        uplink.bind(onFrame, sampleRate: uplinkSampleRate)
        currentOnInterruption = onInterruption
        // Running inner audio: rebind only (a playback-only inner adds capture in place).
        // After a real stop the inner start runs again (and may throw).
        if innerStarted && !innerStopped {
            if !innerCapturing { try startInnerCapture(uplinkSampleRate: uplinkSampleRate) }
            return
        }
        try inner.startRealtime(
            uplinkSampleRate: uplinkSampleRate,
            onFrame: innerFrameSink(),
            onInterruption: innerInterruption()
        )
        innerStarted = true
        innerStopped = false
        innerCapturing = true
    }

    /// Playback-only start; running inner audio only rebinds the interruption callback.
    func startRealtimePlayback(onInterruption: @escaping () -> Void) throws {
        currentOnInterruption = onInterruption
        if innerStarted && !innerStopped { return }
        try inner.startRealtimePlayback(onInterruption: innerInterruption())
        innerStarted = true
        innerStopped = false
        innerCapturing = false
    }

    /// Adds mic capture to playback-only inner audio; already capturing only rebinds the frame callback.
    func startRealtimeCapture(uplinkSampleRate: Double, onFrame: @escaping (Data) -> Void) throws {
        uplink.bind(onFrame, sampleRate: uplinkSampleRate)
        guard !innerCapturing else { return }
        try startInnerCapture(uplinkSampleRate: uplinkSampleRate)
    }

    private func startInnerCapture(uplinkSampleRate: Double) throws {
        try inner.startRealtimeCapture(uplinkSampleRate: uplinkSampleRate, onFrame: innerFrameSink())
        innerCapturing = true
    }

    /// @Sendable: nonisolated, runs on the audio thread without a main-actor hop.
    private func innerFrameSink() -> @Sendable (Data) -> Void {
        { @Sendable [uplink] frame in uplink.deliver(frame) }
    }

    private func innerInterruption() -> () -> Void {
        { [weak self] in
            self?.currentOnInterruption?()
            self?.interruptionObserver?()
        }
    }

    /// Starts loading the speaker gate's speech model off the main thread (once per conversation).
    func loadSpeechModel(_ loader: @escaping RealtimeSpeechProbLoading.Loader) {
        guard speechModelLoad == nil, !innerStarted else { return }
        speechModelLoad = Task { await RealtimeSpeechProbLoading.load(loader) }
    }

    /// Drops uplink frames until the next driver binds a new callback via `startRealtime`.
    func unbindUplink() {
        uplink.bind(nil)
    }

    /// Main actor receiver of throttled uplink levels.
    func observeLevel(_ observer: @escaping @MainActor (Double) -> Void) {
        uplink.observeLevel(observer)
    }

    /// Main actor receiver of "the speaker gate opened on local voice".
    func observeGateOpened(_ observer: @escaping @MainActor () -> Void) {
        uplink.observeGateOpened(observer)
    }

    func setBargeIn(_ on: Bool) {
        uplink.setBargeIn(on)
    }

    /// Conversation end stops the started inner audio exactly once.
    /// Before the inner start, marks the gate closed so an in-flight prepare stops instead of starting.
    /// Also closes the speech model right away (not at deinit); a model still loading is dropped when it arrives.
    func stopIfRunning() {
        uplink.closeSpeechModel()
        speechModelLoad = nil
        guard innerStarted else {
            closed = true
            return
        }
        guard !innerStopped else { return }
        stopInner()
    }

    func enqueue(pcm16: Data, itemId: String) {
        let wasPlaying = inner.isPlaying
        inner.enqueue(pcm16: pcm16, itemId: itemId)
        if !wasPlaying, inner.isPlaying { uplink.playbackStarted(route: inner.route) }
    }
    func playedMs(itemId: String) -> Int { inner.playedMs(itemId: itemId) }
    var isPlaying: Bool { inner.isPlaying }
    var route: VoiceConversationLogic.Route { inner.route }
    func stopRealtimePlayback() {
        inner.stopRealtimePlayback()
        uplink.playbackEnded()
    }
    func stopRealtime() {
        // Not started yet (ended while preparing): the prepared session is still undone.
        guard !(keepsAudioOnDriverStop && innerStarted) else { return }
        stopInner()
    }

    private func stopInner() {
        guard !innerStopped else { return }
        innerStopped = true
        inner.stopRealtime()
    }
    func playEarcon(_ earcon: VoiceConversationLogic.Earcon) { inner.playEarcon(earcon) }
}

/// Audio-thread handle on the inner audio's downlink reference (only its nonisolated reader is called here).
private nonisolated final class PlaybackReferenceTap: @unchecked Sendable {
    private let source: any RealtimeAudioIO

    init(_ source: any RealtimeAudioIO) {
        self.source = source
    }

    func dbs(behindSamples: [Int]) -> [Double?] { source.playbackReferenceDb(behindSamples: behindSamples) }
}

/// Audio-thread half of the uplink gate: hands each frame to the transport on the calling thread
/// (the transport serializes under its own lock) and throttles the orb level there; only the level
/// and the speaker gate's voice opening hop to the main actor. State is written from the main actor and read
/// on the audio thread under one lock; the speaker gate (`RealtimeUplinkGate`) runs under the same lock.
/// Mute / screen reader (uplink off) wins over the gate: frames are dropped, the gate is still fed to keep time.
nonisolated final class RealtimeUplink: @unchecked Sendable {
    private let lock = NSLock()
    private var on = true
    private var send: ((Data) -> Void)?
    private let minLevelInterval: Double
    private var window: RealtimeUplinkLevelWindow
    private var levelObserver: (@MainActor (Double) -> Void)?
    private var gate = RealtimeUplinkGate()
    private var gateOpenedObserver: (@MainActor () -> Void)?
    /// Bytes of one gate frame (frameMs of mono PCM16 at the frames' rate).
    private var gateFrameBytes: Int
    /// The gate frame being filled; its first `pendingSentBytes` bytes already went out (passed before arming).
    private var pending = Data()
    private var pendingSentBytes = 0
    /// Held whole gate frames by index: flushed from the gate's flushFrom on open, the rest dropped.
    private var held: [(frame: Int, data: Data)] = []
    /// Cap on held frames (2 s): a flush never reaches further back than the VAD preroll (≤ ~30 frames),
    /// so a long reply or a lost end-of-playback signal cannot grow the queue without bound.
    static let maxHeldFrames = 100
    /// Mirrors the gate being armed: new bytes are held until the gate decides.
    private var holding = false
    /// Speech model (model mode): fed every gate frame from capture start, resampled to 16 kHz.
    /// nil = energy only (never loaded, or inference failed: never comes back this session).
    /// The feed itself is only used on the deliver thread, outside the lock; the lock guards the reference.
    private var speech: RealtimeSpeechFeed?
    /// The conversation ended: the model is gone and a late one is refused.
    private var speechClosed = false
    private static let logger = Logger(subsystem: "com.oriveo", category: "realtime-voice")

    /// Any thread: the downlink reference level at each `behindSamples` (24 kHz) before one playback head reading.
    private let reference: @Sendable (_ behindSamples: [Int]) -> [Double?]

    /// Downlink samples per gate frame: a gate frame k frames older than the newest looks k blocks behind the head.
    static let referenceBlockSamples = Int(RealtimePCM.sampleRate) * VoiceConversationLogic.Constants.frameMs / 1000

    init(minLevelInterval: Double, reference: @escaping @Sendable (_ behindSamples: [Int]) -> [Double?] = { $0.map { _ in nil } }) {
        self.minLevelInterval = minLevelInterval
        self.reference = reference
        window = RealtimeUplinkLevelWindow(minDuration: minLevelInterval, sampleRate: RealtimePCM.sampleRate)
        gateFrameBytes = Self.gateFrameBytes(sampleRate: RealtimePCM.sampleRate)
    }

    private static func gateFrameBytes(sampleRate: Double) -> Int {
        max(2, Int(sampleRate) * VoiceConversationLogic.Constants.frameMs / 1000 * 2)
    }

    var isOn: Bool { lock.withLock { on } }

    var heldFrameCount: Int { lock.withLock { held.count } }

    /// Turning the uplink off also drops the partially accumulated level window.
    func setOn(_ value: Bool) {
        lock.withLock {
            on = value
            if !value {
                window.reset()
                held.removeAll()
            }
        }
    }

    /// sampleRate: the frames' rate (transport uplink rate); a different rate restarts the level window.
    func bind(_ send: ((Data) -> Void)?, sampleRate: Double? = nil) {
        lock.withLock {
            self.send = send
            if let sampleRate, sampleRate != window.sampleRate {
                window = RealtimeUplinkLevelWindow(minDuration: minLevelInterval, sampleRate: sampleRate)
                gateFrameBytes = Self.gateFrameBytes(sampleRate: sampleRate)
                pending = Data()
                pendingSentBytes = 0
                held.removeAll()
                // The model keeps its state; only the resampler follows the new frame rate (no resampler = failure).
                if let current = speech {
                    speech = current.rebound(sourceSampleRate: sampleRate)
                    if speech == nil { Self.logger.error("realtime speech model resampler unavailable") }
                }
            }
        }
    }

    /// Before capture starts: installs the loaded speech model; every later gate frame carries its prob.
    /// Refused once closed; no resampler for the frame rate = no model (energy for the whole session).
    func setSpeechModel(_ model: (any RealtimeSpeechProb)?) {
        lock.withLock {
            guard !speechClosed else { return }
            speech = model.flatMap { RealtimeSpeechFeed(model: $0, sourceSampleRate: window.sampleRate) }
            if model != nil, speech == nil { Self.logger.error("realtime speech model resampler unavailable") }
        }
    }

    /// Main actor, conversation end: drops the speech model now and refuses a late one.
    func closeSpeechModel() {
        lock.withLock {
            speechClosed = true
            speech = nil
        }
    }

    func observeLevel(_ observer: @escaping @MainActor (Double) -> Void) {
        lock.withLock { levelObserver = observer }
    }

    func observeGateOpened(_ observer: @escaping @MainActor () -> Void) {
        lock.withLock { gateOpenedObserver = observer }
    }

    /// Main actor: a playback cycle starts before the next frame (route sampled at that moment).
    func playbackStarted(route: VoiceConversationLogic.Route) {
        lock.withLock {
            // A new cycle replacing one still held (e.g. the downlink drained mid-reply) drops its voice run: log it.
            if gate.isArmed { logUnopened("replaced") }
            gate.playbackStarted(route: route)
            held.removeAll()
            holding = route.isSpeaker
            if route.isSpeaker {
                Self.logger.notice(
                    "uplink gate armed frame=\(self.gate.frame) floorDb=\(self.gate.floorDb, format: .fixed(precision: 1)) bargeIn=\(self.gate.isBargeInOn)"
                )
            }
        }
    }

    /// Under the lock: one line per playback cycle that has not opened by the time playback ends or is replaced.
    private func logUnopened(_ event: String) {
        let c = gate.cycle
        Self.logger.notice(
            "uplink gate still held at \(event, privacy: .public) reason=\(self.gate.holdReason, privacy: .public) frame=\(self.gate.frame) start=\(c.startFrame) held=\(c.heldFrames) voiced=\(c.voicedFrames) firstVoiced=\(c.firstVoicedFrame ?? -1) echoMasked=\(c.echoMaskedFrames) maxProb=\(c.maxProb, format: .fixed(precision: 2)) maxDb=\(c.maxDb, format: .fixed(precision: 1)) voicedRun=\(c.longestVoicedRun) vadRun=\(c.longestVadRun) bgAtVoiced=\(c.bgDbAtFirstVoiced ?? -999, format: .fixed(precision: 1)) floorDb=\(self.gate.floorDb, format: .fixed(precision: 1))"
        )
    }

    /// Main actor: the output route changed mid-conversation; the gate follows the new route from the next frame.
    /// Leaving the speaker drops the held frames (captured under speaker echo) along with the hold,
    /// including the held part of the gate frame being filled.
    func routeChanged(route: VoiceConversationLogic.Route) {
        lock.withLock {
            gate.routeChanged(route: route)
            let wasHolding = holding
            holding = gate.isArmed
            guard wasHolding, !holding else { return }
            held.removeAll()
            pendingSentBytes = pending.count
        }
    }

    /// Main actor: playback drained or was stopped locally.
    func playbackEnded() {
        lock.withLock {
            if gate.isArmed { logUnopened("playbackEnd") }
            gate.playbackEnded()
        }
    }

    /// Main actor: false once the reducer disabled voice barge-in.
    func setBargeIn(_ on: Bool) {
        lock.withLock { gate.setBargeIn(on) }
    }

    /// Any thread: sends while on (even unbound frames still feed the level), publishes at most one level per window.
    /// Every 20 ms gate frame is stepped through the speaker gate, which passes, holds or opens (flushing held frames).
    /// The speech model runs before the lock is taken (main actor setters never wait on an inference).
    func deliver(_ frame: Data) {
        let (feed, firstBoundary, frameBytes) = lock.withLock { (speech, gateFrameBytes - pending.count, gateFrameBytes) }
        let probs = feed?.probs(pcm16: frame, firstBoundary: firstBoundary, frameBytes: frameBytes)
        // Taken before the lock like the model. The m gate frames completed here were captured one after another:
        // frame k (0-based) reads the block (m - 1 - k) gate frames behind the playback head.
        let completed = frame.count < firstBoundary ? 0 : 1 + (frame.count - firstBoundary) / max(1, frameBytes)
        // One call per delivery (none when no frame completes): the batch shares one playback head reading.
        let refs = completed == 0 ? [] : reference((0..<completed).map { (completed - 1 - $0) * Self.referenceBlockSamples })
        let (send, out, level, observer, opened) = lock.withLock {
            () -> (((Data) -> Void)?, [Data], Double?, (@MainActor (Double) -> Void)?, (@MainActor () -> Void)?) in
            if let feed, probs == nil, speech === feed {
                // Resampling or inference failed: no prob for the rest of the session (the gate switches to energy).
                speech = nil
                Self.logger.error("realtime speech model inference failed")
            }
            let level = on ? window.add(pcm16: frame) : nil
            let (out, openedOnVoice) = gateStep(frame, probs: feed == nil ? nil : probs, latest: feed?.latestProb, refs: refs)
            return (send, out, level, levelObserver, openedOnVoice ? gateOpenedObserver : nil)
        }
        if let send { out.forEach(send) }
        if let opened { onMain(opened) }
        guard let level, let observer else { return }
        onMain { observer(level) }
    }

    private func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body() }
        } else {
            Task { @MainActor in body() }
        }
    }

    /// Under the lock: slices the incoming audio into gate frames and returns what to send now, in order,
    /// and whether the gate opened on voice. While not holding, bytes go out as they arrive.
    /// probs: the model's prob at each gate frame boundary in `frame` (nil = no model or it failed: frames carry no prob).
    /// refs: the downlink reference dB of each gate frame completed in `frame` (nil = not playing).
    private func gateStep(_ frame: Data, probs: [Double]?, latest: Double?, refs: [Double?]) -> ([Data], Bool) {
        var out: [Data] = []
        var boundary = 0
        var openedOnVoice = false
        var offset = frame.startIndex
        while offset < frame.endIndex {
            let take = min(gateFrameBytes - pending.count, frame.endIndex - offset)
            let piece = frame[offset..<(offset + take)]
            offset += take
            pending.append(piece)
            if !holding {
                if on { out.append(Data(piece)) }
                pendingSentBytes += take
            }
            guard pending.count == gateFrameBytes else { continue }
            let index = gate.frame
            let rest = Data(pending.dropFirst(pendingSentBytes))
            // A bind between taking the boundaries and stepping may shift them: fall back to the latest prob.
            let prob = probs.map { probs in probs.indices.contains(boundary) ? probs[boundary] : latest ?? 0 }
            // Same fallback for a shifted boundary: the newest reference.
            let ref = refs.indices.contains(boundary) ? refs[boundary] : refs.last ?? nil
            boundary += 1
            switch gate.step(db: Self.dbfs(pcm16: pending), prob: prob, ref: ref) {
            case .send:
                if on, !rest.isEmpty { out.append(rest) }
            case .hold:
                holding = true
                if on, !rest.isEmpty {
                    held.append((index, rest))
                    if held.count > Self.maxHeldFrames { held.removeFirst(held.count - Self.maxHeldFrames) }
                }
            case let .open(reason, flushFrom):
                holding = false
                // Once per cycle (the gate disarms on open): why and where it opened.
                let c = gate.cycle
                Self.logger.notice(
                    "uplink gate open reason=\(reason.rawValue, privacy: .public) frame=\(index) start=\(c.startFrame) flushFrom=\(flushFrom) held=\(c.heldFrames) voiced=\(c.voicedFrames) firstVoiced=\(c.firstVoicedFrame ?? -1) echoMasked=\(c.echoMaskedFrames) prob=\(prob ?? -1, format: .fixed(precision: 2)) db=\(Self.dbfs(pcm16: self.pending), format: .fixed(precision: 1)) ref=\(ref ?? -99, format: .fixed(precision: 1)) floorDb=\(self.gate.floorDb, format: .fixed(precision: 1))"
                )
                if on {
                    out.append(contentsOf: held.filter { $0.frame >= flushFrom }.map(\.data))
                    if !rest.isEmpty { out.append(rest) }
                    if reason == .speech { openedOnVoice = true }
                }
                held.removeAll()
            }
            pending = Data()
            pendingSentBytes = 0
        }
        return (out, openedOnVoice)
    }

    /// dBFS of mono PCM16 LE (same math as the level window).
    private static func dbfs(pcm16 data: Data) -> Double {
        let count = data.count / 2
        return data.withUnsafeBytes { raw in
            ConversationAudioMath.dbfs((0..<count).lazy.map { index in
                Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))) / 32_768
            })
        }
    }
}

/// Level window over mono PCM16 LE uplink frames at the transport's uplink rate: one level per `minDuration`
/// seconds of audio (window size from the sample rate) = the loudest frame's dBFS in the window, mapped against
/// `ConversationAudioMath.aiFloorDb`. Audio duration, not wall clock: capture is real time and tests stay deterministic.
nonisolated struct RealtimeUplinkLevelWindow {
    let sampleRate: Double
    private let windowSamples: Int
    private var samples = 0
    private var peakDb: Double?

    init(minDuration: Double, sampleRate: Double) {
        self.sampleRate = sampleRate
        windowSamples = max(1, Int((minDuration * sampleRate).rounded()))
    }

    /// nil until the window holds `minDuration` seconds of audio; a frame closing several windows yields one level.
    mutating func add(pcm16 frame: Data) -> Double? {
        let count = frame.count / 2
        guard count > 0 else { return nil }
        let db = frame.withUnsafeBytes { raw in
            ConversationAudioMath.dbfs((0..<count).lazy.map { index in
                Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))) / 32_768
            })
        }
        peakDb = max(peakDb ?? db, db)
        samples += count
        guard samples >= windowSamples, let peak = peakDb else { return nil }
        samples %= windowSamples
        peakDb = nil
        return ConversationAudioMath.level(db: peak, floorDb: ConversationAudioMath.aiFloorDb)
    }

    mutating func reset() {
        samples = 0
        peakDb = nil
    }
}

/// The two live bubbles of a realtime turn (nil = not shown): never stored, never synced. `userAfterAssistant` = the
/// user barged in on the reply, so the reply is stored (and listed) first. `userPersisted` / `assistantPersisted` =
/// persist effects emitted so far this session per role, `userPersistedText` / `assistantPersistedText` the text of the
/// latest one: a cleared side still shows that text until the list holds that many of the session's stored messages of
/// the role.
nonisolated struct RealtimeDrafts: Equatable, Sendable {
    var user: String? = nil
    var assistant: String? = nil
    var userAfterAssistant = false
    var userPersisted = 0
    var assistantPersisted = 0
    var userPersistedText: String? = nil
    var assistantPersistedText: String? = nil
}
