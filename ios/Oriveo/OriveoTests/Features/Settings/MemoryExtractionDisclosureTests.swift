import Foundation
import OriveoProviderKit
import Testing
@testable import Oriveo

/// Disclosure before "AI draft" runs (the drafting part of the contract). Model requests use a stand-in; no real provider is called.
@Suite("MemoryExtractionDisclosure", .serialized)
@MainActor
struct MemoryExtractionDisclosureTests {

    /// Records the requests the stand-in received.
    @MainActor
    private final class SendRecorder {
        var calls: [(providerID: UUID, modelId: String, request: PlannedChatRequest)] = []
    }

    private static func candidate(
        _ modelID: String,
        modelName: String? = nil,
        kind: ProviderKind = .openAI,
        customName: String? = nil
    ) -> MemoryExtractionFlow.Candidate {
        let model = TestFactories.makeModel(id: modelID, name: modelName ?? modelID, isDefault: true)
        return (TestFactories.makeProvider(kind: kind, models: [model], customName: customName), model)
    }

    private static func flow(
        _ recorder: SendRecorder,
        reply: @escaping @MainActor (AIModel) throws -> String = { _ in "I am a novelist." }
    ) -> MemoryExtractionFlow {
        MemoryExtractionFlow { provider, model, request in
            recorder.calls.append((provider.id, model.id, request))
            return try reply(model)
        }
    }

    private static func conversation(_ messages: [ChatMessage], updatedAt: TimeInterval) -> Conversation {
        TestFactories.makeConversation(messages: messages, updatedAt: Date(timeIntervalSince1970: updatedAt))
    }

    private static func userMessage(_ text: String, providerID: UUID?) -> ChatMessage {
        TestFactories.makeMessage(role: .user, text: text, providerID: providerID)
    }

    @Test("draft_disclosure_shows_provider_model_and_scope")
    func draft_disclosure_shows_provider_model_and_scope() throws {
        let recorder = SendRecorder()
        let chosen = Self.candidate("deepseek/deepseek-v4", modelName: "DeepSeek: DeepSeek V4 (free)", kind: .openRouter)
        let flow = Self.flow(recorder)
        let conversations = [Self.conversation([Self.userMessage("I write novels", providerID: chosen.provider.id)], updatedAt: 1)]

        #expect(flow.prepareDraft(conversations: conversations, candidates: [chosen]) == .awaitingConfirmation)

        let disclosure = try #require(flow.disclosure)
        #expect(disclosure.title == L10n.tr("memory_extraction_title_draft", table: .chat))
        let lines = disclosure.message.components(separatedBy: "\n")
        #expect(lines == [
            String(format: L10n.tr("memory_extraction_model", table: .chat), "OpenRouter", "DeepSeek V4"),
            L10n.tr("memory_extraction_scope_draft", table: .chat),
            L10n.tr("memory_extraction_no_fallback", table: .chat),
        ])
        #expect(chosen.provider.displayName == "OpenRouter")
        for key in ["memory_extraction_title_draft", "memory_extraction_model", "memory_extraction_scope_draft",
                    "memory_extraction_no_fallback", "memory_extraction_send"] {
            #expect(L10n.tr(key, table: .chat) != key)
        }
        #expect(recorder.calls.isEmpty)
    }

    @Test("draft_sends_nothing_until_confirmed")
    func draft_sends_nothing_until_confirmed() async {
        let recorder = SendRecorder()
        let chosen = Self.candidate("first")
        let flow = Self.flow(recorder)
        let conversations = [Self.conversation([Self.userMessage("I write novels", providerID: chosen.provider.id)], updatedAt: 1)]

        #expect(flow.prepareDraft(conversations: conversations, candidates: [chosen]) == .awaitingConfirmation)
        #expect(recorder.calls.isEmpty)

        let outcome = await flow.confirm()

        #expect(outcome == .draft("I am a novelist."))
        #expect(recorder.calls.map(\.modelId) == ["first"])
        #expect(flow.disclosure == nil)
        // A confirmed request is not sent a second time
        #expect(await flow.confirm() == nil)
        #expect(recorder.calls.count == 1)
    }

    @Test("draft_cancel_sends_nothing")
    func draft_cancel_sends_nothing() async {
        let recorder = SendRecorder()
        let chosen = Self.candidate("first")
        let flow = Self.flow(recorder)
        let conversations = [Self.conversation([Self.userMessage("I write novels", providerID: chosen.provider.id)], updatedAt: 1)]

        #expect(flow.prepareDraft(conversations: conversations, candidates: [chosen]) == .awaitingConfirmation)
        flow.cancel()

        #expect(flow.disclosure == nil)
        #expect(await flow.confirm() == nil)
        #expect(recorder.calls.isEmpty)
    }

    @Test("draft_sends_only_user_messages_of_chosen_provider")
    func draft_sends_only_user_messages_of_chosen_provider() async throws {
        let recorder = SendRecorder()
        let chosen = Self.candidate("first")
        let other = Self.candidate("second")
        let flow = Self.flow(recorder)
        let mixed = Self.conversation([
            Self.userMessage("I write historical novels", providerID: chosen.provider.id),
            TestFactories.makeMessage(role: .assistant, text: "ASSISTANT-REPLY", providerID: chosen.provider.id),
            Self.userMessage("OTHER-PROVIDER-SECRET", providerID: other.provider.id),
            Self.userMessage("NO-PROVIDER-ID", providerID: nil),
            Self.userMessage("Reply in Arabic please", providerID: chosen.provider.id),
        ], updatedAt: 3)
        let otherOnly = Self.conversation([Self.userMessage("OTHER-ONLY", providerID: other.provider.id)], updatedAt: 2)
        let older = Self.conversation([Self.userMessage("Working on Andalusia", providerID: chosen.provider.id)], updatedAt: 1)
        let conversations = [older, otherOnly, mixed]

        #expect(flow.prepareDraft(conversations: conversations, candidates: [chosen, other]) == .awaitingConfirmation)
        _ = await flow.confirm()

        let call = try #require(recorder.calls.first)
        #expect(recorder.calls.count == 1)
        #expect(call.providerID == chosen.provider.id)
        let excerpts = MemoryView.buildExcerpts(from: conversations, providerID: chosen.provider.id)
        #expect(excerpts == "user: I write historical novels\nuser: Reply in Arabic please\n---\nuser: Working on Andalusia")
        let expected = MemoryView.draftRequest(
            excerpts: excerpts,
            providerKind: chosen.provider.kind,
            providerName: chosen.provider.displayName,
            model: chosen.model
        )
        #expect(call.request.system == expected.system)
        #expect(call.request.messages.map(\.role) == [.user])
        #expect(call.request.messages.map(\.text) == [excerpts])
        let sent = call.request.messages.map(\.text).joined()
        for leaked in ["ASSISTANT-REPLY", "OTHER-PROVIDER-SECRET", "NO-PROVIDER-ID", "OTHER-ONLY"] {
            #expect(!sent.contains(leaked))
        }
    }

    @Test("draft_failure_does_not_switch_provider")
    func draft_failure_does_not_switch_provider() async {
        let recorder = SendRecorder()
        let first = Self.candidate("first")
        let second = Self.candidate("second")
        let flow = Self.flow(recorder) { model in
            if model.id == "first" { throw ProviderServiceError.emptyResponse }
            return "should never be used"
        }
        let conversations = [Self.conversation([
            Self.userMessage("to first", providerID: first.provider.id),
            Self.userMessage("to second", providerID: second.provider.id),
        ], updatedAt: 1)]

        #expect(flow.prepareDraft(conversations: conversations, candidates: [first, second]) == .awaitingConfirmation)
        let outcome = await flow.confirm()

        #expect(recorder.calls.map(\.modelId) == ["first"])
        // The title is the generic failure title and the body holds the provider's error detail (same on all three platforms, Android is the reference)
        let genericTitle = L10n.tr("Generation failed, please write manually", table: .settings)
        #expect(outcome == .failed(
            title: genericTitle,
            message: ProviderServiceError.emptyResponse.message
        ))

        // An empty reply also errors out directly without switching provider; a non-provider error uses the generic failure text
        let emptyRecorder = SendRecorder()
        let emptyFlow = Self.flow(emptyRecorder) { _ in "   " }
        _ = emptyFlow.prepareDraft(conversations: conversations, candidates: [first, second])
        #expect(await emptyFlow.confirm() == .failed(
            title: genericTitle,
            message: ProviderServiceError.emptyResponse.message
        ))
        #expect(emptyRecorder.calls.map(\.modelId) == ["first"])

        // Non-provider error: the title is the generic failure and the body says "try again later or write it by hand"; the two do not repeat each other
        struct Opaque: Error {}
        #expect(MemoryExtractionFlow.draftFailure(Opaque()) == .failed(
            title: L10n.tr("Generation failed, please write manually", table: .settings),
            message: L10n.tr("Please try again later or write manually.", table: .settings)
        ))
    }

    @Test("draft_not_enough_when_no_user_message_for_provider")
    func draft_not_enough_when_no_user_message_for_provider() {
        let recorder = SendRecorder()
        let chosen = Self.candidate("first")
        let other = Self.candidate("second")
        let flow = Self.flow(recorder)
        let conversations = [Self.conversation([
            TestFactories.makeMessage(role: .assistant, text: "reply", providerID: chosen.provider.id),
            Self.userMessage("to other", providerID: other.provider.id),
            Self.userMessage("legacy", providerID: nil),
        ], updatedAt: 1)]

        #expect(MemoryView.buildExcerpts(from: conversations, providerID: chosen.provider.id).isEmpty)
        #expect(flow.prepareDraft(conversations: conversations, candidates: [chosen, other]) == .notEnough)
        #expect(flow.disclosure == nil)
        #expect(flow.prepareDraft(conversations: conversations, candidates: []) == .noModel)
        #expect(flow.disclosure == nil)
        #expect(recorder.calls.isEmpty)
    }

    // MARK: Organize into items

    private static func organizeItem() -> MemoryItem {
        MemoryItem(
            id: "legacy-0001", kind: .fact, content: "Answer briefly.\nUse SI units.", source: MemorySource(type: .migration),
            mutationId: "m-legacy", deviceId: "device-other", createdAt: "2026-01-01T00:00:00.000Z"
        )
    }

    @Test("organize_disclosure_shows_provider_model_and_scope")
    func organize_disclosure_shows_provider_model_and_scope() async throws {
        let recorder = SendRecorder()
        let chosen = Self.candidate("deepseek/deepseek-v4", modelName: "DeepSeek: DeepSeek V4 (free)", kind: .openRouter)
        let other = Self.candidate("second")
        let flow = Self.flow(recorder)
        let item = Self.organizeItem()

        #expect(flow.prepareOrganize(item: item, candidates: [chosen, other]) == .awaitingConfirmation)

        let disclosure = try #require(flow.disclosure)
        #expect(disclosure.title == L10n.tr("memory_extraction_title_organize", table: .chat))
        #expect(disclosure.message.components(separatedBy: "\n") == [
            String(format: L10n.tr("memory_extraction_model", table: .chat), "OpenRouter", "DeepSeek V4"),
            L10n.tr("memory_extraction_scope_organize", table: .chat),
            L10n.tr("memory_extraction_no_fallback", table: .chat),
        ])
        for key in ["memory_extraction_title_organize", "memory_extraction_scope_organize"] {
            #expect(L10n.tr(key, table: .chat) != key)
        }
        #expect(flow.isOrganizePending)

        // What is handed over after confirmation is exactly the provider + model shown in the dialog
        #expect(await flow.confirm() == .organize(item: item, provider: chosen.provider, model: chosen.model))
        #expect(flow.disclosure == nil)
        #expect(await flow.confirm() == nil)
        #expect(recorder.calls.isEmpty)

        // No usable model: no disclosure is shown
        #expect(flow.prepareOrganize(item: item, candidates: []) == .noModel)
        #expect(flow.disclosure == nil)
    }

    @Test("organize_cancel_sends_nothing")
    func organize_cancel_sends_nothing() async {
        let recorder = SendRecorder()
        let flow = Self.flow(recorder)

        #expect(flow.prepareOrganize(item: Self.organizeItem(), candidates: [Self.candidate("first")]) == .awaitingConfirmation)
        flow.cancel()

        #expect(flow.disclosure == nil)
        #expect(!flow.isOrganizePending)
        #expect(await flow.confirm() == nil)
        #expect(recorder.calls.isEmpty)
    }

    @Test("organize_failure_does_not_switch_provider")
    func organize_failure_does_not_switch_provider() async throws {
        let first = Self.candidate("first")
        let second = Self.candidate("second")
        let flow = Self.flow(SendRecorder())
        let item = Self.organizeItem()

        _ = flow.prepareOrganize(item: item, candidates: [first, second])
        guard case let .organize(_, provider, model) = await flow.confirm() else {
            Issue.record("expected organize outcome")
            return
        }

        var calls: [String] = []
        let failing = MemoryOrganizer(candidates: [(provider, model), second]) { _, model, _ in
            calls.append(model.id)
            throw ProviderServiceError.emptyResponse
        }
        #expect(await failing.organize(content: item.content) == .failed)
        #expect(calls == ["first"])

        var emptyCalls: [String] = []
        let empty = MemoryOrganizer(candidates: [(provider, model), second]) { _, model, _ in
            emptyCalls.append(model.id)
            return "   "
        }
        #expect(await empty.organize(content: item.content) == .failed)
        #expect(emptyCalls == ["first"])
    }
}
