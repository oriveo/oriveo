import Foundation

// The stopReason closed set and the mapping of each protocol family's termination signal; spec is the rules in `shared/context-contracts/stop-reason.v1.json`.

/// The persisted stopReason closed set; rawValue is the fixture enum text verbatim, and the CaseIterable order matches the fixture.
public enum StopReason: String, Codable, Hashable, Sendable, CaseIterable {
    case stop
    case length
    case contentFilter = "content_filter"
    case tool
    case contextWindowExceeded = "context_window_exceeded"
    case interrupted
    case incomplete
    case error
    case unknown

    /// Reading from the store: null stays null (old rows did not record it), and an unrecognized string is recorded as unknown.
    public static func fromStored(_ raw: String?) -> StopReason? {
        guard let raw else { return nil }
        return StopReason(rawValue: raw) ?? .unknown
    }
}

/// Protocol families that produce a termination signal.
public enum StopFamily: String, Codable, Hashable, Sendable, CaseIterable {
    case openaiChat = "openai_chat"
    case openaiResponses = "openai_responses"
    case anthropic
    case gemini
    case managed
    case free
    /// Gemini Interactions API: finishRaw is the interaction status of the terminal event.
    case geminiInteractions = "gemini_interactions"
    /// llama.cpp native /completion: finishRaw is the stop_type of the last frame.
    case llamaCpp = "llama_cpp"
}

/// How the stream ended.
public enum StreamEnding: String, Codable, Hashable, Sendable, CaseIterable {
    /// The family's termination marker was seen.
    case clean
    case eofWithoutMarker = "eof_without_marker"
    case errorFrame = "error_frame"
    case transportError = "transport_error"
    case userCancelled = "user_cancelled"
}

public enum StopReasonResolver {
    /// Item by item identical to the fixture mapping.
    public static let mapping: [StopFamily: [String: StopReason]] = [
        .openaiChat: [
            "stop": .stop,
            "length": .length,
            "content_filter": .contentFilter,
            "tool_calls": .tool,
            "function_call": .tool,
        ],
        .openaiResponses: [
            "completed": .stop,
            "incomplete:max_output_tokens": .length,
            "incomplete:content_filter": .contentFilter,
            "failed": .error,
        ],
        .anthropic: [
            "end_turn": .stop,
            "stop_sequence": .stop,
            "max_tokens": .length,
            "tool_use": .tool,
            "pause_turn": .incomplete,
            "refusal": .contentFilter,
            "model_context_window_exceeded": .contextWindowExceeded,
        ],
        .gemini: [
            "STOP": .stop,
            "MAX_TOKENS": .length,
            "SAFETY": .contentFilter,
            "RECITATION": .contentFilter,
            "BLOCKLIST": .contentFilter,
            "PROHIBITED_CONTENT": .contentFilter,
            "SPII": .contentFilter,
            "IMAGE_SAFETY": .contentFilter,
            "IMAGE_PROHIBITED_CONTENT": .contentFilter,
            "IMAGE_RECITATION": .contentFilter,
            "LANGUAGE": .contentFilter,
            "ESCALATION": .contentFilter,
            "PUP_LIMITED_DISABLED": .contentFilter,
            "CONTINUATION": .length,
            "MALFORMED_FUNCTION_CALL": .error,
            "MALFORMED_RESPONSE": .error,
            "MISSING_THOUGHT_SIGNATURE": .error,
            "UNEXPECTED_TOOL_CALL": .error,
            "TOO_MANY_TOOL_CALLS": .error,
            "OTHER": .unknown,
            "FINISH_REASON_UNSPECIFIED": .unknown,
            "IMAGE_OTHER": .unknown,
            "NO_IMAGE": .unknown,
        ],
        .managed: Dictionary(uniqueKeysWithValues: StopReason.allCases.filter { $0 != .interrupted }.map { ($0.rawValue, $0) }),
        .free: [
            "stop": .stop,
            "length": .length,
            "content_filter": .contentFilter,
            "tool_calls": .tool,
        ],
        .geminiInteractions: [
            "completed": .stop,
            "incomplete": .length,
            "requires_action": .tool,
            "failed": .error,
        ],
        .llamaCpp: [
            "eos": .stop,
            "word": .stop,
            "limit": .length,
        ],
    ]

    private static let responsesIncompletePrefix = "incomplete:"
    private static let geminiBlockReasonPrefix = "blockReason:"
    private static let geminiBlockReasonUnspecified = "BLOCK_REASON_UNSPECIFIED"

    /// User cancel -> interrupted; transport error / error frame -> incomplete if there is body text, otherwise error;
    /// disconnect without a termination marker -> incomplete (even if a finish value was seen earlier); a normal end looks up the mapping, defaulting to unknown.
    public static func resolve(family: StopFamily, ended: StreamEnding, finishRaw: String?, hadContent: Bool) -> StopReason {
        switch ended {
        case .userCancelled:
            return .interrupted
        case .transportError, .errorFrame:
            return hadContent ? .incomplete : .error
        case .eofWithoutMarker:
            return .incomplete
        case .clean:
            guard let finishRaw else { return .unknown }
            // generateContent prompt blocked: decided by rule, not through the mapping; an unused value is unknown, and everything else (including future new values) is content_filter.
            if family == .gemini, finishRaw.hasPrefix(geminiBlockReasonPrefix) {
                let value = finishRaw.dropFirst(geminiBlockReasonPrefix.count)
                return value == geminiBlockReasonUnspecified ? .unknown : .contentFilter
            }
            if let mapped = mapping[family]?[finishRaw] {
                return mapped
            }
            // status=incomplete, with or without a reason, records incomplete for anything not listed separately (unified across platforms).
            if family == .openaiResponses,
               finishRaw == "incomplete" || finishRaw.hasPrefix(responsesIncompletePrefix) {
                return .incomplete
            }
            return .unknown
        }
    }

    /// finishRaw when the generateContent prompt is blocked: "blockReason:" + promptFeedback.blockReason.
    public static func geminiBlockReasonFinishRaw(_ blockReason: String) -> String {
        geminiBlockReasonPrefix + blockReason
    }

    /// finishRaw of the llama.cpp last frame: stop_type first; older servers without stop_type are mapped from stopped_eos / stopped_word / stopped_limit, otherwise none.
    public static func llamaCppFinishRaw(stopType: String?, stoppedEos: Bool, stoppedWord: Bool, stoppedLimit: Bool) -> String {
        if let stopType, !stopType.isEmpty { return stopType }
        if stoppedEos { return "eos" }
        if stoppedWord { return "word" }
        if stoppedLimit { return "limit" }
        return "none"
    }

    /// finishRaw for Responses: status; only when status == "incomplete" and incomplete_details.reason is present
    /// is it joined as "incomplete:" + reason (consistent with Android / Web; completed with a reason is still completed).
    public static func responsesFinishRaw(status: String, incompleteReason: String?) -> String {
        guard status == "incomplete", let incompleteReason else { return status }
        return responsesIncompletePrefix + incompleteReason
    }
}
