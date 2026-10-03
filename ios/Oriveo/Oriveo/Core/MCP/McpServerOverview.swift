import Foundation

// MARK: - Server overview for the management page and the settings entry
//
// Reads local storage only and sends no requests. The status is decided in the same order as the tool panel
// (`McpToolPanelModel.status`): first whether the address is on this device, then the connection status, then whether
// any tool is awaiting confirmation.

/// Current state of one server. The first three map to the status pill; `needsReview` means "tools were updated" and
/// `needsAddress` means "the address needs to be entered again".
nonisolated enum McpServerHealth: Sendable, Equatable {
    case connected
    case needsAuth
    case unreachable
    /// Some tools are quarantined, waiting for the user's confirmation.
    case needsReview
    /// The full address of a `localOnly` server is not on this device (restored from a backup / new device): no
    /// request can be sent until the address is entered again.
    case needsAddress

    var needsAttention: Bool { self != .connected }
}

nonisolated struct McpServerSummary: Sendable, Equatable, Identifiable {
    var record: McpServerRecord
    var health: McpServerHealth
    /// Number of tools the server provides (including quarantined and "don't use" ones; this is the size of the
    /// server, not the number sent with a request).
    var toolCount: Int
    var lastSuccessAt: Date?

    var id: UUID { record.id }
}

/// All local data the detail page needs.
nonisolated struct McpServerDetail: Sendable, Equatable {
    var summary: McpServerSummary
    var snapshots: [McpToolSnapshot]
    var permissions: [String: McpToolPermission]
    /// Whether this device holds credentials for the server (the "Sign-in method" row uses it to tell "browser
    /// sign-in / access token / not required").
    var signIn: McpServerSignIn

    var record: McpServerRecord { summary.record }
    var health: McpServerHealth { summary.health }

    var readOnlyTools: [McpToolSnapshot] { snapshots.filter(\.readOnly) }
    var changingTools: [McpToolSnapshot] { snapshots.filter { !$0.readOnly } }

    /// The permission currently in effect for this tool: the default when there is no record.
    func permission(for snapshot: McpToolSnapshot) -> McpToolPermission {
        permissions[snapshot.toolName] ?? McpToolPermission.defaultFor(readOnly: snapshot.readOnly)
    }
}

/// Value of the "Sign-in method" row on the detail page.
nonisolated enum McpServerSignIn: Sendable, Equatable {
    case browser
    case token
    case notNeeded
}

nonisolated enum McpServerOverview {
    static func health(
        endpoint: McpServerEndpointResolution,
        connection: McpConnectionState?,
        snapshots: [McpToolSnapshot]
    ) -> McpServerHealth {
        guard case .ready = endpoint else { return .needsAddress }
        switch connection?.status {
        case .needsAuth: return .needsAuth
        case .unreachable: return .unreachable
        case .connected, .unknown, nil:
            return snapshots.contains(where: \.pendingReview) ? .needsReview : .connected
        }
    }

    static func summary(
        _ record: McpServerRecord,
        store: McpServerStore,
        credentialStore: McpCredentialStore,
        uid: String
    ) throws -> McpServerSummary {
        let connection = try store.fetchConnectionState(serverId: record.id)
        let snapshots = try store.fetchToolSnapshots(serverId: record.id)
        return McpServerSummary(
            record: record,
            health: health(
                endpoint: McpServerEndpoint.resolve(record, uid: uid, credentialStore: credentialStore),
                connection: connection,
                snapshots: snapshots
            ),
            toolCount: snapshots.count,
            lastSuccessAt: connection?.lastSuccessAt
        )
    }

    static func load(store: McpServerStore, credentialStore: McpCredentialStore, uid: String) throws -> [McpServerSummary] {
        try store.fetchAllServers().map {
            try summary($0, store: store, credentialStore: credentialStore, uid: uid)
        }
    }

    static func detail(
        serverId: UUID,
        store: McpServerStore,
        credentialStore: McpCredentialStore,
        uid: String
    ) throws -> McpServerDetail? {
        guard let record = try store.fetchServer(id: serverId) else { return nil }
        let credentials = credentialStore.load(serverId: serverId, uid: uid)
        let signIn: McpServerSignIn
        if credentials?.accessToken != nil || credentials?.refreshToken != nil {
            signIn = .browser
        } else if record.authKind == .token || credentials?.pastedToken != nil {
            signIn = .token
        } else if credentials?.issuer != nil {
            // Signed in through the browser before and the token has since been invalidated (only the client
            // registration is left).
            signIn = .browser
        } else {
            signIn = .notNeeded
        }
        return McpServerDetail(
            summary: try summary(record, store: store, credentialStore: credentialStore, uid: uid),
            snapshots: try store.fetchToolSnapshots(serverId: serverId),
            permissions: try store.fetchToolPermissions(serverId: serverId),
            signIn: signIn
        )
    }

    static func attentionCount(_ servers: [McpServerSummary]) -> Int {
        servers.filter(\.health.needsAttention).count
    }
}

/// Data for the subtitle of the "MCP servers" row in settings.
nonisolated struct McpSettingsEntrySummary: Sendable, Equatable {
    var serverCount: Int
    var attentionCount: Int

    init(serverCount: Int, attentionCount: Int) {
        self.serverCount = serverCount
        self.attentionCount = attentionCount
    }

    init(_ servers: [McpServerSummary]) {
        serverCount = servers.count
        attentionCount = McpServerOverview.attentionCount(servers)
    }
}
