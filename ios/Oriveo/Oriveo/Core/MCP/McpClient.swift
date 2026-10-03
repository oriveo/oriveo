import Foundation

// MARK: - Remote MCP protocol client
//
// Covers both protocol generations (probing and negotiation, request shapes, `tools/list`, `tools/call`,
// MRTR), the runtime configuration, call / cancel / retry behaviour and the closed set of error codes.
// Two safety rules are enforced here: a `tools/call` is never retried once it has been sent, and
// credentials are never sent to another origin because of a redirect.
//
// Streamable HTTP over https only: JSON-RPC is POSTed to the server URL and the response is either a single
// JSON document or an SSE stream. Redirect interception and byte limits live in `McpHTTP.swift`;
// authorization, the tool catalog and UI are outside this unit.

nonisolated enum McpProtocolEra: String, Sendable, Equatable {
    case modern
    case legacy
}

/// The result of one successful negotiation. A legacy session id is kept only in memory and in the local
/// connection state; it is never logged.
nonisolated struct McpSession: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    var generation: McpProtocolGeneration
    var protocolVersion: String
    var sessionId: String?
    /// The server's self-reported name (legacy: `serverInfo.name` from `initialize`; `nil` when the modern
    /// probe does not provide one). When the server record's name is left blank it falls back to this
    /// name and then to the host name.
    var serverName: String? = nil

    var era: McpProtocolEra { generation == .stateless ? .modern : .legacy }

    /// The session id stays out of logs: printing with `String(describing:)` / `String(reflecting:)` only
    /// says whether there is one.
    var description: String {
        "McpSession(generation: \(generation.rawValue), protocolVersion: \(protocolVersion), "
            + "sessionId: \(sessionId == nil ? "nil" : "<redacted>"))"
    }

    var debugDescription: String { description }
}

/// A protocol client error. `code` belongs to the closed set of error codes; `detail` is the server's own
/// text and is used only for the locally stored step payload and the user-visible failure explanation
/// (truncated to 200 characters). **It never goes into `toolSteps` or logs.**
nonisolated struct McpClientError: Error, Sendable, Equatable {
    var code: McpErrorCode
    var detail: String?

    static func make(_ code: McpErrorCode, detail: String? = nil) -> McpClientError {
        McpClientError(code: code, detail: detail.map { String($0.prefix(200)) })
    }
}

/// The terminal states of probing and negotiation. `notMcp` / `unreachable` / `needsAuth` are not error
/// codes but intermediate results for the add-flow state machine.
/// The error code carried by `failed` is one of `server_error` / `timeout` / `cancelled`.
nonisolated enum McpConnectOutcome: Sendable, Equatable {
    case connected(McpSession)
    case notMcp
    case needsAuth
    case unreachable
    case failed(McpClientError)

    var session: McpSession? {
        if case .connected(let session) = self { return session }
        return nil
    }
}

/// The completed result of one `tools/call`. Tool execution errors (`isError: true`) and MRTR
/// (`input_required`) are both **normal results**, not JSON-RPC errors; only transport-level and
/// protocol-level failures throw `McpClientError`.
nonisolated struct McpToolCallResult: Sendable, Equatable {
    /// The trimmed text that is fed back to the model.
    var text: String
    /// `result.isError == true` (a tool execution error, not a JSON-RPC error).
    var isError: Bool
    /// The failure / trimming error code: `tool_error` / `needs_input_unsupported` / `result_too_large`,
    /// or `nil`.
    var errorCode: McpErrorCode?
    /// Whether the result was truncated for exceeding `maxResultChars`.
    var truncated: Bool
    var structuredContent: JSONValue?
}

/// Built-in fallback values: when the catalog carries no configuration these are used instead, and the
/// feature is not disabled because of it.
nonisolated enum McpClientLimits {
    static let fallbackCallTimeoutSeconds: Double = 60
    static let fallbackMaxResultChars = 24_000
    static let truncationMarker = "\n\n[result truncated]"
    static let acceptHeader = "application/json, text/event-stream"
    /// Upper bound on waiting for the legacy cancellation notification. It is a best-effort side request
    /// and should not hang for a minute along with the call timeout.
    static let cancelNotificationTimeoutSeconds: Double = 5
}

/// The remote MCP protocol client (dual-era). One instance per server URL; the negotiation result is
/// cached in the instance.
actor McpClient {
    private let endpoint: URL
    private let runtimeConfig: McpRuntimeConfig
    private let urlSession: URLSession
    private var bearerToken: String?
    private var negotiatedSession: McpSession?
    private var lastAuthChallenge: McpAuthChallenge?
    private var nextRequestID = 1
    /// HTTP exchanges in flight, registered by request id. The actor is reentrant, so two calls interleave:
    /// each registers and clears its own entry, and the one finishing first cannot clear the other's
    /// cancellation handle.
    private var inFlight: [Int: Task<McpExchange, Error>] = [:]

    init(
        endpoint: URL,
        runtimeConfig: McpRuntimeConfig = .fallback,
        session: URLSession = McpHTTP.defaultSession
    ) {
        self.endpoint = endpoint
        self.runtimeConfig = runtimeConfig
        self.urlSession = session
    }

    /// The currently negotiated session (`nil` until negotiation succeeds).
    var session: McpSession? { negotiatedSession }

    /// The challenge (`WWW-Authenticate`) parsed from the most recent 401 / 403 `insufficient_scope`. The
    /// discovery step of the add flow prefers its `resource_metadata`; without a challenge the well-known
    /// URIs are built instead.
    var authChallenge: McpAuthChallenge? { lastAuthChallenge }

    // MARK: - Probing and negotiation

    /// Probes the server's generation and negotiates the version with this state machine.
    ///
    /// 1. Send a modern-shaped `tools/list` first.
    /// 2. Success (the body is a valid `tools/list` result) -> modern (stateless).
    /// 3. `400` -> **read the response body first**: only a "recognizable modern JSON-RPC error" proves the
    ///    server is modern, in which case falling back to `initialize` is **not allowed**; an empty body, a
    ///    body that is not JSON-RPC, or a generic JSON-RPC error without any modern marker always falls
    ///    back to `initialize` (legacy).
    /// 4. `404` with a JSON-RPC body -> modern (it speaks JSON-RPC but does not implement the method); a
    ///    bare 404 -> not an MCP server (there is no HTTP+SSE fallback).
    /// 5. A network-level failure -> `unreachable`, and the generation probe is not retried.
    ///
    /// Returns `.failed(cancelled)` when the caller's Task is cancelled (or `cancel()` is called).
    func connect(bearerToken: String? = nil) async -> McpConnectOutcome {
        self.bearerToken = bearerToken
        self.negotiatedSession = nil
        self.lastAuthChallenge = nil

        let outcome: McpConnectOutcome
        do {
            outcome = try await performConnect()
        } catch let error as McpClientError {
            switch error.code {
            case .timeout, .cancelled, .serverError: return .failed(error)
            default: return .unreachable
            }
        } catch {
            return .unreachable
        }
        if case .connected(let session) = outcome {
            self.negotiatedSession = session
        }
        return outcome
    }

    private func performConnect() async throws -> McpConnectOutcome {
        let probe = try await modernProbe()
        if requiresAuth(probe) { return .needsAuth }

        if let message = probe.message, let error = message["error"], probe.status == 400 || probe.status == 200 {
            // Read the response body before deciding whether to fall back. Some legacy servers answer
            // "not initialized yet" with 200 + a JSON-RPC error instead of 400; the test is the same either
            // way: whether the body carries a modern marker.
            return try await resolveProbeError(error)
        }

        switch probe.status {
        case 200:
            if Self.isToolsListResult(probe.message) {
                return .connected(McpSession(generation: .stateless, protocolVersion: McpProtocol.modernVersion, sessionId: nil))
            }
            // The body is JSON-RPC but does not match our request id: the server speaks JSON-RPC and just
            // violates the protocol.
            if probe.mismatchedID { return .failed(.make(.serverError)) }
            // 200 but the body is not a valid JSON-RPC result (HTML, plain JSON, missing `tools`) -> not an
            // MCP server.
            return .notMcp
        case 400:
            // Empty body / not JSON-RPC -> fall back to initialize.
            return try await legacyHandshake(version: McpProtocol.legacyInitializeVersion)
        case 404:
            // With a JSON-RPC body -> modern (it speaks JSON-RPC but does not implement the method); a bare
            // 404 -> not an MCP server.
            if let message = probe.message {
                return .failed(.make(.serverError, detail: message["error"]?["message"]?.stringValue))
            }
            return .notMcp
        case 405:
            return .notMcp
        case 200..<300:
            return .notMcp
        default:
            return .failed(.make(.serverError))
        }
    }

    /// Decides what to do when the probe receives a JSON-RPC error.
    private func resolveProbeError(_ error: JSONValue) async throws -> McpConnectOutcome {
        // A generic error without any modern marker -> a legacy server refusing a request before initialize
        // (the reference implementation answers -32602 "Received request before initialization was
        // complete"); fall back to the handshake.
        guard Self.isRecognizableModernError(error) else {
            return try await legacyHandshake(version: McpProtocol.legacyInitializeVersion)
        }
        let detail = error["message"]?.stringValue
        // -32020 / -32021, or another error carrying a modern marker / `data.supported`: still modern, no fallback.
        guard error["code"]?.intValue == McpProtocol.unsupportedVersionErrorCode else {
            return .failed(.make(.serverError, detail: detail))
        }

        // -32022: pick the highest version we support from `data.supported`.
        let supported = error["data"]?["supported"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if supported.contains(McpProtocol.modernVersion) {
            let retry = try await modernProbe()
            if requiresAuth(retry) { return .needsAuth }
            if retry.status == 200, Self.isToolsListResult(retry.message) {
                return .connected(McpSession(generation: .stateless, protocolVersion: McpProtocol.modernVersion, sessionId: nil))
            }
            return .failed(.make(.serverError, detail: retry.message?["error"]?["message"]?.stringValue))
        }
        // The server lists legacy versions only: sending the modern shape again is pointless, so switch to
        // the handshake and use exactly the version it listed.
        if let legacy = supported.filter({ McpProtocol.legacyVersions.contains($0) }).max() {
            return try await legacyHandshake(version: legacy)
        }
        return .failed(.make(.serverError, detail: detail))
    }

    private func modernProbe() async throws -> McpExchange {
        let id = nextID()
        let probeSession = McpSession(generation: .stateless, protocolVersion: McpProtocol.modernVersion, sessionId: nil)
        let request = makeRequest(id: id, method: "tools/list", params: [], toolName: nil, session: probeSession)
        // A network-level failure -> unreachable; the generation probe is not retried.
        return try await exchange(request, requestID: id, key: id, allowsPreConnectRetry: false)
    }

    /// The outcome of `initialize`.
    private enum InitializeOutcome {
        case session(McpSession)
        case needsAuth
        /// The handshake does not hold: the peer is not an MCP server.
        case notMcp
        /// The peer is an MCP server but refused this handshake (a JSON-RPC error, 5xx, or a version we do
        /// not support).
        case rejected(McpClientError)
    }

    /// The legacy handshake: `initialize` -> `initialized`.
    private func legacyHandshake(version: String) async throws -> McpConnectOutcome {
        switch try await performInitialize(version: version) {
        case .session(let session):
            await sendInitializedNotification(session: session)
            return .connected(session)
        case .needsAuth:
            return .needsAuth
        case .notMcp:
            // Neither the modern probe nor the fallback handshake holds (the path an ordinary website takes
            // when it answers a JSON POST with 400) -> not an MCP server.
            return .notMcp
        case .rejected(let error):
            return .failed(error)
        }
    }

    /// Sends `initialize` and parses the negotiation result. Network failures, timeouts and cancellation
    /// are thrown as usual.
    private func performInitialize(version: String) async throws -> InitializeOutcome {
        let id = nextID()
        let request = makeInitializeRequest(id: id, version: version)
        let response = try await exchange(request, requestID: id, key: id, allowsPreConnectRetry: false)
        if requiresAuth(response) { return .needsAuth }
        if response.status >= 500 { return .rejected(.make(.serverError)) }
        guard let message = response.message else {
            return response.mismatchedID ? .rejected(.make(.serverError)) : .notMcp
        }
        if let error = message["error"] {
            // A legacy server always implements initialize; something lacking even this method is some
            // other JSON-RPC service.
            if error["code"]?.intValue == McpProtocol.methodNotFoundErrorCode { return .notMcp }
            return .rejected(.make(.serverError, detail: error["message"]?.stringValue))
        }
        guard (200..<300).contains(response.status),
              let result = message["result"], result.objectValue != nil,
              let negotiated = result["protocolVersion"]?.stringValue
        else { return .notMcp }
        // The server answered with a version we do not support: disconnect, as the specification requires.
        guard McpProtocol.legacyVersions.contains(negotiated) else { return .rejected(.make(.serverError)) }
        return .session(McpSession(
            generation: .session,
            protocolVersion: negotiated,
            sessionId: response.headers["mcp-session-id"],
            serverName: result["serverInfo"]?["name"]?.stringValue
        ))
    }

    private func sendInitializedNotification(session: McpSession) async {
        let request = makeNotificationRequest(method: "notifications/initialized", params: nil, session: session)
        _ = try? await exchange(request, requestID: nil, key: nextID(), allowsPreConnectRetry: false)
    }

    /// Performs the handshake once more after the server terminated a legacy session; on success the new
    /// session is stored and later calls carry the new session id.
    private func reinitialize() async throws -> McpSession? {
        guard case .session(let renegotiated) = try await performInitialize(version: McpProtocol.legacyInitializeVersion) else {
            return nil
        }
        await sendInitializedNotification(session: renegotiated)
        negotiatedSession = renegotiated
        return renegotiated
    }

    // MARK: - tools/list

    /// Fetches the complete tool list. **Pagination must be followed to the end**; at most 20 pages are
    /// followed per fetch and exceeding that is treated as a failure.
    func listTools() async throws -> [McpToolDefinition] {
        guard var session = negotiatedSession else {
            throw McpClientError.make(.serverError)
        }
        var tools: [McpToolDefinition] = []
        var cursor: String?
        var pages = 0
        var didReinitialize = false

        while true {
            if pages >= McpProtocol.maxToolsListPages {
                throw McpClientError.make(.serverError)
            }
            pages += 1

            let id = nextID()
            var params: [(String, JSONValue)] = []
            if let cursor { params.append(("cursor", .string(cursor))) }
            let request = makeRequest(id: id, method: "tools/list", params: params, toolName: nil, session: session)
            let response = try await send(request, id: id, session: session, allowsPreConnectRetry: true)
            if requiresAuth(response) { throw McpClientError.make(.needsAuth) }

            // The server terminated the legacy session (404): initialize again once, with no endless retries.
            if session.generation == .session, response.status == 404, !didReinitialize {
                didReinitialize = true
                if let renegotiated = try await reinitialize() {
                    session = renegotiated
                    // Cursors issued by the old session mean nothing in the new one; start from the top.
                    tools = []
                    cursor = nil
                    pages = 0
                    continue
                }
            }

            guard let result = response.message?["result"], result.objectValue != nil else {
                throw McpClientError.make(.serverError, detail: response.message?["error"]?["message"]?.stringValue)
            }
            if let array = result["tools"]?.arrayValue {
                tools.append(contentsOf: array.compactMap { McpToolDefinition(json: $0) })
            }
            if let next = result["nextCursor"]?.stringValue, !next.isEmpty {
                cursor = next
                continue
            }
            return tools
        }
    }

    // MARK: - tools/call

    /// Calls a tool. Tool execution errors (`isError`) and MRTR (`input_required`) are returned as
    /// results; transport-level and protocol-level failures throw `McpClientError`.
    func callTool(name: String, arguments: JSONValue) async throws -> McpToolCallResult {
        guard let session = negotiatedSession else {
            throw McpClientError.make(.serverError)
        }
        let id = nextID()
        let request = makeRequest(
            id: id,
            method: "tools/call",
            params: [("name", .string(name)), ("arguments", arguments)],
            toolName: name,
            session: session
        )
        // A tools/call is never retried automatically once sent (replaying a writing tool would write twice).
        let response = try await send(request, id: id, session: session, allowsPreConnectRetry: false)
        if requiresAuth(response) { throw McpClientError.make(.needsAuth) }

        // The legacy session was terminated: initialize again once to restore the session, but **do not
        // replay this call**.
        if session.generation == .session, response.status == 404 {
            _ = try? await reinitialize()
            throw McpClientError.make(.serverError, detail: response.message?["error"]?["message"]?.stringValue)
        }

        guard let message = response.message else {
            throw McpClientError.make(.serverError)
        }
        if let error = message["error"] {
            let detail = error["message"]?.stringValue
            // Protocol errors such as an unknown tool are handled as tool_error (fixture error.unknown-tool.json).
            if error["code"]?.intValue == McpProtocol.invalidParamsErrorCode {
                throw McpClientError.make(.toolError, detail: detail)
            }
            throw McpClientError.make(.serverError, detail: detail)
        }
        guard let result = message["result"], result.objectValue != nil else {
            throw McpClientError.make(.serverError)
        }

        // MRTR: the decision looks at resultType only and does not try to recognize method names such as
        // elicitation/create.
        if result["resultType"]?.stringValue == "input_required" {
            return McpToolCallResult(
                text: "",
                isError: false,
                errorCode: .needsInputUnsupported,
                truncated: false,
                structuredContent: nil
            )
        }

        let trimmed = trim(result: result)
        let isError = result["isError"]?.boolValue ?? false
        return McpToolCallResult(
            text: trimmed.text,
            isError: isError,
            errorCode: isError ? .toolError : (trimmed.truncated || trimmed.droppedStructured ? .resultTooLarge : nil),
            truncated: trimmed.truncated,
            structuredContent: trimmed.structuredContent
        )
    }

    // MARK: - Cancellation

    /// Cancels every request in flight on this client (closing the response stream is the cancellation).
    /// To cancel a single call, cancel the Task that started it - the cancellation propagates to the
    /// underlying connection.
    func cancel() {
        for task in inFlight.values { task.cancel() }
    }

    // MARK: - Result trimming

    /// `content` text items are concatenated in order; non-text items become a placeholder note; when the
    /// text is empty and there is `structuredContent`, its JSON text is used; anything beyond
    /// `maxResultChars` is truncated and marked at the end.
    ///
    /// `structuredContent` itself is subject to `maxResultChars` too: when its serialization exceeds the
    /// limit it is dropped entirely (truncated JSON is not JSON), so an 8 MB object cannot bypass the limit
    /// and stay in the result.
    private func trim(
        result: JSONValue
    ) -> (text: String, truncated: Bool, structuredContent: JSONValue?, droppedStructured: Bool) {
        var parts: [String] = []
        if let content = result["content"]?.arrayValue {
            for item in content {
                if item["type"]?.stringValue == "text", let text = item["text"]?.stringValue {
                    parts.append(text)
                } else {
                    parts.append(Self.placeholder(for: item["type"]?.stringValue ?? "unknown"))
                }
            }
        }
        var text = parts.joined()
        let limit = maxResultChars
        var structured = result["structuredContent"]
        var droppedStructured = false
        if let value = structured {
            let serialized = value.orderedJSONString
            if text.isEmpty { text = serialized }
            if serialized.count > limit {
                structured = nil
                droppedStructured = true
            }
        }

        guard text.count > limit else { return (text, false, structured, droppedStructured) }
        let marker = McpClientLimits.truncationMarker
        let keep = max(0, limit - marker.count)
        return (String(text.prefix(keep)) + marker, true, structured, droppedStructured)
    }

    private nonisolated static func placeholder(for type: String) -> String {
        "[non-text content: \(type)]"
    }

    private var callTimeout: Double {
        runtimeConfig.callTimeoutSeconds > 0 ? runtimeConfig.callTimeoutSeconds : McpClientLimits.fallbackCallTimeoutSeconds
    }

    private var maxResultChars: Int {
        runtimeConfig.maxResultChars > 0 ? runtimeConfig.maxResultChars : McpClientLimits.fallbackMaxResultChars
    }

    // MARK: - Authorization challenge

    /// 401, or 403 + `insufficient_scope` (step-up is not implemented yet, so it is handled as
    /// `needs_auth`). Records the challenge on a match.
    private func requiresAuth(_ response: McpExchange) -> Bool {
        let header = response.headers["www-authenticate"]
        guard McpAuthResponseMapping.needsAuthErrorCode(status: response.status, wwwAuthenticate: header) != nil else {
            return false
        }
        lastAuthChallenge = McpWWWAuthenticate.parse(header)
        return true
    }

    // MARK: - Request construction

    private func nextID() -> Int {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    private func baseRequest(session: McpSession?) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        // The timeout is decided by our own timer (see `McpHTTP.withDeadline`); the URLSession idle timeout
        // must be strictly larger, otherwise the two timers race and a configured `callTimeoutSeconds`
        // above 60 seconds would be cut short by the system first.
        request.timeoutInterval = callTimeout + McpHTTPLimits.urlSessionTimeoutMargin
        request.setValue(McpClientLimits.acceptHeader, forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearerToken { request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization") }
        // initialize itself carries no MCP-Protocol-Version (the specification requires it on subsequent requests).
        if let session {
            request.setValue(session.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
            if session.generation == .session, let sessionId = session.sessionId {
                request.setValue(sessionId, forHTTPHeaderField: "MCP-Session-Id")
            }
        }
        return request
    }

    /// Request construction shared by both protocol generations. Modern requests carry `_meta` and the
    /// `Mcp-Method` / `Mcp-Name` headers on every request; legacy requests carry only the negotiated
    /// version and the session id.
    private func makeRequest(
        id: Int,
        method: String,
        params: [(String, JSONValue)],
        toolName: String?,
        session: McpSession
    ) -> URLRequest {
        var request = baseRequest(session: session)
        var pairs = params
        if session.generation == .stateless {
            pairs.append(("_meta", Self.modernMeta(version: session.protocolVersion)))
            request.setValue(method, forHTTPHeaderField: "Mcp-Method")
            if let toolName {
                request.setValue(Self.headerValue(toolName), forHTTPHeaderField: "Mcp-Name")
            }
        }
        let body = Self.jsonRPCMessage(id: id, method: method, params: .object(JSONObject(pairs)))
        request.httpBody = Data(body.orderedJSONString.utf8)
        return request
    }

    private func makeInitializeRequest(id: Int, version: String) -> URLRequest {
        var request = baseRequest(session: nil)
        let params = JSONObject([
            ("protocolVersion", .string(version)),
            ("capabilities", .object(JSONObject([("tools", .object(JSONObject()))]))),
            ("clientInfo", .object(JSONObject([
                ("name", .string(McpProtocol.clientInfoName)),
                ("version", .string(McpProtocol.clientInfoVersion))
            ])))
        ])
        let body = Self.jsonRPCMessage(id: id, method: "initialize", params: .object(params))
        request.httpBody = Data(body.orderedJSONString.utf8)
        return request
    }

    private func makeNotificationRequest(method: String, params: JSONValue?, session: McpSession) -> URLRequest {
        var request = baseRequest(session: session)
        var pairs: [(String, JSONValue)] = [
            ("jsonrpc", .string("2.0")),
            ("method", .string(method))
        ]
        if let params { pairs.append(("params", params)) }
        request.httpBody = Data(JSONValue.object(JSONObject(pairs)).orderedJSONString.utf8)
        return request
    }

    private nonisolated static func jsonRPCMessage(id: Int, method: String, params: JSONValue) -> JSONValue {
        .object(JSONObject([
            ("jsonrpc", .string("2.0")),
            ("id", .number(Double(id))),
            ("method", .string(method)),
            ("params", params)
        ]))
    }

    /// The per-request `_meta` of the modern protocol: `protocolVersion` and `clientCapabilities` are
    /// required, `clientInfo` is a SHOULD.
    private nonisolated static func modernMeta(version: String) -> JSONValue {
        .object(JSONObject([
            (McpProtocol.metaProtocolVersionKey, .string(version)),
            (McpProtocol.metaClientInfoKey, .object(JSONObject([
                ("name", .string(McpProtocol.clientInfoName)),
                ("version", .string(McpProtocol.clientInfoVersion))
            ]))),
            (McpProtocol.metaClientCapabilitiesKey, .object(JSONObject([("tools", .object(JSONObject()))])))
        ]))
    }

    /// A modern request header value: visible ASCII is sent as is; values containing non-ASCII characters,
    /// control characters or leading / trailing whitespace are encoded as
    /// `=?base64?{base64 of the UTF-8 bytes}?=` (lowercase prefix and suffix). Put into a header verbatim,
    /// non-ASCII bytes would be rewritten by the system and the server, seeing header and body disagree,
    /// would answer `-32020`. Values that already look like the encoded form are encoded as well, so the
    /// peer does not decode them by mistake.
    nonisolated static func headerValue(_ value: String) -> String {
        let isPlain = value.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) }
            && value == value.trimmingCharacters(in: .whitespaces)
            && !value.hasPrefix("=?base64?")
        if isPlain { return value }
        return "=?base64?\(Data(value.utf8).base64EncodedString())?="
    }

    /// A valid `tools/list` result: `result` is an object with a `tools` array.
    private nonisolated static func isToolsListResult(_ message: JSONValue?) -> Bool {
        message?["result"]?["tools"]?.arrayValue != nil
    }

    /// A "recognizable modern error": matching any one of these marks the server as modern, and falling
    /// back to `initialize` is not allowed.
    /// 1. The error code is `-32022` / `-32021` / `-32020`;
    /// 2. the error's `message` or `data` contains a modern-only marker;
    /// 3. the error carries `data.supported`.
    private nonisolated static func isRecognizableModernError(_ error: JSONValue) -> Bool {
        if let code = error["code"]?.intValue, McpProtocol.modernErrorCodes.contains(code) { return true }
        if error["data"]?["supported"] != nil { return true }
        if let message = error["message"]?.stringValue, McpProtocol.containsModernMarker(message) { return true }
        if let data = error["data"], McpProtocol.containsModernMarker(data.orderedJSONString) { return true }
        return false
    }

    // MARK: - Transport

    /// Sends a request belonging to a negotiated session. When it is cancelled, the legacy protocol
    /// additionally sends a cancellation notification.
    private func send(
        _ request: URLRequest,
        id: Int,
        session: McpSession,
        allowsPreConnectRetry: Bool
    ) async throws -> McpExchange {
        do {
            return try await exchange(request, requestID: id, key: id, allowsPreConnectRetry: allowsPreConnectRetry)
        } catch let error as McpClientError where error.code == .cancelled {
            if session.generation == .session { sendCancelledNotification(requestID: id, session: session) }
            throw error
        }
    }

    /// The legacy cancellation notification: closing the response stream already cancels, this merely tells
    /// a legacy server it may stop working. Best effort - it is not awaited, failures are ignored and it
    /// costs the caller no time. The modern protocol has no such notification over Streamable HTTP.
    private func sendCancelledNotification(requestID: Int, session: McpSession) {
        let params = JSONValue.object(JSONObject([
            ("requestId", .number(Double(requestID))),
            ("reason", .string("User requested cancellation"))
        ]))
        var request = makeNotificationRequest(method: "notifications/cancelled", params: params, session: session)
        request.timeoutInterval = McpClientLimits.cancelNotificationTimeoutSeconds + McpHTTPLimits.urlSessionTimeoutMargin
        let urlSession = self.urlSession
        Task.detached {
            _ = try? await McpClient.execute(
                request,
                requestID: nil,
                session: urlSession,
                timeout: McpClientLimits.cancelNotificationTimeoutSeconds,
                allowsPreConnectRetry: false
            )
        }
    }

    /// One HTTP exchange. Cancelling the caller's Task, or calling `cancel()`, tears down the underlying
    /// connection and throws `cancelled`.
    /// - `requestID`: the JSON-RPC request id; notifications have none, pass `nil` (no response body is awaited).
    /// - `key`: the key in the cancellation table.
    private func exchange(
        _ request: URLRequest,
        requestID: Int?,
        key: Int,
        allowsPreConnectRetry: Bool
    ) async throws -> McpExchange {
        if Task.isCancelled { throw McpClientError.make(.cancelled) }
        // A second https gate: besides URL validation, the client itself never sends anything (tokens
        // included) to a non-https address.
        guard McpOrigin.isHTTPS(endpoint) else { throw McpClientError.make(.unreachable) }
        let urlSession = self.urlSession
        let timeout = callTimeout
        // Runs off the actor: reading the stream and parsing do not occupy it, so `cancel()` can always get
        // in. Cancellation is forwarded manually by the handler below.
        let task = Task<McpExchange, Error>.detached(priority: Task.currentPriority) {
            try await McpClient.execute(
                request,
                requestID: requestID,
                session: urlSession,
                timeout: timeout,
                allowsPreConnectRetry: allowsPreConnectRetry
            )
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private nonisolated static func execute(
        _ request: URLRequest,
        requestID: Int?,
        session: URLSession,
        timeout: Double,
        allowsPreConnectRetry: Bool
    ) async throws -> McpExchange {
        var attempt = 0
        while true {
            do {
                return try await McpHTTP.withDeadline(timeout) {
                    try await perform(request, requestID: requestID, session: session)
                }
            } catch let urlError as URLError where allowsPreConnectRetry && attempt == 0 && isPreConnect(urlError) {
                attempt += 1
                continue
            } catch {
                throw clientError(for: error)
            }
        }
    }

    /// Transport-level error -> error code. Cancellation and timeout each have their own code and are not
    /// folded into `unreachable`.
    private nonisolated static func clientError(for error: Error) -> McpClientError {
        switch error {
        case let error as McpClientError:
            return error
        case is CancellationError:
            return .make(.cancelled)
        case let error as URLError where error.code == .cancelled:
            return .make(.cancelled)
        case let error as URLError where error.code == .timedOut:
            return .make(.timeout)
        case McpHTTPError.timedOut:
            return .make(.timeout)
        case McpHTTPError.bodyTooLarge:
            return .make(.serverError)
        default:
            // Remaining network errors, non-https, and refused redirects.
            return .make(.unreachable)
        }
    }

    /// Sends the request and retrieves the JSON-RPC response **matching this request id**.
    ///
    /// SSE streams are parsed as they arrive: as soon as the matching final response is in hand it is
    /// returned and the connection closed, without waiting for the server to close the stream (the final
    /// response SHOULD end the stream, but that is not guaranteed). Both forms share the same byte limit.
    private nonisolated static func perform(
        _ request: URLRequest,
        requestID: Int?,
        session: URLSession
    ) async throws -> McpExchange {
        try await McpHTTP.withResponse(request, session: session, redirect: .sameOriginHTTPS) { head, bytes in
            var result = McpExchange(status: head.status, headers: head.headers, message: nil, mismatchedID: false)
            // A notification has no response to wait for: the status line is enough.
            guard let requestID else { return result }

            let limit = McpHTTPLimits.maxResponseBytes
            if let declared = head.headers["content-length"].flatMap({ Int($0) }), declared > limit {
                throw McpHTTPError.bodyTooLarge
            }

            var candidates: [JSONValue] = []
            if head.isEventStream {
                var parser = McpSSEParser()
                var received = 0
                for try await byte in bytes {
                    received += 1
                    guard received <= limit else { throw McpHTTPError.bodyTooLarge }
                    guard let message = parser.consume(byte) else { continue }
                    if isResponse(message, to: requestID) {
                        result.message = message
                        return result
                    }
                    candidates.append(message)
                }
                if let message = parser.finish() { candidates.append(message) }
            } else {
                let body = try await McpHTTP.readBody(bytes, limit: limit)
                if let value = try? JSONValue(data: body) {
                    candidates = [value]
                } else {
                    // Fallback for a dishonest Content-Type: try once more as SSE.
                    candidates = McpSSE.messages(in: body)
                }
            }

            result.message = candidates.first { isResponse($0, to: requestID) }
            // Notifications mixed into the stream have no result / error and do not count; only something
            // with a result / error that fails to match the id is a protocol error.
            result.mismatchedID = result.message == nil && candidates.contains { isJSONRPCResponse($0) }
            return result
        }
    }

    private nonisolated static func isJSONRPCResponse(_ message: JSONValue) -> Bool {
        message["jsonrpc"]?.stringValue == "2.0" && (message["result"] != nil || message["error"] != nil)
    }

    /// Whether this is the response to this request: **matched strictly by id**, with no "first response
    /// in the stream" fallback - a response with a mixed-up id may be the result of another call. The only
    /// exception is the "error with a null id" that JSON-RPC allows (the server could not read the request id).
    private nonisolated static func isResponse(_ message: JSONValue, to requestID: Int) -> Bool {
        guard isJSONRPCResponse(message) else { return false }
        if message["result"] == nil {
            switch message["id"] {
            case nil, .null?: return true
            default: break
            }
        }
        return message["id"]?.intValue == requestID
    }

    /// Retries once, and only for network errors that happen before the connection is established.
    /// `tools/call` never passes this switch.
    private nonisolated static func isPreConnect(_ error: URLError) -> Bool {
        switch error.code {
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .notConnectedToInternet, .secureConnectionFailed,
             .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .clientCertificateRejected, .clientCertificateRequired:
            return true
        default:
            return false
        }
    }
}

// MARK: - Transport-level intermediate types

/// The result of one JSON-RPC exchange: the HTTP status, the response headers (lowercased names) and the
/// response matching the request id.
private nonisolated struct McpExchange: Sendable {
    var status: Int
    var headers: [String: String]
    /// The JSON-RPC response matching this request id; `nil` when the body is empty, is not JSON-RPC, or
    /// the id does not match.
    var message: JSONValue?
    /// The body contains JSON-RPC responses, but none of them matches this request id.
    var mismatchedID: Bool
}

// MARK: - Tool definition parsing (`tools[]` of `tools/list`)

extension McpToolDefinition {
    /// Builds from a single tool object of `tools/list`; entries without a `name` are invalid and skipped.
    nonisolated init?(json: JSONValue) {
        guard let name = json["name"]?.stringValue, !name.isEmpty else { return nil }
        self.init(
            name: name,
            title: json["title"]?.stringValue,
            description: json["description"]?.stringValue,
            inputSchema: json["inputSchema"] ?? .object(JSONObject()),
            annotations: json["annotations"] ?? .object(JSONObject())
        )
    }
}
