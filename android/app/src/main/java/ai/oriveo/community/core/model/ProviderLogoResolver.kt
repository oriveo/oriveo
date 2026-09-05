package ai.oriveo.community.core.model

fun resolveProviderLogoKind(provider: Provider): ProviderKind {
    if (provider.kind != ProviderKind.Relay) return provider.kind

    val hints = buildList {
        add(provider.displayName)
        provider.baseUrlText?.let(::add)
        provider.models.forEach { model ->
            model.groupKey?.let(::add)
            model.groupName?.let(::add)
            add(model.id)
            add(model.name)
        }
    }.joinToString(" ").lowercase()

    if (hints.isEmpty()) return provider.relayKind?.let(::relayKindLogoKind) ?: ProviderKind.Relay

    fun has(vararg needles: String): Boolean = needles.any { hints.contains(it) }

    return when {
        has("kimi", "moonshot", "moonshot.ai", "moonshot.cn") -> ProviderKind.Moonshot
        has("grok", "xai", "x.ai") -> ProviderKind.Grok
        
        has("mistral", "mixtral", "codestral", "magistral", "devstral", "ministral", "pixtral") -> ProviderKind.Mistral
        has("openrouter") -> ProviderKind.OpenRouter
        has("openai", "gpt", "chatgpt") || has(" o1", " o3", " o4") -> ProviderKind.OpenAI
        has("anthropic", "claude") -> ProviderKind.Anthropic
        has("gemini", "google", "generativelanguage") -> ProviderKind.Gemini
        has("deepseek") -> ProviderKind.DeepSeek
        has("qwen", "dashscope", "aliyun", "alibaba") -> ProviderKind.Qwen
        has("groq") -> ProviderKind.Groq
        has("together") -> ProviderKind.Together
        has("fireworks") -> ProviderKind.Fireworks
        has("minimax", "minimaxi") -> ProviderKind.MiniMax
        has("zhipu", "z.ai", "bigmodel", "glm") -> ProviderKind.Zhipu
        has("siliconflow") -> ProviderKind.SiliconFlow
        else -> provider.relayKind?.let(::relayKindLogoKind) ?: ProviderKind.Relay
    }
}

private fun relayKindLogoKind(relayKind: RelayKind): ProviderKind? = when (relayKind) {
    RelayKind.OpenAICompatible,
    RelayKind.CodexStyle,
    -> ProviderKind.OpenAI
    RelayKind.AnthropicCompatible -> ProviderKind.Anthropic
    RelayKind.GeminiCompatible -> ProviderKind.Gemini
    RelayKind.Custom -> null
}
