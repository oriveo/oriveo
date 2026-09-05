import Foundation
import OriveoProviderKit


nonisolated enum ToolJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: ToolJSONValue])
    case array([ToolJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([ToolJSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: ToolJSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

nonisolated struct ToolLoopToolDefinition: Codable, Equatable, Sendable {
    struct Function: Codable, Equatable, Sendable {
        var name: String
        var description: String
        var parameters: ToolJSONValue
    }

    var type = "function"
    var function: Function
}

nonisolated struct ToolLoopToolCall: Codable, Equatable, Sendable {
    struct Function: Codable, Equatable, Sendable {
        var name: String
        var arguments: String
    }

    var id: String
    var type = "function"
    var function: Function
    var providerSignature: String?

    init(id: String, type: String = "function", function: Function, providerSignature: String? = nil) {
        self.id = id
        self.type = type
        self.function = function
        self.providerSignature = providerSignature
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, function
    }
}

nonisolated struct ToolLoopMessage: Codable, Equatable, Sendable {
    struct ContentPart: Codable, Equatable, Sendable {
        struct ImageURL: Codable, Equatable, Sendable {
            var url: String
            var detail: String?
        }

        var type: String
        var text: String?
        var imageURL: ImageURL?

        private enum CodingKeys: String, CodingKey {
            case type, text
            case imageURL = "image_url"
        }
    }

    var role: String
    var content: String?
    var contentParts: [ContentPart]?
    var reasoningContent: String?
    var toolCalls: [ToolLoopToolCall]?
    var toolCallID: String?
    var name: String?
    var providerReplayBlocks: [ToolJSONValue]?
    var providerAssistantReplay: ToolJSONValue?

    init(
        role: String,
        content: String? = nil,
        contentParts: [ContentPart]? = nil,
        reasoningContent: String? = nil,
        toolCalls: [ToolLoopToolCall]? = nil,
        toolCallID: String? = nil,
        name: String? = nil,
        providerReplayBlocks: [ToolJSONValue]? = nil,
        providerAssistantReplay: ToolJSONValue? = nil
    ) {
        self.role = role
        self.content = content
        self.contentParts = contentParts
        self.reasoningContent = reasoningContent
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.name = name
        self.providerReplayBlocks = providerReplayBlocks
        self.providerAssistantReplay = providerAssistantReplay
    }

    var plainText: String {
        if let content { return content }
        return contentParts?.compactMap { $0.type == "text" ? $0.text : nil }.joined() ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case role, content, name
        case reasoningContent = "reasoning_content"
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(String.self, forKey: .role)
        content = try? container.decodeIfPresent(String.self, forKey: .content)
        contentParts = content == nil
            ? try? container.decodeIfPresent([ContentPart].self, forKey: .content)
            : nil
        reasoningContent = try container.decodeIfPresent(String.self, forKey: .reasoningContent)
        toolCalls = try container.decodeIfPresent([ToolLoopToolCall].self, forKey: .toolCalls)
        toolCallID = try container.decodeIfPresent(String.self, forKey: .toolCallID)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        providerReplayBlocks = nil
        providerAssistantReplay = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        if let contentParts {
            try container.encode(contentParts, forKey: .content)
        } else {
            try container.encodeIfPresent(content, forKey: .content)
        }
        try container.encodeIfPresent(reasoningContent, forKey: .reasoningContent)
        try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
        try container.encodeIfPresent(name, forKey: .name)
    }
}

nonisolated enum ToolLoopToolChoice: String, Codable, Sendable {
    case auto
    case none
}

nonisolated struct ToolLoopLegRequest: Codable, Equatable, Sendable {
    var messages: [ToolLoopMessage]
    var tools: [ToolLoopToolDefinition]
    var toolChoice: ToolLoopToolChoice
}

nonisolated struct ToolLoopUsage: Codable, Equatable, Sendable {
    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokens: Int?

    var resolvedTotalTokens: Int {
        max(totalTokens ?? 0, (promptTokens ?? 0) + (completionTokens ?? 0))
    }

    func merging(_ other: ToolLoopUsage?) -> ToolLoopUsage {
        guard let other else { return self }
        func sum(_ left: Int?, _ right: Int?) -> Int? {
            left == nil && right == nil ? nil : (left ?? 0) + (right ?? 0)
        }
        return ToolLoopUsage(
            promptTokens: sum(promptTokens, other.promptTokens),
            completionTokens: sum(completionTokens, other.completionTokens),
            totalTokens: sum(totalTokens, other.totalTokens)
        )
    }

    static func merge(_ current: ToolLoopUsage?, _ next: ToolLoopUsage?) -> ToolLoopUsage? {
        guard let current else { return next }
        return current.merging(next)
    }
}

nonisolated struct ToolLoopToolCallDelta: Equatable, Sendable {
    var index: Int
    var id: String?
    var type: String?
    var name: String?
    var arguments: String?
    var providerSignature: String?

    init(index: Int, id: String? = nil, type: String? = nil, name: String? = nil, arguments: String? = nil, providerSignature: String? = nil) {
        self.index = index
        self.id = id
        self.type = type
        self.name = name
        self.arguments = arguments
        self.providerSignature = providerSignature
    }
}

nonisolated enum ToolLoopLegEvent: Equatable, Sendable {
    case textDelta(String)
    case reasoningDelta(String)
    case toolCallDeltas([ToolLoopToolCallDelta])
    case usage(ToolLoopUsage)
    case providerReplayBlocks([ToolJSONValue])
    case providerAssistantReplay(ToolJSONValue)
}

nonisolated protocol ToolLoopLegRunning: Sendable {
    func run(request: ToolLoopLegRequest) -> AsyncThrowingStream<ToolLoopLegEvent, Error>
}

/// Wire-level details each provider protocol contributes to a tool-calling leg:
/// where to send it, how to authenticate, and how to read usage and errors back.
nonisolated protocol ToolLoopLegWire: Sendable {
    var transportKind: TransportKind { get }
    var relayTransportKey: String { get }
    func officialEndpoint(providerKind: ProviderKind, userBaseURL: String?, modelID: String) throws -> URL
    func relayEndpointPath(modelID: String) -> String
    var streamQueryItems: [URLQueryItem] { get }
    func applyProtocolHeaders(to request: inout URLRequest)
    var officialAuthMode: RelayAuthMode { get }
    func requestBody(
        modelID: String,
        conversation: ToolProtocolConversation,
        tools: [Any]?,
        toolChoice: ToolLoopToolChoice,
        maxOutputTokens: Int?
    ) -> [String: Any]
    var injectsEventType: Bool { get }
    func usage(from frame: [String: Any], current: ToolLoopUsage?) -> ToolLoopUsage?
    func streamError(in frame: [String: Any]) -> ProviderServiceError?
}
