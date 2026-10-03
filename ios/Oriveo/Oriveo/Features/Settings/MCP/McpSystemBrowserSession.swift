import AuthenticationServices
import UIKit

/// System browser session for MCP sign-in: `ASWebAuthenticationSession` with `callbackURLScheme: "oriveo"`,
/// non-ephemeral so the user's existing browser sign-in is reused.
///
/// The page content comes from the service and is not drawn by the app. Whether the redirect arrives through the
/// session's completion handler or the system hands the URL straight to the app, `McpOAuthCallbackRouter` routes
/// it back here by `state` (redirects from an unexpected origin are rejected at the router).
nonisolated final class McpSystemBrowserSession: NSObject, McpBrowserSession, ASWebAuthenticationPresentationContextProviding, @unchecked Sendable {
    private let router: McpOAuthCallbackRouter

    init(router: McpOAuthCallbackRouter = .shared) {
        self.router = router
    }

    func authorize(url: URL, callbackURLScheme: String) async throws -> URL {
        // Without a state in the authorization request there is no way to claim the redirect: do not open the browser.
        guard let state = McpOAuthCallbackRouter.state(in: url), !state.isEmpty else {
            throw McpAuthorizerError.cancelled
        }
        let router = router
        router.expect(state: state)
        let session = await MainActor.run { () -> ASWebAuthenticationSession in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackURLScheme) { callback, error in
                if let callback, error == nil {
                    // The redirect's state does not match this authorization (or its origin is wrong): treat the sign-in as
                    // not completed.
                    if router.deliver(callback) != .delivered
                        || McpCallbackValidator.parameters(from: callback)["state"] != state {
                        router.fail(state: state, error: McpAuthorizerError.cancelled)
                    }
                } else {
                    router.fail(state: state, error: McpAuthorizerError.cancelled)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            if !session.start() {
                router.fail(state: state, error: McpAuthorizerError.cancelled)
            }
            return session
        }
        defer {
            router.forget(state: state)
            Task { @MainActor in session.cancel() }
        }
        return try await router.waitForCallback(state: state)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .first ?? ASPresentationAnchor()
        }
    }
}
