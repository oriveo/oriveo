import Foundation

/// Pure reducer for native realtime conversations.
/// The shared realtime conversation fixtures (rules and cases are the source of truth).
nonisolated enum RealtimeConversationLogic {

    enum Constants {
        static let idleEndMs = 120_000
        static let thinkingEarconMs = 3_000
        static let lateUserTranscriptMs = 3_000
        static let muteSilenceMs = 1_000
        /// Speaker false barge-ins (the local uplink gate opened on voice, then the user final was empty or an echo
        /// of the reply) reaching this count turn off voice barge-in during playback for the rest of the session.
        static let falseBargeInsPerSession = 2
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
        /// The reply is fully generated (assistantTurnDone arrived while speaking) but not fully played: it is persisted only after playback finishes.
        var awaitingDrain = false
        /// Played ms frozen at barge-in or end (nil = not frozen); later text is still revealed against it, and persistence uses it.
        var frozenPlayedMs: Int?
        /// Sample count and sample rate of the audio received this turn (PCM16 mono).
        var audioSamples = 0
        var sampleRateHz = 0
        /// itemId → played ms (host playbackProgress; a nil itemId is recorded as "").
        var played: [String: Int] = [:]
        /// itemIds that received audio this turn: progress is only accepted for these.
        var audioItems: [String] = []
    }

    struct State: Sendable, Equatable {
        var phase: Phase = .connecting
        var muted = false
        /// The server expired the session while muted: the connection is dead; unmute reopens it with text history.
        var dormant = false
        /// Reopened once after an expiry with no conversation progress yet: another expiry ends with an error.
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
        /// The reply was already written on barge-in; its assistantTurnDone writes nothing (mjs replyFlushed).
        var skipNextTurnDone = false
        /// Echo pool the next final user transcript is compared against after the speaker uplink gate opened on
        /// voice during playback / the post-playback guard; nil = nothing to judge.
        var echoPool: [String]?
        /// The latest persisted reply: when the gate opens in the guard window the turn is already cleared.
        var lastReply = ""
        var falseBargeIns = 0
        var bargeInOff = false
    }

    enum Input: Sendable, Equatable {
        case event(RealtimeSessionEvent)
        case mute
        case unmute
        /// Sent by the host when the user types while dormant: reopens the connection without touching mute.
        case wake
        case tapOrb
        case playbackDrained
        /// The host player reports played ms for an item (cumulative, never decreases, rounded down).
        case playbackProgress(itemId: String?, playedMs: Int)
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
        /// Sent by the host when the speaker uplink gate (RealtimeUplinkGate) opened because of local voice.
        case gateOpened
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
        /// Stop opening the speaker uplink gate on voice during playback (tap to interrupt only).
        case disableBargeIn
    }

    static let initialState = State()

    /// Voice bar status key; nil once the conversation has ended.
    static func statusKey(_ state: State) -> String? {
        switch state.phase {
        case .ended: nil
        case .connecting: "thinking"
        case .listening: state.muted ? "muted" : "listening"
        // After enough speaker false barge-ins only a tap interrupts: same key as the cascade statusKey.
        case .speaking: state.bargeInOff ? "speakingTapToInterrupt" : "speaking"
        case .thinking: state.phase.rawValue
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

    // MARK: - Reveal

    /// The 6 realtime failure categories (realtime-model.v1 failureCases): showError.code only takes these values.
    static let failureCategories: Set<String> = ["auth", "quota", "model_gone", "max_duration", "network", "unknown"]
    private static let sessionEndLimitReasons: Set<String> = ["max_duration", "timeout"]

    /// The whitespace set is fixed to ECMAScript \s (including NBSP and BOM).
    private static let whitespace: Set<Unicode.Scalar> = Set(
        ([0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006,
         0x2007, 0x2008, 0x2009, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF] as [UInt32])
            .compactMap { Unicode.Scalar($0) }
    )

    /// Text without space-delimited words (CJK, kana, hangul, Thai, Lao, Khmer, Burmese, fullwidth): split per character.
    private static let unspacedRanges: [ClosedRange<UInt32>] = [
        0x0E00...0x0EFF, 0x1000...0x109F, 0x1100...0x11FF, 0x1780...0x17FF, 0x2E80...0x2FDF, 0x3000...0x303F,
        0x3040...0x30FF, 0x3100...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA960...0xA97F, 0xAC00...0xD7FF,
        0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x2FA1F,
    ]

    private static func isSpace(_ c: Unicode.Scalar) -> Bool { whitespace.contains(c) }

    private static func isUnspaced(_ c: Unicode.Scalar) -> Bool {
        unspacedRanges.contains { $0.contains(c.value) }
    }

    /// Combining marks (\p{M}) or ZWJ: do not split before them.
    private static func isJoiner(_ c: Unicode.Scalar) -> Bool {
        if c.value == 0x200D { return true }
        switch c.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    private static func trimWs(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var i = scalars.startIndex
        var j = scalars.endIndex
        while i < j && isSpace(scalars[i]) { i += 1 }
        while j > i && isSpace(scalars[j - 1]) { j -= 1 }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[i..<j])
        return String(view)
    }

    /// Trim leading and trailing whitespace (same table as ECMAScript String.prototype.trim).
    static func trimmed(_ text: String) -> String {
        trimWs(Array(text.unicodeScalars)[...])
    }

    /// The first ⌊n × playedMs × rate ÷ (samples × 1000)⌋ code points of the received text, snapped back to a boundary; fully played received audio gives the full text, no audio gives an empty string.
    /// Mirrors scripts/lib/realtime-conversation.mjs:revealPrefix.
    static func revealPrefix(text: String, playedMs: Int, audioSamples: Int, sampleRateHz: Int) -> String {
        let cps = Array(text.unicodeScalars)
        let n = Int64(cps.count)
        let samples = Int64(audioSamples)
        let rate = Int64(sampleRateHz)
        let played = Int64(max(0, playedMs))
        guard n > 0, samples > 0, rate > 0 else { return "" }
        if played >= samples * 1000 / rate { return trimWs(cps[...]) }
        var k = Int(min(n, n * played * rate / (samples * 1000)))
        if k >= cps.count { return trimWs(cps[...]) }
        while k > 0 && isJoiner(cps[k]) { k -= 1 }
        func boundary(_ i: Int) -> Bool {
            i == 0 || isSpace(cps[i - 1]) || isSpace(cps[i]) || isUnspaced(cps[i - 1]) || isUnspaced(cps[i])
        }
        while k > 0 && !boundary(k) { k -= 1 }
        return trimWs(cps[0..<k])
    }

    private static func playedTotal(_ t: Turn) -> Int { t.played.values.reduce(0, +) }

    private static func revealAt(_ t: Turn, _ playedMs: Int) -> String {
        revealPrefix(text: t.assistantText, playedMs: playedMs, audioSamples: t.audioSamples, sampleRateHz: t.sampleRateHz)
    }

    /// Text shown in the current reply bubble: after freezing, by the frozen played ms; held while waiting for the user transcript, or with no audio this turn while waiting to finish = full text; otherwise by the played ratio.
    static func assistantShown(_ state: State) -> String {
        let t = state.turn
        if let frozen = t.frozenPlayedMs { return revealAt(t, frozen) }
        if t.assistantDone || (t.awaitingDrain && t.audioSamples == 0) { return trimmed(t.assistantText) }
        return revealAt(t, playedTotal(t))
    }

    /// The user's-words bubble: shown only when this turn's user speech is not final and has meaningful text; nil = no slot.
    static func userCaption(_ state: State) -> String? {
        let t = state.turn
        return t.userPending && !isEchoEmpty(t.userText) ? trimmed(t.userText) : nil
    }

    /// The realtime stage line.
    enum StageLine: Sendable, Equatable {
        case user(String)
        case assistant(String)
        case status(key: String)
        /// One-shot host notice for the stage (engine switched to <model>); the reducer does not produce it.
        case notice(String)
    }

    /// nil once ended; shows the user's caption when the user's speech has text; shows the revealed text while the AI is speaking and text has been revealed; otherwise the status string (statusKey).
    static func stageLine(_ state: State) -> StageLine? {
        guard state.phase != .ended, let key = statusKey(state) else { return nil }
        if let user = userCaption(state) { return .user(user) }
        let shown = assistantShown(state)
        if state.phase == .speaking && !shown.isEmpty { return .assistant(shown) }
        return .status(key: key)
    }

    /// Byte count after base64 decoding (no decoding is done).
    private static func base64Bytes(_ b64: String) -> Int {
        let chars = b64.unicodeScalars.filter { !isSpace($0) }
        guard !chars.isEmpty else { return 0 }
        let pad = chars.suffix(2).map { $0 == "=" } == [true, true] ? 2 : (chars.last == "=" ? 1 : 0)
        return chars.count * 3 / 4 - pad
    }

    // MARK: - Reducer

    /// Mirrors scripts/lib/realtime-conversation.mjs:reduce.
    static func reduce(_ state: State, _ input: Input) -> (State, [Effect]) {
        guard state.phase != .ended else { return (state, []) }
        var s = state
        var effects: [Effect] = []
        if case let .tick(ms) = input {
            tick(&s, ms: ms, &effects)
            return (s, effects)
        }
        if case let .playbackProgress(itemId, playedMs) = input {
            // Only while speaking, and only for items that received audio this turn; ignored after freezing; not counted as user or session activity.
            let key = itemId ?? ""
            guard playedMs >= 0, s.turn.frozenPlayedMs == nil, s.phase == .speaking,
                  s.turn.audioItems.contains(key) else { return (s, effects) }
            s.turn.played[key] = max(s.turn.played[key] ?? 0, playedMs)
            return (s, effects)
        }
        s.idleMs = 0
        switch input {
        case .tick, .playbackProgress:
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
        case .wake:
            // Typed while dormant: reopen like unmute, but mute and the uplink stay as they are.
            guard s.dormant else { break }
            s.dormant = false
            s.reopenAwaitingProgress = true
            s.phase = .connecting
            effects.append(.reopen)
        case let .screenReaderSpeaking(speaking):
            guard s.screenReaderSpeaking != speaking else { break }
            s.screenReaderSpeaking = speaking
            // While muted the uplink is already off; announcement start / end leave it alone.
            if !s.muted { effects.append(.setUplink(on: !speaking)) }
        case .tapOrb:
            guard s.phase == .speaking else { break }
            effects.append(.interruptPlayback)
            freezeReveal(&s)
            toListening(&s)
            releaseDrained(&s, &effects)
        case .playbackDrained:
            // A reply waiting to finish playing is released regardless of the current phase.
            if s.phase == .speaking && s.drainPending { toListening(&s) }
            releaseDrained(&s, &effects)
        case .end:
            finish(&s, reason: .user, &effects)
        case .systemInterruption:
            finish(&s, reason: .system, &effects)
        case let .failed(code):
            effects.append(.showError(code: failureCategories.contains(code) ? code : "unknown"))
            finish(&s, reason: .error, &effects)
        case .gateOpened:
            // The speaker uplink gate opened on voice: echo pool = the reply being played + the previous reply.
            guard !s.bargeInOff else { break }
            s.echoPool = [s.turn.assistantText, s.lastReply].map(trimmed).filter { !$0.isEmpty }
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
            // Check order follows realtime-model afterDrop: first check reopened without progress, then check mute;
            // otherwise an expiry while muted would keep sleeping / reopening, diverging from the end the host derives from afterDrop.
            if s.reopenAwaitingProgress {
                // Expired again after a reopen with no progress (muted or not): neither network nor quota, so it is categorized as unknown.
                effects.append(.showError(code: "unknown"))
                finish(&s, reason: .error, &effects)
                break
            }
            flushOnExpiry(&s, &effects)
            s.userSpeaking = false
            s.drainPending = false
            s.turn = Turn()
            if s.muted {
                // Expired while muted: keep the call, release a held reply, then sleep until unmute.
                s.dormant = true
                s.phase = .listening
                break
            }
            // Expired while unmuted: reopen once with text history; the uplink gate is unchanged and
            // StatusKey is thinking until the new connection is ready.
            s.reopenAwaitingProgress = true
            s.phase = .connecting
            effects.append(.reopen)
        }
        return (s, effects)
    }

    private static func apply(_ event: RealtimeSessionEvent, _ s: inout State, _ effects: inout [Effect]) {
        switch event {
        case .ready:
            if s.phase == .connecting { toListening(&s) }
        case .userSpeechStarted:
            if s.phase == .speaking {
                effects.append(.interruptPlayback)
                freezeReveal(&s)
            }
            // The transcript of a new user utterance starts empty.
            if !s.turn.userPending { s.turn.userText = "" }
            if s.turn.awaitingDrain {
                s.turn.awaitingDrain = false
                persistAssistant(&s, &effects)
            } else if s.turn.assistantDone {
                persistAssistant(&s, &effects)
            } else if s.turn.assistantStarted {
                s.turn.userAfterReply = true
            }
            toListening(&s)
            s.userSpeaking = true
            s.turn.userPending = true
            s.earconDone = false
            s.thinkingMs = 0
        case .userSpeechStopped:
            s.phase = .thinking
            s.userSpeaking = false
            s.thinkingMs = 0
        case let .userTranscript(_, text, final):
            s.turn.userText = text
            guard final else {
                s.turn.userPending = true
                return
            }
            s.turn.userPending = false
            if s.turn.userAfterReply && !s.turn.assistantDone {
                // Barge-in: the interrupted reply is frozen at what was played and goes first.
                freezeReveal(&s)
                let turnDoneArrived = s.turn.awaitingDrain
                s.turn.awaitingDrain = false
                persistAssistant(&s, &effects)
                if !turnDoneArrived { s.skipNextTurnDone = true }
            }
            persist(.user, text, &effects)
            if s.turn.assistantDone { persistAssistant(&s, &effects) }
            judgeEcho(text, &s, &effects)
        case let .assistantAudio(itemId, _, base64, sampleRateHz):
            s.phase = .speaking
            s.turn.assistantStarted = true
            if sampleRateHz > 0 {
                s.turn.audioSamples += base64Bytes(base64) / 2
                s.turn.sampleRateHz = sampleRateHz
                let key = itemId ?? ""
                if !s.turn.audioItems.contains(key) { s.turn.audioItems.append(key) }
            }
        case let .assistantTranscript(_, text, _):
            s.turn.assistantStarted = true
            s.turn.assistantText = text
        case .interrupted:
            freezeReveal(&s)
            toListening(&s)
            releaseDrained(&s, &effects)
        case let .assistantTurnDone(_, _, own):
            let speaking = s.phase == .speaking
            if speaking { s.drainPending = true } else { toListening(&s) }
            // A blank text (the unified event has no null) falls back to the latest transcript.
            let text = trimmed(own).isEmpty ? s.turn.assistantText : own
            if s.skipNextTurnDone {
                s.skipNextTurnDone = false
                return
            }
            s.turn.assistantText = text
            if speaking && s.turn.frozenPlayedMs == nil {
                // Still playing: persist only after playbackDrained (or after a barge-in / end freeze).
                s.turn.awaitingDrain = true
                return
            }
            holdOrPersist(&s, &effects)
        case .goAway, .resumable, .error:
            break
        case let .sessionEnded(reason):
            // The server ended the session at the per-session duration limit: routed as a max_duration-type failure.
            if sessionEndLimitReasons.contains(reason) {
                effects.append(.showError(code: "max_duration"))
                finish(&s, reason: .error, &effects)
            } else {
                finish(&s, reason: .system, &effects)
            }
        }
    }

    private static func tick(_ s: inout State, ms: Int, _ effects: inout [Effect]) {
        // ms <= 0 changes no counter (fixture rt_tick_zero_or_negative_ms_noop).
        guard ms > 0 else { return }
        if s.turn.assistantDone && s.turn.userPending {
            s.turn.heldMs += ms
            if s.turn.heldMs >= Constants.lateUserTranscriptMs { persistAssistant(&s, &effects) }
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

    /// End sequence: held / draining reply (what was heard), draft (user end only), close, ended.
    private static func finish(_ s: inout State, reason: EndReason, _ effects: inout [Effect]) {
        let draft = s.turn.userPending && !isEchoEmpty(s.turn.userText) ? trimmed(s.turn.userText) : nil
        if s.turn.awaitingDrain {
            freezeReveal(&s)
            s.turn.awaitingDrain = false
            s.turn.assistantDone = true
        }
        if s.turn.assistantDone { persistAssistant(&s, &effects) }
        if reason == .user, let draft { effects.append(.writeDraft(text: draft)) }
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

    private static func toListening(_ s: inout State) {
        s.phase = .listening
        s.drainPending = false
    }

    /// Barge-in / end: freezes the currently revealed prefix as this reply's persisted text (frozen once only).
    private static func freezeReveal(_ s: inout State) {
        if s.turn.assistantStarted && s.turn.frozenPlayedMs == nil { s.turn.frozenPlayedMs = playedTotal(s.turn) }
    }

    /// Before an expiry reopen / sleep: replies waiting to finish are frozen at the played amount; held or waiting replies are persisted.
    private static func flushOnExpiry(_ s: inout State, _ effects: inout [Effect]) {
        if s.turn.awaitingDrain { freezeReveal(&s) }
        if s.turn.assistantDone || s.turn.awaitingDrain { persistAssistant(&s, &effects) }
    }

    /// A fully generated reply waiting to finish playing is released now.
    private static func releaseDrained(_ s: inout State, _ effects: inout [Effect]) {
        guard s.turn.awaitingDrain else { return }
        s.turn.awaitingDrain = false
        holdOrPersist(&s, &effects)
    }

    /// While this turn's user speech is not final (and not a barge-in), a non-empty reply is held; an empty one only clears the reply half; otherwise it is persisted immediately.
    private static func holdOrPersist(_ s: inout State, _ effects: inout [Effect]) {
        guard s.turn.userPending && !s.turn.userAfterReply else {
            persistAssistant(&s, &effects)
            return
        }
        if !trimmed(shownForPersist(s.turn)).isEmpty {
            s.turn.assistantDone = true
            s.turn.heldMs = 0
        } else {
            let pending = s.turn.userPending
            let text = s.turn.userText
            s.turn = Turn()
            s.turn.userPending = pending
            s.turn.userText = text
        }
    }

    /// Persisted text = the revealed prefix (when frozen) or the full text.
    private static func shownForPersist(_ t: Turn) -> String {
        t.frozenPlayedMs.map { revealAt(t, $0) } ?? t.assistantText
    }

    /// Persists the reply (what was heard) and clears the turn; a userAfterReply utterance carries over.
    private static func persistAssistant(_ s: inout State, _ effects: inout [Effect]) {
        let text = trimmed(shownForPersist(s.turn))
        if !text.isEmpty {
            effects.append(.persist(role: .assistant, text: text))
            s.lastReply = text
        }
        let carry = s.turn.userAfterReply
        let pending = s.turn.userPending
        let userText = s.turn.userText
        s.turn = Turn()
        if carry {
            s.turn.userPending = pending
            s.turn.userText = userText
        }
    }

    /// Judged after the persist effects of a final user transcript: once the gate opened on voice, an empty final or
    /// an echo of the pool counts as a false barge-in; the count reaching the limit disables voice barge-in once.
    private static func judgeEcho(_ text: String, _ s: inout State, _ effects: inout [Effect]) {
        guard let pool = s.echoPool else { return }
        s.echoPool = nil
        guard isEchoEmpty(text) || VoiceConversationLogic.isEcho(transcript: text, pool: pool).echo else { return }
        s.falseBargeIns += 1
        if s.falseBargeIns >= Constants.falseBargeInsPerSession && !s.bargeInOff {
            s.bargeInOff = true
            effects.append(.disableBargeIn)
        }
    }

    /// User text needs echo units.
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
}
