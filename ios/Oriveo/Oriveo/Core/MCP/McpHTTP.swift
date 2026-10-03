import Foundation

// MARK: - HTTP foundation for remote MCP
//
// The protocol client (`McpClient`) and the OAuth transport (`URLSessionMcpAuthTransport`) share this layer, so three
// things are done exactly once, here: https only, redirect interception and the response body byte limit.

nonisolated enum McpHTTPLimits {
    /// Limit for a single response body (same as the web client's forwarding route). Reading stops once it is
    /// exceeded.
    static let maxResponseBytes = 8 * 1024 * 1024
    /// Limit for OAuth metadata / token / registration responses: these are small documents of a few KB.
    static let maxAuthResponseBytes = 1024 * 1024
    /// Maximum number of same-origin redirect hops to follow.
    static let maxRedirects = 5
    /// How many seconds URLSession's own idle timeout exceeds our call timeout by: timeouts are always decided by the
    /// caller's timer. Otherwise a configured `callTimeoutSeconds` above URLSession's default 60 seconds would be cut
    /// off by the system first and reported as unreachable.
    static let urlSessionTimeoutMargin: TimeInterval = 30
}

nonisolated enum McpHTTPError: Error, Equatable {
    /// The address is not https.
    case insecureURL
    /// Redirect rejected: cross-origin, downgraded to non-https, changed the request method, exceeded the hop limit,
    /// or the request does not allow redirects at all.
    case redirectRejected
    /// The response body exceeds the limit.
    case bodyTooLarge
    /// Exceeded the overall deadline given by the caller.
    case timedOut
    case notHTTP
}

nonisolated enum McpOrigin {
    static func isHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && !(url.host ?? "").isEmpty
    }

    /// Same origin = identical scheme + host + port (default ports are filled in per scheme before comparing).
    static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let left = key(lhs), let right = key(rhs) else { return false }
        return left == right
    }

    private static func key(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        let port = url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : -1)
        return "\(scheme)://\(host):\(port)"
    }
}

/// Redirect policy (a server's credentials are only sent to the origin of its recorded address).
nonisolated enum McpRedirectPolicy: Sendable, Equatable {
    /// Follow only same-origin https without changing the request method, at most `McpHTTPLimits.maxRedirects` hops.
    case sameOriginHTTPS
    /// Never follow (token and registration endpoints: the request body carries the authorization code / refresh
    /// token / verifier).
    case never
}

/// One task-level delegate per request. Attached to the task rather than the session, so it takes effect whichever
/// `URLSession` is injected (including `.shared`); interception does not rely on the caller remembering to configure
/// the session.
nonisolated final class McpRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let origin: URL
    private let method: String
    private let authorization: String?
    private let policy: McpRedirectPolicy
    private let lock = NSLock()
    private var hops = 0
    private var rejected = false

    init(request: URLRequest, policy: McpRedirectPolicy) {
        self.origin = request.url ?? URL(fileURLWithPath: "/")
        self.method = (request.httpMethod ?? "GET").uppercased()
        self.authorization = request.value(forHTTPHeaderField: "Authorization")
        self.policy = policy
    }

    var didRejectRedirect: Bool {
        lock.lock(); defer { lock.unlock() }
        return rejected
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        if allows(request) {
            // The system may strip `Authorization` on redirect. The target is confirmed same-origin, so restore the
            // original request's token; otherwise the server answers 401 after a same-origin 307 and it gets
            // misreported as "needs to sign in again".
            var next = request
            if let authorization, next.value(forHTTPHeaderField: "Authorization") == nil {
                next.setValue(authorization, forHTTPHeaderField: "Authorization")
            }
            completionHandler(next)
            return
        }
        lock.lock(); rejected = true; lock.unlock()
        // Do not follow, and cut the task off: the 3xx body is not needed either. The caller sees `didRejectRedirect`
        // and reports the redirect as rejected.
        completionHandler(nil)
        task.cancel()
    }

    private func allows(_ request: URLRequest) -> Bool {
        guard policy == .sameOriginHTTPS, let target = request.url else { return false }
        guard McpOrigin.isHTTPS(target), McpOrigin.isSameOrigin(origin, target) else { return false }
        // 301 / 302 / 303 rewrite POST into GET: a GET to an MCP endpoint either gets 405 or (on legacy servers)
        // opens a hanging long-lived SSE stream. Only follow redirects that preserve the method (307 / 308).
        guard (request.httpMethod ?? "GET").uppercased() == method else { return false }
        lock.lock(); defer { lock.unlock() }
        guard hops < McpHTTPLimits.maxRedirects else { return false }
        hops += 1
        return true
    }
}

nonisolated struct McpHTTPHead: Sendable, Equatable {
    var status: Int
    /// Header names are lowercased (HTTP header names compare case-insensitively); values are untouched.
    var headers: [String: String]

    var contentType: String? { headers["content-type"] }

    var isEventStream: Bool {
        (contentType ?? "").lowercased().contains("text/event-stream")
    }

    init(_ response: HTTPURLResponse) {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }
        self.status = response.statusCode
        self.headers = headers
    }
}

nonisolated enum McpHTTP {
    /// Default production session: no cookies, no cache on disk, no system credential storage. MCP requests
    /// authenticate only through the `Authorization` header we set ourselves; `URLSession.shared`'s shared cookie jar
    /// and disk cache are of no use here, and third-party servers should not get to write to them.
    static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// Sends the request and hands the response head and byte stream to `body`. The connection is closed as soon as
    /// `body` returns (or throws), so callers can return once they have read what they need without draining the
    /// stream.
    ///
    /// - Address is not https → `McpHTTPError.insecureURL`, **not a single byte is sent**.
    /// - Redirect rejected by the policy → `McpHTTPError.redirectRejected`; the redirect target receives no request.
    static func withResponse<T: Sendable>(
        _ request: URLRequest,
        session: URLSession,
        redirect: McpRedirectPolicy,
        _ body: (McpHTTPHead, URLSession.AsyncBytes) async throws -> T
    ) async throws -> T {
        guard let url = request.url, McpOrigin.isHTTPS(url) else { throw McpHTTPError.insecureURL }
        let redirectGuard = McpRedirectGuard(request: request, policy: redirect)
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: redirectGuard)
            defer { bytes.task.cancel() }
            if redirectGuard.didRejectRedirect { throw McpHTTPError.redirectRejected }
            guard let http = response as? HTTPURLResponse else { throw McpHTTPError.notHTTP }
            return try await body(McpHTTPHead(http), bytes)
        } catch {
            // When a redirect is rejected the task was cancelled by us and the system reports "cancelled"; report the
            // real cause.
            if redirectGuard.didRejectRedirect { throw McpHTTPError.redirectRejected }
            throw error
        }
    }

    /// Puts an overall deadline on an operation: when it elapses, throws `McpHTTPError.timedOut` and cancels the
    /// operation (which closes the connection). URLSession only has an idle timeout ("no bytes for this long"), which
    /// cannot stop a peer that keeps trickling bytes.
    static func withDeadline<T: Sendable>(
        _ seconds: Double,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                throw McpHTTPError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw McpHTTPError.timedOut }
            return result
        }
    }

    /// Reads the response body into memory; throws `bodyTooLarge` and stops reading once `limit` is exceeded.
    static func readBody(_ bytes: URLSession.AsyncBytes, limit: Int = McpHTTPLimits.maxResponseBytes) async throws -> Data {
        var buffer: [UInt8] = []
        for try await byte in bytes {
            guard buffer.count < limit else { throw McpHTTPError.bodyTooLarge }
            buffer.append(byte)
        }
        return Data(buffer)
    }

    /// Fetches a whole response in one go (for OAuth metadata / token / registration).
    static func send(
        _ request: URLRequest,
        session: URLSession,
        redirect: McpRedirectPolicy,
        limit: Int = McpHTTPLimits.maxResponseBytes
    ) async throws -> McpHTTPResponse {
        try await withResponse(request, session: session, redirect: redirect) { head, bytes in
            McpHTTPResponse(
                status: head.status,
                headers: head.headers,
                body: try await readBody(bytes, limit: limit),
                contentType: head.contentType
            )
        }
    }
}

/// An HTTP response fetched in one go (header names are lowercased).
nonisolated struct McpHTTPResponse: Sendable, Equatable {
    var status: Int
    var headers: [String: String]
    var body: Data
    var contentType: String?
}
