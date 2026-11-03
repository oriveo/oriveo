import Foundation

nonisolated enum GARealtimeTransportError: Error, Equatable {
    case invalidURL
    case closedByPeer
    /// Uplink audio not yet sent exceeded `GARealtimeTransport.stalledBacklogBytes` (E-491: network).
    case uplinkStalled
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
    private let route: RealtimeRouteProvider
    private let lock = NSLock()
    /// Serializes typed-turn sends with the deferred response.create so the item always precedes its create.
    private let textLock = NSLock()
    /// Guarded by lock.
    private var session: Session?
    /// Latest opened session, kept after it ends so a failure still reads its uplink backlog. Guarded by lock.
    private var latest: Session?

    /// Uplink backlog beyond this many bytes (8 s of 24 kHz PCM16) closes the connection as stalled (E-491);
    /// exactly 8 s does not.
    static let stalledBacklogBytes = GARealtimeCodec.inputSampleRateHz * 2 * 8

    /// One live connection; mutable fields are guarded by the owning transport's lock.
    private final class Session: @unchecked Sendable {
        let socket: any RealtimeSocket
        let continuation: AsyncThrowingStream<RealtimeSessionEvent, Error>.Continuation
        var ready = false
        var finished = false
        /// PCM bytes handed to the socket whose send has not completed; frozen once the session finishes.
        var pendingAudioBytes = 0
        /// Between response.created and response.done.
        var responseActive = false
        /// A typed turn's response.create held until the active response's response.done.
        var pendingCreate = false
        /// Last noise_reduction type sent (opening or route update); nil for xAI, which has no such field.
        var noiseReduction: String?
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
        route: @escaping RealtimeRouteProvider = { .speaker },
        makeSocket: @escaping SocketFactory = { URLSessionRealtimeSocket(request: $0) }
    ) {
        guard let codec = GARealtimeCodec(transport: kind) else { return nil }
        self.kind = kind
        self.endpoint = endpoint
        self.route = route
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
                self.latest = session
                return previous
            }
            if let previous { finish(previous, error: nil) }
            continuation.onTermination = { _ in self.finish(session, error: nil) }

            let openingRoute = route()
            let opening = codec.openingMessages(
                input: transport,
                voice: endpoint.voice,
                inputTranscriptionModel: endpoint.inputTranscriptionModel,
                route: openingRoute,
                language: endpoint.language
            )
            if kind == .openaiRealtime {
                let value = Self.noiseReduction(for: openingRoute)
                lock.withLock { session.noiseReduction = value }
            }
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
        send(codec.append(base64: pcm16.base64EncodedString()), on: session, audioBytes: pcm16.count)
    }

    /// One typed user turn asking for a reply (E-514); dropped until ready. Idle: input_text item, then
    /// response.create. While a response is in progress (only one may write the conversation): response.cancel,
    /// the item, and response.create held until that response's response.done; a second typed turn before then
    /// adds only its item. The controller's barge-in truncate follows separately.
    func sendText(_ text: String) {
        guard let session = activeSession(requireReady: true) else { return }
        textLock.withLock {
            let (busy, cancel) = lock.withLock { () -> (Bool, Bool) in
                guard session.responseActive else { return (false, false) }
                defer { session.pendingCreate = true }
                return (true, !session.pendingCreate)
            }
            if cancel { send(codec.responseCancel(), on: session) }
            send(codec.userTextItem(text), on: session)
            if !busy { send(codec.responseCreate(), on: session) }
        }
    }

    func truncate(itemId: String?, contentIndex: Int, playedMs: Double) {
        guard let message = GARealtimeCodec.truncate(
            transport: kind, itemId: itemId, contentIndex: contentIndex, playedMs: playedMs
        ), let session = activeSession(requireReady: false) else { return }
        send(message, on: session)
    }

    /// E-602: a route change sends one session.update carrying only audio.input.noise_reduction, deduplicated by
    /// value against the last one sent (E-501: headphones ↔ bluetooth are both near_field). openai_realtime only.
    func updateOutputRoute(_ route: VoiceConversationLogic.Route) {
        guard kind == .openaiRealtime, let session = activeSession(requireReady: false) else { return }
        let value = Self.noiseReduction(for: route)
        let changed = lock.withLock { () -> Bool in
            guard session.noiseReduction != value else { return false }
            session.noiseReduction = value
            return true
        }
        guard changed else { return }
        let input: [String: Any] = ["noise_reduction": ["type": value]]
        let update: [String: Any] = ["type": "realtime", "audio": ["input": input]]
        send(["type": "session.update", "session": update], on: session)
    }

    /// Same mapping as the opening session.update: speaker far_field, otherwise near_field.
    private static func noiseReduction(for route: VoiceConversationLogic.Route) -> String {
        route.isSpeaker ? "far_field" : "near_field"
    }

    func close() {
        guard let session = lock.withLock({ self.session }) else { return }
        finish(session, error: nil)
    }

    /// Uplink audio handed to the socket and not yet sent (PCM16 mono at `uplinkSampleRate`), counted from the
    /// send completion callbacks; 0 before any session.
    var uplinkBacklogMs: Double? {
        let bytes = lock.withLock { latest?.pendingAudioBytes ?? 0 }
        return Double(max(0, bytes)) * 1000 / (uplinkSampleRate * 2)
    }

    // MARK: - Internals

    private func activeSession(requireReady: Bool) -> Session? {
        lock.withLock {
            guard let session, !session.finished, !requireReady || session.ready else { return nil }
            return session
        }
    }

    /// `audioBytes` > 0 counts the chunk as uplink backlog until its send completes; judged only when a chunk
    /// arrives (no timer). The first chunk taking the backlog over the threshold is not sent and ends the session.
    private func send(_ message: [String: Any], on session: Session, audioBytes: Int = 0) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        if audioBytes > 0 {
            let stalled = lock.withLock { () -> Bool in
                guard !session.finished else { return false }
                session.pendingAudioBytes += audioBytes
                return session.pendingAudioBytes > Self.stalledBacklogBytes
            }
            if stalled {
                finish(session, error: GARealtimeTransportError.uplinkStalled)
                return
            }
        }
        session.socket.send(String(decoding: data, as: UTF8.self)) { error in
            // Completion arrives on the socket's queue; the count stays as it was once the session finished.
            if audioBytes > 0 {
                self.lock.withLock {
                    if !session.finished { session.pendingAudioBytes -= audioBytes }
                }
            }
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
            trackResponse(message["type"] as? String, on: session)
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

    /// Follows response.created / response.done; on done, sends the held response.create unless the session ended.
    private func trackResponse(_ type: String?, on session: Session) {
        switch type {
        case "response.created":
            textLock.withLock { lock.withLock { session.responseActive = true } }
        case "response.done":
            textLock.withLock {
                let create = lock.withLock { () -> Bool in
                    session.responseActive = false
                    defer { session.pendingCreate = false }
                    return session.pendingCreate && !session.finished
                }
                if create { send(codec.responseCreate(), on: session) }
            }
        default:
            break
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
