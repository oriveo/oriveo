import AVFoundation
import Foundation
import os

// MARK: - Protocols

/// Outcome of one sentence of playback.
enum ConversationPlaybackOutcome: Equatable, Sendable {
    case finished
    /// Interrupted by stopPlayback / stop.
    case stopped
    /// Synthesis / decoding / scheduling failed.
    case failed
}

/// Audio pipeline callbacks; all run on the main actor.
protocol ConversationAudioEngineDelegate: AnyObject {
    /// Microphone dBFS for one 20 ms frame (not called while muted or capture is paused); index increases monotonically from start.
    func conversationAudio(didCaptureFrame index: Int, db: Double)
    /// Speech probability for the same frame: the most recent Silero probability attached to this frame; nil when the model is unavailable in this session.
    func conversationAudio(didCaptureFrame index: Int, db: Double, speechProb: Double?)
    /// Playback output level (dBFS), used for the status orb.
    func conversationAudio(didMeasureOutput db: Double)
    /// A sentence actually started to sound (its first buffer has been queued into the player).
    func conversationAudioDidBeginSentence()
    /// The last buffer of a sentence has actually finished playing (dataPlayedBack, already back on the main thread); called before speak / play returns.
    func conversationAudioDidFinishPlayback()
    func conversationAudioInterruptionBegan()
    func conversationAudioInterruptionEnded()
    /// Interruption ended but the system does not recommend resuming (iOS 27 resumptionRecommendation is not shouldResume): the host should end as system.
    func conversationAudioInterruptionEndedWithoutResume()
    /// Capture stalled: rebuild failed after a configuration change, or capture is running (not interrupted or paused) and no tap callback arrived within the watchdog limit (stall);
    /// the host should end as system.
    func conversationAudioCaptureFailed(reason: ConversationCaptureFailure)
    /// Output route changed; oldDeviceUnavailable = headphones unplugged / Bluetooth disconnected.
    func conversationAudio(routeChanged route: VoiceConversationLogic.Route, oldDeviceUnavailable: Bool)
}

/// Reason for a capture stall: stall = no tap callback within the watchdog limit; rebuild = rebuild failed after a configuration change.
enum ConversationCaptureFailure: String, Sendable {
    case stall
    case rebuild
}

/// Real-time recognition entry for one sentence's recording: receives mono PCM blocks on the recording io queue (callers no longer rewrite them, so they can be handed directly to SystemSTTSession.feed).
typealias ConversationLiveSink = @Sendable (AVAudioPCMBuffer) -> Void

extension ConversationAudioEngine {
    /// Implementation that does not change the audio session (smoke / timing stand-in): nothing to prepare.
    func prepareSession() async throws {}

    /// Implementation that does not support real-time frame feeding (smoke / timing stand-in): records only.
    func beginUtterance(fromFrame frame: Int, live: ConversationLiveSink?) { beginUtterance(fromFrame: frame) }
}

extension ConversationAudioEngineDelegate {
    /// Implementation that ignores probability: forwards to the legacy callback that carries only dBFS.
    func conversationAudio(didCaptureFrame index: Int, db: Double, speechProb: Double?) {
        conversationAudio(didCaptureFrame: index, db: db)
    }
    func conversationAudioInterruptionEndedWithoutResume() {}
    func conversationAudioCaptureFailed(reason: ConversationCaptureFailure) {}
    func conversationAudioDidFinishPlayback() {}
}

/// Voice conversation audio pipeline: one engine both captures (voice processing) and plays output (system TTS / cloud audio / prompt tones).
protocol ConversationAudioEngine: AnyObject {
    var delegate: ConversationAudioEngineDelegate? { get set }
    var route: VoiceConversationLogic.Route { get }
    var isSpeakerRoute: Bool { get }

    /// Before starting the engine, configures and activates the audio session on the session serial queue; the main thread only awaits; call start afterward.
    func prepareSession() async throws
    /// Activates the session in the foreground, sets up the engine, installs the tap and starts (called only when the user taps the orb).
    func start() throws
    /// Stops the engine and deactivates the session.
    func stop()

    /// Software mute: samples are discarded; the input node stays on.
    func setCaptureMuted(_ muted: Bool)
    func pauseCapture()
    func resumeCapture()

    /// Starting from frame `frame` (including the lead-in), writes speech into a recording.
    func beginUtterance(fromFrame frame: Int)
    /// Same as above; when `live` is non-nil, the same mono frames (pre-roll first, then later frames) are also fed to it in order (called on the recording io queue).
    func beginUtterance(fromFrame frame: Int, live: ConversationLiveSink?)
    /// Ends the current segment and exports it (same format as dictation, can be handed directly to `STTEngine.transcribe`); returns immediately, and calls back on the main thread once export completes.
    /// No segment in progress, or export failed: calls back nil.
    func finishUtterance(_ completion: @escaping @MainActor @Sendable (RecordingResult?) -> Void)
    func discardUtterance()

    /// Synthesizes one sentence with system TTS and plays it; returns when playback finishes, is stopped, or fails.
    func speak(_ text: String, language: String?) async -> ConversationPlaybackOutcome
    /// Cloud-synthesized audio (fileExtension such as mp3 / wav) is decoded and queued into the same player.
    func play(audio: Data, fileExtension: String) async -> ConversationPlaybackOutcome
    func pausePlayback()
    /// When fromSentenceStart = true, replays from the start of this sentence (resumes after a false interruption).
    func resumePlayback(fromSentenceStart: Bool)
    func stopPlayback()
    func playEarcon(_ earcon: VoiceConversationLogic.Earcon)
}

/// Install / remove of the input node tap (bus 0); production passes through AVAudioEngine.inputNode, unit tests swap in a counting stand-in.
protocol ConversationInputTap: AnyObject {
    func install(bufferSize: AVAudioFrameCount, format: AVAudioFormat?, block: @escaping AVAudioNodeTapBlock)
    func remove()
}

/// Real input node.
final class EngineConversationInputTap: ConversationInputTap {
    private let engine: AVAudioEngine

    init(_ engine: AVAudioEngine) { self.engine = engine }

    func install(bufferSize: AVAudioFrameCount, format: AVAudioFormat?, block: @escaping AVAudioNodeTapBlock) {
        engine.inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format, block: block)
    }

    func remove() { engine.inputNode.removeTap(onBus: 0) }
}

/// Voice processing (VPIO) switch on the input node; production goes straight to
/// AVAudioEngine.inputNode, unit tests swap in a recording double (the simulator has no real VPIO).
protocol ConversationVoiceProcessing: AnyObject {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

/// Real input node voice processing.
final class EngineConversationVoiceProcessing: ConversationVoiceProcessing {
    private let engine: AVAudioEngine

    init(_ engine: AVAudioEngine) { self.engine = engine }

    var isEnabled: Bool { engine.inputNode.isVoiceProcessingEnabled }

    func setEnabled(_ enabled: Bool) throws { try engine.inputNode.setVoiceProcessingEnabled(enabled) }
}

/// Conversation engine aware of the audio session lease: the wrapper hands it the lease after acquiring it, and teardown deactivates the session only while the lease is still the current generation;
/// if a later holder has taken the lease, the wrapper calls tearDownGraph, which only tears the graph down (stops the engine, removes the tap and observers) and leaves the session alone.
protocol SessionLeaseAwareAudio: AnyObject {
    var sessionLease: VoiceAudioSessionOwner.Lease? { get set }
    /// The owner the deactivation decision is based on; nil = not subject to owner-based decisions.
    var sessionOwner: VoiceAudioSessionOwner? { get }
    func tearDownGraph()
}

// MARK: - Pure helpers (unit-testable)

nonisolated enum ConversationAudioMath {
    /// Lower bound in dBFS for an all-zero frame.
    static let silenceDb = -120.0

    static func dbfs<C: Collection>(_ samples: C) -> Double where C.Element == Float {
        guard !samples.isEmpty else { return silenceDb }
        var sum = 0.0
        for sample in samples { sum += Double(sample) * Double(sample) }
        let rms = (sum / Double(samples.count)).squareRoot()
        guard rms > 0 else { return silenceDb }
        return max(silenceDb, 20 * log10(rms))
    }

    /// Fixed noise floor used when mapping AI playback output (and real-time uplink) levels.
    static let aiFloorDb = -50.0

    /// Status-orb level: mapped relative to the noise floor; lights up at 6 dB above the floor and is full scale at 30 dB more above it.
    static func level(db: Double, floorDb: Double) -> Double {
        min(1, max(0, (db - floorDb - 6) / 30))
    }

    static func samplesPerFrame(sampleRate: Double) -> Int {
        max(1, Int((sampleRate * Double(VoiceConversationLogic.Constants.frameMs) / 1000).rounded()))
    }
}

/// Accumulates arbitrarily sized tap buffers into whole 20 ms frames; any tail shorter than a frame is carried over to the next buffer.
nonisolated struct ConversationFrameAccumulator {
    let samplesPerFrame: Int
    private var pending: [Float] = []

    init(sampleRate: Double) {
        samplesPerFrame = ConversationAudioMath.samplesPerFrame(sampleRate: sampleRate)
        pending.reserveCapacity(samplesPerFrame * 2)
    }

    /// Feeds a segment of mono samples and returns the frames that fill up (each frame has samplesPerFrame samples).
    mutating func append(_ samples: [Float]) -> [[Float]] {
        pending.append(contentsOf: samples)
        var frames: [[Float]] = []
        var start = 0
        while pending.count - start >= samplesPerFrame {
            frames.append(Array(pending[start..<(start + samplesPerFrame)]))
            start += samplesPerFrame
        }
        if start > 0 { pending.removeFirst(start) }
        return frames
    }

    mutating func reset() {
        pending.removeAll(keepingCapacity: true)
    }
}

/// Ring buffer of the most recent frames: on speechStart, frames are taken from speechStart − vadPrerollMs.
/// Capacity must cover the lead-in of 300 ms, plus start backtracking (the larger of the speaker-barge-in gate of 300 ms and the model-mode onset backtrack of 1000 ms), plus the main-thread round trip; default 1.7 s.
nonisolated struct ConversationPrerollRing {
    let capacity: Int
    private var storage: [[Float]] = []
    private var head = 0
    /// Frame number of the next frame.
    private(set) var nextIndex = 0

    static let defaultCapacityMs = VoiceConversationLogic.Constants.vadPrerollMs
        + max(VoiceConversationLogic.Constants.bargeInMinSpeechMs, VoiceConversationLogic.Constants.vadModelOnsetBacktrackMs) + 400

    init(capacityFrames: Int = defaultCapacityMs / VoiceConversationLogic.Constants.frameMs) {
        capacity = max(1, capacityFrames)
        storage.reserveCapacity(capacity)
    }

    mutating func push(_ frame: [Float]) {
        if storage.count < capacity {
            storage.append(frame)
        } else {
            storage[head] = frame
            head = (head + 1) % capacity
        }
        nextIndex += 1
    }

    /// Frame number of the earliest frame still in the ring.
    var oldestIndex: Int { nextIndex - storage.count }

    /// From frame number `index` (or from the earliest frame in the ring if index is earlier than it) up to the newest frame.
    func frames(from index: Int) -> [[Float]] {
        let first = max(index, oldestIndex)
        guard first < nextIndex else { return [] }
        return (first..<nextIndex).map { storage[(head + ($0 - oldestIndex)) % storage.count] }
    }

    mutating func reset() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }
}

/// Code-synthesized prompt tone: sine wave, ≤ 250 ms, peak about −18 dBFS, with 10 ms fades at both ends to prevent clicks.
nonisolated enum ConversationEarconSynth {
    static let peakDb = -18.0
    static let fadeMs = 10.0

    /// Each segment: frequency in Hz, duration in ms.
    static func tones(_ earcon: VoiceConversationLogic.Earcon) -> [(hz: Double, ms: Double)] {
        switch earcon {
        case .start: return [(660, 60), (880, 60)]
        case .heard: return [(880, 60)]
        case .thinking: return [(880, 120)]
        case .end: return [(660, 110), (440, 130)]
        }
    }

    static func durationMs(_ earcon: VoiceConversationLogic.Earcon) -> Double {
        tones(earcon).reduce(0) { $0 + $1.ms }
    }

    /// Segment sines keep phase continuous (no fade between segments); the whole buffer gets a linear fade-in / fade-out of fadeMs at both ends.
    static func samples(_ earcon: VoiceConversationLogic.Earcon, sampleRate: Double) -> [Float] {
        let amplitude = pow(10, peakDb / 20)
        let frequencies = tones(earcon).flatMap { tone in
            Array(repeating: tone.hz, count: Int((sampleRate * tone.ms / 1000).rounded()))
        }
        let count = frequencies.count
        let fade = max(1, Int(sampleRate * fadeMs / 1000))
        var phase = 0.0
        var out: [Float] = []
        out.reserveCapacity(count)
        for (index, hz) in frequencies.enumerated() {
            let envelope = min(1, Double(min(index, count - 1 - index)) / Double(fade))
            out.append(Float(amplitude * envelope * sin(phase)))
            phase = (phase + 2 * .pi * hz / sampleRate).truncatingRemainder(dividingBy: 2 * .pi)
        }
        return out
    }
}

// MARK: - Capture core (audio thread)

/// Counting and generation check for the real-time downlink `.dataPlayedBack` callback → onPlaybackDrained (used on the main thread; does not touch AVAudio objects, so it is unit-testable).
nonisolated struct RealtimePlaybackDrain {
    enum Outcome: Equatable {
        /// Callbacks from an older generation arriving after playback was stopped / rescheduled: not counted.
        case stale
        /// Already counted; drained = this block took the queue from non-empty to empty with no new block waiting to be scheduled, so playback-finished is reported once.
        case counted(drained: Bool)
    }

    /// Number of frames already queued into the player and not yet finished playing.
    private(set) var queuedFrames: AVAudioFramePosition = 0

    mutating func scheduled(frames: AVAudioFramePosition) {
        queuedFrames += frames
    }

    /// One block finished playing. generation is the generation when this block was scheduled; currentGeneration is the generation when the callback arrived.
    mutating func playedBack(
        frames: AVAudioFramePosition, generation: Int, currentGeneration: Int, pendingEmpty: Bool
    ) -> Outcome {
        guard generation == currentGeneration else { return .stale }
        let before = queuedFrames
        queuedFrames = max(0, queuedFrames - frames)
        return .counted(drained: before > 0 && queuedFrames == 0 && pendingEmpty)
    }

    /// Stop playback: clears the queue count (the caller advances the generation at the same time).
    mutating func reset() {
        queuedFrames = 0
    }
}

/// Block count for a cascaded sentence: adds one when a block is scheduled, subtracts one when `.dataPlayedBack` comes back (used on the main thread; does not touch AVAudio objects, so it is unit-testable).
nonisolated struct SentencePlaybackCount {
    /// Number of blocks already queued into the player and not yet finished playing.
    private(set) var outstanding = 0

    mutating func scheduled() {
        outstanding += 1
    }

    /// One block finished playing. generation is the generation when this block was scheduled; currentGeneration is the generation when the callback arrived (callbacks from an older generation are not counted).
    /// true = synthesis has ended, no blocks are waiting to be scheduled, and this is the last block: the playback-finished moment is now (already includes output latency, no offset added).
    mutating func playedBack(generation: Int, currentGeneration: Int, synthesisDone: Bool, pendingEmpty: Bool) -> Bool {
        guard generation == currentGeneration, outstanding > 0 else { return false }
        outstanding -= 1
        return outstanding == 0 && synthesisDone && pendingEmpty
    }

    /// Stop / reschedule: cleared to zero (the caller advances the generation at the same time).
    mutating func reset() {
        outstanding = 0
    }
}

/// Capture frame watchdog: timed while capture is running, not interrupted, and not paused; measured from the most recent tap callback (or the timing start, whichever is later)
/// exceeding stallLimitMs marks a stall. No resident timer: the host only sleeps until dueMs and checks then; nothing wakes while not timing.
struct ConversationFrameWatchdog: Equatable {
    static let stallLimitMs = 1500
    /// Timing start: set to the current time on start / interruption recovery / rebuild / capture resume; nil = not timing (not running, interrupted, or paused).
    private(set) var armedAtMs: Int?

    mutating func arm(nowMs: Int) { armedAtMs = nowMs }
    mutating func disarm() { armedAtMs = nil }

    /// lastFrameMs = time of the most recent tap callback (nil = none yet); callbacks earlier than the timing start do not count.
    func stalled(nowMs: Int, lastFrameMs: Int?) -> Bool {
        guard let armedAtMs else { return false }
        let since = max(armedAtMs, lastFrameMs ?? armedAtMs)
        return nowMs - since > Self.stallLimitMs
    }

    /// Earliest time a stall can be judged (= start point + stallLimitMs + 1); nil when not timing.
    func dueMs(lastFrameMs: Int?) -> Int? {
        guard let armedAtMs else { return nil }
        return max(armedAtMs, lastFrameMs ?? armedAtMs) + Self.stallLimitMs + 1
    }
}

/// The tap thread records the time of the latest callback; the main thread reads it at low frequency (watchdog). The clock is injectable (for tests).
nonisolated final class ConversationTapClock: @unchecked Sendable {
    private let lock = NSLock()
    private var lastMs: Int?
    let now: @Sendable () -> Int

    static let uptimeMs: @Sendable () -> Int = { Int(ProcessInfo.processInfo.systemUptime * 1000) }

    init(now: @escaping @Sendable () -> Int) { self.now = now }

    func mark() {
        let now = now()
        lock.withLock { lastMs = now }
    }

    var last: Int? { lock.withLock { lastMs } }
}

/// Frame accumulation and lead-in ring on the tap thread; commands from the main actor enter through the lock.
/// Creating / writing / closing / deleting the recording writer happens only on the `io` serial queue; callers only dispatch (the result of closing is delivered back on the main thread).
nonisolated final class ConversationCaptureCore: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.oriveo", category: "voice-conversation")
    private let lock = NSLock()
    private var accumulator = ConversationFrameAccumulator(sampleRate: 48_000)
    private var ring = ConversationPrerollRing()
    private var monoFormat: AVAudioFormat?
    /// Under the lock: whether a sentence is currently being recorded (decides whether tap frames should be dispatched for writing).
    private var recording = false
    /// Under the lock: the real-time recognition entry for this sentence (fed on io in the same batch and order as the disk write); removed when the sentence ends / is discarded / changes format.
    private var live: ConversationLiveSink?
    private let io: DispatchQueue
    /// Read and written only on `io`.
    private var writer: RecordingWriter?
    private var muted = false
    private var paused = false
    private let directory: URL
    /// Real-time uplink: when enabled, each tap block is mixed to mono and resampled once to the uplink rate declared by the transport, as PCM16.
    private var realtimeEnabled = false
    private var uplink: RealtimeUplinkResampler?
    private var uplinkSampleRate = RealtimePCM.sampleRate
    private var sampleRate = 48_000.0
    /// Lock for the voice-model state set (not nested with `lock`): taken only for inference on the tap thread and for loading on io; the main thread never waits on it.
    private let speechLock = NSLock()
    /// Under `lock`: model configuration suspended by the main thread's configure, executed under speechLock before the tap thread's next inference block.
    private var pendingSpeechConfig: SpeechConfig?
    /// Under speechLock: the most recent Silero speech probability (0 if no block has been produced; nil if the model is unavailable or inference failed). Frames that fill up carry this value.
    private var speechProb: Double? = 0
    /// Under speechLock: the capture-frame → 16 kHz resampler (records the source sample rate; rebuilding at the same rate does not replace it) and the inference instance.
    private var speechResampler: SpeechResampler?
    private var speechResamplerRate: Double?
    private var speechModel: SileroVad?

    /// io is injectable (tests suspend the queue to verify the main thread does not wait on it).
    init(directory: URL, io: DispatchQueue = DispatchQueue(label: "com.oriveo.voice-conversation.recording")) {
        self.directory = directory
        self.io = io
    }

    /// New input format (after start / configuration change): frame numbers continue; the ring and any in-progress recording are dropped.
    /// newSession = session start: voice-model state / context reset to zero (only once per session);
    /// rebuilds on route / format change pass false: model state continues, and the resampler is replaced only if the sample rate changed.
    func configure(sampleRate: Double, newSession: Bool = true) {
        lock.lock(); defer { lock.unlock() }
        // Does not take speechLock: the tap thread may be holding the lock for inference. Several unexecuted configuration calls are merged; one is enough for session start.
        pendingSpeechConfig = SpeechConfig(
            sampleRate: sampleRate, newSession: newSession || (pendingSpeechConfig?.newSession ?? false)
        )
        accumulator = ConversationFrameAccumulator(sampleRate: sampleRate)
        let next = ring.nextIndex
        ring = ConversationPrerollRing()
        for _ in 0..<next { ring.push([]) }
        ring.reset()
        monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
        recording = false
        live = nil
        io.async { self.writer = nil }
        self.sampleRate = sampleRate
        uplink = realtimeEnabled
            ? RealtimeUplinkResampler(sourceSampleRate: sampleRate, targetSampleRate: uplinkSampleRate) : nil
    }

    /// Enables / disables real-time uplink; when enabled, builds the resampler at the uplink rate declared by the transport. Returns false = a resampler cannot be built at the current input rate.
    @discardableResult
    func setRealtime(_ enabled: Bool, uplinkSampleRate: Double = RealtimePCM.sampleRate) -> Bool {
        lock.lock(); defer { lock.unlock() }
        realtimeEnabled = enabled
        if enabled { self.uplinkSampleRate = uplinkSampleRate }
        uplink = enabled
            ? RealtimeUplinkResampler(sourceSampleRate: sampleRate, targetSampleRate: self.uplinkSampleRate) : nil
        return !enabled || uplink != nil
    }

    /// Real-time is enabled but the resampler is missing (it could not be built after the input rate changed).
    var realtimeBroken: Bool {
        lock.lock(); defer { lock.unlock() }
        return realtimeEnabled && uplink == nil
    }

    func setMuted(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        muted = value
        accumulator.reset()
    }

    func setPaused(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        paused = value
        accumulator.reset()
    }

    /// Returns the (frame number, dBFS) pairs that fill up, the PCM16 for real-time uplink (at the uplink rate declared by the transport; nil if real-time is off or nothing was produced),
    /// and the speech probabilities attached to those frames (the most recent block's inference result; nil when the model is unavailable).
    func consume(_ buffer: AVAudioPCMBuffer) -> (frames: [(Int, Double)], uplink: Data?, speechProb: Double?) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return ([], nil, nil) }
        let count = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: count)
        for channel in 0..<channelCount {
            let source = channels[channel]
            for index in 0..<count { mono[index] += source[index] }
        }
        if channelCount > 1 {
            let scale = 1 / Float(channelCount)
            for index in 0..<count { mono[index] *= scale }
        }
        let accepted: (frames: [(Int, Double)], uplink: Data?, config: SpeechConfig?)? = {
            lock.lock(); defer { lock.unlock() }
            guard !muted, !paused else { return nil }
            let config = pendingSpeechConfig
            pendingSpeechConfig = nil
            var out: [(Int, Double)] = []
            var recorded: [[Float]] = []
            for frame in accumulator.append(mono) {
                let index = ring.nextIndex
                ring.push(frame)
                if recording { recorded.append(frame) }
                out.append((index, ConversationAudioMath.dbfs(frame[...])))
            }
            // Dispatch under the lock: keeps ordering with the dispatches of begin / finish / discard.
            if !recorded.isEmpty, let monoFormat {
                let frames = recorded
                let live = self.live
                io.async { self.write(frames, format: monoFormat, live: live) }
            }
            return (out, uplink?.convert(mono), config)
        }()
        guard let accepted else { return ([], nil, nil) }
        // The voice model infers synchronously on the calling thread (tap callback): frames carry the most recent block's probability, which includes this block.
        return (accepted.frames, accepted.uplink, feedSpeechModel(mono, applying: accepted.config))
    }

    /// One model configuration suspended by the main thread and executed on the tap thread.
    private struct SpeechConfig {
        let sampleRate: Double
        let newSession: Bool
    }

    /// Session start: rebuilds the resampler and clears the model state / context (the first load happens on io; until it is ready, probabilities are attached as 0, and become nil if loading fails);
    /// rebuild: replaces the resampler only if the sample rate changed; model state continues.
    /// Called under speechLock, on the tap thread.
    private func configureSpeechModel(sampleRate: Double, newSession: Bool) {
        if newSession || speechResamplerRate != sampleRate || speechResampler == nil {
            speechResampler = SpeechResampler(sourceSampleRate: sampleRate)
            speechResamplerRate = sampleRate
        }
        guard newSession else {
            if speechResampler == nil { speechProb = nil }
            return
        }
        guard let speechModel else {
            speechProb = speechResampler == nil ? nil : 0
            io.async { self.loadSpeechModel() }
            return
        }
        speechModel.reset()
        speechProb = speechResampler == nil ? nil : 0
    }

    /// On io: loads the inference instance (only once per session); after it is installed, starts from the cleared state; if loading fails, probabilities become nil and the host switches to energy-based judgement.
    private func loadSpeechModel() {
        speechLock.lock()
        let loaded = speechModel != nil
        speechLock.unlock()
        guard !loaded else { return }
        let model: SileroVad?
        do {
            model = try SileroVad()
        } catch {
            model = nil
            let reason = SpeechModelLoad.reason(of: error)
            Self.logger.error("speech model load failed: \(reason, privacy: .public)")
        }
        speechLock.lock(); defer { speechLock.unlock() }
        guard speechModel == nil else { return }
        speechModel = model
        speechProb = model != nil && speechResampler != nil ? 0 : nil
    }

    /// On the calling thread: resamples a block of samples to 16 kHz for the model and returns the most recent block's probability; once inference errors, no more probabilities are given in this session.
    /// When config is non-nil: first applies the configuration suspended by the main thread (clears state / replaces the resampler), then runs inference.
    private func feedSpeechModel(_ samples: [Float], applying config: SpeechConfig?) -> Double? {
        speechLock.lock(); defer { speechLock.unlock() }
        if let config { configureSpeechModel(sampleRate: config.sampleRate, newSession: config.newSession) }
        guard let speechModel, let speechResampler else { return speechProb }
        var failed = false
        speechResampler.convert(samples) { chunk in
            guard !failed else { return }
            do { try speechModel.feed(chunk) } catch { failed = true }
        }
        if failed {
            self.speechModel = nil
            Self.logger.error("speech model inference failed")
        }
        speechProb = failed ? nil : Double(speechModel.latestProb)
        return speechProb
    }

    func beginUtterance(fromFrame frame: Int, live: ConversationLiveSink? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard let monoFormat else { return }
        let url = directory.appendingPathComponent("\(UUID().uuidString).aac")
        let preroll = ring.frames(from: frame)
        recording = true
        self.live = live
        io.async {
            self.writer = try? RecordingWriter(url: url, inputFormat: monoFormat)
            self.write(preroll, format: monoFormat, live: live)
        }
    }

    /// Returns immediately: the close is queued after writes already dispatched on `io`, and the result is delivered back on the main thread.
    /// When not recording, the queue is not touched; calls back nil synchronously on the calling (main) thread, which lets the caller decide there is no draft.
    func finishUtterance(_ completion: @escaping @MainActor @Sendable (RecordingResult?) -> Void) {
        lock.lock()
        guard recording else {
            lock.unlock()
            // Callback outside the lock: completion may call back into this object.
            MainActor.assumeIsolated { completion(nil) }
            return
        }
        recording = false
        live = nil
        // Dispatch under the lock: queued after the last write already dispatched by consume.
        io.async {
            let writer = self.writer
            self.writer = nil
            let result = writer.flatMap { try? $0.close() }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
        lock.unlock()
    }

    func discardUtterance() {
        lock.lock(); defer { lock.unlock() }
        guard recording else { return }
        recording = false
        live = nil
        io.async {
            guard let writer = self.writer else { return }
            self.writer = nil
            _ = try? writer.close()
            try? FileManager.default.removeItem(at: writer.url)
        }
    }

    /// Only called on `io`. If the disk write has failed (writer removed), real-time recognition still gets fed: it does not depend on the file.
    private func write(_ frames: [[Float]], format monoFormat: AVAudioFormat, live: ConversationLiveSink?) {
        guard writer != nil || live != nil, !frames.isEmpty else { return }
        let total = frames.reduce(0) { $0 + $1.count }
        guard total > 0, let buffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(total)),
              let target = buffer.floatChannelData?[0]
        else { return }
        var offset = 0
        for frame in frames {
            for sample in frame {
                target[offset] = sample
                offset += 1
            }
        }
        buffer.frameLength = AVAudioFrameCount(total)
        // After this, the buffer is no longer rewritten: real-time recognition holds it directly (SystemSTTSession.feed does not copy).
        live?(buffer)
        guard let writer else { return }
        do {
            try writer.append(buffer)
        } catch {
            self.writer = nil
        }
    }
}

// MARK: - VPIO implementation

/// AVAudioEngine + voice processing: system TTS goes through `write` into the same player (AEC needs the reference signal); cloud audio is decoded and played on the same path.
final class VPIOConversationAudioEngine: ConversationAudioEngine, SessionLeaseAwareAudio {
    weak var delegate: ConversationAudioEngineDelegate?

    private static let logger = Logger(subsystem: "com.oriveo", category: "voice-conversation")
    private let session: AVAudioSession
    private let center: NotificationCenter
    private let speechRate: () -> Double
    private let engine: AVAudioEngine
    private let player = AVAudioPlayerNode()
    private let earconPlayer = AVAudioPlayerNode()
    private let synthesizer = AVSpeechSynthesizer()
    private let capture: ConversationCaptureCore
    private var playerFormat: AVAudioFormat?
    private var earconFormat: AVAudioFormat?
    private var running = false
    private var observers: [NSObjectProtocol] = []
    /// Audio session ownership; nil = not subject to ownership checks (deactivation is unconditional, as before).
    private let owner: VoiceAudioSessionOwner?
    private let deactivateSession: (AVAudioSession) -> Void
    private let inputTap: ConversationInputTap
    private let voiceProcessing: ConversationVoiceProcessing
    private let startEngine: (AVAudioEngine) throws -> Void
    /// Serial queue for session state changes.
    private let coordinator: AudioSessionCoordinator
    /// Engine sequence number: distinguishes, in logs, which of several VPIO engines in the same process came first.
    private let serial: Int
    private static var nextSerial = 0
    /// Conversation lease obtained by the wrapper; when there is an owner, the session is deactivated only if this lease is still the current one.
    var sessionLease: VoiceAudioSessionOwner.Lease?
    /// prepareSession has already configured and activated the session on the coordinator; start depends on it, and this instance clears it on teardown.
    private var sessionPrepared = false
    /// Interruption generation: incremented on each began; when a recovery Task returns and the generation has changed, the interruption happened again meanwhile and the old recovery is void.
    private var interruptionGeneration = 0
    /// Between interruption start and successful recovery: the watchdog does not time.
    private var captureInterrupted = false
    /// Between pauseCapture and resumeCapture: the watchdog does not time.
    private var capturePaused = false
    private var watchdog = ConversationFrameWatchdog()
    private let tapClock: ConversationTapClock
    /// Watchdog sleep (milliseconds, injectable): only sleeps until the moment a stall can be judged while timing; does not wake while not timing.
    private let watchdogSleep: (Int) async -> Void
    /// The watchdog check task (exists only while timing); cancelled when timing stops / on teardown.
    private var watchdogTask: Task<Void, Never>?

    /// start called without prepareSession first: the main thread no longer activates the session itself, so the engine start is refused outright.
    struct SessionNotPrepared: Error {}
    /// If the engine is not running, capture is started.
    struct NotRunning: Error {}
    /// Whether the input node is in the graph (input tap installed, voice processing on); false when only playback is started (speech-prompt-only start), and the input node is not touched.
    private var captureActive = false

    /// The sentence currently playing: buffers already received (for replaying from the start on resume), number of blocks queued but not yet finished, and whether synthesis has ended.
    private final class Sentence {
        var buffers: [AVAudioPCMBuffer] = []
        var pendingChunk: [AVAudioPCMBuffer] = []
        var pendingFrames: AVAudioFrameCount = 0
        var count = SentencePlaybackCount()
        var synthesisDone = false
        var began = false
        var continuation: CheckedContinuation<ConversationPlaybackOutcome, Never>?
    }

    private var sentence: Sentence?
    /// Incremented on each reschedule / stop; completion callbacks of buffers from an older generation are no longer counted.
    private var scheduleGeneration = 0
    private var paused = false

    // Real-time: uplink callback, interruption callback, and downlink queue.
    /// Uplink callback, read on the audio thread; relayed through a lock (set / cleared by the main thread).
    private let realtimeFrame = RealtimeFrameRelay()
    private var realtimeInterruption: (() -> Void)?
    /// Downlink playback-finished callback (RealtimeAudioIO.onPlaybackDrained).
    private var realtimeDrained: (() -> Void)?
    /// Playback output level callback (RealtimeAudioIO.onOutputLevel).
    private var realtimeOutputLevel: ((Double) -> Void)?
    /// Where route changes go in real-time mode (the uplink gate decides immediately by the new route); the same routeChange observer as the delegate.
    private var realtimeRouteChanged: ((VoiceConversationLogic.Route) -> Void)?

    /// Playback count for one downlink item: base = frames frozen when playback was previously stopped; segments = the continuous segments scheduled on the current player timeline.
    private final class RealtimeItem {
        var baseFrames: AVAudioFramePosition = 0
        var segments: [(start: AVAudioFramePosition, frames: AVAudioFramePosition)] = []
        var playedBackFrames: AVAudioFramePosition = 0
    }

    private var realtimeItems: [String: RealtimeItem] = [:]
    private var realtimePending: [(buffer: AVAudioPCMBuffer, itemId: String)] = []
    private var realtimePendingFrames: AVAudioFrameCount = 0
    /// Frames queued into the player and not yet finished, and the playback-finished determination.
    private var realtimeDrain = RealtimePlaybackDrain()
    /// End of the scheduled queue on the player timeline.
    private var realtimeQueueEnd: AVAudioFramePosition = 0
    private var realtimeFlushWork: DispatchWorkItem?
    /// Downlink reference-level record: written at scheduling time; the uplink gate reads it on the audio thread by playhead.
    private let realtimeReference = RealtimePlaybackReference()

    /// Session configuration passed to setCategory at prepareSession; unit tests read the same one.
    static let sessionConfiguration: (
        category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions
    ) = (.playAndRecord, .voiceChat, [.defaultToSpeaker, .allowBluetoothHFP])

    init(
        session: AVAudioSession = .sharedInstance(),
        notificationCenter: NotificationCenter = .default,
        speechRate: @escaping () -> Double = { VoiceEngineSettings().speechRate },
        directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("voice-conversation", isDirectory: true),
        owner: VoiceAudioSessionOwner? = nil,
        /// nil = queued deactivation via the coordinator, with others notified (does not block the main thread).
        deactivateSession: ((AVAudioSession) -> Void)? = nil,
        inputTap: ((AVAudioEngine) -> ConversationInputTap)? = nil,
        voiceProcessing: ((AVAudioEngine) -> ConversationVoiceProcessing)? = nil,
        startEngine: @escaping (AVAudioEngine) throws -> Void = { try $0.start() },
        coordinator: AudioSessionCoordinator = .shared,
        watchdogClock: @escaping @Sendable () -> Int = ConversationTapClock.uptimeMs,
        watchdogSleep: @escaping (Int) async -> Void = { try? await Task.sleep(for: .milliseconds($0)) }
    ) {
        self.tapClock = ConversationTapClock(now: watchdogClock)
        self.watchdogSleep = watchdogSleep
        self.session = session
        self.coordinator = coordinator
        self.owner = owner
        self.deactivateSession = deactivateSession ?? { _ in coordinator.deactivate(notifyOthers: true) }
        self.center = notificationCenter
        self.speechRate = speechRate
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.capture = ConversationCaptureCore(directory: directory)
        let engine = AVAudioEngine()
        self.engine = engine
        self.inputTap = inputTap?(engine) ?? EngineConversationInputTap(engine)
        self.voiceProcessing = voiceProcessing?(engine) ?? EngineConversationVoiceProcessing(engine)
        self.startEngine = startEngine
        Self.nextSerial += 1
        self.serial = Self.nextSerial
    }

    var route: VoiceConversationLogic.Route {
        Self.route(of: session.currentRoute)
    }

    var isSpeakerRoute: Bool { route.isSpeaker }

    /// Pure mapping, callable from any thread (the real-time transport samples it when opening a connection in the background). Per the voice-conversation.v1 outputRoute contract:
    /// Bluetooth takes priority; routes known to be at the ear (earpiece, headphones) count as headphones; everything else (car, AirPlay, HDMI, line out, USB) drives the speakers in the room and counts as speaker.
    nonisolated static func route(of description: AVAudioSessionRouteDescription) -> VoiceConversationLogic.Route {
        route(ofOutputs: description.outputs.map(\.portType))
    }

    nonisolated static func route(ofOutputs ports: [AVAudioSession.Port]) -> VoiceConversationLogic.Route {
        if ports.contains(where: { [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains($0) }) { return .bluetooth }
        if ports.contains(where: { [.headphones, .builtInReceiver].contains($0) }) { return .headphones }
        return .speaker
    }

    // MARK: Lifecycle

    /// Before activation, sets the category per sessionConfiguration, and enables haptics and system sounds for recording sessions
    /// (the conversation is recording throughout, otherwise the reducer's haptics would be swallowed by the system); ignored when unsupported by the system.
    static let preparedSessionConfiguration = AudioSessionCoordinator.Configuration(
        category: sessionConfiguration.category, mode: sessionConfiguration.mode,
        options: sessionConfiguration.options, allowHapticsDuringRecording: true
    )

    /// On the coordinator queue: configure → activate → IO buffer 0.02; the IO buffer is a preference value, and failing to set it does not affect the conversation (consistent with the original try? in start).
    func prepareSession() async throws {
        guard !running else { return }
        try await coordinator.perform([.configure(Self.preparedSessionConfiguration), .activate])
        try? await coordinator.perform([.preferIOBufferDuration(0.02)])
        sessionPrepared = true
    }

    func start() throws {
        try start(capturing: true)
    }

    /// capturing = false: starts playback only (does not enable voice processing or install the input tap; the system's microphone indicator does not turn on).
    private func start(capturing: Bool) throws {
        guard !running else { return }
        guard sessionPrepared else { throw SessionNotPrepared() }
        Self.logger.info("voice conversation ioBufferDuration=\(self.session.ioBufferDuration, privacy: .public)")
        do {
            if capturing { try enableVoiceProcessing() }
            engine.attach(player)
            engine.attach(earconPlayer)
            captureActive = capturing
            try configureGraph()
            running = true
            observe()
            captureInterrupted = false
            capturePaused = false
            rearmWatchdog()
        } catch {
            teardown()
            throw error
        }
    }

    func stop() {
        guard running else {
            // Session prepared but the engine did not start: clear the flag and deactivate, so the active session is not left to the system.
            // A lease already released (no holder) is also deactivated; only when a new session has already taken the lease is it left to that session.
            if sessionPrepared {
                sessionPrepared = false
                if ownsSession || owner?.current == nil { deactivateSession(session) }
            }
            return
        }
        stopPlayback()
        earconPlayer.stop()
        teardown()
    }

    /// Tears down the graph only: stops playback and the engine, removes the tap and observers; does not deactivate the session and does not close VPIO (the session has passed to a later holder;
    /// VPIO is effectively a process-wide singleton, so closing it would also cancel echo cancellation for the later holder).
    func tearDownGraph() {
        guard running else { return }
        stopPlayback()
        earconPlayer.stop()
        teardown(ownTeardown: false)
    }

    var sessionOwner: VoiceAudioSessionOwner? { owner }

    /// Without an owner, behaves as before; with an owner, the session is held only if this engine's lease is still the current lease.
    private var ownsSession: Bool {
        guard let owner else { return true }
        guard let sessionLease else { return false }
        return owner.current == sessionLease
    }

    #if DEBUG
    /// Unit tests only: does not build a real graph; enters the running state directly and registers observers, to verify the wrap-up of stop / tearDownGraph.
    func enterRunningStateForTesting() {
        running = true
        captureActive = true
        observe()
    }

    var isEngineRunningForTesting: Bool { engine.isRunning }
    /// Unit tests only: iOS 27's resumption-advice notification carries a ResumptionContext built by the system, which tests cannot construct, so this goes straight to the resume entry.
    /// Returns the resume Task (nil when already torn down or no longer holding the session), so tests can await it instead of counting coordinator drains.
    @discardableResult
    func interruptionEndedForTesting() -> Task<Void, Never>? { interruptionEnded() }
    /// Unit tests only: the configuration-change notification's object is the private engine, so this goes straight to the rebuild entry.
    func rebuildForTesting() { rebuild() }
    var observerCountForTesting: Int { observers.count }
    #endif

    /// ownTeardown = this instance tears down itself (lease is still current / no owner): closes VPIO and deactivates the session;
    /// a teardown that was superseded (tearDownGraph, or a stop whose lease is no longer current) only tears down the graph; VPIO and the session are left to the later holder.
    private func teardown(ownTeardown: Bool = true) {
        let releasesSession = ownTeardown && ownsSession
        running = false
        sessionPrepared = false
        watchdogTask?.cancel()
        watchdogTask = nil
        watchdog.disarm()
        for token in observers { center.removeObserver(token) }
        observers = []
        if captureActive { inputTap.remove() }
        captureActive = false
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.stop()
        capture.discardUtterance()
        if releasesSession {
            try? voiceProcessing.setEnabled(false)
            logVoiceProcessing("disable")
            deactivateSession(session)
        } else {
            logVoiceProcessing("keep (superseded teardown)")
        }
    }

    /// Installs the tap and connects the player according to the current input format, then starts; repeated after a configuration change. When only playing (captureActive = false), the input node is not touched.
    /// newCaptureSession: nil = session start before entering the running state at start; for a rebuild after configuration change, running is already true and model state continues;
    /// starting capture late passes true (capture starts here).
    private func configureGraph(newCaptureSession: Bool? = nil) throws {
        engine.mainMixerNode.removeTap(onBus: 0)
        if captureActive { installInputTap(newCaptureSession: newCaptureSession ?? !running) }
        if let playerFormat { engine.connect(player, to: engine.mainMixerNode, format: playerFormat) }
        let earcon = earconFormat ?? AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)
        earconFormat = earcon
        engine.connect(earconPlayer, to: engine.mainMixerNode, format: earcon)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            let db = ConversationAudioMath.dbfs(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
            DispatchQueue.main.async {
                guard let self else { return }
                self.delegate?.conversationAudio(didMeasureOutput: db)
                // Real-time downlink playback levels are also taken from the real output here.
                self.realtimeOutputLevel?(db)
            }
        }
        engine.prepare()
        try startEngine(engine)
    }

    /// Reinstalls the input tap according to the current input format (capture frames go out as VAD frames and real-time uplink).
    private func installInputTap(newCaptureSession: Bool) {
        let input = engine.inputNode
        inputTap.remove()
        let format = input.outputFormat(forBus: 0)
        capture.configure(sampleRate: format.sampleRate, newSession: newCaptureSession)
        let core = capture
        let relay = realtimeFrame
        let tapClock = tapClock
        inputTap.install(bufferSize: 1024, format: format) { [weak self] buffer, _ in
            tapClock.mark()
            let (frames, uplink, speechProb) = core.consume(buffer)
            // Real-time uplink goes straight to the transport on the audio thread, without bouncing through the main thread; only VAD frames return to the main thread.
            if let uplink { relay.deliver(uplink) }
            guard !frames.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                for (index, db) in frames {
                    self.delegate?.conversationAudio(didCaptureFrame: index, db: db, speechProb: speechProb)
                }
            }
        }
    }

    /// Enables voice processing and turns off ducking of others' audio; must be called while the engine is stopped.
    private func enableVoiceProcessing() throws {
        try voiceProcessing.setEnabled(true)
        logVoiceProcessing("enable")
        engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration =
            .init(enableAdvancedDucking: false, duckingLevel: .min)
    }

    private func logVoiceProcessing(_ action: StaticString) {
        let enabled = voiceProcessing.isEnabled
        Self.logger.info(
            "voice processing \(String(describing: action), privacy: .public) engine=\(self.serial, privacy: .public) isVoiceProcessingEnabled=\(enabled, privacy: .public)"
        )
    }

    /// Subscribes to interruption / route / configuration changes; internal so unit tests can verify directly through an injected center (production only calls this from start).
    func observe() {
        if #available(iOS 27, *) {
            observers.append(center.addObserver(
                forName: AVAudioSession.didBecomeInactiveNotification, object: session, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.interruptionBegan() }
            })
            observers.append(center.addObserver(
                forName: AVAudioSession.resumptionRecommendationNotification, object: session, queue: .main
            ) { [weak self] note in
                let context = note.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext
                let resume = context?.recommendation == .shouldResume
                MainActor.assumeIsolated {
                    if resume {
                        self?.interruptionEnded()
                    } else {
                        self?.delegate?.conversationAudioInterruptionEndedWithoutResume()
                    }
                }
            })
        } else {
            observers.append(center.addObserver(
                forName: AVAudioSession.interruptionNotification, object: session, queue: .main
            ) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let type = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
                MainActor.assumeIsolated {
                    switch type {
                    case .began: self?.interruptionBegan()
                    case .ended: self?.interruptionEnded()
                    default: break
                    }
                }
            })
        }
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            MainActor.assumeIsolated {
                guard let self else { return }
                let route = self.route
                self.delegate?.conversationAudio(routeChanged: route, oldDeviceUnavailable: reason == .oldDeviceUnavailable)
                self.realtimeRouteChanged?(route)
            }
        })
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        })
    }

    private func interruptionBegan() {
        interruptionGeneration += 1
        captureInterrupted = true
        rearmWatchdog()
        pausePlayback()
        delegate?.conversationAudioInterruptionBegan()
        realtimeInterruption?()
    }

    /// Interruption ended: if already torn down or no longer holding the session, do not activate; otherwise reactivate on the coordinator queue, return to the main thread to confirm the generation is unchanged,
    /// still running and the lease still current, then start the engine; an expired generation only gives up (the session passes to the next recovery and is not deactivated);
    /// if already stopped, the just-activated session is deactivated (checked before the generation; superseded cases excepted); if superseded, it only gives up. Neither starts the engine nor reports recovery.
    /// Reactivation failure or engine start error: reports "interruption ended but not recovered"; the host ends as interruption, and does not report recovered.
    @discardableResult
    private func interruptionEnded() -> Task<Void, Never>? {
        guard running, ownsSession else { return nil }
        let generation = interruptionGeneration
        return Task { [weak self, coordinator] in
            var reactivated = true
            do {
                try await coordinator.activate(nil)
            } catch {
                reactivated = false
                Self.logger.error("voice conversation reactivate after interruption failed: \(error.localizedDescription, privacy: .public)")
            }
            // Engine already released: no lease to confirm against, so the session is left alone (it may have passed to a later holder).
            guard let self else { return }
            // Stopped during activation: no next recovery will take over, so the just-activated session is deactivated here (also when the lease was released and no one holds it),
            // checked before the generation: a began before stop would expire the generation, otherwise the session would be left active.
            guard self.running else {
                if reactivated, self.ownsSession || self.owner?.current == nil {
                    coordinator.deactivate(notifyOthers: true)
                }
                return
            }
            // Generation expired: another began / ended happened meanwhile; the next recovery takes over the just-activated session, so this only gives up.
            guard self.interruptionGeneration == generation else { return }
            // Superseded: the session is not deactivated; it has passed to the later holder.
            guard self.ownsSession else { return }
            guard reactivated else {
                self.delegate?.conversationAudioInterruptionEndedWithoutResume()
                return
            }
            do {
                if !self.engine.isRunning { try self.engine.start() }
            } catch {
                Self.logger.error("voice conversation resume after interruption failed: \(error.localizedDescription, privacy: .public)")
                self.delegate?.conversationAudioInterruptionEndedWithoutResume()
                return
            }
            self.captureInterrupted = false
            self.rearmWatchdog()
            self.delegate?.conversationAudioInterruptionEnded()
        }
    }

    /// AVAudioEngineConfigurationChange: the engine has stopped; reinstall the tap for the new input format, reconnect and start again.
    private func rebuild() {
        guard running else { return }
        // The real-time downlink queue became invalid when the engine stopped: freeze the played count, then clear it.
        if realtimeInterruption != nil { stopRealtimePlayback() }
        do {
            try configureGraph()
            if let sentence, !paused {
                reschedule(sentence)
                player.play()
            }
            if capture.realtimeBroken { realtimeInterruption?() }
            rearmWatchdog()
        } catch {
            Self.logger.error("voice conversation rebuild failed: \(error.localizedDescription, privacy: .public)")
            captureFailed(.rebuild)
        }
    }

    // MARK: Frame watchdog

    /// Resets the timing start per current state: time only while running, not interrupted, and not paused; otherwise stop timing and cancel the check.
    private func rearmWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
        guard running, captureActive, !captureInterrupted, !capturePaused else {
            watchdog.disarm()
            return
        }
        watchdog.arm(nowMs: tapClock.now())
        let sleep = watchdogSleep
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                // Sleep until the earliest moment a stall can be judged; if a callback arrives meanwhile, restart the count from the latest callback and keep sleeping.
                guard let waitMs = self?.watchdogWaitMs() else { return }
                if waitMs > 0 {
                    await sleep(waitMs)
                    continue
                }
                guard !Task.isCancelled, let self else { return }
                self.watchdogStalled()
                return
            }
        }
    }

    /// Time remaining until a stall can be judged (≤ 0 = stalled); nil when not running or not timing.
    private func watchdogWaitMs() -> Int? {
        guard running, let due = watchdog.dueMs(lastFrameMs: tapClock.last) else { return nil }
        return due - tapClock.now()
    }

    private func watchdogStalled() {
        guard running, watchdog.stalled(nowMs: tapClock.now(), lastFrameMs: tapClock.last) else { return }
        Self.logger.error("voice conversation capture stalled: no tap callback for \(ConversationFrameWatchdog.stallLimitMs, privacy: .public) ms")
        watchdogTask = nil
        captureFailed(.stall)
    }

    /// Capture cannot continue: stop timing and report to the host (ends as system) and the real-time session.
    private func captureFailed(_ reason: ConversationCaptureFailure) {
        watchdog.disarm()
        watchdogTask?.cancel()
        watchdogTask = nil
        realtimeInterruption?()
        delegate?.conversationAudioCaptureFailed(reason: reason)
    }

    // MARK: Capture

    func setCaptureMuted(_ muted: Bool) { capture.setMuted(muted) }
    func pauseCapture() {
        capture.setPaused(true)
        capturePaused = true
        rearmWatchdog()
    }
    func resumeCapture() {
        capture.setPaused(false)
        capturePaused = false
        rearmWatchdog()
    }
    func beginUtterance(fromFrame frame: Int) { capture.beginUtterance(fromFrame: frame) }
    func beginUtterance(fromFrame frame: Int, live: ConversationLiveSink?) {
        capture.beginUtterance(fromFrame: frame, live: live)
    }
    func finishUtterance(_ completion: @escaping @MainActor @Sendable (RecordingResult?) -> Void) {
        capture.finishUtterance(completion)
    }
    func discardUtterance() { capture.discardUtterance() }

    // MARK: Output

    func speak(_ text: String, language: String?) async -> ConversationPlaybackOutcome {
        finishSentence(.stopped)
        let voices = SystemSpeechEngine.usableVoices()
        let tag = language ?? AVSpeechSynthesisVoice.currentLanguageCode()
        let voice = SystemSpeechEngine.bestVoice(for: tag, among: voices)
        let utterance = SystemSpeechEngine.makeUtterance(
            SpeechUtterance(text: text, language: tag), voice: voice, speechRate: speechRate()
        )
        // write does not use the accessibility speech-rate override: the conversation's speech rate follows the setting.
        utterance.prefersAssistiveTechnologySettings = false
        let current = Sentence()
        sentence = current
        return await withCheckedContinuation { continuation in
            current.continuation = continuation
            synthesizer.write(utterance) { [weak self] buffer in
                let pcm = buffer as? AVAudioPCMBuffer
                let box = PCMBox(pcm)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.receive(box.buffer, for: current) }
                }
            }
        }
    }

    func play(audio: Data, fileExtension: String) async -> ConversationPlaybackOutcome {
        finishSentence(.stopped)
        // Claim the sentence first: if it is stopped or replaced during decoding, do not play it when decoding returns.
        let current = Sentence()
        sentence = current
        let box = await Task.detached(priority: .userInitiated) {
            VPIOConversationAudioEngine.decode(audio, fileExtension: fileExtension)
        }.value
        guard sentence === current else { return .stopped }
        guard let decoded = box.buffer, decoded.frameLength > 0 else {
            sentence = nil
            return .failed
        }
        return await withCheckedContinuation { continuation in
            current.continuation = continuation
            receive(decoded, for: current)
            receive(nil, for: current)
        }
    }

    /// Cloud audio for a whole sentence is written to disk, then decoded (run in the background, not touching the main thread); on failure, returns an empty box.
    private nonisolated static func decode(_ audio: Data, fileExtension: String) -> PCMBox {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-conversation-\(UUID().uuidString).\(fileExtension)")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try audio.write(to: url)
            let file = try AVAudioFile(forReading: url)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(file.length))
            else { return PCMBox(nil) }
            try file.read(into: buffer)
            return PCMBox(buffer)
        } catch {
            return PCMBox(nil)
        }
    }

    /// Receives one synthesized buffer: zero length / nil = end of sentence; each sentence accumulates at least 100 ms before scheduling.
    private func receive(_ buffer: AVAudioPCMBuffer?, for target: Sentence) {
        guard sentence === target else { return }
        guard let buffer, buffer.frameLength > 0 else {
            target.synthesisDone = true
            flushPending(target)
            if target.count.outstanding == 0 { finishSentence(target.buffers.isEmpty ? .failed : .finished) }
            return
        }
        if !connect(format: buffer.format) {
            finishSentence(.failed)
            return
        }
        target.pendingChunk.append(buffer)
        target.pendingFrames += buffer.frameLength
        if Double(target.pendingFrames) / buffer.format.sampleRate >= 0.1 { flushPending(target) }
    }

    private func flushPending(_ target: Sentence) {
        guard !target.pendingChunk.isEmpty else { return }
        let chunk = target.pendingChunk
        target.pendingChunk = []
        target.pendingFrames = 0
        target.buffers.append(contentsOf: chunk)
        for buffer in chunk { schedule(buffer, for: target) }
        if !target.began {
            target.began = true
            if !paused { player.play() }
            delegate?.conversationAudioDidBeginSentence()
        }
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, for target: Sentence) {
        let generation = scheduleGeneration
        target.count.scheduled()
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.chunkPlayed(target, generation: generation) }
            }
        }
    }

    private func chunkPlayed(_ target: Sentence, generation: Int) {
        guard sentence === target else { return }
        let last = target.count.playedBack(
            generation: generation, currentGeneration: scheduleGeneration,
            synthesisDone: target.synthesisDone, pendingEmpty: target.pendingChunk.isEmpty
        )
        if last { finishSentence(.finished) }
    }

    /// The player connects to mainMixer according to the first buffer's actual format (mixer does the SRC); if the format changes, it stops and reconnects first.
    private func connect(format: AVAudioFormat) -> Bool {
        if let playerFormat, playerFormat.isEqual(format) { return true }
        guard running else { return false }
        scheduleGeneration += 1
        player.stop()
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        playerFormat = format
        if !engine.isRunning {
            do { try engine.start() } catch { return false }
        }
        return true
    }

    private func reschedule(_ target: Sentence) {
        scheduleGeneration += 1
        player.stop()
        target.count.reset()
        for buffer in target.buffers { schedule(buffer, for: target) }
    }

    private func finishSentence(_ outcome: ConversationPlaybackOutcome) {
        guard let current = sentence else { return }
        sentence = nil
        let continuation = current.continuation
        current.continuation = nil
        continuation?.resume(returning: outcome)
        // Already on the main thread: the last dataPlayedBack reports playback finished, before speak / play returns.
        if outcome == .finished { delegate?.conversationAudioDidFinishPlayback() }
    }

    func pausePlayback() {
        paused = true
        player.pause()
    }

    func resumePlayback(fromSentenceStart: Bool) {
        paused = false
        if fromSentenceStart, let sentence { reschedule(sentence) }
        player.play()
    }

    func stopPlayback() {
        paused = false
        synthesizer.stopSpeaking(at: .immediate)
        scheduleGeneration += 1
        player.stop()
        finishSentence(.stopped)
    }

    func playEarcon(_ earcon: VoiceConversationLogic.Earcon) {
        guard running, let format = earconFormat else { return }
        let samples = ConversationEarconSynth.samples(earcon, sampleRate: format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let target = buffer.floatChannelData?[0]
        else { return }
        for (index, sample) in samples.enumerated() { target[index] = sample }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        earconPlayer.scheduleBuffer(buffer, completionHandler: nil)
        earconPlayer.play()
    }
}

// MARK: - Real-time audio IO

extension VPIOConversationAudioEngine: RealtimeAudioIO {
    /// Downlink is accumulated to this length before being queued into the player; it waits at most this long even if not full.
    private static let realtimePrerollSeconds = 0.1

    func startRealtime(
        uplinkSampleRate: Double,
        onFrame: @escaping (Data) -> Void,
        onInterruption: @escaping () -> Void
    ) throws {
        realtimeFrame.set(onFrame)
        realtimeInterruption = onInterruption
        realtimeItems = [:]
        realtimeReference.reset(player: player)
        let uplinkReady = capture.setRealtime(true, uplinkSampleRate: uplinkSampleRate)
        do {
            try start()
        } catch {
            capture.setRealtime(false)
            realtimeFrame.set(nil)
            realtimeInterruption = nil
            throw error
        }
        if !uplinkReady || capture.realtimeBroken {
            Self.logger.error("realtime uplink resampler unavailable")
            DispatchQueue.main.async { [weak self] in self?.realtimeInterruption?() }
        }
    }

    func startRealtimePlayback(onInterruption: @escaping () -> Void) throws {
        realtimeFrame.set(nil)
        realtimeInterruption = onInterruption
        realtimeItems = [:]
        realtimeReference.reset(player: player)
        capture.setRealtime(false)
        do {
            try start(capturing: false)
        } catch {
            realtimeInterruption = nil
            throw error
        }
    }

    /// Only playback has started: capture is opened in place later: stops the engine (downlink playback stops and the played position is frozen) → enables voice processing → reconfigures the graph with input and restarts it.
    /// The session was configured at prepareSession as playAndRecord, so the session is not changed here.
    func startRealtimeCapture(uplinkSampleRate: Double, onFrame: @escaping (Data) -> Void) throws {
        guard running else { throw NotRunning() }
        guard !captureActive else { return }
        stopRealtimePlayback()
        earconPlayer.stop()
        engine.stop()
        realtimeFrame.set(onFrame)
        let uplinkReady = capture.setRealtime(true, uplinkSampleRate: uplinkSampleRate)
        do {
            try enableVoiceProcessing()
            captureActive = true
            try configureGraph(newCaptureSession: true)
        } catch {
            if captureActive { inputTap.remove() }
            captureActive = false
            capture.setRealtime(false)
            realtimeFrame.set(nil)
            throw error
        }
        captureInterrupted = false
        capturePaused = false
        rearmWatchdog()
        if !uplinkReady || capture.realtimeBroken {
            Self.logger.error("realtime uplink resampler unavailable")
            DispatchQueue.main.async { [weak self] in self?.realtimeInterruption?() }
        }
    }

    func enqueue(pcm16: Data, itemId: String) {
        guard running, let buffer = RealtimePCM.buffer(fromPCM16: pcm16) else { return }
        guard connect(format: buffer.format) else {
            Self.logger.error("realtime playback connect failed")
            return
        }
        if realtimeItems[itemId] == nil { realtimeItems[itemId] = RealtimeItem() }
        realtimePending.append((buffer, itemId))
        realtimePendingFrames += buffer.frameLength
        if realtimeDrain.queuedFrames > 0
            || Double(realtimePendingFrames) / RealtimePCM.sampleRate >= Self.realtimePrerollSeconds {
            flushRealtime()
        } else if realtimeFlushWork == nil {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.flushRealtime() }
            }
            realtimeFlushWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.realtimePrerollSeconds, execute: work)
        }
    }

    func playedMs(itemId: String) -> Int {
        guard let item = realtimeItems[itemId] else { return 0 }
        return Int((Double(renderedFrames(item)) / RealtimePCM.sampleRate * 1000).rounded(.down))
    }

    var isPlaying: Bool { realtimeDrain.queuedFrames > 0 || !realtimePending.isEmpty }

    var onPlaybackDrained: (() -> Void)? {
        get { realtimeDrained }
        set { realtimeDrained = newValue }
    }

    var onOutputLevel: ((Double) -> Void)? {
        get { realtimeOutputLevel }
        set { realtimeOutputLevel = newValue }
    }

    var onRouteChanged: ((VoiceConversationLogic.Route) -> Void)? {
        get { realtimeRouteChanged }
        set { realtimeRouteChanged = newValue }
    }

    func stopRealtimePlayback() {
        realtimeFlushWork?.cancel()
        realtimeFlushWork = nil
        for item in realtimeItems.values {
            item.baseFrames = renderedFrames(item)
            item.segments = []
            item.playedBackFrames = 0
        }
        realtimePending = []
        realtimePendingFrames = 0
        realtimeDrain.reset()
        realtimeQueueEnd = 0
        scheduleGeneration += 1
        player.stop()
        // After stopping playback, the timeline returns to zero: the reference of old blocks is void.
        realtimeReference.reset(player: player)
    }

    nonisolated func playbackReferenceDb(behindSamples: [Int]) -> [Double?] {
        realtimeReference.dbs(behindSamples: behindSamples)
    }

    func stopRealtime() {
        stopRealtimePlayback()
        capture.setRealtime(false)
        realtimeFrame.set(nil)
        realtimeInterruption = nil
        stop()
    }

    private func flushRealtime() {
        realtimeFlushWork?.cancel()
        realtimeFlushWork = nil
        guard running, !realtimePending.isEmpty else { return }
        let chunk = realtimePending
        realtimePending = []
        realtimePendingFrames = 0
        for (buffer, itemId) in chunk { scheduleRealtime(buffer, itemId: itemId) }
        if !paused { player.play() }
    }

    private func scheduleRealtime(_ buffer: AVAudioPCMBuffer, itemId: String) {
        guard let item = realtimeItems[itemId] else { return }
        let frames = AVAudioFramePosition(buffer.frameLength)
        // When the queue is empty, playback starts immediately (at the current timeline position); otherwise it is appended to the end of the queue.
        let now = currentPlayerFrame() ?? 0
        let start = realtimeDrain.queuedFrames > 0 ? max(now, realtimeQueueEnd) : now
        if let last = item.segments.last, last.start + last.frames == start {
            item.segments[item.segments.count - 1].frames += frames
        } else {
            item.segments.append((start, frames))
        }
        realtimeQueueEnd = start + frames
        realtimeReference.record(buffer, at: start)
        realtimeDrain.scheduled(frames: frames)
        let generation = scheduleGeneration
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let outcome = self.realtimeDrain.playedBack(
                        frames: frames, generation: generation,
                        currentGeneration: self.scheduleGeneration, pendingEmpty: self.realtimePending.isEmpty
                    )
                    guard case .counted(let drained) = outcome else { return }
                    item.playedBackFrames += frames
                    if drained { self.realtimeDrained?() }
                }
            }
        }
    }

    /// Frames actually rendered: computed from the timeline when playerTime is available, otherwise falls back to the cumulative count of buffers played.
    private func renderedFrames(_ item: RealtimeItem) -> AVAudioFramePosition {
        guard let now = currentPlayerFrame() else { return item.baseFrames + item.playedBackFrames }
        let rendered = item.segments.reduce(AVAudioFramePosition(0)) { sum, segment in
            sum + min(max(0, now - segment.start), segment.frames)
        }
        return item.baseFrames + rendered
    }

    /// Player timeline's current position, converted to 24 kHz frames; nil when the player is not rendering.
    private func currentPlayerFrame() -> AVAudioFramePosition? {
        Self.playerFrame(player)
    }

    /// Any thread: converts the player timeline's current position to 24 kHz frames (the downlink reference looks up blocks by it on the audio thread).
    nonisolated fileprivate static func playerFrame(_ player: AVAudioPlayerNode) -> AVAudioFramePosition? {
        guard let nodeTime = player.lastRenderTime, nodeTime.isSampleTimeValid,
              let time = player.playerTime(forNodeTime: nodeTime), time.isSampleTimeValid, time.sampleRate > 0
        else { return nil }
        if time.sampleRate == RealtimePCM.sampleRate { return time.sampleTime }
        return AVAudioFramePosition((Double(time.sampleTime) * RealtimePCM.sampleRate / time.sampleRate).rounded())
    }
}

/// Downlink reference level: on the player timeline, per 20 ms block (480 samples at 24 kHz, aligned by timeline sample number) records the sum of squares and sample count,
/// written by the main thread at scheduling time; the audio thread reads dBFS from the block where the playhead sits. Pre-allocated ring (60 s of blocks, since downlink can be scheduled far ahead of real time);
/// slots are verified by block number, and overwritten or never-scheduled blocks are nil; the lock only does array reads and writes. Cleared on stop / session start (the timeline returns to zero).
nonisolated final class RealtimePlaybackReference: @unchecked Sendable {
    static let blockFrames: AVAudioFramePosition = 480
    static let capacity = 3_000

    private struct Ring {
        var blocks = [AVAudioFramePosition](repeating: -1, count: RealtimePlaybackReference.capacity)
        var sums = [Double](repeating: 0, count: RealtimePlaybackReference.capacity)
        var counts = [Int](repeating: 0, count: RealtimePlaybackReference.capacity)
        var player: AVAudioPlayerNode?
    }

    private let ring = OSAllocatedUnfairLock(uncheckedState: Ring())

    /// Main thread: clears the record and switches it to this player's timeline.
    func reset(player: AVAudioPlayerNode?) {
        ring.withLockUnchecked { ring in
            for index in ring.blocks.indices { ring.blocks[index] = -1 }
            ring.player = player
        }
    }

    /// Main thread: one downlink block is placed on the timeline at start; sums of squares are accumulated per 20 ms block it spans (merged when a block spans two scheduling calls).
    func record(_ buffer: AVAudioPCMBuffer, at start: AVAudioFramePosition) {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var parts: [(block: AVAudioFramePosition, sum: Double, count: Int)] = []
        var offset = 0
        let length = Int(buffer.frameLength)
        while offset < length {
            let position = start + AVAudioFramePosition(offset)
            let block = position / Self.blockFrames
            let take = min(length - offset, Int((block + 1) * Self.blockFrames - position))
            var sum = 0.0
            for index in offset..<(offset + take) { sum += Double(samples[index]) * Double(samples[index]) }
            parts.append((block, sum, take))
            offset += take
        }
        ring.withLockUnchecked { ring in
            for part in parts {
                let slot = Int(part.block % AVAudioFramePosition(Self.capacity))
                if ring.blocks[slot] != part.block {
                    ring.blocks[slot] = part.block
                    ring.sums[slot] = 0
                    ring.counts[slot] = 0
                }
                ring.sums[slot] += part.sum
                ring.counts[slot] += part.count
            }
        }
    }

    /// Any thread: for each behindSamples, takes the dBFS of the block containing (playhead − it), returned in the same order. The playhead is read once, and all lookups are done under one lock;
    /// nil when not rendering, when the block was never scheduled or was overwritten, or when it is digital silence (rms 0).
    func dbs(behindSamples: [Int]) -> [Double?] {
        guard !behindSamples.isEmpty,
              let player = ring.withLockUnchecked({ $0.player }),
              let head = VPIOConversationAudioEngine.playerFrame(player)
        else { return behindSamples.map { _ in nil } }
        let blocks = behindSamples.map { behind -> AVAudioFramePosition? in
            let frame = head - AVAudioFramePosition(behind)
            return frame >= 0 ? frame / Self.blockFrames : nil
        }
        let entries = ring.withLockUnchecked { ring in
            blocks.map { block -> (sum: Double, count: Int)? in
                guard let block else { return nil }
                let slot = Int(block % AVAudioFramePosition(Self.capacity))
                return ring.blocks[slot] == block ? (ring.sums[slot], ring.counts[slot]) : nil
            }
        }
        return entries.map { entry in
            guard let entry, entry.count > 0 else { return nil }
            let rms = (entry.sum / Double(entry.count)).squareRoot()
            guard rms > 0 else { return nil }
            return max(ConversationAudioMath.silenceDb, 20 * log10(rms))
        }
    }
}

/// AVAudioPCMBuffer is not Sendable; it is used only to hand the synthesis callback's buffers back to the main thread.
/// Relay for the real-time uplink callback: set / cleared by the main thread; the audio thread takes it out and calls it outside the lock.
private nonisolated final class RealtimeFrameRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((Data) -> Void)?

    func set(_ handler: ((Data) -> Void)?) {
        lock.withLock { self.handler = handler }
    }

    func deliver(_ frame: Data) {
        lock.withLock { handler }?(frame)
    }
}

private nonisolated final class PCMBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer?) { self.buffer = buffer }
}

extension ConversationCaptureCore {
    /// Capture mono frame → 16 kHz mono Float (Silero input), keeps filter state across calls.
    /// Input / output buffers and the input chunk are built once and reused: expanded once only when capacity is insufficient; normally zero per-frame allocation; used only under speechLock.
    fileprivate nonisolated final class SpeechResampler {
        private let source: AVAudioFormat
        private let target: AVAudioFormat
        /// nil = input is already 16 kHz; feed directly.
        private let converter: AVAudioConverter?
        private var input: AVAudioPCMBuffer
        private var output: AVAudioPCMBuffer
        private var supplied = false
        private lazy var inputBlock: AVAudioConverterInputBlock = { [unowned self] _, status in
            if self.supplied {
                status.pointee = .noDataNow
                return nil
            }
            self.supplied = true
            status.pointee = .haveData
            return self.input
        }

        init?(sourceSampleRate: Double) {
            guard let source = RealtimePCM.floatFormat(sampleRate: sourceSampleRate),
                  let target = RealtimePCM.floatFormat(sampleRate: Double(SileroVad.sampleRate))
            else { return nil }
            self.source = source
            self.target = target
            if source.isEqual(target) {
                converter = nil
            } else {
                guard let converter = AVAudioConverter(from: source, to: target) else { return nil }
                self.converter = converter
            }
            let capacity: AVAudioFrameCount = 4096
            guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: capacity),
                  let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: Self.outputCapacity(capacity, source, target))
            else { return nil }
            self.input = input
            self.output = output
        }

        /// Resamples one block and hands the output (possibly empty) to sink; sink must not retain the pointer.
        func convert(_ samples: [Float], into sink: (UnsafeBufferPointer<Float>) -> Void) {
            guard !samples.isEmpty else { return }
            guard let converter else {
                samples.withUnsafeBufferPointer { sink($0) }
                return
            }
            let count = AVAudioFrameCount(samples.count)
            if count > input.frameCapacity {
                guard let grown = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: count),
                      let grownOut = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: Self.outputCapacity(count, source, target))
                else { return }
                input = grown
                output = grownOut
            }
            guard let inPtr = input.floatChannelData?[0] else { return }
            samples.withUnsafeBufferPointer { inPtr.update(from: $0.baseAddress!, count: samples.count) }
            input.frameLength = count
            output.frameLength = 0
            supplied = false
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError, withInputFrom: inputBlock)
            guard status != .error, output.frameLength > 0, let outPtr = output.floatChannelData?[0] else { return }
            sink(UnsafeBufferPointer(start: outPtr, count: Int(output.frameLength)))
        }

        private static func outputCapacity(_ frames: AVAudioFrameCount, _ source: AVAudioFormat, _ target: AVAudioFormat) -> AVAudioFrameCount {
            AVAudioFrameCount(Double(frames) * target.sampleRate / source.sampleRate) + 1024
        }
    }
}
