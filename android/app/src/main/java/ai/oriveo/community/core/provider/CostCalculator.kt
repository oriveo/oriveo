package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import java.time.Instant

/**
 * Local cost estimate for a completed request.
 *
 * The client only ever multiplies and adds: every price and discount ratio comes from
 * the published model catalog, so it can be corrected without a client release.
 * Nothing here that can change over time should ever be hard coded.
 */
object CostCalculator {

    /**
     * Fallback multiplier for the Anthropic 5 minute cache write price, used when the
     * catalog carries no `cacheWrite5mPerMToken`: input x 1.25.
     * Anthropic's default cache TTL is 5 minutes, having previously been 1 hour.
     */
    private const val ANTHROPIC_CACHE_5M_MULTIPLIER = 1.25

    /** Fallback for the Anthropic 1 hour cache write price when the catalog carries no `cacheWrite1hPerMToken`: input x 2.0. */
    private const val ANTHROPIC_CACHE_1H_MULTIPLIER = 2.0

    /** Fallback for the cache read discount when the catalog carries no `cachedInputPerMToken`: input x 0.5, a conservative guess that beats pretending it is free. */
    private const val CACHED_READ_DEFAULT_MULTIPLIER = 0.5

    /**
     * Works out the cost and where the figure came from.
     *
     * Decision order:
     *   0. the request was paid for out of a subscription (a Grok subscription login):
     *      return `(0.0, SUBSCRIPTION)` without consulting any price table;
     *   1. the upstream reported an exact cost (OpenRouter, Grok): return
     *      `(upstreamCost, UPSTREAM)`;
     *   1.5 the metadata carries a per_token pricingV2: go through [PricingV2Estimator]
     *      ([at] is the pricing instant and can be injected);
     *      unavailable -> `(0.0, UNKNOWN)` (price unknown, never shown as 0); not_applicable
     *      falls through to the older path below;
     *   2. the catalog has no pricing for this model: return `(0.0, UNKNOWN)`;
     *   3. otherwise multiply and sum promptTokens / cachedInputTokens /
     *      cacheCreation5m and 1h / completionTokens per bucket and mark the result
     *      `LOCAL_ESTIMATE`.
     *
     * [isSubscription] has to be checked BEFORE the exact upstream figure: the CLI proxy
     * path still returns `cost_in_usd_ticks`, but that is what the request would have
     * cost at API list price, not what the user actually paid, which was a flat monthly
     * fee. Adopting it would show a subscription user a charge against every single
     * message that never happened.
     */
    fun calcCost(
        breakdown: UsageBreakdown,
        pricing: MetadataClient.ResolvedModelMetadata?,
        isSubscription: Boolean = false,
        at: Instant,
    ): Pair<Double, CostSource> {
        val estimate = estimate(breakdown, pricing, isSubscription, at)
        // A single entry only records USD: a non-USD estimate is not converted or recorded and counts as price unknown.
        if (estimate.currencyCode != USD) return 0.0 to CostSource.UNKNOWN
        return estimate.amount to estimate.source
    }

    /**
     * Estimates and also returns the currency: same decision order as [calcCost], but a non-USD price is still
     * computed, without conversion; the currency is that of the selected price (pricingV2 currencyCode, else the
     * model-level currencyCode), uppercase, USD when empty.
     * [units] is the unit count for per-unit pricing (per_image / per_second); unused for per-token pricing.
     */
    fun estimate(
        breakdown: UsageBreakdown,
        pricing: MetadataClient.ResolvedModelMetadata?,
        isSubscription: Boolean = false,
        at: Instant,
        units: Int = 1,
    ): CostEstimate {
        if (isSubscription) return CostEstimate(0.0, CostSource.SUBSCRIPTION, USD)

        // An exact figure from the upstream wins over anything we could compute.
        breakdown.upstreamCost?.let { return CostEstimate(it, CostSource.UPSTREAM, USD) }

        // When the legacy status is unknown (including no pricing) pricingV2 is not read and no number is estimated; only priced / free go through v2.
        if (pricing == null || pricing.pricingStatus == "unknown") return unknown()

        // Price v2: promptTokens is already the uncached input after subtracting cache, so it is used directly as uncachedInput.
        pricing.pricingV2?.let { v2 ->
            val usage = PricingV2Usage(
                uncachedInput = breakdown.promptTokens.toLong(),
                cacheRead = breakdown.cachedInputTokens.toLong(),
                cacheWrite5m = breakdown.cacheCreation5mTokens.toLong(),
                cacheWrite1h = breakdown.cacheCreation1hTokens.toLong(),
                output = breakdown.completionTokens.toLong(),
            )
            when (val estimate = PricingV2Estimator.estimate(v2, usage, at)) {
                is PricingV2Estimate.Estimated ->
                    return CostEstimate(estimate.amount, CostSource.LOCAL_ESTIMATE, normalizeCurrency(estimate.currencyCode))
                PricingV2Estimate.Unavailable -> return unknown()
                PricingV2Estimate.NotApplicable -> Unit
            }
        }

        val currency = normalizeCurrency(pricing.currencyCode)
        if (pricing.pricingStatus == "free") return CostEstimate(0.0, CostSource.LOCAL_ESTIMATE, currency)
        // Per-unit pricing: unit and unit price come from pricingV2 (unit / perUnit) first, the legacy single-tier fields only without v2.
        if ((pricing.pricingV2?.unit ?: pricing.pricingUnit) != "per_token") {
            // A missing unit price is recorded as unknown, not 0.
            val perUnit = pricing.pricingV2?.perUnit ?: pricing.costPerUnit ?: return unknown()
            return CostEstimate(perUnit * units, CostSource.LOCAL_ESTIMATE, currency)
        }

        val promptPerToken = pricing.promptPerToken ?: return unknown()
        val completionPerToken = pricing.completionPerToken ?: return unknown()

        // Discounted rates: take the catalog value when present, otherwise the fallback
        // multiplier. Catalog prices are per million tokens, hence the division.
        // Watch the naming: the catalog field `cachedInputPerMToken` surfaces on
        // ResolvedModelMetadata as `cacheReadInputPerMToken`, to line the read and write
        // names up with each other.
        val cachedReadPerToken = pricing.cacheReadInputPerMToken?.div(1_000_000)
            ?: (promptPerToken * CACHED_READ_DEFAULT_MULTIPLIER)
        // 5m write price: cacheWrite5m, else the older single cacheCreationInput field,
        // else input x 1.25.
        val cacheWrite5mPerToken = pricing.cacheWrite5mPerMToken?.div(1_000_000)
            ?: pricing.cacheCreationInputPerMToken?.div(1_000_000)
            ?: (promptPerToken * ANTHROPIC_CACHE_5M_MULTIPLIER)
        // 1h write price: cacheWrite1h, else input x 2.0. The older single field must not
        // be reused as the 1h price, which would badly underestimate it.
        val cacheWrite1hPerToken = pricing.cacheWrite1hPerMToken?.div(1_000_000)
            ?: (promptPerToken * ANTHROPIC_CACHE_1H_MULTIPLIER)

        val amount = bucketedCost(
            breakdown = breakdown,
            promptPerToken = promptPerToken,
            completionPerToken = completionPerToken,
            cachedReadPerToken = cachedReadPerToken,
            cacheWrite5mPerToken = cacheWrite5mPerToken,
            cacheWrite1hPerToken = cacheWrite1hPerToken,
        )
        return CostEstimate(amount, CostSource.LOCAL_ESTIMATE, currency)
    }

    private const val USD = "USD"

    private fun unknown() = CostEstimate(0.0, CostSource.UNKNOWN, USD)

    private fun normalizeCurrency(code: String?): String =
        code?.trim()?.uppercase()?.takeIf { it.isNotEmpty() } ?: USD

    /**
     * Bucketed estimate from the prices the model carries locally, which is the fallback
     * path for relay endpoints.
     *
     * A relay's models come from the user's own endpoint, so
     * `resolveCatalogModelAcrossProvidersWithProvider` finds nothing in the catalog and
     * [calcCost] returns `(0.0, UNKNOWN)`; the cost then falls back to whatever the
     * caller can work out. Doing that by simply multiplying `promptTokens`, which is the
     * total input INCLUDING cache, would overestimate cache-heavy requests by close to a
     * factor of two. So the fallback buckets the same way and reuses the same three
     * cache fallback ratios as the main path by going through [bucketedCost], rather
     * than growing a second copy of the formula.
     *
     * Unit trap: [AIModel.promptPrice] and [AIModel.completionPrice] are per token,
     * while the four cache prices are per million tokens. Mixing them up is off by 1e6.
     */
    fun calcCostFromLocalPricing(
        breakdown: UsageBreakdown,
        model: AIModel?,
    ): Pair<Double, CostSource> {
        breakdown.upstreamCost?.let { return it to CostSource.UPSTREAM }

        val promptPerToken = model?.promptPrice?.takeIf { it > 0.0 }
        val completionPerToken = model?.completionPrice?.takeIf { it > 0.0 }
        // Neither headline price is known, so the honest answer is UNKNOWN rather than a
        // made-up zero.
        if (promptPerToken == null && completionPerToken == null) return 0.0 to CostSource.UNKNOWN

        val inputRate = promptPerToken ?: 0.0
        return bucketedCost(
            breakdown = breakdown,
            promptPerToken = inputRate,
            completionPerToken = completionPerToken ?: 0.0,
            cachedReadPerToken = model.cacheReadInputPerMToken?.div(1_000_000)
                ?: (inputRate * CACHED_READ_DEFAULT_MULTIPLIER),
            cacheWrite5mPerToken = model.cacheWrite5mPerMToken?.div(1_000_000)
                ?: model.cacheCreationInputPerMToken?.div(1_000_000)
                ?: (inputRate * ANTHROPIC_CACHE_5M_MULTIPLIER),
            cacheWrite1hPerToken = model.cacheWrite1hPerMToken?.div(1_000_000)
                ?: (inputRate * ANTHROPIC_CACHE_1H_MULTIPLIER),
        ) to CostSource.LOCAL_ESTIMATE
    }

    /** The five-bucket multiply and sum. This is the only place the formula lives, so both paths change together. */
    private fun bucketedCost(
        breakdown: UsageBreakdown,
        promptPerToken: Double,
        completionPerToken: Double,
        cachedReadPerToken: Double,
        cacheWrite5mPerToken: Double,
        cacheWrite1hPerToken: Double,
    ): Double =
        breakdown.promptTokens * promptPerToken +
            breakdown.cachedInputTokens * cachedReadPerToken +
            breakdown.cacheCreation5mTokens * cacheWrite5mPerToken +
            breakdown.cacheCreation1hTokens * cacheWrite1hPerToken +
            breakdown.completionTokens * completionPerToken
}

/** One estimate: [amount] is in [currencyCode] (uppercase ISO 4217), not converted; when [source] is UNKNOWN the price is unknown (shown as unavailable). */
data class CostEstimate(
    val amount: Double,
    val source: CostSource,
    val currencyCode: String,
)
