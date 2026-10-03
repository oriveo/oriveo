import Foundation
import Testing
@testable import Oriveo

// MARK: - Handling the OAuth callback
//
// Whether the callback arrives through the `ASWebAuthenticationSession` completion handler or the system hands the
// URL straight to the app (`onOpenURL`), it only enters through `McpOAuthCallbackRouter.deliver`. These tests use the
// production router and the production authorizer to pin that a callback from the wrong origin or with a mismatched
// `state` never reaches any authorization, exchanges no token and stores no credential.

/// A browser session that waits for the callback through the production router (the production
/// `McpSystemBrowserSession` only adds opening the system browser).
private final class RouterBrowserSession: McpBrowserSession, @unchecked Sendable {
    let router: McpOAuthCallbackRouter
    private let lock = NSLock()
    private var opened: [URL] = []

    init(router: McpOAuthCallbackRouter) { self.router = router }

    var openedURLs: [URL] {
        lock.lock(); defer { lock.unlock() }
        return opened
    }

    func authorize(url: URL, callbackURLScheme: String) async throws -> URL {
        guard let state = McpOAuthCallbackRouter.state(in: url) else { throw McpAuthorizerError.cancelled }
        router.expect(state: state)
        lock.lock(); opened.append(url); lock.unlock()
        defer { router.forget(state: state) }
        return try await router.waitForCallback(state: state)
    }
}

@Suite("MCP OAuth callback routing", .serialized)
struct McpOAuthCallbackRouterTests {
    private let serverId = UUID(uuidString: "0A0A0A0A-1111-2222-3333-444444444444")!

    private func makeAuthorizer(
        router: McpOAuthCallbackRouter
    ) throws -> (McpAuthorizer, RouterBrowserSession, FakeMcpAuthTransport, McpCredentialStore, InMemoryMcpCredentialStorage) {
        let transport = FakeMcpAuthTransport()
        try McpUiFixture.stubAuthorization(transport)
        let storage = InMemoryMcpCredentialStorage()
        let credentials = McpCredentialStore(storage: storage)
        let browser = RouterBrowserSession(router: router)
        // The stubbed authorization server accepts a client metadata document, so the authorizer is given one.
        let authorizer = McpAuthorizer(
            transport: transport, browser: browser, credentialStore: credentials,
            clientMetadataDocumentURL: URL(string: "https://app.example.com/oauth/mcp-client.json")
        )
        return (authorizer, browser, transport, credentials, storage)
    }

    private func plan(_ authorizer: McpAuthorizer) async throws -> McpAuthorizationPlan {
        guard case .ready(let plan) = await authorizer.discover(
            challenge: nil, endpoint: try #require(URL(string: McpUiFixture.endpoint))
        ) else {
            throw McpAuthorizerError.notAutoRegisterable
        }
        return plan
    }

    @Test("Only the registered callback address is accepted: other schemes / hosts / paths, including an https address, count as a foreign origin")
    func sourceMatching() {
        #expect(McpOAuthCallbackRouter.isRegisteredCallback(URL(string: "oriveo://mcp/oauth/callback?code=a&state=b")!))
        for foreign in [
            "https://app.example.com/mcp/oauth/callback?code=a&state=b",
            "oriveo://other/path?claim=x",
            "oriveo://mcp/oauth/other?code=a&state=b",
            "oriveo://mcp.evil.example/oauth/callback?code=a&state=b",
            "evil://mcp/oauth/callback?code=a&state=b",
        ] {
            #expect(!McpOAuthCallbackRouter.isRegisteredCallback(URL(string: foreign)!), "\(foreign)")
        }
        // `oriveo://mcp/...` is always consumed by the MCP router and is not passed on to any other URL handler.
        #expect(McpOAuthCallbackRouter.claims(URL(string: "oriveo://mcp/oauth/other")!))
        #expect(!McpOAuthCallbackRouter.claims(URL(string: "oriveo://other/path")!))
        #expect(!McpOAuthCallbackRouter.claims(URL(string: "https://app.example.com/mcp/oauth/callback")!))
    }

    @Test("A callback nobody is waiting for is rejected: no state, a state this device did not issue, the same state arriving twice")
    func unsolicitedCallbacksAreRejected() async throws {
        let router = McpOAuthCallbackRouter()
        #expect(router.deliver(URL(string: "oriveo://mcp/oauth/callback?code=a")!) == .rejectedState)
        #expect(router.deliver(URL(string: "oriveo://mcp/oauth/callback?code=a&state=nobody")!) == .rejectedState)
        #expect(router.deliver(URL(string: "https://app.example.com/mcp/oauth/callback?code=a&state=s1")!) == .rejectedSource)

        router.expect(state: "s1")
        let callback = URL(string: "oriveo://mcp/oauth/callback?code=a&state=s1")!
        #expect(router.deliver(callback) == .delivered)
        #expect(router.deliver(callback) == .rejectedState, "a state is claimed only once")
        #expect(try await router.waitForCallback(state: "s1") == callback, "a callback that arrives first is not lost")
        router.forget(state: "s1")
        #expect(router.deliver(callback) == .rejectedState, "not claimed again once this authorization has ended")
    }

    @Test("A callback from a foreign origin or with a mismatched state never reaches the authorization: no token exchange, no stored credential; the correct callback then completes as usual")
    func mismatchedCallbacksNeverReachTheAuthorizer() async throws {
        let router = McpOAuthCallbackRouter()
        let (authorizer, browser, transport, credentials, storage) = try makeAuthorizer(router: router)
        let plan = try await plan(authorizer)
        let serverId = serverId
        let task = Task { try await authorizer.authorize(plan: plan, serverId: serverId, uid: McpUiFixture.uid) }
        #expect(await McpClientHarness.eventually { browser.openedURLs.count == 1 && router.pendingCount == 1 })
        let state = try #require(McpOAuthCallbackRouter.state(in: browser.openedURLs[0]))

        // These are all URLs the system hands in through `onOpenURL`.
        #expect(router.deliver(URL(string: "oriveo://mcp/oauth/callback?code=stolen&state=attacker&iss=https://auth.example.com")!) == .rejectedState)
        #expect(router.deliver(URL(string: "https://app.example.com/mcp/oauth/callback?code=stolen&state=\(state)")!) == .rejectedSource)
        #expect(router.deliver(URL(string: "oriveo://mcp/oauth/elsewhere?code=stolen&state=\(state)")!) == .rejectedSource)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(transport.formRequests.isEmpty, "a rejected callback does not exchange a token")
        #expect(storage.accounts().isEmpty, "no token is stored")
        #expect(router.pendingCount == 1, "the authorization is still waiting for the real callback")

        #expect(router.deliver(URL(string: "oriveo://mcp/oauth/callback?code=ac_123&state=\(state)&iss=https://auth.example.com")!) == .delivered)
        let issued = try await task.value
        #expect(issued.accessToken != nil)
        #expect(transport.formRequests.count == 1)
        #expect(credentials.load(serverId: serverId, uid: McpUiFixture.uid)?.accessToken == issued.accessToken)
        #expect(router.pendingCount == 0)
    }

    @Test("A callback with the right state but a mismatched iss is rejected by the authorizer: no token exchange, no stored credential")
    func issuerMismatchIsRejectedByTheAuthorizer() async throws {
        let router = McpOAuthCallbackRouter()
        let (authorizer, browser, transport, _, storage) = try makeAuthorizer(router: router)
        let plan = try await plan(authorizer)
        let serverId = serverId
        let task = Task { try await authorizer.authorize(plan: plan, serverId: serverId, uid: McpUiFixture.uid) }
        #expect(await McpClientHarness.eventually { browser.openedURLs.count == 1 && router.pendingCount == 1 })
        let state = try #require(McpOAuthCallbackRouter.state(in: browser.openedURLs[0]))

        #expect(router.deliver(URL(string: "oriveo://mcp/oauth/callback?code=ac_123&state=\(state)&iss=https://evil.example.com")!) == .delivered)
        await #expect(throws: McpAuthorizerError.self) { try await task.value }
        #expect(transport.formRequests.isEmpty)
        #expect(storage.accounts().isEmpty)
    }

    @Test("Sign-in page closed / initiator cancelled: the wait ends and a late callback is no longer claimed")
    func cancelledSessionsStopClaiming() async throws {
        let router = McpOAuthCallbackRouter()
        router.expect(state: "s2")
        let waiting = Task { try await router.waitForCallback(state: "s2") }
        #expect(await McpClientHarness.eventually { router.pendingCount == 1 })
        router.fail(state: "s2", error: McpAuthorizerError.cancelled)
        await #expect(throws: McpAuthorizerError.self) { try await waiting.value }
        #expect(router.deliver(URL(string: "oriveo://mcp/oauth/callback?code=a&state=s2")!) == .rejectedState)

        router.expect(state: "s3")
        let cancelled = Task { try await router.waitForCallback(state: "s3") }
        #expect(await McpClientHarness.eventually { router.pendingCount == 1 })
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(router.deliver(URL(string: "oriveo://mcp/oauth/callback?code=a&state=s3")!) == .rejectedState)
    }
}
