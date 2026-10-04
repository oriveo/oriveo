import Foundation
import Testing
@testable import Oriveo

// MARK: - Remote MCP authorization
//
// Mostly fixture replay: `shared/test-fixtures/mcp/auth/` is the single source of truth. A fake transport and a
// fake browser replay those fixtures; every asserted object comes from a production code path (`McpAuthorizer`
// or pure functions).

private let mcpEndpoint = URL(string: "https://mcp.example.com/mcp")!
private let iosRedirectURI = McpClientMetadata.iosRedirectURI
private let protectedResourceURL = "https://mcp.example.com/.well-known/oauth-protected-resource"
private let authorizationServerURL = "https://auth.example.com/.well-known/oauth-authorization-server"
private let registrationURL = "https://auth.example.com/register"
private let tokenURL = "https://auth.example.com/token"
/// The client metadata document the fixtures use as `client_id`. Tests that exercise that registration method
/// hand it to the authorizer explicitly.
private let fixtureClientMetadataDocumentURL = URL(string: "https://app.example.com/oauth/mcp-client.json")!

private func authFixture(_ name: String) throws -> JSONValue {
    try McpFixture.json("auth/" + name)
}

// MARK: Fake transport / fake browser

final class FakeMcpAuthTransport: McpAuthTransport, @unchecked Sendable {
    private struct Stub {
        var status: Int
        var body: Data
    }

    private let lock = NSLock()
    private var stubs: [String: Stub] = [:]
    /// One-shot responses queued per URL, consumed before the fixed stubs (replays "first attempt fails, second succeeds").
    private var queued: [String: [Stub]] = [:]
    /// Requests to these URLs throw a network error (simulates a connection that did not go through this time).
    private var unreachable: Set<String> = []
    private var getLog: [String] = []
    private var formLog: [(url: String, form: [McpFormField])] = []
    private var jsonLog: [(url: String, body: JSONValue)] = []

    /// Artificial delay on the token endpoint, used to open a concurrency window.
    var postFormDelay: TimeInterval = 0

    var getURLs: [String] {
        lock.lock(); defer { lock.unlock() }
        return getLog
    }

    var formRequests: [(url: String, form: [McpFormField])] {
        lock.lock(); defer { lock.unlock() }
        return formLog
    }

    var jsonRequests: [(url: String, body: JSONValue)] {
        lock.lock(); defer { lock.unlock() }
        return jsonLog
    }

    func stub(status: Int, json: JSONValue, at url: String) {
        lock.lock(); defer { lock.unlock() }
        stubs[url] = Stub(status: status, body: Data(json.orderedJSONString.utf8))
    }

    func stub(status: Int, raw: String, at url: String) {
        lock.lock(); defer { lock.unlock() }
        stubs[url] = Stub(status: status, body: Data(raw.utf8))
    }

    func enqueue(status: Int, json: JSONValue, at url: String) {
        lock.lock(); defer { lock.unlock() }
        queued[url, default: []].append(Stub(status: status, body: Data(json.orderedJSONString.utf8)))
    }

    func setUnreachable(_ isUnreachable: Bool, at url: String) {
        lock.lock(); defer { lock.unlock() }
        if isUnreachable { unreachable.insert(url) } else { unreachable.remove(url) }
    }

    /// Returns the replay for this request; the lock is already held by the caller.
    private func take(_ url: String) throws -> Stub? {
        if unreachable.contains(url) { throw URLError(.notConnectedToInternet) }
        if var queue = queued[url], !queue.isEmpty {
            let next = queue.removeFirst()
            queued[url] = queue
            return next
        }
        return stubs[url]
    }

    func get(_ url: URL) async throws -> McpHTTPResponse {
        lock.lock()
        getLog.append(url.absoluteString)
        let stub = Result { try take(url.absoluteString) }
        lock.unlock()
        return response(for: try stub.get())
    }

    func postForm(_ url: URL, form: [McpFormField]) async throws -> McpHTTPResponse {
        lock.lock()
        formLog.append((url.absoluteString, form))
        let stub = Result { try take(url.absoluteString) }
        let delay = postFormDelay
        lock.unlock()
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        return response(for: try stub.get())
    }

    func postJSON(_ url: URL, body: JSONValue) async throws -> McpHTTPResponse {
        lock.lock()
        jsonLog.append((url.absoluteString, body))
        let stub = Result { try take(url.absoluteString) }
        lock.unlock()
        return response(for: try stub.get())
    }

    private func response(for stub: Stub?) -> McpHTTPResponse {
        guard let stub else {
            return McpHTTPResponse(status: 404, headers: [:], body: Data(), contentType: nil)
        }
        return McpHTTPResponse(
            status: stub.status,
            headers: ["content-type": "application/json"],
            body: stub.body,
            contentType: "application/json"
        )
    }
}

/// A one-shot gate: `wait()` suspends until `open()` has been called, whichever of the two comes first.
nonisolated final class McpTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            let alreadyOpen = isOpen
            if !alreadyOpen { waiters.append(continuation) }
            lock.unlock()
            if alreadyOpen { continuation.resume() }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let waiting = waiters
        waiters = []
        lock.unlock()
        waiting.forEach { $0.resume() }
    }
}

final class FakeMcpBrowserSession: McpBrowserSession, @unchecked Sendable {
    private let lock = NSLock()
    private var opened: [URL] = []
    private var released = 0
    private let pageOpened = McpTestGate()
    /// The test decides the callback URL; throws when there is none (simulates the user cancelling).
    var callbackBuilder: (@Sendable (URL) -> URL)?
    /// The sign-in page stays open until the task that opened it is cancelled: a sign-in the user never finishes.
    var holdsUntilCancelled = false

    var openedURLs: [URL] {
        lock.lock(); defer { lock.unlock() }
        return opened
    }

    /// Held sign-ins that have returned to their caller after being cancelled. Counted on the main actor, so a
    /// test that has not suspended since cancelling cannot have seen the count move yet.
    var releasedSignIns: Int {
        lock.lock(); defer { lock.unlock() }
        return released
    }

    /// Suspends until the sign-in page has been opened.
    func waitUntilOpened() async { await pageOpened.wait() }

    func authorize(url: URL, callbackURLScheme: String) async throws -> URL {
        lock.lock()
        opened.append(url)
        let builder = callbackBuilder
        let holds = holdsUntilCancelled
        lock.unlock()
        pageOpened.open()
        if holds {
            let cancelled = McpTestGate()
            await withTaskCancellationHandler {
                await cancelled.wait()
            } onCancel: {
                cancelled.open()
            }
            await MainActor.run { self.noteReleased() }
            throw McpAuthorizerError.cancelled
        }
        guard let builder else { throw McpAuthorizerError.cancelled }
        return builder(url)
    }

    private func noteReleased() {
        lock.lock(); released += 1; lock.unlock()
    }
}

// MARK: Stubs and factories

private func stubProtectedResource(_ transport: FakeMcpAuthTransport) throws {
    let fixture = try authFixture("protected-resource-metadata.json")
    transport.stub(
        status: fixture["status"]?.intValue ?? 200,
        json: fixture["body"] ?? .object(JSONObject()),
        at: protectedResourceURL
    )
}

private func stubAuthorizationServer(_ transport: FakeMcpAuthTransport, _ name: String) throws {
    let fixture = try authFixture(name)
    transport.stub(
        status: fixture["status"]?.intValue ?? 200,
        json: fixture["body"] ?? .object(JSONObject()),
        at: authorizationServerURL
    )
}

private func stubToken(_ transport: FakeMcpAuthTransport, _ name: String) throws {
    let fixture = try authFixture(name)
    transport.stub(
        status: fixture["status"]?.intValue ?? 200,
        json: fixture["body"] ?? .object(JSONObject()),
        at: tokenURL
    )
}

private func protectedResourceChallenge() -> McpAuthChallenge {
    McpAuthChallenge(resourceMetadata: URL(string: protectedResourceURL), scope: nil)
}

private func makeAuthorizer(
    transport: FakeMcpAuthTransport,
    browser: FakeMcpBrowserSession = FakeMcpBrowserSession(),
    storage: InMemoryMcpCredentialStorage = InMemoryMcpCredentialStorage(),
    clientMetadataDocumentURL: URL? = fixtureClientMetadataDocumentURL,
    now: @escaping @Sendable () -> Date = { Date() }
) -> (McpAuthorizer, McpCredentialStore) {
    let store = McpCredentialStore(storage: storage)
    let authorizer = McpAuthorizer(
        transport: transport, browser: browser, credentialStore: store,
        clientMetadataDocumentURL: clientMetadataDocumentURL, now: now
    )
    return (authorizer, store)
}

private func stubDCR(_ transport: FakeMcpAuthTransport) throws {
    try stubAuthorizationServer(transport, "authorization-server-metadata.dcr.json")
    let dcr = try authFixture("dcr.json")
    transport.stub(status: dcr["status"]?.intValue ?? 201, json: dcr["body"] ?? .object(JSONObject()), at: registrationURL)
}

/// Runs discovery and returns the plan; fails the test unless the result is ready.
private func readyPlan(
    _ authorizer: McpAuthorizer,
    challenge: McpAuthChallenge? = nil
) async throws -> McpAuthorizationPlan {
    let challenge = challenge ?? protectedResourceChallenge()
    guard case .ready(let plan) = await authorizer.discover(challenge: challenge, endpoint: mcpEndpoint) else {
        throw CocoaError(.featureUnsupported)
    }
    return plan
}

/// Replaces one key of an object with another value (other keys and their order are kept); a nil value removes the key.
private func replacing(_ json: JSONValue, key: String, with value: JSONValue?) -> JSONValue {
    guard let object = json.objectValue else { return json }
    var pairs = object.keys.filter { $0 != key }.map { ($0, object[$0]!) }
    if let value { pairs.append((key, value)) }
    return .object(JSONObject(pairs))
}

/// Redirects back to the registered address and echoes `state` unchanged.
private let echoingCallback: @Sendable (URL) -> URL = { authorizeURL in
    let state = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)?
        .queryItems?.first { $0.name == "state" }?.value ?? ""
    return URL(string: "oriveo://mcp/oauth/callback?code=ac_123&state=\(state)&iss=https://auth.example.com")!
}

private func savedCredentials(serverId: UUID, in store: McpCredentialStore) throws {
    try store.save(
        McpCredentials(
            accessToken: "old",
            refreshToken: "mcp_rt_example",
            issuer: "https://auth.example.com",
            clientID: fixtureClientMetadataDocumentURL.absoluteString,
            resource: "https://mcp.example.com/mcp"
        ),
        serverId: serverId,
        uid: "u1"
    )
}

@Suite("MCP authorization", .serialized)
struct McpAuthorizerTests {

    // MARK: Discovery

    @Test("Fixture replay: a 401 WWW-Authenticate yields resource_metadata and scope")
    func challengeParsing() throws {
        let fixture = try authFixture("401.www-authenticate.json")
        let header = fixture["headers"]?["WWW-Authenticate"]?.stringValue
        let challenge = try #require(McpWWWAuthenticate.parse(header))
        #expect(challenge.resourceMetadata?.absoluteString == fixture["expect"]?["resourceMetadataURL"]?.stringValue)
        #expect(challenge.scope == fixture["expect"]?["scope"]?.stringValue)
    }

    @Test("Fixture replay: a 401 without resource_metadata builds both well-known URIs")
    func wellKnownConstruction() throws {
        let fixture = try authFixture("401.no-metadata.json")
        let challenge = try #require(McpWWWAuthenticate.parse(fixture["headers"]?["WWW-Authenticate"]?.stringValue))
        #expect(challenge.resourceMetadata == nil)
        let candidates = McpProtectedResourceDiscovery.candidates(challenge: challenge, endpoint: mcpEndpoint)
        let expected = fixture["expect"]?["constructedURIs"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(candidates.map(\.absoluteString) == expected)
    }

    @Test("Fixture replay: 403 insufficient_scope → needs_auth (no step-up authorization yet)")
    func insufficientScope() throws {
        let fixture = try authFixture("403.insufficient-scope.json")
        let code = McpAuthResponseMapping.needsAuthErrorCode(
            status: fixture["status"]?.intValue ?? 403,
            wwwAuthenticate: fixture["headers"]?["WWW-Authenticate"]?.stringValue
        )
        #expect(code?.rawValue == fixture["expect"]?["errorCode"]?.stringValue)
        #expect(McpAuthResponseMapping.stepUpImplemented == fixture["expect"]?["stepUpImplemented"]?.boolValue)
    }

    @Test("Fixture replay: protected resource metadata MUST contain authorization_servers")
    func protectedResourceParsing() throws {
        let fixture = try authFixture("protected-resource-metadata.json")
        let body = try #require(fixture["body"])
        let metadata = try #require(McpProtectedResourceMetadata(json: body))
        #expect(metadata.authorizationServers.first == fixture["expect"]?["issuer"]?.stringValue)
        #expect(!metadata.authorizationServers.isEmpty)
    }

    @Test("Fixture replay: authorization server metadata parsing and well-known order")
    func authorizationServerMetadataParsing() throws {
        let fixture = try authFixture("authorization-server-metadata.cimd.json")
        let body = try #require(fixture["body"])
        let metadata = try #require(McpAuthorizationServerMetadata(json: body))
        #expect(metadata.issuer == "https://auth.example.com")
        #expect(metadata.clientIDMetadataDocumentSupported)
        #expect(metadata.authorizationResponseIssParameterSupported)
        #expect(McpClientRegistrationDecision.decide(metadata, clientMetadataDocumentURL: fixtureClientMetadataDocumentURL) == .cimd)
        #expect(
            McpClientRegistrationDecision.decide(metadata, clientMetadataDocumentURL: nil) == .dcr,
            "Without a document to present, the registration endpoint is used instead"
        )

        let candidates = McpAuthorizationServerDiscovery
            .candidates(issuer: try #require(URL(string: metadata.issuer)))
            .map(\.absoluteString)
        let tried = fixture["expect"]?["wellKnownTried"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(Array(candidates.prefix(tried.count)) == tried)

        // Issuer with a path: RFC 8414 path insertion / OIDC path insertion / OIDC path appending, in that order.
        let withPath = McpAuthorizationServerDiscovery
            .candidates(issuer: try #require(URL(string: "https://auth.example.com/tenant1")))
            .map(\.absoluteString)
        #expect(withPath == [
            "https://auth.example.com/.well-known/oauth-authorization-server/tenant1",
            "https://auth.example.com/.well-known/openid-configuration/tenant1",
            "https://auth.example.com/tenant1/.well-known/openid-configuration",
        ])
    }

    // MARK: The three client registration paths

    @Test("Registration path one: CIMD (when the metadata declares support and a document is configured, the document URL is the client_id and nothing is registered with the authorization server)")
    func registrationCIMD() async throws {
        let transport = FakeMcpAuthTransport()
        try stubProtectedResource(transport)
        try stubAuthorizationServer(transport, "authorization-server-metadata.cimd.json")
        let (authorizer, _) = makeAuthorizer(transport: transport)

        let plan = try await readyPlan(authorizer)
        #expect(plan.registrationKind == .cimd)
        #expect(plan.registrationEndpoint == nil)
        #expect(plan.issuer == "https://auth.example.com")
        // Stop at the first well-known that answers; later ones are not tried.
        #expect(transport.getURLs == [protectedResourceURL, authorizationServerURL])

        let registration = try await authorizer.register(plan: plan, uid: "u1")
        #expect(registration.kind == .cimd)
        #expect(registration.clientID == fixtureClientMetadataDocumentURL.absoluteString)
        #expect(transport.jsonRequests.isEmpty, "CIMD needs no registration request")
    }

    @Test("Registration path two: DCR. Discovery does not register; registration happens once when authorization begins (application_type = native)")
    func registrationDCR() async throws {
        let transport = FakeMcpAuthTransport()
        try stubProtectedResource(transport)
        try stubDCR(transport)
        let dcr = try authFixture("dcr.json")
        let storage = InMemoryMcpCredentialStorage()
        let (authorizer, _) = makeAuthorizer(transport: transport, storage: storage)

        // Discovery only reads metadata. The user has not agreed to open the browser yet, so nothing may be written
        // to the authorization server.
        let plan = try await readyPlan(authorizer)
        #expect(plan.registrationKind == .dcr)
        #expect(plan.registrationEndpoint?.absoluteString == registrationURL)
        #expect(transport.jsonRequests.isEmpty, "discovery must not register")
        #expect(storage.accounts().isEmpty, "discovery writes nothing to storage")

        let attempt = try await authorizer.beginAuthorization(plan: plan, uid: "u1")
        #expect(attempt.clientID == "oriveo_mcp_2f9c41")
        #expect(attempt.registrationKind == .dcr)
        #expect(attempt.request.queryItems.first { $0.name == "client_id" }?.value == "oriveo_mcp_2f9c41")

        let request = try #require(transport.jsonRequests.first)
        #expect(transport.jsonRequests.count == 1)
        #expect(request.url == registrationURL)
        #expect(request.body["application_type"]?.stringValue == "native")
        #expect(request.body["token_endpoint_auth_method"]?.stringValue == "none")
        #expect(request.body["client_name"]?.stringValue == "Oriveo")
        #expect(request.body["redirect_uris"] == dcr["request"]?["body"]?["redirect_uris"])
    }

    @Test("A DCR registration is stored locally by uid + issuer and reused: the same flow, a later sign-in and a new authorizer instance never register again")
    func dcrRegistrationIsReused() async throws {
        let transport = FakeMcpAuthTransport()
        try stubProtectedResource(transport)
        try stubDCR(transport)
        let storage = InMemoryMcpCredentialStorage()
        let (authorizer, store) = makeAuthorizer(transport: transport, storage: storage)

        let plan = try await readyPlan(authorizer)
        _ = try await authorizer.beginAuthorization(plan: plan, uid: "u1")
        _ = try await authorizer.beginAuthorization(plan: plan, uid: "u1")
        #expect(transport.jsonRequests.count == 1, "the second authorization reuses the existing registration")

        // The registration lives in the credential store (local secure storage), keyed by uid + issuer.
        #expect(storage.accounts() == ["u1:dcr:https://auth.example.com"])
        let stored = try #require(store.loadClientRegistration(issuer: "https://auth.example.com", uid: "u1"))
        #expect(stored.clientID == "oriveo_mcp_2f9c41")
        #expect(stored.redirectURIs == McpClientMetadata.redirectURIs)

        // It is still reused after an app restart (a new authorizer instance over the same storage).
        let (restarted, _) = makeAuthorizer(transport: transport, storage: storage)
        let replanned = try await readyPlan(restarted)
        let attempt = try await restarted.beginAuthorization(plan: replanned, uid: "u1")
        #expect(attempt.clientID == "oriveo_mcp_2f9c41")
        #expect(transport.jsonRequests.count == 1)

        // A different storage partition does not share the registration.
        _ = try await restarted.beginAuthorization(plan: replanned, uid: "u2")
        #expect(transport.jsonRequests.count == 2)
        #expect(Set(storage.accounts()) == ["u1:dcr:https://auth.example.com", "u2:dcr:https://auth.example.com"])
    }

    @Test("DCR: two concurrent authorization starts register only once")
    func concurrentRegistrationSerializes() async throws {
        let transport = FakeMcpAuthTransport()
        try stubProtectedResource(transport)
        try stubDCR(transport)
        let (authorizer, _) = makeAuthorizer(transport: transport)
        let plan = try await readyPlan(authorizer)

        async let first = authorizer.beginAuthorization(plan: plan, uid: "u1")
        async let second = authorizer.beginAuthorization(plan: plan, uid: "u1")
        let attempts = try await [first, second]
        #expect(attempts.allSatisfy { $0.clientID == "oriveo_mcp_2f9c41" })
        #expect(transport.jsonRequests.count == 1)
    }

    @Test("A full add flow (discovery → authorization) registers once and discovers once")
    func discoverOnceRegisterOnce() async throws {
        let transport = FakeMcpAuthTransport()
        try stubProtectedResource(transport)
        try stubDCR(transport)
        try stubToken(transport, "token.success.json")
        let browser = FakeMcpBrowserSession()
        browser.callbackBuilder = echoingCallback
        let (authorizer, store) = makeAuthorizer(transport: transport, browser: browser)
        let serverId = UUID()

        let plan = try await readyPlan(authorizer)
        let credentials = try await authorizer.authorize(plan: plan, serverId: serverId, uid: "u1")

        #expect(credentials.clientID == "oriveo_mcp_2f9c41")
        #expect(store.load(serverId: serverId, uid: "u1")?.clientID == "oriveo_mcp_2f9c41")
        #expect(transport.jsonRequests.count == 1, "one add flow registers exactly once")
        #expect(transport.getURLs == [protectedResourceURL, authorizationServerURL], "authorization does not repeat discovery")
        #expect(browser.openedURLs.count == 1)
    }

    @Test("DCR registration rejected (token exchange returns invalid_client) → drop the cache, register once more and retry")
    func invalidClientReregistersOnce() async throws {
        let transport = FakeMcpAuthTransport()
        try stubProtectedResource(transport)
        try stubAuthorizationServer(transport, "authorization-server-metadata.dcr.json")
        let dcr = try authFixture("dcr.json")
        let registered = try #require(dcr["body"])
        transport.enqueue(status: 201, json: registered, at: registrationURL)
        transport.enqueue(status: 201, json: replacing(registered, key: "client_id", with: .string("oriveo_mcp_second")), at: registrationURL)
        let invalidClient = try #require(try authFixture("token.error.json")["cases"]?.arrayValue?.first {
            $0["caseId"]?.stringValue == "invalid_client"
        })
        transport.enqueue(status: 400, json: try #require(invalidClient["body"]), at: tokenURL)
        try stubToken(transport, "token.success.json")
        let browser = FakeMcpBrowserSession()
        browser.callbackBuilder = echoingCallback
        let (authorizer, store) = makeAuthorizer(transport: transport, browser: browser)
        let serverId = UUID()

        let plan = try await readyPlan(authorizer)
        let credentials = try await authorizer.authorize(plan: plan, serverId: serverId, uid: "u1")

        #expect(credentials.clientID == "oriveo_mcp_second")
        #expect(transport.jsonRequests.count == 2, "re-registered exactly once")
        #expect(browser.openedURLs.count == 2)
        #expect(store.loadClientRegistration(issuer: "https://auth.example.com", uid: "u1")?.clientID == "oriveo_mcp_second")
        let clientIDs = transport.formRequests.map { request in request.form.first { $0.name == "client_id" }?.value }
        #expect(clientIDs == ["oriveo_mcp_2f9c41", "oriveo_mcp_second"])
    }

    @Test("DCR registration rejected twice in a row → no endless re-registration; reports clientRejected and stores no token")
    func invalidClientTwiceGivesUp() async throws {
        let transport = FakeMcpAuthTransport()
        try stubProtectedResource(transport)
        try stubDCR(transport)
        transport.stub(status: 400, raw: #"{"error":"invalid_client"}"#, at: tokenURL)
        let browser = FakeMcpBrowserSession()
        browser.callbackBuilder = echoingCallback
        let (authorizer, store) = makeAuthorizer(transport: transport, browser: browser)
        let serverId = UUID()

        let plan = try await readyPlan(authorizer)
        await #expect(throws: McpAuthorizerError.clientRejected) {
            _ = try await authorizer.authorize(plan: plan, serverId: serverId, uid: "u1")
        }
        #expect(transport.jsonRequests.count == 2)
        #expect(browser.openedURLs.count == 2)
        #expect(store.load(serverId: serverId, uid: "u1") == nil)
        #expect(store.loadClientRegistration(issuer: "https://auth.example.com", uid: "u1") == nil, "a rejected registration does not stay cached")
    }

    @Test("A validated callback carrying error=invalid_client also clears the DCR cache")
    func callbackClientErrorDiscardsRegistration() async throws {
        let transport = FakeMcpAuthTransport()
        try stubProtectedResource(transport)
        try stubDCR(transport)
        let (authorizer, store) = makeAuthorizer(transport: transport)
        let plan = try await readyPlan(authorizer)
        let attempt = try await authorizer.beginAuthorization(plan: plan, uid: "u1", state: "st_test", codeVerifier: "verifier_test")
        #expect(store.loadClientRegistration(issuer: "https://auth.example.com", uid: "u1") != nil)

        // A callback whose state does not match is untrusted: it must not clear the registration.
        let forged = try #require(URL(string: "oriveo://mcp/oauth/callback?error=invalid_client&state=st_other"))
        await #expect(throws: McpAuthorizerError.callbackRejected(.stateMismatch)) {
            _ = try await authorizer.completeAuthorization(attempt: attempt, callbackURL: forged, serverId: UUID(), uid: "u1")
        }
        #expect(store.loadClientRegistration(issuer: "https://auth.example.com", uid: "u1") != nil)

        let genuine = try #require(URL(string: "oriveo://mcp/oauth/callback?error=invalid_client&state=st_test"))
        await #expect(throws: McpAuthorizerError.clientRejected) {
            _ = try await authorizer.completeAuthorization(attempt: attempt, callbackURL: genuine, serverId: UUID(), uid: "u1")
        }
        #expect(store.loadClientRegistration(issuer: "https://auth.example.com", uid: "u1") == nil)
        #expect(transport.formRequests.isEmpty)
    }

    @Test("Registration endpoint unreachable this time → temporarilyUnavailable; registration refused → registrationFailed; neither writes to storage")
    func registrationFailures() async throws {
        let transport = FakeMcpAuthTransport()
        try stubProtectedResource(transport)
        try stubAuthorizationServer(transport, "authorization-server-metadata.dcr.json")
        let storage = InMemoryMcpCredentialStorage()
        let (authorizer, _) = makeAuthorizer(transport: transport, storage: storage)
        let plan = try await readyPlan(authorizer)

        transport.setUnreachable(true, at: registrationURL)
        await #expect(throws: McpAuthorizerError.temporarilyUnavailable) {
            _ = try await authorizer.beginAuthorization(plan: plan, uid: "u1")
        }
        transport.setUnreachable(false, at: registrationURL)
        transport.stub(status: 400, raw: #"{"error":"invalid_redirect_uri"}"#, at: registrationURL)
        await #expect(throws: McpAuthorizerError.registrationFailed) {
            _ = try await authorizer.beginAuthorization(plan: plan, uid: "u1")
        }
        #expect(storage.accounts().isEmpty)
    }

    @Test("No client metadata document configured: a server that supports both methods gets a dynamic registration; a server that only accepts a metadata document requires an access token")
    func withoutDocumentTheMetadataDocumentPathIsSkipped() async throws {
        let transport = FakeMcpAuthTransport()
        try stubProtectedResource(transport)
        try stubAuthorizationServer(transport, "authorization-server-metadata.cimd.json")
        let dcr = try authFixture("dcr.json")
        transport.stub(status: dcr["status"]?.intValue ?? 201, json: dcr["body"] ?? .object(JSONObject()), at: registrationURL)
        let (authorizer, _) = makeAuthorizer(transport: transport, clientMetadataDocumentURL: nil)

        let plan = try await readyPlan(authorizer)
        #expect(plan.registrationKind == .dcr)
        #expect(plan.registrationEndpoint?.absoluteString == registrationURL)
        let registration = try await authorizer.register(plan: plan, uid: "u1")
        #expect(registration.kind == .dcr)
        #expect(registration.clientID == "oriveo_mcp_2f9c41")
        #expect(transport.jsonRequests.map(\.url) == [registrationURL])

        // The same server without a registration endpoint: no client can be registered automatically.
        let metadata = try #require(try authFixture("authorization-server-metadata.cimd.json")["body"])
        let documentOnly = FakeMcpAuthTransport()
        try stubProtectedResource(documentOnly)
        documentOnly.stub(
            status: 200, json: replacing(metadata, key: "registration_endpoint", with: nil), at: authorizationServerURL
        )
        let (unconfigured, _) = makeAuthorizer(transport: documentOnly, clientMetadataDocumentURL: nil)
        #expect(await unconfigured.discover(challenge: protectedResourceChallenge(), endpoint: mcpEndpoint) == .needsToken)
        #expect(documentOnly.jsonRequests.isEmpty)

        // Control: with a document configured the same server is usable.
        let (configured, _) = makeAuthorizer(transport: documentOnly)
        #expect(try await readyPlan(configured).registrationKind == .cimd)
    }

    @Test("Client metadata document setting: only an absolute https URL with a host counts as configured")
    func clientMetadataDocumentURLResolution() {
        let unusable: [String?] = [
            nil, "", "   ", "\n",
            "http://app.example.com/oauth/mcp-client.json",
            "app.example.com/oauth/mcp-client.json",
            "/oauth/mcp-client.json",
            "oriveo://mcp/oauth/callback",
            "not a url",
            "https://",
        ]
        for raw in unusable {
            #expect(McpClientMetadata.resolveDocumentURL(raw) == nil, Comment(rawValue: raw ?? "nil"))
        }
        #expect(McpClientMetadata.resolveDocumentURL("https://app.example.com/oauth/mcp-client.json") == fixtureClientMetadataDocumentURL)
        #expect(
            McpClientMetadata.resolveDocumentURL("  https://app.example.com/oauth/mcp-client.json\n") == fixtureClientMetadataDocumentURL,
            "Surrounding whitespace is ignored"
        )
    }

    @Test("Registration path three: nothing supported → an access token is required (no guessing of default endpoints)")
    func registrationNone() async throws {
        let transport = FakeMcpAuthTransport()
        try stubProtectedResource(transport)
        try stubAuthorizationServer(transport, "authorization-server-metadata.none.json")
        let (authorizer, _) = makeAuthorizer(transport: transport)

        let outcome = await authorizer.discover(challenge: protectedResourceChallenge(), endpoint: mcpEndpoint)
        #expect(outcome == .needsToken)
        #expect(transport.jsonRequests.isEmpty)
    }

    @Test("Authorization server document whose issuer differs from the identifier used to build the URL → rejected, an access token is required")
    func issuerMismatchRejected() async throws {
        let transport = FakeMcpAuthTransport()
        try stubProtectedResource(transport)
        try stubAuthorizationServer(transport, "authorization-server-metadata.issuer-mismatch.json")
        let (authorizer, _) = makeAuthorizer(transport: transport)

        let outcome = await authorizer.discover(challenge: protectedResourceChallenge(), endpoint: mcpEndpoint)
        #expect(outcome == .needsToken)
        // After the first well-known is rejected for its mismatched issuer, the second one is still tried (openid-configuration, 404).
        #expect(transport.getURLs.contains(authorizationServerURL))
        #expect(transport.getURLs.contains("https://auth.example.com/.well-known/openid-configuration"))
    }

    // MARK: Authorization request / token request

    @Test("Fixture replay: authorization request (S256 / resource / state / scope)")
    func authorizationRequestFixture() throws {
        let fixture = try authFixture("authorization-request.json")
        let query = try #require(fixture["query"])
        let record = try #require(fixture["perRequestRecord"])
        let verifier = try #require(record["codeVerifier"]?.stringValue)
        let endpointString = try #require(fixture["url"]?.stringValue)
        let authorizationEndpoint = try #require(URL(string: endpointString))

        #expect(McpPKCE.codeChallenge(forVerifier: verifier) == query["code_challenge"]?.stringValue)

        let request = McpOAuthRequests.authorizationRequest(
            authorizationEndpoint: authorizationEndpoint,
            clientID: try #require(query["client_id"]?.stringValue),
            redirectURI: try #require(query["redirect_uri"]?.stringValue),
            state: try #require(query["state"]?.stringValue),
            codeVerifier: verifier,
            issuer: try #require(record["issuer"]?.stringValue),
            resource: try #require(query["resource"]?.stringValue),
            scope: try #require(query["scope"]?.stringValue)
        )
        var items: [String: String] = [:]
        for item in request.queryItems { items[item.name] = item.value }
        #expect(items["response_type"] == query["response_type"]?.stringValue)
        #expect(items["client_id"] == query["client_id"]?.stringValue)
        #expect(items["redirect_uri"] == query["redirect_uri"]?.stringValue)
        #expect(items["state"] == query["state"]?.stringValue)
        #expect(items["code_challenge"] == query["code_challenge"]?.stringValue)
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["resource"] == query["resource"]?.stringValue)
        #expect(items["scope"] == query["scope"]?.stringValue)
        // Per-request record: the PKCE verifier, issuer and state live in the same entry.
        #expect(request.state == record["state"]?.stringValue)
        #expect(request.issuer == record["issuer"]?.stringValue)
        #expect(request.codeVerifier == verifier)
    }

    @Test("The query string of the authorization endpoint is preserved, our parameters are appended and the original encoding is not rewritten")
    func authorizationRequestKeepsEndpointQuery() throws {
        let endpoint = try #require(URL(string: "https://auth.example.com/authorize?tenant=acme&x=a%2Bb#frag"))
        let request = McpOAuthRequests.authorizationRequest(
            authorizationEndpoint: endpoint,
            clientID: "client-1",
            redirectURI: "https://app.example.com/mcp/callback",
            state: "s1",
            codeVerifier: "verifier-verifier-verifier-verifier-verifier",
            issuer: "https://auth.example.com",
            resource: "https://mcp.example.com/mcp",
            scope: nil
        )
        let query = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
        #expect(query.hasPrefix("tenant=acme&x=a%2Bb&response_type=code&"))
        #expect(request.url.fragment == nil)
        let names = request.queryItems.map(\.name)
        #expect(names.prefix(2) == ["tenant", "x"])
        #expect(names.contains("code_challenge") && names.contains("state") && names.contains("resource"))
    }

    @Test("The canonical URI drops the trailing slash, including for the root path")
    func canonicalURIDropsTrailingSlash() throws {
        let cases: [(String, String)] = [
            ("https://MCP.example.com/mcp/", "https://mcp.example.com/mcp"),
            ("https://mcp.example.com/mcp#frag", "https://mcp.example.com/mcp"),
            ("https://mcp.example.com/", "https://mcp.example.com"),
            ("https://mcp.example.com", "https://mcp.example.com"),
            ("https://mcp.example.com/a/b/", "https://mcp.example.com/a/b"),
        ]
        for (raw, expected) in cases {
            #expect(McpCanonicalURI.canonical(try #require(URL(string: raw))) == expected, "\(raw)")
        }
    }

    @Test("Fixture replay: DCR request body (application_type = native, custom-scheme redirect URI)")
    func dcrRequestBody() throws {
        let fixture = try authFixture("dcr.json")
        let expected = try #require(fixture["request"]?["body"])
        let body = McpClientMetadata.registrationBody(scope: expected["scope"]?.stringValue)
        #expect(body["client_name"] == expected["client_name"])
        #expect(body["redirect_uris"] == expected["redirect_uris"])
        #expect(body["redirect_uris"] == .array(McpClientMetadata.redirectURIs.map { .string($0) }))
        #expect(body["grant_types"] == expected["grant_types"])
        #expect(body["response_types"] == expected["response_types"])
        #expect(body["token_endpoint_auth_method"] == expected["token_endpoint_auth_method"])
        #expect(body["application_type"]?.stringValue == "native")
        #expect(body["scope"] == expected["scope"])
        #expect(fixture["expect"]?["reusableAcrossIssuers"]?.boolValue == false)
    }

    @Test("Fixture replay: the token exchange form carries resource and code_verifier")
    func tokenExchangeFormFixture() throws {
        let fixture = try authFixture("token.request.json")
        let form = try #require(fixture["form"])
        let fields = McpOAuthRequests.tokenExchangeForm(
            code: try #require(form["code"]?.stringValue),
            clientID: try #require(form["client_id"]?.stringValue),
            redirectURI: try #require(form["redirect_uri"]?.stringValue),
            codeVerifier: try #require(form["code_verifier"]?.stringValue),
            resource: try #require(form["resource"]?.stringValue)
        )
        var items: [String: String] = [:]
        for field in fields { items[field.name] = field.value }
        for key in ["grant_type", "code", "redirect_uri", "client_id", "code_verifier", "resource"] {
            #expect(items[key] == form[key]?.stringValue, Comment(rawValue: key))
        }
    }

    @Test("Fixture replay: the refresh form carries resource; the success response is parsed")
    func refreshFormFixture() throws {
        let fixture = try authFixture("token.refresh.success.json")
        // The refresh form is nested under `request` (unlike the top-level form in token.request.json).
        let form = try #require(fixture["request"]?["form"])
        let fields = McpOAuthRequests.refreshForm(
            refreshToken: try #require(form["refresh_token"]?.stringValue),
            clientID: try #require(form["client_id"]?.stringValue),
            resource: try #require(form["resource"]?.stringValue)
        )
        var items: [String: String] = [:]
        for field in fields { items[field.name] = field.value }
        for key in ["grant_type", "refresh_token", "client_id", "resource"] {
            #expect(items[key] == form[key]?.stringValue, Comment(rawValue: key))
        }
        let body = try #require(fixture["body"])
        let tokens = try #require(McpTokenResponse(json: body))
        #expect(tokens.accessToken == "mcp_at_example_2")
        #expect(tokens.refreshToken == "mcp_rt_example_2")
        #expect(tokens.expiresIn == 3600)
    }

    @Test("Fixture replay: successful token exchange response (MUST NOT assume a refresh token is present)")
    func tokenSuccessFixture() throws {
        let fixture = try authFixture("token.success.json")
        let body = try #require(fixture["body"])
        let tokens = try #require(McpTokenResponse(json: body))
        #expect(tokens.accessToken == "mcp_at_example")
        #expect((tokens.refreshToken != nil) == fixture["expect"]?["hasRefreshToken"]?.boolValue)
    }

    // MARK: Callback validation (RFC 9207)

    @Test("Fixture replay: the 9 callback vectors (RFC 9207 2×2 + state + no normalization), each run through the production path of the authorizer")
    func callbackVectors() async throws {
        let fixture = try authFixture("callback.params.json")
        let expectedIssuer = try #require(fixture["expectedIssuer"]?.stringValue)
        let expectedState = try #require(fixture["expectedState"]?.stringValue)
        let cases = try #require(fixture["cases"]?.arrayValue)
        #expect(cases.count == 9)
        let metadata = try #require(try authFixture("authorization-server-metadata.cimd.json")["body"])

        for item in cases {
            let caseId = item["caseId"]?.stringValue ?? "?"
            let comment = Comment(rawValue: caseId)
            let supported = item["metadata"]?["authorization_response_iss_parameter_supported"]?.boolValue
            var params: [String: String] = [:]
            var components = try #require(URLComponents(string: iosRedirectURI))
            var queryItems: [URLQueryItem] = []
            if let object = item["params"]?.objectValue {
                for key in object.keys {
                    params[key] = object[key]?.stringValue ?? ""
                    queryItems.append(URLQueryItem(name: key, value: object[key]?.stringValue))
                }
            }
            components.queryItems = queryItems
            let callbackURL = try #require(components.url)
            let expectAccepted = item["expect"]?["accepted"]?.boolValue ?? false
            let expectedReason = item["expect"]?["reason"]?.stringValue

            // 1. Pure function: the callback URL and the registered URL are really passed in, so redirect URI validation is on the path too.
            let result = McpCallbackValidator.validate(
                params: params,
                expectedState: expectedState,
                expectedIssuer: expectedIssuer,
                issParameterSupported: supported ?? false,
                callbackURL: callbackURL,
                registeredRedirectURI: iosRedirectURI
            )
            #expect(result.isAccepted == expectAccepted, comment)
            #expect(result.rejection?.rawValue == expectedReason, comment)

            // 2. Production path: the authorization server metadata declares support as this vector says → discovery →
            // begin authorization → receive this callback.
            let transport = FakeMcpAuthTransport()
            try stubProtectedResource(transport)
            transport.stub(
                status: 200,
                json: replacing(metadata, key: "authorization_response_iss_parameter_supported", with: supported.map { .bool($0) }),
                at: authorizationServerURL
            )
            try stubToken(transport, "token.success.json")
            let (authorizer, store) = makeAuthorizer(transport: transport)
            let plan = try await readyPlan(authorizer)
            #expect(plan.issParameterSupported == (supported ?? false), comment)
            #expect(plan.issuer == expectedIssuer, comment)
            let attempt = try await authorizer.beginAuthorization(
                plan: plan, uid: "u1", state: expectedState, codeVerifier: "verifier_test"
            )
            let serverId = UUID()
            do {
                let credentials = try await authorizer.completeAuthorization(
                    attempt: attempt, callbackURL: callbackURL, serverId: serverId, uid: "u1"
                )
                #expect(expectAccepted, comment)
                #expect(credentials.accessToken == "mcp_at_example", comment)
                #expect(transport.formRequests.count == 1, comment)
            } catch let error as McpAuthorizerError {
                #expect(!expectAccepted, comment)
                let reason = try #require(expectedReason.flatMap(McpCallbackRejectionReason.init(rawValue:)), comment)
                #expect(error == .callbackRejected(reason), comment)
                // The rejection happens before the token exchange: no token request and no credential on disk.
                #expect(transport.formRequests.isEmpty, comment)
                #expect(store.load(serverId: serverId, uid: "u1") == nil, comment)
                // With a mismatched iss, error / error_description must not be adopted or shown: the error thrown by the
                // production path carries none of the server text.
                if item["expect"]?["surfaceErrorText"]?.boolValue == false {
                    #expect(params["error_description"] == "user said no", comment)
                    for text in [String(describing: error), String(reflecting: error), error.localizedDescription] {
                        #expect(!text.contains("user said no"), comment)
                        #expect(!text.contains("access_denied"), comment)
                    }
                    #expect(error != .callbackRejected(.authorizationError), comment)
                }
            }
        }
    }

    @Test("Redirect URI validation: any mismatch in scheme / host / path is rejected; the query string is not compared")
    func redirectURIMatching() throws {
        let registered = iosRedirectURI
        let accepted = ["oriveo://mcp/oauth/callback?code=x&state=y", "ORIVEO://MCP/oauth/callback"]
        let rejected = [
            "oriveo://mcp/oauth/other?code=x",
            "oriveo://evil/oauth/callback?code=x",
            "https://mcp/oauth/callback?code=x",
            "https://app.example.com/mcp/oauth/callback?code=x",
            "oriveo://mcp/oauth/callback/extra",
        ]
        for text in accepted {
            #expect(McpRedirectURI.matches(callbackURL: try #require(URL(string: text)), registered: registered), Comment(rawValue: text))
        }
        for text in rejected {
            #expect(!McpRedirectURI.matches(callbackURL: try #require(URL(string: text)), registered: registered), Comment(rawValue: text))
        }
    }

    @Test("state mismatch → rejected, no token stored and no token exchange request sent")
    func stateMismatchRejects() async throws {
        let transport = FakeMcpAuthTransport()
        let (authorizer, store, attempt) = try await makeCIMDAttempt(transport: transport)
        let serverId = UUID()
        let callback = try #require(URL(string:
            "oriveo://mcp/oauth/callback?code=ac_123&state=st_other&iss=https://auth.example.com"
        ))
        do {
            _ = try await authorizer.completeAuthorization(attempt: attempt, callbackURL: callback, serverId: serverId, uid: "u1")
            Issue.record("rejection expected")
        } catch let error as McpAuthorizerError {
            #expect(error == .callbackRejected(.stateMismatch))
        }
        #expect(store.load(serverId: serverId, uid: "u1") == nil)
        #expect(transport.formRequests.isEmpty)
    }

    @Test("iss mismatch → rejected and no token stored")
    func issuerMismatchCallbackRejects() async throws {
        let transport = FakeMcpAuthTransport()
        let (authorizer, store, attempt) = try await makeCIMDAttempt(transport: transport)
        let serverId = UUID()
        let callback = try #require(URL(string:
            "oriveo://mcp/oauth/callback?code=ac_123&state=st_test&iss=https://evil.example"
        ))
        do {
            _ = try await authorizer.completeAuthorization(attempt: attempt, callbackURL: callback, serverId: serverId, uid: "u1")
            Issue.record("rejection expected")
        } catch let error as McpAuthorizerError {
            #expect(error == .callbackRejected(.issMismatch))
        }
        #expect(store.load(serverId: serverId, uid: "u1") == nil)
        #expect(transport.formRequests.isEmpty)
    }

    @Test("Callback to an address that is not the registered one → rejected and no token stored")
    func redirectMismatchRejects() async throws {
        let transport = FakeMcpAuthTransport()
        let (authorizer, store, attempt) = try await makeCIMDAttempt(transport: transport)
        let serverId = UUID()
        // The registered address is oriveo://mcp/oauth/callback; this callback arrives at an https address instead.
        let callback = try #require(URL(string:
            "https://app.example.com/mcp/oauth/callback?code=ac_123&state=st_test&iss=https://auth.example.com"
        ))
        do {
            _ = try await authorizer.completeAuthorization(attempt: attempt, callbackURL: callback, serverId: serverId, uid: "u1")
            Issue.record("rejection expected")
        } catch let error as McpAuthorizerError {
            #expect(error == .callbackRejected(.redirectURIMismatch))
        }
        #expect(store.load(serverId: serverId, uid: "u1") == nil)
        #expect(transport.formRequests.isEmpty)
    }

    @Test("Valid callback → token exchange (with resource) and persistence")
    func validCallbackSavesCredentials() async throws {
        let transport = FakeMcpAuthTransport()
        let (authorizer, store, attempt) = try await makeCIMDAttempt(transport: transport)
        let serverId = UUID()
        let callback = try #require(URL(string:
            "oriveo://mcp/oauth/callback?code=ac_123&state=st_test&iss=https://auth.example.com"
        ))
        let credentials = try await authorizer.completeAuthorization(
            attempt: attempt, callbackURL: callback, serverId: serverId, uid: "u1"
        )
        #expect(credentials.accessToken == "mcp_at_example")
        #expect(credentials.refreshToken == "mcp_rt_example")
        #expect(credentials.issuer == "https://auth.example.com")
        #expect(store.load(serverId: serverId, uid: "u1")?.accessToken == "mcp_at_example")

        let request = try #require(transport.formRequests.first)
        #expect(request.url == tokenURL)
        var items: [String: String] = [:]
        for field in request.form { items[field.name] = field.value }
        #expect(items["resource"] == "https://mcp.example.com/mcp")
        #expect(items["code_verifier"] == "verifier_test")
        #expect(items["grant_type"] == "authorization_code")
    }

    @Test("Browser session abstraction: credentials are saved after a complete sign-in")
    func browserFlowSavesCredentials() async throws {
        let transport = FakeMcpAuthTransport()
        try stubProtectedResource(transport)
        try stubAuthorizationServer(transport, "authorization-server-metadata.cimd.json")
        try stubToken(transport, "token.success.json")
        let browser = FakeMcpBrowserSession()
        browser.callbackBuilder = echoingCallback
        let (authorizer, store) = makeAuthorizer(transport: transport, browser: browser)
        let serverId = UUID()

        let plan = try await readyPlan(authorizer)
        let credentials = try await authorizer.authorize(plan: plan, serverId: serverId, uid: "u1")
        #expect(credentials.accessToken == "mcp_at_example")
        #expect(store.load(serverId: serverId, uid: "u1") == credentials, "the returned credentials are the persisted ones")
        #expect(browser.openedURLs.count == 1)
        #expect(browser.openedURLs.first?.host == "auth.example.com")
    }

    // MARK: Refresh

    @Test("Concurrent refreshes are serialized: two concurrent calls trigger a single refresh")
    func concurrentRefreshSerializes() async throws {
        let transport = FakeMcpAuthTransport()
        try stubProtectedResource(transport)
        try stubAuthorizationServer(transport, "authorization-server-metadata.cimd.json")
        try stubToken(transport, "token.refresh.success.json")
        transport.postFormDelay = 0.15
        let (authorizer, store) = makeAuthorizer(transport: transport)
        let serverId = UUID()
        try savedCredentials(serverId: serverId, in: store)

        async let first = authorizer.refresh(serverId: serverId, uid: "u1")
        async let second = authorizer.refresh(serverId: serverId, uid: "u1")
        let a = try await first
        let b = try await second
        #expect(a == b)
        #expect(a.accessToken == "mcp_at_example_2")
        #expect(transport.formRequests.count == 1)

        // Persisted right after a successful refresh: what the credential store returns is the new token (including the rotated refresh token).
        let stored = try #require(store.load(serverId: serverId, uid: "u1"))
        #expect(stored == a)
        #expect(stored.accessToken == "mcp_at_example_2")
        #expect(stored.refreshToken == "mcp_rt_example_2")
        #expect(stored.expiresAt != nil)

        // The refresh request sent matches the fixture (resource is mandatory).
        let fixture = try authFixture("token.refresh.success.json")
        let expected = try #require(fixture["request"]?["form"]?.objectValue)
        let sent = try #require(transport.formRequests.first)
        #expect(sent.url == fixture["request"]?["url"]?.stringValue)
        #expect(sent.form.count == expected.keys.count)
        for key in expected.keys {
            #expect(sent.form.first { $0.name == key }?.value == expected[key]?.stringValue, Comment(rawValue: key))
        }
    }

    @Test("Fixture replay: three token exchange failures → throws; invalid_grant drops the tokens and keeps the registration")
    func tokenErrorCases() async throws {
        let fixture = try authFixture("token.error.json")
        let cases = try #require(fixture["cases"]?.arrayValue)
        #expect(cases.count == 3)

        for item in cases {
            let caseId = item["caseId"]?.stringValue ?? "?"
            let transport = FakeMcpAuthTransport()
            try stubProtectedResource(transport)
            try stubAuthorizationServer(transport, "authorization-server-metadata.cimd.json")
            transport.stub(
                status: item["status"]?.intValue ?? 400,
                json: item["body"] ?? .object(JSONObject()),
                at: tokenURL
            )
            let (authorizer, store) = makeAuthorizer(transport: transport)
            let serverId = UUID()
            try savedCredentials(serverId: serverId, in: store)
            do {
                _ = try await authorizer.refresh(serverId: serverId, uid: "u1")
                Issue.record(Comment(rawValue: "failure expected: \(caseId)"))
            } catch let error as McpAuthorizerError {
                #expect(error == .tokenRequestFailed, Comment(rawValue: caseId))
            }
            let stored = store.load(serverId: serverId, uid: "u1")
            if caseId == "invalid_grant" {
                // discardTokens: true / discardCredentials: false
                #expect(stored?.accessToken == nil, Comment(rawValue: caseId))
                #expect(stored?.refreshToken == nil, Comment(rawValue: caseId))
                #expect(stored?.clientID != nil, Comment(rawValue: caseId))
            } else {
                #expect(stored?.refreshToken == "mcp_rt_example", Comment(rawValue: caseId))
            }
        }
    }

    @Test("Storage is re-read before acting on invalid_grant: a refresh token already rotated elsewhere → adopt the stored credentials instead of wiping them; drop them only when it is still the one that was sent")
    func invalidGrantRereadsStorageBeforeDiscarding() async throws {
        let fixture = try authFixture("token.error.json")
        let invalidGrant = try #require(fixture["cases"]?.arrayValue?.first { $0["caseId"]?.stringValue == "invalid_grant" })
        let transport = FakeMcpAuthTransport()
        try stubProtectedResource(transport)
        try stubAuthorizationServer(transport, "authorization-server-metadata.cimd.json")
        transport.stub(
            status: invalidGrant["status"]?.intValue ?? 400,
            json: invalidGrant["body"] ?? .object(JSONObject()),
            at: tokenURL
        )
        transport.postFormDelay = 0.2
        let (authorizer, store) = makeAuthorizer(transport: transport)
        let serverId = UUID()
        try savedCredentials(serverId: serverId, in: store)

        // While this refresh was waiting on the token endpoint, something else (another refresh, a new sign-in)
        // already rotated the credentials and persisted them.
        let rotated = McpCredentials(
            accessToken: "mcp_at_rotated", refreshToken: "mcp_rt_rotated", expiresAt: Date().addingTimeInterval(3_600),
            issuer: "https://auth.example.com", clientID: fixtureClientMetadataDocumentURL.absoluteString,
            resource: "https://mcp.example.com/mcp"
        )
        let refreshing = Task { try await authorizer.refresh(serverId: serverId, uid: "u1") }
        try await Task.sleep(nanoseconds: 60_000_000)
        #expect(transport.formRequests.first?.form.first { $0.name == "refresh_token" }?.value == "mcp_rt_example")
        try store.save(rotated, serverId: serverId, uid: "u1")

        #expect(try await refreshing.value == rotated, "the stored, newer credentials are returned")
        #expect(store.load(serverId: serverId, uid: "u1") == rotated, "the newer credentials are not wiped by this invalid_grant")

        // Control: storage still holds the refresh token that was sent → drop the tokens, keep the registration
        // (matching the token.error.json fixture).
        let other = UUID()
        try savedCredentials(serverId: other, in: store)
        await #expect(throws: McpAuthorizerError.tokenRequestFailed) {
            _ = try await authorizer.refresh(serverId: other, uid: "u1")
        }
        let discarded = store.load(serverId: other, uid: "u1")
        #expect(discarded?.accessToken == nil && discarded?.refreshToken == nil && discarded?.clientID != nil)

        // The server was removed while waiting for the response (credentials deleted): no empty credential shell is written back.
        let removed = UUID()
        try savedCredentials(serverId: removed, in: store)
        let late = Task { try await authorizer.refresh(serverId: removed, uid: "u1") }
        try await Task.sleep(nanoseconds: 60_000_000)
        try store.delete(serverId: removed, uid: "u1")
        await #expect(throws: McpAuthorizerError.tokenRequestFailed) { _ = try await late.value }
        #expect(store.load(serverId: removed, uid: "u1") == nil)
    }

    @Test("Token about to expire before a call → refresh first, then return the new token")
    func validAccessTokenRefreshesWhenExpiring() async throws {
        let transport = FakeMcpAuthTransport()
        try stubProtectedResource(transport)
        try stubAuthorizationServer(transport, "authorization-server-metadata.cimd.json")
        try stubToken(transport, "token.refresh.success.json")
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let (authorizer, store) = makeAuthorizer(transport: transport, now: { fixedNow })
        let serverId = UUID()
        try store.save(
            McpCredentials(
                accessToken: "old",
                refreshToken: "mcp_rt_example",
                expiresAt: fixedNow.addingTimeInterval(10),
                issuer: "https://auth.example.com",
                clientID: fixtureClientMetadataDocumentURL.absoluteString,
                resource: "https://mcp.example.com/mcp"
            ),
            serverId: serverId,
            uid: "u1"
        )

        let token = try await authorizer.validAccessToken(serverId: serverId, uid: "u1")
        #expect(token == "mcp_at_example_2")

        // The new token and expiry are already persisted; the next call does not refresh again.
        let stored = try #require(store.load(serverId: serverId, uid: "u1"))
        #expect(stored.accessToken == "mcp_at_example_2")
        #expect(stored.refreshToken == "mcp_rt_example_2")
        #expect(stored.expiresAt == fixedNow.addingTimeInterval(3600))
        #expect(try await authorizer.validAccessToken(serverId: serverId, uid: "u1") == "mcp_at_example_2")
        #expect(transport.formRequests.count == 1)
    }

    @Test("Pasted token: validAccessToken returns it after storePastedToken")
    func pastedToken() async throws {
        let (authorizer, _) = makeAuthorizer(transport: FakeMcpAuthTransport())
        let serverId = UUID()
        try await authorizer.storePastedToken("pasted_abc", serverId: serverId, uid: "u1")
        let token = try await authorizer.validAccessToken(serverId: serverId, uid: "u1")
        #expect(token == "pasted_abc")
    }

    // MARK: Validating `resource` in protected resource metadata (RFC 9728 section 3.3)

    @Test("Metadata whose resource does not correspond to the requested MCP endpoint is not used: the authorization server it points to is never fetched",
          arguments: [
            "https://other.example.com/mcp",
            "https://mcp.example.com/other",
            "https://mcp.example.com/mcp/deeper",
            "https://mcp.example.com/mc",
            "http://mcp.example.com/mcp",
            "https://mcp.example.com:8443/mcp",
            "https://mcp.example.com/?tenant=1",
          ])
    func mismatchedResourceMetadataIsRejected(resource: String) async throws {
        let transport = FakeMcpAuthTransport()
        let fixture = try authFixture("protected-resource-metadata.json")
        transport.stub(
            status: 200,
            json: replacing(try #require(fixture["body"]), key: "resource", with: .string(resource)),
            at: protectedResourceURL
        )
        try stubAuthorizationServer(transport, "authorization-server-metadata.cimd.json")
        let (authorizer, _) = makeAuthorizer(transport: transport)

        let outcome = await authorizer.discover(challenge: protectedResourceChallenge(), endpoint: mcpEndpoint)
        #expect(outcome == .needsToken)
        #expect(!transport.getURLs.contains(authorizationServerURL), "the authorization server named by rejected metadata must not be contacted")
    }

    @Test("Metadata without a resource field is not used either")
    func missingResourceIsRejected() async throws {
        let transport = FakeMcpAuthTransport()
        let fixture = try authFixture("protected-resource-metadata.json")
        transport.stub(status: 200, json: replacing(try #require(fixture["body"]), key: "resource", with: nil), at: protectedResourceURL)
        try stubAuthorizationServer(transport, "authorization-server-metadata.cimd.json")
        let (authorizer, _) = makeAuthorizer(transport: transport)

        #expect(await authorizer.discover(challenge: protectedResourceChallenge(), endpoint: mcpEndpoint) == .needsToken)
        #expect(!transport.getURLs.contains(authorizationServerURL))
    }

    @Test("Metadata is usable when resource is the endpoint itself (compared as canonical URI), a parent path or the whole origin",
          arguments: [
            "https://mcp.example.com/mcp",
            "https://MCP.example.com/mcp/",
            "HTTPS://mcp.example.com/mcp#frag",
            "https://mcp.example.com",
            "https://mcp.example.com/",
            "https://mcp.example.com:443/mcp",
          ])
    func matchingResourceMetadataIsAccepted(resource: String) async throws {
        let transport = FakeMcpAuthTransport()
        let fixture = try authFixture("protected-resource-metadata.json")
        transport.stub(
            status: 200,
            json: replacing(try #require(fixture["body"]), key: "resource", with: .string(resource)),
            at: protectedResourceURL
        )
        try stubAuthorizationServer(transport, "authorization-server-metadata.cimd.json")
        let (authorizer, _) = makeAuthorizer(transport: transport)

        let plan = try await readyPlan(authorizer)
        // The resource sent to the authorization server is always the canonical URI of the endpoint we requested,
        // never the spelling in the document.
        #expect(plan.resource == "https://mcp.example.com/mcp")
    }

    @Test("When the metadata named in the header has a mismatched resource, the well-known order is walked to find one that matches")
    func fallsThroughToNextCandidateOnResourceMismatch() async throws {
        let transport = FakeMcpAuthTransport()
        let fixture = try authFixture("protected-resource-metadata.json")
        let body = try #require(fixture["body"])
        let fromHeader = "https://mcp.example.com/somewhere/else.json"
        transport.stub(status: 200, json: replacing(body, key: "resource", with: .string("https://other.example.com/mcp")), at: fromHeader)
        transport.stub(status: 200, json: body, at: "https://mcp.example.com/.well-known/oauth-protected-resource/mcp")
        try stubAuthorizationServer(transport, "authorization-server-metadata.cimd.json")
        let (authorizer, _) = makeAuthorizer(transport: transport)

        let challenge = McpAuthChallenge(resourceMetadata: URL(string: fromHeader))
        _ = try await readyPlan(authorizer, challenge: challenge)
        #expect(transport.getURLs.prefix(2) == [fromHeader, "https://mcp.example.com/.well-known/oauth-protected-resource/mcp"])
    }

    // MARK: PKCE method

    @Test("Authorization server metadata must declare S256: missing, empty or plain-only all stop the flow and fall back to requiring an access token",
          arguments: ["missing", "empty", "plain_only", "wrong_case", "not_an_array"])
    func metadataWithoutS256IsRefused(variant: String) async throws {
        let value: JSONValue? = switch variant {
        case "missing": nil
        case "empty": .array([])
        case "plain_only": .array([.string("plain")])
        case "wrong_case": .array([.string("s256")])
        default: .string("S256")
        }
        for fixture in ["authorization-server-metadata.cimd.json", "authorization-server-metadata.dcr.json"] {
            let transport = FakeMcpAuthTransport()
            try stubProtectedResource(transport)
            let metadata = try #require(try authFixture(fixture)["body"])
            transport.stub(
                status: 200,
                json: replacing(metadata, key: "code_challenge_methods_supported", with: value),
                at: authorizationServerURL
            )
            let storage = InMemoryMcpCredentialStorage()
            let browser = FakeMcpBrowserSession()
            let (authorizer, _) = makeAuthorizer(transport: transport, browser: browser, storage: storage)

            let outcome = await authorizer.discover(challenge: protectedResourceChallenge(), endpoint: mcpEndpoint)
            #expect(outcome == .needsToken, "\(variant) / \(fixture)")
            #expect(transport.jsonRequests.isEmpty, "no client registration may be attempted")
            #expect(browser.openedURLs.isEmpty)
            #expect(storage.accounts().isEmpty)
        }
    }

    @Test("With S256 declared (alongside other methods is fine) an authorization plan is produced as usual")
    func metadataWithS256IsAccepted() async throws {
        let transport = FakeMcpAuthTransport()
        try stubProtectedResource(transport)
        let metadata = try #require(try authFixture("authorization-server-metadata.cimd.json")["body"])
        transport.stub(
            status: 200,
            json: replacing(metadata, key: "code_challenge_methods_supported", with: .array([.string("plain"), .string("S256")])),
            at: authorizationServerURL
        )
        let (authorizer, _) = makeAuthorizer(transport: transport)
        let plan = try await readyPlan(authorizer)
        #expect(plan.registrationKind == .cimd)
    }

    // MARK: https only

    @Test("Metadata whose authorization / token / registration endpoint is not https is unusable, and no request goes to an http address",
          arguments: ["authorization_endpoint", "token_endpoint"])
    func insecureEndpointsAreRefused(key: String) async throws {
        let transport = FakeMcpAuthTransport()
        try stubProtectedResource(transport)
        let metadata = try #require(try authFixture("authorization-server-metadata.cimd.json")["body"])
        transport.stub(status: 200, json: replacing(metadata, key: key, with: .string("http://auth.example.com/insecure")), at: authorizationServerURL)
        let (authorizer, _) = makeAuthorizer(transport: transport)

        #expect(await authorizer.discover(challenge: protectedResourceChallenge(), endpoint: mcpEndpoint) == .needsToken)
        #expect(!transport.getURLs.contains { $0.hasPrefix("http://") })
    }

    @Test("A DCR registration endpoint that is not https → no automatic registration and no request sent to it")
    func insecureRegistrationEndpointIsRefused() async throws {
        let transport = FakeMcpAuthTransport()
        try stubProtectedResource(transport)
        let metadata = try #require(try authFixture("authorization-server-metadata.dcr.json")["body"])
        transport.stub(status: 200, json: replacing(metadata, key: "registration_endpoint", with: .string("http://auth.example.com/register")), at: authorizationServerURL)
        let (authorizer, _) = makeAuthorizer(transport: transport)

        #expect(await authorizer.discover(challenge: protectedResourceChallenge(), endpoint: mcpEndpoint) == .needsToken)
        #expect(transport.jsonRequests.isEmpty)
    }

    @Test("Authorization server issuers and metadata URLs that are not https are never contacted")
    func insecureIssuerAndMetadataURLAreNotFetched() async throws {
        let transport = FakeMcpAuthTransport()
        let fixture = try authFixture("protected-resource-metadata.json")
        transport.stub(
            status: 200,
            json: replacing(try #require(fixture["body"]), key: "authorization_servers", with: .array([.string("http://auth.example.com")])),
            at: protectedResourceURL
        )
        let (authorizer, _) = makeAuthorizer(transport: transport)
        #expect(await authorizer.discover(challenge: protectedResourceChallenge(), endpoint: mcpEndpoint) == .needsToken)

        // The resource_metadata in the 401 header is http: skip it and use the https well-known instead.
        let insecureChallenge = McpAuthChallenge(resourceMetadata: URL(string: "http://mcp.example.com/prm.json"))
        _ = await authorizer.discover(challenge: insecureChallenge, endpoint: mcpEndpoint)
        #expect(!transport.getURLs.contains { $0.hasPrefix("http://") })
    }

    // MARK: Transient errors are kept apart from definitive failures

    @Test("Discovery: metadata unreachable this time → temporarilyUnavailable, not \"access token required\"")
    func discoveryTransientFailure() async throws {
        let transport = FakeMcpAuthTransport()
        try stubProtectedResource(transport)
        try stubAuthorizationServer(transport, "authorization-server-metadata.cimd.json")
        let (authorizer, _) = makeAuthorizer(transport: transport)

        transport.setUnreachable(true, at: authorizationServerURL)
        transport.setUnreachable(true, at: "https://auth.example.com/.well-known/openid-configuration")
        #expect(await authorizer.discover(challenge: protectedResourceChallenge(), endpoint: mcpEndpoint) == .temporarilyUnavailable)

        transport.setUnreachable(false, at: authorizationServerURL)
        transport.stub(status: 503, raw: "", at: authorizationServerURL)
        #expect(await authorizer.discover(challenge: protectedResourceChallenge(), endpoint: mcpEndpoint) == .temporarilyUnavailable)

        transport.setUnreachable(true, at: protectedResourceURL)
        #expect(await authorizer.discover(challenge: protectedResourceChallenge(), endpoint: mcpEndpoint) == .temporarilyUnavailable)
    }

    @Test("Refresh: no refresh token → noRefreshToken, and no request is sent")
    func refreshWithoutRefreshToken() async throws {
        let transport = FakeMcpAuthTransport()
        try stubAuthorizationServer(transport, "authorization-server-metadata.cimd.json")
        let (authorizer, store) = makeAuthorizer(transport: transport)
        let serverId = UUID()
        try store.save(
            McpCredentials(accessToken: "only_access", issuer: "https://auth.example.com",
                           clientID: fixtureClientMetadataDocumentURL.absoluteString, resource: "https://mcp.example.com/mcp"),
            serverId: serverId, uid: "u1"
        )
        await #expect(throws: McpAuthorizerError.noRefreshToken) {
            _ = try await authorizer.refresh(serverId: serverId, uid: "u1")
        }
        #expect(transport.getURLs.isEmpty)
        #expect(transport.formRequests.isEmpty)
    }

    @Test("Refresh: metadata temporarily unavailable / token endpoint unreachable / 5xx → temporarilyUnavailable, credentials kept as is")
    func refreshTransientFailureKeepsCredentials() async throws {
        let transport = FakeMcpAuthTransport()
        try stubAuthorizationServer(transport, "authorization-server-metadata.cimd.json")
        try stubToken(transport, "token.refresh.success.json")
        let (authorizer, store) = makeAuthorizer(transport: transport)
        let serverId = UUID()
        try savedCredentials(serverId: serverId, in: store)
        let before = try #require(store.load(serverId: serverId, uid: "u1"))

        // 1. The metadata endpoint is unreachable.
        transport.setUnreachable(true, at: authorizationServerURL)
        do {
            _ = try await authorizer.refresh(serverId: serverId, uid: "u1")
            Issue.record("failure expected")
        } catch let error as McpAuthorizerError {
            #expect(error == .temporarilyUnavailable)
            #expect(error.isTransient)
            #expect(error != .noRefreshToken, "a transient error must not be reported as needing a new sign-in")
        }
        #expect(transport.formRequests.isEmpty)
        #expect(store.load(serverId: serverId, uid: "u1") == before)

        // 2. Metadata is back, the token endpoint is unreachable.
        transport.setUnreachable(false, at: authorizationServerURL)
        transport.setUnreachable(true, at: tokenURL)
        await #expect(throws: McpAuthorizerError.temporarilyUnavailable) {
            _ = try await authorizer.refresh(serverId: serverId, uid: "u1")
        }
        #expect(store.load(serverId: serverId, uid: "u1") == before)

        // 3. The token endpoint answers 503.
        transport.setUnreachable(false, at: tokenURL)
        transport.enqueue(status: 503, json: .object(JSONObject()), at: tokenURL)
        await #expect(throws: McpAuthorizerError.temporarilyUnavailable) {
            _ = try await authorizer.refresh(serverId: serverId, uid: "u1")
        }
        #expect(store.load(serverId: serverId, uid: "u1") == before)

        // 4. After recovery the refresh succeeds as usual: the transient failures damaged no state.
        #expect(try await authorizer.refresh(serverId: serverId, uid: "u1").accessToken == "mcp_at_example_2")
    }

    @Test("Refresh: authorization server metadata definitively unavailable (all 404) → metadataUnavailable, not a transient error")
    func refreshWithMetadataGone() async throws {
        let transport = FakeMcpAuthTransport()
        let (authorizer, store) = makeAuthorizer(transport: transport)
        let serverId = UUID()
        try savedCredentials(serverId: serverId, in: store)
        do {
            _ = try await authorizer.refresh(serverId: serverId, uid: "u1")
            Issue.record("failure expected")
        } catch let error as McpAuthorizerError {
            #expect(error == .metadataUnavailable)
            #expect(!error.isTransient)
        }
    }

    @Test("Getting a token before a call: a transient refresh error while the token is still valid → return the current token; only once it has really expired is the transient error thrown")
    func validAccessTokenSurvivesTransientRefreshFailure() async throws {
        let transport = FakeMcpAuthTransport()
        try stubAuthorizationServer(transport, "authorization-server-metadata.cimd.json")
        transport.setUnreachable(true, at: tokenURL)
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let (authorizer, store) = makeAuthorizer(transport: transport, now: { fixedNow })
        let serverId = UUID()
        func save(expiresIn seconds: TimeInterval) throws {
            try store.save(
                McpCredentials(
                    accessToken: "still_valid", refreshToken: "mcp_rt_example",
                    expiresAt: fixedNow.addingTimeInterval(seconds),
                    issuer: "https://auth.example.com",
                    clientID: fixtureClientMetadataDocumentURL.absoluteString,
                    resource: "https://mcp.example.com/mcp"
                ),
                serverId: serverId, uid: "u1"
            )
        }

        try save(expiresIn: 30)
        #expect(try await authorizer.validAccessToken(serverId: serverId, uid: "u1") == "still_valid")
        #expect(transport.formRequests.count == 1, "a refresh was really attempted")

        try save(expiresIn: -5)
        await #expect(throws: McpAuthorizerError.temporarilyUnavailable) {
            _ = try await authorizer.validAccessToken(serverId: serverId, uid: "u1")
        }
        #expect(store.load(serverId: serverId, uid: "u1")?.refreshToken == "mcp_rt_example", "a transient error does not drop the refresh token")
    }

    // MARK: A failed persist must not count as saved

    @Test("Token exchange succeeds but secure storage refuses the write → throws credentialPersistenceFailed and returns no credentials")
    func completeAuthorizationFailsWhenStorageFails() async throws {
        let transport = FakeMcpAuthTransport()
        try stubProtectedResource(transport)
        try stubAuthorizationServer(transport, "authorization-server-metadata.cimd.json")
        try stubToken(transport, "token.success.json")
        let storage = InMemoryMcpCredentialStorage()
        let (authorizer, store) = makeAuthorizer(transport: transport, storage: storage)
        let attempt = try await authorizer.beginAuthorization(
            plan: try await readyPlan(authorizer), uid: "u1", state: "st_test", codeVerifier: "verifier_test"
        )
        let callback = try #require(URL(string: "oriveo://mcp/oauth/callback?code=ac_123&state=st_test&iss=https://auth.example.com"))
        let serverId = UUID()

        storage.failWrites = true
        await #expect(throws: McpAuthorizerError.credentialPersistenceFailed) {
            _ = try await authorizer.completeAuthorization(attempt: attempt, callbackURL: callback, serverId: serverId, uid: "u1")
        }
        #expect(transport.formRequests.count == 1, "the token was obtained, it just could not be stored")
        #expect(store.load(serverId: serverId, uid: "u1") == nil)
    }

    @Test("Refresh succeeds but secure storage refuses the write → throws; a pasted token that cannot be written throws as well")
    func refreshAndPasteFailWhenStorageFails() async throws {
        let transport = FakeMcpAuthTransport()
        try stubAuthorizationServer(transport, "authorization-server-metadata.cimd.json")
        try stubToken(transport, "token.refresh.success.json")
        let storage = InMemoryMcpCredentialStorage()
        let (authorizer, store) = makeAuthorizer(transport: transport, storage: storage)
        let serverId = UUID()
        try savedCredentials(serverId: serverId, in: store)

        storage.failWrites = true
        await #expect(throws: McpAuthorizerError.credentialPersistenceFailed) {
            _ = try await authorizer.refresh(serverId: serverId, uid: "u1")
        }
        #expect(store.load(serverId: serverId, uid: "u1")?.accessToken == "old", "storage still holds the old credentials")

        await #expect(throws: McpAuthorizerError.credentialPersistenceFailed) {
            try await authorizer.storePastedToken("pasted_abc", serverId: UUID(), uid: "u1")
        }
    }

    @Test("DCR registration cannot be written to secure storage → throws instead of opening the browser with an unsaved registration")
    func registrationFailsWhenStorageFails() async throws {
        let transport = FakeMcpAuthTransport()
        try stubProtectedResource(transport)
        try stubDCR(transport)
        let storage = InMemoryMcpCredentialStorage()
        let browser = FakeMcpBrowserSession()
        browser.callbackBuilder = echoingCallback
        let (authorizer, _) = makeAuthorizer(transport: transport, browser: browser, storage: storage)
        let plan = try await readyPlan(authorizer)

        storage.failWrites = true
        await #expect(throws: McpAuthorizerError.credentialPersistenceFailed) {
            _ = try await authorizer.authorize(plan: plan, serverId: UUID(), uid: "u1")
        }
        #expect(browser.openedURLs.isEmpty)
    }

    @Test("Signing in again replaces only the OAuth fields; a previously pasted token is kept")
    func reauthorizationKeepsPastedToken() async throws {
        let transport = FakeMcpAuthTransport()
        let (authorizer, store, attempt) = try await makeCIMDAttempt(transport: transport)
        let serverId = UUID()
        try await authorizer.storePastedToken("pasted_abc", serverId: serverId, uid: "u1")
        let callback = try #require(URL(string: "oriveo://mcp/oauth/callback?code=ac_123&state=st_test&iss=https://auth.example.com"))
        _ = try await authorizer.completeAuthorization(attempt: attempt, callbackURL: callback, serverId: serverId, uid: "u1")
        let stored = try #require(store.load(serverId: serverId, uid: "u1"))
        #expect(stored.accessToken == "mcp_at_example")
        #expect(stored.pastedToken == "pasted_abc")
    }

    // MARK: Token response

    @Test("Token response: a non-Bearer type is not used as Bearer; a non-positive lifetime counts as absent; an empty refresh token counts as none; an absurd lifetime is capped")
    func tokenResponseValidation() throws {
        func parse(_ text: String) throws -> McpTokenResponse? { McpTokenResponse(json: try JSONValue(parsing: text)) }
        #expect(try parse(#"{"access_token":"a","token_type":"DPoP"}"#) == nil)
        #expect(try parse(#"{"access_token":"","token_type":"Bearer"}"#) == nil)
        #expect(try parse(#"{"access_token":"a","token_type":"bearer"}"#)?.accessToken == "a")
        #expect(try parse(#"{"access_token":"a"}"#)?.accessToken == "a")
        #expect(try parse(#"{"access_token":"a","expires_in":0}"#)?.expiresIn == nil)
        #expect(try parse(#"{"access_token":"a","expires_in":-5}"#)?.expiresIn == nil)
        #expect(try parse(#"{"access_token":"a","refresh_token":""}"#)?.refreshToken == nil)
        #expect(try parse(#"{"access_token":"a","expires_in":1e30}"#)?.expiresIn == McpTokenResponse.maxExpiresIn)
    }

    @Test("Token exchange returning a non-Bearer token → tokenRequestFailed, nothing stored")
    func nonBearerTokenIsNotStored() async throws {
        let transport = FakeMcpAuthTransport()
        let (authorizer, store, attempt) = try await makeCIMDAttempt(transport: transport)
        transport.stub(status: 200, raw: #"{"access_token":"dpop_token","token_type":"DPoP"}"#, at: tokenURL)
        let callback = try #require(URL(string: "oriveo://mcp/oauth/callback?code=ac_123&state=st_test&iss=https://auth.example.com"))
        let serverId = UUID()
        await #expect(throws: McpAuthorizerError.tokenRequestFailed) {
            _ = try await authorizer.completeAuthorization(attempt: attempt, callbackURL: callback, serverId: serverId, uid: "u1")
        }
        #expect(store.load(serverId: serverId, uid: "u1") == nil)
    }

    // MARK: Redaction

    @Test("Objects produced by the authorization flow never expose verifier / state / authorization code / tokens / client_id in their descriptions")
    func authorizationTypesAreRedacted() async throws {
        let transport = FakeMcpAuthTransport()
        try stubProtectedResource(transport)
        try stubDCR(transport)
        try stubToken(transport, "token.success.json")
        let (authorizer, _) = makeAuthorizer(transport: transport)

        // Everything comes from the production path: discovery → registration → building the authorization request →
        // the form actually sent for the token exchange → the parsed token response.
        let plan = try await readyPlan(authorizer)
        let registration = try await authorizer.register(plan: plan, uid: "u1")
        let attempt = try await authorizer.beginAuthorization(
            plan: plan, uid: "u1", state: "st_secret_state", codeVerifier: "verifier_secret_value"
        )
        let callback = try #require(URL(string: "oriveo://mcp/oauth/callback?code=ac_secret_code&state=st_secret_state"))
        let credentials = try await authorizer.completeAuthorization(attempt: attempt, callbackURL: callback, serverId: UUID(), uid: "u1")
        let sentForm = try #require(transport.formRequests.first?.form)
        let tokenBody = try #require(try authFixture("token.success.json")["body"])
        let tokens = try #require(McpTokenResponse(json: tokenBody))

        let secrets = [
            "st_secret_state", "verifier_secret_value", "ac_secret_code", "oriveo_mcp_2f9c41",
            "mcp_at_example", "mcp_rt_example", McpPKCE.codeChallenge(forVerifier: "verifier_secret_value"),
        ]
        // Precondition: these objects really carry the secrets (otherwise the "does not contain" checks below prove nothing).
        #expect(attempt.codeVerifier == "verifier_secret_value")
        #expect(attempt.request.url.absoluteString.contains("st_secret_state"))
        #expect(registration.clientID == "oriveo_mcp_2f9c41")
        #expect(sentForm.contains { $0.value == "ac_secret_code" })
        #expect(sentForm.contains { $0.value == "verifier_secret_value" })
        #expect(tokens.accessToken == "mcp_at_example")

        let subjects: [Any] = [attempt, attempt.request, registration, plan, tokens, sentForm, credentials,
                               McpAuthDiscoveryOutcome.ready(plan), Optional(attempt) as Any]
        for subject in subjects {
            for text in [String(describing: subject), String(reflecting: subject), "\(subject)"] {
                for secret in secrets {
                    #expect(!text.contains(secret), Comment(rawValue: "\(type(of: subject)) leaks \(secret)"))
                }
            }
        }
        // Non-secret fields stay readable for troubleshooting.
        #expect(String(describing: attempt).contains("https://auth.example.com"))
        #expect(String(describing: attempt.request).contains("https://auth.example.com/authorize"))
        #expect(String(describing: sentForm).contains("code_verifier"))
    }

    // MARK: Internals

    /// Runs `beginAuthorization` once with the CIMD fixture and returns a reusable attempt (state = st_test).
    private func makeCIMDAttempt(
        transport: FakeMcpAuthTransport
    ) async throws -> (McpAuthorizer, McpCredentialStore, McpAuthorizationAttempt) {
        try stubProtectedResource(transport)
        try stubAuthorizationServer(transport, "authorization-server-metadata.cimd.json")
        try stubToken(transport, "token.success.json")
        let (authorizer, store) = makeAuthorizer(transport: transport)
        let attempt = try await authorizer.beginAuthorization(
            plan: try await readyPlan(authorizer),
            uid: "u1",
            redirectURI: iosRedirectURI,
            state: "st_test",
            codeVerifier: "verifier_test"
        )
        return (authorizer, store, attempt)
    }
}
