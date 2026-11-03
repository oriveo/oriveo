import Foundation

/// Turn-taking contract for voice conversation (`voice-conversation.v1`).
/// Every case in the shared fixtures locks this contract.
/// Everything here is a pure function: no IO, no clock; time comes in through each event's atMs. The host only translates real signals into events and executes the returned effects.
nonisolated enum VoiceConversationLogic {

    // MARK: - Constants (client-side constants; names match the fixture's constants)

    enum Constants {
        static let frameMs = 20
        static let vadStartMs = 120
        static let vadEndSilenceMs = 600
        static let vadMinUtteranceMs = 250
        static let vadMaxUtteranceMs = 60_000
        static let vadPrerollMs = 300
        static let vadStartOverFloorDb = 12.0
        static let vadContinueOverFloorDb = 6.0
        static let vadAbsoluteMinDb = -55.0
        static let vadContinueAbsMinDb = -60.0
        static let floorInitDb = -50.0
        static let floorAlpha = 0.05
        static let floorClampDb: ClosedRange<Double> = -75.0 ... -30.0
        /// VAD model mode: when frames carry a speech probability, onset and continuation use the probability plus an energy gate relative to the noise floor;
        /// the noise floor is the minimum of the floorSmoothMs sliding mean within the recent floorWindowMs window
        static let vadModelStartProb = 0.5
        static let vadModelContinueProb = 0.35
        static let vadModelGateOverFloorDb = 6.0
        static let vadModelContinueOverFloorDb = 3.0
        /// Background-level gate: bg = the vadModelBgPercentile-th percentile of the same buffer's smoothed values;
        /// onset must rise vadModelStartOverBgDb above bg; continuation requires the smoothed value to stay vadModelContinueOverBgDb above the onset bg
        static let vadModelBgPercentile = 70
        static let vadModelStartOverBgDb = 4.0
        static let vadModelContinueOverBgDb = 2.0
        /// Continuation reference: within floorWindowMs after a sentence, if the pause-segment floor is not higher than the previous sentence's bgAtStart plus this value,
        /// the onset gate and the new sentence's bgAtStart take min(bg, previous bgAtStart)
        static let vadModelFollowUpFloorOverBgDb = 3.0
        /// Onset backtrack: if interrupted while not speaking, a short run passing the gate with at least vadModelOnsetMinRunFrames frames records its first frame;
        /// at onset, pre-recording backtracks to the earliest segment within the vadModelOnsetBacktrackMs window
        static let vadModelOnsetBacktrackMs = 1000
        static let vadModelOnsetMinRunFrames = 2
        static let floorWindowMs = 3000
        static let floorSmoothMs = 100
        static let frameDbClampDb: ClosedRange<Double> = -120.0 ... 0.0
        static let bargeInGraceMs = 1000
        static let bargeInMinSpeechMs = 300
        static let postPlaybackGuardMs = 800
        /// Onset threshold within the echo window: measured echo is at most 2 frames; 300 ms would swallow one-syllable short answers such as "No"
        static let postPlaybackGuardMinSpeechMs = 160
        static let echoOverlapRatio = 0.6
        static let echoWindowMs = 3000
        static let echoMinWeight = 12
        static let echoHanUnitWeight = 3
        static let echoOtherUnitWeight = 4
        static let falseBargeInsPerConversation = 2
        static let conversationsToRemember = 2
        static let idleTimeoutMs = 120_000
        static let thinkingEarconMs = 1500
        /// Reply-audio gate: reply speech starts no earlier than 1600 ms after the sentence's silence start; speech started before the gate is merged into the same turn.
        static let replyAudioGateMs = 1600
        static let partialStallMs = 1500
        static let endpointMaxSilenceMs = 1600
        static let endpointPartialSettleMs = 500
        static let continuationPunctuation: [String] = [",", "，", "、", ";", "；"]
        static let continuationWords: [String] = [
            "然后", "但是", "因为", "所以", "而且", "或者", "还有", "就是", "那个", "如果", "和", "跟",
            "and", "but", "so", "because", "or", "then", "if", "the", "a", "an", "to", "of", "with", "um", "uh",
        ]
        static let sayAgainMinVoicedMs = 600
        static let checkLanguageMinVoicedMs = 1000
        static let checkLanguageAfterMisses = 2
        static let listenToThinkTapGuardMs = 600
        static let stopToVoiceGuardMs = 500
        static let sttRetries = 1
    }

    // MARK: - A. VAD

    enum VadEndReason: String, Equatable, Sendable {
        case silence
        case maxLength
        /// Host "I'm done talking" forced end (forceEnd); the fixture's runVad never produces it.
        case forced
    }

    enum VadEvent: Equatable, Sendable {
        case speechStart(frame: Int, prerollFrame: Int)
        case speechEnd(frame: Int, voicedMs: Int, reason: VadEndReason)
        case discarded(frame: Int)
    }

    /// Per-frame VAD state; the host calls `step` once per frame, with the same results as runVad frame by frame.
    struct Vad: Equatable, Sendable {
        private(set) var floorDb = Constants.floorInitDb
        private(set) var speaking = false
        private var startFrame = -1
        private(set) var runFrames = 0
        private var runStart = -1
        private var silenceFrames = 0
        private var voicedMs = 0
        /// Model mode: the first frame carrying a prob sets whole-segment model mode (nil = no frame seen yet)
        private var modelMode: Bool?
        private var modelFloor = ModelFloor()
        /// Model mode: background level before this frame, and the bg at the frame where onset succeeded
        private(set) var bgDb = Constants.floorInitDb
        private var bgAtStart = Constants.floorInitDb
        /// Continuation reference: bgAtStart and the end frame of the most recent kept sentence (speechEnd); reset clears them
        private var lastBgAtStart: Double?
        private var lastCloseFrame: Int?
        /// Model mode: first frame of an interrupted short run while not speaking (ascending); at onset, pre-recording backtracks to the earliest segment in the window
        private var onsetRuns: [Int] = []
        /// Whether the current short run's first frame is inside the speaker playback candidate window (most likely echo; not recorded)
        private var runInCandidate = false

        init() {}

        /// speaker = speaker output; playbackStartFrame = frame where playback started on the speaker (nil when not playing; barge-in candidate mode);
        /// playbackEndedFrame = frame where playback actually ended (start of the echo window; nil if none).
        mutating func step(
            frame: Int, db rawDb: Double, speaker: Bool = true,
            playbackStartFrame: Int? = nil, playbackEndedFrame: Int? = nil, prob: Double? = nil
        ) -> [VadEvent] {
            let db = VoiceConversationLogic.clampFrameDb(rawDb)
            // The first frame carrying prob sets whole-segment model mode and is not mixed; frames lacking prob in model mode are treated as 0
            if modelMode == nil { modelMode = prob != nil }
            let model = modelMode == true
            let p = prob ?? 0
            let graceFrames = Constants.bargeInGraceMs / Constants.frameMs
            let guardFrames = Constants.postPlaybackGuardMs / Constants.frameMs
            var inCandidate = false
            if speaker, let start = playbackStartFrame, frame >= start {
                inCandidate = playbackEndedFrame.map { frame < $0 } ?? true
            }
            if inCandidate, let start = playbackStartFrame, frame < start + graceFrames {
                // Grace frame: do not update the noise floor or count speech / silence, but leave a pending barge-in speech run
                runFrames = 0
                return []
            }
            if model {
                floorDb = modelFloor.floor() // only frames already processed before this frame
                bgDb = modelFloor.bg()
                modelFloor.push(db)
            }
            var events: [VadEvent] = []
            if !speaking {
                // Continuation after a pause: the bg raised by the previous sentence does not block the second half; if the pause segment is not quiet (e.g. TV on), behave as before
                var startBg = bgDb
                if model, let lastBg = lastBgAtStart, let lastClose = lastCloseFrame,
                   frame - lastClose <= Constants.floorWindowMs / Constants.frameMs,
                   floorDb <= lastBg + Constants.vadModelFollowUpFloorOverBgDb {
                    startBg = min(bgDb, lastBg)
                }
                let voiced = model
                    ? p >= Constants.vadModelStartProb
                        && db >= max(
                            Constants.vadAbsoluteMinDb, floorDb + Constants.vadModelGateOverFloorDb,
                            startBg + Constants.vadModelStartOverBgDb
                        )
                    : db >= floorDb + Constants.vadStartOverFloorDb && db >= Constants.vadAbsoluteMinDb
                let backtrackFrames = Constants.vadModelOnsetBacktrackMs / Constants.frameMs
                guard voiced else {
                    if model && runFrames >= Constants.vadModelOnsetMinRunFrames && !runInCandidate {
                        onsetRuns.append(runStart)
                        // Keep only what is in the window; long-running noise does not accumulate
                        while let first = onsetRuns.first, frame - first > backtrackFrames { onsetRuns.removeFirst() }
                    }
                    runFrames = 0
                    if !model { updateFloor(db) }
                    return []
                }
                if runFrames == 0 {
                    runStart = frame
                    runInCandidate = inCandidate
                }
                runFrames += 1
                var inGuard = false
                if speaker, let ended = playbackEndedFrame { inGuard = runStart >= ended && runStart < ended + guardFrames }
                let needMs = inCandidate ? Constants.bargeInMinSpeechMs
                    : inGuard ? Constants.postPlaybackGuardMinSpeechMs : Constants.vadStartMs
                guard runFrames >= needMs / Constants.frameMs else { return [] }
                speaking = true
                startFrame = runStart
                bgAtStart = startBg // start-gate bg at the frame where onset succeeded (min(bg, previous bgAtStart) when continuing)
                voicedMs = runFrames * Constants.frameMs
                silenceFrames = 0
                runFrames = 0
                let lowest = playbackEndedFrame.flatMap { runStart >= $0 ? $0 : nil } ?? 0
                let onset = onsetRuns.first { frame - $0 <= backtrackFrames }.map { min(runStart, $0) } ?? runStart
                onsetRuns = []
                events.append(.speechStart(frame: runStart, prerollFrame: max(lowest, onset - Constants.vadPrerollMs / Constants.frameMs)))
                if frame - startFrame + 1 >= Constants.vadMaxUtteranceMs / Constants.frameMs {
                    events.append(close(frame: frame, reason: .maxLength))
                }
                return events
            }
            let held = model
                ? p >= Constants.vadModelContinueProb
                    && modelFloor.smoothed() >= max(
                        floorDb + Constants.vadModelContinueOverFloorDb, bgAtStart + Constants.vadModelContinueOverBgDb
                    )
                : db >= max(floorDb + Constants.vadContinueOverFloorDb, Constants.vadContinueAbsMinDb)
            if held {
                voicedMs += Constants.frameMs
                silenceFrames = 0
            } else {
                silenceFrames += 1
                if !model { updateFloor(db) }
                if silenceFrames >= Constants.vadEndSilenceMs / Constants.frameMs {
                    return [close(frame: frame, reason: .silence)]
                }
            }
            if frame - startFrame + 1 >= Constants.vadMaxUtteranceMs / Constants.frameMs {
                events.append(close(frame: frame, reason: .maxLength))
            }
            return events
        }

        /// "I'm done talking" (tap on the orb, or a forced end on stall): clears the speech run; while speaking, closes the current sentence immediately with the accumulated total
        /// (speech shorter than vadMinUtteranceMs is still dropped as usual); does nothing when not speaking.
        mutating func forceEnd(frame: Int) -> VadEvent? {
            runFrames = 0
            onsetRuns = []
            guard speaking else { return nil }
            return close(frame: frame, reason: .forced)
        }

        /// resetVad: drops the in-progress sentence and speech run (no event emitted); the noise floor is kept.
        mutating func reset() {
            speaking = false
            runFrames = 0
            silenceFrames = 0
            voicedMs = 0
            onsetRuns = []
            // The continuation reference is kept on a playback-start reset: it only drops the in-progress sentence and speech run; otherwise the bg raised by the user's previous sentence within the last 3 s would block barge-in
        }

        private mutating func close(frame: Int, reason: VadEndReason) -> VadEvent {
            let total = voicedMs
            speaking = false
            silenceFrames = 0
            voicedMs = 0
            guard total >= Constants.vadMinUtteranceMs else { return .discarded(frame: frame) }
            lastBgAtStart = bgAtStart
            lastCloseFrame = frame
            return .speechEnd(frame: frame, voicedMs: total, reason: reason)
        }

        private mutating func updateFloor(_ db: Double) {
            let next = floorDb + Constants.floorAlpha * (db - floorDb)
            floorDb = min(max(next, Constants.floorClampDb.lowerBound), Constants.floorClampDb.upperBound)
        }
    }

    /// Model-mode noise floor: stores dB of processed (non-grace) frames; smoothed value = arithmetic mean of the most recent floorSmoothMs frames (all available if fewer),
    /// floor = minimum of the smoothed values over the most recent floorWindowMs frames; floorInitDb when there are none. Speech frames are counted too, so the floor does not freeze mid-sentence.
    /// bg = the element at index floor((n-1)·vadModelBgPercentile/100) of the same buffer sorted ascending, floorInitDb when empty; smoothed = the smoothed value after the latest push.
    struct ModelFloor: Equatable, Sendable {
        private var dbs: [Double] = []
        private var smooth: [Double] = []

        func floor() -> Double {
            smooth.min() ?? Constants.floorInitDb
        }

        func bg() -> Double {
            guard !smooth.isEmpty else { return Constants.floorInitDb }
            let sorted = smooth.sorted()
            return sorted[(sorted.count - 1) * Constants.vadModelBgPercentile / 100]
        }

        func smoothed() -> Double {
            smooth.last ?? Constants.floorInitDb
        }

        mutating func push(_ db: Double) {
            dbs.append(db)
            if dbs.count > Constants.floorSmoothMs / Constants.frameMs { dbs.removeFirst() }
            var sum = 0.0
            for value in dbs { sum += value }
            smooth.append(sum / Double(dbs.count))
            if smooth.count > Constants.floorWindowMs / Constants.frameMs { smooth.removeFirst() }
        }
    }

    /// Frame levels are first clamped to frameDbClampDb; NaN and -infinity are treated as the lower bound.
    static func clampFrameDb(_ db: Double) -> Double {
        guard !db.isNaN else { return Constants.frameDbClampDb.lowerBound }
        return min(max(db, Constants.frameDbClampDb.lowerBound), Constants.frameDbClampDb.upperBound)
    }

    /// Runs VAD over a whole frame sequence (the fixture's vad group); a segment still open at the end emits no event.
    /// resetFrame = frame where the host runs resetVad (reset before that frame is processed); forceEndFrame = frame where the host runs forceEndUtterance (sentence closed before that frame is processed);
    /// probs non-nil means model mode (aligned with frames frame by frame).
    static func runVad(
        frames: [Double], probs: [Double]? = nil, route: Route = .speaker, playbackStartFrame: Int? = nil,
        playbackEndedFrame: Int? = nil, resetFrame: Int? = nil, forceEndFrame: Int? = nil
    ) -> [VadEvent] {
        var vad = Vad()
        var events: [VadEvent] = []
        for (index, db) in frames.enumerated() {
            if index == resetFrame { vad.reset() }
            if index == forceEndFrame, let event = vad.forceEnd(frame: index) { events.append(event) }
            events += vad.step(
                frame: index, db: db, speaker: route.isSpeaker,
                playbackStartFrame: playbackStartFrame, playbackEndedFrame: playbackEndedFrame,
                prob: probs?[index]
            )
        }
        return events
    }

    // MARK: - B. Self-echo detection

    struct EchoResult: Equatable, Sendable {
        let echo: Bool
        /// Four decimal places; nil when the transcript has no units to compare (empty or too short).
        let overlap: Double?
    }

    private static let zhDigits: [Unicode.Scalar: Double] = [
        "零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
    ]
    private static let zhSmall: [Unicode.Scalar: Double] = ["十": 10, "百": 100, "千": 1000]
    private static let zhBig: [Unicode.Scalar: Double] = ["万": 10_000, "亿": 100_000_000]
    private static let maxSafeInteger = 9_007_199_254_740_991.0

    private static func isZhNumeral(_ scalar: Unicode.Scalar) -> Bool {
        zhDigits[scalar] != nil || zhSmall[scalar] != nil || zhBig[scalar] != nil
    }

    /// A run of consecutive Chinese numeral characters becomes an Arabic digit string; runs with no digit characters are returned as-is.
    static func zhNumberRun(_ run: String) -> String {
        let chars = Array(run.unicodeScalars)
        guard chars.contains(where: { zhDigits[$0] != nil }) else { return run }
        if !chars.contains(where: { zhSmall[$0] != nil || zhBig[$0] != nil }) {
            return chars.map { String(Int(zhDigits[$0] ?? 0)) }.joined()
        }
        var total = 0.0
        var section = 0.0
        var num = 0.0
        var hasNum = false
        for c in chars {
            if let digit = zhDigits[c] {
                num = digit
                hasNum = true
            } else if let small = zhSmall[c] {
                section += (hasNum ? num : 1) * small
                num = 0
                hasNum = false
            } else if c == "万" {
                total += (section + num) * 10_000
                section = 0
                num = 0
                hasNum = false
            } else {
                total = (total + section + num) * 100_000_000
                section = 0
                num = 0
                hasNum = false
            }
            if total > maxSafeInteger || section > maxSafeInteger { return run }
        }
        let value = total + section + num
        return value > maxSafeInteger ? run : String(Int64(value))
    }

    /// Reference echoUnits: NFKC, then lowercase, then walk code points: consecutive Chinese numerals are first converted to Arabic digits, one unit per digit;
    /// separators (P / S / Z / Cc / Cf / variation selectors) split and are dropped; ASCII digits, Han / kana / Hangul / Thai code points are one unit each;
    /// any other longest consecutive run is one unit.
    static func units(_ text: String) -> [String] {
        var result: [String] = []
        var run = String.UnicodeScalarView()
        func flush() {
            if !run.isEmpty { result.append(String(run)) }
            run = String.UnicodeScalarView()
        }
        let chars = Array(text.precomposedStringWithCompatibilityMapping.lowercased().unicodeScalars)
        var index = 0
        while index < chars.count {
            let scalar = chars[index]
            if isZhNumeral(scalar) {
                var end = index
                while end < chars.count && isZhNumeral(chars[end]) { end += 1 }
                flush()
                var numeral = String.UnicodeScalarView()
                numeral.append(contentsOf: chars[index..<end])
                for unit in zhNumberRun(String(numeral)).unicodeScalars { result.append(String(unit)) }
                index = end
                continue
            }
            if isSeparator(scalar) {
                flush()
            } else if (0x30...0x39).contains(scalar.value) || isSingleUnit(scalar) {
                flush()
                result.append(String(scalar))
            } else {
                run.append(scalar)
            }
            index += 1
        }
        flush()
        return result
    }

    /// pool = AI sentences and prompts already played this turn (in playback order). Echo is judged by the share of the transcript covered by the longest common run of units.
    static func isEcho(transcript: String, pool: [String]) -> EchoResult {
        let heard = units(transcript)
        let weight = heard.reduce(0) {
            $0 + (isSingleUnit($1.unicodeScalars.first ?? " ") ? Constants.echoHanUnitWeight : Constants.echoOtherUnitWeight)
        }
        guard !heard.isEmpty, weight >= Constants.echoMinWeight else { return EchoResult(echo: false, overlap: nil) }
        let spoken = pool.flatMap(units)
        var best = 0
        var previous = [Int](repeating: 0, count: spoken.count + 1)
        for i in 1...heard.count {
            var current = [Int](repeating: 0, count: spoken.count + 1)
            for j in stride(from: 1, through: spoken.count, by: 1) where heard[i - 1] == spoken[j - 1] {
                current[j] = previous[j - 1] + 1
                best = max(best, current[j])
            }
            previous = current
        }
        let ratio = Double(best) / Double(heard.count)
        return EchoResult(echo: ratio >= Constants.echoOverlapRatio, overlap: (ratio * 10000 + 0.5).rounded(.down) / 10000)
    }

    /// The full Unicode White_Space set, listed explicitly so the three platforms do not depend on their own trim definitions.
    private static let whiteSpace: Set<UInt32> = [
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005,
        0x2006, 0x2007, 0x2008, 0x2009, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000,
    ]

    private static func trimEnd(_ text: String) -> String.UnicodeScalarView {
        var scalars = text.unicodeScalars
        while let last = scalars.last, whiteSpace.contains(last.value) { scalars.removeLast() }
        return scalars
    }

    private static func trimStart(_ text: String) -> String.UnicodeScalarView {
        var scalars = text.unicodeScalars
        while let first = scalars.first, whiteSpace.contains(first.value) { scalars.removeFirst() }
        return scalars
    }

    /// Caption ends with a comma-like punctuation mark or a conjunction: sentence break is deferred to endpointMaxSilenceMs.
    static func endsWithContinuation(_ text: String) -> Bool {
        let raw = trimEnd(text)
        guard let last = raw.last else { return false }
        if Constants.continuationPunctuation.contains(String(last)) { return true }
        if isSeparator(last) { return false }
        let heard = units(String(raw))
        return Constants.continuationWords.contains { word in
            let wordUnits = units(word)
            return wordUnits.count <= heard.count && Array(heard.suffix(wordUnits.count)) == wordUnits
        }
    }

    /// Barge-in while thinking: the new speech is joined onto the end of the previous user message (same bubble).
    static func joinAmend(_ previous: String, _ text: String) -> String {
        let a = trimEnd(previous)
        let b = trimStart(text)
        guard let first = b.first else { return String(a) }
        guard let last = a.last else { return String(b) }
        return isSingleUnit(last) || isSingleUnit(first) ? String(a) + String(b) : String(a) + " " + String(b)
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
        case 0x0E00...0x0E7F, 0x1100...0x11FF, 0x2E80...0x2FDF, 0x3005, 0x3007, 0x3021...0x3029, 0x3038...0x303B,
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
        case sayAgain
        /// Without the language name.
        case checkLanguage
        case echoHint
    }

    enum Earcon: String, Equatable, Sendable {
        case start
        case heard
        case thinking
        case end
    }

    enum Haptic: String, Equatable, Sendable {
        case light
    }

    /// Hint state after not hearing clearly (shown only in listening).
    enum Notice: String, Equatable, Sendable {
        case sayAgain
        case checkLanguage
    }

    enum EndReason: String, Equatable, Sendable {
        /// The user tapped close.
        case user
        /// The host ended it: switched conversation or navigated back.
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
        case vadSpeechEnd(utteranceId: String, voicedMs: Int)
        case vadDiscarded
        case bargeInDetected
        /// Live caption from the recognizer (current text of the whole sentence).
        case sttPartial(text: String)
        case sttResult(utteranceId: String, text: String)
        case sttFailed(utteranceId: String)
        case replySentence(text: String)
        /// Host: a sentence in the queue started playing (feeds echo detection).
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
        /// Host: prompt started / finished playing.
        case promptStarted(text: String)
        case promptEnded
        case end(reason: EndReason)
    }

    enum Effect: Equatable, Sendable {
        case startCapture
        case pauseCapture
        case resumeCapture
        case setCaptureMuted(Bool)
        /// Resets the detector; when playbackEndedAtMs is non-nil, opens the echo window from that moment.
        case resetVad(playbackEndedAtMs: Int?)
        case transcribe(utteranceId: String)
        case transcribeToDraft
        case sendMessage(text: String)
        /// Replaces the previous user message with joinAmend(previous user message, text) and regenerates; an empty string regenerates as-is.
        case amendLastMessage(text: String)
        case cancelGeneration
        case pausePlayback
        case resumePlayback(from: ResumePoint)
        case stopPlayback
        case enqueueSpeech(text: String)
        case speakPrompt(Prompt)
        case earcon(Earcon)
        case haptic(Haptic)
        case nudgeOrb
        case forceEndUtterance
        /// A just-resumed speech run belongs to this sentence: keep the recognition session / recording; the next vadSpeechEnd uses the same id.
        case continueUtterance(utteranceId: String)
        case rememberFalseBargeInConversation
        case playMessage(messageId: String)
        case endConversation(reason: EndReason, code: String?)
    }

    enum ReplyStatus: String, Equatable, Sendable {
        case none, streaming, completed
    }

    /// Queued VAD event and the time it arrived.
    struct QueuedVad: Equatable, Sendable {
        let event: Event
        let atMs: Int
    }

    struct State: Equatable, Sendable {
        var phase: Phase = .idle
        var route: Route = .speaker
        var deviceRemembersNoSpeakerBargeIn = false
        /// Whether voice barge-in works on the speaker in this conversation (always true on headphones / Bluetooth).
        var speakerBargeIn = true
        var userSpeaking = false
        var utteranceStartMs: Int?
        var partialText = ""
        var partialChangedAtMs: Int?
        var stallFired = false
        /// Sentence whose break is deferred (VAD has finished, waiting for the caption to stabilize).
        var holdUtteranceId: String?
        var holdVoicedMs: Int?
        var holdSilenceStartMs: Int?
        var holdSinceMs: Int?
        var continuedUtteranceId: String?
        var continuedVoicedMs: Int?
        /// This sentence was ended by the orb's forceEndUtterance (no reply-audio gate set).
        var forcedByTap = false
        var muted = false
        var awaitingApproval = false
        var error = false
        var interrupted = false
        var screenReaderSpeaking = false
        var messagePlaying = false
        var promptPlaying = false
        var falseBargeIns = 0
        /// Playback was stopped this turn (orb tap / headphones unplugged / after a call); text keeps generating but later sentences are not queued.
        var playbackStopped = false
        var playbackEndedAtMs: Int?
        /// AI sentences and prompts already played this turn (self-echo comparison pool).
        var spoken: [String] = []
        var sttAttempts = 0
        var awaitedUtteranceId: String?
        /// VAD events arriving while thinking and waiting for transcription; replayed in order once the transcript settles.
        var pendingVad: [QueuedVad] = []
        var utteranceVoicedMs: Int?
        var utteranceCompared = false
        var heardPending = false
        /// Barge-in in progress while thinking.
        var amend = false
        /// Barge-in candidate: speech detected while the assistant was speaking.
        var bargeIn = false
        var reply: ReplyStatus = .none
        var drained = false
        var thinkingSinceMs: Int?
        var thinkingEarconPlayed = false
        /// Reply-audio gate time; nil when the sentence ended via forceEnd.
        var gateAt: Int?
        /// Reply sentences that arrived before the gate, in arrival order.
        var gateQueue: [String] = []
        /// replyCompleted arrived before the gate.
        var gateCompleted = false
        var lastActivityMs: Int?
        var emptyStreak = 0
        var languageHintShown = false
        var notice: Notice?

        init() {}
    }

    static func initialState() -> State { State() }

    enum DisplayState: String, Equatable, Sendable {
        case listening, userSpeaking, thinking, speaking, muted, awaitingApproval, sayAgain, checkLanguage, error
    }

    /// Status-line key: when speaking on the speaker with voice barge-in off, speakingTapToInterrupt ("Speaking - tap to interrupt");
    /// while the user is speaking with a caption available, caption (the status position shows `caption(state)`).
    enum StatusKey: String, Equatable, Sendable {
        case listening, caption, thinking, speaking, speakingTapToInterrupt, muted, awaitingApproval, sayAgain,
             checkLanguage, error
    }

    /// Display state (the UI reads only this): error > idle / ended is nil > awaitingApproval > muted && listening
    /// > userSpeaking (when this sentence can become a turn) > listening's notice > phase.
    static func displayState(_ state: State) -> DisplayState? {
        if state.error { return .error }
        switch state.phase {
        case .idle, .ended: return nil
        default: break
        }
        if state.awaitingApproval { return .awaitingApproval }
        if state.muted && state.phase == .listening { return .muted }
        if state.userSpeaking && canFinalize(state) { return .userSpeaking }
        if state.phase == .listening, let notice = state.notice {
            switch notice {
            case .sayAgain: return .sayAgain
            case .checkLanguage: return .checkLanguage
            }
        }
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
        case .userSpeaking: return state.partialText.isEmpty ? .listening : .caption
        case .thinking: return .thinking
        case .speaking: return state.route.isSpeaker && !state.speakerBargeIn ? .speakingTapToInterrupt : .speaking
        case .muted: return .muted
        case .awaitingApproval: return .awaitingApproval
        case .sayAgain: return .sayAgain
        case .checkLanguage: return .checkLanguage
        case .error: return .error
        }
    }

    /// Live caption at the status position: non-nil only when statusKey is caption.
    static func caption(_ state: State) -> String? {
        statusKey(state) == .caption ? state.partialText : nil
    }

    private static func computeSpeakerBargeIn(_ s: State) -> Bool {
        !s.route.isSpeaker || !(s.deviceRemembersNoSpeakerBargeIn || s.falseBargeIns >= Constants.falseBargeInsPerConversation)
    }

    private static func holding(_ s: State) -> Bool { s.holdUtteranceId != nil }

    private static func clearUtterance(_ s: inout State) {
        s.userSpeaking = false
        s.utteranceStartMs = nil
        s.partialText = ""
        s.partialChangedAtMs = nil
        s.stallFired = false
        s.holdUtteranceId = nil
        s.holdVoicedMs = nil
        s.holdSilenceStartMs = nil
        s.holdSinceMs = nil
        s.continuedUtteranceId = nil
        s.continuedVoicedMs = nil
        s.forcedByTap = false
    }

    private static func resetTurn(_ s: inout State) {
        clearUtterance(&s)
        s.playbackStopped = false
        s.sttAttempts = 0
        s.awaitedUtteranceId = nil
        s.pendingVad = []
        s.utteranceVoicedMs = nil
        s.utteranceCompared = false
        s.heardPending = false
        s.amend = false
        s.bargeIn = false
        s.reply = .none
        s.drained = false
        s.thinkingSinceMs = nil
        s.thinkingEarconPlayed = false
        s.gateQueue = []
        s.gateCompleted = false
    }

    private static func guardOrigin(_ s: State, _ t: Int) -> Int? {
        guard let ended = s.playbackEndedAtMs, t - ended < Constants.postPlaybackGuardMs else { return nil }
        return ended
    }

    private static func toListening(_ s: inout State, _ t: Int, _ fx: inout [Effect]) {
        resetTurn(&s)
        s.gateAt = nil
        s.phase = .listening
        s.lastActivityMs = t
        fx.append(.resetVad(playbackEndedAtMs: guardOrigin(s, t)))
    }

    private static func toThinking(_ s: inout State, _ t: Int) {
        resetTurn(&s)
        s.phase = .thinking
        s.thinkingSinceMs = t
    }

    private static func maybeFinish(_ s: inout State, _ t: Int, _ fx: inout [Effect]) {
        if s.phase == .speaking && s.reply == .completed && (s.drained || s.playbackStopped) && !s.bargeIn {
            toListening(&s, t, &fx)
        }
    }

    private static func stopPlayback(_ s: inout State, _ t: Int, _ fx: inout [Effect]) {
        s.playbackStopped = true
        s.playbackEndedAtMs = t
        fx.append(.stopPlayback)
    }

    /// Cases where this sentence can become a turn (sent after transcription / barge-in / amend).
    private static func canFinalize(_ s: State) -> Bool {
        s.phase == .listening || (s.phase == .thinking && s.amend) || (s.phase == .speaking && s.bargeIn)
    }

    /// Only compares sentences on the speaker that started during playback or within echoWindowMs after playback ended.
    private static func inEchoWindow(_ s: State) -> Bool {
        guard s.route.isSpeaker else { return false }
        if s.phase == .speaking { return true }
        guard let start = s.utteranceStartMs, let ended = s.playbackEndedAtMs else { return false }
        return start - ended <= Constants.echoWindowMs
    }

    private static func holdUntil(_ s: State) -> Int {
        let cap = (s.holdSilenceStartMs ?? 0) + Constants.endpointMaxSilenceMs
        if endsWithContinuation(s.partialText) { return cap }
        return min(cap, max(s.holdSinceMs ?? 0, (s.partialChangedAtMs ?? 0) + Constants.endpointPartialSettleMs))
    }

    private static func regenerate(_ s: inout State, _ t: Int, _ fx: inout [Effect], _ text: String) {
        fx.append(.amendLastMessage(text: text))
        toThinking(&s, t)
        s.reply = .streaming
        s.spoken = []
    }

    /// User speech interrupted by an external force (mute, phone call, screen reader, playing an old message, prompt): the sentence is discarded; barge-in while thinking is discarded and the reply is regenerated as-is.
    private static func abandonUtterance(_ s: inout State, _ t: Int, _ fx: inout [Effect]) {
        let wasAmending = s.amend && s.userSpeaking
        clearUtterance(&s)
        s.pendingVad = [] // queued onsets are discarded together
        if wasAmending {
            regenerate(&s, t, &fx, "")
        } else if s.phase == .speaking && s.bargeIn && s.awaitedUtteranceId == nil {
            dropBargeIn(&s, t, &fx)
        }
    }

    /// Barge-in candidate discarded: resumes playback where it was interrupted (not resumed during a phone call; playback stops when the call ends), then runs the closing checks.
    private static func dropBargeIn(_ s: inout State, _ t: Int, _ fx: inout [Effect]) {
        s.bargeIn = false
        if !s.playbackStopped && !s.interrupted { fx.append(.resumePlayback(from: .pausePoint)) }
        maybeFinish(&s, t, &fx)
    }

    /// silenceStartMs: the sentence's silence start; nil when ended by forceEnd, which sets no gate.
    private static func finalize(
        _ s: inout State, _ utteranceId: String, _ voicedMs: Int?, _ t: Int, _ fx: inout [Effect], silenceStartMs: Int?
    ) {
        let compared = inEchoWindow(s)
        if s.phase == .listening {
            toThinking(&s, t)
        } else {
            clearUtterance(&s)
            // Judgement of the add-on sentence: the thinking timer restarts from this judgement moment
            if s.phase == .thinking { s.thinkingSinceMs = t }
        }
        s.gateAt = silenceStartMs.map { $0 + Constants.replyAudioGateMs }
        s.awaitedUtteranceId = utteranceId
        s.sttAttempts = 1
        s.utteranceVoicedMs = voicedMs ?? 0
        s.utteranceCompared = compared
        s.heardPending = compared
        if !compared {
            fx.append(.earcon(.heard))
            fx.append(.haptic(.light))
        }
        fx.append(.transcribe(utteranceId: utteranceId))
    }

    private static func gateWaiting(_ s: State, _ t: Int) -> Bool {
        guard s.phase == .thinking, let gateAt = s.gateAt else { return false }
        return t < gateAt
    }

    /// Queued replies before the gate are sent in arrival order and enter speaking; a replyCompleted that arrived before the gate follows.
    private static func flushGate(_ s: inout State, _ t: Int, _ fx: inout [Effect]) {
        guard s.phase == .thinking, !s.gateQueue.isEmpty else { return }
        s.phase = .speaking
        if !s.playbackStopped {
            s.drained = false
            for text in s.gateQueue { fx.append(.enqueueSpeech(text: text)) }
        }
        s.gateQueue = []
        s.gateAt = nil
        if s.gateCompleted {
            s.gateCompleted = false
            s.reply = .completed
            maybeFinish(&s, t, &fx)
        }
    }

    private static func heard(_ s: inout State, _ fx: inout [Effect]) {
        if s.heardPending {
            fx.append(.earcon(.heard))
            fx.append(.haptic(.light))
        }
        s.heardPending = false
    }

    private static func countEcho(_ s: inout State, _ fx: inout [Effect]) {
        fx.append(.nudgeOrb)
        guard s.route.isSpeaker else { return }
        s.falseBargeIns += 1
        if s.falseBargeIns == Constants.falseBargeInsPerConversation {
            s.speakerBargeIn = computeSpeakerBargeIn(s)
            fx.append(.rememberFalseBargeInConversation)
            fx.append(.speakPrompt(.echoHint))
        }
    }

    private static func sent(_ s: inout State) {
        s.emptyStreak = 0
        s.notice = nil
        s.spoken = []
    }

    private static func miss(_ s: inout State, _ t: Int, _ fx: inout [Effect]) {
        let voiced = s.utteranceVoicedMs ?? 0
        toListening(&s, t, &fx)
        if voiced >= Constants.checkLanguageMinVoicedMs { s.emptyStreak += 1 }
        guard voiced >= Constants.sayAgainMinVoicedMs else { return }
        let notice: Notice
        if s.emptyStreak >= Constants.checkLanguageAfterMisses && !s.languageHintShown {
            s.languageHintShown = true
            notice = .checkLanguage
        } else {
            notice = .sayAgain
        }
        s.notice = notice
        fx.append(.speakPrompt(notice == .checkLanguage ? .checkLanguage : .sayAgain))
        fx.append(.haptic(.light))
    }

    private static func isVadEvent(_ event: Event) -> Bool {
        switch event {
        case .vadSpeechStart, .vadSpeechEnd, .vadDiscarded, .bargeInDetected: return true
        default: return false
        }
    }

    /// Barge-in while thinking: collects VAD only when already sent and not waiting for a transcript; an onset that was already speaking at that moment does not count.
    private static func thinkingAcceptsVad(_ s: State) -> Bool {
        s.awaitedUtteranceId == nil && (s.reply == .streaming || s.userSpeaking)
    }

    /// VAD blocked by an external force (mute, phone call, screen reader, playing an old message, prompt): dropped, not queued.
    private static func vadBlocked(_ s: State) -> Bool {
        s.muted || s.interrupted || s.screenReaderSpeaking || s.messagePlaying || s.promptPlaying
    }

    /// Onset while thinking and waiting for a transcript is not dropped: onset / end / discard are queued as-is and replayed once the transcript settles.
    static func queuesVad(_ s: State, _ event: Event) -> Bool {
        guard s.phase == .thinking, s.awaitedUtteranceId != nil else { return false }
        switch event {
        case .vadSpeechStart, .vadSpeechEnd, .vadDiscarded: return true
        default: return false
        }
    }

    /// Conditions for dropping an unqueued VAD event (not collecting barge-in while thinking; while speaking, barge-in off and not speaking, or already waiting for a transcript).
    private static func dropsUnqueuedVad(_ s: State) -> Bool {
        if s.phase == .thinking && !thinkingAcceptsVad(s) { return true }
        if s.phase == .speaking && ((!s.speakerBargeIn && !s.userSpeaking) || s.awaitedUtteranceId != nil) { return true }
        return false
    }

    /// A speech onset will be dropped (blocked by an external force; not queued while thinking without barge-in; while speaking, barge-in off and not speaking, or already waiting for a transcript).
    /// The controller uses this to predict: a speech onset that would be dropped does not start recording; one that would be queued still records.
    static func dropsVad(_ s: State) -> Bool {
        if vadBlocked(s) { return true }
        if queuesVad(s, .vadSpeechStart) { return false }
        return dropsUnqueuedVad(s)
    }

    private static func idleQuiet(_ s: State) -> Bool {
        !s.muted && !s.userSpeaking && !s.awaitingApproval && !s.interrupted && !s.screenReaderSpeaking && !s.messagePlaying
    }

    private static func earconPending(_ s: State) -> Bool {
        !s.thinkingEarconPlayed && !s.awaitingApproval && !s.interrupted && !s.userSpeaking
    }

    private static func stallPending(_ s: State) -> Bool {
        s.userSpeaking && !holding(s) && canFinalize(s) && !s.partialText.isEmpty && !s.stallFired
    }

    /// The host schedules a one-shot timer from this: the next atMs at which `.deadline` would change state, or nil if none.
    /// Recomputed after every reduce; when the value changes, the old timer is cancelled and rescheduled at the new value. No periodic tick is needed.
    static func nextDeadlineMs(_ s: State) -> Int? {
        if holding(s) {
            guard s.holdSilenceStartMs != nil, s.holdSinceMs != nil else { return nil }
            return holdUntil(s)
        }
        if stallPending(s) { return s.partialChangedAtMs.map { $0 + Constants.partialStallMs } }
        if s.phase == .listening && idleQuiet(s) { return s.lastActivityMs.map { $0 + Constants.idleTimeoutMs } }
        if s.phase == .thinking {
            var at: [Int] = []
            if !s.gateQueue.isEmpty, let gateAt = s.gateAt { at.append(gateAt) }
            if earconPending(s), let since = s.thinkingSinceMs { at.append(since + Constants.thinkingEarconMs) }
            return at.min()
        }
        return nil
    }

    private static func toggleMute(_ s: inout State, _ t: Int, _ fx: inout [Effect]) {
        s.muted.toggle()
        fx.append(.setCaptureMuted(s.muted))
        if s.muted { abandonUtterance(&s, t, &fx) }
    }

    /// Pure function: does not modify its input; returns the new state and the effects to run in order.
    static func reduce(_ current: State, _ event: Event, atMs t: Int) -> (State, [Effect]) {
        if current.phase == .ended { return (current, []) }
        if current.phase == .idle {
            guard case .start = event else { return (current, []) }
        }
        var s = current
        var fx: [Effect] = []
        if case .deadline = event {} else { s.lastActivityMs = t }
        // A dropped event does not change other state, but still records activity time per rules.state (except deadline)
        let dropped = (s, [Effect]())
        var replay: [QueuedVad] = []
        // Position of the final-transcript-failure prompt: not played if the user is already speaking after replay
        var didNotCatchAt: Int?
        /// Position of the empty-result sayAgain / checkLanguage prompt: removed after replay if speaking or waiting for the next sentence
        var missPromptAt: Int?

        if isVadEvent(event) {
            if vadBlocked(s) { return dropped }
            if queuesVad(s, event) {
                // A start immediately followed by a discarded pair cancels out
                if case .vadDiscarded = event, case .vadSpeechStart? = s.pendingVad.last?.event {
                    s.pendingVad.removeLast()
                } else {
                    s.pendingVad.append(QueuedVad(event: event, atMs: t))
                }
                return (s, [])
            }
            if dropsUnqueuedVad(s) { return dropped }
        }

        switch event {
        case .start(let route, let remembers):
            guard s.phase == .idle else { break }
            s.route = route
            s.deviceRemembersNoSpeakerBargeIn = remembers
            s.speakerBargeIn = computeSpeakerBargeIn(s)
            s.phase = .listening
            fx += [.startCapture, .earcon(.start), .haptic(.light)]

        case .vadSpeechStart:
            if let holdId = s.holdUtteranceId {
                fx.append(.continueUtterance(utteranceId: holdId))
                s.continuedUtteranceId = holdId
                s.continuedVoicedMs = s.holdVoicedMs ?? 0
                // On continuation the caption stall timer restarts, so it cannot force an immediate break
                if !s.partialText.isEmpty { s.partialChangedAtMs = t }
                s.holdUtteranceId = nil
                s.holdVoicedMs = nil
                s.holdSilenceStartMs = nil
                s.holdSinceMs = nil
                s.stallFired = false
                s.forcedByTap = false
                break
            }
            if s.userSpeaking { break }
            s.userSpeaking = true
            s.utteranceStartMs = t
            s.notice = nil
            if s.phase == .thinking {
                s.amend = true
                s.reply = .none
                s.gateAt = nil
                s.gateQueue = []
                s.gateCompleted = false
                fx.append(.cancelGeneration)
            }

        case .vadSpeechEnd(let id, let voicedMs):
            if !s.userSpeaking || holding(s) { return dropped }
            if !canFinalize(s) {
                clearUtterance(&s)
                break
            }
            s.holdUtteranceId = id
            // Continuation sentence: speech is summed across segments
            s.holdVoicedMs = (s.continuedVoicedMs ?? 0) + voicedMs
            s.holdSilenceStartMs = t - Constants.vadEndSilenceMs
            s.holdSinceMs = t
            if s.partialText.isEmpty || holdUntil(s) <= t {
                finalize(&s, id, s.holdVoicedMs, t, &fx, silenceStartMs: s.forcedByTap ? nil : s.holdSilenceStartMs)
            }

        case .vadDiscarded:
            if !s.userSpeaking || holding(s) { return dropped }
            // Continuation segment too short and dropped: the previous sentence stays valid and is finalized under its original id
            if let continued = s.continuedUtteranceId, canFinalize(s) {
                finalize(&s, continued, s.continuedVoicedMs, t, &fx, silenceStartMs: s.forcedByTap ? nil : t - Constants.vadEndSilenceMs)
            } else {
                abandonUtterance(&s, t, &fx)
            }

        case .bargeInDetected:
            guard s.phase == .speaking, !s.bargeIn, s.userSpeaking, s.speakerBargeIn else { break }
            s.bargeIn = true
            if !s.playbackStopped { fx.append(.pausePlayback) }

        case .sttPartial(let text):
            if !s.userSpeaking { return dropped }
            if text != s.partialText {
                s.partialText = text
                s.partialChangedAtMs = t
                s.stallFired = false
            }

        case .sttResult(let id, let text):
            guard let awaited = s.awaitedUtteranceId, id == awaited else { return dropped }
            replay = s.pendingVad
            s.pendingVad = []
            s.awaitedUtteranceId = nil
            let empty = units(text).isEmpty
            let echo = !empty && s.utteranceCompared && isEcho(transcript: text, pool: s.spoken).echo
            if s.bargeIn {
                if empty || echo {
                    s.bargeIn = false
                    s.heardPending = false
                    if !s.playbackStopped { fx.append(.resumePlayback(from: .sentenceStart)) }
                    countEcho(&s, &fx)
                    maybeFinish(&s, t, &fx)
                } else {
                    heard(&s, &fx)
                    fx += [.cancelGeneration, .sendMessage(text: text)]
                    toThinking(&s, t)
                    s.reply = .streaming
                    sent(&s)
                }
            } else if s.amend {
                if empty || echo {
                    if echo { fx.append(.nudgeOrb) }
                    regenerate(&s, t, &fx, "")
                } else {
                    heard(&s, &fx)
                    regenerate(&s, t, &fx, text)
                    sent(&s)
                }
            } else if empty {
                let before = fx.count
                miss(&s, t, &fx)
                if fx.count - 2 >= before, case .speakPrompt = fx[fx.count - 2] { missPromptAt = fx.count - 2 }
            } else if echo {
                countEcho(&s, &fx)
                toListening(&s, t, &fx)
            } else {
                heard(&s, &fx)
                fx.append(.sendMessage(text: text))
                s.reply = .streaming
                sent(&s)
            }

        case .sttFailed(let id):
            guard let awaited = s.awaitedUtteranceId, id == awaited else { return dropped }
            replay = s.pendingVad
            s.pendingVad = []
            if s.sttAttempts <= Constants.sttRetries {
                s.sttAttempts += 1
                fx.append(.transcribe(utteranceId: id))
            } else if s.amend {
                regenerate(&s, t, &fx, "")
            } else {
                if s.bargeIn { fx.append(.cancelGeneration) }
                didNotCatchAt = fx.count
                toListening(&s, t, &fx)
            }

        case .replySentence(let text):
            guard s.reply == .streaming, s.phase == .thinking || s.phase == .speaking else { return dropped }
            if gateWaiting(s, t) {
                s.gateQueue.append(text)
                break
            }
            flushGate(&s, t, &fx)
            s.phase = .speaking
            if !s.playbackStopped {
                s.drained = false
                fx.append(.enqueueSpeech(text: text))
            }

        case .sentenceStarted(let text):
            guard s.phase == .speaking else { return dropped }
            s.spoken.append(text)

        case .replyCompleted:
            guard s.reply == .streaming else { return dropped }
            if !s.gateQueue.isEmpty && gateWaiting(s, t) {
                s.gateCompleted = true
                break
            }
            flushGate(&s, t, &fx)
            s.reply = .completed
            if s.phase == .thinking { toListening(&s, t, &fx) } else { maybeFinish(&s, t, &fx) }

        case .playbackDrained:
            guard s.phase == .speaking else { return dropped }
            s.drained = true
            s.playbackEndedAtMs = t
            maybeFinish(&s, t, &fx)

        case .replyFailed(let code):
            guard s.reply == .streaming else { return dropped }
            s.error = true
            s.phase = .ended
            fx.append(.endConversation(reason: .error, code: code))

        case .approvalPending:
            guard !s.awaitingApproval else { break }
            s.awaitingApproval = true
            fx.append(.speakPrompt(.approvalNeeded))

        case .approvalResolved:
            s.awaitingApproval = false

        case .tapOrb:
            if s.awaitingApproval { break }
            if s.muted && s.phase == .listening {
                toggleMute(&s, t, &fx)
            } else if let holdId = s.holdUtteranceId {
                finalize(&s, holdId, s.holdVoicedMs, t, &fx, silenceStartMs: nil)
            } else if s.phase == .listening || (s.phase == .thinking && s.userSpeaking) {
                if s.userSpeaking {
                    s.forcedByTap = true
                    fx.append(.forceEndUtterance)
                }
            } else if s.phase == .thinking {
                if t - (s.thinkingSinceMs ?? 0) >= Constants.listenToThinkTapGuardMs {
                    fx.append(.cancelGeneration)
                    toListening(&s, t, &fx)
                }
            } else if s.phase == .speaking && !s.playbackStopped {
                stopPlayback(&s, t, &fx)
                maybeFinish(&s, t, &fx)
            }

        case .toggleMute:
            toggleMute(&s, t, &fx)

        case .deadline:
            if let holdId = s.holdUtteranceId {
                if t >= holdUntil(s) {
                    finalize(&s, holdId, s.holdVoicedMs, t, &fx, silenceStartMs: s.forcedByTap ? nil : s.holdSilenceStartMs)
                }
            } else if stallPending(s) {
                if t >= (s.partialChangedAtMs ?? 0) + Constants.partialStallMs {
                    s.stallFired = true
                    fx.append(.forceEndUtterance)
                }
            } else if s.phase == .listening {
                if idleQuiet(s) && t - (s.lastActivityMs ?? 0) >= Constants.idleTimeoutMs {
                    s.phase = .ended
                    fx += [.earcon(.end), .haptic(.light), .endConversation(reason: .idle, code: nil)]
                }
            } else if s.phase == .thinking {
                if !s.gateQueue.isEmpty, let gateAt = s.gateAt, t >= gateAt {
                    flushGate(&s, t, &fx)
                } else if earconPending(s) && t - (s.thinkingSinceMs ?? 0) >= Constants.thinkingEarconMs {
                    s.thinkingEarconPlayed = true
                    fx.append(.earcon(.thinking))
                }
            }

        case .interruptionBegan:
            guard !s.interrupted else { break }
            s.interrupted = true
            if s.phase == .speaking && !s.playbackStopped { fx.append(.pausePlayback) }
            fx.append(.pauseCapture)
            abandonUtterance(&s, t, &fx)

        case .interruptionEnded:
            guard s.interrupted else { break }
            s.interrupted = false
            if s.phase == .speaking && !s.playbackStopped { stopPlayback(&s, t, &fx) }
            fx.append(.resumeCapture)
            maybeFinish(&s, t, &fx)

        case .screenReaderSpeaking(let speaking):
            s.screenReaderSpeaking = speaking
            if speaking { abandonUtterance(&s, t, &fx) }

        case .routeChanged(let route):
            let previous = s.route
            s.route = route
            s.speakerBargeIn = computeSpeakerBargeIn(s)
            if !previous.isSpeaker && route.isSpeaker && s.phase == .speaking && !s.playbackStopped {
                stopPlayback(&s, t, &fx)
                maybeFinish(&s, t, &fx)
            }

        case .playMessage(let id):
            guard s.phase == .listening, !s.messagePlaying, !s.interrupted else { return dropped }
            s.messagePlaying = true
            clearUtterance(&s)
            fx += [.pauseCapture, .playMessage(messageId: id)]

        case .messagePlaybackEnded:
            guard s.messagePlaying else { break }
            s.messagePlaying = false
            s.playbackEndedAtMs = t
            fx.append(.resumeCapture)
            if s.phase == .listening { fx.append(.resetVad(playbackEndedAtMs: t)) }

        case .promptStarted(let text):
            guard !s.promptPlaying else { break }
            s.promptPlaying = true
            s.spoken.append(text)
            abandonUtterance(&s, t, &fx)

        case .promptEnded:
            guard s.promptPlaying else { break }
            s.promptPlaying = false
            s.playbackEndedAtMs = t
            if s.phase == .listening { fx.append(.resetVad(playbackEndedAtMs: t)) }

        case .end(let reason):
            if reason == .user && s.userSpeaking { fx.append(.transcribeToDraft) }
            fx += [.earcon(.end), .haptic(.light), .endConversation(reason: reason, code: nil)]
            s.phase = .ended
            s.pendingVad = []
        }
        var out = replay.isEmpty ? (s, fx) : replayVad(s, fx, replay, t)
        if let at = missPromptAt, out.0.userSpeaking || out.0.awaitedUtteranceId != nil {
            // The host plays a prompt, which discards the next sentence being recorded / just ended; if it was not played, the prompt is treated as not given and a later "not heard" may still prompt in this session
            let dropped = out.1[at]
            out.1.removeSubrange(at ..< at + 2)
            out.0.notice = nil
            if case .speakPrompt(.checkLanguage) = dropped { out.0.languageHintShown = false }
        }
        if let at = didNotCatchAt, !out.0.userSpeaking {
            out.1.insert(contentsOf: [.speakPrompt(.didNotCatch), .haptic(.light)], at: at)
        }
        return out
    }

    /// After the transcript settles, queued VAD is replayed: if still waiting for a transcript (retry), it stays as-is; otherwise reduce runs on each event in turn against the new state, with the effects appended in order.
    /// Replayed events keep their original arrival time, so activity time does not go backwards; this event's own time is still recorded.
    private static func replayVad(_ s: State, _ fx: [Effect], _ replay: [QueuedVad], _ t: Int) -> (State, [Effect]) {
        if s.phase == .thinking && s.awaitedUtteranceId != nil {
            var kept = s
            kept.pendingVad = replay
            return (kept, fx)
        }
        var state = s
        var effects = fx
        for queued in replay {
            let (next, more) = reduce(state, queued.event, atMs: queued.atMs)
            state = next
            effects += more
        }
        state.lastActivityMs = t
        return (state, effects)
    }
}
