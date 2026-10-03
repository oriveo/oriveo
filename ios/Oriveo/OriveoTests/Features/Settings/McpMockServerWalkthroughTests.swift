import Foundation
import Testing
@testable import Oriveo

// MARK: - Walkthrough against the local mock server
//
// The target is `shared/test-fixtures/mcp/mock-server.mjs` (Node, plain http on the loopback interface). The app
// currently accepts only `https://`, and the protocol client itself never sends a byte to a non-https address, so
// the real UI in the simulator cannot reach it. These tests go through a test seam instead: the UI model, the
// coordinator, the protocol client and the store are all production objects; the client sends to
// `https://mock.oriveo.test/mcp`, and a URLProtocol forwards each request unchanged to the mock server on the
// loopback port (a real HTTP round trip) and hands the response back unchanged.
//
// Not run by default: each test is enabled only when its port variable is set. To run them, start the mock server
// twice from the repository root,
//   node shared/test-fixtures/mcp/mock-server.mjs --mode=stateless --mutable-tools --port=<p1>
//   node shared/test-fixtures/mcp/mock-server.mjs --mode=token --port=<p2>
// then pass the ports to the test process (xcodebuild forwards `TEST_RUNNER_<NAME>` to it as `<NAME>`):
//   TEST_RUNNER_ORIVEO_MCP_MOCK_PORT=<p1> TEST_RUNNER_ORIVEO_MCP_MOCK_TOKEN_PORT=<p2> \
//     xcodebuild test -project ios/Oriveo/Oriveo.xcodeproj -scheme Oriveo \
//     -destination 'platform=iOS Simulator,name=iPhone 16' \
//     -only-testing:OriveoTests/McpMockServerWalkthroughTests

/// Forwards requests sent to `https://mock.oriveo.test` unchanged to the mock server on the loopback interface.
private final class LoopbackForwardingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var port = 0
    private var forwarding: URLSessionDataTask?

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "mock.oriveo.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let original = request.url,
              var components = URLComponents(url: original, resolvingAgainstBaseURL: false) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Self.port
        var forwarded = URLRequest(url: components.url!)
        forwarded.httpMethod = request.httpMethod
        forwarded.allHTTPHeaderFields = request.allHTTPHeaderFields
        forwarded.httpBody = request.httpBody ?? request.httpBodyStream.map(Self.read)
        forwarding = URLSession(configuration: .ephemeral).dataTask(with: forwarded) { [weak self] data, response, error in
            guard let self else { return }
            guard let http = response as? HTTPURLResponse, error == nil else {
                self.client?.urlProtocol(self, didFailWithError: error ?? URLError(.badServerResponse))
                return
            }
            let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, field in
                result["\(field.key)"] = "\(field.value)"
            }
            if let relayed = HTTPURLResponse(url: original, statusCode: http.statusCode, httpVersion: "HTTP/1.1", headerFields: headers) {
                self.client?.urlProtocol(self, didReceive: relayed, cacheStoragePolicy: .notAllowed)
            }
            if let data { self.client?.urlProtocol(self, didLoad: data) }
            self.client?.urlProtocolDidFinishLoading(self)
        }
        forwarding?.resume()
    }

    override func stopLoading() { forwarding?.cancel() }

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    static func session(port: Int) -> URLSession {
        Self.port = port
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LoopbackForwardingURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private func port(_ name: String) -> Int? {
    ProcessInfo.processInfo.environment[name].flatMap(Int.init)
}

@Suite("MCP mock server walkthrough (real network stack, run on demand)", .serialized)
@MainActor
struct McpMockServerWalkthroughTests {
    private func rig(port: Int) throws -> (McpUiRig, McpAddServerModel, McpServerActions) {
        let rig = try McpUiRig()
        let session = LoopbackForwardingURLProtocol.session(port: port)
        let makeClient: @Sendable (URL) -> McpClient = { McpClient(endpoint: $0, session: session) }
        let directory = rig.directory, credentials = rig.credentials, authorizer = rig.authorizer
        let model = McpAddServerModel(dependencies: .init(
            uid: McpUiFixture.uid,
            makeCoordinator: {
                let probe = McpAddProbe(authorizer: authorizer, credentialStore: credentials, makeClient: makeClient)
                return try directory.makeAddCoordinator(probe: probe, uid: McpUiFixture.uid)
            }
        ))
        let actions = McpServerActions(
            store: rig.store, credentialStore: credentials, uid: McpUiFixture.uid,
            authorizer: authorizer, makeClient: makeClient
        )
        return (rig, model, actions)
    }

    @Test(
        "Add (no sign-in) → review permissions → enable in a conversation → refresh tools on the management page (changes found and confirmed) → remove",
        .enabled(if: port("ORIVEO_MCP_MOCK_PORT") != nil)
    )
    func statelessServer() async throws {
        let (rig, model, actions) = try rig(port: try #require(port("ORIVEO_MCP_MOCK_PORT")))
        defer { rig.cleanUp() }

        // Add
        model.setURL("https://mock.oriveo.test/mcp")
        model.connect()
        await model.waitUntilSettled()
        guard case .review(let review) = model.state.screen else {
            Issue.record("did not reach the review-permissions page: \(model.state.screen)")
            return
        }
        #expect(!review.tools.isEmpty)
        model.finishReview()
        await model.waitUntilSettled()
        let serverId = try #require(model.state.completedServerId)
        let saved = try #require(try rig.store.fetchServer(id: serverId))
        #expect(try rig.store.fetchConnectionState(serverId: serverId)?.generation == .stateless)

        // Enable: the tools panel data and the send path share one assembly.
        let conversation = try rig.database.insertConversation().conversation
        try rig.store.setServerEnabled(true, conversationId: conversation, serverId: serverId)
        let panel = try McpToolPanelModel.load(
            conversationId: conversation, store: rig.store, credentialStore: rig.credentials,
            uid: McpUiFixture.uid, runtimeConfig: .fallback, availability: .available
        )
        #expect(panel.enabledServerCount == 1 && panel.outboundToolCount > 0)

        // Manage: refresh the tools. With `--mutable-tools` the tool list changes on every read.
        let refreshed = await actions.refreshTools(serverId: serverId)
        guard case .connected(let changes) = refreshed else {
            Issue.record("refreshing the tools did not connect: \(refreshed)")
            return
        }
        if !changes.isEmpty {
            #expect(try rig.directory.overview(uid: McpUiFixture.uid).first?.health == .needsReview)
            _ = await actions.confirmChanges(serverId: serverId)
        }
        #expect(try rig.store.fetchConnectionState(serverId: serverId)?.status == .connected)

        // Remove
        try rig.directory.remove(serverId: serverId, uid: McpUiFixture.uid)
        #expect(try rig.store.fetchServer(id: saved.id) == nil)
        #expect(try rig.database.nonEmptyTables().filter { $0.key != "mcp_conversation_switch" } == [:])
    }

    @Test(
        "Server that requires an access token: no token → access token required (authorization metadata discovery uses a fake transport that returns 404) → wrong token rejected → correct token adds the server",
        .enabled(if: port("ORIVEO_MCP_MOCK_TOKEN_PORT") != nil)
    )
    func tokenServer() async throws {
        let (rig, model, _) = try rig(port: try #require(port("ORIVEO_MCP_MOCK_TOKEN_PORT")))
        defer { rig.cleanUp() }
        model.setURL("https://mock.oriveo.test/mcp")
        model.connect()
        await model.waitUntilSettled()
        #expect(model.state.screen == .failure(.needsToken))

        model.setToken("wrong_token")
        model.connectWithToken()
        await model.waitUntilSettled()
        #expect(model.state.screen == .failure(.needsToken) && model.state.tokenRejected)

        model.setToken("mcp_test_token")
        model.connectWithToken()
        await model.waitUntilSettled()
        model.finishReview()
        await model.waitUntilSettled()
        let serverId = try #require(model.state.completedServerId)
        #expect(rig.credentials.load(serverId: serverId, uid: McpUiFixture.uid)?.pastedToken == "mcp_test_token")
        try rig.directory.remove(serverId: serverId, uid: McpUiFixture.uid)
        #expect(rig.credentials.load(serverId: serverId, uid: McpUiFixture.uid) == nil)
    }
}
