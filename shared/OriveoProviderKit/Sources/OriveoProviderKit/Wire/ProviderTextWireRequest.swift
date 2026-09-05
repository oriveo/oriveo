import Foundation

public enum ProviderWireMessageRole: String, Codable, Hashable, Sendable {
    case system, user, assistant, tool
}

public struct ProviderWireTool: Codable, Hashable, Sendable {
    public var name: String
    public var description: String
    public var inputSchema: ProviderRecipeValue

    public init(name: String, description: String, inputSchema: ProviderRecipeValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct ProviderWireToolCall: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var arguments: ProviderRecipeValue
    public var providerSignature: String?

    public init(id: String, name: String, arguments: ProviderRecipeValue, providerSignature: String? = nil) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.providerSignature = providerSignature
    }
}

public struct ProviderWireToolResult: Codable, Hashable, Sendable {
    public var callID: String
    public var name: String
    public var content: ProviderRecipeValue

    public init(callID: String, name: String, content: ProviderRecipeValue) {
        self.callID = callID
        self.name = name
        self.content = content
    }
}

/// One turn of a conversation in transport-neutral form: text, tool calls, a tool result, and
/// whatever opaque state the provider handed back and expects to see replayed. Each transport
/// builder reshapes this into its own message grammar.
public struct ProviderWireMessage: Codable, Hashable, Sendable {
    public var role: ProviderWireMessageRole
    public var text: String?
    public var toolCalls: [ProviderWireToolCall]
    public var toolResult: ProviderWireToolResult?
    public var providerContinuation: ProviderRecipeValue?

    public init(role: ProviderWireMessageRole, text: String) {
        self.init(role: role, text: text, toolCalls: [], toolResult: nil, providerContinuation: nil)
    }

    public init(
        role: ProviderWireMessageRole,
        text: String? = nil,
        toolCalls: [ProviderWireToolCall] = [],
        toolResult: ProviderWireToolResult? = nil,
        providerContinuation: ProviderRecipeValue? = nil
    ) {
        self.role = role
        self.text = text
        self.toolCalls = toolCalls
        self.toolResult = toolResult
        self.providerContinuation = providerContinuation
    }
}

public struct ProviderTextWireRequest: Hashable, Sendable {
    public var modelID: String
    public var messages: [ProviderWireMessage]
    public var tools: [ProviderWireTool]
    public var maxOutputTokens: Int64?

    public init(
        modelID: String,
        messages: [ProviderWireMessage],
        tools: [ProviderWireTool] = [],
        maxOutputTokens: Int64? = nil
    ) {
        self.modelID = modelID
        self.messages = messages
        self.tools = tools
        self.maxOutputTokens = maxOutputTokens
    }
}

public enum ProviderTextWireRequestError: Error, Equatable, Sendable {
    case unsupportedTransport(ProviderWireTransport)
    case missingMessages
    case missingMaxOutputTokens
    case invalidMaxOutputTokens
    case invalidMessage
    case encodingFailed
}

/// Builds the request body for each text transport.
///
/// `object` returns the body as a value tree rather than bytes, because capability recipes are
/// compiled onto it before it is encoded; `encode` is the last step once nothing else will
/// touch the request.
public enum ProviderTextWireRequestBuilder {
    public static func object(
        _ request: ProviderTextWireRequest,
        transport: ProviderWireTransport
    ) throws -> ProviderRecipeValue {
        guard !request.messages.isEmpty else { throw ProviderTextWireRequestError.missingMessages }
        if let max = request.maxOutputTokens, max <= 0 {
            throw ProviderTextWireRequestError.invalidMaxOutputTokens
        }
        let object: [String: Any]
        switch transport {
        case .openAIChat: object = try openAIChat(request)
        case .openAIResponses: object = try openAIResponses(request)
        case .anthropicMessages: object = try anthropicMessages(request)
        case .geminiGenerate: object = try geminiGenerate(request)
        default: throw ProviderTextWireRequestError.unsupportedTransport(transport)
        }
        guard JSONSerialization.isValidJSONObject(object),
              let value = ProviderRecipeValue.fromFoundation(object) else {
            throw ProviderTextWireRequestError.encodingFailed
        }
        return value
    }

    public static func encode(
        _ request: ProviderTextWireRequest,
        transport: ProviderWireTransport
    ) throws -> Data {
        try encode(object(request, transport: transport))
    }

    public static func encode(_ object: ProviderRecipeValue) throws -> Data {
        guard let fields = object.objectValue,
              JSONSerialization.isValidJSONObject(fields.mapValues(\.foundationValue)) else {
            throw ProviderTextWireRequestError.encodingFailed
        }
        return try JSONSerialization.data(withJSONObject: fields.mapValues(\.foundationValue), options: [.sortedKeys])
    }

    private static func openAIChat(_ request: ProviderTextWireRequest) throws -> [String: Any] {
        var body: [String: Any] = [
            "model": request.modelID,
            "messages": try request.messages.map(openAIChatMessage),
            "stream": true,
        ]
        if let max = request.maxOutputTokens { body["max_tokens"] = max }
        if !request.tools.isEmpty { body["tools"] = request.tools.map(openAIChatTool) }
        return body
    }

    private static func openAIChatMessage(_ message: ProviderWireMessage) throws -> [String: Any] {
        if let result = message.toolResult {
            return ["role": "tool", "tool_call_id": result.callID, "content": compactJSONString(result.content)]
        }
        var value: [String: Any] = ["role": message.role.rawValue, "content": message.text ?? ""]
        if !message.toolCalls.isEmpty {
            value["tool_calls"] = message.toolCalls.map { call in
                [
                    "id": call.id,
                    "type": "function",
                    "function": [
                        "name": ToolFunctionNameCodec.encode(call.name),
                        "arguments": compactJSONString(call.arguments),
                    ],
                ]
            }
        }
        if let reasoning = message.providerContinuation?.objectValue?["reasoning_content"]?.stringValue {
            value["reasoning_content"] = reasoning
        }
        return value
    }

    private static func openAIResponses(_ request: ProviderTextWireRequest) throws -> [String: Any] {
        let instructions = request.messages.filter { $0.role == .system }
            .compactMap(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        let previousResponseIndex = request.messages.lastIndex(where: {
            $0.providerContinuation?.objectValue?["previous_response_id"]?.stringValue != nil
        })
        // With `previous_response_id` the provider already holds everything up to that response,
        // so only the turns after it are resent - typically the tool outputs it is waiting for.
        // Resending the earlier turns would duplicate them against the stored state.
        let responseMessages = previousResponseIndex.map { Array(request.messages.suffix(from: request.messages.index(after: $0))) }
            ?? request.messages
        var input: [[String: Any]] = []
        for message in responseMessages where message.role != .system {
            if let result = message.toolResult {
                input.append(["type": "function_call_output", "call_id": result.callID,
                              "output": compactJSONString(result.content)])
            } else if !message.toolCalls.isEmpty {
                if let text = message.text, !text.isEmpty {
                    input.append(["role": "assistant", "content": [["type": "output_text", "text": text]]])
                }
                input.append(contentsOf: message.toolCalls.map { call in
                    ["type": "function_call", "call_id": call.id,
                     "name": ToolFunctionNameCodec.encode(call.name),
                     "arguments": compactJSONString(call.arguments)]
                })
            } else {
                let contentType = message.role == .assistant ? "output_text" : "input_text"
                input.append(["role": message.role.rawValue,
                              "content": [["type": contentType, "text": message.text ?? ""]]])
            }
        }
        var body: [String: Any] = ["model": request.modelID, "input": input, "stream": true]
        if !instructions.isEmpty { body["instructions"] = instructions }
        if let max = request.maxOutputTokens { body["max_output_tokens"] = max }
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { tool in
                ["type": "function", "name": ToolFunctionNameCodec.encode(tool.name),
                 "description": tool.description, "parameters": tool.inputSchema.foundationValue]
            }
        }
        if let previous = request.messages.compactMap({
            $0.providerContinuation?.objectValue?["previous_response_id"]?.stringValue
        }).last { body["previous_response_id"] = previous }
        return body
    }

    private static func anthropicMessages(_ request: ProviderTextWireRequest) throws -> [String: Any] {
        guard let max = request.maxOutputTokens else { throw ProviderTextWireRequestError.missingMaxOutputTokens }
        let system = request.messages.filter { $0.role == .system }
            .compactMap(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        var messages: [[String: Any]] = []
        for message in request.messages where message.role != .system {
            if let result = message.toolResult {
                messages.append(["role": "user", "content": [[
                    "type": "tool_result", "tool_use_id": result.callID,
                    "content": compactJSONString(result.content),
                ]]])
                continue
            }
            var blocks: [[String: Any]] = []
            if let continuation = message.providerContinuation?.objectValue,
               let thinking = continuation["thinking"]?.stringValue,
               let signature = continuation["signature"]?.stringValue {
                blocks.append(["type": "thinking", "thinking": thinking, "signature": signature])
            }
            if let text = message.text, !text.isEmpty { blocks.append(["type": "text", "text": text]) }
            blocks.append(contentsOf: message.toolCalls.map { call in
                ["type": "tool_use", "id": call.id, "name": ToolFunctionNameCodec.encode(call.name),
                 "input": call.arguments.foundationValue]
            })
            if blocks.isEmpty { blocks = [["type": "text", "text": ""]] }
            messages.append(["role": message.role.rawValue, "content": blocks])
        }
        var body: [String: Any] = ["model": request.modelID, "messages": messages,
                                   "max_tokens": max, "stream": true]
        if !system.isEmpty { body["system"] = system }
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { tool in
                ["name": ToolFunctionNameCodec.encode(tool.name), "description": tool.description,
                 "input_schema": tool.inputSchema.foundationValue]
            }
        }
        return body
    }

    private static func geminiGenerate(_ request: ProviderTextWireRequest) throws -> [String: Any] {
        let system = request.messages.filter { $0.role == .system }
            .compactMap(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        var contents: [[String: Any]] = []
        for message in request.messages where message.role != .system {
            var parts: [[String: Any]] = []
            if let result = message.toolResult {
                parts.append(["functionResponse": ["name": ToolFunctionNameCodec.encode(result.name),
                                                    "response": result.content.foundationValue]])
            } else {
                if let text = message.text, !text.isEmpty { parts.append(["text": text]) }
                parts.append(contentsOf: message.toolCalls.map { call in
                    var part: [String: Any] = ["functionCall": [
                        "name": ToolFunctionNameCodec.encode(call.name), "args": call.arguments.foundationValue,
                    ]]
                    if let signature = call.providerSignature
                        ?? message.providerContinuation?.objectValue?["thought_signature"]?.stringValue {
                        part["thoughtSignature"] = signature
                    }
                    return part
                })
            }
            guard !parts.isEmpty else { throw ProviderTextWireRequestError.invalidMessage }
            contents.append(["role": message.role == .assistant ? "model" : "user", "parts": parts])
        }
        var body: [String: Any] = ["contents": contents]
        if !system.isEmpty { body["systemInstruction"] = ["parts": [["text": system]]] }
        if let max = request.maxOutputTokens { body["generationConfig"] = ["maxOutputTokens": max] }
        if !request.tools.isEmpty {
            body["tools"] = [["functionDeclarations": request.tools.map { tool in
                ["name": ToolFunctionNameCodec.encode(tool.name), "description": tool.description,
                 "parameters": tool.inputSchema.foundationValue]
            }]]
        }
        return body
    }

    private static func openAIChatTool(_ tool: ProviderWireTool) -> [String: Any] {
        ["type": "function", "function": ["name": ToolFunctionNameCodec.encode(tool.name),
                                             "description": tool.description,
                                             "parameters": tool.inputSchema.foundationValue]]
    }

    private static func compactJSONString(_ value: ProviderRecipeValue) -> String {
        guard JSONSerialization.isValidJSONObject(["value": value.foundationValue]),
              let data = try? JSONSerialization.data(withJSONObject: value.foundationValue, options: [.sortedKeys])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
