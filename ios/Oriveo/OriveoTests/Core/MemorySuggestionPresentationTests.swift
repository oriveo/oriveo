import Foundation
import OriveoProviderKit
import Testing
import SwiftUI
import UIKit
@testable import Oriveo

// A new send is routed by MemoryIntent.classify to the memory bar / the standing-instruction bar; with memory off only a hint is shown;
// the bar supports save (including undo) / edit / dismiss.
// A new send is routed by the propose_memory mode (in tool mode the v1 memory routing does not run, and the first propose candidate of the turn becomes the bar);
// the bar hangs on this turn's assistant message and appears after streaming ends, identically on both paths.
// Assertions come from the production path: AppState.sendMessage -> background candidate generation -> MemorySuggestionController; candidates / items are read from the repository's actual results.

/// Every request gets 503: only the user message needs to land, no real reply is needed.
private final class MemorySuggestionStubProtocol: URLProtocol, @unchecked Sendable {
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MemorySuggestionStubProtocol.self]
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

/// Whether the two colors resolve to the same RGBA under light / dark appearance (UIColor(Color) is created anew each time, so it cannot be compared with == directly).
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

@Suite("MemorySuggestionPresentation", .serialized, .sharedProcessState)
struct MemorySuggestionPresentationTests {
    /// The primary save button background uses the brand primary color with white text, not system blue (AccentColor is empty).
    @MainActor
    @Test("memory bar save button uses the brand primary color")
    func saveButtonUsesPrimary() throws {
        let bar = MemorySuggestionBarView()
        bar.apply(MemorySuggestionBar(messageID: UUID(), content: "Prefers metric units"))
        let config = try #require(bar.saveButtonConfigurationForTesting)
        #expect(sameResolvedColor(config.baseBackgroundColor, UIColor(OriveoTheme.Palette.primary)))
        #expect(sameResolvedColor(config.baseForegroundColor, .white))
    }

    // Sentences are read as `text` from the cases of shared/context-contracts/memory-intent.v1.json by case id.
    /// Explicit "remember ..." -> suggestion=memory.
    private static let remember = "zh_explicit_01_golden"
    /// Global directive -> suggestion=memory.
    private static let globalDirective = "zh_implicit_04_golden"
    /// Conversation-level directive -> suggestion=conversationInstruction (the lexical bar is gated by language; the zh sentence is used).
    private static let conversationDirective = "zh_implicit_03_golden"
    /// Contains a secret -> suggestion=none.
    private static let secretMessage = "mixed_sensitive_02"
    /// One-off request -> suggestion=none (used as the "next send").
    private static let transientMessage = "zh_transient_02_golden"

    private struct IntentFixture: Decodable {
        struct Case: Decodable {
            let id: String
            let text: String
        }

        let cases: [Case]
    }

    /// The text of a fixture case; walks up from #filePath to find the repository root.
    private static func text(_ caseID: String) throws -> String {
        var folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while folder.path != "/" {
            let url = folder.appendingPathComponent("shared/context-contracts/memory-intent.v1.json")
            if FileManager.default.fileExists(atPath: url.path) {
                let fixture = try JSONDecoder().decode(IntentFixture.self, from: Data(contentsOf: url))
                return try #require(fixture.cases.first { $0.id == caseID }?.text, "missing case \(caseID)")
            }
            folder.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    /// toolMode=false: records this connection + model in the in-process downgrade set and takes the fallback (v1 memory routing); true: a tool-capable connection takes the tool path.
    @MainActor
    private func withState(
        useMemory: Bool = true,
        toolMode: Bool = false,
        _ body: (AppState, Conversation) async throws -> Void
    ) async rethrows {
        let uid = "memory-suggestion-\(UUID().uuidString)"
        let suiteName = "memory-suggestion-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let state = AppState(seedDemoData: false, sessionUID: uid, providerSession: MemorySuggestionStubProtocol.session())
        state.directiveSuggestions = DirectiveSuggestionController(defaults: defaults)
        let provider = TestFactories.makeProvider()
        state.providers = [provider]
        if !toolMode {
            ProposeMemoryRuntime.shared.markDegraded(connectionID: provider.id, modelID: "gpt-4o")
        }
        var conversation = TestFactories.makeConversation(
            hasCustomTitle: true,
            providerID: provider.id,
            modelID: "gpt-4o",
            messages: [TestFactories.makeMessage()]
        )
        conversation.useMemory = useMemory
        state.upsertConversationProjection(conversation)
        defer {
            state.flushConversationPersistQueue()
            DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
            defaults.removePersistentDomain(forName: suiteName)
        }
        try await body(state, conversation)
    }

    /// Sends the sentence of a fixture case and waits for background candidate generation to finish.
    @MainActor
    private func send(_ caseID: String, _ state: AppState, _ conversationID: UUID) async throws {
        _ = await state.sendMessage(try Self.text(caseID), in: conversationID)
        await state.memoryCandidateGeneration?.value
    }

    @MainActor
    private func pendingCandidates(_ state: AppState) async throws -> [MemoryCandidate] {
        let repository = try #require(state.memoryCandidateRepository())
        return try await repository.pending(nowMs: Int64(Date().timeIntervalSince1970 * 1000))
    }

    /// This turn's assistant message: the suggestion bar hangs under it.
    @MainActor
    private func lastAssistantMessageID(_ state: AppState, _ conversationID: UUID) -> UUID? {
        state.conversation(for: conversationID)?.messages.last(where: { $0.role == .assistant })?.id
    }

    @Test("memory_bar_shown_after_candidate_generated")
    @MainActor
    func memoryBarShownAfterCandidateGenerated() async throws {
        try await withState { state, conversation in
            try await send(Self.remember, state, conversation.id)
            let candidate = try #require(try await pendingCandidates(state).first)
            let suggestion = try #require(state.memorySuggestions.pending(in: conversation.id))
            #expect(suggestion.messageID == lastAssistantMessageID(state, conversation.id))
            // The candidate's source.messageIds are still the user message ids.
            let userMessageID = state.conversation(for: conversation.id)?.messages.last(where: { $0.role == .user })?.id
            #expect(candidate.source.messageIds == [try #require(userMessageID).uuidString])
            #expect(suggestion.candidate == candidate)
            #expect(suggestion.bar == MemorySuggestionBar(messageID: suggestion.messageID, content: candidate.content))
            // At most one suggestion bar per conversation.
            #expect(state.directiveSuggestions.pending(in: conversation.id) == nil)

            // Projection: after the answer ends it hangs only on this turn's assistant message (the 503 response is asynchronous to this assertion, so it is projected in the finished state; see the streaming-state case below).
            var messages = try #require(state.conversation(for: conversation.id)).messages
            for index in messages.indices where messages[index].state == .generating {
                messages[index].state = .failed
            }
            let rows = ChatCollectionProjectionBuilder.makeRows(
                from: messages,
                metadata: .empty,
                memorySuggestion: suggestion.bar
            )
            #expect(rows.filter { $0.memorySuggestion != nil }.map(\.message.id) == [suggestion.messageID])
        }
    }

    @Test("global_directive_routes_to_memory_bar")
    @MainActor
    func globalDirectiveRoutesToMemoryBar() async throws {
        try await withState { state, conversation in
            try await send(Self.globalDirective, state, conversation.id)
            let candidate = try #require(try await pendingCandidates(state).first)
            #expect(state.memorySuggestions.pending(in: conversation.id)?.candidate?.id == candidate.id)
            #expect(state.directiveSuggestions.pending(in: conversation.id) == nil)
        }
    }

    @Test("conversation_directive_keeps_instruction_bar")
    @MainActor
    func conversationDirectiveKeepsInstructionBar() async throws {
        try await withState { state, conversation in
            try await send(Self.conversationDirective, state, conversation.id)
            let pending = try #require(state.directiveSuggestions.pending(in: conversation.id))
            #expect(pending.sentence == DirectiveDetector.detect(try Self.text(Self.conversationDirective)).span)
            #expect(state.memorySuggestions.pending(in: conversation.id) == nil)
            let candidates = try await pendingCandidates(state)
            #expect(candidates.isEmpty)
        }
    }

    @Test("secret_message_shows_no_bar")
    @MainActor
    func secretMessageShowsNoBar() async throws {
        try await withState { state, conversation in
            try await send(Self.secretMessage, state, conversation.id)
            #expect(state.memorySuggestions.pending(in: conversation.id) == nil)
            #expect(state.directiveSuggestions.pending(in: conversation.id) == nil)
            let candidates = try await pendingCandidates(state)
            #expect(candidates.isEmpty)
        }
    }

    @Test("memory_off_shows_hint_without_candidate")
    @MainActor
    func memoryOffShowsHintWithoutCandidate() async throws {
        try await withState(useMemory: false) { state, conversation in
            try await send(Self.globalDirective, state, conversation.id)
            let suggestion = try #require(state.memorySuggestions.pending(in: conversation.id))
            #expect(suggestion.messageID == lastAssistantMessageID(state, conversation.id))
            #expect(suggestion.candidate == nil)
            #expect(suggestion.bar.content == nil)
            #expect(state.directiveSuggestions.pending(in: conversation.id) == nil)
            let candidates = try await pendingCandidates(state)
            #expect(candidates.isEmpty)

            // A sentence that is not memory shows no hint even when memory is off.
            try await send(Self.conversationDirective, state, conversation.id)
            #expect(state.memorySuggestions.pending(in: conversation.id) == nil)
        }
    }

    @Test("next_send_clears_bar_keeps_pending")
    @MainActor
    func nextSendClearsBarKeepsPending() async throws {
        try await withState { state, conversation in
            try await send(Self.remember, state, conversation.id)
            let candidate = try #require(state.memorySuggestions.pending(in: conversation.id)?.candidate)

            try await send(Self.transientMessage, state, conversation.id)
            #expect(state.memorySuggestions.pending(in: conversation.id) == nil)
            let candidates = try await pendingCandidates(state)
            #expect(candidates.map(\.id) == [candidate.id])

            // Switching conversations clears it too, while the candidate remains.
            try await send(Self.globalDirective, state, conversation.id)
            #expect(state.memorySuggestions.pending(in: conversation.id) != nil)
            state.openChat(conversationID: UUID())
            #expect(state.memorySuggestions.pending(in: conversation.id) == nil)
            let afterSwitch = try await pendingCandidates(state)
            #expect(afterSwitch.count == 2)
        }
    }

    @Test("no_candidate_becomes_active_without_accept")
    @MainActor
    func noCandidateBecomesActiveWithoutAccept() async throws {
        try await withState { state, conversation in
            try await send(Self.remember, state, conversation.id)
            #expect(state.memorySuggestions.pending(in: conversation.id) != nil)
            let items = try #require(state.memoryItemRepository())
            #expect(items.list().isEmpty)
        }
    }

    @Test("save_creates_item_and_undo_deletes_it")
    @MainActor
    func saveCreatesItemAndUndoDeletesIt() async throws {
        try await withState { state, conversation in
            try await send(Self.remember, state, conversation.id)
            let candidate = try #require(state.memorySuggestions.pending(in: conversation.id)?.candidate)

            // Go through the entry point the UI actually calls: save -> "saved to memory" toast + 5 s undo.
            await state.memorySuggestions.saveWithUndoToast(conversationID: conversation.id, appState: state).value
            #expect(state.memorySuggestions.pending(in: conversation.id) == nil)
            let items = try #require(state.memoryItemRepository())
            let item = try #require(items.list().first)
            #expect(items.list().count == 1)
            #expect(item.content == candidate.content)
            #expect(item.kind == candidate.proposedKind)
            #expect(item.status == .active)
            #expect(item.source.type == .conversation)
            #expect(item.source.conversationId?.lowercased() == conversation.id.uuidString.lowercased())
            #expect(item.scope == candidate.scope)
            #expect(item.confidence == candidate.confidence)
            let candidates = try await pendingCandidates(state)
            #expect(candidates.isEmpty)

            let toast = try #require(ToastManager.shared.current)
            #expect(toast.message == L10n.tr("memory_suggestion_saved", table: .chat))
            #expect(toast.actionTitle == L10n.tr("Undo", table: .notes))
            #expect(ToastManager.shared.currentDuration == 5)

            // Undo = the item repository deletes the just-created item normally.
            ToastManager.shared.performCurrentAction()
            #expect(items.list().isEmpty)
            #expect(items.allItems().first { $0.id == item.id }?.status == .deleted)
        }
    }

    @Test("edit_saves_edited_content")
    @MainActor
    func editSavesEditedContent() async throws {
        try await withState { state, conversation in
            try await send(Self.globalDirective, state, conversation.id)
            let candidate = try #require(state.memorySuggestions.pending(in: conversation.id)?.candidate)

            // New state prefills the candidate body, grouped by proposedKind (unmappable kinds preselect "About me").
            let target = try #require(state.memorySuggestions.edit(conversationID: conversation.id))
            #expect(target.candidate == candidate)
            var editor = target.state
            #expect(editor.isNew)
            #expect(editor.text == candidate.content)
            #expect(editor.category == (MemoryItemGroup(kind: candidate.proposedKind) ?? .about))

            editor.text = "  \u{6240}\u{6709}\u{5BF9}\u{8BDD}\u{90FD}\u{7528}\u{7B80}\u{4F53}\u{4E2D}\u{6587}\u{56DE}\u{590D}  "
            let saved = try #require(
                await state.memorySuggestions.saveEdited(editor, for: target, appState: state)
            )
            #expect(state.memorySuggestions.pending(in: conversation.id) == nil)
            let items = try #require(state.memoryItemRepository())
            let item = try #require(items.list().first { $0.id == saved.id })
            #expect(item.content == "\u{6240}\u{6709}\u{5BF9}\u{8BDD}\u{90FD}\u{7528}\u{7B80}\u{4F53}\u{4E2D}\u{6587}\u{56DE}\u{590D}")
            // Group unchanged: no kind is given, proposedKind is kept; scope unchanged; editing the body sets confidence = 1.0.
            #expect(item.kind == candidate.proposedKind)
            #expect(item.scope == candidate.scope)
            #expect(item.source.type == .conversation)
            #expect(item.confidence == 1.0)
            let candidates = try await pendingCandidates(state)
            #expect(candidates.isEmpty)

            // Kind is sent only when the group was changed.
            try await send(Self.remember, state, conversation.id)
            let regroupTarget = try #require(state.memorySuggestions.edit(conversationID: conversation.id))
            var regrouped = regroupTarget.state
            regrouped.category = regrouped.category == .projects ? .about : .projects
            let regroupedItem = try #require(
                await state.memorySuggestions.saveEdited(regrouped, for: regroupTarget, appState: state)
            )
            #expect(regroupedItem.kind == regrouped.kind)
        }
    }

    @Test("ignore_rejects_candidate")
    @MainActor
    func ignoreRejectsCandidate() async throws {
        try await withState { state, conversation in
            try await send(Self.remember, state, conversation.id)
            let candidate = try #require(state.memorySuggestions.pending(in: conversation.id)?.candidate)

            await state.memorySuggestions.ignore(conversationID: conversation.id, appState: state)
            #expect(state.memorySuggestions.pending(in: conversation.id) == nil)
            let candidates = try await pendingCandidates(state)
            #expect(candidates.isEmpty)
            let repository = try #require(state.memoryCandidateRepository())
            let stored = try repository.store.all().first { $0.id == candidate.id }
            #expect(stored?.status == .rejected)
            let items = try #require(state.memoryItemRepository())
            #expect(items.list().isEmpty)
        }
    }

    @Test("edit_save_after_bar_cleared_still_accepts")
    @MainActor
    func editSaveAfterBarClearedStillAccepts() async throws {
        try await withState { state, conversation in
            try await send(Self.remember, state, conversation.id)
            let target = try #require(state.memorySuggestions.edit(conversationID: conversation.id))

            // A new send while the editor is open cleared the bar; the candidate is still pending.
            try await send(Self.transientMessage, state, conversation.id)
            #expect(state.memorySuggestions.pending(in: conversation.id) == nil)

            var editor = target.state
            editor.text = "\u{504F}\u{597D}\u{7B80}\u{6D01}\u{7684}\u{56DE}\u{7B54}"
            let saved = try #require(await state.memorySuggestions.saveEdited(editor, for: target, appState: state))
            let items = try #require(state.memoryItemRepository())
            #expect(items.list().map(\.id) == [saved.id])
            #expect(items.list().first?.content == "\u{504F}\u{597D}\u{7B80}\u{6D01}\u{7684}\u{56DE}\u{7B54}")
            #expect(items.list().first?.confidence == 1.0)
            let candidates = try await pendingCandidates(state)
            #expect(candidates.isEmpty)

            // The candidate is no longer pending: saving again fails and shows the "couldn't save to memory" alert.
            let again = await state.memorySuggestions.saveEdited(editor, for: target, appState: state)
            #expect(again == nil)
            #expect(ToastManager.shared.current?.message == L10n.tr("memory_suggestion_failed", table: .chat))
            #expect(items.list().count == 1)
        }
    }

    @Test("bar_hidden_while_streaming_shown_after_answer")
    @MainActor
    func barHiddenWhileStreamingShownAfterAnswer() async throws {
        try await withState { state, conversation in
            try await send(Self.remember, state, conversation.id)
            let suggestion = try #require(state.memorySuggestions.pending(in: conversation.id))
            let messages = try #require(state.conversation(for: conversation.id)).messages
            let assistantIndex = try #require(messages.lastIndex { $0.id == suggestion.messageID })
            #expect(messages[assistantIndex].role == .assistant)

            // Streaming: no bar is shown.
            var streaming = messages
            streaming[assistantIndex].state = .generating
            let streamingRows = ChatCollectionProjectionBuilder.makeRows(
                from: streaming, metadata: .empty, memorySuggestion: suggestion.bar
            )
            #expect(streamingRows.allSatisfy { $0.memorySuggestion == nil })

            // After the answer ends: the bar hangs on the assistant message, with the same id.
            var finished = messages
            finished[assistantIndex].state = .delivered
            let finishedRows = ChatCollectionProjectionBuilder.makeRows(
                from: finished, metadata: .empty, memorySuggestion: suggestion.bar
            )
            #expect(finishedRows.filter { $0.memorySuggestion != nil }.map(\.message.id) == [suggestion.messageID])
        }
    }

    @Test("tool_mode_skips_v1_memory_routing")
    @MainActor
    func toolModeSkipsV1MemoryRouting() async throws {
        try await withState(toolMode: true) { state, conversation in
            try await send(Self.remember, state, conversation.id)
            #expect(state.memorySuggestions.pending(in: conversation.id) == nil)
            let candidates = try await pendingCandidates(state)
            #expect(candidates.isEmpty)

            // The lexical standing-instruction bar does not run either: it only comes from the model's instruct.
            try await send(Self.conversationDirective, state, conversation.id)
            #expect(state.directiveSuggestions.pending(in: conversation.id) == nil)
        }
    }

    @Test("The suggestion bar hangs below the assistant answer")
    @MainActor
    func firstProposedCandidateBecomesBar() async throws {
        try await withState(toolMode: true) { state, conversation in
            let text = try Self.text(Self.remember)
            try await send(Self.remember, state, conversation.id)
            let assistantID = try #require(lastAssistantMessageID(state, conversation.id))
            let userID = try #require(
                state.conversation(for: conversation.id)?.messages.last(where: { $0.role == .user })?.id
            )
            let repository = try #require(state.memoryCandidateRepository())
            var created: [MemoryCandidate] = []
            for (index, proposition) in ["\u{504F}\u{597D}\u{7B80}\u{6D01}\u{7684}\u{56DE}\u{7B54}", "\u{5E38}\u{7528} Swift \u{5199}\u{4EE3}\u{7801}"].enumerated() {
                let arguments = String(
                    decoding: try JSONSerialization.data(withJSONObject: [
                        "proposition": proposition, "sourceQuote": text, "kind": "preference", "scope": "global",
                    ]),
                    as: UTF8.self
                )
                let candidate = try #require(try await repository.propose(
                    argumentsJSON: arguments,
                    priorInTurn: index,
                    userText: text,
                    messageId: userID.uuidString,
                    conversationId: conversation.id.uuidString,
                    folderId: nil,
                    nowMs: Int64(Date().timeIntervalSince1970 * 1000)
                ).candidate)
                created.append(candidate)
                state.memorySuggestions.presentProposed(candidate, messageID: assistantID, conversationID: conversation.id)
            }

            let suggestion = try #require(state.memorySuggestions.pending(in: conversation.id))
            #expect(suggestion.messageID == assistantID)
            #expect(suggestion.candidate == created.first)
            #expect(created.first?.source.messageIds == [userID.uuidString])
            let pending = try await pendingCandidates(state)
            #expect(Set(pending.map(\.id)) == Set(created.map(\.id)))
        }
    }
}
