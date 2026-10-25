import AVFoundation
import Foundation
import Testing
@testable import Oriveo

/// Intercepts CloudSTTEngine uploads; the handler replies in the order requests arrive.
nonisolated final class CloudSTTEngineURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// Records every request (including the body read out) and retry wait, and replays queued responses.
nonisolated final class CloudSTTRecorder: @unchecked Sendable {
    struct Reply {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private(set) var requests: [(request: URLRequest, body: Data)] = []
    private(set) var sleeps: [Double] = []

    init(_ replies: [Reply]) { self.replies = replies }

    func handle(_ request: URLRequest) -> (HTTPURLResponse, Data) {
        lock.lock()
        defer { lock.unlock() }
        requests.append((request, request.httpBody ?? Self.readBody(request.httpBodyStream)))
        let reply = replies.isEmpty ? Reply(status: 500, headers: [:], body: Data()) : replies.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil,
                                       headerFields: reply.headers)!
        return (response, reply.body)
    }

    func recordSleep(_ seconds: Double) {
        lock.lock()
        sleeps.append(seconds)
        lock.unlock()
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

/// Cloud dictation engine: real recording -> m4a -> multipart upload, failure matrix, segment stitching.
@Suite("Cloud STT engine", .serialized)
struct CloudSTTEngineTests {

    private static let inputRate = 48_000.0
    private static let toneSec = 1.5
    private static let silenceSec = 1.5
    private static let amplitude: Float = 0.1
    private static let apiKey = "sk-cloud-stt-test"
    private static let baseURL = URL(string: "https://user:secret@stt.example.test:8443/ignored/base?q=1")!

    private static let openAIEntry = VoiceSTTEntry(
        model: "gpt-4o-mini-transcribe", transport: .openAITranscriptions, path: "/v1/audio/transcriptions",
        maxBytes: 25_000_000, maxDurationSec: 1500, languageField: "language", isDefault: true
    )
    private static let xaiEntry = VoiceSTTEntry(
        model: "grok-stt", transport: .xaiSTT, path: "/v1/stt",
        maxBytes: 500_000_000, maxDurationSec: 600, languageField: "language", isDefault: true
    )

    // MARK: - Fixtures

    /// Per-test directories: the slot holds the recording, work is the engine's temporary directory.
    private struct Sandbox {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "CloudSTTEngineTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        var slot: URL { root.appending(path: "slot", directoryHint: .isDirectory) }
        var work: URL { root.appending(path: "work", directoryHint: .isDirectory) }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func workFiles() -> [String] {
            (try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []
        }
    }

    private static var inputFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 2, interleaved: false)!
    }

    /// RecordingWriter writes 48 kHz stereo synthetic audio: a 440 Hz sine for the first toneSec seconds, then digital silence for silenceSec seconds.
    private static func writeRecording(in sandbox: Sandbox) throws -> RecordingResult {
        try FileManager.default.createDirectory(at: sandbox.slot, withIntermediateDirectories: true)
        let url = sandbox.slot.appending(path: "slot.\(DictationRules.recordingFileExtension)")
        let writer = try RecordingWriter(url: url, inputFormat: inputFormat)
        let chunk = Int(inputRate / 10)
        let toneFrames = Int(toneSec * inputRate)
        let totalFrames = Int((toneSec + silenceSec) * inputRate)
        var position = 0
        while position < totalFrames {
            let frames = min(chunk, totalFrames - position)
            let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frames))!
            buffer.frameLength = AVAudioFrameCount(frames)
            for frame in 0..<frames {
                let index = position + frame
                let value: Float = index < toneFrames
                    ? amplitude * Float(sin(2 * Double.pi * 440 * Double(index) / inputRate))
                    : 0
                buffer.floatChannelData![0][frame] = value
                buffer.floatChannelData![1][frame] = value
            }
            try writer.append(buffer)
            position += frames
        }
        return try writer.close()
    }

    private static func ok(_ text: String) -> CloudSTTRecorder.Reply {
        let body = try! JSONSerialization.data(withJSONObject: ["text": text])
        return .init(status: 200, headers: ["Content-Type": "application/json"], body: body)
    }

    private static func status(_ code: Int, headers: [String: String] = [:]) -> CloudSTTRecorder.Reply {
        .init(status: code, headers: headers, body: Data(#"{"error":{"message":"x"}}"#.utf8))
    }

    private static func makeEngine(entry: VoiceSTTEntry, sandbox: Sandbox, recorder: CloudSTTRecorder) -> CloudSTTEngine {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudSTTEngineURLProtocol.self]
        CloudSTTEngineURLProtocol.requestHandler = { recorder.handle($0) }
        return CloudSTTEngine(
            baseURL: baseURL, apiKey: apiKey, entry: entry,
            session: URLSession(configuration: config),
            workDirectory: sandbox.work,
            sleeper: { recorder.recordSleep($0) }
        )
    }

    /// Expects an STTError to be thrown and returns it.
    private static func expectFailure(
        _ engine: CloudSTTEngine, _ recording: RecordingResult, sourceLocation: SourceLocation = #_sourceLocation
    ) async -> STTError? {
        do {
            let text = try await engine.transcribe(recording, language: nil)
            Issue.record("expected failure, got \(text)", sourceLocation: sourceLocation)
        } catch let error as STTError {
            return error
        } catch {
            Issue.record("unexpected error \(error)", sourceLocation: sourceLocation)
        }
        return nil
    }

    // MARK: - Multipart parsing

    private struct ParsedPart {
        let headers: String
        let content: Data

        var name: String? { Self.attribute("name", in: headers) }
        var fileName: String? { Self.attribute("filename", in: headers) }

        private static func attribute(_ key: String, in headers: String) -> String? {
            guard let start = headers.range(of: "; \(key)=\"") else { return nil }
            let rest = headers[start.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            return String(rest[..<end])
        }
    }

    /// Splits parts on the Content-Type boundary; also confirms the last delimiter is the closing marker.
    private static func parseMultipart(_ request: URLRequest, body: Data) throws -> [ParsedPart] {
        let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
        let boundary = try #require(contentType.components(separatedBy: "boundary=").last)
        let delimiter = Data("--\(boundary)".utf8)
        var ranges: [Range<Data.Index>] = []
        var cursor = body.startIndex
        while let range = body.range(of: delimiter, in: cursor..<body.endIndex) {
            ranges.append(range)
            cursor = range.upperBound
        }
        let last = try #require(ranges.last)
        #expect(body[last.upperBound...] == Data("--\r\n".utf8), "closing boundary")
        let crlf = 2
        var parts: [ParsedPart] = []
        for (open, close) in zip(ranges, ranges.dropFirst()) {
            let segment = body[(open.upperBound + crlf)..<(close.lowerBound - crlf)]
            let separator = try #require(segment.range(of: Data("\r\n\r\n".utf8)))
            parts.append(ParsedPart(
                headers: String(decoding: segment[segment.startIndex..<separator.lowerBound], as: UTF8.self),
                content: Data(segment[separator.upperBound...])
            ))
        }
        return parts
    }

    private static func fileContent(_ request: URLRequest, body: Data) throws -> Data {
        let parts = try parseMultipart(request, body: body)
        return try #require(parts.last(where: { $0.name == DictationRules.fileFieldName })).content
    }

    // MARK: - Cases

    @Test("real recording uploads m4a multipart", arguments: [openAIEntry, xaiEntry])
    func uploadsRecording(entry: VoiceSTTEntry) async throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        let recording = try Self.writeRecording(in: sandbox)
        let recorder = CloudSTTRecorder([Self.ok("  hello world \n")])
        let engine = Self.makeEngine(entry: entry, sandbox: sandbox, recorder: recorder)

        let text = try await engine.transcribe(recording, language: "zh_CN")

        #expect(text == "hello world")
        try #require(recorder.requests.count == 1)
        let (request, body) = recorder.requests[0]
        #expect(request.url?.absoluteString == "https://stt.example.test:8443\(entry.path)")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.apiKey)")

        let parts = try Self.parseMultipart(request, body: body)
        #expect(parts.map(\.name) == ["model", "language", "file"])
        #expect(parts.first?.content == Data(entry.model.utf8))
        #expect(parts.dropFirst().first?.content == Data("zh".utf8))
        let file = try #require(parts.last)
        #expect(file.fileName == "audio.m4a")
        #expect(file.headers.contains("Content-Type: audio/mp4"))
        try #require(file.content.count > 8)
        #expect(file.content[file.content.startIndex + 4..<file.content.startIndex + 8] == Data("ftyp".utf8))

        #expect(recorder.sleeps.isEmpty)
        #expect(FileManager.default.fileExists(atPath: recording.url.path), "slot .aac stays")
        #expect(sandbox.workFiles().isEmpty, "temporary m4a removed")
    }

    private static let geminiEntry = VoiceSTTEntry(
        model: "gemini-3.5-transcribe", transport: .geminiTranscribe, path: "/v1beta/interactions",
        maxBytes: 20_000_000, maxDurationSec: 600, languageField: nil, isDefault: true
    )
    private static let dashscopeEntry = VoiceSTTEntry(
        model: "qwen3-asr-flash", transport: .dashscopeASR, path: "/api/v1/services/aigc/multimodal-generation/generation",
        maxBytes: 10_000_000, maxDurationSec: 300, languageField: "language_hints", isDefault: true
    )

    private static func okJSON(_ object: Any) -> CloudSTTRecorder.Reply {
        .init(status: 200, headers: ["Content-Type": "application/json"],
              body: try! JSONSerialization.data(withJSONObject: object))
    }

    private static func expectM4A(_ data: Data?, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let data = try #require(data, sourceLocation: sourceLocation)
        try #require(data.count > 8, sourceLocation: sourceLocation)
        #expect(data[data.startIndex + 4..<data.startIndex + 8] == Data("ftyp".utf8), sourceLocation: sourceLocation)
    }

    @Test("gemini_transcribe sends x-goog-api-key with inline m4a and joins steps text")
    func test_geminiTranscribe_sendsGoogKeyAndParsesSteps() async throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        let recording = try Self.writeRecording(in: sandbox)
        let recorder = CloudSTTRecorder([Self.okJSON([
            "status": "completed",
            "steps": [
                ["type": "model_output", "content": [["type": "text", "text": " Hello"], ["type": "thought", "text": "x"]]],
                ["type": "model_output", "content": [["type": "text", "text": " world. "]]],
            ],
        ])])
        let engine = Self.makeEngine(entry: Self.geminiEntry, sandbox: sandbox, recorder: recorder)

        let text = try await engine.transcribe(recording, language: "zh_CN")

        #expect(text == "Hello world.")
        try #require(recorder.requests.count == 1)
        let (request, body) = recorder.requests[0]
        #expect(request.url?.absoluteString == "https://stt.example.test:8443/v1beta/interactions")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == Self.apiKey)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(json.keys) == ["model", "store", "input"])
        #expect(json["model"] as? String == Self.geminiEntry.model)
        #expect(json["store"] as? Bool == false)
        let input = try #require(json["input"] as? [[String: Any]])
        try #require(input.count == 1)
        #expect(input[0]["type"] as? String == "audio")
        #expect(input[0]["mime_type"] as? String == "audio/m4a")
        try Self.expectM4A(Data(base64Encoded: try #require(input[0]["data"] as? String)))
        #expect(sandbox.workFiles().isEmpty, "temporary m4a removed")
    }

    @Test("gemini_transcribe with no text in steps is an invalid response")
    func geminiTranscribeEmptyIsInvalid() async throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        let recording = try Self.writeRecording(in: sandbox)
        let recorder = CloudSTTRecorder([Self.okJSON(["steps": [["content": [["type": "text", "text": "  "]]]]])])
        let engine = Self.makeEngine(entry: Self.geminiEntry, sandbox: sandbox, recorder: recorder)

        let error = await Self.expectFailure(engine, recording)

        #expect(error?.failure == .invalidResponse)
        #expect(recorder.requests.count == 1)
    }

    @Test("dashscope_asr sends Bearer JSON with language_hints and parses output.text")
    func test_dashscopeASR_parsesOutputText() async throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        let recording = try Self.writeRecording(in: sandbox)
        let recorder = CloudSTTRecorder([Self.okJSON([
            "output": ["text": " \u{4F60}\u{597D}\u{FF0C}\u{4E16}\u{754C}\u{3002} ", "finish_reason": "stop"], "request_id": "req-1",
        ])])
        let engine = Self.makeEngine(entry: Self.dashscopeEntry, sandbox: sandbox, recorder: recorder)

        let text = try await engine.transcribe(recording, language: "zh_CN")

        #expect(text == "\u{4F60}\u{597D}\u{FF0C}\u{4E16}\u{754C}\u{3002}")
        try #require(recorder.requests.count == 1)
        let (request, body) = recorder.requests[0]
        #expect(request.url?.absoluteString == "https://stt.example.test:8443\(Self.dashscopeEntry.path)")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.apiKey)")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == nil)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == Self.dashscopeEntry.model)
        let parameters = try #require(json["parameters"] as? [String: Any])
        #expect(parameters["format"] as? String == "m4a")
        #expect(parameters["language_hints"] as? [String] == ["zh"])
        let messages = try #require((json["input"] as? [String: Any])?["messages"] as? [[String: Any]])
        #expect(messages.first?["role"] as? String == "user")
        let content = try #require(messages.first?["content"] as? [[String: Any]])
        #expect(content.first?["type"] as? String == "input_audio")
        let dataURL = try #require((content.first?["input_audio"] as? [String: Any])?["data"] as? String)
        let prefix = "data:audio/mp4;base64,"
        try #require(dataURL.hasPrefix(prefix))
        try Self.expectM4A(Data(base64Encoded: String(dataURL.dropFirst(prefix.count))))
    }

    @Test("503 then 200 retries once after Retry-After")
    func retriesTransientOnce() async throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        let recording = try Self.writeRecording(in: sandbox)
        let recorder = CloudSTTRecorder([Self.status(503, headers: ["Retry-After": " 2 "]), Self.ok("again")])
        let engine = Self.makeEngine(entry: Self.openAIEntry, sandbox: sandbox, recorder: recorder)

        let text = try await engine.transcribe(recording, language: nil)

        #expect(text == "again")
        #expect(recorder.requests.count == 2)
        #expect(recorder.sleeps == [2.0])
        // No language selected means no language field is sent.
        let (request, body) = recorder.requests[1]
        #expect(try Self.parseMultipart(request, body: body).map(\.name) == ["model", "file"])
        #expect(sandbox.workFiles().isEmpty)
    }

    @Test("401 stops with check connection after one request")
    func authFailureStops() async throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        let recording = try Self.writeRecording(in: sandbox)
        let recorder = CloudSTTRecorder([Self.status(401), Self.ok("unused")])
        let engine = Self.makeEngine(entry: Self.openAIEntry, sandbox: sandbox, recorder: recorder)

        let error = await Self.expectFailure(engine, recording)

        #expect(error == STTError(action: .checkConnection, failure: .http(status: 401, retryAfter: nil)))
        #expect(recorder.requests.count == 1)
        #expect(recorder.sleeps.isEmpty)
        #expect(FileManager.default.fileExists(atPath: recording.url.path))
        #expect(sandbox.workFiles().isEmpty)
    }

    @Test("400 stops with retry after one request")
    func permanentFailureStops() async throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        let recording = try Self.writeRecording(in: sandbox)
        let recorder = CloudSTTRecorder([Self.status(400), Self.ok("unused")])
        let engine = Self.makeEngine(entry: Self.xaiEntry, sandbox: sandbox, recorder: recorder)

        let error = await Self.expectFailure(engine, recording)

        #expect(error == STTError(action: .retry, failure: .http(status: 400, retryAfter: nil)))
        #expect(recorder.requests.count == 1)
        #expect(recorder.sleeps.isEmpty)
    }

    @Test("5xx still failing after the automatic retry reports autoRetried")
    func retryExhaustedMarksAutoRetried() async throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        let recording = try Self.writeRecording(in: sandbox)
        let recorder = CloudSTTRecorder([Self.status(503), Self.status(502), Self.ok("unused")])
        let engine = Self.makeEngine(entry: Self.openAIEntry, sandbox: sandbox, recorder: recorder)

        let error = await Self.expectFailure(engine, recording)

        #expect(recorder.requests.count == 2)
        #expect(error?.failure == .http(status: 502, retryAfter: nil))
        #expect(error?.autoRetried == true)
    }

    @Test("401 on the first request is not auto retried")
    func firstAuthFailureNotAutoRetried() async throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        let recording = try Self.writeRecording(in: sandbox)
        let recorder = CloudSTTRecorder([Self.status(401), Self.ok("unused")])
        let engine = Self.makeEngine(entry: Self.openAIEntry, sandbox: sandbox, recorder: recorder)

        let error = await Self.expectFailure(engine, recording)

        #expect(recorder.requests.count == 1)
        #expect(error?.autoRetried == false)
    }

    @Test("small maxDurationSec uploads segments in order and joins text")
    func segmentsAndJoins() async throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        let recording = try Self.writeRecording(in: sandbox)
        let entry = VoiceSTTEntry(
            model: "gpt-4o-mini-transcribe", transport: .openAITranscriptions, path: "/v1/audio/transcriptions",
            maxBytes: 25_000_000, maxDurationSec: 1, languageField: "language", isDefault: true
        )
        // 3 s, Lmax = 1 s: there is no silence midpoint (2.25) inside [0.5, 1] / [1.5, 2], so it is hard-cut into [0,1] [1,2] [2,3].
        let recorder = CloudSTTRecorder([Self.ok(" Hello "), Self.ok("world."), Self.ok("\u{4F60}\u{597D}")])
        let engine = Self.makeEngine(entry: entry, sandbox: sandbox, recorder: recorder)

        let text = try await engine.transcribe(recording, language: nil)

        #expect(text == "Hello world.\u{4F60}\u{597D}")
        try #require(recorder.requests.count == 3)
        for (index, captured) in recorder.requests.enumerated() {
            let content = try Self.fileContent(captured.request, body: captured.body)
            #expect(content[content.startIndex + 4..<content.startIndex + 8] == Data("ftyp".utf8))
            // Each segment reads back about 1 s.
            let copy = sandbox.root.appending(path: "segment-\(index).m4a")
            try content.write(to: copy)
            let file = try AVAudioFile(forReading: copy)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                       frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            let seconds = Double(buffer.frameLength) / file.fileFormat.sampleRate
            #expect(abs(seconds - 1.0) <= 0.05, "segment \(index) = \(seconds)")
        }
        #expect(sandbox.workFiles().isEmpty)
        #expect(FileManager.default.fileExists(atPath: recording.url.path))
    }

    @Test("durationSec 0 falls back to the file's measured duration, so segmenting still applies")
    func zeroDurationSegmentsByFile() async throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        let written = try Self.writeRecording(in: sandbox)
        let recording = RecordingResult(url: written.url, durationSec: 0, envelope: written.envelope)
        let entry = VoiceSTTEntry(
            model: "gpt-4o-mini-transcribe", transport: .openAITranscriptions, path: "/v1/audio/transcriptions",
            maxBytes: 25_000_000, maxDurationSec: 2, languageField: "language", isDefault: true
        )
        // Measured at about 3 s (the last ADTS packet is padded, adding a few ms), Lmax = 2 s: it is split into two segments; with a duration of 0 the whole recording must not be uploaded in one go.
        let recorder = CloudSTTRecorder([Self.ok("one"), Self.ok("two")])
        let engine = Self.makeEngine(entry: entry, sandbox: sandbox, recorder: recorder)

        let text = try await engine.transcribe(recording, language: nil)

        #expect(recorder.requests.count == 2)
        #expect(text == DictationRules.join(["one", "two"]))
        #expect(sandbox.workFiles().isEmpty)
    }

    @Test("permanent failure in any segment fails the whole dictation")
    func segmentFailureFailsWhole() async throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        let recording = try Self.writeRecording(in: sandbox)
        let entry = VoiceSTTEntry(
            model: "grok-stt", transport: .xaiSTT, path: "/v1/stt",
            maxBytes: 500_000_000, maxDurationSec: 1, languageField: nil, isDefault: true
        )
        let recorder = CloudSTTRecorder([Self.ok("Hello"), Self.status(400), Self.ok("unused")])
        let engine = Self.makeEngine(entry: entry, sandbox: sandbox, recorder: recorder)

        let error = await Self.expectFailure(engine, recording)

        #expect(error == STTError(action: .retry, failure: .http(status: 400, retryAfter: nil)))
        #expect(recorder.requests.count == 2, "later segments not uploaded")
        #expect(sandbox.workFiles().isEmpty)
        #expect(FileManager.default.fileExists(atPath: recording.url.path))
    }
}
