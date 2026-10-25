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
    /// The lexical bar only appears when the detector's lang is in suggestionLanguages: use a zh-Hans sentence.
    private static let directive = "From now on, reply in English."

    /// The primary "Set as instruction" button uses the brand color with white text, not the system blue (AccentColor is empty).
    @MainActor
    @Test("directive bar accept button uses the brand primary color", .sharedProcessState)
    func directiveAcceptButtonUsesPrimary() throws {
        let bar = DirectiveSuggestionBarView()
        let config = try #require(bar.acceptButtonConfigurationForTesting)
        #expect(sameResolvedColor(config.baseBackgroundColor, UIColor(OriveoTheme.Palette.primary)))
        #expect(sameResolvedColor(config.baseForegroundColor, .white))
    }

    @MainActor
    private func withSuggestionState(
        instructions: String = "",
        memoryFallback: Bool = true,
        provider customProvider: Provider? = nil,
        modelID: String = "gpt-4o",
        _ body: (AppState, Conversation, UserDefaults) async throws -> Void
    ) async rethrows {
        let uid = "instructions-suggestion-\(UUID().uuidString)"
        let suiteName = "directive-suggestion-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let state = AppState(seedDemoData: false, sessionUID: uid, providerSession: SuggestionStubProtocol.session())
        state.directiveSuggestions = DirectiveSuggestionController(defaults: defaults)
        let provider = customProvider ?? TestFactories.makeProvider()
        state.providers = [provider]
        // A new send with mode=tool goes through propose_memory and does not run v1 candidate generation; to test the v1 path, put the connection and model into the downgraded set to use the fallback.
        if memoryFallback {
            ProposeMemoryRuntime.shared.markDegraded(connectionID: provider.id, modelID: modelID)
        }
        var conversation = TestFactories.makeConversation(
            hasCustomTitle: true,
            providerID: provider.id,
            modelID: modelID,
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

    @Test("suggestion_shown_for_directive_message", .sharedProcessState)
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

    @Test("suggestion_not_shown_after_three_ignores", .sharedProcessState)
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

    @Test("suggestion_accept_appends_and_undo_restores", .sharedProcessState)
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

    @Test("suggestion_skipped_when_already_in_instructions", .sharedProcessState)
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

    @Test("suggestion_accept_resets_ignore_streak", .sharedProcessState)
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

    @Test("suggestion_not_shown_for_edit_resend", .sharedProcessState)
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

    @Test("memory_candidate_generated_on_fresh_send", .sharedProcessState)
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

    @Test("suggestion_sentence_trims_white_space", .sharedProcessState)
    func suggestionSentenceTrimsWhiteSpace() {
        let sentence = DirectiveSuggestionController.candidateSentence(
            for: "\u{3000} \(Self.directive)\u{00A0}\n", instructions: ""
        )
        #expect(sentence == DirectiveSuggestionController.trimWhiteSpace(sentence ?? ""))
        #expect(sentence?.hasPrefix("From") == true)
        #expect(DirectiveSuggestionController.trimWhiteSpace("\u{2003}a b\u{3000}") == "a b")
        #expect(DirectiveSuggestionController.trimWhiteSpace(" \u{00A0}\n") == "")
    }

    @Test("tool_mode_does_not_run_lexical_suggestion", .sharedProcessState)
    @MainActor
    func toolModeDoesNotRunLexicalSuggestion() async throws {
        // A fresh send that can carry tools: the lexical path does not run, and with no propose_memory call from the model no bar appears.
        try await withSuggestionState(memoryFallback: false) { state, conversation, _ in
            let mode = state.memoryProposeMode(
                conversation: try #require(state.conversation(for: conversation.id)),
                freshSend: true, useMemory: true, capabilitySelection: ChatCapabilitySelection()
            )
            #expect(mode == .tool)
            let outcome = await state.sendMessageOutcome(Self.directive, in: conversation.id)
            #expect(outcome == .sent(conversation.id))
            #expect(state.directiveSuggestions.pending(in: conversation.id) == nil)
        }
        // The same sentence on the fallback path shows the bar as usual (control).
        try await withSuggestionState { state, conversation, _ in
            _ = await state.sendMessage(Self.directive, in: conversation.id)
            #expect(state.directiveSuggestions.pending(in: conversation.id) != nil)
        }
}

    @Test("tool_mode_without_candidate_repository_runs_fallback", .sharedProcessState)
    @MainActor
    func toolModeWithoutCandidateRepositoryRunsFallback() async throws {
        // Judged as tool but the candidate repository cannot be opened and the request carries no propose_memory: this turn runs the lexical bar as fallback.
        try await withSuggestionState(memoryFallback: false) { state, conversation, _ in
            let mode = state.memoryProposeMode(
                conversation: try #require(state.conversation(for: conversation.id)),
                freshSend: true, useMemory: true, capabilitySelection: ChatCapabilitySelection()
            )
            #expect(mode == .tool)
            state.memoryCandidateRepositoryOverride = { nil }
            let outcome = await state.sendMessageOutcome(Self.directive, in: conversation.id)
            #expect(outcome == .sent(conversation.id))
            let pending = try #require(state.directiveSuggestions.pending(in: conversation.id))
            #expect(pending.messageID == lastUserMessageID(state, conversation.id))
        }
    }

    // The three channels whose requests cannot carry clientTools are judged as fallback at the mode decision stage (same rule as Android / Web).
    private static let gatedDirective = "\u{4EE5}\u{540E}\u{90FD}\u{7528}\u{4E2D}\u{6587}\u{56DE}\u{7B54}"

    @MainActor
    private func proposeMode(_ state: AppState, _ conversation: Conversation, _ selection: ChatCapabilitySelection) throws
        -> MemoryPropose.Mode {
        state.memoryProposeMode(
            conversation: try #require(state.conversation(for: conversation.id)),
            freshSend: true, useMemory: true, capabilitySelection: selection
        )
    }

    /// This turn goes through fallback: a sentence in a gated language shows the lexical bar, attached to this user message.
    @MainActor
    private func expectLexicalSuggestion(
        _ state: AppState, _ conversation: Conversation, _ selection: ChatCapabilitySelection
    ) async throws {
        #expect(DirectiveDetector.detect(Self.gatedDirective).lang == "zh-Hans")
        let outcome = await state.sendMessageOutcome(
            Self.gatedDirective, in: conversation.id, capabilitySelection: selection
        )
        #expect(outcome == .sent(conversation.id))
        let pending = try #require(state.directiveSuggestions.pending(in: conversation.id))
        #expect(pending.messageID == lastUserMessageID(state, conversation.id))
    }

    @Test("gemini_interactions_web_runs_fallback", .sharedProcessState)
    @MainActor
    func geminiInteractionsWebRunsFallback() async throws {
        let modelID = "gemini-3-flash"
        let provider = TestFactories.makeProvider(kind: .gemini, models: [TestFactories.makeModel(id: modelID)])
        // Control: with web off and the generateContent route, tools can be carried.
        await MetadataClient.shared.resetForTesting()
        try await withSuggestionState(memoryFallback: false, provider: provider, modelID: modelID) { state, conversation, _ in
            let mode = try proposeMode(state, conversation, ChatCapabilitySelection())
            #expect(mode == .tool)
        }
        try await Self.loadWebRouteMetadata(
            providerKind: "gemini", modelID: modelID, transport: "gemini_interactions",
            recipeRef: "gemini.interactions.web.v1"
        )
        // Precondition: the web route is picked by the production selection function (this turn goes through Interactions, and the request carries no clientTools).
        #expect(GeminiService.interactionsRecipe(modelID: modelID, webSearchEnabled: true, historyHasVideo: false) != nil)
        try await withSuggestionState(memoryFallback: false, provider: provider, modelID: modelID) { state, conversation, _ in
            let web = ChatCapabilitySelection(reasoningMode: .automatic, webSearchEnabled: true)
            let mode = try proposeMode(state, conversation, web)
            #expect(mode == .fallback)
            try await expectLexicalSuggestion(state, conversation, web)
        }
        await MetadataClient.shared.resetForTesting()
    }

    @Test("minimax_web_route_runs_fallback", .sharedProcessState)
    @MainActor
    func miniMaxWebRouteRunsFallback() async throws {
        let modelID = "MiniMax-M3"
        try await Self.loadWebRouteMetadata(
            providerKind: "miniMax", modelID: modelID, transport: "openai_chat", recipeRef: "minimax.messages.web.v1"
        )
        #expect(MiniMaxService.exactAnthropicWebRecipe(modelID: modelID, requested: true) != nil)
        let provider = TestFactories.makeProvider(kind: .miniMax, models: [TestFactories.makeModel(id: modelID)])
        try await withSuggestionState(memoryFallback: false, provider: provider, modelID: modelID) { state, conversation, _ in
            let mode12 = try proposeMode(state, conversation, ChatCapabilitySelection())
            #expect(mode12 == .tool)
            var web = ChatCapabilitySelection()
            web.typedPreferences = CapabilityPreferenceValues(web: .automatic)
            let mode2 = try proposeMode(state, conversation, web)
            #expect(mode2 == .fallback)
            try await expectLexicalSuggestion(state, conversation, web)
        }
        await MetadataClient.shared.resetForTesting()
    }

    @Test("llamacpp_native_runs_fallback", .sharedProcessState)
    @MainActor
    func llamaCppNativeRunsFallback() async throws {
        let modelID = "local-llama"
        func relay(_ transport: RelayTransport) -> Provider {
            Provider(
                id: UUID(), kind: .relay, status: .connected,
                models: [TestFactories.makeModel(id: modelID)], catalogModels: [],
                apiKey: "sk-test", apiKeyPreview: "...test", baseURLText: "https://relay.example.com",
                relayRequested: RelayRequestedConfig(transport: transport, authMode: .auto, securityMode: .remoteHTTPS)
            )
        }
        // Control: the same relay on Chat Completions can still carry tools.
        try await withSuggestionState(memoryFallback: false, provider: relay(.openaiChatCompletions), modelID: modelID) {
            state, conversation, _ in
            let mode13 = try proposeMode(state, conversation, ChatCapabilitySelection())
            #expect(mode13 == .tool)
        }
        try await withSuggestionState(memoryFallback: false, provider: relay(.llamacppNative), modelID: modelID) {
            state, conversation, _ in
            let mode14 = try proposeMode(state, conversation, ChatCapabilitySelection())
            #expect(mode14 == .fallback)
            try await expectLexicalSuggestion(state, conversation, ChatCapabilitySelection())
        }
    }

    /// Web route metadata: the recipe comes from the production registry (`CapabilityRuntimeFixtures`), not hand-copied in the test.
    private static func loadWebRouteMetadata(
        providerKind: String, modelID: String, transport: String, recipeRef: String
    ) async throws {
        let document: [String: Any] = [
            "version": 1,
            "capabilityRuntime": try CapabilityRuntimeFixtures.runtimeEnvelope(),
            "providers": [providerKind: [
                "resolveMap": [modelID: modelID],
                "models": [modelID: [
                    "canonicalModelId": modelID,
                    "transport": transport,
                    "capabilities": ["text", "web"],
                    "capabilityControls": CapabilityRuntimeFixtures.controls(
                        .init(capability: "web", recipeRef: recipeRef)
                    ),
                ]],
            ]],
        ]
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(
            json: String(decoding: try JSONSerialization.data(withJSONObject: document), as: UTF8.self)
        )
    }

    @Test("late_instruct_for_older_message_is_dropped", .sharedProcessState)
    @MainActor
    func lateInstructForOlderMessageIsDropped() async throws {
        // A's instruct arrives after B was sent: it is not attached to A; B's own instruct still shows the bar (control).
        try await withSuggestionState(memoryFallback: false) { state, conversation, _ in
            _ = await state.sendMessage(Self.directive, in: conversation.id)
            let first = try #require(lastUserMessageID(state, conversation.id))
            _ = await state.sendMessage("Thanks.", in: conversation.id)
            let second = try #require(lastUserMessageID(state, conversation.id))
            #expect(first != second)
            let context = try #require(
                state.proposeMemoryContext(text: Self.directive, conversationID: conversation.id, useMemory: true)
            )
            context.onInstruct(Self.directive, first)
            #expect(state.directiveSuggestions.pending(in: conversation.id) == nil)
            context.onInstruct(Self.directive, second)
            #expect(state.directiveSuggestions.pending(in: conversation.id)?.messageID == second)
        }
    }

    @Test("fallback_lexical_suggestion_only_for_gated_languages", .sharedProcessState)
    @MainActor
    func fallbackLexicalSuggestionOnlyForGatedLanguages() async throws {
        let english = "From now on, reply in English."
        #expect(DirectiveDetector.detect(english).lang == "en")
        #expect(!DirectiveDetector.suggestionLanguages.contains("en"))
        try await withSuggestionState { state, conversation, _ in
            _ = await state.sendMessage(english, in: conversation.id)
            #expect(state.directiveSuggestions.pending(in: conversation.id) == nil)

            for text in [Self.directive, "\u{3053}\u{308C}\u{304B}\u{3089}\u{306F}\u{6BCE}\u{56DE}\u{3001}\u{8981}\u{70B9}\u{3092}\u{4E09}\u{3064}\u{306B}\u{307E}\u{3068}\u{3081}\u{3066}\u{304B}\u{3089}\u{8AAC}\u{660E}\u{3057}\u{3066}\u{304F}\u{3060}\u{3055}\u{3044}\u{3002}"] {
                let lang = try #require(DirectiveDetector.detect(text).lang, "\(text)")
                #expect(DirectiveDetector.suggestionLanguages.contains(lang), "\(text)")
                _ = await state.sendMessage(text, in: conversation.id)
                let pending = try #require(state.directiveSuggestions.pending(in: conversation.id), "\(text)")
                #expect(pending.messageID == lastUserMessageID(state, conversation.id))
            }
        }
    }

    @Test("instruct_already_in_instructions_is_skipped", .sharedProcessState)
    @MainActor
    func instructAlreadyInInstructionsIsSkipped() {
        let suiteName = "directive-instruct-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = DirectiveSuggestionController(defaults: defaults)
        let conversationID = UUID()
        let messageID = UUID()
        controller.offerInstruct(
            sentence: "\u{56DE}\u{7B54}\u{90FD}\u{5148}\u{7ED9}\u{7ED3}\u{8BBA}", messageID: messageID, conversationID: conversationID,
            instructions: "\u{8BED}\u{6C14}\u{8F7B}\u{677E}\u{3002}\n\u{4EE5}\u{540E}\u{56DE}\u{7B54}\u{90FD}\u{5148}\u{7ED9}\u{7ED3}\u{8BBA}\u{FF0C}\u{518D}\u{5C55}\u{5F00}\u{7EC6}\u{8282}"
        )
        #expect(controller.pending(in: conversationID) == nil)
        controller.offerInstruct(
            sentence: "\u{4EE5}\u{540E}\u{56DE}\u{7B54}\u{90FD}\u{5148}\u{7ED9}\u{7ED3}\u{8BBA}", messageID: messageID, conversationID: conversationID,
            instructions: String(repeating: "\u{7532}", count: ConversationInstructions.maxCodePoints - 5)
        )
        #expect(controller.pending(in: conversationID) == nil)
        controller.offerInstruct(
            sentence: "\u{4EE5}\u{540E}\u{56DE}\u{7B54}\u{90FD}\u{5148}\u{7ED9}\u{7ED3}\u{8BBA}", messageID: messageID, conversationID: conversationID, instructions: ""
        )
        #expect(controller.pending(in: conversationID) == .init(messageID: messageID, sentence: "\u{4EE5}\u{540E}\u{56DE}\u{7B54}\u{90FD}\u{5148}\u{7ED9}\u{7ED3}\u{8BBA}"))
        // After 3 consecutive ignores the bar no longer appears.
        let other = UUID()
        defaults.set(3, forKey: DirectiveSuggestionController.ignoreKey(other))
        controller.offerInstruct(sentence: "\u{4EE5}\u{540E}\u{56DE}\u{7B54}\u{90FD}\u{5148}\u{7ED9}\u{7ED3}\u{8BBA}", messageID: UUID(), conversationID: other, instructions: "")
        #expect(controller.pending(in: other) == nil)
    }
}
