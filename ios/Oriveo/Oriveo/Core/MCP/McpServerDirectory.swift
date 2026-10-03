import Foundation

/// Single entry point for remote MCP server records in the app: opens the store of a storage partition and
/// updates or removes records together with their credentials. Records, permissions and credentials stay on this
/// device.
@MainActor
final class McpServerDirectory {
    let credentialStore: McpCredentialStore
    private let openStore: (String) throws -> McpServerStore
    private let makeAuthorizer: (McpCredentialStore) -> McpAuthorizer
    private var authorizers: [String: McpAuthorizer] = [:]

    init(
        credentialStore: McpCredentialStore = .shared,
        openStore: @escaping (String) throws -> McpServerStore = {
            McpServerStore(dbPool: try DatabaseManager.shared.openIfNeeded(for: $0))
        },
        makeAuthorizer: @escaping (McpCredentialStore) -> McpAuthorizer = {
            McpAuthorizer(
                transport: URLSessionMcpAuthTransport(),
                browser: McpSystemBrowserSession(),
                credentialStore: $0
            )
        }
    ) {
        self.credentialStore = credentialStore
        self.openStore = openStore
        self.makeAuthorizer = makeAuthorizer
    }

    /// The authorizer for this partition; there is exactly one per process. Serialization of concurrent refreshes lives
    /// in the authorizer instance: if the chat loop, the add flow and the management page each created their own, two
    /// of them would exchange the same refresh token at once, and the later one would be answered `invalid_grant` by
    /// the authorization server and wipe the new token the other one just obtained.
    func authorizer(for uid: String) -> McpAuthorizer {
        if let existing = authorizers[uid] { return existing }
        let created = makeAuthorizer(credentialStore)
        authorizers[uid] = created
        return created
    }

    /// Server store of one storage partition. `uid` must be the currently bound partition
    /// (`AppState.sessionPartitionUID`).
    func store(for uid: String) throws -> McpServerStore {
        try openStore(uid)
    }

    /// Where requests for this server should go; with `needsAddress` no request may be sent.
    func endpoint(for record: McpServerRecord, uid: String) -> McpServerEndpointResolution {
        McpServerEndpoint.resolve(record, uid: uid, credentialStore: credentialStore)
    }

    /// Updates a server record. If the `url` of a `localOnly` record is a full address (the address was
    /// re-entered), it is stored in the credential store first and only the display address goes into the
    /// database; a failed store throws and the record is unchanged.
    func update(_ record: McpServerRecord, uid: String) throws {
        if record.localOnly, McpLocalOnly.displayURL(record.url) != record.url {
            try credentialStore.saveEndpoint(record.url, serverId: record.id, uid: uid)
        }
        try openStore(uid).updateServer(record)
    }

    /// Removes a server: deletes its credentials and then the record with everything kept for it.
    ///
    /// Credentials go first: when they cannot be deleted this throws and the record stays, so the user can try
    /// again. The other way round the record would be gone while the token is still on the device, with nothing
    /// left in the app to clear it from.
    func remove(serverId: UUID, uid: String) throws {
        let store = try openStore(uid)
        try credentialStore.delete(serverId: serverId, uid: uid)
        try store.deleteServer(id: serverId)
    }

    /// Changes one tool's permission. Also revokes this tool's "allow for this conversation" grant in every
    /// conversation: the user just tightened it to "ask every time" or "don't use", and an earlier tap must not
    /// bypass that.
    func setToolPermission(
        _ permission: McpToolPermission,
        serverId: UUID,
        toolName: String,
        uid: String,
        grants: McpConversationGrants = .shared
    ) throws {
        try store(for: uid).setToolPermission(permission, serverId: serverId, toolName: toolName)
        grants.revoke(serverId: serverId, toolNames: [toolName])
    }

    /// Re-enters the full address of a `localOnly` server (after restoring the device from a backup the address is
    /// not on the device). The new address must be same-origin with the record's display address (credentials are
    /// only sent to the recorded origin), otherwise it is rejected. The full address goes into the credential store
    /// and the database still holds only the display address.
    func restoreEndpoint(serverId: UUID, urlString: String, uid: String) throws {
        let store = try openStore(uid)
        guard let record = try store.fetchServer(id: serverId),
              case .success(let url) = McpEndpoint.check(urlString),
              let recorded = URL(string: record.url),
              McpProtectedResourceDiscovery.originString(url) == McpProtectedResourceDiscovery.originString(recorded)
        else {
            throw McpServerDirectoryError.endpointMismatch
        }
        try credentialStore.saveEndpoint(url.absoluteString, serverId: serverId, uid: uid)
    }

    /// Overview for the management page and the settings entry.
    func overview(uid: String) throws -> [McpServerSummary] {
        try McpServerOverview.load(store: try store(for: uid), credentialStore: credentialStore, uid: uid)
    }

    /// Data for the detail page. `nil` when the server is no longer on this device.
    func detail(serverId: UUID, uid: String) throws -> McpServerDetail? {
        try McpServerOverview.detail(
            serverId: serverId, store: try store(for: uid), credentialStore: credentialStore, uid: uid
        )
    }

    /// Coordinator for the add flow: persists through this partition's store.
    func makeAddCoordinator(
        probe: McpAddProbe,
        uid: String,
        runtimeConfig: McpRuntimeConfig = .fallback
    ) throws -> McpAddCoordinator {
        McpAddCoordinator(
            probe: probe,
            store: try openStore(uid),
            credentialStore: credentialStore,
            runtimeConfig: runtimeConfig
        )
    }
}

nonisolated enum McpServerDirectoryError: Error, Equatable {
    /// The re-entered address is invalid, or not same-origin with the recorded server.
    case endpointMismatch
}
