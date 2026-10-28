import Foundation
import Observation
import OriveoProviderKit

/// What the chat list draws under the turn's assistant message for a pending memory suggestion
/// (P6·U3 contract items 3 / 7, P10 contract item 7); shown once that message is no longer streaming.
nonisolated struct MemorySuggestionBar: Hashable, Sendable {
    /// The turn's assistant message.
    let messageID: UUID
    /// Candidate body; nil when memory is off for the conversation (hint text only, no buttons).
    let content: String?
}

/// Memory bar "Edit" sheet target: the captured candidate plus the prefilled P5 item editor (new-item mode).
struct MemorySuggestionEdit: Identifiable, Equatable, Sendable {
    let conversationID: UUID
    let candidate: MemoryCandidate
    let state: MemoryItemEditorState

    var id: String { candidate.id }
}

/// "Save to memory?" suggestion bar (P6·U3 contract items 1, 2, 7).
///
/// Only newly sent chat user messages are evaluated (`AppState.sendMessage`). Mode fallback routes by
/// `MemoryIntent.classify(text).suggestion == .memory`; mode tool takes the turn's first created propose_memory
/// candidate. Either way the bar is keyed by the turn's assistant message (P10 contract item 7). The bar lives in memory, one per conversation: the next
/// user message, switching conversations or relaunching drops it without counting as an ignore (the candidate
/// itself stays pending in the repository). There is no ignore streak and the P4 counter is untouched.
@MainActor
@Observable
final class MemorySuggestionController {
    struct Suggestion: Equatable, Sendable {
        /// The turn's assistant message.
        let messageID: UUID
        /// The generated candidate; nil when memory is off (hint only).
        let candidate: MemoryCandidate?

        var bar: MemorySuggestionBar {
            MemorySuggestionBar(messageID: messageID, content: candidate?.content)
        }
    }

    private(set) var pendingByConversation: [UUID: Suggestion] = [:]
    /// Assistant message whose candidate is awaited, per conversation; cleared by a new send or a switch.
    @ObservationIgnored private var awaitingByConversation: [UUID: UUID] = [:]

    func pending(in conversationID: UUID?) -> Suggestion? {
        conversationID.flatMap { pendingByConversation[$0] }
    }

    /// A new user message was sent: drop the previous bar and any generation still in flight.
    func reset(conversationID: UUID) {
        awaitingByConversation[conversationID] = nil
        if pendingByConversation[conversationID] != nil {
            pendingByConversation[conversationID] = nil
        }
    }

    /// suggestion = memory but the effective useMemory is false: hint only, no candidate.
    func showMemoryOffHint(messageID: UUID, conversationID: UUID) {
        pendingByConversation[conversationID] = Suggestion(messageID: messageID, candidate: nil)
    }

    /// Candidate generation (fallback) or propose_memory (tool) for this turn's assistant message started.
    func awaitCandidate(messageID: UUID, conversationID: UUID) {
        awaitingByConversation[conversationID] = messageID
    }

    /// Generation finished. The bar appears only for a new candidate whose assistant message is still awaited
    /// (no newer send, no switch) and still the latest assistant message of the conversation.
    func present(
        _ candidate: MemoryCandidate?,
        messageID: UUID,
        conversationID: UUID,
        latestAssistantMessageID: UUID?
    ) {
        guard awaitingByConversation[conversationID] == messageID else { return }
        awaitingByConversation[conversationID] = nil
        guard let candidate, latestAssistantMessageID == messageID else { return }
        pendingByConversation[conversationID] = Suggestion(messageID: messageID, candidate: candidate)
    }

    /// A propose_memory call of this turn created a candidate (P10 contract item 4): the first one becomes the
    /// bar; later ones in the same turn stay in the inbox only.
    func presentProposed(_ candidate: MemoryCandidate, messageID: UUID, conversationID: UUID) {
        guard awaitingByConversation[conversationID] == messageID else { return }
        awaitingByConversation[conversationID] = nil
        pendingByConversation[conversationID] = Suggestion(messageID: messageID, candidate: candidate)
    }

    /// The turn was rolled back (P9 U8 gate cancel), keyed by its assistant message: its bar and any generation still awaited disappear,
    /// without counting as an ignore.
    func withdraw(messageID: UUID, conversationID: UUID) {
        if awaitingByConversation[conversationID] == messageID {
            awaitingByConversation[conversationID] = nil
        }
        if pendingByConversation[conversationID]?.messageID == messageID {
            pendingByConversation[conversationID] = nil
        }
    }

    /// The bar was acted on (save / edit / ignore): it disappears.
    func dismiss(conversationID: UUID) {
        pendingByConversation[conversationID] = nil
    }

    // MARK: - Actions (P6·U3 contract items 4, 5, 6)

    static let undoDuration: TimeInterval = 5

    /// Save: accept the candidate as is. The bar disappears either way; nil on failure or when nothing was pending.
    @discardableResult
    func save(conversationID: UUID, appState: AppState) async -> MemoryItem? {
        guard let candidate = pending(in: conversationID)?.candidate else { return nil }
        return await accept(candidate.id, edit: nil, conversationID: conversationID, appState: appState)
    }

    /// Editor prefilled from the pending candidate (new-item mode); the group follows proposedKind, falling back
    /// to "About me" when it maps to none. The candidate is captured so a save still works after the bar was
    /// cleared by a new send or a switch. nil without a candidate.
    func edit(conversationID: UUID) -> MemorySuggestionEdit? {
        guard let candidate = pending(in: conversationID)?.candidate else { return nil }
        return MemorySuggestionEdit(
            conversationID: conversationID,
            candidate: candidate,
            state: .create(category: Self.group(for: candidate), text: candidate.content)
        )
    }

    /// Edit then save: accept the captured candidate with the edited content; kind only when the group was
    /// changed. Scope is untouched.
    @discardableResult
    func saveEdited(_ state: MemoryItemEditorState, for target: MemorySuggestionEdit, appState: AppState) async -> MemoryItem? {
        guard state.canSave else { return nil }
        let edit = MemoryCandidateEdit(
            content: state.trimmedText,
            kind: state.category == Self.group(for: target.candidate) ? nil : state.kind
        )
        return await accept(target.candidate.id, edit: edit, conversationID: target.conversationID, appState: appState)
    }

    /// Ignore: reject the candidate (fingerprint kept) and drop the bar.
    func ignore(conversationID: UUID, appState: AppState) async {
        guard let candidate = pending(in: conversationID)?.candidate else { return }
        dismiss(conversationID: conversationID)
        guard let repository = appState.memoryCandidateRepository() else { return }
        _ = try? await repository.reject(id: candidate.id, nowMs: Self.nowMs())
    }

    /// Undo a save: the normal item delete path on the item just created.
    func undo(itemID: String, appState: AppState) {
        appState.removeMemoryItemInBackground(id: itemID)
    }

    /// UI entry: save, then a 5 s "Saved to memory" toast whose action deletes the new item.
    @discardableResult
    func saveWithUndoToast(conversationID: UUID, appState: AppState) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            let item = await self.save(conversationID: conversationID, appState: appState)
            self.showSavedToast(item, appState: appState)
        }
    }

    /// UI entry for the editor's save.
    @discardableResult
    func saveEditedWithUndoToast(
        _ state: MemoryItemEditorState,
        for target: MemorySuggestionEdit,
        appState: AppState
    ) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            let item = await self.saveEdited(state, for: target, appState: appState)
            self.showSavedToast(item, appState: appState)
        }
    }

    /// Accepts by candidate id; the bar disappears if it still shows that candidate. Failure → "couldn't save" toast.
    private func accept(
        _ candidateID: String,
        edit: MemoryCandidateEdit?,
        conversationID: UUID,
        appState: AppState
    ) async -> MemoryItem? {
        if pending(in: conversationID)?.candidate?.id == candidateID {
            dismiss(conversationID: conversationID)
        }
        if let repository = appState.memoryCandidateRepository(),
           let item = try? await repository.accept(id: candidateID, edit: edit, nowMs: Self.nowMs()) {
            return item
        }
        ToastManager.shared.show(L10n.tr("memory_suggestion_failed", table: .chat), style: .error)
        return nil
    }

    private func showSavedToast(_ item: MemoryItem?, appState: AppState) {
        guard let item else { return }
        ToastManager.shared.show(
            L10n.tr("memory_suggestion_saved", table: .chat),
            duration: Self.undoDuration,
            actionTitle: L10n.tr("Undo", table: .notes)
        ) { [weak self, weak appState] in
            guard let self, let appState else { return }
            self.undo(itemID: item.id, appState: appState)
        }
    }

    private static func group(for candidate: MemoryCandidate) -> MemoryItemGroup {
        MemoryItemGroup(kind: candidate.proposedKind) ?? .about
    }

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    /// Conversation switch / new chat: bars disappear without counting as ignores.
    func clearAll() {
        awaitingByConversation = [:]
        guard !pendingByConversation.isEmpty else { return }
        pendingByConversation = [:]
    }
}
