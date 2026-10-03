import Foundation

// MARK: - Actions on saved servers
//
// Re-reading tools, confirming tool changes, re-authorizing, replacing the access token and probing connection
// status. The management page, the tool panel and "Re-authorize" on a step block all go through here; the UI never
// touches the protocol client or the authorizer directly.
//
// Every action ends by writing the connection status back to the device (`connected` / `needsAuth` / `unreachable`);
// the status pill and the tool panel's row status read it from there.

/// One tool change waiting for the user's confirmation (one row of the change list).
nonisolated struct McpPendingToolChange: Sendable, Equatable, Identifiable {
    var kind: McpToolChangeKind
    var toolName: String
    var title: String
    var readOnly: Bool
    /// Permission that takes effect after confirmation (the default for new tools; changed tools can only be
    /// tightened, never loosened). `nil` for removed tools.
    var permissionAfter: McpToolPermission?
    /// The description the server gives now, verbatim.
    var description: String?
    /// The description before the change. Only known right after re-reading tools, since the device keeps just the
    /// latest snapshot.
    var previousDescription: String?

    var id: String { "\(kind.rawValue):\(toolName)" }
}

nonisolated enum McpRefreshResult: Sendable, Equatable {
    /// The tool list was read. `changes` holds the changes detected this time (empty when there are none).
    case connected(changes: [McpToolChange])
    case needsAuth
    case unreachable
    case needsAddress
    /// The server is no longer on this device (it was removed in the meantime).
    case gone
}

nonisolated enum McpConfirmChangesResult: Sendable, Equatable {
    /// `stillPending`: tools the server changed again during confirmation; they stay quarantined and the UI must have
    /// the user review them again.
    case confirmed(stillPending: [String])
    case needsAuth
    case unreachable
    case needsAddress
    case gone
}

nonisolated enum McpReauthPreparation: Sendable, Equatable {
    /// Browser sign-in is possible: the UI first shows the pre-sign-in notice, then calls `completeReauthorization`
    /// once the user agrees.
    case ready(plan: McpAuthorizationPlan, authorizationHost: String, serverHost: String)
    /// This server uses an access token, or does not support automatic sign-in: the UI shows the token field.
    case needsToken
    /// It actually connects (token refresh succeeded / the server no longer requires sign-in).
    case connected
    case unreachable
    case needsAddress
    case gone
}

nonisolated enum McpReauthOutcome: Sendable, Equatable {
    case connected
    case cancelled
    case unreachable
    case failed
    case gone
}

nonisolated enum McpTokenSubmitOutcome: Sendable, Equatable {
    case connected
    /// The server does not accept this token: it is not saved.
    case rejected
    case unreachable
    case gone
}

nonisolated final class McpServerActions: Sendable {
    private let store: McpServerStore
    private let credentialStore: McpCredentialStore
    private let uid: String
    private let runtimeConfig: McpRuntimeConfig
    private let authorizer: McpAuthorizer
    private let makeClient: @Sendable (URL) -> McpClient
    private let now: @Sendable () -> Date
    private let onReauthorized: @Sendable (UUID) async -> Void
    private let grants: McpConversationGrants

    /// `credentialStore` must be the same one `authorizer` uses. `onReauthorized` is called after signing in again
    /// succeeded and the connection status was written back as `connected`: in production it is wired to
    /// `McpReauthorizationCoordinator.serverReauthorized`, so steps parked on this server resume where they stopped.
    init(
        store: McpServerStore,
        credentialStore: McpCredentialStore = .shared,
        uid: String,
        runtimeConfig: McpRuntimeConfig = .fallback,
        authorizer: McpAuthorizer,
        makeClient: (@Sendable (URL) -> McpClient)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        grants: McpConversationGrants = .shared,
        onReauthorized: @escaping @Sendable (UUID) async -> Void = { _ in }
    ) {
        self.grants = grants
        self.store = store
        self.credentialStore = credentialStore
        self.uid = uid
        self.runtimeConfig = runtimeConfig
        self.authorizer = authorizer
        self.makeClient = makeClient ?? { McpClient(endpoint: $0, runtimeConfig: runtimeConfig) }
        self.now = now
        self.onReauthorized = onReauthorized
    }

    // MARK: Connection

    private enum Connection {
        case connected(McpClient, McpSession)
        case needsAuth(McpClient, URL)
        case unreachable
        case needsAddress
        case gone
    }

    private func endpoint(of serverId: UUID) -> (record: McpServerRecord, endpoint: McpServerEndpointResolution)? {
        guard let record = try? store.fetchServer(id: serverId) else { return nil }
        return (record, McpServerEndpoint.resolve(record, uid: uid, credentialStore: credentialStore))
    }

    /// Connects once with the token stored on this device (refreshing it first if it is about to expire). Does not
    /// sign in again.
    private func connectSaved(_ serverId: UUID) async -> Connection {
        guard let target = endpoint(of: serverId) else { return .gone }
        guard let url = target.endpoint.url else { return .needsAddress }
        let client = makeClient(url)
        let token: String?
        do {
            token = try await authorizer.validAccessToken(serverId: serverId, uid: uid)
        } catch let error as McpAuthorizerError where error.isTransient {
            // A transient error (network / 5xx) does not prove that signing in again is needed.
            return .unreachable
        } catch {
            return .needsAuth(client, url)
        }
        switch await client.connect(bearerToken: token) {
        case .connected(let session): return .connected(client, session)
        case .needsAuth: return .needsAuth(client, url)
        case .notMcp, .unreachable, .failed: return .unreachable
        }
    }

    private func saveStatus(_ serverId: UUID, _ status: McpConnectionStatus, session: McpSession? = nil) {
        let current = try? store.fetchConnectionState(serverId: serverId)
        // Failing to write the state does not affect this action's result; the next probe writes it again.
        try? store.saveConnectionState(McpConnectionState(
            serverId: serverId,
            status: status,
            lastSuccessAt: status == .connected ? now() : current?.lastSuccessAt,
            negotiatedVersion: session?.protocolVersion ?? current?.negotiatedVersion,
            generation: session?.generation ?? current?.generation,
            sessionId: status == .connected ? session?.sessionId : nil
        ))
    }

    /// Reads the tool list. On failure writes the connection status back and returns `nil` (the caller tells
    /// `needsAuth` from other failures by the status written back).
    private func listTools(_ client: McpClient, serverId: UUID) async -> (tools: [McpToolDefinition]?, needsAuth: Bool) {
        do {
            return (try await client.listTools(), false)
        } catch let error as McpClientError where error.code == .needsAuth {
            saveStatus(serverId, .needsAuth)
            return (nil, true)
        } catch {
            saveStatus(serverId, .unreachable)
            return (nil, false)
        }
    }

    // MARK: Re-reading tools

    /// Re-reads the tool list and persists it. New and changed tools go back into quarantine; permission records of
    /// removed tools are cleared; new tools get **no permission written in advance**: the default is applied only at
    /// confirmation, which lets the UI tell "new" (no permission record) from "description changed" (has one).
    func refreshTools(serverId: UUID) async -> McpRefreshResult {
        switch await connectSaved(serverId) {
        case .gone: return .gone
        case .needsAddress: return .needsAddress
        case .unreachable:
            saveStatus(serverId, .unreachable)
            return .unreachable
        case .needsAuth:
            saveStatus(serverId, .needsAuth)
            return .needsAuth
        case .connected(let client, let session):
            let listed = await listTools(client, serverId: serverId)
            guard let definitions = listed.tools else { return listed.needsAuth ? .needsAuth : .unreachable }
            do {
                guard (try? store.fetchServer(id: serverId)) != nil else { return .gone }
                do {
                    let changes = try saveCatalog(serverId: serverId, definitions: definitions)
                    saveStatus(serverId, .connected, session: session)
                    if !changes.isEmpty {
                        // A tool whose definition changed (or disappeared) loses any earlier "allow for this
                        // conversation" grant.
                        grants.revoke(serverId: serverId, toolNames: Set(changes.map { $0.toolName }))
                    }
                    return .connected(changes: changes)
                } catch {
                    return .unreachable
                }
            }
        }
    }

    private func saveCatalog(serverId: UUID, definitions: [McpToolDefinition]) throws -> [McpToolChange] {
        let existing = try store.fetchToolSnapshots(serverId: serverId)
        let incoming = McpToolCatalog.snapshots(
            serverId: serverId, definitions: definitions, runtimeConfig: runtimeConfig, existing: existing, now: now()
        )
        let names = Set(incoming.map(\.toolName))
        let permissions = try store.fetchToolPermissions(serverId: serverId).filter { names.contains($0.key) }
        try store.replaceToolCatalog(serverId: serverId, snapshots: incoming, permissions: permissions)
        return McpToolCatalog.changes(existing: existing, incoming: incoming)
    }

    /// Probes the connection status only (pull to refresh on the list page): does not read the tool list or touch the
    /// catalog.
    @discardableResult
    func probe(serverId: UUID) async -> McpConnectionStatus? {
        switch await connectSaved(serverId) {
        case .gone, .needsAddress: return nil
        case .unreachable:
            saveStatus(serverId, .unreachable)
            return .unreachable
        case .needsAuth:
            saveStatus(serverId, .needsAuth)
            return .needsAuth
        case .connected(_, let session):
            saveStatus(serverId, .connected, session: session)
            return .connected
        }
    }

    /// Pull to refresh on the list page: re-probes the connection status of every server.
    func probeAll() async {
        guard let servers = try? store.fetchAllServers() else { return }
        await withTaskGroup(of: Void.self) { group in
            for server in servers {
                group.addTask { await self.probe(serverId: server.id) }
            }
        }
    }

    // MARK: Confirming tool changes

    /// Tools on this server waiting for the user's confirmation (the quarantined ones in the local snapshot). Those
    /// without a permission record are new; those with one had their description / parameters / title changed.
    /// `removed` and `previous` come from a re-read that was just performed (no historical snapshots are kept on the
    /// device).
    static func pendingChanges(
        snapshots: [McpToolSnapshot],
        permissions: [String: McpToolPermission],
        removed: [McpToolChange] = [],
        previous: [McpToolSnapshot] = []
    ) -> [McpPendingToolChange] {
        let previousByName = Dictionary(previous.map { ($0.toolName, $0) }, uniquingKeysWith: { first, _ in first })
        var result = snapshots.filter(\.pendingReview).map { snapshot in
            let current = permissions[snapshot.toolName]
            return McpPendingToolChange(
                kind: current == nil ? .added : .changed,
                toolName: snapshot.toolName,
                title: snapshot.title,
                readOnly: snapshot.readOnly,
                permissionAfter: McpToolCatalog.permissionAfterConfirming(snapshot, current: current),
                description: snapshot.description,
                previousDescription: current == nil ? nil : previousByName[snapshot.toolName]?.description
            )
        }
        for change in removed where change.kind == .removed {
            let old = previousByName[change.toolName]
            result.append(McpPendingToolChange(
                kind: .removed, toolName: change.toolName, title: change.title, readOnly: old?.readOnly ?? false,
                permissionAfter: nil, description: old?.description, previousDescription: nil
            ))
        }
        return result
    }

    /// The user confirms the changes. **What is confirmed is the snapshot the user saw**: the definitions are fetched
    /// from the server once more, and only tools whose hash and title still match what the user saw leave quarantine;
    /// mismatching ones stay quarantined and the server's current definition is stored as the new snapshot awaiting
    /// confirmation. Permissions can only be tightened, never loosened.
    func confirmChanges(serverId: UUID) async -> McpConfirmChangesResult {
        switch await connectSaved(serverId) {
        case .gone: return .gone
        case .needsAddress: return .needsAddress
        case .unreachable:
            saveStatus(serverId, .unreachable)
            return .unreachable
        case .needsAuth:
            saveStatus(serverId, .needsAuth)
            return .needsAuth
        case .connected(let client, let session):
            let listed = await listTools(client, serverId: serverId)
            guard let definitions = listed.tools else { return listed.needsAuth ? .needsAuth : .unreachable }
            do {
                guard (try? store.fetchServer(id: serverId)) != nil else { return .gone }
                do {
                    let seen = try store.fetchToolSnapshots(serverId: serverId)
                    let confirmation = McpToolCatalog.confirm(
                        seen, definitions: definitions,
                        permissions: try store.fetchToolPermissions(serverId: serverId),
                        runtimeConfig: runtimeConfig, now: now()
                    )
                    // The server's current full set: tools the user confirmed stay released; tools that changed again
                    // during confirmation, and tools that appeared in the meantime, are quarantined under their
                    // latest definition.
                    let confirmed = confirmation.snapshots.filter { snapshot in !snapshot.pendingReview }
                    let next = McpToolCatalog.snapshots(
                        serverId: serverId, definitions: definitions, runtimeConfig: runtimeConfig,
                        existing: confirmed, now: now()
                    )
                    let names = Set(next.map { $0.toolName })
                    // Tools still in quarantine get no permission written: each is either newly appeared (stays
                    // "new") or keeps its pre-confirmation record.
                    let stillPending = Set(next.filter { $0.pendingReview }.map { $0.toolName })
                    let before = try store.fetchToolPermissions(serverId: serverId)
                    var permissions: [String: McpToolPermission] = [:]
                    for (toolName, permission) in confirmation.permissions where names.contains(toolName) {
                        if stillPending.contains(toolName) {
                            if let kept = before[toolName] { permissions[toolName] = kept }
                        } else {
                            permissions[toolName] = permission
                        }
                    }
                    try store.replaceToolCatalog(serverId: serverId, snapshots: next, permissions: permissions)
                    // The new definition is what was confirmed, so "allow for this conversation" grants given under
                    // the old definition do not carry over.
                    grants.revoke(serverId: serverId)
                    saveStatus(serverId, .connected, session: session)
                    return .confirmed(stillPending: next.filter { $0.pendingReview }.map { $0.toolName })
                } catch {
                    return .unreachable
                }
            }
        }
    }

    /// "Pause this server": turns it off in every conversation; quarantined tools stay quarantined.
    func pause(serverId: UUID) throws {
        try store.disableServerInAllConversations(serverId: serverId)
    }

    // MARK: Re-authorization

    /// First step of re-authorization: reads metadata only (GET); no registration, no browser.
    func prepareReauthorization(serverId: UUID) async -> McpReauthPreparation {
        guard let target = endpoint(of: serverId) else { return .gone }
        switch await connectSaved(serverId) {
        case .gone: return .gone
        case .needsAddress: return .needsAddress
        case .unreachable: return .unreachable
        case .connected(_, let session):
            saveStatus(serverId, .connected, session: session)
            await onReauthorized(serverId)
            return .connected
        case .needsAuth(let client, let url):
            if target.record.authKind == .token { return .needsToken }
            switch await authorizer.discover(challenge: await client.authChallenge, endpoint: url) {
            case .temporarilyUnavailable: return .unreachable
            case .needsToken: return .needsToken
            case .ready(let plan):
                return .ready(
                    plan: plan,
                    authorizationHost: plan.authorizationEndpoint.host ?? plan.issuer,
                    serverHost: url.host ?? target.record.name
                )
            }
        }
    }

    /// Second step of re-authorization (the user already tapped "Continue" on the pre-sign-in notice): register →
    /// browser → callback validation → token exchange → connect once with the new token and refresh the tool catalog.
    /// On success the connection status is written back as `connected` and steps parked on this server are woken up.
    func completeReauthorization(
        serverId: UUID,
        plan: McpAuthorizationPlan
    ) async -> McpReauthOutcome {
        guard endpoint(of: serverId) != nil else { return .gone }
        do {
            _ = try await authorizer.authorize(plan: plan, serverId: serverId, uid: uid)
            return await finishReauthorization(serverId)
        } catch let error as McpAuthorizerError {
            if error.isTransient { return .unreachable }
            return error == .cancelled ? .cancelled : .failed
        } catch {
            return .failed
        }
    }

    /// Replaces the access token (the token field, used on an already saved server). Not saved if the server rejects
    /// it.
    func submitAccessToken(serverId: UUID, token: String) async -> McpTokenSubmitOutcome {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target = endpoint(of: serverId), let url = target.endpoint.url else { return .gone }
        guard !trimmed.isEmpty else { return .rejected }
        switch await makeClient(url).connect(bearerToken: trimmed) {
        case .needsAuth: return .rejected
        case .notMcp, .unreachable, .failed: return .unreachable
        case .connected: break
        }
        do {
            try await authorizer.storePastedToken(trimmed, serverId: serverId, uid: uid)
        } catch {
            return .unreachable
        }
        switch await finishReauthorization(serverId) {
        case .connected: return .connected
        case .gone: return .gone
        case .cancelled, .unreachable, .failed: return .unreachable
        }
    }

    /// New credentials are in hand: connect once and refresh the tool catalog along the way (tools that changed in
    /// the meantime go back into quarantine as usual).
    private func finishReauthorization(_ serverId: UUID) async -> McpReauthOutcome {
        switch await refreshTools(serverId: serverId) {
        case .connected:
            await onReauthorized(serverId)
            return .connected
        case .gone: return .gone
        // The server still requires sign-in right after signing in: treat it as not successful and keep the
        // credentials (the next refresh or sign-in overwrites them).
        case .needsAuth: return .failed
        case .unreachable, .needsAddress: return .unreachable
        }
    }
}
