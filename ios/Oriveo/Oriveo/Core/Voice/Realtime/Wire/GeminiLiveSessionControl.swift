import Foundation

/// Adapts `GeminiLiveTransport` to the realtime session control surface:
/// capture arrives already at 16 kHz (`uplinkSampleRate`) and is handed to the transport unchanged, in call order.
nonisolated final class GeminiLiveSessionControl: RealtimeTransport, RealtimeSessionControl, @unchecked Sendable {
    private enum Operation: Sendable {
        case audio(String, bytes: Int)
        case text(String)
        case close
        case barrier(CheckedContinuation<Void, Never>)
    }

    let kind: RealtimeTransportKind = .geminiLive
    private let transport: GeminiLiveTransport
    /// Gemini Live takes 16 kHz PCM16 input; capture resamples straight to it (no 24 kHz hop).
    var uplinkSampleRate: Double { transport.uplinkSampleRate }
    private let lock = NSLock()
    private let operations: AsyncStream<Operation>.Continuation
    private let worker: Task<Void, Never>
    private let backlog = UplinkBacklog()

    /// Uplink backlog beyond this many bytes (8 s of 16 kHz PCM16) marks the connection as stalled (contract E, E-202).
    /// Above the ~5 s buffer a resumed connection flushes at once, so a flush that keeps up never trips it.
    static let stalledBacklogBytes = GeminiLiveTransport.stalledUplinkBytes

    /// 16 kHz PCM bytes enqueued for or in flight to the transport and not yet sent. Audio the transport buffers
    /// behind a history send or resume flush is counted by the transport against the same threshold.
    private final class UplinkBacklog: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = 0
        /// Whether the current over-threshold episode was already reported.
        private var reported = false

        /// Adds an enqueued chunk; true when the backlog first exceeds the stall threshold.
        func enqueued(_ count: Int) -> Bool {
            lock.withLock {
                bytes += count
                guard bytes > GeminiLiveSessionControl.stalledBacklogBytes, !reported else { return false }
                reported = true
                return true
            }
        }

        var pendingBytes: Int { lock.withLock { bytes } }

        func sent(_ count: Int) {
            lock.withLock {
                bytes -= count
                if bytes <= GeminiLiveSessionControl.stalledBacklogBytes { reported = false }
            }
        }
    }

    init(transport: GeminiLiveTransport) {
        self.transport = transport
        let (stream, sink) = AsyncStream<Operation>.makeStream()
        operations = sink
        let backlog = backlog
        worker = Task {
            for await operation in stream {
                switch operation {
                case let .audio(chunk, bytes):
                    await transport.appendAudio(base64: chunk)
                    backlog.sent(bytes)
                case let .text(text):
                    await transport.sendText(text)
                case .close:
                    await transport.close()
                case let .barrier(continuation):
                    continuation.resume()
                }
            }
        }
    }

    convenience init(
        endpoint: RealtimeEndpoint,
        resumeHandle: String? = nil,
        route: @escaping RealtimeRouteProvider = { .speaker }
    ) {
        self.init(transport: GeminiLiveTransport(
            config: Self.config(for: endpoint), resumeHandle: resumeHandle, route: route
        ))
    }

    deinit {
        operations.finish()
    }

    static func config(for endpoint: RealtimeEndpoint) -> GeminiLiveConfig {
        GeminiLiveConfig(
            host: endpoint.host,
            path: endpoint.path,
            model: endpoint.model,
            voice: endpoint.voice,
            apiKey: endpoint.apiKey,
            language: endpoint.language
        )
    }

    func openRealtimeSession(
        transport input: RealtimeTransportInput
    ) -> AsyncThrowingStream<RealtimeSessionEvent, Error> {
        transport.openRealtimeSession(transport: input)
    }

    func sendAudio(_ pcm16: Data) {
        guard !pcm16.isEmpty else { return }
        // Enqueue under one lock so the transport sees chunks in call order.
        lock.withLock {
            operations.yield(.audio(pcm16.base64EncodedString(), bytes: pcm16.count))
            // Judged only when a new frame arrives (no timer); reported once per over-threshold episode.
            guard backlog.enqueued(pcm16.count) else { return }
            let transport = transport
            Task { await transport.dropStalledUplink() }
        }
    }

    /// Typed user turn, ordered with the audio enqueued around it; the transport queues it until the connection is ready.
    func sendText(_ text: String) {
        lock.withLock { _ = operations.yield(.text(text)) }
    }

    /// Returns once every chunk enqueued before this call has been handed to the transport.
    func drainUplink() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let result = lock.withLock { operations.yield(.barrier(continuation)) }
            if case .terminated = result { continuation.resume() }
        }
    }

    /// Gemini Live has no truncate message; barge-in is handled server-side.
    func truncate(itemId: String?, contentIndex: Int, playedMs: Double) {}

    func close() {
        lock.withLock {
            operations.yield(.close)
            operations.finish()
        }
    }

    /// Uplink backlog as audio duration (PCM16 mono at `uplinkSampleRate`); a failure signal of the controller.
    var uplinkBacklogMs: Double? {
        Double(max(0, backlog.pendingBytes)) * 1000 / (uplinkSampleRate * 2)
    }

    /// Latest resumable handle seen on this session (or the handle it was opened with).
    var lastResumeHandle: String? {
        get async { await transport.lastResumeHandle }
    }
}
