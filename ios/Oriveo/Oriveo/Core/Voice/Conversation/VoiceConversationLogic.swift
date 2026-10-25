import Foundation

/// Turn-taking contract for voice conversation (`voice-conversation.v1`).
/// Everything here is a pure function: no IO, no clock; time comes in through each event's atMs. The host only
/// translates real signals into events and executes the returned effects.
nonisolated enum VoiceConversationLogic {

    // MARK: - Constants (client-side constants; names match the fixture's constants)

    enum Constants {
        static let frameMs = 20
        static let vadStartMs = 120
        static let vadEndSilenceMs = 600
        static let vadMinUtteranceMs = 250
        static let vadPrerollMs = 300
        static let vadStartOverFloorDb = 12.0
        static let vadContinueOverFloorDb = 6.0
        static let vadAbsoluteMinDb = -55.0
        static let floorInitDb = -50.0
        static let floorAlpha = 0.05
        static let floorClampDb: ClosedRange<Double> = -90.0 ... -30.0
        static let frameDbClampDb: ClosedRange<Double> = -120.0 ... 0.0
        static let bargeInGraceMs = 1000
        static let bargeInMinSpeechMs = 300
        static let echoOverlapRatio = 0.6
        static let falseBargeInsPerConversation = 2
        static let conversationsToRemember = 2
        static let idleTimeoutMs = 120_000
        static let thinkingEarconMs = 3000
        static let listenToThinkTapGuardMs = 600
        static let stopToVoiceGuardMs = 500
        static let sttRetries = 1
    }

    // MARK: - A. VAD

    enum VadEvent: Equatable, Sendable {
        case speechStart(frame: Int, prerollFrame: Int)
        case speechEnd(frame: Int, voicedMs: Int)
        case discarded(frame: Int)
    }

    /// Per-frame VAD state; the host calls `step` once per frame.
    struct Vad: Equatable, Sendable {
        private(set) var floorDb = Constants.floorInitDb
        private(set) var speaking = false
        private var runFrames = 0
        private var runStart = 0
        private var silenceFrames = 0
        private var voicedMs = 0

        init() {}

        /// candidateFrom = the frame where playback started while the speaker is talking (barge-in candidate mode); pass nil on headphones / Bluetooth or when nothing is playing.
        mutating func step(frame: Int, db rawDb: Double, candidateFrom: Int? = nil) -> VadEvent? {
            let db = VoiceConversationLogic.clampFrameDb(rawDb)
            let candidate = candidateFrom.map { frame >= $0 } ?? false
            if candidate, let start = candidateFrom, frame < start + Constants.bargeInGraceMs / Constants.frameMs {
                if !speaking { runFrames = 0 }
                return nil
            }
            if !speaking {
                guard db >= floorDb + Constants.vadStartOverFloorDb && db >= Constants.vadAbsoluteMinDb else {
                    runFrames = 0
                    updateFloor(db)
                    return nil
                }
                if runFrames == 0 { runStart = frame }
                runFrames += 1
                let needMs = candidate ? Constants.bargeInMinSpeechMs : Constants.vadStartMs
                guard runFrames >= needMs / Constants.frameMs else { return nil }
                speaking = true
                voicedMs = runFrames * Constants.frameMs
                silenceFrames = 0
                runFrames = 0
                return .speechStart(frame: runStart, prerollFrame: max(0, runStart - Constants.vadPrerollMs / Constants.frameMs))
            }
            if db >= floorDb + Constants.vadContinueOverFloorDb {
                voicedMs += Constants.frameMs
                silenceFrames = 0
                return nil
            }
            silenceFrames += 1
            updateFloor(db)
            guard silenceFrames >= Constants.vadEndSilenceMs / Constants.frameMs else { return nil }
            return finish(frame: frame)
        }

        /// "I'm done talking": while speaking, ends immediately with the accumulated total; does nothing otherwise.
        mutating func forceEnd(frame: Int) -> VadEvent? {
            guard speaking else { return nil }
            return finish(frame: frame)
        }

        /// Drops the segment in progress (when muted or capture is paused); the noise floor is kept.
        mutating func reset() {
            speaking = false
            runFrames = 0
            silenceFrames = 0
            voicedMs = 0
        }

        private mutating func finish(frame: Int) -> VadEvent {
            let total = voicedMs
            reset()
            return total >= Constants.vadMinUtteranceMs ? .speechEnd(frame: frame, voicedMs: total) : .discarded(frame: frame)
        }

        private mutating func updateFloor(_ db: Double) {
            let next = floorDb + Constants.floorAlpha * (db - floorDb)
            floorDb = min(max(next, Constants.floorClampDb.lowerBound), Constants.floorClampDb.upperBound)
        }
    }

    /// Frame levels are clamped to frameDbClampDb first; NaN and -infinity count as the lower bound.
    static func clampFrameDb(_ db: Double) -> Double {
        guard !db.isNaN else { return Constants.frameDbClampDb.lowerBound }
        return min(max(db, Constants.frameDbClampDb.lowerBound), Constants.frameDbClampDb.upperBound)
    }

    /// Runs VAD over a whole frame sequence (the fixture's vad group); a segment still open at the end emits no event.
    static func runVad(frames: [Double], route: Route = .speaker, playbackStartFrame: Int? = nil) -> [VadEvent] {
        var vad = Vad()
        let candidateFrom = route.isSpeaker ? playbackStartFrame : nil
        var events: [VadEvent] = []
        for (index, db) in frames.enumerated() {
            if let event = vad.step(frame: index, db: db, candidateFrom: candidateFrom) { events.append(event) }
        }
        return events
    }

    // MARK: - B. Self-echo detection

    struct EchoResult: Equatable, Sendable {
        let echo: Bool
        /// Four decimal places; nil when the transcript has no units.
        let overlap: Double?
    }

    /// NFKC, then lowercase, then walk code points: separators (P / S / Z / Cc / Cf / variation selectors) split and are dropped;
    /// each Han / kana / Hangul code point is one unit; any other longest run is one unit.
    static func units(_ text: String) -> [String] {
        var result: [String] = []
        var run = String.UnicodeScalarView()
        func flush() {
            if !run.isEmpty { result.append(String(run)) }
            run = String.UnicodeScalarView()
        }
        for scalar in text.precomposedStringWithCompatibilityMapping.lowercased().unicodeScalars {
            if isSeparator(scalar) {
                flush()
            } else if isSingleUnit(scalar) {
                flush()
                result.append(String(scalar))
            } else {
                run.append(scalar)
            }
        }
        flush()
        return result
    }

    /// sentences = the previous sentence and the one now playing (whichever exist); their units are merged into one multiset.
    static func isEcho(transcript: String, sentences: [String]) -> EchoResult {
        let heard = units(transcript)
        guard !heard.isEmpty else { return EchoResult(echo: true, overlap: nil) }
        var pool: [String: Int] = [:]
        for unit in sentences.flatMap(units) { pool[unit, default: 0] += 1 }
        var hits = 0
        for unit in heard {
            if let count = pool[unit], count > 0 {
                pool[unit] = count - 1
                hits += 1
            }
        }
        let ratio = Double(hits) / Double(heard.count)
        return EchoResult(echo: ratio >= Constants.echoOverlapRatio, overlap: (ratio * 10000).rounded() / 10000)
    }

    private static func isSeparator(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0xFE00...0xFE0F, 0xE0100...0xE01EF: return true
        default: break
        }
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol,
             .spaceSeparator, .lineSeparator, .paragraphSeparator,
             .control, .format:
            return true
        default:
            return false
        }
    }

    private static func isSingleUnit(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x11FF, 0x2E80...0x2FDF, 0x3005, 0x3007, 0x3021...0x3029, 0x3038...0x303B,
             0x3040...0x30FF, 0x3130...0x318F, 0x31F0...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA960...0xA97F, 0xAC00...0xD7FF, 0xF900...0xFAFF, 0xFF66...0xFF9F, 0xFFA0...0xFFDC,
             0x1B000...0x1B16F, 0x20000...0x3FFFF:
            return true
        default:
            return false
        }
    }

    // MARK: - C. State machine

    enum Phase: String, Equatable, Sendable {
        case idle, listening, thinking, speaking, ended
    }

    /// Output route: only speaker vs. not matters (headphones and Bluetooth share one rule set).
    enum Route: String, Equatable, Sendable {
        case speaker, headphones, bluetooth

        var isSpeaker: Bool { self == .speaker }

        /// Fixture convention: anything unrecognized counts as speaker.
        init(wire: String) { self = Route(rawValue: wire) ?? .speaker }
    }

    enum Prompt: String, Equatable, Sendable {
        case didNotCatch
        case approvalNeeded
    }

    enum Earcon: String, Equatable, Sendable {
        case thinking
        case end
    }

    enum EndReason: String, Equatable, Sendable {
        /// The user tapped close.
        case user
        /// The host ended it (conversation switch, navigating back, etc.).
        case system
        case idle
        case error
        /// The system advised against resuming after an audio interruption (phone call, Siri, etc.).
        case interruption

        /// Reason for an end event: anything other than user is system.
        init(endEvent wire: String) { self = wire == "user" ? .user : .system }
    }

    enum ResumePoint: String, Equatable, Sendable {
        case pausePoint
        case sentenceStart
    }

    enum Event: Equatable, Sendable {
        case start(route: Route, deviceRemembersNoSpeakerBargeIn: Bool)
        case vadSpeechStart
        case vadSpeechEnd(utteranceId: String)
        case vadDiscarded
        case bargeInDetected
        case sttResult(utteranceId: String, text: String)
        case sttFailed(utteranceId: String)
        case replySentence(text: String)
        /// Host: a queued sentence started playing (feeds echo detection).
        case sentenceStarted(text: String)
        case replyCompleted
        case playbackDrained
        case replyFailed(code: String)
        case approvalPending
        case approvalResolved
        case tapOrb
        case toggleMute
        /// The one-shot timer the host scheduled from nextDeadlineMs fired (does not refresh lastActivityMs).
        case deadline
        case interruptionBegan
        case interruptionEnded
        case screenReaderSpeaking(Bool)
        case routeChanged(route: Route)
        case playMessage(messageId: String)
        case messagePlaybackEnded
        case end(reason: EndReason)
    }

    enum Effect: Equatable, Sendable {
        case startCapture
        case pauseCapture
        case resumeCapture
        case setCaptureMuted(Bool)
        case transcribe(utteranceId: String)
        case transcribeToDraft
        case sendMessage(text: String)
        case cancelGeneration
        case pausePlayback
        case resumePlayback(from: ResumePoint)
        case stopPlayback
        case enqueueSpeech(text: String)
        case speakPrompt(Prompt)
        case earcon(Earcon)
        case forceEndUtterance
        case rememberFalseBargeInConversation
        case playMessage(messageId: String)
        case endConversation(reason: EndReason, code: String?)
    }

    enum ReplyStatus: String, Equatable, Sendable {
        case none, streaming, completed
    }

    struct State: Equatable, Sendable {
        var phase: Phase = .idle
        var route: Route = .speaker
        var deviceRemembersNoSpeakerBargeIn = false
        var userSpeaking = false
        var muted = false
        var awaitingApproval = false
        var error = false
        var errorCode: String?
        var interrupted = false
        var screenReaderSpeaking = false
        var messagePlaying = false
        /// Whether voice barge-in works on the speaker in this conversation (always true on headphones / Bluetooth).
        var speakerBargeIn = false
        var falseBargeIns = 0
        /// Playback was stopped this turn (orb tap / headphones unplugged / after a call); text keeps generating but later sentences are not queued.
        var playbackStopped = false
        var sttAttempts = 0
        var awaitedUtteranceId: String?
        /// A barge-in candidate: voice was detected while the assistant was speaking.
        var bargeIn = false
        var reply: ReplyStatus = .none
        var drained = false
        var thinkingSinceMs: Int?
        var thinkingEarconPlayed = false
        var previousSentence: String?
        var currentSentence: String?
        var lastActivityMs: Int?

        init() {}
    }

    static func initialState() -> State { State() }

    enum DisplayState: String, Equatable, Sendable {
        case listening, thinking, speaking, muted, awaitingApproval, error
    }

    /// Status text key: speakingTapToInterrupt ("Speaking - tap to interrupt") when speaking on the speaker with voice barge-in off.
    enum StatusKey: String, Equatable, Sendable {
        case listening, thinking, speaking, speakingTapToInterrupt, muted, awaitingApproval, error
    }

    /// Display state (the only thing the UI reads): error > idle / ended is nil > awaitingApproval > muted && listening > phase.
    static func displayState(_ state: State) -> DisplayState? {
        if state.error { return .error }
        switch state.phase {
        case .idle, .ended: return nil
        default: break
        }
        if state.awaitingApproval { return .awaitingApproval }
        if state.muted && state.phase == .listening { return .muted }
        switch state.phase {
        case .listening: return .listening
        case .thinking: return .thinking
        case .speaking: return .speaking
        case .idle, .ended: return nil
        }
    }

    static func statusKey(_ state: State) -> StatusKey? {
        guard let display = displayState(state) else { return nil }
        switch display {
        case .listening: return .listening
        case .thinking: return .thinking
        case .speaking: return state.route.isSpeaker && !state.speakerBargeIn ? .speakingTapToInterrupt : .speaking
        case .muted: return .muted
        case .awaitingApproval: return .awaitingApproval
        case .error: return .error
        }
    }

    private static func recomputeSpeakerBargeIn(_ state: inout State) {
        state.speakerBargeIn = !state.route.isSpeaker
            || !(state.deviceRemembersNoSpeakerBargeIn || state.falseBargeIns >= Constants.falseBargeInsPerConversation)
    }

    private static func turnReset(_ state: inout State) {
        state.userSpeaking = false
        state.playbackStopped = false
        state.sttAttempts = 0
        state.awaitedUtteranceId = nil
        state.bargeIn = false
        state.reply = .none
        state.drained = false
        state.thinkingSinceMs = nil
        state.thinkingEarconPlayed = false
        state.previousSentence = nil
        state.currentSentence = nil
    }

    private static func enterListening(_ state: inout State, atMs: Int) {
        turnReset(&state)
        state.phase = .listening
        state.lastActivityMs = atMs
    }

    private static func enterThinking(_ state: inout State, atMs: Int) {
        turnReset(&state)
        state.phase = .thinking
        state.thinkingSinceMs = atMs
    }

    private static func finishCheck(_ state: inout State, atMs: Int) {
        if state.phase == .speaking && state.reply == .completed && (state.drained || state.playbackStopped) && !state.bargeIn {
            enterListening(&state, atMs: atMs)
        }
    }

    private static func isVadEvent(_ event: Event) -> Bool {
        switch event {
        case .vadSpeechStart, .vadSpeechEnd, .vadDiscarded, .bargeInDetected: return true
        default: return false
        }
    }

    /// When VAD events are dropped (muted, call, screen reader, playing an old message, thinking; while speaking, barge-in off or a barge-in transcript already pending).
    /// The controller uses this to predict: a voice onset that would be dropped does not start recording.
    static func dropsVad(_ state: State) -> Bool {
        if state.muted || state.interrupted || state.screenReaderSpeaking || state.messagePlaying { return true }
        if state.phase == .thinking { return true }
        if state.phase == .speaking && (!state.speakerBargeIn || (state.bargeIn && state.awaitedUtteranceId != nil)) {
            return true
        }
        return false
    }

    private static func idleQuiet(_ s: State) -> Bool {
        !s.muted && !s.userSpeaking && !s.awaitingApproval && !s.interrupted && !s.screenReaderSpeaking && !s.messagePlaying
    }

    private static func earconPending(_ s: State) -> Bool {
        !s.thinkingEarconPlayed && !s.awaitingApproval && !s.interrupted
    }

    /// The host schedules a one-shot timer from this: the next atMs at which `.deadline` would change state, or nil.
    /// Recomputed after every reduce; when the value changes, cancel the old timer and reschedule. No periodic tick needed.
    static func nextDeadlineMs(_ state: State) -> Int? {
        if state.phase == .listening && idleQuiet(state), let last = state.lastActivityMs {
            return last + Constants.idleTimeoutMs
        }
        if state.phase == .thinking && earconPending(state), let since = state.thinkingSinceMs {
            return since + Constants.thinkingEarconMs
        }
        return nil
    }

    /// Pure function: leaves its input untouched and returns the new state plus the effects to run in order.
    static func reduce(_ current: State, _ event: Event, atMs: Int) -> (State, [Effect]) {
        var state = current
        switch state.phase {
        case .ended:
            return (current, [])
        case .idle:
            guard case .start(let route, let remembers) = event else { return (current, []) }
            state.phase = .listening
            state.route = route
            state.deviceRemembersNoSpeakerBargeIn = remembers
            recomputeSpeakerBargeIn(&state)
            state.lastActivityMs = atMs
            return (state, [.startCapture])
        default:
            break
        }
        if case .deadline = event {} else { state.lastActivityMs = atMs }
        if isVadEvent(event) && dropsVad(state) { return (state, []) }
        var effects: [Effect] = []

        switch event {
        case .start:
            break

        case .vadSpeechStart:
            state.userSpeaking = true

        case .vadSpeechEnd(let id):
            guard state.userSpeaking else { break }
            state.userSpeaking = false
            if state.phase == .listening {
                enterThinking(&state, atMs: atMs)
                state.awaitedUtteranceId = id
                state.sttAttempts = 1
                effects.append(.transcribe(utteranceId: id))
            } else if state.phase == .speaking && state.bargeIn {
                state.awaitedUtteranceId = id
                state.sttAttempts = 1
                effects.append(.transcribe(utteranceId: id))
            }

        case .vadDiscarded:
            guard state.userSpeaking else { break }
            state.userSpeaking = false
            if state.phase == .speaking && state.bargeIn {
                state.bargeIn = false
                if !state.playbackStopped { effects.append(.resumePlayback(from: .pausePoint)) }
                finishCheck(&state, atMs: atMs)
            }

        case .bargeInDetected:
            guard state.phase == .speaking, state.userSpeaking, !state.bargeIn else { break }
            state.bargeIn = true
            if !state.playbackStopped { effects.append(.pausePlayback) }

        case .sttResult(let id, let text):
            guard id == state.awaitedUtteranceId else { break }
            if state.bargeIn {
                let sentences = [state.previousSentence, state.currentSentence].compactMap { $0 }
                if isEcho(transcript: text, sentences: sentences).echo {
                    state.bargeIn = false
                    state.awaitedUtteranceId = nil
                    if !state.playbackStopped { effects.append(.resumePlayback(from: .sentenceStart)) }
                    if state.route.isSpeaker {
                        state.falseBargeIns += 1
                        if state.falseBargeIns == Constants.falseBargeInsPerConversation {
                            recomputeSpeakerBargeIn(&state)
                            effects.append(.rememberFalseBargeInConversation)
                        }
                    }
                    finishCheck(&state, atMs: atMs)
                } else {
                    effects.append(.cancelGeneration)
                    effects.append(.sendMessage(text: text))
                    enterThinking(&state, atMs: atMs)
                    state.reply = .streaming
                }
            } else if units(text).isEmpty {
                enterListening(&state, atMs: atMs)
            } else {
                effects.append(.sendMessage(text: text))
                state.reply = .streaming
                state.awaitedUtteranceId = nil
            }

        case .sttFailed(let id):
            guard id == state.awaitedUtteranceId else { break }
            if state.sttAttempts <= Constants.sttRetries {
                state.sttAttempts += 1
                effects.append(.transcribe(utteranceId: id))
            } else {
                if state.bargeIn { effects.append(.cancelGeneration) }
                effects.append(.speakPrompt(.didNotCatch))
                enterListening(&state, atMs: atMs)
            }

        case .replySentence(let text):
            guard state.reply == .streaming, state.phase == .thinking || state.phase == .speaking else { break }
            state.phase = .speaking
            if !state.playbackStopped {
                state.drained = false
                effects.append(.enqueueSpeech(text: text))
            }

        case .sentenceStarted(let text):
            guard state.phase == .speaking else { break }
            state.previousSentence = state.currentSentence
            state.currentSentence = text

        case .replyCompleted:
            guard state.reply == .streaming else { break }
            state.reply = .completed
            if state.phase == .thinking {
                enterListening(&state, atMs: atMs)
            } else {
                finishCheck(&state, atMs: atMs)
            }

        case .playbackDrained:
            guard state.phase == .speaking else { break }
            state.drained = true
            finishCheck(&state, atMs: atMs)

        case .replyFailed(let code):
            guard state.reply == .streaming else { break }
            state.error = true
            state.errorCode = code
            state.phase = .ended
            effects.append(.endConversation(reason: .error, code: code))

        case .approvalPending:
            guard !state.awaitingApproval else { break }
            state.awaitingApproval = true
            effects.append(.speakPrompt(.approvalNeeded))

        case .approvalResolved:
            state.awaitingApproval = false

        case .tapOrb:
            if state.awaitingApproval { break }
            if state.muted && state.phase == .listening {
                state.muted = false
                effects.append(.setCaptureMuted(false))
                break
            }
            switch state.phase {
            case .listening:
                if state.userSpeaking { effects.append(.forceEndUtterance) }
            case .thinking:
                guard atMs - (state.thinkingSinceMs ?? atMs) >= Constants.listenToThinkTapGuardMs else { break }
                effects.append(.cancelGeneration)
                enterListening(&state, atMs: atMs)
            case .speaking:
                guard !state.playbackStopped else { break }
                state.playbackStopped = true
                effects.append(.stopPlayback)
                finishCheck(&state, atMs: atMs)
            default:
                break
            }

        case .toggleMute:
            state.muted.toggle()
            if state.muted { state.userSpeaking = false }
            effects.append(.setCaptureMuted(state.muted))

        case .deadline:
            switch state.phase {
            case .listening:
                guard idleQuiet(state), atMs - (state.lastActivityMs ?? atMs) >= Constants.idleTimeoutMs
                else { break }
                state.phase = .ended
                effects.append(.earcon(.end))
                effects.append(.endConversation(reason: .idle, code: nil))
            case .thinking:
                guard earconPending(state), atMs - (state.thinkingSinceMs ?? atMs) >= Constants.thinkingEarconMs
                else { break }
                state.thinkingEarconPlayed = true
                effects.append(.earcon(.thinking))
            default:
                break
            }

        case .interruptionBegan:
            guard !state.interrupted else { break }
            state.interrupted = true
            state.userSpeaking = false
            if state.phase == .speaking && !state.playbackStopped { effects.append(.pausePlayback) }
            effects.append(.pauseCapture)

        case .interruptionEnded:
            guard state.interrupted else { break }
            state.interrupted = false
            if state.phase == .speaking && !state.playbackStopped {
                state.playbackStopped = true
                effects.append(.stopPlayback)
            }
            effects.append(.resumeCapture)
            finishCheck(&state, atMs: atMs)

        case .screenReaderSpeaking(let speaking):
            state.screenReaderSpeaking = speaking
            if speaking { state.userSpeaking = false }

        case .routeChanged(let route):
            let leftPrivate = !state.route.isSpeaker && route.isSpeaker
            state.route = route
            recomputeSpeakerBargeIn(&state)
            if leftPrivate && state.phase == .speaking && !state.playbackStopped {
                state.playbackStopped = true
                effects.append(.stopPlayback)
                finishCheck(&state, atMs: atMs)
            }

        case .playMessage(let id):
            guard state.phase == .listening, !state.interrupted, !state.messagePlaying else { break }
            state.messagePlaying = true
            state.userSpeaking = false
            effects.append(.pauseCapture)
            effects.append(.playMessage(messageId: id))

        case .messagePlaybackEnded:
            guard state.messagePlaying else { break }
            state.messagePlaying = false
            effects.append(.resumeCapture)

        case .end(let reason):
            if reason == .user && state.userSpeaking { effects.append(.transcribeToDraft) }
            state.phase = .ended
            effects.append(.endConversation(reason: reason, code: nil))
        }
        return (state, effects)
    }
}
