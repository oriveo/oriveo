package ai.oriveo.community.core.provider.relay

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.provider.RelayRuntimeSupport

/**
 * Relay reasoning tiers (relay x reasoning rules; fixture `shared/test-fixtures/relay/reasoning-tier.v1.json`).
 *
 * - Auto set = the `reasoningEfforts` of Server model-facts mapped through [EFFORT_MAP] (tier order fast/balanced/deep/max, de-duplicated, unknown words ignored).
 *   Family: a family matched by the official catalog takes priority, otherwise the cached by-model family (no fetching, no guessing from the id); if none -> empty.
 * - Tier rejection = a tier was sent, 400 / 422 before any output, and the error body names the reasoning parameter ([REJECTION_TOKENS]).
 * - Settling = first downward, then upward; with no tier, no reasoning field is sent; the panel, in-send resend and later outbound requests share [fallback].
 */
object RelayReasoningTiers {
    val TIERS: List<String> = listOf("fast", "balanced", "deep", "max")

    private val EFFORT_MAP: Map<String, String> = mapOf(
        "low" to "fast",
        "medium" to "balanced",
        "high" to "deep",
        "xhigh" to "max",
        "max" to "max",
    )

    private val REJECTION_TOKENS: List<String> = listOf(
        "reasoning", "thinking", "effort", "budget_tokens",
        "thinkingconfig", "thinkingbudget", "thinkinglevel", "enable_thinking",
    )

    /** Server by-model family -> the official provider in the model-facts keys. */
    private val FAMILY_KINDS: Map<String, ProviderKind> = mapOf(
        "openai" to ProviderKind.OpenAI,
        "anthropic" to ProviderKind.Anthropic,
        "google" to ProviderKind.Gemini,
        "deepseek" to ProviderKind.DeepSeek,
        "xai" to ProviderKind.Grok,
        "qwen" to ProviderKind.Qwen,
        "mistral" to ProviderKind.Mistral,
        "minimax" to ProviderKind.MiniMax,
        "zhipu" to ProviderKind.Zhipu,
        "moonshot" to ProviderKind.Moonshot,
    )

    fun tiers(efforts: List<String>): List<ReasoningMode> {
        val mapped = efforts.mapNotNull { EFFORT_MAP[it.trim().lowercase()] }.toSet()
        return TIERS.filter(mapped::contains).mapNotNull(::mode)
    }

    /** Auto tier set for the relay shape; local engine connections do not come here (still per the write-path table). */
    fun automaticTiers(provider: Provider, model: AIModel, metadata: MetadataClient = MetadataClient.instance): List<ReasoningMode> {
        if (!provider.relayRequested?.engineProfile.isNullOrBlank()) return emptyList()
        // Same match entry as pricing / capability inheritance: canonicalModelId first, then the id.
        val match = relayOfficialMatch(
            modelID = model.id.trim(),
            canonicalModelId = model.canonicalModelId,
            transportPriority = RelayRuntimeSupport.transportProviderKind(provider, model),
            metadata = metadata,
        )
        val kind = match?.matchedProviderKind
            // Reads only the cached by-model family, sends no request for it and does not guess from the id text.
            ?: ai.oriveo.community.core.data.remote.RelayModelFamilyLookup.shared.cachedFamily(model.id)
                ?.let { FAMILY_KINDS[it.lowercase()] }
            ?: return emptyList()
        val canonical = (match?.canonicalModelId ?: model.canonicalModelId)?.trim()?.takeIf { it.isNotEmpty() }
        // Canonical first, same as pricing / capability inheritance: look up the canonical id, then the original id.
        val facts = canonical?.let { metadata.modelFacts(kind, it) } ?: metadata.modelFacts(kind, model.id)
        return tiers(facts?.reasoningEfforts.orEmpty())
    }

    fun bodyNamesThinking(body: String?): Boolean {
        val lowered = body?.lowercase() ?: return false
        return REJECTION_TOKENS.any(lowered::contains)
    }

    /** The rejected tier = [sentTier], or null (404 / 415 are left to transport fallback; 5xx / 401 / 429 are not capability evidence). */
    fun classify(status: Int, bodyNamesThinking: Boolean, sentTier: String?, outputStarted: Boolean): String? {
        if (sentTier == null || sentTier !in TIERS || outputStarted) return null
        if (status != 400 && status != 422) return null
        return sentTier.takeIf { bodyNamesThinking }
    }

    fun classify(status: Int, body: String?, sentTier: String?, outputStarted: Boolean): String? =
        classify(status, bodyNamesThinking(body), sentTier, outputStarted)

    /** If [selected] was not rejected return it as is; otherwise the nearest non-rejected tier (downward first, then upward); null if none (no reasoning field). Auto / off pass through unchanged. */
    fun fallback(available: List<String>, rejected: Set<String>, selected: String?): String? {
        if (selected == null || selected !in TIERS || selected !in rejected) return selected
        val order = TIERS.indexOf(selected)
        val candidates = TIERS.filter { it in available && it !in rejected }
        return candidates.lastOrNull { TIERS.indexOf(it) < order }
            ?: candidates.firstOrNull { TIERS.indexOf(it) > order }
    }

    fun mode(tier: String): ReasoningMode? = ReasoningMode.entries.firstOrNull { it.rawValue == tier && it != ReasoningMode.Automatic }
}
