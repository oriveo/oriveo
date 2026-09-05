import Foundation
import OriveoProviderKit

nonisolated struct OpenAIResponsesToolAdapter: ToolProtocolAdapter {
    let transport = TransportKind.openaiResponses.rawValue

    func encodeTools(_ definitions: [ToolLoopToolDefinition]) throws -> [Any] {
        try definitions.map { definition in
            [
                "type": "function",
                "name": definition.function.name,
                "description": definition.function.description,
                "parameters": try ToolJSONValue.foundation(definition.function.parameters),
            ] as [String: Any]
        }
    }

    func encodeConversation(_ messages: [ToolLoopMessage]) throws -> ToolProtocolConversation {
        var instructions: [String] = []
        var input: [[String: Any]] = []
        for message in messages {
            switch message.role {
            case "system":
                let text = message.plainText
                guard !text.isEmpty else { continue }
                if input.isEmpty {
                    instructions.append(text)
                } else {
                    input.append(["role": "system", "content": [["type": "input_text", "text": text]]])
                }
            case "user":
                input.append(["role": "user", "content": Self.userContent(message)])
            case "assistant":
                for block in message.providerReplayBlocks ?? [] {
                    if let item = try ToolJSONValue.foundation(block) as? [String: Any] { input.append(item) }
                }
                let text = message.plainText
                if !text.isEmpty {
                    input.append(["role": "assistant", "content": [["type": "output_text", "text": text]]])
                }
                for call in message.toolCalls ?? [] {
                    input.append([
                        "type": "function_call",
                        "call_id": call.id,
                        "name": call.function.name,
                        "arguments": call.function.arguments,
                    ])
                }
            case "tool":
                guard let callID = message.toolCallID else { continue }
                input.append(["type": "function_call_output", "call_id": callID, "output": message.plainText])
            default:
                continue
            }
        }
        return ToolProtocolConversation(
            system: instructions.isEmpty ? nil : instructions.joined(separator: "\n\n"),
            messages: input
        )
    }

    func makeStreamDecoder() -> any ToolCallStreamDecoding {
        OpenAIResponsesToolCallStreamDecoder()
    }

    func encodeToolResult(callID: String, toolName: String, content: String) -> ToolLoopMessage {
        ToolLoopMessage(role: "tool", content: content, toolCallID: callID, name: toolName)
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
            providerReplayBlocks: replayBlocks.isEmpty ? nil : replayBlocks
        )
    }

    private static func userContent(_ message: ToolLoopMessage) -> [[String: Any]] {
        guard let parts = message.contentParts else {
            return [["type": "input_text", "text": message.content ?? ""]]
        }
        var content: [[String: Any]] = []
        for part in parts {
            switch part.type {
            case "text":
                if let text = part.text, !text.isEmpty { content.append(["type": "input_text", "text": text]) }
            case "image_url":
                if let url = part.imageURL?.url, !url.isEmpty {
                    content.append(["type": "input_image", "image_url": url, "detail": part.imageURL?.detail ?? "auto"])
                }
            default:
                continue
            }
        }
        return content.isEmpty ? [["type": "input_text", "text": ""]] : content
    }
}

nonisolated struct OpenAIResponsesToolCallStreamDecoder: ToolCallStreamDecoding {
    private struct PendingCall {
        var callID: String?
        var name: String
        var arguments: String
    }

    private var calls: [Int: PendingCall] = [:]
    private var indexByItemID: [String: Int] = [:]
    private var reasoningItems: [Int: ToolJSONValue] = [:]
    private var didFlush = false

    init() {}

    var replayBlocks: [ToolJSONValue] {
        reasoningItems.keys.sorted().compactMap { reasoningItems[$0] }
    }

    mutating func ingest(frame: [String: Any]) -> [ProviderToolCall] {
        guard let type = frame["type"] as? String else { return [] }
        switch type {
        case "response.output_item.added", "response.output_item.done":
            guard let item = frame["item"] as? [String: Any] else { return [] }
            let index = frame["output_index"] as? Int ?? calls.count
            switch item["type"] as? String {
            case "function_call":
                var pending = calls[index] ?? PendingCall(callID: nil, name: "", arguments: "")
                if let callID = item["call_id"] as? String, !callID.isEmpty { pending.callID = callID }
                if let name = item["name"] as? String, !name.isEmpty { pending.name = name }
                if let arguments = item["arguments"] as? String,
                   type == "response.output_item.done" || pending.arguments.isEmpty {
                    pending.arguments = arguments
                }
                calls[index] = pending
                if let itemID = item["id"] as? String { indexByItemID[itemID] = index }
            case "reasoning":
                guard type == "response.output_item.done" else { return [] }
                var replay: [String: ToolJSONValue] = ["type": .string("reasoning")]
                if let id = item["id"] as? String { replay["id"] = .string(id) }
                if let summary = item["summary"], let value = try? ToolJSONValue.make(summary) { replay["summary"] = value }
                if let encrypted = item["encrypted_content"] as? String { replay["encrypted_content"] = .string(encrypted) }
                reasoningItems[index] = .object(replay)
            default:
                break
            }
        case "response.function_call_arguments.delta":
            guard let index = resolveIndex(frame), let delta = frame["delta"] as? String else { return [] }
            calls[index]?.arguments += delta
        case "response.function_call_arguments.done":
            guard let index = resolveIndex(frame), let arguments = frame["arguments"] as? String else { return [] }
            calls[index]?.arguments = arguments
        case "response.completed", "response.incomplete":
            return flush()
        default:
            break
        }
        return []
    }

    mutating func finish() -> [ProviderToolCall] {
        flush()
    }

    private func resolveIndex(_ frame: [String: Any]) -> Int? {
        if let itemID = frame["item_id"] as? String, let index = indexByItemID[itemID] { return index }
        return frame["output_index"] as? Int
    }

    private mutating func flush() -> [ProviderToolCall] {
        guard !didFlush else { return [] }
        didFlush = true
        return calls.keys.sorted().compactMap { index in
            guard let pending = calls[index] else { return nil }
            return ProviderToolCall(providerCallID: pending.callID, name: pending.name, rawArguments: pending.arguments)
        }
    }
}

nonisolated struct OpenAIResponsesLegWire: ToolLoopLegWire {
    let transportKind = TransportKind.openaiResponses
    let relayTransportKey = MetadataClient.RelayTransportKey.openaiResponses
    let officialAuthMode = RelayAuthMode.bearer
    let streamQueryItems: [URLQueryItem] = []
    let injectsEventType = true

    func officialEndpoint(providerKind: ProviderKind, userBaseURL: String?, modelID: String) throws -> URL {
        try EndpointResolver.resolve(
            providerKind: providerKind,
            userBaseURL: userBaseURL,
            kind: .responses,
            metadataTransport: MetadataClient.shared.syncProviderTransport(providerKind: providerKind)
        ).url
    }

    func relayEndpointPath(modelID: String) -> String { "/responses" }

    func applyProtocolHeaders(to request: inout URLRequest) {}

    func requestBody(
        modelID: String,
        conversation: ToolProtocolConversation,
        tools: [Any]?,
        toolChoice: ToolLoopToolChoice,
        maxOutputTokens: Int?
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": modelID,
            "input": conversation.messages,
            "stream": true,
        ]
        if let system = conversation.system { body["instructions"] = system }
        if let maxOutputTokens { body["max_output_tokens"] = maxOutputTokens }
        if let tools {
            body["tools"] = tools
            body["tool_choice"] = toolChoice == .none ? "none" : "auto"
        }
        return body
    }

    func usage(from frame: [String: Any], current: ToolLoopUsage?) -> ToolLoopUsage? {
        guard frame["type"] as? String == "response.completed",
              let usage = (frame["response"] as? [String: Any])?["usage"] as? [String: Any] else { return nil }
        return ToolLoopUsage(
            promptTokens: usage["input_tokens"] as? Int,
            completionTokens: usage["output_tokens"] as? Int,
            totalTokens: usage["total_tokens"] as? Int
        )
    }

    func streamError(in frame: [String: Any]) -> ProviderServiceError? {
        guard let type = frame["type"] as? String, type == "error" || type == "response.failed" else { return nil }
        let error = (frame["error"] as? [String: Any])
            ?? ((frame["response"] as? [String: Any])?["error"] as? [String: Any])
        return OpenAIService.mapRelayStreamError(
            code: error?["code"] as? String,
            message: error?["message"] as? String ?? "The provider returned a streaming error."
        )
    }
}
