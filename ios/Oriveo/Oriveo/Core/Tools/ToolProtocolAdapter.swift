import Foundation
import OriveoProviderKit

/// ```
/// ```
nonisolated protocol ToolProtocolAdapter: Sendable {
    var transport: String { get }
    func encodeTools(_ definitions: [ToolLoopToolDefinition]) throws -> [Any]
    func encodeConversation(_ messages: [ToolLoopMessage]) throws -> ToolProtocolConversation
    func makeStreamDecoder() -> any ToolCallStreamDecoding
    func encodeToolResult(callID: String, toolName: String, content: String) -> ToolLoopMessage
    func encodeAssistantToolCalls(
        text: String,
        reasoning: String?,
        toolCalls: [ToolLoopToolCall],
        replayBlocks: [ToolJSONValue],
        assistantReplay: ToolJSONValue?
    ) -> ToolLoopMessage
}

nonisolated protocol ToolCallStreamDecoding: Sendable {
    mutating func ingest(frame: [String: Any]) -> [ProviderToolCall]
    mutating func finish() -> [ProviderToolCall]
    var replayBlocks: [ToolJSONValue] { get }
}

extension ToolCallStreamDecoding {
    var replayBlocks: [ToolJSONValue] { [] }
}

nonisolated struct ToolProtocolConversation: @unchecked Sendable {
    var system: String?
    var messages: [Any]
}

nonisolated enum ToolProtocolAdapters {
    static let available: [String: any ToolProtocolAdapter] = [
        TransportKind.openaiChat.rawValue: OpenAIChatToolAdapter(),
        TransportKind.anthropicMessages.rawValue: AnthropicToolAdapter(),
        TransportKind.openaiResponses.rawValue: OpenAIResponsesToolAdapter(),
        TransportKind.geminiGenerate.rawValue: GeminiToolAdapter(),
    ]

    static let legWires: [String: any ToolLoopLegWire] = [
        TransportKind.anthropicMessages.rawValue: AnthropicLegWire(),
        TransportKind.openaiResponses.rawValue: OpenAIResponsesLegWire(),
        TransportKind.geminiGenerate.rawValue: GeminiLegWire(),
    ]

    static func adapter(for transport: String) -> (any ToolProtocolAdapter)? {
        available[transport]
    }

    static func legWire(for transport: String) -> (any ToolLoopLegWire)? {
        legWires[transport]
    }
}

nonisolated struct OpenAIChatToolAdapter: ToolProtocolAdapter {
    let transport = TransportKind.openaiChat.rawValue
    var includesToolNameInResult = false

    init(includesToolNameInResult: Bool = false) {
        self.includesToolNameInResult = includesToolNameInResult
    }

    func encodeTools(_ definitions: [ToolLoopToolDefinition]) throws -> [Any] {
        let data = try JSONEncoder().encode(definitions)
        guard let array = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw ProviderServiceError.network(detail: "Could not encode the tool definitions.")
        }
        return array
    }

    func encodeConversation(_ messages: [ToolLoopMessage]) throws -> ToolProtocolConversation {
        var wire: [Any] = []
        for message in messages {
            if let replay = validatedAssistantReplay(message) {
                wire.append(replay)
                continue
            }
            let data = try JSONEncoder().encode(message)
            wire.append(try JSONSerialization.jsonObject(with: data))
        }
        return ToolProtocolConversation(system: nil, messages: wire)
    }

    func makeStreamDecoder() -> any ToolCallStreamDecoding {
        OpenAIChatToolCallStreamDecoder()
    }

    func encodeToolResult(callID: String, toolName: String, content: String) -> ToolLoopMessage {
        ToolLoopMessage(
            role: "tool", content: content, toolCallID: callID,
            name: includesToolNameInResult ? toolName : nil
        )
    }

    func encodeAssistantToolCalls(
        text: String,
        reasoning: String?,
        toolCalls: [ToolLoopToolCall],
        replayBlocks: [ToolJSONValue],
        assistantReplay: ToolJSONValue? = nil
    ) -> ToolLoopMessage {
        ToolLoopMessage(
            role: "assistant", content: text, reasoningContent: reasoning, toolCalls: toolCalls,
            providerAssistantReplay: assistantReplay
        )
    }

    private func validatedAssistantReplay(_ message: ToolLoopMessage) -> [String: Any]? {
        guard message.role == "assistant", let replay = message.providerAssistantReplay,
              let raw = (try? ToolJSONValue.foundation(replay)) as? [String: Any],
              JSONSerialization.isValidJSONObject([raw]),
              let data = try? JSONSerialization.data(withJSONObject: [raw]),
              let state = try? JSONDecoder().decode(RequestPreferenceJSONValue.self, from: data)
        else { return nil }
        let decision = RequestPreferenceResolver.validateContinuation(.init(
            kind: RequestContinuationKind.replayReasoning.rawValue,
            variant: nil,
            step: 1,
            state: ["assistantMessages": state]
        ))
        guard decision.accepted else { return nil }

        guard let expectedData = try? JSONEncoder().encode(message.toolCalls ?? []),
              let expected = try? JSONSerialization.jsonObject(with: expectedData) as? [Any]
        else { return nil }
        let actual = raw["tool_calls"] as? [Any] ?? []
        guard (actual as NSArray).isEqual(to: expected) else { return nil }
        return raw
    }
}

nonisolated struct OpenAIChatToolCallStreamDecoder: ToolCallStreamDecoding {
    private var accumulator = OpenAICompatibleToolCallAccumulator()

    init() {}

    mutating func ingest(frame: [String: Any]) -> [ProviderToolCall] {
        let choice = (frame["choices"] as? [[String: Any]])?.first
        let rawToolCalls = (choice?["delta"] as? [String: Any])?["tool_calls"] as? [[String: Any]]
        let deltas = rawToolCalls.flatMap { raw -> [OpenAICompatibleChunk.Choice.ToolCallDelta]? in
            guard JSONSerialization.isValidJSONObject(raw),
                  let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
            return try? JSONDecoder().decode([OpenAICompatibleChunk.Choice.ToolCallDelta].self, from: data)
        }
        return ingest(toolCalls: deltas, finishReason: choice?["finish_reason"] as? String)
    }

    mutating func ingest(
        toolCalls: [OpenAICompatibleChunk.Choice.ToolCallDelta]?,
        finishReason: String?
    ) -> [ProviderToolCall] {
        if let toolCalls {
            let proposals = toolCalls.filter { $0.function != nil }
            if !proposals.isEmpty { accumulator.accumulate(proposals) }
        }
        guard let finishReason, !finishReason.isEmpty else { return [] }
        return accumulator.flush()
    }

    mutating func finish() -> [ProviderToolCall] {
        accumulator.flush()
    }
}

extension OpenAIChatToolCallStreamDecoder {
    mutating func ingestEvent(
        toolCalls: [OpenAICompatibleChunk.Choice.ToolCallDelta]?,
        finishReason: String?
    ) -> StreamEvent? {
        let calls = ingest(toolCalls: toolCalls, finishReason: finishReason)
        return calls.isEmpty ? nil : .toolCallDeltas(calls)
    }

    mutating func finishEvent() -> StreamEvent? {
        let calls = finish()
        return calls.isEmpty ? nil : .toolCallDeltas(calls)
    }
}
