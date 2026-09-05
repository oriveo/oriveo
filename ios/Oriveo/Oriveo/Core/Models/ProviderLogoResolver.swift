import Foundation

enum ProviderLogoResolver {
    static func logoKind(for provider: Provider) -> ProviderKind {
        guard provider.kind == .relay else { return provider.kind }

        let hints = ([provider.displayName, provider.baseURLText] + provider.models.flatMap { model in
            [model.groupKey, model.groupName, model.id, model.name]
        })
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()

        if hints.isEmpty {
            return provider.relayKind.flatMap(logoKind(for:)) ?? .relay
        }

        if containsAny(hints, ["kimi", "moonshot", "moonshot.ai", "moonshot.cn"]) { return .moonshot }
        if containsAny(hints, ["grok", "xai", "x.ai"]) { return .grok }
        if containsAny(hints, ["mistral", "mixtral", "codestral", "magistral", "devstral", "ministral", "pixtral"]) { return .mistral }
        if containsAny(hints, ["openrouter"]) { return .openRouter }
        if containsAny(hints, ["openai", "gpt", "chatgpt"]) || containsAny(hints, [" o1", " o3", " o4"]) { return .openAI }
        if containsAny(hints, ["anthropic", "claude"]) { return .anthropic }
        if containsAny(hints, ["gemini", "google", "generativelanguage"]) { return .gemini }
        if containsAny(hints, ["deepseek"]) { return .deepseek }
        if containsAny(hints, ["qwen", "dashscope", "aliyun", "alibaba"]) { return .qwen }
        if containsAny(hints, ["groq"]) { return .groq }
        if containsAny(hints, ["together"]) { return .together }
        if containsAny(hints, ["fireworks"]) { return .fireworks }
        if containsAny(hints, ["minimax", "minimaxi"]) { return .miniMax }
        if containsAny(hints, ["zhipu", "z.ai", "bigmodel", "glm"]) { return .zhipu }
        if containsAny(hints, ["siliconflow"]) { return .siliconFlow }
        if containsAny(hints, ["oriveo"]) { return .openAI }

        return provider.relayKind.flatMap(logoKind(for:)) ?? .relay
    }

    private static func logoKind(for relayKind: RelayKind) -> ProviderKind? {
        switch relayKind {
        case .openaiCompatible, .codexStyle:
            return .openAI
        case .anthropicCompatible:
            return .anthropic
        case .geminiCompatible:
            return .gemini
        case .custom:
            return nil
        }
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }
}
