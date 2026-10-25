import Foundation

/// Minimal text WebSocket used by realtime transports; tests inject a fake.
nonisolated protocol RealtimeSocket: Sendable {
    /// Queues one text frame; frames go out in call order. completion gets the send error, if any.
    func send(_ text: String, completion: @escaping @Sendable (Error?) -> Void)
    /// Next inbound text frame (binary frames are skipped); nil or a throw means the socket is gone.
    func receive() async throws -> String?
    /// Closes the socket; pending and later receives fail.
    func close()
}

/// Per-connection URLSession shared by the realtime sockets.
/// Each connection owns an ephemeral session so a dropped connection is never reused by the next one.
/// No WebSocket ping (E-199): the observed silent-period drop is the server idling out the session (1008),
/// which pings cannot prevent. Nothing is sent while muted (E-200, no zero frames); an expired session
/// goes dormant and is reopened on unmute.
nonisolated final class RealtimeSocketConnection: @unchecked Sendable {
    let task: URLSessionWebSocketTask
    private let session: URLSession
    private let lock = NSLock()
    private var closed = false

    init(request: URLRequest) {
        session = URLSession(configuration: .ephemeral)
        task = session.webSocketTask(with: request)
        task.resume()
    }

    /// Cancels the task and invalidates the session; idempotent.
    func close() {
        let first = lock.withLock { () -> Bool in
            guard !closed else { return false }
            closed = true
            return true
        }
        guard first else { return }
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    deinit {
        close()
    }
}

/// URLSessionWebSocketTask-backed socket; resumes the task on creation.
nonisolated final class URLSessionRealtimeSocket: RealtimeSocket, @unchecked Sendable {
    private let connection: RealtimeSocketConnection
    private var task: URLSessionWebSocketTask { connection.task }

    init(request: URLRequest) {
        connection = RealtimeSocketConnection(request: request)
    }

    func send(_ text: String, completion: @escaping @Sendable (Error?) -> Void) {
        task.send(.string(text)) { error in completion(error) }
    }

    func receive() async throws -> String? {
        while true {
            if let text = Self.text(of: try await task.receive()) { return text }
        }
    }

    /// GA realtime only sends text frames: binary (and unknown) frames are ignored, not mapped or raised.
    static func text(of message: URLSessionWebSocketTask.Message) -> String? {
        switch message {
        case let .string(text):
            return text
        case .data:
            return nil
        @unknown default:
            return nil
        }
    }

    func close() {
        connection.close()
    }
}
