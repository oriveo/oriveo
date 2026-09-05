import Foundation
import OriveoProviderKit

nonisolated struct AnthropicToolAdapter: ToolProtocolAdapter {
    let transport = TransportKind.anthropicMessages.rawValue

    func encodeTools(_ definitions: [ToolLoopToolDefinition]) throws -> [Any] {
        try definitions.map { definition in
            [
                "name": definition.function.name,
                "description": definition.function.description,
                "input_schema": try ToolJSONValue.foundation(definition.function.parameters),
            ] as [String: Any]
        }
    }

    func encodeConversation(_ messages: [ToolLoopMessage]) throws -> ToolProtocolConversation {
        var system: [String] = []
        var wire: [[String: Any]] = []

        func appendToLastUser(_ blocks: [[String: Any]]) {
            if let last = wire.last, last["role"] as? String == "user",
               var content = last["content"] as? [[String: Any]] {
                content.append(contentsOf: blocks)
                wire[wire.count - 1]["content"] = content
            } else {
                wire.append(["role": "user", "content": blocks])
            }
        }

        for message in messages {
            switch message.role {
            case "system":
                let text = message.plainText
                guard !text.isEmpty else { continue }
                if wire.isEmpty { system.append(text) } else { appendToLastUser([["type": "text", "text": text]]) }
            case "user":
                appendToLastUser(try Self.userBlocks(message))
            case "assistant":
                var blocks: [[String: Any]] = try (message.providerReplayBlocks ?? []).map { try ToolJSONValue.foundation($0) as? [String: Any] ?? [:] }
                let text = message.plainText
                if !text.isEmpty { blocks.append(["type": "text", "text": text]) }
                for call in message.toolCalls ?? [] {
                    blocks.append([
                        "type": "tool_use",
                        "id": call.id,
                        "name": call.function.name,
                        "input": Self.inputObject(call.function.arguments),
                    ])
                }
                guard !blocks.isEmpty else { continue }
                wire.append(["role": "assistant", "content": blocks])
            case "tool":
                guard let callID = message.toolCallID else { continue }
                appendToLastUser([[
                    "type": "tool_result",
                    "tool_use_id": callID,
                    "content": message.plainText,
                ]])
            default:
                continue
            }
        }
        return ToolProtocolConversation(
            system: system.isEmpty ? nil : system.joined(separator: "\n\n"),
            messages: wire
        )
    }

    func makeStreamDecoder() -> any ToolCallStreamDecoding {
        AnthropicToolCallStreamDecoder()
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

    private static func userBlocks(_ message: ToolLoopMessage) throws -> [[String: Any]] {
        guard let parts = message.contentParts else {
            return [["type": "text", "text": message.content ?? ""]]
        }
        var blocks: [[String: Any]] = []
        for part in parts {
            switch part.type {
            case "text":
                if let text = part.text, !text.isEmpty { blocks.append(["type": "text", "text": text]) }
            case "image_url":
                guard let url = part.imageURL?.url, let image = DataURLImage(url) else { continue }
                blocks.append([
                    "type": "image",
                    "source": ["type": "base64", "media_type": image.mediaType, "data": image.base64],
                ])
            default:
                continue
            }
        }
        return blocks.isEmpty ? [["type": "text", "text": ""]] : blocks
    }

    static func inputObject(_ arguments: String) -> [String: Any] {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
}

nonisolated struct AnthropicToolCallStreamDecoder: ToolCallStreamDecoding {
    private struct PendingToolUse {
        var id: String?
        var name: String
        var partialJSON = ""
        var initialInput: [String: Any]
    }

    private struct PendingThinking {
        var thinking = ""
        var signature = ""
    }

    private var toolUses: [Int: PendingToolUse] = [:]
    private var thinking: [Int: PendingThinking] = [:]
    private var orderedReplay: [(index: Int, block: ToolJSONValue)] = []
    private var didFlush = false

    init() {}

    var replayBlocks: [ToolJSONValue] {
        orderedReplay.sorted { $0.index < $1.index }.map(\.block)
    }

    mutating func ingest(frame: [String: Any]) -> [ProviderToolCall] {
        guard let type = frame["type"] as? String else { return [] }
        switch type {
        case "content_block_start":
            guard let index = frame["index"] as? Int,
                  let block = frame["content_block"] as? [String: Any] else { return [] }
            switch block["type"] as? String {
            case "tool_use":
                toolUses[index] = PendingToolUse(
                    id: block["id"] as? String,
                    name: block["name"] as? String ?? "",
                    initialInput: block["input"] as? [String: Any] ?? [:]
                )
            case "thinking":
                thinking[index] = PendingThinking(thinking: block["thinking"] as? String ?? "")
            case "redacted_thinking":
                if let data = block["data"] as? String {
                    orderedReplay.append((index, .object(["type": .string("redacted_thinking"), "data": .string(data)])))
                }
            default:
                break
            }
        case "content_block_delta":
            guard let index = frame["index"] as? Int,
                  let delta = frame["delta"] as? [String: Any] else { return [] }
            switch delta["type"] as? String {
            case "input_json_delta":
                toolUses[index]?.partialJSON += delta["partial_json"] as? String ?? ""
            case "thinking_delta":
                thinking[index]?.thinking += delta["thinking"] as? String ?? ""
            case "signature_delta":
                thinking[index]?.signature += delta["signature"] as? String ?? ""
            default:
                break
            }
        case "content_block_stop":
            guard let index = frame["index"] as? Int, let pending = thinking.removeValue(forKey: index) else { return [] }
            orderedReplay.append((index, .object([
                "type": .string("thinking"),
                "thinking": .string(pending.thinking),
                "signature": .string(pending.signature),
            ])))
        case "message_delta":
            guard let delta = frame["delta"] as? [String: Any],
                  let stopReason = delta["stop_reason"] as? String, !stopReason.isEmpty else { return [] }
            return flush()
        default:
            break
        }
        return []
    }

    mutating func finish() -> [ProviderToolCall] {
        flush()
    }

    private mutating func flush() -> [ProviderToolCall] {
        guard !didFlush else { return [] }
        didFlush = true
        return toolUses.keys.sorted().compactMap { index in
            guard let pending = toolUses[index] else { return nil }
            let arguments: String = {
                let trimmed = pending.partialJSON.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return pending.partialJSON }
                let data = try? JSONSerialization.data(withJSONObject: pending.initialInput, options: [.sortedKeys])
                return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            }()
            return ProviderToolCall(providerCallID: pending.id, name: pending.name, rawArguments: arguments)
        }
    }
}

nonisolated struct AnthropicLegWire: ToolLoopLegWire {
    let transportKind = TransportKind.anthropicMessages
    let relayTransportKey = MetadataClient.RelayTransportKey.anthropicMessages
    let officialAuthMode = RelayAuthMode.xApiKey
    let streamQueryItems: [URLQueryItem] = []
    let injectsEventType = false

    func officialEndpoint(providerKind: ProviderKind, userBaseURL: String?, modelID: String) throws -> URL {
        try EndpointResolver.resolve(
            providerKind: providerKind,
            userBaseURL: userBaseURL,
            kind: .chat,
            metadataTransport: MetadataClient.shared.syncProviderTransport(providerKind: providerKind)
        ).url
    }

    func relayEndpointPath(modelID: String) -> String { "/messages" }

    func applyProtocolHeaders(to request: inout URLRequest) {
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    }

    func requestBody(
        modelID: String,
        conversation: ToolProtocolConversation,
        tools: [Any]?,
        toolChoice: ToolLoopToolChoice,
        maxOutputTokens: Int?
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": modelID,
            "messages": conversation.messages,
            "stream": true,
            "max_tokens": maxOutputTokens ?? 8192,
        ]
        if let system = conversation.system { body["system"] = system }
        if let tools {
            body["tools"] = tools
            body["tool_choice"] = ["type": toolChoice == .none ? "none" : "auto"]
        }
        return body
    }

    func usage(from frame: [String: Any], current: ToolLoopUsage?) -> ToolLoopUsage? {
        switch frame["type"] as? String {
        case "message_start":
            guard let usage = (frame["message"] as? [String: Any])?["usage"] as? [String: Any] else { return nil }
            let input = (usage["input_tokens"] as? Int ?? 0)
                + (usage["cache_creation_input_tokens"] as? Int ?? 0)
                + (usage["cache_read_input_tokens"] as? Int ?? 0)
            let output = usage["output_tokens"] as? Int ?? 0
            return ToolLoopUsage(promptTokens: input, completionTokens: output, totalTokens: input + output)
        case "message_delta":
            guard let output = (frame["usage"] as? [String: Any])?["output_tokens"] as? Int else { return nil }
            let input = current?.promptTokens ?? 0
            return ToolLoopUsage(promptTokens: input, completionTokens: output, totalTokens: input + output)
        default:
            return nil
        }
    }

    func streamError(in frame: [String: Any]) -> ProviderServiceError? {
        guard frame["type"] as? String == "error" else { return nil }
        let error = frame["error"] as? [String: Any]
        return .upstream(
            statusCode: 500,
            detail: error?["message"] as? String ?? "The provider returned a streaming error."
        )
    }
}

nonisolated struct DataURLImage {
    let mediaType: String
    let base64: String

    init?(_ url: String) {
        guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") else { return nil }
        let header = url[url.index(url.startIndex, offsetBy: 5)..<comma]
        guard header.hasSuffix(";base64") else { return nil }
        mediaType = String(header.dropLast(";base64".count))
        base64 = String(url[url.index(after: comma)...])
    }
}

extension ToolJSONValue {
    static func foundation(_ value: ToolJSONValue) throws -> Any {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    static func make(_ object: Any) throws -> ToolJSONValue {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
        return try JSONDecoder().decode(ToolJSONValue.self, from: data)
    }
}
