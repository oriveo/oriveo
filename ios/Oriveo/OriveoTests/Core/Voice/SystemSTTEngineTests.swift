import AVFoundation
import Foundation
import Observation
import Testing
@testable import Oriveo

/// Fake recognition segment: records the frame count and formats it receives, and finish returns preset text.
nonisolated final class FakeSTTSegment: SystemSTTSegment, @unchecked Sendable {
    private let lock = NSLock()
    private let text: String
    private var receivedFrames = 0
    private var receivedSampleRates: Set<Double> = []
    private var wasCancelled = false

    init(text: String) { self.text = text }

    var frames: Int { lock.withLock { receivedFrames } }
    var sampleRates: Set<Double> { lock.withLock { receivedSampleRates } }
    var cancelled: Bool { lock.withLock { wasCancelled } }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            receivedFrames += Int(buffer.frameLength)
            receivedSampleRates.insert(buffer.format.sampleRate)
        }
    }

    func finish() async throws -> String { text }

    func cancel() { lock.withLock { wasCancelled = true } }
}

/// Fake backend: configurable support, start-segment errors thrown in order, and per-segment text; records start count, locales and segments.
nonisolated final class FakeSTTBackend: SystemSTTBackend, @unchecked Sendable {
    let kind: SystemSTTBackendKind
    let requiresRolling: Bool
    private let supported: Bool
    private let lock = NSLock()
    private var startErrors: [SystemSTTBackendError]
    private let texts: [String]
    private var startedSegments: [FakeSTTSegment] = []
    private var starts = 0
    private var requestedLocales: [Locale] = []

    init(
        _ kind: SystemSTTBackendKind,
        supported: Bool = true,
        startErrors: [SystemSTTBackendError] = [],
        texts: [String] = []
    ) {
        self.kind = kind
        self.requiresRolling = kind == .speechRecognizer
        self.supported = supported
        self.startErrors = startErrors
        self.texts = texts
    }

    var startCount: Int { lock.withLock { starts } }
    var segments: [FakeSTTSegment] { lock.withLock { startedSegments } }
    var locales: [Locale] { lock.withLock { requestedLocales } }

    func supports(_ locale: Locale) async -> Bool { supported }

    func startSegment(locale: Locale, format: AVAudioFormat) async throws -> any SystemSTTSegment {
        try lock.withLock {
            starts += 1
            requestedLocales.append(locale)
            if !startErrors.isEmpty { throw startErrors.removeFirst() }
            let index = startedSegments.count
            let segment = FakeSTTSegment(text: index < texts.count ? texts[index] : "\(kind.rawValue)\(index + 1)")
            startedSegments.append(segment)
            return segment
        }
    }
}

/// Fake backend that records ordering: a segment's finish suspends for a while and returns empty text if the next segment has been opened in the meantime (simulating the system recognizer dropping words from the old segment when two segments run in parallel).
nonisolated final class SequencedSTTBackend: SystemSTTBackend, @unchecked Sendable {
    let kind: SystemSTTBackendKind = .speechRecognizer
    let requiresRolling = true
    private let lock = NSLock()
    private let texts: [String]
    private var opened = 0
    private var log: [String] = []

    init(texts: [String]) { self.texts = texts }

    var events: [String] { lock.withLock { log } }
    var openCount: Int { lock.withLock { opened } }

    func record(_ event: String) { lock.withLock { log.append(event) } }

    func supports(_ locale: Locale) async -> Bool { true }

    func startSegment(locale: Locale, format: AVAudioFormat) async throws -> any SystemSTTSegment {
        let index = lock.withLock { () -> Int in
            opened += 1
            log.append("open\(opened)")
            return opened
        }
        return SequencedSTTSegment(backend: self, index: index, text: index <= texts.count ? texts[index - 1] : "")
    }
}

nonisolated final class SequencedSTTSegment: SystemSTTSegment, @unchecked Sendable {
    private let backend: SequencedSTTBackend
    private let index: Int
    private let text: String

    init(backend: SequencedSTTBackend, index: Int, text: String) {
        self.backend = backend
        self.index = index
        self.text = text
    }

    func append(_ buffer: AVAudioPCMBuffer) {}

    func finish() async throws -> String {
        try await Task.sleep(for: .milliseconds(100))
        let overlapped = backend.openCount > index
        backend.record("finished\(index)")
        return overlapped ? "" : text
    }

    func cancel() {}
}

/// Fake backend whose first segment's finish hangs and only returns with CancellationError on cancel; records the number of segments opened.
nonisolated final class HangingFinishSTTBackend: SystemSTTBackend, @unchecked Sendable {
    let kind: SystemSTTBackendKind = .speechRecognizer
    let requiresRolling = true
    private let lock = NSLock()
    private var opened = 0
    private var finishing = false

    var openCount: Int { lock.withLock { opened } }
    var isFinishing: Bool { lock.withLock { finishing } }

    func markFinishing() { lock.withLock { finishing = true } }

    func supports(_ locale: Locale) async -> Bool { true }

    func startSegment(locale: Locale, format: AVAudioFormat) async throws -> any SystemSTTSegment {
        lock.withLock { opened += 1 }
        return HangingFinishSTTSegment(backend: self)
    }
}

nonisolated final class HangingFinishSTTSegment: SystemSTTSegment, @unchecked Sendable {
    private let backend: HangingFinishSTTBackend
    private let lock = NSLock()
    private var waiter: CheckedContinuation<String, Error>?
    private var cancelled = false

    init(backend: HangingFinishSTTBackend) { self.backend = backend }

    func append(_ buffer: AVAudioPCMBuffer) {}

    func finish() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if cancelled { return true }
                waiter = continuation
                return false
            }
            backend.markFinishing()
            if resumeNow { continuation.resume(throwing: CancellationError()) }
        }
    }

    func cancel() {
        let pending = lock.withLock { () -> CheckedContinuation<String, Error>? in
            cancelled = true
            defer { waiter = nil }
            return waiter
        }
        pending?.resume(throwing: CancellationError())
    }
}

nonisolated final class FakeSpeechAuthorizer: SpeechAuthorizing, @unchecked Sendable {
    private let lock = NSLock()
    private let authorized: Bool
    private let grants: Bool
    private var requests = 0

    init(authorized: Bool, grants: Bool = true) {
        self.authorized = authorized
        self.grants = grants
    }

    var requestCount: Int { lock.withLock { requests } }
    var isAuthorized: Bool { authorized }

    func requestAuthorization() async -> Bool {
        lock.withLock { requests += 1 }
        return grants
    }
}

/// System dictation engine: backend selection, follow-up authorization requests, rolling restart stitching, and re-recognition from a slot file.
@Suite("System STT engine", .timeLimit(.minutes(1)))
struct SystemSTTEngineTests {

    private static let rate = 16_000.0
    private static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    /// A constant 0.1 = -20 dBFS, above the voiced threshold.
    private static let voicedLevel: Float = 0.1

    /// Generates mono buffers in 0.1 s chunks from (seconds, voiced) pairs.
    private static func buffers(_ pattern: [(sec: Double, voiced: Bool)]) -> [AVAudioPCMBuffer] {
        let chunk = Int(rate / 10)
        var result: [AVAudioPCMBuffer] = []
        for part in pattern {
            var remaining = Int((part.sec * rate).rounded())
            while remaining > 0 {
                let frames = min(chunk, remaining)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
                buffer.frameLength = AVAudioFrameCount(frames)
                let value = part.voiced ? voicedLevel : 0
                for frame in 0..<frames { buffer.floatChannelData![0][frame] = value }
                result.append(buffer)
                remaining -= frames
            }
        }
        return result
    }

    private static func makeEngine(
        analyzer: Bool,
        speech: FakeSTTBackend = FakeSTTBackend(.speechTranscriber),
        dictation: FakeSTTBackend = FakeSTTBackend(.dictationTranscriber),
        recognizer: FakeSTTBackend = FakeSTTBackend(.speechRecognizer),
        authorizer: FakeSpeechAuthorizer = FakeSpeechAuthorizer(authorized: true),
        defaultLocale: Locale = Locale(identifier: "en-US")
    ) -> SystemSTTEngine {
        SystemSTTEngine(
            speechTranscriber: speech,
            dictationTranscriber: dictation,
            speechRecognizer: recognizer,
            analyzerAvailable: analyzer,
            authorizer: authorizer,
            defaultLocale: { defaultLocale }
        )
    }

    private static func live(
        _ engine: SystemSTTEngine,
        language: String? = "en-US",
        _ pattern: [(sec: Double, voiced: Bool)] = [(1, true)]
    ) async throws -> String {
        let session = engine.startLive(language: language, format: format)
        for buffer in buffers(pattern) { session.feed(buffer) }
        return try await session.finish()
    }

    // MARK: Paths

    @Test("iOS 26+ with SpeechTranscriber supported: use only it and leave the other two untouched")
    func analyzerPrefersSpeechTranscriber() async throws {
        let speech = FakeSTTBackend(.speechTranscriber, texts: ["hello"])
        let dictation = FakeSTTBackend(.dictationTranscriber)
        let recognizer = FakeSTTBackend(.speechRecognizer)
        let engine = Self.makeEngine(analyzer: true, speech: speech, dictation: dictation, recognizer: recognizer)
        #expect(try await Self.live(engine) == "hello")
        #expect(speech.startCount == 1)
        #expect(dictation.startCount == 0)
        #expect(recognizer.startCount == 0)
        #expect(speech.segments.first?.frames == Int(Self.rate))
    }

    @Test("iOS 26+ with SpeechTranscriber unsupported: fall back to DictationTranscriber")
    func unsupportedFallsBackToDictation() async throws {
        let speech = FakeSTTBackend(.speechTranscriber, supported: false)
        let dictation = FakeSTTBackend(.dictationTranscriber, texts: ["dictated"])
        let recognizer = FakeSTTBackend(.speechRecognizer)
        let engine = Self.makeEngine(analyzer: true, speech: speech, dictation: dictation, recognizer: recognizer)
        #expect(try await Self.live(engine) == "dictated")
        #expect(speech.startCount == 0)
        #expect(dictation.startCount == 1)
        #expect(recognizer.startCount == 0)
    }

    @Test("iOS 26+ asset not found falls through DictationTranscriber and then SFSpeechRecognizer")
    func assetNotFoundFallsThroughChain() async throws {
        let speech = FakeSTTBackend(.speechTranscriber, startErrors: [.assetNotFound])
        let dictation = FakeSTTBackend(.dictationTranscriber, startErrors: [.assetNotFound])
        let recognizer = FakeSTTBackend(.speechRecognizer, texts: ["legacy"])
        let engine = Self.makeEngine(analyzer: true, speech: speech, dictation: dictation, recognizer: recognizer)
        #expect(try await Self.live(engine) == "legacy")
        #expect(speech.startCount == 1)
        #expect(dictation.startCount == 1)
        #expect(recognizer.startCount == 1)

        let unsupported = FakeSTTBackend(.speechTranscriber, supported: false)
        let missing = FakeSTTBackend(.dictationTranscriber, startErrors: [.assetNotFound])
        let fallback = FakeSTTBackend(.speechRecognizer, texts: ["legacy"])
        let second = Self.makeEngine(analyzer: true, speech: unsupported, dictation: missing, recognizer: fallback)
        #expect(try await Self.live(second) == "legacy")
        #expect(missing.startCount == 1)
        #expect(fallback.startCount == 1)
    }

    @Test("iOS 18-25 uses SFSpeechRecognizer only, even if the Analyzer backends are both supported")
    func legacyUsesSpeechRecognizerOnly() async throws {
        let speech = FakeSTTBackend(.speechTranscriber)
        let dictation = FakeSTTBackend(.dictationTranscriber)
        let recognizer = FakeSTTBackend(.speechRecognizer, texts: ["legacy"])
        let authorizer = FakeSpeechAuthorizer(authorized: true)
        let engine = Self.makeEngine(
            analyzer: false, speech: speech, dictation: dictation, recognizer: recognizer, authorizer: authorizer
        )
        #expect(try await Self.live(engine) == "legacy")
        #expect(speech.startCount == 0)
        #expect(dictation.startCount == 0)
        #expect(recognizer.startCount == 1)
        #expect(authorizer.requestCount == 0)
    }

    @Test("iOS 26+ backend reports unavailable on segment start: move to the next backend; fail when the last one is unavailable too")
    func analyzerUnavailableFallsBackToLegacy() async throws {
        let speech = FakeSTTBackend(.speechTranscriber, supported: false)
        let dictation = FakeSTTBackend(.dictationTranscriber, startErrors: [.unavailable])
        let recognizer = FakeSTTBackend(.speechRecognizer, texts: ["legacy"])
        let engine = Self.makeEngine(analyzer: true, speech: speech, dictation: dictation, recognizer: recognizer)
        #expect(try await Self.live(engine) == "legacy")
        #expect(dictation.startCount == 1)
        #expect(recognizer.startCount == 1)

        let allUnavailable = Self.makeEngine(
            analyzer: true,
            speech: FakeSTTBackend(.speechTranscriber, startErrors: [.unavailable]),
            dictation: FakeSTTBackend(.dictationTranscriber, startErrors: [.unavailable]),
            recognizer: FakeSTTBackend(.speechRecognizer, startErrors: [.unavailable])
        )
        await #expect(throws: STTError(action: .retry, failure: nil)) { try await Self.live(allUnavailable) }
    }

    @Test("No backend available: STTError(retry)")
    func noBackendFails() async {
        let engine = Self.makeEngine(
            analyzer: true,
            speech: FakeSTTBackend(.speechTranscriber, supported: false),
            dictation: FakeSTTBackend(.dictationTranscriber, supported: false),
            recognizer: FakeSTTBackend(.speechRecognizer, supported: false)
        )
        await #expect(throws: STTError(action: .retry, failure: nil)) { try await Self.live(engine) }
    }

    // MARK: Authorization

    @Test("iOS 26+ does not request speech recognition authorization upfront")
    func analyzerDoesNotRequestAuthorizationUpfront() async throws {
        let authorizer = FakeSpeechAuthorizer(authorized: false)
        let engine = Self.makeEngine(analyzer: true, authorizer: authorizer)
        _ = try await Self.live(engine)
        #expect(authorizer.requestCount == 0)
    }

    @Test("iOS 26+ authorization error: request authorization once and retry the same backend once")
    func authorizationErrorRequestsOnceAndRetries() async throws {
        let speech = FakeSTTBackend(.speechTranscriber, startErrors: [.notAuthorized], texts: ["after"])
        let authorizer = FakeSpeechAuthorizer(authorized: false)
        let engine = Self.makeEngine(analyzer: true, speech: speech, authorizer: authorizer)
        #expect(try await Self.live(engine) == "after")
        #expect(authorizer.requestCount == 1)
        #expect(speech.startCount == 2)
    }

    @Test("iOS 26+ authorization error again after the follow-up request: fail without requesting again")
    func authorizationErrorTwiceFails() async {
        let speech = FakeSTTBackend(.speechTranscriber, startErrors: [.notAuthorized, .notAuthorized])
        let dictation = FakeSTTBackend(.dictationTranscriber)
        let authorizer = FakeSpeechAuthorizer(authorized: false)
        let engine = Self.makeEngine(analyzer: true, speech: speech, dictation: dictation, authorizer: authorizer)
        await #expect(throws: STTError(action: .retry, failure: nil)) { try await Self.live(engine) }
        #expect(authorizer.requestCount == 1)
        #expect(speech.startCount == 2)
        #expect(dictation.startCount == 0)
    }

    @Test("iOS 18-25 requires authorization upfront: denial fails without starting a segment, approval continues")
    func legacyRequiresAuthorizationUpfront() async throws {
        let deniedRecognizer = FakeSTTBackend(.speechRecognizer)
        let denied = FakeSpeechAuthorizer(authorized: false, grants: false)
        let deniedEngine = Self.makeEngine(analyzer: false, recognizer: deniedRecognizer, authorizer: denied)
        await #expect(throws: STTError(action: .retry, failure: nil)) { try await Self.live(deniedEngine) }
        #expect(denied.requestCount == 1)
        #expect(deniedRecognizer.startCount == 0)

        let recognizer = FakeSTTBackend(.speechRecognizer, texts: ["granted"])
        let granted = FakeSpeechAuthorizer(authorized: false, grants: true)
        let engine = Self.makeEngine(analyzer: false, recognizer: recognizer, authorizer: granted)
        #expect(try await Self.live(engine) == "granted")
        #expect(granted.requestCount == 1)
    }

    // MARK: Rolling

    @Test("Restart at the first silent window once a segment reaches 50 s; silence before 50 s does not restart")
    func rollsAtFirstSilenceAfterSoftLimit() async throws {
        let recognizer = FakeSTTBackend(.speechRecognizer)
        let engine = Self.makeEngine(analyzer: false, recognizer: recognizer)
        _ = try await Self.live(engine, [(30, true), (1, false), (21, true), (0.5, false), (1, true)])
        let segments = recognizer.segments
        #expect(segments.count == 2)
        // Cut at the end of the first 0.05 s silent window after 52 s of voiced audio
        #expect(segments.first?.frames == Int(52.05 * Self.rate))
        #expect(segments.last?.frames == Int(53.5 * Self.rate) - Int(52.05 * Self.rate))
    }

    @Test("Still no silence at 58 s: hard restart")
    func hardRestartAtHardLimit() async throws {
        let recognizer = FakeSTTBackend(.speechRecognizer)
        let engine = Self.makeEngine(analyzer: false, recognizer: recognizer)
        _ = try await Self.live(engine, [(60, true)])
        let frames = recognizer.segments.map(\.frames)
        #expect(frames == [Int(58 * Self.rate), Int(2 * Self.rate)])
    }

    @Test("Rolling segment cut: the new segment opens only after the old segment's final text arrives, and both texts are kept")
    func rollWaitsForPreviousSegmentFinal() async throws {
        let backend = SequencedSTTBackend(texts: ["First part.", "Second part."])
        let engine = SystemSTTEngine(
            speechTranscriber: nil,
            dictationTranscriber: nil,
            speechRecognizer: backend,
            analyzerAvailable: false,
            authorizer: FakeSpeechAuthorizer(authorized: true),
            defaultLocale: { Locale(identifier: "en-US") }
        )
        let session = engine.startLive(language: "en-US", format: Self.format)
        for buffer in Self.buffers([(60, true)]) { session.feed(buffer) }
        let text = try await session.finish()
        let events = backend.events
        let open2 = try #require(events.firstIndex(of: "open2"))
        let finished1 = try #require(events.firstIndex(of: "finished1"))
        #expect(finished1 < open2, "events \(events)")
        #expect(text == DictationRules.join(["First part.", "Second part."]))
    }

    @Test("Cancelling while a rolling cut waits for the old segment's final: CancellationError is thrown quickly and no second segment opens")
    func cancelWhileAwaitingPreviousSegmentFinal() async throws {
        let backend = HangingFinishSTTBackend()
        let engine = SystemSTTEngine(
            speechTranscriber: nil,
            dictationTranscriber: nil,
            speechRecognizer: backend,
            analyzerAvailable: false,
            authorizer: FakeSpeechAuthorizer(authorized: true),
            defaultLocale: { Locale(identifier: "en-US") }
        )
        let session = engine.startLive(language: "en-US", format: Self.format)
        for buffer in Self.buffers([(60, true)]) { session.feed(buffer) }
        let deadline = ContinuousClock.now + .seconds(5)
        while !backend.isFinishing, ContinuousClock.now < deadline { await Task.yield() }
        #expect(backend.isFinishing)

        let cancelledAt = ContinuousClock.now
        session.cancel()
        await #expect(throws: CancellationError.self) { try await session.finish() }
        #expect(ContinuousClock.now - cancelledAt < .seconds(1))
        #expect(backend.openCount == 1)
    }

    @Test("The SpeechAnalyzer backend does not roll")
    func analyzerDoesNotRoll() async throws {
        let speech = FakeSTTBackend(.speechTranscriber)
        let engine = Self.makeEngine(analyzer: true, speech: speech)
        _ = try await Self.live(engine, [(60, true)])
        #expect(speech.segments.map(\.frames) == [Int(60 * Self.rate)])
    }

    @Test("Segment texts are stitched with DictationRules.join")
    func segmentsJoinWithDictationRules() async throws {
        let latin = FakeSTTBackend(.speechRecognizer, texts: ["Hello world. ", " how are you?"])
        let latinEngine = Self.makeEngine(analyzer: false, recognizer: latin)
        let latinText = try await Self.live(latinEngine, [(60, true)])
        #expect(latinText == DictationRules.join(["Hello world. ", " how are you?"]))
        #expect(latinText == "Hello world. how are you?")

        let cjk = FakeSTTBackend(.speechRecognizer, texts: ["\u{4F60}\u{597D}\u{3002}", "\u{4ECA}\u{5929}\u{5929}\u{6C14}\u{4E0D}\u{9519}"])
        let cjkEngine = Self.makeEngine(analyzer: false, recognizer: cjk)
        #expect(try await Self.live(cjkEngine, [(60, true)]) == "\u{4F60}\u{597D}\u{3002}\u{4ECA}\u{5929}\u{5929}\u{6C14}\u{4E0D}\u{9519}")
    }

    // MARK: Language and input

    @Test("A nil recognition language uses the default language, which is the app's UI language")
    @MainActor
    func nilLanguageUsesAppLanguage() async throws {
        let recognizer = FakeSTTBackend(.speechRecognizer)
        let engine = Self.makeEngine(analyzer: false, recognizer: recognizer, defaultLocale: Locale(identifier: "fr-FR"))
        _ = try await Self.live(engine, language: nil)
        _ = try await Self.live(engine, language: "de-DE")
        #expect(recognizer.locales.map { $0.identifier(.bcp47) } == ["fr-FR", "de-DE"])
        #expect(await SystemSTTEngine.appLocale() == AppLocalization.currentLanguage.locale)
    }

    @Test("bufferHandler copies the buffer before feeding recognition")
    func bufferHandlerFeedsCopies() async throws {
        let speech = FakeSTTBackend(.speechTranscriber)
        let engine = Self.makeEngine(analyzer: true, speech: speech)
        let session = engine.startLive(language: "en-US", format: Self.format)
        let handler = session.bufferHandler
        let time = AVAudioTime(sampleTime: 0, atRate: Self.rate)
        for buffer in Self.buffers([(2, true)]) {
            handler(buffer, time)
            buffer.frameLength = 0
        }
        _ = try await session.finish()
        #expect(speech.segments.first?.frames == Int(2 * Self.rate))
    }

    @Test("Re-recognition from a slot file: reads back the whole 16 kHz PCM and keeps the file")
    func transcribesRecordingFile() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "SystemSTTEngineTests-\(UUID().uuidString).aac")
        defer { try? FileManager.default.removeItem(at: url) }
        let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let writer = try RecordingWriter(url: url, inputFormat: input)
        for _ in 0..<20 {
            let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 4800)!
            buffer.frameLength = 4800
            for frame in 0..<4800 { buffer.floatChannelData![0][frame] = Self.voicedLevel }
            try writer.append(buffer)
        }
        let recording = try writer.close()

        let recognizer = FakeSTTBackend(.speechRecognizer, texts: ["from file"])
        let engine = Self.makeEngine(analyzer: false, recognizer: recognizer)
        #expect(try await engine.transcribe(recording, language: "en-US") == "from file")
        let segment = try #require(recognizer.segments.first)
        #expect(segment.sampleRates == [Double(DictationRules.recordingSampleRateHz)])
        let expected = Int(recording.durationSec * Double(DictationRules.recordingSampleRateHz))
        // ADTS does not record encoder priming, so decoding yields about 2112 extra frames, padded to a 1024-frame boundary
        #expect((expected...(expected + 4096)).contains(segment.frames), "frames \(segment.frames) vs \(expected)")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Unreadable slot file: STTError(retry), flagged as audio unreadable")
    func unreadableRecordingFails() async {
        let missing = RecordingResult(
            url: FileManager.default.temporaryDirectory.appending(path: "missing-\(UUID().uuidString).aac"),
            durationSec: 1,
            envelope: []
        )
        let engine = Self.makeEngine(analyzer: false)
        await #expect(throws: STTError(action: .retry, failure: nil, audioUnreadable: true)) {
            try await engine.transcribe(missing, language: "en-US")
        }
    }
}

// MARK: - Assets

nonisolated final class FakeSpeechAssetInventory: SpeechAssetInventory, @unchecked Sendable {
    typealias InstallHook = @Sendable (@escaping @MainActor @Sendable (Double) -> Void) async throws -> Void

    private let lock = NSLock()
    private let maximum: Int
    private var reservedList: [Locale]
    private var installedKeys: Set<String> = []
    private var releasedKeys: [String] = []
    private var installs = 0
    private var failuresLeft: Int
    private var hook: InstallHook?
    private var reservedHang: NeverReturningCall?

    init(maximum: Int, reserved: [Locale] = [], installFailures: Int = 0) {
        self.maximum = maximum
        self.reservedList = reserved
        self.failuresLeft = installFailures
    }

    var released: [String] { lock.withLock { releasedKeys } }
    var reserved: [String] { lock.withLock { reservedList.map(SpeechAssetManager.localeKey) } }
    var installCount: Int { lock.withLock { installs } }

    func setInstallHook(_ hook: @escaping InstallHook) { lock.withLock { self.hook = hook } }
    /// When non-nil, reservedLocales parks on it and never returns.
    func setReservedLocalesHang(_ hang: NeverReturningCall?) { lock.withLock { reservedHang = hang } }

    func maximumReservedLocales() async -> Int { maximum }
    func reservedLocales() async -> [Locale] {
        if let hang = lock.withLock({ reservedHang }) { await hang.hang() }
        return lock.withLock { reservedList }
    }

    func reserve(_ locale: Locale) async throws {
        lock.withLock { reservedList.append(locale) }
    }

    func release(_ locale: Locale) async {
        lock.withLock {
            let key = SpeechAssetManager.localeKey(locale)
            releasedKeys.append(key)
            reservedList.removeAll { SpeechAssetManager.localeKey($0) == key }
        }
    }

    func isInstalled(_ module: SpeechAssetModule, locale: Locale) async -> Bool {
        lock.withLock { installedKeys.contains(SpeechAssetManager.stateKey(module, locale: locale)) }
    }

    func install(
        _ module: SpeechAssetModule,
        locale: Locale,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        let (hook, shouldFail) = lock.withLock { () -> (InstallHook?, Bool) in
            installs += 1
            let fail = failuresLeft > 0
            if fail { failuresLeft -= 1 }
            return (self.hook, fail)
        }
        try await hook?(progress)
        if shouldFail { throw URLError(.networkConnectionLost) }
        lock.withLock { _ = installedKeys.insert(SpeechAssetManager.stateKey(module, locale: locale)) }
    }
}

/// Stand-in for a system call that never returns and ignores cancellation; releaseAll frees the parked calls at the end of a test so no continuation leaks.
nonisolated final class NeverReturningCall: @unchecked Sendable {
    private let lock = NSLock()
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var calls = 0

    var callCount: Int { lock.withLock { calls } }

    func hang() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                calls += 1
                parked.append(continuation)
            }
        }
    }

    func releaseAll() {
        let all = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { parked = [] }
            return parked
        }
        all.forEach { $0.resume() }
    }
}

nonisolated final class SpeechAssetStateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [SpeechAssetInstallState] = []
    private var changed = false

    var states: [SpeechAssetInstallState] { lock.withLock { entries } }
    var didChange: Bool { lock.withLock { changed } }

    func append(_ state: SpeechAssetInstallState) { lock.withLock { entries.append(state) } }
    func markChanged() { lock.withLock { changed = true } }
}

/// Assets: SpeechAssetManager's reservation limit, recent use, progress, and failure retry.
@MainActor
extension SystemSTTEngineTests {

    private var defaults: UserDefaults { UserDefaults(suiteName: "SpeechAssetManagerTests-\(UUID().uuidString)")! }
    private var english: Locale { Locale(identifier: "en-US") }
    private var french: Locale { Locale(identifier: "fr-FR") }
    private var german: Locale { Locale(identifier: "de-DE") }

    @Test("At the reservation limit: release the least recently used first, then reserve")
    func releasesLeastRecentlyUsedAtLimit() async throws {
        let inventory = FakeSpeechAssetInventory(maximum: 2)
        var clock = 100.0
        let manager = SpeechAssetManager(inventory: inventory, defaults: defaults, now: { Date(timeIntervalSince1970: clock) })

        try await manager.prepare(.speechTranscriber, locale: english)
        clock = 200
        try await manager.prepare(.speechTranscriber, locale: french)
        clock = 300
        try await manager.prepare(.speechTranscriber, locale: german)
        #expect(inventory.released == ["en-US"])
        #expect(inventory.reserved == ["fr-FR", "de-DE"])

        // An already reserved language only refreshes its last-used time and does not trigger a release
        clock = 400
        try await manager.prepare(.speechTranscriber, locale: french)
        #expect(inventory.released == ["en-US"])
        clock = 500
        try await manager.prepare(.speechTranscriber, locale: english)
        #expect(inventory.released == ["en-US", "de-DE"])
        #expect(manager.lastUsed()["en-US"] == 500)
        #expect(manager.lastUsed()["fr-FR"] == 400)
    }

    @Test("A reserved language with no recorded use time is released first")
    func unknownReservationReleasedFirst() async throws {
        let inventory = FakeSpeechAssetInventory(maximum: 1, reserved: [french])
        let manager = SpeechAssetManager(inventory: inventory, defaults: defaults, now: { Date(timeIntervalSince1970: 10) })
        try await manager.prepare(.dictationTranscriber, locale: english)
        #expect(inventory.released == ["fr-FR"])
        #expect(inventory.reserved == ["en-US"])
    }

    @Test("Install progress is observable: installing(fraction) then installed")
    func installProgressIsObservable() async throws {
        let inventory = FakeSpeechAssetInventory(maximum: 4)
        let manager = SpeechAssetManager(inventory: inventory, defaults: defaults)
        let log = SpeechAssetStateLog()
        let english = english
        inventory.setInstallHook { progress in
            await progress(0.4)
            let state = await manager.state(.speechTranscriber, locale: english)
            log.append(state)
        }
        withObservationTracking {
            _ = manager.state(.speechTranscriber, locale: english)
        } onChange: {
            log.markChanged()
        }

        #expect(manager.state(.speechTranscriber, locale: english) == .notInstalled)
        try await manager.prepare(.speechTranscriber, locale: english)
        #expect(log.states == [.installing(fraction: 0.4)])
        #expect(log.didChange)
        #expect(manager.state(.speechTranscriber, locale: english) == .installed)
        #expect(manager.state(.dictationTranscriber, locale: english) == .notInstalled)

        // Already installed: no further download
        try await manager.prepare(.speechTranscriber, locale: english)
        #expect(inventory.installCount == 1)
    }

    @Test("A failed install is marked failed and throws; preparing again reinstalls")
    func failedInstallCanRetry() async throws {
        let inventory = FakeSpeechAssetInventory(maximum: 4, installFailures: 1)
        let manager = SpeechAssetManager(inventory: inventory, defaults: defaults)
        await #expect(throws: SpeechAssetError.installFailed) {
            try await manager.prepare(.speechTranscriber, locale: english)
        }
        #expect(manager.state(.speechTranscriber, locale: english) == .failed)

        try await manager.prepare(.speechTranscriber, locale: english)
        #expect(manager.state(.speechTranscriber, locale: english) == .installed)
        #expect(inventory.installCount == 2)
    }

    @Test("VoiceDeadline: cancelling the outer task returns well before the limit; value is nil and run throws CancellationError")
    func deadlineReturnsPromptlyWhenOuterTaskCancelled() async {
        let hang = NeverReturningCall()
        defer { hang.releaseAll() }
        let started = ContinuousClock.now
        let valueTask = Task { () -> Int? in
            await VoiceDeadline.value(within: .seconds(30)) {
                await hang.hang()
                return 1
            }
        }
        let runTask = Task { () -> Error? in
            do {
                _ = try await VoiceDeadline.run(within: .seconds(30)) {
                    await hang.hang()
                    return 1
                }
                return nil
            } catch {
                return error
            }
        }
        // Both calls are parked; now cancel the outer tasks.
        while hang.callCount < 2 { await Task.yield() }
        valueTask.cancel()
        runTask.cancel()

        #expect(await valueTask.value == nil)
        #expect(await runTask.value is CancellationError)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test("VoiceDeadline: when the timeout and the result arrive almost together, each call resumes exactly once and yields a value or nil")
    func deadlineResumesOnceWhenTimeoutAndResultRace() async {
        var values = 0
        var timeouts = 0
        for index in 0..<600 {
            let limit: Duration = index.isMultiple(of: 2) ? .zero : .nanoseconds(1)
            let result = await VoiceDeadline.value(within: limit) { index }
            switch result {
            case .some(let value):
                #expect(value == index)
                values += 1
            case .none:
                timeouts += 1
            }
        }
        #expect(values + timeouts == 600)
    }

    @Test("A reserved-list query that never returns: prepare ends in failure, inFlight is cleared, and calling prepare again runs it afresh")
    func inventoryQueryThatNeverReturnsFailsPrepare() async throws {
        let hang = NeverReturningCall()
        defer { hang.releaseAll() }
        let inventory = FakeSpeechAssetInventory(maximum: 4)
        inventory.setReservedLocalesHang(hang)
        let manager = SpeechAssetManager(inventory: inventory, defaults: defaults, queryLimit: .milliseconds(50))

        await #expect(throws: SpeechAssetError.reservationFailed) {
            try await manager.prepare(.speechTranscriber, locale: english)
        }
        #expect(manager.state(.speechTranscriber, locale: english) == .failed)
        #expect(hang.callCount == 1)

        // Not attached to the previous inFlight: the query runs again and times out again
        await #expect(throws: SpeechAssetError.reservationFailed) {
            try await manager.prepare(.speechTranscriber, locale: english)
        }
        #expect(hang.callCount == 2)

        inventory.setReservedLocalesHang(nil)
        try await manager.prepare(.speechTranscriber, locale: english)
        #expect(manager.state(.speechTranscriber, locale: english) == .installed)
        #expect(inventory.reserved == ["en-US"])
    }
}
