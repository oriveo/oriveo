import AVFoundation
import Foundation
import Speech

// MARK: - Backend protocol

/// System recognition backends: on iOS 26+ SpeechTranscriber -> DictationTranscriber -> SFSpeechRecognizer in turn; on iOS 18-25 only SFSpeechRecognizer.
nonisolated enum SystemSTTBackendKind: String, Sendable, Hashable {
    case speechTranscriber
    case dictationTranscriber
    case speechRecognizer
}

/// Classification of a backend failing to start a segment: unsupportedLocale / assetNotFound / unavailable move on to the next backend, notAuthorized requests authorization once and retries.
nonisolated enum SystemSTTBackendError: Error, Sendable, Hashable {
    case unsupportedLocale
    case assetNotFound
    case notAuthorized
    case unavailable
    case failed
}

/// One recognition segment: buffers are appended in order (serial calls), finish wraps up and returns the segment text; after cancel, finish throws CancellationError.
nonisolated protocol SystemSTTSegment: AnyObject, Sendable {
    func append(_ buffer: AVAudioPCMBuffer)
    func finish() async throws -> String
    func cancel()
}

nonisolated protocol SystemSTTBackend: Sendable {
    var kind: SystemSTTBackendKind { get }
    /// A single recognition task has a duration cap (about 1 minute for SFSpeechRecognizer), so it must be restarted on a rolling basis.
    var requiresRolling: Bool { get }
    func supports(_ locale: Locale) async -> Bool
    /// format is the format of the buffers fed in (the microphone inputFormat or the slot file's processingFormat).
    func startSegment(locale: Locale, format: AVAudioFormat) async throws -> any SystemSTTSegment
}

/// Speech recognition authorization (SFSpeechRecognizer.requestAuthorization).
nonisolated protocol SpeechAuthorizing: Sendable {
    var isAuthorized: Bool { get }
    /// true = the user has not answered yet; only then does requestAuthorization actually show the system prompt.
    var isUndetermined: Bool { get }
    func requestAuthorization() async -> Bool
}

extension SpeechAuthorizing {
    var isUndetermined: Bool { false }
}

// MARK: - Engine

/// System dictation: microphone buffers go to system recognition in real time (startLive), and after a
/// failure the slot's `.aac` can be re-recognized (transcribe).
/// On iOS 26+ it does not request speech recognition authorization up front; only when a backend reports
/// an authorization error does it call requestAuthorization once and retry once.
/// On iOS 18-25 authorization is needed from the start. A backend that needs rolling restarts at the first
/// silent window once the segment reaches rollingSoftLimitSec, hard-restarts at rollingHardLimitSec if
/// there is still no silence, and the segment texts are joined with DictationRules.join.
nonisolated final class SystemSTTEngine: STTEngine {

    static let rollingSoftLimitSec = 50.0
    static let rollingHardLimitSec = 58.0
    static let fileChunkFrames: AVAudioFrameCount = 4096

    typealias LocaleProvider = @Sendable () async -> Locale

    /// Uses the app UI language when the recognition language is nil.
    static let appLocale: LocaleProvider = {
        await MainActor.run { AppLocalization.currentLanguage.locale }
    }

    private let speechTranscriber: (any SystemSTTBackend)?
    private let dictationTranscriber: (any SystemSTTBackend)?
    private let speechRecognizer: any SystemSTTBackend
    private let analyzerAvailable: Bool
    private let authorizer: any SpeechAuthorizing
    private let defaultLocale: LocaleProvider

    /// When analyzerAvailable is false (iOS 18-25) only speechRecognizer is used.
    init(
        speechTranscriber: (any SystemSTTBackend)?,
        dictationTranscriber: (any SystemSTTBackend)?,
        speechRecognizer: any SystemSTTBackend,
        analyzerAvailable: Bool,
        authorizer: any SpeechAuthorizing,
        defaultLocale: @escaping LocaleProvider = SystemSTTEngine.appLocale
    ) {
        self.speechTranscriber = speechTranscriber
        self.dictationTranscriber = dictationTranscriber
        self.speechRecognizer = speechRecognizer
        self.analyzerAvailable = analyzerAvailable
        self.authorizer = authorizer
        self.defaultLocale = defaultLocale
    }

    static func makeDefault(assets: SpeechAssetManager) -> SystemSTTEngine {
        if #available(iOS 26, *) {
            return SystemSTTEngine(
                speechTranscriber: SpeechAnalyzerBackend(kind: .speechTranscriber, assets: assets),
                dictationTranscriber: SpeechAnalyzerBackend(kind: .dictationTranscriber, assets: assets),
                speechRecognizer: SFSpeechRecognizerBackend(),
                analyzerAvailable: true,
                authorizer: SystemSpeechAuthorizer()
            )
        }
        return SystemSTTEngine(
            speechTranscriber: nil,
            dictationTranscriber: nil,
            speechRecognizer: SFSpeechRecognizerBackend(),
            analyzerAvailable: false,
            authorizer: SystemSpeechAuthorizer()
        )
    }

    /// Starts one live recognition: hand session.bufferHandler to AudioCapture.start, then await finish() after recording stops.
    func startLive(language: String?, format: AVAudioFormat) -> SystemSTTSession {
        SystemSTTSession { [self] stream in
            try await run(stream, language: language, format: format)
        }
    }

    /// Re-recognizes from the slot file: reads PCM in chunks and goes through the same segmentation and
    /// joining as live recognition. The slot file is not deleted.
    /// File reading and segmentation run on a background executor, off the main thread (the caller is on the main actor).
    @concurrent
    func transcribe(_ recording: RecordingResult, language: String?) async throws -> String {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: recording.url)
        } catch {
            throw STTError(action: .retry, failure: nil, audioUnreadable: true)
        }
        let format = file.processingFormat
        let session = startLive(language: language, format: format)
        do {
            while file.framePosition < file.length {
                try Task.checkCancellation()
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.fileChunkFrames) else {
                    throw STTError(action: .retry, failure: nil)
                }
                try file.read(into: buffer)
                if buffer.frameLength == 0 { break }
                session.feed(buffer)
            }
        } catch {
            session.cancel()
            if error is CancellationError { throw error }
            throw STTError(action: .retry, failure: nil, audioUnreadable: true)
        }
        return try await withTaskCancellationHandler {
            try await session.finish()
        } onCancel: {
            session.cancel()
        }
    }

    // MARK: - Internals

    private var candidates: [any SystemSTTBackend] {
        guard analyzerAvailable else { return [speechRecognizer] }
        return [speechTranscriber, dictationTranscriber].compactMap { $0 } + [speechRecognizer]
    }

    private func resolveLocale(_ language: String?) async -> Locale {
        if let language, !language.isEmpty { return Locale(identifier: language) }
        return await defaultLocale()
    }

    /// When rolling over, first await the old segment to finish and get its text, then open the new one:
    /// running two system recognitions in parallel makes the old one return empty text.
    /// Buffers arriving while it finishes stay in the stream (unbounded buffering) and are fed in order
    /// after the new segment opens, so no frames are lost.
    private func run(_ stream: AsyncStream<PCMChunk>, language: String?, format: AVAudioFormat) async throws -> String {
        var texts: [String] = []
        var current: (any SystemSTTSegment)?
        do {
            let locale = await resolveLocale(language)
            let (backend, first) = try await openFirstSegment(locale: locale, format: format)
            current = first
            var meter = RollingMeter(sampleRate: format.sampleRate, enabled: backend.requiresRolling)
            for await chunk in stream {
                try Task.checkCancellation()
                let buffer = chunk.buffer
                let total = Int(buffer.frameLength)
                var start = 0
                for cut in meter.consume(buffer) {
                    if let piece = PCMBufferTools.slice(buffer, from: start, to: cut) { current?.append(piece) }
                    start = cut
                    if let old = current {
                        current = nil
                        texts.append(try await Self.finishSegment(old))
                    }
                    current = try await startNextSegment(backend, locale: locale, format: format)
                }
                if let piece = PCMBufferTools.slice(buffer, from: start, to: total) { current?.append(piece) }
            }
            try Task.checkCancellation()
            if let last = current {
                current = nil
                texts.append(try await Self.finishSegment(last))
            }
            return DictationRules.join(texts)
        } catch {
            current?.cancel()
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let error = error as? STTError { throw error }
            throw STTError(action: .retry, failure: nil)
        }
    }

    private static func finishSegment(_ segment: any SystemSTTSegment) async throws -> String {
        try await withTaskCancellationHandler {
            try await segment.finish()
        } onCancel: {
            segment.cancel()
        }
    }

    /// Picks a backend and opens the first segment: unsupported, asset not found or unavailable move on to the next; an authorization error requests authorization once and retries the same backend once.
    private func openFirstSegment(
        locale: Locale,
        format: AVAudioFormat
    ) async throws -> (any SystemSTTBackend, any SystemSTTSegment) {
        var authorizationRequested = false
        if !analyzerAvailable {
            authorizationRequested = true
            if !authorizer.isAuthorized {
                guard await authorizer.requestAuthorization() else { throw STTError(action: .retry, failure: nil) }
            }
        }
        backends: for backend in candidates {
            guard await backend.supports(locale) else { continue }
            while true {
                do {
                    return (backend, try await backend.startSegment(locale: locale, format: format))
                } catch let error as SystemSTTBackendError {
                    switch error {
                    case .unsupportedLocale, .assetNotFound, .unavailable:
                        continue backends
                    case .notAuthorized where !authorizationRequested:
                        authorizationRequested = true
                        _ = await authorizer.requestAuthorization()
                    default:
                        throw STTError(action: .retry, failure: nil)
                    }
                }
            }
        }
        throw STTError(action: .retry, failure: nil)
    }

    private func startNextSegment(
        _ backend: any SystemSTTBackend,
        locale: Locale,
        format: AVAudioFormat
    ) async throws -> any SystemSTTSegment {
        do {
            return try await backend.startSegment(locale: locale, format: format)
        } catch is SystemSTTBackendError {
            throw STTError(action: .retry, failure: nil)
        }
    }
}

// MARK: - Live session

/// A PCM chunk passed across threads: nothing else modifies it after it enters the stream.
nonisolated struct PCMChunk: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

/// One recognition session. On the audio thread bufferHandler only copies the buffer and enqueues it, without blocking; recognition runs serially in a background task.
nonisolated final class SystemSTTSession: Sendable {

    private let continuation: AsyncStream<PCMChunk>.Continuation
    private let task: Task<String, Error>

    init(run: @escaping @Sendable (AsyncStream<PCMChunk>) async throws -> String) {
        let (stream, continuation) = AsyncStream.makeStream(of: PCMChunk.self)
        self.continuation = continuation
        self.task = Task { try await run(stream) }
    }

    /// The consumer handed to AudioCapture.start; the tap reuses its buffers, so copy first.
    var bufferHandler: AudioBufferHandler {
        let continuation = continuation
        return { buffer, _ in
            guard let copy = PCMBufferTools.copy(buffer) else { return }
            continuation.yield(PCMChunk(buffer: copy))
        }
    }

    /// Feeds a buffer the caller will no longer modify (not copied).
    func feed(_ buffer: AVAudioPCMBuffer) {
        continuation.yield(PCMChunk(buffer: buffer))
    }

    /// Input is over; wait for the segments to finish and join them.
    func finish() async throws -> String {
        continuation.finish()
        return try await task.value
    }

    func cancel() {
        continuation.finish()
        task.cancel()
    }
}

// MARK: - Rolling meter

/// Counts in-segment duration by frames and forms silence windows by DictationRules.windowSec, returning
/// the frame offsets within this buffer at which to restart (the cut is after that frame).
/// Only non-interleaved float is analyzed; other formats hard-restart at buffer boundaries by frame count.
nonisolated struct RollingMeter {

    let enabled: Bool
    var windowFrames: Int { window.windowFrames }
    let softFrames: Int
    let hardFrames: Int

    private(set) var segmentFrames = 0
    private var window: DbfsWindowAccumulator

    init(
        sampleRate: Double,
        enabled: Bool,
        softSec: Double = SystemSTTEngine.rollingSoftLimitSec,
        hardSec: Double = SystemSTTEngine.rollingHardLimitSec
    ) {
        self.enabled = enabled
        self.window = DbfsWindowAccumulator(windowFrames: max(1, Int((sampleRate * DictationRules.windowSec).rounded())))
        self.softFrames = Int((sampleRate * softSec).rounded())
        self.hardFrames = max(1, Int((sampleRate * hardSec).rounded()))
    }

    mutating func consume(_ buffer: AVAudioPCMBuffer) -> [Int] {
        let frames = Int(buffer.frameLength)
        guard enabled, frames > 0 else { return [] }
        guard let data = buffer.floatChannelData, !buffer.format.isInterleaved else {
            segmentFrames += frames
            guard segmentFrames >= hardFrames else { return [] }
            reset()
            return [frames]
        }
        let channels = Int(buffer.format.channelCount)
        let scale = 1.0 / Double(channels)
        var cuts: [Int] = []
        for frame in 0..<frames {
            var sum = 0.0
            for channel in 0..<channels { sum += Double(data[channel][frame]) }
            let sample = sum * scale
            let windowFull = window.add(sample)
            segmentFrames += 1
            var cut = false
            if windowFull {
                let silent = !DictationRules.isVoiced(window.take())
                if silent, segmentFrames >= softFrames { cut = true }
            }
            if segmentFrames >= hardFrames { cut = true }
            if cut {
                cuts.append(frame + 1)
                reset()
            }
        }
        return cuts
    }

    private mutating func reset() {
        segmentFrames = 0
        window.reset()
    }
}

nonisolated enum PCMBufferTools {

    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: max(buffer.frameLength, 1)) else {
            return nil
        }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, target) {
            guard let fromData = from.mData, let toData = to.mData else { continue }
            memcpy(toData, fromData, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }

    /// Frames [from, to); the whole buffer is returned as is, an empty range returns nil; slicing supports only non-interleaved float.
    static func slice(_ buffer: AVAudioPCMBuffer, from: Int, to: Int) -> AVAudioPCMBuffer? {
        guard to > from else { return nil }
        if from == 0, to == Int(buffer.frameLength) { return buffer }
        let count = to - from
        guard let source = buffer.floatChannelData, !buffer.format.isInterleaved,
              let piece = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(count)),
              let target = piece.floatChannelData
        else { return nil }
        for channel in 0..<Int(buffer.format.channelCount) {
            target[channel].update(from: source[channel] + from, count: count)
        }
        piece.frameLength = AVAudioFrameCount(count)
        return piece
    }
}

// MARK: - Production: authorization

nonisolated struct SystemSpeechAuthorizer: SpeechAuthorizing {
    var isAuthorized: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }
    var isUndetermined: Bool { SFSpeechRecognizer.authorizationStatus() == .notDetermined }

    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}

// MARK: - Production: SFSpeechRecognizer

nonisolated struct SFSpeechRecognizerBackend: SystemSTTBackend {
    var kind: SystemSTTBackendKind { .speechRecognizer }
    var requiresRolling: Bool { true }

    func supports(_ locale: Locale) async -> Bool {
        SFSpeechRecognizer(locale: locale) != nil
    }

    func startSegment(locale: Locale, format: AVAudioFormat) async throws -> any SystemSTTSegment {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { throw SystemSTTBackendError.notAuthorized }
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { throw SystemSTTBackendError.unsupportedLocale }
        guard recognizer.isAvailable else { throw SystemSTTBackendError.unavailable }
        return SFSpeechRecognizerSegment(recognizer: recognizer)
    }
}

nonisolated final class SFSpeechRecognizerSegment: SystemSTTSegment, @unchecked Sendable {

    /// kAFAssistantErrorDomain 1110: no speech heard in this segment, treated as empty text (common after a rolling restart on a silent stretch).
    static let noSpeechDomain = "kAFAssistantErrorDomain"
    static let noSpeechCode = 1110

    private let request = SFSpeechAudioBufferRecognitionRequest()
    private let lock = NSLock()
    private var task: SFSpeechRecognitionTask?
    private var outcome: Result<String, Error>?
    private var waiter: CheckedContinuation<String, Error>?

    init(recognizer: SFSpeechRecognizer) {
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handle(result: result, error: error)
        }
        lock.lock()
        self.task = task
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        request.append(buffer)
    }

    func finish() async throws -> String {
        request.endAudio()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let outcome {
                    lock.unlock()
                    continuation.resume(with: outcome)
                } else {
                    waiter = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        lock.lock()
        let task = task
        lock.unlock()
        task?.cancel()
        resolve(.failure(CancellationError()))
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result, result.isFinal {
            resolve(.success(result.bestTranscription.formattedString))
        } else if let error {
            let nsError = error as NSError
            if nsError.domain == Self.noSpeechDomain, nsError.code == Self.noSpeechCode {
                resolve(.success(""))
            } else {
                resolve(.failure(SystemSTTBackendError.failed))
            }
        }
    }

    private func resolve(_ value: Result<String, Error>) {
        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            return
        }
        outcome = value
        let waiter = waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(with: value)
    }
}

// MARK: - Production: SpeechAnalyzer (iOS 26+)

@available(iOS 26, *)
nonisolated struct SpeechAnalyzerBackend: SystemSTTBackend {

    let kind: SystemSTTBackendKind
    let assets: SpeechAssetManager

    var requiresRolling: Bool { false }

    private var assetModule: SpeechAssetModule {
        kind == .dictationTranscriber ? .dictationTranscriber : .speechTranscriber
    }

    func supports(_ locale: Locale) async -> Bool {
        await supportedLocale(locale) != nil
    }

    func startSegment(locale: Locale, format: AVAudioFormat) async throws -> any SystemSTTSegment {
        guard let resolved = await supportedLocale(locale) else { throw SystemSTTBackendError.unsupportedLocale }
        do {
            try await assets.prepare(assetModule, locale: resolved)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SystemSTTBackendError.assetNotFound
        }
        let module: any SpeechModule
        let results: Task<String, Error>
        switch kind {
        case .dictationTranscriber:
            let transcriber = DictationTranscriber(locale: resolved, preset: .longDictation)
            module = transcriber
            results = Task {
                var parts: [String] = []
                for try await result in transcriber.results where result.isFinal {
                    parts.append(String(result.text.characters))
                }
                return DictationRules.join(parts)
            }
        default:
            let transcriber = SpeechTranscriber(locale: resolved, preset: .transcription)
            module = transcriber
            results = Task {
                var parts: [String] = []
                for try await result in transcriber.results where result.isFinal {
                    parts.append(String(result.text.characters))
                }
                return DictationRules.join(parts)
            }
        }
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [module], considering: format
        ), let converter = PCMFormatConverter(from: format, to: analyzerFormat) else {
            results.cancel()
            throw SystemSTTBackendError.unavailable
        }
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let analyzer = SpeechAnalyzer(modules: [module])
        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            continuation.finish()
            results.cancel()
            throw Self.classify(error)
        }
        return SpeechAnalyzerSegment(analyzer: analyzer, input: continuation, results: results, converter: converter)
    }

    private func supportedLocale(_ locale: Locale) async -> Locale? {
        switch kind {
        case .dictationTranscriber:
            return await DictationTranscriber.supportedLocale(equivalentTo: locale)
        default:
            guard SpeechTranscriber.isAvailable else { return nil }
            return await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        }
    }

    /// Model / locale allocation errors in SFSpeechErrorDomain count as asset not found; errors from other domains count as authorization errors when not authorized.
    static func classify(_ error: Error) -> SystemSTTBackendError {
        if error is CancellationError { return .failed }
        if let speech = error as? SFSpeechError {
            let assetCodes: [SFSpeechError.Code] = [
                .noModel, .assetLocaleNotAllocated, .cannotAllocateUnsupportedLocale, .tooManyAssetLocalesAllocated,
            ]
            return assetCodes.contains(speech.code) ? .assetNotFound : .failed
        }
        return SFSpeechRecognizer.authorizationStatus() == .authorized ? .failed : .notAuthorized
    }
}

@available(iOS 26, *)
nonisolated final class SpeechAnalyzerSegment: SystemSTTSegment, @unchecked Sendable {

    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let results: Task<String, Error>
    private let converter: PCMFormatConverter

    init(
        analyzer: SpeechAnalyzer,
        input: AsyncStream<AnalyzerInput>.Continuation,
        results: Task<String, Error>,
        converter: PCMFormatConverter
    ) {
        self.analyzer = analyzer
        self.input = input
        self.results = results
        self.converter = converter
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let converted = converter.convert(buffer) else { return }
        input.yield(AnalyzerInput(buffer: converted))
    }

    func finish() async throws -> String {
        input.finish()
        return try await withTaskCancellationHandler {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            return try await results.value
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        input.finish()
        results.cancel()
        let analyzer = analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }
}

/// Converts the input format to the format the recognizer wants; identical formats pass through. Not thread-safe; called serially within a segment.
nonisolated final class PCMFormatConverter {

    private let target: AVAudioFormat
    private let converter: AVAudioConverter?

    init?(from source: AVAudioFormat, to target: AVAudioFormat) {
        self.target = target
        if source.isEqual(target) {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: source, to: target) else { return nil }
            self.converter = converter
        }
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else { return buffer }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}
