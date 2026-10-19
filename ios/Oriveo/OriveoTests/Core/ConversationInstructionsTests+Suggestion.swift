import Foundation
import OriveoProviderKit
import Testing
import SwiftUI
import UIKit
@testable import Oriveo

// The "Set as instruction" suggestion bar.
// Assertions come from the production path: AppState.sendMessage -> DirectiveSuggestionController decides; accept / ignore / undo go through
// ConversationManager.setInstructions, which writes back to the conversation object.

/// Every request answers 503: only the user message landing matters and no real reply is needed.
private final class SuggestionStubProtocol: URLProtocol, @unchecked Sendable {
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SuggestionStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Whether two colors resolve to the same RGBA under light / dark appearance (UIColor(Color) is created anew each time, so == cannot be used directly).
private func sameResolvedColor(_ lhs: UIColor?, _ rhs: UIColor) -> Bool {
    guard let lhs else { return false }
    return [UIUserInterfaceStyle.light, .dark].allSatisfy { style in
        let traits = UITraitCollection(userInterfaceStyle: style)
        var a: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var b: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        guard lhs.resolvedColor(with: traits).getRed(&a.0, green: &a.1, blue: &a.2, alpha: &a.3),
              rhs.resolvedColor(with: traits).getRed(&b.0, green: &b.1, blue: &b.2, alpha: &b.3)
        else { return false }
        return abs(a.0 - b.0) < 0.002 && abs(a.1 - b.1) < 0.002 && abs(a.2 - b.2) < 0.002 && abs(a.3 - b.3) < 0.002
    }
}

extension ConversationInstructionsTests {
    private static let directive = "From now on, reply in English."

    /// The primary "Set as instruction" button uses the brand color with white text, not the system blue (AccentColor is empty).
    @MainActor
    @Test("directive bar accept button uses the brand primary color")
    func directiveAcceptButtonUsesPrimary() throws {
        let bar = DirectiveSuggestionBarView()
        let config = try #require(bar.acceptButtonConfigurationForTesting)
        #expect(sameResolvedColor(config.baseBackgroundColor, UIColor(OriveoTheme.Palette.primary)))
        #expect(sameResolvedColor(config.baseForegroundColor, .white))
    }

    @MainActor
    private func withSuggestionState(
        instructions: String = "",
        memoryFallback: Bool = false,
        _ body: (AppState, Conversation, UserDefaults) async throws -> Void
    ) async rethrows {
        let uid = "instructions-suggestion-\(UUID().uuidString)"
        let suiteName = "directive-suggestion-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let state = AppState(seedDemoData: false, sessionUID: uid, providerSession: SuggestionStubProtocol.session())
        state.directiveSuggestions = DirectiveSuggestionController(defaults: defaults)
        let provider = TestFactories.makeProvider()
        state.providers = [provider]
        // A new send with mode=tool goes through propose_memory and does not run v1 candidate generation; to test the v1 path, put the connection and model into the downgraded set to use the fallback.
        if memoryFallback {
            ProposeMemoryRuntime.shared.markDegraded(connectionID: provider.id, modelID: "gpt-4o")
        }
        var conversation = TestFactories.makeConversation(
            hasCustomTitle: true,
            providerID: provider.id,
            modelID: "gpt-4o",
            messages: [TestFactories.makeMessage()]
        )
        conversation.instructions = instructions
        state.upsertConversationProjection(conversation)
        defer {
            state.flushConversationPersistQueue()
            DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
            defaults.removePersistentDomain(forName: suiteName)
        }
        try await body(state, conversation, defaults)
    }

    @MainActor
    private func lastUserMessageID(_ state: AppState, _ conversationID: UUID) -> UUID? {
        state.conversation(for: conversationID)?.messages.last(where: { $0.role == .user })?.id
    }

    @Test("suggestion_shown_for_directive_message")
    @MainActor
    func suggestionShownForDirectiveMessage() async throws {
        try await withSuggestionState { state, conversation, _ in
            // A non-instruction message shows no bar.
            _ = await state.sendMessage("What is the capital of France?", in: conversation.id)
            #expect(state.directiveSuggestions.pending(in: conversation.id) == nil)

            _ = await state.sendMessage(Self.directive, in: conversation.id)
            let pending = try #require(state.directiveSuggestions.pending(in: conversation.id))
            #expect(pending.messageID == lastUserMessageID(state, conversation.id))
            #expect(pending.sentence == DirectiveDetector.detect(Self.directive).span)

            // The next user message clears the pending suggestion and does not count as an ignore.
            _ = await state.sendMessage("Thanks.", in: conversation.id)
            #expect(state.directiveSuggestions.pending(in: conversation.id) == nil)
            #expect(state.directiveSuggestions.ignoreCount(in: conversation.id) == 0)

            // Switching conversations clears the pending suggestion.
            _ = await state.sendMessage(Self.directive, in: conversation.id)
            #expect(state.directiveSuggestions.pending(in: conversation.id) != nil)
            state.openChat(conversationID: UUID())
            #expect(state.directiveSuggestions.pending(in: conversation.id) == nil)
        }
    }

    @Test("suggestion_not_shown_after_three_ignores")
    @MainActor
    func suggestionNotShownAfterThreeIgnores() async throws {
        try await withSuggestionState { state, conversation, defaults in
            for expected in 1...3 {
                _ = await state.sendMessage(Self.directive, in: conversation.id)
                #expect(state.directiveSuggestions.pending(in: conversation.id) != nil)
                state.directiveSuggestions.ignore(conversationID: conversation.id)
                #expect(state.directiveSuggestions.pending(in: conversation.id) == nil)
                #expect(defaults.integer(forKey: "directive_suggestion_ignores:\(conversation.id.uuidString)") == expected)
            }
            _ = await state.sendMessage(Self.directive, in: conversation.id)
            #expect(state.directiveSuggestions.pending(in: conversation.id) == nil)
        }
    }

    @Test("suggestion_accept_appends_and_undo_restores")
    @MainActor
    func suggestionAcceptAppendsAndUndoRestores() async throws {
        try await withSuggestionState(instructions: "Use metric units.") { state, conversation, _ in
            _ = await state.sendMessage(Self.directive, in: conversation.id)
            let sentence = try #require(state.directiveSuggestions.pending(in: conversation.id)?.sentence)

            let previous = try #require(state.directiveSuggestions.accept(conversationID: conversation.id, appState: state))
            #expect(previous == "Use metric units.")
            #expect(state.conversation(for: conversation.id)?.instructions == "Use metric units.\n" + sentence)
            #expect(state.directiveSuggestions.pending(in: conversation.id) == nil)

            state.directiveSuggestions.undo(conversationID: conversation.id, previous: previous, appState: state)
            #expect(state.conversation(for: conversation.id)?.instructions == "Use metric units.")
        }
        // Appending to empty instructions yields the original sentence.
        try await withSuggestionState { state, conversation, _ in
            _ = await state.sendMessage(Self.directive, in: conversation.id)
            let sentence = try #require(state.directiveSuggestions.pending(in: conversation.id)?.sentence)
            #expect(state.directiveSuggestions.accept(conversationID: conversation.id, appState: state) == "")
            #expect(state.conversation(for: conversation.id)?.instructions == sentence)
        }
    }

    @Test("suggestion_skipped_when_already_in_instructions")
    @MainActor
    func suggestionSkippedWhenAlreadyInInstructions() async throws {
        let sentence = try #require(DirectiveDetector.detect(Self.directive).span)
        try await withSuggestionState(instructions: "Rules:\n\(sentence)\nBe brief.") { state, conversation, _ in
            _ = await state.sendMessage(Self.directive, in: conversation.id)
            #expect(state.directiveSuggestions.pending(in: conversation.id) == nil)
        }
        // Not shown either if appending would exceed 8000 code points.
        let nearlyFull = String(repeating: "a", count: ConversationInstructions.maxCodePoints - 5)
        try await withSuggestionState(instructions: nearlyFull) { state, conversation, _ in
            _ = await state.sendMessage(Self.directive, in: conversation.id)
            #expect(state.directiveSuggestions.pending(in: conversation.id) == nil)
        }
    }

    @Test("suggestion_accept_resets_ignore_streak")
    @MainActor
    func suggestionAcceptResetsIgnoreStreak() async throws {
        try await withSuggestionState { state, conversation, defaults in
            let key = "directive_suggestion_ignores:\(conversation.id.uuidString)"
            for _ in 0..<2 {
                _ = await state.sendMessage(Self.directive, in: conversation.id)
                state.directiveSuggestions.ignore(conversationID: conversation.id)
            }
            #expect(defaults.integer(forKey: key) == 2)

            _ = await state.sendMessage("From now on, reply in French.", in: conversation.id)
            #expect(state.directiveSuggestions.pending(in: conversation.id) != nil)
            #expect(state.directiveSuggestions.accept(conversationID: conversation.id, appState: state) != nil)
            #expect(defaults.integer(forKey: key) == 0)
            #expect(state.directiveSuggestions.ignoreCount(in: conversation.id) == 0)
        }
    }

    @Test("suggestion_not_shown_for_edit_resend")
    @MainActor
    func suggestionNotShownForEditResend() async throws {
        try await withSuggestionState { state, conversation, _ in
            _ = await state.sendMessage("What is the capital of France?", in: conversation.id)
            let editedID = try #require(lastUserMessageID(state, conversation.id))
            _ = state.beginEditingUserMessage(messageID: editedID, in: conversation.id)
            #expect(state.chatManager.isPendingEditResend(conversation.id))

            // Editing and resending an instruction sentence: no bar.
            _ = await state.sendMessage(Self.directive, in: conversation.id)
            #expect(!state.chatManager.isPendingEditResend(conversation.id))
            #expect(state.directiveSuggestions.pending(in: conversation.id) == nil)

            // An automatic send from the onboarding flow (without the evaluate flag) likewise shows no bar.
            _ = await state.sendMessage(Self.directive, in: conversation.id, evaluatesDirectiveSuggestion: false)
            #expect(state.directiveSuggestions.pending(in: conversation.id) == nil)

            // A normal new send afterwards is evaluated as usual.
            _ = await state.sendMessage(Self.directive, in: conversation.id)
            #expect(state.directiveSuggestions.pending(in: conversation.id) != nil)
        }
    }

    /// Waits for the background candidate generation of sendMessage to finish, then reads the actual pending items from the repository.
    @MainActor
    private func pendingCandidates(_ state: AppState) async throws -> [MemoryCandidate] {
        await state.memoryCandidateGeneration?.value
        let repository = try #require(state.memoryCandidateRepository())
        return try await repository.pending(nowMs: Int64(Date().timeIntervalSince1970 * 1000))
    }

    @Test("memory_candidate_generated_on_fresh_send")
    @MainActor
    func memoryCandidateGeneratedOnFreshSend() async throws {
        let remember = "\u{8BB0}\u{4F4F}\u{6211}\u{504F}\u{597D}\u{7B80}\u{6D01}\u{56DE}\u{7B54}"
        // The user sends a new message (fallback mode, v1 candidate generation): one pending item appears, with messageId / conversationId matching the message just sent.
        try await withSuggestionState(memoryFallback: true) { state, conversation, _ in
            _ = await state.sendMessage(remember, in: conversation.id)
            let pending = try await pendingCandidates(state)
            #expect(pending.count == 1)
            let candidate = try #require(pending.first)
            #expect(candidate.status == .pending)
            #expect(candidate.source.messageIds == [try #require(lastUserMessageID(state, conversation.id)).uuidString])
            #expect(candidate.source.conversationId == conversation.id.uuidString)
        }
        // Edit-and-resend and automatic onboarding sends (evaluatesDirectiveSuggestion: false) produce none.
        try await withSuggestionState(memoryFallback: true) { state, conversation, _ in
            _ = await state.sendMessage("What is the capital of France?", in: conversation.id)
            let editedID = try #require(lastUserMessageID(state, conversation.id))
            _ = state.beginEditingUserMessage(messageID: editedID, in: conversation.id)
            _ = await state.sendMessage(remember, in: conversation.id)
            #expect(try await pendingCandidates(state).isEmpty)

            _ = await state.sendMessage(remember, in: conversation.id, evaluatesDirectiveSuggestion: false)
            #expect(try await pendingCandidates(state).isEmpty)
        }
        // A conversation with useMemory=false produces none.
        try await withSuggestionState(memoryFallback: true) { state, conversation, _ in
            var updated = try #require(state.conversation(for: conversation.id))
            updated.useMemory = false
            state.upsertConversationProjection(updated)
            _ = await state.sendMessage(remember, in: conversation.id)
            #expect(try await pendingCandidates(state).isEmpty)
        }
    }

    @Test("suggestion_sentence_trims_white_space")
    func suggestionSentenceTrimsWhiteSpace() {
        let sentence = DirectiveSuggestionController.candidateSentence(
            for: "\u{3000} \(Self.directive)\u{00A0}\n", instructions: ""
        )
        #expect(sentence == DirectiveSuggestionController.trimWhiteSpace(sentence ?? ""))
        #expect(sentence?.hasPrefix("From") == true)
        #expect(DirectiveSuggestionController.trimWhiteSpace("\u{2003}a b\u{3000}") == "a b")
        #expect(DirectiveSuggestionController.trimWhiteSpace(" \u{00A0}\n") == "")
    }
}
