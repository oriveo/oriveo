import Foundation
import Testing
@testable import Oriveo

// MARK: - Remote MCP protocol client
//
// Mostly fixture replay: `shared/test-fixtures/mcp/protocol/` is the single source of truth. The iOS test
// process cannot launch Node,
// so the same fixtures are replayed through URLProtocol (see `McpClientTestSupport.swift`).

private let mcpEndpoint = URL(string: "https://mcp.example.com/mcp")!

private func makeClient(runtimeConfig: McpRuntimeConfig = .fallback) -> McpClient {
    McpClient(endpoint: mcpEndpoint, runtimeConfig: runtimeConfig, session: McpScriptedURLProtocol.session())
}

private func jsonStub(
    _ json: String,
    status: Int = 200,
    delay: TimeInterval = 0,
    errorCode: URLError.Code? = nil
) -> McpScriptedURLProtocol.Stub {
    McpScriptedURLProtocol.Stub(
        status: status,
        headers: ["Content-Type": "application/json"],
        body: Data(json.utf8),
        delay: delay,
        errorCode: errorCode
    )
}

private func emptyBodyStub(status: Int) -> McpScriptedURLProtocol.Stub {
    McpScriptedURLProtocol.Stub(status: status, headers: ["Content-Type": "application/json"], body: Data())
}

/// A connected client on the modern revision: probes with `tools/list`, then replays `stubs` in order.
private func connectedModernClient(
    stubs: [McpScriptedURLProtocol.Stub],
    runtimeConfig: McpRuntimeConfig = .fallback
) async throws -> McpClient {
    McpScriptedURLProtocol.reset()
    try McpScriptedURLProtocol.enqueue(McpClientFixture.stub("protocol/stateless/tools-list.response.json"))
    McpScriptedURLProtocol.enqueue(stubs)
    let client = makeClient(runtimeConfig: runtimeConfig)
    let outcome = await client.connect()
    _ = try #require(outcome.session)
    return client
}

/// A connected client on the legacy revision: the modern probe gets a 400 with an empty body, then falls back to `initialize`.
private func connectedLegacyClient(
    stubs: [McpScriptedURLProtocol.Stub],
    runtimeConfig: McpRuntimeConfig = .fallback
) async throws -> McpClient {
    McpScriptedURLProtocol.reset()
    McpScriptedURLProtocol.enqueue(emptyBodyStub(status: 400))
    try McpScriptedURLProtocol.enqueue(McpClientFixture.stub("protocol/session/initialize.response.json"))
    McpScriptedURLProtocol.enqueue(stubs)
    let client = makeClient(runtimeConfig: runtimeConfig)
    let outcome = await client.connect()
    _ = try #require(outcome.session)
    return client
}

private let weatherArguments = JSONValue.object(JSONObject([("location", .string("New York"))]))

private let renewedSessionID = "renewed-session-0f9e8d7c6b5a"

/// On re-handshake the server issues a **different** session id; replaying the same one would make it
/// impossible to tell whether the new session was written back.
private func renewedInitializeStub() throws -> McpScriptedURLProtocol.Stub {
    var stub = try McpClientFixture.stub("protocol/session/initialize.response.json")
    stub.headers["MCP-Session-Id"] = renewedSessionID
    return stub
}

@Suite("MCP protocol client", .serialized)
struct McpClientTests {

    // MARK: Full replay of both protocol generations

    @Test("Modern: full replay of probe → tools/list → tools/call")
    func modernRoundTrip() async throws {
        McpScriptedURLProtocol.reset()
        try McpScriptedURLProtocol.enqueue([
            McpClientFixture.stub("protocol/stateless/tools-list.response.json"),
            McpClientFixture.stub("protocol/stateless/tools-list.response.json"),
            McpClientFixture.stub("protocol/stateless/tools-call.response.json"),
        ])
        let client = makeClient()

        let outcome = await client.connect()
        let session = try #require(outcome.session)
        #expect(session.generation == .stateless)
        #expect(session.protocolVersion == "2026-07-28")

        let tools = try await client.listTools()
        #expect(tools.map(\.name) == ["get_weather", "create_issue"])
        #expect(tools.first?.displayTitle == "Weather Information Provider")
        #expect(tools.first?.readOnly == true)

        let result = try await client.callTool(name: "get_weather", arguments: weatherArguments)
        #expect(result.isError == false)
        #expect(result.text.contains("72°F"))
        #expect(result.truncated == false)
        #expect(result.errorCode == nil)

        let probe = try #require(McpScriptedURLProtocol.requests(method: "tools/list").first)
        #expect(probe.header("Mcp-Method") == "tools/list")
        #expect(probe.header("Mcp-Name") == nil)
        #expect(probe.header("MCP-Protocol-Version") == "2026-07-28")
        #expect(probe.header("Accept") == "application/json, text/event-stream")

        let call = try #require(McpScriptedURLProtocol.requests(method: "tools/call").first)
        #expect(call.header("Mcp-Method") == "tools/call")
        #expect(call.header("Mcp-Name") == "get_weather")
        #expect(call.header("MCP-Protocol-Version") == "2026-07-28")
        #expect(call.header("Accept") == "application/json, text/event-stream")
        #expect(call.header("Authorization") == nil)
    }

    @Test("Legacy: full replay of empty-body 400 falling back to initialize → tools/list → tools/call")
    func legacyRoundTrip() async throws {
        McpScriptedURLProtocol.reset()
        McpScriptedURLProtocol.enqueue(emptyBodyStub(status: 400))
        try McpScriptedURLProtocol.enqueue([
            McpClientFixture.stub("protocol/session/initialize.response.json"),
            McpClientFixture.stub("protocol/session/tools-list.response.json"),
            McpClientFixture.stub("protocol/session/tools-call.response.json"),
        ])
        let client = makeClient()

        let outcome = await client.connect(bearerToken: "mcp_at_example")
        let session = try #require(outcome.session)
        #expect(session.generation == .session)
        #expect(session.protocolVersion == "2025-11-25")
        #expect(session.sessionId == "c1f2a3b4d5e60718293a4b5c6d7e8f90")

        let tools = try await client.listTools()
        #expect(tools.map(\.name) == ["get_weather", "create_issue"])

        let result = try await client.callTool(name: "get_weather", arguments: weatherArguments)
        #expect(result.isError == false)
        #expect(result.text.contains("72°F"))

        let initialize = try #require(McpScriptedURLProtocol.requests(method: "initialize").first)
        #expect(initialize.header("MCP-Protocol-Version") == nil)

        let call = try #require(McpScriptedURLProtocol.requests(method: "tools/call").first)
        #expect(call.header("MCP-Protocol-Version") == "2025-11-25")
        #expect(call.header("MCP-Session-Id") == "c1f2a3b4d5e60718293a4b5c6d7e8f90")
        #expect(call.header("Mcp-Method") == nil)
        #expect(call.header("Mcp-Name") == nil)
        #expect(call.header("Authorization") == "Bearer mcp_at_example")

        let list = try #require(McpScriptedURLProtocol.requests(method: "tools/list").last)
        #expect(list.header("MCP-Session-Id") == "c1f2a3b4d5e60718293a4b5c6d7e8f90")
    }

    // MARK: Era detection state machine

    @Test("Era detection: 400 + -32022 means modern; retry with a supported version, no fallback to initialize")
    func unsupportedVersionDoesNotFallback() async throws {
        McpScriptedURLProtocol.reset()
        try McpScriptedURLProtocol.enqueue([
            McpClientFixture.stub("protocol/stateless/error.unsupported-protocol-version.json"),
            McpClientFixture.stub("protocol/stateless/tools-list.response.json"),
        ])
        let client = makeClient()

        let outcome = await client.connect()
        let session = try #require(outcome.session)
        #expect(session.generation == .stateless)
        #expect(session.protocolVersion == "2026-07-28")
        #expect(McpScriptedURLProtocol.requests(method: "initialize").isEmpty)
        #expect(McpScriptedURLProtocol.requests(method: "tools/list").count == 2)
        let retry = try #require(McpScriptedURLProtocol.requests(method: "tools/list").last)
        #expect(retry.header("MCP-Protocol-Version") == "2026-07-28")
    }

    @Test("Era detection: 400 + -32020 means modern; no fallback, reports server_error")
    func headerMismatchDoesNotFallback() async throws {
        McpScriptedURLProtocol.reset()
        try McpScriptedURLProtocol.enqueue(McpClientFixture.stub("protocol/stateless/error.header-mismatch.json"))
        let client = makeClient()

        let outcome = await client.connect()
        guard case .failed(let error) = outcome else {
            Issue.record("expected failed, got \(outcome)")
            return
        }
        #expect(error.code == .serverError)
        #expect(error.detail != nil)
        #expect(McpScriptedURLProtocol.requests(method: "initialize").isEmpty)
    }

    @Test("Era detection: 400 + -32021 means modern; no fallback")
    func missingCapabilityDoesNotFallback() async throws {
        McpScriptedURLProtocol.reset()
        try McpScriptedURLProtocol.enqueue(McpClientFixture.stub("protocol/stateless/error.missing-required-capability.json"))
        let client = makeClient()

        let outcome = await client.connect()
        guard case .failed(let error) = outcome else {
            Issue.record("expected failed, got \(outcome)")
            return
        }
        #expect(error.code == .serverError)
        #expect(McpScriptedURLProtocol.requests(method: "initialize").isEmpty)
    }

    @Test("Era detection: 400 + empty body falls back to initialize")
    func empty400FallsBackToInitialize() async throws {
        McpScriptedURLProtocol.reset()
        McpScriptedURLProtocol.enqueue(emptyBodyStub(status: 400))
        try McpScriptedURLProtocol.enqueue(McpClientFixture.stub("protocol/session/initialize.response.json"))
        let client = makeClient()

        let outcome = await client.connect()
        let session = try #require(outcome.session)
        #expect(session.generation == .session)
        #expect(McpScriptedURLProtocol.requests(method: "initialize").count == 1)
    }

    @Test("Era detection: 400 + generic -32602 (no modern marker) falls back to initialize and is not mistaken for modern")
    func legacyGenericErrorFallsBackToInitialize() async throws {
        // Fixture protocol/shared/error.legacy-before-initialize.json:
        // the generic -32602 a legacy server returns when it receives tools/list before initialize
        // ("Received request before initialization was complete"), without any modern marker.
        McpScriptedURLProtocol.reset()
        try McpScriptedURLProtocol.enqueue(McpClientFixture.stub("protocol/shared/error.legacy-before-initialize.json"))
        try McpScriptedURLProtocol.enqueue(McpClientFixture.stub("protocol/session/initialize.response.json"))
        let client = makeClient()

        let outcome = await client.connect()
        let session = try #require(outcome.session)
        #expect(session.generation == .session)
        #expect(session.protocolVersion == "2025-11-25")
        #expect(McpScriptedURLProtocol.requests(method: "initialize").count == 1)
    }

    @Test("Era detection: 400 + -32602 (not one of the three specific codes) is modern as well; no fallback")
    func invalidParamsDoesNotFallback() async throws {
        McpScriptedURLProtocol.reset()
        try McpScriptedURLProtocol.enqueue(McpClientFixture.stub("protocol/shared/error.invalid-params.json"))
        let client = makeClient()

        let outcome = await client.connect()
        guard case .failed(let error) = outcome else {
            Issue.record("expected failed, got \(outcome)")
            return
        }
        #expect(error.code == .serverError)
        #expect(McpScriptedURLProtocol.requests(method: "initialize").isEmpty)
    }

    @Test("Era detection: 404 + -32601 means modern; no fallback")
    func methodNotFoundDoesNotFallback() async throws {
        McpScriptedURLProtocol.reset()
        try McpScriptedURLProtocol.enqueue(McpClientFixture.stub("protocol/shared/error.method-not-found.json"))
        let client = makeClient()

        let outcome = await client.connect()
        guard case .failed(let error) = outcome else {
            Issue.record("expected failed, got \(outcome)")
            return
        }
        #expect(error.code == .serverError)
        #expect(McpScriptedURLProtocol.requests(method: "initialize").isEmpty)
    }

    @Test("All four non-MCP responses are classified as not_mcp without falling back to initialize")
    func notMcpResponses() async throws {
        for (caseId, stub) in try McpClientFixture.notMcpCases() {
            McpScriptedURLProtocol.reset()
            McpScriptedURLProtocol.enqueue(stub)
            let client = makeClient()
            let outcome = await client.connect()
            #expect(outcome == .notMcp, Comment(rawValue: caseId))
            #expect(McpScriptedURLProtocol.requests(method: "initialize").isEmpty, Comment(rawValue: caseId))
        }
    }

    // MARK: SSE (one case per generation)

    @Test("SSE: modern tools/call response parsing (with a notification in between)")
    func modernSSECall() async throws {
        let sse = try McpClientFixture.sse("protocol/stateless/tools-call.sse.txt")
        let client = try await connectedModernClient(stubs: [
            McpScriptedURLProtocol.Stub(status: 200, headers: ["Content-Type": "text/event-stream"], body: sse),
        ])
        let result = try await client.callTool(name: "get_weather", arguments: weatherArguments)
        #expect(result.isError == false)
        #expect(result.text.contains("72°F"))
    }

    @Test("SSE: legacy tools/call response parsing (a missing resultType is not a failure)")
    func legacySSECall() async throws {
        let sse = try McpClientFixture.sse("protocol/session/tools-call.sse.txt")
        let client = try await connectedLegacyClient(stubs: [
            McpScriptedURLProtocol.Stub(status: 200, headers: ["Content-Type": "text/event-stream"], body: sse),
        ])
        let result = try await client.callTool(name: "get_weather", arguments: weatherArguments)
        #expect(result.isError == false)
        #expect(result.text.contains("72°F"))
    }

    // MARK: Pagination

    @Test("tools/list follows nextCursor to the last page")
    func paginationFollowsCursor() async throws {
        let page1 = #"{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"a","inputSchema":{}}],"nextCursor":"p2"}}"#
        let page2 = #"{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"b","inputSchema":{}}]}}"#
        let client = try await connectedModernClient(stubs: [jsonStub(page1), jsonStub(page2)])

        let tools = try await client.listTools()
        #expect(tools.map(\.name) == ["a", "b"])
        let listRequests = McpScriptedURLProtocol.requests(method: "tools/list")
        #expect(listRequests.count == 3) // probe + 2 pages
        #expect(listRequests[2].bodyText?.contains("\"cursor\":\"p2\"") == true)
    }

    @Test("tools/list beyond 20 pages is a failure")
    func paginationFailsAfterTwentyPages() async throws {
        let cursorPage = #"{"jsonrpc":"2.0","id":2,"result":{"tools":[],"nextCursor":"more"}}"#
        McpScriptedURLProtocol.reset()
        try McpScriptedURLProtocol.enqueue(McpClientFixture.stub("protocol/stateless/tools-list.response.json"))
        McpScriptedURLProtocol.setFallback(jsonStub(cursorPage))
        let client = makeClient()
        _ = try #require((await client.connect()).session)

        do {
            _ = try await client.listTools()
            Issue.record("more than 20 pages should fail")
        } catch let error as McpClientError {
            #expect(error.code == .serverError)
        }
        #expect(McpScriptedURLProtocol.requests(method: "tools/list").count == 21) // probe + 20 pages
    }

    // MARK: Timeouts and network errors

    @Test("A timeout maps to timeout (using callTimeoutSeconds)")
    func callTimeoutMapsToTimeout() async throws {
        let body = #"{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"late"}]}}"#
        let client = try await connectedModernClient(
            stubs: [jsonStub(body, delay: 1.0)],
            runtimeConfig: McpRuntimeConfig(callTimeoutSeconds: 0.2)
        )
        do {
            _ = try await client.callTool(name: "get_weather", arguments: weatherArguments)
            Issue.record("timeout expected")
        } catch let error as McpClientError {
            #expect(error.code == .timeout)
        }
    }

    @Test("A network-level failure maps to unreachable")
    func networkFailureMapsToUnreachable() async throws {
        let client = try await connectedModernClient(stubs: [.init(errorCode: .cannotConnectToHost)])
        do {
            _ = try await client.callTool(name: "get_weather", arguments: weatherArguments)
            Issue.record("failure expected")
        } catch let error as McpClientError {
            #expect(error.code == .unreachable)
        }
    }

    @Test("Network-level failure during the probe → unreachable, era detection is not retried")
    func probeNetworkFailureIsUnreachable() async throws {
        McpScriptedURLProtocol.reset()
        McpScriptedURLProtocol.enqueue(.init(errorCode: .cannotConnectToHost))
        let client = makeClient()

        let outcome = await client.connect()
        #expect(outcome == .unreachable)
        #expect(McpScriptedURLProtocol.requests(method: "tools/list").count == 1)
        #expect(McpScriptedURLProtocol.requests(method: "initialize").isEmpty)
    }

    // MARK: Result trimming

    @Test("Result trimming: text items are concatenated and non-text items become placeholders")
    func trimmingTextAndPlaceholder() async throws {
        let body = #"{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"hello "},{"type":"image","data":"x"},{"type":"text","text":"world"}]}}"#
        let client = try await connectedModernClient(stubs: [jsonStub(body)])
        let result = try await client.callTool(name: "get_weather", arguments: weatherArguments)
        #expect(result.text == "hello [non-text content: image]world")
        #expect(result.truncated == false)
    }

    @Test("Result trimming: empty text falls back to the JSON text of structuredContent")
    func trimmingStructuredContentFallback() async throws {
        let body = #"{"jsonrpc":"2.0","id":3,"result":{"resultType":"complete","content":[],"structuredContent":{"temperature":22.5,"conditions":"Partly cloudy"}}}"#
        let client = try await connectedModernClient(stubs: [jsonStub(body)])
        let result = try await client.callTool(name: "get_weather", arguments: weatherArguments)
        #expect(result.text == #"{"temperature":22.5,"conditions":"Partly cloudy"}"#)
        #expect(result.structuredContent != nil)
        #expect(result.truncated == false)
    }

    @Test("Result trimming: text beyond maxResultChars is truncated and marked at the end")
    func trimmingTruncatesAndMarks() async throws {
        let longText = String(repeating: "x", count: 200)
        let body = #"{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"\#(longText)"}]}}"#
        let client = try await connectedModernClient(
            stubs: [jsonStub(body)],
            runtimeConfig: McpRuntimeConfig(maxResultChars: 30)
        )
        let result = try await client.callTool(name: "get_weather", arguments: weatherArguments)
        #expect(result.truncated == true)
        #expect(result.text.count == 30)
        #expect(result.text.hasSuffix(McpClientLimits.truncationMarker))
        #expect(result.errorCode == .resultTooLarge)
        #expect(result.isError == false)
    }

    // MARK: Tool execution errors and MRTR

    @Test("isError: true → tool_error, not a JSON-RPC error")
    func isErrorMapsToToolError() async throws {
        let client = try await connectedModernClient(stubs: [
            try McpClientFixture.stub("protocol/shared/tools-call.is-error.response.json"),
        ])
        let result = try await client.callTool(name: "get_weather", arguments: weatherArguments)
        #expect(result.isError == true)
        #expect(result.errorCode == .toolError)
        #expect(result.text.contains("Invalid departure date"))
    }

    @Test("input_required (MRTR) → needs_input_unsupported")
    func inputRequiredMapsToNeedsInputUnsupported() async throws {
        let client = try await connectedModernClient(stubs: [
            try McpClientFixture.stub("protocol/shared/tools-call.input-required.response.json"),
        ])
        let result = try await client.callTool(name: "get_weather", arguments: weatherArguments)
        #expect(result.errorCode == .needsInputUnsupported)
    }

    @Test("Unknown tool (-32602) → tool_error")
    func unknownToolMapsToToolError() async throws {
        let client = try await connectedModernClient(stubs: [
            try McpClientFixture.stub("protocol/session/error.unknown-tool.json"),
        ])
        do {
            _ = try await client.callTool(name: "invalid_tool_name", arguments: .object(JSONObject()))
            Issue.record("failure expected")
        } catch let error as McpClientError {
            #expect(error.code == .toolError)
        }
    }

    // MARK: Retry discipline

    @Test("tools/call is never retried automatically once sent")
    func toolsCallIsNotRetried() async throws {
        let client = try await connectedModernClient(stubs: [.init(errorCode: .cannotConnectToHost)])
        let before = McpScriptedURLProtocol.requests(method: "tools/call").count
        do {
            _ = try await client.callTool(name: "get_weather", arguments: weatherArguments)
            Issue.record("failure expected")
        } catch let error as McpClientError {
            #expect(error.code == .unreachable)
        }
        #expect(McpScriptedURLProtocol.requests(method: "tools/call").count == before + 1)
    }

    @Test("Network error before the connection is established: tools/list is retried once")
    func listRetriesOnceOnPreConnectError() async throws {
        let client = try await connectedModernClient(stubs: [
            .init(errorCode: .cannotConnectToHost),
            try McpClientFixture.stub("protocol/stateless/tools-list.response.json"),
        ])
        let tools = try await client.listTools()
        #expect(tools.count == 2)
        // 1 probe + 1 retry after listTools failed
        #expect(McpScriptedURLProtocol.requests(method: "tools/list").count == 3)
    }

    // MARK: Legacy session termination

    @Test("Legacy session termination: after a 404 on tools/list, initialize once more and retry; the new session is written back and used for later calls")
    func sessionTerminatedReinitializesOnList() async throws {
        McpScriptedURLProtocol.reset()
        McpScriptedURLProtocol.enqueue(emptyBodyStub(status: 400))
        try McpScriptedURLProtocol.enqueue([
            McpClientFixture.stub("protocol/session/initialize.response.json"),
            McpClientFixture.stub("protocol/session/error.session-terminated.json"),
            renewedInitializeStub(),
            McpClientFixture.stub("protocol/session/tools-list.response.json"),
            McpClientFixture.stub("protocol/session/tools-call.response.json"),
        ])
        let client = makeClient()
        let first = try #require((await client.connect()).session)
        #expect(first.sessionId == "c1f2a3b4d5e60718293a4b5c6d7e8f90")

        let tools = try await client.listTools()
        #expect(tools.count == 2)
        let initializes = McpScriptedURLProtocol.requests(method: "initialize")
        #expect(initializes.count == 2)
        #expect(initializes[1].header("MCP-Session-Id") == nil)

        // The rebuilt session must be written back: later requests carry the new session id, not the one the server terminated.
        #expect(await client.session?.sessionId == renewedSessionID)
        let lists = McpScriptedURLProtocol.requests(method: "tools/list")
        #expect(lists.last?.header("MCP-Session-Id") == renewedSessionID)

        _ = try await client.callTool(name: "get_weather", arguments: weatherArguments)
        let call = try #require(McpScriptedURLProtocol.requests(method: "tools/call").first)
        #expect(call.header("MCP-Session-Id") == renewedSessionID)

        // After the re-handshake the initialized notification is sent again, with the new session id.
        let initialized = McpScriptedURLProtocol.requests(method: "notifications/initialized")
        #expect(initialized.count == 2)
        #expect(initialized.last?.header("MCP-Session-Id") == renewedSessionID)
    }

    @Test("Legacy session termination: after a 404 on tools/call the session is restored but the call is not replayed")
    func sessionTerminatedOnCallDoesNotReplay() async throws {
        let client = try await connectedLegacyClient(stubs: [
            try McpClientFixture.stub("protocol/session/error.session-terminated.json"),
            try renewedInitializeStub(),
            try McpClientFixture.stub("protocol/session/tools-call.response.json"),
        ])
        do {
            _ = try await client.callTool(name: "get_weather", arguments: weatherArguments)
            Issue.record("a call on a terminated session should fail")
        } catch let error as McpClientError {
            #expect(error.code == .serverError)
        }
        #expect(McpScriptedURLProtocol.requests(method: "tools/call").count == 1, "must not be replayed automatically")
        #expect(await client.session?.sessionId == renewedSessionID)

        _ = try await client.callTool(name: "get_weather", arguments: weatherArguments)
        #expect(McpScriptedURLProtocol.requests(method: "tools/call").last?.header("MCP-Session-Id") == renewedSessionID)
    }

    // MARK: Classifying the fallback handshake

    @Test("Fallback initialize answered with 401 → needsAuth, and the challenge is recorded")
    func initializeUnauthorizedNeedsAuth() async throws {
        let fixture = try McpFixture.json("auth/401.www-authenticate.json")
        let header = try #require(fixture["headers"]?["WWW-Authenticate"]?.stringValue)
        McpScriptedURLProtocol.reset()
        McpScriptedURLProtocol.enqueue(emptyBodyStub(status: 400))
        McpScriptedURLProtocol.enqueue(.init(status: 401, headers: ["WWW-Authenticate": header]))
        let client = makeClient()

        #expect(await client.connect() == .needsAuth)
        let challenge = try #require(await client.authChallenge)
        #expect(challenge.resourceMetadata?.absoluteString == fixture["expect"]?["resourceMetadataURL"]?.stringValue)
        #expect(challenge.scope == fixture["expect"]?["scope"]?.stringValue)
    }

    @Test("Ordinary website: modern probe gets 400 and the fallback handshake fails too → notMcp, not unreachable")
    func ordinaryWebsiteIsNotMcp() async throws {
        let html = McpScriptedURLProtocol.Stub(
            status: 400, headers: ["Content-Type": "text/html"], body: Data("<h1>Bad Request</h1>".utf8)
        )
        for second in [html, emptyBodyStub(status: 404), jsonStub(#"{"ok":true}"#)] {
            McpScriptedURLProtocol.reset()
            McpScriptedURLProtocol.enqueue([html, second])
            let client = makeClient()
            #expect(await client.connect() == .notMcp)
            #expect(McpScriptedURLProtocol.requests(method: "initialize").count == 1)
        }
    }

    @Test("Fallback handshake: another JSON-RPC service that does not know initialize (-32601) → notMcp")
    func foreignJSONRPCServiceIsNotMcp() async throws {
        McpScriptedURLProtocol.reset()
        McpScriptedURLProtocol.enqueue([
            jsonStub(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}"#, status: 400),
            jsonStub(#"{"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"Method not found"}}"#),
        ])
        let client = makeClient()
        #expect(await client.connect() == .notMcp)
    }

    @Test("Fallback handshake: an MCP server refusing the handshake (JSON-RPC error / unsupported version returned) → failed(server_error)")
    func rejectedHandshakeIsServerError() async throws {
        let refusals = [
            #"{"jsonrpc":"2.0","id":2,"error":{"code":-32603,"message":"Internal error"}}"#,
            #"{"jsonrpc":"2.0","id":2,"result":{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"Old","version":"1"}}}"#,
        ]
        for refusal in refusals {
            McpScriptedURLProtocol.reset()
            McpScriptedURLProtocol.enqueue([emptyBodyStub(status: 400), jsonStub(refusal)])
            let client = makeClient()
            guard case .failed(let error) = await client.connect() else {
                Issue.record("expected failed: \(refusal)")
                continue
            }
            #expect(error.code == .serverError)
            #expect(await client.session == nil)
        }
    }

    @Test("Probe returns 200 but the body is not a valid tools/list result → notMcp, not treated as connected")
    func probeRequiresRealToolsListResult() async throws {
        let bodies = [
            #"{"jsonrpc":"2.0","id":1,"result":{}}"#,
            #"{"jsonrpc":"2.0","id":1,"result":"ok"}"#,
            #"{"id":1,"result":{"tools":[]}}"#,
            #"{"result":{"tools":[]}}"#,
        ]
        for body in bodies {
            McpScriptedURLProtocol.reset()
            McpScriptedURLProtocol.enqueue(jsonStub(body))
            let client = makeClient()
            #expect(await client.connect() == .notMcp, Comment(rawValue: body))
            #expect(await client.session == nil)
        }
    }

    @Test("Probe returns 200 + a JSON-RPC error without a modern marker (some legacy servers do not answer 400) → falls back to initialize as well")
    func legacyErrorOn200FallsBack() async throws {
        McpScriptedURLProtocol.reset()
        McpScriptedURLProtocol.enqueue(
            jsonStub(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"Server not initialized"}}"#)
        )
        try McpScriptedURLProtocol.enqueue(McpClientFixture.stub("protocol/session/initialize.response.json"))
        let client = makeClient()
        let session = try #require((await client.connect()).session)
        #expect(session.generation == .session)
    }

    // MARK: Era detection markers

    @Test("Era detection: Mcp-Session-Id in a legacy server error message is not a modern marker; must fall back to initialize")
    func legacySessionHeaderMentionFallsBack() async throws {
        // This is how the legacy reference implementation answers a request without the session header.
        // `Mcp-Session-Id` is a legacy header, not a modern one.
        let messages = [
            "Bad Request: Mcp-Session-Id header is required",
            "Bad Request: MCP-Session-Id header is required",
            "Invalid or missing mcp-session-id",
        ]
        for message in messages {
            McpScriptedURLProtocol.reset()
            McpScriptedURLProtocol.enqueue(
                jsonStub(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32000,"message":"\#(message)"}}"#, status: 400)
            )
            try McpScriptedURLProtocol.enqueue(McpClientFixture.stub("protocol/session/initialize.response.json"))
            let client = makeClient()

            let session = try #require((await client.connect()).session, Comment(rawValue: message))
            #expect(session.generation == .session)
            #expect(McpScriptedURLProtocol.requests(method: "initialize").count == 1)
        }
    }

    @Test("Era detection: MCP-Protocol-Version in a legacy server error message is not a modern marker; must fall back to initialize")
    func legacyProtocolVersionHeaderMentionFallsBack() async throws {
        // Legacy servers use this header too (on every request after the handshake), so it shows up in their message
        // when they reject a version they do not know.
        let messages = [
            "Bad Request: Unsupported MCP-Protocol-Version header",
            "Invalid mcp-protocol-version: 2026-07-28",
            "Mcp-Protocol-Version header must be one of 2025-06-18, 2025-03-26",
        ]
        for message in messages {
            #expect(!McpProtocol.containsModernMarker(message), Comment(rawValue: message))
            McpScriptedURLProtocol.reset()
            McpScriptedURLProtocol.enqueue(
                jsonStub(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32000,"message":"\#(message)"}}"#, status: 400)
            )
            try McpScriptedURLProtocol.enqueue(McpClientFixture.stub("protocol/session/initialize.response.json"))
            let client = makeClient()

            let session = try #require((await client.connect()).session, Comment(rawValue: message))
            #expect(session.generation == .session)
            #expect(McpScriptedURLProtocol.requests(method: "initialize").count == 1)
        }
    }

    @Test("Era detection: a modern-only header name (Mcp-Method / Mcp-Name / Mcp-Param-) in the error message still means modern")
    func modernHeaderMentionDoesNotFallBack() async throws {
        let messages = [
            "Missing required header: Mcp-Method",
            "mcp-name does not match params.name",
            "Unexpected header Mcp-Param-Region",
        ]
        for message in messages {
            McpScriptedURLProtocol.reset()
            McpScriptedURLProtocol.enqueue(
                jsonStub(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"\#(message)"}}"#, status: 400)
            )
            let client = makeClient()
            guard case .failed(let error) = await client.connect() else {
                Issue.record("expected failed: \(message)")
                continue
            }
            #expect(error.code == .serverError)
            #expect(McpScriptedURLProtocol.requests(method: "initialize").isEmpty, Comment(rawValue: message))
        }
    }

    @Test("-32022 whose supported list has only legacy versions → no retry in the modern shape; handshake instead, using the highest version listed")
    func unsupportedVersionWithLegacyOnlyGoesToHandshake() async throws {
        let error = #"{"jsonrpc":"2.0","id":1,"error":{"code":-32022,"message":"Unsupported protocol version","data":{"supported":["2025-03-26","2025-06-18","2024-11-05"],"requested":"2026-07-28"}}}"#
        let initialized = #"{"jsonrpc":"2.0","id":2,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"Legacy","version":"1"}}}"#
        McpScriptedURLProtocol.reset()
        McpScriptedURLProtocol.enqueue([jsonStub(error, status: 400), jsonStub(initialized)])
        let client = makeClient()

        let session = try #require((await client.connect()).session)
        #expect(session.generation == .session)
        #expect(session.protocolVersion == "2025-06-18")
        #expect(session.serverName == "Legacy")

        // The retry is not the same request as the first one: the first is a modern-shaped tools/list, the retry is initialize.
        #expect(McpScriptedURLProtocol.requests(method: "tools/list").count == 1)
        let initialize = try #require(McpScriptedURLProtocol.requests(method: "initialize").first)
        #expect(initialize.json?["params"]?["protocolVersion"]?.stringValue == "2025-06-18")
        #expect(initialize.header("Mcp-Method") == nil)
        #expect(initialize.header("MCP-Protocol-Version") == nil)
    }

    @Test("-32022 whose supported list has no version we support → failed(server_error), no blind retry")
    func unsupportedVersionWithNothingInCommon() async throws {
        let error = #"{"jsonrpc":"2.0","id":1,"error":{"code":-32022,"message":"Unsupported protocol version","data":{"supported":["2027-01-01"]}}}"#
        McpScriptedURLProtocol.reset()
        McpScriptedURLProtocol.enqueue(jsonStub(error, status: 400))
        let client = makeClient()
        guard case .failed(let failure) = await client.connect() else {
            Issue.record("expected failed")
            return
        }
        #expect(failure.code == .serverError)
        #expect(McpScriptedURLProtocol.requests().count == 1)
    }

    // MARK: 403 insufficient_scope

    @Test("Fixture replay: tools/call answered with 403 insufficient_scope → needs_auth, and the scope from the challenge is recorded")
    func insufficientScopeOnCallNeedsAuth() async throws {
        let fixture = try McpFixture.json("auth/403.insufficient-scope.json")
        let client = try await connectedModernClient(stubs: [
            try McpClientFixture.stub("auth/403.insufficient-scope.json"),
        ])
        do {
            _ = try await client.callTool(name: "create_issue", arguments: .object(JSONObject()))
            Issue.record("failure expected")
        } catch let error as McpClientError {
            #expect(error.code.rawValue == fixture["expect"]?["errorCode"]?.stringValue)
        }
        let challenge = try #require(await client.authChallenge)
        #expect(challenge.error == "insufficient_scope")
        #expect(challenge.scope == "files:write")
        #expect(challenge.resourceMetadata?.absoluteString == "https://mcp.example.com/.well-known/oauth-protected-resource")
    }

    @Test("403 insufficient_scope on the probe and on tools/list is needsAuth as well; a plain 403 is not")
    func insufficientScopeOnProbeAndList() async throws {
        McpScriptedURLProtocol.reset()
        try McpScriptedURLProtocol.enqueue(McpClientFixture.stub("auth/403.insufficient-scope.json"))
        #expect(await makeClient().connect() == .needsAuth)

        let client = try await connectedModernClient(stubs: [
            try McpClientFixture.stub("auth/403.insufficient-scope.json"),
            emptyBodyStub(status: 403),
        ])
        await #expect(throws: McpClientError.make(.needsAuth)) { _ = try await client.listTools() }
        await #expect(throws: McpClientError.make(.serverError)) { _ = try await client.listTools() }
    }

    // MARK: Mcp-Name encoding

    @Test("Mcp-Name: a non-ASCII tool name is encoded as =?base64?…?= while the request body keeps the original name")
    func nonASCIIToolNameIsBase64Encoded() async throws {
        let body = #"{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"ok"}]}}"#
        let name = "날씨조회_ünï"
        let client = try await connectedModernClient(stubs: [jsonStub(body)])
        _ = try await client.callTool(name: name, arguments: weatherArguments)

        let call = try #require(McpScriptedURLProtocol.requests(method: "tools/call").first)
        let header = try #require(call.header("Mcp-Name"))
        #expect(header.hasPrefix("=?base64?"))
        #expect(header.hasSuffix("?="))
        #expect(header.unicodeScalars.allSatisfy { $0.isASCII })
        let encoded = String(header.dropFirst("=?base64?".count).dropLast("?=".count))
        let decoded = try #require(Data(base64Encoded: encoded))
        #expect(String(decoding: decoded, as: UTF8.self) == name)
        #expect(call.jsonRPCName == name)
    }

    @Test("Mcp-Name: visible ASCII is sent as is; leading/trailing whitespace, control characters and values that look like an encoded result are encoded")
    func headerValueEncodingRules() {
        #expect(McpClient.headerValue("get_weather") == "get_weather")
        #expect(McpClient.headerValue("a b.c-d/e") == "a b.c-d/e")
        for value in [" padded", "padded ", "tab\there", "line\nbreak", "=?base64?Zm9v?=", "é"] {
            let header = McpClient.headerValue(value)
            #expect(header.hasPrefix("=?base64?") && header.hasSuffix("?="), Comment(rawValue: value))
            let encoded = String(header.dropFirst("=?base64?".count).dropLast("?=".count))
            #expect(Data(base64Encoded: encoded).map { String(decoding: $0, as: UTF8.self) } == value)
        }
    }

    // MARK: Request fixture replay (headers and bodies sent by the production path)

    @Test("Request fixtures: modern tools/list (probe and actual fetch) and tools/call")
    func modernRequestsMatchFixtures() async throws {
        // In the fixtures tools/list has no Authorization and tools/call does, so two clients send one each.
        let anonymous = try await connectedModernClient(stubs: [
            try McpClientFixture.stub("protocol/stateless/tools-list.response.json"),
        ])
        _ = try await anonymous.listTools()
        let lists = McpScriptedURLProtocol.requests(method: "tools/list")
        #expect(lists.count == 2)
        for list in lists {
            #expect(try McpClientHarness.mismatches(list, fixture: "protocol/stateless/tools-list.request.json") == [])
        }

        McpScriptedURLProtocol.reset()
        try McpScriptedURLProtocol.enqueue([
            McpClientFixture.stub("protocol/stateless/tools-list.response.json"),
            McpClientFixture.stub("protocol/stateless/tools-call.response.json"),
        ])
        let authorized = makeClient()
        _ = try #require((await authorized.connect(bearerToken: "mcp_at_example")).session)
        _ = try await authorized.callTool(name: "get_weather", arguments: weatherArguments)
        let call = try #require(McpScriptedURLProtocol.requests(method: "tools/call").first)
        #expect(try McpClientHarness.mismatches(call, fixture: "protocol/stateless/tools-call.request.json") == [])

        // The two required `_meta` fields are checked by name, not just through the overall comparison.
        for request in lists + [call] {
            let meta = try #require(request.json?["params"]?["_meta"])
            #expect(meta["io.modelcontextprotocol/protocolVersion"]?.stringValue == request.header("MCP-Protocol-Version"))
            #expect(meta["io.modelcontextprotocol/clientCapabilities"]?.objectValue != nil)
            #expect(request.header("Mcp-Method") == request.jsonRPCMethod)
        }
    }

    @Test("Request fixtures: legacy initialize, initialized notification, tools/list, tools/call")
    func legacyRequestsMatchFixtures() async throws {
        McpScriptedURLProtocol.reset()
        McpScriptedURLProtocol.enqueue(emptyBodyStub(status: 400))
        try McpScriptedURLProtocol.enqueue([
            McpClientFixture.stub("protocol/session/initialize.response.json"),
            McpClientFixture.stub("protocol/session/tools-list.response.json"),
        ])
        let anonymous = makeClient()
        _ = try #require((await anonymous.connect()).session)
        _ = try await anonymous.listTools()

        let initialize = try #require(McpScriptedURLProtocol.requests(method: "initialize").first)
        #expect(try McpClientHarness.mismatches(initialize, fixture: "protocol/session/initialize.request.json") == [])
        let initialized = try #require(McpScriptedURLProtocol.requests(method: "notifications/initialized").first)
        #expect(try McpClientHarness.mismatches(initialized, fixture: "protocol/session/initialized.notification.json") == [])
        let list = try #require(McpScriptedURLProtocol.requests(method: "tools/list").last)
        #expect(try McpClientHarness.mismatches(list, fixture: "protocol/session/tools-list.request.json") == [])

        // Handshake order: initialize → initialized → other requests.
        let order = McpScriptedURLProtocol.requests().compactMap(\.jsonRPCMethod)
        #expect(order == ["tools/list", "initialize", "notifications/initialized", "tools/list"])

        McpScriptedURLProtocol.reset()
        McpScriptedURLProtocol.enqueue(emptyBodyStub(status: 400))
        try McpScriptedURLProtocol.enqueue([
            McpClientFixture.stub("protocol/session/initialize.response.json"),
            McpClientFixture.stub("protocol/session/tools-call.response.json"),
        ])
        let authorized = makeClient()
        _ = try #require((await authorized.connect(bearerToken: "mcp_at_example")).session)
        _ = try await authorized.callTool(name: "get_weather", arguments: weatherArguments)
        let call = try #require(McpScriptedURLProtocol.requests(method: "tools/call").first)
        #expect(try McpClientHarness.mismatches(call, fixture: "protocol/session/tools-call.request.json") == [])
    }

    @Test("The session id stays out of string descriptions")
    func sessionDescriptionIsRedacted() async throws {
        let client = try await connectedLegacyClient(stubs: [])
        let session = try #require(await client.session)
        #expect(session.sessionId == "c1f2a3b4d5e60718293a4b5c6d7e8f90")
        for text in [String(describing: session), String(reflecting: session), "\(McpConnectOutcome.connected(session))"] {
            #expect(!text.contains("c1f2a3b4d5e60718293a4b5c6d7e8f90"))
        }
    }

    // MARK: Cancellation

    @Test("Cancelling an in-flight tools/call → cancelled")
    func cancelInFlightCall() async throws {
        let body = #"{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"late"}]}}"#
        let client = try await connectedModernClient(stubs: [jsonStub(body, delay: 2.0)])

        let task = Task { try await client.callTool(name: "get_weather", arguments: weatherArguments) }
        try await Task.sleep(for: .milliseconds(100))
        await client.cancel()

        do {
            _ = try await task.value
            Issue.record("cancellation expected")
        } catch let error as McpClientError {
            #expect(error.code == .cancelled)
        }
    }
}
