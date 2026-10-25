import AVFoundation
import Foundation

// MARK: - Player abstraction

/// Plays one synthesized clip. Production wraps `AVAudioPlayer(data:)`; tests inject a fake.
protocol SpeechAudioPlaying: AnyObject {
    /// Called once on the main actor: true = finished playing, false = decode / playback error.
    var onFinish: ((Bool) -> Void)? { get set }
    /// Starts playback; false means it could not start.
    func play() -> Bool
    func stop()
}

/// Production player: `AVAudioPlayer(data:)`.
final class SystemSpeechAudioPlayer: NSObject, SpeechAudioPlaying, AVAudioPlayerDelegate {
    var onFinish: ((Bool) -> Void)?

    private let player: AVAudioPlayer

    init(data: Data) throws {
        player = try AVAudioPlayer(data: data)
        super.init()
        player.delegate = self
        player.prepareToPlay()
    }

    func play() -> Bool {
        player.play()
    }

    func stop() {
        player.stop()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Self.deliver { [weak self] in self?.finish(flag) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        Self.deliver { [weak self] in self?.finish(false) }
    }

    private func finish(_ succeeded: Bool) {
        let callback = onFinish
        onFinish = nil
        callback?(succeeded)
    }

    private nonisolated static func deliver(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { work() }
        } else {
            Task { @MainActor in work() }
        }
    }
}

// MARK: - Engine

/// Cloud read-aloud (openai_speech / xai_tts / gemini_tts / mistral_speech / dashscope_tts). Sentences are split with `CloudReadAloudRules.chunks` and requested serially,
/// prefetching only one chunk beyond the one playing. Each chunk is retried silently at most once per the dictation failure matrix; with no retry (including 401 / 403)
/// the fallback engine continues from the first sentence of the failed chunk and `onFallback` is called once (the controller shows the notice); settings are not rewritten.
/// A successful synthesis is written to the cache, and a hit plays directly without a request. `stop()` cancels in-flight requests and stops playback, with no callbacks afterwards.
final class CloudSpeechEngine: SpeechEngine {

    typealias Sleeper = CloudSTTEngine.Sleeper
    typealias PlayerFactory = (Data) throws -> any SpeechAudioPlaying

    weak var delegate: SpeechEngineDelegate?

    /// Cloud voices are always available; on fallback the system engine handles voices itself.
    var hasAnyVoice: Bool { true }

    let entry: VoiceTTSEntry
    let providerKind: ProviderKind
    let baseURL: URL
    let voice: String
    /// Effective speed (the caller already clamped it to the entry range and rounded to two decimals).
    let speed: Double
    /// Reading language, supplied by the caller.
    let language: String

    private let apiKey: String
    private let fallback: SpeechEngine
    private let onFallback: () -> Void
    private let cache: any SpeechAudioCaching
    private let session: URLSession
    private let sleeper: Sleeper
    private let makePlayer: PlayerFactory

    /// Incremented on every speak / stop; async work from an older generation no longer changes state or calls back.
    private var generation = 0
    private var runTask: Task<Void, Never>?
    private var prefetchTask: Task<Synthesis, Never>?
    private var player: (any SpeechAudioPlaying)?
    private var playbackResult: Bool?
    private var playbackWaiter: CheckedContinuation<Bool, Never>?
    private var fallbackRelay: FallbackRelay?

    init(
        entry: VoiceTTSEntry,
        providerKind: ProviderKind,
        baseURL: URL,
        apiKey: String,
        voice: String,
        speed: Double,
        language: String,
        fallback: SpeechEngine,
        onFallback: @escaping () -> Void,
        cache: any SpeechAudioCaching = SpeechAudioCache.shared,
        session: URLSession = .shared,
        sleeper: @escaping Sleeper = CloudSTTEngine.defaultSleeper,
        makePlayer: @escaping PlayerFactory = { try SystemSpeechAudioPlayer(data: $0) }
    ) {
        self.entry = entry
        self.providerKind = providerKind
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.voice = voice
        self.speed = speed
        self.language = language
        self.fallback = fallback
        self.onFallback = onFallback
        self.cache = cache
        self.session = session
        self.sleeper = sleeper
        self.makePlayer = makePlayer
    }

    func speak(_ utterances: [SpeechUtterance]) {
        stop()
        let chunks = Self.chunks(of: utterances, maxChars: entry.maxChars)
        guard !chunks.isEmpty else {
            delegate?.speechEngineDidFail()
            return
        }
        let current = generation
        runTask = Task { [weak self] in
            await self?.run(chunks, utterances: utterances, generation: current)
        }
    }

    func stop() {
        generation += 1
        runTask?.cancel()
        runTask = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        stopPlayer()
        if let waiter = playbackWaiter {
            playbackWaiter = nil
            waiter.resume(returning: false)
        }
        if fallbackRelay != nil {
            fallbackRelay = nil
            fallback.stop()
        }
    }

    // MARK: - Chunking

    /// One chunk = one request: its text and the index of its first sentence in utterances.
    struct Chunk: Equatable {
        let text: String
        let firstIndex: Int
    }

    /// Splits with `CloudReadAloudRules.chunks` and maps each chunk back to the original index of its first sentence
    /// (blank sentences are dropped by the rules but still occupy an index).
    static func chunks(of utterances: [SpeechUtterance], maxChars: Int) -> [Chunk] {
        let texts = CloudReadAloudRules.chunks(sentences: utterances.map(\.text), maxChars: maxChars)
        let items: [(index: Int, text: String)] = utterances.enumerated().compactMap { index, utterance in
            let text = DictationRules.trim(utterance.text)
            return text.isEmpty ? nil : (index, text)
        }
        var result: [Chunk] = []
        var cursor = 0
        for text in texts where cursor < items.count {
            let firstIndex = items[cursor].index
            var joined = items[cursor].text
            cursor += 1
            while joined != text, cursor < items.count {
                joined += CloudReadAloudRules.sentenceJoiner + items[cursor].text
                cursor += 1
            }
            result.append(Chunk(text: text, firstIndex: firstIndex))
        }
        return result
    }

    // MARK: - Playback loop

    private enum Synthesis {
        case audio(Data)
        case failed
        case cancelled
    }

    private func isCurrent(_ value: Int) -> Bool {
        value == generation
    }

    private func run(_ chunks: [Chunk], utterances: [SpeechUtterance], generation current: Int) async {
        var upcoming: Task<Synthesis, Never>?
        for (position, chunk) in chunks.enumerated() {
            let result: Synthesis
            if let upcoming {
                result = await upcoming.value
            } else {
                result = await synthesize(chunk.text)
            }
            guard isCurrent(current) else { return }
            prefetchTask = nil
            guard case .audio(let data) = result, let next = try? makePlayer(data) else {
                fallBack(from: chunk.firstIndex, utterances: utterances)
                return
            }
            player = next
            playbackResult = nil
            next.onFinish = { [weak self, weak next] succeeded in
                guard let self, let next, self.player === next else { return }
                self.playbackEnded(succeeded)
            }
            guard next.play() else {
                fallBack(from: chunk.firstIndex, utterances: utterances)
                return
            }
            delegate?.speechEngineDidStartSegment(at: chunk.firstIndex)
            guard isCurrent(current) else { return }
            // Prefetch only the next chunk (contract constants.prefetchChunks = 1).
            if position + 1 < chunks.count {
                let text = chunks[position + 1].text
                let task = Task { [weak self] () -> Synthesis in
                    guard let self else { return .cancelled }
                    return await self.synthesize(text)
                }
                upcoming = task
                prefetchTask = task
            } else {
                upcoming = nil
            }
            let finished = await waitForPlayback()
            guard isCurrent(current) else { return }
            player = nil
            guard finished else {
                fallBack(from: chunk.firstIndex, utterances: utterances)
                return
            }
        }
        runTask = nil
        delegate?.speechEngineDidFinishAll()
    }

    private func playbackEnded(_ succeeded: Bool) {
        if let waiter = playbackWaiter {
            playbackWaiter = nil
            waiter.resume(returning: succeeded)
        } else {
            playbackResult = succeeded
        }
    }

    private func waitForPlayback() async -> Bool {
        if let result = playbackResult {
            playbackResult = nil
            return result
        }
        return await withCheckedContinuation { playbackWaiter = $0 }
    }

    private func stopPlayer() {
        if let player {
            player.onFinish = nil
            player.stop()
        }
        player = nil
        playbackResult = nil
    }

    // MARK: - Fallback

    /// Hands sentences from index onward to the fallback engine; callback indices are translated back to the whole reply. This reply makes no further cloud requests.
    private func fallBack(from index: Int, utterances: [SpeechUtterance]) {
        runTask = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        stopPlayer()
        let relay = FallbackRelay(owner: self, generation: generation, offset: index)
        fallbackRelay = relay
        fallback.delegate = relay
        fallback.speak(Array(utterances[index...]))
        onFallback()
    }

    fileprivate func relayStart(_ index: Int, generation relayed: Int) {
        guard isCurrent(relayed), fallbackRelay != nil else { return }
        delegate?.speechEngineDidStartSegment(at: index)
    }

    fileprivate func relayEnd(failed: Bool, generation relayed: Int) {
        guard isCurrent(relayed), fallbackRelay != nil else { return }
        fallbackRelay = nil
        if failed {
            delegate?.speechEngineDidFail()
        } else {
            delegate?.speechEngineDidFinishAll()
        }
    }

    // MARK: - Synthesis

    private enum Response {
        case audio(Data)
        case failed(DictationFailure)
        case cancelled
    }

    /// Checks the cache first; on a miss it sends the request, with retries decided by `CloudReadAloudRules.decide`.
    private func synthesize(_ text: String) async -> Synthesis {
        let key = SpeechAudioCacheKey(
            text: text, providerKind: providerKind.rawValue, model: entry.model, voice: voice,
            speed: speed, language: language, outputFormat: entry.outputFormat
        )
        if let data = await cache.data(for: key) { return .audio(data) }
        guard let request = CloudReadAloudRules.makeRequest(
            baseURL: baseURL, entry: entry, text: text, voice: voice, speed: speed,
            language: language, apiKey: apiKey
        ) else {
            return .failed
        }
        var attempt = 1
        while true {
            guard !Task.isCancelled else { return .cancelled }
            switch await send(request) {
            case .audio(let data):
                // Do not wait for the cache write: the cache actor queues it itself, and this chunk can play immediately.
                let cache = self.cache
                Task { await cache.store(data, for: key) }
                return .audio(data)
            case .cancelled:
                return .cancelled
            case .failed(let failure):
                switch CloudReadAloudRules.decide(failure, attempt: attempt) {
                case .autoRetry(let delaySec):
                    do {
                        try await sleeper(delaySec)
                    } catch {
                        return .cancelled
                    }
                    attempt += 1
                case .fallbackSystemFromFailedChunk:
                    return .failed
                }
            }
        }
    }

    /// Synthesis request; after a 2xx the audio bytes are decoded per transport, and dashscope_tts adds one GET hop to download (no auth header, same status-code criterion).
    private func send(_ request: URLRequest) async -> Response {
        let data: Data
        switch await fetch(request) {
        case .success(let body): data = body
        case .failure(let response): return response
        }
        switch await Self.decodeAudioResponse(transport: entry.transport, data: data) {
        case .audio(let audio):
            return .audio(audio)
        case .download(let url):
            switch await fetch(CloudReadAloudRules.downloadRequest(url)) {
            case .success(let audio):
                return audio.isEmpty ? .failed(.invalidResponse) : .audio(audio)
            case .failure(let response):
                return response
            }
        case nil:
            return .failed(.invalidResponse)
        }
    }

    /// JSON and base64 decoding run on a background executor, and the result returns to the caller (the main actor).
    @concurrent
    private nonisolated static func decodeAudioResponse(
        transport: VoiceTTSTransport,
        data: Data
    ) async -> CloudReadAloudRules.AudioResponse? {
        CloudReadAloudRules.audioResponse(transport: transport, data: data)
    }

    private enum Fetched {
        case success(Data)
        case failure(Response)
    }

    /// One HTTP round trip: network errors, cancellation and non-2xx become failures; a 2xx returns the body.
    private func fetch(_ request: URLRequest) async -> Fetched {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch let error as URLError {
            if error.code == .cancelled, Task.isCancelled { return .failure(.cancelled) }
            return .failure(.failed(error.code == .timedOut ? .timeout : .network))
        } catch {
            return .failure(.failed(.network))
        }
        guard !Task.isCancelled else { return .failure(.cancelled) }
        guard let http = response as? HTTPURLResponse else { return .failure(.failed(.network)) }
        guard (200..<300).contains(http.statusCode) else {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
            return .failure(.failed(.http(status: http.statusCode, retryAfter: retryAfter)))
        }
        return .success(data)
    }
}

// MARK: - Voice conversation: synthesize without playing

/// Cloud synthesis failed (already retried per the failure matrix).
nonisolated enum CloudSpeechSynthesisError: Error, Equatable {
    case failed
}

/// Voice conversation: the same cache and requests, but it only returns the audio and does not play it; read-aloud speak behavior is unchanged.
extension CloudSpeechEngine: ConversationCloudSynthesizing {
    func synthesize(text: String) async throws -> Data {
        switch await synthesize(text) {
        case .audio(let data): return data
        case .failed: throw CloudSpeechSynthesisError.failed
        case .cancelled: throw CancellationError()
        }
    }

    var audioFileExtension: String { entry.outputFormat }

    var fallbackProviderName: String { providerKind.displayName }
}

/// Delegate of the fallback engine: adds the offset to indices and forwards them to the cloud engine. It carries its generation, and callbacks after stop / a new speak are dropped.
private final class FallbackRelay: SpeechEngineDelegate {
    weak var owner: CloudSpeechEngine?
    let generation: Int
    let offset: Int

    init(owner: CloudSpeechEngine, generation: Int, offset: Int) {
        self.owner = owner
        self.generation = generation
        self.offset = offset
    }

    func speechEngineDidStartSegment(at index: Int) {
        owner?.relayStart(offset + index, generation: generation)
    }

    func speechEngineDidFinishAll() {
        owner?.relayEnd(failed: false, generation: generation)
    }

    func speechEngineDidFail() {
        owner?.relayEnd(failed: true, generation: generation)
    }
}
