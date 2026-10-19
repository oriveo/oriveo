import Foundation
import GRDB
import OriveoProviderKit
import Testing
@testable import Oriveo

/// For replay-style continuation the service replays the target assistant message, so the target must be removed from the outbound history,
/// otherwise the target assistant would be sent twice, once by the continue outbound history and once by the replay. Assertions read the request body MoonshotService actually emits.
extension ContextPipelineTests {

    private static let replayModelID = "kimi-replay"

    @Test func continue_replay_kind_drops_target() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: Self.moonshotReplayMetadata)
        defer { JoinedURLProtocol.reset() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oriveo-replay-continuation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try RecipeContinuationStore(
            dbPool: try DatabasePool(path: directory.appendingPathComponent("sidecar.sqlite").path)
        )
        defer {
            try? store.dbPoolForTesting.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let session = JoinedURLProtocol.session { _, _, _ in
            JoinedContinuationFixture.response(
                recipeRef: "moonshot.chat.reasoning.v1", responseParserKind: "moonshot_reasoning_v1",
                transport: "openai_chat", stream: true
            )
        }
        let service = MoonshotService(session: session)
        let question = Self.moonshotMessage(role: .user, text: "Question")
        let targetID = UUID()
        let partial = Self.moonshotMessage(id: targetID, role: .assistant, text: "Partial answer")
        let continueTurn = Self.moonshotMessage(role: .user, text: ContextAssembler.continuePrompt)

        var producerOptions = ChatRequestOptions()
        producerOptions.localContinuationMessageID = targetID
        try await RecipeContinuationRuntime.withStore(store) {
            for try await _ in service.sendMessageStream(
                apiKey: "test-key", modelID: Self.replayModelID, messages: [question],
                reasoningMode: .deep, requestOptions: producerOptions
            ) {}
        }
        #expect(try store.load(messageID: targetID)?.kind == "replay_reasoning")
        let before = JoinedURLProtocol.capturedRequests().count

        var explicitOptions = ChatRequestOptions()
        explicitOptions.localExplicitContinuationMessageID = targetID
        explicitOptions.continuationFingerprintMatches = true
        try await RecipeContinuationRuntime.withStore(store) {
            for try await _ in service.sendMessageStream(
                apiKey: "test-key", modelID: Self.replayModelID, messages: [question, partial, continueTurn],
                reasoningMode: .deep, requestOptions: explicitOptions
            ) {}
        }

        let request = try #require(JoinedURLProtocol.capturedRequests().dropFirst(before).first)
        let body = try #require(try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any])
        let messages = try #require(body["messages"] as? [[String: Any]])
        let roles = messages.compactMap { $0["role"] as? String }
        // The target is replayed exactly once by replay (in native shape, not as the flat partial in the outbound history) and comes before the continuation user message.
        #expect(roles.filter { $0 == "assistant" }.count == 1, "roles: \(roles)")
        #expect(roles == ["user", "assistant", "user"], "roles: \(roles)")
        #expect(messages.last?["content"] as? String == ContextAssembler.continuePrompt)
        #expect(messages[1]["content"] as? String != "Partial answer")
        await MetadataClient.shared.resetForTesting()
    }

    private static func moonshotMessage(id: UUID = UUID(), role: ChatRole, text: String) -> ChatMessage {
        ChatMessage(
            id: id, role: role, text: text, providerKind: .moonshot, providerName: "Moonshot",
            modelID: replayModelID, modelName: replayModelID, state: .delivered
        )
    }

    private static let moonshotReplayMetadata = """
    {
      "version": 1,
      "providers": {
        "moonshot": {
          "resolveMap": {"kimi-replay":"kimi-replay"},
          "models": {
            "kimi-replay": {
              "canonicalModelId":"kimi-replay",
              "transport":"openai_chat",
              "capabilities":["text","reasoning"],
              "capabilityControls": {
                "reasoning":{"state":"auto_available","recipeRef":"moonshot.chat.reasoning.v1"}
              }
            }
          }
        }
      },
      "capabilityRuntime": {
        "schemaVersion":2,
        "revision":"moonshot-replay-test",
        "generatedAt":"2026-10-15T00:00:00Z",
        "recipes": {
          "moonshot.chat.reasoning.v1": {
            "id":"moonshot.chat.reasoning.v1",
            "providerKind":"moonshot",
            "transport":{"protocol":"openai_chat"},
            "capability":"reasoning",
            "executionKind":"request_overlay",
            "requestOps":[{"op":"set","intent":"deep","pointer":"/reasoning_effort","value":"high"}],
            "responseParserKind":"moonshot_reasoning_v1",
            "continuationKind":"replay_reasoning",
            "fallbackPolicy":"remove_auto_patch_once_pre_token",
            "sourceRefs":["kimi.thinking_models"]
          }
        },
        "controlDefinitions":{},
        "sourceIndex":{"kimi.thinking_models":{"kind":"official_doc","url":"https://platform.moonshot.ai/","reviewedAt":"2026-08-15"}}
      }
    }
    """
}
