import Foundation

// MARK: - Value types shared with the protocol
//
// This layer only holds the values and data structures that must be identical on iOS, Android and web. Shared test
// vectors live in `shared/test-fixtures/mcp/`.

/// Sign-in method chosen by the user.
nonisolated enum McpAuthKind: String, Codable, Sendable, Equatable, CaseIterable {
    case auto
    case token
}

/// Negotiated protocol generation. `stateless` = 2026-07-28 and later; `session` = legacy handshake + session.
nonisolated enum McpProtocolGeneration: String, Codable, Sendable, Equatable {
    case stateless
    case session
}

/// Connection status.
nonisolated enum McpConnectionStatus: String, Codable, Sendable, Equatable {
    case connected
    case needsAuth
    case unreachable
    case unknown
}

/// Tool permission.
nonisolated enum McpToolPermission: String, Codable, Sendable, Equatable {
    case auto
    case ask
    case off

    /// Tools that declare themselves read-only "run automatically"; everything else (including tools with no
    /// declaration) "asks every time".
    static func defaultFor(readOnly: Bool) -> McpToolPermission {
        readOnly ? .auto : .ask
    }
}

/// Kind of tool change.
nonisolated enum McpToolChangeKind: String, Sendable, Equatable {
    case added
    case changed
    case removed
}

/// Closed set of error codes. The same set is fed back to the model and written to `toolSteps.errorCode`,
/// **never carrying the server's original text**.
nonisolated enum McpErrorCode: String, Sendable, Equatable, CaseIterable {
    case userDenied = "user_denied"
    case needsAuth = "needs_auth"
    case authSkipped = "auth_skipped"
    case timeout
    case unreachable
    case serverError = "server_error"
    case toolError = "tool_error"
    case resultTooLarge = "result_too_large"
    case needsInputUnsupported = "needs_input_unsupported"
    case toolUnavailable = "tool_unavailable"
    case cancelled
    case interrupted
}

// MARK: - Server record

/// Server record, stored in the local database. **It has no credential fields at all** (credentials only go
/// through `McpCredentialStore`).
nonisolated struct McpServerRecord: Codable, Sendable, Equatable, Identifiable {
    static let maxNameLength = 64
    static let maxURLLength = 2048
    static let currentSchemaVersion = 1

    var id: UUID
    var name: String
    var slug: String
    var url: String
    var authKind: McpAuthKind
    var localOnly: Bool
    var iconURL: String?
    var createdAt: Date
    var updatedAt: Date
    var schemaVersion: Int

    init(
        id: UUID = UUID(),
        name: String,
        slug: String,
        url: String,
        authKind: McpAuthKind,
        localOnly: Bool,
        iconURL: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        schemaVersion: Int = McpServerRecord.currentSchemaVersion
    ) {
        self.id = id
        self.name = name
        self.slug = slug
        self.url = url
        self.authKind = authKind
        self.localOnly = localOnly
        self.iconURL = iconURL
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }
}

/// Runtime limits. The model catalog may carry an `mcpRuntimeConfig` section; when it does not (a self-hosted
/// catalog, or one not fetched yet) the built-in fallbacks apply, and the feature is not disabled because of it.
nonisolated struct McpRuntimeConfig: Sendable, Equatable {
    var version: Int
    var enabled: Bool
    var maxServers: Int
    var maxToolsPerRequest: Int
    var maxToolDefinitionBytes: Int
    var maxResultChars: Int
    var callTimeoutSeconds: Double
    var maxSteps: Int

    init(
        version: Int = 1,
        enabled: Bool = true,
        maxServers: Int = 20,
        maxToolsPerRequest: Int = 40,
        maxToolDefinitionBytes: Int = 16_384,
        maxResultChars: Int = 24_000,
        callTimeoutSeconds: Double = 60,
        maxSteps: Int = 6
    ) {
        self.version = version
        self.enabled = enabled
        self.maxServers = maxServers
        self.maxToolsPerRequest = maxToolsPerRequest
        self.maxToolDefinitionBytes = maxToolDefinitionBytes
        self.maxResultChars = maxResultChars
        self.callTimeoutSeconds = callTimeoutSeconds
        self.maxSteps = maxSteps
    }

    /// Fallback values used when the catalog carries no configuration.
    static let fallback = McpRuntimeConfig()

    /// Allowed range of each numeric field. Configured values outside the range are clamped to the bounds: one
    /// mistyped number in the configuration (0, a negative, a few extra zeros) should neither break the feature as a
    /// whole (limit 0 = no server can be added, timeout 0 = every call times out at once) nor void the protective
    /// limits (a single tool definition of several GB, results never truncated). The upper bounds are hard client
    /// caps, independent of the catalog's values.
    enum Bounds {
        static let maxServers = 1...100
        static let maxToolsPerRequest = 1...128
        static let maxToolDefinitionBytes = 1_024...262_144
        static let maxResultChars = 1_000...200_000
        static let callTimeoutSeconds = 5.0...600.0
        static let maxSteps = 1...8
    }

    /// Parses the top-level `mcpRuntimeConfig` of `/api/metadata`. Missing or wrongly typed fields use the fallback;
    /// a missing section returns the fallback; numbers outside `Bounds` are clamped.
    init(json: JSONValue?) {
        var config = McpRuntimeConfig.fallback
        guard case .object(let root)? = json else {
            self = config
            return
        }
        // The version is not a quantity, so clamping it makes no sense: only integers ≥ 1 are accepted, anything else
        // keeps the fallback.
        if let version = root["version"]?.intValue, version >= 1 { config.version = version }
        if let enabled = root["enabled"]?.boolValue { config.enabled = enabled }
        if let value = Self.clamped(root["maxServers"], to: Bounds.maxServers) { config.maxServers = value }
        if let value = Self.clamped(root["maxToolsPerRequest"], to: Bounds.maxToolsPerRequest) {
            config.maxToolsPerRequest = value
        }
        if let value = Self.clamped(root["maxToolDefinitionBytes"], to: Bounds.maxToolDefinitionBytes) {
            config.maxToolDefinitionBytes = value
        }
        if let value = Self.clamped(root["maxResultChars"], to: Bounds.maxResultChars) { config.maxResultChars = value }
        if let timeout = root["callTimeoutSeconds"]?.doubleValue, timeout.isFinite {
            config.callTimeoutSeconds = min(max(timeout, Bounds.callTimeoutSeconds.lowerBound), Bounds.callTimeoutSeconds.upperBound)
        }
        if let value = Self.clamped(root["maxSteps"], to: Bounds.maxSteps) { config.maxSteps = value }
        self = config
    }

    /// Number → integer clamped to the range. Clamp on `Double` first, then convert: values like `1e30` would trap
    /// when converted straight to `Int`. Returns `nil` when the value is not a number (or not finite), and the caller
    /// keeps the fallback.
    private static func clamped(_ value: JSONValue?, to range: ClosedRange<Int>) -> Int? {
        guard let number = value?.doubleValue, number.isFinite else { return nil }
        let bounded = min(max(number, Double(range.lowerBound)), Double(range.upperBound))
        return Int(bounded.rounded(.down))
    }

    /// Step limit: the configured value capped at 8 (default 6).
    var effectiveMaxSteps: Int { min(maxSteps, 8) }
}

// MARK: - Tool definitions and snapshots

/// One tool returned by the server (an item of `tools[]` in `tools/list`). `annotations` are all hints self-reported
/// by a third party and are treated as untrusted.
nonisolated struct McpToolDefinition: Sendable, Equatable {
    var name: String
    var title: String?
    var description: String?
    var inputSchema: JSONValue
    var annotations: JSONValue

    init(
        name: String,
        title: String? = nil,
        description: String? = nil,
        inputSchema: JSONValue = .object(JSONObject()),
        annotations: JSONValue = .object(JSONObject())
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.annotations = annotations
    }

    /// Display name precedence: `title` → `annotations.title` → `name`.
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if case .object(let dict) = annotations,
           case .string(let annotationTitle)? = dict["title"],
           !annotationTitle.isEmpty {
            return annotationTitle
        }
        return name
    }

    /// Read-only declaration. Missing = not declared = treated as modifying data.
    var readOnlyHint: Bool? {
        guard case .object(let dict) = annotations else { return nil }
        return dict["readOnlyHint"]?.boolValue
    }

    var readOnly: Bool { readOnlyHint == true }
}

/// Tool snapshot: `serverId` + original tool name → title, description, parameter definition, read-only declaration,
/// content hash, quarantine flag and "too large to use" flag.
nonisolated struct McpToolSnapshot: Sendable, Equatable {
    var serverId: UUID
    var toolName: String
    var title: String
    var description: String?
    var inputSchema: JSONValue
    var annotations: JSONValue
    var contentHash: String
    var readOnly: Bool
    var pendingReview: Bool
    var oversized: Bool
    var updatedAt: Date

    init(
        serverId: UUID,
        toolName: String,
        title: String,
        description: String?,
        inputSchema: JSONValue,
        annotations: JSONValue,
        contentHash: String,
        readOnly: Bool,
        pendingReview: Bool = false,
        oversized: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.serverId = serverId
        self.toolName = toolName
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.annotations = annotations
        self.contentHash = contentHash
        self.readOnly = readOnly
        self.pendingReview = pendingReview
        self.oversized = oversized
        self.updatedAt = updatedAt
    }
}

/// One tool change.
nonisolated struct McpToolChange: Sendable, Equatable {
    var kind: McpToolChangeKind
    var toolName: String
    var title: String
}

/// Connection state record. The legacy protocol's session identifier is kept only in memory and in the local
/// connection state, never in logs.
nonisolated struct McpConnectionState: Sendable, Equatable {
    var serverId: UUID
    var status: McpConnectionStatus
    var lastSuccessAt: Date?
    var negotiatedVersion: String?
    var generation: McpProtocolGeneration?
    var sessionId: String?

    init(
        serverId: UUID,
        status: McpConnectionStatus = .unknown,
        lastSuccessAt: Date? = nil,
        negotiatedVersion: String? = nil,
        generation: McpProtocolGeneration? = nil,
        sessionId: String? = nil
    ) {
        self.serverId = serverId
        self.status = status
        self.lastSuccessAt = lastSuccessAt
        self.negotiatedVersion = negotiatedVersion
        self.generation = generation
        self.sessionId = sessionId
    }
}

// MARK: - Protocol constants

nonisolated enum McpProtocol {
    /// Latest version we support.
    static let modernVersion = "2026-07-28"
    /// In the legacy handshake the client SHOULD send the latest version it supports; the server may answer with
    /// another version it supports.
    static let legacyInitializeVersion = "2025-11-25"
    /// Legacy versions we support.
    static let legacyVersions: Set<String> = ["2025-11-25", "2025-06-18", "2025-03-26"]
    /// Recognizable modern JSON-RPC error codes: seeing one means the server is modern and we must not fall back to
    /// initialize.
    static let modernErrorCodes: Set<Int> = [-32020, -32021, unsupportedVersionErrorCode]
    /// `UnsupportedProtocolVersion`: carries `data.supported`; pick a version from it and retry.
    static let unsupportedVersionErrorCode = -32022
    static let invalidParamsErrorCode = -32602
    static let methodNotFoundErrorCode = -32601
    /// Markers specific to the modern protocol: any of them in an error's `message` / `data` means modern. The
    /// generic `-32602` a legacy server returns before `initialize` contains none of these strings, so it correctly
    /// falls back.
    static let modernErrorMarkers = [
        "io.modelcontextprotocol/",
        "_meta",
        "resultType",
    ]
    /// Request **header names** specific to the modern protocol (lowercase; header names compare case-insensitively).
    ///
    /// Deliberately listed one by one instead of matching the `Mcp-` prefix, and **without `MCP-Protocol-Version`**:
    /// the `Mcp-Session-Id` and `MCP-Protocol-Version` headers are used by legacy versions too. If they counted as
    /// modern markers when they show up in a legacy server's error text ("Bad Request: Mcp-Session-Id header is
    /// required", "Unsupported MCP-Protocol-Version"), such servers would be misjudged as modern, never fall back to
    /// `initialize`, and never connect.
    static let modernHeaderMarkers = [
        "mcp-method",
        "mcp-name",
        "mcp-param-",
    ]

    static func containsModernMarker(_ text: String) -> Bool {
        if modernErrorMarkers.contains(where: { text.contains($0) }) { return true }
        let lowered = text.lowercased()
        return modernHeaderMarkers.contains { lowered.contains($0) }
    }
    /// Page limit for `tools/list` (a client-side limit, not taken from the specification).
    static let maxToolsListPages = 20
    /// Key name of the per-request `_meta` entry in the modern version.
    static let metaProtocolVersionKey = "io.modelcontextprotocol/protocolVersion"
    static let metaClientInfoKey = "io.modelcontextprotocol/clientInfo"
    static let metaClientCapabilitiesKey = "io.modelcontextprotocol/clientCapabilities"
    static let metaServerInfoKey = "io.modelcontextprotocol/serverInfo"
    static let clientInfoName = "Oriveo"
    static let clientInfoVersion = "1.0.0"
}
