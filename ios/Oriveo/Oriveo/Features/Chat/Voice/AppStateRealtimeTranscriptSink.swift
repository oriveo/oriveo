import Foundation
import os

/// Attribution of one realtime-session turn: the realtime model on the voice connection.
nonisolated struct RealtimeVoiceAttribution: Sendable, Hashable {
    let providerID: UUID
    let providerKind: ProviderKind
    let providerName: String
    let model: String
}

/// Stores completed realtime-session turns as ordinary text messages (no source marker, no generation, no usage recorded).
/// Written through ChatManager in production; tests inject a writer.
/// When entered from the home page the conversation id is nil: when the first turn event arrives (assistant audio / transcript, user transcript) the controller creates the conversation through ensureConversation and opens the chat page,
/// then follows the new conversation id; with no turn event nothing is created. Creation is attempted once per session. A created conversation is deleted only if, by the end of the session, this sink persisted nothing and the store holds no messages,
/// and after deleting, the app returns to the home page. Chat-page entries (draft / existing conversation) never create on the first turn event and never delete:
/// a draft entry creates the conversation when the first message is persisted (carrying the draft's instruction).
@MainActor
final class AppStateRealtimeTranscriptSink: RealtimeConversationSink {
    typealias Write = @MainActor (_ message: ChatMessage, _ conversationID: UUID) -> Void
    /// Creates the conversation and opens the chat page; returns the new conversation id, or nil when it cannot be created (this turn is not persisted).
    typealias CreateConversation = @MainActor () -> UUID?
    /// Deletes an empty conversation this sink created but never persisted into (the emptiness check and the delete share one transaction); the completion reports whether it was actually deleted.
    typealias DeleteConversation = @MainActor (_ id: UUID, _ completion: @escaping @MainActor @Sendable (Bool) -> Void) -> Void
    /// Whether the store already holds messages for the conversation (writes from elsewhere count).
    typealias HasStoredMessages = @MainActor (UUID) -> Bool

    private(set) var conversationID: UUID?
    /// Home entry (set by the host before opening the session): only the home page creates a conversation on the first turn event and deletes an empty one at the end.
    var isHomeEntry = false
    let attribution: RealtimeVoiceAttribution
    /// Conversation creation before the first persisted message is in flight: during the home → chat page handoff the host must not treat the page leaving as a return.
    private(set) var isCreatingConversation = false
    /// The conversation id changed (the home page created one on the first persisted message; back to nil after one is deleted for being empty).
    var onConversationChanged: ((UUID?) -> Void)?
    private let createConversation: CreateConversation?
    private let deleteConversation: DeleteConversation?
    private let hasStoredMessages: HasStoredMessages
    /// This session has already tried to create a conversation (failing counts): once per session.
    private var creationAttempted = false
    /// The conversation this sink created (home entry); cleared once something is persisted, so if it is still set at the end the conversation is empty.
    private var emptyCreatedConversationID: UUID?
    private let write: Write
    private let now: () -> Date
    private var lastCreatedAt: Date?
    /// Id of the realtime session currently open: replaced by beginSession on every open / reopen; used as currentSessionId when replanning.
    private(set) var sessionID = UUID().uuidString
    /// Ids of messages already persisted in this session (sessionID): excluded when replanning so the session's own transcript does not change the fingerprint.
    private(set) var sessionMessageIDs: Set<UUID> = []

    init(
        conversationID: UUID?,
        attribution: RealtimeVoiceAttribution,
        now: @escaping () -> Date = Date.init,
        createConversation: CreateConversation? = nil,
        deleteConversation: DeleteConversation? = nil,
        hasStoredMessages: @escaping HasStoredMessages = { _ in false },
        write: @escaping Write
    ) {
        self.conversationID = conversationID
        self.attribution = attribution
        self.now = now
        self.createConversation = createConversation
        self.deleteConversation = deleteConversation
        self.hasStoredMessages = hasStoredMessages
        self.write = write
    }

    static func appState(_ appState: AppState, conversationID: UUID?, attribution: RealtimeVoiceAttribution) -> AppStateRealtimeTranscriptSink {
        AppStateRealtimeTranscriptSink(
            conversationID: conversationID,
            attribution: attribution,
            createConversation: { [weak appState] in appState?.createConversationForRealtimeVoice() },
            deleteConversation: { [weak appState] id, completion in
                guard let appState else { return completion(false) }
                // Not a user deletion: skips deleteConversation (delete analytics / parameter cleanup); the emptiness check, delete and tombstone run inside the write queue.
                appState.deleteConversationIfEmpty(id: id) { [weak appState] deleted in
                    // deleted = empty in memory and already removed (step one of two); return to the home page only if that conversation is still on screen. If it is gone from memory or already has messages, nothing is deleted and nothing navigates.
                    if deleted { appState?.navigation.dismissChat(conversationID: id) }
                    completion(deleted)
                }
            },
            hasStoredMessages: { [weak appState] id in
                !(appState?.conversation(for: id)?.messages.isEmpty ?? true)
            }
        ) { [weak appState] message, id in
            guard let appState else {
                RealtimeVoiceLog.logger.info("persist skipped id=\(message.id.uuidString, privacy: .public) reason=appStateGone")
                return
            }
            if !appState.chatManager.appendCompletedTextMessage(message, in: id) {
                RealtimeVoiceLog.logger.error(
                    "persist rejected id=\(message.id.uuidString, privacy: .public) reason=conversationMissing"
                )
            }
        }
    }

    /// Opens / reopens a realtime session: replaces the session id, and earlier transcript becomes ordinary history from then on.
    @discardableResult
    func beginSession() -> String {
        sessionID = UUID().uuidString
        sessionMessageIDs = []
        return sessionID
    }

    var hasConversation: Bool? { conversationID != nil }

    func appendUser(_ text: String) { append(.user, text) }
    func appendAssistant(_ text: String) { append(.assistant, text) }

    /// First turn event: a home entry with no conversation yet creates one and opens the chat page (reusing the same path as creating before the first persisted message); returns false when it cannot be created.
    /// Chat-page entries do not create here.
    func ensureConversation() -> Bool {
        guard isHomeEntry, conversationID == nil else { return true }
        return makeConversation() != nil
    }

    /// Session ended: a conversation this sink created for a home entry is deleted if nothing was persisted into it and the store holds no messages; the id returns to nil only when it was really deleted,
    /// so the host no longer points at a deleted conversation. Deletion completes asynchronously on the write queue; if it did not happen (already gone / has messages / write failed) the id is left alone.
    func conversationEnded() {
        guard isHomeEntry, let empty = emptyCreatedConversationID else { return }
        emptyCreatedConversationID = nil
        guard !hasStoredMessages(empty), let deleteConversation else { return }
        // Held strongly until the delete callback: the host has already released this sink when the session ends, but the callback still has to reset the id on the host.
        deleteConversation(empty) { deleted in
            RealtimeVoiceLog.logger.info(
                "empty conversation delete id=\(empty.uuidString, privacy: .public) deleted=\(deleted)"
            )
            guard deleted, self.conversationID == empty else { return }
            self.conversationID = nil
            self.onConversationChanged?(nil)
        }
    }

    /// The message persisted for one turn; both user and assistant carry the realtime model attribution.
    static func message(role: ChatRole, text: String, attribution: RealtimeVoiceAttribution, createdAt: Date) -> ChatMessage {
        ChatMessage(
            id: UUID(),
            role: role,
            text: text,
            providerID: attribution.providerID,
            providerKind: attribution.providerKind,
            providerName: attribution.providerName,
            modelID: attribution.model,
            modelName: attribution.model,
            state: .delivered,
            createdAt: createdAt,
            providerMode: .byok
        )
    }

    private func append(_ role: ChatRole, _ text: String) {
        guard let conversationID = conversationID ?? makeConversation() else {
            let reason = creationAttempted ? "conversationUnavailable" : "noConversation"
            RealtimeVoiceLog.logger.info(
                "persist skipped role=\(String(describing: role), privacy: .public) text=\(RealtimeVoiceLog.text(text), privacy: .public) reason=\(reason, privacy: .public)"
            )
            return
        }
        // Guarantees createdAt strictly increases even when two turns are persisted at the same instant.
        var createdAt = now()
        if let lastCreatedAt, createdAt <= lastCreatedAt { createdAt = lastCreatedAt.addingTimeInterval(0.001) }
        lastCreatedAt = createdAt
        let message = Self.message(role: role, text: text, attribution: attribution, createdAt: createdAt)
        sessionMessageIDs.insert(message.id)
        if emptyCreatedConversationID == conversationID { emptyCreatedConversationID = nil }
        RealtimeVoiceLog.logger.info(
            "persist write role=\(String(describing: role), privacy: .public) id=\(message.id.uuidString, privacy: .public) text=\(RealtimeVoiceLog.text(text), privacy: .public)"
        )
        write(message, conversationID)
    }

    private func makeConversation() -> UUID? {
        guard !creationAttempted else { return nil }
        creationAttempted = true
        isCreatingConversation = true
        let created = createConversation?()
        isCreatingConversation = false
        guard let created else { return nil }
        conversationID = created
        emptyCreatedConversationID = created
        onConversationChanged?(created)
        return created
    }
}
