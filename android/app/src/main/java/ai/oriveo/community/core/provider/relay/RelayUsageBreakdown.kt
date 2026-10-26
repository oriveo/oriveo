package ai.oriveo.community.core.provider.relay

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.CostCalculator
import ai.oriveo.community.core.provider.CostSource
import ai.oriveo.community.core.provider.RelayRuntimeSupport
import ai.oriveo.community.core.provider.UsageBreakdown
import java.time.Instant
import kotlinx.serialization.Serializable

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

/** Relay usage parse result: [usageReported] = whether the response carried a usage object. The parser decides it; the exit path does not re-judge. */
internal data class RelayParsedUsage(val breakdown: UsageBreakdown, val usageReported: Boolean)

/**
 * Usage of an Anthropic Messages non-streaming response -> pricing breakdown + whether usage was returned.
 * The exit path and the contract tests both go through here; when the 5m cache write has no nested tier it falls back to the outer cache_creation_input_tokens (older responses).
 */
internal fun relayAnthropicUsage(usage: RelayAnthropicUsage?): RelayParsedUsage =
    RelayParsedUsage(
        breakdown = anthropicUsageBreakdown(
            inputTokens = usage?.input_tokens,
            outputTokens = usage?.output_tokens,
            cacheReadInputTokens = usage?.cache_read_input_tokens,
            cacheCreation5mInputTokens = usage?.cache_creation?.ephemeral_5m_input_tokens ?: usage?.cache_creation_input_tokens,
            cacheCreation1hInputTokens = usage?.cache_creation?.ephemeral_1h_input_tokens,
        ),
        usageReported = usage != null,
    )

/** Relay Anthropic Messages non-streaming response (only the body and usage are decoded). */
@Serializable
internal data class RelayAnthropicResponse(
    val content: List<RelayAnthropicContent>? = null,
    val usage: RelayAnthropicUsage? = null,
) {
    val resolvedText: String
        get() = content.orEmpty()
            .filter { it.type == "text" }
            .mapNotNull { it.text }
            .joinToString("")
}

@Serializable
internal data class RelayAnthropicContent(
    val type: String? = null,
    val text: String? = null,
)

@Serializable
internal data class RelayAnthropicUsage(
    val input_tokens: Int? = null,
    val output_tokens: Int? = null,
    val cache_read_input_tokens: Int? = null,
    val cache_creation_input_tokens: Int? = null,
    val cache_creation: RelayAnthropicCacheCreation? = null,
)

@Serializable
internal data class RelayAnthropicCacheCreation(
    val ephemeral_5m_input_tokens: Int? = null,
    val ephemeral_1h_input_tokens: Int? = null,
)

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

/**
 * Relay service-layer pricing: when an official catalog entry matches, it goes through the same entry as the official services, [CostCalculator.calcCost]
 * (actual upstream cost > pricingV2 > legacy single-tier price, USD only). When the matched entry is not USD this is unknown, and the delivery layer
 * [ai.oriveo.community.core.provider.DeliveredCostResolver.resolve] records it in the original currency via the same [CostCalculator.estimate]. When nothing matches, the delivery layer falls back to the local unit price.
 * [at] is the pricing moment (time-of-day pricing is chosen by it), injected by the caller (production passes the moment the response was received); no wall clock is read here.
 */
internal fun computeRelayCost(
    modelID: String,
    canonicalModelId: String?,
    transport: RelayTransport,
    breakdown: UsageBreakdown,
    at: Instant,
    metadata: MetadataClient = MetadataClient.instance,
): Pair<Double, CostSource> {
    return CostCalculator.calcCost(breakdown, relayCatalogMatch(modelID, canonicalModelId, transport, metadata)?.metadata, at = at)
}

/**
 * Cross-family catalog match used for relay pricing: the family of the actual transport goes first (the service-layer [computeRelayCost] and the delivery-layer
 * [ai.oriveo.community.core.provider.DeliveredCostResolver] share this one place, so two separate matches cannot pick different catalog prices).
 * When [transport] is null (unknown), [RelayTransport.Auto] is used. See [relayOfficialMatch] for the matching rules.
 */
internal fun relayCatalogMatch(
    modelID: String,
    canonicalModelId: String?,
    transport: RelayTransport?,
    metadata: MetadataClient = MetadataClient.instance,
): MetadataClient.RelayCatalogMatchResult? =
    relayOfficialMatch(
        modelID = modelID,
        canonicalModelId = canonicalModelId,
        // Same priority family as capability inheritance (RelayRuntimeSupport.transportProviderKind, reads transportRules).
        transportPriority = RelayRuntimeSupport.transportProviderKind(
            transport ?: RelayTransport.Auto,
            metadata.relayRuntimeConfig(),
        ),
        metadata = metadata,
    )

/**
 * The single entry for matching a relay model to the official catalog (shared by pricing, unit-price labels and official capability inheritance): first by the model's [canonicalModelId],
 * then, if absent or not found, by [modelID] (canonicalModelId is used only for pricing and official capability inheritance).
 * [transportPriority] is the official family preferred during the cross-family scan.
 */
internal fun relayOfficialMatch(
    modelID: String,
    canonicalModelId: String?,
    transportPriority: ProviderKind?,
    metadata: MetadataClient = MetadataClient.instance,
): MetadataClient.RelayCatalogMatchResult? {
    val canonical = canonicalModelId?.trim()?.takeIf { it.isNotEmpty() }
    return canonical?.let { metadata.resolveCatalogModelAcrossProvidersWithProvider(it, transportPriority) }
        ?: metadata.resolveCatalogModelAcrossProvidersWithProvider(modelID, transportPriority)
}
