import Foundation
import Observation

/// A send held at the pre-send confirmation gate (P9 U8), waiting for "Send anyway" or "Cancel".
struct PendingContextCapConfirmation: Identifiable, Equatable, Sendable {
    let id: UUID
    let conversationID: UUID
    /// Assistant placeholder of the held send.
    let messageID: UUID
    let prompt: ContextCapConfirmPresentation.Prompt
}

enum ContextCapConfirmChoice: Equatable, Sendable {
    /// "Send anyway"; `dontAsk` is the dialog checkbox (only honoured when the box was shown).
    case send(dontAsk: Bool)
    case cancel
}

/// Gate between pre-send compaction and transport: the send task suspends here until the chat screen
/// resolves the dialog. No timeout; a cancelled send task or a stop resolves as cancel.
@MainActor
@Observable
final class ContextCapConfirmCoordinator {
    @ObservationIgnored private var continuations: [UUID: CheckedContinuation<ContextCapConfirmChoice, Never>] = [:]
    private(set) var pendingConfirmations: [PendingContextCapConfirmation] = []

    func request(
        _ prompt: ContextCapConfirmPresentation.Prompt,
        conversationID: UUID,
        messageID: UUID
    ) async -> ContextCapConfirmChoice {
        let pending = PendingContextCapConfirmation(
            id: UUID(),
            conversationID: conversationID,
            messageID: messageID,
            prompt: prompt
        )
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .cancel)
                    return
                }
                // One held send per conversation: a newer one supersedes the older.
                cancel(conversationID: conversationID)
                pendingConfirmations.append(pending)
                continuations[pending.id] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolve(id: pending.id, choice: .cancel)
            }
        }
    }

    func pending(for conversationID: UUID) -> PendingContextCapConfirmation? {
        pendingConfirmations.first { $0.conversationID == conversationID }
    }

    func resolve(id: UUID, choice: ContextCapConfirmChoice) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        pendingConfirmations.removeAll { $0.id == id }
        continuation.resume(returning: choice)
    }

    func cancel(conversationID: UUID) {
        let ids = pendingConfirmations
            .filter { $0.conversationID == conversationID }
            .map(\.id)
        for id in ids {
            resolve(id: id, choice: .cancel)
        }
    }

    func cancelAll() {
        let ids = pendingConfirmations.map(\.id)
        for id in ids {
            resolve(id: id, choice: .cancel)
        }
    }
}

/// A held send that was cancelled and rolled back: what the composer gets back when it is empty (B2).
struct ContextCapSendRollback: Sendable {
    let conversationID: UUID
    let text: String
    /// Already turned back into composer attachments (see `ComposerAttachmentRestoration`).
    let attachments: [Attachment]
    let quoteContext: QuoteContext?
}
