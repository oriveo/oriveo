import Foundation
import Testing
@testable import Oriveo

/// Events recorded in order of occurrence from the engine, network, player and fallback.
private enum CloudSpeechEvent: Equatable {
    case request(String)
    case cancelled
    case sleep(Double)
    case play(String)
    case started(Int)
    case finishedAll
    case failed
    case fallback
}

/// Intercepts CloudSpeechEngine synthesis requests; a hanging request gets no response until it is cancelled.
nonisolated final class CloudSpeechEngineURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var recorder: CloudSpeechRecorder?

    private var isHanging = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let recorder = Self.recorder else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        switch recorder.handle(request) {
        case .hang:
            isHanging = true
        case .reply(let status, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        if isHanging {
            isHanging = false
            Self.recorder?.recordCancel()
        }
    }
}

/// Replays queued responses; by default (empty queue) replies 200 + "audio:<input>".
nonisolated final class CloudSpeechRecorder: @unchecked Sendable {
    enum Reply {
        case reply(status: Int, body: Data)
        case hang
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private let emit: @Sendable (CloudSpeechEvent) -> Void
    private(set) var requests: [(request: URLRequest, json: [String: Any])] = []

    fileprivate init(_ replies: [Reply], emit: @escaping @Sendable (CloudSpeechEvent) -> Void) {
        self.replies = replies
        self.emit = emit
    }

    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return requests.count
    }

    func handle(_ request: URLRequest) -> Reply {
        let body = request.httpBody ?? Self.readBody(request.httpBodyStream)
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let input = json["input"] as? String ?? ""
        lock.lock()
        requests.append((request, json))
        let reply = replies.isEmpty ? .reply(status: 200, body: Data("audio:\(input)".utf8)) : replies.removeFirst()
        lock.unlock()
        emit(.request(input))
        return reply
    }

    func recordCancel() {
        emit(.cancelled)
    }

    private static func readBody(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

@MainActor
private final class FakeAudioPlayer: SpeechAudioPlaying {
    var onFinish: ((Bool) -> Void)?
    let label: String
    private(set) var stopCount = 0
    private let emit: (CloudSpeechEvent) -> Void

    init(data: Data, emit: @escaping (CloudSpeechEvent) -> Void) {
        label = String(decoding: data, as: UTF8.self)
        self.emit = emit
    }

    func play() -> Bool {
        emit(.play(label))
        return true
    }

    func stop() {
        stopCount += 1
    }

    /// Simulates playback finishing.
    func finish() {
        onFinish?(true)
    }
}

@MainActor
private final class FakeSpeechEngine: SpeechEngine {
    weak var delegate: SpeechEngineDelegate?
    var hasAnyVoice = true
    private(set) var spoken: [[SpeechUtterance]] = []
    private(set) var stopCount = 0

    func speak(_ utterances: [SpeechUtterance]) {
        spoken.append(utterances)
    }

    func stop() {
        stopCount += 1
    }
}

@MainActor
private final class SpeechDelegateSpy: SpeechEngineDelegate {
    private let emit: (CloudSpeechEvent) -> Void
    private(set) var started: [Int] = []
    private(set) var finishedAll = 0
    private(set) var failed = 0

    init(emit: @escaping (CloudSpeechEvent) -> Void) { self.emit = emit }

    func speechEngineDidStartSegment(at index: Int) {
        started.append(index)
        emit(.started(index))
    }

    func speechEngineDidFinishAll() {
        finishedAll += 1
        emit(.finishedAll)
    }

    func speechEngineDidFail() {
        failed += 1
        emit(.failed)
    }
}

/// A cache whose writes hang until open(): measures "cache writes do not block playback". Reads always miss.
private actor GatedAudioCache: SpeechAudioCaching {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var stored: [String] = []

    func data(for key: SpeechAudioCacheKey) -> Data? { nil }

    func store(_ data: Data, for key: SpeechAudioCacheKey) async {
        if !isOpen { await withCheckedContinuation { waiters.append($0) } }
        stored.append(String(decoding: data, as: UTF8.self))
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}

/// Per-test rig: temporary cache directory, intercepted network, fake player, fake fallback engine, event stream.
@MainActor
private final class CloudSpeechHarness {
    static let apiKey = "sk-cloud-tts-test"
    static let baseURL = URL(string: "https://tts.example.test")!
    /// maxChars 20: two sentences per chunk ("Line 0. Line 1." = 15; adding a third makes 23, over the limit).
    static let entry = VoiceTTSEntry(
        model: "gpt-4o-mini-tts", transport: .openAISpeech, path: "/v1/audio/speech", outputFormat: "mp3",
        maxChars: 20, voices: [VoiceCatalogVoice(id: "alloy", isDefault: true)],
        speedRange: VoiceSpeedRange(min: 0.25, max: 4), isDefault: true
    )
    static let utterances = (0..<6).map { SpeechUtterance(text: "Line \($0).", language: "en") }
    static let chunkTexts = ["Line 0. Line 1.", "Line 2. Line 3.", "Line 4. Line 5."]

    let root: URL
    let cache: any SpeechAudioCaching
    let recorder: CloudSpeechRecorder
    let fallback = FakeSpeechEngine()
    let delegate: SpeechDelegateSpy
    let events: AsyncStream<CloudSpeechEvent>
    private let continuation: AsyncStream<CloudSpeechEvent>.Continuation
    private(set) var players: [FakeAudioPlayer] = []
    private(set) var fallbackCalls = 0
    private(set) var sleeps: [Double] = []

    init(replies: [CloudSpeechRecorder.Reply] = [], root: URL? = nil, cache: (any SpeechAudioCaching)? = nil) {
        let (stream, continuation) = AsyncStream<CloudSpeechEvent>.makeStream()
        events = stream
        self.continuation = continuation
        self.root = root ?? FileManager.default.temporaryDirectory
            .appending(path: "cloud-speech-\(UUID().uuidString)", directoryHint: .isDirectory)
        self.cache = cache ?? SpeechAudioCache(root: self.root)
        recorder = CloudSpeechRecorder(replies, emit: { continuation.yield($0) })
        delegate = SpeechDelegateSpy(emit: { continuation.yield($0) })
        CloudSpeechEngineURLProtocol.recorder = recorder
    }

    func makeEngine(entry: VoiceTTSEntry = CloudSpeechHarness.entry, providerKind: ProviderKind = .openAI) -> CloudSpeechEngine {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudSpeechEngineURLProtocol.self]
        let continuation = self.continuation
        let engine = CloudSpeechEngine(
            entry: entry, providerKind: providerKind, baseURL: Self.baseURL, apiKey: Self.apiKey,
            voice: "alloy", speed: 1, language: "en",
            fallback: fallback,
            onFallback: { [weak self] in
                self?.fallbackCalls += 1
                continuation.yield(.fallback)
            },
            cache: cache,
            session: URLSession(configuration: config),
            sleeper: { seconds in continuation.yield(.sleep(seconds)) },
            makePlayer: { [weak self] data in
                let player = FakeAudioPlayer(data: data, emit: { continuation.yield($0) })
                self?.players.append(player)
                return player
            }
        )
        engine.delegate = delegate
        return engine
    }

    func cleanUp() {
        continuation.finish()
        try? FileManager.default.removeItem(at: root)
    }

    /// A correct implementation sends no more requests; leave a little time so any extra request lands in the record.
    static func settle() async throws {
        try await Task.sleep(for: .milliseconds(150))
    }

    static func audio(_ text: String) -> String { "audio:\(text)" }
}

/// Cloud read-aloud engine: requests / plays chunk by chunk, prefetches one chunk ahead, and on failure hands over to the system engine from the failed chunk.
@Suite("Cloud speech engine", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct CloudSpeechEngineTests {

    private typealias H = CloudSpeechHarness

    private static func expectNext(
        _ expected: CloudSpeechEvent,
        _ events: inout AsyncStream<CloudSpeechEvent>.Iterator,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let actual = await events.next()
        #expect(actual == expected, sourceLocation: sourceLocation)
    }

    @Test("Chunk plan and first sentence index: blank sentences are skipped but keep their index")
    func chunkPlan() {
        let utterances = [SpeechUtterance(text: "Line 0.", language: nil), SpeechUtterance(text: "   ", language: nil)]
            + (2..<6).map { SpeechUtterance(text: "Line \($0).", language: nil) }
        let chunks = CloudSpeechEngine.chunks(of: utterances, maxChars: 20)
        #expect(chunks.map(\.text) == CloudReadAloudRules.chunks(sentences: utterances.map(\.text), maxChars: 20))
        #expect(chunks.map(\.text) == ["Line 0. Line 2.", "Line 3. Line 4.", "Line 5."])
        #expect(chunks.map(\.firstIndex) == [0, 3, 5])
    }

    @Test("While chunk k plays only k+1 is requested; didStartSegment reports the chunk's first sentence index; didFinishAll fires once at the end")
    func prefetchesOneChunkAhead() async throws {
        let harness = H()
        defer { harness.cleanUp() }
        var events = harness.events.makeAsyncIterator()
        let engine = harness.makeEngine()
        engine.speak(H.utterances)

        let firstIndices = [0, 2, 4]
        for (k, text) in H.chunkTexts.enumerated() {
            if k == 0 { await Self.expectNext(.request(text), &events) }
            await Self.expectNext(.play(H.audio(text)), &events)
            await Self.expectNext(.started(firstIndices[k]), &events)
            if k + 1 < H.chunkTexts.count {
                await Self.expectNext(.request(H.chunkTexts[k + 1]), &events)
            }
            try await H.settle()
            #expect(harness.recorder.requestCount == min(k + 2, H.chunkTexts.count))
            harness.players[k].finish()
        }
        await Self.expectNext(.finishedAll, &events)
        try await H.settle()

        #expect(harness.delegate.started == firstIndices)
        #expect(harness.delegate.finishedAll == 1)
        #expect(harness.delegate.failed == 0)
        #expect(harness.recorder.requestCount == 3)
        #expect(harness.fallback.spoken.isEmpty)
        #expect(harness.fallbackCalls == 0)

        let first = try #require(harness.recorder.requests.first)
        #expect(first.request.url?.absoluteString == "https://tts.example.test/v1/audio/speech")
        #expect(first.request.httpMethod == "POST")
        #expect(first.request.value(forHTTPHeaderField: "Authorization") == "Bearer \(H.apiKey)")
        #expect(first.json["model"] as? String == "gpt-4o-mini-tts")
        #expect(first.json["voice"] as? String == "alloy")
        #expect(first.json["response_format"] as? String == "mp3")
        #expect(first.json["speed"] == nil)
    }

    @Test("stop cancels the in-flight request and playback, with no callbacks afterwards")
    func stopCancelsInFlight() async throws {
        let harness = H(replies: [.reply(status: 200, body: Data(H.audio(H.chunkTexts[0]).utf8)), .hang])
        defer { harness.cleanUp() }
        var events = harness.events.makeAsyncIterator()
        let engine = harness.makeEngine()
        engine.speak(H.utterances)

        await Self.expectNext(.request(H.chunkTexts[0]), &events)
        await Self.expectNext(.play(H.audio(H.chunkTexts[0])), &events)
        await Self.expectNext(.started(0), &events)
        await Self.expectNext(.request(H.chunkTexts[1]), &events)

        engine.stop()
        await Self.expectNext(.cancelled, &events)
        let player = try #require(harness.players.first)
        #expect(player.stopCount == 1)
        player.finish()
        try await H.settle()

        #expect(harness.delegate.started == [0])
        #expect(harness.delegate.finishedAll == 0)
        #expect(harness.delegate.failed == 0)
        #expect(harness.recorder.requestCount == 2)
        #expect(harness.players.count == 1)
        #expect(harness.fallbackCalls == 0)
    }

    @Test("A 5xx retried once and still failing falls back to the system engine from the failed chunk's first sentence, fires the fallback callback once, and sends no more requests")
    func serverErrorFallsBackFromFailedChunk() async throws {
        let failure = CloudSpeechRecorder.Reply.reply(status: 503, body: Data(#"{"error":"x"}"#.utf8))
        let harness = H(replies: [.reply(status: 200, body: Data(H.audio(H.chunkTexts[0]).utf8)), failure, failure])
        defer { harness.cleanUp() }
        var events = harness.events.makeAsyncIterator()
        let engine = harness.makeEngine()
        engine.speak(H.utterances)

        await Self.expectNext(.request(H.chunkTexts[0]), &events)
        await Self.expectNext(.play(H.audio(H.chunkTexts[0])), &events)
        await Self.expectNext(.started(0), &events)
        await Self.expectNext(.request(H.chunkTexts[1]), &events)
        let sleep = await events.next()
        guard case .sleep = sleep else {
            Issue.record("expected one retry wait, got \(String(describing: sleep))")
            return
        }
        await Self.expectNext(.request(H.chunkTexts[1]), &events)
        try await H.settle()
        // Chunk 1 is still playing: no early fallback.
        #expect(harness.fallback.spoken.isEmpty)

        harness.players[0].finish()
        await Self.expectNext(.fallback, &events)
        #expect(harness.fallback.spoken == [Array(H.utterances[2...])])
        #expect(harness.fallbackCalls == 1)

        // Fallback engine indices are mapped back to the whole reply.
        harness.fallback.delegate?.speechEngineDidStartSegment(at: 0)
        harness.fallback.delegate?.speechEngineDidStartSegment(at: 2)
        harness.fallback.delegate?.speechEngineDidFinishAll()
        try await H.settle()

        #expect(harness.delegate.started == [0, 2, 4])
        #expect(harness.delegate.finishedAll == 1)
        #expect(harness.delegate.failed == 0)
        #expect(harness.recorder.requestCount == 3)
        #expect(harness.fallbackCalls == 1)
        #expect(harness.players.count == 1)
    }

    @Test("401 is not retried and falls back from chunk 1 directly")
    func unauthorizedFallsBackWithoutRetry() async throws {
        let harness = H(replies: [.reply(status: 401, body: Data(#"{"error":"x"}"#.utf8))])
        defer { harness.cleanUp() }
        var events = harness.events.makeAsyncIterator()
        let engine = harness.makeEngine()
        engine.speak(H.utterances)

        await Self.expectNext(.request(H.chunkTexts[0]), &events)
        await Self.expectNext(.fallback, &events)
        try await H.settle()

        #expect(harness.fallback.spoken == [H.utterances])
        #expect(harness.fallbackCalls == 1)
        #expect(harness.recorder.requestCount == 1)
        #expect(harness.players.isEmpty)
        #expect(harness.delegate.started.isEmpty)
        #expect(harness.delegate.failed == 0)
    }

    @Test("A successful synthesis writes the cache; replaying the same content hits every chunk and sends no request")
    func cacheHitSkipsRequest() async throws {
        let harness = H()
        defer { harness.cleanUp() }
        var events = harness.events.makeAsyncIterator()
        let engine = harness.makeEngine()

        engine.speak(H.utterances)
        await Self.expectNext(.request(H.chunkTexts[0]), &events)
        for (k, text) in H.chunkTexts.enumerated() {
            await Self.expectNext(.play(H.audio(text)), &events)
            await Self.expectNext(.started(k * 2), &events)
            if k + 1 < H.chunkTexts.count {
                await Self.expectNext(.request(H.chunkTexts[k + 1]), &events)
            }
            harness.players[k].finish()
        }
        await Self.expectNext(.finishedAll, &events)
        #expect(harness.recorder.requestCount == 3)
        // Cache writes are background and unawaited: leave time for them to land on disk.
        try await H.settle()

        let again = harness.makeEngine()
        again.speak(H.utterances)
        for (k, text) in H.chunkTexts.enumerated() {
            await Self.expectNext(.play(H.audio(text)), &events)
            await Self.expectNext(.started(k * 2), &events)
            harness.players[3 + k].finish()
        }
        await Self.expectNext(.finishedAll, &events)
        try await H.settle()

        #expect(harness.recorder.requestCount == 3)
        #expect(harness.delegate.finishedAll == 2)
    }
    // MARK: Private protocols

    private static func privateEntry(_ transport: VoiceTTSTransport, model: String, path: String, format: String) -> VoiceTTSEntry {
        VoiceTTSEntry(
            model: model, transport: transport, path: path, outputFormat: format,
            maxChars: 1000, voices: [VoiceCatalogVoice(id: "v1", isDefault: true)],
            speedRange: nil, isDefault: true
        )
    }

    private static let oneLine = [SpeechUtterance(text: "Hello there.", language: "en")]

    private static func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    /// Reads the cache after the write has landed (cache writes do not block playback).
    private static func cached(_ cache: any SpeechAudioCaching, _ key: SpeechAudioCacheKey) async throws -> Data? {
        try await H.settle()
        return await cache.data(for: key)
    }

    @Test("gemini_tts: authenticates with x-goog-api-key and writes the cache / plays only after base64 decoding")
    func test_geminiTTS_decodesBase64BeforeCache() async throws {
        let wav = Data("RIFF-wav-bytes".utf8)
        let body = try Self.json([
            "steps": [["type": "model_output", "content": [
                ["type": "text", "text": "ignored"],
                ["type": "audio", "mime_type": "audio/wav", "data": wav.base64EncodedString()],
            ]]],
        ])
        let harness = H(replies: [.reply(status: 200, body: body)])
        defer { harness.cleanUp() }
        var events = harness.events.makeAsyncIterator()
        let entry = Self.privateEntry(.geminiTTS, model: "gemini-3.8-flash-tts", path: "/v1beta/interactions", format: "wav")
        let engine = harness.makeEngine(entry: entry, providerKind: .gemini)
        engine.speak(Self.oneLine)

        await Self.expectNext(.request(""), &events)
        await Self.expectNext(.play("RIFF-wav-bytes"), &events)
        await Self.expectNext(.started(0), &events)
        let request = try #require(harness.recorder.requests.first?.request)
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == H.apiKey)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(harness.recorder.requests.first?.json["speed"] == nil)
        let key = SpeechAudioCacheKey(
            text: "Hello there.", providerKind: ProviderKind.gemini.rawValue, model: entry.model, voice: "alloy",
            speed: 1, language: "en", outputFormat: "wav"
        )
        #expect(try await Self.cached(harness.cache, key) == wav)
        harness.players[0].finish()
        await Self.expectNext(.finishedAll, &events)
    }

    @Test("dashscope_tts: synthesizes with Bearer; the second-hop GET download carries no auth header and plays the downloaded bytes")
    func test_dashscopeTTS_downloadsURLWithoutAuth() async throws {
        let audioURL = "https://dashscope-result.example.test/tts/abc.wav?Signature=x"
        let first = try Self.json(["output": ["audio": ["url": audioURL, "id": "a1"]], "request_id": "r1"])
        let harness = H(replies: [
            .reply(status: 200, body: first),
            .reply(status: 200, body: Data("wav-from-oss".utf8)),
        ])
        defer { harness.cleanUp() }
        var events = harness.events.makeAsyncIterator()
        let entry = Self.privateEntry(
            .dashscopeTTS, model: "qwen3-tts-flash", path: "/api/v1/services/aigc/multimodal-generation/generation", format: "wav"
        )
        let engine = harness.makeEngine(entry: entry, providerKind: .qwen)
        engine.speak(Self.oneLine)

        await Self.expectNext(.request(""), &events)
        await Self.expectNext(.request(""), &events)
        await Self.expectNext(.play("wav-from-oss"), &events)
        let requests = harness.recorder.requests.map(\.request)
        #expect(requests.count == 2)
        #expect(requests[0].httpMethod == "POST")
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer \(H.apiKey)")
        #expect(requests[1].httpMethod == "GET")
        #expect(requests[1].url?.absoluteString == audioURL)
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == nil)
        #expect(requests[1].value(forHTTPHeaderField: "x-goog-api-key") == nil)
        #expect(requests[1].timeoutInterval == CloudReadAloudRules.requestTimeoutSec)
        harness.players[0].finish()
        await Self.expectNext(.started(0), &events)
        await Self.expectNext(.finishedAll, &events)
    }

    @Test("mistral_speech: audio_data is decoded before playback")
    func test_mistralSpeech_decodesAudioData() async throws {
        let mp3 = Data("ID3-mp3-bytes".utf8)
        let harness = H(replies: [
            .reply(status: 200, body: try Self.json(["audio_data": mp3.base64EncodedString()])),
        ])
        defer { harness.cleanUp() }
        var events = harness.events.makeAsyncIterator()
        let entry = Self.privateEntry(.mistralSpeech, model: "voxtral-mini-tts-3-0", path: "/v1/audio/speech", format: "mp3")
        let engine = harness.makeEngine(entry: entry, providerKind: .mistral)
        engine.speak(Self.oneLine)

        await Self.expectNext(.request("Hello there."), &events)
        await Self.expectNext(.play("ID3-mp3-bytes"), &events)
        await Self.expectNext(.started(0), &events)
        #expect(harness.recorder.requests.first?.request.value(forHTTPHeaderField: "Authorization") == "Bearer \(H.apiKey)")
        harness.players[0].finish()
        await Self.expectNext(.finishedAll, &events)
    }

    @Test("mistral_speech: bad base64 (including unpadded) is an invalid response, not retried, and falls back")
    func test_mistralSpeech_badBase64_fallsBackWithoutRetry() async throws {
        let harness = H(replies: [
            .reply(status: 200, body: try Self.json(["audio_data": "SUQzBAAAAAAAI1RTU0U"])),
        ])
        defer { harness.cleanUp() }
        var events = harness.events.makeAsyncIterator()
        let entry = Self.privateEntry(.mistralSpeech, model: "voxtral-mini-tts-3-0", path: "/v1/audio/speech", format: "mp3")
        let engine = harness.makeEngine(entry: entry, providerKind: .mistral)
        let bad = [SpeechUtterance(text: "Second line.", language: "en")]
        engine.speak(bad)

        await Self.expectNext(.request("Second line."), &events)
        await Self.expectNext(.fallback, &events)
        try await H.settle()
        #expect(harness.recorder.requestCount == 1)
        #expect(harness.fallback.spoken.last == bad)
    }

    @Test("Chunks already in the cache play directly without sending any request")
    func prefilledCacheSkipsEveryRequest() async throws {
        let harness = H()
        defer { harness.cleanUp() }
        let entry = H.entry
        for text in H.chunkTexts {
            let key = SpeechAudioCacheKey(
                text: text, providerKind: ProviderKind.openAI.rawValue, model: entry.model, voice: "alloy",
                speed: 1, language: "en", outputFormat: entry.outputFormat
            )
            await harness.cache.store(Data(H.audio(text).utf8), for: key)
        }
        var events = harness.events.makeAsyncIterator()
        let engine = harness.makeEngine()
        engine.speak(H.utterances)
        for (k, text) in H.chunkTexts.enumerated() {
            await Self.expectNext(.play(H.audio(text)), &events)
            await Self.expectNext(.started(k * 2), &events)
            harness.players[k].finish()
        }
        await Self.expectNext(.finishedAll, &events)
        try await H.settle()

        #expect(harness.recorder.requestCount == 0)
        #expect(harness.delegate.finishedAll == 1)
    }

    @Test("The first chunk starts playing before the cache write completes; once released the write lands in the cache")
    func cacheWriteDoesNotBlockFirstChunk() async throws {
        let gated = GatedAudioCache()
        let harness = H(cache: gated)
        defer { harness.cleanUp() }
        var events = harness.events.makeAsyncIterator()
        let engine = harness.makeEngine()
        engine.speak(H.utterances)

        await Self.expectNext(.request(H.chunkTexts[0]), &events)
        await Self.expectNext(.play(H.audio(H.chunkTexts[0])), &events)
        await Self.expectNext(.started(0), &events)
        #expect(await gated.stored.isEmpty)

        engine.stop()
        await gated.open()
        try await H.settle()
        #expect(await gated.stored.first == H.audio(H.chunkTexts[0]))
    }
}
