package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CostFormatter
import ai.oriveo.community.core.model.ProviderChatResult
import ai.oriveo.community.core.model.ProviderKind

object DeliveredCostResolver {

    fun resolve(result: ProviderChatResult?, model: AIModel?, providerKind: ProviderKind): Double {
        val usage = result ?: return 0.0
        if (usage.estimatedCost > CostFormatter.COST_EPSILON) return usage.estimatedCost
        if (usage.promptTokens <= 0 && usage.completionTokens <= 0) return usage.estimatedCost

        val promptPrice = model?.promptPrice ?: 0.0
        val completionPrice = model?.completionPrice ?: 0.0
        if (promptPrice <= 0.0 && completionPrice <= 0.0) return usage.estimatedCost

        // The fallback has to bucket the tokens too. `usage.promptTokens` is the **total input
        // including cache** (RelayTransportCoordinator explicitly fills it as
        // input + cache_read + cache_create), so multiplying it by the full price nearly doubles
        // the estimate for a request that hits cache almost entirely; the cache-write side is
        // underestimated the same way (5m should be x1.25, 1h should be x2.0). Reusing
        // CostCalculator's coefficients keeps this consistent with the main path.
        val (cost, _) = CostCalculator.calcCostFromLocalPricing(usage.toBucketedBreakdown(), model)
        return cost
    }

    /**
     * Converts a [ProviderChatResult] from its display shape into the pricing shape of a
     * [UsageBreakdown]: `promptTokens` is the total input in the former, and **only the new,
     * uncached input** in the latter.
     */
    private fun ProviderChatResult.toBucketedBreakdown(): UsageBreakdown {
        val cacheRead = cachedInputTokens ?: 0
        val cache5m = cacheCreation5mTokens ?: 0
        val cache1h = cacheCreation1hTokens ?: 0
        return UsageBreakdown(
            promptTokens = (promptTokens - cacheRead - cache5m - cache1h).coerceAtLeast(0),
            cachedInputTokens = cacheRead,
            cacheCreation5mTokens = cache5m,
            cacheCreation1hTokens = cache1h,
            completionTokens = completionTokens,
        )
    }

    fun isUnknownPricing(result: ProviderChatResult?, model: AIModel?, providerKind: ProviderKind): Boolean {
        val usage = result ?: return false
        if (usage.estimatedCost > CostFormatter.COST_EPSILON) return false
        if (usage.promptTokens <= 0 && usage.completionTokens <= 0) return false
        val promptPrice = model?.promptPrice ?: 0.0
        val completionPrice = model?.completionPrice ?: 0.0
        return promptPrice <= 0.0 && completionPrice <= 0.0
    }
}
