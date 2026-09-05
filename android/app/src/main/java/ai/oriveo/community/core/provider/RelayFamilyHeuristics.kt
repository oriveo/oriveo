package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.RelayKind

enum class RelayModelFamily {
    OpenAI,
    Anthropic,
    Google,
    DeepSeek,
    Qwen,
    XAI,
    Meta,
    Mistral,
}

object RelayFamilyHeuristics {
    private val patterns = listOf(
        RelayModelFamily.OpenAI to Regex("^(?:gpt-|o[134](?:\\b|-)|chatgpt|dall-e|whisper|tts-|gpt-image|text-embedding)"),
        RelayModelFamily.Anthropic to Regex("^claude-"),
        RelayModelFamily.Google to Regex("^(gemini|imagen|text-bison|palm)"),
        RelayModelFamily.DeepSeek to Regex("^(deepseek|ds-)"),
        RelayModelFamily.Qwen to Regex("^(qwen|qwq)"),
        RelayModelFamily.XAI to Regex("^grok"),
        RelayModelFamily.Meta to Regex("^(llama|codellama)"),
        RelayModelFamily.Mistral to Regex("^(mistral|mixtral|codestral)"),
    )

    fun infer(modelId: String?): RelayModelFamily? {
        val normalized = modelId?.trim()?.lowercase().orEmpty()
        if (normalized.isEmpty()) return null
        return patterns.firstNotNullOfOrNull { (family, regex) ->
            family.takeIf { regex.containsMatchIn(normalized) }
        }
    }

    fun compatibleRelayKinds(family: RelayModelFamily?): List<RelayKind> = when (family) {
        RelayModelFamily.OpenAI -> listOf(RelayKind.OpenAICompatible, RelayKind.CodexStyle)
        RelayModelFamily.Anthropic -> listOf(RelayKind.AnthropicCompatible)
        RelayModelFamily.Google -> listOf(RelayKind.GeminiCompatible)
        RelayModelFamily.DeepSeek,
        RelayModelFamily.Qwen,
        RelayModelFamily.XAI,
        RelayModelFamily.Meta,
        RelayModelFamily.Mistral,
        null,
        -> emptyList()
    }

    fun suggestedRelayKind(family: RelayModelFamily?): RelayKind? = when (family) {
        RelayModelFamily.OpenAI -> RelayKind.OpenAICompatible
        RelayModelFamily.Anthropic -> RelayKind.AnthropicCompatible
        RelayModelFamily.Google -> RelayKind.GeminiCompatible
        RelayModelFamily.DeepSeek,
        RelayModelFamily.Qwen,
        RelayModelFamily.XAI,
        RelayModelFamily.Meta,
        RelayModelFamily.Mistral,
        null,
        -> null
    }
}
