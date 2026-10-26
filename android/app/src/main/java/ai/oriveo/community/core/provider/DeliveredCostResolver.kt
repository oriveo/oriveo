package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.CostFormatter
import ai.oriveo.community.core.model.NonUsdCost
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderChatResult
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RegionOption
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.relay.relayCatalogMatch
import ai.oriveo.community.core.provider.transport.OfficialEndpointSource
import ai.oriveo.community.core.util.DeterministicProviderId
import java.time.Instant

/**
 * A pricing part of one delivered message (generation / library retrieval): [amount] is in [currencyCode] (uppercase ISO 4217), not converted;
 * when [unknown] is true the price is unknown (shown as unavailable, not 0). [costSource] is a [CostSource] name (nullable for old data).
 */
data class DeliveredCost(
    val amount: Double,
    val currencyCode: String,
    val unknown: Boolean,
    val costSource: String?,
) {
    val isUsd: Boolean get() = currencyCode == DeliveredCostResolver.USD
}

/**
 * The cost persisted with one message: [estimatedCost] / [costSource] describe only the USD part (0 + UNKNOWN when there is none),
 * [nonUsdCost] is the single non-USD part. Every dollar consumer (conversation totals, usage reporting, budget) reads only [estimatedCost].
 */
data class MessageCostRecord(
    val estimatedCost: Double,
    val costSource: String?,
    val nonUsdCost: NonUsdCost?,
)

/**
 * The catalog price selected per connection: [selected] is the price of the effective region (the model level when no regional entry is selected), [currencyCode] is its uppercase currency,
 * [regionEntryChosen] says a regionPricing entry was chosen.
 */
data class ConnectionPricing(
    val selected: MetadataClient.ResolvedModelMetadata,
    val currencyCode: String,
    val regionEntryChosen: Boolean,
)

object DeliveredCostResolver {

    internal const val USD = "USD"

    /**
     * Selects the price by the connection's effective region at delivery and records the original currency.
     *
     * With a catalog price, first select via [RegionPricingSelector.select], then re-estimate with the token breakdown of [result] using [CostCalculator.estimate]
     * at [at] (the service-layer amount is not reused). A local [AIModel] unit price has no currency,
     * so falling back to it only happens when the selected currency is USD -- previously a non-USD estimate of 0 fell back to it and recorded a non-USD price as dollars.
     * Relay does not select a region; when it matches an official catalog it uses the same estimate entry as official messages, and a non-USD price is recorded in the matched entry's currency.
     * Relay catalog matching prefers the family of [relayTransport], the same function as the service layer.
     * Whether a local unit price can be the fallback when the catalog has no match: see [allowsLocalPriceWithoutCatalog] (same rule as Web allowsLocalPrice).
     * Once a catalog entry (official, or a Relay match to an official one) is matched there is no fallback to the local unit price: when the service layer produced no amount the selected entry is re-estimated,
     * and pricingV2 unavailable / legacy status unknown means the price is unknown.
     * Relay first matches the local model's canonicalModelId and then its id via [relayOfficialMatch] (fixture relay_matched_via_canonical_id).
     * When upstream returned no usage object the per-token part is recorded unknown, not 0; a usage object with all buckets 0 is a real 0.
     * Relay always re-estimates from the matched entry and never reuses the service-layer amount.
     * [at] is the pricing instant (time-of-day prices are selected by it), injected by the caller: production passes the delivery instant, tests pass the fixture instant, and the wall clock is not read here.
     * [units] is the actual unit count of the whole message for per-unit pricing (image count / seconds) ([producedUnits]); per-unit pricing with 0 units is recorded unknown.
     * A subscription connection ([Provider.authMode] = subscription) is recorded as subscription for the whole message and no leg is estimated.
     * A multi-leg result may become two currency parts, and delivery accounting goes through [resolveParts]; here a multi-leg result is returned as is only when it merges into a single part, otherwise it is recorded unknown.
     * Upstream actual cost ([CostSource.UPSTREAM]) is adopted as is, a reported 0 is a real 0 and is not topped up with local prices; Relay does not adopt upstream actual cost (the unit and currency of the
     * cost reported by an arbitrary relay cannot be trusted) and re-estimates from the matched entry / local unit price.
     * With a catalog entry it always re-estimates at the injected [at] and does not reuse the service-layer amount (the service layer estimates by wall clock).
     */
    fun resolve(
        result: ProviderChatResult?,
        model: AIModel?,
        provider: Provider,
        modelId: String,
        at: Instant,
        units: Int = 1,
        relayTransport: RelayTransport? = null,
        catalog: MetadataClient.ResolvedModelMetadata? =
            catalogModel(provider.kind, modelId, relayTransport, model?.canonicalModelId),
        regionOptions: List<RegionOption> = regionOptions(provider.kind),
    ): DeliveredCost {
        if (result?.legs?.let { it.size > 1 } == true) {
            val parts = resolveParts(result, model, provider, modelId, at, units, relayTransport, catalog, regionOptions)
            return parts.singleOrNull() ?: unknownPart(parts.first().currencyCode)
        }
        val kind = provider.kind
        subscriptionPart(provider)?.let { return it }
        // Upstream actual cost reported by a Relay is not adopted: wipe the service-layer amount and re-estimate from ordinary usage.
        val priced = if (kind == ProviderKind.Relay && result?.costSource == CostSource.UPSTREAM.name) {
            result.copy(estimatedCost = 0.0, costSource = CostSource.UNKNOWN.name)
        } else {
            result
        }
        val legacy = {
            val amount = resolve(priced, model, kind)
            val unknown = isUnknownPricing(priced, model, kind)
            // The service layer produced no price (UNKNOWN) but the local unit price fallback really computed an amount (> epsilon): the source is a local estimate, otherwise record would drop it as unknown.
            val source = when {
                unknown -> priced?.costSource
                priced?.costSource == CostSource.UNKNOWN.name && amount > CostFormatter.COST_EPSILON ->
                    CostSource.LOCAL_ESTIMATE.name
                else -> priced?.costSource
            }
            DeliveredCost(amount, USD, unknown, source)
        }
        val usage = priced ?: return legacy()
        // Subscription quota and upstream-computed costs are not re-priced from the catalog: the former was not paid per use, the latter is the actual dollar figure from upstream.
        if (usage.costSource == CostSource.SUBSCRIPTION.name || usage.costSource == CostSource.UPSTREAM.name) {
            return legacy()
        }
        val base = catalog ?: return when {
            usage.hasNoUsage() -> unknownPart(USD)
            allowsLocalPriceWithoutCatalog(provider) -> legacy()
            else -> {
                // The selected currency cannot be determined to be USD: do not fall back to the local unit price (it has no currency, so falling back would record it as dollars), only accept the existing service-layer amount.
                val unknown = isUnknownPricing(priced, null, kind)
                DeliveredCost(resolve(priced, null, kind), USD, unknown, if (unknown) CostSource.UNKNOWN.name else priced.costSource)
            }
        }
        val pricing = select(provider, base, regionOptions)
        val selected = pricing.selected
        val currency = pricing.currencyCode
        if (usage.hasNoUsage() && isPerToken(selected)) return unknownPart(currency)
        // Per-unit pricing is estimated by the actual unit count, with no "at least 1 unit" floor: 0 units is unknown; a free entry is still a real 0.
        if (!isPerToken(selected) && units <= 0 && selected.pricingStatus != "free") return unknownPart(currency)
        return part(CostCalculator.estimate(usage.toBucketedBreakdown(), selected, at = at, units = units), currency)
    }

    /**
     * Delivery accounting entry: the generation cost of one message split into parts by currency. A single leg is one part of [resolve];
     * for multiple legs ([ProviderChatResult.legs]) each leg is [resolve]d on its own (that leg's upstream actual cost > estimate) and then summed per currency via [sumLegParts],
     * recorded as a USD part + the single non-USD part. A subscription connection is judged once by the connection authMode and the whole message is recorded as subscription.
     * [legCatalog] gives the catalog entry of leg i; by default every leg uses [catalog].
     * Per-unit pricing (the selected price is not per_token) is not split by leg: the whole message is estimated once by [units]; upstream actual costs are summed per leg only when every leg returned one
     * (upstream actual cost wins), and when only some legs reported, the whole message is still estimated per unit; Relay does not adopt upstream actual cost and always estimates the whole message once.
     */
    fun resolveParts(
        result: ProviderChatResult?,
        model: AIModel?,
        provider: Provider,
        modelId: String,
        at: Instant,
        units: Int = 1,
        relayTransport: RelayTransport? = null,
        catalog: MetadataClient.ResolvedModelMetadata? =
            catalogModel(provider.kind, modelId, relayTransport, model?.canonicalModelId),
        regionOptions: List<RegionOption> = regionOptions(provider.kind),
        legCatalog: (Int) -> MetadataClient.ResolvedModelMetadata? = { catalog },
    ): List<DeliveredCost> {
        subscriptionPart(provider)?.let { return listOf(it) }
        val legs = result?.legs?.takeIf { it.size > 1 }
            ?: return listOf(resolve(result, model, provider, modelId, at, units, relayTransport, legCatalog(0), regionOptions))
        val perUnit = legCatalog(0)?.let { !isPerToken(select(provider, it, regionOptions).selected) } == true
        // Per unit: for Relay always, or when not every leg reported an upstream actual cost, the whole message is estimated once per unit; the merged result's source comes from the last leg,
        // and if it is an upstream actual cost it must be wiped, otherwise some legs' actual cost would be adopted as the whole message's actual cost.
        if (perUnit && (provider.kind == ProviderKind.Relay || !legs.all { it.costSource == CostSource.UPSTREAM.name })) {
            val whole = if (result.costSource == CostSource.UPSTREAM.name) {
                result.copy(legs = null, estimatedCost = 0.0, costSource = CostSource.UNKNOWN.name)
            } else {
                result.copy(legs = null)
            }
            return listOf(resolve(whole, model, provider, modelId, at, units, relayTransport, legCatalog(0), regionOptions))
        }
        return sumLegParts(
            legs.mapIndexed { index, leg ->
                resolve(leg, model, provider, modelId, at, units, relayTransport, legCatalog(index), regionOptions)
            },
            anyLegWithoutUsage = legs.any { !it.usageReported },
        )
    }

    /** A subscription connection (judged by the connection authMode): the whole message is recorded as subscription at 0, not estimated by usage. */
    private fun subscriptionPart(provider: Provider): DeliveredCost? =
        if (provider.authMode == ProviderAuthMode.Subscription) {
            DeliveredCost(0.0, USD, unknown = false, CostSource.SUBSCRIPTION.name)
        } else {
            null
        }

    /**
     * Production merge entry for multi-leg messages (fixture multiLegCostCases): the results of tool loop / library first leg + answer /
     * resend / propose tail legs are combined into one. Tokens and cache buckets are summed, service-layer amounts are summed, and [ProviderChatResult.usageReported]
     * requires every leg to have returned usage; each leg is kept as is in [ProviderChatResult.legs] (nested multi-leg results are flattened), and at delivery [resolve]
     * prices each leg on its own (that leg's upstream actual cost > estimate) and then sums them. A null in [legs] = that leg has no result at all (counted as no usage returned).
     * Other fields (citations, thinking, servedModelID etc.) come from [base], by default the last non-null leg; the body text is overridden by the caller.
     */
    fun mergeLegs(legs: List<ProviderChatResult?>, base: ProviderChatResult? = null): ProviderChatResult {
        val flat = legs.flatMap { leg ->
            leg?.legs ?: listOf(leg ?: ProviderChatResult(text = "", usageReported = false))
        }
        fun sumBucket(pick: (ProviderChatResult) -> Int?): Int? =
            flat.mapNotNull(pick).takeIf { it.isNotEmpty() }?.sum()
        return (base ?: legs.lastOrNull { it != null } ?: ProviderChatResult(text = "", usageReported = false)).copy(
            promptTokens = flat.sumOf { it.promptTokens },
            completionTokens = flat.sumOf { it.completionTokens },
            estimatedCost = flat.sumOf { it.estimatedCost },
            cachedInputTokens = sumBucket { it.cachedInputTokens },
            cacheCreation5mTokens = sumBucket { it.cacheCreation5mTokens },
            cacheCreation1hTokens = sumBucket { it.cacheCreation1hTokens },
            usageReported = flat.all { it.usageReported },
            legs = flat,
        )
    }

    /**
     * Per-leg pricing parts summed per currency (fixture multiLegCostCases): any leg without usage or with an unknown price -> the whole message unknown;
     * legs of the same currency are summed into one part, USD part first; the USD part is recorded UPSTREAM only if all of it came from upstream actual cost, otherwise LOCAL_ESTIMATE,
     * the source of a non-USD part is that of the first leg of that currency; when a second non-USD currency appears the parts of every currency are still handed out, and [record] merges them via [mergeNonUsdCost]
     * by the record rule into {first non-USD currency, 0, UNKNOWN} while the USD part is kept (same as recordCases second_non_usd_currency_marks_unknown).
     * No conversion and no leg is dropped.
     */
    internal fun sumLegParts(parts: List<DeliveredCost>, anyLegWithoutUsage: Boolean): List<DeliveredCost> {
        val first = parts.firstOrNull()?.currencyCode ?: USD
        if (anyLegWithoutUsage || parts.isEmpty() || parts.any { it.unknown || it.costSource == CostSource.UNKNOWN.name }) {
            return listOf(unknownPart(first))
        }
        val byCurrency = parts.groupBy { it.currencyCode }
        return byCurrency.entries
            .sortedBy { if (it.key == USD) 0 else 1 }
            .map { (currency, legs) ->
                val source = when {
                    currency != USD -> legs.first().costSource
                    legs.all { it.costSource == CostSource.UPSTREAM.name } -> CostSource.UPSTREAM.name
                    else -> CostSource.LOCAL_ESTIMATE.name
                }
                DeliveredCost(legs.sumOf { it.amount }, currency, unknown = false, source)
            }
    }

    /**
     * Unit count for per-unit pricing: the number of images actually produced by this message (production count, same entry for delivery accounting and contract tests).
     */
    fun producedUnits(attachments: List<Attachment>): Int =
        attachments.count { it.kind == AttachmentKind.Image }

    private fun unknownPart(currency: String) = DeliveredCost(0.0, currency, unknown = true, CostSource.UNKNOWN.name)

    /**
     * Upstream returned no usage object (only a missing object counts, all buckets 0 = real 0).
     */
    private fun ProviderChatResult.hasNoUsage(): Boolean = !usageReported

    private fun isPerToken(pricing: MetadataClient.ResolvedModelMetadata): Boolean =
        (pricing.pricingV2?.unit ?: pricing.pricingUnit) == "per_token"

    /**
     * Price selection entry when there is a connection context (shared by delivery billing [resolve] and unit-price labels, the same selection entry):
     * the catalog price is selected by the connection's effective region via [RegionPricingSelector.select], and the currency is that of the selected price.
     * Returns null when the catalog has no match (the caller keeps the model-level price).
     */
    fun connectionPricing(
        provider: Provider,
        modelId: String,
        relayTransport: RelayTransport? = null,
        canonicalModelId: String? = null,
        catalog: MetadataClient.ResolvedModelMetadata? = catalogModel(provider.kind, modelId, relayTransport, canonicalModelId),
        regionOptions: List<RegionOption> = regionOptions(provider.kind),
    ): ConnectionPricing? {
        val base = catalog ?: return null
        return select(provider, base, regionOptions)
    }

    private fun select(
        provider: Provider,
        base: MetadataClient.ResolvedModelMetadata,
        regionOptions: List<RegionOption>,
    ): ConnectionPricing {
        val selected = RegionPricingSelector.select(
            model = base,
            regionOptions = regionOptions,
            endpointSource = provider.endpointSource,
            baseUrl = provider.baseUrlText,
            kind = provider.kind,
            setupValues = provider.setupValues,
        )
        return ConnectionPricing(selected, pricingCurrency(selected), regionEntryChosen = selected !== base)
    }

    /** One local estimate as a pricing part: when the price is unknown the amount is 0, the source UNKNOWN, and the currency that of the selected price [currency]. */
    fun part(estimate: CostEstimate, currency: String = estimate.currencyCode): DeliveredCost =
        if (estimate.source == CostSource.UNKNOWN) {
            DeliveredCost(0.0, currency, unknown = true, CostSource.UNKNOWN.name)
        } else {
            DeliveredCost(estimate.amount, estimate.currencyCode, unknown = false, estimate.source.name)
        }

    /** Library retrieval cost: the USD part estimated at OpenAI dollar prices; when there is no cost (<= epsilon) it does not become a part. */
    fun retrievalPart(estimatedCost: Double?): DeliveredCost? =
        estimatedCost?.takeIf { it > CostFormatter.COST_EPSILON }
            ?.let { DeliveredCost(it, USD, unknown = false, CostSource.LOCAL_ESTIMATE.name) }

    /**
     * Combines the pricing parts of one message into the persisted shape (fixture cost-currency recordCases; same as Web recordOfParts):
     * a part with unknown price is not recorded (it does not become a 0 part nor produce a non-USD part); USD parts are summed into estimatedCost, costSource is taken from the first
     * known USD part (UNKNOWN when none); non-USD parts are merged into nonUsdCost via [mergeNonUsdCost], without conversion.
     */
    fun record(parts: List<DeliveredCost>): MessageCostRecord {
        var usdAmount = 0.0
        var usdSource: String? = null
        var nonUsdCost: NonUsdCost? = null
        for (part in parts) {
            if (part.unknown || part.costSource == CostSource.UNKNOWN.name) continue
            val source = part.costSource ?: CostSource.LOCAL_ESTIMATE.name
            if (part.isUsd) {
                usdAmount += part.amount
                if (usdSource == null) usdSource = source
            } else {
                nonUsdCost = mergeNonUsdCost(nonUsdCost, NonUsdCost(part.currencyCode, part.amount, source))
            }
        }
        return MessageCostRecord(
            estimatedCost = usdAmount,
            costSource = usdSource ?: CostSource.UNKNOWN.name,
            nonUsdCost = nonUsdCost,
        )
    }

    /**
     * Merges two non-USD parts (same as Web mergeNonUsdCost): if one side is missing take the other; same currency with both amounts usable -> sum
     * (costSource from the first); different currencies or either amount unknown -> {first currency, 0, UNKNOWN}, not summed and not converted.
     */
    fun mergeNonUsdCost(first: NonUsdCost?, second: NonUsdCost?): NonUsdCost? {
        if (first == null) return second
        if (second == null) return first
        if (first.currencyCode != second.currencyCode ||
            first.costSource == CostSource.UNKNOWN.name ||
            second.costSource == CostSource.UNKNOWN.name
        ) {
            return NonUsdCost(first.currencyCode, 0.0, CostSource.UNKNOWN.name)
        }
        return first.copy(amount = first.amount + second.amount)
    }

    /**
     * Appends one more cost to the same message (continuation, same as Web addMessageCost): USD parts are summed, non-USD parts are merged via [mergeNonUsdCost].
     * The returned costSource is that of this round (one continuation is one new upstream billing request).
     */
    fun addMessageCost(baseEstimatedCost: Double, baseNonUsdCost: NonUsdCost?, next: MessageCostRecord): MessageCostRecord =
        next.copy(
            estimatedCost = baseEstimatedCost + next.estimatedCost,
            nonUsdCost = mergeNonUsdCost(baseNonUsdCost, next.nonUsdCost),
        )

    /**
     * Region options used for region selection: those delivered by metadata (past the trusted table) first, then ids not listed there from the frozen identity table.
     * The identity table does not change with whether metadata is loaded, so a cn connection is still recognized as the cn region when metadata is not loaded and is not recorded at the model-level dollar price.
     */
    private fun regionOptions(kind: ProviderKind): List<RegionOption> {
        val fromMetadata = OfficialEndpointSource.metadataCatalog(kind)?.regions.orEmpty()
        val known = fromMetadata.mapTo(HashSet()) { it.id }
        val fromIdentity = DeterministicProviderId.identityRegions[kind].orEmpty()
            .filter { it.id !in known }
            .map { RegionOption(it.id, it.id, it.baseURL) }
        return fromMetadata + fromIdentity
    }

    /**
     * Catalog price used for delivery estimation: official providers use their own catalog, Relay matches across providers by an allowlist (transport priority same as the service layer),
     * first by [canonicalModelId] and then by id ([relayCatalogMatch], the same match as the service layer and capability inheritance).
     */
    private fun catalogModel(
        kind: ProviderKind,
        modelId: String,
        relayTransport: RelayTransport?,
        canonicalModelId: String? = null,
    ): MetadataClient.ResolvedModelMetadata? = when (kind) {
        ProviderKind.Relay -> relayCatalogMatch(modelId, canonicalModelId, relayTransport)?.metadata
        else -> MetadataClient.resolveCatalogModel(modelId, kind)
    }

    /**
     * When the catalog has no such model, whether the local [AIModel] unit price (no currency, recorded as dollars) may be the fallback: only if the selected currency can be determined to be USD.
     * Relay / custom endpoints do not select a region and keep the fallback as before; an official provider needs the whole catalog of that provider to be USD prices ([providerPricedAllInUsd]),
     * and when metadata is not loaded or the provider has no catalog models it cannot be determined and there is no fallback (recorded unknown).
     */
    private fun allowsLocalPriceWithoutCatalog(provider: Provider): Boolean {
        if (provider.kind == ProviderKind.Relay || provider.endpointSource == OfficialEndpointSource.CUSTOM) return true
        return providerPricedAllInUsd(provider.kind)
    }

    /** Whether every price in this provider's catalog is USD (the model-level price and every region price of each model); returns false when the catalog is empty because it cannot be determined. */
    private fun providerPricedAllInUsd(kind: ProviderKind): Boolean {
        val ids = MetadataClient.providerModelIds(kind)
        if (ids.isEmpty()) return false
        return ids.all { id ->
            val model = MetadataClient.resolveCatalogModel(id, kind) ?: return@all false
            pricingCurrency(model) == USD && model.regionPricing.all { entry ->
                normalizedCurrency(entry.price.pricingV2?.currencyCode ?: entry.price.currencyCode) == USD
            }
        }
    }

    /** Currency of the selected price: the pricingV2 currency first, otherwise the model level; uppercase, USD when empty (same as [CostCalculator.estimate]). */
    internal fun pricingCurrency(pricing: MetadataClient.ResolvedModelMetadata): String =
        normalizedCurrency(pricing.pricingV2?.currencyCode ?: pricing.currencyCode)

    private fun normalizedCurrency(code: String?): String =
        code?.trim()?.uppercase()?.takeIf { it.isNotEmpty() } ?: USD

    fun resolve(result: ProviderChatResult?, model: AIModel?, providerKind: ProviderKind): Double {
        val usage = result ?: return 0.0
        if (usage.estimatedCost > CostFormatter.COST_EPSILON) return usage.estimatedCost
        // A reported upstream actual cost of 0 is a real 0 and is not topped up with local unit prices.
        if (usage.costSource == CostSource.UPSTREAM.name) return usage.estimatedCost
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

    /** Legacy (USD path) unknown check; delivery with a connection goes through [DeliveredCostResolver.resolve] returning [DeliveredCost.unknown], and the two agree for USD. */
    fun isUnknownPricing(result: ProviderChatResult?, model: AIModel?, providerKind: ProviderKind): Boolean {
        val usage = result ?: return false
        if (usage.estimatedCost > CostFormatter.COST_EPSILON) return false
        if (usage.costSource == CostSource.UPSTREAM.name) return false
        if (usage.promptTokens <= 0 && usage.completionTokens <= 0) return false
        val promptPrice = model?.promptPrice ?: 0.0
        val completionPrice = model?.completionPrice ?: 0.0
        return promptPrice <= 0.0 && completionPrice <= 0.0
    }
}
