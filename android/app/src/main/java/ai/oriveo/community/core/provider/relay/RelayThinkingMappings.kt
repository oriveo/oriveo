package ai.oriveo.community.core.provider.relay

import ai.oriveo.community.core.model.ReasoningMode

// Relay is where local reasoning-mode mappings are allowed to live: a user-supplied endpoint has no
// published capability profile to consult, so the mapping has to be hardcoded here rather than looked up.
internal fun ReasoningMode.relayOpenAIEffort(): String? = when (this) {
    ReasoningMode.Automatic -> null
    ReasoningMode.Fast -> "low"
    ReasoningMode.Balanced -> "medium"
    ReasoningMode.Deep -> "high"
    ReasoningMode.Max -> "xhigh"
}

// Anthropic-compatible custom endpoints have no published profile either, so they still need this local
// thinking fallback plus the self-healing retry that follows when the endpoint rejects the shape.
internal fun relayAnthropicThinkingJson(mode: ReasoningMode, modelID: String): String? {
    val lowered = modelID.lowercase()
    // heuristic-allow: Relay Anthropic-compatible fallback only; official Anthropic uses metadata profiles.
    val usesAdaptiveThinking = lowered.contains("sonnet-4-6") || lowered.contains("sonnet-4.6") ||
        // heuristic-allow: Relay Anthropic-compatible fallback only; official Anthropic uses metadata profiles.
        lowered.contains("opus-4-6") || lowered.contains("opus-4.6")

    if (usesAdaptiveThinking) {
        val effort = when (mode) {
            ReasoningMode.Automatic -> null
            ReasoningMode.Fast -> "low"
            ReasoningMode.Balanced -> "medium"
            ReasoningMode.Deep -> "high"
            // heuristic-allow: Relay Anthropic-compatible fallback only; official Anthropic uses metadata profiles.
            ReasoningMode.Max -> if (lowered.contains("opus")) "max" else "high"
        } ?: return null
        return """"thinking":{"type":"adaptive"},"output_config":{"effort":"$effort"}"""
    }

    val budget = when (mode) {
        ReasoningMode.Automatic -> null
        ReasoningMode.Fast -> 2_048
        ReasoningMode.Balanced -> 8_192
        ReasoningMode.Deep -> 16_384
        ReasoningMode.Max -> 24_576
    } ?: return null
    return """"thinking":{"type":"enabled","budget_tokens":$budget}"""
}

// Gemini-compatible custom endpoints likewise have to guess thinkingConfig from the model family name.
internal fun relayGeminiThinkingJson(mode: ReasoningMode, modelID: String): String? {
    if (mode == ReasoningMode.Automatic) return null
    // heuristic-allow: Relay Gemini-compatible fallback only; official Gemini uses metadata profiles.
    val usesLevel = modelID.lowercase().let { it.contains("3.1") || it.contains("gemini-3") }
    return if (usesLevel) {
        val level = when (mode) {
            ReasoningMode.Fast -> "LOW"
            ReasoningMode.Balanced -> "MEDIUM"
            ReasoningMode.Deep, ReasoningMode.Max -> "HIGH"
            ReasoningMode.Automatic -> null
        } ?: return null
        """"thinkingConfig":{"thinkingLevel":"$level"}"""
    } else {
        val budget = when (mode) {
            ReasoningMode.Fast -> 1_024
            ReasoningMode.Balanced -> 4_096
            ReasoningMode.Deep -> 16_384
            ReasoningMode.Max -> 24_576
            ReasoningMode.Automatic -> null
        } ?: return null
        """"thinkingConfig":{"thinkingBudget":$budget}"""
    }
}

internal fun relayChatCompletionsReasoningJson(mode: ReasoningMode): String? {
    val effort = when (mode) {
        ReasoningMode.Automatic -> null
        ReasoningMode.Fast -> "low"
        ReasoningMode.Balanced -> "medium"
        ReasoningMode.Deep, ReasoningMode.Max -> "high"
    } ?: return null
    return """"reasoning_effort":"$effort""""
}
