import Foundation
import Testing
@testable import Oriveo

// MARK: - Transport layer of the protocol client
//
// Redirects, https, byte limits, streaming SSE, strict id matching, cancellation, timeouts.
// Every assertion exercises the production path of `McpClient`: requests are sent by production code and
// answered by the URLProtocol replay layer,
// and what is asserted is the requests the replay layer actually received (or did not) and the error codes
// thrown by production code.

private typealias Harness = McpClientHarness
private typealias Scripted = McpScriptedURLProtocol

private let evilEndpoint = "https://evil.example/collect"

private func callError(
    _ client: McpClient,
    name: String = "get_weather"
) async -> McpErrorCode? {
    do {
        _ = try await client.callTool(name: name, arguments: Harness.weatherArguments)
        return nil
    } catch let error as McpClientError {
        return error.code
    } catch {
        return nil
    }
}

/// "Connection was cut" assertions match on a tool name unique to the test case: the connection of a previous
/// case may only be reclaimed by the system after this one has started,
/// and matching on the method name alone would let it pass for this one.
private func wasAborted(toolName: String) async -> Bool {
    await Harness.eventually {
        Scripted.abortedRequests().contains { $0.jsonRPCMethod == "tools/call" && $0.jsonRPCName == toolName }
    }
}

private func textResult(_ text: String) -> String {
    #"{"jsonrpc":"2.0","id":__REQUEST_ID__,"result":{"content":[{"type":"text","text":"\#(text)"}]}}"#
}

@Suite("MCP protocol client: transport layer", .serialized)
struct McpClientTransportTests {

    // MARK: Redirects

    @Test("Probe redirected by a 3xx to another origin → unreachable, the second host receives no request")
    func crossOriginRedirectOnConnectIsRejected() async throws {
        Scripted.reset()
        Scripted.enqueue(Harness.redirect(to: evilEndpoint))
        // Should the redirect be followed, the second host would return this success response, and the assertions
        // would fail on both the outcome and the request log.
        try Scripted.enqueue(McpClientFixture.stub("protocol/stateless/tools-list.response.json"))
        let client = Harness.client()

        let outcome = await client.connect(bearerToken: "mcp_at_example")
        #expect(outcome == .unreachable)
        let requests = Scripted.requests()
        #expect(requests.count == 1)
        #expect(requests.first?.host == "mcp.example.com")
        #expect(requests.first?.header("Authorization") == "Bearer mcp_at_example")
        #expect(!requests.contains { $0.host == "evil.example" }, "the second host must receive no request after a cross-origin redirect")
    }

    @Test("tools/call redirected by a 3xx to another origin → unreachable, neither token nor arguments leave the origin")
    func crossOriginRedirectOnCallIsRejected() async throws {
        let client = try await Harness.modern(
            stubs: [Harness.redirect(to: evilEndpoint), Harness.json(textResult("leaked"))],
            bearerToken: "mcp_at_example"
        )
        #expect(await callError(client) == .unreachable)
        #expect(!Scripted.requests().contains { $0.host == "evil.example" })
        #expect(Scripted.requests(method: "tools/call").count == 1)
    }

    @Test("A redirect to the same host downgraded to http is refused")
    func downgradeRedirectIsRejected() async throws {
        let client = try await Harness.modern(
            stubs: [Harness.redirect(to: "http://mcp.example.com/mcp"), Harness.json(textResult("leaked"))],
            bearerToken: "mcp_at_example"
        )
        #expect(await callError(client) == .unreachable)
        #expect(!Scripted.requests().contains { $0.request.url?.scheme == "http" })
    }

    @Test("Same host on a different port is not the same origin, the redirect is refused")
    func differentPortRedirectIsRejected() async throws {
        let client = try await Harness.modern(
            stubs: [Harness.redirect(to: "https://mcp.example.com:8443/mcp"), Harness.json(textResult("leaked"))],
            bearerToken: "mcp_at_example"
        )
        #expect(await callError(client) == .unreachable)
        #expect(!Scripted.requests().contains { $0.request.url?.port == 8443 })
    }

    @Test("A same-origin https redirect that keeps the method may be followed")
    func sameOriginRedirectIsFollowed() async throws {
        let client = try await Harness.modern(
            stubs: [Harness.redirect(to: "https://mcp.example.com/v2/mcp"), Harness.json(textResult("moved"))],
            bearerToken: "mcp_at_example"
        )
        let result = try await client.callTool(name: "get_weather", arguments: Harness.weatherArguments)
        #expect(result.text == "moved")
        let calls = Scripted.requests(method: "tools/call")
        #expect(calls.map { $0.request.url?.path } == ["/mcp", "/v2/mcp"])
        #expect(calls.allSatisfy { $0.host == "mcp.example.com" })
    }

    @Test("Authorization stripped by the system on a same-origin redirect → the original token is restored and the result is not misreported as needing sign-in")
    func sameOriginRedirectKeepsAuthorization() async throws {
        var redirect = Harness.redirect(to: "https://mcp.example.com/v2/mcp")
        redirect.redirectDropsAuthorization = true
        let client = try await Harness.modern(
            stubs: [redirect, Harness.json(textResult("moved"))],
            bearerToken: "mcp_at_example"
        )
        _ = try await client.callTool(name: "get_weather", arguments: Harness.weatherArguments)
        let calls = Scripted.requests(method: "tools/call")
        #expect(calls.count == 2)
        #expect(calls.allSatisfy { $0.header("Authorization") == "Bearer mcp_at_example" })
    }

    @Test("A same-origin redirect that rewrites POST to GET is not followed")
    func methodChangingRedirectIsRejected() async throws {
        let client = try await Harness.modern(
            stubs: [
                Harness.redirect(to: "https://mcp.example.com/v2/mcp", status: 302, method: "GET"),
                Harness.json(textResult("moved")),
            ]
        )
        #expect(await callError(client) == .unreachable)
        #expect(!Scripted.requests().contains { $0.method == "GET" })
    }

    @Test("Same-origin redirects are followed for at most 5 hops")
    func redirectHopLimit() async throws {
        Scripted.reset()
        Scripted.setFallback(Harness.redirect(to: "https://mcp.example.com/mcp"))
        let client = Harness.client()

        let outcome = await client.connect()
        #expect(outcome == .unreachable)
        #expect(Scripted.requests().count == McpHTTPLimits.maxRedirects + 1) // initial request + 5 hops
    }

    // MARK: https only

    @Test("For a non-https URL the client itself refuses to send and no request goes out")
    func nonHTTPSEndpointSendsNothing() async throws {
        Scripted.reset()
        try Scripted.enqueue(McpClientFixture.stub("protocol/stateless/tools-list.response.json"))
        let client = Harness.client(endpoint: URL(string: "http://mcp.example.com/mcp")!)

        let outcome = await client.connect(bearerToken: "mcp_at_example")
        #expect(outcome == .unreachable)
        #expect(Scripted.requests().isEmpty)
    }

    // MARK: Resource limits

    @Test("Response body larger than 8 MB → server_error")
    func oversizedJSONBodyIsRejected() async throws {
        let padding = String(repeating: "x", count: McpHTTPLimits.maxResponseBytes + 1)
        // The 8 MB body skips the JSON-level rewrite (placeholder substitution is enough), which saves the replay
        // layer from parsing it a second time.
        let client = try await Harness.modern(stubs: [Harness.json(textResult(padding), rewriteID: false)])
        #expect(await callError(client) == .serverError)
    }

    @Test("A Content-Length above the limit is refused without reading the body")
    func declaredOversizeIsRejectedEarly() async throws {
        let client = try await Harness.modern(stubs: [
            Harness.json(textResult("small"), headers: ["Content-Length": String(McpHTTPLimits.maxResponseBytes + 1)]),
        ])
        #expect(await callError(client) == .serverError)
    }

    @Test("An SSE stream that keeps sending bytes without a final response is aborted at 8 MB with server_error")
    func oversizedSSEStreamIsRejected() async throws {
        let chunk = "data: " + String(repeating: "y", count: 1024 * 1024) + "\n\n"
        let client = try await Harness.modern(
            stubs: [Harness.sse(Array(repeating: chunk, count: 9), keepOpen: true)],
            runtimeConfig: McpRuntimeConfig(callTimeoutSeconds: 30)
        )
        #expect(await callError(client, name: "flood_stream") == .serverError)
        #expect(await wasAborted(toolName: "flood_stream"), "the connection should be cut once the limit is exceeded")
    }

    @Test("A deeply nested response body is a parse failure, not a crash")
    func deeplyNestedBodyIsRejected() async throws {
        let depth = 50_000
        let nested = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        let body = #"{"jsonrpc":"2.0","id":__REQUEST_ID__,"result":{"content":[],"structuredContent":\#(nested)}}"#
        let client = try await Harness.modern(stubs: [Harness.json(body)])
        #expect(await callError(client) == .serverError)
    }

    @Test("Out-of-range ids and error codes do not crash: an id of 1e30 counts as a mismatch, an error code of 1e30 as an ordinary error")
    func hugeNumbersDoNotCrash() async throws {
        let hugeID = #"{"jsonrpc":"2.0","id":1e30,"result":{"content":[{"type":"text","text":"x"}]}}"#
        let hugeCode = #"{"jsonrpc":"2.0","id":__REQUEST_ID__,"error":{"code":1e30,"message":"boom"}}"#
        let client = try await Harness.modern(stubs: [
            Harness.json(hugeID, rewriteID: false),
            Harness.json(hugeCode, rewriteID: false),
        ])
        #expect(await callError(client) == .serverError)
        #expect(await callError(client) == .serverError)

        // The same input during the probe.
        Scripted.reset()
        Scripted.enqueue(Harness.json(#"{"jsonrpc":"2.0","id":1e30,"error":{"code":1e30,"message":"boom"}}"#, status: 400, rewriteID: false))
        Scripted.enqueue(Harness.status(400))
        let outcome = await Harness.client().connect()
        #expect(outcome == .notMcp)
    }

    @Test("structuredContent beyond maxResultChars is not kept in the result, and the fallback text is truncated as well")
    func oversizedStructuredContentIsDropped() async throws {
        let big = String(repeating: "z", count: 500)
        let onlyStructured = #"{"jsonrpc":"2.0","id":__REQUEST_ID__,"result":{"content":[],"structuredContent":{"blob":"\#(big)"}}}"#
        let withText = #"{"jsonrpc":"2.0","id":__REQUEST_ID__,"result":{"content":[{"type":"text","text":"ok"}],"structuredContent":{"blob":"\#(big)"}}}"#
        let client = try await Harness.modern(
            stubs: [Harness.json(onlyStructured), Harness.json(withText)],
            runtimeConfig: McpRuntimeConfig(maxResultChars: 100)
        )

        let fallback = try await client.callTool(name: "get_weather", arguments: Harness.weatherArguments)
        #expect(fallback.truncated)
        #expect(fallback.text.count == 100)
        #expect(fallback.text.hasSuffix(McpClientLimits.truncationMarker))
        #expect(fallback.structuredContent == nil)
        #expect(fallback.errorCode == .resultTooLarge)

        let text = try await client.callTool(name: "get_weather", arguments: Harness.weatherArguments)
        #expect(text.text == "ok")
        #expect(text.truncated == false)
        #expect(text.structuredContent == nil, "oversized structuredContent must not bypass the limit by staying in the result")
        #expect(text.errorCode == .resultTooLarge)
    }

    @Test("Fixture replay: for a response with structuredContent the text items win and the structured content is kept as is")
    func structuredContentFixture() async throws {
        let client = try await Harness.modern(stubs: [
            try McpClientFixture.stub("protocol/shared/tools-call.structured-content.response.json"),
        ])
        let result = try await client.callTool(name: "get_weather", arguments: Harness.weatherArguments)
        #expect(result.text == #"{"temperature": 22.5, "conditions": "Partly cloudy", "humidity": 65}"#)
        #expect(result.structuredContent?["humidity"]?.intValue == 65)
        #expect(result.structuredContent?["temperature"]?.doubleValue == 22.5)
        #expect(result.truncated == false)
        #expect(result.errorCode == nil)
    }

    // MARK: Streaming SSE

    @Test("SSE: final response arrived but the server keeps the stream open → return immediately and close the connection instead of waiting for the timeout")
    func sseReturnsWithoutWaitingForStreamClose() async throws {
        let final = "event: message\ndata: " + textResult("done") + "\n\n"
        let client = try await Harness.modern(
            stubs: [Harness.sse([": keep-alive\n\n", final], keepOpen: true)],
            runtimeConfig: McpRuntimeConfig(callTimeoutSeconds: 20)
        )
        let clock = ContinuousClock()
        let started = clock.now
        let result = try await client.callTool(name: "open_stream", arguments: Harness.weatherArguments)
        let elapsed = clock.now - started

        #expect(result.text == "done")
        #expect(elapsed < .seconds(5), "should not wait for the stream to close or time out, took \(elapsed)")
        #expect(await wasAborted(toolName: "open_stream"), "the connection should be closed once the final response is in")
        #expect(Scripted.requests(method: "tools/call").count == 1)
    }

    @Test("SSE: no blank line after the last data line and the stream stays open → still returns immediately")
    func sseReturnsOnUnterminatedFinalEvent() async throws {
        let client = try await Harness.modern(
            stubs: [Harness.sse(["data: " + textResult("done") + "\n"], keepOpen: true)],
            runtimeConfig: McpRuntimeConfig(callTimeoutSeconds: 20)
        )
        let clock = ContinuousClock()
        let started = clock.now
        let result = try await client.callTool(name: "get_weather", arguments: Harness.weatherArguments)
        #expect(result.text == "done")
        #expect(clock.now - started < .seconds(5))
    }

    @Test("SSE: chunks split mid-line / mid multi-byte character / mid CRLF are reassembled")
    func sseSurvivesArbitraryChunking() async throws {
        // Chunking would split the placeholder, so the id is hard-coded: the probe of `Harness.modern` uses 1 and this call is 2.
        let payload = textResult("72°F は 😀").replacingOccurrences(of: Scripted.requestIDPlaceholder, with: "2")
        let stream = "event: message\r\ndata: " + payload + "\r\n\r\n"
        let bytes = Array(stream.utf8)
        // One chunk every 7 bytes: guaranteed to split multi-byte characters and CRLF.
        let chunks = stride(from: 0, to: bytes.count, by: 7).map { start in
            Data(bytes[start..<min(start + 7, bytes.count)])
        }
        var stub = Harness.sse([])
        stub.chunks = chunks
        stub.chunkInterval = 0.002
        let client = try await Harness.modern(stubs: [stub])

        let result = try await client.callTool(name: "get_weather", arguments: Harness.weatherArguments)
        #expect(result.text == "72°F は 😀")
    }

    @Test("SSE: with a notification and a response to another request arriving first, only the one with the matching id counts")
    func ssePicksResponseByID() async throws {
        let stream = [
            #"data: {"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","data":"working"}}"# + "\n\n",
            #"data: {"jsonrpc":"2.0","id":987654,"result":{"content":[{"type":"text","text":"someone else's"}]}}"# + "\n\n",
            "data: " + textResult("mine") + "\n\n",
        ]
        let client = try await Harness.modern(stubs: [Harness.sse(stream)])
        let result = try await client.callTool(name: "get_weather", arguments: Harness.weatherArguments)
        #expect(result.text == "mine")
    }

    // MARK: Strict id matching

    @Test("Response id that does not match the request id → protocol error, never used as the result")
    func mismatchedIDIsProtocolError() async throws {
        let wrong = #"{"jsonrpc":"2.0","id":987654,"result":{"content":[{"type":"text","text":"not yours"}]}}"#
        let client = try await Harness.modern(stubs: [
            Harness.json(wrong, rewriteID: false),
            Harness.sse(["data: " + wrong + "\n\n"]),
        ])
        #expect(await callError(client) == .serverError)
        #expect(await callError(client) == .serverError)
    }

    @Test("An id in string form is not a match")
    func stringIDDoesNotMatch() async throws {
        let body = #"{"jsonrpc":"2.0","id":"__REQUEST_ID__","result":{"content":[{"type":"text","text":"x"}]}}"#
        let client = try await Harness.modern(stubs: [Harness.json(body, rewriteID: false)])
        #expect(await callError(client) == .serverError)
    }

    @Test("A JSON-RPC error with a null id counts as the error of this request (the server could not read the request id)")
    func nullIDErrorIsAccepted() async throws {
        let body = #"{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Invalid Request"}}"#
        let client = try await Harness.modern(stubs: [Harness.json(body, status: 400)])
        do {
            _ = try await client.callTool(name: "get_weather", arguments: Harness.weatherArguments)
            Issue.record("failure expected")
        } catch let error as McpClientError {
            #expect(error.code == .serverError)
            #expect(error.detail == "Invalid Request")
        }
    }

    // MARK: Cancellation

    @Test("Caller Task cancelled → the request is aborted and reports cancelled")
    func callerCancellationAbortsRequest() async throws {
        let client = try await Harness.modern(stubs: [Harness.json(textResult("late"), delay: 5)])
        let task = Task { await callError(client, name: "cancel_me") }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()

        #expect(await task.value == .cancelled)
        #expect(await wasAborted(toolName: "cancel_me"), "cancellation has to reach the underlying connection")
    }

    @Test("Two concurrent calls: the one that finishes first does not clear the cancellation handle of the other")
    func concurrentCallsKeepTheirOwnCancelHandles() async throws {
        let client = try await Harness.modern(stubs: [
            Harness.json(textResult("slow"), delay: 5),
            Harness.json(textResult("fast"), delay: 0.1),
        ])
        let slow = Task { await callError(client) }
        try await Task.sleep(for: .milliseconds(100))
        let fast = try await client.callTool(name: "get_weather", arguments: Harness.weatherArguments)
        #expect(fast.text == "fast")

        // The fast one has finished. The slow one must still be cancellable.
        await client.cancel()
        #expect(await slow.value == .cancelled)
    }

    @Test("Two concurrent calls: cancelling the Task of one does not affect the other")
    func cancellingOneCallLeavesTheOtherRunning() async throws {
        let client = try await Harness.modern(stubs: [
            Harness.json(textResult("cancelled"), delay: 5),
            Harness.json(textResult("kept"), delay: 0.4),
        ])
        let doomed = Task { await callError(client) }
        try await Task.sleep(for: .milliseconds(100))
        let kept = Task { try await client.callTool(name: "get_weather", arguments: Harness.weatherArguments) }
        try await Task.sleep(for: .milliseconds(100))
        doomed.cancel()

        #expect(await doomed.value == .cancelled)
        #expect(try await kept.value.text == "kept")
    }

    @Test("connect() is cancellable: it yields failed(cancelled) rather than being folded into unreachable")
    func connectIsCancellable() async throws {
        Scripted.reset()
        var slow = try McpClientFixture.stub("protocol/stateless/tools-list.response.json")
        slow.delay = 5
        Scripted.enqueue(slow)
        let client = Harness.client()

        let task = Task { await client.connect() }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()

        #expect(await task.value == .failed(.make(.cancelled)))
        #expect(await client.session == nil)
    }

    @Test("Legacy cancellation: besides closing the connection, a notifications/cancelled is sent (with the request id and session header)")
    func legacyCancellationSendsNotification() async throws {
        let client = try await Harness.legacy(stubs: [Harness.json(textResult("late"), delay: 5)])
        let task = Task { await callError(client) }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        #expect(await task.value == .cancelled)

        let sent = await Harness.eventually { !Scripted.requests(method: "notifications/cancelled").isEmpty }
        #expect(sent)
        let notification = try #require(Scripted.requests(method: "notifications/cancelled").first)
        let call = try #require(Scripted.requests(method: "tools/call").first)
        #expect(notification.json?["params"]?["requestId"]?.intValue == call.jsonRPCID)
        #expect(notification.json?["id"] == nil)
        #expect(notification.header("MCP-Session-Id") == "c1f2a3b4d5e60718293a4b5c6d7e8f90")
        #expect(notification.header("MCP-Protocol-Version") == "2025-11-25")
    }

    @Test("Modern cancellation: only closes the connection, no notifications/cancelled")
    func modernCancellationSendsNoNotification() async throws {
        let client = try await Harness.modern(stubs: [Harness.json(textResult("late"), delay: 5)])
        let task = Task { await callError(client) }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        #expect(await task.value == .cancelled)

        try await Task.sleep(for: .milliseconds(300))
        #expect(Scripted.requests(method: "notifications/cancelled").isEmpty)
    }

    // MARK: Timeouts

    @Test("The URLSession timeout is strictly greater than the call timeout: a configured 90 seconds is not cut short by the system")
    func urlSessionTimeoutExceedsCallTimeout() async throws {
        let client = try await Harness.modern(
            stubs: [Harness.json(textResult("ok"))],
            runtimeConfig: McpRuntimeConfig(callTimeoutSeconds: 90)
        )
        _ = try await client.callTool(name: "get_weather", arguments: Harness.weatherArguments)
        for request in Scripted.requests() {
            #expect(request.request.timeoutInterval > 90)
        }
    }

    @Test("A timeout reported by the system layer also maps to timeout, not unreachable")
    func urlSessionTimeoutMapsToTimeout() async throws {
        let client = try await Harness.modern(stubs: [.init(errorCode: .timedOut)])
        #expect(await callError(client) == .timeout)
    }

    @Test("SSE stream open but never delivering a final response → timeout at the call timeout, and the connection is closed")
    func silentSSEStreamTimesOut() async throws {
        let client = try await Harness.modern(
            stubs: [Harness.sse([": keep-alive\n\n"], keepOpen: true)],
            runtimeConfig: McpRuntimeConfig(callTimeoutSeconds: 0.4)
        )
        #expect(await callError(client, name: "silent_stream") == .timeout)
        #expect(await wasAborted(toolName: "silent_stream"))
    }
}
