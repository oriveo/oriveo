import Foundation
import OriveoProviderKit

nonisolated struct GeminiToolAdapter: ToolProtocolAdapter {
    let transport = TransportKind.geminiGenerate.rawValue

    func encodeTools(_ definitions: [ToolLoopToolDefinition]) throws -> [Any] {
        let declarations: [[String: Any]] = try definitions.map { definition in
            [
                "name": definition.function.name,
                "description": definition.function.description,
                "parameters": Self.geminiSchema(try ToolJSONValue.foundation(definition.function.parameters)),
            ]
        }
        return [["functionDeclarations": declarations]]
    }

    func encodeConversation(_ messages: [ToolLoopMessage]) throws -> ToolProtocolConversation {
        var system: [String] = []
        var contents: [[String: Any]] = []

        func appendToLastUser(_ parts: [[String: Any]]) {
            if let last = contents.last, last["role"] as? String == "user",
               var existing = last["parts"] as? [[String: Any]] {
                existing.append(contentsOf: parts)
                contents[contents.count - 1]["parts"] = existing
            } else {
                contents.append(["role": "user", "parts": parts])
            }
        }

        for message in messages {
            switch message.role {
            case "system":
                let text = message.plainText
                guard !text.isEmpty else { continue }
                if contents.isEmpty { system.append(text) } else { appendToLastUser([["text": text]]) }
            case "user":
                appendToLastUser(Self.userParts(message))
            case "assistant":
                var parts: [[String: Any]] = []
                let text = message.plainText
                if !text.isEmpty { parts.append(["text": text]) }
                for call in message.toolCalls ?? [] {
                    var functionCall: [String: Any] = [
                        "name": call.function.name,
                        "args": Self.argsObject(call.function.arguments),
                    ]
                    if let id = Self.providerCallID(call.id) { functionCall["id"] = id }
                    var part: [String: Any] = ["functionCall": functionCall]
                    if let signature = call.providerSignature { part["thoughtSignature"] = signature }
                    parts.append(part)
                }
                guard !parts.isEmpty else { continue }
                contents.append(["role": "model", "parts": parts])
            case "tool":
                guard let callID = message.toolCallID else { continue }
                var functionResponse: [String: Any] = [
                    "name": message.name ?? "",
                    "response": Self.responseObject(message.plainText),
                ]
                if let id = Self.providerCallID(callID) { functionResponse["id"] = id }
                appendToLastUser([["functionResponse": functionResponse]])
            default:
                continue
            }
        }
        return ToolProtocolConversation(
            system: system.isEmpty ? nil : system.joined(separator: "\n\n"),
            messages: contents
        )
    }

    func makeStreamDecoder() -> any ToolCallStreamDecoding {
        GeminiToolCallStreamDecoder()
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
        ToolLoopMessage(role: "assistant", content: text, reasoningContent: reasoning, toolCalls: toolCalls)
    }

    private static func providerCallID(_ id: String) -> String? {
        id.hasPrefix(ToolCallLoop.fallbackCallIDPrefix) ? nil : id
    }

    private static func userParts(_ message: ToolLoopMessage) -> [[String: Any]] {
        guard let parts = message.contentParts else {
            return [["text": message.content ?? ""]]
        }
        var result: [[String: Any]] = []
        for part in parts {
            switch part.type {
            case "text":
                if let text = part.text, !text.isEmpty { result.append(["text": text]) }
            case "image_url":
                guard let url = part.imageURL?.url, let image = DataURLImage(url) else { continue }
                result.append(["inlineData": ["mimeType": image.mediaType, "data": image.base64]])
            default:
                continue
            }
        }
        return result.isEmpty ? [["text": ""]] : result
    }

    static func argsObject(_ arguments: String) -> [String: Any] {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    static func responseObject(_ content: String) -> [String: Any] {
        if let data = content.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        return ["result": content]
    }

    static let schemaKeyAllowlist: Set<String> = [
        "type", "format", "title", "description", "nullable", "enum", "items", "properties", "required",
        "minItems", "maxItems", "minimum", "maximum", "minLength", "maxLength", "pattern", "anyOf",
        "propertyOrdering", "default", "example",
    ]

    static func geminiSchema(_ raw: Any) -> Any {
        guard let object = raw as? [String: Any] else { return raw }
        var result: [String: Any] = [:]
        for (key, value) in object where schemaKeyAllowlist.contains(key) {
            switch key {
            case "type":
                if let types = value as? [String] {
                    let concrete = types.filter { $0 != "null" }
                    if let first = concrete.first { result["type"] = first }
                    if types.contains("null") { result["nullable"] = true }
                } else {
                    result["type"] = value
                }
            case "properties":
                if let properties = value as? [String: Any] {
                    result["properties"] = properties.mapValues { geminiSchema($0) }
                }
            case "items":
                result["items"] = geminiSchema(value)
            case "anyOf":
                if let variants = value as? [Any] { result["anyOf"] = variants.map { geminiSchema($0) } }
            default:
                result[key] = value
            }
        }
        return result
    }
}

nonisolated struct GeminiToolCallStreamDecoder: ToolCallStreamDecoding {
    private var proposals: [ProviderToolCall] = []
    private var didFlush = false

    init() {}

    mutating func ingest(frame: [String: Any]) -> [ProviderToolCall] {
        guard let candidate = (frame["candidates"] as? [[String: Any]])?.first else { return [] }
        if let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] {
            for part in parts {
                guard let functionCall = part["functionCall"] as? [String: Any],
                      let name = functionCall["name"] as? String else { continue }
                let args = functionCall["args"] as? [String: Any] ?? [:]
                let arguments = (try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                proposals.append(ProviderToolCall(
                    providerCallID: functionCall["id"] as? String,
                    name: name,
                    rawArguments: arguments,
                    providerSignature: part["thoughtSignature"] as? String
                ))
            }
        }
        guard let finishReason = candidate["finishReason"] as? String, !finishReason.isEmpty else { return [] }
        return flush()
    }

    mutating func finish() -> [ProviderToolCall] {
        flush()
    }

    private mutating func flush() -> [ProviderToolCall] {
        guard !didFlush else { return [] }
        didFlush = true
        return proposals
    }
}

nonisolated struct GeminiLegWire: ToolLoopLegWire {
    let transportKind = TransportKind.geminiGenerate
    let relayTransportKey = MetadataClient.RelayTransportKey.geminiGenerateContent
    let officialAuthMode = RelayAuthMode.xGoogApiKey
    let streamQueryItems = [URLQueryItem(name: "alt", value: "sse")]
    let injectsEventType = false

    static let blockedFinishReasons: Set<String> = ["SAFETY", "RECITATION", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII"]

    func officialEndpoint(providerKind: ProviderKind, userBaseURL: String?, modelID: String) throws -> URL {
        let models = try EndpointResolver.resolve(
            providerKind: providerKind,
            userBaseURL: userBaseURL,
            kind: .chat,
            metadataTransport: MetadataClient.shared.syncProviderTransport(providerKind: providerKind)
        ).url
        guard let url = URL(string: "\(models.absoluteString)/\(modelID):streamGenerateContent") else {
            throw ProviderServiceError.invalidConfiguration(detail: "Invalid Gemini endpoint.")
        }
        return url
    }

    func relayEndpointPath(modelID: String) -> String { "/models/\(modelID):streamGenerateContent" }

    func applyProtocolHeaders(to request: inout URLRequest) {}

    func requestBody(
        modelID: String,
        conversation: ToolProtocolConversation,
        tools: [Any]?,
        toolChoice: ToolLoopToolChoice,
        maxOutputTokens: Int?
    ) -> [String: Any] {
        var body: [String: Any] = ["contents": conversation.messages]
        if let system = conversation.system {
            body["systemInstruction"] = ["parts": [["text": system]]]
        }
        if let maxOutputTokens { body["generationConfig"] = ["maxOutputTokens": maxOutputTokens] }
        if let tools {
            body["tools"] = tools
            body["toolConfig"] = ["functionCallingConfig": ["mode": toolChoice == .none ? "NONE" : "AUTO"]]
        }
        return body
    }

    func usage(from frame: [String: Any], current: ToolLoopUsage?) -> ToolLoopUsage? {
        guard let usage = frame["usageMetadata"] as? [String: Any] else { return nil }
        return ToolLoopUsage(
            promptTokens: usage["promptTokenCount"] as? Int ?? current?.promptTokens,
            completionTokens: usage["candidatesTokenCount"] as? Int ?? current?.completionTokens,
            totalTokens: usage["totalTokenCount"] as? Int ?? current?.totalTokens
        )
    }

    func streamError(in frame: [String: Any]) -> ProviderServiceError? {
        if let error = frame["error"] as? [String: Any] {
            let message = (error["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let status = (error["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !message.isEmpty || !status.isEmpty {
                let detail = !status.isEmpty && !message.isEmpty ? "[\(status)] \(message)" : (message.isEmpty ? status : message)
                return .upstream(statusCode: 200, detail: "Gemini stream error: \(detail)")
            }
        }
        if let blockReason = (frame["promptFeedback"] as? [String: Any])?["blockReason"] as? String, !blockReason.isEmpty {
            return .upstream(statusCode: 200, detail: "Gemini blocked the prompt (blockReason=\(blockReason)).")
        }
        if let finishReason = (frame["candidates"] as? [[String: Any]])?.first?["finishReason"] as? String,
           Self.blockedFinishReasons.contains(finishReason) {
            return .upstream(statusCode: 200, detail: "Gemini stopped the response (finishReason=\(finishReason)).")
        }
        return nil
    }
}
