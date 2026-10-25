import Foundation

nonisolated enum GARealtimeTransportError: Error, Equatable {
    case invalidURL
    case closedByPeer
}

/// OpenAI / xAI GA realtime over WebSocket: sends opening messages on connect, maps server
/// frames through GARealtimeCodec, and exposes audio / truncate / close control.
nonisolated final class GARealtimeTransport: RealtimeTransport, RealtimeSessionControl, @unchecked Sendable {
    typealias SocketFactory = @Sendable (URLRequest) -> any RealtimeSocket

    let kind: RealtimeTransportKind
    let uplinkSampleRate = Double(GARealtimeCodec.inputSampleRateHz)
    let endpoint: RealtimeEndpoint
    private let codec: GARealtimeCodec
    private let makeSocket: SocketFactory
    private let lock = NSLock()
    /// Guarded by lock.
    private var session: Session?

    /// One live connection; mutable fields are guarded by the owning transport's lock.
    private final class Session: @unchecked Sendable {
        let socket: any RealtimeSocket
        let continuation: AsyncThrowingStream<RealtimeSessionEvent, Error>.Continuation
        var ready = false
        var finished = false
        var receiver: Task<Void, Never>?

        init(socket: any RealtimeSocket, continuation: AsyncThrowingStream<RealtimeSessionEvent, Error>.Continuation) {
            self.socket = socket
            self.continuation = continuation
        }
    }

    /// Only openai_realtime / xai_realtime.
    init?(
        kind: RealtimeTransportKind,
        endpoint: RealtimeEndpoint,
        makeSocket: @escaping SocketFactory = { URLSessionRealtimeSocket(request: $0) }
    ) {
        guard let codec = GARealtimeCodec(transport: kind) else { return nil }
        self.kind = kind
        self.endpoint = endpoint
        self.codec = codec
        self.makeSocket = makeSocket
    }

    func openRealtimeSession(
        transport: RealtimeTransportInput
    ) -> AsyncThrowingStream<RealtimeSessionEvent, Error> {
        AsyncThrowingStream { continuation in
            guard let url = URL(string: codec.connectURL(host: endpoint.host, path: endpoint.path, model: endpoint.model)) else {
                continuation.finish(throwing: GARealtimeTransportError.invalidURL)
                return
            }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(endpoint.apiKey)", forHTTPHeaderField: "Authorization")
            let session = Session(socket: makeSocket(request), continuation: continuation)
            let previous = lock.withLock { () -> Session? in
                let previous = self.session
                self.session = session
                return previous
            }
            if let previous { finish(previous, error: nil) }
            continuation.onTermination = { _ in self.finish(session, error: nil) }

            let opening = codec.openingMessages(
                input: transport,
                voice: endpoint.voice,
                inputTranscriptionModel: endpoint.inputTranscriptionModel
            )
            for message in opening.beforeReady {
                send(message, on: session)
            }
            let receiver = Task { await self.receiveLoop(session) }
            lock.withLock { session.receiver = receiver }
        }
    }

    // MARK: - RealtimeSessionControl

    func sendAudio(_ pcm16: Data) {
        guard let session = activeSession(requireReady: true) else { return }
        send(codec.append(base64: pcm16.base64EncodedString()), on: session)
    }

    func truncate(itemId: String?, contentIndex: Int, playedMs: Double) {
        guard let message = GARealtimeCodec.truncate(
            transport: kind, itemId: itemId, contentIndex: contentIndex, playedMs: playedMs
        ), let session = activeSession(requireReady: false) else { return }
        send(message, on: session)
    }

    func close() {
        guard let session = lock.withLock({ self.session }) else { return }
        finish(session, error: nil)
    }

    // MARK: - Internals

    private func activeSession(requireReady: Bool) -> Session? {
        lock.withLock {
            guard let session, !session.finished, !requireReady || session.ready else { return nil }
            return session
        }
    }

    private func send(_ message: [String: Any], on session: Session) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        session.socket.send(String(decoding: data, as: UTF8.self)) { error in
            if let error { self.finish(session, error: error) }
        }
    }

    private func receiveLoop(_ session: Session) async {
        var state = GARealtimeCodec.State()
        while true {
            let frame: String?
            do {
                frame = try await session.socket.receive()
            } catch {
                finish(session, error: error)
                return
            }
            guard let frame else {
                finish(session, error: GARealtimeTransportError.closedByPeer)
                return
            }
            // Frames that are not a JSON object are dropped silently.
            guard let message = (try? JSONSerialization.jsonObject(with: Data(frame.utf8))) as? [String: Any] else {
                continue
            }
            for event in codec.map(message, state: &state) {
                let live = lock.withLock { () -> Bool in
                    if event == .ready { session.ready = true }
                    return !session.finished
                }
                guard live else { return }
                session.continuation.yield(event)
                if case .sessionEnded = event {
                    finish(session, error: nil)
                    return
                }
            }
        }
    }

    /// Idempotent: closes the socket, stops receiving and ends the stream once.
    private func finish(_ session: Session, error: Error?) {
        let receiver = lock.withLock { () -> Task<Void, Never>?? in
            guard !session.finished else { return nil }
            session.finished = true
            if self.session === session { self.session = nil }
            return .some(session.receiver)
        }
        guard let receiver else { return }
        session.socket.close()
        receiver?.cancel()
        if let error {
            session.continuation.finish(throwing: error)
        } else {
            session.continuation.finish()
        }
    }
}
