import Foundation

// MARK: - Connection probe state machine
//
// The complete state machine of the add flow: validate the URL -> connect once without credentials ->
// (success / not MCP / unreachable / sign-in required). When sign-in is required the flow branches on
// `authKind`: `token` retries with the token, `auto` runs OAuth discovery (CIMD / DCR / neither).
//
// **A server record is saved only after the tool list has been read; no failure leaves half a server behind.**
// "Nothing behind" covers the local database **and the credential store**: a browser sign-in may already
// have produced tokens, and any later failure (reading the tool list, hitting the server limit, a failed
// write, cancellation) must leave none of them in the Keychain.
//
// The production entry point is `McpAddCoordinator.add` (probe + save + exactly one terminal state).
// `McpAddProbe` only probes and never writes the server store.

/// URL validation, the first step of the add flow. Accepts `https://` only, requires a host name and at most 2048 characters.
nonisolated enum McpEndpoint {
    static func validate(_ raw: String) -> URL? {
        if case .success(let url) = check(raw) { return url }
        return nil
    }

    /// Validates and reports why a URL was rejected (the UI picks its explanation from the reason).
    static func check(_ raw: String) -> Result<URL, McpInvalidURLReason> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= McpServerRecord.maxURLLength else { return .failure(.malformed) }
        guard var components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty else {
            return .failure(.malformed)
        }
        // URLs carrying a userinfo component (`user:pass@`) are always rejected, with a hint to use an access
        // token instead. The browser fetch standard forbids credentials in URLs, so the web client could not
        // connect anyway; all clients agree at this step.
        if components.user != nil || components.password != nil {
            return .failure(.hasUserinfo)
        }
        // Stored URLs always use a lowercase scheme, so every client records the same address.
        components.scheme = "https"
        guard let url = components.url else { return .failure(.malformed) }
        return .success(url)
    }
}

/// Why a URL failed validation. Both reasons lead to the same "invalid URL" screen with different explanations.
nonisolated enum McpInvalidURLReason: Error, Sendable, Equatable {
    /// Incomplete, not `https://`, or too long.
    case malformed
    /// The URL contains a user name or password: the explanation says to use an access token instead.
    case hasUserinfo
}

/// Where requests for a saved server should be sent. **Every request path takes the URL from here** rather
/// than from `record.url`: for `localOnly` records `url` is only a display URL and the full URL lives in
/// the credential store.
nonisolated enum McpServerEndpointResolution: Sendable, Equatable {
    case ready(URL)
    /// The full URL is not on this device (restored from a backup onto a new device, or the Keychain was
    /// cleared): the server needs its URL entered again and no request is sent.
    case needsAddress

    var url: URL? {
        if case .ready(let url) = self { return url }
        return nil
    }
}

nonisolated enum McpServerEndpoint {
    static func resolve(
        _ record: McpServerRecord,
        uid: String,
        credentialStore: McpCredentialStore
    ) -> McpServerEndpointResolution {
        let raw = record.localOnly ? credentialStore.loadEndpoint(serverId: record.id, uid: uid) : record.url
        guard let raw, let url = McpEndpoint.validate(raw) else { return .needsAddress }
        return .ready(url)
    }
}

/// The result of successfully reading the tool list (the data the permission review screen needs).
nonisolated struct McpAddReview: Sendable, Equatable {
    var serverId: UUID
    var session: McpSession
    /// Freshly fetched tool snapshots; new or changed tools have `pendingReview = true` and are not sent
    /// to the model until the user confirms them.
    var tools: [McpToolSnapshot]
    /// Default permissions: `auto` for tools declared read-only, `ask` for everything else.
    var defaultPermissions: [String: McpToolPermission]
    /// Tokens obtained by browser sign-in that are **not yet in the credential store**. `McpAddCoordinator`
    /// saves them after the record is written; they are stripped from the terminal state handed to the UI
    /// (and the string description of the credential type is redacted anyway).
    var pendingCredentials: McpCredentials? = nil
}

/// States of the probe state machine. The first ten each have their own screen in the add flow; the remaining
/// terminal states are shown on the add form itself.
nonisolated enum McpAddState: Sendable, Equatable {
    /// Connecting.
    case connecting
    /// Pre-sign-in prompt. Carries the host name of the authorization endpoint; the state machine waits
    /// here for the user's consent and neither registers a client nor opens the browser before it is given.
    case authPrompt(authorizationHost: String)
    /// System browser.
    case browser
    /// Reading the tool list.
    case finishing
    /// Review default permissions (the success terminal state).
    case review(McpAddReview)
    /// Invalid URL (including URLs that are not `https://` and URLs with a userinfo component).
    case invalidURL(McpInvalidURLReason)
    /// Unreachable.
    case unreachable
    /// Not an MCP server.
    case notMcp
    /// Access token required.
    case needsToken
    /// Sign-in not completed (cancelled by the user, refused by the provider, or still rejected by the
    /// server after signing in).
    case authCancelled
    /// Token field error: `authKind = token` and the retry with the token still returned 401.
    case tokenRejected
    /// The server limit has been reached (carries the limit). Checked before probing starts so the user is
    /// not turned away only after completing sign-in.
    case limitReached(max: Int)
    /// The add was cancelled (the Task that started it was cancelled). No record or credential is left behind.
    case cancelled
    /// The server connected and the tools were read, but writing local storage failed. No record or
    /// credential is left behind.
    case saveFailed

    /// The first four are in-progress states, the rest are terminal.
    var isTerminal: Bool {
        switch self {
        case .connecting, .authPrompt, .browser, .finishing: return false
        case .review, .invalidURL, .unreachable, .notMcp, .needsToken, .authCancelled, .tokenRejected,
             .limitReached, .cancelled, .saveFailed:
            return true
        }
    }

    var review: McpAddReview? {
        if case .review(let review) = self { return review }
        return nil
    }
}

/// What the pre-sign-in prompt shows: the host name of the authorization endpoint. The system browser
/// opens only after the user confirms.
nonisolated struct McpAuthPrompt: Sendable, Equatable {
    /// Host name of the authorization endpoint (the sign-in page the user will see in the browser).
    var authorizationHost: String
}

/// The connection probe state machine. It does not write the server store; in-progress
/// states are reported to the UI through the `progress` callback.
actor McpAddProbe {
    typealias Progress = @Sendable (McpAddState) async -> Void
    /// Pre-sign-in gate: shows the prompt and waits for the user's decision. Only `true` lets the flow
    /// continue (register a client, open the browser).
    typealias AuthorizationGate = @Sendable (McpAuthPrompt) async -> Bool

    private let runtimeConfig: McpRuntimeConfig
    private let authorizer: McpAuthorizer
    private let credentialStore: McpCredentialStore
    private let makeClient: @Sendable (URL) -> McpClient

    /// `credentialStore` must be the one `authorizer` uses: a failed probe deletes the tokens this sign-in
    /// stored from it.
    init(
        runtimeConfig: McpRuntimeConfig = .fallback,
        authorizer: McpAuthorizer,
        credentialStore: McpCredentialStore = .shared,
        makeClient: @escaping @Sendable (URL) -> McpClient = { McpClient(endpoint: $0) }
    ) {
        self.runtimeConfig = runtimeConfig
        self.authorizer = authorizer
        self.credentialStore = credentialStore
        self.makeClient = makeClient
    }

    /// Stores the access token the user pasted, after the record is saved. Goes through the authorizer's
    /// single entry point (`McpAuthorizer.storePastedToken`).
    func storePastedToken(_ token: String, serverId: UUID, uid: String) async throws {
        try await authorizer.storePastedToken(token, serverId: serverId, uid: uid)
    }

    /// Runs one probe and also emits the terminal state through `progress`. Probes only and saves nothing;
    /// production code goes through `McpAddCoordinator.add`.
    func probe(
        urlString: String,
        authKind: McpAuthKind,
        uid: String,
        token: String? = nil,
        serverId: UUID = UUID(),
        confirmAuthorization: AuthorizationGate? = nil,
        progress: Progress? = nil
    ) async -> McpAddState {
        let state = await run(
            urlString: urlString, authKind: authKind, uid: uid, token: token, serverId: serverId,
            confirmAuthorization: confirmAuthorization, progress: progress
        )
        await progress?(state)
        return state
    }

    /// Runs one probe and returns the terminal state. In-progress states are delivered through `progress`
    /// in order; **the terminal state is not** - the caller emits it once after saving, so the UI never
    /// sees "success" followed by "failure".
    ///
    /// - `token`: the access token the user entered when `authKind = .token`.
    /// - `serverId` / `uid`: after a successful sign-in, credentials are stored under `uid:serverId`.
    ///   `serverId` must belong to a server that does not exist yet: on failure the credentials stored
    ///   under this id are deleted.
    /// - `confirmAuthorization`: the pre-sign-in gate. Omitting it means the user did not consent, so no
    ///   client is registered and no browser is opened.
    ///
    /// Before any failure state is returned, the credentials stored by this sign-in have been deleted.
    func run(
        urlString: String,
        authKind: McpAuthKind,
        uid: String,
        token: String? = nil,
        serverId: UUID = UUID(),
        confirmAuthorization: AuthorizationGate? = nil,
        progress: Progress? = nil
    ) async -> McpAddState {
        let endpoint: URL
        switch McpEndpoint.check(urlString) {
        case .success(let url): endpoint = url
        case .failure(let reason): return .invalidURL(reason)
        }
        let state = await explore(
            endpoint: endpoint, authKind: authKind, uid: uid, token: token, serverId: serverId,
            confirmAuthorization: confirmAuthorization, progress: progress
        )
        if state.review == nil {
            discardCredentials(serverId: serverId, uid: uid)
        }
        return state
    }

    /// Deletes the credentials stored by this add (a no-op when there are none). A failed delete has
    /// nowhere better to be reported - the add itself has already failed - and must not mask the original
    /// failure, so nothing is thrown here; Keychain error codes are already typed in `McpCredentialStore`.
    private func discardCredentials(serverId: UUID, uid: String) {
        try? credentialStore.delete(serverId: serverId, uid: uid)
    }

    private func explore(
        endpoint: URL,
        authKind: McpAuthKind,
        uid: String,
        token: String?,
        serverId: UUID,
        confirmAuthorization: AuthorizationGate?,
        progress: Progress?
    ) async -> McpAddState {
        if Task.isCancelled { return .cancelled }
        await progress?(.connecting)

        let client = makeClient(endpoint)
        // Step one: connect once without credentials.
        switch await client.connect() {
        case .connected(let session):
            return await finish(client: client, session: session, serverId: serverId, authKind: authKind, progress: progress)
        case .notMcp:
            return .notMcp
        case .failed(let error):
            return Self.failureState(for: error)
        case .unreachable:
            return Task.isCancelled ? .cancelled : .unreachable
        case .needsAuth:
            break
        }

        switch authKind {
        case .token:
            guard let token, !token.isEmpty else { return .tokenRejected }
            let state = await retryWithToken(
                client: client, token: token, serverId: serverId, authKind: authKind, progress: progress
            )
            return state
        case .auto:
            return await runDiscovery(
                client: client, endpoint: endpoint, serverId: serverId, uid: uid,
                confirmAuthorization: confirmAuthorization, progress: progress
            )
        }
    }

    // MARK: - Branches

    /// Discovery for `authKind = auto`: when a client can be registered automatically -> 19 (wait for
    /// consent) -> 20 -> sign in -> 21 / 22; when it cannot -> 26.
    private func runDiscovery(
        client: McpClient,
        endpoint: URL,
        serverId: UUID,
        uid: String,
        confirmAuthorization: AuthorizationGate?,
        progress: Progress?
    ) async -> McpAddState {
        let challenge = await client.authChallenge
        let plan: McpAuthorizationPlan
        switch await authorizer.discover(challenge: challenge, endpoint: endpoint) {
        case .ready(let discovered):
            plan = discovered
        case .needsToken:
            return Task.isCancelled ? .cancelled : .needsToken
        case .temporarilyUnavailable:
            // The metadata could not be fetched this time (network / timeout / 5xx): that is "unreachable",
            // not evidence that an access token is required.
            return Task.isCancelled ? .cancelled : .unreachable
        }
        if Task.isCancelled { return .cancelled }

        // Pre-sign-in gate: only GET requests have been sent so far. DCR leaves a client behind on the
        // authorization server and opening the browser takes the user to a third-party page - both must
        // happen only after the user consents.
        let prompt = McpAuthPrompt(authorizationHost: plan.authorizationEndpoint.host ?? plan.issuer)
        await progress?(.authPrompt(authorizationHost: prompt.authorizationHost))
        let approved = await confirmAuthorization?(prompt) ?? false
        if Task.isCancelled { return .cancelled }
        guard approved else { return .authCancelled }

        await progress?(.browser)
        let credentials: McpCredentials
        do {
            // The discovery result is passed to authorization as is, with no second discovery; client
            // registration happens inside this step. The tokens stay in memory for now and are stored only
            // after the record is saved (see `McpAddCoordinator.commit`).
            credentials = try await authorizer.authorize(plan: plan, serverId: serverId, uid: uid, persist: false)
        } catch {
            let transient = (error as? McpAuthorizerError)?.isTransient == true
            if Task.isCancelled { return .cancelled }
            if transient { return .unreachable }
            // Cancelled by the user / refused by the provider / callback rejected -> sign-in not completed.
            return .authCancelled
        }
        if Task.isCancelled { return .cancelled }

        guard let token = credentials.accessToken ?? credentials.pastedToken else { return .authCancelled }
        var state = await retryWithToken(
            client: client, token: token, serverId: serverId, authKind: .auto, progress: progress
        )
        if case .review(var review) = state {
            review.pendingCredentials = credentials
            state = .review(review)
        }
        return state
    }

    /// Reconnects with a token. If sign-in is still required the outcome depends on how the user signed in:
    /// pasted token -> token field error; browser sign-in -> sign-in not completed.
    private func retryWithToken(
        client: McpClient,
        token: String,
        serverId: UUID,
        authKind: McpAuthKind,
        progress: Progress?
    ) async -> McpAddState {
        switch await client.connect(bearerToken: token) {
        case .connected(let session):
            return await finish(client: client, session: session, serverId: serverId, authKind: authKind, progress: progress)
        case .needsAuth:
            return Self.rejectedState(for: authKind)
        case .notMcp:
            return .notMcp
        case .failed(let error):
            return Self.failureState(for: error)
        case .unreachable:
            return Task.isCancelled ? .cancelled : .unreachable
        }
    }

    /// Read the tool list -> review default permissions.
    private func finish(
        client: McpClient,
        session: McpSession,
        serverId: UUID,
        authKind: McpAuthKind,
        progress: Progress?
    ) async -> McpAddState {
        if Task.isCancelled { return .cancelled }
        await progress?(.finishing)
        do {
            let definitions = try await client.listTools()
            if Task.isCancelled { return .cancelled }
            let snapshots = McpToolCatalog.snapshots(
                serverId: serverId, definitions: definitions, runtimeConfig: runtimeConfig
            )
            return .review(McpAddReview(
                serverId: serverId,
                session: session,
                tools: snapshots,
                defaultPermissions: McpToolCatalog.defaultPermissions(for: snapshots)
            ))
        } catch let error as McpClientError {
            if error.code == .needsAuth { return Self.rejectedState(for: authKind) }
            return Self.failureState(for: error)
        } catch {
            return Task.isCancelled ? .cancelled : .unreachable
        }
    }

    // MARK: - Internals

    private static func rejectedState(for authKind: McpAuthKind) -> McpAddState {
        authKind == .token ? .tokenRejected : .authCancelled
    }

    /// Cancellation has its own terminal state and is not folded into "unreachable"; timeouts and server
    /// errors still are.
    private static func failureState(for error: McpClientError) -> McpAddState {
        error.code == .cancelled || Task.isCancelled ? .cancelled : .unreachable
    }
}

/// The production entry point of the add flow: probe -> save -> emit **one** terminal state.
///
/// A server record is written only once the tool list has been read; after any failure state neither the
/// local database nor the credential store holds a trace of this add.
final class McpAddCoordinator: Sendable {
    private let probe: McpAddProbe
    private let store: McpServerStore
    private let credentialStore: McpCredentialStore
    private let runtimeConfig: McpRuntimeConfig

    /// `credentialStore` must be the one the probe and the authorizer use. Production code builds this through
    /// `McpServerDirectory.makeAddCoordinator`.
    init(
        probe: McpAddProbe,
        store: McpServerStore,
        credentialStore: McpCredentialStore = .shared,
        runtimeConfig: McpRuntimeConfig = .fallback
    ) {
        self.probe = probe
        self.store = store
        self.credentialStore = credentialStore
        self.runtimeConfig = runtimeConfig
    }

    /// Runs the probe and saves on success. Returns the terminal state; `progress` receives the in-progress
    /// states in order and then exactly one terminal state (the return value).
    ///
    /// This is the one-step "save as soon as the probe succeeds" entry point. The UI uses two steps:
    /// `prepare` only probes, and `commit` runs once the user taps Done on the permission review screen
    /// (nothing is saved before that confirmation).
    func add(
        urlString: String,
        name: String = "",
        authKind: McpAuthKind,
        uid: String,
        token: String? = nil,
        serverId: UUID = UUID(),
        now: Date = Date(),
        confirmAuthorization: McpAddProbe.AuthorizationGate? = nil,
        progress: McpAddProbe.Progress? = nil
    ) async -> McpAddState {
        var state = await explore(
            urlString: urlString, authKind: authKind, uid: uid, token: token, serverId: serverId,
            confirmAuthorization: confirmAuthorization, progress: progress
        )
        if case .review(let review) = state {
            // One last cancellation check before saving: the user has left the add screen, so a server
            // must not quietly appear.
            state = Task.isCancelled
                ? .cancelled
                : await commit(
                    McpAddDraft(urlString: urlString, name: name, authKind: authKind, token: token, review: review),
                    uid: uid, now: now
                )
        }
        await progress?(state)
        return state
    }

    /// Step one of the two-step flow: probe only, **writing no storage at all**. On success the returned
    /// draft holds the tool snapshots, the default permissions and (for browser sign-in) the tokens still
    /// in memory; if the user abandons the add, dropping the draft is enough and there is nothing to clean up.
    /// `progress` only receives in-progress states; the terminal state is the return value.
    func prepare(
        urlString: String,
        name: String = "",
        authKind: McpAuthKind,
        uid: String,
        token: String? = nil,
        serverId: UUID = UUID(),
        confirmAuthorization: McpAddProbe.AuthorizationGate? = nil,
        progress: McpAddProbe.Progress? = nil
    ) async -> McpAddPreparation {
        let state = await explore(
            urlString: urlString, authKind: authKind, uid: uid, token: token, serverId: serverId,
            confirmAuthorization: confirmAuthorization, progress: progress
        )
        guard case .review(let review) = state else { return .failed(state) }
        if Task.isCancelled { return .failed(.cancelled) }
        return .ready(McpAddDraft(urlString: urlString, name: name, authKind: authKind, token: token, review: review))
    }

    /// Validates the URL, checks the server limit and probes. Saves nothing.
    private func explore(
        urlString: String,
        authKind: McpAuthKind,
        uid: String,
        token: String?,
        serverId: UUID,
        confirmAuthorization: McpAddProbe.AuthorizationGate?,
        progress: McpAddProbe.Progress?
    ) async -> McpAddState {
        if case .failure(let reason) = McpEndpoint.check(urlString) { return .invalidURL(reason) }

        // At the limit, or the id already belongs to a server: reject before sending any request.
        // The former spares the user from finishing browser sign-in only to be told the server cannot be
        // added; the latter matters because the failure cleanup below deletes the credentials stored under
        // this id and must never touch the tokens of an existing server.
        do {
            guard try store.fetchServer(id: serverId) == nil else { return .saveFailed }
            guard try store.serverCount() < runtimeConfig.maxServers else {
                return .limitReached(max: runtimeConfig.maxServers)
            }
        } catch {
            return .saveFailed
        }

        return await probe.run(
            urlString: urlString, authKind: authKind, uid: uid, token: token, serverId: serverId,
            confirmAuthorization: confirmAuthorization, progress: progress
        )
    }

    /// Step two of the two-step flow (and the second half of the one-step flow): saves the draft. Returns
    /// `.review` (saved) or a failure state; after any failure neither the local database nor the
    /// credential store holds a trace of this add.
    ///
    /// - `permissions`: the permissions the user settled on the permission review screen. Passing them
    ///   means the user has seen these tools - the snapshots leave quarantine and these permissions are
    ///   written; omitting them (one-step flow) keeps the tools quarantined with default permissions until
    ///   the user confirms later.
    /// - The order is **save the record first, then store the credentials**: the other way round, being
    ///   killed midway would leave tokens without a server and no way to ever clear them; now the worst
    ///   case is a server missing its credentials, which the user can see, delete, or fix by signing in again.
    func commit(
        _ draft: McpAddDraft,
        permissions: [String: McpToolPermission]? = nil,
        uid: String,
        now: Date = Date()
    ) async -> McpAddState {
        guard case .success(let endpoint) = McpEndpoint.check(draft.urlString) else { return .invalidURL(.malformed) }
        let review = draft.review
        let serverId = review.serverId
        let authKind = draft.authKind
        let token = draft.token

        // A URL that looks like it contains a secret (see `McpLocalOnly` for the test) is stored as a
        // credential, and the database only keeps the display URL (`McpServerStore` enforces this again
        // when writing): the database is part of a device backup, the credential store is not.
        let fullURL = endpoint.absoluteString
        let localOnly = McpLocalOnly.isLocalOnly(fullURL)
        let snapshots = permissions == nil ? review.tools : review.tools.map { snapshot -> McpToolSnapshot in
            var accepted = snapshot
            accepted.pendingReview = false
            return accepted
        }
        do {
            // A single write transaction covers everything; a failure rolls it all back, and a primary-key
            // collision with an existing server leaves that server untouched.
            try store.addServer(
                McpServerAddition(
                    id: serverId,
                    name: Self.resolveName(draft.name, session: review.session, endpoint: endpoint),
                    url: localOnly ? McpLocalOnly.displayURL(fullURL) : fullURL,
                    authKind: authKind,
                    localOnly: localOnly,
                    iconURL: nil,
                    createdAt: now,
                    snapshots: snapshots,
                    permissions: permissions ?? review.defaultPermissions,
                    connectionState: McpConnectionState(
                        serverId: serverId,
                        status: .connected,
                        lastSuccessAt: now,
                        negotiatedVersion: review.session.protocolVersion,
                        generation: review.session.generation,
                        sessionId: review.session.sessionId
                    )
                ),
                maxServers: runtimeConfig.maxServers
            )
        } catch McpStoreError.limitReached(let max) {
            // Another add filled the last slot while probing.
            discardCredentials(serverId: serverId, uid: uid)
            return .limitReached(max: max)
        } catch {
            discardCredentials(serverId: serverId, uid: uid)
            return .saveFailed
        }

        // The full URL, the browser sign-in tokens and the pasted token are all stored after the record is
        // saved; if any of them cannot be stored the add fails and the record is withdrawn - a localOnly
        // server without its full URL cannot send any request and a server without a token is unusable.
        // What gets removed here is always the row this very call inserted (`addServer` succeeding proves
        // it did not exist before).
        do {
            if localOnly {
                try credentialStore.saveEndpoint(fullURL, serverId: serverId, uid: uid)
            }
            if let pending = review.pendingCredentials {
                try credentialStore.save(pending, serverId: serverId, uid: uid)
            }
            if authKind == .token, let token, !token.isEmpty {
                // Same entry point as "paste a new access token" on the management screen: storing a pasted
                // token clears the OAuth fields, otherwise the OAuth access token would take precedence
                // when a token is looked up and the pasted one would never be sent.
                try await probe.storePastedToken(token, serverId: serverId, uid: uid)
            }
        } catch {
            try? store.deleteServer(id: serverId)
            discardCredentials(serverId: serverId, uid: uid)
            return .saveFailed
        }
        var saved = review
        saved.pendingCredentials = nil
        saved.tools = snapshots
        return .review(saved)
    }

    private func discardCredentials(serverId: UUID, uid: String) {
        try? credentialStore.delete(serverId: serverId, uid: uid)
    }

    /// Fallback when the name is left blank: the server's self-reported name, then the host name.
    private static func resolveName(_ name: String, session: McpSession, endpoint: URL) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return capped(trimmed) }
        if let serverName = session.serverName?.trimmingCharacters(in: .whitespacesAndNewlines), !serverName.isEmpty {
            return capped(serverName)
        }
        return capped(endpoint.host ?? "MCP Server")
    }

    /// Truncates to at most 64 UTF-16 code units without splitting a grapheme cluster. Code units are
    /// counted so that every client cuts a name at the same place.
    private static func capped(_ name: String) -> String {
        var result = ""
        var units = 0
        for character in name {
            let size = character.utf16.count
            if units + size > McpServerRecord.maxNameLength { break }
            result.append(character)
            units += size
        }
        return result.isEmpty ? "MCP Server" : result
    }
}

/// An add that probed successfully and has not been saved yet. It lives in memory only; once the user taps
/// Done it is handed to `McpAddCoordinator.commit`.
nonisolated struct McpAddDraft: Sendable, Equatable {
    var urlString: String
    var name: String
    var authKind: McpAuthKind
    /// The access token the user pasted (`authKind = .token`).
    var token: String?
    var review: McpAddReview
}

nonisolated enum McpAddPreparation: Sendable, Equatable {
    case ready(McpAddDraft)
    /// A failure terminal state (the probe's own failure has already cleared this add's credentials).
    case failed(McpAddState)
}
