import Foundation
import OriveoProviderKit

/// Connection settings for one gemini_live session.
nonisolated struct GeminiLiveConfig: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    let host: String
    let path: String
    let model: String
    let voice: String
    let apiKey: String

    /// The API key is always redacted so configs never leak it into logs.
    var description: String {
        "GeminiLiveConfig(host: \(host), path: \(path), model: \(model), voice: \(voice), apiKey: <redacted>)"
    }

    var debugDescription: String { description }
}

/// Minimal text WebSocket used by GeminiLiveTransport; tests inject a replay fake.
/// `receive()` returning nil or throwing both mean the connection is closed.
nonisolated protocol GeminiLiveSocket: Sendable {
    func send(_ text: String) async throws
    func receive() async throws -> String?
    func close()
}

/// Stream failures of GeminiLiveTransport (never mapped to an `error` event).
/// Cases carry no underlying error: URLError holds the authenticated URL (with ?key=).
nonisolated enum GeminiLiveTransportError: Error, Equatable, CustomStringConvertible {
    case invalidURL
    /// The first connection could not be opened or its setup could not be sent.
    case connectFailed
    /// The connection closed without a preceding goAway (and could not be resumed).
    case connectionClosed
    /// The resumed connection failed or closed before setupComplete (tried once).
    case resumeFailed
    /// The server closed a connection with 1008 after Ready, or rejected the resume handle with 1008:
    /// the session expired server-side and cannot be resumed. `reason` is the server close reason for
    /// diagnostics (at most 200 characters, URLs and the API key redacted).
    case sessionExpired(reason: String?)

    var isSessionExpired: Bool {
        if case .sessionExpired = self { return true }
        return false
    }

    var description: String {
        switch self {
        case .invalidURL: "invalidURL"
        case .connectFailed: "connectFailed"
        case .connectionClosed: "connectionClosed"
        case .resumeFailed: "resumeFailed"
        case let .sessionExpired(reason): reason.map { "sessionExpired: \($0)" } ?? "sessionExpired"
        }
    }

    /// Longest close reason kept in the error description.
    static let maxReasonLength = 200

    /// Close reason safe for diagnostics: URLs, `key=` parameters and the API key are redacted, then it is
    /// truncated to `maxReasonLength`; blank becomes nil.
    static func diagnosticReason(_ raw: String?, apiKey: String) -> String? {
        guard var text = raw else { return nil }
        text = text.replacingOccurrences(
            of: "[A-Za-z][A-Za-z0-9+.-]*://\\S*", with: "<url>", options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "(?i)key=\\S*", with: "<redacted>", options: .regularExpression
        )
        if !apiKey.isEmpty {
            text = text.replacingOccurrences(of: apiKey, with: "<redacted>")
            if let encoded = apiKey.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
                text = text.replacingOccurrences(of: encoded, with: "<redacted>")
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxReasonLength))
    }
}

/// Server close carrying a WebSocket close code; thrown by `GeminiLiveSocket.receive()`.
nonisolated struct GeminiLiveSocketClosed: Error, Equatable {
    let code: Int
    let reason: String?
}

/// Production socket over URLSessionWebSocketTask; binary frames are decoded as UTF-8 JSON text.
nonisolated final class URLSessionGeminiLiveSocket: GeminiLiveSocket, @unchecked Sendable {
    private let connection: RealtimeSocketConnection
    private var task: URLSessionWebSocketTask { connection.task }

    /// Opens on its own ephemeral session.
    init(url: URL) {
        connection = RealtimeSocketConnection(request: URLRequest(url: url))
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func receive() async throws -> String? {
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await task.receive()
        } catch {
            // Surface the server close code so the transport can tell a rejected resume from a plain drop.
            let code = task.closeCode
            guard code != .invalid else { throw error }
            throw GeminiLiveSocketClosed(
                code: code.rawValue,
                reason: task.closeReason.map { String(decoding: $0, as: UTF8.self) }
            )
        }
        switch message {
        case let .string(text):
            return text
        case let .data(data):
            return String(decoding: data, as: UTF8.self)
        @unknown default:
            return nil
        }
    }

    func close() {
        connection.close()
    }
}

/// gemini_live transport with GoAway resumption (E-151) and resumption after unexpected drops. One session per instance.
nonisolated final class GeminiLiveTransport: RealtimeTransport {
    typealias SocketFactory = @Sendable (URL) throws -> any GeminiLiveSocket
    /// Waits the given milliseconds; injected so tests can drive the forced switch.
    typealias Sleep = @Sendable (Int) async throws -> Void

    /// Audio buffered during a switch keeps the newest chunks within this many base64 characters.
    static let audioBufferLimit = 220_000

    /// Consecutive resume attempts after an unexpected drop that may fail before Ready.
    static let maxRecoveryAttempts = 4

    /// Wait (ms) before each consecutive resume attempt; attempt n uses entry n-1. Reset once Ready.
    static let recoveryBackoffMs = [0, 1000, 2000, 4000]

    /// Uplink not yet sent on the current connection beyond this many bytes (8 s of 16 kHz PCM16) marks it as
    /// stalled (contract E, E-202). Above the ~5 s buffer a resumed connection flushes at once.
    static let stalledUplinkBytes = 16_000 * 2 * 8

    /// Close code the server uses when a resume handle names a session that no longer exists or expired.
    static let sessionRejectedCloseCode = 1008

    /// Longest wait (ms) whose nanoseconds still fit Int64; longer waits count as untimed.
    static let maxSleepMs = Int(Int64.max / 1_000_000)

    static let defaultSleep: Sleep = { ms in
        guard ms <= GeminiLiveTransport.maxSleepMs else {
            // Saturate instead of trapping: wait until cancelled.
            try await Task.sleep(nanoseconds: UInt64.max)
            return
        }
        try await Task.sleep(nanoseconds: UInt64(max(ms, 0)) * 1_000_000)
    }

    let kind: RealtimeTransportKind = .geminiLive
    /// Matches `GeminiLiveWire.inputMimeType` (audio/pcm;rate=16000).
    let uplinkSampleRate = 16_000.0
    private let core: Core

    init(
        config: GeminiLiveConfig,
        resumeHandle: String? = nil,
        socketFactory: @escaping SocketFactory = { URLSessionGeminiLiveSocket(url: $0) },
        sleep: @escaping Sleep = GeminiLiveTransport.defaultSleep
    ) {
        core = Core(config: config, resumeHandle: resumeHandle, factory: socketFactory, sleep: sleep)
    }

    func openRealtimeSession(
        transport: RealtimeTransportInput
    ) -> AsyncThrowingStream<RealtimeSessionEvent, Error> {
        let core = core
        return AsyncThrowingStream { continuation in
            let task = Task { await core.run(input: transport, continuation: continuation) }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await core.close() }
            }
        }
    }

    /// Sends a 16 kHz PCM16 chunk; buffered until the (re)connection is ready.
    func appendAudio(base64: String) async {
        await core.appendAudio(base64)
    }

    /// The uplink backlog says the current connection is stalled: tear it down at once and handle it like an
    /// unexpected close (pending sends fail, its unread events are dropped, later audio is buffered, the close
    /// handling resumes with the last handle).
    func dropStalledUplink() async {
        await core.dropStalledUplink()
    }

    /// Host teardown (call, Siri, background): closes the socket and finishes the stream without an event.
    func close() async {
        await core.close()
    }

    /// Latest resumable handle seen on this session (or the handle it was opened with).
    var lastResumeHandle: String? {
        get async { await core.lastHandle }
    }
}

private nonisolated enum GeminiLiveSignal: Sendable {
    case message(generation: Int, text: String)
    case closed(generation: Int, code: Int?, reason: String?)
    case deadline(generation: Int)
}

private extension GeminiLiveTransport {
    actor Core {
        private let config: GeminiLiveConfig
        private let factory: SocketFactory
        private let sleep: Sleep

        private(set) var lastHandle: String?
        private var continuation: AsyncThrowingStream<RealtimeSessionEvent, Error>.Continuation?
        private var signals: AsyncStream<GeminiLiveSignal>.Continuation?
        private var socket: (any GeminiLiveSocket)?
        private var reader: Task<Void, Never>?
        private var instructions = ""
        private var deadline: Task<Void, Never>?
        private var finished = false

        private var generation = 0
        private var mapper = GeminiLiveEventMapper()
        private var initialConnection = true
        private var awaitingSetup = true
        private var goAwayReceived = false
        private var endingWithoutHandle = false
        /// First error of the current unexpected-drop recovery; nil when not recovering.
        private var recoveryError: GeminiLiveTransportError?
        private var recoveryAttempts = 0

        private var audioReady = false
        private var pendingAudio: [String] = []
        private var pendingChars = 0
        /// Whether the Ready connection is sending history or flushing buffered audio (live audio is buffered behind it).
        private var flushing = false
        /// Bytes handed to the Ready connection during the history send / flush and not yet sent: the in-flight frame,
        /// the buffered audio behind it and audio trimmed from that buffer (it arrived faster than the uplink drained).
        private var flushBacklog = 0
        /// Connection torn down as stalled: its unread messages never reach the session.
        private var abandonedGeneration: Int?

        init(config: GeminiLiveConfig, resumeHandle: String?, factory: @escaping SocketFactory, sleep: @escaping Sleep) {
            self.config = config
            self.factory = factory
            self.sleep = sleep
            lastHandle = (resumeHandle?.isEmpty == false) ? resumeHandle : nil
        }

        func run(input: RealtimeTransportInput, continuation: AsyncThrowingStream<RealtimeSessionEvent, Error>.Continuation) async {
            guard !finished else {
                continuation.finish()
                return
            }
            self.continuation = continuation
            let (stream, signalContinuation) = AsyncStream<GeminiLiveSignal>.makeStream()
            signals = signalContinuation
            instructions = input.instructions
            let history = input.history.map { GeminiLiveHistoryTurn(role: $0.role.rawValue, text: $0.text) }
            let opening = GeminiLiveWire.openingMessages(
                instructions: input.instructions,
                history: history,
                model: config.model,
                voice: config.voice,
                resumeHandle: lastHandle
            )
            do {
                try await connect(opening.beforeReady)
            } catch {
                fail(GeminiLiveTransportError.connectFailed)
                return
            }
            for await signal in stream {
                if finished { break }
                switch signal {
                case let .message(gen, text):
                    guard gen == generation, gen != abandonedGeneration, let message = Self.decode(text) else { continue }
                    await handle(message, afterReady: opening.afterReady)
                case let .closed(gen, code, reason):
                    guard gen == generation else { continue }
                    await handleClosed(code: code, reason: reason)
                case let .deadline(gen):
                    guard gen == generation, goAwayReceived, !endingWithoutHandle else { continue }
                    await switchConnection()
                }
            }
        }

        func appendAudio(_ chunk: String) async {
            guard !finished else { return }
            if audioReady, let socket {
                let gen = generation
                do {
                    try await socket.send(Self.encode(GeminiLiveWire.audioAppendMessage(base64: chunk)))
                } catch {
                    // A failed uplink send counts as an unexpected drop of this connection.
                    guard !finished, gen == generation else { return }
                    bufferAudio(chunk)
                    dropConnection()
                }
                return
            }
            bufferAudio(chunk)
            guard flushing, socket != nil else { return }
            // Same measure as the live sends (contract E): judged only when a new frame arrives, no timer.
            flushBacklog += Self.audioBytes(chunk)
            if flushBacklog > GeminiLiveTransport.stalledUplinkBytes { dropStalledConnection() }
        }

        /// Only a Ready connection (live sends, history or flush) carries uplink; otherwise audio is already being buffered.
        func dropStalledUplink() {
            guard !finished, audioReady || flushing, socket != nil else { return }
            dropStalledConnection()
        }

        /// Puts an unsent chunk back at the head, then trims the oldest audio over the limit.
        private func requeueAudio(_ chunk: String) {
            pendingAudio.insert(chunk, at: 0)
            pendingChars += chunk.count
            while pendingChars > GeminiLiveTransport.audioBufferLimit, !pendingAudio.isEmpty {
                pendingChars -= pendingAudio.removeFirst().count
            }
        }

        private func bufferAudio(_ chunk: String) {
            pendingAudio.append(chunk)
            pendingChars += chunk.count
            while pendingChars > GeminiLiveTransport.audioBufferLimit, !pendingAudio.isEmpty {
                pendingChars -= pendingAudio.removeFirst().count
            }
        }

        func close() {
            guard !finished else { return }
            finish(nil)
        }

        // MARK: - Session flow

        private func handle(_ message: [String: Any], afterReady: [[String: Any]]) async {
            if !awaitingSetup, message["serverContent"] != nil {
                recoveryError = nil
                recoveryAttempts = 0
            }
            for event in mapper.map(message) {
                switch event {
                case .ready:
                    // Ready alone does not reset the recovery counter; the first
                    // serverContent after Ready does (below), so ready-then-drop loops stay capped.
                    awaitingSetup = false
                    let gen = generation
                    flushing = true
                    flushBacklog = pendingAudio.reduce(0) { $0 + Self.audioBytes($1) }
                    if initialConnection {
                        yield(.ready)
                        // Missing history would leave the model without context: end instead of resuming.
                        do {
                            let frames = afterReady.map(Self.encode)
                            flushBacklog += frames.reduce(0) { $0 + $1.utf8.count }
                            for frame in frames {
                                try await socket?.send(frame)
                                if gen == generation { flushBacklog -= frame.utf8.count }
                            }
                        } catch {
                            fail(GeminiLiveTransportError.connectionClosed)
                            return
                        }
                    }
                    await flushAudio()
                case let .resumable(handle):
                    lastHandle = handle
                    yield(event)
                case let .goAway(timeLeftMs):
                    yield(event)
                    goAwayReceived = true
                    if let timeLeftMs { scheduleDeadline(max(timeLeftMs - 1000, 0)) }
                default:
                    yield(event)
                }
                if finished { return }
            }
            if goAwayReceived, !endingWithoutHandle, !mapper.midTurn {
                await switchConnection()
            }
        }

        private func handleClosed(code: Int?, reason: String?) async {
            if code == GeminiLiveTransport.sessionRejectedCloseCode, !initialConnection || !awaitingSetup {
                // The session is gone server-side (closed after Ready or resume rejected): never resume with this handle.
                // Close out pending user text first so the reducer persists it before the silent reopen / end.
                for event in mapper.flushPendingUser() { yield(event) }
                fail(GeminiLiveTransportError.sessionExpired(
                    reason: GeminiLiveTransportError.diagnosticReason(reason, apiKey: config.apiKey)
                ))
            } else if !initialConnection, awaitingSetup {
                if let recoveryError {
                    await recover(from: recoveryError)
                } else {
                    fail(GeminiLiveTransportError.resumeFailed)
                }
            } else if goAwayReceived {
                if !endingWithoutHandle, lastHandle != nil {
                    await switchConnection()
                } else {
                    // Expired without a handle: finalize pending user text first, then end the session
                    for event in mapper.flushPendingUser() { yield(event) }
                    yield(.sessionEnded(reason: "go_away"))
                    finish(nil)
                }
            } else if !awaitingSetup, lastHandle != nil {
                // Unexpected drop after Ready (no goAway, not client-initiated): resume with the last handle.
                await recover(from: .connectionClosed)
            } else {
                // Unexpected drop with no handle: close out pending user text before ending with an error.
                for event in mapper.flushPendingUser() { yield(event) }
                fail(GeminiLiveTransportError.connectionClosed)
            }
        }

        /// Resumes after an unexpected drop; ends with the first error once the attempts run out.
        private func recover(from error: GeminiLiveTransportError) async {
            let original = recoveryError ?? error
            recoveryError = original
            guard recoveryAttempts < GeminiLiveTransport.maxRecoveryAttempts, lastHandle != nil else {
                fail(original)
                return
            }
            let wait = GeminiLiveTransport.recoveryBackoffMs[
                min(recoveryAttempts, GeminiLiveTransport.recoveryBackoffMs.count - 1)
            ]
            recoveryAttempts += 1
            if wait > 0 {
                // The dead socket must not take uplink audio while waiting: buffer it for the next connection.
                audioReady = false
                do {
                    try await sleep(wait)
                } catch {
                    fail(original)
                    return
                }
                guard !finished else { return }
            }
            await switchConnection()
        }

        /// Close old → open with the last handle (no history) → fresh mapper; without a handle wait for the server close.
        private func switchConnection() async {
            deadline?.cancel()
            deadline = nil
            guard let handle = lastHandle else {
                endingWithoutHandle = true
                return
            }
            // Finalize the old mapper's pending user text before replacing it, so nothing is lost
            for event in mapper.flushPendingUser() { yield(event) }
            audioReady = false
            flushing = false
            flushBacklog = 0
            socket?.close()
            socket = nil
            reader?.cancel()
            reader = nil
            generation += 1
            initialConnection = false
            awaitingSetup = true
            goAwayReceived = false
            mapper = GeminiLiveEventMapper()
            let opening = GeminiLiveWire.openingMessages(
                instructions: instructions, history: [], model: config.model, voice: config.voice, resumeHandle: handle
            )
            do {
                try await connect(opening.beforeReady)
            } catch {
                if let recoveryError {
                    await recover(from: recoveryError)
                } else {
                    fail(GeminiLiveTransportError.resumeFailed)
                }
            }
        }

        private func connect(_ frames: [[String: Any]]) async throws {
            let address = GeminiLiveWire.authenticatedURL(host: config.host, path: config.path, key: config.apiKey)
            guard let url = URL(string: address) else { throw GeminiLiveTransportError.invalidURL }
            let opened = try factory(url)
            socket = opened
            for frame in frames {
                try await opened.send(Self.encode(frame))
            }
            let gen = generation
            let signals = signals
            reader = Task {
                var code: Int?
                var reason: String?
                do {
                    while let text = try await opened.receive() {
                        signals?.yield(.message(generation: gen, text: text))
                    }
                } catch let closed as GeminiLiveSocketClosed {
                    code = closed.code
                    reason = closed.reason
                } catch {}
                signals?.yield(.closed(generation: gen, code: code, reason: reason))
            }
        }

        private func scheduleDeadline(_ ms: Int) {
            deadline?.cancel()
            deadline = nil
            // Beyond the Int64 nanosecond range the wait is treated as untimed.
            guard ms <= GeminiLiveTransport.maxSleepMs else { return }
            let gen = generation
            let signals = signals
            let sleep = sleep
            deadline = Task {
                do {
                    try await sleep(ms)
                    signals?.yield(.deadline(generation: gen))
                } catch {}
            }
        }

        /// Sends buffered audio in order; on a send failure the unsent chunks stay buffered and the connection is dropped.
        private func flushAudio() async {
            let gen = generation
            while !pendingAudio.isEmpty, !finished, let socket {
                // Take the chunk out before awaiting: bufferAudio may trim the head while send is suspended.
                let chunk = pendingAudio.removeFirst()
                pendingChars -= chunk.count
                do {
                    try await socket.send(Self.encode(GeminiLiveWire.audioAppendMessage(base64: chunk)))
                } catch {
                    requeueAudio(chunk)
                    if !finished, gen == generation { dropConnection() }
                    return
                }
                guard gen == generation, flushing else {
                    requeueAudio(chunk)
                    return
                }
                flushBacklog -= Self.audioBytes(chunk)
            }
            guard gen == generation, flushing else { return }
            flushing = false
            flushBacklog = 0
            audioReady = true
        }

        /// Closes the current socket so its reader reports `.closed` and the close handling decides resume or failure.
        private func dropConnection() {
            audioReady = false
            flushing = false
            flushBacklog = 0
            socket?.close()
        }

        /// Stalled uplink (E-202, card F item 1): the socket close sends 1000 best effort and tears the connection down
        /// at once, so pending sends return now; the reader is cancelled, the connection's unread messages are dropped,
        /// and the close is reported here instead of waiting for the reader.
        private func dropStalledConnection() {
            let gen = generation
            dropConnection()
            socket = nil
            reader?.cancel()
            reader = nil
            abandonedGeneration = gen
            signals?.yield(.closed(generation: gen, code: nil, reason: nil))
        }

        /// Raw PCM bytes of a base64 chunk.
        private static func audioBytes(_ chunk: String) -> Int {
            let padding = chunk.hasSuffix("==") ? 2 : (chunk.hasSuffix("=") ? 1 : 0)
            return chunk.utf8.count / 4 * 3 - padding
        }

        // MARK: - Termination

        private func yield(_ event: RealtimeSessionEvent) {
            guard !finished else { return }
            continuation?.yield(event)
        }

        private func fail(_ error: Error) {
            finish(error)
        }

        private func finish(_ error: Error?) {
            guard !finished else { return }
            finished = true
            if let error {
                continuation?.finish(throwing: error)
            } else {
                continuation?.finish()
            }
            continuation = nil
            signals?.finish()
            signals = nil
            deadline?.cancel()
            deadline = nil
            reader?.cancel()
            reader = nil
            socket?.close()
            socket = nil
            pendingAudio = []
            pendingChars = 0
        }

        // MARK: - JSON

        private static func decode(_ text: String) -> [String: Any]? {
            (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        }

        private static func encode(_ frame: [String: Any]) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: frame) else { return "{}" }
            return String(decoding: data, as: UTF8.self)
        }
    }
}
