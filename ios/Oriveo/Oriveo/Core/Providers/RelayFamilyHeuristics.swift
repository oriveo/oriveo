import Foundation


enum RelayModelFamily: String, CaseIterable, Hashable, Sendable {
    case openai
    case anthropic
    case google
    case deepseek
    case qwen
    case xai
    case meta
    case mistral
}

enum RelayFamilyHeuristics {

    private static let patterns: [(RelayModelFamily, String)] = [
        (.openai, "^(?:gpt-|o[134](?:\\b|-)|chatgpt|dall-e|whisper|tts-|gpt-image|text-embedding)"),
        (.anthropic, "^claude-"),
        (.google, "^(gemini|imagen|text-bison|palm)"),
        (.deepseek, "^(deepseek|ds-)"),
        (.qwen, "^(qwen|qwq)"),
        (.xai, "^grok"),
        (.meta, "^(llama|codellama)"),
        (.mistral, "^(mistral|mixtral|codestral)"),
    ]

    private static let compiled: [(RelayModelFamily, NSRegularExpression)] = patterns.compactMap { pair in
        guard let regex = try? NSRegularExpression(pattern: pair.1, options: []) else { return nil }
        return (pair.0, regex)
    }

    static func infer(modelID: String?) -> RelayModelFamily? {
        guard let raw = modelID else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let range = NSRange(location: 0, length: (trimmed as NSString).length)
        for (family, regex) in compiled {
            if regex.firstMatch(in: trimmed, options: [], range: range) != nil {
                return family
            }
        }
        return nil
    }

    static func compatibleRelayKinds(for family: RelayModelFamily?) -> Set<RelayKind> {
        guard let family else { return [] }
        switch family {
        case .anthropic: return [.anthropicCompatible]
        case .google: return [.geminiCompatible]
        case .openai: return [.openaiCompatible, .codexStyle]
        case .deepseek, .qwen, .xai, .meta, .mistral: return []
        }
    }

    static func suggestedRelayKind(for family: RelayModelFamily?) -> RelayKind? {
        guard let family else { return nil }
        switch family {
        case .anthropic: return .anthropicCompatible
        case .google: return .geminiCompatible
        case .openai: return .openaiCompatible
        case .deepseek, .qwen, .xai, .meta, .mistral: return nil
        }
    }
}
