import Combine
import Foundation

// MARK: - Ports

/// Chat reply events: text is the full text of the current reply (delivered once per change).
enum VoiceConversationReplyEvent: Equatable, Sendable {
    case text(String)
    case completed
    case failed(code: String)
    /// true = an approval is pending (tool confirmation etc.), false = it has been handled.
    case approvalPending(Bool)
}

/// The bridge between voice conversation and chat (implemented with AppState / ChatManager).
protocol VoiceConversationChatPort: AnyObject {
    /// Sends a user message (purpose = chat); false = it could not be sent (no model, no connection, etc.).
    func send(_ text: String) async -> Bool
    /// Takes a fresh reply event stream each time a conversation starts (cancelling the iteration when the conversation ends terminates it); only forwards events of the current reply.
    func makeReplyEvents() -> AsyncStream<VoiceConversationReplyEvent>
    /// Cancels the generation in flight.
    func cancel()
}

/// A prompt to speak aloud; the host supplies the text in the UI language (localized).
enum VoicePrompt: Equatable, Sendable {
    case didNotCatch
    case approvalNeeded
    /// The placeholder sentence for a code / table / formula block in the reply.
    case placeholder(SpeakablePlaceholder)
}

/// How a conversation ended, handed to the host (to write the draft, show the error card).
struct VoiceConversationEnd: Equatable, Sendable {
    let reason: VoiceConversationLogic.EndReason
    /// The error code from replyFailed.
    let code: String?
    /// The half-finished transcript when the user tapped close (written into the draft); nil if there is none.
    let draft: String?
    /// true = a half-finished recording existed when the user tapped close; its transcript is delivered later through onDraft (the conversation has already ended).
    var draftPending = false
}

/// The synthesize-only entry point of the cloud read-aloud engine (implemented by CloudSpeechEngine).
protocol ConversationCloudSynthesizing: AnyObject {
    func synthesize(text: String) async throws -> Data
    /// Audio file extension (the catalog's outputFormat).
    var audioFileExtension: String { get }
    /// Provider name used in the fallback notice.
    var fallbackProviderName: String { get }
}

// MARK: - Clock

protocol VoiceConversationTimer: AnyObject {
    func cancel()
}

/// Millisecond clock plus timer callbacks; tests inject a manual clock.
protocol VoiceConversationClock: AnyObject {
    var nowMs: Int { get }
    /// One-shot timer: calls back once after ms milliseconds.
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

// MARK: - Remembering "no voice barge-in on speaker" on this device

/// Stored only in local UserDefaults, never reported and not exposed as a setting; cleared to re-learn when the OS major version changes.
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

    /// Checks the OS major version before reading: cleared if it changed.
    var remembersNoSpeakerBargeIn: Bool {
        clearIfOSChanged()
        return defaults.bool(forKey: Key.remembered)
    }

    /// A conversation ended: triggered = this conversation hit the false-barge-in limit; not triggered but played on the speaker = the streak is broken.
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

/// Voice conversation host: translates audio / recognition / chat signals into `VoiceConversationLogic` events and runs the returned effects in order.
/// The display state comes only from the reducer; the UI reads just displayState / statusKey / level.
final class VoiceConversationController: ObservableObject, VoiceConversationSurface {
    typealias Logic = VoiceConversationLogic

    @Published private(set) var displayState: Logic.DisplayState?
    @Published private(set) var statusKey: Logic.StatusKey?
    /// Status orb level 0...1: listening = microphone, speaking = output; 0 otherwise; at most about 15 updates per second.
    @Published private(set) var level: Double = 0
    @Published private(set) var isActive = false

    /// The conversation ended (including errors, idle timeout and the close button).
    var onEnded: ((VoiceConversationEnd) -> Void)?
    /// The draftPending draft transcript finished after the end (nil when empty / failed); setting it inside onEnded is enough, and it is still delivered after the controller is released.
    var onDraft: ((String?) -> Void)?
    /// Cloud read-aloud failed midway and the rest of this reply uses the system voice; the argument is the provider name (the host shows the notice).
    var onCloudFallback: ((String) -> Void)?
    /// The user-visible notice for a cloud read-aloud fallback: sent once per conversation (each reply still tries the cloud first and calls onCloudFallback on its own).
    var onCloudFallbackNotice: ((String) -> Void)?
    /// The stored cloud read-aloud choice is no longer valid and the system voice is used this time (the setting has been reset to system).
    var onTTSEngineFallback: ((VoiceFallbackReason) -> Void)?

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
    private let sttLanguage: () -> String?

    private(set) var state = Logic.initialState()
    private var pendingEvents: [Logic.Event] = []
    private var dispatching = false
    /// Incremented on every start: send / transcription Tasks left over from the previous conversation are discarded by it when they return.
    private var sessionGeneration = 0

    // Capture
    private var vad = Logic.Vad()
    private var lastFrame = -1
    private var playbackStartFrame: Int?
    private var utteranceCounter = 0
    private var recordings: [String: PendingRecording] = [:]
    private var draftRecording: PendingRecording?
    private var lastLevelMs: Int?
    private var sttChoice: Task<DictationEngineChoice, Never>?

    // Reply
    private var replyTask: Task<Void, Never>?
    private var segmentsEnqueued = 0
    private var replyText = ""

    // Speech
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
    /// The fallback notice has already been shown this conversation; reset by start, not by send.
    private var fallbackNoticeShown = false
    private var messageTask: Task<Void, Never>?
    private var pendingMessages: [String: String] = [:]

    /// The one-shot timer scheduled from Logic.nextDeadlineMs; at most one at a time.
    private var deadlineTimer: VoiceConversationTimer?
    private var armedDeadlineMs: Int?
    private var falseBargeInLimitReached = false
    /// Deletes segment recording files nobody waits for anymore; only called off the main thread (tests inject an implementation that records the thread).
    private let segmentFiles: FileManager
    private var hadSpeakerPlayback = false

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
        segmentFiles: FileManager = .default
    ) {
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
        audio.delegate = self
    }

    // MARK: Public actions

    /// The user tapped the voice button (foreground): stops read-aloud, activates the session and starts listening. Throws when session activation fails, and the conversation does not begin.
    func start() throws {
        guard !isActive else { return }
        stopReadAloud()
        try audio.start()
        resetSession()
        sessionGeneration += 1
        isActive = true
        let source = dictation
        sttChoice = Task { await source.select() }
        let events = chat.makeReplyEvents()
        replyTask = Task { [weak self] in
            for await event in events {
                guard let self, self.isActive else { return }
                self.handleReply(event)
            }
        }
        dispatch(.start(route: audio.route, deviceRemembersNoSpeakerBargeIn: memory.remembersNoSpeakerBargeIn))
    }

    /// Close button = user; conversation switch / navigating back = system.
    func end(_ reason: Logic.EndReason = .user) {
        dispatch(.end(reason: reason == .user ? .user : .system))
    }

    func tapOrb() { dispatch(.tapOrb) }
    func toggleMute() { dispatch(.toggleMute) }

    /// Tapping the speaker button on an old message during a conversation: pauses capture, plays it with the same engine, then returns to listening.
    func playMessage(id: String, text: String) {
        pendingMessages[id] = text
        dispatch(.playMessage(messageId: id))
        pendingMessages[id] = nil
    }

    /// The screen reader is speaking: capture is not processed meanwhile.
    func setScreenReaderSpeaking(_ speaking: Bool) {
        dispatch(.screenReaderSpeaking(speaking))
    }

    // MARK: Event loop

    private func dispatch(_ event: Logic.Event) {
        pendingEvents.append(event)
        guard !dispatching else { return }
        dispatching = true
        while !pendingEvents.isEmpty {
            let next = pendingEvents.removeFirst()
            let (newState, effects) = Logic.reduce(state, next, atMs: clock.nowMs)
            state = newState
            publish()
            for effect in effects { perform(effect) }
            armDeadline()
        }
        dispatching = false
    }

    /// Rescheduled after every reduce from nextDeadlineMs: untouched when the value is unchanged, otherwise the old timer is cancelled and a new one scheduled; already expired deadlines are dispatched immediately.
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
        if display != .listening && display != .speaking && level != 0 { level = 0 }
        if state.phase == .speaking && audio.isSpeakerRoute { hadSpeakerPlayback = true }
    }

    private func perform(_ effect: Logic.Effect) {
        switch effect {
        case .startCapture:
            break  // start() already activated the session and installed the tap
        case .pauseCapture:
            dropUtterance()
            audio.pauseCapture()
        case .resumeCapture:
            audio.resumeCapture()
        case .setCaptureMuted(let muted):
            if muted { dropUtterance() }
            audio.setCaptureMuted(muted)
        case .transcribe(let id):
            transcribe(id)
        case .transcribeToDraft:
            if vad.speaking { vad.reset() }
            draftRecording?.abandon()
            let draft = PendingRecording(files: segmentFiles)
            draftRecording = draft
            audio.finishUtterance { draft.deliver($0) }
        case .sendMessage(let text):
            send(text)
        case .cancelGeneration:
            chat.cancel()
            clearSpeech()
        case .pausePlayback:
            audio.pausePlayback()
        case .resumePlayback(let from):
            if from == .sentenceStart { playbackStartFrame = lastFrame + 1 }
            audio.resumePlayback(fromSentenceStart: from == .sentenceStart)
        case .stopPlayback:
            clearSpeech()
        case .enqueueSpeech(let text):
            enqueue(.sentence(text))
        case .speakPrompt(let kind):
            enqueue(.prompt(prompt(kind == .didNotCatch ? .didNotCatch : .approvalNeeded)))
        case .earcon(let kind):
            audio.playEarcon(kind)
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

    private func handleFrame(index: Int, db: Double) {
        guard isActive else { return }
        lastFrame = index
        if state.phase == .listening { publishLevel(db) }
        // Don't capture while a prompt is playing, so the speaker output isn't mistaken for the user's voice.
        if case .prompt = speaking?.item { return }
        let candidateFrom = state.phase == .speaking && audio.isSpeakerRoute ? playbackStartFrame : nil
        guard let event = vad.step(frame: index, db: db, candidateFrom: candidateFrom) else { return }
        handleVad(event)
    }

    private func handleVad(_ event: Logic.VadEvent) {
        switch event {
        case .speechStart(_, let prerollFrame):
            // Don't start recording for an onset the reducer will drop, to avoid creating a file only to delete it.
            if !Logic.dropsVad(state) { audio.beginUtterance(fromFrame: prerollFrame) }
            dispatch(.vadSpeechStart)
            if state.phase == .speaking && state.userSpeaking { dispatch(.bargeInDetected) }
            if !state.userSpeaking { audio.discardUtterance() }
        case .speechEnd:
            guard state.userSpeaking else {
                audio.discardUtterance()
                return
            }
            utteranceCounter += 1
            let id = "u\(utteranceCounter)"
            // The recording is delivered only after finalizing on io; vadSpeechEnd doesn't wait for it, transcription does.
            let pending = PendingRecording(files: segmentFiles)
            recordings[id] = pending
            audio.finishUtterance { pending.deliver($0) }
            dispatch(.vadSpeechEnd(utteranceId: id))
            if state.awaitedUtteranceId != id { discardRecording(id) }
        case .discarded:
            audio.discardUtterance()
            dispatch(.vadDiscarded)
        }
    }

    /// Drops speech in progress (mute, capture paused).
    private func dropUtterance() {
        vad.reset()
        audio.discardUtterance()
    }

    private func publishLevel(_ db: Double) {
        let now = clock.nowMs
        if let last = lastLevelMs, now - last < Self.levelIntervalMs { return }
        lastLevelMs = now
        let value = min(1, max(0, (db + 60) / 60))
        if level != value { level = value }
    }

    // MARK: Recognition

    private func transcribe(_ id: String) {
        guard let pending = recordings[id], let sttChoice else {
            dispatch(.sttFailed(utteranceId: id))
            return
        }
        let generation = sessionGeneration
        // Don't transcribe before finalizing completes; if the session generation changed or this segment is no longer awaited, delete it on delivery.
        pending.wait { [weak self] recording in
            guard let self, self.sessionGeneration == generation, self.isActive,
                  self.state.awaitedUtteranceId == id, self.recordings[id] === pending else {
                pending.abandon()
                return
            }
            guard let recording else {
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
        Task { [weak self] in
            let engine = await sttChoice.value.engine
            let result: Result<String, Error>
            do {
                result = .success(try await engine.transcribe(recording, language: language))
            } catch {
                result = .failure(error)
            }
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

    private func discardRecording(_ id: String) {
        recordings.removeValue(forKey: id)?.abandon()
    }

    // MARK: Reply

    private func send(_ text: String) {
        segmentsEnqueued = 0
        replyText = ""
        replyVoice = nil
        replyLanguage = nil
        cloudFellBack = false
        let generation = sessionGeneration
        Task { [weak self, chat] in
            let sent = await chat.send(text)
            guard let self, self.sessionGeneration == generation, self.isActive, !sent else { return }
            self.dispatch(.replyFailed(code: "send_failed"))
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
            if speaking == nil && speechQueue.isEmpty { dispatch(.playbackDrained) }
        case .failed(let code):
            dispatch(.replyFailed(code: code))
        case .approvalPending(let pending):
            dispatch(pending ? .approvalPending : .approvalResolved)
        }
    }

    /// Feeds the reducer only newly closed sentences (including the trailing sentence when final); the prefix is stable.
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

    // MARK: Speech

    private func enqueue(_ item: SpeechItem) {
        let queued = QueuedSpeech(item)
        if case .prompt = item, speaking != nil {
            speechQueue.insert(queued, at: 0)
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
        Task { [weak self] in
            guard let self else { return }
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

    /// Cloud: starts synthesis ahead of time (prefetches just one extra sentence).
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
            // Cloud failed: the rest of this reply falls back to the system voice, with a single notice.
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

    private func speechEnded(_ queued: QueuedSpeech, outcome: ConversationPlaybackOutcome, generation: Int) {
        guard generation == speechGeneration, speaking === queued else { return }
        speaking = nil
        guard isActive else { return }
        if speechQueue.isEmpty {
            dispatch(.playbackDrained)
        } else {
            pumpSpeech()
        }
    }

    /// Stops playback and drops queued and paused sentences.
    private func clearSpeech() {
        speechGeneration += 1
        for queued in speechQueue { queued.synthesis?.cancel() }
        speaking?.synthesis?.cancel()
        speechQueue = []
        speaking = nil
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

    // MARK: Ending

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
        level = 0
        let draft = draftRecording
        draftRecording = nil
        // Delivered and empty = no draft; one not yet delivered is treated as a draft and transcribed when it arrives.
        guard let draft, !draft.deliveredEmpty, let sttChoice else {
            draft?.abandon()
            onEnded?(VoiceConversationEnd(reason: reason, code: code, draft: nil))
            return
        }
        // End first (the host collapses immediately and can reopen right away); the draft recording is delivered and transcribed, then arrives separately through onDraft.
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

    /// On an idle end, lets the ending earcon finish before deactivating the session.
    private func stopAfterEarcon() {
        let delay = ConversationEarconSynth.durationMs(.end) + 50
        // Hold audio strongly: the host's teardown releases the controller first, but the delayed stop must still run (otherwise the session is never deactivated and the lease is not released after stop).
        // Skip only when the controller still exists and has already started a new conversation.
        Task { [weak self, audio] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000))
            if let self, self.isActive { return }
            audio.stop()
        }
    }

    private func resetSession() {
        state = Logic.initialState()
        pendingEvents = []
        vad = Logic.Vad()
        lastFrame = -1
        playbackStartFrame = nil
        for pending in recordings.values { pending.abandon() }
        recordings = [:]
        draftRecording?.abandon()
        draftRecording = nil
        speechQueue = []
        speaking = nil
        replyVoice = nil
        falseBargeInLimitReached = false
        hadSpeakerPlayback = false
        fallbackNoticeShown = false
        segmentsEnqueued = 0
        replyText = ""
    }
}

extension VoiceConversationController: ConversationAudioEngineDelegate {
    func conversationAudio(didCaptureFrame index: Int, db: Double) {
        handleFrame(index: index, db: db)
    }

    func conversationAudio(didMeasureOutput db: Double) {
        guard isActive, state.phase == .speaking else { return }
        publishLevel(db)
    }

    func conversationAudioDidBeginSentence() {
        guard isActive, case .sentence(let text)? = speaking?.item else { return }
        playbackStartFrame = lastFrame + 1
        dispatch(.sentenceStarted(text: text))
    }

    func conversationAudioInterruptionBegan() {
        dispatch(.interruptionBegan)
    }

    func conversationAudioInterruptionEnded() {
        dispatch(.interruptionEnded)
    }

    /// The system advises against resuming: ends as an interruption (not routed through .system, which would read as navigation).
    func conversationAudioInterruptionEndedWithoutResume() {
        dispatch(.end(reason: .interruption))
    }

    func conversationAudio(routeChanged route: VoiceConversationLogic.Route, oldDeviceUnavailable: Bool) {
        dispatch(.routeChanged(route: route))
    }
}

/// A recording still being finalized on io: a waiter can register before delivery; once abandoned, the file is deleted on delivery.
private final class PendingRecording {
    private var delivered = false
    private var result: RecordingResult?
    private var waiter: ((RecordingResult?) -> Void)?
    private var abandoned = false
    private let files: FileManager

    init(files: FileManager) {
        self.files = files
    }

    /// Delivered with no recording (nothing was recording / the export failed).
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

    /// Calls back immediately if already delivered, otherwise on delivery. The file still belongs to this object; call abandon to delete it when done.
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

    /// File removal goes to a background utility queue; the main thread does no file IO.
    private func removeFile() {
        guard let result else { return }
        self.result = nil
        let files = UncheckedFiles(manager: self.files)
        let url = result.url
        Self.removalQueue.async { try? files.manager.removeItem(at: url) }
    }

    private static let removalQueue = DispatchQueue(label: "com.kenny.oriveo.voice-conversation.segment-removal",
                                                    qos: .utility)

    private struct UncheckedFiles: @unchecked Sendable {
        let manager: FileManager
    }
}
