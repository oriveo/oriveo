import Foundation

/// Streaming speaker uplink gate for native realtime conversations (F2: speaker self-excitation).
/// Contract: shared/voice-contracts/realtime-conversation.v1.json uplinkGateCases; reference
/// scripts/lib/realtime-conversation.mjs:uplinkGate.
///
/// Platform echo cancellation still leaves residue on the speaker route, and the server VAD takes it for the user
/// speaking. On the speaker route, from the playback start frame until postPlaybackGuardMs after playback ends,
/// uplink frames are held. Local voice (same thresholds as the cascade Vad: 1 s grace after playback start,
/// bargeInMinSpeechMs during playback, postPlaybackGuardMinSpeechMs in the guard window) opens the gate and flushes
/// the Vad preroll; reaching the guard end opens it and flushes the last vadPrerollMs. Held frames before the
/// flush start are dropped (no silence is sent in their place). After opening, frames pass until the next playback.
nonisolated struct RealtimeUplinkGate: Sendable, Equatable {

    private typealias Cascade = VoiceConversationLogic

    enum OpenReason: String, Sendable, Equatable {
        case speech, guardEnd
    }

    enum Output: Sendable, Equatable {
        /// Send this frame now.
        case send
        /// Hold this frame: it is either flushed by a later `open` or dropped.
        case hold
        /// Send the held frames from `flushFrom` up to and including this frame, in order; then pass frames through.
        case open(reason: OpenReason, flushFrom: Int)
    }

    private static let guardFrames = Cascade.Constants.postPlaybackGuardMs / Cascade.Constants.frameMs
    private static let prerollFrames = Cascade.Constants.vadPrerollMs / Cascade.Constants.frameMs

    // Echo-reference decision; names match the reference implementation's CONSTANTS
    static let echoRefWindowMs = 300
    static let echoRefDelayWindowMs = 1000
    static let echoRefMaxDelayMs = 500
    static let echoRefMinCorrelation = 0.6
    static let echoRefMinDelayCorrelation = 0.7
    static let echoRefBargeInMarginDb = 6.0
    static let echoRefFloorDb = -80.0

    // Onset backtrack, same as the echoRef branch of the reference uplinkGate
    private static let graceFrames = Cascade.Constants.bargeInGraceMs / Cascade.Constants.frameMs
    private static let backtrackFrames = Cascade.Constants.vadModelOnsetBacktrackMs / Cascade.Constants.frameMs
    /// Backtrack ring length, same as the reference implementation; the search lower bound is never earlier than i − (historyCapacity − 1)
    private static let historyCapacity = 256

    /// Fed with every frame, armed or not, so the noise floor stays current.
    private var vad = Cascade.Vad()
    /// The first frame's prob decides the mode for the whole gate (nil = no frame yet): model mode once it carried one.
    private var modelMode: Bool?
    /// Index of the next frame passed to `step`.
    private(set) var frame = 0
    private var route: Cascade.Route = .speaker
    private var playbackStart: Int?
    private var playbackEnd: Int?
    private var armed = false
    private var bargeIn = true
    /// Every frame's (db, ref) since the gate's first frame, for the echo reference check.
    private var echoReference = RealtimeEchoReference()
    /// Whether any frame so far carried a ref (the echo reference is in effect): enables the onset backtrack.
    private var echoRefSeen = false
    /// Recent frames' prob as fed to the Vad (after the echo check; nil stored as -1) and db, ring by frame index;
    /// preallocated so the audio thread does not allocate.
    private var recentProb = Array(repeating: -1.0, count: historyCapacity)
    private var recentDb = Array(repeating: echoRefFloorDb, count: historyCapacity)

    /// Per-cycle diagnostics for the one-line logs at open / playback end (E-708); never read by the decision.
    struct CycleStats: Sendable, Equatable {
        var startFrame = 0
        var heldFrames = 0
        /// Frames whose voice evidence passed the start threshold (model: prob fed to the Vad; energy: db over floor).
        var voicedFrames = 0
        var firstVoicedFrame: Int?
        /// Model frames over the start prob zeroed by the echo reference.
        var echoMaskedFrames = 0
        var maxProb = -1.0
        var maxDb = echoRefFloorDb
        /// Longest run of consecutive voiced frames (the evidence) vs the Vad's longest voiced run (what counted):
        /// a long evidence run with a short Vad run means the Vad's energy / background gates turned the voice down.
        var longestVoicedRun = 0
        var longestVadRun = 0
        /// Background dB the Vad's start gate compared against at the first voiced frame (model mode).
        var bgDbAtFirstVoiced: Double?
        var voicedRun = 0
    }
    private(set) var cycle = CycleStats()
    var floorDb: Double { vad.floorDb }
    var isBargeInOn: Bool { bargeIn }

    /// Why an armed cycle has not opened (diagnostic only).
    var holdReason: String {
        if !bargeIn { return "bargeInOff" }
        if cycle.voicedFrames == 0 { return cycle.echoMaskedFrames > 0 ? "echoMasked" : "noVoice" }
        return cycle.longestVadRun < cycle.longestVoicedRun ? "vadRejected" : "runTooShort"
    }

    init() {}

    /// Playback starts before the next frame. A new cycle replaces the previous one (even an opened one);
    /// only the speaker route arms the gate.
    mutating func playbackStarted(route: VoiceConversationLogic.Route) {
        self.route = route
        playbackStart = frame
        playbackEnd = nil
        cycle = CycleStats(startFrame: frame)
        // Same as runVad resetFrame: drop the sentence and voiced run in progress, keep the noise floor.
        vad.reset()
        armed = route.isSpeaker
    }

    /// Whether frames are being held (the speaker route during a playback cycle, until the gate opens).
    var isArmed: Bool { armed }

    /// The output route changed before the next frame (E-511). Leaving the speaker disarms the gate at once;
    /// moving onto the speaker while playback is still running arms it as a cycle starting now.
    /// A notification that keeps the speaker / non-speaker side changes nothing.
    mutating func routeChanged(route: VoiceConversationLogic.Route) {
        let previous = self.route
        self.route = route
        guard route.isSpeaker != previous.isSpeaker, playbackStart != nil else { return }
        if !route.isSpeaker {
            armed = false
        } else if playbackEnd == nil {
            playbackStarted(route: route)
        }
    }

    /// Playback really ended before the next frame (the post-playback guard window starts here).
    mutating func playbackEnded() {
        guard playbackStart != nil, playbackEnd == nil else { return }
        playbackEnd = frame
    }

    /// false (after the reducer's disableBargeIn): voice during playback no longer opens the gate;
    /// voice in the guard window still does.
    mutating func setBargeIn(_ on: Bool) {
        bargeIn = on
    }

    /// prob: speech probability of this frame from the speech model (nil = energy only). A nil prob once in model
    /// mode means the model failed: a fresh energy Vad takes over for the rest of the gate's life.
    /// ref: dBFS of the downlink PCM block at the playhead when this frame was captured (nil = not playing / digital
    /// silence). In model mode, a frame in [playback start, guard end) correlated with ref is fed to the Vad as prob 0.
    mutating func step(db: Double, prob: Double? = nil, ref: Double? = nil) -> Output {
        let current = frame
        frame += 1
        echoReference.append(db: db, ref: ref)
        if ref != nil { echoRefSeen = true }
        let voice = localVoiceStart(frame: current, db: db, prob: prob)
        guard armed, let start = playbackStart else { return .send }
        let guardEnd = playbackEnd.map { $0 + Self.guardFrames }
        // The guard end is checked before voice on the same frame.
        if let guardEnd, current >= guardEnd {
            armed = false
            return .open(reason: .guardEnd, flushFrom: max(start, current - Self.prerollFrames))
        }
        if let voice, voice.runStart >= start, guardEnd.map({ voice.runStart < $0 }) ?? true,
           bargeIn || playbackEnd.map({ voice.runStart >= $0 }) ?? false {
            armed = false
            var from = max(start, voice.prerollFrame)
            if echoRefSeen, let onset = backtrackOnset(runStart: voice.runStart, playbackStart: start, current: current) {
                from = max(start, min(from, onset - Self.prerollFrames))
            }
            return .open(reason: .speech, flushFrom: from)
        }
        cycle.heldFrames += 1
        return .hold
    }

    /// Onset backtrack (E-434): with the echo reference in effect, frames it let through during playback are trusted as
    /// voice. Within vadModelOnsetBacktrackMs before the run start (not before the playback grace end), the first frame
    /// of the earliest run of ≥ vadModelOnsetMinRunFrames frames with prob ≥ vadModelStartProb and db ≥ vadAbsoluteMinDb.
    private func backtrackOnset(runStart: Int, playbackStart: Int, current: Int) -> Int? {
        let lo = max(playbackStart + Self.graceFrames, runStart - Self.backtrackFrames, current - Self.historyCapacity + 1, 0)
        guard lo < runStart else { return nil }
        var run = 0
        for j in lo..<runStart {
            let slot = j % Self.historyCapacity
            run = recentProb[slot] >= Cascade.Constants.vadModelStartProb
                && recentDb[slot] >= Cascade.Constants.vadAbsoluteMinDb ? run + 1 : 0
            if run >= Cascade.Constants.vadModelOnsetMinRunFrames { return j - run + 1 }
        }
        return nil
    }

    /// The only local voice decision: steps the cascade Vad (model mode when frames carry prob) and returns its
    /// speechStart on this frame.
    private mutating func localVoiceStart(frame: Int, db: Double, prob: Double?) -> (runStart: Int, prerollFrame: Int)? {
        if modelMode == nil { modelMode = prob != nil }
        if modelMode == true, prob == nil {
            // Inference failed mid-session: same as the cascade handleFrame, a new energy Vad, never back to the model.
            modelMode = false
            vad = Cascade.Vad()
        }
        let raw = prob
        var prob = prob
        if modelMode == true, let p = prob, p > 0, let start = playbackStart, frame >= start,
           playbackEnd.map({ frame < $0 + Self.guardFrames }) ?? true, echoReference.isEchoAtLatest() {
            // Echo of the downlink: no voice evidence for the Vad; db still feeds the noise floor.
            prob = 0
        }
        if armed {
            let start = Cascade.Constants.vadModelStartProb
            let voiced = modelMode == true
                ? (prob ?? 0) >= start
                : db >= vad.floorDb + Cascade.Constants.vadStartOverFloorDb
            if voiced {
                cycle.voicedFrames += 1
                cycle.voicedRun += 1
                cycle.longestVoicedRun = max(cycle.longestVoicedRun, cycle.voicedRun)
                if cycle.firstVoicedFrame == nil {
                    cycle.firstVoicedFrame = frame
                    cycle.bgDbAtFirstVoiced = vad.bgDb
                }
            } else {
                cycle.voicedRun = 0
            }
            if (raw ?? 0) >= start, (prob ?? 0) < start { cycle.echoMaskedFrames += 1 }
            cycle.maxProb = max(cycle.maxProb, raw ?? -1)
            cycle.maxDb = max(cycle.maxDb, db)
        }
        let slot = frame % Self.historyCapacity
        recentProb[slot] = prob ?? -1
        recentDb[slot] = db
        let events = vad.step(
            frame: frame, db: db, speaker: route.isSpeaker,
            playbackStartFrame: playbackStart, playbackEndedFrame: playbackEnd, prob: prob
        )
        if armed { cycle.longestVadRun = max(cycle.longestVadRun, vad.runFrames) }
        for event in events {
            if case let .speechStart(runStart, prerollFrame) = event { return (runStart, prerollFrame) }
        }
        return nil
    }
}
