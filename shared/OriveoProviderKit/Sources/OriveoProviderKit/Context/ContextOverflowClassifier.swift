import Foundation

// Context overflow detection; spec is the rules in `shared/context-contracts/overflow-errors.v1.json`:
// structured code first; 413 is always an overflow; message regexes apply only to 400 and are grouped by protocol family.

/// Protocol families used for overflow detection; one more than StopFamily: openai_compatible.
public enum OverflowFamily: String, Codable, Hashable, Sendable, CaseIterable {
    case openaiChat = "openai_chat"
    case openaiResponses = "openai_responses"
    case openaiCompatible = "openai_compatible"
    case anthropic
    case gemini
    case managed
    case free

    /// Regex group name; providers that expose only structured codes recognize just the code and have no group.
    public var patternGroup: String? {
        switch self {
        case .openaiChat, .openaiResponses, .openaiCompatible: return "openai_compatible"
        case .anthropic: return "anthropic"
        case .gemini: return "gemini"
        case .managed, .free: return nil
        }
    }
}

public enum OverflowVia: String, Codable, Hashable, Sendable, CaseIterable {
    case code
    case typeRegex = "type+regex"
    case statusRegex = "status+regex"
    case status413
}

public struct ContextOverflowResult: Codable, Hashable, Sendable {
    public var overflow: Bool
    public var via: OverflowVia?

    public init(overflow: Bool, via: OverflowVia?) {
        self.overflow = overflow
        self.via = via
    }

    public static let notOverflow = ContextOverflowResult(overflow: false, via: nil)
}

public enum ContextOverflowClassifier {
    /// Initial regex groups, verbatim equal to the fixture patterns; extraPatterns is currently always empty, and the remote-added key is not yet decided.
    public static let defaultPatterns: [String: String] = [
        "openai_compatible": "(?i)(maximum context length|context length (is|of)|context window|exceeds? the (model'?s? )?(maximum )?context|prompt is too long|too many tokens in (the )?(prompt|input|messages)|exceeded model token limit|reduce the length of the (messages|prompt|input))",
        "anthropic": "(?i)(prompt is too long|input length and `?max_tokens`? exceed context limit)",
        "gemini": "(?i)(input token count.*exceeds the maximum number of tokens|exceeds the maximum number of tokens allowed)",
    ]

    /// defaultPatterns compiled once and cached.
    private static let compiledDefaults: [String: NSRegularExpression] = defaultPatterns.compactMapValues(compile)

    /// Strips a leading `(?i)` and compiles case-insensitively; returns nil when compilation fails (the caller skips it).
    private static func compile(_ pattern: String) -> NSRegularExpression? {
        let body = pattern.hasPrefix("(?i)") ? String(pattern.dropFirst(4)) : pattern
        return try? NSRegularExpression(pattern: body, options: [.caseInsensitive])
    }

    /// body is the raw response body string; when it is not JSON only 413 is considered.
    public static func classify(
        family: OverflowFamily,
        status: Int,
        body: String,
        extraPatterns: [String: [String]] = [:]
    ) -> ContextOverflowResult {
        if status == 401 || status == 429 || status >= 500 {
            return .notOverflow
        }
        let object = parseObject(body)
        if let object, hasOverflowCode(object) {
            return ContextOverflowResult(overflow: true, via: .code)
        }
        if status == 413 {
            return ContextOverflowResult(overflow: true, via: .status413)
        }
        guard status == 400, let object, let group = family.patternGroup, let message = message(in: object) else {
            return .notOverflow
        }
        if family == .anthropic {
            let errorType = (object["error"] as? [String: Any])?["type"] as? String
            guard errorType == "invalid_request_error" else { return .notOverflow }
        }
        guard matches(message, group: group, extraPatterns: extraPatterns[group] ?? []) else {
            return .notOverflow
        }
        return ContextOverflowResult(overflow: true, via: family == .anthropic ? .typeRegex : .statusRegex)
    }

    /// Overflow at the stopReason level: only context_window_exceeded (an in-stream Anthropic signal).
    public static func isOverflow(_ stopReason: StopReason?) -> Bool {
        stopReason == .contextWindowExceeded
    }

    private static func parseObject(_ body: String) -> [String: Any]? {
        guard let data = body.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func hasOverflowCode(_ object: [String: Any]) -> Bool {
        let error = object["error"] as? [String: Any]
        if error?["code"] as? String == "context_length_exceeded" { return true }
        if object["code"] as? String == "CONTEXT_LENGTH_EXCEEDED" { return true }
        if let code = object["code"] as? NSNumber, !(object["code"] is Bool), code.intValue == 40022 { return true }
        if (object["data"] as? [String: Any])?["reason"] as? String == "free_context_length_exceeded" { return true }
        return false
    }

    private static func message(in object: [String: Any]) -> String? {
        if let message = (object["error"] as? [String: Any])?["message"] as? String { return message }
        return object["message"] as? String
    }

    private static func matches(_ message: String, group: String, extraPatterns: [String]) -> Bool {
        let range = NSRange(message.startIndex..., in: message)
        let regexes = [compiledDefaults[group]].compactMap { $0 } + extraPatterns.compactMap(compile)
        return regexes.contains { $0.firstMatch(in: message, range: range) != nil }
    }
}
