import AVFoundation
import Foundation
import os

// MARK: - Protocols

/// How playback of one sentence ended.
enum ConversationPlaybackOutcome: Equatable, Sendable {
    case finished
    /// Interrupted by stopPlayback / stop.
    case stopped
    /// Synthesis / decoding / scheduling failed.
    case failed
}

/// Audio pipeline callbacks; all on the main actor.
protocol ConversationAudioEngineDelegate: AnyObject {
    /// One 20 ms microphone frame in dBFS (not called while muted or capture is paused); index increases monotonically from start.
    func conversationAudio(didCaptureFrame index: Int, db: Double)
    /// Playback output level (dBFS), used by the status orb.
    func conversationAudio(didMeasureOutput db: Double)
    /// A sentence actually started making sound (the first buffer is scheduled on the player).
    func conversationAudioDidBeginSentence()
    func conversationAudioInterruptionBegan()
    func conversationAudioInterruptionEnded()
    /// The interruption ended but the system advises against resuming (iOS 27 resumptionRecommendation is not shouldResume): the host should end with the system reason.
    func conversationAudioInterruptionEndedWithoutResume()
    /// Output route changed; oldDeviceUnavailable = headphones unplugged / Bluetooth disconnected.
    func conversationAudio(routeChanged route: VoiceConversationLogic.Route, oldDeviceUnavailable: Bool)
}

extension ConversationAudioEngineDelegate {
    func conversationAudioInterruptionEndedWithoutResume() {}
}

/// Voice conversation audio pipeline: one engine both captures (voice processing) and plays (system TTS / cloud audio / earcons).
protocol ConversationAudioEngine: AnyObject {
    var delegate: ConversationAudioEngineDelegate? { get set }
    var route: VoiceConversationLogic.Route { get }
    var isSpeakerRoute: Bool { get }

    /// Activates the session in the foreground, configures the engine, installs the tap and starts (only called when the user taps the voice button).
    func start() throws
    /// Stops the engine and deactivates the session.
    func stop()

    /// Software mute: drops samples, the input node stays on.
    func setCaptureMuted(_ muted: Bool)
    func pauseCapture()
    func resumeCapture()

    /// Starts writing speech into a recording from frame `frame` (preroll included).
    func beginUtterance(fromFrame frame: Int)
    /// Ends the current segment and exports it (same format as dictation, can be handed straight to `STTEngine.transcribe`); returns immediately and calls back on the main thread once the export finishes.
    /// Calls back with nil when there is no segment in progress or the export fails.
    func finishUtterance(_ completion: @escaping @MainActor @Sendable (RecordingResult?) -> Void)
    func discardUtterance()

    /// Synthesizes one sentence with the system TTS and plays it; returns when it finishes, is stopped, or fails.
    func speak(_ text: String, language: String?) async -> ConversationPlaybackOutcome
    /// Decodes audio already synthesized by the cloud (fileExtension such as mp3 / wav) and schedules it on the same player.
    func play(audio: Data, fileExtension: String) async -> ConversationPlaybackOutcome
    func pausePlayback()
    /// With fromSentenceStart = true, replays from the start of this sentence (resuming after a false barge-in).
    func resumePlayback(fromSentenceStart: Bool)
    func stopPlayback()
    func playEarcon(_ earcon: VoiceConversationLogic.Earcon)
}

/// Installs / removes the input node tap (bus 0); production goes straight to AVAudioEngine.inputNode, unit tests swap in a counting double.
protocol ConversationInputTap: AnyObject {
    func install(bufferSize: AVAudioFrameCount, format: AVAudioFormat?, block: @escaping AVAudioNodeTapBlock)
    func remove()
}

/// The real input node.
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

/// A conversation engine that knows about the audio session lease: the wrapper hands it the lease once acquired, and teardown only deactivates the session while the lease is still the current generation;
/// when a later owner has taken over the lease, the wrapper calls tearDownGraph, which only tears down the graph (stops the engine, removes the tap and observers) and leaves the session alone.
protocol SessionLeaseAwareAudio: AnyObject {
    var sessionLease: VoiceAudioSessionOwner.Lease? { get set }
    /// The owner that deactivation is judged against; nil = no ownership check.
    var sessionOwner: VoiceAudioSessionOwner? { get }
    func tearDownGraph()
}

// MARK: - Pure helpers (unit-testable)

nonisolated enum ConversationAudioMath {
    /// The dBFS floor for an all-zero frame.
    static let silenceDb = -120.0

    static func dbfs<C: Collection>(_ samples: C) -> Double where C.Element == Float {
        guard !samples.isEmpty else { return silenceDb }
        var sum = 0.0
        for sample in samples { sum += Double(sample) * Double(sample) }
        let rms = (sum / Double(samples.count)).squareRoot()
        guard rms > 0 else { return silenceDb }
        return max(silenceDb, 20 * log10(rms))
    }

    static func samplesPerFrame(sampleRate: Double) -> Int {
        max(1, Int((sampleRate * Double(VoiceConversationLogic.Constants.frameMs) / 1000).rounded()))
    }
}

/// Accumulates tap buffers of any size into whole 20 ms frames; a tail shorter than one frame carries over to the next block.
nonisolated struct ConversationFrameAccumulator {
    let samplesPerFrame: Int
    private var pending: [Float] = []

    init(sampleRate: Double) {
        samplesPerFrame = ConversationAudioMath.samplesPerFrame(sampleRate: sampleRate)
        pending.reserveCapacity(samplesPerFrame * 2)
    }

    /// Feeds a run of mono samples and returns the completed frames (samplesPerFrame samples each).
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

/// Ring buffer of the most recent frames: when speechStart is detected, frames are taken from speechStart minus vadPrerollMs.
/// Capacity must cover the 300 ms preroll plus the start threshold (300 ms for speaker barge-in) plus the main-thread round trip; the default is 1 s.
nonisolated struct ConversationPrerollRing {
    let capacity: Int
    private var storage: [[Float]] = []
    private var head = 0
    /// The next frame's index.
    private(set) var nextIndex = 0

    static let defaultCapacityMs = VoiceConversationLogic.Constants.vadPrerollMs
        + VoiceConversationLogic.Constants.bargeInMinSpeechMs + 400

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

    /// The oldest frame index still in the ring.
    var oldestIndex: Int { nextIndex - storage.count }

    /// From frame index `index` (from the oldest frame when it predates the ring) up to the newest frame.
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

/// Earcons synthesized in code: sine tones, at most 250 ms, peak about -18 dBFS, with 10 ms fades at both ends to avoid pops.
nonisolated enum ConversationEarconSynth {
    static let peakDb = -18.0
    static let fadeMs = 10.0

    /// Per tone: frequency in Hz, duration in ms.
    static func tones(_ earcon: VoiceConversationLogic.Earcon) -> [(hz: Double, ms: Double)] {
        switch earcon {
        case .thinking: return [(880, 120)]
        case .end: return [(660, 110), (440, 130)]
        }
    }

    static func durationMs(_ earcon: VoiceConversationLogic.Earcon) -> Double {
        tones(earcon).reduce(0) { $0 + $1.ms }
    }

    static func samples(_ earcon: VoiceConversationLogic.Earcon, sampleRate: Double) -> [Float] {
        let amplitude = pow(10, peakDb / 20)
        var out: [Float] = []
        for tone in tones(earcon) {
            let count = Int((sampleRate * tone.ms / 1000).rounded())
            let fade = max(1, Int(sampleRate * fadeMs / 1000))
            for index in 0..<count {
                let envelope = min(1, Double(min(index, count - 1 - index)) / Double(fade))
                let value = amplitude * envelope * sin(2 * .pi * tone.hz * Double(index) / sampleRate)
                out.append(Float(value))
            }
        }
        return out
    }
}

// MARK: - Capture core (audio thread)

/// Counting and generation checks that turn realtime downlink `.dataPlayedBack` callbacks into onPlaybackDrained (used on the main thread; touches no AVAudio objects, so it is unit-testable).
nonisolated struct RealtimePlaybackDrain {
    enum Outcome: Equatable {
        /// A callback from an older generation arriving after a stop / reschedule: not counted.
        case stale
        /// Counted; drained = this chunk emptied the queue and no new chunk is waiting, so one drained report is due.
        case counted(drained: Bool)
    }

    /// Frames scheduled on the player and not yet played back.
    private(set) var queuedFrames: AVAudioFramePosition = 0

    mutating func scheduled(frames: AVAudioFramePosition) {
        queuedFrames += frames
    }

    /// One chunk finished playing. generation is the generation when it was scheduled, currentGeneration the one when the callback arrived.
    mutating func playedBack(
        frames: AVAudioFramePosition, generation: Int, currentGeneration: Int, pendingEmpty: Bool
    ) -> Outcome {
        guard generation == currentGeneration else { return .stale }
        let before = queuedFrames
        queuedFrames = max(0, queuedFrames - frames)
        return .counted(drained: before > 0 && queuedFrames == 0 && pendingEmpty)
    }

    /// Stop: clears the queue count (the caller advances the generation at the same time).
    mutating func reset() {
        queuedFrames = 0
    }
}

/// Frame accumulation and the preroll ring on the tap thread; main-actor commands come in through the lock.
/// Creating / writing / closing / deleting the recording writer happens only on the serial `io` queue; callers only dispatch (the close result is delivered back on the main thread).
nonisolated final class ConversationCaptureCore: @unchecked Sendable {
    private let lock = NSLock()
    private var accumulator = ConversationFrameAccumulator(sampleRate: 48_000)
    private var ring = ConversationPrerollRing()
    private var monoFormat: AVAudioFormat?
    /// Under the lock: whether a sentence is being recorded (decides whether tap frames get dispatched for writing).
    private var recording = false
    private let io: DispatchQueue
    /// Read and written only on `io`.
    private var writer: RecordingWriter?
    private var muted = false
    private var paused = false
    private let directory: URL
    /// Realtime uplink: when on, each tap block is mixed to mono and resampled once to PCM16 at the uplink rate the transport declares.
    private var realtimeEnabled = false
    private var uplink: RealtimeUplinkResampler?
    private var uplinkSampleRate = RealtimePCM.sampleRate
    private var sampleRate = 48_000.0

    /// io is injectable (tests suspend the queue to verify the main thread never waits on it).
    init(directory: URL, io: DispatchQueue = DispatchQueue(label: "com.kenny.oriveo.voice-conversation.recording")) {
        self.directory = directory
        self.io = io
    }

    /// New input format (after start / a configuration change): frame numbering continues, the ring and any recording in progress are dropped.
    func configure(sampleRate: Double) {
        lock.lock(); defer { lock.unlock() }
        accumulator = ConversationFrameAccumulator(sampleRate: sampleRate)
        let next = ring.nextIndex
        ring = ConversationPrerollRing()
        for _ in 0..<next { ring.push([]) }
        ring.reset()
        monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
        recording = false
        io.async { self.writer = nil }
        self.sampleRate = sampleRate
        uplink = realtimeEnabled
            ? RealtimeUplinkResampler(sourceSampleRate: sampleRate, targetSampleRate: uplinkSampleRate) : nil
    }

    /// Turns the realtime uplink on / off; when on, builds the resampler at the uplink rate the transport declares. Returns false = no resampler could be built for the current input rate.
    @discardableResult
    func setRealtime(_ enabled: Bool, uplinkSampleRate: Double = RealtimePCM.sampleRate) -> Bool {
        lock.lock(); defer { lock.unlock() }
        realtimeEnabled = enabled
        if enabled { self.uplinkSampleRate = uplinkSampleRate }
        uplink = enabled
            ? RealtimeUplinkResampler(sourceSampleRate: sampleRate, targetSampleRate: self.uplinkSampleRate) : nil
        return !enabled || uplink != nil
    }

    /// Realtime is on but the resampler is missing (could not be rebuilt after the input rate changed).
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

    /// Returns the completed (frame index, dBFS) pairs and the realtime uplink PCM16 (at the uplink rate the transport declares; nil when realtime is off or nothing was produced).
    func consume(_ buffer: AVAudioPCMBuffer) -> (frames: [(Int, Double)], uplink: Data?) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return ([], nil) }
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
        lock.lock(); defer { lock.unlock() }
        guard !muted, !paused else { return ([], nil) }
        var out: [(Int, Double)] = []
        var recorded: [[Float]] = []
        for frame in accumulator.append(mono) {
            let index = ring.nextIndex
            ring.push(frame)
            if recording { recorded.append(frame) }
            out.append((index, ConversationAudioMath.dbfs(frame[...])))
        }
        // Dispatch under the lock: keeps ordering with the dispatches from begin / finish / discard.
        if !recorded.isEmpty, let monoFormat {
            let frames = recorded
            io.async { self.write(frames, format: monoFormat) }
        }
        return (out, uplink?.convert(mono))
    }

    func beginUtterance(fromFrame frame: Int) {
        lock.lock(); defer { lock.unlock() }
        guard let monoFormat else { return }
        let url = directory.appendingPathComponent("\(UUID().uuidString).aac")
        let preroll = ring.frames(from: frame)
        recording = true
        io.async {
            self.writer = try? RecordingWriter(url: url, inputFormat: monoFormat)
            self.write(preroll, format: monoFormat)
        }
    }

    /// Returns immediately: the close is queued after the writes already dispatched on `io`, and the result is delivered back on the main thread.
    /// When nothing is being recorded the queue is left alone and nil is delivered synchronously on the caller (main thread), so the caller can decide on the spot that there is no draft.
    func finishUtterance(_ completion: @escaping @MainActor @Sendable (RecordingResult?) -> Void) {
        lock.lock()
        guard recording else {
            lock.unlock()
            // Call back outside the lock: completion may call back into this object.
            MainActor.assumeIsolated { completion(nil) }
            return
        }
        recording = false
        // Dispatch under the lock: queued after the last write consume already dispatched.
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
        io.async {
            guard let writer = self.writer else { return }
            self.writer = nil
            _ = try? writer.close()
            try? FileManager.default.removeItem(at: writer.url)
        }
    }

    /// Call only on `io`.
    private func write(_ frames: [[Float]], format monoFormat: AVAudioFormat) {
        guard let writer, !frames.isEmpty else { return }
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
        do {
            try writer.append(buffer)
        } catch {
            self.writer = nil
        }
    }
}

// MARK: - VPIO implementation

/// AVAudioEngine + voice processing: system TTS goes through `write` into the same player (so AEC has a reference signal), and decoded cloud audio plays down the same path.
final class VPIOConversationAudioEngine: ConversationAudioEngine, SessionLeaseAwareAudio {
    weak var delegate: ConversationAudioEngineDelegate?

    private static let logger = Logger(subsystem: "com.kenny.oriveo", category: "voice-conversation")
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
    /// Audio session ownership; nil = no ownership check (deactivation stays unconditional).
    private let owner: VoiceAudioSessionOwner?
    private let deactivateSession: (AVAudioSession) -> Void
    private let inputTap: ConversationInputTap
    private let voiceProcessing: ConversationVoiceProcessing
    private let startEngine: (AVAudioEngine) throws -> Void
    /// Engine serial number: tells apart successive VPIO engines of one process in logs.
    private let serial: Int
    private static var nextSerial = 0
    /// The conversation lease the wrapper acquired; with an owner, the session is only deactivated while this is still the current lease.
    var sessionLease: VoiceAudioSessionOwner.Lease?

    /// The sentence being played: buffers received so far (for rescheduling from the start when resuming), chunks scheduled but not yet played, and whether synthesis has finished.
    private final class Sentence {
        var buffers: [AVAudioPCMBuffer] = []
        var pendingChunk: [AVAudioPCMBuffer] = []
        var pendingFrames: AVAudioFrameCount = 0
        var scheduled = 0
        var synthesisDone = false
        var began = false
        var continuation: CheckedContinuation<ConversationPlaybackOutcome, Never>?
    }

    private var sentence: Sentence?
    /// Incremented on every reschedule / stop so completion callbacks of older buffers no longer count.
    private var scheduleGeneration = 0
    private var paused = false

    // Realtime: uplink callback, interruption callback and the downlink queue.
    /// The uplink callback is read on the audio thread and relayed through a lock (set / cleared on the main thread).
    private let realtimeFrame = RealtimeFrameRelay()
    private var realtimeInterruption: (() -> Void)?
    /// Downlink drained callback (RealtimeAudioIO.onPlaybackDrained).
    private var realtimeDrained: (() -> Void)?

    /// Playback counting for one downlink item: base = frames frozen at earlier stops; segments = contiguous runs scheduled on the current player timeline.
    private final class RealtimeItem {
        var baseFrames: AVAudioFramePosition = 0
        var segments: [(start: AVAudioFramePosition, frames: AVAudioFramePosition)] = []
        var playedBackFrames: AVAudioFramePosition = 0
    }

    private var realtimeItems: [String: RealtimeItem] = [:]
    private var realtimePending: [(buffer: AVAudioPCMBuffer, itemId: String)] = []
    private var realtimePendingFrames: AVAudioFrameCount = 0
    /// Frames scheduled on the player and not yet played back, plus the drained check.
    private var realtimeDrain = RealtimePlaybackDrain()
    /// The end of the scheduled queue on the player timeline.
    private var realtimeQueueEnd: AVAudioFramePosition = 0
    private var realtimeFlushWork: DispatchWorkItem?

    /// Session configuration passed to setCategory at start; unit tests read the same value.
    static let sessionConfiguration: (
        category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions
    ) = (.playAndRecord, .voiceChat, [.defaultToSpeaker, .allowBluetoothHFP])

    init(
        session: AVAudioSession = .sharedInstance(),
        notificationCenter: NotificationCenter = .default,
        speechRate: @escaping () -> Double = { VoiceEngineSettings().speechRate },
        directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("voice-conversation", isDirectory: true),
        owner: VoiceAudioSessionOwner? = nil,
        deactivateSession: @escaping (AVAudioSession) -> Void = {
            try? $0.setActive(false, options: .notifyOthersOnDeactivation)
        },
        inputTap: ((AVAudioEngine) -> ConversationInputTap)? = nil,
        voiceProcessing: ((AVAudioEngine) -> ConversationVoiceProcessing)? = nil,
        startEngine: @escaping (AVAudioEngine) throws -> Void = { try $0.start() }
    ) {
        self.session = session
        self.owner = owner
        self.deactivateSession = deactivateSession
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

    static func route(of description: AVAudioSessionRouteDescription) -> VoiceConversationLogic.Route {
        let ports = description.outputs.map(\.portType)
        if ports.contains(where: { [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains($0) }) { return .bluetooth }
        if ports.contains(where: { [.headphones, .usbAudio, .airPlay, .carAudio, .lineOut, .HDMI].contains($0) }) {
            return .headphones
        }
        return .speaker
    }

    // MARK: Lifecycle

    func start() throws {
        guard !running else { return }
        let config = Self.sessionConfiguration
        try session.setCategory(config.category, mode: config.mode, options: config.options)
        try session.setActive(true)
        try? session.setPreferredIOBufferDuration(0.02)
        Self.logger.info("voice conversation ioBufferDuration=\(self.session.ioBufferDuration, privacy: .public)")
        do {
            try voiceProcessing.setEnabled(true)
            logVoiceProcessing("enable")
            engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                .init(enableAdvancedDucking: false, duckingLevel: .min)
            engine.attach(player)
            engine.attach(earconPlayer)
            try configureGraph()
            running = true
            observe()
        } catch {
            teardown()
            throw error
        }
    }

    func stop() {
        guard running else { return }
        stopPlayback()
        earconPlayer.stop()
        teardown()
    }

    /// Tears down the graph only: stops playback and the engine, removes the tap and observers, but neither deactivates the session nor turns off VPIO
    /// (the session now belongs to a later owner, and VPIO is close to a process-wide singleton, so turning it off would take the later owner's echo cancellation with it).
    func tearDownGraph() {
        guard running else { return }
        stopPlayback()
        earconPlayer.stop()
        teardown(ownTeardown: false)
    }

    var sessionOwner: VoiceAudioSessionOwner? { owner }

    /// Without an owner this is always true; with an owner, the session only counts as held while this engine's lease is still the current one.
    private var ownsSession: Bool {
        guard let owner else { return true }
        guard let sessionLease else { return false }
        return owner.current == sessionLease
    }

    #if DEBUG
    /// For unit tests: skips building the real graph, enters the running state and registers observers directly, to verify how stop / tearDownGraph clean up.
    func enterRunningStateForTesting() {
        running = true
        observe()
    }

    var isEngineRunningForTesting: Bool { engine.isRunning }
    var observerCountForTesting: Int { observers.count }
    #endif

    /// ownTeardown = this engine's own teardown (lease still current / no owner): turns off VPIO and deactivates the session;
    /// a superseded teardown (tearDownGraph, or a stop whose lease is no longer current) only tears down the graph and leaves VPIO and the session to the later owner.
    private func teardown(ownTeardown: Bool = true) {
        let releasesSession = ownTeardown && ownsSession
        running = false
        for token in observers { center.removeObserver(token) }
        observers = []
        inputTap.remove()
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

    /// Installs the tap for the current input format, connects the player and starts; runs again after a configuration change.
    private func configureGraph() throws {
        let input = engine.inputNode
        inputTap.remove()
        engine.mainMixerNode.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        capture.configure(sampleRate: format.sampleRate)
        let core = capture
        let relay = realtimeFrame
        inputTap.install(bufferSize: 1024, format: format) { [weak self] buffer, _ in
            let (frames, uplink) = core.consume(buffer)
            // Realtime uplink goes straight to the transport on the audio thread without a main-thread hop; only VAD frames go to the main thread.
            if let uplink { relay.deliver(uplink) }
            guard !frames.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                for (index, db) in frames { self.delegate?.conversationAudio(didCaptureFrame: index, db: db) }
            }
        }
        if let playerFormat { engine.connect(player, to: engine.mainMixerNode, format: playerFormat) }
        let earcon = earconFormat ?? AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)
        earconFormat = earcon
        engine.connect(earconPlayer, to: engine.mainMixerNode, format: earcon)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            let db = ConversationAudioMath.dbfs(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
            DispatchQueue.main.async { self?.delegate?.conversationAudio(didMeasureOutput: db) }
        }
        engine.prepare()
        try startEngine(engine)
    }

    private func logVoiceProcessing(_ action: StaticString) {
        let enabled = voiceProcessing.isEnabled
        Self.logger.info(
            "voice processing \(String(describing: action), privacy: .public) engine=\(self.serial, privacy: .public) isVoiceProcessingEnabled=\(enabled, privacy: .public)"
        )
    }

    /// Subscribes to interruption / route / configuration changes; internal so unit tests can drive it through an injected center (production only calls it from start).
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
                self.delegate?.conversationAudio(routeChanged: self.route, oldDeviceUnavailable: reason == .oldDeviceUnavailable)
            }
        })
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        })
    }

    private func interruptionBegan() {
        pausePlayback()
        delegate?.conversationAudioInterruptionBegan()
        realtimeInterruption?()
    }

    private func interruptionEnded() {
        do {
            try session.setActive(true)
            if !engine.isRunning { try engine.start() }
        } catch {
            Self.logger.error("voice conversation resume after interruption failed: \(error.localizedDescription, privacy: .public)")
        }
        delegate?.conversationAudioInterruptionEnded()
    }

    /// AVAudioEngineConfigurationChange: the engine has stopped; reinstall the tap for the new input format, reconnect, then start again.
    private func rebuild() {
        guard running else { return }
        // The realtime downlink queue became invalid when the engine stopped: freeze the played counts, then clear it.
        if realtimeInterruption != nil { stopRealtimePlayback() }
        do {
            try configureGraph()
            if let sentence, !paused {
                reschedule(sentence)
                player.play()
            }
            if capture.realtimeBroken { realtimeInterruption?() }
        } catch {
            Self.logger.error("voice conversation rebuild failed: \(error.localizedDescription, privacy: .public)")
            realtimeInterruption?()
        }
    }

    // MARK: Capture

    func setCaptureMuted(_ muted: Bool) { capture.setMuted(muted) }
    func pauseCapture() { capture.setPaused(true) }
    func resumeCapture() { capture.setPaused(false) }
    func beginUtterance(fromFrame frame: Int) { capture.beginUtterance(fromFrame: frame) }
    func finishUtterance(_ completion: @escaping @MainActor @Sendable (RecordingResult?) -> Void) {
        capture.finishUtterance(completion)
    }
    func discardUtterance() { capture.discardUtterance() }

    // MARK: Playback

    func speak(_ text: String, language: String?) async -> ConversationPlaybackOutcome {
        finishSentence(.stopped)
        let voices = SystemSpeechEngine.usableVoices()
        let tag = language ?? AVSpeechSynthesisVoice.currentLanguageCode()
        let voice = SystemSpeechEngine.bestVoice(for: tag, among: voices)
        let utterance = SystemSpeechEngine.makeUtterance(
            SpeechUtterance(text: text, language: tag), voice: voice, speechRate: speechRate()
        )
        // write does not honor the accessibility rate override: the conversation speed follows the settings.
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
        // Claim the sentence first: if it is stopped or replaced during decoding, it will not play when decoding returns.
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

    /// Writes the cloud's whole-sentence audio to disk and decodes it (runs in the background, off the main thread); returns an empty box on failure.
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

    /// Receives one synthesized buffer: zero length / nil = end of sentence; each sentence first accumulates at least 100 ms before scheduling.
    private func receive(_ buffer: AVAudioPCMBuffer?, for target: Sentence) {
        guard sentence === target else { return }
        guard let buffer, buffer.frameLength > 0 else {
            target.synthesisDone = true
            flushPending(target)
            if target.scheduled == 0 { finishSentence(target.buffers.isEmpty ? .failed : .finished) }
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
        target.scheduled += 1
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.chunkPlayed(target, generation: generation) }
            }
        }
    }

    private func chunkPlayed(_ target: Sentence, generation: Int) {
        guard sentence === target, generation == scheduleGeneration else { return }
        target.scheduled -= 1
        if target.scheduled == 0 && target.synthesisDone && target.pendingChunk.isEmpty { finishSentence(.finished) }
    }

    /// The player connects to the mainMixer using the first buffer's actual format (the mixer does the sample-rate conversion); when the format changes, stop first and reconnect.
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
        target.scheduled = 0
        for buffer in target.buffers { schedule(buffer, for: target) }
    }

    private func finishSentence(_ outcome: ConversationPlaybackOutcome) {
        guard let current = sentence else { return }
        sentence = nil
        let continuation = current.continuation
        current.continuation = nil
        continuation?.resume(returning: outcome)
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

// MARK: - Realtime audio IO

extension VPIOConversationAudioEngine: RealtimeAudioIO {
    /// Downlink audio accumulates this long before being scheduled on the player; a shorter backlog also waits at most this long.
    private static let realtimePrerollSeconds = 0.1

    func startRealtime(
        uplinkSampleRate: Double,
        onFrame: @escaping (Data) -> Void,
        onInterruption: @escaping () -> Void
    ) throws {
        realtimeFrame.set(onFrame)
        realtimeInterruption = onInterruption
        realtimeItems = [:]
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
        // With an empty queue, start playing right away (at the timeline's current position); otherwise append after the scheduled queue.
        let now = currentPlayerFrame() ?? 0
        let start = realtimeDrain.queuedFrames > 0 ? max(now, realtimeQueueEnd) : now
        if let last = item.segments.last, last.start + last.frames == start {
            item.segments[item.segments.count - 1].frames += frames
        } else {
            item.segments.append((start, frames))
        }
        realtimeQueueEnd = start + frames
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

    /// Frames actually rendered: computed from the timeline when playerTime is available, otherwise falls back to the accumulated played-back buffers.
    private func renderedFrames(_ item: RealtimeItem) -> AVAudioFramePosition {
        guard let now = currentPlayerFrame() else { return item.baseFrames + item.playedBackFrames }
        let rendered = item.segments.reduce(AVAudioFramePosition(0)) { sum, segment in
            sum + min(max(0, now - segment.start), segment.frames)
        }
        return item.baseFrames + rendered
    }

    /// The player timeline's current position converted to 24 kHz frames; nil when the player is not rendering.
    private func currentPlayerFrame() -> AVAudioFramePosition? {
        guard let nodeTime = player.lastRenderTime, nodeTime.isSampleTimeValid,
              let time = player.playerTime(forNodeTime: nodeTime), time.isSampleTimeValid, time.sampleRate > 0
        else { return nil }
        if time.sampleRate == RealtimePCM.sampleRate { return time.sampleTime }
        return AVAudioFramePosition((Double(time.sampleTime) * RealtimePCM.sampleRate / time.sampleRate).rounded())
    }
}

/// Relay for the realtime uplink callback: set / cleared on the main thread, taken on the audio thread and invoked outside the lock.
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

/// AVAudioPCMBuffer is not Sendable; this box only hands the synthesis callback's buffer back to the main thread.
private nonisolated final class PCMBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer?) { self.buffer = buffer }
}
