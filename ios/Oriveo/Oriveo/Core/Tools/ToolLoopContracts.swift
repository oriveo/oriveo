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

        /// A Chat Completions native file block (`file_data` is a data URI). Only the OpenRouter leg carries it.
        struct File: Codable, Equatable, Sendable {
            var filename: String
            var fileData: String

            private enum CodingKeys: String, CodingKey {
                case filename
                case fileData = "file_data"
            }
        }

        var type: String
        var text: String?
        var imageURL: ImageURL?
        var file: File? = nil

        private enum CodingKeys: String, CodingKey {
            case type, text, file
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
    /// Whether every merged leg reported usage: when any leg lacks usage, the cost of the whole message is unknown.
    var allLegsReported: Bool = true
    /// The breakdown this leg produced through the same usage parser as the provider's normal chat (cache buckets, upstream-reported
    /// actual cost such as OpenRouter `usage.cost` / Grok ticks). A merged total does not carry it, each leg is in `legs`; nil = token counts only.
    var breakdown: UsageBreakdown? = nil
    /// Every merged leg (per-leg pricing); empty = this is a single leg itself.
    var legs: [ToolLoopUsage] = []

    private enum CodingKeys: String, CodingKey {
        case promptTokens, completionTokens, totalTokens, allLegsReported, breakdown, legs
    }

    /// Usage of one leg: token counts come from the breakdown of the normal chat parser (input = uncached + cache read + cache write), and the breakdown travels with the leg for per-leg pricing.
    static func leg(_ breakdown: UsageBreakdown) -> ToolLoopUsage {
        let input = breakdown.totalInputTokens
        return ToolLoopUsage(
            promptTokens: input,
            completionTokens: breakdown.completionTokens,
            totalTokens: input + breakdown.completionTokens,
            breakdown: breakdown
        )
    }

    /// The per-leg usages used for per-leg pricing: a single leg is itself.
    var perLeg: [ToolLoopUsage] {
        legs.isEmpty ? [self] : legs
    }

    /// Placeholder for a leg whose upstream reported no usage: carries no tokens and marks "not all reported".
    static let unreported = ToolLoopUsage(allLegsReported: false)

    var resolvedTotalTokens: Int {
        max(totalTokens ?? 0, (promptTokens ?? 0) + (completionTokens ?? 0))
    }

    /// Whether it carries any token count (for progress reporting; an unreported placeholder carries none).
    var hasTokenCounts: Bool {
        promptTokens != nil || completionTokens != nil || totalTokens != nil
    }

    /// Adds two parts; a nil `other` means that part reported no usage.
    func merging(_ other: ToolLoopUsage?) -> ToolLoopUsage {
        let other = other ?? .unreported
        func sum(_ left: Int?, _ right: Int?) -> Int? {
            left == nil && right == nil ? nil : (left ?? 0) + (right ?? 0)
        }
        return ToolLoopUsage(
            promptTokens: sum(promptTokens, other.promptTokens),
            completionTokens: sum(completionTokens, other.completionTokens),
            totalTokens: sum(totalTokens, other.totalTokens),
            allLegsReported: allLegsReported && other.allLegsReported,
            legs: perLeg + other.perLeg
        )
    }

    /// Merges two complete usages (MCP first leg + resend): a nil part means that part reported no usage.
    static func merge(_ current: ToolLoopUsage?, _ next: ToolLoopUsage?) -> ToolLoopUsage {
        (current ?? .unreported).merging(next)
    }

    /// Per-leg accumulation of the tool loop: a nil `accumulated` means there is no leg yet; a nil `leg` means this leg reported no usage.
    static func accumulate(_ accumulated: ToolLoopUsage?, leg: ToolLoopUsage?) -> ToolLoopUsage {
        guard let accumulated else { return leg ?? .unreported }
        return accumulated.merging(leg)
    }

    /// The whole message can be priced: at least one leg and every leg reported usage.
    static func reported(_ usage: ToolLoopUsage?) -> Bool {
        usage?.allLegsReported == true
    }
}

nonisolated extension ToolLoopUsage {
    /// The old shape has no allLegsReported: read as all reported.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            promptTokens: try container.decodeIfPresent(Int.self, forKey: .promptTokens),
            completionTokens: try container.decodeIfPresent(Int.self, forKey: .completionTokens),
            totalTokens: try container.decodeIfPresent(Int.self, forKey: .totalTokens),
            allLegsReported: try container.decodeIfPresent(Bool.self, forKey: .allLegsReported) ?? true,
            breakdown: try container.decodeIfPresent(UsageBreakdown.self, forKey: .breakdown),
            legs: try container.decodeIfPresent([ToolLoopUsage].self, forKey: .legs) ?? []
        )
    }
}

nonisolated extension ToolLoopUsage {
    /// The usage object in an openai_chat leg SSE frame -> usage of this leg: goes through the same usage parser as the provider's normal
    /// chat: OpenRouter carries `usage.cost`, Grok carries `cost_in_usd_ticks`, DeepSeek cache hit / miss, Moonshot top-level
    /// `cached_tokens`, and the rest (including Relay) use the OpenAI standard `prompt_tokens_details.cached_tokens`.
    static func openAIChatLeg(usageJSON: [String: Any], providerKind: ProviderKind) -> ToolLoopUsage? {
        let breakdown: UsageBreakdown?
        switch providerKind {
        case .openRouter:
            breakdown = OpenRouterService.legUsageBreakdown(usageJSON: usageJSON)
        case .grok:
            breakdown = GrokService.legUsageBreakdown(usageJSON: usageJSON)
        case .deepseek:
            breakdown = OpenAICompatibleStreamState.legUsageBreakdown(usageJSON: usageJSON, profile: .deepSeek)
        case .moonshot:
            breakdown = OpenAICompatibleStreamState.legUsageBreakdown(usageJSON: usageJSON, profile: .moonshot)
        case .qwen:
            breakdown = QwenService.legUsageBreakdown(usageJSON: usageJSON)
        default:
            breakdown = OpenAIService.legUsageBreakdown(usageJSON: usageJSON)
        }
        return breakdown.map(ToolLoopUsage.leg)
    }

    /// The usage object in one openai_chat leg frame: Groq puts usage in `x_groq.usage`, so that is taken first and the top-level `usage` is the fallback
    /// (same as the normal GroqService chat); Moonshot (Kimi) puts usage in `choices[0].usage` and it is read when the top level is missing
    /// (the same parsing as normal chat); every other provider takes the top-level `usage`.
    static func openAIChatLegUsageJSON(chunk: [String: Any], providerKind: ProviderKind) -> [String: Any]? {
        if providerKind == .groq,
           let groqUsage = (chunk["x_groq"] as? [String: Any])?["usage"] as? [String: Any] {
            return groqUsage
        }
        if let usage = chunk["usage"] as? [String: Any] { return usage }
        guard providerKind == .moonshot else { return nil }
        return (chunk["choices"] as? [[String: Any]])?.first?["usage"] as? [String: Any]
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
    /// Stream-end info of this leg: handed out when the leg finishes; the tool loop records the stopReason of the last leg.
    case finish(StreamFinish)
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
