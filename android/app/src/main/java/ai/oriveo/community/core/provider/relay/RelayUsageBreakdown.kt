package ai.oriveo.community.core.provider.relay

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.CostCalculator
import ai.oriveo.community.core.provider.CostSource
import ai.oriveo.community.core.provider.UsageBreakdown

/*
 * Breakdown builders for relay responses. Every one of them has to carry an explicit observation
 * flag, because the question we are answering is whether the upstream reported the raw field at
 * all, not whether the number it reported was large. Check for the presence of the field first and
 * read the value second; collapsing it with `?: 0` before the observability decision destroys the
 * distinction. Without the flag, an upstream that honestly reports `cached_tokens: 0` degrades into
 * "field missing" once UsageBreakdown.reportedCachedInputTokens applies its `it > 0` test, and the
 * cache row disappears from the usage card entirely. The per-provider services such as
 * OpenAIService already set these flags, so a relay that skips them would report usage by a
 * different standard than everything else in the app.
 */

internal fun openAIChatUsageBreakdown(
    promptTokens: Int,
    completionTokens: Int,
    cachedInputTokens: Int?,
    reasoningTokens: Int?,
): UsageBreakdown {
    val cached = cachedInputTokens ?: 0
    return UsageBreakdown(
        promptTokens = (promptTokens - cached).coerceAtLeast(0),
        cachedInputTokens = cached,
        completionTokens = completionTokens,
        reasoningTokens = reasoningTokens ?: 0,
        cacheReadObserved = cachedInputTokens != null,
    )
}

internal fun openAIResponsesUsageBreakdown(
    inputTokens: Int?,
    outputTokens: Int?,
    cachedInputTokens: Int?,
    reasoningTokens: Int?,
): UsageBreakdown {
    val cached = cachedInputTokens ?: 0
    val input = inputTokens ?: 0
    return UsageBreakdown(
        promptTokens = (input - cached).coerceAtLeast(0),
        cachedInputTokens = cached,
        completionTokens = outputTokens ?: 0,
        reasoningTokens = reasoningTokens ?: 0,
        cacheReadObserved = cachedInputTokens != null,
    )
}

internal fun anthropicUsageBreakdown(
    inputTokens: Int?,
    outputTokens: Int?,
    cacheReadInputTokens: Int?,
    cacheCreation5mInputTokens: Int?,
    cacheCreation1hInputTokens: Int?,
): UsageBreakdown {
    return UsageBreakdown(
        promptTokens = inputTokens ?: 0,
        cachedInputTokens = cacheReadInputTokens ?: 0,
        cacheCreation5mTokens = cacheCreation5mInputTokens ?: 0,
        cacheCreation1hTokens = cacheCreation1hInputTokens ?: 0,
        completionTokens = outputTokens ?: 0,
        reasoningTokens = 0,
        cacheReadObserved = cacheReadInputTokens != null,
        // Either path counts as "cache write observed": older Anthropic responses only return the
        // top-level cache_creation_input_tokens, which the caller attributes to the 5m tier, while
        // newer ones return a nested cache_creation object split into the 5m and 1h buckets.
        cacheWriteObserved = cacheCreation5mInputTokens != null || cacheCreation1hInputTokens != null,
    )
}

internal fun geminiUsageBreakdown(
    promptTokenCount: Int?,
    candidatesTokenCount: Int?,
    thoughtsTokenCount: Int?,
    cachedContentTokenCount: Int?,
): UsageBreakdown {
    val cached = cachedContentTokenCount ?: 0
    val promptTotal = promptTokenCount ?: 0
    val candidates = candidatesTokenCount ?: 0
    val thoughts = thoughtsTokenCount ?: 0
    return UsageBreakdown(
        promptTokens = (promptTotal - cached).coerceAtLeast(0),
        cachedInputTokens = cached,
        completionTokens = candidates + thoughts,
        reasoningTokens = thoughts,
        cacheReadObserved = cachedContentTokenCount != null,
    )
}

internal fun computeRelayCost(
    modelID: String,
    transport: RelayTransport,
    breakdown: UsageBreakdown,
    metadata: MetadataClient = MetadataClient.instance,
): Pair<Double, CostSource> {
    val matched = metadata.resolveCatalogModelAcrossProvidersWithProvider(
        modelID = modelID,
        transportPriority = relayCostPriorityProviderKind(transport),
    )
    return CostCalculator.calcCost(breakdown, matched?.metadata)
}

internal fun estimateRelayCost(
    modelID: String,
    transport: RelayTransport,
    promptTokens: Int,
    completionTokens: Int,
    metadata: MetadataClient = MetadataClient.instance,
): Double {
    val matched = metadata.resolveCatalogModelAcrossProvidersWithProvider(
        modelID = modelID,
        transportPriority = relayCostPriorityProviderKind(transport),
    ) ?: return 0.0
    return metadata.estimateCost(
        modelID = modelID,
        providerKind = matched.matchedProviderKind,
        promptTokens = promptTokens,
        completionTokens = completionTokens,
    )
}

internal fun relayCostPriorityBackendKey(transport: RelayTransport): String =
    when (relayCostPriorityProviderKind(transport)) {
        ProviderKind.OpenAI -> "openAI"
        ProviderKind.Anthropic -> "anthropic"
        ProviderKind.Gemini -> "gemini"
        else -> "openAI"
    }

private fun relayCostPriorityProviderKind(transport: RelayTransport): ProviderKind =
    when (transport) {
        RelayTransport.LlamaCppNative,
        RelayTransport.OpenAIChatCompletions,
        RelayTransport.OpenAIResponses,
        RelayTransport.Auto -> ProviderKind.OpenAI
        RelayTransport.AnthropicMessages -> ProviderKind.Anthropic
        RelayTransport.GeminiGenerateContent -> ProviderKind.Gemini
    }
