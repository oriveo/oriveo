import AVFoundation
import Combine
import Foundation
import os

// MARK: - Ports

/// Chat reply event: text is the full text of the current reply (given on each change).
enum VoiceConversationReplyEvent: Equatable, Sendable {
    case text(String)
    case completed
    case failed(code: String)
    /// true = a pending approval appeared (tool confirmation, etc.), false = handled.
    case approvalPending(Bool)
}

/// Bridge between voice conversation and chat (implemented by AppState / ChatManager).
protocol VoiceConversationChatPort: AnyObject {
    /// Sends one user message (through purpose = chat); false = it could not be sent (no model, no connection, etc.).
    func send(_ text: String) async -> Bool
    /// Synchronously registers this turn, then sends asynchronously (the controller uses this): the turn is registered before returning, so a later cancel applies to it; the task result is the same as send.
    func beginSend(_ text: String) -> Task<Bool, Never>
    /// At the start of each conversation, takes a new reply event stream (ending the conversation cancels the iteration and terminates the stream); forwards only the events of the current reply.
    func makeReplyEvents() -> AsyncStream<VoiceConversationReplyEvent>
    /// Cancels the in-flight generation.
    func cancel()
    /// Barge-in while thinking: replaces the previous user message with joinAmend(previous user message, text) and regenerates; an empty string regenerates as-is.
    /// false = it could not be sent.
    func amend(_ text: String) async -> Bool
    /// Synchronously registers this barge-in, then sends asynchronously (the controller uses this): registered before returning, so a later cancel applies to it; the task result is the same as amend.
    func beginAmend(_ text: String) -> Task<Bool, Never>
    /// Same as beginAmend; at the moment the port hands the text to the host to rewrite the message (the delivery point), onDelivered is called synchronously; if it was voided before delivery, it is not called.
    func beginAmend(_ text: String, onDelivered: @escaping @MainActor () -> Void) -> Task<Bool, Never>
}

extension VoiceConversationChatPort {
    func amend(_ text: String) async -> Bool { false }
    func beginSend(_ text: String) -> Task<Bool, Never> {
        Task { await self.send(text) }
    }
    func beginAmend(_ text: String) -> Task<Bool, Never> {
        Task { await self.amend(text) }
    }
    /// The fake does not report the delivery point by default: on cancel, the text is staged as undelivered.
    func beginAmend(_ text: String, onDelivered: @escaping @MainActor () -> Void) -> Task<Bool, Never> {
        beginAmend(text)
    }
}

/// Prompt to be spoken aloud; the text is supplied by the host in the interface language (localized by the host).
enum VoicePrompt: Equatable, Sendable {
    case didNotCatch
    case approvalNeeded
    case sayAgain
    case checkLanguage
    case echoHint
    /// Placeholder sentence for a code / table / formula block in a reply.
    case placeholder(SpeakablePlaceholder)
}

/// Outcome of one conversation, handed to the host (writes the draft, shows the error card).
struct VoiceConversationEnd: Equatable, Sendable {
    let reason: VoiceConversationLogic.EndReason
    /// Error code for replyFailed.
    let code: String?
    /// Transcript of what the user had said partway through when ✕ was tapped (written into the draft); nil if none.
    let draft: String?
    /// true = there was a partial recording when ✕ was tapped; its transcript is delivered separately later via onDraft (the session has already ended).
    var draftPending = false
}

/// Cloud speech engine's "synthesize only, no playback" entry (implemented by CloudSpeechEngine).
protocol ConversationCloudSynthesizing: AnyObject {
    func synthesize(text: String) async throws -> Data
    /// Audio file extension (the directory's outputFormat).
    var audioFileExtension: String { get }
    /// Provider name used for the fallback notice.
    var fallbackProviderName: String { get }
}

// MARK: - Clock

protocol VoiceConversationTimer: AnyObject {
    func cancel()
}

/// Millisecond clock + timed callbacks; tests inject a manual clock.
protocol VoiceConversationClock: AnyObject {
    var nowMs: Int { get }
    /// One-shot timer: calls back once after `ms` milliseconds.
    func after(ms: Int, _ handler: @escaping () -> Void) -> VoiceConversationTimer
}

final class SystemVoiceConversationClock: VoiceConversationClock {
    private final class TaskTimer: VoiceConversationTimer {
        var task: Task<Void, Never>?
        func cancel() {
            task?.cancel()
            task = nil
        }
    }

    var nowMs: Int { Int(ProcessInfo.processInfo.systemUptime * 1000) }

    func after(ms: Int, _ handler: @escaping () -> Void) -> VoiceConversationTimer {
        let timer = TaskTimer()
        timer.task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(ms, 0)) * 1_000_000)
            guard !Task.isCancelled else { return }
            handler()
        }
        return timer
    }
}

// MARK: - Speech model loading and diagnostics

/// Result of loading the speech model when the session is prepared.
enum SpeechModelLoad: Equatable, Sendable {
    case ready
    /// No model was prepared for this session (not via prepareAudioSession / a stand-in that does not configure a model).
    case unavailable
    case timeout
    /// Loading threw; the associated value is the reason (the LoadError case name, or the NSError domain#code).
    case failed(String)

    nonisolated static func reason(of error: Error) -> String {
        if let load = error as? SileroVad.LoadError {
            switch load {
            case .modelMissing: return "modelMissing"
            case .unexpectedSignature: return "unexpectedSignature"
            }
        }
        let ns = error as NSError
        return "\(ns.domain)#\(ns.code)"
    }

    /// Diagnostic (mode, reason): in model mode reason is nil; in energy mode it is none / timeout / load_failed:<reason>.
    var vadMode: (mode: String, reason: String?) {
        switch self {
        case .ready: return ("model", nil)
        case .unavailable: return ("energy", "none")
        case .timeout: return ("energy", "timeout")
        case .failed(let reason): return ("energy", "load_failed:\(reason)")
        }
    }
}

/// Conversation host diagnostics: observe only, do not change behavior; called synchronously on the main thread, implementations do no IO and do not block. Default is a no-op.
protocol VoiceConversationDiagnostics: AnyObject {
    /// VAD mode for this session: reported once when capture starts, and again when inference fails and switches to energy (only switches once):
    /// mode is model / energy; reason is the energy-mode reason (none / timeout / load_failed:<reason> / inference_failed), and nil in model mode.
    func vadMode(mode: String, reason: String?)
    /// After each reduce: the event, the effects it returns, and the number of VAD events queued after the reduce.
    func reduced(event: VoiceConversationLogic.Event, effects: [VoiceConversationLogic.Effect], pendingVad: Int)
    /// A transcript has settled: source is live / file; text is nil = empty / failed / timed out; start and end are uptime nanoseconds.
    func transcribed(utteranceId: String, source: String, text: String?, startNs: UInt64, endNs: UInt64)
    /// Capture stalled, then ends as system: reason is stall (no tap callback within the watchdog limit) / rebuild (rebuild failed after a configuration change).
    func captureStalled(reason: String)
}

extension VoiceConversationDiagnostics {
    func vadMode(mode: String, reason: String?) {}
    func reduced(event: VoiceConversationLogic.Event, effects: [VoiceConversationLogic.Effect], pendingVad: Int) {}
    func transcribed(utteranceId: String, source: String, text: String?, startNs: UInt64, endNs: UInt64) {}
    func captureStalled(reason: String) {}
}

final class NoOpVoiceConversationDiagnostics: VoiceConversationDiagnostics {}

// MARK: - Local memory of "speaker barge-in off"

/// Stored only in local UserDefaults; not reported, not a setting; cleared and re-tested when the major system version changes.
struct VoiceBargeInMemory {
    enum Key {
        static let remembered = "voice.conversation.noSpeakerBargeIn"
        static let streak = "voice.conversation.falseBargeInStreak"
        static let osMajor = "voice.conversation.bargeInOSMajor"
    }

    private let defaults: UserDefaults
    private let osMajorVersion: Int

    init(defaults: UserDefaults = .standard,
         osMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) {
        self.defaults = defaults
        self.osMajorVersion = osMajorVersion
    }

    /// Before reading, checks the major system version: if it changed, clears it.
    var remembersNoSpeakerBargeIn: Bool {
        clearIfOSChanged()
        return defaults.bool(forKey: Key.remembered)
    }

    /// On conversation end: triggered = self-interruptions in this session reached the limit; not triggered but playback on the speaker occurred = consecutive interruptions.
    func conversationEnded(triggered: Bool, hadSpeakerPlayback: Bool) {
        clearIfOSChanged()
        if triggered {
            let streak = defaults.integer(forKey: Key.streak) + 1
            defaults.set(streak, forKey: Key.streak)
            if streak >= VoiceConversationLogic.Constants.conversationsToRemember {
                defaults.set(true, forKey: Key.remembered)
            }
        } else if hadSpeakerPlayback {
            defaults.set(0, forKey: Key.streak)
        }
    }

    private func clearIfOSChanged() {
        let stored = defaults.object(forKey: Key.osMajor) as? Int
        guard stored != osMajorVersion else { return }
        defaults.removeObject(forKey: Key.remembered)
        defaults.removeObject(forKey: Key.streak)
        defaults.set(osMajorVersion, forKey: Key.osMajor)
    }
}

// MARK: - Controller

/// Voice conversation host: translates audio / recognition / chat signals into `VoiceConversationLogic` events and executes the returned effects in order.
/// Display state comes only from the reducer; the UI reads only displayState / statusKey / level.
final class VoiceConversationController: ObservableObject, VoiceConversationSurface {
    typealias Logic = VoiceConversationLogic

    @Published private(set) var displayState: Logic.DisplayState?
    @Published private(set) var statusKey: Logic.StatusKey?
    /// Status orb level 0…1: listening = microphone, speaking = output; otherwise 0; at most about 15 times per second.
    @Published private(set) var level: Double = 0
    @Published private(set) var isActive = false
    /// Live caption at the status position: after each reduce = Logic.caption(state) (non-nil only when statusKey is caption).
    @Published private(set) var caption: String?
    /// Count of the reducer's nudgeOrb (signal that the status orb should jiggle slightly on echo / false interruption; the animation is handled by the UI).
    @Published private(set) var nudgeCount = 0

    /// Conversation ended (including on error, idle, or ✕ tapped).
    var onEnded: ((VoiceConversationEnd) -> Void)?
    /// The draft transcription completed when the conversation ended with draftPending (nil if empty / failed); setting it in onEnded is enough: it is still delivered after the controller is released.
    var onDraft: ((String?) -> Void)?
    /// Mid-way failure of cloud reading aloud: the remaining sentences of this reply fall back to the system voice (the parameter is the provider name; the host shows the prompt).
    var onCloudFallback: ((String) -> Void)?
    /// User-visible notice of cloud-read fallback: sent only once per conversation (each reply still tries the cloud first and calls onCloudFallback).
    var onCloudFallbackNotice: ((String) -> Void)?
    /// The stored cloud-voice selection is invalid; this time the system voice is used (the setting has been changed back to system).
    var onTTSEngineFallback: ((VoiceFallbackReason) -> Void)?
    /// Reducer's haptics (the host performs them according to the system haptics switch).
    var onHaptic: ((Logic.Haptic) -> Void)?

    static let levelIntervalMs = 67

    private let audio: ConversationAudioEngine
    private let dictation: DictationEngineSource
    private let readAloud: ReadAloudEngineSource
    private let chat: VoiceConversationChatPort
    private let prompt: (VoicePrompt) -> String
    private let clock: VoiceConversationClock
    private let memory: VoiceBargeInMemory
    private let stopReadAloud: () -> Void
    private let detectLanguage: (String) -> String?
    /// Conversation recognition language (production = the recognition language in settings, from the same source as dictation).
    let sttLanguage: () -> String?

    private(set) var state = Logic.initialState()
    private var pendingEvents: [Logic.Event] = []
    private var dispatching = false
    /// On the sentence-start-closing vadSpeechEnd dispatched while speaking: after reduce, decide whether this sentence's recording is kept or dropped (same as Android settleOpenTurn).
    /// When forceEndUtterance executes mid-dispatch, the close is only queued; reading state immediately at the dispatch point would read a stale value and delete the recording.
    private var settleEndedIds: Set<String> = []
    /// Number of cancelGeneration executions: a send issued earlier that was voided by it and returned false is not counted as a send failure.
    private var replyCancels = 0
    /// Barge-in text being sent and not yet returned (serial claim: only the call that issued it clears it); on cancelGeneration only the undelivered portion is moved into carriedAmend.
    /// delivered = the port has handed the text to the host to rewrite the message (the delivery point): after that, cancel does not stage it again, so the next barge-in does not repeat this part.
    private var pendingAmend: (text: String, serial: Int, delivered: Bool)?
    private var amendSerial = 0
    /// Barge-in text intercepted by cancelGeneration and not delivered is prepended to the next send / amend, so what the user said is not lost.
    /// send is not staged: when send is voided at the port, the user message is still saved, and only generation stops.
    private var carriedAmend: String?
    /// Incremented on each start: leftover send / transcript Tasks from the previous session check this when they return and discard themselves.
    private var sessionGeneration = 0

    // Capture
    private var vad = Logic.Vad()
    private var lastFrame = -1
    /// Result of loading the speech model when the session is prepared; taken at start as this session's judgement mode, then reset.
    private var preparedSpeechModel = SpeechModelLoad.unavailable
    /// This session's VAD uses model probabilities; once frames stop carrying a probability (inference failed), an energy-mode Vad takes over for the rest of the session and is never switched back.
    private var speechModelActive = false
    private let loadSpeechModel: @Sendable () async -> SpeechModelLoad
    private let diagnostics: VoiceConversationDiagnostics
    /// Barge-in grace start point: set once each when reply playback begins and on each resume; not reset per sentence.
    private var playbackStartFrame: Int?
    /// Barge-in candidate window: from the first sentence of a reply starting to play, until drained / stopPlayback / pausePlayback for the completed reply; gaps between sentences and mid-stream pauses also count as playing.
    private var playbackActive = false
    /// Frame where playback actually ended (converted by resetVad), the start of the echo window; cleared when a new sentence starts playing.
    private var playbackEndedFrame: Int?
    private var utteranceCounter = 0
    /// The sentence id that owns the recording currently being written (assigned by vadSpeechStart; carried over on continuation; cleared on transcribe / discard).
    private var openUtteranceId: String?
    /// A batch of effects replaying queued onsets is executing: resetVad does not drop the recording still needed.
    private var keepWantedOpenUtterance = false
    private var recordings: [String: PendingRecording] = [:]
    private var draftRecording: PendingRecording?
    private var lastLevelMs: Int?
    /// Peak within the current level window (nil if no value in the window yet).
    private var levelPeak: Double?
    private var sttChoice: Task<DictationEngineChoice, Never>?

    // Reply
    private var replyTask: Task<Void, Never>?
    private var segmentsEnqueued = 0
    private var replyText = ""

    // Speaking
    private enum SpeechItem {
        case sentence(String)
        case prompt(String)

        var text: String {
            switch self {
            case .sentence(let text), .prompt(let text): return text
            }
        }

        var isPrompt: Bool {
            if case .prompt = self { return true }
            return false
        }
    }

    private final class QueuedSpeech {
        let item: SpeechItem
        var synthesis: Task<Data, Error>?
        /// The session generation when promptStarted was reported for a prompt; cleared after promptEnded is reported (sent only once).
        var promptSession: Int?
        init(_ item: SpeechItem) { self.item = item }
    }

    private enum ReplyVoice {
        case system
        case cloud(ConversationCloudSynthesizing)
    }

    private var speechQueue: [QueuedSpeech] = []
    private var speaking: QueuedSpeech?
    private var speechGeneration = 0
    private var replyVoice: ReplyVoice?
    private var replyLanguage: String?
    private var cloudFellBack = false
    /// The cloud-fallback notice has been sent in this session; reset at start, not reset by send.
    private var fallbackNoticeShown = false
    private var messageTask: Task<Void, Never>?
    private var pendingMessages: [String: String] = [:]

    /// One-shot timer scheduled per Logic.nextDeadlineMs; at most one at any moment.
    private var deadlineTimer: VoiceConversationTimer?
    private var armedDeadlineMs: Int?
    private var falseBargeInLimitReached = false
    /// Deletes segment recording files that nobody is waiting for anymore; called only off the main thread (tests inject an implementation that records the thread).
    private let segmentFiles: FileManager
    private var hadSpeakerPlayback = false

    // Real-time recognition (system engine)
    /// Upper limit for the real-time session finish; on timeout, falls back to recognizing the recording file.
    static let liveFinishLimit: Duration = .milliseconds(1500)
    /// The engine among the "listening" engines in this session that can recognize while speaking (default = system engine; nil for cloud, which only uses the recording file).
    private let liveEngine: (DictationEngineChoice) -> (any LiveSTTEngine)?
    private let finishLimit: Duration
    /// The real-time engine for this session (derived from engine selection at start); nil until resolution completes.
    private var liveEngineTask: Task<(any LiveSTTEngine)?, Never>?
    /// Resolved result: outer nil = resolution not yet complete; inner nil = real-time not enabled for this session (cloud).
    private var resolvedLiveEngine: (any LiveSTTEngine)??
    /// Real-time recognition for each sentence (sentence id → session); removed when transcribed, and cancelled when abandoned.
    private var lives: [String: LiveRun] = [:]

    /// Default real-time engine: the system engine picked by prepareConversationListening.
    static func systemLiveEngine(_ choice: DictationEngineChoice) -> (any LiveSTTEngine)? {
        choice.isSystem ? choice.engine as? any LiveSTTEngine : nil
    }

    init(
        audio: ConversationAudioEngine,
        dictation: DictationEngineSource,
        readAloud: ReadAloudEngineSource,
        chat: VoiceConversationChatPort,
        prompt: @escaping (VoicePrompt) -> String,
        clock: VoiceConversationClock = SystemVoiceConversationClock(),
        memory: VoiceBargeInMemory = VoiceBargeInMemory(),
        stopReadAloud: @escaping () -> Void = { ReadAloudController.shared.stop(.interrupted) },
        detectLanguage: @escaping (String) -> String? = ReadAloudController.dominantLanguage,
        sttLanguage: @escaping () -> String? = { nil },
        segmentFiles: FileManager = .default,
        liveEngine: @escaping (DictationEngineChoice) -> (any LiveSTTEngine)? = VoiceConversationController.systemLiveEngine,
        liveFinishLimit: Duration = VoiceConversationController.liveFinishLimit,
        loadSpeechModel: @escaping @Sendable () async -> SpeechModelLoad = VoiceConversationController.loadSileroVad,
        diagnostics: VoiceConversationDiagnostics = NoOpVoiceConversationDiagnostics()
    ) {
        self.loadSpeechModel = loadSpeechModel
        self.diagnostics = diagnostics
        self.audio = audio
        self.dictation = dictation
        self.readAloud = readAloud
        self.chat = chat
        self.prompt = prompt
        self.clock = clock
        self.memory = memory
        self.stopReadAloud = stopReadAloud
        self.detectLanguage = detectLanguage
        self.sttLanguage = sttLanguage
        self.segmentFiles = segmentFiles
        self.liveEngine = liveEngine
        self.finishLimit = liveFinishLimit
        audio.delegate = self
    }

    // MARK: Public actions

    /// Before start: first stops read-aloud (its deactivation is queued before the conversation is activated); the audio pipeline then configures and activates the session on the session serial queue, and the main thread only awaits.
    /// Also loads the speech model (≤ speechModelLimit); on timeout / failure, energy judgement is used for the whole session.
    func prepareAudioSession() async throws {
        guard !isActive else { return }
        stopReadAloud()
        async let model = loadSpeechModel()
        try await audio.prepareSession()
        preparedSpeechModel = await model
    }

    /// Session prepared, conversation not started (ended or left during the startup period): the audio's stop releases the lease and deactivates the session.
    func abandonPreparedSession() {
        guard !isActive else { return }
        preparedSpeechModel = .unavailable
        audio.stop()
    }

    /// Upper limit for waiting for the speech model to be ready when preparing the session.
    static let speechModelLimit: DispatchTimeInterval = .milliseconds(500)

    /// Default speech-model loading: builds a SileroVad in the background (warming a process-wide shared session); success within the time limit is ready, a throw carries the reason; does not wait on it on timeout.
    nonisolated static func loadSileroVad() async -> SpeechModelLoad {
        let claimed = OSAllocatedUnfairLock(initialState: false)
        let claim: @Sendable () -> Bool = {
            claimed.withLock { done in
                if done { return false }
                done = true
                return true
            }
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome: SpeechModelLoad
                do {
                    _ = try SileroVad()
                    outcome = .ready
                } catch {
                    outcome = .failed(SpeechModelLoad.reason(of: error))
                }
                if claim() { continuation.resume(returning: outcome) }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + speechModelLimit) {
                if claim() { continuation.resume(returning: .timeout) }
            }
        }
    }

    /// User taps ≋ (foreground): stops read-aloud, activates the session and starts listening. Throws if session activation fails, and does not enter the conversation.
    func start() throws {
        guard !isActive else { return }
        stopReadAloud()
        try audio.start()
        resetSession()
        let load = preparedSpeechModel
        speechModelActive = load == .ready
        preparedSpeechModel = .unavailable
        let mode = load.vadMode
        diagnostics.vadMode(mode: mode.mode, reason: mode.reason)
        sessionGeneration += 1
        pendingAmend = nil
        carriedAmend = nil
        isActive = true
        let source = dictation
        let choice = Task { await source.select() }
        sttChoice = choice
        let pick = liveEngine
        let generation = sessionGeneration
        let liveTask = Task { pick(await choice.value) }
        liveEngineTask = liveTask
        Task { [weak self] in
            let engine = await liveTask.value
            guard let self, self.sessionGeneration == generation else { return }
            self.resolvedLiveEngine = .some(engine)
        }
        let events = chat.makeReplyEvents()
        replyTask = Task { [weak self] in
            for await event in events {
                guard let self, self.isActive else { return }
                self.handleReply(event)
            }
        }
        dispatch(.start(route: audio.route, deviceRemembersNoSpeakerBargeIn: memory.remembersNoSpeakerBargeIn))
    }

    /// ✕ tapped = user; switching session / going back = system.
    func end(_ reason: Logic.EndReason = .user) {
        dispatch(.end(reason: reason == .user ? .user : .system))
    }

    func tapOrb() { dispatch(.tapOrb) }
    func toggleMute() { dispatch(.toggleMute) }

    /// During the conversation, tapping 🔈 on an old message: pauses capture and plays through the same engine; returns to listening after playback ends.
    func playMessage(id: String, text: String) {
        pendingMessages[id] = text
        dispatch(.playMessage(messageId: id))
        pendingMessages[id] = nil
    }

    /// VoiceOver is speaking: any speech discards the current sentence (recording and real-time session); during this time capture is not processed and the noise floor is not updated.
    func setScreenReaderSpeaking(_ speaking: Bool) {
        dispatch(.screenReaderSpeaking(speaking))
        if speaking { dropUtterance() }
    }

    /// The recognizer's live caption (current text of the whole sentence).
    func receivePartial(_ text: String) {
        guard isActive else { return }
        dispatch(.sttPartial(text: text))
    }

    // MARK: Event loop

    private func dispatch(_ event: Logic.Event) {
        pendingEvents.append(event)
        guard !dispatching else { return }
        dispatching = true
        while !pendingEvents.isEmpty {
            let next = pendingEvents.removeFirst()
            let queuedBefore = state.pendingVad
            let (newState, effects) = Logic.reduce(state, next, atMs: clock.nowMs)
            state = newState
            diagnostics.reduced(event: next, effects: effects, pendingVad: state.pendingVad.count)
            publish()
            // After a queued-onset replay / discard: the resetVad in this batch of effects does not drop the sentence recording still needed; leftovers nobody needs are cleaned up after it finishes.
            let queueMoved = !queuedBefore.isEmpty && state.pendingVad != queuedBefore
            keepWantedOpenUtterance = queueMoved
            for effect in effects { perform(effect) }
            keepWantedOpenUtterance = false
            if queueMoved {
                settleQueuedUtterances(queuedBefore)
                recaptionReplayedUtterance()
            }
            settleEndedUtterance(after: next)
            armDeadline()
        }
        dispatching = false
    }

    /// After each reduce, reschedules according to nextDeadlineMs: if the value is unchanged, nothing happens; if it changed, cancel the old one and reschedule; if already past, dispatch immediately.
    private func armDeadline() {
        let next = isActive ? Logic.nextDeadlineMs(state) : nil
        guard next != armedDeadlineMs else { return }
        cancelDeadline()
        guard let next else { return }
        let delay = next - clock.nowMs
        if delay <= 0 {
            pendingEvents.append(.deadline)
            return
        }
        armedDeadlineMs = next
        let generation = sessionGeneration
        deadlineTimer = clock.after(ms: delay) { [weak self] in
            guard let self, self.isActive, self.sessionGeneration == generation, self.armedDeadlineMs == next else { return }
            self.deadlineTimer = nil
            self.armedDeadlineMs = nil
            self.dispatch(.deadline)
        }
    }

    private func cancelDeadline() {
        deadlineTimer?.cancel()
        deadlineTimer = nil
        armedDeadlineMs = nil
    }

    private func publish() {
        let display = Logic.displayState(state)
        if displayState != display { displayState = display }
        let key = Logic.statusKey(state)
        if statusKey != key { statusKey = key }
        let text = Logic.caption(state)
        if caption != text { caption = text }
        let tracksLevel: Set<Logic.DisplayState> = [.listening, .userSpeaking, .sayAgain, .checkLanguage, .speaking]
        if !(display.map(tracksLevel.contains) ?? false) {
            levelPeak = nil
            if level != 0 { level = 0 }
        }
        if state.phase == .speaking && audio.isSpeakerRoute { hadSpeakerPlayback = true }
    }

    private func perform(_ effect: Logic.Effect) {
        switch effect {
        case .startCapture:
            break  // session already activated and tap installed in start()
        case .pauseCapture:
            dropUtterance()
            audio.pauseCapture()
        case .resumeCapture:
            audio.resumeCapture()
        case .setCaptureMuted(let muted):
            if muted { dropUtterance() }
            audio.setCaptureMuted(muted)
        case .resetVad(let endedAtMs):
            if !(keepWantedOpenUtterance && openUtteranceWanted()) { dropUtterance() }
            playbackEndedFrame = endedAtMs.map { max(0, lastFrame + 1 - (clock.nowMs - $0) / Logic.Constants.frameMs) }
        case .transcribe(let id):
            transcribe(id)
        case .transcribeToDraft:
            if vad.speaking { vad.reset() }
            if let id = openUtteranceId { cancelLive(id) }
            openUtteranceId = nil
            draftRecording?.abandon()
            let draft = PendingRecording(files: segmentFiles)
            draftRecording = draft
            audio.finishUtterance { draft.deliver($0) }
        case .sendMessage(let text):
            send(text)
        case .amendLastMessage(let text):
            amend(text)
        case .cancelGeneration:
            replyCancels += 1
            // A barge-in still pending was voided and its text was not delivered: stage it for the next send (cancel only stops generation and does not lose the user's text); if already delivered, it is already in the message and is not carried over again.
            if let pending = pendingAmend, !pending.delivered { carriedAmend = pending.text }
            pendingAmend = nil
            chat.cancel()
            clearSpeech()
        case .pausePlayback:
            playbackActive = false
            audio.pausePlayback()
        case .resumePlayback(let from):
            playbackActive = true
            playbackStartFrame = lastFrame + 1
            playbackEndedFrame = nil
            audio.resumePlayback(fromSentenceStart: from == .sentenceStart)
        case .stopPlayback:
            clearSpeech()
        case .enqueueSpeech(let text):
            enqueue(.sentence(text))
        case .speakPrompt(let kind):
            enqueue(.prompt(prompt(Self.voicePrompt(kind))))
        case .earcon(let kind):
            audio.playEarcon(kind)
        case .haptic(let kind):
            onHaptic?(kind)
        case .nudgeOrb:
            nudgeCount += 1
        case .continueUtterance(let id):
            // Continuation: the same sentence and the same recording keep being written (no new recording was opened at onset).
            openUtteranceId = id
        case .forceEndUtterance:
            if let event = vad.forceEnd(frame: max(lastFrame, 0)) { handleVad(event) }
        case .rememberFalseBargeInConversation:
            falseBargeInLimitReached = true
        case .playMessage(let id):
            playStoredMessage(pendingMessages[id] ?? "")
        case .endConversation(let reason, let code):
            finish(reason: reason, code: code)
        }
    }

    // MARK: Capture and VAD

    private func handleFrame(index: Int, db: Double, speechProb: Double? = nil) {
        guard isActive else { return }
        if speechModelActive && speechProb == nil {
            // Mid-way inference failure: an energy-mode Vad takes over for the rest of the session; a sentence not finished is dropped (same as reset), rather than treating the missing probability as 0.
            speechModelActive = false
            diagnostics.vadMode(mode: "energy", reason: "inference_failed")
            let wasSpeaking = vad.speaking
            vad = Logic.Vad()
            if wasSpeaking { handleVad(.discarded(frame: index)) }
        }
        lastFrame = index
        if state.phase == .listening { publishLevel(ConversationAudioMath.level(db: db, floorDb: vad.floorDb)) }
        // Prompt is playing: no capture, so the speaker output is not mistaken for speech.
        if case .prompt = speaking?.item { return }
        // Screen reader is speaking: frames do not enter VAD, and the noise floor is frozen.
        if state.screenReaderSpeaking { return }
        let events = vad.step(
            frame: index, db: db, speaker: audio.isSpeakerRoute,
            playbackStartFrame: playbackActive ? playbackStartFrame : nil,
            playbackEndedFrame: playbackEndedFrame, prob: speechModelActive ? speechProb : nil
        )
        for event in events { handleVad(event) }
    }

    private func handleVad(_ event: Logic.VadEvent) {
        switch event {
        case .speechStart(_, let prerollFrame):
            // Still held and speech started again = continuation (the reducer returns continueUtterance): no new recording is opened.
            // A start point the reducer will drop does not open a recording, to avoid creating a file only to delete it.
            if state.holdUtteranceId == nil && !Logic.dropsVad(state) {
                if openUtteranceId != nil { discardOpenUtterance() }
                let id = nextUtteranceId()
                openUtteranceId = id
                audio.beginUtterance(fromFrame: prerollFrame, live: startLive(id))
            }
            dispatch(.vadSpeechStart)
            if playbackActive && state.userSpeaking { dispatch(.bargeInDetected) }
            // An onset queued while waiting for transcription keeps recording; it is replayed once the transcript settles.
            if !state.userSpeaking && !openUtteranceQueued() { discardOpenUtterance() }
        case .speechEnd(_, let voicedMs, _):
            guard state.userSpeaking else {
                if Self.startQueued(state.pendingVad) {
                    // A queued close: the recording is closed now and kept; after replay, transcribe is sent. If not needed, settleQueuedUtterances deletes it.
                    // An onset that is queued but has no recording is still dispatched: otherwise, after replaying the onset, the close would never arrive and it would hang while speaking.
                    let id = openUtteranceId ?? nextUtteranceId()
                    dispatch(.vadSpeechEnd(utteranceId: id, voicedMs: voicedMs))
                    if openUtteranceId == id, Self.queuedEnd(state.pendingVad, id) {
                        parkOpenRecording(id)
                        return
                    }
                }
                discardOpenUtterance()
                return
            }
            let id = openUtteranceId ?? nextUtteranceId()
            // Not closed here: while held, a continuation may follow; the recording is closed only when the reducer sends transcribe. Whether to keep it is decided after reduce.
            settleEndedIds.insert(id)
            dispatch(.vadSpeechEnd(utteranceId: id, voicedMs: voicedMs))
        case .discarded:
            // Whether this segment is kept is decided after reduce (settleEndedUtterance).
            dispatch(.vadDiscarded)
        }
    }

    /// After reduce, while speaking, following the close / discard: the sentence that the reducer did not close (not waiting, not held) has its recording dropped.
    private func settleEndedUtterance(after event: Logic.Event) {
        switch event {
        case .vadSpeechEnd(let id, _):
            guard settleEndedIds.remove(id) != nil else { return }
            // The close is still queued in pendingVad (same as Android queuedOpenUtterance): after replay it still needs transcribing, so the recording is kept.
            if state.awaitedUtteranceId != id && state.holdUtteranceId != id && !Self.queuedEnd(state.pendingVad, id) {
                if openUtteranceId == id { discardOpenUtterance() }
                discardRecording(id)
            }
        case .vadDiscarded:
            // A continuation segment too short and dropped: the previous sentence is finalized under its original id, and the recording has already been taken by transcribe; the rest of this segment is dropped.
            if let id = openUtteranceId, state.awaitedUtteranceId != id, state.holdUtteranceId != id, !openUtteranceQueued() {
                discardOpenUtterance()
            }
        default:
            return
        }
    }

    /// Whether the sentence currently being written is still queued: the last onset / close in the queue is an onset.
    private func openUtteranceQueued() -> Bool {
        openUtteranceId != nil && Self.startQueued(state.pendingVad)
    }

    /// The last onset / close in the queue is an onset.
    private static func startQueued(_ queue: [Logic.QueuedVad]) -> Bool {
        for queued in queue.reversed() {
            switch queued.event {
            case .vadSpeechStart: return true
            case .vadSpeechEnd: return false
            default: continue
            }
        }
        return false
    }

    private func openUtteranceWanted() -> Bool {
        guard let id = openUtteranceId else { return false }
        // The moment a close has just been queued and the recording has not yet been closed also counts as queued.
        return state.userSpeaking || state.awaitedUtteranceId == id || state.holdUtteranceId == id || openUtteranceQueued()
            || Self.queuedEnd(state.pendingVad, id)
    }

    private static func queuedEnd(_ queue: [Logic.QueuedVad], _ id: String) -> Bool {
        queue.contains {
            if case .vadSpeechEnd(let queuedId, _) = $0.event { return queuedId == id }
            return false
        }
    }

    /// Queued-close recordings are closed first and stored in recordings; replay uses them directly when transcribing.
    private func parkOpenRecording(_ id: String) {
        openUtteranceId = nil
        let pending = PendingRecording(files: segmentFiles)
        recordings[id] = pending
        audio.finishUtterance { pending.deliver($0) }
    }

    /// After a queued-onset replay / discard: the sentence being written and any queued sentence already closed, if neither speaking, waiting, nor held, nor in the queue, are dropped.
    private func settleQueuedUtterances(_ queuedBefore: [Logic.QueuedVad]) {
        if openUtteranceId != nil && !openUtteranceWanted() { discardOpenUtterance() }
        for queued in queuedBefore {
            guard case .vadSpeechEnd(let id, _) = queued.event, recordings[id] != nil,
                  state.awaitedUtteranceId != id, !Self.queuedEnd(state.pendingVad, id) else { continue }
            discardRecording(id)
        }
    }

    private func nextUtteranceId() -> String {
        utteranceCounter += 1
        return "u\(utteranceCounter)"
    }

    /// Discards the segment recording currently being written (nothing happens if not recording).
    private func discardOpenUtterance() {
        if let id = openUtteranceId { cancelLive(id) }
        openUtteranceId = nil
        audio.discardUtterance()
    }

    #if DEBUG
    /// Unit tests only: the recording segment being written is gone while VAD is still speaking (queued onset with no recording).
    func discardOpenUtteranceForTesting() { discardOpenUtterance() }
    #endif

    /// Discards the in-progress speech (silence, capture paused).
    private func dropUtterance() {
        vad.reset()
        discardOpenUtterance()
    }

    /// Peak accumulated within the window, emitted and reset every levelIntervalMs (the envelope is in the view layer).
    private func publishLevel(_ value: Double) {
        let peak = max(levelPeak ?? 0, value)
        levelPeak = peak
        let now = clock.nowMs
        if let last = lastLevelMs, now - last < Self.levelIntervalMs { return }
        lastLevelMs = now
        levelPeak = nil
        if level != peak { level = peak }
    }

    // MARK: Recognition

    private func transcribe(_ id: String) {
        // This sentence's recording is closed only now: delivered after io completes, and the transcript waits for it. A retry reuses the same segment.
        if recordings[id] == nil, openUtteranceId == id {
            openUtteranceId = nil
            let pending = PendingRecording(files: segmentFiles)
            recordings[id] = pending
            audio.finishUtterance { pending.deliver($0) }
        }
        guard let pending = recordings[id], let sttChoice else {
            cancelLive(id)
            dispatch(.sttFailed(utteranceId: id))
            return
        }
        let generation = sessionGeneration
        // Do not transcribe before the close completes: if the session generation has changed or it is no longer awaited, delivery deletes it.
        pending.wait { [weak self] recording in
            guard let self, self.sessionGeneration == generation, self.isActive,
                  self.state.awaitedUtteranceId == id, self.recordings[id] === pending else {
                pending.abandon()
                return
            }
            guard let recording else {
                self.cancelLive(id)
                self.recordings[id] = nil
                self.dispatch(.sttFailed(utteranceId: id))
                return
            }
            self.transcribe(id, recording: recording, sttChoice: sttChoice, generation: generation)
        }
    }

    private func transcribe(
        _ id: String, recording: RecordingResult, sttChoice: Task<DictationEngineChoice, Never>, generation: Int
    ) {
        let language = sttLanguage()
        // The recording is closed: frames queued on io before it have all been fed to the real-time session, so input ends only now.
        let live = lives.removeValue(forKey: id)
        let limit = finishLimit
        Task { [weak self] in
            let choice = await sttChoice.value
            let liveStart = DispatchTime.now().uptimeNanoseconds
            let liveText = await Self.finishLive(live, within: limit)
            if live != nil {
                self?.diagnostics.transcribed(
                    utteranceId: id, source: "live", text: liveText,
                    startNs: liveStart, endNs: DispatchTime.now().uptimeNanoseconds
                )
            }
            if let text = liveText {
                guard let self, self.sessionGeneration == generation, self.isActive,
                      self.state.awaitedUtteranceId == id else { return }
                self.discardRecording(id)
                self.dispatch(.sttResult(utteranceId: id, text: text))
                return
            }
            let result: Result<String, Error>
            let fileStart = DispatchTime.now().uptimeNanoseconds
            do {
                let engine = choice.engine
                if choice.isSystem {
                    // Same upper limit as dictation: if system recognition hangs, it is recorded as a timeout failure.
                    let limit = Self.fileTranscriptionLimit(durationSec: recording.durationSec)
                    result = .success(try await VoiceDeadline.run(within: limit) {
                        try await engine.transcribe(recording, language: language)
                    })
                } else {
                    result = .success(try await engine.transcribe(recording, language: language))
                }
            } catch {
                result = .failure(error)
            }
            self?.diagnostics.transcribed(
                utteranceId: id, source: "file", text: try? result.get(),
                startNs: fileStart, endNs: DispatchTime.now().uptimeNanoseconds
            )
            guard let self, self.sessionGeneration == generation, self.isActive,
                  self.state.awaitedUtteranceId == id else { return }
            switch result {
            case .success(let text):
                self.discardRecording(id)
                self.dispatch(.sttResult(utteranceId: id, text: text))
            case .failure:
                self.dispatch(.sttFailed(utteranceId: id))
                if self.state.awaitedUtteranceId != id { self.discardRecording(id) }
            }
        }
    }

    /// Upper limit for recording-file recognition = durationSec × fileTimeoutFactor + fileTimeoutBaseSec (same convention as dictation).
    static func fileTranscriptionLimit(durationSec: Double) -> Duration {
        let seconds = durationSec * DictationRules.fileTimeoutFactor + DictationRules.fileTimeoutBaseSec
        return .milliseconds(Int64((seconds * 1000).rounded(.up)))
    }

    private func discardRecording(_ id: String) {
        cancelLive(id)
        recordings.removeValue(forKey: id)?.abandon()
    }

    // MARK: Real-time recognition

    /// A new sentence starts: when this session's engine is the system engine, opens one real-time session and returns the sink handed to the recording; returns nil for cloud.
    /// While engine selection is still unresolved, the sink is handed out first; frames queue in LiveUtteranceFeed, and the session is opened after resolution (for cloud, it is voided).
    private func startLive(_ id: String) -> ConversationLiveSink? {
        cancelLive(id)
        guard let liveEngineTask else { return nil }
        let language = sttLanguage()
        let run = LiveRun(id: id)
        switch resolvedLiveEngine {
        case .some(.none):
            return nil
        case .some(.some(let engine)):
            lives[id] = run
            openLive(run, engine: engine, language: language)
        case .none:
            lives[id] = run
            let generation = sessionGeneration
            run.opening = Task { [weak self] in
                let engine = await liveEngineTask.value
                guard let self, self.sessionGeneration == generation, self.lives[id] === run else { return }
                guard let engine else {
                    self.cancelLive(id)
                    return
                }
                self.openLive(run, engine: engine, language: language)
            }
        }
        return run.feed.sink
    }

    /// Opens the session and feeds the queued frames in order; a sentence whose queue overflowed (the session opened too slowly) does not use real-time, and its transcript comes from the recording file.
    private func openLive(_ run: LiveRun, engine: any LiveSTTEngine, language: String?) {
        let session = engine.startLive(language: language)
        guard run.feed.attach(session) else {
            session.cancel()
            return
        }
        run.session = session
        run.reader = Task { [weak self, weak run] in
            for await snapshot in session.snapshots {
                guard let self, let run else { return }
                self.receiveLive(snapshot, run: run)
            }
        }
    }

    /// Caption = livePartial(finals, partial); dispatches sttPartial only when it is still the sentence currently being spoken and the text has changed.
    private func receiveLive(_ snapshot: SystemSTTLiveSnapshot, run: LiveRun) {
        guard isActive, lives[run.id] === run, openUtteranceId == run.id else { return }
        let text = DictationRules.livePartial(finals: snapshot.finals, partial: snapshot.partial).text
        guard text != run.caption else { return }
        run.caption = text
        receivePartial(text)
    }

    /// After a queued-onset replay: during the queue the real-time caption was already recorded in run.caption, so the same text is not dispatched again later;
    /// if this sentence is replayed as speaking, dispatch it once more so the caption does not wait for the next change.
    private func recaptionReplayedUtterance() {
        guard state.userSpeaking, let id = openUtteranceId, let run = lives[id],
              !run.caption.isEmpty, state.partialText != run.caption else { return }
        pendingEvents.append(.sttPartial(text: run.caption))
    }

    /// Sentence abandoned (discarded / barge-in undone / muted / ended): cancelled immediately, without waiting for a result.
    private func cancelLive(_ id: String) {
        lives.removeValue(forKey: id)?.cancel()
    }

    private func cancelAllLives() {
        let runs = lives.values
        lives = [:]
        for run in runs { run.cancel() }
    }

    /// Ends input and takes the real-time result within limit; used only if non-empty. Empty / failed / timed out / session not opened returns nil (the session has been cancelled).
    private static func finishLive(_ run: LiveRun?, within limit: Duration) async -> String? {
        guard let run else { return nil }
        run.opening?.cancel()
        guard let session = run.session else {
            run.cancel()
            return nil
        }
        do {
            let text = try await VoiceDeadline.run(within: limit) { try await session.finish() }
            guard !DictationRules.trim(text).isEmpty else { return nil }
            return text
        } catch {
            session.cancel()
            return nil
        }
    }

    // MARK: Reply

    private func send(_ text: String) {
        segmentsEnqueued = 0
        replyText = ""
        replyVoice = nil
        replyLanguage = nil
        cloudFellBack = false
        let generation = sessionGeneration
        let cancels = replyCancels
        let text = takeCarried(prependingTo: text)
        // Synchronously registered: the cancelGeneration later in the same batch (replayed barge-in) applies to this turn.
        let sending = chat.beginSend(text)
        Task { [weak self] in
            let sent = await sending.value
            guard let self, self.sessionGeneration == generation, self.isActive,
                  self.replyCancels == cancels, !sent else { return }
            self.dispatch(.replyFailed(code: "send_failed"))
        }
    }

    private func amend(_ text: String) {
        segmentsEnqueued = 0
        replyText = ""
        replyVoice = nil
        replyLanguage = nil
        cloudFellBack = false
        let generation = sessionGeneration
        let cancels = replyCancels
        let text = takeCarried(prependingTo: text)
        amendSerial += 1
        let serial = amendSerial
        pendingAmend = (text, serial, false)
        // Synchronously registered: the cancelGeneration later in the same batch applies to this barge-in.
        let amending = chat.beginAmend(text) { [weak self] in
            guard let self, self.pendingAmend?.serial == serial else { return }
            self.pendingAmend?.delivered = true
        }
        Task { [weak self] in
            let sent = await amending.value
            if let self, self.pendingAmend?.serial == serial { self.pendingAmend = nil }
            guard let self, self.sessionGeneration == generation, self.isActive,
                  self.replyCancels == cancels, !sent else { return }
            self.dispatch(.replyFailed(code: "send_failed"))
        }
    }

    /// Takes the barge-in text intercepted by cancellation and prepends it to this text via joinAmend (for empty text regenerated as-is, only the staged portion is sent).
    private func takeCarried(prependingTo text: String) -> String {
        guard let carried = carriedAmend else { return text }
        carriedAmend = nil
        return Logic.joinAmend(carried, text)
    }

    private static func voicePrompt(_ prompt: Logic.Prompt) -> VoicePrompt {
        switch prompt {
        case .didNotCatch: return .didNotCatch
        case .approvalNeeded: return .approvalNeeded
        case .sayAgain: return .sayAgain
        case .checkLanguage: return .checkLanguage
        case .echoHint: return .echoHint
        }
    }

    private func handleReply(_ event: VoiceConversationReplyEvent) {
        switch event {
        case .text(let text):
            guard state.reply == .streaming else { return }
            replyText = text
            enqueueNewSegments(final: false)
        case .completed:
            guard state.reply == .streaming else { return }
            enqueueNewSegments(final: true)
            dispatch(.replyCompleted)
            if speaking == nil && speechQueue.isEmpty { drained() }
        case .failed(let code):
            dispatch(.replyFailed(code: code))
        case .approvalPending(let pending):
            dispatch(pending ? .approvalPending : .approvalResolved)
        }
    }

    /// Only feeds the newly appearing closed sentences (the final includes the tail sentence) to the reducer; the prefix is stable.
    private func enqueueNewSegments(final: Bool) {
        let segments = SpeakableText.segments(text: replyText, final: final)
        guard segments.count > segmentsEnqueued else { return }
        let fresh = segments[segmentsEnqueued...]
        segmentsEnqueued = segments.count
        for segment in fresh {
            switch segment {
            case .sentence(let text): dispatch(.replySentence(text: text))
            case .placeholder(let kind): dispatch(.replySentence(text: prompt(.placeholder(kind))))
            }
        }
    }

    // MARK: Speaking

    /// Prompts are inserted after the current sentence and before the remaining reply sentences; multiple prompts go first in, first out.
    private func enqueue(_ item: SpeechItem) {
        let queued = QueuedSpeech(item)
        if case .prompt = item, speaking != nil {
            let promptsAhead = speechQueue.prefix { $0.item.isPrompt }.count
            speechQueue.insert(queued, at: promptsAhead)
        } else {
            speechQueue.append(queued)
        }
        pumpSpeech()
    }

    private func pumpSpeech() {
        guard speaking == nil, !speechQueue.isEmpty else { return }
        let next = speechQueue.removeFirst()
        speaking = next
        let generation = speechGeneration
        if case .sentence(let text) = next.item, replyVoice == nil { resolveReplyVoice(firstSentence: text) }
        prefetch(next)
        if let following = speechQueue.first { prefetch(following) }
        // Prompt: before playing, reports the text being played (for echo comparison); reports the end when it finishes, fails, or is stopped.
        if next.item.isPrompt {
            next.promptSession = sessionGeneration
            dispatch(.promptStarted(text: next.item.text))
        }
        Task { [weak self] in
            guard let self else { return }
            defer { self.endPrompt(next) }
            let outcome = await self.play(next)
            self.speechEnded(next, outcome: outcome, generation: generation)
        }
    }

    private func resolveReplyVoice(firstSentence: String) {
        let language = detectLanguage(firstSentence) ?? AppLocalization.currentLanguage.rawValue
        replyLanguage = language
        let choice = readAloud.select(language) { _ in }
        if let fallback = choice.fallback { onTTSEngineFallback?(fallback) }
        if let cloud = choice.engine as? ConversationCloudSynthesizing {
            replyVoice = .cloud(cloud)
        } else {
            replyVoice = .system
        }
    }

    /// Cloud: starts synthesis early (prefetches only one extra sentence).
    private func prefetch(_ queued: QueuedSpeech) {
        guard queued.synthesis == nil, !cloudFellBack, case .sentence(let text) = queued.item,
              case .cloud(let cloud)? = replyVoice
        else { return }
        queued.synthesis = Task { try await cloud.synthesize(text: text) }
    }

    private func play(_ queued: QueuedSpeech) async -> ConversationPlaybackOutcome {
        let text = queued.item.text
        guard case .sentence = queued.item, case .cloud(let cloud)? = replyVoice, !cloudFellBack,
              let synthesis = queued.synthesis
        else {
            let language = queued.item.isPrompt ? detectLanguage(text) : replyLanguage
            return await audio.speak(text, language: language)
        }
        do {
            let data = try await synthesis.value
            return await audio.play(audio: data, fileExtension: cloud.audioFileExtension)
        } catch is CancellationError {
            return .stopped
        } catch {
            // Cloud failed: the remaining sentences of this reply fall back to the system voice, with the notice shown only once.
            if !cloudFellBack {
                cloudFellBack = true
                onCloudFallback?(cloud.fallbackProviderName)
                if !fallbackNoticeShown {
                    fallbackNoticeShown = true
                    onCloudFallbackNotice?(cloud.fallbackProviderName)
                }
            }
            return await audio.speak(text, language: replyLanguage)
        }
    }

    /// Prompt end is reported only once; not dispatched if the conversation has ended or the session was replaced (the ended state does not receive events anyway).
    private func endPrompt(_ queued: QueuedSpeech) {
        guard let session = queued.promptSession else { return }
        queued.promptSession = nil
        guard isActive, sessionGeneration == session else { return }
        dispatch(.promptEnded)
    }

    private func speechEnded(_ queued: QueuedSpeech, outcome: ConversationPlaybackOutcome, generation: Int) {
        guard generation == speechGeneration, speaking === queued else { return }
        endPrompt(queued)
        speaking = nil
        guard isActive else { return }
        if speechQueue.isEmpty {
            drained()
        } else {
            pumpSpeech()
        }
    }

    /// Queue drained empty: only when the reply has completed is the barge-in candidate window closed and the grace start reset on the next playback start; during a mid-stream temporary pause the window and grace start point do not move
    /// (the next sentence may arrive immediately, and speaking in the gap still counts as barge-in); playbackDrained is still dispatched to the reducer.
    private func drained() {
        if state.reply != .streaming {
            playbackActive = false
            playbackStartFrame = nil
        }
        dispatch(.playbackDrained)
    }

    /// Stops playback and discards queued and paused sentences.
    private func clearSpeech() {
        speechGeneration += 1
        for queued in speechQueue { queued.synthesis?.cancel() }
        speaking?.synthesis?.cancel()
        if let speaking { endPrompt(speaking) }
        speechQueue = []
        speaking = nil
        playbackActive = false
        playbackStartFrame = nil
        audio.stopPlayback()
    }

    private func playStoredMessage(_ text: String) {
        let sentences: [String] = SpeakableText.segments(text: text, final: true).map {
            switch $0 {
            case .sentence(let text): return text
            case .placeholder(let kind): return prompt(.placeholder(kind))
            }
        }
        messageTask = Task { [weak self] in
            for sentence in sentences {
                guard let self, self.isActive else { return }
                let outcome = await self.audio.speak(sentence, language: self.detectLanguage(sentence))
                if outcome != .finished { break }
            }
            guard let self, self.isActive else { return }
            self.dispatch(.messagePlaybackEnded)
        }
    }

    // MARK: End

    private func finish(reason: Logic.EndReason, code: String?) {
        guard isActive else { return }
        isActive = false
        cancelDeadline()
        replyTask?.cancel()
        replyTask = nil
        messageTask?.cancel()
        messageTask = nil
        clearSpeech()
        if reason != .idle { audio.stop() } else { stopAfterEarcon() }
        memory.conversationEnded(triggered: falseBargeInLimitReached, hadSpeakerPlayback: hadSpeakerPlayback)
        for id in Array(recordings.keys) { discardRecording(id) }
        cancelAllLives()
        level = 0
        let draft = draftRecording
        draftRecording = nil
        // Already delivered and empty = no draft; an undelivered one is handled as a draft and transcribed when it arrives.
        guard let draft, !draft.deliveredEmpty, let sttChoice else {
            draft?.abandon()
            onEnded?(VoiceConversationEnd(reason: reason, code: code, draft: nil))
            return
        }
        // End first (the host collapses immediately and can reopen right away); the draft recording is delivered and transcribed, after which it is delivered separately via onDraft.
        onEnded?(VoiceConversationEnd(reason: reason, code: code, draft: nil, draftPending: true))
        let deliver = onDraft
        let language = sttLanguage()
        draft.wait { recording in
            guard let recording else {
                deliver?(nil)
                return
            }
            Task {
                let engine = await sttChoice.value.engine
                let text = try? await engine.transcribe(recording, language: language)
                draft.abandon()
                deliver?(text.flatMap { $0.isEmpty ? nil : $0 })
            }
        }
    }

    /// On idle end, let the end prompt sound finish before deactivating the session.
    private func stopAfterEarcon() {
        let delay = ConversationEarconSynth.durationMs(.end) + 50
        // Strong reference to audio: the host's teardown releases the controller first, and a delayed stop must still execute (otherwise the session would not deactivate, and the lease would not be released after stop).
        // Skipped only when the controller is still present and a new conversation has already started.
        Task { [weak self, audio] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000))
            if let self, self.isActive { return }
            audio.stop()
        }
    }

    private func resetSession() {
        state = Logic.initialState()
        pendingEvents = []
        settleEndedIds = []
        vad = Logic.Vad()
        lastFrame = -1
        playbackActive = false
        playbackStartFrame = nil
        playbackEndedFrame = nil
        openUtteranceId = nil
        cancelAllLives()
        liveEngineTask = nil
        resolvedLiveEngine = nil
        for pending in recordings.values { pending.abandon() }
        recordings = [:]
        draftRecording?.abandon()
        draftRecording = nil
        speechQueue = []
        speaking = nil
        replyVoice = nil
        falseBargeInLimitReached = false
        hadSpeakerPlayback = false
        nudgeCount = 0
        fallbackNoticeShown = false
        segmentsEnqueued = 0
        replyText = ""
    }
}

extension VoiceConversationController: ConversationAudioEngineDelegate {
    func conversationAudio(didCaptureFrame index: Int, db: Double) {
        handleFrame(index: index, db: db)
    }

    func conversationAudio(didCaptureFrame index: Int, db: Double, speechProb: Double?) {
        handleFrame(index: index, db: db, speechProb: speechProb)
    }

    func conversationAudio(didMeasureOutput db: Double) {
        guard isActive, state.phase == .speaking else { return }
        publishLevel(ConversationAudioMath.level(db: db, floorDb: ConversationAudioMath.aiFloorDb))
    }

    func conversationAudioDidBeginSentence() {
        guard isActive, case .sentence(let text)? = speaking?.item else { return }
        if !playbackActive {
            playbackActive = true
            playbackStartFrame = lastFrame + 1
        }
        playbackEndedFrame = nil
        dispatch(.sentenceStarted(text: text))
    }

    /// Last block's dataPlayedBack: the playback-finished moment = now (clock.nowMs), without waiting for speak / play to return before dispatching playbackDrained.
    func conversationAudioDidFinishPlayback() {
        guard isActive, let current = speaking else { return }
        speechEnded(current, outcome: .finished, generation: speechGeneration)
    }

    func conversationAudioInterruptionBegan() {
        dispatch(.interruptionBegan)
    }

    func conversationAudioInterruptionEnded() {
        dispatch(.interruptionEnded)
    }

    /// The system advises against resuming: ends the conversation as an interruption.
    func conversationAudioInterruptionEndedWithoutResume() {
        dispatch(.end(reason: .interruption))
    }

    /// Capture stalled (rebuild failed / frame stream cut off): ends as system, same as Android onCaptureFailed.
    func conversationAudioCaptureFailed(reason: ConversationCaptureFailure) {
        diagnostics.captureStalled(reason: reason.rawValue)
        dispatch(.end(reason: .system))
    }

    func conversationAudio(routeChanged route: VoiceConversationLogic.Route, oldDeviceUnavailable: Bool) {
        dispatch(.routeChanged(route: route))
    }
}

/// One sentence's real-time recognition: the session, the wait for opening the session, the task reading snapshots, and the caption already dispatched.
@MainActor
private final class LiveRun {
    let id: String
    let feed = LiveUtteranceFeed()
    var session: SystemSTTSession?
    var opening: Task<Void, Never>?
    var reader: Task<Void, Never>?
    var caption = ""

    init(id: String) { self.id = id }

    func cancel() {
        opening?.cancel()
        reader?.cancel()
        feed.close()
        session?.cancel()
    }
}

/// Recording io queue → real-time session: before the session is open, frames are queued in order (up to queueLimitSec seconds; a sentence beyond that does not use real-time); once open, they are fed directly.
/// The sink is called on the io queue, only queues / hands off, and does no heavy work.
private nonisolated final class LiveUtteranceFeed: @unchecked Sendable {
    static let queueLimitSec = 10.0

    private let lock = NSLock()
    private var queued: [AVAudioPCMBuffer] = []
    private var queuedSec = 0.0
    private var overflowed = false
    private var session: SystemSTTSession?
    private var closed = false

    var sink: ConversationLiveSink {
        { [self] buffer in receive(buffer) }
    }

    private func receive(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard !closed, !overflowed else { return }
            if let session {
                session.feed(buffer)
                return
            }
            let seconds = Double(buffer.frameLength) / max(buffer.format.sampleRate, 1)
            guard queuedSec + seconds <= Self.queueLimitSec else {
                overflowed = true
                queued = []
                return
            }
            queued.append(buffer)
            queuedSec += seconds
        }
    }

    /// Hands queued frames to the session in order; later frames are fed directly. Returns false if closed or the queue overflowed.
    func attach(_ session: SystemSTTSession) -> Bool {
        lock.withLock {
            guard !closed, !overflowed else { return false }
            for buffer in queued { session.feed(buffer) }
            queued = []
            queuedSec = 0
            self.session = session
            return true
        }
    }

    func close() {
        lock.withLock {
            closed = true
            queued = []
            session = nil
        }
    }
}

/// A segment recording still being closed on io: before delivery, waiters can be registered; after abandonment, the file is deleted on delivery.
private final class PendingRecording {
    private var delivered = false
    private var result: RecordingResult?
    private var waiter: ((RecordingResult?) -> Void)?
    private var abandoned = false
    private let files: FileManager

    init(files: FileManager) {
        self.files = files
    }

    /// Delivered with no recording (not recording / export failed).
    var deliveredEmpty: Bool { delivered && result == nil }

    func deliver(_ recording: RecordingResult?) {
        guard !delivered else { return }
        delivered = true
        result = recording
        if abandoned {
            removeFile()
            return
        }
        if let waiter {
            self.waiter = nil
            waiter(recording)
        }
    }

    /// If already delivered, calls back immediately; otherwise calls back at delivery. The file still belongs to this object; call abandon when done to delete it.
    func wait(_ body: @escaping (RecordingResult?) -> Void) {
        guard !abandoned else { return }
        if delivered {
            body(result)
        } else {
            waiter = body
        }
    }

    func abandon() {
        abandoned = true
        waiter = nil
        if delivered { removeFile() }
    }

    /// The file deletion is dispatched to the background utility queue; the main thread does no file IO.
    private func removeFile() {
        guard let result else { return }
        self.result = nil
        let files = UncheckedFiles(manager: self.files)
        let url = result.url
        Self.removalQueue.async { try? files.manager.removeItem(at: url) }
    }

    private static let removalQueue = DispatchQueue(label: "com.oriveo.voice-conversation.segment-removal",
                                                    qos: .utility)

    private struct UncheckedFiles: @unchecked Sendable {
        let manager: FileManager
    }
}
