import Combine
import Foundation
import OriveoProviderKit
import Testing
@testable import Oriveo

/// Counts the requests the send chain sends out; the response is the shortest successful stream.
private final class GateURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        let url = request.url ?? URL(string: "https://gate.invalid")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("data: [DONE]\n\n".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GateURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

/// grok-4.7: 2M window, price line T = 4000 (below priceLineCapMin, so the auto tier is not capped and B stays the auto default).
private enum GateFixture {
    static let modelID = "grok-4.7"
    static let window = 2_000_000
    static let priceLine = 4_000

    static func installMetadata() async throws {
        let json = """
        {
          "version": 1,
          "updatedAt": "2026-10-15T00:00:00Z",
          "providers": {
            "grok": {
              "displayName": "grok",
              "defaultModelId": "\(modelID)",
              "resolveMap": { "\(modelID)": "\(modelID)" },
              "models": { "\(modelID)": {
                "canonicalModelId": "\(modelID)",
                "displayName": "Grok 4.7",
                "contextLength": \(window),
                "pricing": {
                  "promptPerMToken": 2,
                  "completionPerMToken": 6,
                  "longContext": {"thresholdTokens": \(priceLine), "promptPerMToken": 4, "completionPerMToken": 12}
                },
                "capabilities": ["text"],
                "profiles": {}
              } }
            }
          }
        }
        """
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: json)
    }

    static func provider() -> Provider {
        var model = TestFactories.makeModel(id: modelID, name: "Grok 4.7", capabilities: [.text], isDefault: true)
        model.contextLength = window
        return Provider(
            id: UUID(),
            kind: .grok,
            status: .connected,
            models: [model],
            catalogModels: [],
            apiKey: "grok-key",
            apiKeyPreview: "...key",
            baseURLText: nil
        )
    }

    /// A body far beyond T; each `words` group is about 15 bytes.
    static func longText(words: Int) -> String {
        String(repeating: "context window ", count: words)
    }

    static func makeState(
        messages: (Provider) -> [ChatMessage] = { _ in [] },
        prepare: (inout Conversation) -> Void = { _ in }
    ) -> (AppState, Conversation) {
        let provider = provider()
        let state = AppState(
            seedDemoData: false,
            sessionUID: "context-cap-gate-\(UUID().uuidString)",
            providerSession: GateURLProtocol.session()
        )
        var conversation = TestFactories.makeConversation(
            providerID: provider.id,
            providerKind: provider.kind,
            modelID: modelID,
            messages: messages(provider)
        )
        prepare(&conversation)
        state.providers = [provider]
        state.preferences.contextDefaultCap = .auto
        state.upsertConversationProjection(conversation)
        GateURLProtocol.requestCount = 0
        return (state, conversation)
    }
}

/// Pre-send confirmation sits after compaction and before the request goes out; cancel rolls back, confirm sends exactly once.
extension ContextCapConfirmPresentationTests {

    private func waitFor(_ condition: () -> Bool, seconds: Int = 5) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    private func pendingGate(_ state: AppState, _ conversationID: UUID) async throws -> PendingContextCapConfirmation {
        _ = await waitFor { state.contextCapConfirmCoordinator.pending(for: conversationID) != nil }
        return try #require(
            state.contextCapConfirmCoordinator.pending(for: conversationID),
            "send did not stop at the confirmation gate"
        )
    }

    /// The user message of the turn held at the gate: right before the assistant placeholder.
    private func heldUserMessageID(_ state: AppState, _ pending: PendingContextCapConfirmation) throws -> UUID {
        let messages = try #require(state.conversation(for: pending.conversationID)).messages
        let index = try #require(messages.firstIndex { $0.id == pending.messageID })
        let user = try #require(index > 0 ? messages[index - 1] : nil)
        #expect(user.role == .user)
        #expect(messages[index].state == .generating)
        return user.id
    }

    /// Turns off AI summaries (compaction sends nothing out) and restores the preferences and local confirmation state at the end.
    private func withGateEnvironment(_ body: () async throws -> Void) async throws {
        let previousSummary = AppPreferencesStore.savedContextAISummaryEnabled
        AppPreferencesStore.savedContextAISummaryEnabled = false
        defer { AppPreferencesStore.savedContextAISummaryEnabled = previousSummary }
        try await GateFixture.installMetadata()
        try await body()
        await MetadataClient.shared.resetForTesting()
    }

    @Test func gate_over_cap_cancel_rolls_back() async throws {
        try await withGateEnvironment {
            let (state, conversation) = GateFixture.makeState(prepare: { $0.contextCap = .custom(32_000) })
            var rollbacks: [ContextCapSendRollback] = []
            let subscription = state.chatManager.contextCapRollbacks.sink { rollbacks.append($0) }
            defer { subscription.cancel() }

            let text = GateFixture.longText(words: 16_000)
            _ = await state.sendMessage(text, in: conversation.id)
            let pending = try await pendingGate(state, conversation.id)
            let userMessageID = try heldUserMessageID(state, pending)
            #expect(pending.prompt.decision.kind == .overCap || pending.prompt.decision.kind == .overCapAndPriceLine)
            #expect(GateURLProtocol.requestCount == 0)

            state.resolveContextCapConfirmation(id: pending.id, choice: .cancel)
            #expect(await waitFor { !rollbacks.isEmpty })
            try? await Task.sleep(nanoseconds: 300_000_000)

            #expect(GateURLProtocol.requestCount == 0)
            let messages = try #require(state.conversation(for: conversation.id)).messages
            #expect(!messages.contains { $0.id == userMessageID || $0.id == pending.messageID })
            #expect(state.chatManager.streamingMessageID(in: conversation.id) == nil)
            #expect(state.contextCapConfirmCoordinator.pending(for: conversation.id) == nil)
            #expect(rollbacks.count == 1)
            #expect(rollbacks.first?.conversationID == conversation.id)
            #expect(rollbacks.first?.text == text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    @Test func gate_over_cap_confirm_sends_once() async throws {
        try await withGateEnvironment {
            let (state, conversation) = GateFixture.makeState(prepare: { $0.contextCap = .custom(32_000) })
            defer { UserDefaults.standard.removeObject(forKey: ContextPriceLineConfirmStore.key(conversation.id)) }

            _ = await state.sendMessage(GateFixture.longText(words: 16_000), in: conversation.id)
            let pending = try await pendingGate(state, conversation.id)
            let userMessageID = try heldUserMessageID(state, pending)
            #expect(GateURLProtocol.requestCount == 0)

            state.resolveContextCapConfirmation(id: pending.id, choice: .send(dontAsk: false))
            #expect(await waitFor { GateURLProtocol.requestCount >= 1 })
            #expect(await waitFor { state.chatManager.streamingMessageID(in: conversation.id) == nil })
            try? await Task.sleep(nanoseconds: 300_000_000)

            #expect(GateURLProtocol.requestCount == 1)
            let messages = try #require(state.conversation(for: conversation.id)).messages
            #expect(messages.contains { $0.id == userMessageID })
            #expect(messages.contains { $0.id == pending.messageID })
        }
    }

    @Test func gate_price_line_asks_once_per_conversation() async throws {
        try await withGateEnvironment {
            let (state, conversation) = GateFixture.makeState()
            defer { UserDefaults.standard.removeObject(forKey: ContextPriceLineConfirmStore.key(conversation.id)) }

            _ = await state.sendMessage(GateFixture.longText(words: 2_000), in: conversation.id)
            let pending = try await pendingGate(state, conversation.id)
            #expect(pending.prompt.decision.kind == .priceLine)
            #expect(pending.prompt.input.model == GateFixture.modelID)
            #expect(pending.prompt.input.priceLineTokens == GateFixture.priceLine)

            state.resolveContextCapConfirmation(id: pending.id, choice: .send(dontAsk: false))
            #expect(await waitFor { GateURLProtocol.requestCount == 1 })
            #expect(await waitFor { state.chatManager.streamingMessageID(in: conversation.id) == nil })
            #expect(
                ContextPriceLineConfirmStore().state(for: conversation.id).acknowledged
                    == .init(model: GateFixture.modelID, T: GateFixture.priceLine)
            )

            // Second time over the line in the same conversation with the same model: history is already past T, so no more asking.
            _ = await state.sendMessage("Again", in: conversation.id)
            #expect(await waitFor { GateURLProtocol.requestCount == 2 })
            #expect(state.contextCapConfirmCoordinator.pending(for: conversation.id) == nil)
        }
    }

    @Test func gate_regenerate_skips_confirm() async throws {
        try await withGateEnvironment {
            let assistantID = UUID()
            let (state, conversation) = GateFixture.makeState(messages: { provider in
                [
                    TestFactories.makeMessage(
                        role: .user, text: GateFixture.longText(words: 2_000),
                        providerID: provider.id, providerKind: .grok, modelID: GateFixture.modelID
                    ),
                    TestFactories.makeMessage(
                        id: assistantID, role: .assistant, text: "Answer",
                        providerID: provider.id, providerKind: .grok, modelID: GateFixture.modelID
                    ),
                ]
            })
            defer { UserDefaults.standard.removeObject(forKey: ContextPriceLineConfirmStore.key(conversation.id)) }

            await state.chatManager.regenerateMessage(messageID: assistantID, in: conversation.id)
            #expect(await waitFor { GateURLProtocol.requestCount == 1 })
            #expect(state.contextCapConfirmCoordinator.pending(for: conversation.id) == nil)
        }
    }

    @Test func gate_reminder_off_skips_price_line() async throws {
        try await withGateEnvironment {
            let (state, conversation) = GateFixture.makeState()
            defer {
                state.preferences.contextPriceLineReminderEnabled = true
                UserDefaults.standard.removeObject(forKey: ContextPriceLineConfirmStore.key(conversation.id))
            }
            state.preferences.contextPriceLineReminderEnabled = false

            _ = await state.sendMessage(GateFixture.longText(words: 2_000), in: conversation.id)
            #expect(await waitFor { GateURLProtocol.requestCount == 1 })
            #expect(state.contextCapConfirmCoordinator.pending(for: conversation.id) == nil)
        }
    }

    // MARK: B2

    /// After cancel, the composer is restored only when both its text and attachments are empty; otherwise the payload is discarded. The restore payload comes from the production rollback event.
    @Test func composer_restored_after_cancel_only_when_empty() async throws {
        try await withGateEnvironment {
            let (state, conversation) = GateFixture.makeState(prepare: { $0.contextCap = .custom(32_000) })
            var rollbacks: [ContextCapSendRollback] = []
            let subscription = state.chatManager.contextCapRollbacks.sink { rollbacks.append($0) }
            defer { subscription.cancel() }

            let text = GateFixture.longText(words: 16_000)
            _ = await state.sendMessage(text, in: conversation.id)
            let pending = try await pendingGate(state, conversation.id)
            state.resolveContextCapConfirmation(id: pending.id, choice: .cancel)
            #expect(await waitFor { !rollbacks.isEmpty })
            let rollback = try #require(rollbacks.first)

            // Composer empty (including whitespace only): restore everything
            let restored = try #require(ContextCapComposerRestore.restoration(
                for: rollback, composerText: "", composerAttachments: []
            ))
            #expect(restored.conversationID == conversation.id)
            #expect(restored.text == text.trimmingCharacters(in: .whitespacesAndNewlines))
            #expect(restored.attachments.isEmpty)
            #expect(restored.quoteContext == nil)
            #expect(ContextCapComposerRestore.restoration(
                for: rollback, composerText: " \n", composerAttachments: []
            )?.text == restored.text)

            // The user has typed text or added an attachment: discard, do not overwrite
            #expect(ContextCapComposerRestore.restoration(
                for: rollback, composerText: "typed meanwhile", composerAttachments: []
            ) == nil)
            let attachment = Oriveo.Attachment(
                id: UUID(), kind: .image, fileName: "p.png", mimeType: "image/png", base64Data: "aGk="
            )
            #expect(ContextCapComposerRestore.restoration(
                for: rollback, composerText: "", composerAttachments: [attachment]
            ) == nil)
        }
    }

    /// Tapping stop while the gate is held = cancel: no chat request, the message pair rolls back, nothing is persisted as interrupted;
    /// the "Set as instruction" and "Save as memory?" suggestions raised by this send are withdrawn together.
    @Test func gate_stop_while_waiting_rolls_back() async throws {
        try await withGateEnvironment {
            let (state, conversation) = GateFixture.makeState(prepare: { $0.contextCap = .custom(32_000) })
            var rollbacks: [ContextCapSendRollback] = []
            let subscription = state.chatManager.contextCapRollbacks.sink { rollbacks.append($0) }
            defer { subscription.cancel() }

            let text = GateFixture.longText(words: 16_000)
            _ = await state.sendMessage(text, in: conversation.id)
            let pending = try await pendingGate(state, conversation.id)
            let userMessageID = try heldUserMessageID(state, pending)

            // The two kinds of suggestion bars raised by this send (attached to this user message)
            state.directiveSuggestions.evaluate(
                text: "\u{4EE5}\u{540E}\u{6BCF}\u{6B21}\u{56DE}\u{7B54}\u{90FD}\u{5148}\u{7ED9}\u{7ED3}\u{8BBA}",
                messageID: userMessageID,
                conversationID: conversation.id,
                instructions: "",
                suggestion: .conversationInstruction
            )
            #expect(state.directiveSuggestions.pending(in: conversation.id)?.messageID == userMessageID)
            let ignoresBefore = state.directiveSuggestions.ignoreCount(in: conversation.id)
            // The memory bar is attached to this turn's assistant message, so withdrawing it follows the assistant message.
            let assistantMessageID = try #require(
                state.conversation(for: conversation.id)?.messages.last(where: { $0.role == .assistant })?.id
            )
            state.memorySuggestions.showMemoryOffHint(messageID: assistantMessageID, conversationID: conversation.id)
            #expect(state.memorySuggestions.pending(in: conversation.id)?.messageID == assistantMessageID)

            state.chatManager.cancelGeneration(in: conversation.id)
            #expect(await waitFor { !rollbacks.isEmpty })
            try? await Task.sleep(nanoseconds: 300_000_000)

            #expect(GateURLProtocol.requestCount == 0)
            let messages = try #require(state.conversation(for: conversation.id)).messages
            #expect(!messages.contains { $0.id == userMessageID || $0.id == pending.messageID })
            #expect(!messages.contains { $0.state == .interrupted })
            #expect(state.chatManager.streamingMessageID(in: conversation.id) == nil)
            #expect(state.contextCapConfirmCoordinator.pending(for: conversation.id) == nil)
            #expect(rollbacks.count == 1)
            #expect(rollbacks.first?.text == text.trimmingCharacters(in: .whitespacesAndNewlines))

            #expect(state.directiveSuggestions.pending(in: conversation.id) == nil)
            #expect(state.directiveSuggestions.ignoreCount(in: conversation.id) == ignoresBefore)
            #expect(state.memorySuggestions.pending(in: conversation.id) == nil)
        }
    }

    /// When the conversation is removed (here via the passive interruption on background expiry, which also goes through removeSession), the pending cap confirmation is cancelled too,
    /// so no confirmation dialog is left pointing at a removed session.
    @Test func remove_session_cancels_pending_confirm() async throws {
        try await withGateEnvironment {
            let (state, conversation) = GateFixture.makeState(prepare: { $0.contextCap = .custom(32_000) })
            _ = await state.sendMessage(GateFixture.longText(words: 16_000), in: conversation.id)
            let pending = try await pendingGate(state, conversation.id)
            #expect(state.contextCapConfirmCoordinator.pending(for: conversation.id)?.id == pending.id)

            state.chatManager.debugTriggerGracefulInterruptForTesting()

            #expect(state.contextCapConfirmCoordinator.pending(for: conversation.id) == nil)
            #expect(state.chatManager.streamingMessageID(in: conversation.id) == nil)
            try? await Task.sleep(nanoseconds: 300_000_000)
            #expect(GateURLProtocol.requestCount == 0)
        }
    }
}
