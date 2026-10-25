import Foundation

/// Pure reducer for native realtime conversations.
/// Contract: the shared realtime conversation fixtures (rules and cases are the source of truth).
nonisolated enum RealtimeConversationLogic {

    enum Constants {
        static let idleEndMs = 120_000
        static let thinkingEarconMs = 3_000
        static let lateUserTranscriptMs = 3_000
        static let muteSilenceMs = 1_000
    }

    // MARK: - Types

    enum Phase: String, Sendable, Equatable {
        case connecting, listening, thinking, speaking, ended
    }

    struct Turn: Sendable, Equatable {
        var userPending = false
        var userText = ""
        var assistantStarted = false
        /// A finished reply that is held until the late user final arrives.
        var assistantDone = false
        var assistantText = ""
        var heldMs = 0
        /// The pending utterance started while the reply was still in progress (belongs to the next turn).
        var userAfterReply = false
    }

    struct State: Sendable, Equatable {
        var phase: Phase = .connecting
        var muted = false
        /// The server expired the session while muted: the connection is dead; unmute reopens it with text history (E-200).
        var dormant = false
        /// Reopened once after an expiry with no conversation progress yet: another expiry ends with an error (E-203).
        var reopenAwaitingProgress = false
        /// The screen reader is announcing: the uplink pauses without touching mute;
        /// uplink on = not muted and not announcing (mute wins).
        var screenReaderSpeaking = false
        var userSpeaking = false
        var drainPending = false
        var turn = Turn()
        var idleMs = 0
        var thinkingMs = 0
        var earconDone = false
        /// The reply was already written on barge-in; its assistantTurnDone writes nothing.
        var skipNextTurnDone = false
    }

    enum Input: Sendable, Equatable {
        case event(RealtimeSessionEvent)
        case mute
        case unmute
        case tapOrb
        case playbackDrained
        case tick(ms: Int)
        case end
        case systemInterruption
        /// Sent by the host when the session stream throws or the connection drops unexpectedly.
        case failed(code: String)
        /// Sent by the host when a Gemini Live session ends with `GeminiLiveTransportError.sessionExpired`.
        case sessionExpired
        /// Sent by the host when the screen reader starts / finishes announcing the status word.
        case screenReaderSpeaking(Bool)
        /// Sent by the host when a turn-boundary replan (off the main thread, currentSessionId = the open session)
        /// yields a fingerprint different from the open session's (realtime-session.v1).
        case planChanged
    }

    enum Role: String, Sendable, Equatable {
        case user, assistant
    }

    enum EndReason: String, Sendable, Equatable {
        case user, system, error, idle
    }

    enum Effect: Sendable, Equatable {
        case persist(role: Role, text: String)
        case interruptPlayback
        case sendSilence(ms: Int)
        case setUplink(on: Bool)
        case earcon
        case showError(code: String)
        case writeDraft(text: String)
        case close
        case ended(reason: EndReason)
        /// Open a new session (history includes persisted transcripts); the new connection's ready ends connecting.
        case reopen
    }

    static let initialState = State()

    /// Voice bar status key; nil once the conversation has ended.
    static func statusKey(_ state: State) -> String? {
        switch state.phase {
        case .ended: nil
        case .connecting: "thinking"
        case .listening: state.muted ? "muted" : "listening"
        case .thinking, .speaking: state.phase.rawValue
        }
    }

    /// Milliseconds until the next tick can change the state (the host arms one one-shot timer, no periodic tick);
    /// nil once ended or when no wait applies.
    static func nextTickMs(_ state: State) -> Int? {
        guard state.phase != .ended else { return nil }
        var waits: [Int] = []
        if state.turn.assistantDone && state.turn.userPending {
            waits.append(Constants.lateUserTranscriptMs - state.turn.heldMs)
        }
        if state.phase == .thinking && !state.earconDone {
            waits.append(Constants.thinkingEarconMs - state.thinkingMs)
        }
        if state.phase == .listening && !state.muted && !state.userSpeaking {
            waits.append(Constants.idleEndMs - state.idleMs)
        }
        return waits.min().map { max(0, $0) }
    }

    // MARK: - Reducer

    static func reduce(_ state: State, _ input: Input) -> (State, [Effect]) {
        guard state.phase != .ended else { return (state, []) }
        var s = state
        var effects: [Effect] = []
        if case let .tick(ms) = input {
            tick(&s, ms: ms, &effects)
            return (s, effects)
        }
        s.idleMs = 0
        switch input {
        case .tick:
            break
        case let .event(event):
            // Conversation progress clears the reopen guard; ready does not count.
            if isProgress(event) { s.reopenAwaitingProgress = false }
            apply(event, &s, &effects)
        case .mute:
            guard !s.muted else { break }
            s.muted = true
            if s.userSpeaking { effects.append(.sendSilence(ms: Constants.muteSilenceMs)) }
            effects.append(.setUplink(on: false))
        case .unmute:
            guard s.muted else { break }
            s.muted = false
            if s.dormant {
                // Reopen first, then turn the uplink on; statusKey is thinking until the new connection is ready.
                s.dormant = false
                s.reopenAwaitingProgress = true
                s.phase = .connecting
                effects.append(.reopen)
            }
            // The screen reader is still announcing: the uplink opens when it finishes.
            if !s.screenReaderSpeaking { effects.append(.setUplink(on: true)) }
        case let .screenReaderSpeaking(speaking):
            guard s.screenReaderSpeaking != speaking else { break }
            s.screenReaderSpeaking = speaking
            // While muted the uplink is already off; announcement start / end leave it alone.
            if !s.muted { effects.append(.setUplink(on: !speaking)) }
        case .tapOrb:
            guard s.phase == .speaking else { break }
            effects.append(.interruptPlayback)
            s.phase = .listening
            s.drainPending = false
        case .playbackDrained:
            guard s.phase == .speaking, s.drainPending else { break }
            s.phase = .listening
            s.drainPending = false
        case .end:
            finish(&s, reason: .user, &effects)
        case .systemInterruption:
            finish(&s, reason: .system, &effects)
        case let .failed(code):
            effects.append(.showError(code: code))
            finish(&s, reason: .error, &effects)
        case .planChanged:
            // Only an idle listening session reopens; mid-turn or dormant it is ignored and the host compares
            // again at the next turn boundary.
            guard !s.dormant, s.phase == .listening, !s.userSpeaking,
                  !s.turn.userPending, !s.turn.assistantStarted else { break }
            s.phase = .connecting
            s.drainPending = false
            s.turn = Turn()
            effects.append(.reopen)
        case .sessionExpired:
            guard !s.dormant else { break }
            if s.muted {
                // Expired while muted: keep the call, release a held reply, then sleep until unmute.
                if s.turn.assistantDone { releaseHeld(&s, &effects, keepUser: false) }
                s.dormant = true
                s.phase = .listening
                s.userSpeaking = false
                s.drainPending = false
                s.turn = Turn()
                break
            }
            if !s.reopenAwaitingProgress {
                // Expired while unmuted: reopen once with text history; the uplink gate is unchanged and
                // statusKey is thinking until the new connection is ready (E-203).
                if s.turn.assistantDone { releaseHeld(&s, &effects, keepUser: false) }
                s.reopenAwaitingProgress = true
                s.phase = .connecting
                s.userSpeaking = false
                s.drainPending = false
                s.turn = Turn()
                effects.append(.reopen)
                break
            }
            // Expired again after a reopen without progress: end with an error.
            effects.append(.showError(code: "sessionExpired"))
            finish(&s, reason: .error, &effects)
        }
        return (s, effects)
    }

    private static func apply(_ event: RealtimeSessionEvent, _ s: inout State, _ effects: inout [Effect]) {
        switch event {
        case .ready:
            if s.phase == .connecting { s.phase = .listening }
        case .userSpeechStarted:
            if s.phase == .speaking { effects.append(.interruptPlayback) }
            if s.turn.assistantDone { releaseHeld(&s, &effects, keepUser: false) }
            if s.turn.assistantStarted && !s.turn.assistantDone { s.turn.userAfterReply = true }
            s.phase = .listening
            s.drainPending = false
            s.userSpeaking = true
            s.turn.userPending = true
            s.thinkingMs = 0
            s.earconDone = false
        case .userSpeechStopped:
            s.phase = .thinking
            s.drainPending = false
            s.userSpeaking = false
            s.thinkingMs = 0
        case let .userTranscript(_, text, final):
            s.turn.userText = text
            guard final else {
                s.turn.userPending = true
                return
            }
            s.turn.userPending = false
            if s.turn.userAfterReply && s.turn.assistantStarted && !s.turn.assistantDone {
                // Barge-in: the interrupted reply goes first with its current transcript.
                persist(.assistant, s.turn.assistantText, &effects)
                persist(.user, text, &effects)
                s.turn = Turn()
                s.skipNextTurnDone = true
            } else {
                persist(.user, text, &effects)
                if s.turn.assistantDone { releaseHeld(&s, &effects, keepUser: false) }
            }
        case .assistantAudio:
            s.phase = .speaking
            s.turn.assistantStarted = true
        case let .assistantTranscript(_, text, _):
            s.turn.assistantText = text
            s.turn.assistantStarted = true
        case .interrupted:
            s.phase = .listening
            s.drainPending = false
        case let .assistantTurnDone(_, _, text):
            if s.phase == .speaking { s.drainPending = true } else { s.phase = .listening }
            if s.skipNextTurnDone {
                s.skipNextTurnDone = false
                return
            }
            // A blank text (the unified event has no null) falls back to the latest transcript.
            let reply = trimmed(text).isEmpty ? s.turn.assistantText : text
            if s.turn.userPending && !s.turn.userAfterReply {
                if trimmed(reply).isEmpty {
                    clearReply(&s)
                } else {
                    s.turn.assistantDone = true
                    s.turn.assistantText = reply
                    s.turn.heldMs = 0
                }
            } else {
                persist(.assistant, reply, &effects)
                clearTurnAfterReply(&s)
            }
        case .goAway, .resumable, .error:
            break
        case .sessionEnded:
            finish(&s, reason: .system, &effects)
        }
    }

    private static func tick(_ s: inout State, ms: Int, _ effects: inout [Effect]) {
        // ms <= 0 changes no counter (fixture rt_tick_zero_or_negative_ms_noop).
        guard ms > 0 else { return }
        if s.turn.assistantDone {
            s.turn.heldMs += ms
            if s.turn.heldMs >= Constants.lateUserTranscriptMs { releaseHeld(&s, &effects, keepUser: true) }
        }
        if s.phase == .thinking {
            s.thinkingMs += ms
            if !s.earconDone && s.thinkingMs >= Constants.thinkingEarconMs {
                s.earconDone = true
                effects.append(.earcon)
            }
        }
        if s.phase == .listening && !s.muted && !s.userSpeaking {
            s.idleMs += ms
            if s.idleMs >= Constants.idleEndMs { finish(&s, reason: .idle, &effects) }
        }
    }

    /// End sequence: held reply, draft (user end only), close, ended.
    private static func finish(_ s: inout State, reason: EndReason, _ effects: inout [Effect]) {
        if s.turn.assistantDone { persist(.assistant, s.turn.assistantText, &effects) }
        if reason == .user && s.turn.userPending && !isEchoEmpty(s.turn.userText) {
            effects.append(.writeDraft(text: trimmed(s.turn.userText)))
        }
        effects.append(.close)
        effects.append(.ended(reason: reason))
        s.phase = .ended
        s.turn = Turn()
        s.drainPending = false
        s.userSpeaking = false
    }

    // MARK: - Helpers

    private static func isProgress(_ event: RealtimeSessionEvent) -> Bool {
        switch event {
        case .userTranscript, .assistantAudio, .assistantTranscript, .assistantTurnDone: true
        default: false
        }
    }

    private static func releaseHeld(_ s: inout State, _ effects: inout [Effect], keepUser: Bool) {
        persist(.assistant, s.turn.assistantText, &effects)
        if keepUser { clearReply(&s) } else { s.turn = Turn() }
    }

    /// After a reply is written the turn is cleared, except a userAfterReply utterance carries over.
    private static func clearTurnAfterReply(_ s: inout State) {
        let carry = s.turn.userAfterReply
        let pending = s.turn.userPending
        let text = s.turn.userText
        s.turn = Turn()
        if carry {
            s.turn.userPending = pending
            s.turn.userText = text
        }
    }

    private static func clearReply(_ s: inout State) {
        s.turn.assistantStarted = false
        s.turn.assistantDone = false
        s.turn.assistantText = ""
        s.turn.heldMs = 0
    }

    /// User text needs echo units; assistant text only needs to be non-blank.
    private static func persist(_ role: Role, _ text: String, _ effects: inout [Effect]) {
        let value = trimmed(text)
        switch role {
        case .user: guard !isEchoEmpty(text) else { return }
        case .assistant: guard !value.isEmpty else { return }
        }
        effects.append(.persist(role: role, text: value))
    }

    /// Blank or punctuation / separators only (same separator set as voice-conversation isEcho).
    private static func isEchoEmpty(_ text: String) -> Bool {
        VoiceConversationLogic.units(text).isEmpty
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
