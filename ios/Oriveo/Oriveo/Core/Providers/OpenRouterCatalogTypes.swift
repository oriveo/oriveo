import Foundation

enum OpenRouterVendorName {
    static func displayName(for groupKey: String) -> String {
        switch groupKey {
        case "openai":        return "OpenAI"
        case "anthropic":     return "Anthropic"
        case "google":        return "Google"
        case "meta":          return "Meta"
        case "mistralai":     return "Mistral"
        case "deepseek":      return "DeepSeek"
        case "x-ai":          return "xAI"
        case "qwen":          return "Qwen"
        case "perplexity":    return "Perplexity"
        case "moonshotai":    return "Moonshot AI"
        case "microsoft":     return "Microsoft"
        case "nvidia":        return "NVIDIA"
        case "bytedance-seed": return "ByteDance Seed"
        case "openrouter":    return "OpenRouter"
        default:
            return groupKey
                .replacingOccurrences(of: "-", with: " ")
                .split(separator: " ")
                .map { String($0).capitalized }
                .joined(separator: " ")
        }
    }
}

enum SiliconFlowVendorName {
    static func displayName(for groupKey: String) -> String {
        switch groupKey {
        case "openai": return "OpenAI"
        case "anthropic": return "Anthropic"
        case "google": return "Google"
        case "deepseek", "deepseek-ai": return "DeepSeek"
        case "meta", "meta-llama": return "Meta"
        case "perplexity": return "Perplexity"
        case "qwen": return "Qwen"
        case "zai", "z-ai", "zai-org", "thudm": return "Z.ai / GLM"
        case "stepfun", "stepfun-ai": return "StepFun"
        case "tencent": return "Tencent"
        case "bytedance", "bytedance-seed": return "ByteDance"
        case "kwai", "kwai-kolors": return "Kwai"
        case "nex-agi": return "NEX"
        default:
            return groupKey
                .replacingOccurrences(of: "-", with: " ")
                .split(separator: " ")
                .map { String($0).capitalized }
                .joined(separator: " ")
        }
    }
}

