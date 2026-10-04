import Foundation
import Observation

// MARK: - UI state for the add-server flow
//
// Maps the `McpAddCoordinator` state machine to "which page to draw now". Probing, sign-in and persistence all
// live in the coordinator; this type only collects the form, maps in-progress and terminal states to pages, and
// on the "review default permissions" step either admits the tools or abandons the add. No failed terminal state
// leaves a record behind (the coordinator guarantees it).

/// Which step the progress page is on.
enum McpAddStage: Equatable, Sendable {
    case connecting
    case authPrompt
    case browser
    case finishing
}

/// Kinds of failure page, including "limit reached" and "could not save".
enum McpAddFailure: Equatable, Sendable {
    case unreachable
    case notMcp
    case needsToken
    case authCancelled
    case limitReached(max: Int)
    case saveFailed
}

enum McpAddScreen: Equatable, Sendable {
    /// Address form. An invalid address or a token error also stays on this page.
    case form
    /// `authorizationHost`: host name of the sign-in page, which the progress page must show.
    /// `signedIn`: the browser sign-in already happened, so the second checklist step reads "signed in".
    case progress(stage: McpAddStage, authorizationHost: String?, signedIn: Bool)
    /// Connected; review the default permissions. Nothing is stored yet: only "Done" persists.
    case review(McpAddReviewScreen)
    case failure(McpAddFailure)
}

struct McpAddReviewScreen: Equatable, Sendable {
    var serverId: UUID
    var tools: [McpToolSnapshot]
    var readOnlyPermission: McpToolPermission = .auto
    var changesPermission: McpToolPermission = .ask
    var saving = false

    var readOnlyTools: [McpToolSnapshot] { tools.filter(\.readOnly) }
    var changingTools: [McpToolSnapshot] { tools.filter { !$0.readOnly } }
}

struct McpAddUiState: Equatable, Sendable {
    var url = ""
    var name = ""
    var authKind: McpAuthKind = .auto
    var token = ""
    var urlError: McpInvalidURLReason?
    /// The server rejected the token that was just pasted (field error on the form and on the "access token
    /// required" page).
    var tokenRejected = false
    var screen: McpAddScreen = .form
    /// Name reported by the server itself (only known once connected).
    var serverName: String?
    /// Server id after "Done"; the UI leaves the add page when it is set.
    var completedServerId: UUID?

    var host: String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return URLComponents(string: trimmed)?.host ?? trimmed
    }

    /// Name not known yet (the user gave none and the server reported none): the hero card shows the host name and
    /// a globe icon.
    var nameIsUnknown: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (serverName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Name on the hero card and the pre-sign-in prompt: user-entered, then server-reported, then the host name.
    var displayName: String {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        let reported = (serverName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return reported.isEmpty ? host : reported
    }

    var trimmedToken: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }

    var canConnect: Bool {
        !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && urlError == nil
    }
}

/// The answer to the pre-sign-in prompt. Each connection gets a fresh one that exists before the page switches
/// to the prompt, so a tap is never lost because the state machine has not reached the waiting line yet.
private nonisolated final class McpAuthApproval: @unchecked Sendable {
    private let lock = NSLock()
    private var decision: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?

    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let decision {
                lock.unlock()
                continuation.resume(returning: decision)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func resolve(_ approved: Bool) {
        lock.lock()
        guard decision == nil else {
            lock.unlock()
            return
        }
        decision = approved
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: approved)
    }
}

@MainActor
@Observable
final class McpAddServerModel {
    struct Dependencies {
        var uid: String
        /// A new coordinator per connection (in production via `McpServerDirectory.makeAddCoordinator`).
        var makeCoordinator: @MainActor () throws -> McpAddCoordinator
    }

    private(set) var state = McpAddUiState()

    @ObservationIgnored private let dependencies: Dependencies
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The attempt most recently abandoned by `cancel()`. It is still unwinding when `cancel()` returns: the page
    /// has moved on, but its browser session and requests are only now being torn down.
    @ObservationIgnored private var abandonedTask: Task<Void, Never>?
    /// Connection attempt counter. After a cancel or restart, progress callbacks still in flight from the previous
    /// attempt no longer change the page.
    @ObservationIgnored private var runID = 0
    @ObservationIgnored private var approval = McpAuthApproval()
    /// The token was entered on the "access token required" page: if the server rejects it, stay there and show
    /// the error instead of falling back to the form.
    @ObservationIgnored private var tokenFromNeedsTokenPage = false
    /// The draft from a successful probe waiting for "Done" (in memory only), and the coordinator that probed it.
    @ObservationIgnored private var draft: McpAddDraft?
    @ObservationIgnored private var draftCoordinator: McpAddCoordinator?

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    // MARK: Form

    func setURL(_ value: String) {
        state.url = value
        state.urlError = nil
    }

    func setName(_ value: String) { state.name = value }

    func setToken(_ value: String) {
        state.token = value
        state.tokenRejected = false
    }

    // MARK: Connect

    /// "Connect" on the form. The form only has address and name: the sign-in method is decided by probing, not
    /// chosen by the user.
    func connect() {
        tokenFromNeedsTokenPage = false
        state.authKind = .auto
        start()
    }

    /// "Retry" / "Sign in again": run again with the same input.
    func retry() { start() }

    /// "Connect" after pasting a token on the "access token required" page.
    func connectWithToken() {
        tokenFromNeedsTokenPage = true
        state.authKind = .token
        start()
    }

    /// "Edit address": back to the form, keeping everything already entered.
    func editAddress() { state.screen = .form }

    var isRunning: Bool { task != nil }

    /// Waits until this connection reaches a terminal state, and until an attempt abandoned by `cancel()` has
    /// finished unwinding (for tests).
    func waitUntilSettled() async {
        await abandonedTask?.value
        await task?.value
    }

    private func start() {
        guard task == nil else { return }
        let input = state
        // Invalid address: stay on the form with a field error and send no request.
        if case .failure(let reason) = McpEndpoint.check(input.url) {
            state.urlError = reason
            state.screen = .form
            return
        }
        let coordinator: McpAddCoordinator
        do {
            coordinator = try dependencies.makeCoordinator()
        } catch {
            state.screen = .failure(.saveFailed)
            return
        }
        state.screen = .progress(stage: .connecting, authorizationHost: nil, signedIn: false)
        state.serverName = nil
        state.tokenRejected = false
        runID += 1
        let run = runID
        let approval = McpAuthApproval()
        self.approval = approval
        let uid = dependencies.uid
        let token = input.authKind == .token && !input.trimmedToken.isEmpty ? input.trimmedToken : nil

        draft = nil
        draftCoordinator = nil
        task = Task { [weak self] in
            let preparation = await coordinator.prepare(
                urlString: input.url,
                name: input.name,
                authKind: input.authKind,
                uid: uid,
                token: token,
                confirmAuthorization: { _ in await approval.wait() },
                progress: { progress in
                    await self?.show(progress, run: run)
                }
            )
            self?.finish(preparation, coordinator: coordinator, run: run, input: input)
        }
    }

    @ObservationIgnored private var usedBrowser = false

    private func show(_ progress: McpAddState, run: Int) {
        guard run == runID else { return }
        switch progress {
        case .connecting:
            usedBrowser = false
            state.screen = .progress(stage: .connecting, authorizationHost: nil, signedIn: false)
        case .authPrompt(let host):
            state.screen = .progress(stage: .authPrompt, authorizationHost: host, signedIn: false)
        case .browser:
            usedBrowser = true
            state.screen = .progress(stage: .browser, authorizationHost: currentAuthorizationHost, signedIn: false)
        case .finishing:
            state.screen = .progress(stage: .finishing, authorizationHost: currentAuthorizationHost, signedIn: usedBrowser)
        default:
            break
        }
    }

    private var currentAuthorizationHost: String? {
        if case .progress(_, let host, _) = state.screen { return host }
        return nil
    }

    private func finish(
        _ preparation: McpAddPreparation,
        coordinator: McpAddCoordinator,
        run: Int,
        input: McpAddUiState
    ) {
        guard run == runID else {
            // The user cancelled this attempt (or the page is gone): probing wrote no storage, so drop the result.
            return
        }
        task = nil
        switch preparation {
        case .ready(let draft):
            // Not persisted yet: that happens once the user taps Done.
            self.draft = draft
            draftCoordinator = coordinator
            state.serverName = draft.review.session.serverName
            state.screen = .review(McpAddReviewScreen(
                serverId: draft.review.serverId,
                tools: draft.review.tools
            ))
        case .failed(let terminal):
            showFailure(terminal)
        }
    }

    private func showFailure(_ terminal: McpAddState) {
        switch terminal {
        case .invalidURL(let reason):
            state.urlError = reason
            state.screen = .form
        case .tokenRejected:
            // The token is only entered on the "access token required" page; when rejected, stay there with a
            // field error.
            state.tokenRejected = true
            state.screen = .failure(.needsToken)
        case .unreachable: state.screen = .failure(.unreachable)
        case .notMcp: state.screen = .failure(.notMcp)
        case .needsToken: state.screen = .failure(.needsToken)
        case .authCancelled: state.screen = .failure(.authCancelled)
        case .limitReached(let max): state.screen = .failure(.limitReached(max: max))
        case .saveFailed: state.screen = .failure(.saveFailed)
        // User cancelled: back to the form, keeping what was entered.
        case .cancelled: state.screen = .form
        case .review, .connecting, .authPrompt, .browser, .finishing: break
        }
    }

    // MARK: Pre-sign-in prompt

    /// "Continue": register the client and open the system browser.
    func approveSignIn() {
        guard case .progress(.authPrompt, _, _) = state.screen else { return }
        approval.resolve(true)
    }

    /// Cancels an add in progress ("Cancel" on the progress page or the pre-sign-in prompt, or system back). Returns
    /// to the form once the coordinator has cleaned up; no record or credential is left behind.
    func cancel() {
        guard let running = task else { return }
        runID += 1
        task = nil
        abandonedTask = running
        running.cancel()
        approval.resolve(false)
        if case .progress = state.screen { state.screen = .form }
    }

    // MARK: Review default permissions

    func setReadOnlyPermission(_ permission: McpToolPermission) {
        guard case .review(var review) = state.screen else { return }
        review.readOnlyPermission = permission
        state.screen = .review(review)
    }

    func setChangesPermission(_ permission: McpToolPermission) {
        guard case .review(var review) = state.screen else { return }
        review.changesPermission = permission
        state.screen = .review(review)
    }

    /// "Done": the user has seen the tool groups and default permissions, so only now is anything persisted
    /// (record, admitted tool snapshots, permissions, credentials). A failed save is treated
    /// as a failed add; no half-saved server remains.
    func finishReview() {
        guard case .review(var review) = state.screen, !review.saving,
              let draft, let coordinator = draftCoordinator, task == nil else { return }
        review.saving = true
        state.screen = .review(review)
        var permissions: [String: McpToolPermission] = [:]
        for tool in review.tools {
            permissions[tool.toolName] = tool.readOnly ? review.readOnlyPermission : review.changesPermission
        }
        let uid = dependencies.uid
        runID += 1
        let run = runID
        task = Task { [weak self] in
            let terminal = await coordinator.commit(draft, permissions: permissions, uid: uid)
            self?.finishCommit(terminal, run: run, authKind: draft.authKind)
        }
    }

    private func finishCommit(_ terminal: McpAddState, run: Int, authKind: McpAuthKind) {
        guard run == runID else { return }
        task = nil
        draft = nil
        draftCoordinator = nil
        if case .review(let saved) = terminal {
            state.completedServerId = saved.serverId
        } else {
            showFailure(terminal)
        }
    }

    /// Leaving the add page (system back, top-bar back, page disappearing). Leaving the "review default
    /// permissions" step without tapping Done abandons the add: the draft is in memory only, so dropping it leaves
    /// no trace of this server anywhere. Leaving while in progress cancels.
    func close() {
        if case .review(let review) = state.screen, state.completedServerId == nil, !review.saving {
            draft = nil
            draftCoordinator = nil
            state.screen = .form
            return
        }
        // Do not interrupt a save in progress (Done was already tapped): that step is short, and interrupting it
        // would only leave an ambiguous intermediate state.
        if case .review = state.screen { return }
        cancel()
    }
}
