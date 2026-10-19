import Foundation

// WireAdapter: projects the same plan onto request-body fragments by protocol family.
// It owns only the system carrier, the message / block shapes, the single Anthropic cache breakpoint, and the position of the tool leg + host notice; other request fields such as model / stream /
// tool declarations / attachment parts belong to each Provider. The spec is the rules in `shared/context-contracts/wire-system.v1.json`,
// with the same API on every platform: project(plan, family, toolLeg?). Pure function, no I/O.

public enum ContextWireFamily: String, CaseIterable, Hashable, Sendable {
    case openaiChat = "openai_chat"
    case openaiChatStringOnly = "openai_chat_string_only"
    case free
    case llamacpp
    case managed
    case openaiResponses = "openai_responses"
    case anthropic
    case gemini

    /// Families that accept only string content: blocks are joined with "\n\n".
    var isStringOnly: Bool {
        switch self {
        case .openaiChatStringOnly, .free, .llamacpp: true
        default: false
        }
    }
}

public struct ContextWireBlock: Hashable, Sendable {
    public let kind: ContextBlockKind
    public let text: String

    public init(kind: ContextBlockKind, text: String) {
        self.kind = kind
        self.text = text
    }
}

public struct ContextWireMessage: Hashable, Sendable {
    public let role: ContextMessageRole
    public let blocks: [ContextWireBlock]

    public init(role: ContextMessageRole, blocks: [ContextWireBlock]) {
        self.role = role
        self.blocks = blocks
    }
}

/// WireAdapter looks only at the plan's system and messages.
public struct ContextWirePlan: Hashable, Sendable {
    public let system: String?
    /// nil for refused and image-generation plans.
    public let messages: [ContextWireMessage]?

    public init(system: String?, messages: [ContextWireMessage]?) {
        self.system = system
        self.messages = messages
    }

    public init(_ plan: ContextPlan) {
        self.system = plan.system
        self.messages = plan.messages?.map { message in
            ContextWireMessage(
                role: message.role,
                blocks: message.blocks.map { ContextWireBlock(kind: $0.kind, text: $0.text) }
            )
        }
    }
}

public struct ContextWireToolCall: Hashable, Sendable {
    public let id: String
    public let name: String
    /// The raw argument JSON text given by the model.
    public let arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct ContextWireToolResult: Hashable, Sendable {
    public let callId: String
    public let name: String
    public let output: String

    public init(callId: String, name: String, output: String) {
        self.callId = callId
        self.name = name
        self.output = output
    }
}

/// One leg of the host tool loop: the model's calls, the host's execution results, and an optional host notice (such as running out of steps).
/// Placed after the plan's last user message, using each family's native tool format via this API.
public struct ContextWireToolLeg: Hashable, Sendable {
    public let calls: [ContextWireToolCall]
    public let results: [ContextWireToolResult]
    public let notice: String?

    public init(calls: [ContextWireToolCall], results: [ContextWireToolResult], notice: String? = nil) {
        self.calls = calls
        self.results = results
        self.notice = notice
    }
}

public enum ContextWireAdapterError: Error, Equatable, Sendable {
    /// The plan has no sendable messages (a refused / image-generation plan).
    case noMessages
    /// This family does not send tools.
    case toolsUnsupported(ContextWireFamily)
    /// The tool arguments are not a JSON object (Anthropic input / Gemini args need a structured object).
    case invalidToolArguments(callId: String)
}

public enum ContextWireAdapter {
    public static func project(
        plan: ContextPlan,
        family: ContextWireFamily,
        toolLeg: ContextWireToolLeg? = nil
    ) throws -> ProviderRecipeValue {
        try project(plan: ContextWirePlan(plan), family: family, toolLeg: toolLeg)
    }

    public static func project(
        plan: ContextWirePlan,
        family: ContextWireFamily,
        toolLeg: ContextWireToolLeg? = nil
    ) throws -> ProviderRecipeValue {
        guard let messages = plan.messages, !messages.isEmpty else {
            throw ContextWireAdapterError.noMessages
        }
        if toolLeg != nil, family == .free {
            throw ContextWireAdapterError.toolsUnsupported(family)
        }
        switch family {
        case .openaiChat, .openaiChatStringOnly, .free, .llamacpp, .managed:
            return try chatShaped(plan.system, messages, family: family, toolLeg: toolLeg)
        case .openaiResponses:
            return try responses(plan.system, messages, toolLeg: toolLeg)
        case .anthropic:
            return try anthropic(plan.system, messages, toolLeg: toolLeg)
        case .gemini:
            return try gemini(plan.system, messages, toolLeg: toolLeg)
        }
    }

    // MARK: - Families

    private static func chatShaped(
        _ system: String?,
        _ messages: [ContextWireMessage],
        family: ContextWireFamily,
        toolLeg: ContextWireToolLeg?
    ) throws -> ProviderRecipeValue {
        var items: [ProviderRecipeValue] = []
        if let system {
            items.append(.object(["role": .string("system"), "content": .string(system)]))
        }
        for message in messages {
            let content: ProviderRecipeValue = family.isStringOnly
                ? .string(joined(message.blocks))
                : stringOrParts(message.blocks, partType: "text")
            items.append(.object(["role": .string(message.role.rawValue), "content": content]))
        }
        if let toolLeg {
            items.append(.object([
                "role": .string("assistant"),
                "content": .null,
                "tool_calls": .array(toolLeg.calls.map { call in
                    .object([
                        "id": .string(call.id),
                        "type": .string("function"),
                        "function": .object(["name": .string(call.name), "arguments": .string(call.arguments)]),
                    ])
                }),
            ]))
            for result in toolLeg.results {
                items.append(.object([
                    "role": .string("tool"),
                    "tool_call_id": .string(result.callId),
                    "content": .string(result.output),
                ]))
            }
            if let notice = toolLeg.notice {
                items.append(.object(["role": .string("user"), "content": .string(notice)]))
            }
        }
        return .object(["messages": .array(items)])
    }

    private static func responses(
        _ system: String?,
        _ messages: [ContextWireMessage],
        toolLeg: ContextWireToolLeg?
    ) throws -> ProviderRecipeValue {
        var input: [ProviderRecipeValue] = messages.map { message in
            // A Responses assistant message accepts only output_text parts.
            let partType = message.role == .assistant ? "output_text" : "input_text"
            return .object([
                "role": .string(message.role.rawValue),
                "content": stringOrParts(message.blocks, partType: partType),
            ])
        }
        if let toolLeg {
            input += toolLeg.calls.map { call in
                .object([
                    "type": .string("function_call"),
                    "call_id": .string(call.id),
                    "name": .string(call.name),
                    "arguments": .string(call.arguments),
                ])
            }
            input += toolLeg.results.map { result in
                .object([
                    "type": .string("function_call_output"),
                    "call_id": .string(result.callId),
                    "output": .string(result.output),
                ])
            }
            if let notice = toolLeg.notice {
                input.append(.object(["role": .string("user"), "content": .string(notice)]))
            }
        }
        var body: [String: ProviderRecipeValue] = ["input": .array(input)]
        if let system { body["instructions"] = .string(system) }
        return .object(body)
    }

    private static func anthropic(
        _ system: String?,
        _ messages: [ContextWireMessage],
        toolLeg: ContextWireToolLeg?
    ) throws -> ProviderRecipeValue {
        // The single breakpoint for the whole request: the last non-[D] block of the last user message in the request; fall back to the last block when there is no non-[D] block.
        // With a tool leg, the last user message is the tool_result turn, and the breakpoint lands on that turn's last block (the notice block when there is a notice).
        let lastUser = toolLeg == nil ? messages.lastIndex { $0.role == .user } : nil
        var items: [ProviderRecipeValue] = messages.enumerated().map { index, message in
            let breakpoint: Int? = index == lastUser
                ? (message.blocks.lastIndex { $0.kind != .dynamic } ?? message.blocks.indices.last)
                : nil
            let blocks: [ProviderRecipeValue] = message.blocks.enumerated().map { blockIndex, block in
                var value: [String: ProviderRecipeValue] = ["type": .string("text"), "text": .string(block.text)]
                if blockIndex == breakpoint {
                    value["cache_control"] = .object(["type": .string("ephemeral")])
                }
                return .object(value)
            }
            return .object(["role": .string(message.role.rawValue), "content": .array(blocks)])
        }
        if let toolLeg {
            let uses: [ProviderRecipeValue] = try toolLeg.calls.map { call in
                .object([
                    "type": .string("tool_use"),
                    "id": .string(call.id),
                    "name": .string(call.name),
                    "input": try argumentsObject(call),
                ])
            }
            items.append(.object(["role": .string("assistant"), "content": .array(uses)]))
            var turn: [ProviderRecipeValue] = toolLeg.results.map { result in
                .object([
                    "type": .string("tool_result"),
                    "tool_use_id": .string(result.callId),
                    "content": .string(result.output),
                ])
            }
            if let notice = toolLeg.notice {
                turn.append(.object(["type": .string("text"), "text": .string(notice)]))
            }
            if let last = turn.indices.last, case .object(var block) = turn[last] {
                block["cache_control"] = .object(["type": .string("ephemeral")])
                turn[last] = .object(block)
            }
            items.append(.object(["role": .string("user"), "content": .array(turn)]))
        }
        var body: [String: ProviderRecipeValue] = ["messages": .array(items)]
        if let system { body["system"] = .string(system) }
        return .object(body)
    }

    private static func gemini(
        _ system: String?,
        _ messages: [ContextWireMessage],
        toolLeg: ContextWireToolLeg?
    ) throws -> ProviderRecipeValue {
        var contents: [ProviderRecipeValue] = messages.map { message in
            .object([
                "role": .string(message.role == .assistant ? "model" : "user"),
                "parts": .array(message.blocks.map { .object(["text": .string($0.text)]) }),
            ])
        }
        if let toolLeg {
            let calls: [ProviderRecipeValue] = try toolLeg.calls.map { call in
                .object(["functionCall": .object(["name": .string(call.name), "args": try argumentsObject(call)])])
            }
            contents.append(.object(["role": .string("model"), "parts": .array(calls)]))
            var parts: [ProviderRecipeValue] = toolLeg.results.map { result in
                .object(["functionResponse": .object([
                    "name": .string(result.name),
                    "response": .object(["content": .string(result.output)]),
                ])])
            }
            if let notice = toolLeg.notice {
                parts.append(.object(["text": .string(notice)]))
            }
            contents.append(.object(["role": .string("user"), "parts": .array(parts)]))
        }
        var body: [String: ProviderRecipeValue] = ["contents": .array(contents)]
        if let system {
            body["systemInstruction"] = .object(["parts": .array([.object(["text": .string(system)])])])
        }
        return .object(body)
    }

    // MARK: - Block shapes

    /// A single block is a string; multiple blocks are text parts.
    private static func stringOrParts(_ blocks: [ContextWireBlock], partType: String) -> ProviderRecipeValue {
        if blocks.count == 1 { return .string(blocks[0].text) }
        return .array(blocks.map { .object(["type": .string(partType), "text": .string($0.text)]) })
    }

    private static func joined(_ blocks: [ContextWireBlock]) -> String {
        blocks.map(\.text).joined(separator: "\n\n")
    }

    /// Empty arguments are sent as an empty object (models often give "" for tools without parameters).
    private static func argumentsObject(_ call: ContextWireToolCall) throws -> ProviderRecipeValue {
        if ContextSanitizer.trimWhiteSpace(call.arguments).isEmpty { return .object([:]) }
        guard let data = call.arguments.data(using: .utf8),
              let value = try? JSONDecoder().decode(ProviderRecipeValue.self, from: data),
              case .object = value else {
            throw ContextWireAdapterError.invalidToolArguments(callId: call.id)
        }
        return value
    }
}
