import Foundation
import Observation
import OriveoProviderKit

/// "Set as instruction" suggestion bar (P4·U3 contract item 5).
///
/// Only newly sent chat user messages are evaluated (`AppState.sendMessage`). The pending suggestion lives in
/// memory, one per conversation: the next user message, switching conversations or relaunching drops it without
/// counting as an ignore. The consecutive-ignore streak is a local key `directive_suggestion_ignores:<id>`.
@MainActor
@Observable
final class DirectiveSuggestionController {
    struct Suggestion: Equatable, Sendable {
        let messageID: UUID
        /// Lexical route: detector span, or the trimmed full text when the span is empty.
        /// Tool route: the instruct sentence (propose_memory sourceQuote, trimmed).
        let sentence: String
    }

    static let undoDuration: TimeInterval = 5

    @ObservationIgnored private let defaults: UserDefaults
    private(set) var pendingByConversation: [UUID: Suggestion] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func ignoreKey(_ conversationID: UUID) -> String {
        "directive_suggestion_ignores:\(conversationID.uuidString)"
    }

    // MARK: Rules

    /// Lexical route (requests that cannot carry propose_memory): the sentence to offer, or nil when the message
    /// is not a directive, its detected language is not in the detector's suggestionLanguages (propose-v3), the
    /// sentence is already part of the instructions, or appending it would exceed `ConversationInstructions.maxCodePoints`.
    nonisolated static func candidateSentence(for text: String, instructions: String) -> String? {
        let detection = DirectiveDetector.detect(text)
        guard detection.isSuggestionLanguage else { return nil }
        let span = trimWhiteSpace(detection.span ?? "")
        let sentence = span.isEmpty ? trimWhiteSpace(text) : span
        guard MemoryPropose.instructionBarShows(sentence: sentence, instructions: instructions, ignoreCount: 0)
        else { return nil }
        return sentence
    }

    /// Trims Unicode White_Space code points at both ends (same rule as the other clients).
    nonisolated static func trimWhiteSpace(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        guard let first = scalars.firstIndex(where: { !$0.properties.isWhitespace }),
              let last = scalars.lastIndex(where: { !$0.properties.isWhitespace })
        else { return "" }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[first...last])
        return String(view)
    }

    nonisolated static func appended(_ sentence: String, to instructions: String) -> String {
        instructions.isEmpty ? sentence : instructions + "\n" + sentence
    }

    // MARK: State

    func pending(in conversationID: UUID?) -> Suggestion? {
        conversationID.flatMap { pendingByConversation[$0] }
    }

    func ignoreCount(in conversationID: UUID) -> Int {
        defaults.integer(forKey: Self.ignoreKey(conversationID))
    }

    /// A new user message was sent: drop any previous suggestion, then evaluate this one. Only messages that
    /// `MemoryIntent.classify` routes to `.conversationInstruction` are considered (P6·U3 contract item 1).
    func evaluate(
        text: String,
        messageID: UUID,
        conversationID: UUID,
        instructions: String,
        suggestion: MemoryIntent.Suggestion
    ) {
        pendingByConversation[conversationID] = nil
        guard suggestion == .conversationInstruction,
              ignoreCount(in: conversationID) < MemoryPropose.instructionBarIgnoreLimit,
              let sentence = Self.candidateSentence(for: text, instructions: instructions)
        else { return }
        pendingByConversation[conversationID] = Suggestion(messageID: messageID, sentence: sentence)
    }

    /// A tool-mode fresh send (propose-v3): the lexical route does not run; only the previous message's
    /// suggestion is dropped, so an instruct that already arrived for this message stays.
    func beginToolTurn(messageID: UUID, conversationID: UUID) {
        guard let pending = pendingByConversation[conversationID], pending.messageID != messageID else { return }
        pendingByConversation[conversationID] = nil
    }

    /// The model's propose_memory instruct outcome for this user message (propose-v3 rule 5): offered under the
    /// same ignore / substring / length rules as the lexical bar.
    func offerInstruct(sentence: String, messageID: UUID, conversationID: UUID, instructions: String) {
        guard MemoryPropose.instructionBarShows(
            sentence: sentence, instructions: instructions, ignoreCount: ignoreCount(in: conversationID)
        ) else { return }
        pendingByConversation[conversationID] = Suggestion(messageID: messageID, sentence: sentence)
    }

    /// Conversation switch / new chat: pending suggestions disappear without counting as ignores.
    func clearAll() {
        guard !pendingByConversation.isEmpty else { return }
        pendingByConversation = [:]
    }

    /// The message it was offered for was rolled back (P9 U8 gate cancel): drop it without counting as an ignore.
    func withdraw(messageID: UUID, conversationID: UUID) {
        guard pendingByConversation[conversationID]?.messageID == messageID else { return }
        pendingByConversation[conversationID] = nil
    }

    func ignore(conversationID: UUID) {
        guard pendingByConversation.removeValue(forKey: conversationID) != nil else { return }
        defaults.set(ignoreCount(in: conversationID) + 1, forKey: Self.ignoreKey(conversationID))
    }

    /// Appends the pending sentence to the instructions and resets the ignore streak.
    /// Returns the previous instructions (for undo), or nil when nothing was pending.
    @discardableResult
    func accept(conversationID: UUID, appState: AppState) -> String? {
        guard let suggestion = pendingByConversation.removeValue(forKey: conversationID),
              let conversation = appState.conversation(for: conversationID)
        else { return nil }
        let previous = conversation.instructions
        appState.conversationManager.setInstructions(
            id: conversationID,
            text: Self.appended(suggestion.sentence, to: previous)
        )
        defaults.removeObject(forKey: Self.ignoreKey(conversationID))
        return previous
    }

    func undo(conversationID: UUID, previous: String, appState: AppState) {
        appState.conversationManager.setInstructions(id: conversationID, text: previous)
    }

    /// UI entry: accept, then a 5 s toast whose action writes the old value back.
    func acceptWithUndoToast(conversationID: UUID, appState: AppState) {
        guard let previous = accept(conversationID: conversationID, appState: appState) else { return }
        ToastManager.shared.show(
            L10n.tr("directive_suggestion_added", table: .chat),
            duration: Self.undoDuration,
            actionTitle: L10n.tr("Undo", table: .notes)
        ) { [weak self, weak appState] in
            guard let self, let appState else { return }
            self.undo(conversationID: conversationID, previous: previous, appState: appState)
        }
    }
}
