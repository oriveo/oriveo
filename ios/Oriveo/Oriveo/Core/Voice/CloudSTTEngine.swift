import AVFoundation
import Foundation

/// Cloud dictation (openai_transcriptions / xai_stt upload multipart and read a top-level `text` from the response;
/// gemini_transcribe / dashscope_asr send a JSON body with inline base64 audio; requests and parsing live in DictationRules).
/// The slot's `.aac` is passthrough-exported to m4a; when it exceeds the entry limit it is split at silence points and uploaded
/// segment by segment in order, each segment auto-retried at most once per the failure matrix, and the results are joined with DictationRules.join.
/// Temporary m4a files live in workDirectory (caches by default) and are deleted after use; the slot's `.aac` belongs to the controller and is not deleted here.
/// Uses the injected URLSession.data(for:) directly rather than BaseAPIService (which throws on non-2xx and would hide Retry-After).
nonisolated struct CloudSTTEngine: STTEngine {

    /// Wait before a retry, in seconds; tests inject an implementation that does not really sleep.
    typealias Sleeper = @Sendable (Double) async throws -> Void

    static let defaultSleeper: Sleeper = { seconds in
        try await Task.sleep(for: .seconds(seconds))
    }

    static var defaultWorkDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "dictation-upload", directoryHint: .isDirectory)
    }

    let baseURL: URL
    let apiKey: String
    let entry: VoiceSTTEntry
    private let session: URLSession
    private let workDirectory: URL
    private let sleeper: Sleeper

    init(
        baseURL: URL,
        apiKey: String,
        entry: VoiceSTTEntry,
        session: URLSession = .shared,
        workDirectory: URL = CloudSTTEngine.defaultWorkDirectory,
        sleeper: @escaping Sleeper = CloudSTTEngine.defaultSleeper
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.entry = entry
        self.session = session
        self.workDirectory = workDirectory
        self.sleeper = sleeper
    }

    /// Export and upload run on a background executor, off the main thread (the caller is on the main actor).
    @concurrent
    func transcribe(_ recording: RecordingResult, language: String?) async throws -> String {
        do {
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        } catch {
            throw STTError(action: .retry, failure: nil)
        }
        let whole = temporaryFile()
        defer { try? FileManager.default.removeItem(at: whole) }
        try await export(recording.url, to: whole, span: nil)

        // The segment limit is derived from the byte rate of the whole m4a.
        // When the duration is missing (0), use the measured file duration so the segment limit is not bypassed.
        let plan = DictationRules.segmentPlan(
            durationSec: recording.durationSec > 0 ? recording.durationSec : Self.fileDuration(recording.url),
            uploadBytes: fileSize(whole),
            silences: DictationRules.silenceRuns(envelope: recording.envelope),
            entry: entry
        )
        guard plan.count > 1 else {
            return DictationRules.join([try await upload(whole, language: language)])
        }
        var texts: [String] = []
        for span in plan {
            try Task.checkCancellation()
            let part = temporaryFile()
            defer { try? FileManager.default.removeItem(at: part) }
            try await export(recording.url, to: part, span: span)
            // If any segment stops, the whole run fails and later segments are not uploaded.
            texts.append(try await upload(part, language: language))
        }
        return DictationRules.join(texts)
    }

    // MARK: - Internals

    private enum Outcome {
        case text(String)
        case failed(DictationFailure)
    }

    private func temporaryFile() -> URL {
        workDirectory.appending(path: "\(UUID().uuidString).m4a")
    }

    /// Measured duration of the slot's `.aac` minus the AAC encoder priming frames; 0 if it cannot be read.
    private static func fileDuration(_ url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        return max(0, seconds - RecordingExporter.aacPrimingSec)
    }

    private func fileSize(_ url: URL) -> Int {
        let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        return size?.intValue ?? 0
    }

    private func export(_ source: URL, to destination: URL, span: DictationSpan?) async throws {
        do {
            try await RecordingExporter.exportM4A(from: source, to: destination, span: span)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw STTError(action: .retry, failure: nil)
        }
    }

    /// Uploads one segment; attempt starts at 1, and DictationRules.decide chooses between an automatic retry and stopping.
    private func upload(_ file: URL, language: String?) async throws -> String {
        let audio: Data
        do {
            audio = try Data(contentsOf: file)
        } catch {
            throw STTError(action: .retry, failure: nil)
        }
        // A base URL that cannot form a request address is a connection configuration problem.
        guard let request = DictationRules.makeRequest(
            baseURL: baseURL, entry: entry, language: language, apiKey: apiKey, audio: audio
        ) else {
            throw STTError(action: .checkConnection, failure: nil)
        }
        var attempt = 1
        while true {
            switch try await send(request) {
            case .text(let text):
                return text
            case .failed(let failure):
                switch DictationRules.decide(failure, attempt: attempt) {
                case .autoRetry(let delaySec):
                    try await sleeper(delaySec)
                    attempt += 1
                case .stop(let action):
                    throw STTError(action: action, failure: failure, autoRetried: attempt > 1)
                }
            }
        }
    }

    private func send(_ request: URLRequest) async throws -> Outcome {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if error.code == .cancelled, Task.isCancelled { throw CancellationError() }
            return .failed(error.code == .timedOut ? .timeout : .network)
        } catch {
            return .failed(.network)
        }
        guard let http = response as? HTTPURLResponse else { return .failed(.network) }
        guard (200..<300).contains(http.statusCode) else {
            return .failed(.http(status: http.statusCode, retryAfter: http.value(forHTTPHeaderField: "Retry-After")))
        }
        guard let text = DictationRules.transcript(fromResponseData: data, transport: entry.transport) else { return .failed(.invalidResponse) }
        return .text(text)
    }
}
