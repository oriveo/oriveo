import Foundation
@testable import Oriveo

// MARK: - URLProtocol replay for the protocol client tests
//
// The iOS test process cannot launch Node, so the same fixtures under `shared/test-fixtures/mcp/protocol/` are
// replayed through URLProtocol.
// Notifications without an id, such as `notifications/initialized`, do not consume the script queue and get a 202.

final class McpScriptedURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        var status: Int = 200
        var headers: [String: String] = [:]
        var body: Data = Data()
        var delay: TimeInterval = 0
        var errorCode: URLError.Code? = nil
        /// Rewrites the `id` of the JSON-RPC response in the replayed body to the id of the current request: a
        /// well-behaved server echoes the request id,
        /// whereas the ids in the fixtures are the fixed values from recording time. Cases that test an id mismatch turn this off.
        var rewriteID: Bool = true
        /// Response body delivered in chunks (replaces `body` when set). `__REQUEST_ID__` inside a chunk becomes the current request id.
        var chunks: [Data]? = nil
        /// Delay between chunks.
        var chunkInterval: TimeInterval = 0.02
        /// Do not finish after sending the body (simulates a server that sends the final response but keeps the stream open).
        var keepOpen: Bool = false
        /// Answer with a 3xx and redirect the request to this URL (method, headers and body are carried over unchanged, the worst case).
        var redirectTo: String? = nil
        /// The redirected request uses this method (simulates 301 / 302 / 303 turning a POST into a GET).
        var redirectMethod: String? = nil
        /// The redirected request carries no `Authorization` (the system may strip it on redirect).
        var redirectDropsAuthorization: Bool = false
    }

    struct Captured: Sendable {
        let request: URLRequest
        let body: Data?

        var method: String? { request.httpMethod }
        var host: String? { request.url?.host }
        func header(_ name: String) -> String? { request.value(forHTTPHeaderField: name) }
        var bodyText: String? { body.flatMap { String(data: $0, encoding: .utf8) } }
        var json: JSONValue? { body.flatMap { try? JSONValue(data: $0) } }
        var jsonRPCMethod: String? { json?["method"]?.stringValue }
        var jsonRPCName: String? { json?["params"]?["name"]?.stringValue }
        var jsonRPCID: Int? { json?["id"]?.intValue }
    }

    /// Placeholder in replayed bodies that stands for the current request id.
    static let requestIDPlaceholder = "__REQUEST_ID__"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var queue: [Stub] = []
    nonisolated(unsafe) private static var fallback: Stub?
    nonisolated(unsafe) private static var captured: [Captured] = []
    nonisolated(unsafe) private static var aborted: [Captured] = []
    nonisolated(unsafe) private static var arrivalWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    private let stateLock = NSLock()
    private var completed = false
    private var stopped = false
    private var current: Captured?

    static func reset() {
        lock.lock()
        queue = []; fallback = nil; captured = []; aborted = []
        let waiting = arrivalWaiters
        arrivalWaiters = []
        lock.unlock()
        waiting.forEach { $0.continuation.resume() }
    }

    /// Suspends until at least `count` requests have reached the protocol since the last `reset()`.
    static func waitForRequests(_ count: Int = 1) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            let arrived = captured.count >= count
            if !arrived { arrivalWaiters.append((count, continuation)) }
            lock.unlock()
            if arrived { continuation.resume() }
        }
    }

    static func enqueue(_ stub: Stub) {
        lock.lock(); queue.append(stub); lock.unlock()
    }

    static func enqueue(_ stubs: [Stub]) {
        lock.lock(); queue.append(contentsOf: stubs); lock.unlock()
    }

    static func setFallback(_ stub: Stub) {
        lock.lock(); fallback = stub; lock.unlock()
    }

    static func requests() -> [Captured] {
        lock.lock(); defer { lock.unlock() }
        return captured
    }

    static func requests(method: String) -> [Captured] {
        requests().filter { $0.jsonRPCMethod == method }
    }

    /// Requests the client cut off before the response was fully sent (cancel / early return / timeout).
    static func abortedRequests() -> [Captured] {
        lock.lock(); defer { lock.unlock() }
        return aborted
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [McpScriptedURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.readBody(request)
        let capture = Captured(request: request, body: body)
        stateLock.lock(); current = capture; stateLock.unlock()

        Self.lock.lock()
        Self.captured.append(capture)
        let arrivedCount = Self.captured.count
        let arrived = Self.arrivalWaiters.filter { $0.count <= arrivedCount }
        Self.arrivalWaiters.removeAll { $0.count <= arrivedCount }
        let isNotification = Self.isNotification(body)
        var stub: Stub?
        if !isNotification {
            if !Self.queue.isEmpty { stub = Self.queue.removeFirst() } else { stub = Self.fallback }
        }
        Self.lock.unlock()
        arrived.forEach { $0.continuation.resume() }

        if isNotification {
            respond(status: 202, headers: [:], chunks: [], interval: 0, keepOpen: false)
            return
        }
        guard let stub else {
            fail(URLError(.unsupportedURL))
            return
        }
        let requestID = capture.jsonRPCID
        let work = { [weak self] in
            guard let self else { return }
            if let code = stub.errorCode {
                self.fail(URLError(code))
                return
            }
            if let target = stub.redirectTo, let url = URL(string: target) {
                self.redirect(
                    to: url, status: stub.status, body: body,
                    method: stub.redirectMethod, dropsAuthorization: stub.redirectDropsAuthorization
                )
                return
            }
            let chunks = (stub.chunks ?? [stub.body]).map { chunk -> Data in
                var data = McpResponseRewriter.replacingPlaceholder(in: chunk, requestID: requestID)
                if stub.rewriteID, stub.chunks == nil, let requestID {
                    data = McpResponseRewriter.rewritingID(in: data, requestID: requestID)
                }
                return data
            }
            self.respond(
                status: stub.status,
                headers: stub.headers,
                chunks: chunks,
                interval: stub.chunks == nil ? 0 : stub.chunkInterval,
                keepOpen: stub.keepOpen
            )
        }
        if stub.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + stub.delay, execute: work)
        } else {
            work()
        }
    }

    override func stopLoading() {
        stateLock.lock()
        let wasCompleted = completed
        stopped = true
        let capture = current
        stateLock.unlock()
        if !wasCompleted, let capture {
            Self.lock.lock(); Self.aborted.append(capture); Self.lock.unlock()
        }
    }

    private var isStopped: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return stopped
    }

    private func markCompleted() {
        stateLock.lock(); completed = true; stateLock.unlock()
    }

    private func fail(_ error: URLError) {
        markCompleted()
        client?.urlProtocol(self, didFailWithError: error)
    }

    private func redirect(to url: URL, status: Int, body: Data?, method: String?, dropsAuthorization: Bool) {
        guard let source = request.url,
              let response = HTTPURLResponse(
                url: source,
                statusCode: (300..<400).contains(status) ? status : 307,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": url.absoluteString]
              )
        else { return }
        // Carry the original request over unchanged (method, all headers including Authorization, body): whether it
        // gets blocked is entirely up to the production delegate.
        var next = request
        next.url = url
        next.httpBodyStream = nil
        next.httpBody = body
        if let method {
            next.httpMethod = method
            next.httpBody = nil
        }
        if dropsAuthorization { next.setValue(nil, forHTTPHeaderField: "Authorization") }
        markCompleted()
        client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
    }

    private func respond(status: Int, headers: [String: String], chunks: [Data], interval: TimeInterval, keepOpen: Bool) {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if interval <= 0 {
            for chunk in chunks where !chunk.isEmpty { client?.urlProtocol(self, didLoad: chunk) }
            finish(keepOpen: keepOpen)
            return
        }
        deliver(chunks[...], interval: interval, keepOpen: keepOpen)
    }

    private func deliver(_ chunks: ArraySlice<Data>, interval: TimeInterval, keepOpen: Bool) {
        guard !isStopped else { return }
        guard let chunk = chunks.first else {
            finish(keepOpen: keepOpen)
            return
        }
        if !chunk.isEmpty { client?.urlProtocol(self, didLoad: chunk) }
        DispatchQueue.global().asyncAfter(deadline: .now() + interval) { [weak self] in
            self?.deliver(chunks.dropFirst(), interval: interval, keepOpen: keepOpen)
        }
    }

    private func finish(keepOpen: Bool) {
        guard !keepOpen else { return }
        markCompleted()
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func isNotification(_ body: Data?) -> Bool {
        guard let body, let value = try? JSONValue(data: body) else { return false }
        return value["id"] == nil && value["method"] != nil
    }

    private static func readBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }
}

// MARK: - Rewriting replayed bodies

/// Makes replayed responses echo the request id the way a well-behaved server does. Fixture ids are the fixed
/// values from recording time and production code matches strictly by id,
/// so the replay layer rewrites them instead of production code falling back to the first response in the stream.
enum McpResponseRewriter {
    static func replacingPlaceholder(in data: Data, requestID: Int?) -> Data {
        guard let requestID, let text = String(data: data, encoding: .utf8),
              text.contains(McpScriptedURLProtocol.requestIDPlaceholder) else { return data }
        return Data(text.replacingOccurrences(of: McpScriptedURLProtocol.requestIDPlaceholder, with: String(requestID)).utf8)
    }

    static func rewritingID(in data: Data, requestID: Int) -> Data {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return data }
        if let value = try? JSONValue(parsing: text) {
            guard let rewritten = rewrite(value, requestID: requestID) else { return data }
            return Data(rewritten.orderedJSONString.utf8)
        }
        // SSE: rewrite the data payload line by line and keep every other line (event / comment / blank) as is.
        let lines = text.components(separatedBy: "\n").map { line -> String in
            guard line.hasPrefix("data:") else { return line }
            let payload = String(line.dropFirst(5))
            guard let value = try? JSONValue(parsing: payload),
                  let rewritten = rewrite(value, requestID: requestID) else { return line }
            return "data: " + rewritten.orderedJSONString + (line.hasSuffix("\r") ? "\r" : "")
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    /// Only rewrites JSON-RPC responses with a non-null id; notifications, errors with `id: null` and plain JSON are untouched.
    private static func rewrite(_ value: JSONValue, requestID: Int) -> JSONValue? {
        guard let object = value.objectValue,
              object["result"] != nil || object["error"] != nil,
              let id = object["id"], id != .null else { return nil }
        return .object(JSONObject(object.keys.map { key in
            (key, key == "id" ? .number(Double(requestID)) : object[key]!)
        }))
    }
}

// MARK: - Fixture loading

enum McpClientFixture {
    /// Turns a protocol fixture (under `protocol/`) into a replayable response stub.
    static func stub(_ name: String) throws -> McpScriptedURLProtocol.Stub {
        try stub(json: McpFixture.json(name))
    }

    static func stub(json value: JSONValue) throws -> McpScriptedURLProtocol.Stub {
        var headers: [String: String] = [:]
        if let object = value["headers"]?.objectValue {
            for key in object.keys {
                if let text = object[key]?.stringValue { headers[key] = text }
            }
        }
        var body = Data()
        if let raw = value["raw"]?.stringValue {
            body = Data(raw.utf8)
        } else if let payload = value["body"] {
            body = Data(payload.orderedJSONString.utf8)
        }
        return McpScriptedURLProtocol.Stub(
            status: value["status"]?.intValue ?? 200,
            headers: headers,
            body: body
        )
    }

    /// Raw SSE text fixture (`*.sse.txt`).
    static func sse(_ name: String) throws -> Data {
        try Data(contentsOf: McpFixture.url(name))
    }

    /// The four cases of `not-mcp.responses.json`.
    static func notMcpCases() throws -> [(id: String, stub: McpScriptedURLProtocol.Stub)] {
        let value = try McpFixture.json("protocol/shared/not-mcp.responses.json")
        let cases = value["cases"]?.arrayValue ?? []
        return try cases.compactMap { item in
            guard let id = item["caseId"]?.stringValue else { return nil }
            return (id, try stub(json: item))
        }
    }
}

// MARK: - Building connected clients

enum McpClientHarness {
    static let endpoint = URL(string: "https://mcp.example.com/mcp")!
    static let weatherArguments = JSONValue.object(JSONObject([("location", .string("New York"))]))

    static func client(endpoint: URL = endpoint, runtimeConfig: McpRuntimeConfig = .fallback) -> McpClient {
        McpClient(endpoint: endpoint, runtimeConfig: runtimeConfig, session: McpScriptedURLProtocol.session())
    }

    /// A connected client on the modern revision: probes with `tools/list`, then replays `stubs` in order.
    static func modern(
        stubs: [McpScriptedURLProtocol.Stub] = [],
        runtimeConfig: McpRuntimeConfig = .fallback,
        bearerToken: String? = nil
    ) async throws -> McpClient {
        McpScriptedURLProtocol.reset()
        try McpScriptedURLProtocol.enqueue(McpClientFixture.stub("protocol/stateless/tools-list.response.json"))
        McpScriptedURLProtocol.enqueue(stubs)
        let client = client(runtimeConfig: runtimeConfig)
        guard await client.connect(bearerToken: bearerToken).session != nil else { throw HarnessError.notConnected }
        return client
    }

    /// A connected client on the legacy revision: the modern probe gets a 400 with an empty body, then falls back to `initialize`.
    static func legacy(
        stubs: [McpScriptedURLProtocol.Stub] = [],
        runtimeConfig: McpRuntimeConfig = .fallback,
        bearerToken: String? = nil
    ) async throws -> McpClient {
        McpScriptedURLProtocol.reset()
        McpScriptedURLProtocol.enqueue(status(400))
        try McpScriptedURLProtocol.enqueue(McpClientFixture.stub("protocol/session/initialize.response.json"))
        McpScriptedURLProtocol.enqueue(stubs)
        let client = client(runtimeConfig: runtimeConfig)
        guard await client.connect(bearerToken: bearerToken).session != nil else { throw HarnessError.notConnected }
        return client
    }

    enum HarnessError: Error { case notConnected }

    static func json(
        _ text: String,
        status: Int = 200,
        headers: [String: String] = [:],
        delay: TimeInterval = 0,
        rewriteID: Bool = true
    ) -> McpScriptedURLProtocol.Stub {
        var merged = ["Content-Type": "application/json"]
        for (key, value) in headers { merged[key] = value }
        return McpScriptedURLProtocol.Stub(
            status: status, headers: merged, body: Data(text.utf8), delay: delay, rewriteID: rewriteID
        )
    }

    /// Empty-body response.
    static func status(_ status: Int, headers: [String: String] = [:]) -> McpScriptedURLProtocol.Stub {
        McpScriptedURLProtocol.Stub(status: status, headers: headers, body: Data())
    }

    /// SSE stream delivered in chunks. `__REQUEST_ID__` inside a chunk stands for the current request id.
    static func sse(_ chunks: [String], keepOpen: Bool = false) -> McpScriptedURLProtocol.Stub {
        McpScriptedURLProtocol.Stub(
            status: 200,
            headers: ["Content-Type": "text/event-stream"],
            chunks: chunks.map { Data($0.utf8) },
            keepOpen: keepOpen
        )
    }

    static func redirect(to target: String, status: Int = 307, method: String? = nil) -> McpScriptedURLProtocol.Stub {
        McpScriptedURLProtocol.Stub(status: status, redirectTo: target, redirectMethod: method)
    }

    /// Polls for a side effect that lands asynchronously (connection cut, out-of-band notification sent).
    static func eventually(timeout: TimeInterval = 3, _ condition: @Sendable () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    /// Compares the request sent by the production path against a request fixture (`*.request.json` /
    /// `*.notification.json`) item by item:
    /// method, path, every header the fixture lists, protocol headers that must be absent, and the body (the
    /// JSON-RPC id is assigned by the client and only has to be an integer).
    static func mismatches(_ captured: McpScriptedURLProtocol.Captured, fixture name: String) throws -> [String] {
        let fixture = try McpFixture.json(name)
        var problems: [String] = []
        if captured.method != fixture["method"]?.stringValue { problems.append("method: \(captured.method ?? "nil")") }
        if captured.request.url?.path != fixture["path"]?.stringValue {
            problems.append("path: \(captured.request.url?.path ?? "nil")")
        }
        let headers = fixture["headers"]?.objectValue
        for key in headers?.keys ?? [] where captured.header(key) != headers?[key]?.stringValue {
            problems.append("header \(key): \(captured.header(key) ?? "nil")")
        }
        for key in ["MCP-Protocol-Version", "Mcp-Method", "Mcp-Name", "MCP-Session-Id", "Authorization"]
        where headers?[key] == nil && captured.header(key) != nil {
            problems.append("unexpected header \(key)")
        }
        guard let expected = fixture["body"]?.objectValue, let actual = captured.json?.objectValue else {
            problems.append("body is not a JSON object")
            return problems
        }
        if expected["id"] != nil, actual["id"]?.intValue == nil { problems.append("id is not an integer") }
        if expected["id"] == nil, actual["id"] != nil { problems.append("notification carries an id") }
        let strip: (JSONObject) -> String = { object in
            JSONValue.object(JSONObject(object.keys.filter { $0 != "id" }.map { ($0, object[$0]!) })).canonicalJSONString
        }
        if strip(expected) != strip(actual) { problems.append("body: \(strip(actual))") }
        return problems
    }
}
