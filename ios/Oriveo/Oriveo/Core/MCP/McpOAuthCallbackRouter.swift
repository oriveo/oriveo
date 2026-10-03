import Foundation

// MARK: - In-process handoff of the OAuth callback
//
// iOS has a single redirect URI: `oriveo://mcp/oauth/callback`. A callback can reach the app two ways: the completion
// handler of `ASWebAuthenticationSession` (usually this one), and the system handing the URL straight to the app
// (`onOpenURL`). Both enter only through `deliver(_:)` and are handed, by `state`, to the authorization that started
// it:
//
// - Not this redirect URI (another scheme / host / path) → rejected. An https callback, such as the web client's
//   own `/mcp/oauth/callback`, never enters here: the browser session only accepts the custom scheme;
// - No `state`, or nobody is waiting for that `state` (not started on this device, already claimed, already
//   cancelled) → rejected;
// - Each `state` is claimed only once.
//
// Validation of `state` / `iss` / the authorization code itself still happens in
// `McpAuthorizer.completeAuthorization` (`McpCallbackValidator`); this only guarantees that a callback from the wrong
// place never reaches any authorization.

nonisolated enum McpOAuthCallbackDelivery: Sendable, Equatable {
    /// Handed to the waiting authorization.
    case delivered
    /// Not the registered redirect URI.
    case rejectedSource
    /// The redirect URI is right, but `state` is missing or nobody is waiting for it.
    case rejectedState
}

nonisolated final class McpOAuthCallbackRouter: @unchecked Sendable {
    static let shared = McpOAuthCallbackRouter()

    private let lock = NSLock()
    private var pending: [String: CheckedContinuation<URL, Error>] = [:]
    /// `state` values started on this device that have not received their callback yet.
    private var expected: Set<String> = []
    /// Outcome of a callback that arrived before the waiter was in place (or after it was cancelled), parked by
    /// `state`.
    private var settled: [String: Result<URL, Error>] = [:]

    /// Whether this URL is aimed at the MCP callback (`oriveo://mcp/...`). If so this router consumes it whether or
    /// not it is claimed, and it is not passed on to any other URL handler.
    static func claims(_ url: URL) -> Bool {
        url.scheme?.lowercased() == McpClientMetadata.callbackURLScheme && url.host?.lowercased() == "mcp"
    }

    /// Whether it is the redirect URI we registered (scheme, host and path all match).
    static func isRegisteredCallback(_ url: URL) -> Bool {
        McpRedirectURI.matches(callbackURL: url, registered: McpClientMetadata.iosRedirectURI)
    }

    static func state(in authorizationURL: URL) -> String? {
        URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "state" }?.value
    }

    /// This device started an authorization with this `state`. Call it **before opening the browser**: only from then
    /// on is a callback for this `state` claimed, even if it arrives before `waitForCallback`.
    func expect(state: String) {
        lock.lock()
        expected.insert(state)
        lock.unlock()
    }

    /// Waits for the callback of this `state` (call `expect` first). Throws `CancellationError` when cancelled.
    func waitForCallback(state: String) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result = settled.removeValue(forKey: state) {
                    lock.unlock()
                    continuation.resume(with: result)
                    return
                }
                guard expected.contains(state) else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[state] = continuation
                lock.unlock()
            }
        } onCancel: {
            self.forget(state: state)
        }
    }

    /// Hands the callback URL to the waiting authorization.
    @discardableResult
    func deliver(_ url: URL) -> McpOAuthCallbackDelivery {
        guard Self.isRegisteredCallback(url) else { return .rejectedSource }
        guard let state = McpCallbackValidator.parameters(from: url)["state"], !state.isEmpty else {
            return .rejectedState
        }
        lock.lock()
        guard expected.remove(state) != nil else {
            lock.unlock()
            return .rejectedState
        }
        let continuation = pending.removeValue(forKey: state)
        if continuation == nil { settled[state] = .success(url) }
        lock.unlock()
        continuation?.resume(returning: url)
        return .delivered
    }

    /// The browser session ended without a callback (the user closed the sign-in page, or the session could not
    /// start): fail the waiter.
    func fail(state: String, error: Error) {
        lock.lock()
        guard expected.remove(state) != nil else {
            lock.unlock()
            return
        }
        let continuation = pending.removeValue(forKey: state)
        if continuation == nil { settled[state] = .failure(error) }
        lock.unlock()
        continuation?.resume(throwing: error)
    }

    /// This authorization is over: stop claiming this `state` and clear any parked outcome.
    func forget(state: String) {
        lock.lock()
        expected.remove(state)
        settled.removeValue(forKey: state)
        let continuation = pending.removeValue(forKey: state)
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }

    var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pending.count
    }
}
