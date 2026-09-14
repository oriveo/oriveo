import Foundation

enum ProviderLogoResolver {
    /// Inferring a relay's logo joins every enabled model's names and runs dozens of substring
    /// searches (about 10ms for 150 models), while the provider detail hero card reads it a dozen
    /// times per body and every providers write re-reads it. The cost sits in the system string
    /// search, so an optimized build is no faster. Remember the last inputs and result per provider
    /// and reuse them only when every input is equal; comparing `models` is O(1) while it still
    /// shares storage, and any content change recomputes.
    private struct Memo {
        let customName: String?
        let baseURLText: String?
        let relayKind: RelayKind?
        let models: [AIModel]
        let kind: ProviderKind

        func matches(_ provider: Provider) -> Bool {
            guard customName == provider.customName, baseURLText == provider.baseURLText else { return false }
            guard relayKind == provider.relayKind else { return false }
            return models == provider.models
        }
    }

    private static var memos: [UUID: Memo] = [:]
    private static let memoCapacity = 32

    #if DEBUG
    private static var computationCounts: [UUID: Int] = [:]

    /// DEBUG only: how many times a provider's logo was actually inferred (memo misses).
    static func computationCountForTesting(providerID: UUID) -> Int {
        computationCounts[providerID, default: 0]
    }
    #endif

    static func logoKind(for provider: Provider) -> ProviderKind {
        guard provider.kind == .relay else { return provider.kind }
        if let memo = memos[provider.id], memo.matches(provider) {
            return memo.kind
        }

        let kind = inferRelayLogoKind(for: provider)
        #if DEBUG
        computationCounts[provider.id, default: 0] += 1
        #endif
        if memos[provider.id] == nil, memos.count >= memoCapacity {
            memos.removeAll()
        }
        memos[provider.id] = Memo(
            customName: provider.customName,
            baseURLText: provider.baseURLText,
            relayKind: provider.relayKind,
            models: provider.models,
            kind: kind
        )
        return kind
    }

    /// Reads only displayName (for a relay it depends on customName and baseURLText), baseURLText,
    /// models and relayKind, which are exactly the fields `Memo.matches` compares. Change both
    /// together when adding an input.
    private static func inferRelayLogoKind(for provider: Provider) -> ProviderKind {
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
