import Foundation
import OriveoProviderKit

extension ChatRequestBuilder {
    /// Opening input of a realtime session: the conversation / memory / reminder switches share the chat assembly (assembleInput),
    /// the history is every message in the snapshot (except the one excluded by the send path; quotes are expanded as in chat), and the current message is not split off.
    /// Checkpoints follow the same rule as chat stored rows: coversTo is applied only if it is in the history, covered messages (including coversTo) leave the history, and row.text goes to the kit.
    /// The history goes through ContextSanitizer.sanitize (the same one chat uses), so what reaches the kit is already sanitize-idempotent.
    /// When currentSessionId is non-nil, messages in sessionMessageIds (ids of this session's messages already persisted, held in host memory) are removed before sanitizing;
    /// realtimeSessionId is not persisted, so history messages never carry one (this session's transcripts were removed in the previous step).
    static func realtimeSessionInput(
        _ snapshot: ChatRequestSnapshot,
        contextWindow: Int?,
        currentSessionId: String?,
        sessionMessageIds: Set<UUID>,
        rhoHi: Double = 0.5,
        checkpoint: ContextCheckpointRecord? = nil
    ) -> RealtimeSessionInput {
        let assembly = ChatRequestAssemblyContext(
            window: ContextWindowInput(W: contextWindow, windowKind: .total, maxOutput: ContextMaxOutputSources()),
            rhoHi: rhoHi
        )
        let assembled = assembleInput(snapshot, assembly: assembly).input
        var excluding: UUID?
        if case .send(let excluded) = snapshot.sendPath { excluding = excluded }
        var messages: [ContextMessage] = snapshot.messages
            .filter { $0.id != excluding }
            .map { message in
                var context = contextMessage(message)
                if message.role == .user {
                    context.text = QuotePromptBuilder.effectiveUserContent(
                        userInput: message.text, quoteContext: message.quoteContext
                    )
                }
                return context
            }
        var checkpointText: String?
        if let checkpoint, let coversIndex = messages.firstIndex(where: { $0.id == checkpoint.coversTo }) {
            messages = Array(messages[(coversIndex + 1)...])
            checkpointText = checkpoint.text
        }
        let sessionIds = Set(sessionMessageIds.map(\.uuidString))
        // Remove this session's transcripts before sanitizing: sanitize keeps the later id when it merges adjacent user messages,
        // so without removing first, an unanswered chat user message would be dropped together with the session user transcript that follows it.
        if currentSessionId != nil {
            messages.removeAll { sessionIds.contains($0.id) }
        }
        let history = ContextSanitizer.sanitize(messages).map { RealtimeSessionMessage($0) }
        return RealtimeSessionInput(
            contextWindow: contextWindow,
            rhoHi: rhoHi,
            conversation: assembled.conversation,
            memoryItems: assembled.memoryItems,
            history: history,
            checkpoint: checkpointText,
            reminderEnabled: assembled.reminderEnabled,
            currentSessionId: currentSessionId
        )
    }
}

/// Source of the input for opening or re-planning a realtime session: the main actor only takes the conversation snapshot (ChatManager.realtimeSessionSource),
/// while the checkpoint read and input assembly live in `input`, which can run off the main actor (re-planning at a turn boundary).
nonisolated struct RealtimeSessionSource: Sendable {
    let snapshot: ChatRequestSnapshot
    /// Reads the latestValid checkpoint; nil when none is available.
    let checkpoint: @Sendable (ChatRequestSnapshot) -> ContextCheckpointRecord?
    /// Pinned notes to read back that are not in the snapshot (the pending pinned notes of a new conversation started from the home screen, read from the database); nil = the snapshot's pinnedNotes are already complete.
    let pinnedNotes: (@Sendable () -> [ChatRequestPinnedNoteSnapshot])?

    init(
        snapshot: ChatRequestSnapshot,
        checkpoint: @escaping @Sendable (ChatRequestSnapshot) -> ContextCheckpointRecord? = { _ in nil },
        pinnedNotes: (@Sendable () -> [ChatRequestPinnedNoteSnapshot])? = nil
    ) {
        self.snapshot = snapshot
        self.checkpoint = checkpoint
        self.pinnedNotes = pinnedNotes
    }

    /// When currentSessionId is non-nil, messages in sessionMessageIds (this session's transcripts) stay out of the plan.
    func input(contextWindow: Int?, currentSessionId: String?, sessionMessageIds: Set<UUID>) -> RealtimeSessionInput {
        let snapshot = pinnedNotes.map { self.snapshot.withPinnedNotes($0()) } ?? self.snapshot
        return ChatRequestBuilder.realtimeSessionInput(
            snapshot,
            contextWindow: contextWindow,
            currentSessionId: currentSessionId,
            sessionMessageIds: sessionMessageIds,
            checkpoint: checkpoint(snapshot)
        )
    }
}
