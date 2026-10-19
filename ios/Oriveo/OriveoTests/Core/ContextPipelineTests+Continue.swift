import Foundation
import GRDB
import OriveoProviderKit
import Testing
@testable import Oriveo

/// "Continue generating" is produced by ContextAssembler (purpose continue). Assertions read the request bodies the production send chain actually emits;
/// the relay fixtures are reused from ContextPipelineTests+Overflow.swift and the Responses metadata from ContextPipelineTests+Stateful.swift.
extension ContextPipelineTests {

    private static let legacyContinueInstruction = "Continue from where you stopped."

    @Test func continue_uses_continue_prompt_and_keeps_target() async throws {
        let targetID = UUID()
        let fixture = makeOverflowFixture(messages: [
            TestFactories.makeMessage(role: .user, text: "Question"),
            TestFactories.makeMessage(id: targetID, role: .assistant, text: "Partial answer", state: .interrupted),
        ])
        OverflowURLProtocol.reset([
            .init(status: 200, body: Self.sse([Self.contentFrame(" more"), Self.stopFrame(promptTokens: nil)])),
        ])
        defer { OverflowURLProtocol.reset([]) }

        await fixture.state.chatManager.continueMessage(messageID: targetID, in: fixture.conversationID)
        try await Self.waitUntilSettled(fixture.state, conversationID: fixture.conversationID)

        let body = try #require(OverflowURLProtocol.bodies.first, "continue issued no request")
        let messages = Self.chatWireMessages(body)
        // History is cut at the target (inclusive), an interrupted target is kept as delivered, and the current message is the core continuation sentence.
        #expect(messages.map(\.role) == ["user", "assistant", "user"])
        #expect(messages.map(\.text) == ["Question", "Partial answer", ContextAssembler.continuePrompt])
        #expect(!messages.contains { $0.text.contains(Self.legacyContinueInstruction) })
        // The continuation text is still appended to the target assistant message; no new message is added.
        let stored = fixture.state.conversation(for: fixture.conversationID)?.messages ?? []
        #expect(stored.count == 2)
        #expect(stored.last?.id == targetID)
        #expect(stored.last?.text.hasPrefix("Partial answer") == true, "stored: \(stored.last?.text ?? "nil")")
        #expect(stored.last?.text.contains("more") == true)
    }

    @Test func continue_stateful_omit_drops_instructions() async throws {
        let bodies = try await Self.responsesContinueBodies(mode: "omit")
        let body = try #require(bodies.last)
        #expect(body["previous_response_id"] as? String == Self.continueFirstResponseID)
        #expect(body["instructions"] == nil, "omit mode never sends instructions with previous_response_id")
        let input = body["input"] as? [[String: Any]] ?? []
        #expect(input.count == 1, "stateful continue sends only the continue prompt")
        #expect(Self.responsesText(input.first) == ContextAssembler.continuePrompt)
    }

    @Test func continue_mode_missing_sends_full_plan() async throws {
        let bodies = try await Self.responsesContinueBodies(mode: nil)
        let body = try #require(bodies.last)
        #expect(body["previous_response_id"] == nil)
        #expect(body["instructions"] as? String == bodies.first?["instructions"] as? String)
        #expect((body["instructions"] as? String)?.contains(Self.continueMemoryText) == true)
        let input = body["input"] as? [[String: Any]] ?? []
        #expect(input.count == 3, "full plan replays the history through the target plus the continue prompt")
        #expect(Self.responsesText(input.last) == ContextAssembler.continuePrompt)
    }

    // MARK: Fixtures

    private static let continueFirstResponseID = "resp_a1_first"
    private static let continueMemoryText = "The user prefers green tea."
    private static let continueModelID = "grok-4.3"

    /// Grok Responses: send one message first (storing previousResponseId and the fingerprint on completion), then "continue generating" on that answer. Returns both request bodies.
    private static func responsesContinueBodies(mode: String?) async throws -> [[String: Any]] {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: try statefulMetadata(
            recipeRef: "grok.responses.web.v1", modelID: continueModelID, serverProviderKey: "grok", mode: mode
        ))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oriveo-a1-continue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: directory.appendingPathComponent("sidecar.sqlite").path)
        let store = try RecipeContinuationStore(dbPool: pool)
        defer {
            try? pool.close()
            try? FileManager.default.removeItem(at: directory)
        }

        let providerID = UUID()
        let model = TestFactories.makeModel(id: continueModelID, capabilities: [.text], isDefault: true)
        let provider = Provider(
            id: providerID, kind: .grok, status: .connected, models: [model], catalogModels: [],
            apiKey: "grok-key", apiKeyPreview: "...key", baseURLText: ""
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OverflowURLProtocol.self]
        let state = AppState(
            seedDemoData: false,
            sessionUID: "context-pipeline-continue-\(UUID().uuidString)",
            providerSession: URLSession(configuration: configuration)
        )
        try await ContextPipelineTests.seedMemory(state, [
            ContextPipelineTests.memoryItem("mem-continue", .fact, continueMemoryText, createdAt: "2026-01-01T00:00:00Z"),
        ])
        var conversation = TestFactories.makeConversation(
            providerID: providerID, providerKind: .grok, modelID: continueModelID, messages: []
        )
        conversation.useMemory = true
        state.providers = [provider]
        state.upsertConversationProjection(conversation)

        var selection = ChatCapabilitySelection()
        selection.webSearchEnabled = true
        selection.typedPreferences = CapabilityPreferenceValues(web: .automatic)
        OverflowURLProtocol.reset([
            .init(status: 200, body: responsesSSE(text: "Partial", responseID: continueFirstResponseID)),
            .init(status: 200, body: responsesSSE(text: " rest", responseID: "resp_a1_second")),
        ])
        defer { OverflowURLProtocol.reset([]) }

        await RecipeContinuationRuntime.$storeFactory.withValue({ store }) {
            _ = await state.sendMessage("Question", in: conversation.id, capabilitySelection: selection)
            try? await waitUntilSettled(state, conversationID: conversation.id)
            let answerID = state.conversation(for: conversation.id)?.messages.last?.id
            if let answerID {
                // The first answer completes: the sidecar stores previousResponseId (the fingerprint is kept in memory alongside).
                let saved = RecipeContinuationRuntime.load(messageID: answerID)
                let savedID: String? = if case let .string(value)? = saved?.state["previousResponseId"] { value } else { nil }
                #expect(savedID == continueFirstResponseID,
                        "sidecar after first answer: \(String(describing: saved))")
                await state.chatManager.continueMessage(
                    messageID: answerID, in: conversation.id, capabilitySelection: selection
                )
                try? await waitUntilSettled(state, conversationID: conversation.id)
                let continued = state.conversation(for: conversation.id)?.messages.last
                #expect(continued?.id == answerID)
                // The continuation text follows the original text (it does not overwrite it).
                #expect(continued?.text.hasPrefix("Partial") == true, "continued: \(continued?.text ?? "nil")")
                #expect(continued?.text.hasSuffix("rest") == true, "continued: \(continued?.text ?? "nil")")
            }
        }
        await MetadataClient.shared.resetForTesting()
        let bodies = OverflowURLProtocol.bodies
        #expect(bodies.count == 2, "expected the first send and the continue request")
        return bodies
    }

    private static func responsesSSE(text: String, responseID: String) -> String {
        let delta = #"{"type":"response.output_text.delta","delta":"\#(text)"}"#
        let completed = #"{"type":"response.completed","response":{"id":"\#(responseID)","status":"completed"}}"#
        return "event: response.output_text.delta\ndata: \(delta)\n\n"
            + "event: response.completed\ndata: \(completed)\n\n"
    }

    private static func responsesText(_ item: [String: Any]?) -> String? {
        if let text = item?["content"] as? String { return text }
        let parts = item?["content"] as? [[String: Any]] ?? []
        return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private static func waitUntilSettled(_ state: AppState, conversationID: UUID) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        try await Task.sleep(nanoseconds: 50_000_000)
        while ContinuousClock.now < deadline {
            let last = state.conversation(for: conversationID)?.messages.last
            if last?.role == .assistant, last?.state != .generating { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    private static func chatWireMessages(_ body: [String: Any]) -> [(role: String, text: String)] {
        let raw = body["messages"] as? [[String: Any]] ?? []
        return raw.map { message in
            let text: String
            if let string = message["content"] as? String {
                text = string
            } else if let parts = message["content"] as? [[String: Any]] {
                text = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                    .joined(separator: "\n")
            } else {
                text = ""
            }
            return (message["role"] as? String ?? "", text)
        }
    }
}
