import Foundation
import Observation

/// A confirmation waiting for the user's decision.
struct PendingMcpConfirmation: Identifiable, Equatable, Sendable {
    let id: UUID
    let request: McpConfirmationRequest
}

/// UI side of the confirmation gate: the loop's `execute` suspends here, and the confirmation sheet
/// (`mcpConfirmationPresenter`) reads the head of the queue and sends the user's choice back.
///
/// - One at a time: the queue follows proposal order and the sheet only ever presents its head.
/// - No timeout: waiting does not count toward the call timeout, and the sheet stays up while the app is in the
///   background; if the process is killed, that step shows as interrupted next time.
/// - When the user taps stop (the send task is cancelled) this throws `CancellationError` and the loop winds down the
///   whole turn.
@MainActor
@Observable
final class McpConfirmationCoordinator: McpConfirmationGate {
    @ObservationIgnored private var continuations: [UUID: CheckedContinuation<McpConfirmationChoice, Error>] = [:]
    /// Requests whose cancellation arrived before they were enqueued: they finish as cancelled on enqueue, so no
    /// sheet is left that nobody will ever answer.
    @ObservationIgnored private var cancelledBeforeEnqueue: Set<UUID> = []
    private(set) var pending: [PendingMcpConfirmation] = []

    nonisolated func requestConfirmation(_ request: McpConfirmationRequest) async throws -> McpConfirmationChoice {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task { @MainActor in
                    self.enqueue(PendingMcpConfirmation(id: id, request: request), continuation: continuation)
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id: id) }
        }
    }

    private func enqueue(
        _ confirmation: PendingMcpConfirmation,
        continuation: CheckedContinuation<McpConfirmationChoice, Error>
    ) {
        if cancelledBeforeEnqueue.remove(confirmation.id) != nil {
            continuation.resume(throwing: CancellationError())
            return
        }
        continuations[confirmation.id] = continuation
        pending.append(confirmation)
    }

    /// The user made a choice on the sheet.
    func resolve(id: UUID, choice: McpConfirmationChoice) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        pending.removeAll { $0.id == id }
        continuation.resume(returning: choice)
    }

    private func cancel(id: UUID) {
        guard let continuation = continuations.removeValue(forKey: id) else {
            cancelledBeforeEnqueue.insert(id)
            return
        }
        pending.removeAll { $0.id == id }
        continuation.resume(throwing: CancellationError())
    }

    /// The reply in this conversation was stopped or finished: every confirmation still waiting ends as cancelled.
    func cancel(conversationID: UUID) {
        for confirmation in pending where confirmation.request.conversationId == conversationID {
            cancel(id: confirmation.id)
        }
    }

    func cancelAll() {
        for confirmation in pending { cancel(id: confirmation.id) }
    }
}

/// A step parked on "needs to sign in again".
struct PendingMcpReauthorization: Identifiable, Equatable, Sendable {
    let id: UUID
    let request: McpReauthorizationRequest
}

/// UI side of the expired-authorization gate: the loop parks on that step and the step block offers "Re-authorize" /
/// "Skip this step".
///
/// - Skip: `skip(conversationID:stepID:)`; that step feeds back `auth_skipped` and the reply continues.
/// - Signing in again happens in the server management UI (opening the browser is a UI flow); once it succeeds, call
///   `serverReauthorized(_:)` and every step parked on that server resumes where it stopped, without redoing earlier
///   results.
/// - No timeout; throws `CancellationError` when the user taps stop.
@MainActor
@Observable
final class McpReauthorizationCoordinator: McpReauthorizationGate {
    @ObservationIgnored private var continuations: [UUID: CheckedContinuation<McpReauthorizationChoice, Error>] = [:]
    @ObservationIgnored private var cancelledBeforeEnqueue: Set<UUID> = []
    private(set) var pending: [PendingMcpReauthorization] = []
    /// Which conversation each on-screen chat page is showing (the value is a registration count: in split view the
    /// same conversation can be on screen twice).
    private(set) var visibleChatConversations: [UUID: Int] = [:]

    func chatPageAppeared(_ conversationID: UUID) {
        visibleChatConversations[conversationID, default: 0] += 1
    }

    func chatPageDisappeared(_ conversationID: UUID) {
        guard let count = visibleChatConversations[conversationID] else { return }
        visibleChatConversations[conversationID] = count > 1 ? count - 1 : nil
    }

    /// The one prompt the app root should present right now: when the user is not in the conversation that started
    /// the reply, the prompt follows the user.
    ///
    /// Three cases where the root does not present it: that conversation's chat page is on screen (both buttons are
    /// already under the step block); the user is signing in again on that server's detail page (another layer would
    /// cover the sign-in); the user just dismissed this one (dismissing is not skipping, the step keeps waiting).
    func rootPrompt(signingInServerId: UUID?, dismissed: Set<UUID> = []) -> PendingMcpReauthorization? {
        pending.first { item in
            visibleChatConversations[item.request.conversationId] == nil
                && item.request.serverId != signingInServerId
                && !dismissed.contains(item.id)
        }
    }

    /// When the top of the navigation stack is a server's detail page, that server is being (or is about to be)
    /// signed in again.
    static func signingInServerId(in path: [AppRoute]) -> UUID? {
        if case let .mcpServerDetail(serverID, _)? = path.last { return serverID }
        return nil
    }

    nonisolated func requestReauthorization(_ request: McpReauthorizationRequest) async throws -> McpReauthorizationChoice {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task { @MainActor in
                    if self.cancelledBeforeEnqueue.remove(id) != nil {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    self.continuations[id] = continuation
                    self.pending.append(PendingMcpReauthorization(id: id, request: request))
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id: id) }
        }
    }

    private func resolve(id: UUID, choice: McpReauthorizationChoice) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        pending.removeAll { $0.id == id }
        continuation.resume(returning: choice)
    }

    /// The user tapped "Skip this step".
    func skip(conversationID: UUID, stepID: String) {
        for item in pending where item.request.conversationId == conversationID && item.request.stepId == stepID {
            resolve(id: item.id, choice: .skip)
        }
    }

    /// This server was signed in again successfully: every step parked on it resumes.
    func serverReauthorized(_ serverId: UUID) {
        for item in pending where item.request.serverId == serverId {
            resolve(id: item.id, choice: .reauthorized)
        }
    }

    private func cancel(id: UUID) {
        guard let continuation = continuations.removeValue(forKey: id) else {
            cancelledBeforeEnqueue.insert(id)
            return
        }
        pending.removeAll { $0.id == id }
        continuation.resume(throwing: CancellationError())
    }

    func cancel(conversationID: UUID) {
        for item in pending where item.request.conversationId == conversationID { cancel(id: item.id) }
    }

    func cancelAll() {
        for item in pending { cancel(id: item.id) }
    }
}
