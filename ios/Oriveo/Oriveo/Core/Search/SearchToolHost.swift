import Foundation

// MARK: - Tool-host table for ordinary chat (see the external search services contract)
//
// Port of scripts/lib/search-tool-host.mjs (same-named implementation on every platform): resolveSearchToolHost.
// The continuation step count is read from this platform's continuation table RequestPreferenceResolver.continuationSpecs (request_preference_contract.v2.json), not copied again.

nonisolated struct SearchToolHostInput: Sendable, Equatable {
    var path: WebSearchRoute.Path
    var library = false
    var mcp = false
    var memoryTools = false
    var nativeMoonshotLoop = false
    var serverMaxSteps: Int? = nil
    /// Raw value of RequestContinuationKind; an unknown value raises an error on the external_tool path.
    var continuationKind = RequestContinuationKind.toolLoop.rawValue
}

nonisolated struct SearchToolHost: Encodable, Sendable, Equatable {
    /// Consecutive-failure circuit breaker: off when MCP is attached, otherwise stop after N consecutive failures.
    enum Breaker: Encodable, Sendable, Equatable {
        case count(Int)
        case off

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .count(let value): try container.encode(value)
            case .off: try container.encode("off")
            }
        }
    }

    var host: String
    var tools: [String]
    var webSearchRegistered: Bool
    /// Non-external_tool path: the host is unchanged.
    var unchanged: Bool? = nil
    var maxSteps: Int? = nil
    var prompts: String? = nil
    var consecutiveFailureBreaker: Breaker? = nil
    var webSearchDisposition: String? = nil
    var writeToolConfirm: String? = nil
    var memoryTailLeg: String? = nil

    private enum CodingKeys: String, CodingKey {
        case host, tools, webSearchRegistered, unchanged, maxSteps, prompts
        case consecutiveFailureBreaker, webSearchDisposition, writeToolConfirm, memoryTailLeg
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(host, forKey: .host)
        try container.encode(tools, forKey: .tools)
        try container.encode(webSearchRegistered, forKey: .webSearchRegistered)
        try container.encodeIfPresent(unchanged, forKey: .unchanged)
        try container.encodeIfPresent(maxSteps, forKey: .maxSteps)
        try container.encodeIfPresent(prompts, forKey: .prompts)
        try container.encodeIfPresent(consecutiveFailureBreaker, forKey: .consecutiveFailureBreaker)
        try container.encodeIfPresent(webSearchDisposition, forKey: .webSearchDisposition)
        try container.encodeIfPresent(writeToolConfirm, forKey: .writeToolConfirm)
        try container.encodeIfPresent(memoryTailLeg, forKey: .memoryTailLeg)
    }
}

nonisolated enum SearchToolHostError: Error, Equatable {
    case unknownContinuationKind(String)

    var message: String {
        switch self {
        case .unknownContinuationKind(let kind): "unknown continuationKind: \(kind)"
        }
    }
}

nonisolated enum SearchToolHosts {
    /// Same convention as ToolCallLoop.Limits: effective value = min(server-provided, 8), default 6.
    static let loopLimits = (hardCap: 8, defaultMaxSteps: 6)

    /// Protocol rules for tools under thinking mode: tool_loop = tools can run while thinking is on; presearch = switch to pre-search when thinking is on.
    static let thinkingToolRules: [String: (thinkingWithTools: String, replay: String)] = [
        "openai_chat": ("presearch", "since GPT-5.4, Chat does not support tool calls when reasoning_effort is not none"),
        "openai_responses": ("tool_loop", "send back the reasoning item together with function_call / output; with store=false also send back encrypted_content"),
        "anthropic_messages": ("tool_loop", "send thinking / redacted_thinking blocks back unchanged, with their signature"),
        "gemini_generate_content": ("tool_loop", "put thoughtSignature back on the original part; needed at every step of this turn"),
        "deepseek_chat": ("tool_loop", "with tools, reasoning_content of all past turns must be sent back"),
        "moonshot_chat": ("tool_loop", "reasoning_content must be sent back; across turns it depends on the model"),
        "zhipu_chat": ("tool_loop", "send back reasoning_content within the loop; across turns it depends on clear_thinking"),
        "qwen_chat": ("tool_loop", "with preserve_thinking, history carries reasoning_content; tool_choice must not be required"),
    ]

    /// Neutral default copy for the loop when only search is on (memory tools allowed); when on together with library / MCP, that loop's existing copy is kept.
    static let hostPrompts: [String: String] = [
        "neutral": "tool_loop_stopped",
        "library": "research_stopped",
        "mcp": "tool_loop_stopped",
    ]

    static func resolveSearchToolHost(_ input: SearchToolHostInput) throws -> SearchToolHost {
        guard input.path == .externalTool else {
            let host = input.nativeMoonshotLoop && input.path == .native ? "moonshot_loop" : "none"
            return SearchToolHost(host: host, tools: [], webSearchRegistered: false, unchanged: true)
        }
        let server = input.serverMaxSteps.map { $0 > 0 ? min($0, loopLimits.hardCap) : loopLimits.defaultMaxSteps }
            ?? loopLimits.defaultMaxSteps
        guard let kind = RequestContinuationKind(rawValue: input.continuationKind),
              let continuation = RequestPreferenceResolver.continuationSpecs[kind]?.maxSteps else {
            throw SearchToolHostError.unknownContinuationKind(input.continuationKind)
        }
        var tools: [String] = []
        if input.library { tools.append("library") }
        if input.mcp { tools.append("mcp") }
        if input.memoryTools { tools.append("memory") }
        tools.append("web_search")
        return SearchToolHost(
            host: input.library || input.mcp ? "shared_tool_loop" : "generic_tool_loop",
            tools: tools,
            webSearchRegistered: true,
            maxSteps: min(server, continuation),
            prompts: input.library ? "library" : input.mcp ? "mcp" : "neutral",
            // Breaker is off when MCP is attached (see above); web_search failures are always fed back at the neutral level and do not count as consecutive failures
            consecutiveFailureBreaker: input.mcp ? .off : .count(3),
            webSearchDisposition: "neutral",
            // When web results are in this turn's context, MCP write tools are forced to "this time only" confirmation
            writeToolConfirm: input.mcp ? "once_when_web_results_present" : "n/a",
            // Memory tools enter the same loop and take one tool step, with no separate tail leg added
            memoryTailLeg: input.memoryTools ? "in_loop" : "n/a"
        )
    }
}
