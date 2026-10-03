import Foundation
import Observation

// MARK: - UI state for the server management page
//
// Every action on the detail page goes through here: reading local data, reloading tools, per-tool permissions,
// re-authorization (including the one started from a chat step block), confirming tool changes, removal, and
// re-entering the address. Protocol and authorization sit behind `McpServerActions`; the page only draws
// `McpServerDetailUiState`.

/// How the detail page was entered.
enum McpServerDetailIntent: String, Hashable, Sendable {
    case view
    /// "Re-authorize" in the tool panel, or on a chat step block stopped at "sign in again": start re-authorizing
    /// on entry. A step waiting on this server resumes in place after a successful sign-in.
    case reauthorize

    var startsReauthorization: Bool { self != .view }
}

/// Production wiring: the `McpServerActions` used by the management page (real network, system browser, and the
/// same credential store as the directory).
@MainActor
enum McpServerManagement {
    static func actions(
        directory: McpServerDirectory,
        uid: String,
        reauthorization: McpReauthorizationCoordinator? = nil
    ) throws -> McpServerActions {
        let runtimeConfig = MetadataClient.shared.syncMcpRuntimeConfig()
        return McpServerActions(
            store: try directory.store(for: uid),
            credentialStore: directory.credentialStore,
            uid: uid,
            runtimeConfig: runtimeConfig,
            authorizer: directory.authorizer(for: uid),
            onReauthorized: { serverId in
                await reauthorization?.serverReauthorized(serverId)
            }
        )
    }
}

/// What is layered over the detail page (only one at a time).
enum McpServerDetailOverlay: Equatable, Sendable {
    /// Permission of a single tool.
    case toolPermission(toolName: String)
    /// Pre-sign-in prompt (re-authorization).
    case authPrompt(authorizationHost: String, serverHost: String)
    /// Access-token input for an already saved server.
    case tokenEntry
    /// Tools were updated.
    case toolsChanged
    /// Remove confirmation.
    case removeConfirm
}

/// A notice below the hero card (when an operation did not succeed).
enum McpServerDetailNotice: Equatable, Sendable {
    case signInNotCompleted
    case unreachable
    case removeFailed
    case addressRejected
}

struct McpServerDetailUiState: Equatable, Sendable {
    var detail: McpServerDetail?
    /// Local storage has been read. When the server is no longer on this device, `detail == nil && loaded` and the
    /// page navigates back on its own.
    var loaded = false
    var overlay: McpServerDetailOverlay?
    var notice: McpServerDetailNotice?
    /// Reloading tools / checking the sign-in method / signing in / confirming changes.
    var busy = false
    /// Changes waiting for confirmation.
    var pendingChanges: [McpPendingToolChange] = []
    /// The server changed again during confirmation: stay in the sheet so the user can review once more.
    var changedAgain = false
    var token = ""
    var tokenRejected = false
    var address = ""
    var expandedReadOnly = false
    var expandedChanging = false

    /// The tool list is dimmed and inactive (when authorization has expired).
    var toolsDisabled: Bool {
        guard let health = detail?.health else { return true }
        return health == .needsAuth || health == .needsAddress
    }
}

@MainActor
@Observable
final class McpServerDetailModel {
    struct Dependencies {
        var uid: String
        var loadDetail: @MainActor (UUID) throws -> McpServerDetail?
        var actions: @MainActor () throws -> McpServerActions
        var setPermission: @MainActor (McpToolPermission, UUID, String) throws -> Void
        var remove: @MainActor (UUID) throws -> Void
        var restoreEndpoint: @MainActor (UUID, String) throws -> Void
    }

    let serverId: UUID
    let intent: McpServerDetailIntent
    private(set) var state = McpServerDetailUiState()
    /// The server was removed (or is no longer on this device); the page navigates back when this is set.
    private(set) var isGone = false

    @ObservationIgnored private let dependencies: Dependencies
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var plan: McpAuthorizationPlan?
    @ObservationIgnored private var startedIntent = false
    /// The old snapshots and "removed" entries from the latest reload. No history is stored locally, so the
    /// before/after comparison only exists within this session.
    @ObservationIgnored private var previousSnapshots: [McpToolSnapshot] = []
    @ObservationIgnored private var removedChanges: [McpToolChange] = []

    init(serverId: UUID, intent: McpServerDetailIntent = .view, dependencies: Dependencies) {
        self.serverId = serverId
        self.intent = intent
        self.dependencies = dependencies
    }

    // MARK: Loading

    func load() {
        let detail = try? dependencies.loadDetail(serverId)
        state.detail = detail
        state.loaded = true
        guard let detail else {
            isGone = true
            return
        }
        state.pendingChanges = McpServerActions.pendingChanges(
            snapshots: detail.snapshots, permissions: detail.permissions,
            removed: removedChanges, previous: previousSnapshots
        )
        if case .toolsChanged = state.overlay, state.pendingChanges.isEmpty { state.overlay = nil }
    }

    /// Page appeared: read local data; when entered with a "re-authorize" intent, start one re-authorization (once).
    func appear() {
        load()
        guard !startedIntent, intent.startsReauthorization, !isGone else { return }
        startedIntent = true
        beginReauthorization()
    }

    func waitUntilIdle() async {
        await task?.value
    }

    private func run(_ operation: @escaping @MainActor (McpServerActions) async -> Void) {
        guard task == nil else { return }
        guard let actions = try? dependencies.actions() else {
            state.notice = .unreachable
            return
        }
        state.busy = true
        state.notice = nil
        task = Task { [weak self] in
            await operation(actions)
            self?.task = nil
            self?.state.busy = false
            self?.load()
        }
    }

    // MARK: Reload tools

    func reloadTools() {
        let before = state.detail?.snapshots ?? []
        run { [weak self] actions in
            let result = await actions.refreshTools(serverId: self?.serverId ?? UUID())
            guard let self else { return }
            switch result {
            case .connected(let changes):
                if !changes.isEmpty {
                    self.previousSnapshots = before
                    self.removedChanges = changes.filter { $0.kind == .removed }
                    self.state.changedAgain = false
                    self.state.overlay = .toolsChanged
                }
            case .unreachable: self.state.notice = .unreachable
            case .needsAuth, .needsAddress: break
            case .gone: self.isGone = true
            }
        }
    }

    // MARK: Single-tool permission

    func openToolPermission(_ toolName: String) {
        guard !state.toolsDisabled else { return }
        state.overlay = .toolPermission(toolName: toolName)
    }

    func setPermission(_ permission: McpToolPermission, toolName: String) {
        try? dependencies.setPermission(permission, serverId, toolName)
        load()
    }

    func toggleReadOnlyExpanded() { state.expandedReadOnly.toggle() }
    func toggleChangingExpanded() { state.expandedChanging.toggle() }

    func dismissOverlay() {
        // "Cancel" on the pre-sign-in prompt also lands here: without consent, nothing is registered and no browser opens.
        if case .authPrompt = state.overlay { plan = nil }
        state.overlay = nil
        state.token = ""
        state.tokenRejected = false
    }

    // MARK: Re-authorization

    /// Step one: read metadata only and work out how to sign in. Browser sign-in shows the pre-sign-in prompt; an
    /// access-token server shows the input field.
    func beginReauthorization() {
        run { [weak self] actions in
            let preparation = await actions.prepareReauthorization(serverId: self?.serverId ?? UUID())
            guard let self else { return }
            switch preparation {
            case let .ready(plan, authorizationHost, serverHost):
                self.plan = plan
                self.state.overlay = .authPrompt(authorizationHost: authorizationHost, serverHost: serverHost)
            case .needsToken:
                self.state.overlay = .tokenEntry
            case .connected, .needsAddress: break
            case .unreachable: self.state.notice = .unreachable
            case .gone: self.isGone = true
            }
        }
    }

    /// "Continue" on the pre-sign-in prompt: register, browser, token exchange, then connect once.
    func approveReauthorization() {
        guard case .authPrompt = state.overlay, let plan else { return }
        state.overlay = nil
        self.plan = nil
        run { [weak self] actions in
            let outcome = await actions.completeReauthorization(serverId: self?.serverId ?? UUID(), plan: plan)
            guard let self else { return }
            switch outcome {
            case .connected, .cancelled: break
            case .failed: self.state.notice = .signInNotCompleted
            case .unreachable: self.state.notice = .unreachable
            case .gone: self.isGone = true
            }
        }
    }

    func setToken(_ value: String) {
        state.token = value
        state.tokenRejected = false
    }

    func submitToken() {
        let token = state.token
        run { [weak self] actions in
            let outcome = await actions.submitAccessToken(serverId: self?.serverId ?? UUID(), token: token)
            guard let self else { return }
            switch outcome {
            case .connected:
                self.state.overlay = nil
                self.state.token = ""
            case .rejected: self.state.tokenRejected = true
            case .unreachable:
                self.state.overlay = nil
                self.state.notice = .unreachable
            case .gone: self.isGone = true
            }
        }
    }

    // MARK: Tools were updated

    func reviewChanges() {
        state.changedAgain = false
        state.overlay = .toolsChanged
    }

    /// "Confirm and keep using": re-check with the server, then lift the quarantine; permissions are only ever
    /// lowered, never raised.
    func confirmChanges() {
        run { [weak self] actions in
            let result = await actions.confirmChanges(serverId: self?.serverId ?? UUID())
            guard let self else { return }
            self.previousSnapshots = []
            self.removedChanges = []
            switch result {
            case .confirmed(let stillPending):
                if stillPending.isEmpty {
                    self.state.overlay = nil
                } else {
                    self.state.changedAgain = true
                }
            case .needsAuth, .needsAddress: self.state.overlay = nil
            case .unreachable:
                self.state.overlay = nil
                self.state.notice = .unreachable
            case .gone: self.isGone = true
            }
        }
    }

    /// "Pause this server for now": turn it off in every conversation; quarantined tools stay quarantined.
    func pauseServer() {
        try? dependencies.actions().pause(serverId: serverId)
        state.overlay = nil
    }

    // MARK: Removal

    func askRemove() { state.overlay = .removeConfirm }

    func confirmRemove() {
        do {
            try dependencies.remove(serverId)
            state.overlay = nil
            isGone = true
        } catch {
            state.overlay = nil
            state.notice = .removeFailed
        }
    }

    // MARK: Re-enter the address

    func setAddress(_ value: String) {
        state.address = value
        if state.notice == .addressRejected { state.notice = nil }
    }

    func saveAddress() {
        do {
            try dependencies.restoreEndpoint(serverId, state.address)
            state.address = ""
            load()
            reloadTools()
        } catch {
            state.notice = .addressRejected
        }
    }
}
